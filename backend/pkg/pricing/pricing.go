// Package pricing estimates the USD cost of AI-model token usage.
//
// 价格为「每 100 万 token 的美元单价」，取自各家公开定价（近似值，仅用于估算）。
// 未识别的模型回退到 sonnet 档位。该映射是 token 成本的唯一可信来源（服务端计算），
// 这样调价时无需发布客户端。
package pricing

import "strings"

// Price 表示某一模型档位每 100 万 token 的美元单价。
type Price struct {
	Input       float64
	Output      float64
	CachedInput float64
	Reasoning   float64
}

// FallbackFamily 是无法识别模型时使用的档位。
const FallbackFamily = "unknown"

// tokensPerUnit 是定价单位（每 100 万 token）。
const tokensPerUnit = 1_000_000.0

// familyPrices 按档位给出单价（USD / 1M tokens）。
var familyPrices = map[string]Price{
	"claude-opus":   {Input: 15, Output: 75, CachedInput: 1.5, Reasoning: 75},
	"claude-sonnet": {Input: 3, Output: 15, CachedInput: 0.30, Reasoning: 15},
	"claude-haiku":  {Input: 0.80, Output: 4, CachedInput: 0.08, Reasoning: 4},
	"gpt-4o":        {Input: 2.5, Output: 10, CachedInput: 1.25, Reasoning: 10},
	"gpt-4o-mini":   {Input: 0.15, Output: 0.60, CachedInput: 0.075, Reasoning: 0.60},
	"o-series":      {Input: 15, Output: 60, CachedInput: 7.5, Reasoning: 60},
	"o-series-mini": {Input: 1.1, Output: 4.4, CachedInput: 0.55, Reasoning: 4.4},
	"gemini-pro":    {Input: 1.25, Output: 5, CachedInput: 0.3125, Reasoning: 5},
	"gemini-flash":  {Input: 0.075, Output: 0.30, CachedInput: 0.01875, Reasoning: 0.30},
	FallbackFamily:  {Input: 3, Output: 15, CachedInput: 0.30, Reasoning: 15},
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
func EstimateCostUsd(model string, input, output, cachedInput, reasoning int64) float64 {
	p := PriceForModel(model)
	return float64(input)/tokensPerUnit*p.Input +
		float64(output)/tokensPerUnit*p.Output +
		float64(cachedInput)/tokensPerUnit*p.CachedInput +
		float64(reasoning)/tokensPerUnit*p.Reasoning
}
