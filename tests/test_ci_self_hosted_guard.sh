#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures Depot-hosted UI tests are never run for fork pull requests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

EXPECTED_IF="if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

if ! grep -Fq "$EXPECTED_IF" "$WORKFLOW_FILE"; then
  echo "FAIL: Missing fork pull_request guard for tests in $WORKFLOW_FILE"
  echo "Expected line:"
  echo "  $EXPECTED_IF"
  exit 1
fi

if ! awk '
  /^  tests-depot:/ { in_tests=1; next }
  in_tests && /^  [^[:space:]]/ { in_tests=0 }
  in_tests && /runs-on: depot-macos-latest/ { saw_depot=1 }
  in_tests && /github.event.pull_request.head.repo.full_name == github.repository/ { saw_guard=1 }
  END { exit !(saw_depot && saw_guard) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-depot block must keep both depot-macos-latest runner and fork guard"
  exit 1
fi

echo "PASS: tests-depot Depot runner fork guard is present"
