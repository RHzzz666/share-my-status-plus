#!/bin/bash
# Stand up a PERSISTENT local backend so you can verify the macOS GUI client
# against it. The GUI app CAN reach localhost (Feishu cannot), so this is the
# way to watch the real app collect -> report -> render.
#
#   bash serve-local.sh        # start backend + Postgres + Redis, print app settings
#   bash serve-local.sh stop   # tear everything down
#
# Needs: docker, go. Uses ports 18080 / 55432 / 56379.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT=/tmp/sms-localserver
PG=sms-localdev-pg; RD=sms-localdev-redis
SECRET="localdev-secret"; SHARE="localdev-share"

if [ "${1:-}" = "stop" ]; then
  pkill -f "$OUT/backend" 2>/dev/null && echo "backend stopped" || echo "backend not running"
  docker rm -f "$PG" "$RD" >/dev/null 2>&1 && echo "containers removed" || echo "no containers"
  exit 0
fi

mkdir -p "$OUT"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

echo "==> Postgres + Redis…"
docker rm -f "$PG" "$RD" >/dev/null 2>&1 || true
docker run -d --name "$PG" -e POSTGRES_PASSWORD=postgres -e POSTGRES_USER=postgres -e POSTGRES_DB=smsp -p 55432:5432 postgres:16-alpine >/dev/null
docker run -d --name "$RD" -p 56379:6379 redis:7 >/dev/null
for i in $(seq 1 30); do docker exec "$PG" pg_isready -U postgres -d smsp >/dev/null 2>&1 && break; sleep 1; done

echo "==> Building + starting backend on :18080 (stays up)…"
( cd "$ROOT/backend" && go build -o "$OUT/backend" . ) || { echo "backend build failed"; exit 1; }
APP_ENV=e2e DB_DSN="host=localhost user=postgres password=postgres dbname=smsp port=55432 sslmode=disable TimeZone=Asia/Shanghai" \
  REDIS_URL="redis://localhost:56379" HTTP_PORT=18080 FEISHU_APP_ID=x FEISHU_APP_SECRET=x LOG_LEVEL=warn \
  nohup "$OUT/backend" >"$OUT/server.log" 2>&1 & disown
for i in $(seq 1 40); do [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18080/healthz 2>/dev/null||echo 000)" = "200" ] && break; sleep 1; done

echo "==> Creating test user…"
docker exec "$PG" psql -U postgres -d smsp -c "INSERT INTO users (open_id,secret_key,sharing_key,status,created_at,updated_at) VALUES ('localdev','$SECRET'::bytea,'$SHARE',1,now(),now()) ON CONFLICT (open_id) DO UPDATE SET secret_key=EXCLUDED.secret_key;" >/dev/null
USERID=$(docker exec "$PG" psql -U postgres -d smsp -t -A -c "SELECT id FROM users WHERE open_id='localdev';" | tr -d '[:space:]')
docker exec "$PG" psql -U postgres -d smsp -c "INSERT INTO user_settings (user_id,settings,updated_at) VALUES ($USERID,'{\"publicEnabled\":true,\"authorizedMusicStats\":false}'::jsonb,now()) ON CONFLICT (user_id) DO UPDATE SET settings=EXCLUDED.settings;" >/dev/null

cat <<EOF

================ Local backend is UP (stays running) ================
In the macOS app → Settings, set:
  endpointURL : http://localhost:18080/api/v1/state/report
  secretKey   : $SECRET
Then turn ON "AI Token 用量" (it does an immediate first scan+report).

Check the client actually reported (run after it reports once):
  curl -sG http://localhost:18080/api/v1/render \\
    --data-urlencode "sharingKey=$SHARE" \\
    --data-urlencode 'm=今日{tokensTodayH} 花费{tokenCostToday} 主力{topModel} {tokenSessions}会话' ; echo

Or inspect what's stored:
  curl -s "http://localhost:18080/api/v1/state/query?sharingKey=$SHARE" | python3 -m json.tool

Server log : $OUT/server.log
Stop all   : bash "$HERE/serve-local.sh" stop
=====================================================================
EOF
