package render

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	common "share-my-status/api/model/share_my_status/common"
	"share-my-status/domain/user"
	"share-my-status/pkg/dbutil"

	"gorm.io/gorm"
)

const (
	DefaultTemplate     = "正在听{artist}-{title}"
	DefaultPreviewTitle = "未在播放音乐"
	DefaultImageKey     = "img_v3_02e1_e30f851f-c7c1-4c58-8366-3494186fcbeg"
)

var (
	ErrSharingKeyNotFound   = errors.New("sharing key not found")
	ErrPublicAccessDisabled = errors.New("public access is disabled")
)

type Service struct {
	db          *gorm.DB
	userService *user.UserService
}

type PreviewResponse struct {
	Inline *Inline `json:"inline,omitempty"`
}

type Inline struct {
	Title     string            `json:"title,omitempty"`
	I18nTitle map[string]string `json:"i18n_title,omitempty"`
	ImageKey  string            `json:"image_key,omitempty"`
	URL       *URL              `json:"url,omitempty"`
}

type URL struct {
	CopyURL string `json:"copy_url,omitempty"`
	IOS     string `json:"ios,omitempty"`
	Android string `json:"android,omitempty"`
	PC      string `json:"pc,omitempty"`
	Web     string `json:"web,omitempty"`
}

func NewRenderService(db *gorm.DB, userService *user.UserService) *Service {
	return &Service{
		db:          db,
		userService: userService,
	}
}

func NewDefaultPreview() *PreviewResponse {
	return &PreviewResponse{
		Inline: &Inline{
			Title:    DefaultPreviewTitle,
			ImageKey: DefaultImageKey,
		},
	}
}

func (s *Service) RenderBySharingKey(ctx context.Context, sharingKey string, template string) (*PreviewResponse, error) {
	u, err := s.userService.GetUserBySharingKey(sharingKey)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrSharingKeyNotFound
		}
		return nil, fmt.Errorf("failed to get user by sharing key: %w", err)
	}

	return s.RenderByUserID(ctx, u.ID, template)
}

func (s *Service) RenderByUserID(ctx context.Context, userID uint64, template string) (*PreviewResponse, error) {
	publicEnabled, err := s.userService.IsPublicEnabled(userID)
	if err != nil {
		return nil, fmt.Errorf("failed to check public access: %w", err)
	}
	if !publicEnabled {
		return nil, ErrPublicAccessDisabled
	}

	currentState, err := dbutil.GetCurrentStateFromDB(ctx, s.db, userID)
	if err != nil {
		return nil, fmt.Errorf("failed to get current state: %w", err)
	}

	preview := NewDefaultPreview()
	preview.Inline.Title = RenderTemplate(normalizeTemplate(template), currentState)
	return preview, nil
}

func normalizeTemplate(template string) string {
	if template == "" {
		return DefaultTemplate
	}
	return template
}

func RenderTemplate(template string, state *common.StatusSnapshot) string {
	if state == nil {
		result := strings.ReplaceAll(template, "{artist}", "")
		result = strings.ReplaceAll(result, "{title}", "未在播放")
		result = strings.ReplaceAll(result, "{album}", "")
		result = strings.ReplaceAll(result, "{activityLabel}", "")
		result = renderTokenVariables(result, nil)
		result = renderTimeVariables(result)
		result = renderSystemVariables(result, nil)
		result = renderConditionalVariables(result, nil)
		return result
	}

	result := template
	result = renderMusicVariables(result, state.Music)
	result = renderSystemVariables(result, state.System)
	result = renderActivityVariables(result, state.Activity)
	result = renderTokenVariables(result, state.Tokens)
	result = renderTimeVariables(result)
	result = renderConditionalVariables(result, state.System)

	return result
}

func renderMusicVariables(template string, music *common.Music) string {
	result := template

	if music != nil {
		artist := ""
		title := ""
		album := ""

		if music.Artist != nil {
			artist = *music.Artist
		}
		if music.Title != nil {
			title = *music.Title
		}
		if music.Album != nil {
			album = *music.Album
		}

		result = strings.ReplaceAll(result, "{artist}", artist)
		result = strings.ReplaceAll(result, "{title}", title)
		result = strings.ReplaceAll(result, "{album}", album)
	} else {
		result = strings.ReplaceAll(result, "{artist}", "")
		result = strings.ReplaceAll(result, "{title}", "未在播放")
		result = strings.ReplaceAll(result, "{album}", "")
	}

	return result
}

