//
//  TraeParser.swift
//  share-my-status-client
//
//  Parser for the Trae CLI (coco) on-disk trace spans.
//  Mirrors kaboo's ParseTraeCLI / parseTraeCLISessionDir (cli/parser_trae_cli.go):
//    - scans <root>/<session>/traces.jsonl under coco's session roots:
//        $XDG_CACHE_HOME/coco/sessions, ~/.cache/coco/sessions,
//        ~/Library/Caches/coco/sessions   (deduped, in that order)
//    - each traces.jsonl line is an OTel-style span; usage lives in the span's
//      `tags` (an array of {key,type,value}, or a map):
//        usage.input_tokens, usage.output_tokens, usage.cache_read_tokens,
//        usage.reasoning_tokens, usage.total_tokens; model = tag "model.name".
//    - kaboo normalization (must match exactly):
//        cacheRead = min(cacheRead, input); reasoning = min(reasoning, output)
//        normalizedInput  = max(0, input - cacheRead)   -> inputTokens
//        normalizedOutput = max(0, output - reasoning)   -> outputTokens
//        cacheRead -> cachedInputTokens; reasoning -> reasoningOutputTokens
//      i.e. cache_read is carved OUT of input, reasoning OUT of output, so the
//      four counters never overlap (same shape as TokenEntry's contract).
//    - only spans that "look like" a model-usage span are kept (a name/category
//      free of tool/read/bash/file/command/agent/system substrings, with a
//      non-zero usage sum) — replicates looksLikeTraeCLIModelUsage.
//    - timestamp = startTime + duration (microseconds), falling back to the
//      session updated_at/created_at.
//    - project = base name of session.json metadata.cwd ("unknown" otherwise).
//    - DedupKey = "trae-cli:<traceID>:<spanID>" when both present, else a content
//      fingerprint (sha256 over source|ts|model|in|out|cached|reasoning|...).
//      We store that key (minus the "trae-cli:" prefix) in `messageId` so the
//      Swift aggregator's `source + ":" + messageId` dedup reproduces kaboo's key.
//
//  This port covers TOKEN accounting only. kaboo additionally emits SessionEvents
//  and count-only skill entries from the sibling events.jsonl; those carry NO
//  token totals (tokens come from traces.jsonl exclusively) and have no field in
//  the Swift TokenEntry, so they are intentionally not ported here.
//
//  Foundation-only; never throws on malformed input — bad records are skipped.
//

import Foundation
import CommonCrypto

