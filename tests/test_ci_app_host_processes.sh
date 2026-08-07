#!/usr/bin/env bash
set -euo pipefail

if [ "$(basename "$0")" = "fake-lsof" ]; then
  if [ "${CMUX_FAKE_LSOF_WARNING:-0}" = "1" ]; then
    printf 'lsof: simulated advisory diagnostic\n' >&2
  fi
  pid_filter=""
  fd_filter=""
  path_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -p)
        pid_filter="$2"
        shift 2
        ;;
      -d)
        fd_filter="$2"
        shift 2
        ;;
      --)
        shift
        path_filter="${1:-}"
        [ "$#" -eq 0 ] || shift
        ;;
      *) shift ;;
    esac
  done

  found=0
  while IFS='|' read -r state_pid state_executable; do
    [ -n "$state_pid" ] || continue
    if [ -n "$pid_filter" ] && [ "$pid_filter" != "$state_pid" ]; then
      continue
    fi
    if ! /bin/kill -0 "$state_pid" 2>/dev/null; then
      continue
    fi
    if [ -n "$path_filter" ]; then
      if [ "${CMUX_FAKE_LSOF_MISSING_RECEIPT_PID:-}" = "$state_pid" ] \
        || [ "$fd_filter" != "9" ]; then
        continue
      fi
      printf 'p%s\n%s\n%s\nn%s\n' \
        "$state_pid" \
        "${CMUX_FAKE_LSOF_RECEIPT_FD_FIELD:-f9}" \
        "${CMUX_FAKE_LSOF_RECEIPT_ACCESS_FIELD:-aw}" \
        "$path_filter"
    else
      printf 'p%s\nftxt\nn%s\nftxt\nn/usr/lib/dyld\n' \
        "$state_pid" "$state_executable"
    fi
    found=1
  done < "$CMUX_FAKE_LSOF_STATE"
  if [ "$found" -eq 1 ] || [ -z "$pid_filter" ]; then
    exit 0
  fi
  if [ "${CMUX_FAKE_LSOF_DEAD_PID_DIAGNOSTIC:-0}" = "1" ]; then
    printf 'lsof: status error on %s: No such process\n' "$pid_filter" >&2
  fi
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
PIDS=""
SCOPE_CLEANUP_PATHS=""
cleanup() {
  local pid
  for pid in $PIDS; do
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done
  /bin/sleep 0.2
  for pid in $PIDS; do
    if /bin/kill -0 "$pid" 2>/dev/null; then
      /bin/kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  for pid in $PIDS; do
    wait "$pid" 2>/dev/null || true
  done
  local scope_path
  for scope_path in $SCOPE_CLEANUP_PATHS; do
    rm -rf -- "$scope_path"
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

FAKE_LSOF="$TMP_DIR/fake-lsof"
ln -s "$ROOT_DIR/tests/test_ci_app_host_processes.sh" "$FAKE_LSOF"
export CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER=1
export CMUX_APP_HOST_LSOF="$FAKE_LSOF"
export CMUX_FAKE_LSOF_STATE="$TMP_DIR/lsof-state"
export GITHUB_REPOSITORY_ID=1234567
: > "$CMUX_FAKE_LSOF_STATE"

# shellcheck source=scripts/ci/app-host-processes.sh
PROCESS_HELPER="$ROOT_DIR/scripts/ci/app-host-processes.sh"
if [ ! -f "$PROCESS_HELPER" ]; then
  echo "FAIL: app-host process receipt helper is missing" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$PROCESS_HELPER"
# shellcheck source=scripts/ci/app-host-isolation.sh
source "$ROOT_DIR/scripts/ci/app-host-isolation.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Recovery is inclusive at the grace boundary and excludes current, newest,
# future-dated, young, and pre-v3 scopes.
cmux_classify_app_host_scope_recovery_eligibility \
  111111111111 222222222222 3 100 300 200 100
[ "$CMUX_APP_HOST_SCOPE_RECOVERY_ELIGIBLE" -eq 1 ] \
  || fail "exact app-host recovery grace boundary was not eligible"
cmux_classify_app_host_scope_recovery_eligibility \
  111111111111 222222222222 3 199 300 200 0
[ "$CMUX_APP_HOST_SCOPE_RECOVERY_ELIGIBLE" -eq 1 ] \
  || fail "authenticated prior owner was not immediately eligible"
for eligibility_case in \
  "222222222222 222222222222 3 100 300 200 100" \
  "111111111111 222222222222 3 300 300 400 100" \
  "111111111111 222222222222 3 301 300 300 100" \
  "111111111111 222222222222 3 101 300 200 100" \
  "111111111111 222222222222 2 100 300 200 100" \
  "111111111111 222222222222 1 100 300 200 100"
do
  # shellcheck disable=SC2086
  cmux_classify_app_host_scope_recovery_eligibility $eligibility_case
  [ "$CMUX_APP_HOST_SCOPE_RECOVERY_ELIGIBLE" -eq 0 ] \
    || fail "ineligible app-host recovery scope was admitted"
done

# Shared /tmp debris cannot make a genuine old scope lose newest protection.
newest_scope_root="$TMP_DIR/newest-scope-root"
mkdir -p "$newest_scope_root"
cmux_compute_app_host_key 940001 1 1 "$GITHUB_REPOSITORY_ID"
trusted_newest_key="$CMUX_COMPUTED_APP_HOST_KEY"
trusted_newest_home="$newest_scope_root/cmux-ah-$trusted_newest_key"
trusted_newest_receipts="$newest_scope_root/cmux-ah-$trusted_newest_key-receipts"
cmux_compute_app_host_cleanup_confirmation \
  940001 1 1 "$trusted_newest_home" "$trusted_newest_receipts" \
  "$GITHUB_REPOSITORY_ID"
trusted_newest_confirmation="$newest_scope_root/cmux-ah-$trusted_newest_key.confirm"
printf 'version=3\nrepository_id=%s\nrun_id=940001\nrun_attempt=1\nshard=1\nkey=%s\nhome=%s\nreceipt_dir=%s\nconfirmation=%s\n' \
  "$GITHUB_REPOSITORY_ID" "$trusted_newest_key" \
  "$trusted_newest_home" "$trusted_newest_receipts" \
  "$CMUX_COMPUTED_APP_HOST_CLEANUP_CONFIRMATION" \
  > "$trusted_newest_confirmation"
chmod 600 "$trusted_newest_confirmation"
touch -t 202001010000 "$trusted_newest_confirmation"
cmux_app_host_scope_mtime "$trusted_newest_confirmation"
trusted_newest_mtime="$CMUX_APP_HOST_SCOPE_MTIME"

cmux_compute_app_host_key 940002 1 1 "$GITHUB_REPOSITORY_ID"
malformed_newest_confirmation="$newest_scope_root/cmux-ah-$CMUX_COMPUTED_APP_HOST_KEY.confirm"
printf 'version=3\nmalformed\n' > "$malformed_newest_confirmation"
chmod 600 "$malformed_newest_confirmation"
touch -t 203001010000 "$malformed_newest_confirmation"

cmux_compute_app_host_key 940003 1 1 "$GITHUB_REPOSITORY_ID"
nonprivate_newest_key="$CMUX_COMPUTED_APP_HOST_KEY"
nonprivate_newest_home="$newest_scope_root/cmux-ah-$nonprivate_newest_key"
nonprivate_newest_receipts="$newest_scope_root/cmux-ah-$nonprivate_newest_key-receipts"
cmux_compute_app_host_cleanup_confirmation \
  940003 1 1 "$nonprivate_newest_home" "$nonprivate_newest_receipts" \
  "$GITHUB_REPOSITORY_ID"
nonprivate_newest_confirmation="$newest_scope_root/cmux-ah-$nonprivate_newest_key.confirm"
printf 'version=3\nrepository_id=%s\nrun_id=940003\nrun_attempt=1\nshard=1\nkey=%s\nhome=%s\nreceipt_dir=%s\nconfirmation=%s\n' \
  "$GITHUB_REPOSITORY_ID" "$nonprivate_newest_key" \
  "$nonprivate_newest_home" \
  "$nonprivate_newest_receipts" "$CMUX_COMPUTED_APP_HOST_CLEANUP_CONFIRMATION" \
  > "$nonprivate_newest_confirmation"
chmod 644 "$nonprivate_newest_confirmation"
touch -t 204001010000 "$nonprivate_newest_confirmation"

cmux_newest_app_host_confirmation_mtime "$newest_scope_root"
[ "$CMUX_NEWEST_APP_HOST_CONFIRMATION_MTIME" = "$trusted_newest_mtime" ] \
  || fail "untrusted confirmation changed newest-scope protection"

untrack_pid() {
  local target_pid="$1"
  local tracked_pid updated_pids
  updated_pids=""
  for tracked_pid in $PIDS; do
    if [ "$tracked_pid" != "$target_pid" ]; then
      updated_pids="${updated_pids:+$updated_pids }$tracked_pid"
    fi
  done
  PIDS="$updated_pids"
}

PIDS="123 1234 9123"
untrack_pid 123
[ "$PIDS" = "1234 9123" ] \
  || fail "PID tracking removed numeric substrings instead of one exact token"
PIDS=""

spawn_process() {
  /bin/bash -c 'trap "exit 0" TERM; while :; do /bin/sleep 0.1; done' &
  CMUX_TEST_SPAWNED_PID=$!
  PIDS="${PIDS:+$PIDS }$CMUX_TEST_SPAWNED_PID"
}

spawn_forged_argv_process() {
  /bin/bash -c 'exec -a "$1" /bin/bash -c "$2" "$1"' \
    bash "$1" 'trap "exit 0" TERM; while :; do /bin/sleep 0.1; done' &
  CMUX_TEST_SPAWNED_PID=$!
  PIDS="${PIDS:+$PIDS }$CMUX_TEST_SPAWNED_PID"
}

write_receipt() {
  local receipt_dir="$1"
  local key="$2"
  local pid="$3"
  local executable="$4"
  printf 'version=2\nkey=%s\npid=%s\nexecutable=%s\nreceipt_fd=9\n' \
    "$key" "$pid" "$executable" \
    > "$receipt_dir/app-host-$pid.receipt"
}

write_changed_confirmation_record() {
  local confirmation_file="$1"
  local record changed_record
  record="$(cat "$confirmation_file")"
  case "$record" in
    *0) changed_record="${record%?}1" ;;
    *) changed_record="${record%?}0" ;;
  esac
  [ "$changed_record" != "$record" ] \
    || fail "confirmation mutation did not change the record"
  printf '%s\n' "$changed_record" > "$confirmation_file"
}

