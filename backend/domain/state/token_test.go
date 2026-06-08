package state

import (
	"math"
	"testing"

	common "share-my-status/api/model/share_my_status/common"
)

func i64p(v int64) *int64   { return &v }
func strp(v string) *string { return &v }

func almostEqual(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestPriceWindow_ByModel(t *testing.T) {
	w := &common.TokenWindowUsage{
		InputTokens:  i64p(1_500_000),
		OutputTokens: i64p(500_000),
		ByModel: []*common.TokenModelUsage{
			{Model: "claude-opus-4-8", InputTokens: i64p(1_000_000), OutputTokens: i64p(200_000)},
			{Model: "claude-3-5-sonnet", InputTokens: i64p(500_000), OutputTokens: i64p(300_000)},
		},
	}
	out := priceWindow(w)

	// totalTokens = sum of the four aggregate counters = 1.5M + 0.5M
	if out.TotalTokens == nil || *out.TotalTokens != 2_000_000 {
		t.Fatalf("TotalTokens = %v, want 2000000", out.TotalTokens)
	}
	// cost = opus(1M in*15 + 0.2M out*75) + sonnet(0.5M in*3 + 0.3M out*15)
	//      = (15 + 15) + (1.5 + 4.5) = 30 + 6 = 36
	if out.EstimatedCostUsd == nil || !almostEqual(*out.EstimatedCostUsd, 36.0) {
		t.Fatalf("EstimatedCostUsd = %v, want 36.0", out.EstimatedCostUsd)
	}
}

func TestPriceWindow_NoByModel_FallbackPricing(t *testing.T) {
	w := &common.TokenWindowUsage{InputTokens: i64p(1_000_000)}
	out := priceWindow(w)
	if out.TotalTokens == nil || *out.TotalTokens != 1_000_000 {
		t.Fatalf("TotalTokens = %v, want 1000000", out.TotalTokens)
	}
	// no byModel => unknown(=sonnet) pricing: 1M input * 3 = 3.0
	if out.EstimatedCostUsd == nil || !almostEqual(*out.EstimatedCostUsd, 3.0) {
		t.Fatalf("EstimatedCostUsd = %v, want 3.0", out.EstimatedCostUsd)
	}
}

func TestPriceWindow_Nil(t *testing.T) {
	if priceWindow(nil) != nil {
		t.Fatal("priceWindow(nil) should be nil")
	}
}

// 客户端只发 byModel、不发聚合计数时，服务端应从 byModel 回填聚合数与 total，
// 使「展示 token 数」与「成本」自洽（回归：避免 0 token 却有成本）。
func TestPriceWindow_ByModelOnly_DerivesAggregates(t *testing.T) {
	w := &common.TokenWindowUsage{
		// 注意：聚合计数全部为 nil，仅给 byModel
		ByModel: []*common.TokenModelUsage{
			{Model: "claude-opus-4-8", InputTokens: i64p(1_000_000), OutputTokens: i64p(200_000)},
		},
	}
	out := priceWindow(w)
	if out.InputTokens == nil || *out.InputTokens != 1_000_000 {
		t.Fatalf("derived InputTokens = %v, want 1000000", out.InputTokens)
	}
	if out.OutputTokens == nil || *out.OutputTokens != 200_000 {
		t.Fatalf("derived OutputTokens = %v, want 200000", out.OutputTokens)
	}
	if out.TotalTokens == nil || *out.TotalTokens != 1_200_000 {
		t.Fatalf("derived TotalTokens = %v, want 1200000", out.TotalTokens)
	}
	// cost(opus) = 1M*15 + 0.2M*75 = 15 + 15 = 30
	if out.EstimatedCostUsd == nil || !almostEqual(*out.EstimatedCostUsd, 30.0) {
		t.Fatalf("EstimatedCostUsd = %v, want 30.0", out.EstimatedCostUsd)
	}
}

func TestPriceTokenUsage_DerivesTopModel(t *testing.T) {
	in := &common.TokenUsage{
		Ts: 123,
		Today: &common.TokenWindowUsage{
			ByModel: []*common.TokenModelUsage{
				{Model: "claude-3-5-sonnet", InputTokens: i64p(100)},
				{Model: "claude-opus-4-8", InputTokens: i64p(900)},
			},
		},
	}
	out := priceTokenUsage(in)
	if out.TopModel == nil || *out.TopModel != "claude-opus-4-8" {
		t.Fatalf("derived TopModel = %v, want claude-opus-4-8", out.TopModel)
	}
}

func TestPriceTokenUsage_PreservesProvidedTopModel(t *testing.T) {
	in := &common.TokenUsage{
		Ts:       123,
		TopModel: strp("gpt-4o"),
		Today: &common.TokenWindowUsage{
			ByModel: []*common.TokenModelUsage{{Model: "claude-opus-4-8", InputTokens: i64p(900)}},
		},
	}
	out := priceTokenUsage(in)
	if out.TopModel == nil || *out.TopModel != "gpt-4o" {
		t.Fatalf("TopModel = %v, want gpt-4o (preserved)", out.TopModel)
	}
}

func TestPriceTokenUsage_Nil(t *testing.T) {
	if priceTokenUsage(nil) != nil {
		t.Fatal("priceTokenUsage(nil) should be nil")
	}
}

func TestMergeSnapshots_TokensReplace(t *testing.T) {
	s := &StateService{}
	existing := &common.StatusSnapshot{
		Tokens: &common.TokenUsage{Ts: 1, TopModel: strp("old")},
	}
	newSnap := &common.StatusSnapshot{
		LastUpdateTs: 2,
		Tokens:       &common.TokenUsage{Ts: 2, TopModel: strp("new")},
	}
	merged := s.mergeSnapshots(existing, newSnap)
	if merged.Tokens == nil || merged.Tokens.TopModel == nil || *merged.Tokens.TopModel != "new" {
		t.Fatalf("merged tokens should be the new block, got %+v", merged.Tokens)
	}
}

func TestMergeSnapshots_TokensKeptWhenNewNil(t *testing.T) {
	s := &StateService{}
	existing := &common.StatusSnapshot{
		Tokens: &common.TokenUsage{Ts: 1, TopModel: strp("old")},
	}
	newSnap := &common.StatusSnapshot{LastUpdateTs: 2} // no tokens
	merged := s.mergeSnapshots(existing, newSnap)
	if merged.Tokens == nil || merged.Tokens.TopModel == nil || *merged.Tokens.TopModel != "old" {
		t.Fatalf("merged tokens should keep the old block, got %+v", merged.Tokens)
	}
}

// 关闭上报时客户端发「非 nil 但全零」块，应覆盖清空旧数据。
func TestMergeSnapshots_TokensClearedByZeroBlock(t *testing.T) {
	s := &StateService{}
	existing := &common.StatusSnapshot{
		Tokens: &common.TokenUsage{Ts: 1, TopModel: strp("old"), Today: &common.TokenWindowUsage{InputTokens: i64p(999)}},
	}
	zero := &common.TokenUsage{Ts: 2} // non-nil, empty windows
	newSnap := &common.StatusSnapshot{LastUpdateTs: 2, Tokens: zero}
	merged := s.mergeSnapshots(existing, newSnap)
	if merged.Tokens == nil {
		t.Fatal("merged tokens should be the zero block, got nil")
	}
	if merged.Tokens.Today != nil {
		t.Fatalf("zero block should have cleared Today, got %+v", merged.Tokens.Today)
	}
}
