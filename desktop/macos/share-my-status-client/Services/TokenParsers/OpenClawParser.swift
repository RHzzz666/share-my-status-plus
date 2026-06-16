//
//  OpenClawParser.swift
//  share-my-status-client
//
//  Parser for OpenClaw local session JSONL logs.
//  Mirrors kaboo's parseOpenClawFile (cli/parser_openclaw.go):
//    - discovers sessions under ~/.openclaw/agents/<agentID>/sessions/, using
//      each agent dir's sessions.json index when present and falling back to a
//      direct *.jsonl scan (skipping *.trajectory.* / *.checkpoint.* files).
//    - one record per JSONL line; only type=="message" with a message object,
//      role=="assistant", and a usage object that sums to >0 emits an entry.
//    - usage fields: input -> inputTokens, output -> outputTokens,
//      cacheRead + cacheWrite -> cachedInputTokens. OpenClaw has no separate
//      reasoning count, so reasoningOutputTokens stays 0 (no carve-out, unlike
//      claude-code; kaboo does not split output for this tool).
//    - model = message.model (or "unknown"); project = agentID (the dir name);
//      sessionId = the index record's sessionId or the file stem.
//    - messageId = line.id (the upstream provider's globally-unique message id).
//      kaboo's DedupKey for this tool is "openclaw:" + id, which the Swift
//      aggregator reproduces exactly via source(":")messageId dedup — so
//      fork-copied pre-fork rows that reuse the same upstream id collapse
//      across files, matching kaboo's cross-file dedup intent.
//
//  No env override exists for the scan dir: kaboo hardcodes ~/.openclaw.
//  Foundation-only; returns [] cleanly when ~/.openclaw/agents is absent.
//

import Foundation