make_scope() {
  local name="$1"
  TEST_DERIVED_DATA="$TMP_DIR/$name/Derived Data"
  TEST_RECEIPT_DIR="$TMP_DIR/$name/receipts"
  TEST_EXECUTABLE="$TEST_DERIVED_DATA/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
  mkdir -p "$(dirname "$TEST_EXECUTABLE")" "$TEST_RECEIPT_DIR"
  : > "$TEST_EXECUTABLE"
}

KEY=0123456789ab

make_scope empty-current-scope
: > "$CMUX_FAKE_LSOF_STATE"
empty_verified="$(cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA")" \
  || fail "an empty current scope was treated as malformed"
[ -z "$empty_verified" ] || fail "an empty current scope returned a process"

make_scope dead-pid-diagnostic
spawn_process
dead_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n' "$dead_pid" "$TEST_EXECUTABLE" > "$CMUX_FAKE_LSOF_STATE"
write_receipt "$TEST_RECEIPT_DIR" "$KEY" "$dead_pid" "$TEST_EXECUTABLE"
/bin/kill -TERM "$dead_pid"
wait "$dead_pid" 2>/dev/null || true
untrack_pid "$dead_pid"
export CMUX_FAKE_LSOF_DEAD_PID_DIAGNOSTIC=1
dead_verified="$(cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA")" \
  || fail "a dead-PID lsof diagnostic was treated as an inspection failure"
