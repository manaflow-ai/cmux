#!/usr/bin/env bash
# Fleet entry for the transcript fling bench (RFD 0121 app-perf.md section 6, "First PR"): builds a tagged cmux-next
# app at this checkout (a bench build by default: the debug.native_transcript RPC is DEBUG/bench only), holds a
# virtual main display at 120 Hz, then runs scripts/ci/frame-pacing/transcript_fling.py against it: the React
# transcript and the native one, interleaved in one launched app, 3,000 rows each. Runs alone on the worker because
# it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure [--label gui-session-v1] \
#     --script scripts/measure/transcript-fling.sh --ref <sha> [--arg=--rounds=N] [--arg=--seconds=S] \
#     [--arg=--config=debug|bench] [--arg=--vdisplay=HZ] [--arg=--build-at=SHA] --artifact transcript-fling.json
# --build-at=SHA builds the app at SHA (a pull request's head) with that commit's own reload.sh and runs this
# checkout's bench against it (scripts/measure/app-at-commit.sh): the controller runs an unlisted measure script only
# at a commit on feat-cmux-next or main, so a pull request's head is measured this way.
# The step's log has one TRANSCRIPT_FLING_JSON line per arm (the median over the rounds) and the build's
# BUILD-FLAGS line; transcript-fling.json is the whole report. The tool exits 0 whatever the numbers (report only)
# and 1 when the app never came up.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/app-at-commit.sh
tag="ntfling"
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
app="" vdisplay_pid=""
# shellcheck disable=SC2329 # run by the trap below
cleanup() {
  if [[ -n "$app" ]]; then python3 scripts/cmux-next/tag_teardown.py "$app" || true; fi
  if [[ -n "$vdisplay_pid" ]]; then kill "$vdisplay_pid" 2>/dev/null || true; wait "$vdisplay_pid" 2>/dev/null || true; fi  # the helper this script started
  measure_remove_scratch "$out"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Steps run with a per-step HOME: bun and node live under the account's real home (as held-new-tab.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
config="bench" vdisplay_hz="120" build_at="" bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) config="${arg#--config=}" ;;
    --vdisplay=*) vdisplay_hz="${arg#--vdisplay=}" ;;
    --build-at=*) build_at="${arg#--build-at=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
if [[ -n "$build_at" ]]; then
  app="$(measure_app_at_commit "$build_at" "$tag" "$out/at" --config "$config")"
  cp "$out/at.reload.log" "$out/reload.log" 2>/dev/null || true
else
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config "$config" 2>&1 | tee "$out/reload.log"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
fi
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "transcript-fling: the build printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
python3 scripts/measure/build-flags.py "$out/reload.log" --out "$out/build-flags.json" || true
if [[ -n "$vdisplay_hz" && "$vdisplay_hz" != 0 ]]; then
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
    echo "transcript-fling: display: $(grep -m1 '^ready\|^error' "$vd/out" 2>/dev/null || echo 'the virtual display never reported')"
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
    echo "transcript-fling: the virtual display helper did not compile; measuring on the real display"
  fi
fi
python3 scripts/ci/frame-pacing/transcript_fling.py --app "$app" --json "$PWD/transcript-fling.json" \
  --out "$out/arms.jsonl" --artifacts "$out/logs" ${bench_args[@]+"${bench_args[@]}"}
