#!/usr/bin/env bash
set -euo pipefail

case "${0##*/}" in
  fake-lsof)
    pid_filter=""
    fd_filter=""
    path_filter=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p) pid_filter="$2"; shift 2 ;;
        -d) fd_filter="$2"; shift 2 ;;
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
        if [ "$fd_filter" != "9" ]; then
          continue
        fi
        printf 'p%s\nf9\naw\nn%s\n' "$state_pid" "$path_filter"
      else
        printf 'p%s\nftxt\nn%s\nftxt\nn/usr/lib/dyld\n' \
          "$state_pid" "$state_executable"
      fi
      found=1
    done < "$CMUX_FAKE_LSOF_STATE"
    [ "$found" -eq 1 ] || [ -z "$pid_filter" ]
    exit
    ;;
  stat)
    if [ "$*" = "-f %Su /dev/console" ]; then
      printf 'ci-console\n'
      exit 0
    fi
    if [ "${1:-}" = "-f" ] && [ "${2:-}" = "%Su" ]; then
      if [ "${3:-}" = "${CMUX_FAKE_UNTRUSTED_SCOPE_PATH:-}" ]; then
        printf 'untrusted-local-user\n'
      else
        /usr/bin/id -un
      fi
      exit 0
    fi
    exec /usr/bin/stat "$@"
    ;;
  id)
    if [ "${1:-}" = "-u" ] && [ "${2:-}" = "ci-console" ]; then
      printf '501\n'
      exit 0
    fi
    exec /usr/bin/id "$@"
    ;;
  dscl)
    if [ "$*" = ". -read /Users/ci-console NFSHomeDirectory" ]; then
      printf 'NFSHomeDirectory: /Users/ci-console\n'
      exit 0
    fi
    exit 1
    ;;
  launchctl)
    if [ "${1:-}" = "asuser" ]; then shift 2; fi
    exec "$@"
    ;;
  sudo)
    preserve_environment=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -n) shift ;;
        -E) preserve_environment=1; shift ;;
        -u) shift 2 ;;
        *) break ;;
      esac
    done
    case "${1:-}" in
      true) exit 0 ;;
      chown|chmod)
        if [ -n "${CMUX_FAKE_MUTATION_LOG:-}" ]; then
          printf '%s\n' "$*" >> "$CMUX_FAKE_MUTATION_LOG"
        fi
        exit 0
        ;;
      env)
        if [ "$preserve_environment" -eq 0 ]; then
          shift
          exec /usr/bin/env -i PATH="$PATH" "$@"
        fi
        shift
        exec /usr/bin/env \
          -u GITHUB_REPOSITORY_ID -u CARGO_HOME -u RUSTUP_HOME "$@"
        ;;
      *) exec "$@" ;;
    esac
    ;;
