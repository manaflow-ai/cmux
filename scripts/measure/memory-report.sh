#!/usr/bin/env bash
# Fleet entry for memory-report.py (plans/cmux-next/chrome-parity/p07-memory.md, task 014, DC15,
# MQ-UNATTRIBUTED): builds a tagged cmux-next app at this checkout (`--config bench` by default:
# Release optimization with the debug.* socket methods kept, so the footprint is a Release one),
# launches it with a scratch config, measures where the app's footprint goes at Home idle, then
# builds the STRESS session (perf-stress-session.py) in it and measures again. STRESS needs a 1920 x 1200
# virtual main display: memory-report.py starts one at 120 Hz before the launch (perf-stress-session.py
# start_vdisplay; --vdisplay=HZ picks the rate, --vdisplay=0 measures on the host's display). Each phase
# also walks the heap (--heap) for the MQ-CACHE heap bytes. Prints one table per phase, MEMORY-REPORT,
# MQ-UNATTRIBUTED and MQ-CACHE lines; the JSON, raw tool outputs and app.log land in
# artifacts/memory-report/, also when a phase fails. A build without debug.memory still reports (every
# group unexplained). Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/memory-report.sh \
#     --ref <sha> --artifact artifacts/memory-report/report.json [--arg=--phases=home] [--arg=--vdisplay=60]
# The glyph atlas measurement (task 039, ATLAS line, atlas_bytes_per_extra_terminal) is --arg=--phases=home,atlas
# in its own launch: memory-report.py refuses atlas with stress, since the atlas it grows stays grown and
# would inflate every STRESS terminal's frame textures.
# --config=<debug|release|bench> picks reload.sh's configuration; every other argument goes to memory-report.py.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="memreport"
out="$PWD/artifacts/memory-report"
mkdir -p "$out"
reload_config=(--config bench) report_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) report_args+=("$arg") ;;
  esac
done
echo "PERF-MEMORY-REPORT-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) config=${reload_config[1]}"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links "${reload_config[@]}" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "memory-report: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
python3 -I scripts/cmux-next/memory-report.py --app "$app" --phases home,stress --heap --out "$out/report.json" \
  ${report_args[@]+"${report_args[@]}"}
