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

TEST_IDENTIFIERS=()
while IFS= read -r test_identifier; do
  TEST_IDENTIFIERS+=("$test_identifier")
done < <(
  perl -ne '
    if (!defined($current_file) || $current_file ne $ARGV) {
      $current_file = $ARGV;
      @inactive_blocks = ();
      $imports_testing = 0;
      $pending_suite_attribute = 0;
      $candidate_name = "";
      $candidate_kind = "";
      $candidate_depth = 0;
      $candidate_has_test = 0;
      $candidate_has_suite_attribute = 0;
      $swift_brace_depth = 0;
    }

    sub brace_delta {
      my ($line) = @_;
      my $opens = ($line =~ tr/{/{/);
      my $closes = ($line =~ tr/}/}/);
      return $opens - $closes;
    }

    sub maybe_emit_candidate {
      if ($candidate_name ne "" && ($candidate_has_test || $candidate_has_suite_attribute)) {
        print "$candidate_name\n";
      }
      $candidate_name = "";
      $candidate_kind = "";
      $candidate_depth = 0;
      $candidate_has_test = 0;
      $candidate_has_suite_attribute = 0;
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

    $imports_testing = 1 if /^\s*import\s+Testing\b/;

    my $line = $_;
    my $depth_before = $swift_brace_depth // 0;

    if ($candidate_name eq "" && /^\s*(?:\@[A-Za-z0-9_()]+\s+)*(?:final\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b/) {
      $candidate_name = $1;
      $candidate_kind = "xctest";
      $candidate_depth = $depth_before;
      $candidate_has_test = /\bfunc\s+test[A-Za-z0-9_]*\s*\(/ ? 1 : 0;
      $candidate_has_suite_attribute = 0;
    } elsif ($candidate_kind eq "xctest" && /\bfunc\s+test[A-Za-z0-9_]*\s*\(/) {
      $candidate_has_test = 1;
    }

    if ($imports_testing) {
      $pending_suite_attribute = 1 if /^\s*\@Suite\b/;

      if ($candidate_name eq "" && $depth_before == 0 && /^\s*(?:\@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal)\s+)?struct\s+([A-Za-z_][A-Za-z0-9_]*)\b/) {
        $candidate_name = $1;
        $candidate_kind = "swift-testing";
        $candidate_depth = $depth_before;
        $candidate_has_test = 0;
        $candidate_has_suite_attribute = $pending_suite_attribute || /^\s*\@Suite\b/;
        $pending_suite_attribute = 0;
      } elsif ($candidate_name ne "" && /^\s*\@Test\b/) {
        $candidate_has_test = 1;
      }
    }

    $swift_brace_depth = $depth_before + brace_delta($line);
    if (($swift_brace_depth // 0) < 0) {
      $swift_brace_depth = 0;
    }

    if ($candidate_name ne "" && ($swift_brace_depth // 0) <= $candidate_depth && /}/) {
      maybe_emit_candidate();
    }
  ' cmuxTests/*.swift | sort -u
)

if [ "${#TEST_IDENTIFIERS[@]}" -eq 0 ]; then
  echo "No cmuxTests XCTestCase classes or Swift Testing suites were discovered" >&2
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

SELECTED_TEST_IDENTIFIERS=()
for test_identifier in "${TEST_IDENTIFIERS[@]}"; do
  class_hash="$(printf '%s' "$test_identifier" | cksum | awk '{print $1}')"
  if [ $((class_hash % SHARD_COUNT)) -eq "$SHARD_INDEX" ]; then
    SELECTED_TEST_IDENTIFIERS+=("$test_identifier")
  fi
done

if [ "${#SELECTED_TEST_IDENTIFIERS[@]}" -eq 0 ]; then
  echo "Shard $SHARD_INDEX/$SHARD_COUNT did not select any cmuxTests XCTestCase classes or Swift Testing suites" >&2
  exit 1
fi

echo "Discovered ${#TEST_IDENTIFIERS[@]} cmuxTests XCTestCase classes and Swift Testing suites"
echo "Running shard $SHARD_INDEX/$SHARD_COUNT with ${#SELECTED_TEST_IDENTIFIERS[@]} test types"

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
while [ "$class_offset" -lt "${#SELECTED_TEST_IDENTIFIERS[@]}" ]; do
  batch_classes=("${SELECTED_TEST_IDENTIFIERS[@]:$class_offset:$BATCH_SIZE}")
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

  run_xctest_batch() {
    local label="$1"
    local log_path="$2"
    local result_path="$3"
    local home_path="$4"
    shift 4
    local only_testing_args=("$@")

    rm -rf "$home_path" "$result_path"
    mkdir -p "$home_path"

    set +e
    env -u SSH_AUTH_SOCK \
        HOME="$home_path" RUSTUP_HOME="$ORIGINAL_HOME/.rustup" CARGO_HOME="$ORIGINAL_HOME/.cargo" CFFIXED_USER_HOME="$home_path" \
        CMUX_UI_TEST_SUPPRESS_SYSTEM_NOTIFICATIONS=1 \
        scripts/ci/xcodebuild_noninteractive.py \
          xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
          -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
          -derivedDataPath "$DERIVED_DATA_PATH" \
          -disableAutomaticPackageResolution \
          -destination "platform=macOS" \
          -resultBundlePath "$result_path" \
          "${only_testing_args[@]}" \
          test-without-building >"$log_path" 2>&1 &
    test_pid=$!
    deadline=$((SECONDS + BATCH_TIMEOUT_SECONDS))
    timed_out=0
    while kill -0 "$test_pid" 2>/dev/null; do
      if [ "$SECONDS" -ge "$deadline" ]; then
        timed_out=1
        echo "Timed out after ${BATCH_TIMEOUT_SECONDS}s running $label; terminating xcodebuild" >>"$log_path"
        kill -TERM "$test_pid" 2>/dev/null || true
        sleep 5
        if kill -0 "$test_pid" 2>/dev/null; then
          echo "xcodebuild still running for $label after SIGTERM; sending SIGKILL" >>"$log_path"
          kill -KILL "$test_pid" 2>/dev/null || true
        fi
        break
      fi
      sleep 1
    done
    wait "$test_pid"
    exit_code=$?

    if [ "$timed_out" -ne 0 ]; then
      echo "FAIL $label timed out after ${BATCH_TIMEOUT_SECONDS}s" >&2
      echo "===== $label log =====" >&2
      tail -n 1200 "$log_path" >&2
      exit 124
    fi

    return "$exit_code"
  }

  executed_test_count() {
    local log_path="$1"
    local result_path="$2"
    local count

    count=""
    if [ -d "$result_path" ] && command -v xcrun >/dev/null 2>&1; then
      count="$(
        { xcrun xcresulttool get test-results summary --path "$result_path" --format json 2>/dev/null || true; } |
          /usr/bin/python3 -c '
import json
import sys

try:
    summary = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

total = None
for key in ("totalTestCount", "testsCount", "testCount"):
    value = summary.get(key)
    if isinstance(value, int):
        total = value
        break

if total is None:
    metrics = summary.get("metrics")
    if isinstance(metrics, dict):
        for key in ("testsCount", "testCount", "totalTestCount"):
            value = metrics.get(key)
            if isinstance(value, int):
                total = value
                break

print("" if total is None else total)
'
      )"
    fi

    if [ -n "$count" ]; then
      printf '%s\n' "$count"
      return 0
    fi

    /usr/bin/awk '
      /Test Case .* passed/ { count += 1 }
      /Test .* passed after [0-9.]+ seconds/ { count += 1 }
      END { print count + 0 }
    ' "$log_path"
  }

  assert_executed_tests() {
    local label="$1"
    local log_path="$2"
    local result_path="$3"
    local count

    count="$(executed_test_count "$log_path" "$result_path")"
    case "$count" in
      ''|*[!0-9]*)
        echo "FAIL $label could not determine executed test count" >&2
        echo "===== $label log =====" >&2
        tail -n 1200 "$log_path" >&2
        exit 1
        ;;
    esac
    if [ "$count" -eq 0 ]; then
      echo "FAIL $label reported zero executed tests" >&2
      echo "===== $label log =====" >&2
      tail -n 1200 "$log_path" >&2
      exit 1
    fi
  }

  echo "Running $BATCH_LABEL with ${#batch_classes[@]} classes"
  printf '  %s\n' "${batch_classes[@]}"

  set +e
  run_xctest_batch "$BATCH_LABEL" "$BATCH_LOG" "$BATCH_RESULT" "$BATCH_HOME" "${ONLY_TESTING_ARGS[@]}"
  exit_code=$?
  set -e

  if [ "$exit_code" -ne 0 ]; then
    if grep -Fq "Restarting after unexpected exit, crash, or test timeout" "$BATCH_LOG"; then
      echo "FAIL $BATCH_LABEL crashed or timed out under XCTest; fix the underlying app-host crash instead of retrying it" >&2
      echo "===== $BATCH_LABEL log =====" >&2
      tail -n 1200 "$BATCH_LOG" >&2
      exit "$exit_code"
    fi
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
  assert_executed_tests "$BATCH_LABEL" "$BATCH_LOG" "$BATCH_RESULT"

  echo "PASS $BATCH_LABEL"
  batch_index=$((batch_index + 1))
  class_offset=$((class_offset + BATCH_SIZE))
done

echo "All ${#SELECTED_TEST_IDENTIFIERS[@]} selected cmuxTests XCTestCase classes and Swift Testing suites passed in $SHARD_LABEL batches"
