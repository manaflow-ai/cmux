#!/usr/bin/env bash
# Run this worker's app-host unit-test batches, or, when
# CMUX_APP_HOST_UNIT_SELECTORS is set, one batch holding exactly those suites.
# CMUX_APP_HOST_SHARD names the physical worker. Shared by the app-host
# unit-test shards and compile admission's changed-suites run.
set -euo pipefail
PHYSICAL_SHARD="${CMUX_APP_HOST_SHARD:?CMUX_APP_HOST_SHARD is required}"
PHYSICAL_SHARD_TOTAL=6
LOGICAL_BATCHES_PER_WORKER=2
LOGICAL_SHARD_TOTAL=$((PHYSICAL_SHARD_TOTAL * LOGICAL_BATCHES_PER_WORKER))
LOGICAL_SHARDS=("$PHYSICAL_SHARD" "$((PHYSICAL_SHARD + PHYSICAL_SHARD_TOTAL))")
if [ -n "${CMUX_APP_HOST_UNIT_SELECTORS:-}" ]; then
  # A changed-suites run: one batch holding exactly those suites.
  LOGICAL_SHARD_TOTAL=1
  LOGICAL_SHARDS=(1)
fi

# Each worker runs two balanced batches sequentially. Every invocation
# writes to a regular file, and this script mirrors that file into the
# Actions log itself. Detached test descendants therefore cannot retain
# the CI capture pipe after xcodebuild exits.
#
# Mirroring in-process rather than from a background `tail -f` is what
# makes the last write observable. A tail had to be given some margin
# to deliver it before being killed, and a loaded runner could miss
# that margin and drop the final lines -- the ones saying why a batch
# died. Tracking the byte offset here has no margin to miss.
stream_offset=0
emit_batch_output() {
  local file="$1" size
  size="$(wc -c <"$file" 2>/dev/null || echo 0)"
  size="${size//[[:space:]]/}"
  if [ "${size:-0}" -gt "$stream_offset" ]; then
    # Read exactly the byte range included in the size snapshot.
    # Reading to EOF here would race a concurrent writer: bytes
    # appended after wc(1) could be emitted now while stream_offset
    # advances only to the old size, duplicating them next poll.
    python3 -c '
import sys
path, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, "rb") as stream:
    stream.seek(start)
    sys.stdout.buffer.write(stream.read(end - start))
