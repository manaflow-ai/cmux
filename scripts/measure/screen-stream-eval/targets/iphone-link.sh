#!/usr/bin/env bash
# Screen stream eval target: the Mac's screen as cmux.rd/1 over the cmux link (WireGuard) into the
# iPhone app in an iOS simulator on the same Mac, the path the app's Mac Screen over Link viewer
# takes. It reports the same rows as `iphone-sim` (WebRTC), so one run compares the two.
#
# The host side runs without the person's cmux: cmux-mobile-host (hostd) standalone, signaling
# through cmux-mobile-fake-backend on loopback (bearer `user:eval`, the phone the same user), its
# `surface` service streaming `d~0` from a child `cmux-rd surface-source` (CMUX_MOBILE_SURFACE_SOURCE,
# CMUX_MOBILE_MAC_DISPLAY=1): the rd target's ScreenCaptureKit capture and VideoToolbox encode, so
# the step needs the Screen Recording grant the rd target has (the responsible process's, inherited
# by hostd and its child), and Accessibility for the injected input, as rd's host does.
#
# The viewer is the app's DEBUG `ScreenSharingRdLinkRoot` (CMUX_MOBILE_RD_LINK): it dials with the
# app's FFIMacLinkDialer over WireGuard, opens `d~0` on the same StreamedBrowserModel and
# StreamedViewOnlySurface the real viewer uses, and times the marker in each picture the decoder
# enqueued and the first display link tick after it (iphone-sim's sample-buffer clock). A view-only
# rd/1 session carries no input, so the app sends each input as a loopback datagram to the source
# (CMUX_RD_SURFACE_EVAL_INPUT, with a per-run token), which injects it on the Mac; the timer starts
# at that send. No netem: like iphone-sim, the link is the simulator's loopback path to hostd.
# Latency only (`caps`). The build and simulator helpers are iphone-sim's. The interface every
# target implements is in ../README.md.
set -euo pipefail
verb=$1
shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$EVAL_ROOT/cmux-next-ios"
backend_port=4105
input_port=4106

record_pid() {
  local pid=$1 file=$2
  echo "$pid" >"$file"
  LC_ALL=C ps -p "$pid" -o lstart= >"$file.start" || true
}

same_pid() {
  local file=$1 pid=$2 expected actual
  expected=$(cat "$file.start" 2>/dev/null) || return 1
  [[ -n "$expected" ]] || return 1
  actual=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [[ "$actual" == "$expected" ]]
}

stop_pid() {
  local file=$1
  [[ -f "$file" ]] || return 0
  local pid
  pid=$(cat "$file")
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # A reused PID is not the child this run recorded. Never signal it.
  if ! same_pid "$file" "$pid"; then
    rm -f "$file" "$file.start"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null || ! same_pid "$file" "$pid"; then
      rm -f "$file" "$file.start"
      return 0
    fi
    sleep 0.1 # bounded wait for the child to exit (5 s)
  done
  if same_pid "$file" "$pid" && kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$file" "$file.start"
}

# The iPhone app and simulator: iphone-sim's own, in this target's state directory.
sim() { bash "$here/iphone-sim.sh" "$@"; }

