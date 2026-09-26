#!/usr/bin/env bash
set -euo pipefail

if [ "$(basename "$0")" = "fake-lsof" ]; then
  exit 0
fi
if [ "$(basename "$0")" = "launchctl" ]; then
  printf '%s\n' "$*" >> "${CMUX_CAPTURE_LAUNCHCTL:?}"
  exit 0
fi
if [ "$(basename "$0")" = "pgrep" ]; then
  [ -z "${CMUX_FAKE_PGREP_PIDS:-}" ] || printf '%s\n' $CMUX_FAKE_PGREP_PIDS
  exit 0
fi

if [ "${CMUX_MOCK_XCODEBUILD_PROCESS:-0}" = "1" ]; then
  printf '%s\n' "$@" >> "$CMUX_CAPTURE_XCODEBUILD_ARGS"
  printf '%s\n' "${TEST_RUNNER_CMUX_TEST_PROCESS:-<unset>}" >> "$CMUX_CAPTURE_TEST_RUNNER_ENV"
  if [ -n "${CMUX_CAPTURE_TEST_RUNNER_CI_ENV:-}" ]; then
    printf '%s|%s\n' "${TEST_RUNNER_CI-<unset>}" "${TEST_RUNNER_GITHUB_ACTIONS-<unset>}" \
      >> "$CMUX_CAPTURE_TEST_RUNNER_CI_ENV"
  fi
  printf '%s|%s|%s\n' \
    "${HOME:-<unset>}" \
    "${CFFIXED_USER_HOME:-<unset>}" \
    "${XDG_CONFIG_HOME:-<unset>}" \
    >> "$CMUX_CAPTURE_XCODEBUILD_PARENT_ENV"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${TEST_RUNNER_HOME:-<unset>}" \
    "${TEST_RUNNER_CFFIXED_USER_HOME:-<unset>}" \
    "${TEST_RUNNER_XDG_CONFIG_HOME:-<unset>}" \
    "${TEST_RUNNER_SSH_AUTH_SOCK-<unset>}" \
    "${TEST_RUNNER_CMUX_APP_HOST_ISOLATION_REQUIRED:-<unset>}" \
    "${TEST_RUNNER_CMUX_APP_HOST_EXPECTED_HOME:-<unset>}" \
    "${TEST_RUNNER_CMUX_APP_HOST_EXPECTED_XDG_CONFIG_HOME:-<unset>}" \
    "${TEST_RUNNER_CMUX_APP_HOST_KEY:-<unset>}" \
    "${TEST_RUNNER_CMUX_APP_HOST_RECEIPT_DIR:-<unset>}" \
    >> "$CMUX_CAPTURE_TEST_RUNNER_HOME_ENV"
  if [ -n "${CMUX_CAPTURE_TEST_RUNNER_TOOL_ENV:-}" ]; then
    printf '%s|%s\n' "${TEST_RUNNER_PATH-<unset>}" "${TEST_RUNNER_BUN_INSTALL-<unset>}" \
      >> "$CMUX_CAPTURE_TEST_RUNNER_TOOL_ENV"
  fi
  config_home="${TEST_RUNNER_HOME:-${HOME:-/tmp}}"
  config_category=default
  config_message="reading configuration file"
  config_suffix='Library/Application Support/com.mitchellh.ghostty/config.ghostty'
  emit_config_evidence=1
  case "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" in
    leak) config_home=/Users/runner ;;
    sibling-leak) config_home="${TEST_RUNNER_HOME}-other" ;;
    published-default-alias) config_home="$CMUX_APP_HOST_HOME" ;;
    published-config-alias)
      config_category=config
      config_home="$CMUX_APP_HOST_HOME"
      ;;
    published-default-sibling-leak) config_home="${CMUX_APP_HOST_HOME}-other" ;;
    published-config-sibling-leak)
      config_category=config
      config_home="${CMUX_APP_HOST_HOME}-other"
      ;;
    xdg-config-leak)
      config_category=config
      config_home=/Users/runner
      config_suffix='.config/ghostty/config'
      ;;
    xdg-default-leak)
      config_category=default
      config_home=/Users/runner
      config_suffix='.config/ghostty/config'
      ;;
    unrelated-config-token)
      config_category=config
      config_message="config:"
      ;;
    no-config-evidence)
      emit_config_evidence=0
      ;;
    missing-log)
      rm -f "$CMUX_XCODEBUILD_NONINTERACTIVE_LOG_PATH"
      exit 0
      ;;
  esac
  if [ "$emit_config_evidence" = "1" ]; then
    echo "cmux DEV [$config_category] $config_message path=$config_home/$config_suffix"
  fi
  [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" != "leak" ] || exit 0
  if [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "assertion-then-success" ]; then
    sequence_file="${CMUX_MOCK_XCODEBUILD_SEQUENCE_FILE:?missing mock sequence file}"
    sequence_attempt=1
    if [ -r "$sequence_file" ]; then
      sequence_attempt=$(( $(cat "$sequence_file") + 1 ))
    fi
    printf '%s\n' "$sequence_attempt" >"$sequence_file"
    if [ "$sequence_attempt" -eq 1 ]; then
      echo "Test Suite 'Selected tests' started at 2026-09-21 00:00:00."
      echo "Test Case '-[cmuxTests.ExampleTests testExample]' started."
      echo "/tmp/ExampleTests.swift:1: error: -[cmuxTests.ExampleTests testExample] : XCTAssertTrue failed"
      echo "Executed 1 test, with 1 failure (0 unexpected)"
      echo "Failed to establish communication with the test runner"
      exit 65
    fi
    echo 'cmux DEV message = "socket.listener.start"'
    echo "Executed 1 test, with 0 failures (0 unexpected)"
    exit 0
  fi
  if [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "startup-hang" ]; then
    # testmanagerd refused xcodebuild's channel: the host launched, and no
    # test ever starts.
    echo 'cmux DEV message = "socket.listener.start"'
    echo "Testing started"
    sleep 30
    exit 0
  fi
  if [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "crash-loop" ]; then
    # xcodebuild relaunching an app host that crashes on contact: the run is
    # resumed after every crash and never ends on its own.
    echo 'cmux DEV message = "socket.listener.start"'
    for _ in 1 2 3 4 5 6 7 8; do
      echo "Test Case '-[cmuxTests.ExampleTests testExample]' started."
      echo "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches."
      sleep 0.2
    done
    sleep 600
    exit 0
  fi
  if [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "success" ] \
    || [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "xdg-config-leak" ] \
    || [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "xdg-default-leak" ] \
    || [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "unrelated-config-token" ] \
    || [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "no-config-evidence" ] \
    || [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "published-default-alias" ] \
    || [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "published-config-alias" ] \
    || [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "published-default-sibling-leak" ] \
    || [ "${CMUX_MOCK_XCODEBUILD_MODE:-timeout}" = "published-config-sibling-leak" ]; then
    echo 'cmux DEV message = "socket.listener.start"'
    exit 0
  fi
  sleep 10
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
APP_HOST_HOME=""
APP_HOST_RECEIPT_DIR=""
APP_HOST_CONFIRMATION_FILE=""
cleanup() {
  [ -z "$APP_HOST_HOME" ] || rm -rf -- "$APP_HOST_HOME"
  [ -z "$APP_HOST_RECEIPT_DIR" ] || rm -rf -- "$APP_HOST_RECEIPT_DIR"
  [ -z "$APP_HOST_CONFIRMATION_FILE" ] || rm -f -- "$APP_HOST_CONFIRMATION_FILE"
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

ln -s "$ROOT_DIR/tests/test_ci_app_host_xcodebuild_retry.sh" "$TMP_DIR/xcodebuild"
ln -s "$ROOT_DIR/tests/test_ci_app_host_xcodebuild_retry.sh" "$TMP_DIR/fake-lsof"
ln -s "$ROOT_DIR/tests/test_ci_app_host_xcodebuild_retry.sh" "$TMP_DIR/launchctl"
ln -s "$ROOT_DIR/tests/test_ci_app_host_xcodebuild_retry.sh" "$TMP_DIR/pgrep"
BASH32_BIN_DIR="$TMP_DIR/bash32-bin"
mkdir -p "$BASH32_BIN_DIR"
ln -s /bin/bash "$BASH32_BIN_DIR/bash"

RUNNER_TEMP_DIR="$TMP_DIR/runner-temp"
export RUNNER_TEMP="$RUNNER_TEMP_DIR"
export GITHUB_ENV="$TMP_DIR/github-env"
export GITHUB_REPOSITORY_ID=1234567
export GITHUB_RUN_ID="910000$$"
export GITHUB_RUN_ATTEMPT="2"
export CMUX_APP_HOST_SHARD="4"
export CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER=1
export CMUX_APP_HOST_LSOF="$TMP_DIR/fake-lsof"
mkdir -p "$RUNNER_TEMP_DIR"
export CMUX_DERIVED_DATA_PATH="$RUNNER_TEMP_DIR/cmux-derived-data-tests-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-shard-$CMUX_APP_HOST_SHARD"
mkdir -p "$CMUX_DERIVED_DATA_PATH"
: > "$GITHUB_ENV"
bash "$ROOT_DIR/scripts/ci/prepare-app-host-home.sh"
set -a
# shellcheck disable=SC1090
source "$GITHUB_ENV"
set +a
APP_HOST_HOME="$CMUX_APP_HOST_HOME"
APP_HOST_XDG_CONFIG_HOME="$CMUX_APP_HOST_XDG_CONFIG_HOME"
APP_HOST_RECEIPT_DIR="$CMUX_APP_HOST_RECEIPT_DIR"
APP_HOST_CONFIRMATION_FILE="$CMUX_APP_HOST_CONFIRMATION_FILE"
XCODE_PARENT_FIXED_HOME="$TMP_DIR/xcode-parent-fixed-home"
XCODE_PARENT_XDG_CONFIG_HOME="$TMP_DIR/xcode-parent-xdg"
mkdir -p \
  "$APP_HOST_XDG_CONFIG_HOME" \
  "$XCODE_PARENT_FIXED_HOME" \
  "$XCODE_PARENT_XDG_CONFIG_HOME"
RESOLVED_APP_HOST_HOME="$(cd "$APP_HOST_HOME" && pwd -P)"
RESOLVED_APP_HOST_XDG_CONFIG_HOME="$(cd "$APP_HOST_XDG_CONFIG_HOME" && pwd -P)"

set +e
/usr/bin/env -u CMUX_APP_HOST_HOME -u CMUX_APP_HOST_XDG_CONFIG_HOME \
  -u CFFIXED_USER_HOME -u XDG_CONFIG_HOME \
  -u TEST_RUNNER_CI -u TEST_RUNNER_GITHUB_ACTIONS \
  CI=true GITHUB_ACTIONS=true \
  PATH="$BASH32_BIN_DIR:$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/non-isolated-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/non-isolated-test-runner-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_CI_ENV="$TMP_DIR/non-isolated-ci-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/non-isolated-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/non-isolated-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE=success \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  /bin/bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
    >"$TMP_DIR/non-isolated-output.log" 2>&1
non_isolated_status=$?
set -e

if [ "$non_isolated_status" -ne 0 ] \
  || [ "$(grep -cx 'test' "$TMP_DIR/non-isolated-xcodebuild-args.log" 2>/dev/null || true)" -ne 1 ]; then
  cat "$TMP_DIR/non-isolated-output.log"
  echo "FAIL: macOS Bash 3.2 must launch xcodebuild when isolation is disabled"
  exit 1
fi

if ! grep -Fxq 'true|true' "$TMP_DIR/non-isolated-ci-env.log"; then
  cat "$TMP_DIR/non-isolated-ci-env.log"
  echo "FAIL: CI identity must reach the app host through Xcode's TEST_RUNNER_ channel"
  exit 1
fi

AMBIENT_XDG_CONFIG_HOME="$TMP_DIR/ambient-xdg"
mkdir -p "$AMBIENT_XDG_CONFIG_HOME"
set +e
/usr/bin/env -u CMUX_APP_HOST_HOME -u CMUX_APP_HOST_XDG_CONFIG_HOME \
  -u CFFIXED_USER_HOME \
  -u CI -u GITHUB_ACTIONS -u TEST_RUNNER_CI -u TEST_RUNNER_GITHUB_ACTIONS \
  PATH="$BASH32_BIN_DIR:$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  XDG_CONFIG_HOME="$AMBIENT_XDG_CONFIG_HOME" \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/ambient-xdg-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/ambient-xdg-test-runner-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_CI_ENV="$TMP_DIR/ambient-xdg-ci-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/ambient-xdg-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/ambient-xdg-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE=success \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  /bin/bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
    >"$TMP_DIR/ambient-xdg-output.log" 2>&1
ambient_xdg_status=$?
set -e

if ! grep -Fxq '<unset>|<unset>' "$TMP_DIR/ambient-xdg-ci-env.log"; then
  cat "$TMP_DIR/ambient-xdg-ci-env.log"
  echo "FAIL: local app-host launches must not acquire CI identity"
  exit 1
fi

if [ "$ambient_xdg_status" -ne 0 ] \
  || [ "$(grep -cx 'test' "$TMP_DIR/ambient-xdg-xcodebuild-args.log" 2>/dev/null || true)" -ne 1 ] \
  || ! awk -F '|' -v xdg="$AMBIENT_XDG_CONFIG_HOME" '
    $2 == "<unset>" && $3 == xdg { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$TMP_DIR/ambient-xdg-parent-env.log"; then
  cat "$TMP_DIR/ambient-xdg-output.log"
  cat "$TMP_DIR/ambient-xdg-parent-env.log" 2>/dev/null || true
  echo "FAIL: ordinary XDG_CONFIG_HOME must remain a non-isolated xcodebuild input"
  exit 1
fi

set +e
/usr/bin/env -u CMUX_APP_HOST_HOME -u CMUX_APP_HOST_XDG_CONFIG_HOME \
  -u CFFIXED_USER_HOME -u XDG_CONFIG_HOME \
  PATH="$BASH32_BIN_DIR:$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/missing-isolation-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/missing-isolation-test-runner-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/missing-isolation-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/missing-isolation-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE=success \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  /bin/bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
    >"$TMP_DIR/missing-isolation-output.log" 2>&1
missing_isolation_status=$?
set -e

if [ "$missing_isolation_status" -ne 1 ] \
  || ! grep -Fq \
    "FAIL: required app-host isolation environment is incomplete" \
    "$TMP_DIR/missing-isolation-output.log" \
  || [ -s "$TMP_DIR/missing-isolation-xcodebuild-args.log" ]; then
  cat "$TMP_DIR/missing-isolation-output.log"
  echo "FAIL: mandatory isolation must reject missing redirects before xcodebuild"
  exit 1
fi

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/xcodebuild-args.log" \
CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/test-runner-env.log" \
CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/xcodebuild-parent-env.log" \
CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/test-runner-home-env.log" \
CMUX_CAPTURE_TEST_RUNNER_TOOL_ENV="$TMP_DIR/test-runner-tool-env.log" \
CMUX_MOCK_XCODEBUILD_PROCESS=1 \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=2 \
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=0.1 \
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
CMUX_APP_HOST_HOME="$APP_HOST_HOME" \
CMUX_APP_HOST_XDG_CONFIG_HOME="$APP_HOST_XDG_CONFIG_HOME" \
TEST_RUNNER_PATH="/ci/node/bin:/usr/bin" \
TEST_RUNNER_BUN_INSTALL="/ci/bun" \
CFFIXED_USER_HOME="$XCODE_PARENT_FIXED_HOME" \
XDG_CONFIG_HOME="$XCODE_PARENT_XDG_CONFIG_HOME" \
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

if [ "$(grep -Fxc -- '-test-timeouts-enabled' "$TMP_DIR/xcodebuild-args.log" || true)" -ne "$invocation_count" ] \
  || [ "$(grep -Fxc -- '-default-test-execution-time-allowance' "$TMP_DIR/xcodebuild-args.log" || true)" -ne "$invocation_count" ] \
  || [ "$(grep -Fxc -- '-maximum-test-execution-time-allowance' "$TMP_DIR/xcodebuild-args.log" || true)" -ne "$invocation_count" ]; then
  cat "$TMP_DIR/xcodebuild-args.log"
  echo "FAIL: every app-host launch must carry an explicit per-test execution allowance"
  exit 1
fi

if [ "$(grep -Fxc '/ci/node/bin:/usr/bin|/ci/bun' "$TMP_DIR/test-runner-tool-env.log" || true)" -ne "$invocation_count" ]; then
  cat "$TMP_DIR/test-runner-tool-env.log"
  echo "FAIL: focused test-runner tool paths must reach every app-host launch"
  exit 1
fi

isolated_parent_count="$(awk -F '|' -v isolated="$APP_HOST_HOME" '
  $1 == isolated { count += 1 }
  END { print count + 0 }
' "$TMP_DIR/xcodebuild-parent-env.log")"
wrong_parent_configuration_count="$(awk -F '|' \
  -v fixed="$XCODE_PARENT_FIXED_HOME" \
  -v xdg="$XCODE_PARENT_XDG_CONFIG_HOME" '
  $2 != fixed || $3 != xdg { count += 1 }
  END { print count + 0 }
' "$TMP_DIR/xcodebuild-parent-env.log")"
if [ "$isolated_parent_count" -ne 0 ] \
  || [ "$wrong_parent_configuration_count" -ne 0 ]; then
  cat "$TMP_DIR/xcodebuild-parent-env.log"
  echo "FAIL: xcodebuild must retain its real HOME and configuration redirects"
  exit 1
fi

compiled_assertion_count="$(grep -Fxc \
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED" \
  "$TMP_DIR/xcodebuild-args.log" || true)"
if [ "$compiled_assertion_count" -ne "$invocation_count" ]; then
  cat "$TMP_DIR/xcodebuild-args.log"
  echo "FAIL: every required launch must compile an independent isolation assertion"
  exit 1
fi

isolated_runner_count="$(awk -F '|' \
  -v home="$RESOLVED_APP_HOST_HOME" \
  -v xdg="$RESOLVED_APP_HOST_XDG_CONFIG_HOME" \
  -v key="$CMUX_APP_HOST_KEY" \
  -v receipts="$CMUX_APP_HOST_RECEIPT_DIR" '
  $1 == home && $2 == home && $3 == xdg && $4 == "" && $5 == "1" && $6 == home && $7 == xdg && $8 == key && $9 == receipts {
    count += 1
  }
  END { print count + 0 }
' "$TMP_DIR/test-runner-home-env.log")"
if [ "$isolated_runner_count" -ne "$invocation_count" ]; then
  cat "$TMP_DIR/test-runner-home-env.log"
  echo "FAIL: every xcodebuild invocation must pass isolated homes through TEST_RUNNER_ variables"
  exit 1
fi

for published_alias_evidence in published-default-alias published-config-alias; do
  set +e
  PATH="$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/$published_alias_evidence-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/$published_alias_evidence-test-runner-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/$published_alias_evidence-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/$published_alias_evidence-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE="$published_alias_evidence" \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
  CMUX_APP_HOST_HOME="$APP_HOST_HOME" \
  CMUX_APP_HOST_XDG_CONFIG_HOME="$APP_HOST_XDG_CONFIG_HOME" \
    bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
      >"$TMP_DIR/$published_alias_evidence-output.log" 2>&1
  published_alias_evidence_status=$?
  set -e

  if [ "$published_alias_evidence_status" -ne 0 ]; then
    cat "$TMP_DIR/$published_alias_evidence-output.log"
    echo "FAIL: wrapper must accept $published_alias_evidence"
    exit 1
  fi
done

for evidence_regression in no-config-evidence unrelated-config-token; do
  set +e
  PATH="$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/$evidence_regression-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/$evidence_regression-test-runner-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/$evidence_regression-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/$evidence_regression-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE="$evidence_regression" \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
  CMUX_APP_HOST_HOME="$APP_HOST_HOME" \
  CMUX_APP_HOST_XDG_CONFIG_HOME="$APP_HOST_XDG_CONFIG_HOME" \
    bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
      >"$TMP_DIR/$evidence_regression-output.log" 2>&1
  evidence_regression_status=$?
  set -e

  if [ "$evidence_regression_status" -ne 1 ] || ! grep -Fq \
    "FAIL: app-host configuration evidence is missing" \
    "$TMP_DIR/$evidence_regression-output.log"; then
    cat "$TMP_DIR/$evidence_regression-output.log"
    echo "FAIL: wrapper must reject $evidence_regression"
    exit 1
  fi
done

EXTERNAL_XDG_CONFIG_HOME="$TMP_DIR/external-xdg"
mkdir -p "$EXTERNAL_XDG_CONFIG_HOME"
set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/external-xdg-xcodebuild-args.log" \
CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/external-xdg-test-runner-env.log" \
CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/external-xdg-parent-env.log" \
CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/external-xdg-runner-home-env.log" \
CMUX_MOCK_XCODEBUILD_PROCESS=1 \
CMUX_MOCK_XCODEBUILD_MODE=leak \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
CMUX_APP_HOST_HOME="$APP_HOST_HOME" \
CMUX_APP_HOST_XDG_CONFIG_HOME="$EXTERNAL_XDG_CONFIG_HOME" \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
    >"$TMP_DIR/external-xdg-output.log" 2>&1
external_xdg_status=$?
set -e

if [ "$external_xdg_status" -ne 1 ] \
  || ! grep -Fq \
    "FAIL: published CMUX_APP_HOST_XDG_CONFIG_HOME does not match the run identity" \
    "$TMP_DIR/external-xdg-output.log" \
  || [ -s "$TMP_DIR/external-xdg-xcodebuild-args.log" ]; then
  cat "$TMP_DIR/external-xdg-output.log"
  echo "FAIL: wrapper must reject external XDG configuration before xcodebuild"
  exit 1
fi

set +e
PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$RUNNER_TEMP_DIR" \
CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/leak-xcodebuild-args.log" \
CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/leak-test-runner-env.log" \
CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/leak-xcodebuild-parent-env.log" \
CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/leak-test-runner-home-env.log" \
CMUX_MOCK_XCODEBUILD_PROCESS=1 \
CMUX_MOCK_XCODEBUILD_MODE=leak \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
CMUX_APP_HOST_HOME="$APP_HOST_HOME" \
CMUX_APP_HOST_XDG_CONFIG_HOME="$APP_HOST_XDG_CONFIG_HOME" \
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

for xdg_leak in xdg-config-leak xdg-default-leak; do
  set +e
  PATH="$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/$xdg_leak-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/$xdg_leak-test-runner-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/$xdg_leak-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/$xdg_leak-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE="$xdg_leak" \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
  CMUX_APP_HOST_HOME="$APP_HOST_HOME" \
  CMUX_APP_HOST_XDG_CONFIG_HOME="$APP_HOST_XDG_CONFIG_HOME" \
    bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
      >"$TMP_DIR/$xdg_leak-output.log" 2>&1
  xdg_leak_status=$?
  set -e

  if [ "$xdg_leak_status" -ne 1 ] || ! grep -Fq \
    "FAIL: Ghostty accessed configuration outside the isolated app-host home" \
    "$TMP_DIR/$xdg_leak-output.log"; then
    cat "$TMP_DIR/$xdg_leak-output.log"
    echo "FAIL: wrapper must reject $xdg_leak outside the isolated home"
    exit 1
  fi
done

for regression in \
  sibling-leak \
  published-default-sibling-leak \
  published-config-sibling-leak \
  missing-log; do
  case "$regression" in
    *sibling-leak)
      expected_failure="FAIL: Ghostty accessed configuration outside the isolated app-host home"
      ;;
    missing-log)
      expected_failure="FAIL: app-host configuration log could not be scanned"
      ;;
  esac

  set +e
  PATH="$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/$regression-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/$regression-test-runner-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/$regression-xcodebuild-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/$regression-test-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE="$regression" \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
  CMUX_APP_HOST_HOME="$APP_HOST_HOME" \
  CMUX_APP_HOST_XDG_CONFIG_HOME="$APP_HOST_XDG_CONFIG_HOME" \
    bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
      >"$TMP_DIR/$regression-output.log" 2>&1
  regression_status=$?
  set -e

  if [ "$regression_status" -ne 1 ] || ! grep -Fq \
    "$expected_failure" "$TMP_DIR/$regression-output.log"; then
    cat "$TMP_DIR/$regression-output.log"
    echo "FAIL: wrapper must reject $regression app-host validation"
    exit 1
  fi
