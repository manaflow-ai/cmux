#!/usr/bin/env bash
# Regression test for CI unit-test SwiftPM dependency flake handling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"
COMPAT_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
DEPOT_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/test-depot.yml"

REQUIRED_PATTERNS=(
  "run_unit_tests()"
  "Could not resolve package dependencies"
  "rm -rf ~/Library/Caches/org.swift.swiftpm"
  'rm -rf "$DERIVED_DATA_PATH"'
  'DERIVED_DATA_PATH="$PWD/.ci-derived-data/tests"'
  "run_unit_tests | tee /tmp/test-output.txt"
  "xcodebuild unit tests timed out"
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in ci.yml: $pattern"
    exit 1
  fi
done

for workflow in "$WORKFLOW_FILE" "$COMPAT_WORKFLOW_FILE" "$DEPOT_WORKFLOW_FILE"; do
  if grep -Fq 'All failures are expected, treating as pass' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must not pass unit tests with expected XCTest failures"
    exit 1
  fi

  if grep -Fq 'grep -q "(0 unexpected)"' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must not treat XCTest failure summaries as success"
    exit 1
  fi

  if ! grep -Fq 'echo "Unit tests failed"' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must report nonzero unit-test exits as failures"
    exit 1
  fi

  if ! grep -Fq 'exit "$EXIT_CODE"' "$workflow"; then
    echo "FAIL: $(basename "$workflow") must propagate nonzero unit-test exit codes"
    exit 1
  fi
done

echo "PASS: CI unit-test SwiftPM retry guard is present"
