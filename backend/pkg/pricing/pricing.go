// Package pricing estimates the USD cost of AI-model token usage.
//
// 价格为「每 100 万 token 的美元单价」，取自各家公开定价（近似值，仅用于估算）。
// 未识别的模型回退到 sonnet 档位。该映射是 token 成本的唯一可信来源（服务端计算），
// 这样调价时无需发布客户端。
package pricing

import "strings"

// Price 表示某一模型档位每 100 万 token 的美元单价。
// 五档与 kaboo 的 model_pricing 列对齐：input / output / cache_read / cache_creation / reasoning。
type Price struct {
	Input         float64
	Output        float64
	CachedInput   float64 // cache 读取（cache_read）
	CacheCreation float64 // cache 写入（cache_creation）。OpenAI/Gemini 无此档 = 0；Anthropic = 1.25× input
	Reasoning     float64
}

// FallbackFamily 是无法识别模型时使用的档位。
const FallbackFamily = "unknown"

// tokensPerUnit 是定价单位（每 100 万 token）。
const tokensPerUnit = 1_000_000.0

// familyPrices 按档位给出单价（USD / 1M tokens），对齐 kaboo 2026 定价
// (migration 000034_seed_2026_model_prices)。Anthropic 的 cache_creation = 1.25× input；
// OpenAI/Gemini 无 cache-write 档（= 0）。
var familyPrices = map[string]Price{
	"claude-opus":   {Input: 5, Output: 25, CachedInput: 0.5, CacheCreation: 6.25, Reasoning: 25},
	"claude-sonnet": {Input: 3, Output: 15, CachedInput: 0.30, CacheCreation: 3.75, Reasoning: 15},
	"claude-haiku":  {Input: 1, Output: 5, CachedInput: 0.10, CacheCreation: 1.25, Reasoning: 5},
	"gpt-5":         {Input: 1.25, Output: 10, CachedInput: 0.125, Reasoning: 10},
	"gpt-5-mini":    {Input: 0.25, Output: 2, CachedInput: 0.025, Reasoning: 2},
	"gpt-5-nano":    {Input: 0.05, Output: 0.40, CachedInput: 0.005, Reasoning: 0.40},
	"gpt-5-3":       {Input: 1.75, Output: 14, CachedInput: 0.175, Reasoning: 14}, // gpt-5.2 / 5.3
	"gpt-5-4":       {Input: 2.5, Output: 15, CachedInput: 0.25, Reasoning: 15},   // gpt-5.4（Codex 当前默认）
	"gpt-5-5":       {Input: 5, Output: 30, CachedInput: 0.5, Reasoning: 30},      // gpt-5.5
	"gpt-4o":        {Input: 2.5, Output: 10, CachedInput: 0, Reasoning: 0},
	"gpt-4o-mini":   {Input: 0.15, Output: 0.60, CachedInput: 0, Reasoning: 0},
	"o-series":      {Input: 15, Output: 60, CachedInput: 0, Reasoning: 60},
	"o-series-mini": {Input: 1.1, Output: 4.4, CachedInput: 0, Reasoning: 4.4},
	"gemini-pro":    {Input: 2, Output: 12, CachedInput: 0.20, Reasoning: 0},   // Gemini 3 Pro
	"gemini-flash":  {Input: 0.5, Output: 3, CachedInput: 0.05, Reasoning: 0},  // Gemini 3 Flash
	FallbackFamily:  {Input: 3, Output: 15, CachedInput: 0.30, CacheCreation: 3.75, Reasoning: 15},
}

// DetectFamily 把原始模型名映射到定价档位。
// 顺序很重要：先判断更具体的型号（如 gpt-4o-mini、gpt-4o）再判断 o 系列，
// 避免 "gpt-4o" 被误判为 o1/o3 系列。
func DetectFamily(model string) string {
	m := strings.ToLower(strings.TrimSpace(model))
	switch {
	case m == "":
		return FallbackFamily
	case strings.Contains(m, "opus"):
		return "claude-opus"
	case strings.Contains(m, "sonnet"):
		return "claude-sonnet"
	case strings.Contains(m, "haiku"):
		return "claude-haiku"
	case strings.Contains(m, "gemini"):
		if strings.Contains(m, "flash") {
			return "gemini-flash"
		}
		return "gemini-pro"
	case strings.Contains(m, "gpt-5"), strings.Contains(m, "gpt5"):
		// GPT-5 系列(Codex 默认模型族)。按 kaboo 2026 定价区分小版本;
		// 基档(gpt-5 / 5.1 / -codex)= 1.25/10。
		switch {
		case strings.Contains(m, "nano"):
			return "gpt-5-nano"
		case strings.Contains(m, "mini"):
			return "gpt-5-mini"
		case strings.Contains(m, "5.5"), strings.Contains(m, "5-5"):
			return "gpt-5-5"
		case strings.Contains(m, "5.4"), strings.Contains(m, "5-4"):
			return "gpt-5-4"
		case strings.Contains(m, "5.3"), strings.Contains(m, "5-3"),
			strings.Contains(m, "5.2"), strings.Contains(m, "5-2"):
			return "gpt-5-3"
		default:
			return "gpt-5"
		}
	case strings.Contains(m, "4o-mini"), strings.Contains(m, "4o mini"),
		strings.Contains(m, "gpt-4") && strings.Contains(m, "mini"),
		strings.Contains(m, "gpt-4") && strings.Contains(m, "nano"):
		// 含 mini/nano 的 GPT-4 系列（如 gpt-4o-mini、gpt-4.1-mini、gpt-4.1-nano）走 mini 档位。
		return "gpt-4o-mini"
	case strings.Contains(m, "4o"), strings.Contains(m, "gpt-4"), strings.Contains(m, "gpt4"):
		return "gpt-4o"
	case strings.Contains(m, "o1"), strings.Contains(m, "o3"), strings.Contains(m, "o4"):
		// o 系列推理模型；mini 版（o1-mini/o3-mini/o4-mini）单独走更便宜的档位。
		if strings.Contains(m, "mini") {
			return "o-series-mini"
		}
		return "o-series"
	default:
		return FallbackFamily
	}
}

// PriceForModel 返回模型对应档位的单价（未识别则回退）。
func PriceForModel(model string) Price {
	if p, ok := familyPrices[DetectFamily(model)]; ok {
		return p
	}
	return familyPrices[FallbackFamily]
}

// EstimateCostUsd 估算某模型在给定 token 数下的美元成本。
func EstimateCostUsd(model string, input, output, cachedInput, cacheCreation, reasoning int64) float64 {
	p := PriceForModel(model)
	return float64(input)/tokensPerUnit*p.Input +
		float64(output)/tokensPerUnit*p.Output +
		float64(cachedInput)/tokensPerUnit*p.CachedInput +
		float64(cacheCreation)/tokensPerUnit*p.CacheCreation +
		float64(reasoning)/tokensPerUnit*p.Reasoning
}
