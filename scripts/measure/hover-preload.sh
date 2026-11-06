#!/usr/bin/env bash
# Fleet entry for the hover preload bench (plans/cmux-next/hover-preload-DESIGN.md, cmux-ad m34): builds a tagged
# cmux-next DEV app at this checkout, then runs scripts/cmux-next/bench_hover_preload.py:
#   (a) a 120 Hz pointer sweep over the sidebar's workspace rows (200 crossings): wakes started (must be 0),
#       missed refreshes and main-thread busy ms per frame, each pointer move's main-thread round trip;
#   (b) time to content after a select, cold and after a 150 ms rest on the row (--trials each);
#   (c) the woken pages hibernate again after the 30 s grace, and the footprint before, woken and after.
# The bench uses only socket calls every DEV build has, so the same run measures a build without hover preload:
# cherry-pick this harness onto that commit (the script blobs must match the reviewed ones).
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/hover-preload.sh --ref <sha> [--arg=--engine=chromium]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# --arms=OFF,ON,OFF,ON (the default) runs the bench once per arm, in that order, on this build and this mini: OFF sets
# browser.keepNeighborTabsAwake 0 (hover wakes off; the per-row lock write stays), ON is the default.
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="hoverpre"
out="$(mktemp -d)"
# --config=<debug|release|bench> picks reload.sh's build configuration; every other argument goes to the bench.
reload_config=() bench_args=() arms="OFF,ON,OFF,ON"
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --arms=*) arms="${arg#--arms=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "hover-preload: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
echo "hover-preload: ref $(git rev-parse HEAD)"
# A fleet step has no LaunchServices session: run the app binary itself (bench_memory.launch).
IFS=, read -r -a arm_list <<<"$arms"
index=0 failed=0
for arm in "${arm_list[@]}"; do
  index=$((index + 1))
  hover="$(tr '[:upper:]' '[:lower:]' <<<"$arm")"
  echo "hover-preload: arm $index/${#arm_list[@]} hover=$hover"
  # One arm that fails does not stop the others (each launches its own app); the step fails at the end.
  CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/bench_hover_preload.py --app "$app" --hover "$hover" \
    --out "$PWD/hover-preload-$index-$hover.json" "$@" || { echo "hover-preload: arm $index ($hover) failed" >&2; failed=1; }
done
exit "$failed"
