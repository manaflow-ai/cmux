#!/usr/bin/env bash
# Regression test for CI unit-test SwiftPM dependency flake handling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

REQUIRED_PATTERNS=(
  "run_unit_tests()"
  "python3 .github/scripts/run-with-output-watchdog.py"
  "CMUX_TEST_CHUNK_SIZE: 48"
  "should_isolate_selector()"
  "-parallel-testing-enabled NO"
  "--output \"\$output_path\""
  "OUTPUT=\$(cat \"\$CHUNK_OUTPUT\")"
  "Could not resolve package dependencies"
  "rm -rf ~/Library/Caches/org.swift.swiftpm"
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq -- "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in ci.yml: $pattern"
    exit 1
  fi
done

echo "PASS: CI unit-test SwiftPM retry guard is present"
