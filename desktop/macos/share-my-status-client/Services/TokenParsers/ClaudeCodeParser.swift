//
//  ClaudeCodeParser.swift
//  share-my-status-client
//
//  Primary, robust parser for Claude Code transcript logs.
//  Mirrors kaboo's parseClaudeTranscriptFile (cli/parsers.go ~line 840):
//    - scans ~/.claude/projects/**/*.jsonl (honors CLAUDE_CONFIG_DIR)
//    - usage at message.usage: input_tokens, output_tokens,
//      cache_read_input_tokens (-> cachedInputTokens), reasoning_output_tokens
//    - model = message.model; timestamp = line.timestamp (ISO8601)
//    - messageId = message.id or top-level uuid; sessionId = jsonl file stem
//    - project = derived from the encoded project dir name in the path
//    - Anthropic reasoning carve-out: when reasoning is absent, estimate the
//      thinking share from the turn's thinking-vs-other char ratio and move it
//      OUT of output (replicates kaboo's splitOutputTokens).
//

import Foundation

nonisolated struct ClaudeCodeParser: TokenLogParser {
    let source = "claude-code"

    /// Override config dirs (tests inject a temp dir). When empty, resolves from
    /// CLAUDE_CONFIG_DIR then ~/.claude.
    let configDirs: [URL]

    init(configDirs: [URL] = []) {
        self.configDirs = configDirs
    }

    private func resolvedConfigDirs() -> [URL] {
        if !configDirs.isEmpty { return configDirs }
        let env = ProcessInfo.processInfo.environment
        if let v = env["CLAUDE_CONFIG_DIR"], !v.isEmpty {
            return v.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        return [TokenParseHelpers.homeDirectory.appendingPathComponent(".claude", isDirectory: true)]
    }

    func parse(since: Date, cache: inout TokenScanCache) -> [TokenEntry] {
        var out: [TokenEntry] = []
        let fm = FileManager.default

        for dir in resolvedConfigDirs() {
            let projectsDir = dir.appendingPathComponent("projects", isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectsDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let jsonlFiles = TokenParseHelpers.findFiles(under: projectsDir) {
                $0.hasSuffix(".jsonl")
            }

            for file in jsonlFiles {
                // Skip Task sub-agent transcripts (…/subagents/agent-*.jsonl), as
                // kaboo does — their tokens must not be double-counted.
                if file.path.contains("/subagents/") { continue }

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

                let project = Self.extractProject(file: file, projectsDir: projectsDir)
                let sessionId = file.deletingPathExtension().lastPathComponent
                let entries = Self.parseFile(file, project: project, sessionId: sessionId)
                cache.store(entries, for: file, key: key)
                out.append(contentsOf: entries)
            }
        }
        return out
    }

    // MARK: - File parsing

    /// Per-turn character footprint used to split reasoning out of output.
    private final class TurnSplit {
        var thinkingChars = 0
        var otherChars = 0
        var seen = Set<String>()
        func mark(_ tag: String, _ s: String) -> Bool {
            // de-dup identical blocks repeated across same-msg.id lines
            let key = tag + "\u{0}" + s
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    /// A usage record collected during the single file pass, before the
    /// reasoning carve-out (which needs the turn's COMPLETED char counts —
    /// a turn's content may span multiple lines).
    private struct PendingUsage {
        let ts: Date
        let model: String
        let stableID: String
        let input: Int64
        let output: Int64
        let cached: Int64
        let cacheCreation: Int64
        let reasoning: Int64
    }

    static func parseFile(_ url: URL, project: String, sessionId: String) -> [TokenEntry] {
        // Single pass: for each assistant line simultaneously (a) aggregate the
        // turn's thinking-vs-other char footprint keyed by its stable id, and
        // (b) when the line carries usage, collect a lightweight pending record.
        var turns: [String: TurnSplit] = [:]
        var pending: [PendingUsage] = []
        TokenParseHelpers.forEachJSONLLine(at: url) { obj in
            guard (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any] else { return }

            let localUUID = obj["uuid"] as? String ?? ""
            let apiMsgID = msg["id"] as? String ?? ""
            let stableID = apiMsgID.isEmpty ? localUUID : apiMsgID

            // (a) char footprint for the reasoning carve-out.
            if !stableID.isEmpty, let content = msg["content"] as? [[String: Any]] {
                let acc = turns[stableID] ?? TurnSplit()
                turns[stableID] = acc
                for part in content {
                    switch part["type"] as? String {
                    case "thinking":
                        let s = part["thinking"] as? String ?? ""
                        if !s.isEmpty, acc.mark("t", s) { acc.thinkingChars += s.count }
                    case "text":
                        let s = part["text"] as? String ?? ""
                        if !s.isEmpty, acc.mark("x", s) { acc.otherChars += s.count }
                    case "tool_use":
                        let name = part["name"] as? String ?? ""
                        var inputJSON = ""
                        if let input = part["input"],
                           let d = try? JSONSerialization.data(withJSONObject: input),
                           let s = String(data: d, encoding: .utf8) {
                            inputJSON = s
                        }
                        let n = name.count + inputJSON.count
                        if n > 0, acc.mark("u", name + "\u{0}" + inputJSON) { acc.otherChars += n }
                    default:
                        break
                    }
                }
            }

            // (b) pending usage record (carve applied after the pass completes).
            guard let tsStr = obj["timestamp"] as? String,
                  let ts = TokenParseHelpers.parseTimestamp(tsStr),
                  let usage = msg["usage"] as? [String: Any] else { return }

            var model = msg["model"] as? String ?? ""
            if model.isEmpty { model = "unknown" }

            pending.append(PendingUsage(
                ts: ts,
                model: model,
                stableID: stableID,
                input: TokenParseHelpers.int64(usage, "input_tokens"),
                output: TokenParseHelpers.int64(usage, "output_tokens"),
                cached: TokenParseHelpers.int64(usage, "cache_read_input_tokens"),
                cacheCreation: TokenParseHelpers.int64(usage, "cache_creation_input_tokens"),
                reasoning: TokenParseHelpers.int64(usage, "reasoning_output_tokens")
            ))
        }

        // Emit: apply the Anthropic reasoning carve-out now that every turn's
        // char counts are complete.
        var entries: [TokenEntry] = []
        entries.reserveCapacity(pending.count)
        for p in pending {
            var output = p.output
            var reasoning = p.reasoning

            // Anthropic folds extended-thinking into output_tokens and reports no
            // separate reasoning count. When the native field is absent, carve the
            // estimated thinking share OUT of output (turn total unchanged).
            if reasoning == 0, output > 0, TokenParseHelpers.isAnthropicModel(p.model),
               let tc = turns[p.stableID] {
                let est = splitOutputTokens(thinkingChars: tc.thinkingChars,
                                            otherChars: tc.otherChars,
                                            outputTokens: output)
                if est > 0 {
                    reasoning = est
                    output -= est
                }
            }

            entries.append(TokenEntry(
                source: "claude-code",
                model: p.model,
                project: project,
                timestamp: p.ts,
                inputTokens: p.input,
                outputTokens: output,
                cachedInputTokens: p.cached,
                cacheCreationInputTokens: p.cacheCreation,
                reasoningOutputTokens: reasoning,
                sessionId: sessionId,
                messageId: p.stableID
            ))
        }
        return entries
    }

    /// Apportion known output_tokens to thinking by the thinking/other char ratio.
    /// Integer round-half-up; returns 0 when nothing to split. Mirrors kaboo.
    static func splitOutputTokens(thinkingChars: Int, otherChars: Int, outputTokens: Int64) -> Int64 {
        if outputTokens <= 0 || thinkingChars <= 0 { return 0 }
        let denom = Int64(thinkingChars + otherChars)
        if denom <= 0 { return 0 }
        var est = (outputTokens * Int64(thinkingChars) + denom / 2) / denom
        if est > outputTokens { est = outputTokens }
        return est
    }

    /// Derive the project name from the encoded project dir, mirroring kaboo's
    /// extractClaudeProject: take the first path segment under projectsDir, split
    /// on "-", and use the last non-empty segment.
    static func extractProject(file: URL, projectsDir: URL) -> String {
        let relComponents = file.path
            .replacingOccurrences(of: projectsDir.path + "/", with: "")
            .split(separator: "/")
            .map(String.init)
        guard relComponents.count >= 2 else { return "unknown" }
        let encoded = relComponents[0]
        let segments = encoded.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        return segments.last ?? "unknown"
    }
}
