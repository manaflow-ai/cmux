#!/usr/bin/env bash
# Fleet entry for pane layout motion (panes-perf): builds a tagged cmux-next app at this checkout, then runs
# scripts/cmux-next/pane-perf-terminal.py against it (split, close, New Column, zoom and a divider drag in
# 2, 8 and 30 terminal layouts; frame p50/p95/p99/max, missed frames, layout work per frame, grids sent to
# the PTY owner, hangs). Needs a logged-in console (an owned mini).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/pane-perf.sh \
#     --ref <sha> --key <key> --artifact artifacts/pane-perf/report.json [--arg=--rounds=3] [--arg=--layouts=1x2,4x2,6x5]
#     [--arg=--actions=split,close,column,zoom,drag] [--arg=--stream] [--arg=--record] [--arg=--gate]
# Until the controller allowlists this entry, the same run goes through split-spring.sh:
#   --script scripts/measure/split-spring.sh --arg=--suite=pane-perf ... --artifact artifacts/split-spring/report.json
# With --record the recordings are artifacts/pane-perf/frames.tgz (a second step with that --artifact).
# To time an older commit, revert the change on a scratch ref of the tip (this script's blob must match the reviewed one).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
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
tag="pane-perf"
out="$(pwd)/artifacts/pane-perf"
mkdir -p "$out"
# --config=<debug|release|bench> picks reload.sh's build configuration (bench: Release optimization with the
# debug.* control commands kept); every other argument goes to the bench.
reload_config=() bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "pane-perf: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/pane-perf-terminal.py --tag "$tag" --app "$app" --out "$out" --json "$out/report.json" "$@"
