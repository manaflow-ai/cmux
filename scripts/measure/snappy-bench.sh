#!/usr/bin/env bash
# Fleet entry for snappy-bench (Leo 2026-11-25: "when you press enter, the stuff should just start playing. we dont
# need to wait/get blocked by anything on rendering."): builds a tagged cmux-next app at this checkout, then runs
# scripts/measure/snappy-bench.py against it: agent chats on the page's in-page mock, Enter to the sent row's frame,
# the reserved turn in that frame, layout shifts per send, first token and chat switch, under each duress (plain, a
# 1000-turn chat, 12 other chats open, offline). Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 \
#     --script scripts/measure/snappy-bench.sh --ref <sha> --arg=--config=bench --arg=--vdisplay=120 \
#     [--arg=--duress=none,offline] [--arg=--sends=12] [--arg=--cpu-load] --artifact snappy-bench.tar
# --cpu-load runs a `yes` on every core while it measures (host-line-shift-duress.sh's load). The artifact:
# snappy.json (schema snappy-bench/v1) and app.log; the last stdout line is the rows. The perf cron runs the same
# bench as its chat-snappy part (split-spring --suite=chat-snappy).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="snappy"
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
# copy of the bun that webviews/package.json pins, first on PATH (as held-new-tab.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
reload_config=() film_args=() vdisplay_hz="" cpu_load=0
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    --cpu-load) cpu_load=1; film_args+=("$arg") ;;
    *) film_args+=("$arg") ;;
  esac
done
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "snappy-bench: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p "$out/run"
load_pids=()
vdisplay_pid="" display="real"
# shellcheck disable=SC2329 # run by the trap below
cleanup() {
  python3 scripts/cmux-next/tag_teardown.py "$app" || true
  for pid in ${load_pids[@]+"${load_pids[@]}"}; do kill "$pid" 2>/dev/null || true; done  # the load this script started
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
    echo "snappy-bench: display: $display"
    sleep 2  # WindowServer settles the new main display before the app opens on it
  else
    echo "snappy-bench: the virtual display helper did not compile; it measures on the real display"
  fi
fi
if [[ "$cpu_load" == 1 ]]; then
  for _ in $(seq "$(sysctl -n hw.ncpu)"); do yes > /dev/null & load_pids+=($!); done
  echo "snappy-bench: CPU load: ${#load_pids[@]} spinners"
fi
status=0
echo "snappy-bench: display: $display"
python3 scripts/measure/snappy-bench.py --app "$app" --out "$out/run" ${film_args[@]+"${film_args[@]}"} || status=$?
if [ -f "$out/films/snappy.json" ]; then
  (cd "$out/run" && find . -maxdepth 1 \( -name 'snappy.json' -o -name 'app.log' \) -print0 \
    | tar -cf "$OLDPWD/snappy-bench.tar" --null -T -) || true
  echo "snappy-bench: artifact $(du -h snappy-bench.tar 2>/dev/null | cut -f1)"
fi
exit "$status"
