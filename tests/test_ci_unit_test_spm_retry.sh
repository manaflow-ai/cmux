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
  'SUMMARY=$(grep "Executed.*tests.*with.*failures" <<<"$OUTPUT" | tail -1)'
  'grep -q "(0 unexpected)"'
  "Unexpected test failures detected"
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in ci.yml: $pattern"
    exit 1
  fi
done

if ! grep -Fq 'SUMMARY=$(grep "Executed.*tests.*with.*failures" <<<"$OUTPUT" | tail -1)' "$COMPAT_WORKFLOW_FILE"; then
  echo "FAIL: ci-macos-compat.yml must inspect XCTest failure summaries"
  exit 1
fi

if ! grep -Fq 'grep -q "(0 unexpected)"' "$COMPAT_WORKFLOW_FILE"; then
  echo "FAIL: ci-macos-compat.yml must allow only expected XCTest failures"
  exit 1
fi

if ! grep -Fq 'Unexpected unit test failures detected' "$COMPAT_WORKFLOW_FILE"; then
  echo "FAIL: ci-macos-compat.yml must report unexpected unit-test failures"
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

echo "PASS: CI unit-test SwiftPM retry and expected-failure guards are present"
