//
//  TokenModels.swift
//  share-my-status-client
//
//  Pure, Foundation-only domain models and aggregation logic for AI token usage.
//  Intentionally free of AppKit / SwiftUI so the parsers + aggregation stay
//  trivially unit-testable.
//

import Foundation

// MARK: - Raw parsed entry

/// One token-usage record parsed from a local AI-tool log.
///
/// Mirrors kaboo's `TokenEntry` (cli/parsers.go ~line 24). Each entry already has
/// its reasoning share carved out of `outputTokens` (so the four counters never
/// overlap and `output` is reasoning-free), matching the kaboo parsers.
///
/// All token domain types are explicitly `nonisolated`: this layer is pure,
/// Foundation-only value logic with no shared mutable state, callable from any
/// actor (the `actor TokenUsageService`) and unit-testable standalone.
nonisolated struct TokenEntry: Equatable {
    /// Tool/source label, e.g. "claude-code", "codex", "gemini-cli", "cursor".
    let source: String
    /// Model name, e.g. "claude-opus-4-8". "unknown" when absent.
    let model: String
    /// Project name derived from the log path / session cwd. "unknown" when absent.
    let project: String
    /// Event timestamp.
    let timestamp: Date
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedInputTokens: Int64
    /// Anthropic cache-WRITE tokens (`cache_creation_input_tokens`). A separate
    /// counter, parallel to the other four (never folded into input/cached) —
    /// matches kaboo's claude-code accounting where cache_creation is the dominant
    /// component of usage.
    let cacheCreationInputTokens: Int64
    let reasoningOutputTokens: Int64
    /// Distinct session this entry belongs to (used for today's sessionCount).
    let sessionId: String
    /// Stable upstream message id when available; used to dedup re-reads of the
    /// same record. Empty when the source has no stable id (entry is kept as-is).
    let messageId: String

    init(source: String,
         model: String,
         project: String = "unknown",
         timestamp: Date,
         inputTokens: Int64 = 0,
         outputTokens: Int64 = 0,
         cachedInputTokens: Int64 = 0,
         cacheCreationInputTokens: Int64 = 0,
         reasoningOutputTokens: Int64 = 0,
         sessionId: String = "",
         messageId: String = "") {
        self.source = source
        self.model = model
        self.project = project
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.sessionId = sessionId
        self.messageId = messageId
    }

    /// Sum of the five counters. Used for top-model / top-N ranking.
    var totalTokens: Int64 {
        inputTokens + outputTokens + cachedInputTokens
            + cacheCreationInputTokens + reasoningOutputTokens
    }
}

// MARK: - Aggregated value types (domain, pre-DTO)

/// Per-model aggregate inside a window.
nonisolated struct TokenModelAggregate: Equatable {
    let model: String
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var cacheCreationInputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0

    var totalTokens: Int64 {
        inputTokens + outputTokens + cachedInputTokens
            + cacheCreationInputTokens + reasoningOutputTokens
    }
}

/// Aggregate for a single time window (today / last7d / total).
nonisolated struct TokenWindowAggregate: Equatable {
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var cacheCreationInputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    /// Top-N models by total tokens, with the remainder folded into "other".
    var byModel: [TokenModelAggregate] = []

    var totalTokens: Int64 {
        inputTokens + outputTokens + cachedInputTokens
            + cacheCreationInputTokens + reasoningOutputTokens
    }
}

/// The full aggregated token-usage payload for one scan cycle.
nonisolated struct TokenUsageAggregate: Equatable {
    var today = TokenWindowAggregate()
    var last7d = TokenWindowAggregate()
    var total = TokenWindowAggregate()
    var topModel: String = ""
    var sessionCount: Int = 0
    var windowDays: Int = 30
    /// Computation time (ms since epoch).
    var ts: Int64 = 0

    /// A zeroed payload used when reporting is disabled / no data exists.
    static func zeroed(windowDays: Int, ts: Int64) -> TokenUsageAggregate {
        TokenUsageAggregate(
            today: TokenWindowAggregate(),
            last7d: TokenWindowAggregate(),
            total: TokenWindowAggregate(),
            topModel: "",
            sessionCount: 0,
            windowDays: windowDays,
            ts: ts
        )
    }
}

