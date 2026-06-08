//
//  TestMain.swift
//  Standalone (swiftc) tests for the Foundation-only token parsing + aggregation.
//
//  Compiled by run-tests.sh against the real client sources:
//    Models/Domain/TokenModels.swift
//    Models/API/StateModels.swift
//    Services/TokenParsers/*.swift
//  No XCTest, no Xcode test target. Uses a tiny assert harness so the whole file
//  runs and reports a pass/fail count.
//

import Foundation

// MARK: - Tiny assert harness

final class T {
    static var passed = 0
    static var failed = 0
    static func ok(_ cond: Bool, _ msg: String) {
        if cond { passed += 1 }
        else { failed += 1; FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)) }
    }
    static func eq<V: Equatable>(_ a: V, _ b: V, _ msg: String) {
        ok(a == b, "\(msg) (got \(a), want \(b))")
    }
}

// MARK: - Fixed clock helpers (UTC calendar for determinism)

var utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: iso)!
}

func entry(source: String = "claude-code",
           model: String,
           ts: String,
           input: Int64 = 0, output: Int64 = 0, cached: Int64 = 0, reasoning: Int64 = 0,
           session: String = "s1", message: String = "") -> TokenEntry {
    TokenEntry(source: source, model: model, project: "proj",
               timestamp: date(ts),
               inputTokens: input, outputTokens: output,
               cachedInputTokens: cached, reasoningOutputTokens: reasoning,
               sessionId: session, messageId: message)
}

// MARK: - Test: Claude Code JSONL parsing from a fixture

func testClaudeCodeParsing() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("sms-claude-\(UUID().uuidString)", isDirectory: true)
    // ~/.claude/projects/<encoded>/<session>.jsonl
    let projectDir = tmp.appendingPathComponent("projects/-Users-me-code-myproj", isDirectory: true)
    try? fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let sessionFile = projectDir.appendingPathComponent("session-abc.jsonl")

    // One assistant line with explicit usage (no carve since reasoning present),
    // one user line (ignored), one assistant line with no reasoning field on a
    // non-thinking turn (carve = 0 because no thinking chars).
    let lines = [
        #"{"type":"user","uuid":"u1","timestamp":"2026-06-05T10:00:00.000Z","message":{"role":"user","content":"hi"}}"#,
        #"{"type":"assistant","uuid":"a1","timestamp":"2026-06-05T10:00:01.000Z","message":{"id":"msg_01","model":"claude-opus-4-8","content":[{"type":"text","text":"hello there"}],"usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":20,"reasoning_output_tokens":5}}}"#,
        #"{"type":"assistant","uuid":"a2","timestamp":"2026-06-05T10:00:02.000Z","message":{"id":"msg_02","model":"claude-opus-4-8","content":[{"type":"text","text":"second"}],"usage":{"input_tokens":10,"output_tokens":8,"cache_read_input_tokens":0,"reasoning_output_tokens":0}}}"#
    ]
    try? lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

    let parser = ClaudeCodeParser(configDirs: [tmp])
    var cache = TokenScanCache()
    let entries = parser.parse(since: date("2026-01-01T00:00:00.000Z"), cache: &cache)

    T.eq(entries.count, 2, "claude: two usage entries parsed")
    if let first = entries.first(where: { $0.messageId == "msg_01" }) {
        T.eq(first.model, "claude-opus-4-8", "claude: model parsed")
        T.eq(first.inputTokens, 100, "claude: input_tokens")
        T.eq(first.outputTokens, 40, "claude: output_tokens (reasoning present, no carve)")
        T.eq(first.cachedInputTokens, 20, "claude: cache_read_input_tokens -> cachedInputTokens")
        T.eq(first.reasoningOutputTokens, 5, "claude: reasoning_output_tokens")
        T.eq(first.sessionId, "session-abc", "claude: sessionId = file stem")
        T.eq(first.project, "myproj", "claude: project from encoded dir last segment")
    } else {
        T.ok(false, "claude: msg_01 entry missing")
    }

    // Cache hit: parsing again returns the same entries without re-reading.
    let entries2 = parser.parse(since: date("2026-01-01T00:00:00.000Z"), cache: &cache)
    T.eq(entries2.count, 2, "claude: cache hit returns same count")

    try? fm.removeItem(at: tmp)
}

// MARK: - Test: Claude reasoning carve-out (Anthropic thinking split)

