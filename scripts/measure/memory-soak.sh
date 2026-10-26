#!/usr/bin/env bash
# Fleet entry for the memory soak (p07-memory 015, DC12 and MQ-LEAK of
# plans/cmux-next/chrome-parity/p07-memory.md): builds a tagged cmux-next DEV app at this checkout,
# builds STRESS in it on a 1920 x 1200 virtual display, churns it for 2 h (tabs of each engine,
# workspaces, splits, hibernate and wake, switches), samples the footprint per process kind every
# 5 min, and prints the slopes, the top 30 growing heap classes of the app and the MQ-LEAK lines
# (scripts/cmux-next/memory-soak.py). Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/memory-soak.sh \
#     --ref SHA [--arg=--minutes=120] [--arg=--sample-minutes=5] [--arg=--config=bench]
# --config=<debug|release|bench> picks reload.sh's build configuration; every other argument goes to
# memory-soak.py. The soak exits 0 whatever it measured; only a failed build exits non-zero.
# Output: MEMORY-SOAK-* and MQ-LEAK lines; JSON and heap tables under .build/memory-soak.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers and ghostty-next for the
# bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="memsoak"
out="$PWD/.build/memory-soak"
rm -rf "$out"
mkdir -p "$out"
reload_config=() soak_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) soak_args+=("$arg") ;;
  esac
done
echo "MEMORY-SOAK-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} > "$out/reload.log" 2>&1 || {
  tail -n 80 "$out/reload.log"
  exit 1
}
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "memory-soak: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
echo "memory-soak: ref $(git rev-parse HEAD) app $(basename "$app")"
python3 -I scripts/cmux-next/memory-soak.py --app "$app" --vdisplay 120 --out "$out" ${soak_args[@]+"${soak_args[@]}"}
