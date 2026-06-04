#!/usr/bin/env bash
# Regression test for CI unit-test SwiftPM dependency flake handling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"
COMPAT_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
DEPOT_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/test-depot.yml"
ISOLATED_RUNNER="$ROOT_DIR/scripts/ci/run-cmux-unit-tests-isolated.sh"

REQUIRED_PATTERNS=(
  "run_unit_tests()"
  "Could not resolve package dependencies"
  "rm -rf ~/Library/Caches/org.swift.swiftpm"
  'rm -rf "$DERIVED_DATA_PATH"'
  'DERIVED_DATA_PATH="$PWD/.ci-derived-data/tests"'
  "scripts/ci/run-cmux-unit-tests-isolated.sh"
  "run_unit_tests | tee /tmp/test-output.txt"
  "cmuxTests XCTestCase classes passed in isolated app-host runs"
  "Unit tests failed"
  'exit "$EXIT_CODE"'
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq -- "$pattern" "$WORKFLOW_FILE"; then
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

for file in "$COMPAT_WORKFLOW_FILE" "$DEPOT_WORKFLOW_FILE"; do
  if ! grep -Fq -- 'scripts/ci/run-cmux-unit-tests-isolated.sh' "$file"; then
    echo "FAIL: $(basename "$file") must run the class-isolated app-host unit-test runner"
    exit 1
  fi
done

ISOLATED_RUNNER_PATTERNS=(
  "build-for-testing"
  "test-without-building"
  '-only-testing:"cmuxTests/$class"'
  'CFFIXED_USER_HOME="$test_home"'
  'RUSTUP_HOME="$HOME/.rustup" CARGO_HOME="$HOME/.cargo"'
  "All \${#TEST_CLASSES[@]} cmuxTests XCTestCase classes passed in isolated app-host runs"
)

for pattern in "${ISOLATED_RUNNER_PATTERNS[@]}"; do
  if ! grep -Fq -- "$pattern" "$ISOLATED_RUNNER"; then
    echo "FAIL: run-cmux-unit-tests-isolated.sh missing pattern: $pattern"
    exit 1
  fi
done

if grep -Fq -- "-skip-testing" "$ISOLATED_RUNNER"; then
  echo "FAIL: run-cmux-unit-tests-isolated.sh must not skip cmuxTests classes"
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
