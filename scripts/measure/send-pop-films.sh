#!/usr/bin/env bash
# Fleet entry for the sent-prompt pop's films (Leo 2026-11-22: "oh you better probably also watch that attachments
# and such are good too when the pop is there"): builds a tagged cmux-next app at this checkout, then runs
# scripts/measure/send-pop-films.py against it: one agent chat on the page's in-page mock, each prompt shape (one
# picture, four, a file chip, a big paste, a picture and text, a long prompt, a send while a reply streams) sent at
# each chat length, each filmed by the app's own recorder and judged by webviews/bench/send-pop-probe.js. Runs alone
# on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 \
#     --script scripts/measure/send-pop-films.sh --ref <sha> --arg=--config=bench --arg=--vdisplay=120 \
#     [--arg=--turns=4,1000] [--arg=--cases=image,images] [--arg=--no-gate] --artifact send-pop-films.tar
# --config and --vdisplay as pane-motion-films.sh; --no-gate passes a run whose films came back with a case that is
# not clean (the tool's exit 2), so the films return. The artifact: cases.json and each <turns>-<case>.mov.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="sendpop"
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
reload_config=() film_args=() vdisplay_hz="" gate=1
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    --no-gate) gate=0 ;;
    *) film_args+=("$arg") ;;
  esac
done
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "send-pop-films: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p "$out/films"
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
    echo "send-pop-films: display: $display"
    sleep 2  # WindowServer settles the new main display before the app opens on it
  else
    echo "send-pop-films: the virtual display helper did not compile; the films are of the real display"
  fi
fi
status=0
echo "send-pop-films: display: $display"
python3 scripts/measure/send-pop-films.py --app "$app" --out "$out/films" ${film_args[@]+"${film_args[@]}"} || status=$?
if [ -f "$out/films/cases.json" ]; then
  (cd "$out/films" && find . -maxdepth 1 \( -name 'cases.json' -o -name '*.mov' -o -name '*.mov.frames.json' -o -name 'app.log' \) -print0 \
    | tar -cf "$OLDPWD/send-pop-films.tar" --null -T -) || true
  echo "send-pop-films: artifact $(du -h send-pop-films.tar 2>/dev/null | cut -f1)"
fi
# An artifact comes back only from a passing step: --no-gate passes a run whose cases are not all clean (exit 2).
if [[ "$gate" == 0 && "$status" == 2 && -f send-pop-films.tar ]]; then status=0; fi
exit "$status"
