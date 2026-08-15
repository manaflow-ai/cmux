#!/usr/bin/env bash
set -euo pipefail

ci_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/app-host-isolation.sh
source "$ci_script_dir/app-host-isolation.sh"
# shellcheck source=scripts/ci/app-host-processes.sh
source "$ci_script_dir/app-host-processes.sh"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <xcodebuild args...>" >&2
  exit 2
fi
log_dir="${RUNNER_TEMP:-/tmp}"
log_stem="${log_dir%/}/cmux-app-host-xcodebuild-${CMUX_TAG:-untagged}"
max_attempts="${CMUX_APP_HOST_XCODEBUILD_ATTEMPTS:-3}"
total_timeout_seconds="${CMUX_APP_HOST_XCODEBUILD_TOTAL_TIMEOUT_SECONDS:-}"
case "$total_timeout_seconds" in
  '') ;;
  *[!0-9]*|0*)
    echo "FAIL: CMUX_APP_HOST_XCODEBUILD_TOTAL_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
    ;;
  *) ;;
esac
export CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS="${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS:-${CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_SECONDS:-300}}"
echo "App-host xcodebuild idle timeout: ${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS}s, attempts: ${max_attempts}"
if [ -n "$total_timeout_seconds" ]; then
  echo "App-host xcodebuild total timeout: ${total_timeout_seconds}s"
fi

# Principled serialization (the actual fix; the retry below is only a backstop).
# Invariant: a GUI test host owns the Mac's single login session + testmanagerd
# while it runs. Two hosts on one self-hosted Mac contend for that one session
# and drop the test-runner channel. Enforce one app-host test at a time PER
# MACHINE with a real kernel lock (fcntl.flock via app_host_test_lock.py): the
# kernel releases it automatically when the holder exits, even on crash, so there
# is no stale lock to detect and no recovery race. The lock helper runs this
# script as its child and retains the lock for the child's whole lifetime.
# Different machines use different local lock files, so cross-machine
# parallelism is preserved.
if [ -z "${CMUX_APP_HOST_TEST_LOCK_ACTIVE:-}" ]; then
  app_host_lock_root="$(cd /tmp 2>/dev/null && pwd -P)" || {
    echo "FAIL: canonical app-host lock root is unavailable" >&2
    exit 1
  }
  if [ "${CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER:-0}" = "1" ]; then
    lock_file="${CMUX_APP_HOST_TEST_LOCK_FILE:-${RUNNER_TEMP:-$app_host_lock_root}/cmux-app-host-test.lock}"
  else
    lock_file="${app_host_lock_root%/}/cmux-app-host-test.lock"
  fi
  lock_wait_seconds="${CMUX_APP_HOST_TEST_LOCK_WAIT_SECONDS:-3600}"
  export CMUX_APP_HOST_TEST_LOCK_ACTIVE=1
  exec python3 "$(dirname "$0")/app_host_test_lock.py" \
    "$lock_file" "$lock_wait_seconds" "$0" "$@"
fi

# Keep one elapsed-time execution budget across all xcodebuild attempts. The
# lock helper owns queue admission separately; after it acquires the lock, this
# wrapper starts the full budget and carries its remaining time through retries.
app_host_total_deadline_seconds=""
if [ -n "$total_timeout_seconds" ]; then
  app_host_total_deadline_seconds=$((SECONDS + total_timeout_seconds))
fi

# xcodebuild must retain the console user's real HOME so Xcode and its package
# toolchains remain available. Capture isolation only after the lock re-exec,
# then pass it through Xcode's TEST_RUNNER_ environment channel. Xcode strips
# that prefix when it launches the test runner, so the app host receives the
# redirects without exposing them to the xcodebuild driver.
app_host_test_runner_environment=("TEST_RUNNER_CMUX_TEST_PROCESS=1")
app_host_home=""
app_host_key=""
app_host_receipt_dir=""
app_host_home_input="${CMUX_APP_HOST_HOME:-}"
app_host_xdg_config_home_input="${CMUX_APP_HOST_XDG_CONFIG_HOME:-}"
if [ "${CMUX_CI_APP_HOST_ISOLATION_REQUIRED:-0}" = "1" ]; then
  if [ -z "$app_host_home_input" ] \
    || [ -z "$app_host_xdg_config_home_input" ] \
    || [ -z "${CMUX_APP_HOST_KEY:-}" ] \
    || [ -z "${CMUX_APP_HOST_RECEIPT_DIR:-}" ] \
    || [ -z "${CMUX_APP_HOST_CLEANUP_CONFIRMATION:-}" ] \
    || [ -z "${CMUX_APP_HOST_CONFIRMATION_FILE:-}" ]; then
    echo "FAIL: required app-host isolation environment is incomplete" >&2
    exit 1
  fi
fi
if { [ -n "$app_host_home_input" ] && [ -z "$app_host_xdg_config_home_input" ]; } \
  || { [ -z "$app_host_home_input" ] && [ -n "$app_host_xdg_config_home_input" ]; }; then
  echo "FAIL: app-host isolation environment is incomplete" >&2
  exit 1