func testClaudeReasoningCarve() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("sms-carve-\(UUID().uuidString)", isDirectory: true)
    let projectDir = tmp.appendingPathComponent("projects/-x-y", isDirectory: true)
    try? fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let sessionFile = projectDir.appendingPathComponent("sess.jsonl")

    // Thinking block of 30 chars + text block of 10 chars = 40 total. output=80,
    // reasoning absent -> carve = round(80 * 30/40) = 60. output becomes 20.
    let thinking = String(repeating: "a", count: 30)
    let text = String(repeating: "b", count: 10)
    let line = #"{"type":"assistant","uuid":"a1","timestamp":"2026-06-05T10:00:01.000Z","message":{"id":"m1","model":"claude-sonnet-4","content":[{"type":"thinking","thinking":"\#(thinking)"},{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":50,"output_tokens":80,"cache_read_input_tokens":0}}}"#
    try? line.write(to: sessionFile, atomically: true, encoding: .utf8)

    var cache = TokenScanCache()
    let entries = ClaudeCodeParser(configDirs: [tmp]).parse(since: date("2026-01-01T00:00:00.000Z"), cache: &cache)
    T.eq(entries.count, 1, "carve: one entry")
    if let e = entries.first {
        T.eq(e.reasoningOutputTokens, 60, "carve: reasoning = 80*30/40 = 60")
        T.eq(e.outputTokens, 20, "carve: output reduced to 20 (total unchanged)")
        T.eq(e.inputTokens + e.outputTokens + e.cachedInputTokens + e.reasoningOutputTokens, 130, "carve: total = 50+20+0+60")
    }
    try? fm.removeItem(at: tmp)
}

// MARK: - Test: Codex parsing from a fixture

func testCodexParsing() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("sms-codex-\(UUID().uuidString)", isDirectory: true)
    let sessDir = tmp.appendingPathComponent("sessions/2026/06/05", isDirectory: true)
    try? fm.createDirectory(at: sessDir, withIntermediateDirectories: true)
    let file = sessDir.appendingPathComponent("rollout-abc.jsonl")

    let lines = [
        #"{"type":"session_meta","timestamp":"2026-06-05T10:00:00.000Z","payload":{"cwd":"/Users/me/work/codexproj"}}"#,
        #"{"type":"turn_context","timestamp":"2026-06-05T10:00:01.000Z","payload":{"model":"gpt-5-codex"}}"#,
        #"{"type":"event_msg","timestamp":"2026-06-05T10:00:02.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"output_tokens":60,"cached_input_tokens":20,"reasoning_output_tokens":15},"total_token_usage":{"input_tokens":120,"output_tokens":60}}}}"#
    ]
    try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

    var cache = TokenScanCache()
    let entries = CodexParser(configDirs: [tmp]).parse(since: date("2026-01-01T00:00:00.000Z"), cache: &cache)
    T.eq(entries.count, 1, "codex: one token entry")
    if let e = entries.first {
        T.eq(e.model, "gpt-5-codex", "codex: model from turn_context")
        T.eq(e.project, "codexproj", "codex: project from session_meta cwd")
        T.eq(e.cachedInputTokens, 20, "codex: cached_input_tokens")
        T.eq(e.inputTokens, 100, "codex: input normalized (120 - 20 cached)")
        T.eq(e.outputTokens, 45, "codex: output normalized (60 - 15 reasoning)")
        T.eq(e.reasoningOutputTokens, 15, "codex: reasoning_output_tokens")
    }
    try? fm.removeItem(at: tmp)
}

// MARK: - Test: window bucketing (today / 7d / 30d) with injectable now

func testWindowBucketing() {
    // now = 2026-06-05 12:00 UTC. Aligned with kaboo: today = UTC calendar day;
    // 7d/30d are ROLLING windows anchored at now (7d >= 05-29T12:00, 30d >= 05-06T12:00).
    let now = date("2026-06-05T12:00:00.000Z")
    let entries = [
        entry(model: "m", ts: "2026-06-05T01:00:00.000Z", input: 10, message: "today_a"),     // today + 7d + 30d
        entry(model: "m", ts: "2026-06-05T11:00:00.000Z", input: 10, message: "today_b"),     // today + 7d + 30d
        entry(model: "m", ts: "2026-06-02T12:00:00.000Z", input: 100, message: "d3"),         // 7d + 30d (not today)
        entry(model: "m", ts: "2026-05-29T13:00:00.000Z", input: 1000, message: "edge7d_in"), // just inside 7d
        entry(model: "m", ts: "2026-05-29T11:00:00.000Z", input: 2000, message: "edge7d_out"),// just outside 7d, inside 30d
        entry(model: "m", ts: "2026-05-06T13:00:00.000Z", input: 50000, message: "edge30_in"),// just inside 30d
        entry(model: "m", ts: "2026-05-06T11:00:00.000Z", input: 99999, message: "edge30_out")// just outside 30d -> dropped
    ]
    let agg = TokenAggregator.aggregate(entries: entries, windowDays: 30, now: now, calendar: utcCalendar)

    T.eq(agg.today.inputTokens, 20, "window: today (UTC cal day) = 10+10")
    T.eq(agg.last7d.inputTokens, 1120, "window: rolling 7d = 10+10+100+1000 (edge7d_in in, edge7d_out out)")
    T.eq(agg.total.inputTokens, 53120, "window: rolling 30d = 1120 + 2000 + 50000 (edge30_out dropped)")
    T.eq(agg.sessionCount, 1, "window: sessionCount distinct today sessions")
    T.eq(agg.windowDays, 30, "window: windowDays echoed")
    T.eq(agg.ts, Int64(now.timeIntervalSince1970 * 1000), "window: ts is now in ms")
}

