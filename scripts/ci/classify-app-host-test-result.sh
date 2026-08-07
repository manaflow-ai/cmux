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

# xcodebuild_noninteractive.py reserves 126 for a required Swift Testing phase
# that never produced a terminal result. An earlier clean XCTest summary cannot
# make that incomplete mixed-framework run successful.
if [ "$original_status" -eq 126 ]; then
  echo "Required Swift Testing phase did not complete" >&2
  exit 1
fi

if [ ! -r "$output_path" ]; then
  echo "FAIL: app-host test output could not be classified" >&2
  exit 1
fi

summary="$(grep -E "Executed.*tests?.*with.*failures?" "$output_path" | tail -n 1 || true)"
if [[ "$summary" == *"(0 unexpected)"* ]]; then
  echo "All failures are expected, treating as pass"
  exit 0
fi

echo "Unexpected test failures detected" >&2
exit 1
