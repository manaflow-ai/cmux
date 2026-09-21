#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
state="${CMUX_WORKLOAD_STATE_ROOT:?CMUX_WORKLOAD_STATE_ROOT is required}"
xctestrun="${CMUX_APP_HOST_XCTESTRUN:?CMUX_APP_HOST_XCTESTRUN is required}"
physical_shard="${CMUX_WORKLOAD_PARAM_SHARD:?CMUX_WORKLOAD_PARAM_SHARD is required}"
physical_total=6
logical_total=12

stage() {
  python3 "$root/scripts/ci/cmux_workload_profile.py" stage "$1" "$2"
}

case "$physical_shard" in
  1|2|3|4|5|6) ;;
  *) echo "invalid app-host physical shard: $physical_shard" >&2; exit 64 ;;
esac

derived="$(dirname "$(dirname "$(dirname "$xctestrun")")")"
cd "$root"
mkdir -p "$state"

export CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1
export CMUX_DERIVED_DATA_PATH="$derived"
# These controls are part of this workload generation. Ignore inherited
# overrides so two executions with the same semantic key run the same shard.
export CMUX_UNIT_TEST_TIMEOUT_SECONDS=1800
export CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=1200
export CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS=45
export CMUX_APP_HOST_RESERVED_WALL_SECONDS="1=474 4=235 5=245 6=284"
export CMUX_UNIT_TEST_CASE_TIMEOUT_SECONDS=300
export SWIFT_BACKTRACE="interactive=no,timeout=0s,symbolicate=off,color=no"

run_batch() {
  local logical_shard="$1"
  local shard_args="$state/shard-${logical_shard}-of-${logical_total}.args"
  local batch_output="$state/shard-${logical_shard}-of-${logical_total}.log"
  local reserve_args=()
  local reservation
  for reservation in ${CMUX_APP_HOST_RESERVED_WALL_SECONDS:-}; do
    reserve_args+=(--reserve "$reservation")
  done

  local plan_status=0
  python3 scripts/ci/cmux_unit_test_shard.py     --shard-index "$logical_shard"     --shard-total "$logical_total"     --physical-shard-total "$physical_total"     ${reserve_args[@]+"${reserve_args[@]}"}     --output "$shard_args" || plan_status=$?
  if [[ "$plan_status" -ne 0 ]]; then
    return "$plan_status"
  fi

  local only_testing_args=()
  while IFS= read -r arg; do
    [[ -n "$arg" ]] && only_testing_args+=("$arg")
  done < "$shard_args"
  if [[ "${#only_testing_args[@]}" -eq 0 ]]; then
    echo "shard planner produced no test arguments" >&2
    return 64
  fi

  set +e
  scripts/ci/run-in-console-session.sh     scripts/ci/run-app-host-xcodebuild.sh     -xctestrun "$xctestrun"     -destination "platform=macOS"     "${only_testing_args[@]}"     -test-timeouts-enabled YES     -default-test-execution-time-allowance "$CMUX_UNIT_TEST_CASE_TIMEOUT_SECONDS"     -maximum-test-execution-time-allowance "$CMUX_UNIT_TEST_CASE_TIMEOUT_SECONDS"     CMUX_SKIP_ZIG_BUILD=1     test-without-building 2>&1 | tee "$batch_output"
  local status="${PIPESTATUS[0]}"
  set -e

  if [[ "$status" -eq 65 ]]     && python3 scripts/ci/classify-app-host-test-output.py "$batch_output"; then
    return 0
  fi
  return "$status"
}

stage start test
combined=0
for logical_shard in "$physical_shard" "$((physical_shard + physical_total))"; do
  run_batch "$logical_shard" || combined=$?
done
stage end test
exit "$combined"