build_host() {
  local t0=$SECONDS rust="$ios/rust" tui="$EVAL_ROOT/cmux-tui"
  # hostd and the fake backend (from the rust workspace, so rustup takes its toolchain file).
  (cd "$rust" && cargo build --release -p cmux-mobile-host --features fake-backend \
    --bin cmux-mobile-host --bin cmux-mobile-fake-backend)
  local target
  target=$(cd "$rust" && cargo metadata --format-version 1 --no-deps | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
  cp "$target/release/cmux-mobile-host" "$EVAL_BIN/cmux-mobile-host"
  cp "$target/release/cmux-mobile-fake-backend" "$EVAL_BIN/cmux-mobile-fake-backend"
  # The source: the rd target's cmux-rd (surface-source), built as rd.sh builds it.
  (cd "$tui" && cargo build --release --manifest-path "$tui/crates/cmux-rd-host/Cargo.toml" --bin cmux-rd)
  cp "$tui/crates/cmux-rd-host/target/release/cmux-rd" "$EVAL_BIN/cmux-rd-surface"
  echo "iphone-link: host built in $((SECONDS - t0)) s"
}

host_start() {
  head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$EVAL_STATE/input-token"
  chmod 600 "$EVAL_STATE/input-token"
  mkdir -p "$EVAL_STATE/hostd"
  chmod 700 "$EVAL_STATE/hostd"
  : >"$EVAL_STATE/backend.log"
  "$EVAL_BIN/cmux-mobile-fake-backend" "127.0.0.1:$backend_port" >>"$EVAL_STATE/backend.log" 2>&1 &
  record_pid "$!" "$EVAL_STATE/backend.pid"
  for _ in $(seq 1 100); do
    grep -q 'cmux-mobile-fake-backend on' "$EVAL_STATE/backend.log" && break
    kill -0 "$(cat "$EVAL_STATE/backend.pid")" 2>/dev/null || break
    sleep 0.1 # bounded wait for the backend's line (10 s)
  done
  grep -q 'cmux-mobile-fake-backend on' "$EVAL_STATE/backend.log" || {
    echo "iphone-link: the fake backend did not start" >&2
    tail -20 "$EVAL_STATE/backend.log" >&2
    stop_pid "$EVAL_STATE/backend.pid"
    return 1
  }
  : >"$EVAL_STATE/host.log"
  # Every path hostd keeps state in is under this target's state, so nothing of the person's
  # (their cmux-mobile-host state, acpmux, terminal sockets) is read or written.
  env CMUX_MOBILE_BASE_URL="http://127.0.0.1:$backend_port" CMUX_MOBILE_TEAM_ID=eval \
    CMUX_MOBILE_ACCESS_TOKEN=user:eval CMUX_MOBILE_OWNER_USER_ID=eval \
    CMUX_MOBILE_DEVICE_ID=eval-mac CMUX_MOBILE_DEVICE_NAME="screen-stream-eval" \
    CMUX_MOBILE_STATE_DIR="$EVAL_STATE/hostd" CMUX_MOBILE_APP_SUPPORT_DIR="$EVAL_STATE/hostd/app-support" \
    CMUX_MOBILE_TUI_SOCKET_DIR="$EVAL_STATE/hostd/tui" CMUX_MOBILE_UPLOADS_DIR="$EVAL_STATE/hostd/uploads" \
    ACPMUX_HOME="$EVAL_STATE/hostd/acpmux" CMUX_MOBILE_RB_CACHE_DIR="$EVAL_STATE/hostd/rb" \
    CMUX_MOBILE_SURFACE_SOURCE="$EVAL_BIN/cmux-rd-surface" CMUX_MOBILE_MAC_DISPLAY=1 \
    CMUX_RD_SURFACE_EVAL_INPUT="127.0.0.1:$input_port" CMUX_RD_SURFACE_EVAL_TOKEN="$(cat "$EVAL_STATE/input-token")" \
    "$EVAL_BIN/cmux-mobile-host" >>"$EVAL_STATE/host.log" 2>&1 &
  record_pid "$!" "$EVAL_STATE/host.pid"
  for _ in $(seq 1 300); do
    grep -q 'signaling connected' "$EVAL_STATE/host.log" && return 0
    kill -0 "$(cat "$EVAL_STATE/host.pid")" 2>/dev/null || break
    sleep 0.1 # bounded wait for hostd's signaling socket (30 s)
  done
  echo "iphone-link: hostd did not connect to the fake backend" >&2
  tail -30 "$EVAL_STATE/host.log" >&2
  stop_pid "$EVAL_STATE/host.pid"
  stop_pid "$EVAL_STATE/backend.pid"
  return 1
}

one_mac_only() {
  if [[ -n "${EVAL_BIND:-}" || -n "${EVAL_PEER:-}" ]]; then
    echo "iphone-link: one Mac only (lan=/viewer-of= is not supported: the simulator runs beside the host)" >&2
    exit 1
  fi
}

case "$verb" in
  caps) echo latency-only ;;
  build)
    [[ -z "${EVAL_PREBUILT:-}" ]] || { echo "iphone-link: no prebuilt= mode (it builds the iPhone app)" >&2; exit 1; }
    one_mac_only
    build_host
    # The app (iphone-sim's build; it also builds the webrtc host, which this target leaves unused).
    sim build
    ;;
  host-start)
    one_mac_only
    host_start
    ;;
  host-stop)
    # Also the harness's exit trap. hostd stops its source (the lifeline: stdin closes).
    stop_pid "$EVAL_STATE/host.pid"
    stop_pid "$EVAL_STATE/backend.pid"
    sim host-stop || true
    ;;
  latency-view)
    # latency-view INPUT SAMPLES RAW
    one_mac_only
    input=$1 samples=$2 raw=$3
    kind=key
    [[ $input == pointer ]] && kind=click
    # The marker's fractions, as iphone-sim computes them.
    marker=$(sim fractions)
    link="http://127.0.0.1:$backend_port/?team=eval&device=eval-iphone&mac=eval-mac&token=user:eval&input=127.0.0.1:$input_port&key=$(cat "$EVAL_STATE/input-token")"
    udid=$(sim ensure-sim) || { echo "iphone-link: could not make, boot or install the simulator" >&2; exit 1; }
    set_dir=$(cat "$EVAL_STATE/sims")
    bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(cat "$EVAL_BIN/iphone-sim-app")/Info.plist")
    : >"$raw.app"
    SIMCTL_CHILD_CMUX_MOBILE_RD_LINK="$link" SIMCTL_CHILD_CMUX_MOBILE_SS_MARKER="$marker" \
      SIMCTL_CHILD_CMUX_MOBILE_SS_INPUT="$kind" SIMCTL_CHILD_CMUX_MOBILE_SS_SAMPLES="$samples" \
      xcrun simctl --set "$set_dir" launch --terminate-running-process --stdout="$raw.app" --stderr="$raw.app.err" "$udid" "$bundle" >/dev/null
    # Bounded: the dial plus 30 s to the first marker, then at most 1.2 s an input.
    limit=$((90 + samples * 12 / 10))
    for _ in $(seq 1 "$limit"); do
      grep -q '^iphonesim: ' "$raw.app" && break
      sleep 1 # bounded wait for the app's report line
    done
    xcrun simctl --set "$set_dir" terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    grep '^iphonesim: ' "$raw.app" >"$raw" || {
      echo "iphone-link: no report within $limit s" >&2
      tail -20 "$raw.app.err" >&2
      tail -30 "$EVAL_STATE/host.log" >&2
      exit 1
    }
    ;;
  latency-report)
    # latency-report INPUT RAW OUT
    input=$1 raw=$2 out=$3
    python3 -I - "$raw" "$out" <<'EOF'
