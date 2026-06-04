#!/usr/bin/env bash
set -euo pipefail

SOURCE_PACKAGES_DIR="${SOURCE_PACKAGES_DIR:-$PWD/.ci-source-packages}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.ci-derived-data/tests}"
RESULT_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-results"
LOG_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-logs"
STATUS_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-status"
SHARD_INDEX="${CMUX_UNIT_TEST_SHARD_INDEX:-0}"
SHARD_COUNT="${CMUX_UNIT_TEST_SHARD_COUNT:-1}"
ORIGINAL_HOME="$HOME"
SWIFT_COMPILER_SUPPORTS_6_2="$(
  xcrun swift -e '#if compiler(>=6.2)
print("1")
#else
print("0")
#endif' 2>/dev/null || echo 0
)"
export SWIFT_COMPILER_SUPPORTS_6_2

mkdir -p "$SOURCE_PACKAGES_DIR" "$RESULT_ROOT" "$LOG_ROOT" "$STATUS_ROOT"
rm -rf "$RESULT_ROOT"/* "$LOG_ROOT"/* "$STATUS_ROOT"/*

TEST_CLASSES=()
while IFS= read -r class; do
  TEST_CLASSES+=("$class")
done < <(
  perl -ne '
    if (!defined($current_file) || $current_file ne $ARGV) {
      $current_file = $ARGV;
      @inactive_blocks = ();
    }
    if (!$ENV{SWIFT_COMPILER_SUPPORTS_6_2} && /^\s*#if\s+compiler\(>=\s*6\.2\)/) {
      push @inactive_blocks, 1;
      next;
    }
    if (@inactive_blocks && /^\s*#if\b/) {
      push @inactive_blocks, 1;
      next;
    }
    if (@inactive_blocks && /^\s*#endif\b/) {
      pop @inactive_blocks;
      next;
    }
    next if @inactive_blocks;
    print "$1\n" if /^\s*(?:@[A-Za-z0-9_()]+\s+)*(?:final\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b/;
  ' cmuxTests/*.swift | sort -u
)

if [ "${#TEST_CLASSES[@]}" -eq 0 ]; then
  echo "No cmuxTests XCTestCase classes were discovered" >&2
  exit 1
fi

case "$SHARD_INDEX" in
  ''|*[!0-9]*)
    echo "CMUX_UNIT_TEST_SHARD_INDEX must be a zero-based integer" >&2
    exit 1
    ;;
esac

case "$SHARD_COUNT" in
  ''|*[!0-9]*)
    echo "CMUX_UNIT_TEST_SHARD_COUNT must be a positive integer" >&2
    exit 1
    ;;
esac

if [ "$SHARD_COUNT" -lt 1 ]; then
  echo "CMUX_UNIT_TEST_SHARD_COUNT must be at least 1" >&2
  exit 1
fi

if [ "$SHARD_INDEX" -ge "$SHARD_COUNT" ]; then
  echo "CMUX_UNIT_TEST_SHARD_INDEX must be less than CMUX_UNIT_TEST_SHARD_COUNT" >&2
  exit 1
fi

SELECTED_TEST_CLASSES=()
class_index=0
for class in "${TEST_CLASSES[@]}"; do
  if [ $((class_index % SHARD_COUNT)) -eq "$SHARD_INDEX" ]; then
    SELECTED_TEST_CLASSES+=("$class")
  fi
  class_index=$((class_index + 1))
done

if [ "${#SELECTED_TEST_CLASSES[@]}" -eq 0 ]; then
  echo "Shard $SHARD_INDEX/$SHARD_COUNT did not select any cmuxTests XCTestCase classes" >&2
  exit 1
fi

echo "Discovered ${#TEST_CLASSES[@]} cmuxTests XCTestCase classes"
echo "Running shard $SHARD_INDEX/$SHARD_COUNT with ${#SELECTED_TEST_CLASSES[@]} classes"

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
  HOME="$test_home" RUSTUP_HOME="$ORIGINAL_HOME/.rustup" CARGO_HOME="$ORIGINAL_HOME/.cargo" CFFIXED_USER_HOME="$test_home" \
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

  if grep -Fq "Test Suite '$class' failed" "$log_file"; then
    echo "failed" >"$status_file"
    echo "FAIL $class"
    return 0
  fi

  if grep -Fq "Test Suite '$class' passed" "$log_file"; then
    echo "passed" >"$status_file"
    if [ "$exit_code" -ne 0 ]; then
      echo "PASS $class (selected class passed; xcodebuild exited $exit_code during app-host cleanup)"
    else
      echo "PASS $class"
    fi
    return 0
  fi

  if [ "$exit_code" -ne 0 ]; then
    echo "failed" >"$status_file"
    echo "FAIL $class (xcodebuild exited $exit_code before reporting a class result)"
    return 0
  fi

  echo "no-tests" >"$status_file"
  echo "FAIL $class did not report an XCTest class result"
  return 0
}

export SOURCE_PACKAGES_DIR DERIVED_DATA_PATH RESULT_ROOT LOG_ROOT STATUS_ROOT ORIGINAL_HOME
export -f run_one_class

printf '%s\n' "${SELECTED_TEST_CLASSES[@]}" | while IFS= read -r class; do
  run_one_class "$class"
done

failed=()
no_tests=()
for class in "${SELECTED_TEST_CLASSES[@]}"; do
  status="$(cat "$STATUS_ROOT/$class.status" 2>/dev/null || echo missing)"
  case "$status" in
    passed) ;;
    failed) failed+=("$class") ;;
    no-tests | missing) no_tests+=("$class") ;;
  esac
done

if [ "${#no_tests[@]}" -ne 0 ]; then
  echo "Unit test classes completed without reporting an XCTest class result:" >&2
  printf '  %s\n' "${no_tests[@]}" >&2
  for class in "${no_tests[@]}"; do
    echo "===== $class log =====" >&2
    tail -n 220 "$LOG_ROOT/$class.log" >&2
  done
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

echo "All ${#SELECTED_TEST_CLASSES[@]} cmuxTests XCTestCase classes passed in isolated app-host runs"