esac

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEANUP_SCRIPT="$ROOT_DIR/scripts/ci/cleanup-app-host-home.sh"
PREPARE_SCRIPT="$ROOT_DIR/scripts/ci/prepare-app-host-home.sh"
TMP_DIR="$(mktemp -d)"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
APP_HOST_PID=""
APP_HOST_HOME=""
OUTSIDE_HOME=""
cleanup() {
  if [ -n "$APP_HOST_PID" ]; then
    /bin/kill -KILL "$APP_HOST_PID" 2>/dev/null || true
    wait "$APP_HOST_PID" 2>/dev/null || true
  fi
  [ -z "$APP_HOST_HOME" ] || rm -rf -- "$APP_HOST_HOME"
  [ -z "$OUTSIDE_HOME" ] || rm -rf -- "$OUTSIDE_HOME"
  [ -z "${RUNNER_TEMP_DIR:-}" ] || chmod u+rwx "$RUNNER_TEMP_DIR" 2>/dev/null || true
  [ -z "${CMUX_APP_HOST_RECEIPT_DIR:-}" ] || rm -rf -- "$CMUX_APP_HOST_RECEIPT_DIR"
  [ -z "${CMUX_APP_HOST_CONFIRMATION_FILE:-}" ] || rm -f -- "$CMUX_APP_HOST_CONFIRMATION_FILE"
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

RUNNER_TEMP_DIR="$TMP_DIR/runner-temp"
DERIVED_DATA_PATH="$RUNNER_TEMP_DIR/cmux-derived-data-tests-123-1-shard-1"
FAKE_BIN="$TMP_DIR/fake-bin"
FAKE_LSOF="$FAKE_BIN/fake-lsof"
FAKE_LSOF_STATE="$TMP_DIR/lsof-state"
mkdir -p "$RUNNER_TEMP_DIR" "$DERIVED_DATA_PATH/Build/Products/Debug" "$FAKE_BIN"
for helper in fake-lsof stat id dscl launchctl sudo; do
  ln -s "$ROOT_DIR/tests/test_ci_app_host_home_cleanup.sh" "$FAKE_BIN/$helper"
done
: > "$FAKE_LSOF_STATE"

export RUNNER_TEMP="$RUNNER_TEMP_DIR"
export GITHUB_ENV="$TMP_DIR/github-env"
export GITHUB_REPOSITORY_ID=1234567
export GITHUB_RUN_ID="920000$$"
export GITHUB_RUN_ATTEMPT="3"
export CMUX_APP_HOST_SHARD="1"
export CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1
export CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH"
export CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER=1
export CMUX_APP_HOST_LSOF="$FAKE_LSOF"
export CMUX_FAKE_LSOF_STATE="$FAKE_LSOF_STATE"
export GITHUB_WORKSPACE="$ROOT_DIR"

prepare_scope() {
  : > "$GITHUB_ENV"
  bash "$PREPARE_SCRIPT"
  set -a
  # shellcheck disable=SC1090
  source "$GITHUB_ENV"
  set +a
  APP_HOST_HOME="$CMUX_APP_HOST_HOME"
  CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH"
  export CMUX_DERIVED_DATA_PATH
  : > "$FAKE_LSOF_STATE"
}

run_cleanup() {
  bash "$CLEANUP_SCRIPT"
}

different_digest() {
  local digest="$1"
  case "$digest" in
    *0) printf '%s1\n' "${digest%?}" ;;
    *) printf '%s0\n' "${digest%?}" ;;
  esac
}

discard_corrupted_scope_fixture() {
  local system_temp_root
  system_temp_root="$(cd /tmp && pwd -P)"
  if [ "$CMUX_APP_HOST_HOME" != "/tmp/cmux-ah-$CMUX_APP_HOST_KEY" ]; then
    echo "FAIL: refusing to discard an unexpected cleanup-test home"
    exit 1
  fi
  if [ "$CMUX_APP_HOST_RECEIPT_DIR" != \
    "$system_temp_root/cmux-ah-$CMUX_APP_HOST_KEY-receipts" ]; then
    echo "FAIL: refusing to discard unexpected cleanup-test receipts"
    exit 1
  fi
  if [ "$CMUX_APP_HOST_CONFIRMATION_FILE" != \
    "$system_temp_root/cmux-ah-$CMUX_APP_HOST_KEY.confirm" ]; then
    echo "FAIL: refusing to discard an unexpected cleanup-test confirmation"
    exit 1
  fi
  rm -rf -- "$CMUX_APP_HOST_HOME"
  rm -rf -- "$CMUX_APP_HOST_RECEIPT_DIR"
  rm -f -- "$CMUX_APP_HOST_CONFIRMATION_FILE"
}

unset CARGO_HOME RUSTUP_HOME
prepare_scope

unset_toolchain_capture="$TMP_DIR/unset-toolchain.capture"
# shellcheck disable=SC2016 # expanded by the console-user child shell
unset_toolchain_probe='printf "%s|%s|%s|%s\n" "$HOME" "$GITHUB_REPOSITORY_ID" "${CARGO_HOME-<unset>}" "${RUSTUP_HOME-<unset>}" > "$1"'
PATH="$FAKE_BIN:$PATH" \
  bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
    /bin/bash -c "$unset_toolchain_probe" \
    bash "$unset_toolchain_capture"
