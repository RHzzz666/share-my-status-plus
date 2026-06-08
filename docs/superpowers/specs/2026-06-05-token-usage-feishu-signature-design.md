# Token Usage in Feishu 个性签名 — Design Spec

Date: 2026-06-05
Status: Approved scope (autonomous goal execution)

## Goal

Port kaboo CLI's "token reporting" capability into share-my-status-plus so a user can
**configure**, **view**, and **display** their own AI-tool token usage. Display surface =
the existing **Feishu 个性签名 (personal signature)** render pipeline.

## How the existing signature works (confirmed)

1. macOS client reports realtime status → `POST /api/v1/state/report` → stored in
   `current_state.snapshot` (`common.StatusSnapshot` jsonb).
2. User pastes `https://<host>/s/{SharingKey}?m={template}` into their Feishu 个性签名.
3. Feishu unfurls the URL → URL-preview event over the bot WebSocket →
   `OnP2CardURLPreviewGet` → `render.RenderBySharingKey(key, template)` → substitutes
   `{var}` placeholders against the current snapshot → returns the title → Feishu shows it.
4. Variable catalogue is `render/template_config.go` (served at `/api/v1/render/template-config`).

Token usage plugs straight in: client reports a **Tokens block** in the snapshot, the
backend prices it, render exposes `{token…}` variables. **No new HTTP endpoints, no bucket
history table, no leaderboard** — token display rides the realtime-snapshot + render path
(the render path is deliberately query-free per Tech Design).

## Architecture / data flow

```
macOS: scan local AI logs (Claude Code / Codex / Cursor / Gemini)
   → aggregate per-model token counts for windows: today / last7d / total(30d)
   → report TokenUsage block via existing /api/v1/state/report
backend: state.processEvent prices the block (pkg/pricing) → totalTokens + estimatedCostUsd
   → store in current_state.snapshot (mergeSnapshots carries the Tokens block)
render: renderTokenVariables substitutes {tokensToday},{tokenCostToday},{topModel},...
Feishu 个性签名: user template e.g. "今日Token {tokensTodayH} 花费{tokenCostToday}"
```

## 1. IDL (`idl/common.thrift`) — source of truth, regenerate via `hz update`

```thrift
struct TokenModelUsage {
    1: required string model;
    2: optional i64 inputTokens;
    3: optional i64 outputTokens;
    4: optional i64 cachedInputTokens;
    5: optional i64 reasoningOutputTokens;
}
struct TokenWindowUsage {
    1: optional i64 inputTokens;
    2: optional i64 outputTokens;
    3: optional i64 cachedInputTokens;
    4: optional i64 reasoningOutputTokens;
    5: optional i64 totalTokens;          // server-computed = sum of four
    6: optional double estimatedCostUsd;  // server-computed via pricing
    7: optional list<TokenModelUsage> byModel; // client-reported top-N, used for pricing/topModel
}
struct TokenUsage {
    1: optional TokenWindowUsage today;   // local calendar day
    2: optional TokenWindowUsage last7d;  // last 7 days
    3: optional TokenWindowUsage total;   // rolling window of windowDays days
    4: optional string topModel;          // most-used model today
    5: optional i64 sessionCount;         // today's session count
    6: optional i32 windowDays;           // 'total' window size (for label)
    7: required i64 ts;                   // when computed (ms)
}
```
Add `6: optional TokenUsage tokens;` to `ReportEvent` and `5: optional TokenUsage tokens;`
to `StatusSnapshot`.

## 2. Backend (Go)

| Change | File |
|---|---|
| Pricing map + `EstimateCostUsd` + `DetectFamily` (Claude/GPT/Gemini families, fallback) | new `backend/pkg/pricing/pricing.go` |
| `state.processEvent`: if `event.Tokens != nil`, price the block (fill totalTokens, estimatedCostUsd, derive topModel), set `newSnapshot.Tokens`; `mergeSnapshots` carries Tokens (whole-block replace; zeroed block from client clears it on disable) | `backend/domain/state/state_service.go` |
| `renderTokenVariables` wired into `RenderTemplate` | `backend/domain/render/render_service.go` |
| Token `TemplateVariable`s (category `token`) | `backend/domain/render/template_config.go` |

