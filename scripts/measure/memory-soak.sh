#!/usr/bin/env bash
# Fleet entry for the memory soak (p07-memory 015, DC12 and MQ-LEAK of
# plans/cmux-next/chrome-parity/p07-memory.md): builds a tagged cmux-next DEV app at this checkout,
# builds STRESS in it on a 1920 x 1200 virtual display, warms it up for 20 min, churns it for 2 h (tabs
# of each engine, workspaces, splits, hibernate and wake, switches), samples the footprint per process
# kind every 5 min, and prints the slopes, the growing heap classes of the app and the MQ-LEAK lines
# (scripts/cmux-next/memory-soak.py). Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/memory-soak.sh \
#     --ref SHA --artifact artifacts/memory-soak.tar.gz [--arg=--minutes=120] [--arg=--sample-minutes=5] \
#     [--arg=--config=bench]
# --config=<debug|bench|bench-checks> picks reload.sh's build configuration (release is refused: it has
# no debug control surface to drive); every other argument goes to memory-soak.py. The soak exits 0
# whatever it measured; only a failed build or a refused argument exits non-zero.
# Output: MEMORY-SOAK-* and MQ-LEAK lines; the JSON report, the raw heap tables and the reload log under
# artifacts/memory-soak, packed into artifacts/memory-soak.tar.gz on any exit.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
root="$PWD"
reload_config=() soak_args=()
for arg in "$@"; do
  case "$arg" in
    --config=debug|--config=bench|--config=bench-checks) reload_config=(--config "${arg#--config=}") ;;
    --config=*)
      echo "memory-soak: $arg is not supported: use debug, bench or bench-checks (release has no debug socket to drive the soak)" >&2
      exit 2 ;;
    *) soak_args+=("$arg") ;;
  esac
done
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers and ghostty-next for the
# bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="memsoak"
out="$root/artifacts/memory-soak"
rm -rf "$out" "$root/artifacts/memory-soak.tar.gz"
mkdir -p "$out"
pack() {
  [[ -d "$out" ]] || return 0
  tar -czf "$root/artifacts/memory-soak.tar.gz" -C "$root/artifacts" memory-soak 2>/dev/null || true
}
trap pack EXIT
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