' "$file" "$stream_offset" "$size"
    stream_offset="$size"
  fi
}
run_unit_test_batch() {
  local logical_shard="$1"
  local execution_attempt="$2"
  local shard_args="$RUNNER_TEMP/cmux-unit-shard-${logical_shard}-of-${LOGICAL_SHARD_TOTAL}.args"
  local batch_output="$RUNNER_TEMP/cmux-unit-output-${logical_shard}-of-${LOGICAL_SHARD_TOTAL}-run-${execution_attempt}.txt"
  local batch_tag="unit-physical-${PHYSICAL_SHARD}-logical-${logical_shard}-run-${execution_attempt}"
  local result_bundle_root="${CMUX_APP_HOST_RESULT_BUNDLE_ROOT:-${RUNNER_TEMP:-/tmp}/cmux-app-host-xcresults}"
  local reserve_args=()
  local reservation
  for reservation in ${CMUX_APP_HOST_RESERVED_WALL_SECONDS:-}; do
    reserve_args+=(--reserve "$reservation")
  done
  if [ -n "${CMUX_APP_HOST_UNIT_SELECTORS:-}" ]; then
    # Suites a strict step owns ran in that step, not this batch.
    python3 - "$shard_args" <<'PY'
import os
import sys
sys.path.insert(0, "scripts/ci")
from cmux_unit_test_shard import FOCUSED_GATE_SELECTORS
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for selector in os.environ["CMUX_APP_HOST_UNIT_SELECTORS"].split():
        if selector not in FOCUSED_GATE_SELECTORS:
            handle.write(f"-only-testing:{selector}\n")
PY
    if [ ! -s "$shard_args" ]; then
      echo "Every changed suite ran in its strict step; no shared batch."
      return 0
    fi
  else
    python3 scripts/ci/cmux_unit_test_shard.py \
      --shard-index "$logical_shard" \
      --shard-total "$LOGICAL_SHARD_TOTAL" \
      --physical-shard-total "$PHYSICAL_SHARD_TOTAL" \
      ${reserve_args[@]+"${reserve_args[@]}"} \
      --output "$shard_args" || {
        local shard_status=$?
        echo "Failed to generate app-host unit-test batch ${logical_shard}/${LOGICAL_SHARD_TOTAL}"
        return "$shard_status"
      }
  fi
  if [ ! -r "$shard_args" ]; then
    echo "Missing selector file for app-host unit-test batch ${logical_shard}/${LOGICAL_SHARD_TOTAL}"
    return 1
  fi
  local only_testing_args=()
  while IFS= read -r arg; do
    [ -n "$arg" ] && only_testing_args+=("$arg")
  done < "$shard_args"
  if [ "${#only_testing_args[@]}" -eq 0 ]; then
    echo "No selectors generated for app-host unit-test batch ${logical_shard}/${LOGICAL_SHARD_TOTAL}"
    return 1
  fi

  # CmuxBundledBinPathIntegrationTests includes fish-specific coverage
  # that is enabled only when fish exists. Install it only on the
  # worker/batch that actually owns that selector.
  if grep -Fq 'CmuxBundledBinPathIntegrationTests' "$shard_args"; then
    if ! command -v fish >/dev/null 2>&1; then
      HOMEBREW_NO_AUTO_UPDATE=1 brew install fish
    fi
    command -v fish >/dev/null 2>&1 || {
      echo "fish is required for CmuxBundledBinPathIntegrationTests" >&2
      return 1
    }
  fi

  echo "Running app-host unit-test batch ${logical_shard}/${LOGICAL_SHARD_TOTAL}, execution ${execution_attempt}"
  : >"$batch_output"
  stream_offset=0
  CMUX_TAG="$batch_tag" \
    scripts/ci/run-in-console-session.sh \
    scripts/ci/run-app-host-xcodebuild.sh \
    -xctestrun "$CMUX_APP_HOST_XCTESTRUN" \
    -destination "platform=macOS" \
    "${only_testing_args[@]}" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance "${CMUX_UNIT_TEST_CASE_TIMEOUT_SECONDS:-300}" \
    -maximum-test-execution-time-allowance "${CMUX_UNIT_TEST_CASE_TIMEOUT_SECONDS:-300}" \
    CMUX_SKIP_ZIG_BUILD=1 \
    test-without-building >"$batch_output" 2>&1 &
  local xcodebuild_pid=$!

  local timeout_seconds="${CMUX_UNIT_TEST_TIMEOUT_SECONDS:-900}"
  local deadline=$((SECONDS + timeout_seconds))
  local timed_out=0
  while kill -0 "$xcodebuild_pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      local unfinished="$RUNNER_TEMP/cmux-unit-unfinished-${logical_shard}-run-${execution_attempt}.txt"
      grep -E "Test Case .* started|[◇◆] Test .* started\." "$batch_output" \
        | tail -40 >"$unfinished" || true
      {
        echo "xcodebuild unit-test batch ${logical_shard}/${LOGICAL_SHARD_TOTAL} timeout after ${timeout_seconds}s; terminating"
        echo "Last observed test starts:"
        cat "$unfinished" 2>/dev/null || true
        # shellcheck disable=SC2009 # include parent/group/elapsed diagnostics
        ps -axo pid,ppid,pgid,etime,command 2>/dev/null \
          | grep -E 'xcodebuild|xctest|run-app-host-xcodebuild|app_host_test_lock|Contents/MacOS/cmux' \
          | grep -v grep || true
      } >>"$batch_output" 2>&1
      for hang_pid in $(pgrep -f 'Contents/MacOS/cmux DEV( |$)' 2>/dev/null | head -2); do
        hang_sample="$RUNNER_TEMP/app-host-hang-sample-${logical_shard}-run-${execution_attempt}-${hang_pid}.txt"
        if sample "$hang_pid" 3 -mayDie -file "$hang_sample" >/dev/null 2>&1; then
          {
            echo "app-host hang sample: $hang_sample"
            awk '/^Call graph:/{p=1} p' "$hang_sample" | head -900
          } >>"$batch_output" 2>&1
        fi
      done
      kill -TERM "$xcodebuild_pid" 2>/dev/null || true
      pkill -TERM -f "$CMUX_DERIVED_DATA_PATH" 2>/dev/null || true
      sleep 5
      kill -KILL "$xcodebuild_pid" 2>/dev/null || true
      pkill -KILL -f "$CMUX_DERIVED_DATA_PATH" 2>/dev/null || true
      timed_out=1
      break
    fi
    emit_batch_output "$batch_output"
    sleep 5
  done

  local batch_status
  set +e
  wait "$xcodebuild_pid"
  batch_status=$?
  set -e
  if [ "$timed_out" -eq 1 ]; then
    batch_status=124
  fi

  emit_batch_output "$batch_output"

  shopt -s nullglob
  local typed_results=("$result_bundle_root"/cmux-app-host-xcodebuild-"$batch_tag"-pid-*.tests.json)
  shopt -u nullglob
  if [ "${#typed_results[@]}" -eq 0 ]; then
    echo "No typed xcresult test JSON found for $batch_tag" >&2
    if [ "$batch_status" -ne 0 ]; then
      return "$batch_status"
    fi
    return 1
  fi

  local accounting_status
  local ratchet_mode=()
  if [ -n "${CMUX_APP_HOST_UNIT_SELECTORS:-}" ]; then
    ratchet_mode=(--changed-suites)
  fi
  set +e
  python3 scripts/ci/app_host_result_accounting.py check-run \
    --inventory "$CMUX_APP_HOST_TEST_INVENTORY" \
    --selectors "$shard_args" \
    --known scripts/ci/app-host-known-failures.json \
    --log "$batch_output" \
    --xcode-status "$batch_status" \
    --tests-json "${typed_results[@]}" \
    ${ratchet_mode[@]+"${ratchet_mode[@]}"}
  accounting_status=$?
  set -e
  if [ "$accounting_status" -eq 0 ]; then
    return 0
  fi
  if [ "$batch_status" -ne 0 ]; then
    return "$batch_status"
  fi
  return "$accounting_status"
}