// MARK: - Test: byModel top-N + "other" folding

func testByModelTopNFolding() {
    let now = date("2026-06-05T12:00:00.000Z")
    var entries: [TokenEntry] = []
    // 10 distinct models with decreasing totals; topN limit is 8 -> 2 fold to other.
    for i in 0..<10 {
        entries.append(entry(model: "model-\(String(format: "%02d", i))",
                             ts: "2026-06-05T10:00:00.000Z",
                             input: Int64((10 - i) * 100),
                             message: "m\(i)"))
    }
    let agg = TokenAggregator.aggregate(entries: entries, windowDays: 30, now: now, calendar: utcCalendar)
    let models = agg.today.byModel
    T.eq(models.count, 9, "byModel: 8 explicit + 1 other = 9")
    T.eq(models.last?.model, "other", "byModel: last is 'other'")
    // The two smallest were model-08 (200) and model-09 (100) -> other = 300.
    T.eq(models.last?.totalTokens, 300, "byModel: other = 200 + 100")
    // Top model overall is model-00 (1000).
    T.eq(models.first?.model, "model-00", "byModel: sorted desc, top is model-00")
}

// MARK: - Test: topModel selection (today, fallback to total, else "")

func testTopModelSelection() {
    let now = date("2026-06-05T12:00:00.000Z")

    // Case 1: today has data -> today's max wins.
    let a1 = TokenAggregator.aggregate(entries: [
        entry(model: "alpha", ts: "2026-06-05T10:00:00.000Z", input: 10, message: "x1"),
        entry(model: "beta",  ts: "2026-06-05T10:00:00.000Z", input: 99, message: "x2"),
        entry(model: "alpha", ts: "2026-06-01T10:00:00.000Z", input: 99999, message: "x3")
    ], windowDays: 30, now: now, calendar: utcCalendar)
    T.eq(a1.topModel, "beta", "topModel: today's max wins over older total")

    // Case 2: today empty -> falls back to total's max.
    let a2 = TokenAggregator.aggregate(entries: [
        entry(model: "gamma", ts: "2026-06-01T10:00:00.000Z", input: 500, message: "y1"),
        entry(model: "delta", ts: "2026-06-02T10:00:00.000Z", input: 10, message: "y2")
    ], windowDays: 30, now: now, calendar: utcCalendar)
    T.eq(a2.topModel, "gamma", "topModel: today empty -> total's max")

    // Case 3: no data at all -> "".
    let a3 = TokenAggregator.aggregate(entries: [], windowDays: 30, now: now, calendar: utcCalendar)
    T.eq(a3.topModel, "", "topModel: empty when no data")
}

// MARK: - Test: dedup by messageId

func testDedupByMessageId() {
    let now = date("2026-06-05T12:00:00.000Z")
    // Same messageId appears twice with different totals -> keep largest-total.
    let entries = [
        entry(model: "m", ts: "2026-06-05T10:00:00.000Z", input: 10, message: "dup"),
        entry(model: "m", ts: "2026-06-05T10:00:00.000Z", input: 50, message: "dup"),
        entry(model: "m", ts: "2026-06-05T10:00:00.000Z", input: 7, message: ""),       // empty id -> kept
        entry(model: "m", ts: "2026-06-05T10:00:00.000Z", input: 3, message: "")        // empty id -> kept
    ]
    let agg = TokenAggregator.aggregate(entries: entries, windowDays: 30, now: now, calendar: utcCalendar)
    // 50 (winning dup) + 7 + 3 = 60.
    T.eq(agg.today.inputTokens, 60, "dedup: keeps largest-total per id, keeps empty-id entries")

    // Cross-source same id must NOT collide.
    let cross = TokenAggregator.dedupe([
        entry(source: "claude-code", model: "m", ts: "2026-06-05T10:00:00.000Z", input: 5, message: "id"),
        entry(source: "codex",       model: "m", ts: "2026-06-05T10:00:00.000Z", input: 9, message: "id")
    ])
    T.eq(cross.count, 2, "dedup: same id across sources kept separate")
}

