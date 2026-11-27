#!/usr/bin/env bash
# Fleet entry for the agent connection chaos suite (scripts/cmux-next/agent-conn-chaos/, CONTRACT.md there): builds a
# tagged cmux-next DEV app at this checkout (--config bench: Release optimization, debug.* kept), then runs suite.py
# against it: a real app, its real acpmux daemon, a scripted agent, one driver; each case faults a running turn and
# judges recovery, the page's text and the turn's words. It launches an app and kills its processes, so it runs alone:
#   cmux-ci run --class exclusive --measurement --label measure --display --script scripts/measure/agent-conn-chaos.sh \
#     --ref <sha> --artifact artifacts/agent-conn-chaos/result.json [--arg=--cases=daemon-sigkill,app-sigkill]
# Fleet Macs only: it refuses cosmic-gray and air-blue (Leo's own Macs) and big-red, by name, before building.
# The log prints one AGENT-CONN-CHAOS line per case and the table between AGENT-CONN-CHAOS-TABLE-BEGIN and -END.
# Exit status: the suite's (0 only when every case passed or failed as its XFAIL mark says).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
names="$(scutil --get ComputerName 2>/dev/null || true) $(scutil --get LocalHostName 2>/dev/null || true) $(hostname -s)"
case "$(echo "$names" | tr '[:upper:] ' '[:lower:]-')" in
  *cosmic-gray*|*air-blue*|*big-red*)
    echo "agent-conn-chaos: refusing to run on $names: Leo's machines and big-red are off limits (fleet Macs only)" >&2
    exit 3 ;;
esac
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="connchaos"
out="$(pwd)/artifacts/agent-conn-chaos"
mkdir -p "$out"
suite_args=()
for arg in "$@"; do
  case "$arg" in
    --cases=*|--sleep=*) suite_args+=("$arg") ;;
    *) echo "agent-conn-chaos.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
echo "AGENT-CONN-CHAOS-MACHINE sha=$(git rev-parse HEAD) host=$(hostname -s) model=$(sysctl -n hw.model) macos=$(sw_vers -productVersion)"
# The build streams to the step log (the controller stops a measurement silent for 45 min; relaunch-shift.sh).
: > "/tmp/cmux-reload-$tag.log" 2>/dev/null || true
tail -n +1 -F "/tmp/cmux-reload-$tag.log" 2>/dev/null > >(awk '{ print "reload-log: " $0; fflush() }') &
follow_pid=$!
trap 'kill "$follow_pid" 2>/dev/null || true' EXIT
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config bench 2>&1 | tee "$out/reload.log" || { tail -n 80 "$out/reload.log"; exit 1; }
kill "$follow_pid" 2>/dev/null || true
trap - EXIT
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "agent-conn-chaos: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
status=0
# A fleet step has no LaunchServices session on every worker: launch the binary directly (bench_memory.launch).
CMUX_BENCH_LAUNCH=direct python3 -u scripts/cmux-next/agent-conn-chaos/suite.py --app "$app" --out "$out/result.json" \
  ${suite_args[@]+"${suite_args[@]}"} 2>&1 | tee "$out/suite.log" || status=${PIPESTATUS[0]}
exit "$status"
