#!/usr/bin/env bash
# Fleet entry for the graceful web swap films and latency series (cmux#50535): what air-blue's capture runs measured
# (scripts/measure/graceful-swap.py over Cua Driver), on a fleet Mac's own GUI session instead of a person's laptop.
# Builds a tagged bench app at this checkout (Release optimization with the debug.* control commands, so the app's
# own recorder `debug.motion` record_start is there), brings up a 1x virtual main display, then runs
# scripts/measure/graceful-swap-fleet.py: a fresh HOME with the fake ACP agent as a harness, one window of
# sidebar | Settings | chat-a (focused, draft + image chip) | chat-b (unfocused, two-line draft) with chat-c hidden
# behind chat-b, one film per trigger (GRACEFUL_SWAP lines) and the edit-to-visible series on the dev server
# (GRACEFUL_SWAP_LATENCY lines: focused, unfocused, hidden). Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/graceful-swap-fleet.sh --ref <feat-cmux-next sha> --arg=--build-at=<sha under test> \
#     [--arg=--runs=20] [--arg=--films=a,b] [--arg=--series=composer,hidden,settings] [--arg=--config=bench] \
#     [--arg=--vdisplay=60] --artifact graceful-swap-fleet.tar
# --build-at=SHA builds the app at SHA with that commit's own reload.sh (scripts/measure/app-at-commit.sh: the fleet
# runs an unlisted measure script only at a commit on feat-cmux-next or main), and that commit's tree is the one the
# dev server serves, the saves edit and whose scripts/measure/graceful-swap.py analyzes the films (it must have one:
# cmux#50535's head or later). Without it, this checkout is built and used.
# Then: cmux-ci log STEP > step.log; scripts/bench/cmux-bench graceful-swap --import step.log (or each
# latency/*.json and runs/*/run.json in the artifact).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="gswfleet"
. scripts/measure/app-at-commit.sh
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
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" /opt/homebrew/bin /usr/local/bin; do
  [ -n "$tool_dir" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
# The analysis reads every film with ffmpeg and ffprobe (graceful-swap.py analyze).
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  HOMEBREW_NO_AUTO_UPDATE=1 "$(command -v brew || echo /opt/homebrew/bin/brew)" install ffmpeg >/dev/null 2>&1 || true
fi
command -v ffmpeg >/dev/null || { echo "graceful-swap-fleet: no ffmpeg on this worker" >&2; exit 1; }
reload_config=(--config bench) film_args=() vdisplay_hz="60" build_at=""
for arg in "$@"; do
  case "$arg" in
    --build-at=*) build_at="${arg#--build-at=}" ;;
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    *) film_args+=("$arg") ;;
  esac
done
vdisplay_pid="" app=""
# shellcheck disable=SC2329 # run by the trap below
cleanup() {
  [[ -n "$app" ]] && { python3 scripts/cmux-next/tag_teardown.py "$app" || true; }
  if [[ -n "$vdisplay_pid" ]]; then kill "$vdisplay_pid" 2>/dev/null || true; wait "$vdisplay_pid" 2>/dev/null || true; fi
  measure_remove_scratch "$out"
}
trap cleanup EXIT
started=$SECONDS
if [[ -n "$build_at" ]]; then
  app="$(measure_app_at_commit "$build_at" "$tag" "$out/at" "${reload_config[@]}" 2> "$out/reload.log")" || {
    tail -n 80 "$out/reload.log" >&2; exit 1; }
  tree="$out/at"
else
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" "${reload_config[@]}" > "$out/reload.log" 2>&1 || {
    tail -n 80 "$out/reload.log" >&2; exit 1; }
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  tree="$PWD"
fi
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "graceful-swap-fleet: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
echo "graceful-swap-fleet: harness $(git rev-parse HEAD), app at $(git -C "$tree" rev-parse HEAD): $app, built in $(( SECONDS - started )) s"
if [[ "$vdisplay_hz" != 0 ]]; then
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
    echo "graceful-swap-fleet: display: $(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo 'the virtual display never reported')"
    sleep 2  # WindowServer settles the new main display before the app opens on it
  else
    echo "graceful-swap-fleet: the virtual display helper did not compile; the films are of the real display"
  fi
fi
status=0
CMUX_BENCH_LAUNCH=direct python3 scripts/measure/graceful-swap-fleet.py --app "$app" --tree "$tree" --out "$out/gsw" \
  ${film_args[@]+"${film_args[@]}"} || status=$?
# The artifact: the trigger films and the first two of each latency series (with their frame times), every run's
# run.json, marks and transient frames, the latency receipts and the summary. The other latency films stay behind.
root="$PWD"
(cd "$out/gsw" && find . \( -path ./scratch -prune \) -o -type f \( -path './runs/*' -o -path './latency/*' -o -name summary.json \
    -o \( -path './films/*' ! -name '*-[0-9][0-9].mov*' \) -o -path './films/*-0[01].mov*' \) -print0 \
  | tar -cf "$root/graceful-swap-fleet.tar" --null -T -) || true
echo "graceful-swap-fleet: artifact $(du -h graceful-swap-fleet.tar 2>/dev/null | cut -f1)"
exit "$status"
