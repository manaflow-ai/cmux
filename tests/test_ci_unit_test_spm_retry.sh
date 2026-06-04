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
  "Unit tests failed"
  'exit "$EXIT_CODE"'
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in ci.yml: $pattern"
    exit 1
  fi
done

if grep -Fq 'grep -q "(0 unexpected)"' "$WORKFLOW_FILE" "$COMPAT_WORKFLOW_FILE"; then
  echo "FAIL: unit-test workflows must not convert broad XCTest expected failures into passing CI"
  exit 1
fi

if ! grep -Fq 'exit "$EXIT_CODE"' "$COMPAT_WORKFLOW_FILE"; then
  echo "FAIL: ci-macos-compat.yml must propagate unexpected unit-test exit codes"
  exit 1
fi

if ! grep -Fq 'echo "Unit tests failed"' "$DEPOT_WORKFLOW_FILE"; then
  echo "FAIL: test-depot.yml must report nonzero unit-test exits as failures"
  exit 1
fi

if ! grep -Fq 'exit "$EXIT_CODE"' "$DEPOT_WORKFLOW_FILE"; then
  echo "FAIL: test-depot.yml must propagate nonzero unit-test exit codes"
  exit 1
fi

echo "PASS: CI unit-test SwiftPM retry and failure propagation guards are present"
