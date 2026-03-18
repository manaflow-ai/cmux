#!/usr/bin/env bash
# Regression test for CI unit-test SwiftPM dependency flake handling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACTION_FILE="$ROOT_DIR/.github/actions/run-unit-test-shard/action.yml"

REQUIRED_PATTERNS=(
  "run_unit_tests()"
  "Could not resolve package dependencies"
  "rm -rf ~/Library/Caches/org.swift.swiftpm"
  "run_unit_tests | tee /tmp/test-output.txt"
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq "$pattern" "$ACTION_FILE"; then
    echo "FAIL: Missing pattern in run-unit-test-shard action: $pattern"
    exit 1
  fi
done

echo "PASS: CI unit-test shard SwiftPM retry guard is present"