done

# A caller-supplied maximum allowance is authoritative. The wrapper may fill
# the missing enable/default options, but it must not append a later maximum.
set +e
/usr/bin/env -u CMUX_APP_HOST_HOME -u CMUX_APP_HOST_XDG_CONFIG_HOME \
  -u CFFIXED_USER_HOME -u XDG_CONFIG_HOME \
  PATH="$BASH32_BIN_DIR:$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/caller-timeout-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/caller-timeout-test-runner-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/caller-timeout-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/caller-timeout-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE=success \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=1 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  /bin/bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" \
    test -maximum-test-execution-time-allowance 120 \
    >"$TMP_DIR/caller-timeout-output.log" 2>&1
caller_timeout_status=$?
set -e

if [ "$caller_timeout_status" -ne 0 ] \
  || [ "$(grep -Fxc -- '-maximum-test-execution-time-allowance' "$TMP_DIR/caller-timeout-xcodebuild-args.log" || true)" -ne 1 ] \
  || ! awk '
    previous == "-maximum-test-execution-time-allowance" && $0 == "120" { found = 1 }
    { previous = $0 }
    END { exit found ? 0 : 1 }
  ' "$TMP_DIR/caller-timeout-xcodebuild-args.log"; then
  cat "$TMP_DIR/caller-timeout-output.log"
  cat "$TMP_DIR/caller-timeout-xcodebuild-args.log" 2>/dev/null || true
  echo "FAIL: wrapper must preserve the caller-supplied maximum test allowance"
  exit 1
