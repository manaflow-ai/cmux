#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid/gated CI jobs are never run for fork pull requests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

EXPECTED_IF="if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

if ! grep -Fq "$EXPECTED_IF" "$WORKFLOW_FILE"; then
  echo "FAIL: Missing fork pull_request guard in $WORKFLOW_FILE"
  echo "Expected line:"
  echo "  $EXPECTED_IF"
  exit 1
fi

# tests: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# tests-build-and-lag: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  tests-build-and-lag:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-build-and-lag block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

# ui-regressions: must use WarpBuild runner with fork guard (paid runner)
if ! awk '
  /^  ui-regressions:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_warp && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: ui-regressions block must keep both warp-macos-15-arm64-6x runner and fork guard"
  exit 1
fi

echo "PASS: tests WarpBuild runner fork guard is present"
echo "PASS: tests-build-and-lag WarpBuild runner fork guard is present"
echo "PASS: ui-regressions WarpBuild runner fork guard is present"
