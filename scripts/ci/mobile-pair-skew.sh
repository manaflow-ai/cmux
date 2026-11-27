#!/usr/bin/env bash
# Phone x Mac version matrix for the iPhone link, past `identify`, against a real daemon.
#
# The phone and the Mac never update together. TestFlight carries one commit's link
# (cmux-mobile-link) while Leo's Mac runs whatever NIGHTLY it last relaunched into.
# tests/pair_matrix_ios_mac.rs builds both sides at one commit, so a change that breaks
# the other version passes it. Leo, 11-27: "well clearly we need to be able to support
# the multiple versions as it goes".
#
# Builds, per tree: cmux-tui (the real daemon), cmux-mobile-host (the Mac), and
# cmux-mobile-applike (the phone: the app's setup batch, a terminal attached, resized,
# typed into and read back; see its header). An older tree gets this head's applike and
# skew_impair.rs copied in for the build (removed after). The fake backend (signaling,
# WSS relay, a local TURN) comes from HEAD. Then, on loopback, cells:
#
#   fresh    phone {N-1,N} x Mac {N-1,N} x carrier {webrtc, wireguard, wireguard over
#            TURN only, wireguard over the WSS relay (no UDP)}, each held SKEW_HOLD_S
#            (60) under steady typing: no missed echo, at most one path switch;
#            WireGuard cells also lose every inbound datagram for 6 s and must answer
#            again (same link or one redial, as the app)
#   lossy    the same on WireGuard direct and TURN with 40+-20 ms and 2% loss inbound
#   carried  the Mac upgraded N-1 -> N (and downgraded N -> N-1) on one state dir under
#            an already paired phone, which dials again with the same device id
#   far      phone FAR x Mac N and phone N x Mac FAR (FAR: a week-old commit)
#
#   scripts/ci/mobile-pair-skew.sh N1_TREE [N_TREE [FAR_TREE]]
# Env: SKEW_LOG_DIR (keep each cell's logs), SKEW_HOLD_S (60), SKEW_JOBS (cells at once,
# 6), SKEW_ONLY (a regex on cell names), SKEW_SUMMARY (append the table here, say
# $GITHUB_STEP_SUMMARY), CARGO_TARGET_DIR. Exit 1 if any cell fails.
set -euo pipefail

usage="usage: mobile-pair-skew.sh N1_TREE [N_TREE [FAR_TREE]]"
n1=$(cd "${1:?$usage}" && pwd)
n=$(cd "${2:-.}" && pwd)
far=${3:+$(cd "$3" && pwd)}
self=$(cd "$(dirname "$0")/../.." && pwd)
hold=${SKEW_HOLD_S:-60}
jobs=${SKEW_JOBS:-6}
only=${SKEW_ONLY:-.}
target=${CARGO_TARGET_DIR:-$self/target-pair-skew}
work=$(mktemp -d /tmp/pskew.XXXX)
cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

applike_src=$self/cmux-next-ios/rust/crates/cmux-mobile-host/src/bin/cmux-mobile-applike.rs
impair_src=$self/cmux-next-ios/rust/crates/cmux-mobile-host/src/skew_impair.rs