### Pricing (USD per 1M tokens, approximate public 2025 prices; fallback = sonnet-like)
| family | input | output | cachedInput | reasoning |
|---|---|---|---|---|
| claude-opus | 15 | 75 | 1.5 | 75 |
| claude-sonnet | 3 | 15 | 0.30 | 15 |
| claude-haiku | 0.80 | 4 | 0.08 | 4 |
| gpt-4o | 2.5 | 10 | 1.25 | 10 |
| gpt-4o-mini | 0.15 | 0.60 | 0.075 | 0.60 |
| o-series (o1/o3) | 15 | 60 | 7.5 | 60 |
| gemini-pro | 1.25 | 5 | 0.3125 | 5 |
| gemini-flash | 0.075 | 0.30 | 0.01875 | 0.30 |
| unknown (fallback) | 3 | 15 | 0.30 | 15 |

### Render variables
`{tokensToday}` `{tokensTodayH}`(1.2M) `{tokenCostToday}`($1.23)
`{tokenInToday}` `{tokenOutToday}` `{tokenCacheToday}` `{tokenReasonToday}`
`{tokens7d}` `{tokens7dH}` `{tokenCost7d}`
`{tokensTotal}` `{tokensTotalH}` `{tokenCostTotal}`
`{topModel}` `{tokenSessions}` `{tokenWindowDays}`
- Human format: `>=1e9→x.xB, >=1e6→x.xM, >=1e3→x.xK, else int`, trailing `.0` stripped.
- Cost: `$%.2f`. Nil/zero Tokens block → numerics render `0`, human `0`, cost `$0.00`, topModel ``.

## 3. macOS client (Swift)

| Change | File |
|---|---|
| `TokenUsageService` (orchestrator) + scan cache (path→size,mtime) + window aggregation | new `Services/TokenUsageService.swift` |
| `TokenLogParser` protocol + parsers: ClaudeCode (`~/.claude/projects/**/*.jsonl`), Codex (`~/.codex/sessions/**`), Gemini (`~/.gemini/tmp/**`), Cursor (`state.vscdb` via system libsqlite3) | new `Services/TokenParsers/*.swift` |
| Domain models `TokenModels.swift` (`TokenEntry`, window aggregates) | new `Models/Domain/TokenModels.swift` |
| API models: add `TokenUsage`/`TokenWindowUsage`/`TokenModelUsage` Codable to `ReportEvent` snapshot | `Models/API/StateModels.swift` |
| Settings: `tokenReportingEnabled`, per-tool toggles, interval, window days; export/import | `AppConfiguration.swift`, `DefaultSettings.swift`, `SettingsTabView.swift`, `ExportableConfiguration` |
| Reporter: start/stop token service, include Tokens in `ReportEvent`; on disable send a zeroed block once to clear | `Core/StatusReporter.swift` |
| Local display: today's tokens + cost | `Views/MainWindow/StatusTabView.swift` / `MenuBarView.swift` |

Collection mirrors kaboo parsers: read `message.usage` (input/output/cache_read/reasoning),
30-min-bucket not needed (we aggregate to day/7d/total windows directly), dedup by message id.

## 4. Configure / View / Display

- **Configure**: macOS settings (enable, which tools, interval, window days) + choose which
  signature variables via the existing `m` template / DIY page (now offers token variables).
- **View**: macOS app shows today/total tokens + cost locally.
- **Display**: Feishu 个性签名 renders the chosen token variables.

## 5. Tests

- **Go (runnable here)**: `pkg/pricing` table tests; `renderTokenVariables` tests (incl. nil
  block); `mergeSnapshots` carries/clears Tokens; `processEvent` prices into snapshot.
- **e2e (docker)**: bring up postgres+redis+backend, create user, `POST /state/report` with a
  Tokens block, then drive the render path (`GET /api/v1/render?sharingKey=&m=`) and assert the
  rendered signature contains the expected token numbers + cost.
- **Swift (xcodebuild)**: XCTest target for parsers (fixtures) + window aggregation + Codable
  round-trip. Run via `xcodebuild test` (Xcode 26.5 present).

## Edge cases (功能完整性)

- Token reporting disabled → client sends one zeroed Tokens block → signature shows 0.
- No AI logs / first run → windows zero → render `0` / `$0.00`.
- Unknown model → fallback pricing; logged, not dropped.
- `byModel` capped to top-N (e.g. 8) + synthetic `other` remainder (priced as unknown).
- Scan cache invalidated on size/mtime change.

## Out of scope (YAGNI)

No bucket-history table, no leaderboard, no `/api/v1/token/*` endpoints, no React card.
