#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <exit-code> <captured-output-path>" >&2
  exit 2
fi

original_status="$1"
output_path="$2"
case "$original_status" in
  ""|*[!0-9]*)
    echo "FAIL: app-host test exit code must be a nonnegative integer" >&2
    exit 2
    ;;
esac

if [ "$original_status" -eq 0 ]; then
  exit 0
fi

# xcodebuild_noninteractive.py reserves these statuses for authoritative
# mixed-framework outcomes. An earlier clean XCTest summary cannot override
# any of them, even if console backpressure omitted the decisive output line.
if [ "$original_status" -eq 123 ]; then
  echo "Swift Testing failures detected" >&2
  exit 1
fi

if [ "$original_status" -eq 124 ]; then
  echo "App-host test run timed out" >&2
  exit 1
fi

if [ "$original_status" -eq 126 ]; then
  echo "Required Swift Testing phase did not complete" >&2
  exit 1
fi

if [ ! -r "$output_path" ]; then
  echo "FAIL: app-host test output could not be classified" >&2
  exit 1
fi

if grep -Eq \
  'Test run with [0-9]+ tests?( in [0-9]+ suites?)? failed after ' \
  "$output_path"; then
  echo "Swift Testing failures detected" >&2
  exit 1
fi

summary="$(grep -E "Executed.*tests?.*with.*failures?" "$output_path" | tail -n 1 || true)"
if [[ "$summary" == *"(0 unexpected)"* ]]; then
  echo "All failures are expected, treating as pass"
  exit 0
fi

echo "Unexpected test failures detected" >&2
exit 1
