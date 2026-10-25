#!/usr/bin/env bash
# Fleet entry for the instant-create bench (Cmd-N, Cmd-T, Cmd-D, Cmd-Shift-D): builds a tagged
# cmux-next DEBUG app at this checkout, then runs scripts/cmux-next/instant-new-surfaces-bench.py
# (key to visible frame and to daemon confirm, idle and under load). Runs alone on the worker
# because it launches an app and loads every core:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/instant-new-surfaces.sh --ref <sha> [--arg=--runs=12]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A fleet checkout has no submodules or GhosttyKit yet (as scripts/measure/tab-switch.sh).
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
tag="instantnew"
out="$(mktemp -d)"
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
  echo "instant-new-surfaces: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p artifacts
exec python3 scripts/cmux-next/instant-new-surfaces-bench.py --tag "$tag" --app "$app" --out "$out" \
  --json artifacts/instant-new-surfaces.json "$@"
