#!/usr/bin/env bash
# Screen stream eval target: the iPhone app's own viewer. The host is the `webrtc` target's
# (`cmux-vnc-host --capture`, default device hub signaling); the viewer is the cmux-next iPhone app
# (cmux-next-ios, Demo configuration: optimized, with the DEBUG developer surface) in an iOS
# simulator on the same Mac, opened on the host's pairing link (`CMUX_MOBILE_SS_LINK`,
# ScreenSharingLinkRoot) and timing the marker in the app's own ScreenSessionView. Each input is
# timed to the first decoded frame and to the first present that shows the next counter
# (ScreenPresentProbe; the simulator's Metal reports no presents, so with an RTCMTLVideoView or an
# AVSampleBufferDisplayLayer it is the scheduled scan-out, the targetTimestamp of the first display link
# tick after the draw or enqueue; present.clock.renderer says which); g2g_ms is the presented one. The simulator runs on the Mac's
# clock (CACurrentMediaTime), so no offset is needed. Latency only: `caps` prints latency-only, and
# the harness runs no window or OCR repeats for it. The interface every target implements is in
# ../README.md.
set -euo pipefail
verb=$1
shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$EVAL_ROOT/cmux-next-ios"

# The simulator device set: under /tmp, since a deep path overflows CoreSimulator's socket paths.
sims() { cat "$EVAL_STATE/sims" 2>/dev/null || true; }
simctl() { xcrun simctl --set "$(sims)" "$@"; }

# The runtime and iPhone: the fleet's declared runtime (CMUX_CI_IOS_SIM_RUNTIME), else the newest
# installed. A Mac without an iOS simulator runtime stops here, naming what it has.
pick_sim() {
  xcrun simctl list -j runtimes devicetypes | python3 -I "$EVAL_ROOT/scripts/ci/ios_sim_runtime.py" || {
    echo "iphone-sim: no usable iOS simulator runtime on this Mac; it has:" >&2
    xcrun simctl runtime list >&2 2>&1 || xcrun simctl list runtimes >&2 || true
    echo "iphone-sim: install one (xcodebuild -downloadPlatform iOS) or run on a Mac that has it" >&2
    return 3
  }
}

# The host: the webrtc target's build, run in place (it loads WebRTC.framework from beside it).
build_host() {
  local package="$EVAL_ROOT/Packages/Shared/CmuxVNCWebRTC"
  swift build -c release --package-path "$package" --product cmux-vnc-host
  printf '#!/bin/sh\nexec "%s/cmux-vnc-host" "$@"\n' "$(swift build -c release --package-path "$package" --show-bin-path)" \
    >"$EVAL_BIN/cmux-vnc-host"
  chmod +x "$EVAL_BIN/cmux-vnc-host"
}

build_app() {
  local t0=$SECONDS
  pick_sim >"$EVAL_STATE/sim-choice" || return 3
  echo "iphone-sim: simulator $(cat "$EVAL_STATE/sim-choice")"
  # The app's Rust link: the worker's source-keyed cache (scripts/ci/ios_ffi_cache.py), else a build.
  local key=""
  key=$(cd "$EVAL_ROOT" && python3 -I scripts/ci/ios_ffi_cache.py key "$EVAL_ROOT" "$EVAL_STATE/ffi-inputs.json" 2>/dev/null) || key=""
  if [[ "$key" =~ ^[0-9a-f]{64}$ ]] && (cd "$EVAL_ROOT" && python3 -I scripts/ci/ios_ffi_cache.py restore "$EVAL_ROOT" "$key") &&
    [[ -f "$ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework/Info.plist" ]]; then
    echo "iphone-sim: FFI from cache ${key:0:12}"
  else
    (cd "$EVAL_ROOT" && JOBS="${JOBS:-8}" bash cmux-next-ios/rust/scripts/build-xcframework.sh)
  fi
  # xcodegen, the release cmux-next-ios-sim.sh pins (checksum-verified).
  local xg="$EVAL_STATE/xcodegen" version=2.46.0 sha=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
  rm -rf "$xg"
  mkdir -p "$xg"
  bash "$EVAL_ROOT/scripts/ci/fetch-xcodegen.sh" "$version" "$sha" "$xg" >/dev/null || return 1
  (cd "$ios" && "$xg/xcodegen/bin/xcodegen" generate -q)
  # Demo: optimized like Release, with DEBUG (the link viewer and the probe exist only there).
  # $(inherited) is xcodebuild's, not the shell's.
  # shellcheck disable=SC2016
  xcodebuild -project "$ios/CmuxMobileApp.xcodeproj" -scheme CmuxMobileApp -configuration Demo \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$EVAL_STATE/dd" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO' build >"$EVAL_STATE/xcodebuild.log" 2>&1 || {
    grep -E "error:" "$EVAL_STATE/xcodebuild.log" | sort -u | head -40 >&2
    tail -30 "$EVAL_STATE/xcodebuild.log" >&2
    return 1
  }
  local app="$EVAL_STATE/dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app"
  [[ -d "$app" ]] || { echo "iphone-sim: no app at $app" >&2; return 1; }
  echo "$app" >"$EVAL_BIN/iphone-sim-app"
  echo "iphone-sim: built in $((SECONDS - t0)) s"
}

