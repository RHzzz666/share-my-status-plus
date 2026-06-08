// Dev tool: scan THIS machine's real local AI-tool logs using the SAME parser
// sources the app ships, print a human summary (stderr) + the exact
// BatchReportRequest wire JSON the client would POST (stdout).
// Mirrors the app's default-ON parser set (cursor + antigravity default OFF).
// Build/run via run.sh — not part of the app target.
import Foundation

let windowDays = Int(ProcessInfo.processInfo.environment["SMS_WINDOW_DAYS"] ?? "") ?? 30
let since = Date(timeIntervalSinceNow: -Double(windowDays) * 86400)
var cache = TokenScanCache()
var entries: [TokenEntry] = []

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func run(_ name: String, _ p: TokenLogParser) {
    let raw = p.parse(since: since, cache: &cache)
    // Show the post-dedup contribution (matches how the windows count it; dedup
    // is source-namespaced so per-tool dedup == this tool's share of the total).
    let deduped = TokenAggregator.dedupe(raw)
    let tot = deduped.reduce(Int64(0)) { $0 + $1.totalTokens }
    err("  \(name): \(deduped.count) entries, \(TokenFormatting.compact(tot)) tokens")
    entries += raw   // global aggregate re-dedupes (idempotent)
}

err("Scanning local AI logs (rolling window = \(windowDays)d)…")
run("claude-code", ClaudeCodeParser())
run("codex",       CodexParser())
run("gemini",      GeminiParser())
run("claude-app",  ClaudeAppParser())
run("openclaw",    OpenClawParser())
run("trae",        TraeParser())

let agg = TokenAggregator.aggregate(entries: entries, windowDays: windowDays, now: Date(), calendar: .current)

func line(_ label: String, _ w: TokenWindowAggregate) -> String {
    "  \(label): \(TokenFormatting.compact(w.totalTokens))  (in \(w.inputTokens), out \(w.outputTokens), cache \(w.cachedInputTokens), reason \(w.reasoningOutputTokens))"
}
err("")
err("=== Your token usage ===")
err(line("today ", agg.today))
err(line("7-day ", agg.last7d))
err(line("30-day", agg.total))
err("  topModel: \(agg.topModel)   sessions(today): \(agg.sessionCount)")
err("  today by model:")
for m in agg.today.byModel { err("    \(m.model): \(TokenFormatting.compact(m.totalTokens))") }
err("")
err("(cost is server-side; run with --live to POST and see cost + the rendered signature)")

// The exact wire JSON the client POSTs (server fills totalTokens/estimatedCostUsd).
let req = BatchReportRequest(events: [ReportEvent(tokens: agg.toDTO())])
FileHandle.standardOutput.write(try JSONEncoder().encode(req))