unset CMUX_FAKE_LSOF_DEAD_PID_DIAGNOSTIC
[ -z "$dead_verified" ] || fail "a dead PID was returned as a live process"

make_scope matching
spawn_process
matching_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n' "$matching_pid" "$TEST_EXECUTABLE" > "$CMUX_FAKE_LSOF_STATE"
write_receipt "$TEST_RECEIPT_DIR" "$KEY" "$matching_pid" "$TEST_EXECUTABLE"
export CMUX_FAKE_LSOF_WARNING=1
verified="$(cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  2> "$TMP_DIR/matching-lsof-warning.err")" || fail "matching receipt was rejected"
[ "$verified" = "$matching_pid" ] || fail "matching receipt did not return its PID"
export CMUX_FAKE_LSOF_RECEIPT_FD_FIELD=f9w
if cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  > "$TMP_DIR/human-fd-suffix.out" 2> "$TMP_DIR/human-fd-suffix.err"; then
  fail "human-readable lsof descriptor suffix was accepted as machine output"
fi
unset CMUX_FAKE_LSOF_RECEIPT_FD_FIELD
/bin/kill -0 "$matching_pid" 2>/dev/null \
  || fail "malformed lsof descriptor verification signaled the live PID"
cmux_terminate_verified_app_hosts \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  2>> "$TMP_DIR/matching-lsof-warning.err" || fail "matching receipt did not terminate"
grep -Fq "lsof: simulated advisory diagnostic" \
  "$TMP_DIR/matching-lsof-warning.err" \
  || fail "lsof advisory diagnostics did not remain on stderr"
unset CMUX_FAKE_LSOF_WARNING
wait "$matching_pid" 2>/dev/null || true
untrack_pid "$matching_pid"

make_scope unbound-receipt
spawn_process
unbound_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n' "$unbound_pid" "$TEST_EXECUTABLE" > "$CMUX_FAKE_LSOF_STATE"
write_receipt "$TEST_RECEIPT_DIR" "$KEY" "$unbound_pid" "$TEST_EXECUTABLE"
export CMUX_FAKE_LSOF_MISSING_RECEIPT_PID="$unbound_pid"
if cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  > "$TMP_DIR/unbound.out" 2> "$TMP_DIR/unbound.err"; then
  fail "a live PID without the receipt file open was authenticated"
fi
unset CMUX_FAKE_LSOF_MISSING_RECEIPT_PID
/bin/kill -0 "$unbound_pid" 2>/dev/null \
  || fail "unbound receipt verification signaled the live PID"

make_scope deleted-vnode
spawn_process
deleted_vnode_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s (deleted)\n' \
  "$deleted_vnode_pid" "$TEST_EXECUTABLE" > "$CMUX_FAKE_LSOF_STATE"
write_receipt \
  "$TEST_RECEIPT_DIR" "$KEY" "$deleted_vnode_pid" "$TEST_EXECUTABLE"
deleted_verified="$(cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA")" \
  || fail "lsof's deleted-vnode suffix broke receipt verification"
[ "$deleted_verified" = "$deleted_vnode_pid" ] \
  || fail "deleted-vnode verification did not return its PID"
cmux_terminate_verified_app_hosts \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  || fail "deleted-vnode receipt did not terminate"
wait "$deleted_vnode_pid" 2>/dev/null || true
untrack_pid "$deleted_vnode_pid"

make_scope forged-argv
spawn_forged_argv_process "$TEST_EXECUTABLE"
forged_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n' "$forged_pid" /bin/sleep > "$CMUX_FAKE_LSOF_STATE"
write_receipt "$TEST_RECEIPT_DIR" "$KEY" "$forged_pid" "$TEST_EXECUTABLE"
if cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  > "$TMP_DIR/forged.out" 2> "$TMP_DIR/forged.err"; then
  fail "a forged process title authorized an app-host PID"
fi
/bin/kill -0 "$forged_pid" 2>/dev/null || fail "forged process was signaled"

make_scope wrong-key
spawn_process
wrong_key_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n' "$wrong_key_pid" "$TEST_EXECUTABLE" > "$CMUX_FAKE_LSOF_STATE"
write_receipt "$TEST_RECEIPT_DIR" fedcba987654 "$wrong_key_pid" "$TEST_EXECUTABLE"
if cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  > "$TMP_DIR/wrong-key.out" 2> "$TMP_DIR/wrong-key.err"; then
  fail "a receipt from another run key was accepted"
