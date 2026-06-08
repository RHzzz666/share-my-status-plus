//
//  ClaudeAppParser.swift
//  share-my-status-client
//
//  Parser for the Claude desktop app's local IndexedDB token-usage caches.
//  Mirrors kaboo's ParseClaudeApp (cli/parser_claude_app.go):
//    - scans ~/Library/Application Support/Claude/IndexedDB/
//      https_claude.ai_0.indexeddb.blob/** (the snappy-compressed, V8-serialised
//      message-level usage blobs). Honors no env override (kaboo uses none for
//      this tool; the platform-default Claude data dir is fixed per-OS).
//    - each blob is a Chromium IDB envelope: 1 byte format-tag, 1 byte version,
//      1 byte compression-type, then a snappy stream wrapping a V8 ValueSerializer
//      blob. We snappy-decode raw[3:] then byte-scan for "usage" objects plus the
//      surrounding requestId / sessionId / cwd / model / type / timestamp.
//    - field mapping (matches kaboo exactly):
//        input_tokens + cache_creation_input_tokens -> inputTokens
//        output_tokens                              -> outputTokens
//        cache_read_input_tokens                    -> cachedInputTokens
//        (no reasoning carve-out for claude_app)    -> reasoningOutputTokens = 0
//    - cache_creation_input_tokens IS read and folded into inputTokens (kaboo
//      has no separate field for it; folding into input is closer than dropping).
//    - dedup: kaboo keys by DedupKey "claude-app:req:<requestId>". We set
//      messageId = "req:<requestId>" so the aggregator's "source:messageId"
//      dedup reproduces "claude-app:req:<requestId>" identically.
//    - to avoid double-counting against the Claude Code CLI parser, IDB usage
//      rows whose sessionId already has a JSONL file under ~/.claude/projects/
//      are dropped (replicates kaboo's claudeCodeKnownSessions filter).
//
//  Foundation-only: includes a minimal pure-Swift snappy decompressor and a
//  tolerant V8 ValueSerializer byte reader (no external deps). When the blob
//  directory is missing/locked, returns [] cleanly.
//

import Foundation