# build NAME TREE: bin/NAME/{cmux-tui,cmux-mobile-host,cmux-mobile-applike}
build() {
  local name=$1 tree=$2 out=$work/bin/$1 log=$work/build-$1.log
  mkdir -p "$out"
  local host=$tree/cmux-next-ios/rust/crates/cmux-mobile-host added=()
  if [[ ! -f $host/src/skew_impair.rs ]]; then
    cp "$impair_src" "$host/src/skew_impair.rs"; added+=("$host/src/skew_impair.rs")
  fi
  if [[ ! -f $host/src/bin/cmux-mobile-applike.rs ]] || ! cmp -s "$applike_src" "$host/src/bin/cmux-mobile-applike.rs"; then
    if [[ -f $host/src/bin/cmux-mobile-applike.rs ]]; then cp "$host/src/bin/cmux-mobile-applike.rs" "$work/applike-$name.orig"; fi
    cp "$applike_src" "$host/src/bin/cmux-mobile-applike.rs"; added+=("$host/src/bin/cmux-mobile-applike.rs")
    # The impair hook took two arguments up to 2026-11-20.
    if ! grep -q 'type ImpairInbound' "$tree/cmux-next-ios/rust/crates/cmux-mobile-link/src/dial/mod.rs"; then
      sed -i 's/skew_impair::impair3/skew_impair::impair2/' "$host/src/bin/cmux-mobile-applike.rs"
    fi
  fi
  local status=0
  {
    (cd "$tree/cmux-tui" && CMUX_GHOSTTY_SRC="" CARGO_TARGET_DIR=$target/tui cargo build --release --locked -p cmux-tui --bin cmux-tui) &&
      cp "$target/tui/release/cmux-tui" "$out/" &&
      (cd "$tree/cmux-next-ios/rust" && CARGO_TARGET_DIR=$target/mobile cargo build --release --locked -p cmux-mobile-host \
        --bin cmux-mobile-host --bin cmux-mobile-applike) &&
      cp "$target/mobile/release/cmux-mobile-host" "$target/mobile/release/cmux-mobile-applike" "$out/"
  } >"$log" 2>&1 || status=$?
  for f in "${added[@]}"; do rm -f "$f"; done
  if [[ -f $work/applike-$name.orig ]]; then cp "$work/applike-$name.orig" "$host/src/bin/cmux-mobile-applike.rs"; fi
  if [[ $status -ne 0 ]]; then
    tail -40 "$log"; echo "BUILD_FAIL $name ($tree)"; return 1
  fi
  echo "built $name $(git -C "$tree" rev-parse --short=10 HEAD)"
}

trees=("N-1:$n1" "N:$n")
[[ -n $far ]] && trees+=("FAR:$far")
for entry in "${trees[@]}"; do build "${entry%%:*}" "${entry#*:}"; done
(cd "$n/cmux-next-ios/rust" && CARGO_TARGET_DIR=$target/mobile cargo build --release --locked -p cmux-mobile-host \
  --features fake-backend --bin cmux-mobile-fake-backend) >"$work/build-backend.log" 2>&1 || { tail -40 "$work/build-backend.log"; exit 3; }
cp "$target/mobile/release/cmux-mobile-fake-backend" "$work/bin/"

free_port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# In a cell dir: daemon_up MAC / host_up MAC / host_down / daemon_down MAC
daemon_up() {
  local ens
  ens=$(HOME=$cell/home TMPDIR=$cell/tmp XDG_RUNTIME_DIR=$cell/tmp CMUX_TUI_STATE_DIR=$cell/state \
    "$work/bin/$1/cmux-tui" --session main --json server ensure 2>>"$cell/daemon.err" | tail -1) || return 1
  sock=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["socket"])' "$ens")
}
daemon_down() {
  HOME=$cell/home TMPDIR=$cell/tmp XDG_RUNTIME_DIR=$cell/tmp CMUX_TUI_STATE_DIR=$cell/state \
    "$work/bin/$1/cmux-tui" --socket "$sock" server stop --end-terminals >/dev/null 2>&1 || true
}
host_up() {
  CMUX_MOBILE_BASE_URL=$url CMUX_MOBILE_TEAM_ID=t1 CMUX_MOBILE_DEVICE_ID=mac1 \
    CMUX_MOBILE_ACCESS_TOKEN=user:u1 CMUX_MOBILE_OWNER_USER_ID=u1 CMUX_MOBILE_STATE_DIR="$cell/hoststate" \
    CMUX_MOBILE_TUI_SOCKET_DIR="$(dirname "$sock")" CMUX_MOBILE_TUI_SOCKET="$sock" HOME=$cell/home \
    CMUX_MOBILE_INCLUDE_LOOPBACK=1 CMUX_MOBILE_ACPMUX_URL=ws://127.0.0.1:1/none RUST_LOG=${RUST_LOG:-info} \
    "$work/bin/$1/cmux-mobile-host" >>"$cell/host-$1.log" 2>&1 &
  host_pid=$!
  for _ in $(seq 150); do grep -q 'signaling connected' "$cell/host-$1.log" && return 0; kill -0 $host_pid 2>/dev/null || break; sleep 0.2; done
  return 1
}
host_down() { kill "$host_pid" 2>/dev/null || true; wait "$host_pid" 2>/dev/null || true; }

