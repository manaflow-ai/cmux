#!/usr/bin/env bash
# End-to-end local proof for the presence worker against real Stack auth.
#
# Starts `wrangler dev`, signs in to Stack with a real dev account, then walks
# the full lifecycle: unauthorized rejection, heartbeat -> online, SSE + WS
# subscribe (snapshot + transitions), repeat heartbeat -> seen, goodbye ->
# offline(goodbye), and missed heartbeats -> alarm-driven offline(timeout).
#
# Required env (source your dev Stack secrets first):
#   STACK_PROJECT_ID, STACK_PUBLISHABLE_CLIENT_KEY, STACK_EMAIL, STACK_PASSWORD
# Optional: PORT (default 8799), STACK_API_URL (default hosted Stack).
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${PORT:-8799}"
STACK_API_URL="${STACK_API_URL:-https://api.stack-auth.com}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d /tmp/presence-proof.XXXXXX)"
SSE_LOG="$WORK/sse.log"
WS_LOG="$WORK/ws.log"
DEV_LOG="$WORK/wrangler-dev.log"

for var in STACK_PROJECT_ID STACK_PUBLISHABLE_CLIENT_KEY STACK_EMAIL STACK_PASSWORD; do
  [ -n "${!var:-}" ] || { echo "missing required env: $var" >&2; exit 2; }
done

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

step "sign in to Stack (dev project ${STACK_PROJECT_ID:0:8}...)"
SIGNIN=$(curl -fsS -X POST "$STACK_API_URL/api/v1/auth/password/sign-in" \
  -H "x-stack-access-type: client" \
  -H "x-stack-project-id: $STACK_PROJECT_ID" \
  -H "x-stack-publishable-client-key: $STACK_PUBLISHABLE_CLIENT_KEY" \
  -H "content-type: application/json" \
  -d "{\"email\":\"$STACK_EMAIL\",\"password\":\"$STACK_PASSWORD\"}")
ACCESS_TOKEN=$(printf '%s' "$SIGNIN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
echo "signed in: got access token"

step "start wrangler dev on :$PORT"
bunx wrangler dev --port "$PORT" \
  --var "STACK_PROJECT_ID:$STACK_PROJECT_ID" \
  --var "STACK_PUBLISHABLE_CLIENT_KEY:$STACK_PUBLISHABLE_CLIENT_KEY" \
  --var "STACK_API_URL:$STACK_API_URL" \
  >"$DEV_LOG" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/healthz"; echo

step "unauthenticated heartbeat is rejected"
CODE=$(curl -s -o "$WORK/unauth.json" -w '%{http_code}' -X POST "$BASE/v1/presence/heartbeat" \
  -H "content-type: application/json" -d '{}')
cat "$WORK/unauth.json"; echo " (status $CODE)"
[ "$CODE" = "401" ] || { echo "FAIL: expected 401" >&2; exit 1; }

DEVICE_ID=$(uuidgen | tr 'A-Z' 'a-z')
AUTH=(-H "authorization: Bearer $ACCESS_TOKEN")
beat() { # beat <tag> [extra-json-fields]
  curl -fsS -X POST "$BASE/v1/presence/heartbeat" "${AUTH[@]}" \
    -H "content-type: application/json" \
    -d "{\"deviceId\":\"$DEVICE_ID\",\"platform\":\"mac\",\"tag\":\"$1\",\"displayName\":\"proof-mac\"${2:-}}"
  echo
}

step "subscribe via SSE (background curl) and WebSocket (bun probe)"
curl -Ns "$BASE/v1/presence/subscribe" "${AUTH[@]}" >"$SSE_LOG" &
PIDS+=($!)
PRESENCE_TOKEN="$ACCESS_TOKEN" bun -e '
  const ws = new WebSocket("ws://127.0.0.1:'"$PORT"'/v1/presence/subscribe", {
    headers: { authorization: `Bearer ${process.env.PRESENCE_TOKEN}` },
  });
  ws.onmessage = (e) => console.log(String(e.data));
  ws.onerror = (e) => console.error("ws error", e?.message ?? e);
' >"$WS_LOG" 2>&1 &
PIDS+=($!)
sleep 2

step "heartbeat -> online"
beat default
step "heartbeat again -> seen"
beat default

step "goodbye (stopping: true) -> immediate offline(goodbye)"
beat default ',"stopping":true'

step "one more heartbeat -> back online, then stop heartbeating"
beat default
LAST_BEAT=$(date +%s)

step "snapshot while online"
curl -fsS "$BASE/v1/presence/snapshot" "${AUTH[@]}"; echo

step "wait for alarm-driven offline(timeout) (45s after last heartbeat)"
DEADLINE=$(( LAST_BEAT + 90 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  grep -q '"reason":"timeout"' "$SSE_LOG" && break
  sleep 2
done
grep -q '"reason":"timeout"' "$SSE_LOG" || { echo "FAIL: no timeout offline within 90s" >&2; tail -20 "$SSE_LOG"; exit 1; }
echo "offline(timeout) observed $(( $(date +%s) - LAST_BEAT ))s after last heartbeat"

step "snapshot after timeout"
curl -fsS "$BASE/v1/presence/snapshot" "${AUTH[@]}"; echo

step "SSE transcript ($SSE_LOG)"
cat "$SSE_LOG"
step "WebSocket transcript ($WS_LOG)"
cat "$WS_LOG"

step "PASS: heartbeat -> subscribe -> online -> goodbye -> online -> timeout offline all observed"
echo "logs kept in $WORK"