# ensure_sim: the target's one iPhone, created and booted on first use, then installed with the app.
# It runs in $(...), where set -e is off (bash 3.2), so every step checks its own result. The set's
# path is recorded before anything is made in it, so host-stop (and the harness's exit trap) can
# remove whatever a failed step left; the udid is recorded only once the app is installed.
ensure_sim() {
  if [[ -s "$EVAL_STATE/udid" ]]; then cat "$EVAL_STATE/udid"; return 0; fi
  local runtime device_type udid set
  read -r runtime device_type <"$EVAL_STATE/sim-choice" || return 1
  [[ -n "$runtime" && -n "$device_type" ]] || { echo "iphone-sim: no simulator choice from build" >&2; return 1; }
  if [[ -z "$(sims)" ]]; then
    # One fixed set per checkout (a short /tmp path: CoreSimulator's sockets live inside it), not a
    # fresh folder per run: this script runs once per verb, so no EXIT trap here can own it; host-stop
    # (also from the harness's exit trap) removes it, and a run it misses leaves this one folder, which
    # the next run reuses. The name is guessable, so the folder is made 0700 and used only if this
    # account owns it and it is not a symlink: a folder another account made first is refused.
    set="/tmp/iphsim.$(printf %s "$EVAL_STATE" | shasum | cut -c1-10)"
    mkdir -m 700 "$set" 2>/dev/null || [[ -d "$set" ]] || return 1
    [[ -O "$set" && ! -L "$set" ]] || { echo "iphone-sim: $set is not this account's own folder" >&2; return 1; }
    echo "$set" >"$EVAL_STATE/sims" || return 1
  fi
  udid=$(simctl create screen-eval-iphone "$device_type" "$runtime") || return 1
  [[ -n "$udid" ]] || { echo "iphone-sim: simctl create printed no udid" >&2; return 1; }
  simctl bootstatus "$udid" -b >&2 || return 1
  simctl install "$udid" "$(cat "$EVAL_BIN/iphone-sim-app")" >&2 || return 1
  echo "$udid" >"$EVAL_STATE/udid" || return 1
  echo "$udid"
}

# delete_sims: every simulator in the target's set, then the set itself (cmux-next-ios-sim.sh's cleanup).
delete_sims() {
  local set
  set=$(sims)
  [[ -n "$set" ]] || return 0
  xcrun simctl --set "$set" shutdown all >/dev/null 2>&1 || true
  xcrun simctl --set "$set" delete all >/dev/null 2>&1 || true
  # Only the set this target made: a /tmp/iphsim.* directory.
  [[ "$set" == /tmp/iphsim.* ]] && rm -rf "$set"
  rm -f "$EVAL_STATE/sims" "$EVAL_STATE/udid"
}

# Two Macs: the viewer Mac would build and boot its own simulator, which nothing on the host Mac
# could stop. Refused until that is designed; one Mac only.
one_mac_only() {
  if [[ -n "${EVAL_BIND:-}" || -n "${EVAL_PEER:-}" ]]; then
    echo "iphone-sim: one Mac only (lan=/viewer-of= is not supported: the simulator runs beside the host)" >&2
    exit 1
  fi
}

