//
//  TraeXParser.swift
//  share-my-status-client
//
//  Parser for the Trae CLI's codex-backend rollout logs ("traex").
//  Mirrors kaboo's ParseTraeX → parseCodexLikeDirsWithOptions("traex", …)
//  (cli/parsers.go:1315-1330, cli/config.go:301-317):
//    - the on-disk format is IDENTICAL to OpenAI Codex rollouts, so this parser
//      reuses CodexParser.parseFile(_:source:) verbatim — only the scan roots and
//      the source label differ. kaboo itself shares one parser between the two.
//    - roots resolve like kaboo's parseTraeXDirs:
//        KABOO_TRAEX_DIRS (":"-separated) → TRAE_CLI_HOME → TRAE_HOME+"/cli"
//        → default ~/.trae/cli
//    - under each root, scans BOTH `sessions` and `archived_sessions` recursively
//      for *.jsonl (kaboo codexSessionDirs, parsers.go:1401-1404).
//
//  This is a DISTINCT source from `trae-cli` (TraeParser): that one parses coco's
//  OTel trace spans under ~/Library/Caches/coco/sessions — a different product
//  store with a different on-disk shape. The two roots never overlap, so the
//  source-namespaced dedup ("traex:" vs "trae-cli:") keeps them isolated and no
//  same-usage double count occurs.
//
//  Foundation-only; never throws on malformed input — bad records are skipped.
//

import Foundation

nonisolated struct TraeXParser: TokenLogParser {
    let source = "traex"

    /// Override config dirs (tests inject a temp dir). When empty, resolves from
    /// KABOO_TRAEX_DIRS / TRAE_CLI_HOME / TRAE_HOME, then ~/.trae/cli.
    let configDirs: [URL]

    init(configDirs: [URL] = []) {
        self.configDirs = configDirs
    }

    /// Mirrors kaboo's parseTraeXDirs (config.go:305): KABOO_TRAEX_DIRS is an
    /// OS-list-separated list; TRAE_CLI_HOME is the CLI home; TRAE_HOME is the
    /// ~/.trae-style base and gets "/cli" appended; default ~/.trae/cli.
    private func resolvedConfigDirs() -> [URL] {
        if !configDirs.isEmpty { return configDirs }
        let env = ProcessInfo.processInfo.environment
        let home = TokenParseHelpers.homeDirectory

        var raw = ""
        if let v = env["KABOO_TRAEX_DIRS"], !v.isEmpty {
            raw = v
        } else if let v = env["TRAE_CLI_HOME"], !v.isEmpty {
            raw = v
        } else if let v = env["TRAE_HOME"], !v.isEmpty {
            raw = (v as NSString).appendingPathComponent("cli")
        }

        if raw.isEmpty {
            return [home.appendingPathComponent(".trae/cli", isDirectory: true)]
        }
        return raw.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true)
        }
    }

    func parse(since: Date, cache: inout TokenScanCache) -> [TokenEntry] {
        var out: [TokenEntry] = []
        let fm = FileManager.default

        for dir in resolvedConfigDirs() {
            // kaboo codexSessionDirs scans both sessions and archived_sessions.
            for sub in ["sessions", "archived_sessions"] {
                let sessionsDir = dir.appendingPathComponent(sub, isDirectory: true)
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
                    // Identical codex rollout format → reuse CodexParser, relabeled.
                    let entries = CodexParser.parseFile(file, source: source)
                    cache.store(entries, for: file, key: key)
                    out.append(contentsOf: entries)
                }
            }
        }
        return out
    }
}
