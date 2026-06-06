#!/usr/bin/env bash
# Regression test for CI unit-test SwiftPM dependency flake handling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

REQUIRED_PATTERNS=(
  "run_unit_tests()"
  "output_path = \"/tmp/test-output.txt\""
  "CMUX_XCTEST_CRASH_QUIET_TIMEOUT_SECONDS"
  "CMUX_DERIVED_DATA_PATH"
  "Program crashed:"
  "start_new_session=True"
  "os.killpg"
  "signal.SIGTERM"
  "signal.SIGKILL"
  "os.set_blocking"
  "os.read(fd, 65536)"
  "stdout_fd = process.stdout.fileno()"
  "stdout_eof = False"
  "stdout_eof = True"
  "os.read(stdout_fd, 65536)"
  "drain_remaining_output(process, output)"
  "Could not resolve package dependencies"
  "rm -rf ~/Library/Caches/org.swift.swiftpm"
  'OUTPUT=$(cat /tmp/test-output.txt)'
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in ci.yml: $pattern"
    exit 1
  fi
done

if grep -Fq "process.stdout.readline()" "$WORKFLOW_FILE"; then
  echo "FAIL: CI watchdog must not block on process.stdout.readline()"
  exit 1
fi

echo "PASS: CI unit-test SwiftPM retry guard is present"
