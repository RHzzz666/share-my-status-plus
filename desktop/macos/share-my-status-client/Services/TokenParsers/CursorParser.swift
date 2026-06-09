//
//  CursorParser.swift
//  share-my-status-client
//
//  BEST-EFFORT parser for Cursor usage, reading the local SQLite state DB.
//
//  Context / deviation note vs kaboo:
//  kaboo's ParseCursor (cli/parsers.go ~line 1710) does NOT read token usage out
//  of SQLite. It reads only the *auth token* (key "cursorAuth/accessToken") from
//  state.vscdb, then fetches a usage CSV from Cursor's REMOTE API and parses that
//  (parseCursorCSV — columns "Input (w/ Cache Write)", "Input (w/o Cache Write)",
//  "Cache Read", "Output Tokens", "Model", "Date", "Kind").
//
//  This client is meant to scan LOCAL logs offline; fetching a remote CSV per
//  scan is out of scope and unreliable. So this parser is best-effort: it opens
//  state.vscdb read-only and looks for any LOCALLY-CACHED usage blob — first any
//  Cursor-exported usage CSV cached on disk next to the DB, then JSON usage
//  records stored in the DB's key/value tables — and maps whatever token fields
//  exist using the same field semantics kaboo's CSV parser uses. When no local
//  usage data is present (the common case), it returns nothing rather than making
//  a network call. SQLite access is fully gated so the app still builds and the
//  other parsers work even if the DB is absent/locked.
//

import Foundation
import SQLite3