fi

make_scope wrong-path
spawn_process
wrong_path_pid="$CMUX_TEST_SPAWNED_PID"
outside_executable="$TMP_DIR/outside/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
mkdir -p "$(dirname "$outside_executable")"
: > "$outside_executable"
printf '%s|%s\n' "$wrong_path_pid" "$outside_executable" > "$CMUX_FAKE_LSOF_STATE"
write_receipt "$TEST_RECEIPT_DIR" "$KEY" "$wrong_path_pid" "$outside_executable"
if cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  > "$TMP_DIR/wrong-path.out" 2> "$TMP_DIR/wrong-path.err"; then
  fail "an executable outside the supplied DerivedData path was accepted"
fi

make_scope wrong-lsof
spawn_process
wrong_lsof_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n' "$wrong_lsof_pid" /bin/sleep > "$CMUX_FAKE_LSOF_STATE"
write_receipt "$TEST_RECEIPT_DIR" "$KEY" "$wrong_lsof_pid" "$TEST_EXECUTABLE"
if cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  > "$TMP_DIR/wrong-lsof.out" 2> "$TMP_DIR/wrong-lsof.err"; then
  fail "a receipt whose PID had another executable vnode was accepted"
fi

make_scope missing-receipt
spawn_process
unreceipted_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n' "$unreceipted_pid" "$TEST_EXECUTABLE" > "$CMUX_FAKE_LSOF_STATE"
if cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" \
  > "$TMP_DIR/unreceipted.out" 2> "$TMP_DIR/unreceipted.err"; then
  fail "a live target without a receipt was accepted"
fi
grep -Fq "has no verified receipt" "$TMP_DIR/unreceipted.err" \
  || fail "missing receipt failure did not identify the live target"

empty_runner_root="$TMP_DIR/empty-runner-work"
empty_receipt_root="$TMP_DIR/empty-receipts"
mkdir -p "$empty_runner_root" "$empty_receipt_root"
: > "$CMUX_FAKE_LSOF_STATE"
export CMUX_FAKE_LSOF_WARNING=1
cmux_reclaim_abandoned_app_host_scopes \
  "$empty_runner_root" "$empty_receipt_root" fedcba987654 \
  2000000000 86400 fedcba987654 \
  2> "$TMP_DIR/empty-runner-lsof-warning.err" \
  || fail "stale receipt cleanup was unsafe when no receipts existed"
grep -Fq "lsof: simulated advisory diagnostic" \
  "$TMP_DIR/empty-runner-lsof-warning.err" \
  || fail "runner lsof diagnostics did not remain on stderr"
unset CMUX_FAKE_LSOF_WARNING

preflight_runner_root="$TMP_DIR/preflight-runner-work"
preflight_receipt_root="$TMP_DIR/preflight-receipts"
preflight_key=13579bdf0246
preflight_receipt_dir="$preflight_receipt_root/cmux-ah-$preflight_key-receipts"
preflight_receipted_executable="$preflight_runner_root/old-job/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
preflight_unreceipted_executable="$preflight_runner_root/current-job/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
mkdir -p \
  "$preflight_runner_root" \
  "$preflight_receipt_dir" \
  "$(dirname "$preflight_receipted_executable")" \
  "$(dirname "$preflight_unreceipted_executable")"
: > "$preflight_receipted_executable"
: > "$preflight_unreceipted_executable"
spawn_process
preflight_receipted_pid="$CMUX_TEST_SPAWNED_PID"
spawn_process
preflight_unreceipted_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n%s|%s\n' \
  "$preflight_receipted_pid" "$preflight_receipted_executable" \
  "$preflight_unreceipted_pid" "$preflight_unreceipted_executable" \
  > "$CMUX_FAKE_LSOF_STATE"
write_receipt \
  "$preflight_receipt_dir" "$preflight_key" \
  "$preflight_receipted_pid" "$preflight_receipted_executable"
if cmux_recover_owned_app_host_attempt \
  "$preflight_receipt_dir" "$preflight_key" \
  "${preflight_receipted_executable%%/Build/Products/*}" \
  "$preflight_runner_root" "$preflight_receipt_root" \
  > "$TMP_DIR/stale-unreceipted.out" 2> "$TMP_DIR/stale-unreceipted.err"; then
  fail "stale cleanup accepted a live unreceipted runner target"
fi
grep -Fq "foreign app-host" "$TMP_DIR/stale-unreceipted.err" || {
  cat "$TMP_DIR/stale-unreceipted.err" >&2
  fail "owned recovery did not identify the foreign runner target"
}
/bin/kill -0 "$preflight_receipted_pid" 2>/dev/null \
  || fail "stale cleanup signaled a verified target before completing preflight"
/bin/kill -0 "$preflight_unreceipted_pid" 2>/dev/null \
  || fail "stale cleanup signaled an unreceipted target"

deleted_runner_root="$TMP_DIR/deleted-runner-work"
deleted_receipt_root="$TMP_DIR/deleted-receipts"
deleted_key=2468ace01357
deleted_receipt_dir="$deleted_receipt_root/cmux-ah-$deleted_key-receipts"
deleted_derived_data="$deleted_runner_root/old-job/deleted-derived-data"
deleted_executable="$deleted_derived_data/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
mkdir -p "$deleted_runner_root" "$deleted_receipt_dir"
spawn_process
deleted_stale_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s (deleted)\n' \
  "$deleted_stale_pid" "$deleted_executable" > "$CMUX_FAKE_LSOF_STATE"
