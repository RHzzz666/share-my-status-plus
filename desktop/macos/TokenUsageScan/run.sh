#!/bin/bash
# Test the AI-token feature against YOUR real local logs.
#
#   bash run.sh          # scan your logs + print your token numbers (no backend)
#   bash run.sh --live   # also: spin up backend+Postgres+Redis, POST, render the
#                        # Feishu signature (with server-computed cost), then tear down.
#                        # Needs: docker, go. Uses port 18080 + 55432 + 56379.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$HERE/../share-my-status-client"
ROOT="$(cd "$HERE/../../.." && pwd)"        # repo root
OUT=/tmp/sms-tokenscan
mkdir -p "$OUT"

echo "==> Compiling scan tool (real client parser sources)…"
swiftc -O \
  "$C/Models/Domain/TokenModels.swift" \
  "$C/Models/API/StateModels.swift" \
  "$C/Models/API/APIModels.swift" \
  "$C/Services/TokenParsers/TokenLogParser.swift" \
  "$C/Services/TokenParsers/ClaudeCodeParser.swift" \
  "$C/Services/TokenParsers/CodexParser.swift" \
  "$C/Services/TokenParsers/GeminiParser.swift" \
  "$C/Services/TokenParsers/ClaudeAppParser.swift" \
  "$C/Services/TokenParsers/OpenClawParser.swift" \
  "$C/Services/TokenParsers/TraeParser.swift" \
  "$C/Services/TokenParsers/TraeXParser.swift" \
  "$HERE/main.swift" -lsqlite3 -o "$OUT/scan" || { echo "compile failed"; exit 1; }

echo "==> Scanning your real local logs…"
"$OUT/scan" > "$OUT/report.json"
echo "==> Wire JSON: $OUT/report.json ($(wc -c < "$OUT/report.json" | tr -d ' ') bytes)"

[ "${1:-}" = "--live" ] || { echo "Done (scan only). Re-run with --live for cost + the rendered signature."; exit 0; }

# ---------- live mode: backend + DB + POST + render ----------
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"   # backend deps are public; change if you have a working mirror
PG=sms-tokentest-pg; RD=sms-tokentest-redis
cleanup(){ echo "==> teardown"; pkill -f "$OUT/backend" 2>/dev/null||true; docker rm -f "$PG" "$RD" >/dev/null 2>&1||true; }
trap cleanup EXIT

echo "==> Starting Postgres + Redis…"
docker rm -f "$PG" "$RD" >/dev/null 2>&1||true
docker run -d --name "$PG" -e POSTGRES_PASSWORD=postgres -e POSTGRES_USER=postgres -e POSTGRES_DB=smsp -p 55432:5432 postgres:16-alpine >/dev/null
docker run -d --name "$RD" -p 56379:6379 redis:7 >/dev/null
for i in $(seq 1 30); do docker exec "$PG" pg_isready -U postgres -d smsp >/dev/null 2>&1 && break; sleep 1; done

echo "==> Building backend…"
( cd "$ROOT/backend" && go build -o "$OUT/backend" . ) || { echo "backend build failed (try a different GOPROXY)"; exit 1; }

echo "==> Starting backend on :18080…"
APP_ENV=e2e DB_DSN="host=localhost user=postgres password=postgres dbname=smsp port=55432 sslmode=disable TimeZone=Asia/Shanghai" \
  REDIS_URL="redis://localhost:56379" HTTP_PORT=18080 FEISHU_APP_ID=x FEISHU_APP_SECRET=x LOG_LEVEL=warn \
  nohup "$OUT/backend" >"$OUT/server.log" 2>&1 & disown
for i in $(seq 1 40); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18080/healthz 2>/dev/null||echo 000)" = "200" ] && break; sleep 1; done

echo "==> Creating a test user…"
docker exec "$PG" psql -U postgres -d smsp -c "INSERT INTO users (open_id,secret_key,sharing_key,status,created_at,updated_at) VALUES ('t','tsecret'::bytea,'tshare',1,now(),now()) ON CONFLICT (open_id) DO UPDATE SET secret_key=EXCLUDED.secret_key;" >/dev/null
USERID=$(docker exec "$PG" psql -U postgres -d smsp -t -A -c "SELECT id FROM users WHERE open_id='t';" | tr -d '[:space:]')
docker exec "$PG" psql -U postgres -d smsp -c "INSERT INTO user_settings (user_id,settings,updated_at) VALUES ($USERID,'{\"publicEnabled\":true,\"authorizedMusicStats\":false}'::jsonb,now()) ON CONFLICT (user_id) DO UPDATE SET settings=EXCLUDED.settings;" >/dev/null

echo "==> POST your scanned report → /api/v1/state/report"
curl -s -X POST http://localhost:18080/api/v1/state/report -H "X-Secret-Key: tsecret" -H "Content-Type: application/json" --data-binary @"$OUT/report.json"; echo

echo "==> Rendered Feishu signature (server-computed cost):"
TPL='今日 {tokensTodayH} ({tokenCostToday}) · 近7天 {tokens7dH} ({tokenCost7d}) · 近30天 {tokensTotalH} ({tokenCostTotal}) · 主力 {topModel} · {tokenSessions}会话'
curl -s -G http://localhost:18080/api/v1/render --data-urlencode "sharingKey=tshare" --data-urlencode "m=$TPL"; echo
