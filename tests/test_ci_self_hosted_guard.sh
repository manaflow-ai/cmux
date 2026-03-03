#!/usr/bin/env bash
# Validates CI workflow runner configuration.
# Originally checked for Depot fork guards (manaflow-ai/cmux#385).
# Updated for crux fork: verifies standard GitHub-hosted runners are used.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

# Verify tests-depot job uses a standard GitHub runner (not Depot)
if grep -q 'runs-on: depot-macos' "$WORKFLOW_FILE"; then
  echo "FAIL: tests-depot should use standard GitHub runners, not Depot"
  echo "Replace depot-macos-latest with macos-15"
  exit 1
fi

echo "PASS: CI workflow uses standard GitHub-hosted runners"