nonisolated struct CursorParser: TokenLogParser {
    let source = "cursor"

    /// Override DB path (tests inject a temp file). When nil, the default macOS
    /// Cursor state DB location is used.
    let stateDBPath: URL?

    init(stateDBPath: URL? = nil) {
        self.stateDBPath = stateDBPath
    }

    private func resolvedDBPath() -> URL {
        if let stateDBPath { return stateDBPath }
        return TokenParseHelpers.homeDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    func parse(since: Date, cache: inout TokenScanCache) -> [TokenEntry] {
        let dbURL = resolvedDBPath()
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        var entries: [TokenEntry] = []

        // 1) A locally-cached Cursor usage CSV export, if present next to the DB.
        //    Cached under the CSV file's OWN identity, not the DB's.
        let csvURL = sidecarCSVURL(near: dbURL)
        if let csvKey = TokenScanCache.fileKey(for: csvURL) {
            if let cached = cache.cachedEntries(for: csvURL, key: csvKey) {
                entries.append(contentsOf: cached)
            } else if let csv = try? String(contentsOf: csvURL, encoding: .utf8) {
                let parsed = Self.parseCSV(csv)
                cache.store(parsed, for: csvURL, key: csvKey)
                entries.append(contentsOf: parsed)
            }
        }

        // 2) Any JSON usage records stored in the DB's key/value tables.
        //    The live state.vscdb changes size/mtime on virtually every tick, so
        //    its exact identity never repeats and the cache would never hit.
        //    Rate-limit by caching under a SYNTHETIC key: mtime bucketed to 30
        //    minutes and size zeroed, so within a bucket the cache hits and the
        //    multi-GB DB is table-scanned at most twice an hour.
        if let realKey = TokenScanCache.fileKey(for: dbURL) {
            let bucketedKey = TokenScanFileKey(
                path: realKey.path,
                size: 0,
                mtimeMs: (realKey.mtimeMs / 1_800_000) * 1_800_000
            )
            if let cached = cache.cachedEntries(for: dbURL, key: bucketedKey) {
                entries.append(contentsOf: cached)
            } else {
                let parsed = readUsageFromSQLite(dbURL)
                cache.store(parsed, for: dbURL, key: bucketedKey)
                entries.append(contentsOf: parsed)
            }
        }

        return entries
    }

    // MARK: - Sidecar CSV

    private func sidecarCSVURL(near dbURL: URL) -> URL {
        dbURL.deletingLastPathComponent().appendingPathComponent("cursor-usage.csv")
    }

    // MARK: - SQLite (best-effort, fully gated)

    private func readUsageFromSQLite(_ dbURL: URL) -> [TokenEntry] {
        var db: OpaquePointer?
        // Read-only + URI so a live Cursor won't be disturbed.
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let uri = "file:\(dbURL.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, openFlags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        var out: [TokenEntry] = []
        // Cursor stores blobs in both ItemTable (workbench state) and cursorDiskKV.
        for table in ["cursorDiskKV", "ItemTable"] {
            out.append(contentsOf: scanKVTable(db, table: table))
        }
        return out
    }

    /// Scan a key/value table whose `value` column may hold JSON usage blobs that
    /// mention token fields. We only keep rows whose key hints at usage to avoid
    /// scanning every workbench setting.
    private func scanKVTable(_ db: OpaquePointer, table: String) -> [TokenEntry] {
        // Guard: skip if table doesn't exist.
        guard tableExists(db, name: table) else { return [] }

        // Pass 1: select KEYS only. Matching on key alone means non-matching
        // rows' multi-MB value blobs (overflow pages) are never read off disk.
        let keySQL = "SELECT key FROM \(table) WHERE lower(key) LIKE '%usage%' OR lower(key) LIKE '%token%'"
        var keyStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, keySQL, -1, &keyStmt, nil) == SQLITE_OK else { return [] }
        var keys: [String] = []
        while sqlite3_step(keyStmt) == SQLITE_ROW {
            if let keyPtr = sqlite3_column_text(keyStmt, 0) {
                keys.append(String(cString: keyPtr))
            }
        }
        sqlite3_finalize(keyStmt)
        if keys.isEmpty { return [] }

        // Pass 2: fetch values one-by-one for the matched keys only.
        let valSQL = "SELECT value FROM \(table) WHERE key = ?"
        var valStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, valSQL, -1, &valStmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(valStmt) }

        var out: [TokenEntry] = []
        for key in keys {
            sqlite3_reset(valStmt)
            sqlite3_clear_bindings(valStmt)
            sqlite3_bind_text(valStmt, 1, (key as NSString).utf8String, -1, nil)
            guard sqlite3_step(valStmt) == SQLITE_ROW,
                  let valuePtr = sqlite3_column_text(valStmt, 0) else { continue }
            let value = String(cString: valuePtr)
            guard let data = value.data(using: .utf8) else { continue }
            out.append(contentsOf: Self.entriesFromJSONValue(data))
        }
        return out
    }

    private func tableExists(_ db: OpaquePointer, name: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - JSON usage extraction (best-effort)

    /// Pull token entries out of an arbitrary JSON usage blob. Handles either a
    /// top-level array of usage records or an object with a `usage`/`generations`
    /// array. Each record must carry a recognizable token field.
    static func entriesFromJSONValue(_ data: Data) -> [TokenEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var records: [[String: Any]] = []
        if let arr = json as? [[String: Any]] {
            records = arr
        } else if let obj = json as? [String: Any] {
            for key in ["usage", "generations", "events", "records"] {
                if let arr = obj[key] as? [[String: Any]] {
                    records.append(contentsOf: arr)
                }
            }
        }

        var out: [TokenEntry] = []
        for rec in records {
            guard let e = entryFromRecord(rec) else { continue }
            out.append(e)
        }
        return out
    }

    private static func entryFromRecord(_ rec: [String: Any]) -> TokenEntry? {
        // Timestamp may be ms epoch, s epoch, or ISO8601.
        let ts: Date
        if let ms = rec["timestamp"] as? Double {
            ts = Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        } else if let s = rec["date"] as? String, let parsed = TokenParseHelpers.parseTimestamp(s) {
            ts = parsed
        } else {
            return nil
        }

        let model = (rec["model"] as? String) ?? "unknown"

        // Map the same semantics as kaboo's CSV: input(total) = w/ + w/o cache
        // write; cache read -> cachedInputTokens; output -> outputTokens.
        let inputCacheWrite = TokenParseHelpers.int64(rec, "inputWithCacheWrite")
            + TokenParseHelpers.int64(rec, "input_tokens")
        let inputNoCache = TokenParseHelpers.int64(rec, "inputWithoutCacheWrite")
        let cacheRead = TokenParseHelpers.int64(rec, "cacheReadTokens")
            + TokenParseHelpers.int64(rec, "cache_read_input_tokens")
        let output = TokenParseHelpers.int64(rec, "outputTokens")
            + TokenParseHelpers.int64(rec, "output_tokens")
        let input = inputCacheWrite + inputNoCache

        if input + output + cacheRead == 0 { return nil }

        let messageId = "cursor|\(model)|\(Int64(ts.timeIntervalSince1970))|\(input)|\(output)|\(cacheRead)"
        return TokenEntry(
            source: "cursor",
            model: model,
            project: "unknown",
            timestamp: ts,
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: cacheRead,
            reasoningOutputTokens: 0,
            sessionId: "cursor",
            messageId: messageId
        )
    }

    // MARK: - CSV parsing (mirrors kaboo's parseCursorCSV columns)

    static func parseCSV(_ csv: String) -> [TokenEntry] {
        let rows = parseCSVRows(csv)
        guard rows.count >= 2 else { return [] }
        let header = rows[0]
        func idx(_ name: String) -> Int {
            for (i, h) in header.enumerated() where h.trimmingCharacters(in: .whitespaces) == name {
                return i
            }
            return -1
        }
        let dateIdx = idx("Date")
        let modelIdx = idx("Model")
        let inputCacheWriteIdx = idx("Input (w/ Cache Write)")
        let inputNoCacheIdx = idx("Input (w/o Cache Write)")
        let cacheReadIdx = idx("Cache Read")
        let outputIdx = idx("Output Tokens")
        guard dateIdx >= 0, modelIdx >= 0 else { return [] }

        func cell(_ row: [String], _ i: Int) -> String {
            (i >= 0 && i < row.count) ? row[i] : ""
        }
        func intCell(_ row: [String], _ i: Int) -> Int64 {
            let s = cell(row, i).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
            return Int64(s) ?? 0
        }

        var out: [TokenEntry] = []
        for row in rows.dropFirst() {
            if row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let model = cell(row, modelIdx).trimmingCharacters(in: .whitespaces)
            guard let ts = TokenParseHelpers.parseTimestamp(cell(row, dateIdx)) ?? csvDate(cell(row, dateIdx)),
                  !model.isEmpty else { continue }

            let inputCacheWrite = intCell(row, inputCacheWriteIdx)
            let inputNoCache = intCell(row, inputNoCacheIdx)
            let cacheRead = intCell(row, cacheReadIdx)
            let output = intCell(row, outputIdx)
            let input = inputCacheWrite + inputNoCache
            if input + cacheRead + output == 0 { continue }

            let messageId = "cursor-csv|\(model)|\(Int64(ts.timeIntervalSince1970))|\(input)|\(output)|\(cacheRead)"
            out.append(TokenEntry(
                source: "cursor",
                model: model,
                project: "unknown",
                timestamp: ts,
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: cacheRead,
                reasoningOutputTokens: 0,
                sessionId: "cursor",
                messageId: messageId
            ))
        }
        return out
    }

    /// Cursor CSV "Date" is typically "YYYY-MM-DD HH:MM:SS".
    private static func csvDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: trimmed)
    }

    /// Minimal RFC4180-ish CSV row splitter (handles quoted fields + escapes).
    static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r":
                    break
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
