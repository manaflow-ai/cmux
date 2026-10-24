#!/usr/bin/env bash
# Fleet entry for the WebKit page and tab cadence bench (perf-lead row 23: scrolling at the display's
# full refresh, and macOS Low Power Mode halving it through WebKit's own path). Builds a tagged
# cmux-next DEV app at this checkout, then runs scripts/cmux-next/bench-page-cadence.py: a cmux page
# and a WebKit browser tab at full rate, in Low Power Mode, and back. The Low Power Mode legs switch
# macOS Low Power Mode for the whole host, so this runs only alone on its worker (the bench refuses
# them without CMUX_CI_STEP_CLASS=exclusive):
#   cmux-ci run --class exclusive --label measure --script scripts/measure/page-cadence.sh --ref <sha> [--arg=--stress]
# Needs a 120 Hz display (the bench refuses 60 Hz, where the rates look the same) and a
# passwordless `sudo -n pmset` for the Low Power Mode legs.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="pagecad"
out="$(mktemp -d)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "page-cadence: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
echo "page-cadence: ref $(git rev-parse HEAD)"
exec python3 scripts/cmux-next/bench-page-cadence.py --app "$app" --out "$out" --json "$PWD/page-cadence.json" "$@"