write_receipt \
  "$deleted_receipt_dir" "$deleted_key" \
  "$deleted_stale_pid" "$deleted_executable"
cmux_terminate_one_verified_app_host \
  "$deleted_receipt_dir/app-host-$deleted_stale_pid.receipt" \
  "$deleted_key" "$deleted_derived_data" "$deleted_runner_root" \
  || fail "deleted stale product was not verified and terminated"
wait "$deleted_stale_pid" 2>/dev/null || true
untrack_pid "$deleted_stale_pid"
[ ! -e "$deleted_derived_data" ] \
  || fail "deleted stale verification recreated the missing DerivedData root"

make_durable_scope() {
  local scope_name="$1"
  local run_id="$2"
  local run_attempt="$3"
  local shard="$4"
  local derived_data_path="$5"
  export GITHUB_RUN_ID="$run_id"
  export GITHUB_RUN_ATTEMPT="$run_attempt"
  export CMUX_APP_HOST_SHARD="$shard"
  export RUNNER_TEMP="$stale_runner_root/$scope_name-runner-temp"
  mkdir -p "$RUNNER_TEMP"
  cmux_resolve_app_host_identity
  DURABLE_SCOPE_KEY="$CMUX_RESOLVED_APP_HOST_KEY"
  DURABLE_SCOPE_HOME="$CMUX_RESOLVED_APP_HOST_HOME"
  DURABLE_SCOPE_RECEIPT_DIR="$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR"
  DURABLE_SCOPE_CONFIRMATION_FILE="$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE"
  DURABLE_SCOPE_CONFIRMATION="$CMUX_RESOLVED_APP_HOST_CLEANUP_CONFIRMATION"
  DURABLE_SCOPE_EXECUTABLE="$derived_data_path/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
  mkdir -p \
    "$DURABLE_SCOPE_HOME" \
    "$DURABLE_SCOPE_RECEIPT_DIR" \
    "$(dirname "$DURABLE_SCOPE_EXECUTABLE")"
  : > "$DURABLE_SCOPE_EXECUTABLE"
  printf 'version=3\nrepository_id=%s\nrun_id=%s\nrun_attempt=%s\nshard=%s\nkey=%s\nhome=%s\nreceipt_dir=%s\nconfirmation=%s\n' \
    "$GITHUB_REPOSITORY_ID" "$run_id" "$run_attempt" "$shard" \
    "$DURABLE_SCOPE_KEY" "$DURABLE_SCOPE_HOME" \
    "$DURABLE_SCOPE_RECEIPT_DIR" "$DURABLE_SCOPE_CONFIRMATION" \
    > "$DURABLE_SCOPE_CONFIRMATION_FILE"
  chmod 700 "$DURABLE_SCOPE_HOME" "$DURABLE_SCOPE_RECEIPT_DIR"
  chmod 600 "$DURABLE_SCOPE_CONFIRMATION_FILE"
  SCOPE_CLEANUP_PATHS="${SCOPE_CLEANUP_PATHS:+$SCOPE_CLEANUP_PATHS }$DURABLE_SCOPE_HOME $DURABLE_SCOPE_RECEIPT_DIR $DURABLE_SCOPE_CONFIRMATION_FILE"
}

stale_runner_root="$TMP_DIR/stale-runner-work"
system_temp_root="$(cd /tmp && pwd -P)"
mkdir -p "$stale_runner_root"

current_repository_id="$GITHUB_REPOSITORY_ID"
GITHUB_REPOSITORY_ID=7654321
export GITHUB_REPOSITORY_ID
make_durable_scope old "930000$$" 2 1 \
  "$stale_runner_root/old-job/derived-data"
old_key="$DURABLE_SCOPE_KEY"
old_home="$DURABLE_SCOPE_HOME"
old_receipt_dir="$DURABLE_SCOPE_RECEIPT_DIR"
old_confirmation_file="$DURABLE_SCOPE_CONFIRMATION_FILE"
old_executable="$DURABLE_SCOPE_EXECUTABLE"
GITHUB_REPOSITORY_ID="$current_repository_id"
export GITHUB_REPOSITORY_ID
spawn_process
old_pid_one="$CMUX_TEST_SPAWNED_PID"
spawn_process
old_pid_two="$CMUX_TEST_SPAWNED_PID"
write_receipt "$old_receipt_dir" "$old_key" "$old_pid_one" "$old_executable"
write_receipt "$old_receipt_dir" "$old_key" "$old_pid_two" "$old_executable"

make_durable_scope current "930001$$" 2 1 \
  "$stale_runner_root/current-job/derived-data"
current_key="$DURABLE_SCOPE_KEY"
current_home="$DURABLE_SCOPE_HOME"
current_receipt_dir="$DURABLE_SCOPE_RECEIPT_DIR"
current_confirmation_file="$DURABLE_SCOPE_CONFIRMATION_FILE"
current_executable="$DURABLE_SCOPE_EXECUTABLE"
spawn_process
current_pid="$CMUX_TEST_SPAWNED_PID"
spawn_process
current_pid_two="$CMUX_TEST_SPAWNED_PID"
write_receipt \
  "$current_receipt_dir" "$current_key" "$current_pid" "$current_executable"
