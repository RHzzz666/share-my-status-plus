# AI Token 用量 → 飞书个性签名

把你在本机各 AI 工具（Claude Code / Codex / Cursor / Gemini）里消耗的 token 数与预估花费，
展示到自己的飞书个性签名里。整套流程复用项目已有的「上报 → 存储 → 渲染签名」管线。

## 数据流

```
macOS 客户端：扫描本地 AI 工具日志
   → 按窗口聚合（今日 / 近 7 天 / 总窗口 30 天）每个模型的 token 数
   → 通过现有 POST /api/v1/state/report 把 tokens 块随状态一起上报
后端：state.processEvent 对 tokens 块做服务端计算
   → 每个窗口写入 totalTokens 与 estimatedCostUsd（pkg/pricing 定价）
   → 存入 current_state.snapshot（jsonb）
渲染：render 把 {token...} 变量替换为实际数值
飞书个性签名：你把含变量的模板 URL 贴进签名即可
```

- 成本在**服务端**计算（`backend/pkg/pricing`），调价无需发布客户端。
- 签名渲染路径保持「无额外 DB 查询」：展示值来自实时快照，而非聚合统计查询。
- 关闭上报时，客户端会发送一次「全零」tokens 块，签名随之归零。

## 可用模板变量

在飞书签名链接 `https://<host>/s/{SharingKey}?m={template}` 的 `m` 模板里使用：

| 变量 | 含义 | 示例 |
|---|---|---|
| `{tokensToday}` | 今日 token 总数 | `1234567` |
| `{tokensTodayH}` | 今日 token（可读） | `1.2M` |
| `{tokenCostToday}` | 今日预计花费 | `$3.45` |
| `{tokenInToday}` | 今日输入 token | `800000` |
| `{tokenOutToday}` | 今日输出 token | `300000` |
| `{tokenCacheToday}` | 今日缓存读取 token | `120000` |
| `{tokenCacheCreateToday}` | 今日缓存写入 token | `45000` |
| `{tokenReasonToday}` | 今日推理 token | `14567` |
| `{tokens7d}` / `{tokens7dH}` | 近 7 天 token / 可读 | `8901234` / `8.9M` |
| `{tokenCost7d}` | 近 7 天预计花费 | `$21.30` |
| `{tokensTotal}` / `{tokensTotalH}` | 总窗口 token / 可读 | `34567890` / `34.6M` |
| `{tokenCostTotal}` | 总窗口预计花费 | `$98.76` |
| `{topModel}` | 今日主力模型 | `claude-opus-4-8` |
| `{tokenSessions}` | 今日会话数 | `12` |
| `{tokenWindowDays}` | 总窗口天数 | `30` |

可读格式规则：`>=1e9 → x.xB`、`>=1e6 → x.xM`、`>=1e3 → x.xK`，否则原始整数；末尾 `.0` 去除。
无数据 / 未上报 / 已清空时：数值渲染为 `0`、成本为 `$0.00`、`{topModel}` 为空。
完整变量目录见 `GET /api/v1/render/template-config`（category 为 `token`）。

### 示例签名模板

```
今日 Token {tokensTodayH} · 预计 {tokenCostToday} · 主力 {topModel}
```
渲染结果示例：`今日 Token 1.2M · 预计 $3.45 · 主力 claude-opus-4-8`

```
本周烧了 {tokens7dH}（{tokenCost7d}），近{tokenWindowDays}天累计 {tokensTotalH}
```

## 定价档位（USD / 1M tokens，近似公开价；未识别模型回退 sonnet 档）

| 档位 | input | output | cachedInput | reasoning |
|---|---|---|---|---|
| claude-opus | 15 | 75 | 1.5 | 75 |
| claude-sonnet | 3 | 15 | 0.30 | 15 |
| claude-haiku | 0.80 | 4 | 0.08 | 4 |
| gpt-5（Codex 默认族,含 gpt-5-codex） | 1.25 | 10 | 0.125 | 10 |
| gpt-5-mini/nano | 0.25 | 2 | 0.025 | 2 |
| gpt-4o | 2.5 | 10 | 1.25 | 10 |
| gpt-4o-mini（含 gpt-4.1-mini/nano） | 0.15 | 0.60 | 0.075 | 0.60 |
| o-series（o1/o3/o4） | 15 | 60 | 7.5 | 60 |
| o-series-mini（o1/o3/o4-mini） | 1.1 | 4.4 | 0.55 | 4.4 |
| gemini-pro | 1.25 | 5 | 0.3125 | 5 |
| gemini-flash | 0.075 | 0.30 | 0.01875 | 0.30 |
| unknown（回退） | 3 | 15 | 0.30 | 15 |

定价表见 `backend/pkg/pricing/pricing.go`，可按需调整。

## 在 macOS 客户端开启

设置面板里的「AI Token 用量」分组：开启总开关、勾选要统计的工具（Claude Code / Codex /
Cursor / Gemini）、设置上报间隔与总窗口天数。开启后客户端会定期扫描本地日志并随状态上报；
关闭后会发送一次归零数据清空签名。

## 实现位置

| 层 | 文件 |
|---|---|
| IDL | `idl/common.thrift`（`TokenUsage` / `TokenWindowUsage` / `TokenModelUsage`，及 `ReportEvent`/`StatusSnapshot` 的 `tokens` 字段） |
| 定价 | `backend/pkg/pricing/pricing.go` |
| 上报定价/聚合 | `backend/domain/state/token.go`、`state_service.go` |
| 签名渲染 | `backend/domain/render/render_service.go`、`template_config.go` |
| 客户端采集 | `desktop/macos/.../Services/TokenUsageService.swift` 及 `Services/TokenParsers/*` |
| 测试 | `backend/pkg/pricing/pricing_test.go`、`backend/domain/render/render_token_test.go`、`backend/domain/state/token_test.go`、`backend/e2e/token_signature_e2e_test.go` |