# cell NAME PHONE MACS CARRIER IMPAIR STALL_MS HOLD_S: MACS is one build, or A>B (carried).
cell() {
  local name=$1 phone=$2 macs=$3 carrier=$4 impair=$5 stall=$6 hold_s=$7
  cell=$work/cells/$name
  mkdir -p "$cell/home" "$cell/tmp" "$cell/state"
  local port backend_pid result at="" first=${macs%%>*} second=""
  [[ $macs == *">"* ]] && second=${macs#*>}
  port=$(free_port); url="http://127.0.0.1:$port"; printf 'user:u1' >"$cell/token"
  CMUX_FAKE_TURN=1 "$work/bin/cmux-mobile-fake-backend" "127.0.0.1:$port" >"$cell/backend.log" 2>&1 &
  backend_pid=$!
  for _ in $(seq 50); do curl -s -o /dev/null "$url/v1/ice" && break; sleep 0.2; done
  dial() { # the phone; $1 log suffix
    local st=0
    env CMUX_APPLIKE_DEVICE=phone-$name ${impair:+CMUX_SKEW_IMPAIR=$impair} CMUX_SKEW_STALL_MS=${3:-0} CMUX_SKEW_HOLD_S=${2:-0} \
      timeout $((120 + ${2:-0})) "$work/bin/$phone/cmux-mobile-applike" "$url" "$cell/token" t1 mac1 "$carrier" \
      >"$cell/applike-$1.out" 2>"$cell/applike-$1.err" || st=$?
    grep -q '"result":"PASS"' "$cell/applike-$1.out" && return 0
    at=$(python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
    try: v=json.loads(l)
    except Exception: continue
    if v.get("result")=="FAIL": print(v.get("at","")[:400]); break
else: print("exit %s: %s" % (sys.argv[2], open(sys.argv[3]).read()[-300:].replace("\n"," ")))' "$cell/applike-$1.out" "$st" "$cell/applike-$1.err")
    return 1
  }
  result=FAIL
  if ! daemon_up "$first"; then at="daemon $first: $(tail -c 300 "$cell/daemon.err")"
  elif ! host_up "$first"; then at="host $first: $(grep -v -i debug "$cell/host-$first.log" | tail -3 | tr '\n' ' ')"
  elif [[ -z $second ]]; then
    dial run "$hold_s" "$stall" && result=PASS
  elif ! dial before; then at="before upgrade: $at"
  else
    # The upgrade: both Mac processes stop and the next build starts on the same state.
    host_down; daemon_down "$first"
    if ! daemon_up "$second"; then at="daemon $second after $first: $(tail -c 300 "$cell/daemon.err")"
    elif ! host_up "$second"; then at="host $second on $first's state: $(grep -v -i debug "$cell/host-$second.log" | tail -3 | tr '\n' ' ')"
    elif dial after; then result=PASS
    else at="after $first>$second: $at"
    fi
  fi
  host_down; daemon_down "${second:-$first}"
  kill "$backend_pid" 2>/dev/null || true; wait "$backend_pid" 2>/dev/null || true
  local holdinfo
  holdinfo=$(cat "$cell"/applike-*.out 2>/dev/null | python3 -I -c 'import json,sys
for l in sys.stdin:
    try: v=json.loads(l)
    except Exception: continue
    if v.get("step")=="hold": print("%ss %d echoes worst %sms switches %s" % (v["held_ms"]//1000, v["echoes"], v["worst_echo_ms"], "/".join(v["path_switches"]) or 0)); break' || true)
  python3 -I -c 'import json,sys; print(json.dumps(dict(zip(["cell","phone","mac","carrier","impair","result","hold","at"], sys.argv[1:]))))' \
    "$name" "$phone" "$macs" "$carrier" "${impair:-none}" "$result" "$holdinfo" "$at" >"$cell/result.json"
  if [[ -n ${SKEW_LOG_DIR:-} ]]; then mkdir -p "$SKEW_LOG_DIR/$name"; cp "$cell"/*.log "$cell"/*.out "$cell"/*.err "$cell/result.json" "$SKEW_LOG_DIR/$name/" 2>/dev/null || true; fi
  echo "$result $name${at:+: ${at:0:200}}"
}

lossy=delay_ms=40,jitter_ms=20,loss_pct=2,seed=7
plan=()
for p in N-1 N; do for m in N-1 N; do
  plan+=("fresh-$p-$m-webrtc $p $m webrtc - 0 $hold")
  plan+=("fresh-$p-$m-wg $p $m wireguard delay_ms=0 6000 $hold")
  plan+=("fresh-$p-$m-turn $p $m wireguard+relay-only delay_ms=0 6000 $hold")
  plan+=("fresh-$p-$m-wss $p $m wireguard+block-udp - 0 $hold")
  plan+=("lossy-$p-$m-wg $p $m wireguard $lossy 0 $hold")
  plan+=("lossy-$p-$m-turn $p $m wireguard+relay-only $lossy 0 $hold")
done; done
for p in N-1 N; do
  plan+=("carried-$p-upgrade $p N-1>N wireguard - 0 0")
  plan+=("carried-$p-downgrade $p N>N-1 wireguard - 0 0")
done
if [[ -n $far ]]; then
  for c in webrtc wireguard; do
    plan+=("far-FAR-N-$c FAR N $c - 0 0")
    plan+=("far-N-FAR-$c N FAR $c - 0 0")
  done
fi

running=0
for row in "${plan[@]}"; do
  read -r name phone mac carrier impair stall hold_s <<<"$row"
  [[ $name =~ $only ]] || continue
  [[ $impair == - ]] && impair=""
  ( cell "$name" "$phone" "$mac" "$carrier" "$impair" "$stall" "$hold_s" ) &
  running=$((running + 1))
  if [[ $running -ge $jobs ]]; then wait -n || true; running=$((running - 1)); fi
done
wait || true

table=$(cat "$work"/cells/*/result.json | python3 -I -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
print("| cell | phone | Mac | carrier | impair | result | hold | failed at |")
print("|---|---|---|---|---|---|---|---|")
for r in rows:
    at = r["at"].replace("|", "/").replace("\n", " ")[:220]
    print(f"| {r[\"cell\"]} | {r[\"phone\"]} | {r[\"mac\"]} | {r[\"carrier\"]} | {r[\"impair\"]} | {r[\"result\"]} | {r[\"hold\"]} | {at} |")
fails = sum(r["result"] != "PASS" for r in rows)
print(f"\n{len(rows) - fails}/{len(rows)} cells pass")
')
trees_line=$(for entry in "${trees[@]}"; do printf '%s=%s ' "${entry%%:*}" "$(git -C "${entry#*:}" rev-parse --short=10 HEAD)"; done)
printf '\nphone x Mac skew matrix (%s)\n\n%s\n' "$trees_line" "$table"
if [[ -n ${SKEW_SUMMARY:-} ]]; then printf '## Phone x Mac skew matrix\n\n`%s`\n\n%s\n' "$trees_line" "$table" >>"$SKEW_SUMMARY"; fi
! grep -q '"result": "FAIL"' "$work"/cells/*/result.json