func renderSystemVariables(template string, system *common.System) string {
	result := template

	if system != nil {
		if system.BatteryPct != nil {
			batteryPct := *system.BatteryPct
			result = strings.ReplaceAll(result, "{batteryPct}", fmt.Sprintf("%.2f", batteryPct))
			result = strings.ReplaceAll(result, "{batteryPctRounded}", fmt.Sprintf("%.0f%%", batteryPct*100))
		} else {
			result = strings.ReplaceAll(result, "{batteryPct}", "")
			result = strings.ReplaceAll(result, "{batteryPctRounded}", "")
		}

		if system.CpuPct != nil {
			cpuPct := *system.CpuPct
			result = strings.ReplaceAll(result, "{cpuPct}", fmt.Sprintf("%.2f", cpuPct))
			result = strings.ReplaceAll(result, "{cpuPctRounded}", fmt.Sprintf("%.0f%%", cpuPct*100))
		} else {
			result = strings.ReplaceAll(result, "{cpuPct}", "")
			result = strings.ReplaceAll(result, "{cpuPctRounded}", "")
		}

		if system.MemoryPct != nil {
			memoryPct := *system.MemoryPct
			result = strings.ReplaceAll(result, "{memoryPct}", fmt.Sprintf("%.2f", memoryPct))
			result = strings.ReplaceAll(result, "{memoryPctRounded}", fmt.Sprintf("%.0f%%", memoryPct*100))
		} else {
			result = strings.ReplaceAll(result, "{memoryPct}", "")
			result = strings.ReplaceAll(result, "{memoryPctRounded}", "")
		}
	} else {
		result = strings.ReplaceAll(result, "{batteryPct}", "")
		result = strings.ReplaceAll(result, "{batteryPctRounded}", "")
		result = strings.ReplaceAll(result, "{cpuPct}", "")
		result = strings.ReplaceAll(result, "{cpuPctRounded}", "")
		result = strings.ReplaceAll(result, "{memoryPct}", "")
		result = strings.ReplaceAll(result, "{memoryPctRounded}", "")
	}

	return result
}

func renderActivityVariables(template string, activity *common.Activity) string {
	result := template

	if activity != nil && activity.Label != "" {
		result = strings.ReplaceAll(result, "{activityLabel}", activity.Label)
	} else {
		result = strings.ReplaceAll(result, "{activityLabel}", "")
	}

	return result
}

// renderTokenVariables 替换所有 token 相关占位符。
// tokens 为 nil（无数据/未上报/已清空）时，数值渲染为 0、人类可读为 0、成本为 $0.00、topModel 为空。
func renderTokenVariables(template string, tokens *common.TokenUsage) string {
	result := template

	var today, last7d, total *common.TokenWindowUsage
	topModel := ""
	var sessionCount int64
	var windowDays int32
	if tokens != nil {
		today = tokens.Today
		last7d = tokens.Last7d
		total = tokens.Total
		if tokens.TopModel != nil {
			topModel = *tokens.TopModel
		}
		if tokens.SessionCount != nil {
			sessionCount = *tokens.SessionCount
		}
		if tokens.WindowDays != nil {
			windowDays = *tokens.WindowDays
		}
	}

	// 当日
	result = strings.ReplaceAll(result, "{tokensToday}", strconv.FormatInt(windowTotalTokens(today), 10))
	result = strings.ReplaceAll(result, "{tokensTodayH}", formatTokensHuman(windowTotalTokens(today)))
	result = strings.ReplaceAll(result, "{tokenCostToday}", formatCostUsd(windowCostUsd(today)))
	result = strings.ReplaceAll(result, "{tokenInToday}", strconv.FormatInt(windowField(today, fieldInput), 10))
	result = strings.ReplaceAll(result, "{tokenOutToday}", strconv.FormatInt(windowField(today, fieldOutput), 10))
	result = strings.ReplaceAll(result, "{tokenCacheToday}", strconv.FormatInt(windowField(today, fieldCached), 10))
	result = strings.ReplaceAll(result, "{tokenReasonToday}", strconv.FormatInt(windowField(today, fieldReasoning), 10))

	// 近 7 天
	result = strings.ReplaceAll(result, "{tokens7d}", strconv.FormatInt(windowTotalTokens(last7d), 10))
	result = strings.ReplaceAll(result, "{tokens7dH}", formatTokensHuman(windowTotalTokens(last7d)))
	result = strings.ReplaceAll(result, "{tokenCost7d}", formatCostUsd(windowCostUsd(last7d)))

	// 总窗口
	result = strings.ReplaceAll(result, "{tokensTotal}", strconv.FormatInt(windowTotalTokens(total), 10))
	result = strings.ReplaceAll(result, "{tokensTotalH}", formatTokensHuman(windowTotalTokens(total)))
	result = strings.ReplaceAll(result, "{tokenCostTotal}", formatCostUsd(windowCostUsd(total)))

	// 其他
	result = strings.ReplaceAll(result, "{topModel}", topModel)
	result = strings.ReplaceAll(result, "{tokenSessions}", strconv.FormatInt(sessionCount, 10))
	result = strings.ReplaceAll(result, "{tokenWindowDays}", strconv.FormatInt(int64(windowDays), 10))

	return result
}

