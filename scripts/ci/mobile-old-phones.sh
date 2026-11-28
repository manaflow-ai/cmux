#!/usr/bin/env bash
# Shipped iPhone builds against the DEPLOYED mobile API and a Mac host (cmuxterm-hq phone-link-fix fan-out).
#
# mobile-pair-skew.sh dials an old Mac host from this head's phone link on a fake backend. Nothing
# dialed the real, deployed cmux-mobile-api with the phone builds people already have, so a Worker
# deploy or a new Mac could break every shipped phone while CI stayed green. This does, per Mac
# host tree and per phone build:
#
#   pair       cmux-mobile-dial (the phone's Rust link, built at the TestFlight build's commit)
#              links to the Mac host over webrtc and wireguard through the deployed Worker
#   attach     the Mac's daemon channel answers `identify`
#   stream     the echo channel moves BYTES each way
#   reconnect  a held link redials and answers a probe after the Mac host restarts
#
#   scripts/ci/mobile-old-phones.sh API_ENV OUT_DIR MAC_NAME=MAC_TREE... -- PHONE_SHA[:CREATED]...
#
# API_ENV is staging (cmux-mobile-api-dev, the dev Stack project) or prod (mobile-api.cmux.dev, the
# production Stack project). STACK_EMAIL and STACK_PASSWORD are that project's test account. Each
# phone build's dial is built from OLD_PHONES_TREES/PHONE_SHA, else a worktree of it; one target dir
# serves every build. Every device this registers is deleted on exit. scripts/ci/mobile_old_phones.py
# verdict reads OUT_DIR.
set -euo pipefail