[ "$(cat "$unset_toolchain_capture")" = \
  "/Users/ci-console|$GITHUB_REPOSITORY_ID|<unset>|<unset>" ] \
  || { echo "FAIL: unset toolchain homes did not follow console HOME"; exit 1; }

shared_cargo_home="$TMP_DIR/shared-cargo"
shared_rustup_home="$TMP_DIR/shared-rustup"
shared_toolchain_capture="$TMP_DIR/shared-toolchain.capture"
# shellcheck disable=SC2016 # expanded by the console-user child shell
shared_toolchain_probe='printf "%s|%s|%s|%s\n" "$HOME" "$GITHUB_REPOSITORY_ID" "$CARGO_HOME" "$RUSTUP_HOME" > "$1"'
CARGO_HOME="$shared_cargo_home" RUSTUP_HOME="$shared_rustup_home" \
  PATH="$FAKE_BIN:$PATH" \
  bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
    /bin/bash -c "$shared_toolchain_probe" \
    bash "$shared_toolchain_capture"
[ "$(cat "$shared_toolchain_capture")" = \
  "/Users/ci-console|$GITHUB_REPOSITORY_ID|$shared_cargo_home|$shared_rustup_home" ] \
  || { echo "FAIL: configured shared toolchain homes were not forwarded"; exit 1; }

APP_HOST_EXECUTABLE="$DERIVED_DATA_PATH/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
mkdir -p "$(dirname "$APP_HOST_EXECUTABLE")"
: > "$APP_HOST_EXECUTABLE"
/bin/bash -c 'trap "exit 0" TERM; while :; do /bin/sleep 0.1; done' &
APP_HOST_PID=$!
printf '%s|%s\n' "$APP_HOST_PID" "$APP_HOST_EXECUTABLE" > "$FAKE_LSOF_STATE"
printf 'version=2\nkey=%s\npid=%s\nexecutable=%s\nreceipt_fd=9\n' \
  "$CMUX_APP_HOST_KEY" "$APP_HOST_PID" "$APP_HOST_EXECUTABLE" \
  > "$CMUX_APP_HOST_RECEIPT_DIR/app-host-$APP_HOST_PID.receipt"

# Model the supported split-account runner: the console user owns the exact
# app-host targets but cannot modify the runner account's RUNNER_TEMP parent.
chmod 0555 "$RUNNER_TEMP_DIR"
if ! PATH="$FAKE_BIN:$PATH" \
  bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
    scripts/ci/cleanup-app-host-home.sh \
    > "$TMP_DIR/success.log" 2>&1; then
  cat "$TMP_DIR/success.log"
  echo "FAIL: cleanup rejected a trusted split-account scope"
  exit 1
fi
chmod 0755 "$RUNNER_TEMP_DIR"
wait "$APP_HOST_PID" 2>/dev/null || true
APP_HOST_PID=""
if [ -e "$CMUX_APP_HOST_HOME" ] \
  || [ -e "$CMUX_APP_HOST_RECEIPT_DIR" ] \
  || [ -e "$CMUX_APP_HOST_CONFIRMATION_FILE" ]; then
  cat "$TMP_DIR/success.log"
  echo "FAIL: cleanup left an identity-owned target behind"
  exit 1
fi
grep -Fq "Confirmed app-host cleanup target:" "$TMP_DIR/success.log" || {
  cat "$TMP_DIR/success.log"
  echo "FAIL: cleanup did not confirm its exact deletion target"
  exit 1
}

# Repeating cleanup with the same published identity is idempotent.
run_cleanup > "$TMP_DIR/already-absent.log"
grep -Fq "already absent" "$TMP_DIR/already-absent.log"

