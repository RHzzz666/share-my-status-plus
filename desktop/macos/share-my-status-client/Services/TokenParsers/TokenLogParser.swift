//
//  TokenLogParser.swift
//  share-my-status-client
//
//  Extensible protocol for per-tool token-usage log parsers.
//  Foundation-only (no AppKit / SwiftUI) so parsers are unit-testable standalone.
//

import Foundation

/// A parser that scans a single AI tool's local logs and returns token entries.
///
/// Implementations MUST be Foundation-only and side-effect free apart from
/// reading the filesystem. They should never throw on malformed input — skip
/// bad records and return whatever was parsed successfully.
nonisolated protocol TokenLogParser {
    /// Stable source label used on every emitted entry (e.g. "claude-code").
    var source: String { get }

    /// Scan logs and return parsed entries. `since` is the earliest timestamp
    /// worth keeping (entries older than this may be skipped to bound work — the
    /// aggregator filters again, so over-returning is harmless).
    ///
    /// `cache` is read-and-write: for each scanned file the parser first checks
    /// `cache.cachedEntries(for:)` (skip re-read when the file's identity is
    /// unchanged) and, after parsing a new/changed file, calls
    /// `cache.store(_:for:)` so the next scan can skip it. Pass a fresh empty
    /// cache to force a full scan.
    func parse(since: Date, cache: inout TokenScanCache) -> [TokenEntry]
}

// MARK: - Shared parsing helpers (Foundation-only)

nonisolated enum TokenParseHelpers {
    /// Resolve the user's home directory, honoring a possible sandbox.
    static var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Parse an ISO8601 timestamp string. Tries fractional seconds first, then
    /// plain seconds, then a couple of common explicit formats. Returns nil on
    /// failure (caller should skip the record).
    static func parseTimestamp(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoPlain.date(from: s) { return d }
        for fmt in fallbackFormatters {
            if let d = fmt.date(from: s) { return d }
        }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fallbackFormatters: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]
        return patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = pattern
            return f
        }
    }()

    /// Read an Int64 from a JSON object value, tolerating Int / Double / String.
    static func int64(_ dict: [String: Any], _ key: String) -> Int64 {
        guard let v = dict[key] else { return 0 }
        if let n = v as? Int64 { return n }
        if let n = v as? Int { return Int64(n) }
        if let n = v as? Double { return Int64(n) }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let n = Int64(s) { return n }
        return 0
    }

    /// True when a model name looks Anthropic/Claude-family (gates the reasoning
    /// carve-out, mirroring kaboo's isAnthropicModel).
    static func isAnthropicModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("claude") || m.contains("sonnet") ||
               m.contains("haiku") || m.contains("opus")
    }

    /// Iterate over non-empty lines of a JSONL file, decoding each as a JSON
    /// object. Returns false if the file can't be read. Malformed lines are
    /// skipped silently.
    @discardableResult
    static func forEachJSONLLine(at url: URL, _ body: ([String: Any]) -> Void) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            // Drain per line: JSONSerialization returns autoreleased Foundation
            // objects (NSDictionary/NSArray). Without a pool they accumulate for
            // the whole scan — at ~tens of thousands of lines across multi-GB of
            // logs that was a ~2.6 GB cold-scan peak. A per-line pool bounds it to
            // one line's working set regardless of file size. The values `body`
            // keeps (bridged Swift Strings/Int64 in TokenEntry) are retained
            // independently and stay valid after the pool drains.
            autoreleasepool {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return }
                guard let data = trimmed.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return
                }
                body(obj)
            }
        }
        return true
    }

    /// Recursively find files under `dir` matching `predicate(relativeName)`.
    static func findFiles(under dir: URL, matching predicate: (String) -> Bool) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true, predicate(url.lastPathComponent) {
                out.append(url)
            }
        }
        return out
    }
}

// MARK: - Per-file scan cache

/// Identity of a file at scan time: path + size + mtime. If unchanged between
/// scans we reuse the cached parse result instead of re-reading.
nonisolated struct TokenScanFileKey: Codable, Equatable {
    let path: String
    let size: Int64
    let mtimeMs: Int64
}