write_receipt \
  "$current_receipt_dir" "$current_key" "$current_pid_two" "$current_executable"

make_durable_scope waiting "930002$$" 2 1 \
  "$stale_runner_root/waiting-job/derived-data"
waiting_home="$DURABLE_SCOPE_HOME"
waiting_receipt_dir="$DURABLE_SCOPE_RECEIPT_DIR"
waiting_confirmation_file="$DURABLE_SCOPE_CONFIRMATION_FILE"

printf '%s|%s\n%s|%s\n%s|%s\n%s|%s\n' \
  "$old_pid_one" "$old_executable" \
  "$old_pid_two" "$old_executable" \
  "$current_pid" "$current_executable" \
  "$current_pid_two" "$current_executable" \
  > "$CMUX_FAKE_LSOF_STATE"
touch -t 204001010000 "$old_confirmation_file"
if cmux_recover_owned_app_host_attempt \
  "$current_receipt_dir" "$current_key" \
  "${current_executable%%/Build/Products/*}" \
  "$stale_runner_root" "$system_temp_root" \
  > "$TMP_DIR/foreign-owner.out" 2> "$TMP_DIR/foreign-owner.err"; then
  fail "current retry recovery accepted a live foreign app-host owner"
fi
grep -Fq "foreign app-host" "$TMP_DIR/foreign-owner.err" \
  || fail "current retry recovery did not identify the foreign owner"
for preserved_pid in \
  "$old_pid_one" "$old_pid_two" "$current_pid" "$current_pid_two"
do
  /bin/kill -0 "$preserved_pid" 2>/dev/null \
    || fail "ownership preflight signaled a process before rejecting recovery"
done

# The future-dated newest authority above is never eligible for a signal. Once
# its processes are gone, the current retry may terminate only its own hosts.
for foreign_pid in "$old_pid_one" "$old_pid_two"; do
  /bin/kill -TERM "$foreign_pid"
  wait "$foreign_pid" 2>/dev/null || true
  untrack_pid "$foreign_pid"
done
cmux_recover_owned_app_host_attempt \
  "$current_receipt_dir" "$current_key" \
  "${current_executable%%/Build/Products/*}" \
  "$stale_runner_root" "$system_temp_root" \
  || fail "current retry did not terminate its owned app host"
for terminated_pid in "$current_pid" "$current_pid_two"; do
  wait "$terminated_pid" 2>/dev/null || true
  untrack_pid "$terminated_pid"
done
for preserved_path in \
  "$old_home" "$old_receipt_dir" "$old_confirmation_file" \
  "$current_home" "$current_receipt_dir" "$current_confirmation_file" \
  "$waiting_home" "$waiting_receipt_dir" "$waiting_confirmation_file"
do
  [ -e "$preserved_path" ] \
    || fail "owned retry recovery removed another job or waiting scope"
done

# The canonical machine-lock holder must immediately recover an authenticated
# prior owner. The process-free scope still observes the deletion grace period.
spawn_process
old_orphan_pid_one="$CMUX_TEST_SPAWNED_PID"
spawn_process
old_orphan_pid_two="$CMUX_TEST_SPAWNED_PID"
write_receipt \
  "$old_receipt_dir" "$old_key" "$old_orphan_pid_one" "$old_executable"
write_receipt \
  "$old_receipt_dir" "$old_key" "$old_orphan_pid_two" "$old_executable"
touch "$old_confirmation_file"
cmux_app_host_scope_mtime "$old_confirmation_file"
old_orphan_confirmation_mtime="$CMUX_APP_HOST_SCOPE_MTIME"
old_orphan_recovery_now=$((old_orphan_confirmation_mtime + 1))
touch -t 204001010000 \
  "$current_confirmation_file" "$waiting_confirmation_file"
old_derived_data="${old_executable%%/Build/Products/*}"
rm -rf -- "$old_derived_data"
printf '%s|%s (deleted)\n%s|%s (deleted)\n' \
  "$old_orphan_pid_one" "$old_executable" \
  "$old_orphan_pid_two" "$old_executable" \
  > "$CMUX_FAKE_LSOF_STATE"
cmux_recover_owned_app_host_attempt \
  "$current_receipt_dir" "$current_key" \
  "${current_executable%%/Build/Products/*}" \
  "$stale_runner_root" "$system_temp_root" \
  "$old_orphan_recovery_now" 86400 \
  "$old_key" \
  || fail "authenticated old prior-run app hosts were not recovered"
for old_orphan_pid in "$old_orphan_pid_one" "$old_orphan_pid_two"; do
  wait "$old_orphan_pid" 2>/dev/null || true
  untrack_pid "$old_orphan_pid"
done
[ ! -e "$old_derived_data" ] \
  || fail "prior-run recovery recreated deleted DerivedData"
for preserved_path in "$old_home" "$old_receipt_dir" "$old_confirmation_file"; do
  [ -e "$preserved_path" ] \
    || fail "live recovery bypassed process-free scope deletion grace"
done
for preserved_path in \
  "$current_home" "$current_receipt_dir" "$current_confirmation_file" \
  "$waiting_home" "$waiting_receipt_dir" "$waiting_confirmation_file"
do
  [ -e "$preserved_path" ] \
    || fail "prior-run recovery removed a current or waiting scope"
done