nonisolated struct ClaudeAppParser: TokenLogParser {
    let source = "claude-app"

    /// Override scan roots (tests inject a temp dir). When empty, resolves to the
    /// platform-default Claude desktop data dir. kaboo honors no env override for
    /// this tool, so neither do we.
    let dataDirs: [URL]

    init(dataDirs: [URL] = []) {
        self.dataDirs = dataDirs
    }

    /// Platform-default Claude desktop data dir candidates, mirroring kaboo's
    /// claudeAppDataDirCandidates. On macOS: ~/Library/Application Support/Claude.
    private func resolvedDataDirs() -> [URL] {
        if !dataDirs.isEmpty { return dataDirs }
        let home = TokenParseHelpers.homeDirectory
        #if os(macOS)
        return [home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)]
        #else
        // Match kaboo's linux candidate; other platforms are unused by this client.
        return [home.appendingPathComponent(".config/Claude", isDirectory: true)]
        #endif
    }

    func parse(since: Date, cache: inout TokenScanCache) -> [TokenEntry] {
        let fm = FileManager.default
        var out: [TokenEntry] = []

        // Sessions already covered by the Claude Code parser; their IDB rows are
        // dropped to avoid double-counting (mirrors claudeCodeKnownSessions()).
        let covered = Self.claudeCodeKnownSessions()

        // Cross-file requestId dedup within a single scan (Chromium snapshot
        // rotation can repeat the same requestId across blob shards). The
        // aggregator dedups across scans by messageId; this guards a single scan.
        var seenReq = Set<String>()

        for root in resolvedDataDirs() {
            let blobRoot = root.appendingPathComponent(
                "IndexedDB/https_claude.ai_0.indexeddb.blob", isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: blobRoot.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let blobFiles = TokenParseHelpers.findFiles(under: blobRoot) { _ in true }
            for file in blobFiles {
                // Bound work by mtime like ClaudeCodeParser: a blob last modified
                // well before `since` cannot hold an in-window record (1-day slack
                // since one shard may hold many records).
                if let key = TokenScanCache.fileKey(for: file),
                   Double(key.mtimeMs) / 1000 < since.timeIntervalSince1970 - 86_400 {
                    continue
                }

                let entries: [TokenEntry]
                if let cached = cache.cachedEntries(for: file) {
                    entries = cached
                } else {
                    let parsed = Self.parseBlobFile(file, covered: covered)
                    cache.store(parsed, for: file)
                    entries = parsed
                }

                // Apply requestId dedup at the scan level (the cache stores the
                // raw per-file rows; cross-shard dedup is applied here).
                for e in entries {
                    let req = e.messageId
                    if !req.isEmpty {
                        if seenReq.contains(req) { continue }
                        seenReq.insert(req)
                    }
                    out.append(e)
                }
            }
        }
        return out
    }

    // MARK: - claude-code session coverage

    /// Set of session UUIDs already captured by the Claude Code parser
    /// (~/.claude/projects/*.jsonl). Mirrors kaboo's claudeCodeKnownSessions.
    static func claudeCodeKnownSessions() -> Set<String> {
        var out = Set<String>()
        let root = TokenParseHelpers.homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else {
            return out
        }
        for file in TokenParseHelpers.findFiles(under: root, matching: { $0.hasSuffix(".jsonl") }) {
            out.insert(file.deletingPathExtension().lastPathComponent)
        }
        return out
    }

    // MARK: - Blob file parsing

    static func parseBlobFile(_ url: URL, covered: Set<String>) -> [TokenEntry] {
        guard let raw = try? Data(contentsOf: url), raw.count >= 8 else { return [] }
        // Chromium IDB envelope: format-tag, version, compression-type, then snappy.
        let bytes = [UInt8](raw)
        guard let decoded = Snappy.decode(Array(bytes[3...])) else { return [] }

        var entries: [TokenEntry] = []
        for r in scanClaudeAppUsage(decoded) {
            if r.requestID.isEmpty { continue }
            // Drop sessions already covered by the Claude Code parser.
            if !r.sessionID.isEmpty, covered.contains(r.sessionID) { continue }

            var project = "claude-app"
            if !r.cwd.isEmpty {
                project = (r.cwd as NSString).lastPathComponent
            }
            var model = r.model
            if model.isEmpty { model = "unknown" }

            // cache_creation_input_tokens (cacheWrite) folded into input, matching
            // kaboo. reasoningOutputTokens stays 0 (no carve-out for this tool).
            entries.append(TokenEntry(
                source: "claude-app",
                model: model,
                project: project,
                timestamp: r.timestamp,
                inputTokens: r.input + r.cacheWrite,
                outputTokens: r.output,
                cachedInputTokens: r.cacheRead,
                reasoningOutputTokens: 0,
                sessionId: r.sessionID,
                // Aggregator dedups by "source:messageId" -> "claude-app:req:<id>",
                // identical to kaboo's DedupKey "claude-app:req:" + requestID.
                messageId: "req:" + r.requestID
            ))
        }
        return entries
    }

    // MARK: - Usage record scan over V8 ValueSerializer stream

    struct UsageRecord {
        var requestID = ""
        var sessionID = ""
        var cwd = ""
        var model = ""
        var role = ""
        var timestamp = Date(timeIntervalSince1970: 0)
        var hasTimestamp = false
        var input: Int64 = 0
        var output: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheWrite: Int64 = 0
    }

    /// Tolerant byte-level scan for each "usage" object plus the surrounding
    /// requestId / sessionId / cwd / model / type / timestamp. Mirrors kaboo's
    /// scanClaudeAppUsage — we do not fully deserialize the V8 stream (Chromium
    /// wraps it with version-unstable host-object/blob tags); the byte pattern
    /// "\x22\x05usage\x6f" (OneByteString len-5 "usage" followed by BeginJSObject)
    /// is stable and safe to grep for.
    static func scanClaudeAppUsage(_ buf: [UInt8]) -> [UsageRecord] {
        var out: [UsageRecord] = []
        let needle: [UInt8] = [0x22, 0x05, 0x75, 0x73, 0x61, 0x67, 0x65, 0x6f] // "\x22\x05usage\x6f"
        guard buf.count > needle.count else { return out }

        var i = 0
        while i + needle.count < buf.count {
            let j = V8.indexOf(buf, needle, from: i)
            if j < 0 { break }
            i = j + 1

            guard let obj = V8.parseSimpleObject(buf, j + 7) else { continue }
            let input = obj["input_tokens"].flatMap(V8.asInt64) ?? 0
            let output = obj["output_tokens"].flatMap(V8.asInt64) ?? 0
            let cacheRead = obj["cache_read_input_tokens"].flatMap(V8.asInt64) ?? 0
            let cacheWrite = obj["cache_creation_input_tokens"].flatMap(V8.asInt64) ?? 0
            if input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 { continue }

            var rec = UsageRecord()
            rec.input = input
            rec.output = output
            rec.cacheRead = cacheRead
            rec.cacheWrite = cacheWrite

            // Stable assistant-message envelope keys live within ~3KB of usage.
            let window = 3000
            let lo = max(0, j - window)
            let hi = min(buf.count, j + window)
            let base = lo

            rec.requestID = nearbyString(buf, lo: lo, hi: hi, base: base, center: j, name: "requestId")
            rec.sessionID = nearbyString(buf, lo: lo, hi: hi, base: base, center: j, name: "sessionId")
            rec.cwd = nearbyString(buf, lo: lo, hi: hi, base: base, center: j, name: "cwd")
            rec.model = nearbyString(buf, lo: lo, hi: hi, base: base, center: j, name: "model")
            rec.role = nearbyString(buf, lo: lo, hi: hi, base: base, center: j, name: "type")
            let tsStr = nearbyString(buf, lo: lo, hi: hi, base: base, center: j, name: "timestamp")
            if !tsStr.isEmpty, let t = TokenParseHelpers.parseTimestamp(tsStr) {
                rec.timestamp = t
                rec.hasTimestamp = true
            }

            if !rec.hasTimestamp { continue }
            out.append(rec)
        }
        return out
    }

    /// Find a OneByteString key `name` inside [lo,hi) preferring the closest match
    /// before `center`, then read the immediately following string value. Mirrors
    /// kaboo's nearbyString. `buf` is the full backing array; lo/hi/base/center are
    /// absolute indices.
    static func nearbyString(_ buf: [UInt8], lo: Int, hi: Int, base: Int, center: Int, name: String) -> String {
        var pat: [UInt8] = [0x22, UInt8(name.utf8.count)]
        pat.append(contentsOf: Array(name.utf8))
        let regionLen = hi - lo
        let centerRel = center - base
        var idx = V8.lastIndexBefore(buf, regionStart: lo, regionLen: regionLen, needle: pat, before: centerRel)
        if idx < 0 {
            idx = V8.indexOfInRegion(buf, regionStart: lo, regionLen: regionLen, needle: pat, from: centerRel)
            if idx < 0 { return "" }
        }
        let pos = base + idx + pat.count
        if pos >= buf.count { return "" }
        return V8.readString(buf, pos).0
    }
}

