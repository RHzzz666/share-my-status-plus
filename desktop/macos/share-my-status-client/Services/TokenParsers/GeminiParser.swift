//
//  GeminiParser.swift
//  share-my-status-client
//
//  Parser for the Gemini CLI tool, mirroring kaboo's ParseGeminiCLI
//  (cli/parsers.go ~line 1583). source == "gemini-cli".
//
//  IMPORTANT — which "Gemini" this is:
//    In kaboo the "Gemini" tool is the Gemini *CLI*, whose token logs live under
//    ~/.gemini/tmp/<project-hash>/chats/session-*.json. The large ~/.gemini/antigravity
//    tree on some machines belongs to a DIFFERENT kaboo source ("antigravity-ide" /
//    "antigravity") that kaboo reads via a running Language Server's Connect-RPC, not
//    by scanning files — it is NOT the Gemini tool. To match kaboo's Gemini accounting
//    we therefore scan ~/.gemini/tmp and ignore the antigravity subtree entirely.
//
//  Field mapping (mirrors kaboo exactly):
//    Per assistant/user message, kaboo reads ONE of two token shapes:
//      msg.tokens        : { input, output, cached, thoughts }
//      msg.usageMetadata : { promptTokenCount, candidatesTokenCount,
//                            cachedContentTokenCount, thoughtsTokenCount }
//    then:
//      cached  -> CachedInputTokens
//      thoughts-> ReasoningOutputTokens
//      input   -> InputTokens   = max(0, rawInput  - cached)
//      output  -> OutputTokens  = max(0, rawOutput - thoughts)
//    model     = msg.model if present else data.model (may be "")
//    timestamp = msg.timestamp || msg.createTime (RFC3339Nano)
//    project   = "unknown" (kaboo hardcodes this for gemini-cli)
//
//  kaboo has NO Anthropic reasoning carve-out here (output is already reasoning-free
//  because thoughts is subtracted), and does NOT read any cache_creation field.
//
//  Dedup: kaboo fingerprints each entry with
//    contentDedupKey("gemini-cli", ts, model, in, out, cached, thoughts, role)
//  i.e. a content hash of (source, ts.UTC nanos, model, in, out, cached, reasoning, role),
//  namespaced by source. We replicate that intent verbatim into `messageId`, which the
//  Swift TokenAggregator dedups on (key = source + ":" + messageId). This collapses
//  fork-copied duplicate turns exactly as kaboo's dedupeTokenEntriesByKey does.
//

import Foundation

