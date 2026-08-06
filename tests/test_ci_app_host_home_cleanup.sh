#!/usr/bin/env bash
set -euo pipefail

if [ "${CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER:-0}" = "1" ]; then
  case "${0##*/}" in
    ps)
      real_ps=/bin/ps
      [ -x "$real_ps" ] || real_ps=/usr/bin/ps
      if [ "$*" = "-axww -o pid=,command=" ]; then
        exec "$real_ps" "$@"
      fi
      # Model macOS process output whose long command was truncated before the
      # Build/Products suffix that scopes the app host.
      exit 0
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
    dscl)
      exit 1
      ;;
    launchctl)
      if [ "${1:-}" = "asuser" ]; then
        shift 2
      fi
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
fi

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
DERIVED_DATA_PATH="$RUNNER_TEMP_DIR/cmux-derived-data-tests-123-1-shard-1-with-a-realistically-long-self-hosted-runner-path-for-process-discovery"
APP_HOST_HOME="$RUNNER_TEMP_DIR/ah-012345abcdef"
FAKE_BIN="$TMP_DIR/fake-bin"
mkdir -p \
  "$DERIVED_DATA_PATH/Build/Products/Debug" \
  "$APP_HOST_HOME/.config" \
  "$FAKE_BIN"
for helper in ps stat id dscl launchctl sudo; do
  ln -s "$ROOT_DIR/tests/test_ci_app_host_home_cleanup.sh" "$FAKE_BIN/$helper"
done
printf 'private\n' > "$APP_HOST_HOME/sentinel"

RESOLVED_DERIVED_DATA_PATH="$(cd "$DERIVED_DATA_PATH" && pwd -P)"
/bin/bash -c 'exec -a "$1" /bin/sleep 30' bash \
  "$RESOLVED_DERIVED_DATA_PATH/Build/Products/Debug/cmux DEV" &
app_host_pid=$!
kill -0 "$app_host_pid"

PATH="$FAKE_BIN:$PATH" \
CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER=1 \
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CMUX_APP_HOST_HOME="$APP_HOST_HOME" \
CMUX_APP_HOST_XDG_CONFIG_HOME="$APP_HOST_HOME/.config" \
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
PATH="$FAKE_BIN:$PATH" \
CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER=1 \
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CMUX_APP_HOST_HOME="$MISSING_XDG_HOME" \
CMUX_APP_HOST_XDG_CONFIG_HOME="$MISSING_XDG_HOME/.config" \
GITHUB_WORKSPACE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
    scripts/ci/cleanup-app-host-home.sh
if [ -e "$MISSING_XDG_HOME" ]; then
  echo "FAIL: cleanup must remove the home after its mutable XDG child disappears"
  exit 1
fi

PARTIAL_SETUP_HOME="$RUNNER_TEMP_DIR/ah-123456abcdef"
mkdir -p "$PARTIAL_SETUP_HOME"
printf 'partially-created\n' > "$PARTIAL_SETUP_HOME/sentinel"
set +e
PATH="$FAKE_BIN:$PATH" \
CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER=1 \
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CMUX_APP_HOST_HOME="$PARTIAL_SETUP_HOME" \
GITHUB_WORKSPACE="$ROOT_DIR" \
  /usr/bin/env -u CMUX_APP_HOST_XDG_CONFIG_HOME \
    bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
      scripts/ci/cleanup-app-host-home.sh \
      >"$TMP_DIR/partial-setup-cleanup.log" 2>&1
partial_setup_status=$?
set -e
if [ "$partial_setup_status" -ne 0 ] || [ -e "$PARTIAL_SETUP_HOME" ]; then
  cat "$TMP_DIR/partial-setup-cleanup.log"
  echo "FAIL: cleanup must recover a home created after its single target was published"
  exit 1
fi

for mutated_xdg_kind in regular-file dangling-symlink; do
  case "$mutated_xdg_kind" in
    regular-file) MUTATED_XDG_HOME="$RUNNER_TEMP_DIR/ah-112233445566" ;;
    dangling-symlink) MUTATED_XDG_HOME="$RUNNER_TEMP_DIR/ah-66778899aabb" ;;
  esac
  mkdir -p "$MUTATED_XDG_HOME"
  if [ "$mutated_xdg_kind" = "regular-file" ]; then
    printf 'corrupt\n' > "$MUTATED_XDG_HOME/.config"
  else
    ln -s "$TMP_DIR/missing-xdg-target" "$MUTATED_XDG_HOME/.config"
  fi

  set +e
  PATH="$FAKE_BIN:$PATH" \
  CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER=1 \
  CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
  CMUX_APP_HOST_HOME="$MUTATED_XDG_HOME" \
  CMUX_APP_HOST_XDG_CONFIG_HOME="$MUTATED_XDG_HOME/.config" \
  GITHUB_WORKSPACE="$ROOT_DIR" \
    bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
      scripts/ci/cleanup-app-host-home.sh \
      >"$TMP_DIR/$mutated_xdg_kind-cleanup.log" 2>&1
  mutated_xdg_status=$?
  set -e
  if [ "$mutated_xdg_status" -ne 0 ] || [ -e "$MUTATED_XDG_HOME" ]; then
    cat "$TMP_DIR/$mutated_xdg_kind-cleanup.log"
    echo "FAIL: cleanup must remove a home whose XDG child is a $mutated_xdg_kind"
    exit 1
  fi
done

INVALID_HOME="$RUNNER_TEMP_DIR/not-an-app-host-home"
mkdir -p "$INVALID_HOME/.config"
printf 'keep\n' > "$INVALID_HOME/sentinel"
set +e
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CMUX_APP_HOST_HOME="$INVALID_HOME" \
CMUX_APP_HOST_XDG_CONFIG_HOME="$INVALID_HOME/.config" \
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
CMUX_APP_HOST_HOME="$RUNNER_TEMP_DIR/ah-fedcba654321" \
CMUX_APP_HOST_XDG_CONFIG_HOME="$RUNNER_TEMP_DIR/ah-fedcba654321/.config" \
  bash "$CLEANUP_SCRIPT" >"$TMP_DIR/symlink-escape.log" 2>&1
symlink_escape_status=$?
set -e
if [ "$symlink_escape_status" -ne 1 ] || [ ! -f "$OUTSIDE_HOME/sentinel" ]; then
  cat "$TMP_DIR/symlink-escape.log"
  echo "FAIL: cleanup must reject a canonical path outside the runner temp root"
  exit 1
fi

/usr/bin/env -u CMUX_APP_HOST_HOME -u CMUX_APP_HOST_XDG_CONFIG_HOME \
  -u CFFIXED_USER_HOME -u XDG_CONFIG_HOME \
  CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
  bash "$CLEANUP_SCRIPT"

ABSENT_HOME="$RUNNER_TEMP_DIR/ah-001122334455"
PATH="$FAKE_BIN:$PATH" \
CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER=1 \
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
CMUX_APP_HOST_HOME="$ABSENT_HOME" \
CMUX_APP_HOST_XDG_CONFIG_HOME="$ABSENT_HOME/.config" \
GITHUB_WORKSPACE="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/ci/run-in-console-session.sh" \
    scripts/ci/cleanup-app-host-home.sh

echo "PASS: isolated app-host cleanup is scoped and path validated"