# The marker's geometry as fractions of the frame, as the webrtc target computes it.
fractions() {
  local geometry width cell origin top display
  geometry=$(grep -m1 "stream width" "$EVAL_MARKER_LOG")
  width=${geometry#*stream width }
  width=${width%% *}
  cell=${geometry#*cell }
  cell=${cell%% pt*}
  origin=$(grep -m1 marker-origin "$EVAL_MARKER_LOG")
  top=${origin#marker-origin 0,}
  top=${top%% *}
  display=${geometry#*display \(}
  display=${display%\)*}
  python3 -I -c '
import sys
width, cell, top = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
dw, dh = map(float, sys.argv[4].split(","))
print(f"{cell / dw},{top / (int(width * dh / dw) & ~1)}")' "$width" "$cell" "$top" "$display"
}

case "$verb" in
  caps) echo latency-only ;;
  build)
    [[ -z "${EVAL_PREBUILT:-}" ]] || { echo "iphone-sim: no prebuilt= mode (it builds the iPhone app)" >&2; exit 1; }
    one_mac_only
    build_host
    build_app
    ;;
  app-build)
    # The iPhone app alone, for a host that is not on this Mac (ios-linux-screen-e2e.yml: a Linux
    # cmux-rd host on the dev device hub).
    build_app
    ;;
  host-start)
    one_mac_only
    # The webrtc target's host, in this target's own state directory.
    bash "$here/webrtc.sh" host-start
    ;;
  host-stop)
    # Also the harness's exit trap: the simulator lives from the first latency view to here.
    bash "$here/webrtc.sh" host-stop || true
    delete_sims
    ;;
  latency-view)
    # latency-view INPUT SAMPLES RAW
    one_mac_only
    input=$1 samples=$2 raw=$3
    kind=key
    [[ $input == pointer ]] && kind=click
    marker=$(fractions)
    link=$(grep -m1 -o 'cmux-vnc://pair[^ ]*' "$EVAL_STATE/host.log")
    udid=$(ensure_sim) || { echo "iphone-sim: could not make, boot or install the simulator" >&2; exit 1; }
    bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(cat "$EVAL_BIN/iphone-sim-app")/Info.plist")
    : >"$raw.app"
    SIMCTL_CHILD_CMUX_MOBILE_SS_LINK="$link" SIMCTL_CHILD_CMUX_MOBILE_SS_MARKER="$marker" \
      SIMCTL_CHILD_CMUX_MOBILE_SS_INPUT="$kind" SIMCTL_CHILD_CMUX_MOBILE_SS_SAMPLES="$samples" \
      simctl launch --terminate-running-process --stdout="$raw.app" --stderr="$raw.app.err" "$udid" "$bundle" >/dev/null
    # Bounded: 30 s to the first marker, then at most 1.2 s an input (1 s loss deadline, 160 ms gap).
    limit=$((60 + samples * 12 / 10))
    for _ in $(seq 1 "$limit"); do
      grep -q '^iphonesim: ' "$raw.app" && break
      sleep 1 # bounded wait for the app's report line
    done
    simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    grep '^iphonesim: ' "$raw.app" >"$raw" || { echo "iphone-sim: no report within $limit s" >&2; tail -20 "$raw.app.err" >&2; exit 1; }
    ;;
  hub-view)
    # hub-view DEVICE INPUT SAMPLES RAW: the app signed in from $EVAL_REFRESH_TOKEN_FILE (a 0600 file
    # holding a Stack refresh token of the host's account), opens the account's hub device DEVICE (its id,
    # or its name in this DEBUG build) with control on, and times INPUT on the cmux-rd marker (cmux.rd/1,
    # MacScreenRdView). The Linux host's marker is 20 cells of 32 px at (0,0); EVAL_HUB_MARKER is its
    # cell width and top as fractions of the frame (default: a 1280 px wide screen).
    device=$1 input=$2 samples=$3 raw=$4
    kind=key
    [[ $input == pointer ]] && kind=click
    [[ -r "${EVAL_REFRESH_TOKEN_FILE:-}" ]] || { echo "iphone-sim: hub-view needs EVAL_REFRESH_TOKEN_FILE" >&2; exit 2; }
    hub=${EVAL_HUB_URL:-https://cmux-device-hub-dev.debussy.workers.dev}
    marker=${EVAL_HUB_MARKER:-0.025,0}
    link="cmux://mac-screen?device=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$device")&control=1"
    udid=$(ensure_sim) || { echo "iphone-sim: could not make, boot or install the simulator" >&2; exit 1; }
    bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(cat "$EVAL_BIN/iphone-sim-app")/Info.plist")
    : >"$raw.app"
    # The token goes to the app through simctl's child environment, never argv; this shell's copy is
    # read from the file only for this one command.
    SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN="$(cat "$EVAL_REFRESH_TOKEN_FILE")" \
      SIMCTL_CHILD_CMUX_MOBILE_DEVICE_HUB_URL="$hub" SIMCTL_CHILD_CMUX_MOBILE_OPEN_URL="$link" \
      SIMCTL_CHILD_CMUX_MOBILE_SS_MARKER="$marker" SIMCTL_CHILD_CMUX_MOBILE_SS_INPUT="$kind" \
      SIMCTL_CHILD_CMUX_MOBILE_SS_SAMPLES="$samples" \
      simctl launch --terminate-running-process --stdout="$raw.app" --stderr="$raw.app.err" "$udid" "$bundle" \
      -cmuxMobile.setupComplete YES >/dev/null
    # Bounded: sign-in, the hub list and the session take up to 90 s, then at most 1.2 s an input.
    limit=$((120 + samples * 12 / 10))
    for _ in $(seq 1 "$limit"); do
      grep -q '^iphonesim: ' "$raw.app" && break
      sleep 1 # bounded wait for the app's report line
    done
    simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    grep '^iphonesim: ' "$raw.app" >"$raw" || { echo "iphone-sim: no report within $limit s" >&2; tail -40 "$raw.app.err" >&2; exit 1; }
    ;;
  sims-delete)
    delete_sims
    ;;
  latency-report)
    # latency-report INPUT RAW OUT: RAW.span cuts the host's encode lines to the view.
    input=$1 raw=$2 out=$3
    python3 -I - "$raw" "$out" "$EVAL_STATE/encode.jsonl" "$raw.span" <<'EOF'
