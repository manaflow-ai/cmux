#!/usr/bin/env bash
set -euo pipefail

if [ "$(basename "$0")" = "fake-lsof" ]; then
  pid_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -p)
        pid_filter="$2"
        shift 2
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
    printf 'p%s\nftxt\nn%s\nftxt\nn/usr/lib/dyld\n' \
      "$state_pid" "$state_executable"
    found=1
  done < "$CMUX_FAKE_LSOF_STATE"
  [ "$found" -eq 1 ] || [ -z "$pid_filter" ]
  exit
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
PIDS=""
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
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

FAKE_LSOF="$TMP_DIR/fake-lsof"
ln -s "$ROOT_DIR/tests/test_ci_app_host_processes.sh" "$FAKE_LSOF"
export CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER=1
export CMUX_APP_HOST_LSOF="$FAKE_LSOF"
export CMUX_FAKE_LSOF_STATE="$TMP_DIR/lsof-state"
: > "$CMUX_FAKE_LSOF_STATE"

# shellcheck source=scripts/ci/app-host-processes.sh
PROCESS_HELPER="$ROOT_DIR/scripts/ci/app-host-processes.sh"
if [ ! -f "$PROCESS_HELPER" ]; then
  echo "FAIL: app-host process receipt helper is missing" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$PROCESS_HELPER"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

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
  printf 'version=1\nkey=%s\npid=%s\nexecutable=%s\n' \
    "$key" "$pid" "$executable" \
    > "$receipt_dir/app-host-$pid.receipt"
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

make_scope matching
spawn_process
matching_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n' "$matching_pid" "$TEST_EXECUTABLE" > "$CMUX_FAKE_LSOF_STATE"
write_receipt "$TEST_RECEIPT_DIR" "$KEY" "$matching_pid" "$TEST_EXECUTABLE"
verified="$(cmux_app_host_verified_pids \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA")" || fail "matching receipt was rejected"
[ "$verified" = "$matching_pid" ] || fail "matching receipt did not return its PID"
cmux_terminate_verified_app_hosts \
  "$TEST_RECEIPT_DIR" "$KEY" "$TEST_DERIVED_DATA" || fail "matching receipt did not terminate"
wait "$matching_pid" 2>/dev/null || true
case " $PIDS " in
  *" $matching_pid "*) PIDS="${PIDS//$matching_pid/}" ;;
esac

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

empty_runner_temp="$TMP_DIR/empty-runner"
mkdir -p "$empty_runner_temp"
: > "$CMUX_FAKE_LSOF_STATE"
cmux_terminate_stale_receipted_app_hosts "$empty_runner_temp" \
  || fail "stale receipt cleanup was unsafe when no receipts existed"

preflight_runner_temp="$TMP_DIR/preflight-runner"
preflight_key=13579bdf0246
preflight_receipt_dir="$preflight_runner_temp/cmux-app-host-$preflight_key-receipts"
preflight_receipted_executable="$preflight_runner_temp/receipted/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
preflight_unreceipted_executable="$preflight_runner_temp/unreceipted/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
mkdir -p "$preflight_receipt_dir"
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
if cmux_terminate_stale_receipted_app_hosts "$preflight_runner_temp" \
  > "$TMP_DIR/stale-unreceipted.out" 2> "$TMP_DIR/stale-unreceipted.err"; then
  fail "stale cleanup accepted a live unreceipted runner target"
fi
grep -Fq "has no verified receipt beneath" "$TMP_DIR/stale-unreceipted.err" \
  || fail "stale cleanup did not identify the unreceipted runner target"
/bin/kill -0 "$preflight_receipted_pid" 2>/dev/null \
  || fail "stale cleanup signaled a verified target before completing preflight"
/bin/kill -0 "$preflight_unreceipted_pid" 2>/dev/null \
  || fail "stale cleanup signaled an unreceipted target"

deleted_runner_temp="$TMP_DIR/deleted-runner"
deleted_key=2468ace01357
deleted_receipt_dir="$deleted_runner_temp/cmux-app-host-$deleted_key-receipts"
deleted_derived_data="$deleted_runner_temp/deleted-derived-data"
deleted_executable="$deleted_derived_data/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
mkdir -p "$deleted_receipt_dir"
spawn_process
deleted_stale_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s (deleted)\n' \
  "$deleted_stale_pid" "$deleted_executable" > "$CMUX_FAKE_LSOF_STATE"
write_receipt \
  "$deleted_receipt_dir" "$deleted_key" \
  "$deleted_stale_pid" "$deleted_executable"
cmux_terminate_stale_receipted_app_hosts "$deleted_runner_temp" \
  || fail "deleted stale product was not verified and terminated"
wait "$deleted_stale_pid" 2>/dev/null || true
[ ! -e "$deleted_derived_data" ] \
  || fail "deleted stale verification recreated the missing DerivedData root"

stale_runner_temp="$TMP_DIR/stale-runner"
stale_key=abcdef012345
stale_receipt_dir="$stale_runner_temp/cmux-app-host-$stale_key-receipts"
stale_derived_data="$stale_runner_temp/derived-data"
stale_executable="$stale_derived_data/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
mkdir -p "$stale_receipt_dir" "$(dirname "$stale_executable")"
: > "$stale_executable"
spawn_process
stale_pid="$CMUX_TEST_SPAWNED_PID"
printf '%s|%s\n' "$stale_pid" "$stale_executable" > "$CMUX_FAKE_LSOF_STATE"
write_receipt "$stale_receipt_dir" "$stale_key" "$stale_pid" "$stale_executable"
cmux_terminate_stale_receipted_app_hosts "$stale_runner_temp" \
  || fail "verified stale receipt was not terminated"
wait "$stale_pid" 2>/dev/null || true

echo "PASS: app-host processes require matching receipts and executable vnodes"
