package render

import (
	"strings"
	"testing"

	common "share-my-status/api/model/share_my_status/common"
)

func i64p(v int64) *int64       { return &v }
func f64p(v float64) *float64   { return &v }
func i32p(v int32) *int32       { return &v }
func strp(v string) *string     { return &v }

func TestFormatTokensHuman(t *testing.T) {
	cases := map[int64]string{
		0:             "0",
		999:           "999",
		1000:          "1K",
		1500:          "1.5K",
		12_345:        "12.3K",
		1_000_000:     "1M",
		1_234_567:     "1.2M",
		1_000_000_000: "1B",
		-1500:         "-1.5K",
		// 进位边界：%.1f 会把 999.95K+ 舍入成 1000.0，应晋升单位而不是显示 "1000K"/"1000M"
		999_949:     "999.9K",
		999_999:     "1M",
		999_950_000: "1B",
	}
	for n, want := range cases {
		if got := formatTokensHuman(n); got != want {
			t.Errorf("formatTokensHuman(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestFormatCostUsd(t *testing.T) {
	if got := formatCostUsd(0); got != "$0.00" {
		t.Errorf("formatCostUsd(0) = %q, want $0.00", got)
	}
	if got := formatCostUsd(3.456); got != "$3.46" {
		t.Errorf("formatCostUsd(3.456) = %q, want $3.46", got)
	}
}

func sampleTokens() *common.TokenUsage {
	return &common.TokenUsage{
		Ts:           1_733_000_000_000,
		TopModel:     strp("claude-opus-4-8"),
		SessionCount: i64p(12),
		WindowDays:   i32p(30),
		Today: &common.TokenWindowUsage{
			InputTokens:           i64p(800_000),
			OutputTokens:          i64p(300_000),
			CachedInputTokens:     i64p(120_000),
			ReasoningOutputTokens: i64p(14_567),
			TotalTokens:           i64p(1_234_567),
			EstimatedCostUsd:      f64p(3.45),
		},
		Last7d: &common.TokenWindowUsage{
			TotalTokens:      i64p(8_900_000),
			EstimatedCostUsd: f64p(21.30),
		},
		Total: &common.TokenWindowUsage{
			TotalTokens:      i64p(34_600_000),
			EstimatedCostUsd: f64p(98.76),
		},
	}
}

func TestRenderTokenVariables_WithData(t *testing.T) {
	tpl := "今日{tokensTodayH}({tokensToday}) 花费{tokenCostToday} 入{tokenInToday} 出{tokenOutToday} " +
		"缓存{tokenCacheToday} 推理{tokenReasonToday} | 7d {tokens7dH}/{tokenCost7d} | " +
		"总 {tokensTotalH}/{tokenCostTotal} | 模型 {topModel} 会话{tokenSessions} 窗口{tokenWindowDays}d"
	got := renderTokenVariables(tpl, sampleTokens())

	wantContains := []string{
		"今日1.2M(1234567)", "花费$3.45", "入800000", "出300000", "缓存120000", "推理14567",
		"7d 8.9M/$21.30", "总 34.6M/$98.76", "模型 claude-opus-4-8", "会话12", "窗口30d",
	}
	for _, w := range wantContains {
		if !strings.Contains(got, w) {
			t.Errorf("rendered output missing %q\nfull: %s", w, got)
		}
	}
	if strings.Contains(got, "{token") || strings.Contains(got, "{topModel}") {
		t.Errorf("unsubstituted placeholder remains: %s", got)
	}
}

func TestRenderTokenVariables_Nil(t *testing.T) {
	tpl := "今日{tokensToday}/{tokensTodayH} 花费{tokenCostToday} 模型[{topModel}] 会话{tokenSessions}"
	got := renderTokenVariables(tpl, nil)
	want := "今日0/0 花费$0.00 模型[] 会话0"
	if got != want {
		t.Errorf("nil render = %q, want %q", got, want)
	}
}

// 当窗口未带 TotalTokens 时，按四项求和。
func TestWindowTotalTokens_SumFallback(t *testing.T) {
	w := &common.TokenWindowUsage{
		InputTokens:           i64p(10),
		OutputTokens:          i64p(20),
		CachedInputTokens:     i64p(5),
		ReasoningOutputTokens: i64p(1),
	}
	if got := windowTotalTokens(w); got != 36 {
		t.Errorf("windowTotalTokens sum fallback = %d, want 36", got)
	}
	if got := windowTotalTokens(nil); got != 0 {
		t.Errorf("windowTotalTokens(nil) = %d, want 0", got)
	}
}

// RenderTemplate 整链路应同时渲染音乐与 token 变量。
func TestRenderTemplate_IncludesTokens(t *testing.T) {
	state := &common.StatusSnapshot{
		LastUpdateTs: 1,
		Tokens:       sampleTokens(),
	}
	got := RenderTemplate("Token今日{tokensTodayH}", state)
	if !strings.Contains(got, "Token今日1.2M") {
		t.Errorf("RenderTemplate did not render token var: %s", got)
	}
}