/// Persisted per-file parse results, keyed by file identity. Foundation-only and
/// Codable so `TokenUsageService` can serialize it to Application Support.
nonisolated struct TokenScanCache: Codable {
    /// One cached file's entries (entries are stored DTO-style for Codable).
    struct CachedEntry: Codable {
        let source: String
        let model: String
        let project: String
        let timestampMs: Int64
        let inputTokens: Int64
        let outputTokens: Int64
        let cachedInputTokens: Int64
        let cacheCreationInputTokens: Int64
        let reasoningOutputTokens: Int64
        let sessionId: String
        let messageId: String

        init(_ e: TokenEntry) {
            self.source = e.source
            self.model = e.model
            self.project = e.project
            self.timestampMs = Int64(e.timestamp.timeIntervalSince1970 * 1000)
            self.inputTokens = e.inputTokens
            self.outputTokens = e.outputTokens
            self.cachedInputTokens = e.cachedInputTokens
            self.cacheCreationInputTokens = e.cacheCreationInputTokens
            self.reasoningOutputTokens = e.reasoningOutputTokens
            self.sessionId = e.sessionId
            self.messageId = e.messageId
        }

        // Custom decode so caches written before cacheCreationInputTokens existed
        // still load (the key is simply absent there → default 0). Everything else
        // matches the synthesized behavior.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(String.self, forKey: .source)
            model = try c.decode(String.self, forKey: .model)
            project = try c.decode(String.self, forKey: .project)
            timestampMs = try c.decode(Int64.self, forKey: .timestampMs)
            inputTokens = try c.decode(Int64.self, forKey: .inputTokens)
            outputTokens = try c.decode(Int64.self, forKey: .outputTokens)
            cachedInputTokens = try c.decode(Int64.self, forKey: .cachedInputTokens)
            cacheCreationInputTokens = try c.decodeIfPresent(Int64.self, forKey: .cacheCreationInputTokens) ?? 0
            reasoningOutputTokens = try c.decode(Int64.self, forKey: .reasoningOutputTokens)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            messageId = try c.decode(String.self, forKey: .messageId)
        }

        var entry: TokenEntry {
            TokenEntry(
                source: source,
                model: model,
                project: project,
                timestamp: Date(timeIntervalSince1970: Double(timestampMs) / 1000),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedInputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens,
                reasoningOutputTokens: reasoningOutputTokens,
                sessionId: sessionId,
                messageId: messageId
            )
        }
    }

    /// path -> (file identity, parsed entries)
    var files: [String: CachedFile] = [:]

    /// True when the cache changed since it was last persisted. Not serialized —
    /// `TokenUsageService` uses it to skip re-encoding/rewriting an unchanged
    /// multi-MB cache file every tick, and resets it after a successful write.
    var dirty: Bool = false

    private enum CodingKeys: String, CodingKey { case files }

    struct CachedFile: Codable {
        let key: TokenScanFileKey
        let entries: [CachedEntry]
    }

    /// Return cached entries for `url` iff its identity matches the cached key.
    func cachedEntries(for url: URL) -> [TokenEntry]? {
        guard let currentKey = TokenScanCache.fileKey(for: url) else { return nil }
        return cachedEntries(for: url, key: currentKey)
    }

    /// Variant taking a precomputed identity, so parsers that already stat'ed the
    /// file (e.g. for a window pre-filter) don't trigger a second syscall.
    func cachedEntries(for url: URL, key currentKey: TokenScanFileKey) -> [TokenEntry]? {
        guard let cf = files[url.path], cf.key == currentKey else { return nil }
        return cf.entries.map { $0.entry }
    }

    mutating func store(_ entries: [TokenEntry], for url: URL) {
        guard let key = TokenScanCache.fileKey(for: url) else { return }
        store(entries, for: url, key: key)
    }

    /// Variant taking a precomputed identity (see `cachedEntries(for:key:)`).
    mutating func store(_ entries: [TokenEntry], for url: URL, key: TokenScanFileKey) {
        files[url.path] = CachedFile(key: key, entries: entries.map { CachedEntry($0) })
        dirty = true
    }

    /// Compute a file's identity (path + size + mtime). nil when the file is gone.
    static func fileKey(for url: URL) -> TokenScanFileKey? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return TokenScanFileKey(path: url.path, size: size, mtimeMs: Int64(mtime * 1000))
    }
}