import json, os, sys
line = next((l[len("iphonesim: "):] for l in reversed(open(sys.argv[1]).read().splitlines()) if l.startswith("iphonesim: ")), "")
raw = json.loads(line) if line.strip() else {}
span = json.load(open(sys.argv[4])) if os.path.exists(sys.argv[4]) else {}
lines = [json.loads(l) for l in open(sys.argv[3]) if l.strip()] if os.path.exists(sys.argv[3]) else []
if span:
    lines = [l for l in lines if span["start_unix_ms"] <= l["unix_ms"] <= span["end_unix_ms"]]
encode = None
if len(lines) >= 2 and lines[-1]["encoded"] > lines[0]["encoded"]:
    a, b = lines[0], lines[-1]
    encode = (b["mean_ms"] * b["encoded"] - a["mean_ms"] * a["encoded"]) / (b["encoded"] - a["encoded"])
rtt, jitter = raw.get("rtt_ms"), raw.get("jitter_buffer_ms")
transport = rtt / 2 + max(jitter, 0) if isinstance(rtt, (int, float)) and rtt >= 0 and isinstance(jitter, (int, float)) else None
decode = raw.get("decode_ms_mean")
def stat(d):
    d = d or {}
    return {"n": d.get("n"), "p50": d.get("p50"), "p95": d.get("p95")}
json.dump({
    "g2g_ms": raw.get("g2g_ms") or {}, "lost": raw.get("lost"),
    "split": {"input_to_capture_ms": None, "encode_ms": encode, "transport_ms": transport,
              "decode_ms": decode if isinstance(decode, (int, float)) and decode >= 0 else None,
              "method": "iphone-sim: g2g = the app's send to the first present showing the counter (present.clock.renderer: RTCMTLVideoView, the targetTimestamp of the first display link tick after the draw, as the simulator's Metal reports no presents; "
                        "AVSampleBufferDisplayLayer, the targetTimestamp of the first display link tick after enqueue, scheduled not measured); "
                        "encode = host totalEncodeTime/framesEncoded over the run, transport = rtt/2 + the app's jitter buffer, decode = the app's totalDecodeTime/framesDecoded over the run",
              "present": {"presented_ms": stat(raw.get("g2g_ms")), "decoded_ms": stat(raw.get("decoded_g2g_ms")),
                          "decode_to_present_ms": stat(raw.get("decode_to_present_ms")),
                          "decoded_not_presented": raw.get("decoded_not_presented"),
                          "clock": raw.get("present_clock")}},
    "raw": raw,
}, open(sys.argv[2], "w"))
EOF
    ;;
  window-view | window-report) echo "iphone-sim: latency only (caps: latency-only)" >&2; exit 2 ;;
  *) echo "iphone-sim.sh: unknown verb $verb" >&2; exit 2 ;;
esac
