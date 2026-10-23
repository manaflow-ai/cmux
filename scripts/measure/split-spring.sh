#!/usr/bin/env bash
# Fleet entry for the rapid Cmd-D / Cmd-Shift-D run (split-spring): builds a tagged cmux-next app at this
# checkout, then runs scripts/cmux-next/split-spring-terminal.py against it (five splits 100 ms apart
# from one terminal with scrollback, optionally streaming; missed frames, frame intervals, layout work,
# grids sent to the PTY owner, hangs). Needs a logged-in console (an owned mini).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \
#     --ref <sha> --artifact artifacts/split-spring/report.json [--arg=--rounds=3] [--arg=--stream] [--arg=--gate]
# To time an older commit, revert the change on a scratch ref of the tip (the script blob must match the reviewed one).
#
# Options this script reads (the rest go to split-spring-terminal.py):
#   --app-cache     reuse this commit's app when an earlier step on this worker built it
#                   ($CI_SHARED_CACHE_DIR/split-spring-apps/<sha>), and keep it there after a build (the 3
#                   newest commits). The perf cron (scripts/cmux-next/perf-cron.py) builds once per measurement.
#   --build-only    build (or find) the app, keep it in the cache, measure nothing; report.json records the build.
#   --vdisplay=HZ   measure on a virtual display at HZ (scripts/ci/frame-pacing/vdisplay.m, the private
#                   CGVirtualDisplay API): it is the main display while the step runs, so the app opens on it.
#                   When it does not come up at that rate, the step measures on the real display and says so
#                   (VDISPLAY-FALLBACK); every bench report carries the refresh it saw.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
build_only=0 app_cache=0 vdisplay_hz="" args=()
for arg in "$@"; do
  case "$arg" in
    --build-only) build_only=1 app_cache=1 ;;
    --app-cache) app_cache=1 ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    *) args+=("$arg") ;;
  esac
done
tag="split-spring"
out="$(pwd)/artifacts/split-spring"
mkdir -p "$out"
sha="$(git rev-parse HEAD)"
cache=""
if [[ "$app_cache" == 1 && -n "${CI_SHARED_CACHE_DIR:-}" ]]; then
  cache="$CI_SHARED_CACHE_DIR/split-spring-apps"
fi
build_start=$SECONDS
app="" cached=false
if [[ -n "$cache" && -f "$cache/$sha/ok" ]]; then
  mkdir -p "$out/app"
  ditto "$cache/$sha/cmux DEV $tag.app" "$out/app/cmux DEV $tag.app"
  touch "$cache/$sha/ok"
  app="$out/app/cmux DEV $tag.app" cached=true
  echo "split-spring: the app of $sha from the app cache ($((SECONDS - build_start)) s)"
fi
if [[ -z "$app" ]]; then
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
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "split-spring: the tagged reload printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
    exit 1
  fi
  if [[ -n "$cache" ]]; then
    mkdir -p "$cache"
    rm -rf "${cache:?}/$sha.tmp"
    mkdir -p "$cache/$sha.tmp"
    if ditto "$app" "$cache/$sha.tmp/cmux DEV $tag.app"; then
      rm -rf "${cache:?}/$sha"
      mv "$cache/$sha.tmp" "$cache/$sha"
      touch "$cache/$sha/ok"
      # shellcheck disable=SC2012 # the directory names are 40-hex commit ids
      ls -1t "$cache"/*/ok 2>/dev/null | tail -n +4 | while read -r old; do rm -rf "$(dirname "$old")"; done
      echo "split-spring: kept the app of $sha in the app cache"
    fi
  fi
fi
build_seconds=$((SECONDS - build_start))
if [[ "$build_only" == 1 ]]; then
  printf '{"build": {"sha": "%s", "seconds": %d, "cached": %s}}\n' "$sha" "$build_seconds" "$cached" > "$out/report.json"
  cat "$out/report.json"
  exit 0
fi

vdisplay_pid=""
stop_vdisplay() {
  if [[ -n "$vdisplay_pid" ]]; then
    kill "$vdisplay_pid" 2>/dev/null || true
    vdisplay_pid=""
  fi
}
trap stop_vdisplay EXIT
if [[ -n "$vdisplay_hz" ]]; then
  vd="$out/vdisplay"
  mkdir -p "$vd/VDisplay.app/Contents/MacOS"
  line="error: the virtual display helper did not compile"
  if xcrun clang -fobjc-arc -O2 -Wno-deprecated-declarations -framework AppKit -framework CoreVideo \
      scripts/ci/frame-pacing/vdisplay.m -o "$vd/VDisplay.app/Contents/MacOS/VDisplay" 2> "$vd/clang.err"; then
    cp scripts/ci/frame-pacing/VDisplay-Info.plist "$vd/VDisplay.app/Contents/Info.plist"
    codesign -s - --force "$vd/VDisplay.app" 2>/dev/null || true
    "$vd/VDisplay.app/Contents/MacOS/VDisplay" "$vdisplay_hz" 3600 > "$vd/out" 2> "$vd/err" &
    vdisplay_pid=$!
    for _ in $(seq 20); do
      grep -q '^ready\|^error' "$vd/out" 2>/dev/null && break
      kill -0 "$vdisplay_pid" 2>/dev/null || break
      sleep 1  # bounded wait for the helper's own ready line
    done
    line="$(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo "error: the virtual display never reported ($(head -c 300 "$vd/err" 2>/dev/null || true))")"
  fi
  # `ready DISPLAY_ID P50_MS main=MAIN_ID`: the main display, ticking within 15 % of the rate.
  if python3 - "$line" "$vdisplay_hz" <<'PY'
import re, sys
m = re.match(r"ready (\d+) ([\d.]+) main=(\d+)", sys.argv[1])
period = 1000 / float(sys.argv[2])
sys.exit(0 if m and m.group(1) == m.group(3) and abs(float(m.group(2)) - period) <= 0.15 * period else 1)
PY
  then
    echo "split-spring: VDISPLAY ${vdisplay_hz} Hz main display ($line)"
    sleep 2  # let WindowServer settle the new main display before the app opens on it
  else
    echo "split-spring: VDISPLAY-FALLBACK no ${vdisplay_hz} Hz virtual display ($line); measuring on the real display"
    stop_vdisplay
  fi
  echo "$line" > "$out/display.txt"
fi

status=0
python3 scripts/cmux-next/split-spring-terminal.py --tag "$tag" --app "$app" --out "$out" --json "$out/report.json" \
  ${args[@]+"${args[@]}"} || status=$?
exit "$status"