// MARK: - Test: Codable JSON encoding produces the exact frozen keys

func testFrozenJSONKeys() {
    let now = date("2026-06-05T12:00:00.000Z")
    let agg = TokenAggregator.aggregate(entries: [
        entry(model: "claude-opus-4-8", ts: "2026-06-05T10:00:00.000Z",
              input: 1, output: 2, cached: 3, reasoning: 4, message: "k1")
    ], windowDays: 30, now: now, calendar: utcCalendar)

    let dto = agg.toDTO()
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let data = try! enc.encode(dto)
    let json = String(data: data, encoding: .utf8)!
    let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

    // Top-level keys present.
    for key in ["today", "last7d", "total", "topModel", "sessionCount", "windowDays", "ts"] {
        T.ok(obj[key] != nil, "json: top-level key '\(key)' present")
    }

    // Window keys: the four counters + byModel present; server-computed fields absent.
    let today = obj["today"] as! [String: Any]
    for key in ["inputTokens", "outputTokens", "cachedInputTokens", "reasoningOutputTokens", "byModel"] {
        T.ok(today[key] != nil, "json: window key '\(key)' present")
    }
    T.ok(today["totalTokens"] == nil, "json: window omits server-computed totalTokens")
    T.ok(today["estimatedCostUsd"] == nil, "json: window omits server-computed estimatedCostUsd")
    T.ok(!json.contains("totalTokens"), "json: 'totalTokens' nowhere in payload")
    T.ok(!json.contains("estimatedCostUsd"), "json: 'estimatedCostUsd' nowhere in payload")

    // Model entry keys.
    let byModel = today["byModel"] as! [[String: Any]]
    T.eq(byModel.count, 1, "json: one model entry")
    let m0 = byModel[0]
    T.eq(m0["model"] as? String, "claude-opus-4-8", "json: model name")
    for key in ["inputTokens", "outputTokens", "cachedInputTokens", "reasoningOutputTokens"] {
        T.ok(m0[key] != nil, "json: model key '\(key)' present")
    }

    // Value checks.
    T.eq(today["inputTokens"] as? Int, 1, "json: inputTokens value")
    T.eq(obj["topModel"] as? String, "claude-opus-4-8", "json: topModel value")
    T.eq(obj["windowDays"] as? Int, 30, "json: windowDays value")
    T.eq(obj["ts"] as? Int64 ?? Int64(obj["ts"] as? Int ?? 0), Int64(now.timeIntervalSince1970 * 1000), "json: ts value")
}

// MARK: - Test: zeroed payload helper

func testZeroedPayload() {
    let z = TokenUsageAggregate.zeroed(windowDays: 30, ts: 1733000000000)
    T.eq(z.today.totalTokens, 0, "zeroed: today is 0")
    T.eq(z.last7d.totalTokens, 0, "zeroed: 7d is 0")
    T.eq(z.total.totalTokens, 0, "zeroed: total is 0")
    T.eq(z.topModel, "", "zeroed: topModel empty")
    T.eq(z.sessionCount, 0, "zeroed: sessionCount 0")
    T.eq(z.ts, 1733000000000, "zeroed: ts preserved")
    // Encodes with ts present.
    let data = try! JSONEncoder().encode(z.toDTO())
    let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    T.ok(obj["ts"] != nil, "zeroed: ts present in JSON")
}

// MARK: - Test: human formatting

func testFormatting() {
    T.eq(TokenFormatting.compact(0), "0", "fmt: 0")
    T.eq(TokenFormatting.compact(999), "999", "fmt: 999")
    T.eq(TokenFormatting.compact(1000), "1K", "fmt: 1000 -> 1K")
    T.eq(TokenFormatting.compact(1234), "1.2K", "fmt: 1234 -> 1.2K")
    T.eq(TokenFormatting.compact(1_200_000), "1.2M", "fmt: 1.2M")
    T.eq(TokenFormatting.compact(2_000_000_000), "2B", "fmt: 2B")
}

// MARK: - Run

testClaudeCodeParsing()
testClaudeReasoningCarve()
testCodexParsing()
testWindowBucketing()
testByModelTopNFolding()
testTopModelSelection()
testDedupByMessageId()
testFrozenJSONKeys()
testZeroedPayload()
testFormatting()

print("Token tests: \(T.passed) passed, \(T.failed) failed")
if T.failed > 0 { exit(1) }