// MARK: - Aggregation

/// Pure aggregation over parsed entries. `now` is injectable so the windowing
/// is deterministic in tests; `calendar` lets tests pin a timezone.
nonisolated enum TokenAggregator {
    /// Max number of explicit models in `byModel`; the rest fold into "other".
    static let topModelLimit = 8

    /// Build the full aggregate from raw entries.
    ///
    /// - Dedups by `messageId` (when present) so re-reads don't double count.
    /// - `today`  = entries on the local calendar day of `now`.
    /// - `last7d` = entries with timestamp >= now − 7×24h (rolling).
    /// - `total`  = entries with timestamp >= now − windowDays×24h (rolling).
    /// - `topModel` = model with max total in today; if today empty, use total; else "".
    /// - `sessionCount` = distinct sessionIds with >= 1 entry today.
    static func aggregate(entries: [TokenEntry],
                          windowDays: Int,
                          now: Date,
                          calendar: Calendar = .current) -> TokenUsageAggregate {
        let deduped = dedupe(entries)
        let safeWindowDays = max(1, windowDays)

        // Windows match kaboo: `today` = calendar day (kaboo "1D"); `last7d`/`total`
        // are ROLLING N×24h windows anchored at `now` (kaboo "7D"/"30D"), not
        // calendar-aligned. windowDays is always >= 7 (UI range), so startTotal <= start7d.
        let start7d = now.addingTimeInterval(-7 * 86400)
        let startTotal = now.addingTimeInterval(-Double(safeWindowDays) * 86400)

        var todayEntries: [TokenEntry] = []
        var last7dEntries: [TokenEntry] = []
        var totalEntries: [TokenEntry] = []

        var todaySessions = Set<String>()

        for e in deduped {
            // total window is the widest; anything outside it is ignored entirely.
            guard e.timestamp >= startTotal else { continue }
            totalEntries.append(e)
            if e.timestamp >= start7d {
                last7dEntries.append(e)
            }
            if calendar.isDate(e.timestamp, inSameDayAs: now) {
                todayEntries.append(e)
                if !e.sessionId.isEmpty {
                    todaySessions.insert(e.sessionId)
                }
            }
        }

        let todayWindow = window(from: todayEntries)
        let last7dWindow = window(from: last7dEntries)
        let totalWindow = window(from: totalEntries)

        // topModel: prefer today's top, fall back to total's top, else "".
        let top = topModel(today: todayWindow, total: totalWindow)

        return TokenUsageAggregate(
            today: todayWindow,
            last7d: last7dWindow,
            total: totalWindow,
            topModel: top,
            sessionCount: todaySessions.count,
            windowDays: safeWindowDays,
            ts: Int64(now.timeIntervalSince1970 * 1000)
        )
    }

    /// Dedup by stable messageId, keeping the largest-total entry per id (mirrors
    /// kaboo's dedupeTokenEntriesByKey). Entries with empty messageId are kept.
    static func dedupe(_ entries: [TokenEntry]) -> [TokenEntry] {
        var seen: [String: Int] = [:]
        var out: [TokenEntry] = []
        out.reserveCapacity(entries.count)
        for e in entries {
            // Namespace the key by source so distinct tools can't collide.
            guard !e.messageId.isEmpty else {
                out.append(e)
                continue
            }
            let key = e.source + ":" + e.messageId
            if let idx = seen[key] {
                if e.totalTokens > out[idx].totalTokens {
                    out[idx] = e
                }
            } else {
                seen[key] = out.count
                out.append(e)
            }
        }
        return out
    }

    /// Sum the four counters and build the top-N byModel list with "other" folding.
    static func window(from entries: [TokenEntry]) -> TokenWindowAggregate {
        var w = TokenWindowAggregate()
        var byModel: [String: TokenModelAggregate] = [:]

        for e in entries {
            w.inputTokens += e.inputTokens
            w.outputTokens += e.outputTokens
            w.cachedInputTokens += e.cachedInputTokens
            w.cacheCreationInputTokens += e.cacheCreationInputTokens
            w.reasoningOutputTokens += e.reasoningOutputTokens

            var m = byModel[e.model] ?? TokenModelAggregate(model: e.model)
            m.inputTokens += e.inputTokens
            m.outputTokens += e.outputTokens
            m.cachedInputTokens += e.cachedInputTokens
            m.cacheCreationInputTokens += e.cacheCreationInputTokens
            m.reasoningOutputTokens += e.reasoningOutputTokens
            byModel[e.model] = m
        }

        // Drop zero-total placeholder models (e.g. claude-code writes "<synthetic>"
        // rows with zeroed usage) so they never reach the wire payload or UI.
        w.byModel = topNByModel(byModel.values.filter { $0.totalTokens > 0 })
        return w
    }

    /// Sort models by total desc (model name asc as tie-break for determinism),
    /// keep top-N, fold the remainder into a synthetic "other" entry.
    static func topNByModel(_ models: [TokenModelAggregate]) -> [TokenModelAggregate] {
        let sorted = models.sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens {
                return lhs.totalTokens > rhs.totalTokens
            }
            return lhs.model < rhs.model
        }

        guard sorted.count > topModelLimit else { return sorted }

        var result = Array(sorted.prefix(topModelLimit))
        var other = TokenModelAggregate(model: "other")
        for m in sorted.dropFirst(topModelLimit) {
            other.inputTokens += m.inputTokens
            other.outputTokens += m.outputTokens
            other.cachedInputTokens += m.cachedInputTokens
            other.cacheCreationInputTokens += m.cacheCreationInputTokens
            other.reasoningOutputTokens += m.reasoningOutputTokens
        }
        if other.totalTokens > 0 {
            result.append(other)
        }
        return result
    }

    /// topModel = today's max-total model; if today has none, total's; else "".
    static func topModel(today: TokenWindowAggregate, total: TokenWindowAggregate) -> String {
        if let m = maxModel(today.byModel) { return m }
        if let m = maxModel(total.byModel) { return m }
        return ""
    }

    private static func maxModel(_ models: [TokenModelAggregate]) -> String? {
        // byModel is already sorted by total desc, but be defensive and re-pick.
        let candidates = models.filter { $0.totalTokens > 0 && $0.model != "other" }
        guard let best = candidates.max(by: { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens < rhs.totalTokens }
            return lhs.model > rhs.model
        }) else { return nil }
        return best.model
    }
}

