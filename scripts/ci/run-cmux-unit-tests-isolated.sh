#!/usr/bin/env bash
set -euo pipefail

SOURCE_PACKAGES_DIR="${SOURCE_PACKAGES_DIR:-$PWD/.ci-source-packages}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.ci-derived-data/tests}"
RESULT_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-results"
LOG_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-logs"
STATUS_ROOT="${RUNNER_TEMP:-/tmp}/cmux-unit-isolated-status"
SHARD_INDEX="${CMUX_UNIT_TEST_SHARD_INDEX:-0}"
SHARD_COUNT="${CMUX_UNIT_TEST_SHARD_COUNT:-1}"
BATCH_SIZE="${CMUX_UNIT_TEST_BATCH_SIZE:-1}"
BATCH_TIMEOUT_SECONDS="${CMUX_UNIT_TEST_BATCH_TIMEOUT_SECONDS:-900}"
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

case "$BATCH_SIZE" in
  ''|*[!0-9]*)
    echo "CMUX_UNIT_TEST_BATCH_SIZE must be a positive integer" >&2
    exit 1
    ;;
esac

if [ "$BATCH_SIZE" -lt 1 ]; then
  echo "CMUX_UNIT_TEST_BATCH_SIZE must be at least 1" >&2
  exit 1
fi

scripts/ci/xcodebuild_noninteractive.py \
  xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -disableAutomaticPackageResolution \
  -destination "platform=macOS" \
  CMUX_SKIP_ZIG_BUILD=1 \
  build-for-testing

SHARD_LABEL="shard-${SHARD_INDEX}-of-${SHARD_COUNT}"
batch_index=0
class_offset=0
while [ "$class_offset" -lt "${#SELECTED_TEST_CLASSES[@]}" ]; do
  batch_classes=("${SELECTED_TEST_CLASSES[@]:$class_offset:$BATCH_SIZE}")
  BATCH_LABEL="${SHARD_LABEL}-batch-${batch_index}"
  BATCH_LOG="$LOG_ROOT/$BATCH_LABEL.log"
  BATCH_RESULT="$RESULT_ROOT/$BATCH_LABEL.xcresult"
  BATCH_HOME="${RUNNER_TEMP:-/tmp}/cmux-unit-home-$BATCH_LABEL"
  rm -rf "$BATCH_HOME" "$BATCH_RESULT"
  mkdir -p "$BATCH_HOME"

  ONLY_TESTING_ARGS=()
  for class in "${batch_classes[@]}"; do
    ONLY_TESTING_ARGS+=("-only-testing:cmuxTests/$class")
  done

  echo "Running $BATCH_LABEL with ${#batch_classes[@]} classes"
  printf '  %s\n' "${batch_classes[@]}"

  set +e
  env -u SSH_AUTH_SOCK \
      HOME="$BATCH_HOME" RUSTUP_HOME="$ORIGINAL_HOME/.rustup" CARGO_HOME="$ORIGINAL_HOME/.cargo" CFFIXED_USER_HOME="$BATCH_HOME" \
      CMUX_UI_TEST_SUPPRESS_SYSTEM_NOTIFICATIONS=1 \
      scripts/ci/xcodebuild_noninteractive.py \
        xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
        -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -disableAutomaticPackageResolution \
        -destination "platform=macOS" \
        -resultBundlePath "$BATCH_RESULT" \
        "${ONLY_TESTING_ARGS[@]}" \
        test-without-building >"$BATCH_LOG" 2>&1 &
  test_pid=$!
  deadline=$((SECONDS + BATCH_TIMEOUT_SECONDS))
  timed_out=0
  while kill -0 "$test_pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      timed_out=1
      echo "Timed out after ${BATCH_TIMEOUT_SECONDS}s running $BATCH_LABEL; terminating xcodebuild" >>"$BATCH_LOG"
      kill -TERM "$test_pid" 2>/dev/null || true
      sleep 5
      if kill -0 "$test_pid" 2>/dev/null; then
        echo "xcodebuild still running for $BATCH_LABEL after SIGTERM; sending SIGKILL" >>"$BATCH_LOG"
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
    echo "FAIL $BATCH_LABEL timed out after ${BATCH_TIMEOUT_SECONDS}s" >&2
    echo "===== $BATCH_LABEL log =====" >&2
    tail -n 1200 "$BATCH_LOG" >&2
    exit 124
  fi

  if [ "$exit_code" -ne 0 ]; then
    echo "FAIL $BATCH_LABEL exited $exit_code" >&2
    echo "===== $BATCH_LABEL log =====" >&2
    tail -n 1200 "$BATCH_LOG" >&2
    exit "$exit_code"
  fi

  if ! grep -Fq "Test Suite 'Selected tests' passed" "$BATCH_LOG"; then
    echo "FAIL $BATCH_LABEL did not report a selected XCTest suite pass" >&2
    echo "===== $BATCH_LABEL log =====" >&2
    tail -n 1200 "$BATCH_LOG" >&2
    exit 1
  fi

  echo "PASS $BATCH_LABEL"
  batch_index=$((batch_index + 1))
  class_offset=$((class_offset + BATCH_SIZE))
done

echo "All ${#SELECTED_TEST_CLASSES[@]} selected cmuxTests XCTestCase classes passed in $SHARD_LABEL batches"
