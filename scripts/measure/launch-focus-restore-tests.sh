#!/usr/bin/env bash
# Runs LaunchFocusRestoreTests alone (red/green evidence for the launch focus restore).
#   cmux-ci run --class exclusive --script scripts/measure/launch-focus-restore-tests.sh --ref SHA
set -uo pipefail
./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext LaunchFocusRestoreTests 2>&1 \
  | grep -E "LaunchFocusRestoreTests|Test .*(passed|failed)|Test run with|error:|Expectation failed" | grep -v " started" || true