fi
if [ -n "$app_host_home_input" ]; then
  cmux_validate_published_app_host_identity || exit 1
  app_host_home="$CMUX_RESOLVED_APP_HOST_HOME"
  app_host_xdg_config_home="$CMUX_RESOLVED_APP_HOST_XDG_CONFIG_HOME"
  app_host_key="$CMUX_RESOLVED_APP_HOST_KEY"
  app_host_receipt_dir="$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR"
  app_host_test_runner_environment+=(
    "TEST_RUNNER_HOME=$app_host_home"
    "TEST_RUNNER_CFFIXED_USER_HOME=$app_host_home"
    "TEST_RUNNER_XDG_CONFIG_HOME=$app_host_xdg_config_home"
    "TEST_RUNNER_SSH_AUTH_SOCK="
    "TEST_RUNNER_CMUX_APP_HOST_ISOLATION_REQUIRED=1"
    "TEST_RUNNER_CMUX_APP_HOST_EXPECTED_HOME=$app_host_home"
    "TEST_RUNNER_CMUX_APP_HOST_EXPECTED_XDG_CONFIG_HOME=$app_host_xdg_config_home"
    "TEST_RUNNER_CMUX_APP_HOST_RECEIPT_DIR=$app_host_receipt_dir"
    "TEST_RUNNER_CMUX_APP_HOST_KEY=$app_host_key"
  )
  app_host_test_runner_environment+=(
    "CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_CLEANUP_COMMAND=$ci_script_dir/cleanup-owned-app-host-attempt.sh"
  )
fi

app_host_xcodebuild_arguments=("$@")
# One xcodebuild can still run Swift Testing functions concurrently inside its
# app host. Those functions share AppKit, Ghostty, sockets, and process-global
# registries, so the per-Mac process lock above is not sufficient. Make serial
# execution an invariant of this app-host boundary. Reject a conflicting caller
# value instead of allowing one focused workflow step to reopen the race.
parallel_testing_seen=0
parallel_testing_needs_value=0
for argument in "${app_host_xcodebuild_arguments[@]}"; do
  if [ "$parallel_testing_needs_value" -eq 1 ]; then
    if [ "$argument" != "NO" ]; then
      echo "FAIL: app-host tests require -parallel-testing-enabled NO" >&2
      exit 2
    fi
    parallel_testing_needs_value=0
    continue
  fi

  if [ "$argument" = "-parallel-testing-enabled" ]; then
    if [ "$parallel_testing_seen" -eq 1 ]; then
      echo "FAIL: app-host tests accept one -parallel-testing-enabled setting" >&2
      exit 2
    fi
    parallel_testing_seen=1
    parallel_testing_needs_value=1
  fi
done
if [ "$parallel_testing_needs_value" -eq 1 ]; then
  echo "FAIL: -parallel-testing-enabled requires the value NO" >&2
  exit 2
fi
if [ "$parallel_testing_seen" -eq 0 ]; then
  app_host_xcodebuild_arguments+=("-parallel-testing-enabled" "NO")
fi

if [ "${CMUX_CI_APP_HOST_ISOLATION_REQUIRED:-0}" = "1" ]; then
  # This compiled condition reaches the test bundle through Xcode build
  # settings, independently of the TEST_RUNNER_ runtime environment channel.
  # The test therefore fails closed if Xcode ever drops that runtime handoff.
  app_host_xcodebuild_arguments+=(
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED"
  )
fi

kill_stale_app_host() {
  [ "${CMUX_CI_APP_HOST_ISOLATION_REQUIRED:-0}" = "1" ] || return 0
  cmux_validate_app_host_derived_data "$CMUX_DERIVED_DATA_PATH" || return 1
  cmux_recover_owned_app_host_attempt \
    "$app_host_receipt_dir" \
    "$app_host_key" \
    "$CMUX_VALIDATED_APP_HOST_DERIVED_DATA" \
    "$CMUX_RESOLVED_RUNNER_WORK_ROOT" \
    "$CMUX_RESOLVED_SYSTEM_TEMP_ROOT"
}

exit_after_total_timeout() {
  echo "FAIL: app-host xcodebuild reached its total timeout; cleaning owned app-host processes" >&2
  if ! kill_stale_app_host; then
    echo "FAIL: receipt-verified app-host cleanup failed after total timeout" >&2
  fi
  exit 124
}

