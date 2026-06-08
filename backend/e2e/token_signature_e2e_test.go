//go:build e2e

// Package e2e contains end-to-end integration tests that require a live
// Postgres (E2E_DB_DSN) and optional Redis (E2E_REDIS_ADDR). They are excluded
// from normal `go test ./...` via the `e2e` build tag.
//
// Run:
//
//	E2E_DB_DSN="host=localhost user=postgres password=postgres dbname=smsp port=55432 sslmode=disable TimeZone=Asia/Shanghai" \
//	E2E_REDIS_ADDR="localhost:56379" \
//	go test -tags e2e ./e2e/ -run TestTokenSignature -v
package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	common "share-my-status/api/model/share_my_status/common"
	"share-my-status/domain/render"
	"share-my-status/domain/state"
	"share-my-status/domain/user"
	"share-my-status/model"

	"github.com/redis/go-redis/v9"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

// openE2E is shared setup: returns a migrated DB + optional redis, skipping if no DSN.
func openE2E(t *testing.T) (*gorm.DB, *redis.Client) {
	t.Helper()
	dsn := os.Getenv("E2E_DB_DSN")
	if dsn == "" {
		t.Skip("E2E_DB_DSN not set; skipping e2e (needs live Postgres)")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := model.CreateTables(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	var rdb *redis.Client
	if addr := os.Getenv("E2E_REDIS_ADDR"); addr != "" {
		rdb = redis.NewClient(&redis.Options{Addr: addr})
	}
	return db, rdb
}

// TestTokenSignatureE2E_FromWireJSON feeds the EXACT JSON the macOS Swift client emits
// (camelCase keys, server-computed fields omitted) through the Go consumer to prove the
// cross-language wire contract: json.Unmarshal -> common.ReportEvent -> price -> render.
func TestTokenSignatureE2E_FromWireJSON(t *testing.T) {
	ctx := context.Background()
	db, rdb := openE2E(t)

	userSvc := user.NewUserService(db, rdb)
	u, err := userSvc.CreateUser(fmt.Sprintf("e2e-wire-%d", time.Now().UnixNano()))
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	stateSvc := state.NewStateService(db, rdb, nil, userSvc)

	// This is exactly what the Swift TokenUsageDTO/ReportEvent serialize to:
	// per-window counters + byModel; NO totalTokens / estimatedCostUsd (server-computed).
	wire := `{
	  "version": "1",
	  "tokens": {
	    "today": {
	      "inputTokens": 1000000,
	      "outputTokens": 200000,
	      "byModel": [
	        {"model":"claude-opus-4-8","inputTokens":1000000,"outputTokens":200000}
	      ]
	    },
	    "topModel": "claude-opus-4-8",
	    "sessionCount": 7,
	    "windowDays": 30,
	    "ts": 1733000000000
	  }
	}`

	var event common.ReportEvent
	if err := json.Unmarshal([]byte(wire), &event); err != nil {
		t.Fatalf("unmarshal wire JSON into common.ReportEvent: %v", err)
	}
	if event.Tokens == nil || event.Tokens.Today == nil || len(event.Tokens.Today.ByModel) != 1 {
		t.Fatalf("wire JSON did not decode into the expected token structure: %+v", event.Tokens)
	}

	if _, err := stateSvc.BatchReport(ctx, u.ID, []*common.ReportEvent{&event}); err != nil {
		t.Fatalf("batch report: %v", err)
	}

	renderSvc := render.NewRenderService(db, userSvc)
	title, err := renderSvc.RenderBySharingKey(ctx, u.SharingKey,
		"今日 {tokensTodayH} 花费{tokenCostToday} 模型{topModel} 会话{tokenSessions}")
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	got := title.Inline.Title
	t.Logf("rendered from wire JSON: %s", got)
	want := "今日 1.2M 花费$30.00 模型claude-opus-4-8 会话7"
	if got != want {
		t.Errorf("wire-JSON render = %q, want %q", got, want)
	}
}

func i64p(v int64) *int64 { return &v }
func i32p(v int32) *int32 { return &v }

// TestTokenSignatureE2E proves the full token→signature chain through a real DB:
// client reports a Tokens block → backend prices & stores it in current_state.snapshot
// (jsonb round-trip) → render substitutes the {token...} variables for the Feishu signature.
func TestTokenSignatureE2E(t *testing.T) {
	dsn := os.Getenv("E2E_DB_DSN")
	if dsn == "" {
		t.Skip("E2E_DB_DSN not set; skipping e2e (needs live Postgres)")
	}
	ctx := context.Background()

	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	if err := model.CreateTables(db); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	var rdb *redis.Client
	if addr := os.Getenv("E2E_REDIS_ADDR"); addr != "" {
		rdb = redis.NewClient(&redis.Options{Addr: addr})
	}

	userSvc := user.NewUserService(db, rdb)
	openID := fmt.Sprintf("e2e-%d", time.Now().UnixNano())
	u, err := userSvc.CreateUser(openID)
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	t.Logf("created user id=%d sharingKey=%s", u.ID, u.SharingKey)

	stateSvc := state.NewStateService(db, rdb, nil, userSvc)

	// Client reports raw per-model counts; backend computes totals + cost.
	event := &common.ReportEvent{
		Version: "1",
		Tokens: &common.TokenUsage{
			Ts:           time.Now().UnixMilli(),
			SessionCount: i64p(7),
			WindowDays:   i32p(30),
			Today: &common.TokenWindowUsage{
				InputTokens:  i64p(1_000_000),
				OutputTokens: i64p(200_000),
				ByModel: []*common.TokenModelUsage{
					{Model: "claude-opus-4-8", InputTokens: i64p(1_000_000), OutputTokens: i64p(200_000)},
				},
			},
			Total: &common.TokenWindowUsage{
				InputTokens:  i64p(5_000_000),
				OutputTokens: i64p(1_000_000),
				ByModel: []*common.TokenModelUsage{
					{Model: "claude-opus-4-8", InputTokens: i64p(5_000_000), OutputTokens: i64p(1_000_000)},
				},
			},
		},
	}
	if _, err := stateSvc.BatchReport(ctx, u.ID, []*common.ReportEvent{event}); err != nil {
		t.Fatalf("batch report: %v", err)
	}

	renderSvc := render.NewRenderService(db, userSvc)
	tpl := "今日 {tokensTodayH}({tokensToday}) 花费{tokenCostToday} | 模型{topModel} | 总 {tokensTotalH} 花费{tokenCostTotal} | 会话{tokenSessions}"
	resp, err := renderSvc.RenderBySharingKey(ctx, u.SharingKey, tpl)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	title := resp.Inline.Title
	t.Logf("rendered signature: %s", title)

	// Expectations:
	//  today total = 1.0M + 0.2M = 1.2M tokens; cost(opus) = 1M*15 + 0.2M*75 = 15 + 15 = $30.00
	//  total       = 5.0M + 1.0M = 6M tokens;  cost(opus) = 5M*15 + 1M*75 = 75 + 75 = $150.00
	//  topModel derived server-side from byModel.
	wantContains := []string{
		"今日 1.2M(1200000)",
		"花费$30.00",
		"模型claude-opus-4-8",
		"总 6M",
		"花费$150.00",
		"会话7",
	}
	for _, w := range wantContains {
		if !strings.Contains(title, w) {
			t.Errorf("signature missing %q\nfull: %s", w, title)
		}
	}

	// Re-render with the default music template to prove non-token rendering still works
	// even when a Tokens block is stored.
	musicResp, err := renderSvc.RenderBySharingKey(ctx, u.SharingKey, render.DefaultTemplate)
	if err != nil {
		t.Fatalf("render default: %v", err)
	}
	if strings.Contains(musicResp.Inline.Title, "{") {
		t.Errorf("default template left unsubstituted placeholders: %s", musicResp.Inline.Title)
	}

	// --- Disable path: a zeroed Tokens block clears the signature numbers ---
	clearEvent := &common.ReportEvent{
		Version: "1",
		Tokens:  &common.TokenUsage{Ts: time.Now().UnixMilli()}, // non-nil, empty windows
	}
	if _, err := stateSvc.BatchReport(ctx, u.ID, []*common.ReportEvent{clearEvent}); err != nil {
		t.Fatalf("batch report (clear): %v", err)
	}
	clearedResp, err := renderSvc.RenderBySharingKey(ctx, u.SharingKey, "今日 {tokensTodayH} 花费{tokenCostToday}")
	if err != nil {
		t.Fatalf("render after clear: %v", err)
	}
	if got, want := clearedResp.Inline.Title, "今日 0 花费$0.00"; got != want {
		t.Errorf("after clear = %q, want %q", got, want)
	}
}
