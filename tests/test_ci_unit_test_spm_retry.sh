#!/usr/bin/env bash
# Regression test for CI unit-test SwiftPM dependency flake handling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

REQUIRED_PATTERNS=(
  "run_unit_tests()"
  "Could not resolve package dependencies"
  'resolve_log="$RUNNER_TEMP/cmux-swiftpm-resolve-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-shard-${{ matrix.shard }}.log"'
  'resolve_status="${PIPESTATUS[0]}"'
  "already exists in file system"
  'rm -rf "$HOME/Library/Caches/org.swift.swiftpm"'
  'rm -rf "$SOURCE_PACKAGES_DIR"'
  "rm -rf ~/Library/Caches/org.swift.swiftpm"
  'TEST_OUTPUT="$RUNNER_TEMP/cmux-unit-output-shard-${{ matrix.shard }}.txt"'
  'run_unit_tests | tee "$TEST_OUTPUT"'
  'OUTPUT=$(cat "$TEST_OUTPUT")'
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in ci.yml: $pattern"
    exit 1
  fi
done

echo "PASS: CI unit-test SwiftPM retry guard is present"