// MARK: - Minimal V8 ValueSerializer reader (Foundation-only)

private enum V8 {
    // Coerce a parsed object value to Int64 (kaboo only stores Int64/Double here).
    static func asInt64(_ v: Any) -> Int64? {
        if let n = v as? Int64 { return n }
        if let d = v as? Double { return Int64(d) }
        return nil
    }

    // --- byte search helpers ---

    static func indexOf(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int {
        if needle.isEmpty { return from }
        var i = max(0, from)
        let last = haystack.count - needle.count
        while i <= last {
            if equalAt(haystack, needle, at: i) { return i }
            i += 1
        }
        return -1
    }

    static func indexOfInRegion(_ buf: [UInt8], regionStart: Int, regionLen: Int, needle: [UInt8], from: Int) -> Int {
        // Returns index relative to regionStart, or -1. `from` is region-relative.
        if needle.isEmpty { return max(0, from) }
        var i = max(0, from)
        let end = min(buf.count, regionStart + regionLen)
        let last = end - needle.count
        while regionStart + i <= last {
            if equalAt(buf, needle, at: regionStart + i) { return i }
            i += 1
        }
        return -1
    }

    static func lastIndexBefore(_ buf: [UInt8], regionStart: Int, regionLen: Int, needle: [UInt8], before: Int) -> Int {
        // Returns region-relative index of the last match wholly before `before`
        // (region-relative), or -1.
        var beforeClamped = before
        if beforeClamped > regionLen { beforeClamped = regionLen }
        if needle.isEmpty || beforeClamped < needle.count { return -1 }
        var last = -1
        var i = 0
        while i + needle.count <= beforeClamped {
            if equalAt(buf, needle, at: regionStart + i) { last = i }
            i += 1
        }
        return last
    }

    static func equalAt(_ haystack: [UInt8], _ needle: [UInt8], at: Int) -> Bool {
        if at < 0 || at + needle.count > haystack.count { return false }
        for k in 0..<needle.count where haystack[at + k] != needle[k] { return false }
        return true
    }

    // --- varint / string readers ---

    static func varint(_ buf: [UInt8], _ i: Int) -> (value: UInt64, next: Int, ok: Bool) {
        var res: UInt64 = 0
        var shift: UInt64 = 0
        var idx = i
        while true {
            if idx >= buf.count { return (0, idx, false) }
            let b = buf[idx]
            idx += 1
            res |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return (res, idx, true) }
            shift += 7
            if shift > 63 { return (0, idx, false) }
        }
    }

