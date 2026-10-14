#!/bin/bash
# Start the cnx Mac host as you (no sudo, no LaunchDaemons): a cmux-tui
# session daemon, acpmux, and cnx-hostd, which registers this Mac with the
# cnx service and lets your phone connect. Stop everything with stop-host.sh.
#
# Sign-in, first that applies (tokens stay in 0600 files and are never printed):
#   1. A saved session in $CNX_HOST_HOME/refresh-token.
#   2. CNX_REFRESH_TOKEN_FILE: a file holding a Stack refresh token.
#   3. CNX_STACK_EMAIL + CNX_STACK_PASSWORD: password sign-in.
#   4. Otherwise it asks for your email and the 6-digit code it sends you.
# Use the same account you sign in with on the phone. --sign-out forgets it.
#
# Options and environment:
#   --team <id> / CNX_TEAM_ID   the team space (default: your personal space)
#   --name <name> / CNX_DEVICE_NAME   how the phone lists this Mac (default: host name)
#   --root <dir> (repeatable) / CNX_WEB_ROOTS (colon-separated)
#                               folders the phone may use for agents and files
#                               (default: $CNX_HOST_HOME/work)
#   --seed                      create a "cnx-demo" workspace if the session is empty
#   --prod                      sign in to the production Stack project (for the
#                               production app build, dev.cmux.cnx.prod); state in
#                               ~/.cnx-host-prod, beside a dev host (also with --sign-out)
#   CNX_HOST_HOME               state, logs and sockets (default ~/.cnx-host, or ~/.cnx-host-prod)
#   CNX_BASE_URL                service (default the production Worker https://cnx-ios-api.cmux.dev
#                               with --prod, else the dev Worker)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bin=$here/bin
prod=0
for a in "$@"; do [[ "$a" != --prod ]] || prod=1; done
stack_api=${CNX_STACK_API:-https://api.stack-auth.com}
if [[ $prod == 1 ]]; then
  # Production Stack project: no publishable key, the cmux.com email callback.
  home=${CNX_HOST_HOME:-$HOME/.cnx-host-prod}
  base=${CNX_BASE_URL:-https://cnx-ios-api.cmux.dev}
  project=9790718f-14cd-4f7e-824d-eaf527a82b82 pck="" callback=https://cmux.com/auth/callback
else
  home=${CNX_HOST_HOME:-$HOME/.cnx-host}
  base=${CNX_BASE_URL:-https://cnx-ios-api-dev.debussy.workers.dev}
  project=${CNX_STACK_PROJECT_ID:-454ecd03-1db2-4050-845e-4ce5b0cd9895}
  pck=${CNX_STACK_PUBLISHABLE_KEY-pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g}
  callback=http://localhost:3000/auth/callback
fi
session=${CNX_TUI_SESSION:-cnx}
team=${CNX_TEAM_ID:-}
name=${CNX_DEVICE_NAME:-}
roots=() seed=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) team=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --root) roots+=("$2"); shift 2 ;;
    --seed) seed=1; shift ;;
    --prod) shift ;;
    --sign-out) rm -f "$home/refresh-token" "$home/user-id"; echo "Signed out."; exit 0 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ ${#roots[@]} -eq 0 && -n "${CNX_WEB_ROOTS:-}" ]]; then IFS=: read -r -a roots <<<"$CNX_WEB_ROOTS"; fi
[[ ${#roots[@]} -gt 0 ]] || roots=("$home/work")

umask 077
mkdir -p "$home"/{run,logs,sock,acpmux,state,work}
chmod 700 "$home"
for i in "${!roots[@]}"; do
  roots[$i]=$(cd "${roots[$i]}" 2>/dev/null && pwd) || { echo "error: no such folder: ${roots[$i]}" >&2; exit 1; }
done
for b in cnx-hostd cmux-tui acpmux; do
  [[ -x "$bin/$b" ]] || { echo "error: missing $bin/$b" >&2; exit 1; }
  xattr -d com.apple.quarantine "$bin/$b" 2>/dev/null || true
done
if [[ -f "$home/run/hostd.pid" ]] && kill -0 "$(cat "$home/run/hostd.pid")" 2>/dev/null; then
  echo "cnx host is already running (stop it with $here/stop-host.sh)."; exit 0
fi

# --- Stack sign-in ---------------------------------------------------------
tmp=$(mktemp -d "$home/state/tmp.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
stack_post() {  # path body-file out-file [header-file] -> HTTP status
  local extra=(); [[ -z "${4:-}" ]] || extra=(-H "@$4")
  # Production needs no publishable key; send it only when set.
  [[ -z "$pck" ]] || extra+=(-H "x-stack-publishable-client-key: $pck")
  curl -sS -o "$3" -w '%{http_code}' -X POST "$stack_api/api/v1$1" \
    -H 'content-type: application/json' -H "x-stack-project-id: $project" \
    -H 'x-stack-access-type: client' \
    "${extra[@]+"${extra[@]}"}" --data-binary "@$2"
}
field() { plutil -extract "$1" raw -o - "$2" 2>/dev/null; }
save_refresh() {
  field refresh_token "$1" > "$home/refresh-token" && [[ -s "$home/refresh-token" ]] \
    || { echo "error: sign-in returned no session" >&2; exit 1; }
  chmod 600 "$home/refresh-token"
}
if [[ ! -s "$home/refresh-token" ]]; then
  if [[ -n "${CNX_REFRESH_TOKEN_FILE:-}" ]]; then
    tr -d '\n' < "$CNX_REFRESH_TOKEN_FILE" > "$home/refresh-token"
  elif [[ -n "${CNX_STACK_EMAIL:-}" && -n "${CNX_STACK_PASSWORD:-}" ]]; then
    printf '{"email":%s,"password":%s}' "$(json_str "$CNX_STACK_EMAIL")" "$(json_str "$CNX_STACK_PASSWORD")" > "$tmp/body"
    status=$(stack_post /auth/password/sign-in "$tmp/body" "$tmp/out")
    [[ "$status" == 200 ]] || { echo "error: password sign-in failed (HTTP $status)" >&2; exit 1; }
    save_refresh "$tmp/out"
  else
    read -r -p "Email for cmux sign-in: " email
    printf '{"email":%s,"callback_url":"%s"}' "$(json_str "$email")" "$callback" > "$tmp/body"
    status=$(stack_post /auth/otp/send-sign-in-code "$tmp/body" "$tmp/out")
    [[ "$status" == 200 ]] || { echo "error: could not send a code (HTTP $status)" >&2; exit 1; }
    nonce=$(field nonce "$tmp/out")
    read -r -p "6-digit code from the email: " code
    printf '{"code":%s}' "$(json_str "${code//[^0-9]/}$nonce")" > "$tmp/body"
    status=$(stack_post /auth/otp/sign-in "$tmp/body" "$tmp/out")
    [[ "$status" == 200 ]] || { echo "error: the code was not accepted (HTTP $status)" >&2; exit 1; }
    save_refresh "$tmp/out"
  fi
  chmod 600 "$home/refresh-token"
fi

# The user id (JWT sub) names the personal space.
printf 'x-stack-refresh-token: %s\n' "$(cat "$home/refresh-token")" > "$tmp/hdr"
echo '{}' > "$tmp/body"
status=$(stack_post /auth/sessions/current/refresh "$tmp/body" "$tmp/out" "$tmp/hdr")
[[ "$status" == 200 ]] || { echo "error: the saved session was refused (HTTP $status); run $0 $([[ $prod == 1 ]] && echo "--prod ")--sign-out and sign in again" >&2; exit 1; }
payload=$(field access_token "$tmp/out" | cut -d. -f2 | tr '_-' '/+')
while (( ${#payload} % 4 )); do payload+="="; done
user_id=$(base64 -D <<<"$payload" | plutil -extract sub raw -o - - 2>/dev/null)
[[ -n "$user_id" ]] || { echo "error: could not read the user id" >&2; exit 1; }
echo "$user_id" > "$home/user-id"
team=${team:-personal-$user_id}

# --- acpmux ----------------------------------------------------------------
export ACPMUX_HOME="$home/acpmux"
cfg="$ACPMUX_HOME/config.json"
port=""
if [[ -f "$cfg" ]]; then port=$(field websocket.listen "$cfg" | sed 's/.*://'); fi
if [[ -z "$port" ]] || lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
  for p in $(seq 47911 47999); do lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || { port=$p; break; }; done
fi
if [[ -f "$cfg" ]]; then
  sed -i '' -E "s/(\"listen\"[[:space:]]*:[[:space:]]*\")[^\"]*\"/\1127.0.0.1:$port\"/" "$cfg"
else
  roots_json=$(for r in "${roots[@]}"; do json_str "$r"; echo; done | paste -sd, -)
  printf '{\n  "permissionPolicy": "ask",\n  "websocket": {"listen": "127.0.0.1:%s", "token": "%s"},\n  "webRoots": [%s]\n}\n' \
    "$port" "$(openssl rand -hex 24)" "$roots_json" > "$cfg"
fi
chmod 600 "$cfg"
nohup "$bin/acpmux" daemon run --listen "127.0.0.1:$port" > "$home/logs/acpmux.log" 2>&1 &
echo $! > "$home/run/acpmux.pid"

# --- cmux-tui session daemon -----------------------------------------------
sock="$home/sock/$session.sock"
mkdir -p "$home/tui-state"
nohup "$bin/cmux-tui" daemon start --session "$session" --socket "$sock" --state "$home/tui-state" > "$home/logs/cmux-tui.log" 2>&1 &
echo $! > "$home/run/cmux-tui.pid"
for _ in $(seq 1 100); do [[ -S "$sock" ]] && break; perl -e 'select(undef,undef,undef,0.1)'; done
[[ -S "$sock" ]] || { echo "error: cmux-tui did not start; see $home/logs/cmux-tui.log" >&2; exit 1; }

if [[ $seed == 1 ]]; then
  if ! "$bin/cmux-tui" --socket "$sock" workspace list 2>/dev/null | grep -q cnx-demo; then
    "$bin/cmux-tui" --socket "$sock" --quiet workspace create --name cnx-demo --cwd "${roots[0]}" \
      || echo "note: could not create the cnx-demo workspace"
  fi
fi

# --- cnx-hostd ---------------------------------------------------------------
export CNX_BASE_URL="$base" CNX_TEAM_ID="$team" CNX_REFRESH_TOKEN_FILE="$home/refresh-token"
export CNX_STACK_PROJECT_ID="$project" CNX_STACK_PUBLISHABLE_KEY="$pck" CNX_STACK_API="$stack_api"
export CNX_STATE_DIR="$home/state" CNX_TUI_SOCKET_DIR="$home/sock" CNX_TUI_SESSION="$session"
export CNX_FILE_ROOTS="$(IFS=:; echo "${roots[*]}")" CNX_EXCLUDE_CGNAT="${CNX_EXCLUDE_CGNAT:-1}"
[[ -z "$name" ]] || export CNX_DEVICE_NAME="$name"
NO_COLOR=1 nohup "$bin/cnx-hostd" > "$home/logs/hostd.log" 2>&1 &
echo $! > "$home/run/hostd.pid"
for _ in $(seq 1 100); do grep -qiE "signal|connected|registered|error" "$home/logs/hostd.log" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.1)'; done

cat <<EOF
cnx host is running.
  Team:    $team
  Session: cmux-tui $session ($sock)
  Roots:   ${roots[*]}
  Logs:    $home/logs
Open cmux cnx on your phone, signed in with the same account; this Mac shows under Workspaces.
Attach here with:  $bin/cmux-tui attach --socket $sock
Stop with:         $here/stop-host.sh
EOF
