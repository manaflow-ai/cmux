#!/usr/bin/env bash
set -euo pipefail

if [ "${CMUX_MOCK_XCODEBUILD_PROCESS:-0}" = "1" ]; then
  printf '%s\n' "$@" >> "$CMUX_CAPTURE_XCODEBUILD_ARGS"
  printf '%s\n' "${TEST_RUNNER_CMUX_TEST_PROCESS:-<unset>}" >> "$CMUX_CAPTURE_TEST_RUNNER_ENV"
  printf '%s|%s|%s\n' \
    "${HOME:-<unset>}" \
    "${CFFIXED_USER_HOME:-<unset>}" \
    "${XDG_CONFIG_HOME:-<unset>}" \
    >> "$CMUX_CAPTURE_XCODEBUILD_PARENT_ENV"
  printf '%s|%s|%s|%s|%s\n' \
    "${TEST_RUNNER_HOME:-<unset>}" \
    "${TEST_RUNNER_CFFIXED_USER_HOME:-<unset>}" \
    "${TEST_RUNNER_XDG_CONFIG_HOME:-<unset>}" \
    "${TEST_RUNNER_CMUX_APP_HOST_EXPECTED_HOME:-<unset>}" \
    "${TEST_RUNNER_CMUX_APP_HOST_EXPECTED_XDG_CONFIG_HOME:-<unset>}" \
    >> "$CMUX_CAPTURE_TEST_RUNNER_HOME_ENV"
  config_home="${TEST_RUNNER_HOME:-${HOME:-/tmp}}"
  [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" != "leak" ] || config_home=/Users/runner
  config_suffix='Library/Application Support/com.mitchellh.ghostty/config.ghostty'
  echo "cmux DEV [config] config: path=$config_home/$config_suffix"
  [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" != "leak" ] || exit 0
  sleep 10
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ln -s "$ROOT_DIR/tests/test_ci_app_host_xcodebuild_retry.sh" "$TMP_DIR/xcodebuild"

APP_HOST_HOME="$TMP_DIR/app-host-home"
APP_HOST_XDG_CONFIG_HOME="$APP_HOST_HOME/.config"
mkdir -p "$APP_HOST_XDG_CONFIG_HOME"

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/xcodebuild-args.log" \
CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/test-runner-env.log" \
CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/xcodebuild-parent-env.log" \
CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/test-runner-home-env.log" \
CMUX_MOCK_XCODEBUILD_PROCESS=1 \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=2 \
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=0.1 \
CFFIXED_USER_HOME="$APP_HOST_HOME" \
XDG_CONFIG_HOME="$APP_HOST_XDG_CONFIG_HOME" \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/output.log" 2>&1
status=$?
set -e

if [ "$status" -ne 124 ]; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: expected wrapper to exit with final timeout status 124, got $status"
  exit 1
fi

if ! grep -Fq "Retrying app-host xcodebuild after 0.1s idle timeout (attempt 1/2)" "$TMP_DIR/output.log"; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: wrapper did not retry after idle timeout"
  exit 1
fi

timeout_count="$(grep -Fc "Idle timed out after 0.1s" "$TMP_DIR/output.log")"
if [ "$timeout_count" -ne 2 ]; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: expected two timed-out attempts, got $timeout_count"
  exit 1
fi

invocation_count="$(grep -cx 'test' "$TMP_DIR/xcodebuild-args.log" || true)"
runner_marker_count="$(grep -cx '1' "$TMP_DIR/test-runner-env.log" || true)"
if [ "$runner_marker_count" -eq 0 ] || [ "$runner_marker_count" -ne "$invocation_count" ]; then
  cat "$TMP_DIR/test-runner-env.log"
  echo "FAIL: expected every app-host launch to receive TEST_RUNNER_CMUX_TEST_PROCESS=1"
  exit 1
fi

isolated_parent_count="$(awk -F '|' -v isolated="$APP_HOST_HOME" '
  $1 == isolated || $2 != "<unset>" || $3 != "<unset>" { count += 1 }
  END { print count + 0 }
' "$TMP_DIR/xcodebuild-parent-env.log")"
if [ "$isolated_parent_count" -ne 0 ]; then
  cat "$TMP_DIR/xcodebuild-parent-env.log"
  echo "FAIL: xcodebuild must keep its real HOME without app-host-only redirects"
  exit 1
fi

isolated_runner_count="$(awk -F '|' \
  -v home="$APP_HOST_HOME" \
  -v xdg="$APP_HOST_XDG_CONFIG_HOME" '
  $1 == home && $2 == home && $3 == xdg && $4 == home && $5 == xdg {
    count += 1
  }
  END { print count + 0 }
' "$TMP_DIR/test-runner-home-env.log")"
if [ "$isolated_runner_count" -ne "$invocation_count" ]; then
  cat "$TMP_DIR/test-runner-home-env.log"
  echo "FAIL: every xcodebuild invocation must pass isolated homes through TEST_RUNNER_ variables"
  exit 1
fi

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/leak-xcodebuild-args.log" \
CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/leak-test-runner-env.log" \
CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/leak-xcodebuild-parent-env.log" \
CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/leak-test-runner-home-env.log" \
CMUX_MOCK_XCODEBUILD_PROCESS=1 \
CMUX_MOCK_XCODEBUILD_MODE=leak \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
CFFIXED_USER_HOME="$APP_HOST_HOME" \
XDG_CONFIG_HOME="$APP_HOST_XDG_CONFIG_HOME" \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/leak-output.log" 2>&1
leak_status=$?
set -e

if [ "$leak_status" -ne 1 ] || ! grep -Fq \
  "FAIL: Ghostty accessed configuration outside the isolated app-host home" \
  "$TMP_DIR/leak-output.log"; then
  cat "$TMP_DIR/leak-output.log"
  echo "FAIL: wrapper must reject a Ghostty config path outside the isolated app-host home"
  exit 1
fi

echo "PASS: app-host xcodebuild wrapper retries idle timeouts"
