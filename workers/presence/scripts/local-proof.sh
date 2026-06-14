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
# Optional second same-team account to prove the device-owner guard
# (a co-member's heartbeat for someone else's device is rejected):
#   STACK_EMAIL_2, STACK_PASSWORD_2
# Optional explicit team to scope every request to (X-Cmux-Team-Id); both
# accounts must be members:
#   PROOF_TEAM_ID
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
  # $WORK is kept for the transcript logs, so scrub every token-bearing file
  # (curl configs carrying live Stack bearer tokens, sign-in bodies) on every
  # exit path; only non-secret logs survive.
  rm -f "$WORK"/*.curlrc "$WORK"/signin-body.json 2>/dev/null || true
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

# Secrets never ride argv (process args are world-readable): request bodies
# and bearer headers go through files in $WORK (mktemp -d, mode 700).
sign_in() { # sign_in <email> <password> -> access token on stdout
  local body="$WORK/signin-body.json"
  printf '{"email":"%s","password":"%s"}' "$1" "$2" >"$body"
  curl -fsS -X POST "$STACK_API_URL/api/v1/auth/password/sign-in" \
    -H "x-stack-access-type: client" \
    -H "x-stack-project-id: $STACK_PROJECT_ID" \
    -H "x-stack-publishable-client-key: $STACK_PUBLISHABLE_CLIENT_KEY" \
    -H "content-type: application/json" \
    -d @"$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
  rm -f "$body"
}

stack_user_id() { # stack_user_id <access token> -> Stack user id on stdout
  local cfg="$WORK/me.curlrc"
  printf 'header = "x-stack-access-token: %s"\n' "$1" >"$cfg"
  curl -fsS -K "$cfg" "$STACK_API_URL/api/v1/users/me" \
    -H "x-stack-access-type: client" \
    -H "x-stack-project-id: $STACK_PROJECT_ID" \
    -H "x-stack-publishable-client-key: $STACK_PUBLISHABLE_CLIENT_KEY" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
  rm -f "$cfg"
}

step "sign in to Stack (dev project ${STACK_PROJECT_ID:0:8}...)"
ACCESS_TOKEN=$(sign_in "$STACK_EMAIL" "$STACK_PASSWORD")
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
AUTH_CFG="$WORK/auth1.curlrc"
printf 'header = "authorization: Bearer %s"\n' "$ACCESS_TOKEN" >"$AUTH_CFG"
if [ -n "${PROOF_TEAM_ID:-}" ]; then
  printf 'header = "x-cmux-team-id: %s"\n' "$PROOF_TEAM_ID" >>"$AUTH_CFG"
fi
AUTH=(-K "$AUTH_CFG")
beat() { # beat <tag> [extra-json-fields]
  curl -fsS -X POST "$BASE/v1/presence/heartbeat" "${AUTH[@]}" \
    -H "content-type: application/json" \
    -d "{\"deviceId\":\"$DEVICE_ID\",\"platform\":\"mac\",\"tag\":\"$1\",\"displayName\":\"proof-mac\"${2:-}}"
  echo
}

step "subscribe via SSE (background curl) and WebSocket (bun probe)"
curl -Ns "$BASE/v1/presence/subscribe" "${AUTH[@]}" >"$SSE_LOG" &
PIDS+=($!)
PRESENCE_TOKEN="$ACCESS_TOKEN" PRESENCE_TEAM_ID="${PROOF_TEAM_ID:-}" bun -e '
  const headers = { authorization: `Bearer ${process.env.PRESENCE_TOKEN}` };
  if (process.env.PRESENCE_TEAM_ID) headers["x-cmux-team-id"] = process.env.PRESENCE_TEAM_ID;
  const ws = new WebSocket("ws://127.0.0.1:'"$PORT"'/v1/presence/subscribe", { headers });
  ws.onmessage = (e) => console.log(String(e.data));
  ws.onerror = (e) => console.error("ws error", e?.message ?? e);
' >"$WS_LOG" 2>&1 &
PIDS+=($!)
sleep 2

step "heartbeat -> online"
FIRST_BEAT=$(curl -fsS -X POST "$BASE/v1/presence/heartbeat" "${AUTH[@]}" \
  -H "content-type: application/json" \
  -d "{\"deviceId\":\"$DEVICE_ID\",\"platform\":\"mac\",\"tag\":\"default\",\"displayName\":\"proof-mac\"}")
echo "$FIRST_BEAT"
TEAM_ID=$(printf '%s' "$FIRST_BEAT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["teamId"])')
step "heartbeat again -> seen"
beat default

if [ -n "${STACK_EMAIL_2:-}" ] && [ -n "${STACK_PASSWORD_2:-}" ]; then
  step "device-owner guard: a second team member cannot spoof this device"
  ACCESS_TOKEN_2=$(sign_in "$STACK_EMAIL_2" "$STACK_PASSWORD_2")
  # The guard only proves anything across two DISTINCT users; aliased env
  # (e.g. dogfood == uitest account) would make a legitimate same-owner 200
  # look like a guard failure, so detect and skip instead.
  if [ "$(stack_user_id "$ACCESS_TOKEN")" = "$(stack_user_id "$ACCESS_TOKEN_2")" ]; then
    echo "(skipping device-owner guard step: STACK_EMAIL_2 resolves to the same Stack user as STACK_EMAIL; provide a second distinct same-team account)"
  else
    AUTH2_CFG="$WORK/auth2.curlrc"
    printf 'header = "authorization: Bearer %s"\n' "$ACCESS_TOKEN_2" >"$AUTH2_CFG"
    printf 'header = "x-cmux-team-id: %s"\n' "$TEAM_ID" >>"$AUTH2_CFG"
    CODE=$(curl -s -o "$WORK/owner.json" -w '%{http_code}' -X POST "$BASE/v1/presence/heartbeat" \
      -K "$AUTH2_CFG" \
      -H "content-type: application/json" \
      -d "{\"deviceId\":\"$DEVICE_ID\",\"platform\":\"mac\",\"tag\":\"default\",\"stopping\":true}")
    cat "$WORK/owner.json"; echo " (status $CODE)"
    [ "$CODE" = "403" ] || { echo "FAIL: expected 403 owner mismatch" >&2; exit 1; }
    grep -q device_owner_mismatch "$WORK/owner.json" || { echo "FAIL: expected device_owner_mismatch" >&2; exit 1; }
  fi
else
  echo "(skipping device-owner guard step: STACK_EMAIL_2/STACK_PASSWORD_2 not set)"
fi

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