    static func zigzag(_ v: UInt64) -> Int64 {
        Int64(bitPattern: v >> 1) ^ -Int64(bitPattern: v & 1)
    }

    /// Read a V8 string at i. Returns (decoded, next). next == i means failure.
    static func readString(_ buf: [UInt8], _ i: Int) -> (String, Int) {
        if i >= buf.count { return ("", i) }
        let tag = buf[i]
        switch tag {
        case 0x22, 0x53: // OneByteString (Latin-1) / Utf8String
            let (n, j, ok) = varint(buf, i + 1)
            let len = Int(n)
            if !ok || j + len > buf.count { return ("", i) }
            let slice = Array(buf[j..<(j + len)])
            let s: String
            if tag == 0x53 {
                s = String(decoding: slice, as: UTF8.self)
            } else {
                // Latin-1: each byte is a code point.
                s = String(slice.map { Character(UnicodeScalar($0)) })
            }
            return (s, j + len)
        case 0x63: // TwoByteString (UTF-16-LE, length in bytes)
            let (n, j, ok) = varint(buf, i + 1)
            let len = Int(n)
            if !ok || j + len > buf.count || len % 2 != 0 { return ("", i) }
            var u = [UInt16](repeating: 0, count: len / 2)
            for k in 0..<u.count {
                u[k] = UInt16(buf[j + k * 2]) | (UInt16(buf[j + k * 2 + 1]) << 8)
            }
            return (String(decoding: u, as: UTF16.self), j + len)
        default:
            return ("", i)
        }
    }

