#!/usr/bin/env bash
# Runs AgentTabLaunchDeferral alone (red/green evidence for the launch deferral).
#   cmux-ci run --class exclusive --script scripts/measure/agent-tab-deferral-tests.sh --ref SHA
set -uo pipefail
./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext AgentTabLaunchDeferral 2>&1 \
  | grep -E "AgentTabLaunchDeferral|Test .*(passed|failed)|Test run with|error:|Expectation failed" | grep -v " started" || true
