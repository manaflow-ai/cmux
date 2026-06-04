#!/usr/bin/env bash
set -euo pipefail

SOURCE_PACKAGES_DIR="${SOURCE_PACKAGES_DIR:-$PWD/.ci-source-packages}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.ci-derived-data/tests}"
RESULT_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-results"
LOG_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-logs"
STATUS_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-status"

mkdir -p "$SOURCE_PACKAGES_DIR" "$RESULT_ROOT" "$LOG_ROOT" "$STATUS_ROOT"
rm -rf "$RESULT_ROOT"/* "$LOG_ROOT"/* "$STATUS_ROOT"/*

TEST_CLASSES=()
while IFS= read -r class; do
  TEST_CLASSES+=("$class")
done < <(
  perl -ne 'print "$1\n" if /^\s*(?:@[A-Za-z0-9_()]+\s+)*(?:final\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b/' cmuxTests/*.swift | sort -u
)

if [ "${#TEST_CLASSES[@]}" -eq 0 ]; then
  echo "No cmuxTests XCTestCase classes were discovered" >&2
  exit 1
fi

echo "Discovered ${#TEST_CLASSES[@]} cmuxTests XCTestCase classes"

scripts/ci/xcodebuild_noninteractive.py \
  xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -disableAutomaticPackageResolution \
  -destination "platform=macOS" \
  CMUX_SKIP_ZIG_BUILD=1 \
  build-for-testing

run_one_class() {
  local class="$1"
  local log_file="$LOG_ROOT/$class.log"
  local status_file="$STATUS_ROOT/$class.status"
  local result_path="$RESULT_ROOT/$class.xcresult"
  local test_home="${RUNNER_TEMP:-/tmp}/cmux-unit-home-$class"
  rm -rf "$test_home" "$result_path"
  mkdir -p "$test_home"

  set +e
  RUSTUP_HOME="$HOME/.rustup" CARGO_HOME="$HOME/.cargo" CFFIXED_USER_HOME="$test_home" \
    scripts/ci/xcodebuild_noninteractive.py \
      xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
      -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      -resultBundlePath "$result_path" \
      -only-testing:"cmuxTests/$class" \
      test-without-building >"$log_file" 2>&1
  local exit_code=$?
  set -e

  if ! grep -Eq 'Executed [1-9][0-9]* test,|Executed [1-9][0-9]* tests|Test run with [1-9][0-9]* tests' "$log_file"; then
    echo "no-tests" >"$status_file"
    echo "FAIL $class did not execute any tests"
    return 0
  fi

  if [ "$exit_code" -ne 0 ]; then
    echo "failed" >"$status_file"
    echo "FAIL $class"
    return 0
  fi

  echo "passed" >"$status_file"
  echo "PASS $class"
}

export SOURCE_PACKAGES_DIR DERIVED_DATA_PATH RESULT_ROOT LOG_ROOT STATUS_ROOT
export -f run_one_class

printf '%s\n' "${TEST_CLASSES[@]}" | while IFS= read -r class; do
  run_one_class "$class"
done

failed=()
no_tests=()
for class in "${TEST_CLASSES[@]}"; do
  status="$(cat "$STATUS_ROOT/$class.status" 2>/dev/null || echo missing)"
  case "$status" in
    passed) ;;
    failed) failed+=("$class") ;;
    no-tests | missing) no_tests+=("$class") ;;
  esac
done

if [ "${#no_tests[@]}" -ne 0 ]; then
  echo "Unit test classes completed without executing tests:" >&2
  printf '  %s\n' "${no_tests[@]}" >&2
fi

if [ "${#failed[@]}" -ne 0 ]; then
  echo "Failing unit test classes:" >&2
  printf '  %s\n' "${failed[@]}" >&2
  for class in "${failed[@]}"; do
    echo "===== $class log =====" >&2
    tail -n 220 "$LOG_ROOT/$class.log" >&2
  done
fi

if [ "${#failed[@]}" -ne 0 ] || [ "${#no_tests[@]}" -ne 0 ]; then
  exit 1
fi

echo "All ${#TEST_CLASSES[@]} cmuxTests XCTestCase classes passed in isolated app-host runs"
