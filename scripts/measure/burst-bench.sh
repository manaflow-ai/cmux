#!/usr/bin/env bash
# Fleet entry for the burst bench (PL-burst): builds a tagged cmux-next app at this checkout, then runs
# scripts/cmux-next/burst-bench.py against it: bursts of Cmd-W, Cmd-D, Cmd-Shift-D, mixed, held Cmd-W and
# Cmd-Shift-L through the real key path, light and STRESS (a new app per phase); per press input to next commit
# p50/p95/p99/max, each press's fate (performed, swallowed by the close guard, cancelled, refused, lost), Chromium
# and STRESS shape validity, frames, and key -> PTY grid / first TUI output (`debug.burst`, so a Debug or
# --config=bench build). Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/burst-bench.sh --ref <sha> \
#     [--label macos-26] [--arg=--vdisplay=120] [--arg=--no-stress] [--arg=--presses=20] --artifact burst-bench.json
# --vdisplay=HZ runs the bench on a virtual main display at HZ (split-spring.sh's helper, 1920 x 1200: STRESS
# needs a display that holds its 4 x 3 grid and a 1000 pt window under the Dock); without it the bench measures on
# the host's display.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="burst"
# A fleet step checks out no submodules (only their empty gitlink directories): the app build needs
# Ghostty's headers and the ghostty-next tree, and GhosttyKit.xcframework (a prebuilt download).
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
# Steps run with a per-step HOME; the account's user-level tools (bun and node for the Debug
# build's web bundles) live under its real home (as perf-bench.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
# The web bundles need the bun webviews/package.json pins; a bench host's shared ~/.bun may hold
# another version (cmux20-bench: none). The step gets its own checked copy, first on PATH.
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
# --config=<debug|release|bench> picks reload.sh's build configuration (bench: Release optimization with the
# debug.* control commands kept); every other argument goes to the bench.
reload_config=() bench_args=() vdisplay_hz=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "burst-bench: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
vdisplay_pid=""
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
    echo "burst-bench: display: $(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo 'the virtual display never reported')"
    sleep 2  # WindowServer settles the new main display before the app opens on it
  else
    echo "burst-bench: the virtual display helper did not compile; measuring on the real display"
  fi
fi
status=0
python3 scripts/cmux-next/burst-bench.py --app "$app" --out "$out/bench" "$@" || status=$?
cp "$out/bench/report.json" "$PWD/burst-bench.json" 2>/dev/null || true
exit "$status"