fi

set +e
/usr/bin/env -u CMUX_APP_HOST_HOME -u CMUX_APP_HOST_XDG_CONFIG_HOME \
  -u CFFIXED_USER_HOME -u XDG_CONFIG_HOME \
  PATH="$BASH32_BIN_DIR:$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_TAG=sticky-retry \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/sticky-retry-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/sticky-retry-test-runner-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/sticky-retry-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/sticky-retry-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE=assertion-then-success \
  CMUX_MOCK_XCODEBUILD_SEQUENCE_FILE="$TMP_DIR/sticky-retry-sequence" \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=2 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=5 \
  /bin/bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
    >"$TMP_DIR/sticky-retry-output.log" 2>&1
sticky_retry_status=$?
set -e

if [ "$sticky_retry_status" -ne 65 ]; then
  cat "$TMP_DIR/sticky-retry-output.log"
  echo "FAIL: an assertion-bearing attempt must remain red, got $sticky_retry_status"
  exit 1
fi
if [ "$(cat "$TMP_DIR/sticky-retry-sequence")" -ne 1 ]; then
  cat "$TMP_DIR/sticky-retry-output.log"
  echo "FAIL: wrapper launched a later green attempt after test execution"
  exit 1
fi
if grep -Fq "Retrying app-host xcodebuild after" "$TMP_DIR/sticky-retry-output.log" \
  || ! grep -Fq "retry blocked after test execution evidence" "$TMP_DIR/sticky-retry-output.log"; then
  cat "$TMP_DIR/sticky-retry-output.log"
  echo "FAIL: sticky failure retry decision was not reported"
  exit 1
