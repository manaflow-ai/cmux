#!/usr/bin/env bash
# A real Sparkle update of cmux NEXT whose Restart to Update comes a few seconds after the update staged (Leo's
# NIGHTLY: staged 22:07:57Z, clicked 22:08:00Z), base vs head built and run on one Mac (goal next-launch-instant,
# CMUX-571). Each side builds a bench app (--config bench: the update harness's marks); the update harness
# (scripts/cmux-next/update-harness/run.py --click-at-stage --click-delay N) runs a copy of it as v1 and updates it to
# a newer copy of itself, so the running build's updater is the side's own, and so is the launch after the update.
# Rounds interleave: base 1, head 1, base 2, ...
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/update-click-ab.sh --ref <a feat-cmux-next commit with this file> \
#     --arg=base=<sha> --arg=head=<sha> [--arg=rounds=3] [--arg=click_delay=3] \
#     --artifact .build/update-click-ab/report.tgz --timeout 7200
#   base=SHA, head=SHA  40-hex commits; head defaults to the checkout
#   rounds=N            1 to 10 (default 3); click_delay=S  seconds from staged to the click (default 3)
#   stress=K            K busy loops per core during each update (default 0), for a Mac as loaded as Leo's
#   frames=1            judge each update for transition frames (ask-ad4a68e740, scripts/measure/update_frames.py): a
#                       window log every 8 ms (update-frames/watch.swift, no grant) and a display recording (CuaDriver,
#                       when the Mac has it); prints UCF <side> <round> {...} and the medians gain the verdicts
# Prints UCA <side> <round> {...} per update and UCA-MEDIAN <side> {...} (scripts/measure/update-click-ab.py), in ms:
# click_to_relaunch (install_clicked to will_relaunch), click_to_v1_exit, prewarm_wait, prewarm_total (the pre-warm's
# own "N ms in all", when it ended before the relaunch), v2_first_frame and
# v2_home_first_page (from v2's process start), click_to_home (install_clicked to v2's Home first page).
set -uo pipefail

