#!/usr/bin/env bash
# Fleet entry for the pane motion films: builds a tagged cmux-next app at this checkout, then runs
# scripts/measure/pane-motion-films.py against it: a session of many workspaces, then one movie for each pane act
# (a split, a zoom, a close, a held key, a drag), made by the app's own recorder (`debug.motion` record_start) with
# the keys through `debug.key` (real key events on the app's own queue; not the HID tap). The films are a record for
# a person to look at; nothing here judges a film. Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --label gui-session-v1 \
#     --script scripts/measure/pane-motion-films.sh --ref <sha> --arg=--config=bench --arg=--vdisplay=120 \
#     [--arg=--films=kinds] [--arg=--workspaces=N] [--arg=--live-shells=K] [--arg=--step-seconds=S] [--arg=--no-gate] \
#     --artifact pane-motion-films.tar
# --config=<debug|release|bench> picks reload.sh's build configuration (the recorder and the debug keys are in debug
# and bench builds), --vdisplay=HZ a virtual main display at HZ (as held-new-tab.sh; it is 1x), --step-seconds=S the
# step's own bound (a film with no time left before it is `not_run` in films.json, and the films so far still come
# back), --no-gate exit 0 when some films are made and some are not (an artifact comes back only from a passing step;
# a failed preflight and a run with no film stay exit 1); every other argument goes to pane-motion-films.py (its
# --launch-form picks how the app is launched and how the keys go). The artifact: films.json, each <id>.mov and its
# <id>.mov.frames.json.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="panefilm"
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
reload_config=() film_args=() vdisplay_hz="" gate=1 step_seconds=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    --step-seconds=*) step_seconds="${arg#--step-seconds=}" ;;
    --no-gate) gate=0 ;;
    *) film_args+=("$arg") ;;
  esac
done
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "pane-motion-films: the tagged reload printed no app path" >&2
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
    echo "pane-motion-films: display: $display"
    sleep 2  # WindowServer settles the new main display before the app opens on it
  else
    echo "pane-motion-films: the virtual display helper did not compile; the films are of the real display"
  fi
fi
# The films end 2 minutes before the step's bound (the build's time is in $SECONDS): the tar and the upload need them.
if [[ -n "$step_seconds" ]]; then film_args+=("--budget=$(( step_seconds - SECONDS - 120 > 60 ? step_seconds - SECONDS - 120 : 60 ))"); fi
status=0
python3 scripts/measure/pane-motion-films.py --app "$app" --out "$out/films" --display="$display" ${film_args[@]+"${film_args[@]}"} || status=$?
if [ -f "$out/films/films.json" ]; then
  (cd "$out/films" && find . -maxdepth 1 \( -name 'films.json' -o -name '*.mov' -o -name '*.mov.frames.json' \) -print0 \
    | tar -cf "$OLDPWD/pane-motion-films.tar" --null -T -) || true
  echo "pane-motion-films: artifact $(du -h pane-motion-films.tar 2>/dev/null | cut -f1)"
fi
# An artifact comes back only from a passing step: --no-gate passes a run with some films made and some not (the
# tool's exit 2). A failed preflight, and a run with no film, stay a failed step.
if [[ "$gate" == 0 && "$status" == 2 && -f pane-motion-films.tar ]]; then status=0; fi
exit "$status"