# Model interruption immediately after cleanup authority becomes durable but
# before either mutable scope root is claimed. Teardown must remove the exact
# confirmation instead of leaving a run key that preparation can never reuse.
prepare_scope
rm -rf -- "$CMUX_APP_HOST_HOME" "$CMUX_APP_HOST_RECEIPT_DIR"
run_cleanup > "$TMP_DIR/confirmation-only-partial.log"
if [ -e "$CMUX_APP_HOST_CONFIRMATION_FILE" ]; then
  cat "$TMP_DIR/confirmation-only-partial.log"
  echo "FAIL: cleanup left a confirmation-only partial scope behind"
  exit 1
fi

prepare_scope
rm -f -- "$CMUX_APP_HOST_CONFIRMATION_FILE"
: > "$TMP_DIR/unauthenticated-mutations.log"
set +e
PATH="$FAKE_BIN:$PATH" \
CMUX_FAKE_MUTATION_LOG="$TMP_DIR/unauthenticated-mutations.log" \
  bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
    scripts/ci/cleanup-app-host-home.sh \
    > "$TMP_DIR/unauthenticated-cleanup.log" 2>&1
unauthenticated_cleanup_status=$?
set -e
if [ "$unauthenticated_cleanup_status" -ne 1 ] \
  || [ -s "$TMP_DIR/unauthenticated-mutations.log" ]; then
  cat "$TMP_DIR/unauthenticated-cleanup.log"
  cat "$TMP_DIR/unauthenticated-mutations.log"
  echo "FAIL: console cleanup mutated a scope before authenticating it"
  exit 1
fi
discard_corrupted_scope_fixture

prepare_scope
: > "$TMP_DIR/untrusted-owner-mutations.log"
set +e
PATH="$FAKE_BIN:$PATH" \
CMUX_FAKE_MUTATION_LOG="$TMP_DIR/untrusted-owner-mutations.log" \
CMUX_FAKE_UNTRUSTED_SCOPE_PATH="$(cd "$CMUX_APP_HOST_HOME" && pwd -P)" \
  bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
    scripts/ci/cleanup-app-host-home.sh \
    > "$TMP_DIR/untrusted-owner-cleanup.log" 2>&1
untrusted_owner_status=$?
set -e
if [ "$untrusted_owner_status" -ne 1 ] \
  || [ -s "$TMP_DIR/untrusted-owner-mutations.log" ]; then
  cat "$TMP_DIR/untrusted-owner-cleanup.log"
  cat "$TMP_DIR/untrusted-owner-mutations.log"
  echo "FAIL: console cleanup took ownership of an untrusted scope"
  exit 1
fi
run_cleanup >/dev/null

prepare_scope
real_confirmation="$CMUX_APP_HOST_CLEANUP_CONFIRMATION"
CMUX_APP_HOST_CLEANUP_CONFIRMATION="$(different_digest "$real_confirmation")"
[ "$CMUX_APP_HOST_CLEANUP_CONFIRMATION" != "$real_confirmation" ] || {
  echo "FAIL: wrong-confirmation fixture did not change the digest"
  exit 1
}
export CMUX_APP_HOST_CLEANUP_CONFIRMATION
if run_cleanup > "$TMP_DIR/wrong-confirmation.log" 2>&1; then
  echo "FAIL: cleanup accepted a confirmation for another target"
  exit 1
fi
[ -f "$CMUX_APP_HOST_HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" ] || {
  echo "FAIL: rejected cleanup changed the app-host home"
  exit 1
}
CMUX_APP_HOST_CLEANUP_CONFIRMATION="$real_confirmation"
export CMUX_APP_HOST_CLEANUP_CONFIRMATION
run_cleanup >/dev/null

prepare_scope
rm -f -- "$CMUX_APP_HOST_CONFIRMATION_FILE"
if run_cleanup > "$TMP_DIR/missing-confirmation.log" 2>&1; then
  echo "FAIL: cleanup accepted a missing external confirmation record"
  exit 1
fi
[ -d "$CMUX_APP_HOST_HOME" ] || {
  echo "FAIL: cleanup removed a home without its confirmation record"
  exit 1
}
discard_corrupted_scope_fixture
prepare_scope
run_cleanup >/dev/null