fi
metadata_path="$(find "$RUNNER_TEMP_DIR" -maxdepth 1 \
  -name 'cmux-app-host-xcodebuild-sticky-retry-pid-*-attempt-1.meta' -print -quit)"
if [ -z "$metadata_path" ] || ! grep -Fxq "attempt=1" "$metadata_path" \
  || ! grep -Fxq "arg=test" "$metadata_path" \
  || ! grep -Fxq "exit_status=65" "$metadata_path"; then
  cat "${metadata_path:-/dev/null}" 2>/dev/null || true
  echo "FAIL: wrapper must retain per-invocation attempt metadata"
  exit 1
fi
if find "$RUNNER_TEMP_DIR" -maxdepth 1 \
  -name 'cmux-app-host-xcodebuild-sticky-retry-pid-*-attempt-2.meta' -print -quit \
  | grep -q .; then
  echo "FAIL: blocked retry created a second attempt artifact"
  exit 1
fi
if find "$RUNNER_TEMP_DIR" -maxdepth 1 -name 'cmux-app-host-xcodebuild-*-pid-$-*' -print -quit \
  | grep -q .; then
  echo "FAIL: per-invocation artifact stem contains a literal dollar sign instead of the process id"
  exit 1
fi

# A crash-looping app host must abort the invocation once its restart budget
# is spent, and must not be retried: each attempt would loop again and spend
# the same runner time. https://github.com/manaflow-ai/cmux/issues/13707
set +e
/usr/bin/env -u CMUX_APP_HOST_HOME -u CMUX_APP_HOST_XDG_CONFIG_HOME \
  -u CFFIXED_USER_HOME -u XDG_CONFIG_HOME \
  PATH="$BASH32_BIN_DIR:$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_TAG=crash-loop \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/crash-loop-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/crash-loop-test-runner-env.log" \
  CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/crash-loop-parent-env.log" \
  CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/crash-loop-runner-home-env.log" \
  CMUX_MOCK_XCODEBUILD_PROCESS=1 \
  CMUX_MOCK_XCODEBUILD_MODE=crash-loop \
  CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=3 \
  CMUX_XCODEBUILD_NONINTERACTIVE_RESTART_BUDGET=2 \
  CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=60 \
  /bin/bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
    >"$TMP_DIR/crash-loop-output.log" 2>&1
