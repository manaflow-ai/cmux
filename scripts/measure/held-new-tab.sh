#!/usr/bin/env bash
# Fleet entry for the held new tab measure: builds a tagged cmux-next app at this checkout, then runs
# scripts/measure/held-new-tab.py against it: a session of many workspaces, then Cmd-T held with a Cmd-W now and
# then, Cmd-T held alone and Cmd-W held, through `debug.key` (real key events on the app's own queue; not the HID
# tap). Per row: each key's fate, input to next commit, frames, the daemon's requests. Runs alone on the worker
# because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure [--label gui-session-v1] \
#     --script scripts/measure/held-new-tab.sh --ref <sha> --arg=--config=bench --arg=--vdisplay=120 \
#     [--arg=--workspaces=N] [--arg=--repeat-delay-ms=MS] [--arg=--repeat-ms=MS] [--arg=--film] [--arg=--no-gate] \
#     [--arg=--launch-form=auto|activate|one-key] [--arg=--allow-no-chromium] --artifact held-new-tab.tgz
# A step brings back ONE --artifact (of 2 the client keeps the last): held-new-tab.tgz is the report, each take's
# record and signpost stream, and with --film frames.json and each fifth JPEG frame; held-new-tab.json is the report
# alone (the bench `newtab` asks for that one).
# --config=<debug|release|bench> picks reload.sh's build configuration, --vdisplay=HZ a virtual main display at HZ
# (as burst-bench.sh; the helper is this script's own, no label gives it), --film one more take as JPEG frames,
# --no-gate exit 0 when a row did not measure what it names and each round still has a valid row (the tool's exit 2).
# A failed preflight and a round with no valid row stay a failed step.
# NO artifact comes back from a failed step. A step fails at the tool's exit 1, at its exit 2 without --no-gate (a
# fault of the wider take or of a restore alone gives exit 2 also), and at its exit 3 (the tool writes no report
# then). What comes back in each case is the step's log: the lines HELD-NEW-TAB-ROW (one for each row) and
# HELD-NEW-TAB (the whole report) at exit 1 and 2, the tool's NOT RUN line at exit 3.
# The build requires the Chromium page engine (CMUX_NEXT_REQUIRE_CEF=1): without its artifact the reload fails and no
# row is measured. --allow-no-chromium turns that off: the build then has no Chromium, each page is a WebKit page,
# and the tool's line `PREFLIGHT page engine:` and the report's `page_engine` say so.
# Every other argument goes to held-new-tab.py. The label gui-session-v1 adds a console session with a screen
# that is not locked; without it the tool's preflight says in 2 minutes for each launch form if the display link
# gives frames and if a key makes a tab.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="heldtab"
# A fleet step checks out no submodules: the app build needs Ghostty's headers, the ghostty-next tree and
# GhosttyKit.xcframework (a prebuilt download).
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
out="$(mktemp -d)"
# Steps run with a per-step HOME: bun and node live under the account's real home, and the step gets its own
# copy of the bun that webviews/package.json pins, first on PATH (as burst-bench.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
reload_config=() measure_args=() vdisplay_hz="" gate=1 require_cef=1
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    --film) measure_args+=(--film "$out/film") ;;
    --no-gate) gate=0 ;;
    --allow-no-chromium) require_cef=0 ;;
    *) measure_args+=("$arg") ;;
  esac
done
# CMUX_NEXT_REQUIRE_CEF=1: a missing CEF artifact fails the build here (embed-cef.sh otherwise builds an app without
# Chromium and exits 0, and the rows would then measure tabs with another page engine and not say so in the build).
CMUX_NEXT_REQUIRE_CEF="$require_cef" CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" \
  ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "held-new-tab: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
vdisplay_pid="" display="real"
# shellcheck disable=SC2329 # run by the trap below
cleanup() {
  python3 scripts/cmux-next/tag_teardown.py "$app" || true
  if [[ -n "$vdisplay_pid" ]]; then kill "$vdisplay_pid" 2>/dev/null || true; wait "$vdisplay_pid" 2>/dev/null || true; fi  # the helper this script started
}
trap cleanup EXIT
if [[ -n "$vdisplay_hz" ]]; then
  vd="$out/vdisplay"
  mkdir -p "$vd/VDisplay.app/Contents/MacOS"
  if xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
      scripts/ci/frame-pacing/vdisplay.m -o "$vd/VDisplay.app/Contents/MacOS/VDisplay" 2> "$vd/clang.err"; then
    cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/VDisplay.app/Contents/Info.plist"
    codesign -s - --force "$vd/VDisplay.app" 2>/dev/null || true
    "$vd/VDisplay.app/Contents/MacOS/VDisplay" "$vdisplay_hz" 3600 main 1920x1200 > "$vd/out" 2> "$vd/err" &
    vdisplay_pid=$!
    for _ in $(seq 20); do
      grep -q '^ready\|^error' "$vd/out" 2>/dev/null && break
      kill -0 "$vdisplay_pid" 2>/dev/null || break
      sleep 1  # bounded wait for the helper's own ready line
    done
    display="$(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo 'the virtual display never reported')"
    echo "held-new-tab: display: $display"
    sleep 2  # WindowServer settles the new main display before the app opens on it
  else
    echo "held-new-tab: the virtual display helper did not compile; measuring on the real display"
  fi
fi
status=0
python3 scripts/measure/held-new-tab.py --app "$app" --out "$out/measure" --display="$display" \
  --artifact "$PWD/held-new-tab.tgz" ${measure_args[@]+"${measure_args[@]}"} || status=$?
cp "$out/measure/report.json" "$PWD/held-new-tab.json" 2>/dev/null || true
# An artifact comes back only from a passing step: --no-gate passes a run in which each round has a valid row (the
# tool's exit 2). A failed preflight, and a round with no valid row, stay a failed step: the log's HELD-NEW-TAB
# lines are then all that comes back (the header).
if [[ "$gate" == 0 && "$status" == 2 && -f held-new-tab.json ]]; then status=0; fi
exit "$status"
