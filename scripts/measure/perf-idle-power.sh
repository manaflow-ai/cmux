#!/usr/bin/env bash
# Idle power + wakeups bench (msg 2654, vs Ardia/Helium/Dia): CPU energy (mW),
# CPU % and wakeups/s of a cmux-next app and every process it owns, in the
# Ardia scenarios: terminal only, 1 tab in view, hidden, 20 tabs, 20 tabs
# hidden, switching tabs, scrolling, video, minimized.
# Builds a tagged app at this checkout (Release by default, config=Debug for a
# debug build) and runs scripts/cmux-next/bench_power.py. Run alone:
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/perf-idle-power.sh --ref SHA [--arg=measure=60] [--arg=config=Release]
#     [--arg=scenarios=terminal,tab1] [--arg=settings={"browser":{...}}]
# Output: PERF-POWER lines; JSON at artifacts/perf-idle-power.json.
set -euo pipefail
measure=60
config=Release
scenarios=""
settings="{}"
for arg in "$@"; do
  case "$arg" in
    measure=*) measure="${arg#measure=}" ;;
    config=*) config="${arg#config=}" ;;
    scenarios=*) scenarios="${arg#scenarios=}" ;;
    settings=*) settings="${arg#settings=}" ;;
    *) echo "perf-idle-power.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
work=".build/perf-idle-power"
rm -rf "$work"; mkdir -p "$work" artifacts
echo "PERF-POWER-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) config=$config load=\"$(uptime | sed 's/.*load averages*: //')\""
release=()
[ "$config" = "Release" ] && release=(--release)
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag perfpower "${release[@]}" > "$work/reload.log" 2>&1 || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "perf-idle-power: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
extra=()
[ -n "$scenarios" ] && extra=(--scenarios "$scenarios")
python3 scripts/cmux-next/bench_power.py --app "$app" --measure "$measure" --config "$settings" \
  --out artifacts/perf-idle-power.json "${extra[@]}"
