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
evidence_dir="$(mktemp -d)"
trap 'rm -rf "$evidence_dir"' EXIT
# Keep process-global test state inside one suite. Some packages otherwise
# finish every assertion but leave the aggregate Swift Testing runner waiting.
swift test list --package-path "$package_path" > "$evidence_dir/discovered-tests.txt"
python3 "$script_dir/require_swift_test_execution.py" \
  --list-filters "$evidence_dir/discovered-tests.txt" > "$evidence_dir/filters.txt"

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  echo "swift test $package_path --skip-build --filter $suite"
  suite_status=0
  # Keep the child from consuming the suite-list pipe that drives this loop.
  # On a stall the watchdog names the tests still running, samples them, and
  # also kills swiftpm-testing-helper, which runs in its own process group.
  python3 "$script_dir/hung_test_watchdog.py" \
    --timeout-seconds "$suite_timeout_seconds" --label "$suite" \
    -- swift test --package-path "$package_path" --skip-build --filter "$suite" \
    < /dev/null 2>&1 | tee "$evidence_dir/execution.log" || suite_status=$?
  if [ "$suite_status" -eq 124 ]; then
    echo "Swift test suite timed out; retrying $suite once." >&2
    suite_status=0
    python3 "$script_dir/hung_test_watchdog.py" \
      --timeout-seconds "$suite_timeout_seconds" --label "$suite" \
      -- swift test --package-path "$package_path" --skip-build --filter "$suite" \
      < /dev/null 2>&1 | tee "$evidence_dir/execution.log" || suite_status=$?
  fi
  if [ "$suite_status" -ne 0 ]; then
    exit "$suite_status"
  fi
  python3 "$script_dir/require_swift_test_execution.py" --log "$evidence_dir/execution.log"
done < "$evidence_dir/filters.txt"
