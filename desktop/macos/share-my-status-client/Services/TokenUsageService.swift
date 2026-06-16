//
//  TokenUsageService.swift
//  share-my-status-client
//
//  Orchestrates the per-tool token-log parsers on an interval, maintains a
//  per-file scan cache (persisted in Application Support, keyed by path+size+mtime
//  so unchanged files are not re-parsed), produces the aggregated TokenUsage
//  payload, exposes it for display, and notifies the reporter on each refresh.
//

import Foundation

/// Which parsers are enabled for a scan.
nonisolated struct TokenParserToggles: Equatable {
    var claudeCode: Bool
    var codex: Bool
    var cursor: Bool
    var gemini: Bool
    var claudeApp: Bool
    var openClaw: Bool
    var trae: Bool
    var traex: Bool
}

/// Actor-based token usage collector. Foundation-only domain logic; the reporter
/// (MainActor) reads `latestAggregate()` and registers a change callback.
actor TokenUsageService {
    private let logger = AppLogger.token

    // Configuration
    private var toggles = TokenParserToggles(claudeCode: true, codex: true, cursor: false, gemini: true,
                                             claudeApp: true, openClaw: true, trae: true, traex: true)
    private var windowDays: Int = 30
    private var intervalSeconds: TimeInterval = 300

    // State
    private var scanTask: Task<Void, Never>?
    private var isRunning = false
    private var latest: TokenUsageAggregate?
    private var cache = TokenScanCache()
    private var changeCallback: ((TokenUsageAggregate) -> Void)?

    // Injectable "now" + parser overrides so this is testable; defaults to live.
    private let nowProvider: () -> Date
    private let parserOverride: [TokenLogParser]?

    init(now: @escaping () -> Date = { Date() },
         parsers: [TokenLogParser]? = nil) {
        self.nowProvider = now
        self.parserOverride = parsers
    }

    // MARK: - Public control

    func updateConfiguration(toggles: TokenParserToggles,
                             windowDays: Int,
                             intervalSeconds: TimeInterval) {
        let intervalChanged = self.intervalSeconds != intervalSeconds
        self.toggles = toggles
        // Floor at 7: the last7d window assumes the total window is >= 7d (the UI
        // fixes it at 30 anyway); this guards old imported configs with e.g. 3.
        self.windowDays = max(7, windowDays)
        self.intervalSeconds = max(30, intervalSeconds)
        if isRunning && intervalChanged {
            // Restart the loop so the new interval takes effect promptly.
            restartLoop()
        }
    }

    func registerCallback(_ cb: @escaping (TokenUsageAggregate) -> Void) {
        self.changeCallback = cb
    }

    func isActive() -> Bool { isRunning }

    /// Start periodic scanning. Loads cache, runs one immediate scan, then loops.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        loadCache()
        logger.info("TokenUsageService starting (windowDays=\(windowDays), interval=\(Int(intervalSeconds))s)")
        restartLoop()
    }

    func stop() {
        logger.info("TokenUsageService stopping")
        isRunning = false
        scanTask?.cancel()
        scanTask = nil
    }

    /// Latest computed aggregate, or nil if never scanned.
    func latestAggregate() -> TokenUsageAggregate? { latest }

    /// Run one scan synchronously (used for immediate report on enable, and tests).
    @discardableResult
    func scanOnce() -> TokenUsageAggregate {
        let now = nowProvider()
        // Earliest timestamp worth keeping = start of the rolling total window.
        // kaboo aligns 7D/30D as rolling N×24h windows (not calendar-aligned), so
        // the scan floor is now − windowDays×24h.
        let cal = Calendar.current
        let since = now.addingTimeInterval(-Double(windowDays) * 86400)

        let parsers = activeParsers()
        var entries: [TokenEntry] = []

        // Parsers read the cache for unchanged files and write fresh results for
        // new/changed ones into the same cache (inout).
        for parser in parsers {
            let parsed = parser.parse(since: since, cache: &cache)
            entries.append(contentsOf: parsed)
        }

        let aggregate = TokenAggregator.aggregate(
            entries: entries,
            windowDays: windowDays,
            now: now,
            calendar: cal
        )
        latest = aggregate
        persistCache()
        logger.info("Token scan complete: today=\(aggregate.today.totalTokens), sessions=\(aggregate.sessionCount), models=\(aggregate.today.byModel.count)")
        return aggregate
    }

    // MARK: - Loop

    private func restartLoop() {
        scanTask?.cancel()
        let interval = intervalSeconds
        scanTask = Task { [weak self] in
            guard let self else { return }
            // Immediate first scan.
            await self.runScanAndNotify()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self.runScanAndNotify()
            }
        }
    }

    private func runScanAndNotify() {
        guard isRunning else { return }
        let aggregate = scanOnce()
        changeCallback?(aggregate)
    }

    // MARK: - Parsers

    private func activeParsers() -> [TokenLogParser] {
        if let parserOverride { return parserOverride }
        var parsers: [TokenLogParser] = []
        if toggles.claudeCode { parsers.append(ClaudeCodeParser()) }
        if toggles.codex { parsers.append(CodexParser()) }
        if toggles.gemini { parsers.append(GeminiParser()) }
        if toggles.cursor { parsers.append(CursorParser()) }
        if toggles.claudeApp { parsers.append(ClaudeAppParser()) }
        if toggles.openClaw { parsers.append(OpenClawParser()) }
        if toggles.trae { parsers.append(TraeParser()) }
        if toggles.traex { parsers.append(TraeXParser()) }
        return parsers
    }

    // MARK: - Cache persistence (Application Support)

    private func cacheFileURL() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("ShareMyStatus", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("token-scan-cache.json")
    }

    private func loadCache() {
        guard let url = cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TokenScanCache.self, from: data) else {
            cache = TokenScanCache()
            return
        }
        cache = decoded
    }

    private func persistCache() {
        // Nothing changed this cycle: skip the filter/encode/rewrite entirely so
        // an unchanged multi-MB cache isn't rewritten on every tick.
        guard cache.dirty else { return }

        // Parsers have already written fresh per-file results into `cache` this
        // cycle. Drop entries whose backing file no longer exists, and entries
        // whose file mtime fell out of the scan window (+1 day slack, mirroring
        // the parsers' window pre-filter so nothing reachable is lost), so the
        // cache doesn't grow unbounded, then persist.
        let fm = FileManager.default
        let nowMs = nowProvider().timeIntervalSince1970 * 1000
        let cutoffMs = Int64(nowMs - Double(windowDays + 1) * 86_400 * 1000)
        cache.files = cache.files.filter {
            $0.value.key.mtimeMs >= cutoffMs && fm.fileExists(atPath: $0.value.key.path)
        }
        guard let url = cacheFileURL(),
              let data = try? JSONEncoder().encode(cache) else { return }
        if (try? data.write(to: url, options: .atomic)) != nil {
            cache.dirty = false
        }
    }
}