    /// Skip a single V8 value starting at i. Returns (next, ok).
    static func skipValue(_ buf: [UInt8], _ i: Int) -> (Int, Bool) {
        if i >= buf.count { return (i, false) }
        let t = buf[i]
        switch t {
        case 0x30, 0x5F, 0x54, 0x46: // null, undefined, true, false
            return (i + 1, true)
        case 0x49: // Int32 zigzag
            let (_, j, ok) = varint(buf, i + 1)
            return (j, ok)
        case 0x55: // Uint32
            let (_, j, ok) = varint(buf, i + 1)
            return (j, ok)
        case 0x4E: // Double
            if i + 9 > buf.count { return (i, false) }
            return (i + 9, true)
        case 0x22, 0x53, 0x63: // strings
            let (_, j) = readString(buf, i)
            if j == i { return (i, false) }
            return (j, true)
        case 0x6F: // BeginJSObject
            var j = i + 1
            while j < buf.count {
                if buf[j] == 0x7B { // EndJSObject
                    j += 1
                    let (_, j2, ok) = varint(buf, j)
                    if !ok { return (j2, false) }
                    return (j2, true)
                }
                var ok: Bool
                (j, ok) = skipValue(buf, j) // key
                if !ok { return (j, false) }
                (j, ok) = skipValue(buf, j) // value
                if !ok { return (j, false) }
            }
            return (j, false)
        case 0x61: // BeginSparseJSArray
            let (_, j0, ok0) = varint(buf, i + 1)
            if !ok0 { return (j0, false) }
            var j = j0
            while j < buf.count {
                if buf[j] == 0x40 { // EndSparseJSArray
                    j += 1
                    var ok: Bool
                    (_, j, ok) = varint(buf, j)
                    if !ok { return (j, false) }
                    (_, j, ok) = varint(buf, j)
                    return (j, ok)
                }
                var ok: Bool
                (j, ok) = skipValue(buf, j)
                if !ok { return (j, false) }
                (j, ok) = skipValue(buf, j)
                if !ok { return (j, false) }
            }
            return (j, false)
        case 0x41: // BeginDenseJSArray
            let (_, j0, ok0) = varint(buf, i + 1)
            if !ok0 { return (j0, false) }
            var j = j0
            while j < buf.count {
                if buf[j] == 0x24 { // EndDenseJSArray
                    j += 1
                    var ok: Bool
                    (_, j, ok) = varint(buf, j)
                    if !ok { return (j, false) }
                    (_, j, ok) = varint(buf, j)
                    return (j, ok)
                }
                var ok: Bool
                (j, ok) = skipValue(buf, j)
                if !ok { return (j, false) }
            }
            return (j, false)
        default:
            return (i, false)
        }
    }

    /// Parse a JS object whose values are scalars, nested objects, or arrays.
    /// Arrays / unsupported nested values are skipped while keeping in sync.
    /// Returns nil on malformed input. Mirrors kaboo's v8ParseSimpleObject.
    static func parseSimpleObject(_ buf: [UInt8], _ start: Int) -> [String: Any]? {
        if start >= buf.count || buf[start] != 0x6F { return nil }
        var i = start + 1
        var obj: [String: Any] = [:]
        while true {
            if i >= buf.count { return nil }
            if buf[i] == 0x7B { // EndJSObject
                i += 1
                let (_, _, ok) = varint(buf, i)
                if !ok { return nil }
                return obj
            }
            let (key, j) = readString(buf, i)
            if j == i { return nil }
            i = j
            if i >= buf.count { return nil }
            let t = buf[i]
            switch t {
            case 0x49: // Int32 zigzag
                let (n, j2, ok) = varint(buf, i + 1)
                if !ok { return nil }
                obj[key] = zigzag(n)
                i = j2
            case 0x55: // Uint32
                let (n, j2, ok) = varint(buf, i + 1)
                if !ok { return nil }
                obj[key] = Int64(bitPattern: n)
                i = j2
            case 0x4E: // Double
                if i + 9 > buf.count { return nil }
                var bits: UInt64 = 0
                for k in 0..<8 { bits |= UInt64(buf[i + 1 + k]) << (8 * UInt64(k)) }
                obj[key] = Double(bitPattern: bits)
                i += 9
            case 0x22, 0x53, 0x63: // strings
                let (s, j2) = readString(buf, i)
                obj[key] = s
                i = j2
            case 0x30, 0x5F: // null, undefined
                obj[key] = NSNull()
                i += 1
            case 0x54: // true
                obj[key] = true
                i += 1
            case 0x46: // false
                obj[key] = false
                i += 1
            case 0x6F: // nested object
                if let nested = parseSimpleObject(buf, i) {
                    obj[key] = nested
                    // advance past nested object
                    let (j2, ok) = skipValue(buf, i)
                    if !ok { return nil }
                    i = j2
                } else {
                    let (j2, ok) = skipValue(buf, i)
                    if !ok { return nil }
                    i = j2
                }
            case 0x61, 0x41: // arrays
                let (j2, ok) = skipValue(buf, i)
                if !ok { return nil }
                i = j2
            default:
                return nil
            }
        }
    }
}

