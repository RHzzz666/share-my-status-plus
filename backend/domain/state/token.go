package state

import (
	common "share-my-status/api/model/share_my_status/common"
	"share-my-status/pkg/pricing"
)

// priceTokenUsage 对客户端上报的 token 用量块做服务端计算：
//   - 每个窗口填充 totalTokens（五项之和）与 estimatedCostUsd（按 byModel 逐模型定价）
//   - 若 topModel 为空，则从当日（或总窗口）的 byModel 推导
//
// 返回新的块（不修改入参）。入参为 nil 时返回 nil。
func priceTokenUsage(in *common.TokenUsage) *common.TokenUsage {
	if in == nil {
		return nil
	}

	out := &common.TokenUsage{
		Ts:           in.Ts,
		TopModel:     in.TopModel,
		SessionCount: in.SessionCount,
		WindowDays:   in.WindowDays,
		Today:        priceWindow(in.Today),
		Last7d:       priceWindow(in.Last7d),
		Total:        priceWindow(in.Total),
	}

	// 服务端兜底推导 topModel：优先当日，其次总窗口。
	if out.TopModel == nil || *out.TopModel == "" {
		tm := topModelOfWindow(in.Today)
		if tm == "" {
			tm = topModelOfWindow(in.Total)
		}
		if tm != "" {
			out.TopModel = &tm
		}
	}

	return out
}

// priceWindow 填充单个窗口的聚合计数、totalTokens 与 estimatedCostUsd。
//
// 为保证「展示的 token 数」与「成本」始终一致，对每个聚合计数采用「显式优先、否则按
// byModel 求和」的对账策略：客户端既可只发聚合数、也可只发 byModel、或两者都发——
// 服务端都会得到自洽的结果（避免出现「0 token 却有 $30 成本」）。
func priceWindow(w *common.TokenWindowUsage) *common.TokenWindowUsage {
	if w == nil {
		return nil
	}

	// byModel 各项求和（用于回填缺失的聚合计数）。
	var bmIn, bmOut, bmCached, bmCacheCreation, bmReason int64
	for _, m := range w.ByModel {
		if m == nil {
			continue
		}
		bmIn += derefI64(m.InputTokens)
		bmOut += derefI64(m.OutputTokens)
		bmCached += derefI64(m.CachedInputTokens)
		bmCacheCreation += derefI64(m.CacheCreationInputTokens)
		bmReason += derefI64(m.ReasoningOutputTokens)
	}

	// 对每个聚合计数钳制 ≥0：客户端异常或时间倒退可能上报负值，
	// 与 kaboo 的负值防护对齐，避免污染 totalTokens 与成本。
	in := clampNonNeg(pickAggregate(w.InputTokens, bmIn))
	outTok := clampNonNeg(pickAggregate(w.OutputTokens, bmOut))
	cached := clampNonNeg(pickAggregate(w.CachedInputTokens, bmCached))
	cacheCreation := clampNonNeg(pickAggregate(w.CacheCreationInputTokens, bmCacheCreation))
	reason := clampNonNeg(pickAggregate(w.ReasoningOutputTokens, bmReason))
	total := in + outTok + cached + cacheCreation + reason

	out := &common.TokenWindowUsage{
		InputTokens:              &in,
		OutputTokens:             &outTok,
		CachedInputTokens:        &cached,
		CacheCreationInputTokens: &cacheCreation,
		ReasoningOutputTokens:    &reason,
		TotalTokens:              &total,
		ByModel:                  w.ByModel,
	}

	var cost float64
	if len(w.ByModel) > 0 {
		// 优先按模型逐项定价（精确）。
		for _, m := range w.ByModel {
			if m == nil {
				continue
			}
			cost += pricing.EstimateCostUsd(
				m.Model,
				derefI64(m.InputTokens), derefI64(m.OutputTokens),
				derefI64(m.CachedInputTokens), derefI64(m.CacheCreationInputTokens),
				derefI64(m.ReasoningOutputTokens),
			)
		}
	} else {
		// 没有逐模型明细时，按未知档位对聚合数定价。
		cost = pricing.EstimateCostUsd("", in, outTok, cached, cacheCreation, reason)
	}
	out.EstimatedCostUsd = &cost

	return out
}

// pickAggregate 返回显式聚合值（非 nil 时），否则返回按 byModel 求得的和。
func pickAggregate(explicit *int64, byModelSum int64) int64 {
	if explicit != nil {
		return *explicit
	}
	return byModelSum
}

// topModelOfWindow 返回窗口内总 token 数最高的模型名（无则空串）。
// 跳过零用量条目（如 claude-code 的 "<synthetic>" 错误占位记录）与合成的 "other"
// 折叠项，与客户端 maxModel 的过滤口径一致。
func topModelOfWindow(w *common.TokenWindowUsage) string {
	if w == nil || len(w.ByModel) == 0 {
		return ""
	}
	best := ""
	var bestTotal int64
	for _, m := range w.ByModel {
		if m == nil || m.Model == "other" {
			continue
		}
		t := derefI64(m.InputTokens) + derefI64(m.OutputTokens) +
			derefI64(m.CachedInputTokens) + derefI64(m.CacheCreationInputTokens) +
			derefI64(m.ReasoningOutputTokens)
		if t > bestTotal {
			bestTotal = t
			best = m.Model
		}
	}
	return best
}

func derefI64(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

// clampNonNeg 将负数钳制为 0（防御客户端上报的异常负值）。
func clampNonNeg(v int64) int64 {
	if v < 0 {
		return 0
	}
	return v
}
