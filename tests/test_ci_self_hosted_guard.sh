#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures self-hosted UI tests are never run for fork pull requests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

EXPECTED_IF="if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

if ! grep -Fq "$EXPECTED_IF" "$WORKFLOW_FILE"; then
  echo "FAIL: Missing fork pull_request guard for ui-tests in $WORKFLOW_FILE"
  echo "Expected line:"
  echo "  $EXPECTED_IF"
  exit 1
fi

if ! awk '
  /^  ui-tests:/ { in_ui_tests=1; next }
  in_ui_tests && /^  [^[:space:]]/ { in_ui_tests=0 }
  in_ui_tests && /runs-on: self-hosted/ { saw_self_hosted=1 }
  in_ui_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_self_hosted && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: ui-tests block must keep both self-hosted and fork guard"
  exit 1
fi

echo "PASS: ui-tests self-hosted fork guard is present"