type tokenField int

const (
	fieldInput tokenField = iota
	fieldOutput
	fieldCached
	fieldReasoning
)

func windowField(w *common.TokenWindowUsage, f tokenField) int64 {
	if w == nil {
		return 0
	}
	switch f {
	case fieldInput:
		return derefInt64(w.InputTokens)
	case fieldOutput:
		return derefInt64(w.OutputTokens)
	case fieldCached:
		return derefInt64(w.CachedInputTokens)
	case fieldReasoning:
		return derefInt64(w.ReasoningOutputTokens)
	default:
		return 0
	}
}

// windowTotalTokens 返回窗口总 token 数：优先用服务端写入的 TotalTokens，否则按四项求和。
func windowTotalTokens(w *common.TokenWindowUsage) int64 {
	if w == nil {
		return 0
	}
	if w.TotalTokens != nil {
		return *w.TotalTokens
	}
	return derefInt64(w.InputTokens) + derefInt64(w.OutputTokens) +
		derefInt64(w.CachedInputTokens) + derefInt64(w.ReasoningOutputTokens)
}

func windowCostUsd(w *common.TokenWindowUsage) float64 {
	if w == nil || w.EstimatedCostUsd == nil {
		return 0
	}
	return *w.EstimatedCostUsd
}

func derefInt64(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

// formatTokensHuman 把 token 数格式化为紧凑可读形式：1234567 -> "1.2M"，末尾 ".0" 去除。
func formatTokensHuman(n int64) string {
	neg := ""
	if n < 0 {
		neg = "-"
		n = -n
	}
	switch {
	case n >= 1_000_000_000:
		return neg + trimDotZero(fmt.Sprintf("%.1f", float64(n)/1e9)) + "B"
	case n >= 1_000_000:
		return neg + trimDotZero(fmt.Sprintf("%.1f", float64(n)/1e6)) + "M"
	case n >= 1_000:
		return neg + trimDotZero(fmt.Sprintf("%.1f", float64(n)/1e3)) + "K"
	default:
		return neg + strconv.FormatInt(n, 10)
	}
}

func trimDotZero(s string) string {
	return strings.TrimSuffix(s, ".0")
}

func formatCostUsd(c float64) string {
	return fmt.Sprintf("$%.2f", c)
}

func renderTimeVariables(template string) string {
	result := template
	now := time.Now()

	result = strings.ReplaceAll(result, "{nowLocal}", now.Format("2006-01-02 15:04:05"))
	result = strings.ReplaceAll(result, "{dateYMD}", now.Format("2006-01-02"))
	result = strings.ReplaceAll(result, "{nowISO}", now.Format(time.RFC3339))

	return result
}

func renderConditionalVariables(template string, system *common.System) string {
	result := template

	charging := false
	if system != nil && system.Charging != nil {
		charging = *system.Charging
	}

	return chargingTernaryExpression.ReplaceAllStringFunc(result, func(match string) string {
		parts := chargingTernaryExpression.FindStringSubmatch(match)
		if len(parts) != 4 || parts[1] != "charging" {
			return match
		}
		if charging {
			return parts[2]
		}
		return parts[3]
	})
}