crash_loop_status=$?
set -e

if [ "$crash_loop_status" -ne 123 ]; then
  cat "$TMP_DIR/crash-loop-output.log"
  echo "FAIL: expected restart-budget abort status 123, got $crash_loop_status"
  exit 1
fi
if ! grep -Fq "Aborted by the app-host restart budget" "$TMP_DIR/crash-loop-output.log"; then
  cat "$TMP_DIR/crash-loop-output.log"
  echo "FAIL: restart-budget abort did not explain itself in the job log"
  exit 1
fi
if ! grep -Fq "App-host restart budget exceeded on attempt 1/3; not retrying" \
  "$TMP_DIR/crash-loop-output.log"; then
  cat "$TMP_DIR/crash-loop-output.log"
  echo "FAIL: wrapper did not report that it declined to retry a crash loop"
  exit 1
fi
if [ "$(grep -cx 'test' "$TMP_DIR/crash-loop-xcodebuild-args.log")" -ne 1 ]; then
  cat "$TMP_DIR/crash-loop-output.log"
  echo "FAIL: wrapper retried a crash loop instead of stopping after one attempt"
  exit 1
fi

# A runner that never connects is cut at the startup deadline, retried once
# after a testmanagerd restart, then reported as a runner fault. A single-attempt
# caller gets the fault on its only hang, and another user's live xcodebuild
# test keeps testmanagerd from being restarted under it.
run_startup_hang() {
  local name="$1" attempts="$2" pgrep_pids="${3:-}"
  set +e
  /usr/bin/env -u CMUX_APP_HOST_HOME -u CMUX_APP_HOST_XDG_CONFIG_HOME \
    -u CFFIXED_USER_HOME -u XDG_CONFIG_HOME \
    PATH="$BASH32_BIN_DIR:$TMP_DIR:$PATH" \
    RUNNER_TEMP="$RUNNER_TEMP_DIR" \
    RUNNER_NAME=fake-mini-glaeda-1 \
    CMUX_TAG="$name" \
    CMUX_CAPTURE_LAUNCHCTL="$TMP_DIR/$name-launchctl.log" \
    CMUX_FAKE_PGREP_PIDS="$pgrep_pids" \
    CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/$name-xcodebuild-args.log" \
    CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/$name-test-runner-env.log" \
    CMUX_CAPTURE_XCODEBUILD_PARENT_ENV="$TMP_DIR/$name-parent-env.log" \
    CMUX_CAPTURE_TEST_RUNNER_HOME_ENV="$TMP_DIR/$name-runner-home-env.log" \
    CMUX_MOCK_XCODEBUILD_PROCESS=1 \
    CMUX_MOCK_XCODEBUILD_MODE=startup-hang \
    CMUX_APP_HOST_XCODEBUILD_ATTEMPTS="$attempts" \
    CMUX_XCODEBUILD_NONINTERACTIVE_STARTUP_TIMEOUT_SECONDS=0.5 \
    CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=60 \
    /bin/bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test \
      >"$TMP_DIR/$name-output.log" 2>&1
  startup_status=$?
  set -e
  : >> "$TMP_DIR/$name-launchctl.log"
}
fail_startup() {
  cat "$TMP_DIR/$1-output.log"
  echo "FAIL: $2"
  exit 1
}