run_unit_tests() {
  local execution_attempt="$1"
  local logical_shard combined_status=0
  for logical_shard in "${LOGICAL_SHARDS[@]}"; do
    run_unit_test_batch "$logical_shard" "$execution_attempt" || {
      local batch_status=$?
      if [ "$combined_status" -eq 0 ]; then
        combined_status="$batch_status"
      fi
    }
  done
  return "$combined_status"
}

TEST_OUTPUT="$RUNNER_TEMP/cmux-unit-output-shard-${PHYSICAL_SHARD}.txt"
collect_unit_test_output() {
  : >"$TEST_OUTPUT"
  local output_path
  shopt -s nullglob
  # The unquoted expansion is the glob this line exists to perform.
  # shellcheck disable=SC2206
  local output_paths=("$RUNNER_TEMP"/cmux-unit-output-*-of-${LOGICAL_SHARD_TOTAL}-run-*.txt)
  shopt -u nullglob
  # Bash with `set -u` treats an empty array expansion as an unset variable.
  # A changed-suites run can legitimately produce no shared-batch output.
  if [[ -n ${output_paths[0]+x} ]]; then
    for output_path in "${output_paths[@]}"; do
      {
        echo "===== $(basename "$output_path") ====="
        cat "$output_path"
        echo
      } >>"$TEST_OUTPUT"
    done
  fi
}

set +e
run_unit_tests 1
EXIT_CODE=$?
set -e
collect_unit_test_output

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "App-host unit-test batch failed with status ${EXIT_CODE}"
  exit "$EXIT_CODE"
fi