old_scope_reclaim_now=$((old_orphan_confirmation_mtime + 86400))
cmux_recover_owned_app_host_attempt \
  "$current_receipt_dir" "$current_key" \
  "${current_executable%%/Build/Products/*}" \
  "$stale_runner_root" "$system_temp_root" \
  "$old_scope_reclaim_now" 86400 "$old_key" \
  || fail "recovered prior-run scope was not reclaimed at the grace boundary"
for removed_path in "$old_home" "$old_receipt_dir" "$old_confirmation_file"; do
  [ ! -e "$removed_path" ] \
    || fail "process-free prior-run scope survived the grace boundary"
done

# A later process-free pass reclaims an authenticated old scope, but keeps the
# current key and every scope newer than the minimum age.
make_durable_scope abandoned "930006$$" 2 1 \
  "$stale_runner_root/abandoned/derived-data"
abandoned_key="$DURABLE_SCOPE_KEY"
abandoned_home="$DURABLE_SCOPE_HOME"
abandoned_receipt_dir="$DURABLE_SCOPE_RECEIPT_DIR"
abandoned_confirmation_file="$DURABLE_SCOPE_CONFIRMATION_FILE"
touch -t 200001010000 "$abandoned_confirmation_file"
: > "$CMUX_FAKE_LSOF_STATE"
cmux_recover_owned_app_host_attempt \
  "$current_receipt_dir" "$current_key" \
  "${current_executable%%/Build/Products/*}" \
  "$stale_runner_root" "$system_temp_root" 2000000000 86400 \
  "$abandoned_key" \
  || fail "process-free abandoned scope reclamation failed"
for removed_path in \
  "$abandoned_home" "$abandoned_receipt_dir" "$abandoned_confirmation_file"
do
  [ ! -e "$removed_path" ] \
    || fail "authenticated old process-free scope was not reclaimed"
done
for preserved_path in \
  "$current_home" "$current_receipt_dir" "$current_confirmation_file" \
  "$waiting_home" "$waiting_receipt_dir" "$waiting_confirmation_file"
do
  [ -e "$preserved_path" ] \
    || fail "age-bounded reclamation removed a current or young scope"
done

make_durable_scope abandoned-partial "930007$$" 2 1 \
  "$stale_runner_root/abandoned-partial/derived-data"
abandoned_partial_key="$DURABLE_SCOPE_KEY"
abandoned_partial_home="$DURABLE_SCOPE_HOME"
abandoned_partial_receipt_dir="$DURABLE_SCOPE_RECEIPT_DIR"
abandoned_partial_confirmation_file="$DURABLE_SCOPE_CONFIRMATION_FILE"
rm -rf -- "$abandoned_partial_home" "$abandoned_partial_receipt_dir"
touch -t 200001010000 "$abandoned_partial_confirmation_file"
cmux_recover_owned_app_host_attempt \
  "$current_receipt_dir" "$current_key" \
  "${current_executable%%/Build/Products/*}" \
  "$stale_runner_root" "$system_temp_root" 2000000000 86400 \
  "$abandoned_partial_key" \
  || fail "confirmation-only abandoned scope reclamation failed"
[ ! -e "$abandoned_partial_confirmation_file" ] \
  || fail "confirmation-only abandoned scope was not reclaimed"

# Validate every candidate before deleting the first one.
make_durable_scope candidate-one "930003$$" 2 1 \
  "$stale_runner_root/candidate-one/derived-data"
candidate_one_key="$DURABLE_SCOPE_KEY"
candidate_one_home="$DURABLE_SCOPE_HOME"
candidate_one_receipt_dir="$DURABLE_SCOPE_RECEIPT_DIR"
candidate_one_confirmation_file="$DURABLE_SCOPE_CONFIRMATION_FILE"
make_durable_scope candidate-two "930004$$" 2 1 \
  "$stale_runner_root/candidate-two/derived-data"
candidate_two_key="$DURABLE_SCOPE_KEY"
candidate_two_home="$DURABLE_SCOPE_HOME"
candidate_two_receipt_dir="$DURABLE_SCOPE_RECEIPT_DIR"
candidate_two_confirmation_file="$DURABLE_SCOPE_CONFIRMATION_FILE"
candidate_two_record="$(cat "$candidate_two_confirmation_file")"
touch -t 200001010000 \
  "$candidate_one_confirmation_file" "$candidate_two_confirmation_file"
write_changed_confirmation_record "$candidate_two_confirmation_file"
touch -t 200001010000 "$candidate_two_confirmation_file"
if cmux_reclaim_abandoned_app_host_scopes \
  "$stale_runner_root" "$system_temp_root" "$current_key" \
  2000000000 86400 \
  "$current_key" "$candidate_one_key" "$candidate_two_key" \
  > "$TMP_DIR/invalid-candidate.out" \
  2> "$TMP_DIR/invalid-candidate.err"; then
  fail "stale recovery accepted an altered confirmation"
fi
for preserved_path in \
  "$candidate_one_home" "$candidate_one_receipt_dir" \
  "$candidate_one_confirmation_file" "$candidate_two_home" \
  "$candidate_two_receipt_dir" "$candidate_two_confirmation_file"
do
  [ -e "$preserved_path" ] \
    || fail "candidate validation partially deleted a stale scope"
done
if ! cmux_recover_owned_app_host_attempt \
  "$current_receipt_dir" "$current_key" \
  "${current_executable%%/Build/Products/*}" \
  "$stale_runner_root" "$system_temp_root" 2000000000 86400 \
  "$candidate_one_key" "$candidate_two_key" \
  > "$TMP_DIR/advisory-reclaim.out" \
  2> "$TMP_DIR/advisory-reclaim.err"; then
  fail "unrelated abandoned-scope debris blocked current-run recovery"
