#!/usr/bin/env bash
# Regression test for CI unit-test SwiftPM dependency flake handling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

REQUIRED_PATTERNS=(
  "debug-app-build:"
  "Resolve Swift packages"
  "for attempt in 1 2 3"
  "Failed to resolve Swift packages after 3 attempts"
  "run_unit_tests()"
  "run_unit_tests | tee /tmp/test-output.txt"
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in ci.yml: $pattern"
    exit 1
  fi
done

echo "PASS: CI shared-build SwiftPM retry and unit-test runner guards are present"