validate_app_host_config_paths() {
  local log_path="$1"
  local require_evidence="$2"
  [ -n "$app_host_home" ] || return 0

  if [ ! -r "$log_path" ]; then
    echo "FAIL: app-host configuration log could not be scanned" >&2
    return 1
  fi

  # macOS resolves the published /tmp scope through /private/tmp, while
  # Ghostty may report either spelling. Both roots were derived and validated
  # above; keep the slash boundary so a same-prefix sibling is still rejected.
  local published_expected_config_path resolved_expected_config_path
  published_expected_config_path="${app_host_home_input%/}/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
  resolved_expected_config_path="${app_host_home%/}/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
  local matches scan_status line reported_path
  if matches="$(grep -E 'cmux DEV.*\[(config|default)\].*path=.*(Library/Application Support/com\.mitchellh\.ghostty/|/\.config/ghostty/)' "$log_path")"; then
    scan_status=0
  else
    scan_status=$?
  fi

  if [ "$scan_status" -eq 1 ]; then
    matches=""
  fi
  if [ "$scan_status" -gt 1 ]; then
    echo "FAIL: app-host configuration log could not be scanned" >&2
    return 1
  fi

  if [ -n "$matches" ]; then
    while IFS= read -r line; do
      reported_path="${line#*path=}"
      case "$reported_path" in
        "$app_host_home"|"${app_host_home%/}/"* \
          |"$app_host_home_input"|"${app_host_home_input%/}/"*) ;;
        *)
          echo "FAIL: Ghostty accessed configuration outside the isolated app-host home" >&2
          echo "$line" >&2
          return 1
          ;;
      esac
    done <<< "$matches"
  fi

  if [ "$require_evidence" = "1" ]; then
    if ! grep -Fq \
      "[default] reading configuration file path=$resolved_expected_config_path" \
      "$log_path" \
      && ! grep -Fq \
        "[config] reading configuration file path=$resolved_expected_config_path" \
        "$log_path" \
      && ! grep -Fq \
        "[default] reading configuration file path=$published_expected_config_path" \
        "$log_path" \
      && ! grep -Fq \
        "[config] reading configuration file path=$published_expected_config_path" \
        "$log_path"; then
      echo "FAIL: app-host configuration evidence is missing" >&2
      return 1
    fi
  fi
}

attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
  xcodebuild_environment=("${app_host_test_runner_environment[@]}")
  log_path="${log_stem}-attempt-${attempt}.log"
  : >"$log_path"
  # Recover only this run key's prior attempt. A live foreign key fails the
  # complete preflight without signaling any PID, so one runner service cannot
  # terminate another service's healthy app host.
  kill_stale_app_host
  if [ -n "$app_host_total_deadline_seconds" ]; then
    total_remaining_seconds=$((app_host_total_deadline_seconds - SECONDS))
    if [ "$total_remaining_seconds" -le 0 ]; then
      exit_after_total_timeout
    fi
    xcodebuild_environment+=(
      "CMUX_XCODEBUILD_NONINTERACTIVE_TOTAL_TIMEOUT_SECONDS=$total_remaining_seconds"
    )
  fi
  set +e
  env \
    "${xcodebuild_environment[@]}" \
    CMUX_XCODEBUILD_NONINTERACTIVE_LOG_PATH="$log_path" \
    scripts/ci/xcodebuild_noninteractive.py xcodebuild \
      "${app_host_xcodebuild_arguments[@]}"
  status=$?
  set -e

  total_timeout_marker=0
  if [ "$status" -eq 124 ] \
    && grep -Fq 'CMUX_XCODEBUILD_TIMEOUT_KIND=total' "$log_path" 2>/dev/null; then
    total_timeout_marker=1
  fi
  if [ "$total_timeout_marker" -eq 1 ]; then
    exit_after_total_timeout
  fi

  require_config_evidence=0
  if [ "$status" -eq 0 ]; then
    require_config_evidence=1
  fi
  if ! validate_app_host_config_paths \
    "$log_path" "$require_config_evidence"; then
    exit 1
  fi

  if grep -Fq 'path = "/tmp/cmux-debug.sock"' "$log_path"; then
    echo "FAIL: app-host used default debug socket instead of an XCTest-scoped socket" >&2
    exit 1
  fi

  if grep -Fq 'SocketControlServer: Listening on /tmp/cmux-debug.sock' "$log_path"; then
    echo "FAIL: app-host listener used default debug socket instead of an XCTest-scoped socket" >&2
    exit 1
  fi

  if [ "$status" -ne 0 ]; then
    retry_reason=""
    if [ "$status" -eq 124 ]; then
      retry_reason="${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS}s idle timeout"
    elif grep -Fq 'The test runner hung before establishing connection.' "$log_path"; then
      retry_reason="XCTest startup hang"
    elif grep -Fq 'Failed to establish communication with the test runner' "$log_path"; then
      retry_reason="test runner communication failure"
    elif grep -Fq 'com.apple.testmanagerd.control was invalidated' "$log_path"; then
      retry_reason="testmanagerd connection invalidated"
    elif grep -Fq "Couldn't communicate with a helper application" "$log_path"; then
      retry_reason="test helper communication failure"
    fi

    if [ -n "$retry_reason" ] && [ "$attempt" -lt "$max_attempts" ]; then
      echo "Retrying app-host xcodebuild after ${retry_reason} (attempt $attempt/$max_attempts)" >&2
      kill_stale_app_host
      attempt=$((attempt + 1))
      continue
    fi
    exit "$status"
  fi

  if ! grep -Eq 'SocketControlServer: Listening on |message = "socket.listener.start"' "$log_path"; then
    echo "FAIL: app-host xcodebuild output did not include socket listener evidence" >&2
    exit 1
  fi

  exit 0
done

exit 1
