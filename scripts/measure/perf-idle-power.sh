#!/usr/bin/env bash
# Idle power + wakeups bench (msg 2654, vs Ardia/Helium/Dia): CPU energy (mW),
# CPU % and wakeups/s of a cmux-next app and every process it owns, in the
# Ardia scenarios: terminal only, 1 tab in view, hidden, 20 tabs, 20 tabs
# hidden, switching tabs, scrolling, video, minimized.
# Builds a tagged app at this checkout (Release by default, config=Debug for a
# debug build, config=bench for Release optimization with the debug.* commands) and runs scripts/cmux-next/bench_power.py. Run alone:
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/perf-idle-power.sh --ref SHA [--arg=measure=60] [--arg=config=Release]
#     [--arg=scenarios=terminal,tab1] [--arg=settings={"browser":{...}}]
#     [--arg=freeze=SECONDS] [--arg=neighbors=0..3]  (browser.freezeHiddenTabs and
#     browser.keepNeighborTabsAwake without JSON, which the fleet's argument check refuses)
# Each idle scenario settles 120 s first (Chromium's post-load work), so a
# full run takes about 25 minutes.
# Output: PERF-POWER lines; JSON at artifacts/perf-idle-power.json.
set -euo pipefail
measure=60
config=Release
scenarios=""
settings="{}"
freeze=""
neighbors=""
for arg in "$@"; do
  case "$arg" in
    measure=*) measure="${arg#measure=}" ;;
    config=*) config="${arg#config=}" ;;
    scenarios=*) scenarios="${arg#scenarios=}" ;;
    settings=*) settings="${arg#settings=}" ;;
    freeze=*) freeze="${arg#freeze=}"; [[ "$freeze" =~ ^[0-9]+$ ]] || { echo "perf-idle-power.sh: freeze=SECONDS" >&2; exit 2; } ;;
    neighbors=*) neighbors="${arg#neighbors=}"; [[ "$neighbors" =~ ^[0-3]$ ]] || { echo "perf-idle-power.sh: neighbors=0..3" >&2; exit 2; } ;;
    *) echo "perf-idle-power.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
if [ -n "$freeze$neighbors" ]; then
  settings="$(python3 -c 'import json,sys; s=json.loads(sys.argv[1]); b=s.setdefault("browser", {})
if sys.argv[2]: b["freezeHiddenTabs"]=int(sys.argv[2])
if sys.argv[3]: b["keepNeighborTabsAwake"]=int(sys.argv[3])
print(json.dumps(s))' "$settings" "$freeze" "$neighbors")"
fi
cd "$(git rev-parse --show-toplevel)"
work=".build/perf-idle-power"
rm -rf "$work"; mkdir -p "$work" artifacts
echo "PERF-POWER-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) config=$config load=\"$(uptime | sed 's/.*load averages*: //')\""
# A fleet step checks out no submodules (only their empty gitlink directories): the app build needs
# Ghostty's headers and the ghostty-next tree, and GhosttyKit.xcframework (a prebuilt download).
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
release=()
[ "$config" = "Release" ] && release=(--release)
[ "$config" = "bench" ] && release=(--config bench)
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag perfpower "${release[@]}" > "$work/reload.log" 2>&1 || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "perf-idle-power: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
extra=()
[ -n "$scenarios" ] && extra=(--scenarios "$scenarios")
python3 scripts/cmux-next/bench_power.py --app "$app" --measure "$measure" --config "$settings" \
  --out artifacts/perf-idle-power.json "${extra[@]}"
