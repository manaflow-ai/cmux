#!/usr/bin/env bash
# Fleet entry for the instant-create bench (Cmd-N, Cmd-T, Cmd-D, Cmd-Shift-D): builds a tagged
# cmux-next DEBUG app at this checkout, then runs scripts/cmux-next/instant-new-surfaces-bench.py
# (key to visible frame and to daemon confirm, idle and under load). Runs alone on the worker
# because it launches an app and loads every core:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/instant-new-surfaces.sh --ref <sha> [--arg=--runs=12]
# The engine (decision 2026-11-16: each measure says its engine): the build requires Chromium, the default engine
# of a page, so a host with no engine fails at its build and gives no WebKit time by accident; the bench is asked
# for Chromium pages (`--page-engine=cef`: a New Tab page in another engine is an error of its row, not a number).
# `--allow-no-chromium` turns both off for a measure of WebKit (scripts/measure/require-chromium.sh).
# `--vdisplay=HZ` holds a virtual main display at HZ for the run (as held-new-tab.sh; it is 1x). The step's log has
# the build's form (scripts/measure/build-flags.py's `BUILD-FLAGS` line).
# One Cmd-T and one Cmd-N as the screen showed them, frame by frame, alone and 100 ms after another key, in a session
# of N workspaces (scripts/cmux-next/new_surface_screen.py; a report, with the kept pictures in the artifact):
#   cmux-ci run --class exclusive --label gui-session-v1 --label measure --script scripts/measure/instant-new-surfaces.sh \
#     --ref <sha> --arg=--bench=cmd-n-paint --arg=--screen --arg=--config=bench --arg=--vdisplay=120 \
#     --arg=--workspaces=<N> --arg=--live-shells=<K> --arg=--runs=10 --artifact artifacts/new-surface-screen.tgz
# Cmd-T to the new tab visible (key_to_visible_ms) and to a key typed into it echoing (typed_key_accepted_ms), each
# of N rounds a sample, as a JSON report (scripts/cmux-next/new-tab-startup-bench.py; cmuxterm-hq's new-tab-startup probe):
#   cmux-ci run --class exclusive --label measure --script scripts/measure/instant-new-surfaces.sh --ref <sha> \
#     --arg=--bench=new-tab-startup --arg=--config=bench --arg=--runs=10 --artifact artifacts/instant-new-surfaces.json
# That app is at the schema's defaults. `--arg=--window-look=KEY=VALUE,...` (scripts/cmux-next/window_look.py's
# words; a `+` between 2 words of a value is a space) gives the launch other settings, and the run ends before its
# session when the app does not show them.
# --build=SHA (also spelled --build-at=SHA, as chat-open.sh and cef-tab.sh) builds the app at SHA, 40 hex, a pull
# request's head or base, with that commit's own reload.sh (scripts/measure/app-at-commit.sh), and runs this
# checkout's bench against it: the controller runs this script only at a landed commit, so an unlanded pair is
# measured as one step per arm at the same landed commit.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/require-chromium.sh
. scripts/measure/app-at-commit.sh
require_chromium="$(measure_chromium_required "$@")"
ask_engine="$(measure_engine_asked "$@")"
build_sha=""
for arg in "$@"; do
  case "$arg" in
    --build=*|--build-at=*) build_sha="${arg#--build=}" build_sha="${build_sha#--build-at=}" ;;
  esac
done
if [[ -n "$build_sha" && ! "$build_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "instant-new-surfaces: --build=$build_sha: want a full 40-hex commit sha" >&2
  exit 2
fi
# A fleet checkout has no submodules or GhosttyKit yet (as scripts/measure/tab-switch.sh); a build at another commit
# fetches its own (measure_app_at_commit).
if [[ -z "$build_sha" ]]; then
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
fi
tag="instantnew"
out="$(mktemp -d)"
# Remove the scratch folder on every exit (a failed build, a TERM), not only at the end: a leaked one holds a build.
vdisplay_pid="" app="" screen=0
# shellcheck disable=SC2329 # run by the trap below
cleanup() {
  # --screen makes a session of many workspaces under this script's one tag, and its driver ends the app only when
  # Python ends by itself. So: end the tag's daemons and shells (as held-new-tab.sh), then move the tag's saved
  # session aside, and no later step of this tag starts in that session.
  if [[ "$screen" == 1 && -n "$app" ]]; then
    python3 scripts/cmux-next/tag_teardown.py "$app" || true
    python3 scripts/cmux-next/new_surface_screen.py --fresh-session "$tag" || true
  fi
  if [[ -n "$vdisplay_pid" ]]; then kill "$vdisplay_pid" 2>/dev/null || true; wait "$vdisplay_pid" 2>/dev/null || true; fi  # the helper this script started
  rm -rf -- "$out"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# --config=<debug|release|bench> picks reload.sh's build configuration (bench: Release optimization with the
# debug.* control commands kept), --vdisplay=HZ the display; every other argument goes to the bench.
reload_config=() bench_args=() vdisplay_hz=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    --allow-no-chromium|--build=*|--build-at=*) ;;
    --screen) screen=1; bench_args+=("$arg") ;;
    *) bench_args+=("$arg") ;;
  esac
