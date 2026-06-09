package pricing

import (
	"math"
	"testing"
)

func TestDetectFamily(t *testing.T) {
	cases := map[string]string{
		"":                       FallbackFamily,
		"claude-opus-4-8":        "claude-opus",
		"claude-3-5-sonnet":      "claude-sonnet",
		"claude-sonnet-4-6":      "claude-sonnet",
		"claude-3-5-haiku":       "claude-haiku",
		"gpt-4o":                 "gpt-4o",
		"gpt-4o-2024-08-06":      "gpt-4o",
		"gpt-4o-mini":            "gpt-4o-mini",
		"gpt-5":                  "gpt-5",
		"gpt-5-codex":            "gpt-5",
		"gpt-5.1-codex":          "gpt-5",
		"gpt-5-mini":             "gpt-5-mini",
		"gpt-5-nano":             "gpt-5-mini",
		"gpt-4.1":                "gpt-4o",
		"gpt-4.1-mini":           "gpt-4o-mini",
		"gpt-4.1-nano":           "gpt-4o-mini",
		"chatgpt-4o-latest":      "gpt-4o",
		"o1-preview":             "o-series",
		"o1-mini":                "o-series-mini",
		"o3-mini":                "o-series-mini",
		"o4-mini":                "o-series-mini",
		"gemini-2.5-pro":         "gemini-pro",
		"gemini-2.0-flash":       "gemini-flash",
		"gemini-1.5-flash-8b":    "gemini-flash",
		"some-unknown-model-xyz": FallbackFamily,
	}
	for model, want := range cases {
		if got := DetectFamily(model); got != want {
			t.Errorf("DetectFamily(%q) = %q, want %q", model, got, want)
		}
	}
}

// 关键回归：gpt-4o 不能被误判为 o 系列。
func TestDetectFamily_GPT4oNotOSeries(t *testing.T) {
	if got := DetectFamily("gpt-4o"); got != "gpt-4o" {
		t.Fatalf("gpt-4o misclassified as %q", got)
	}
}

func almostEqual(a, b float64) bool {
	return math.Abs(a-b) < 1e-9
}

func TestEstimateCostUsd(t *testing.T) {
	// sonnet: 3 / 15 / 0.30 / 15 per 1M
	if c := EstimateCostUsd("claude-sonnet-4-6", 1_000_000, 0, 0, 0); !almostEqual(c, 3.0) {
		t.Errorf("sonnet 1M input = %v, want 3.0", c)
	}
	if c := EstimateCostUsd("claude-sonnet-4-6", 0, 1_000_000, 0, 0); !almostEqual(c, 15.0) {
		t.Errorf("sonnet 1M output = %v, want 15.0", c)
	}
	if c := EstimateCostUsd("claude-sonnet-4-6", 0, 0, 1_000_000, 0); !almostEqual(c, 0.30) {
		t.Errorf("sonnet 1M cached = %v, want 0.30", c)
	}
	if c := EstimateCostUsd("claude-sonnet-4-6", 0, 0, 0, 1_000_000); !almostEqual(c, 15.0) {
		t.Errorf("sonnet 1M reasoning = %v, want 15.0", c)
	}
	// opus combined: 0.5M in*15 + 0.2M out*75 = 7.5 + 15 = 22.5
	if c := EstimateCostUsd("claude-opus-4-8", 500_000, 200_000, 0, 0); !almostEqual(c, 22.5) {
		t.Errorf("opus combined = %v, want 22.5", c)
	}
	// unknown model falls back to sonnet pricing
	if c := EstimateCostUsd("totally-unknown", 1_000_000, 0, 0, 0); !almostEqual(c, 3.0) {
		t.Errorf("unknown fallback 1M input = %v, want 3.0 (sonnet)", c)
	}
	// gpt-4.1-mini uses the mini tier (0.15 in), not the full gpt-4o tier (2.5)
	if c := EstimateCostUsd("gpt-4.1-mini", 1_000_000, 0, 0, 0); !almostEqual(c, 0.15) {
		t.Errorf("gpt-4.1-mini 1M input = %v, want 0.15 (mini tier)", c)
	}
	// o3-mini uses the o-series-mini tier (1.1 in), not full o1 (15)
	if c := EstimateCostUsd("o3-mini", 1_000_000, 0, 0, 0); !almostEqual(c, 1.1) {
		t.Errorf("o3-mini 1M input = %v, want 1.1 (o-series-mini)", c)
	}
	// gpt-5-codex (Codex's default family) uses the gpt-5 tier (1.25 in), not the sonnet fallback (3)
	if c := EstimateCostUsd("gpt-5-codex", 1_000_000, 0, 0, 0); !almostEqual(c, 1.25) {
		t.Errorf("gpt-5-codex 1M input = %v, want 1.25 (gpt-5 tier)", c)
	}
	// zero tokens => zero cost
	if c := EstimateCostUsd("claude-opus-4-8", 0, 0, 0, 0); !almostEqual(c, 0) {
		t.Errorf("zero tokens = %v, want 0", c)
	}
}
