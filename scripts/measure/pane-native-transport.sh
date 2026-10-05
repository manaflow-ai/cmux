#!/usr/bin/env bash
# The agent pane's native transport against today's page-world WebSocket (AgentPaneTransportBench).
# Run alone on a worker: cmux-ci run --class exclusive --script scripts/measure/pane-native-transport.sh
#   --ref SHA [--arg=rounds=N] [--arg=config=release]
set -euo pipefail
rounds=5
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    config=debug|config=release) export CMUX_SWIFT_SUITE_CONFIGURATION="${arg#config=}" ;;
    *) echo "pane-native-transport.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
echo "PANE-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)"
echo "PANE-CONFIG ${CMUX_SWIFT_SUITE_CONFIGURATION:-debug}"
echo "PANE-LOAD before $(uptime | sed 's/.*load averages*: //')"
status=0
CMUX_PANE_TRANSPORT_BENCH=1 CMUX_PANE_TRANSPORT_BENCH_ROUNDS="$rounds" \
  ./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext AgentPaneTransportBench || status=$?
echo "PANE-LOAD after $(uptime | sed 's/.*load averages*: //')"
exit "$status"