prepare_scope
OUTSIDE_HOME="$TMP_DIR/outside-home"
mkdir -p "$OUTSIDE_HOME"
printf 'keep\n' > "$OUTSIDE_HOME/sentinel"
rm -rf -- "$CMUX_APP_HOST_HOME"
ln -s "$OUTSIDE_HOME" "$CMUX_APP_HOST_HOME"
if run_cleanup > "$TMP_DIR/symlink.log" 2>&1; then
  echo "FAIL: cleanup followed a replacement home symlink"
  exit 1
fi
grep -Fxq "FAIL: refusing app-host cleanup through a home symlink" "$TMP_DIR/symlink.log"
[ -f "$OUTSIDE_HOME/sentinel" ] || {
  echo "FAIL: cleanup changed a symlink target outside its identity"
  exit 1
}
rm -f -- "$CMUX_APP_HOST_HOME"
discard_corrupted_scope_fixture
prepare_scope
run_cleanup >/dev/null

for mutated_xdg_kind in regular-file dangling-symlink; do
  prepare_scope
  rm -rf -- "$CMUX_APP_HOST_XDG_CONFIG_HOME"
  if [ "$mutated_xdg_kind" = "regular-file" ]; then
    printf 'corrupt\n' > "$CMUX_APP_HOST_XDG_CONFIG_HOME"
  else
    ln -s "$TMP_DIR/missing-xdg-target" "$CMUX_APP_HOST_XDG_CONFIG_HOME"
  fi
  run_cleanup > "$TMP_DIR/$mutated_xdg_kind.log"
  [ ! -e "$CMUX_APP_HOST_HOME" ] || {
    cat "$TMP_DIR/$mutated_xdg_kind.log"
    echo "FAIL: cleanup did not remove a home with a mutated XDG leaf"
    exit 1
  }
done

prepare_scope
derived_data_target="$RUNNER_TEMP_DIR/derived-data-symlink-target"
mv "$DERIVED_DATA_PATH" "$derived_data_target"
ln -s "$derived_data_target" "$DERIVED_DATA_PATH"
if run_cleanup > "$TMP_DIR/derived-data-symlink.log" 2>&1; then
  echo "FAIL: cleanup accepted a symlinked DerivedData input"
  exit 1
fi
for preserved_path in \
  "$CMUX_APP_HOST_HOME" \
  "$CMUX_APP_HOST_RECEIPT_DIR" \
  "$CMUX_APP_HOST_CONFIRMATION_FILE"
do
  [ -e "$preserved_path" ] || {
    echo "FAIL: rejected DerivedData symlink changed the app-host scope"
    exit 1
  }
done
rm -f -- "$DERIVED_DATA_PATH"
mv "$derived_data_target" "$DERIVED_DATA_PATH"
run_cleanup >/dev/null

prepare_scope
real_home="$CMUX_APP_HOST_HOME"
CMUX_APP_HOST_HOME="$HOME"
export CMUX_APP_HOST_HOME
if run_cleanup > "$TMP_DIR/wrong-home.log" 2>&1; then
  echo "FAIL: cleanup accepted the console-user home as its target"
  exit 1
fi
CMUX_APP_HOST_HOME="$real_home"
export CMUX_APP_HOST_HOME
run_cleanup >/dev/null

/usr/bin/env \
  -u CMUX_APP_HOST_KEY \
  -u CMUX_APP_HOST_HOME \
  -u CMUX_APP_HOST_XDG_CONFIG_HOME \
  -u CMUX_APP_HOST_RECEIPT_DIR \
  -u CMUX_APP_HOST_CLEANUP_CONFIRMATION \
  -u CMUX_APP_HOST_CONFIRMATION_FILE \
  bash "$CLEANUP_SCRIPT" > "$TMP_DIR/unpublished.log"
grep -Fq "cleanup skipped" "$TMP_DIR/unpublished.log"

echo "PASS: isolated app-host cleanup requires identity, receipts, and confirmation"