run_startup_hang startup-hang 3
[ "$startup_status" -eq 122 ] || fail_startup startup-hang "expected startup-hang status 122, got $startup_status"
[ "$(grep -cx 'test' "$TMP_DIR/startup-hang-xcodebuild-args.log")" -eq 2 ] \
  || fail_startup startup-hang "a startup hang must be retried exactly once"
[ "$(grep -c "^kickstart -k gui/$(id -u)/com.apple.testmanagerd\$" "$TMP_DIR/startup-hang-launchctl.log")" -eq 1 ] \
  || fail_startup startup-hang "testmanagerd must be restarted once, before the retry"
grep -Fq "App-host runner fault::fake-mini-glaeda-1: the XCTest runner never connected in 2 launch(es)" \
  "$TMP_DIR/startup-hang-output.log" \
  || fail_startup startup-hang "second startup hang must report a runner fault"

run_startup_hang startup-hang-single 1
[ "$startup_status" -eq 122 ] || fail_startup startup-hang-single "expected status 122, got $startup_status"
[ "$(grep -cx 'test' "$TMP_DIR/startup-hang-single-xcodebuild-args.log")" -eq 1 ] \
  || fail_startup startup-hang-single "a single-attempt caller must not retry"
[ ! -s "$TMP_DIR/startup-hang-single-launchctl.log" ] \
  || fail_startup startup-hang-single "no retry means no testmanagerd restart"
grep -Fq "App-host runner fault::fake-mini-glaeda-1" "$TMP_DIR/startup-hang-single-output.log" \
  || fail_startup startup-hang-single "a single-attempt startup hang must report a runner fault"

bash -c 'exec -a "xcodebuild test-without-building -xctestrun other" sleep 30' &
other_xcodebuild=$!
run_startup_hang startup-hang-shared 3 "$other_xcodebuild"
kill "$other_xcodebuild" 2>/dev/null || true
wait "$other_xcodebuild" 2>/dev/null || true
[ ! -s "$TMP_DIR/startup-hang-shared-launchctl.log" ] \
  || fail_startup startup-hang-shared "testmanagerd must not restart under another live xcodebuild test"
grep -Fq "Not restarting testmanagerd: xcodebuild $other_xcodebuild is running tests" \
  "$TMP_DIR/startup-hang-shared-output.log" \
  || fail_startup startup-hang-shared "skipped restart must explain itself"

echo "PASS: app-host xcodebuild wrapper retries only before test execution, aborts a crash loop without retrying, and fails a startup hang as a runner fault after one testmanagerd restart"
