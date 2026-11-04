#!/usr/bin/env bash
# Fleet entry for the relaunch-after-update shift bench: builds a tagged cmux-next app at this checkout (Debug by
# default: the launch recorder and debug.* commands; --config=bench for Release optimization with them kept), then runs
# scripts/cmux-next/relaunch-shift-bench.py against it: a seeded session (windows, split workspaces, tabs, terminals,
# web pages, agent chats) relaunched through the updater's relaunch path, every window recorded from its first frame,
# and what moved, flashed or filled in after it counted (launch_shift.py). It launches an app and reads its frames, so
# it runs alone on a display worker:
#   cmux-ci run --class exclusive --measurement --label measure --display --script scripts/measure/relaunch-shift.sh \
#     --ref <sha> --artifact artifacts/relaunch-shift/report.json [--arg=--rounds=3] [--arg=--seconds=8] [--arg=--config=bench]
# The log prints the table between RELAUNCH-SHIFT-TABLE-BEGIN and -END and the medians as RELAUNCH-SHIFT {json}.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="rshift"
out="$(pwd)/artifacts/relaunch-shift"
mkdir -p "$out"
reload_config=() bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --rounds=*|--seconds=*|--skip=*|--variants=*) bench_args+=("$arg") ;;
    *) echo "relaunch-shift.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
echo "RELAUNCH-SHIFT-MACHINE sha=$(git rev-parse HEAD) model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
# The build and the bench stream to the step log as they go (as the other measure scripts do): the controller stops a
# measurement whose log is silent for 45 min (CMUX_CI_MEASURE_SILENT_MAX), and a cold Debug build on a light mini
# takes about that long. 2026-11-04: two relaunch-shift steps on a light mini were stopped as "hung" after
# the MACHINE line while reload.sh was still compiling (one build log ended 43 s before the stop).
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log" || { tail -n 80 "$out/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "relaunch-shift: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
status=0
python3 -u scripts/cmux-next/relaunch-shift-bench.py --app "$app" --out "$out" ${bench_args[@]+"${bench_args[@]}"} 2>&1 | tee "$out/bench.log" || status=${PIPESTATUS[0]}
tail -n 120 "$out/journey/journey.log" 2>/dev/null || true
echo "RELAUNCH-SHIFT-TABLE-BEGIN"
cat "$out/report.md" 2>/dev/null || tail -n 60 "$out/bench.log"
echo "RELAUNCH-SHIFT-TABLE-END"
grep -E "^RELAUNCH-SHIFT |LAUNCH-SHIFT " "$out/bench.log" || true
exit "$status"