// MARK: - DTO mapping

nonisolated extension TokenWindowAggregate {
    /// Map to the wire DTO. Per the frozen contract the client sends the four
    /// counters + byModel; totalTokens / estimatedCostUsd are server-computed and
    /// left nil so Codable omits them.
    func toDTO() -> TokenWindowUsageDTO {
        TokenWindowUsageDTO(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            byModel: byModel.map { $0.toDTO() }
        )
    }
}

nonisolated extension TokenModelAggregate {
    func toDTO() -> TokenModelUsageDTO {
        TokenModelUsageDTO(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            reasoningOutputTokens: reasoningOutputTokens
        )
    }
}

nonisolated extension TokenUsageAggregate {
    func toDTO() -> TokenUsageDTO {
        TokenUsageDTO(
            today: today.toDTO(),
            last7d: last7d.toDTO(),
            total: total.toDTO(),
            topModel: topModel,
            sessionCount: Int64(sessionCount),
            windowDays: Int32(windowDays),
            ts: ts
        )
    }
}

// MARK: - Human formatting (Foundation-only)

nonisolated enum TokenFormatting {
    /// Format a token count compactly, e.g. 1234 -> "1.2K", 1_200_000 -> "1.2M".
    static func compact(_ value: Int64) -> String {
        let v = Double(value)
        // Unit-promotion thresholds match the Go side: values that would round
        // to "1000.0" of the smaller unit promote instead (999_999 -> "1M",
        // not "1000K").
        switch value {
        case ..<1_000:
            return "\(value)"
        case ..<999_950:
            return trim(v / 1_000) + "K"
        case ..<999_950_000:
            return trim(v / 1_000_000) + "M"
        default:
            return trim(v / 1_000_000_000) + "B"
        }
    }

    private static func trim(_ value: Double) -> String {
        // One decimal place, but drop a trailing ".0".
        let s = String(format: "%.1f", value)
        if s.hasSuffix(".0") {
            return String(s.dropLast(2))
        }
        return s
    }
}
