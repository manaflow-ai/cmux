#!/usr/bin/env bash
# Fleet entry for the close-flash run: builds a tagged cmux-next app at this checkout, then runs
# scripts/cmux-next/close-flash-bench.py against it (Close Window with Ctrl-Cmd-W and the close key in Debug Settings,
# each close's debug.action_budget commit time and outcome, in an ACTIVE app: the close button's ~100 ms nested flash
# draws only there). It launches and activates an app, so it runs alone and needs a logged-in console (an owned mini).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/close-flash.sh --ref <sha> \
#     --artifact artifacts/close-flash/report.json --arg=--config=bench --arg=--kinds=closeWindow [--arg=--close-rounds=25]
# The close key needs Debug Settings (DevTools: a Debug compile): --arg=--config=debug with the default --kinds.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="closeflash"
out="$(pwd)/artifacts/close-flash"
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
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "close-flash: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/close-flash-bench.py --app "$app" --out "$out" "$@"
