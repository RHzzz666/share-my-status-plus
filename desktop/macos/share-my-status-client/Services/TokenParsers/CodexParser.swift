//
//  CodexParser.swift
//  share-my-status-client
//
//  Parser for OpenAI Codex CLI session logs.
//  Mirrors kaboo's parseCodexFile (cli/parsers.go ~line 1391):
//    - scans ~/.codex/sessions/**/*.jsonl (honors CODEX_HOME)
//    - per-turn model from "turn_context" payload.model; project from
//      session_meta payload.cwd
//    - token usage from event_msg payload (type == "token_count") info:
//      reads last_token_usage, falling back to total_token_usage
//    - cachedInput = cached_input_tokens + cache_read_input_tokens
//      reasoning   = reasoning_output_tokens
//      input       = max(0, input_tokens - cachedInput)   (reasoning-free)
//      output      = max(0, output_tokens - reasoning)
//

import Foundation

nonisolated struct CodexParser: TokenLogParser {
    let source = "codex"

    /// Override config dirs (tests inject a temp dir). When empty, resolves from
    /// CODEX_HOME then ~/.codex.
    let configDirs: [URL]

    init(configDirs: [URL] = []) {
        self.configDirs = configDirs
    }

    private func resolvedConfigDirs() -> [URL] {
        if !configDirs.isEmpty { return configDirs }
        let env = ProcessInfo.processInfo.environment
        if let v = env["CODEX_HOME"], !v.isEmpty {
            return v.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        return [TokenParseHelpers.homeDirectory.appendingPathComponent(".codex", isDirectory: true)]
    }

    func parse(since: Date, cache: inout TokenScanCache) -> [TokenEntry] {
        var out: [TokenEntry] = []
        let fm = FileManager.default

        for dir in resolvedConfigDirs() {
            let sessionsDir = dir.appendingPathComponent("sessions", isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sessionsDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let files = TokenParseHelpers.findFiles(under: sessionsDir) {
                $0.hasSuffix(".jsonl")
            }

            for file in files {
                // Stat the file ONCE; the same key feeds the mtime pre-filter,
                // the cache lookup, and the store below.
                guard let key = TokenScanCache.fileKey(for: file) else { continue }
                if Double(key.mtimeMs) / 1000 < since.timeIntervalSince1970 - 86_400 {
                    continue
                }
                if let cached = cache.cachedEntries(for: file, key: key) {
                    out.append(contentsOf: cached)
                    continue
                }
                let entries = Self.parseFile(file)
                cache.store(entries, for: file, key: key)
                out.append(contentsOf: entries)
            }
        }
        return out
    }

    static func parseFile(_ url: URL) -> [TokenEntry] {
        var entries: [TokenEntry] = []
        let sessionId = url.deletingPathExtension().lastPathComponent
        var sessionProject = "unknown"
        var turnContextModel = "unknown"

        TokenParseHelpers.forEachJSONLLine(at: url) { obj in
            let msgType = obj["type"] as? String ?? ""

            if msgType == "session_meta" {
                if let payload = obj["payload"] as? [String: Any],
                   let cwd = payload["cwd"] as? String {
                    sessionProject = (cwd as NSString).lastPathComponent
                }
                return
            }

            if msgType == "turn_context" {
                if let payload = obj["payload"] as? [String: Any],
                   let m = payload["model"] as? String {
                    turnContextModel = m
                }
                return
            }

            guard msgType == "event_msg" else { return }
            guard let tsStr = obj["timestamp"] as? String,
                  let ts = TokenParseHelpers.parseTimestamp(tsStr) else { return }
            guard let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any] else { return }

            var usage = info["last_token_usage"] as? [String: Any]
            if usage == nil { usage = info["total_token_usage"] as? [String: Any] }
            guard let usage else { return }

            var model = info["model"] as? String ?? ""
            if model.isEmpty { model = turnContextModel }

            let cachedInput = TokenParseHelpers.int64(usage, "cached_input_tokens")
                + TokenParseHelpers.int64(usage, "cache_read_input_tokens")
            let cacheCreation = TokenParseHelpers.int64(usage, "cache_creation_input_tokens")
            let reasoning = TokenParseHelpers.int64(usage, "reasoning_output_tokens")
            // cache_creation is carved OUT of input (alongside cache_read), so the
            // counters never overlap — mirrors kaboo (commit b6428ff9).
            let input = max(0, TokenParseHelpers.int64(usage, "input_tokens") - cachedInput - cacheCreation)
            let output = max(0, TokenParseHelpers.int64(usage, "output_tokens") - reasoning)

            // Codex rollouts have no stable per-turn message id; fingerprint by
            // the usage tuple + running total so fork/replay collapses (mirrors
            // kaboo's codexTokenDedupKey).
            var totalInput: Int64 = 0
            var totalOutput: Int64 = 0
            if let total = info["total_token_usage"] as? [String: Any] {
                totalInput = TokenParseHelpers.int64(total, "input_tokens")
                totalOutput = TokenParseHelpers.int64(total, "output_tokens")
            }
            let messageId = "tok|\(model)|\(input)|\(output)|\(cachedInput)|\(cacheCreation)|\(reasoning)|\(totalInput)|\(totalOutput)"

            entries.append(TokenEntry(
                source: "codex",
                model: model,
                project: sessionProject,
                timestamp: ts,
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: cachedInput,
                cacheCreationInputTokens: cacheCreation,
                reasoningOutputTokens: reasoning,
                sessionId: sessionId,
                messageId: messageId
            ))
        }
        return entries
    }
}
