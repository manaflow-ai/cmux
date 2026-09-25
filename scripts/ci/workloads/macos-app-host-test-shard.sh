#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
state="${CMUX_WORKLOAD_STATE_ROOT:?CMUX_WORKLOAD_STATE_ROOT is required}"
xctestrun="${CMUX_APP_HOST_XCTESTRUN:?CMUX_APP_HOST_XCTESTRUN is required}"
physical_shard="${CMUX_WORKLOAD_PARAM_SHARD:?CMUX_WORKLOAD_PARAM_SHARD is required}"
attempt_id="${CMUX_WORKLOAD_ATTEMPT_ID:?CMUX_WORKLOAD_ATTEMPT_ID is required}"
physical_total=6
logical_total=12
profile_env="$state/profile.env"

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
export PATH="$HOME/.cargo/bin:$PATH"
export GITHUB_REPOSITORY_ID=1
export GITHUB_RUN_ID="$attempt_id"
export GITHUB_RUN_ATTEMPT=1
export CMUX_APP_HOST_SHARD="$physical_shard"
export CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1
export CMUX_DERIVED_DATA_PATH="$derived"
export CMUX_UNIT_TEST_TIMEOUT_SECONDS=1800
export CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=1200
export CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS=45
export CMUX_APP_HOST_RESERVED_WALL_SECONDS="1=474 4=235 5=320 6=284"
export CMUX_UNIT_TEST_CASE_TIMEOUT_SECONDS=300
export SWIFT_BACKTRACE="interactive=no,timeout=0s,symbolicate=off,color=no"

prepared=0
cleanup_profile_app_host() {
  status=$?
  trap - EXIT
  if [[ "$prepared" -eq 1 ]]; then
    set +e
    scripts/ci/run-in-console-session.sh scripts/ci/cleanup-app-host-home.sh
    cleanup_status=$?
    set -e
    if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
      status="$cleanup_status"
    fi
  fi
  exit "$status"
}
trap cleanup_profile_app_host EXIT

stage start setup
: > "$profile_env"
GITHUB_ENV="$profile_env" CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=26 \
  ./scripts/select-ci-xcode.sh
while IFS= read -r assignment; do
  case "$assignment" in
    DEVELOPER_DIR=*) export "$assignment" ;;
  esac
done < "$profile_env"

GITHUB_ENV="$profile_env" scripts/ci/prepare-app-host-home.sh
while IFS= read -r assignment; do
  case "$assignment" in
    DEVELOPER_DIR=*|CMUX_APP_HOST_*=*) export "$assignment" ;;
  esac
done < "$profile_env"
prepared=1
stage end setup

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
  python3 scripts/ci/cmux_unit_test_shard.py \
    --shard-index "$logical_shard" \
    --shard-total "$logical_total" \
    --physical-shard-total "$physical_total" \
    ${reserve_args[@]+"${reserve_args[@]}"} \
    --output "$shard_args" || plan_status=$?
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
  scripts/ci/run-in-console-session.sh \
    scripts/ci/run-app-host-xcodebuild.sh \
    -xctestrun "$xctestrun" \
    -destination "platform=macOS" \
    "${only_testing_args[@]}" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance "$CMUX_UNIT_TEST_CASE_TIMEOUT_SECONDS" \
    -maximum-test-execution-time-allowance "$CMUX_UNIT_TEST_CASE_TIMEOUT_SECONDS" \
    CMUX_SKIP_ZIG_BUILD=1 \
    test-without-building 2>&1 | tee "$batch_output"
  local status="${PIPESTATUS[0]}"
  set -e

  if [[ "$status" -eq 65 ]] \
    && python3 scripts/ci/classify-app-host-test-output.py "$batch_output"; then
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