done
# --screen counts frames of the display: a display that this script was asked for and did not get is no display to
# count on (below), and a rate that is no number above 0 stops the step here, before the build (the driver refuses
# such a --display-hz too, but only after the build). The match runs with LC_ALL=C (in a subshell, so the script's
# own locale stays): in a UTF-8 locale `[0-9]` also takes digits of other scripts. The driver's `float` takes those
# as a number and the display's helper reads its rate with `atof`, so the display and the asked rate could differ.
if [[ "$screen" == 1 && -n "$vdisplay_hz" ]] && ! (LC_ALL=C; [[ "$vdisplay_hz" =~ ^[0-9]+(\.[0-9]+)?$ && ! "$vdisplay_hz" =~ ^[0.]+$ ]]); then
  echo "instant-new-surfaces: --screen: --vdisplay=$vdisplay_hz is not a rate in Hz above 0" >&2
  exit 2
fi
# --window-look=WORDS (--screen: the launched app's settings, scripts/cmux-next/new_surface_look.py): words that the
# option refuses stop the step here, before the build, and not after it.
for arg in ${bench_args[@]+"${bench_args[@]}"}; do
  if [[ "$arg" == --window-look=* ]]; then
    if [[ "$screen" != 1 ]]; then
      echo "instant-new-surfaces: --window-look is an option of --screen" >&2
      exit 2
    fi
    python3 scripts/cmux-next/new_surface_look.py --check "${arg#--window-look=}" || exit 2
  fi
done
set -- ${bench_args[@]+"${bench_args[@]}"}
# Before the step's own arguments, so `--arg=--page-engine=webkit` wins over it. `--bench=` runs another bench on
# the same app, and that bench has no `--page-engine` (measure_engine_asked).
if [[ "$ask_engine" == 1 ]]; then
  set -- --page-engine=cef "$@"
fi
if [[ "$require_chromium" == 1 ]]; then
  echo "instant-new-surfaces: the build requires the Chromium engine (CMUX_NEXT_REQUIRE_CEF=1)"
else
  echo "instant-new-surfaces: --allow-no-chromium: the build may have no Chromium engine; each row says its page's engine"
fi
reload_status=0
if [[ -n "$build_sha" ]]; then
  echo "instant-new-surfaces: build $build_sha (bench at $(git rev-parse HEAD))"
  app="$(CMUX_NEXT_REQUIRE_CEF="$require_chromium" measure_app_at_commit "$build_sha" "$tag" "$out/at" \
    ${reload_config[@]+"${reload_config[@]}"})" || reload_status=$?
  if [[ "$reload_status" -ne 0 ]]; then
    measure_chromium_failure instant-new-surfaces "$out/at.reload.log" || true
    exit "$reload_status"
  fi
else
  echo "instant-new-surfaces: build $(git rev-parse HEAD)"
  CMUX_NEXT_REQUIRE_CEF="$require_chromium" CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log" || reload_status=$?
  if [[ "$reload_status" -ne 0 ]]; then
    measure_chromium_failure instant-new-surfaces "$out/reload.log" || true
    exit "$reload_status"
  fi
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
fi
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "instant-new-surfaces: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
# The form of the build, in the step's log. A fault of this read stops no measure: the line then says that the
# build's form was not read.
python3 scripts/measure/build-flags.py "$out/reload.log" --out "$out/build-flags.json" || true
display="real"
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
    echo "instant-new-surfaces: display: $display"
    # Until a new process sees the virtual display as its main display (what the app opens on), 15 s.
    # Only when the helper's ready line says it made the display main (main=ID).
    vd_id="$(sed -n 's/^ready \([0-9]*\) [0-9.]* main=\1 .*/\1/p' "$vd/out" 2>/dev/null | head -1 || true)"
    if [[ -n "$vd_id" ]]; then
      vd_main="" vd_deadline=$((SECONDS + 15))
      while (( SECONDS < vd_deadline )); do
        vd_main="$("$vd/VDisplay.app/Contents/MacOS/VDisplay" probe 2>/dev/null | awk '$1 == "main" {print $2}' || true)"
        [[ "$vd_main" == "$vd_id" ]] && break
        sleep 0.2
      done
      [[ "$vd_main" == "$vd_id" ]] || echo "warning: a new process still sees display ${vd_main:-?} as main, not the virtual display $vd_id, after 15 s" >&2
    fi
  else
    display="the virtual display helper did not compile"
    echo "instant-new-surfaces: the virtual display helper did not compile; measuring on the real display"
  fi
  if [[ "$screen" == 1 && "$display" != ready* ]]; then
    echo "instant-new-surfaces: --screen: no virtual display at $vdisplay_hz Hz ($display): its rows would be frames of another display" >&2
    exit 1
  fi
fi
mkdir -p artifacts
# --screen (cmd-n-paint-e2e.py's report of each key from the screen's frames) gets the display and the build's form
# for its report, and its window on the virtual display when this script made one (the main display: screen 0).
screen_args=()
if [[ "$screen" == 1 ]]; then
  screen_args=(--display="$display" --build "$out/build-flags.json" --screen-tgz artifacts/new-surface-screen.tgz)
  if [[ "$display" == ready* ]]; then screen_args+=(--display-hz "$vdisplay_hz" --window-screen 0); fi
fi
python3 scripts/cmux-next/instant-new-surfaces-bench.py --tag "$tag" --app "$app" --out "$out" \
  --json artifacts/instant-new-surfaces.json "$@" ${screen_args[@]+"${screen_args[@]}"}