nonisolated struct GeminiParser: TokenLogParser {
    let source = "gemini-cli"

    /// Override base dir (tests inject a temp dir). When nil, resolves to ~/.gemini.
    /// kaboo hardcodes ~/.gemini and honors no env override for this tool, so neither do we.
    let baseDir: URL?

    init(baseDir: URL? = nil) {
        self.baseDir = baseDir
    }

    private func resolvedBaseDir() -> URL {
        if let baseDir { return baseDir }
        return TokenParseHelpers.homeDirectory.appendingPathComponent(".gemini", isDirectory: true)
    }

    func parse(since: Date, cache: inout TokenScanCache) -> [TokenEntry] {
        var out: [TokenEntry] = []
        let fm = FileManager.default

        // kaboo: tmpDir := ~/.gemini/tmp ; if !fileExists(tmpDir) -> empty result.
        let tmpDir = resolvedBaseDir().appendingPathComponent("tmp", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: tmpDir.path, isDirectory: &isDir), isDir.boolValue else {
            return out
        }

        // kaboo walks tmp/<dir>/chats/session-*.json. We find every session-*.json
        // and keep only those whose path goes through a /chats/ directory, which is
        // the same set kaboo visits while being robust to nesting.
        let files = TokenParseHelpers.findFiles(under: tmpDir) {
            $0.hasPrefix("session-") && $0.hasSuffix(".json")
        }.filter { $0.path.contains("/chats/") }

        for file in files {
            // Stat the file ONCE; the same key feeds the mtime pre-filter,
            // the cache lookup, and the store below.
            guard let key = TokenScanCache.fileKey(for: file) else { continue }
            // Bound work by mtime: a file untouched before `since` (minus a 1-day
            // slack, since one session file can span a day) can't matter.
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
        return out
    }

    // MARK: - File parsing

    static func parseFile(_ url: URL) -> [TokenEntry] {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Malformed / unreadable -> skip, never crash (kaboo `continue`s).
            return []
        }

        // sessionId: kaboo only puts the file path on SessionEvents, not on TokenEntry
        // (its TokenEntry has no session field). The Swift TokenEntry carries sessionId
        // purely for today's distinct-session count, so we use the file stem here; it
        // does not affect token sums or dedup (dedup is content-fingerprint based).
        let sessionId = url.deletingPathExtension().lastPathComponent

        // kaboo: messages, _ := data["messages"]; if nil, fall back to data["history"].
        var messages = root["messages"] as? [[String: Any]]
        if messages == nil { messages = root["history"] as? [[String: Any]] }
        guard let messages else { return [] }

        // kaboo: model, _ := data["model"].(string)  (may be "")
        let sessionModel = root["model"] as? String ?? ""

        var entries: [TokenEntry] = []

        for msg in messages {
            // Timestamp: kaboo tries msg.timestamp then msg.createTime; skips if neither
            // parses as RFC3339Nano.
            var tsStr = msg["timestamp"] as? String ?? ""
            if tsStr.isEmpty { tsStr = msg["createTime"] as? String ?? "" }
            if tsStr.isEmpty { continue }
            guard let ts = TokenParseHelpers.parseTimestamp(tsStr) else { continue }

            // role: kaboo => "assistant" unless msg.role == "user". Used in the dedup key.
            let role: String = (msg["role"] as? String == "user") ? "user" : "assistant"

            // model: msg.model overrides session model when non-empty.
            var model = sessionModel
            if let m = msg["model"] as? String, !m.isEmpty { model = m }

            // Token mapping: prefer msg.tokens, else msg.usageMetadata. If neither key
            // exists, kaboo emits nothing for this message.
            let input: Int64
            let output: Int64
            let cached: Int64
            let thoughts: Int64

            if let tokens = msg["tokens"] as? [String: Any] {
                cached = TokenParseHelpers.int64(tokens, "cached")
                thoughts = TokenParseHelpers.int64(tokens, "thoughts")
                input = max(0, TokenParseHelpers.int64(tokens, "input") - cached)
                output = max(0, TokenParseHelpers.int64(tokens, "output") - thoughts)
            } else if let usage = msg["usageMetadata"] as? [String: Any] {
                cached = TokenParseHelpers.int64(usage, "cachedContentTokenCount")
                thoughts = TokenParseHelpers.int64(usage, "thoughtsTokenCount")
                input = max(0, TokenParseHelpers.int64(usage, "promptTokenCount") - cached)
                output = max(0, TokenParseHelpers.int64(usage, "candidatesTokenCount") - thoughts)
            } else {
                continue
            }

            // Content-fingerprint dedup, mirroring kaboo's
            // contentDedupKey("gemini-cli", ts, model, in, out, cached, thoughts, role).
            // The Swift aggregator namespaces by source itself, so messageId carries the
            // hashed content tuple. ts is normalized to UTC nanoseconds like kaboo.
            let messageId = Self.contentDedupKey(
                ts: ts, model: model, input: input, output: output,
                cached: cached, reasoning: thoughts, role: role
            )

            // kaboo emits unconditionally once a token shape is present (even all-zero).
            entries.append(TokenEntry(
                source: "gemini-cli",
                model: model,
                project: "unknown",
                timestamp: ts,
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: cached,
                cacheCreationInputTokens: 0,  // gemini-cli has no cache-write concept
                reasoningOutputTokens: thoughts,
                sessionId: sessionId,
                messageId: messageId
            ))
        }
        return entries
    }

    /// Mirror kaboo's contentDedupKey for gemini-cli: SHA-256 over
    /// "<source>|<ts.UTC unixnano>|<model>|<in>|<out>|<cached>|<reasoning>|<role>",
    /// returned as the source-namespaced hex of the first 16 bytes.
    static func contentDedupKey(ts: Date, model: String,
                                input: Int64, output: Int64,
                                cached: Int64, reasoning: Int64,
                                role: String) -> String {
        let nanos = Int64((ts.timeIntervalSince1970 * 1_000_000_000).rounded())
        let payload = "gemini-cli|\(nanos)|\(model)|\(input)|\(output)|\(cached)|\(reasoning)|\(role)"
        let digest = SHA256Lite.hashFirst16Hex(payload)
        return "gemini-cli:" + digest
    }
}

// MARK: - Minimal Foundation-only SHA-256

/// Tiny dependency-free SHA-256 so the dedup fingerprint matches kaboo's
/// content hash byte-for-byte without importing CryptoKit (keeps this file
/// Foundation-only and standalone-compilable for the unit tests).
private enum SHA256Lite {
    /// Hex string of the first 16 bytes of SHA-256(message), matching kaboo's
    /// hex.EncodeToString(sum[:16]).
    static func hashFirst16Hex(_ message: String) -> String {
        let digest = hash(Array(message.utf8))
        let first16 = digest.prefix(16)
        var hex = ""
        hex.reserveCapacity(32)
        for byte in first16 {
            hex.append(hexDigit(byte >> 4))
            hex.append(hexDigit(byte & 0x0f))
        }
        return hex
    }

    private static func hexDigit(_ v: UInt8) -> Character {
        let table: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
        return table[Int(v)]
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    static func hash(_ messageBytes: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19

        var msg = messageBytes
        let bitLen = UInt64(messageBytes.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0x00) }
        for i in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLen >> UInt64(i)) & 0xff))
        }

        var w = [UInt32](repeating: 0, count: 64)
        var chunkStart = 0
        while chunkStart < msg.count {
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16) |
                       (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, hh = h7
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }

            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d
            h4 = h4 &+ e; h5 = h5 &+ f; h6 = h6 &+ g; h7 = h7 &+ hh
            chunkStart += 64
        }

        var out = [UInt8]()
        out.reserveCapacity(32)
        for h in [h0, h1, h2, h3, h4, h5, h6, h7] {
            out.append(UInt8((h >> 24) & 0xff))
            out.append(UInt8((h >> 16) & 0xff))
            out.append(UInt8((h >> 8) & 0xff))
            out.append(UInt8(h & 0xff))
        }
        return out
    }
}
