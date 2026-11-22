#!/usr/bin/env bash
# The agent pane's native transport against today's page-world WebSocket (AgentPaneTransportBench and
# AgentPaneTransportBenchParse). Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/pane-native-transport.sh --ref SHA
#     [--arg=rounds=N] [--arg=config=release] [--arg=against=SHA]
# against=SHA runs the benches first with that commit's agent pane package sources and tests
# (Sources/CmuxNextAgentPane, Tests/CmuxNextAgentPaneTests; nothing else may differ), then with this
# ref's, in the same checkout on the same machine; every PANE- line of the first run is marked
# PANE-RUN against, of the second PANE-RUN ref.
set -euo pipefail
rounds=5
against=""
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    config=debug|config=release) export CMUX_SWIFT_SUITE_CONFIGURATION="${arg#config=}" ;;
    against=*) against="${arg#against=}" ;;
    *) echo "pane-native-transport.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
echo "PANE-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)"
echo "PANE-CONFIG ${CMUX_SWIFT_SUITE_CONFIGURATION:-debug}"
paths=(Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests)
bench() {
  echo "PANE-RUN $1 $(git rev-parse --short=11 HEAD) sources=$2"
  echo "PANE-LOAD before $(uptime | sed 's/.*load averages*: //')"
  local status=0
  CMUX_PANE_TRANSPORT_BENCH=1 CMUX_PANE_TRANSPORT_BENCH_ROUNDS="$rounds" \
    ./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext AgentPaneTransportBench || status=$?
  echo "PANE-LOAD after $(uptime | sed 's/.*load averages*: //')"
  return "$status"
}
status=0
if [ -n "$against" ]; then
  git cat-file -e "$against^{commit}" 2>/dev/null || git fetch --quiet --depth=1 origin "$against"
  here="$(git rev-parse HEAD)"
  rm -rf "${paths[@]}"
  git checkout "$against" -- "${paths[@]}"
  bench against "$against" || status=$?
  rm -rf "${paths[@]}"
  git checkout "$here" -- "${paths[@]}"
fi
bench ref "$(git rev-parse HEAD)" || status=$?
exit "$status"