// MARK: - Minimal pure-Swift Snappy decompressor (Foundation-only)

/// Decompresses a raw Snappy stream (the format used by Chromium IDB blobs and
/// the Go `github.com/golang/snappy` Decode). Returns nil on malformed input.
private enum Snappy {
    static func decode(_ src: [UInt8]) -> [UInt8]? {
        var srcIdx = 0
        // Preamble: uncompressed length as a varint.
        var dLen: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            if srcIdx >= src.count { return nil }
            let b = src[srcIdx]
            srcIdx += 1
            dLen |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            if shift > 63 { return nil }
        }
        let outLen = Int(dLen)
        // Guard against absurd lengths (corrupt envelope).
        if outLen < 0 || outLen > 1 << 30 { return nil }

        var dst = [UInt8]()
        dst.reserveCapacity(outLen)

        while srcIdx < src.count {
            let tag = src[srcIdx]
            switch tag & 0x03 {
            case 0x00: // Literal
                var length = Int(tag >> 2)
                srcIdx += 1
                if length >= 60 {
                    let bytesToRead = length - 59
                    if srcIdx + bytesToRead > src.count { return nil }
                    var lit = 0
                    for k in 0..<bytesToRead { lit |= Int(src[srcIdx + k]) << (8 * k) }
                    srcIdx += bytesToRead
                    length = lit
                }
                length += 1
                if srcIdx + length > src.count { return nil }
                dst.append(contentsOf: src[srcIdx..<(srcIdx + length)])
                srcIdx += length
            case 0x01: // Copy with 1-byte offset
                if srcIdx + 1 >= src.count { return nil }
                let length = Int((tag >> 2) & 0x07) + 4
                let offset = (Int(tag & 0xE0) << 3) | Int(src[srcIdx + 1])
                srcIdx += 2
                if !copyMatch(&dst, offset: offset, length: length) { return nil }
            case 0x02: // Copy with 2-byte offset
                if srcIdx + 2 >= src.count { return nil }
                let length = Int(tag >> 2) + 1
                let offset = Int(src[srcIdx + 1]) | (Int(src[srcIdx + 2]) << 8)
                srcIdx += 3
                if !copyMatch(&dst, offset: offset, length: length) { return nil }
            default: // 0x03: Copy with 4-byte offset
                if srcIdx + 4 >= src.count { return nil }
                let length = Int(tag >> 2) + 1
                let offset = Int(src[srcIdx + 1]) | (Int(src[srcIdx + 2]) << 8)
                    | (Int(src[srcIdx + 3]) << 16) | (Int(src[srcIdx + 4]) << 24)
                srcIdx += 5
                if !copyMatch(&dst, offset: offset, length: length) { return nil }
            }
        }
        if dst.count != outLen { return nil }
        return dst
    }

    /// Append `length` bytes copied from `offset` bytes back in `dst` (overlapping
    /// copies are allowed and must be byte-by-byte, per Snappy semantics).
    private static func copyMatch(_ dst: inout [UInt8], offset: Int, length: Int) -> Bool {
        if offset <= 0 || offset > dst.count || length <= 0 { return false }
        var start = dst.count - offset
        for _ in 0..<length {
            dst.append(dst[start])
            start += 1
        }
        return true
    }
}
