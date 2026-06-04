#!/usr/bin/env bash
set -euo pipefail

SOURCE_PACKAGES_DIR="${SOURCE_PACKAGES_DIR:-$PWD/.ci-source-packages}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.ci-derived-data/tests}"
RESULT_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-results"
LOG_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-logs"
STATUS_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-status"
SHARD_INDEX="${CMUX_UNIT_TEST_SHARD_INDEX:-0}"
SHARD_COUNT="${CMUX_UNIT_TEST_SHARD_COUNT:-1}"
SHARD_TIMEOUT_SECONDS="${CMUX_UNIT_TEST_SHARD_TIMEOUT_SECONDS:-2400}"
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

ONLY_TESTING_ARGS=()
for class in "${SELECTED_TEST_CLASSES[@]}"; do
  ONLY_TESTING_ARGS+=("-only-testing:cmuxTests/$class")
done

SHARD_LABEL="shard-${SHARD_INDEX}-of-${SHARD_COUNT}"
SHARD_LOG="$LOG_ROOT/$SHARD_LABEL.log"
SHARD_RESULT="$RESULT_ROOT/$SHARD_LABEL.xcresult"
SHARD_HOME="${RUNNER_TEMP:-/tmp}/cmux-unit-home-$SHARD_LABEL"
rm -rf "$SHARD_HOME" "$SHARD_RESULT"
mkdir -p "$SHARD_HOME"

set +e
env -u SSH_AUTH_SOCK \
    HOME="$SHARD_HOME" RUSTUP_HOME="$ORIGINAL_HOME/.rustup" CARGO_HOME="$ORIGINAL_HOME/.cargo" CFFIXED_USER_HOME="$SHARD_HOME" \
    scripts/ci/xcodebuild_noninteractive.py \
      xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
      -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      -resultBundlePath "$SHARD_RESULT" \
      "${ONLY_TESTING_ARGS[@]}" \
      test-without-building >"$SHARD_LOG" 2>&1 &
test_pid=$!
deadline=$((SECONDS + SHARD_TIMEOUT_SECONDS))
timed_out=0
while kill -0 "$test_pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    timed_out=1
    echo "Timed out after ${SHARD_TIMEOUT_SECONDS}s running $SHARD_LABEL; terminating xcodebuild" >>"$SHARD_LOG"
    kill -TERM "$test_pid" 2>/dev/null || true
    sleep 5
    if kill -0 "$test_pid" 2>/dev/null; then
      echo "xcodebuild still running for $SHARD_LABEL after SIGTERM; sending SIGKILL" >>"$SHARD_LOG"
      kill -KILL "$test_pid" 2>/dev/null || true
    fi
    break
  fi
  sleep 1
done
wait "$test_pid"
exit_code=$?
set -e

if [ "$timed_out" -ne 0 ]; then
  echo "FAIL $SHARD_LABEL timed out after ${SHARD_TIMEOUT_SECONDS}s" >&2
  echo "===== $SHARD_LABEL log =====" >&2
  tail -n 260 "$SHARD_LOG" >&2
  exit 124
fi

if [ "$exit_code" -ne 0 ]; then
  echo "FAIL $SHARD_LABEL exited $exit_code" >&2
  echo "===== $SHARD_LABEL log =====" >&2
  tail -n 260 "$SHARD_LOG" >&2
  exit "$exit_code"
fi

if ! grep -Fq "Test Suite 'Selected tests' passed" "$SHARD_LOG"; then
  echo "FAIL $SHARD_LABEL did not report a selected XCTest suite pass" >&2
  echo "===== $SHARD_LABEL log =====" >&2
  tail -n 260 "$SHARD_LOG" >&2
  exit 1
fi

echo "All ${#SELECTED_TEST_CLASSES[@]} selected cmuxTests XCTestCase classes passed in $SHARD_LABEL"
