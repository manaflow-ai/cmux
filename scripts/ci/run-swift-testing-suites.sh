#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <package-path>" >&2
  exit 2
fi

package_path="$1"
suite_timeout_seconds="${CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS:-300}"
if ! [[ "$suite_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Keep process-global test state inside one suite. Some packages otherwise
# finish every assertion but leave the aggregate Swift Testing runner waiting.
# GhosttyKit's static archive name also makes `swift test list` return a
# nonzero status after emitting the complete list. Preserve that list while
# tolerating only the same known diagnostic accepted by the package test lane.
suite_list_output=""
suite_list_status=0
suite_list_output="$(swift test list --package-path "$package_path" 2>&1)" || suite_list_status=$?
if [ "$suite_list_status" -ne 0 ]; then
  if printf '%s\n' "$suite_list_output" \
    | grep -v 'unexpected binary' \
    | grep -Eq '(^|[^a-zA-Z])error:'; then
    printf '%s\n' "$suite_list_output" >&2
    exit "$suite_list_status"
  fi
fi
suite_list="$(printf '%s\n' "$suite_list_output" | sed -nE 's/^[^.]+\.([A-Za-z_][A-Za-z0-9_]*)\/.*$/\1/p' | sort -u)"

if [ -z "$suite_list" ]; then
  echo "no test suites discovered for $package_path" >&2
  exit 1
fi

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  echo "swift test $package_path --filter $suite"
  suite_status=0
  # Keep the child from consuming the suite-list pipe that drives this loop.
  python3 "$script_dir/run_with_timeout.py" \
    --timeout-seconds "$suite_timeout_seconds" \
    -- swift test --package-path "$package_path" --filter "$suite" \
    < /dev/null || suite_status=$?
  if [ "$suite_status" -eq 124 ]; then
    echo "Swift test suite timed out; retrying $suite once." >&2
    suite_status=0
    python3 "$script_dir/run_with_timeout.py" \
      --timeout-seconds "$suite_timeout_seconds" \
      -- swift test --package-path "$package_path" --filter "$suite" \
      < /dev/null || suite_status=$?
  fi
  if [ "$suite_status" -ne 0 ]; then
    exit "$suite_status"
  fi
done < <(printf '%s\n' "$suite_list")