# One function, called on the last line: bash has read all of it before a checkout changes this file.
main() {
  cd "$(dirname "$0")/../.." || exit 3
  source scripts/measure/build-progress.sh
  local out="$PWD/.build/update-click-ab" tools
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  # The harness and summary as of this commit, whatever the sides' trees hold.
  tools="$out/tools" && mkdir -p "$tools" && cp -R scripts/cmux-next/update-harness "$tools/" && cp scripts/measure/update-click-ab.py "$tools/" \
    && cp scripts/cmux-next/tag_teardown.py scripts/cmux-next/state_wait.py "$tools/"  # run.py and idle_e2e.py import them from their parent folder
  local base="" head rounds=3 delay=3 stress=0 frames=0 arg rc=0 i side
  head="$(git rev-parse HEAD)"
  local checkout="$head"
  for arg in "$@"; do
    case "$arg" in
      base=*) base="${arg#base=}" ;;
      head=*) head="${arg#head=}" ;;
      rounds=*) rounds="${arg#rounds=}" ;;
      click_delay=*) delay="${arg#click_delay=}" ;;
      stress=*) stress="${arg#stress=}" ;;
      frames=*) frames="${arg#frames=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$rounds" =~ ^([1-9]|10)$ ]] || { echo "rounds= must be 1 to 10" >&2; exit 2; }
  [[ "$delay" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "click_delay= takes seconds" >&2; exit 2; }
  [[ "$stress" =~ ^[0-9]{1,2}$ ]] || { echo "stress= takes busy loops per core, 0 to 99" >&2; exit 2; }
  [[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "base= and head= take 40-hex commits" >&2; exit 2; }
  echo "UCA host chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  for side in base head; do
    local sha="$base"
    [[ "$side" == head ]] && sha="$head"
    fetch_checkout "$sha" || exit 3
    build_app "$out" "$side" || { git -c advice.detachedHead=false checkout --quiet --detach "$checkout"; exit 3; }
  done
  git -c advice.detachedHead=false checkout --quiet --detach "$checkout" || exit 3
  [[ "$frames" == 1 ]] && { frame_tools "$tools" || frames=0; }
  for ((i = 1; i <= rounds; i++)); do
    for side in base head; do
      echo "UCA-ROUND $i $side"
      [[ "$frames" == 1 ]] && start_frames "$out/frames-$side-$i" "$tools"
      start_stress "$stress"
      GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$tools/update-harness/run.py" \
        --app "$out/$side/cmux DEV ucab.app" --tag ucab --out "$out/run-$side-$i" --click-at-stage --click-delay "$delay" \
        2>&1 | tee -a "$out/run.log" | sed "s/^/[$side] /"
      [[ ${PIPESTATUS[0]} == 0 ]] || rc=1
      stop_stress
      [[ "$frames" == 1 ]] && stop_frames "$out/frames-$side-$i" "$out/run-$side-$i" "$tools" "$side" "$i"
    done
  done
  python3 -I "$tools/update-click-ab.py" "$out"
  rm -rf "$out/base" "$out/head"
  tar -czf "$out.tgz" -C "$out" . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

# stress=K: K busy loops per core for the whole update (a Mac under a load like Leo's, about 150-200),
# each ended by its own recorded pid.
STRESS_PIDS=()
start_stress() {
  local per_core="$1" cores n
  STRESS_PIDS=()
  [[ "$per_core" -gt 0 ]] || return 0
  cores="$(sysctl -n hw.ncpu)"
  for ((n = 0; n < per_core * cores; n++)); do
    yes >/dev/null &
    STRESS_PIDS+=("$!")
  done
  echo "UCA stress $((per_core * cores)) busy loops on $cores cores"
}
stop_stress() {
  local pid
  for pid in ${STRESS_PIDS[@]+"${STRESS_PIDS[@]}"}; do kill "$pid" 2>/dev/null; done
  for pid in ${STRESS_PIDS[@]+"${STRESS_PIDS[@]}"}; do wait "$pid" 2>/dev/null; done
  STRESS_PIDS=()
}
trap 'stop_stress; for p in "$WATCH_PID" "$REC_PID"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done' EXIT

# frames=1: the window watcher and the frame decoder, compiled here (neither needs a TCC grant), and whether
# CuaDriver can record the display (the one recorder the fleet grants Screen Recording).
RECORDS=0
frame_tools() {
  local tools="$1"
  xcrun swiftc -O -o "$tools/update-frames-watch" scripts/measure/update-frames/watch.swift >"$tools/swiftc.log" 2>&1 \
    && xcrun swiftc -O -o "$tools/tab-switch-tools" scripts/measure/tab-switch-frames/tools.swift >>"$tools/swiftc.log" 2>&1 \
    || { echo "UCF cannot compile the frame tools: $(tail -n 5 "$tools/swiftc.log")" >&2; return 1; }
  cp scripts/measure/update_frames.py "$tools/"
  if python3 scripts/measure/launch_reveal_record.py preflight >"$tools/preflight.log" 2>&1; then
    RECORDS=1; echo "UCF recorder CuaDriver"
  else
    echo "UCF no display recording ($(tail -n 1 "$tools/preflight.log")): window log only"
  fi
}
WATCH_PID="" REC_PID=""
start_frames() {
  local dir="$1" tools="$2" n
  mkdir -p "$dir"
  "$tools/update-frames-watch" "ucab" 8 900 >"$dir/windows.ndjson" 2>"$dir/watch.err" &
  WATCH_PID=$!
  if [[ "$RECORDS" == 1 ]]; then
    python3 scripts/measure/launch_reveal_record.py record "$dir/rec" 900 >"$dir/rec.log" 2>&1 &
    REC_PID=$!
    for n in $(seq 1 100); do grep -q '^READY' "$dir/rec.log" 2>/dev/null && break; sleep 0.1; done  # sleep-ok: the recorder's start, 10 s at most
  fi
}
stop_frames() {
  local dir="$1" run="$2" tools="$3" side="$4" round="$5" video size crop
  [[ -n "$WATCH_PID" ]] && { kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; WATCH_PID=""; }
  [[ -n "$REC_PID" ]] && { kill -TERM "$REC_PID" 2>/dev/null; wait "$REC_PID" 2>/dev/null; REC_PID=""; }
  [[ -d "$run" ]] || return 0
  cp "$dir/windows.ndjson" "$run/" 2>/dev/null
  [[ -f "$dir/rec.log" ]] && cp "$dir/rec.log" "$run/"
  video="$(sed -n 's/^VIDEO //p' "$dir/rec.log" 2>/dev/null | tail -n 1)"
  if [[ -n "$video" && -f "$video" ]]; then
    cp "$video" "$run/recording.mp4"
    size="$("$tools/tab-switch-tools" decode "$video" "$dir/probe.gray" 0 0 32 32 32 0 0 2 2 | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["video"][0]))')"
    if crop="$(python3 -I "$tools/update_frames.py" crop "$run" "$size")"; then
      # shellcheck disable=SC2086 # crop is four numbers
      "$tools/tab-switch-tools" decode "$video" "$run/frames.gray" $crop 160 0 0 2 2 | python3 -c 'import json,sys; d=json.load(sys.stdin); d.pop("marker",None); print(json.dumps(d))' >"$run/frames.json"
    fi
    rm -f "$dir/probe.gray"
  fi
  python3 -I "$tools/update_frames.py" "$run" >"$run/frames-verdict.json"
  echo "UCF $side $round $(cat "$run/frames-verdict.json")"
  rm -f "$run/frames.gray"
}

fetch_checkout() {
  local sha="$1" depth=()
  [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && depth=(--depth=1) # a full clone stays full
  # A fleet step's origin is the fleet mirror, which holds feat-cmux-next only: a PR or lane commit comes from GitHub.
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch --quiet ${depth[@]+"${depth[@]}"} origin "$sha" 2>/dev/null \
    || git fetch --quiet ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$sha" || { echo "UCA cannot fetch $sha" >&2; return 3; }
  git -c advice.detachedHead=false checkout --quiet --detach "$sha"
}

# Builds the checkout's bench app with tag ucab (both sides one bundle id; the second build recompiles only what the
# two commits change) and copies it to OUT/SIDE/.
build_app() {
  local out="$1" side="$2" app started=$SECONDS
  for sub in ghostty ghostty-next; do
    git submodule update --init --depth 1 "$sub" >>"$out/build-$side.log" 2>&1 || { echo "UCA submodule $sub failed" >&2; return 3; }
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh >>"$out/build-$side.log" 2>&1 || { echo "UCA GhosttyKit download failed" >&2; return 3; }
  fi
  measure_quiet "UCA acpmux build $side" "$out/build-$side.log" env CMUX_FLEET_BUILD_TAG=ucab ./scripts/cmux-next/build-acpmux.sh || { echo "UCA acpmux build $side failed" >&2; tail -n 40 "$out/build-$side.log" >&2; return 3; }
  measure_quiet "UCA build $side" "$out/build-$side.log" env CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag ucab --no-global-cli-links --config bench
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/build-$side.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "UCA build $side failed: no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/build-$side.log" | head -n 60 >&2
    tail -n 40 "$out/build-$side.log" >&2
    return 3
  fi
  mkdir -p "$out/$side" && ditto "$app" "$out/$side/cmux DEV ucab.app" || { echo "UCA copy $side failed" >&2; return 3; }
  echo "UCA build $side $(git rev-parse HEAD) $((SECONDS - started)) s $(du -sh "$app" | cut -f1)"
}

main "$@"
