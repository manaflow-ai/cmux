#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <package-path>" >&2
  exit 2
fi

package_path="$1"
if [[ "${CMUX_CI_REQUIRED_MACOS_SDK_MAJOR:-}" == "export-settings" ]]; then
  set -x
  CMUX_UPDATE_MDM_SCHEMA=1 swift test --package-path "$package_path" --filter ManagedPreferencesManifestTests
  CMUX_UPDATE_ACTION_SURFACES=1 swift test --package-path "$package_path" --filter SettingsSchemaExportTests
  for file in docs/mdm/com.manaflow.cmux.json docs/mdm/com.manaflow.cmux.plist docs/mdm/managed-preferences.md schemas/settings/settings-schema.json; do
    echo "BEGIN_ARTIFACT:$file"
    base64 < "$file" | tr -d "\n"
    echo
    echo "END_ARTIFACT:$file"
  done
  exit 0
fi
suite_timeout_seconds="${CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS:-300}"
if ! [[ "$suite_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
# Same stall rule as the package loop in ci-macos.yml: after the build, no test
# starting or finishing for this long is a hang.
stall_seconds="${CMUX_SWIFT_TEST_STALL_SECONDS:-180}"
if ! [[ "$stall_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "CMUX_SWIFT_TEST_STALL_SECONDS must be a positive integer" >&2
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

# Run every suite, so one early failure or hang does not hide the rest, then
# list each suite's result and exit with the first failure's status.
first_failure=0
results=()
while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  echo "swift test $package_path --skip-build --filter $suite"
  suite_status=0
  # Keep the child from consuming the suite-list pipe that drives this loop.
  # On a stall the watchdog names the tests still running, samples them, and
  # also kills swiftpm-testing-helper, which runs in its own process group.
  python3 "$script_dir/hung_test_watchdog.py" \
    --timeout-seconds "$suite_timeout_seconds" --stall-seconds "$stall_seconds" \
    --label "$suite" \
    -- swift test --package-path "$package_path" --skip-build --filter "$suite" \
    < /dev/null 2>&1 | tee "$evidence_dir/execution.log" || suite_status=$?
  if [ "$suite_status" -eq 124 ]; then
    echo "Swift test suite timed out; retrying $suite once." >&2
    suite_status=0
    python3 "$script_dir/hung_test_watchdog.py" \
      --timeout-seconds "$suite_timeout_seconds" --stall-seconds "$stall_seconds" \
      --label "$suite" \
      -- swift test --package-path "$package_path" --skip-build --filter "$suite" \
      < /dev/null 2>&1 | tee "$evidence_dir/execution.log" || suite_status=$?
  fi
  if [ "$suite_status" -eq 0 ]; then
    python3 "$script_dir/require_swift_test_execution.py" --log "$evidence_dir/execution.log" \
      || suite_status=$?
  fi
  if [ "$suite_status" -eq 0 ]; then
    results+=("PASS $suite")
  else
    [ "$first_failure" -ne 0 ] || first_failure="$suite_status"
    if [ "$suite_status" -eq 124 ]; then
      results+=("FAIL (timed out) $suite")
    else
      results+=("FAIL (exit $suite_status) $suite")
    fi
  fi
done < "$evidence_dir/filters.txt"

failed=0
for result in ${results[@]+"${results[@]}"}; do
  [[ "$result" == PASS* ]] || failed=$((failed + 1))
done
echo "Swift test suites: $(( ${#results[@]} - failed )) passed, $failed failed"
for result in ${results[@]+"${results[@]}"}; do
  echo "  $result"
done
exit "$first_failure"
