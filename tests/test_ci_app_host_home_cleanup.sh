#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEANUP_SCRIPT="$ROOT_DIR/scripts/ci/cleanup-app-host-home.sh"
if [ ! -f "$CLEANUP_SCRIPT" ]; then
  echo "FAIL: isolated app-host cleanup script is missing"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
app_host_pid=""
cleanup() {
  if [ -n "$app_host_pid" ]; then
    kill -KILL "$app_host_pid" 2>/dev/null || true
    wait "$app_host_pid" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

RUNNER_TEMP_DIR="$TMP_DIR/runner-temp"
DERIVED_DATA_PATH="$RUNNER_TEMP_DIR/cmux-derived-data-tests-123-1-shard-1"
APP_HOST_HOME="$RUNNER_TEMP_DIR/ah-012345abcdef"
mkdir -p \
  "$DERIVED_DATA_PATH/Build/Products/Debug" \
  "$APP_HOST_HOME/.config"
printf 'private\n' > "$APP_HOST_HOME/sentinel"

cp /bin/sleep "$DERIVED_DATA_PATH/Build/Products/Debug/cmux DEV"
"$DERIVED_DATA_PATH/Build/Products/Debug/cmux DEV" 30 &
app_host_pid=$!
kill -0 "$app_host_pid"

CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CFFIXED_USER_HOME="$APP_HOST_HOME" \
XDG_CONFIG_HOME="$APP_HOST_HOME/.config" \
  bash "$CLEANUP_SCRIPT"

if [ -e "$APP_HOST_HOME" ]; then
  echo "FAIL: cleanup left the isolated app-host home behind"
  exit 1
fi
if kill -0 "$app_host_pid" 2>/dev/null; then
  echo "FAIL: cleanup removed the home before its scoped app host stopped"
  exit 1
fi
wait "$app_host_pid" 2>/dev/null || true
app_host_pid=""

MISSING_XDG_HOME="$RUNNER_TEMP_DIR/ah-aabbccddeeff"
mkdir -p "$MISSING_XDG_HOME/.config"
printf 'private\n' > "$MISSING_XDG_HOME/sentinel"
rmdir "$MISSING_XDG_HOME/.config"
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CFFIXED_USER_HOME="$MISSING_XDG_HOME" \
XDG_CONFIG_HOME="$MISSING_XDG_HOME/.config" \
  bash "$CLEANUP_SCRIPT"
if [ -e "$MISSING_XDG_HOME" ]; then
  echo "FAIL: cleanup must remove the home after its mutable XDG child disappears"
  exit 1
fi

INVALID_HOME="$RUNNER_TEMP_DIR/not-an-app-host-home"
mkdir -p "$INVALID_HOME/.config"
printf 'keep\n' > "$INVALID_HOME/sentinel"
set +e
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CFFIXED_USER_HOME="$INVALID_HOME" \
XDG_CONFIG_HOME="$INVALID_HOME/.config" \
  bash "$CLEANUP_SCRIPT" >"$TMP_DIR/invalid-name.log" 2>&1
invalid_name_status=$?
set -e
if [ "$invalid_name_status" -ne 1 ] || [ ! -f "$INVALID_HOME/sentinel" ]; then
  cat "$TMP_DIR/invalid-name.log"
  echo "FAIL: cleanup must reject a non-app-host directory"
  exit 1
fi

OUTSIDE_HOME="$TMP_DIR/outside-home"
mkdir -p "$OUTSIDE_HOME/.config"
printf 'keep\n' > "$OUTSIDE_HOME/sentinel"
ln -s "$OUTSIDE_HOME" "$RUNNER_TEMP_DIR/ah-fedcba654321"
set +e
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CFFIXED_USER_HOME="$RUNNER_TEMP_DIR/ah-fedcba654321" \
XDG_CONFIG_HOME="$RUNNER_TEMP_DIR/ah-fedcba654321/.config" \
  bash "$CLEANUP_SCRIPT" >"$TMP_DIR/symlink-escape.log" 2>&1
symlink_escape_status=$?
set -e
if [ "$symlink_escape_status" -ne 1 ] || [ ! -f "$OUTSIDE_HOME/sentinel" ]; then
  cat "$TMP_DIR/symlink-escape.log"
  echo "FAIL: cleanup must reject a canonical path outside the runner temp root"
  exit 1
fi

/usr/bin/env -u CFFIXED_USER_HOME -u XDG_CONFIG_HOME \
  CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
  bash "$CLEANUP_SCRIPT"

echo "PASS: isolated app-host cleanup is scoped and path validated"