fi
grep -Fq "WARNING: abandoned app-host scope reclamation was skipped" \
  "$TMP_DIR/advisory-reclaim.err" \
  || fail "current-run recovery did not report skipped scope maintenance"
for preserved_path in \
  "$candidate_one_home" "$candidate_one_receipt_dir" \
  "$candidate_one_confirmation_file" "$candidate_two_home" \
  "$candidate_two_receipt_dir" "$candidate_two_confirmation_file"
do
  [ -e "$preserved_path" ] \
    || fail "advisory scope maintenance partially deleted a stale scope"
done
printf '%s\n' "$candidate_two_record" > "$candidate_two_confirmation_file"
chmod 600 "$candidate_two_confirmation_file"
touch -t 200001010000 "$candidate_two_confirmation_file"
cmux_reclaim_abandoned_app_host_scopes \
  "$stale_runner_root" "$system_temp_root" "$current_key" \
  2000000000 86400 \
  "$current_key" "$candidate_one_key" "$candidate_two_key" \
  || fail "valid terminated scope candidates were not removed"

# Pre-v3 records do not carry repository-scoped stale authority.
make_durable_scope legacy "930005$$" 2 1 \
  "$stale_runner_root/legacy/derived-data"
legacy_key="$DURABLE_SCOPE_KEY"
legacy_home="$DURABLE_SCOPE_HOME"
legacy_receipt_dir="$DURABLE_SCOPE_RECEIPT_DIR"
legacy_confirmation_file="$DURABLE_SCOPE_CONFIRMATION_FILE"
legacy_record="$(cat "$legacy_confirmation_file")"
printf 'version=2\nrun_id=%s\nrun_attempt=2\nshard=1\nkey=%s\nhome=%s\nreceipt_dir=%s\nconfirmation=%s\n' \
  "930005$$" "$legacy_key" "$legacy_home" "$legacy_receipt_dir" \
  "$DURABLE_SCOPE_CONFIRMATION" > "$legacy_confirmation_file"
cmux_reclaim_abandoned_app_host_scopes \
  "$stale_runner_root" "$system_temp_root" "$current_key" \
  2000000000 86400 "$current_key" "$legacy_key" \
  > "$TMP_DIR/v2-candidate.out" 2> "$TMP_DIR/v2-candidate.err" \
  || fail "V2 confirmation preservation blocked valid recovery"
[ -d "$legacy_home" ] \
  || fail "stale recovery removed a V2 scope"
printf 'version=1\nkey=%s\nhome=%s\nreceipt_dir=%s\nconfirmation=%s\n' \
  "$legacy_key" "$legacy_home" "$legacy_receipt_dir" \
  "$DURABLE_SCOPE_CONFIRMATION" > "$legacy_confirmation_file"
cmux_reclaim_abandoned_app_host_scopes \
  "$stale_runner_root" "$system_temp_root" "$current_key" \
  2000000000 86400 "$current_key" "$legacy_key" \
  > "$TMP_DIR/legacy-candidate.out" 2> "$TMP_DIR/legacy-candidate.err" \
  || fail "legacy confirmation preservation blocked valid recovery"
[ -d "$legacy_home" ] \
  || fail "stale recovery removed a V1 scope"
printf '%s\n' "$legacy_record" > "$legacy_confirmation_file"
chmod 600 "$legacy_confirmation_file"
touch -t 200001010000 "$legacy_confirmation_file"

# Root symlinks and wrong owner identities fail closed.
outside_scope="$TMP_DIR/outside-stale-scope"
mkdir -p "$outside_scope"
printf 'preserve\n' > "$outside_scope/sentinel"
legacy_home_backup="$TMP_DIR/legacy-home-backup"
mv "$legacy_home" "$legacy_home_backup"
ln -s "$outside_scope" "$legacy_home"
if cmux_reclaim_abandoned_app_host_scopes \
  "$stale_runner_root" "$system_temp_root" "$current_key" \
  2000000000 86400 "$current_key" "$legacy_key" \
  > "$TMP_DIR/symlink-candidate.out" 2> "$TMP_DIR/symlink-candidate.err"; then
  fail "stale recovery accepted a replacement home symlink"
fi
grep -Fxq preserve "$outside_scope/sentinel" \
  || fail "stale recovery followed a replacement home symlink"
unlink "$legacy_home"
mv "$legacy_home_backup" "$legacy_home"
wrong_uid=$(( $(/usr/bin/id -u) + 1 ))
if cmux_validate_abandoned_app_host_scope \
  "$system_temp_root" "$legacy_key" "$wrong_uid" \
  > "$TMP_DIR/wrong-owner.out" 2> "$TMP_DIR/wrong-owner.err"; then
  fail "stale recovery accepted a scope owned by another UID"
fi

# Internal symlinks are unlinked with the authenticated root, not traversed.
ln -s "$outside_scope" "$legacy_home/internal-link"
cmux_reclaim_abandoned_app_host_scopes \
  "$stale_runner_root" "$system_temp_root" "$current_key" \
  2000000000 86400 "$current_key" "$legacy_key" \
  || fail "valid stale scope with an internal symlink was not removed"
grep -Fxq preserve "$outside_scope/sentinel" \
  || fail "stale recovery followed an internal home symlink"

echo "PASS: app-host processes require matching receipts and executable vnodes"
