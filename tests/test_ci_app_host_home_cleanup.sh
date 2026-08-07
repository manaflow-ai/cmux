#!/usr/bin/env bash
set -euo pipefail

case "${0##*/}" in
  fake-lsof)
    pid_filter=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p) pid_filter="$2"; shift 2 ;;
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
    ;;
  stat)
    if [ "$*" = "-f %Su /dev/console" ]; then
      printf 'ci-console\n'
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
  dscl) exit 1 ;;
  launchctl)
    if [ "${1:-}" = "asuser" ]; then shift 2; fi
    exec "$@"
    ;;
  sudo)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -n|-E) shift ;;
        -u) shift 2 ;;
        *) break ;;
      esac
    done
    case "${1:-}" in
      true|chown|chmod) exit 0 ;;
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

prepare_scope
APP_HOST_EXECUTABLE="$DERIVED_DATA_PATH/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
mkdir -p "$(dirname "$APP_HOST_EXECUTABLE")"
: > "$APP_HOST_EXECUTABLE"
/bin/bash -c 'trap "exit 0" TERM; while :; do /bin/sleep 0.1; done' &
APP_HOST_PID=$!
printf '%s|%s\n' "$APP_HOST_PID" "$APP_HOST_EXECUTABLE" > "$FAKE_LSOF_STATE"
printf 'version=1\nkey=%s\npid=%s\nexecutable=%s\n' \
  "$CMUX_APP_HOST_KEY" "$APP_HOST_PID" "$APP_HOST_EXECUTABLE" \
  > "$CMUX_APP_HOST_RECEIPT_DIR/app-host-$APP_HOST_PID.receipt"

PATH="$FAKE_BIN:$PATH" \
  bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
    scripts/ci/cleanup-app-host-home.sh \
    > "$TMP_DIR/success.log" 2>&1
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

prepare_scope
real_confirmation="$CMUX_APP_HOST_CLEANUP_CONFIRMATION"
CMUX_APP_HOST_CLEANUP_CONFIRMATION="${real_confirmation%?}0"
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