import json, sys
line = next((l[len("iphonesim: "):] for l in reversed(open(sys.argv[1]).read().splitlines()) if l.startswith("iphonesim: ")), "")
raw = json.loads(line) if line.strip() else {}
decode = raw.get("decode_ms_mean")
def stat(d):
    d = d or {}
    return {"n": d.get("n"), "p50": d.get("p50"), "p95": d.get("p95")}
json.dump({
    "g2g_ms": raw.get("g2g_ms") or {}, "lost": raw.get("lost"),
    "split": {"input_to_capture_ms": None, "encode_ms": None, "transport_ms": None,
              "decode_ms": decode if isinstance(decode, (int, float)) and decode >= 0 else None,
              "method": "iphone-link: g2g = the app's input datagram to the source to the first present showing the counter "
                        "(AVSampleBufferDisplayLayer: the targetTimestamp of the first display link tick after BrowserVideoDecoder enqueued it, scheduled not measured); "
                        "rd/1 over the cmux link (WireGuard) from standalone cmux-mobile-host and cmux-rd surface-source; "
                        "decode = the app's StreamedBrowserModel meter (VideoToolbox decode, last second)",
              "present": {"presented_ms": stat(raw.get("g2g_ms")), "decoded_ms": stat(raw.get("decoded_g2g_ms")),
                          "decode_to_present_ms": stat(raw.get("decode_to_present_ms")),
                          "decoded_not_presented": raw.get("decoded_not_presented"),
                          "clock": raw.get("present_clock")}},
    "raw": raw,
}, open(sys.argv[2], "w"))
EOF
    ;;
  window-view | window-report) echo "iphone-link: latency only (caps: latency-only)" >&2; exit 2 ;;
  *) echo "iphone-link.sh: unknown verb $verb" >&2; exit 2 ;;
esac
