#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid CI jobs use WarpBuild runners.
# Fork PRs are gated by GitHub's built-in "Require approval for outside
# collaborators" setting, so workflow-level fork guards are not needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

# tests: must use WarpBuild runner (paid runner)
if ! awk '
  /^  tests:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  END { exit !(saw_warp) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests block must use warp-macos-15-arm64-6x runner"
  exit 1
fi

# tests-build-and-lag: must use WarpBuild runner (paid runner)
if ! awk '
  /^  tests-build-and-lag:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  END { exit !(saw_warp) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-build-and-lag block must use warp-macos-15-arm64-6x runner"
  exit 1
fi

# ui-regressions: must use WarpBuild runner (paid runner)
if ! awk '
  /^  ui-regressions:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: warp-macos-15-arm64-6x/ { saw_warp=1 }
  END { exit !(saw_warp) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: ui-regressions block must use warp-macos-15-arm64-6x runner"
  exit 1
fi

echo "PASS: tests WarpBuild runner is present"
echo "PASS: tests-build-and-lag WarpBuild runner is present"
echo "PASS: ui-regressions WarpBuild runner is present"
