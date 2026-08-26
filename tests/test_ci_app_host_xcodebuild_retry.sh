#!/usr/bin/env bash
set -euo pipefail

if [ "$(basename "$0")" = "fake-lsof" ]; then
  exit 0
fi

if [ "${CMUX_MOCK_XCODEBUILD_PROCESS:-0}" = "1" ]; then
  printf '%s\n' "$@" >> "$CMUX_CAPTURE_XCODEBUILD_ARGS"
  printf '%s\n' "${TEST_RUNNER_CMUX_TEST_PROCESS:-<unset>}" >> "$CMUX_CAPTURE_TEST_RUNNER_ENV"
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
  PATH="$BASH32_BIN_DIR:$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/non-isolated-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/non-isolated-test-runner-env.log" \
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

AMBIENT_XDG_CONFIG_HOME="$TMP_DIR/ambient-xdg"
mkdir -p "$AMBIENT_XDG_CONFIG_HOME"
set +e
/usr/bin/env -u CMUX_APP_HOST_HOME -u CMUX_APP_HOST_XDG_CONFIG_HOME \
  -u CFFIXED_USER_HOME \
  PATH="$BASH32_BIN_DIR:$TMP_DIR:$PATH" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  XDG_CONFIG_HOME="$AMBIENT_XDG_CONFIG_HOME" \
  CMUX_CAPTURE_XCODEBUILD_ARGS="$TMP_DIR/ambient-xdg-xcodebuild-args.log" \
  CMUX_CAPTURE_TEST_RUNNER_ENV="$TMP_DIR/ambient-xdg-test-runner-env.log" \
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
CMUX_MOCK_XCODEBUILD_PROCESS=1 \
CMUX_APP_HOST_XCODEBUILD_ATTEMPTS=2 \
CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS=0.1 \
CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1 \
CMUX_APP_HOST_HOME="$APP_HOST_HOME" \
CMUX_APP_HOST_XDG_CONFIG_HOME="$APP_HOST_XDG_CONFIG_HOME" \
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

echo "PASS: app-host xcodebuild wrapper retries idle timeouts"