nonisolated struct TraeParser: TokenLogParser {
    let source = "trae-cli"

    /// Override session roots (tests inject a temp dir). When empty, resolves the
    /// coco defaults (honoring $XDG_CACHE_HOME), exactly like kaboo.
    let configDirs: [URL]

    init(configDirs: [URL] = []) {
        self.configDirs = configDirs
    }

    /// Mirrors kaboo's traeCLISessionRoots: XDG_CACHE_HOME/coco/sessions first
    /// (if set), then ~/.cache/coco/sessions and ~/Library/Caches/coco/sessions,
    /// with duplicates removed in first-seen order.
    private func resolvedRoots() -> [URL] {
        if !configDirs.isEmpty { return configDirs }
        let home = TokenParseHelpers.homeDirectory
        var roots: [URL] = []
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CACHE_HOME"]?.trimmingCharacters(in: .whitespaces), !xdg.isEmpty {
            roots.append(URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("coco", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true))
        }
        roots.append(home.appendingPathComponent(".cache/coco/sessions", isDirectory: true))
        roots.append(home.appendingPathComponent("Library/Caches/coco/sessions", isDirectory: true))
        // Dedup by resolved path, first-seen order (kaboo dedupeStrings).
        var seen = Set<String>()
        var out: [URL] = []
        for r in roots where seen.insert(r.standardizedFileURL.path).inserted {
            out.append(r)
        }
        return out
    }

    func parse(since: Date, cache: inout TokenScanCache) -> [TokenEntry] {
        var out: [TokenEntry] = []
        let fm = FileManager.default
        // Dedup traces.jsonl files across sibling roots by realpath (kaboo `seen`).
        var seenTraceRealPaths = Set<String>()

        for root in resolvedRoots() {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for sessionDir in entries {
                let dv = try? sessionDir.resourceValues(forKeys: [.isDirectoryKey])
                guard dv?.isDirectory == true else { continue }

                let tracesPath = sessionDir.appendingPathComponent("traces.jsonl", isDirectory: false)
                guard fm.fileExists(atPath: tracesPath.path) else { continue }

                // Dedup fork-copied sessions by the resolved real path of traces.jsonl.
                let realPath = (try? FileManager.default.destinationOfSymbolicLink(atPath: tracesPath.path))
                    .map { Self.resolveRelative($0, relativeTo: tracesPath) } ?? tracesPath.resolvingSymlinksInPath().path
                if !seenTraceRealPaths.insert(realPath).inserted { continue }

                // Bound work by mtime: a file last modified before `since` (minus a
                // 1-day slack, since one file holds a whole session's spans) can't
                // contribute to any window we care about.
                if let key = TokenScanCache.fileKey(for: tracesPath),
                   Double(key.mtimeMs) / 1000 < since.timeIntervalSince1970 - 86_400 {
                    continue
                }

                if let cached = cache.cachedEntries(for: tracesPath) {
                    out.append(contentsOf: cached)
                    continue
                }

                let entries = Self.parseSessionDir(sessionDir, tracesPath: tracesPath)
                cache.store(entries, for: tracesPath)
                out.append(contentsOf: entries)
            }
        }
        return out
    }

    // MARK: - Session parsing

    static func parseSessionDir(_ sessionDir: URL, tracesPath: URL) -> [TokenEntry] {
        let meta = readSessionMeta(sessionDir.appendingPathComponent("session.json", isDirectory: false))
        let project = projectName(from: meta.cwd)
        let fallbackModel = meta.modelName.trimmingCharacters(in: .whitespaces)
        let fallbackTS = fallbackTime(meta)
        let fallbackSessionID = firstNonEmpty(meta.id, sessionDir.lastPathComponent)

        var entries: [TokenEntry] = []
        TokenParseHelpers.forEachJSONLLine(at: tracesPath) { obj in
            guard let entry = entryFromTrace(
                obj,
                project: project,
                sessionId: fallbackSessionID,
                fallbackModel: fallbackModel,
                fallbackTS: fallbackTS
            ) else { return }
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Trace -> TokenEntry (mirrors traeCLIEntryFromTrace)

    private static func entryFromTrace(
        _ obj: [String: Any],
        project: String,
        sessionId: String,
        fallbackModel: String,
        fallbackTS: Date?
    ) -> TokenEntry? {
        let tags = traeTags(obj)
        if tags.isEmpty { return nil }

        let inputRaw = max(0, TokenParseHelpers.int64(tags, "usage.input_tokens"))
        let outputRaw = max(0, TokenParseHelpers.int64(tags, "usage.output_tokens"))
        var cacheRead = max(0, TokenParseHelpers.int64(tags, "usage.cache_read_tokens"))
        var reasoning = max(0, TokenParseHelpers.int64(tags, "usage.reasoning_tokens"))
        let totalTokens = max(0, TokenParseHelpers.int64(tags, "usage.total_tokens"))

        var model = (tags["model.name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if model.isEmpty { model = fallbackModel }
        if model.isEmpty { return nil }

        if cacheRead > inputRaw { cacheRead = inputRaw }
        if reasoning > outputRaw { reasoning = outputRaw }
        let normalizedInput = max(0, inputRaw - cacheRead)
        let normalizedOutput = max(0, outputRaw - reasoning)
        if normalizedInput + normalizedOutput + cacheRead + reasoning == 0 { return nil }

        let category = firstNonEmpty(stringValue(obj["span.category"]), tags["span.category"] as? String ?? "")
        let spanName = firstNonEmpty(stringValue(obj["span.name"]), tags["span.name"] as? String ?? "")
        let usageSum = inputRaw + outputRaw + cacheRead + reasoning
        if !looksLikeModelUsage(category: category, spanName: spanName, usageSum: usageSum, model: model) {
            return nil
        }

        guard let ts = traceTimestamp(obj, fallback: fallbackTS) else { return nil }

        let traceID = firstNonEmpty(
            stringValue(obj["traceId"]), stringValue(obj["traceID"]), stringValue(obj["trace.id"])
        )
        let spanID = firstNonEmpty(
            stringValue(obj["spanId"]), stringValue(obj["spanID"]), stringValue(obj["span.id"])
        )
        // kaboo DedupKey = "trae-cli:<traceID>:<spanID>" (or content fingerprint).
        // We store the part AFTER "trae-cli:" in messageId so the Swift aggregator's
        // "<source>:<messageId>" reproduces kaboo's exact key.
        let messageId = dedupMessageId(
            traceID: traceID, spanID: spanID, model: model, ts: ts,
            totalTokens: totalTokens, input: normalizedInput, output: normalizedOutput,
            cached: cacheRead, reasoning: reasoning
        )

        return TokenEntry(
            source: "trae-cli",
            model: model,
            project: project,
            timestamp: ts,
            inputTokens: normalizedInput,
            outputTokens: normalizedOutput,
            cachedInputTokens: cacheRead,
            reasoningOutputTokens: reasoning,
            sessionId: sessionId,
            messageId: messageId
        )
    }

    /// Mirrors looksLikeTraeCLIModelUsage: reject spans whose category/name look
    /// like a tool/system span; require a non-empty model and non-zero usage.
    static func looksLikeModelUsage(category: String, spanName: String, usageSum: Int64, model: String) -> Bool {
        if model.isEmpty { return false }
        if usageSum == 0 { return false }
        let bad = ["tool", "read", "bash", "file", "command", "agent", "system"]
        for value in [category.lowercased().trimmingCharacters(in: .whitespaces),
                      spanName.lowercased().trimmingCharacters(in: .whitespaces)] {
            for token in bad where value.contains(token) {
                return false
            }
        }
        return true
    }

    // MARK: - Tags (array-or-map form, mirrors traeCLITags)

    /// Normalize the span's `tags` into a [key: value] map. Real coco traces use
    /// the array form ([{key,type,value}, ...]); a map form is also tolerated.
    static func traeTags(_ obj: [String: Any]) -> [String: Any] {
        if let map = obj["tags"] as? [String: Any] { return map }
        guard let arr = obj["tags"] as? [[String: Any]] else { return [:] }
        var out: [String: Any] = [:]
        for tag in arr {
            let key = (tag["key"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            out[key] = tag["value"]
        }
        return out
    }

    // MARK: - Timestamps (mirrors traeCLITraceTimestamp / unixAuto)

    static func traceTimestamp(_ obj: [String: Any], fallback: Date?) -> Date? {
        var start = timestampValue(obj["startTime"])
        if start == nil { start = timestampValue(obj["start_time"]) }
        let durationMicros = durationMicros(obj)
        if let s = start {
            if durationMicros > 0 {
                return s.addingTimeInterval(Double(durationMicros) / 1_000_000.0)
            }
            return s
        }
        return fallback
    }

    private static func timestampValue(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let s = value as? String {
            if let d = parseTimeString(s) { return d }
            if let n = Int64(s.trimmingCharacters(in: .whitespaces)) { return unixAuto(n) }
            return nil
        }
        if let n = value as? Int64 { return unixAuto(n) }
        if let n = value as? Int { return unixAuto(Int64(n)) }
        if let d = value as? Double { return unixAuto(Int64(d)) }
        if let num = value as? NSNumber { return unixAuto(num.int64Value) }
        return nil
    }

    private static func durationMicros(_ obj: [String: Any]) -> Int64 {
        for key in ["duration", "duration_us", "durationUsec", "durationMicros"] {
            guard let value = obj[key] else { continue }
            if let s = value as? String, let n = Int64(s.trimmingCharacters(in: .whitespaces)) {
                return max(0, n)
            }
            if let n = value as? Int64 { return max(0, n) }
            if let n = value as? Int { return max(0, Int64(n)) }
            if let d = value as? Double { return max(0, Int64(d)) }
            if let num = value as? NSNumber { return max(0, num.int64Value) }
        }
        return 0
    }

    /// Mirrors kaboo unixAuto: pick seconds/millis/micros/nanos by magnitude.
    static func unixAuto(_ n: Int64) -> Date? {
        if n <= 0 { return nil }
        let secs: Double
        if n >= 1_000_000_000_000_000_000 {        // >= 1e18 -> nanoseconds
            secs = Double(n) / 1_000_000_000.0
        } else if n >= 1_000_000_000_000_000 {      // >= 1e15 -> microseconds
            secs = Double(n) / 1_000_000.0
        } else if n >= 1_000_000_000_000 {          // >= 1e12 -> milliseconds
            secs = Double(n) / 1_000.0
        } else {                                     // seconds
            secs = Double(n)
        }
        return Date(timeIntervalSince1970: secs)
    }

    /// Mirrors parseTraeCLITimeString: RFC3339(nano) then "yyyy-MM-dd HH:mm:ss".
    static func parseTimeString(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if let d = TokenParseHelpers.parseTimestamp(s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }

    // MARK: - Session metadata (mirrors traeCLISessionMeta + helpers)

    struct SessionMeta {
        var id = ""
        var cwd = ""
        var modelName = ""
        var createdAt = ""
        var updatedAt = ""
    }

    static func readSessionMeta(_ path: URL) -> SessionMeta {
        var meta = SessionMeta()
        guard let data = try? Data(contentsOf: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return meta
        }
        meta.id = obj["id"] as? String ?? ""
        meta.createdAt = obj["created_at"] as? String ?? ""
        meta.updatedAt = obj["updated_at"] as? String ?? ""
        if let md = obj["metadata"] as? [String: Any] {
            meta.cwd = md["cwd"] as? String ?? ""
            meta.modelName = md["model_name"] as? String ?? ""
        }
        return meta
    }

    /// Mirrors traeCLIProject: base name of cwd, "unknown" when empty/root/".".
    static func projectName(from cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "unknown" }
        let base = (trimmed as NSString).lastPathComponent
        if base == "." || base == "/" || base.isEmpty { return "unknown" }
        return base
    }

    /// Mirrors traeCLIFallbackTime: prefer updated_at, then created_at.
    static func fallbackTime(_ meta: SessionMeta) -> Date? {
        for raw in [meta.updatedAt, meta.createdAt] {
            if let ts = parseTimeString(raw) { return ts }
        }
        return nil
    }

    // MARK: - Dedup key (mirrors traeCLIDedupKey + contentDedupKey)

    /// Returns the kaboo DedupKey with its leading "trae-cli:" namespace stripped,
    /// so the aggregator re-applies it via "<source>:<messageId>".
    static func dedupMessageId(
        traceID: String, spanID: String, model: String, ts: Date,
        totalTokens: Int64, input: Int64, output: Int64, cached: Int64, reasoning: Int64
    ) -> String {
        if !traceID.isEmpty && !spanID.isEmpty {
            return "\(traceID):\(spanID)"
        }
        // Content fingerprint fallback (older traces missing trace/span ids).
        let nanos = Int64((ts.timeIntervalSince1970 * 1_000_000_000).rounded())
        var payload = "trae-cli|\(nanos)|\(model)|\(input)|\(output)|\(cached)|\(reasoning)"
        for x in [traceID, spanID, String(totalTokens)] {
            payload += "|" + x
        }
        let digest = sha256Hex16(payload)
        return digest
    }

    /// sha256 of `s`, first 16 bytes hex-encoded (matches contentDedupKey suffix).
    private static func sha256Hex16(_ s: String) -> String {
        let data = Data(s.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Small helpers

    private static func stringValue(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        for v in values {
            let s = v.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return s }
        }
        return ""
    }

    /// Resolve a possibly-relative symlink target against the link's directory.
    private static func resolveRelative(_ target: String, relativeTo link: URL) -> String {
        if target.hasPrefix("/") { return URL(fileURLWithPath: target).standardizedFileURL.path }
        return link.deletingLastPathComponent()
            .appendingPathComponent(target)
            .standardizedFileURL.path
    }
}