nonisolated struct OpenClawParser: TokenLogParser {
    let source = "openclaw"

    /// Override config dirs (tests inject a temp dir). When empty, resolves to
    /// ~/.openclaw. kaboo honors no env override for this tool.
    let configDirs: [URL]

    init(configDirs: [URL] = []) {
        self.configDirs = configDirs
    }

    private func resolvedConfigDirs() -> [URL] {
        if !configDirs.isEmpty { return configDirs }
        return [TokenParseHelpers.homeDirectory.appendingPathComponent(".openclaw", isDirectory: true)]
    }

    /// A discovered session file plus the metadata kaboo carries alongside it.
    private struct SessionFile {
        let url: URL
        let sessionId: String
        let agentId: String // -> project
    }

    func parse(since: Date, cache: inout TokenScanCache) -> [TokenEntry] {
        var out: [TokenEntry] = []

        for dir in resolvedConfigDirs() {
            let sessionFiles = Self.discoverSessionFiles(openClawDir: dir)
            if sessionFiles.isEmpty { continue }

            for sf in sessionFiles {
                let file = sf.url

                // Stat the file ONCE; the same key feeds the mtime pre-filter,
                // the cache lookup, and the store below.
                guard let key = TokenScanCache.fileKey(for: file) else { continue }

                // Bound work by mtime: a file last modified before `since` cannot
                // contain entries inside any window we care about. (Cheap pre-filter,
                // with a 1-day slack since one file may hold a whole day's records.)
                if Double(key.mtimeMs) / 1000 < since.timeIntervalSince1970 - 86_400 {
                    continue
                }

                if let cached = cache.cachedEntries(for: file, key: key) {
                    out.append(contentsOf: cached)
                    continue
                }

                let entries = Self.parseFile(file, sessionId: sf.sessionId, project: sf.agentId)
                cache.store(entries, for: file, key: key)
                out.append(contentsOf: entries)
            }
        }
        return out
    }

    // MARK: - Session discovery (mirrors openClawSessionFiles)

    /// Enumerate ~/.openclaw/agents/<agentID>/sessions and collect session files,
    /// deduping by resolved (symlink-followed) path across agents.
    private static func discoverSessionFiles(openClawDir: URL) -> [SessionFile] {
        let fm = FileManager.default
        let agentsDir = openClawDir.appendingPathComponent("agents", isDirectory: true)

        guard let agents = try? fm.contentsOfDirectory(
            at: agentsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var out: [SessionFile] = []
        var seen = Set<String>()

        for agent in agents {
            let isDir = (try? agent.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let agentId = agent.lastPathComponent
            let sessionsDir = agent.appendingPathComponent("sessions", isDirectory: true)

            for sf in indexedSessionFiles(sessionsDir: sessionsDir, agentId: agentId) {
                let key = pathKey(sf.url)
                if seen.contains(key) { continue }
                seen.insert(key)
                out.append(sf)
            }
        }
        return out
    }

    /// One agent's session files: prefer the sessions.json index, then union in
    /// any direct *.jsonl files not already named by the index (matches kaboo).
    private static func indexedSessionFiles(sessionsDir: URL, agentId: String) -> [SessionFile] {
        let indexURL = sessionsDir.appendingPathComponent("sessions.json", isDirectory: false)

        guard let data = try? Data(contentsOf: indexURL),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let index = raw as? [String: Any] else {
            return fallbackSessionFiles(sessionsDir: sessionsDir, agentId: agentId)
        }

        var out: [SessionFile] = []
        let fm = FileManager.default
        for (_, value) in index {
            guard let record = value as? [String: Any] else { continue }
            guard let path = record["sessionFile"] as? String,
                  !path.isEmpty,
                  path.hasSuffix(".jsonl"),
                  fm.fileExists(atPath: path) else {
                continue
            }
            let url = URL(fileURLWithPath: path)
            var sessionId = (record["sessionId"] as? String) ?? ""
            if sessionId.isEmpty {
                sessionId = url.deletingPathExtension().lastPathComponent
            }
            out.append(SessionFile(url: url, sessionId: sessionId, agentId: agentId))
        }

        var seen = Set<String>()
        for sf in out { seen.insert(pathKey(sf.url)) }
        for sf in fallbackSessionFiles(sessionsDir: sessionsDir, agentId: agentId) {
            let key = pathKey(sf.url)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(sf)
        }
        return out
    }

    /// Direct *.jsonl scan, skipping trajectory/checkpoint sidecar files.
    private static func fallbackSessionFiles(sessionsDir: URL, agentId: String) -> [SessionFile] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }
        let files = TokenParseHelpers.findFiles(under: sessionsDir) { $0.hasSuffix(".jsonl") }
        var out: [SessionFile] = []
        for url in files {
            let name = url.lastPathComponent
            if name.contains(".trajectory.") || name.contains(".checkpoint.") { continue }
            let sessionId = url.deletingPathExtension().lastPathComponent
            out.append(SessionFile(url: url, sessionId: sessionId, agentId: agentId))
        }
        return out
    }

    /// Resolve symlinks for cross-agent dedup; fall back to the literal path.
    private static func pathKey(_ url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().path
        return resolved.isEmpty ? url.path : resolved
    }

    // MARK: - File parsing (mirrors parseOpenClawFile)

    static func parseFile(_ url: URL, sessionId: String, project: String) -> [TokenEntry] {
        var entries: [TokenEntry] = []

        TokenParseHelpers.forEachJSONLLine(at: url) { obj in
            guard (obj["type"] as? String) == "message",
                  let msg = obj["message"] as? [String: Any] else { return }

            let ts = parseTimestamp(messageTS: msg["timestamp"], lineTS: obj["timestamp"] as? String)
            guard let ts else { return }

            let role = msg["role"] as? String ?? ""
            guard role == "assistant", let usage = msg["usage"] as? [String: Any] else { return }

            let input = TokenParseHelpers.int64(usage, "input")
            let output = TokenParseHelpers.int64(usage, "output")
            let cacheRead = TokenParseHelpers.int64(usage, "cacheRead")
            let cacheWrite = TokenParseHelpers.int64(usage, "cacheWrite")
            if input + output + cacheRead + cacheWrite == 0 { return }

            var model = msg["model"] as? String ?? ""
            if model.isEmpty { model = "unknown" }

            // line.id is the upstream provider's globally-unique message id;
            // carrying it as messageId reproduces kaboo's "openclaw:"+id dedup key
            // (the Swift aggregator dedups by source+":"+messageId), so fork-copied
            // pre-fork rows collapse with the originals across files.
            let messageId = obj["id"] as? String ?? ""

            entries.append(TokenEntry(
                source: "openclaw",
                model: model,
                project: project,
                timestamp: ts,
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: cacheRead + cacheWrite,
                // openclaw folds cacheWrite into cached (kaboo-aligned); no separate field.
                cacheCreationInputTokens: 0,
                reasoningOutputTokens: 0,
                sessionId: sessionId,
                messageId: messageId
            ))
        }
        return entries
    }

    /// Resolve a record timestamp the way kaboo's parseOpenClawTimestamp does:
    /// prefer the numeric message.timestamp (epoch s or ms, >1e12 => ms), else
    /// fall back to the RFC3339 line.timestamp string. nil => skip the record.
    static func parseTimestamp(messageTS: Any?, lineTS: String?) -> Date? {
        if let n = numeric(messageTS) {
            if n > 1_000_000_000_000 { // 1e12 -> milliseconds
                return Date(timeIntervalSince1970: n / 1000)
            }
            if n > 0 {
                return Date(timeIntervalSince1970: n)
            }
        }
        if let lineTS, !lineTS.isEmpty, let d = TokenParseHelpers.parseTimestamp(lineTS) {
            return d
        }
        return nil
    }

    /// Extract a numeric epoch value from a JSON timestamp. kaboo's switch only
    /// matches float64 / json.Number — a string message.timestamp falls through
    /// to the RFC3339 line.timestamp — so we accept only JSON numbers here
    /// (JSONSerialization returns these as NSNumber/Double/Int, never String).
    private static func numeric(_ v: Any?) -> Double? {
        guard let v else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