api_env=${1:?usage: mobile-old-phones.sh staging|prod OUT_DIR MAC_NAME=TREE... -- PHONE_SHA...}
out=$(mkdir -p "${2:?OUT_DIR}" && cd "$2" && pwd)
shift 2
macs=()
while [[ $# -gt 0 && "$1" != "--" ]]; do macs+=("$1"); shift; done
[[ "${1:-}" == "--" ]] && shift
phones=("$@")
[[ ${#macs[@]} -gt 0 && ${#phones[@]} -gt 0 ]] || { echo "need a Mac tree and a phone build" >&2; exit 2; }

case "$api_env" in
  staging) base=https://cmux-mobile-api-dev.debussy.workers.dev
           project=454ecd03-1db2-4050-845e-4ce5b0cd9895
           pck=pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g ;;
  prod)    base=https://mobile-api.cmux.dev
           project=9790718f-14cd-4f7e-824d-eaf527a82b82
           pck= ;;
  *) echo "API_ENV is staging or prod" >&2; exit 2 ;;
esac
base=${CMUX_MOBILE_BASE_URL_OVERRIDE:-$base}
: "${STACK_EMAIL:?the test account}" "${STACK_PASSWORD:?the test account}"
bytes=${OLD_PHONES_BYTES:-1048576}
hold=${OLD_PHONES_HOLD_SECONDS:-40}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
work=$(mktemp -d)
target=${CARGO_TARGET_DIR:-$work/target}
pids=()
devices=()

stack() {  # path body-json [extra curl args...] -> body on stdout; fails on non-2xx
  local path=$1 body=$2; shift 2
  local h=(-H 'content-type: application/json' -H "x-stack-project-id: $project" -H 'x-stack-access-type: client')
  [[ -z "$pck" ]] || h+=(-H "x-stack-publishable-client-key: $pck")
  curl -fsS --max-time 20 --retry 2 -X POST "https://api.stack-auth.com/api/v1$path" "${h[@]}" "$@" -d "$body"
}
field() { python3 -I -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
fresh_token() {  # writes a fresh access token to $work/token (0600)
  stack /auth/sessions/current/refresh '{}' -H "x-stack-refresh-token: $(cat "$work/refresh")" \
    | field access_token > "$work/token.new"
  chmod 600 "$work/token.new"; mv "$work/token.new" "$work/token"
}
api_delete() { curl -sS -o /dev/null --max-time 15 -X DELETE -H "authorization: Bearer $(cat "$work/token")" "$base/v1/devices/$1" || true; }
stop_host() { [[ -n "${host_pid:-}" ]] && { kill "$host_pid" 2>/dev/null || true; wait "$host_pid" 2>/dev/null || true; host_pid=; }; }
cleanup() {
  stop_host
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [[ -s "$work/refresh" ]]; then
    fresh_token 2>/dev/null || true
    for d in "${devices[@]}"; do api_delete "$d"; done
  fi
  for t in "$work"/phone-*; do [[ -d "$t" ]] && git -C "$repo" worktree remove --force "$t" 2>/dev/null || true; done
  rm -rf "$work/token" "$work/token.new" "$work/refresh" "$work/state"* "$work/tui"*
}
trap cleanup EXIT
umask 077

# The test account: password sign-in once; every leg mints a fresh access token from the refresh token.
stack /auth/password/sign-in "$(python3 -I -c 'import json,os; print(json.dumps({"email": os.environ["STACK_EMAIL"], "password": os.environ["STACK_PASSWORD"]}))')" \
  > "$work/signin.json"
field refresh_token < "$work/signin.json" > "$work/refresh"
field access_token < "$work/signin.json" > "$work/token"
rm -f "$work/signin.json"
sub=$(python3 -I -c 'import base64,json,sys; p=open(sys.argv[1]).read().split(".")[1]; print(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4)))["sub"])' "$work/token")
team="personal-$sub"
health=$(curl -fsS --max-time 10 "$base/v1/health" || echo '{}')
api_version=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get("version","?"))' "$health")
echo "API $api_env $base serves $api_version"

# Phone links: cmux-mobile-dial at each shipped build's commit (cached in OLD_PHONES_BIN_CACHE by sha).
cache=${OLD_PHONES_BIN_CACHE:-$work/bin-cache}
mkdir -p "$cache"
for p in "${phones[@]}"; do
  sha=${p%%:*}
  [[ -x "$cache/dial-$sha" ]] && continue
  src="${OLD_PHONES_TREES:-/nonexistent}/$sha"
  if [[ ! -d "$src" ]]; then
    git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$repo" fetch -q --no-tags --depth=1 origin "$sha"
    git -C "$repo" worktree add -q --detach "$work/phone-$sha" "$sha"
    src="$work/phone-$sha"
  fi
  (cd "$src/cmux-next-ios/rust" && CARGO_TARGET_DIR=$target cargo build --release -q -p cmux-mobile-host --bin cmux-mobile-dial)
  cp "$target/release/cmux-mobile-dial" "$cache/dial-$sha"
  [[ "$src" != "$work/phone-$sha" ]] || git -C "$repo" worktree remove --force "$src"
done

status=0
for m in "${macs[@]}"; do
  name=${m%%=*}; tree=$(cd "${m#*=}" && pwd)
  mac_sha=$(git -C "$tree" rev-parse HEAD)
  mkdir -p "$work/bin-$name"
  (cd "$tree/cmux-next-ios/rust" && CARGO_TARGET_DIR=$target cargo build --release -q -p cmux-mobile-host \
    --bin cmux-mobile-host --bin cmux-mobile-stub-tui)
  cp "$target/release/cmux-mobile-host" "$target/release/cmux-mobile-stub-tui" "$work/bin-$name/"
  mac_id=$(python3 -I -c 'import uuid; print(uuid.uuid4())')
  devices+=("$mac_id")
  mkdir -p "$work/tui-$name" "$work/state-$name"
  "$work/bin-$name/cmux-mobile-stub-tui" "$work/tui-$name" main > "$out/$name-tui.log" 2>&1 & pids+=($!)
  start_host() {
    fresh_token
    CMUX_MOBILE_BASE_URL=$base CMUX_MOBILE_TEAM_ID=$team CMUX_MOBILE_DEVICE_ID=$mac_id \
      CMUX_MOBILE_DEVICE_NAME="ci-old-phones-$name" CMUX_MOBILE_REFRESH_TOKEN_FILE="$work/refresh" \
      CMUX_MOBILE_STACK_PROJECT_ID=$project CMUX_MOBILE_STACK_PUBLISHABLE_KEY=$pck \
      CMUX_MOBILE_STATE_DIR="$work/state-$name" CMUX_MOBILE_TUI_SOCKET_DIR="$work/tui-$name" \
      CMUX_MOBILE_TUI_SOCKET="$work/tui-$name/main.sock" CMUX_MOBILE_ACPMUX_URL=ws://127.0.0.1:1/none \
      "$work/bin-$name/cmux-mobile-host" >> "$out/$name-host.log" 2>&1 &
    host_pid=$!
    local before=$1
    for _ in $(seq 150); do
      [[ $(grep -c 'signaling connected' "$out/$name-host.log" || true) -gt $before ]] && return 0
      sleep 0.2
    done
    echo "::error::Mac host $name never connected to $api_env signaling"; tail -40 "$out/$name-host.log"; return 1
  }
  for _ in $(seq 50); do [[ -S "$work/tui-$name/main.sock" ]] && break; sleep 0.2; done
  : > "$out/$name-host.log"
  start_host 0 || { status=1; continue; }

  for p in "${phones[@]}"; do
    sha=${p%%:*}; created=${p#*:}; [[ "$created" == "$p" ]] && created=
    cell="$out/$name/$sha"; mkdir -p "$cell"
    dev_file="$work/phone-device-$sha"
    fresh_token
    # pair + attach + stream: one dial per transport, the daemon channel, BYTES through echo.
    bash "$here/timeout.sh" 150 "$cache/dial-$sha" --base-url "$base" --token-file "$work/token" --team "$team" \
      --mac "$mac_id" --device-file "$dev_file" --transport webrtc --transport wireguard --daemon --bytes "$bytes" \
      > "$cell/pair.out" 2> "$cell/pair.err" || echo "dial exit $?" >> "$cell/pair.err"
    [[ -s "$dev_file" ]] && devices+=("$(cat "$dev_file")")
    # reconnect: hold the link, restart the Mac host 10 s in, expect a redial and an answered probe.
    fresh_token
    "$cache/dial-$sha" --base-url "$base" --token-file "$work/token" --team "$team" --mac "$mac_id" \
      --device-file "$dev_file" --transport wireguard --hold-seconds "$hold" --probe-ms 250 --dead-after-ms 3000 \
      > "$cell/hold.out" 2> "$cell/hold.err" &
    dial_pid=$!
    for _ in $(seq 100); do grep -q '"event":"probe"' "$cell/hold.out" 2>/dev/null && break; sleep 0.2; done
    sleep 8
    stop_host
    restart_ms=$(python3 -I -c 'import time; print(int(time.time()*1000))')
    sleep 2
    before=$(grep -c 'signaling connected' "$out/$name-host.log" || true)
    start_host "$before" || status=1
    bash "$here/timeout.sh" $((hold + 30)) tail --pid="$dial_pid" -f /dev/null || kill "$dial_pid" 2>/dev/null || true
    wait "$dial_pid" 2>/dev/null || echo "hold exit $?" >> "$cell/hold.err"
    python3 -I -c 'import json,sys; json.dump(dict(zip(["api","api_version","mac","mac_sha","phone_sha","phone_created","transports","bytes","restart_epoch_ms"], [sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5],sys.argv[6],["webrtc","wireguard"],int(sys.argv[7]),int(sys.argv[8])])), open(sys.argv[9],"w"))' \
      "$api_env" "$api_version" "$name" "$mac_sha" "$sha" "$created" "$bytes" "$restart_ms" "$cell/meta.json"
  done
  stop_host
done
exit $status
