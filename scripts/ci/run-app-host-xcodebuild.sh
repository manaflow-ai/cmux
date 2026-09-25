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
log_tag="${CMUX_TAG:-untagged}"
# Keep every invocation distinct. Focused suites run sequentially in one job,
# and a shared "untagged" stem used to overwrite earlier retry evidence.
# Python observes this shell as its parent and avoids relying on shell PID
# syntax that can be rewritten while workflow text is generated.
invocation_id="$(python3 -c 'import os; print(os.getppid())')"
log_stem="${log_dir%/}/cmux-app-host-xcodebuild-${log_tag}-pid-${invocation_id}"
max_attempts="${CMUX_APP_HOST_XCODEBUILD_ATTEMPTS:-3}"
export CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS="${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS:-${CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_SECONDS:-300}}"
# A crashed app host is relaunched by xcodebuild, which then resumes the run.
# Nothing bounds that loop, so cap the restarts one invocation may spend before
# the wrapper aborts it (https://github.com/manaflow-ai/cmux/issues/13707).
export CMUX_XCODEBUILD_NONINTERACTIVE_RESTART_BUDGET="${CMUX_XCODEBUILD_NONINTERACTIVE_RESTART_BUDGET:-2}"
restart_budget_exit_code=123
echo "App-host xcodebuild idle timeout: ${CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS}s, attempts: ${max_attempts}, restart budget: ${CMUX_XCODEBUILD_NONINTERACTIVE_RESTART_BUDGET}"

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

# xcodebuild must retain the console user's real HOME so Xcode and its package
# toolchains remain available. Capture isolation only after the lock re-exec,
# then pass it through Xcode's TEST_RUNNER_ environment channel. Xcode strips
# that prefix when it launches the test runner, so the app host receives the
# redirects without exposing them to the xcodebuild driver.
app_host_test_runner_environment=("TEST_RUNNER_CMUX_TEST_PROCESS=1")
# Xcode does not inherit the driver's full environment into the test host.
# Preserve CI identity so existing CI-specific test deadlines actually apply.
if [ -n "${CI:-}" ]; then
  app_host_test_runner_environment+=("TEST_RUNNER_CI=$CI")
fi
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  app_host_test_runner_environment+=("TEST_RUNNER_GITHUB_ACTIONS=$GITHUB_ACTIONS")
fi
# Focused app-host suites invoke Node/Bun-backed helpers from the test process.
# Xcode does not inherit these driver variables, so carry them through the
# TEST_RUNNER_ channel when the caller supplied them.
if [ -n "${TEST_RUNNER_PATH:-}" ]; then
  app_host_test_runner_environment+=("TEST_RUNNER_PATH=$TEST_RUNNER_PATH")
fi
if [ -n "${TEST_RUNNER_BUN_INSTALL:-}" ]; then
  app_host_test_runner_environment+=("TEST_RUNNER_BUN_INSTALL=$TEST_RUNNER_BUN_INSTALL")
fi
# Focused opt-in suites (renderer memory regression, benchmarks) are gated on a
# plain variable the driver receives. Xcode does not inherit it, so a caller that
# exports the plain name would silently run nothing. Carry those through.
for cmux_opt_in_gate in CMUX_RENDERER_MEMORY_REGRESSION; do
  cmux_opt_in_value="${!cmux_opt_in_gate:-}"
  if [ -n "$cmux_opt_in_value" ]; then
    app_host_test_runner_environment+=("TEST_RUNNER_${cmux_opt_in_gate}=$cmux_opt_in_value")
  fi
done
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
fi

app_host_xcodebuild_arguments=("$@")
caller_has_result_bundle=0
caller_has_test_timeouts_enabled=0
caller_has_default_test_timeout=0
caller_has_maximum_test_timeout=0
for app_host_argument in "${app_host_xcodebuild_arguments[@]}"; do
  case "$app_host_argument" in
    -resultBundlePath)
      caller_has_result_bundle=1
      ;;
    -test-timeouts-enabled)
      caller_has_test_timeouts_enabled=1
      ;;
    -default-test-execution-time-allowance)
      caller_has_default_test_timeout=1
      ;;
    -maximum-test-execution-time-allowance)
      caller_has_maximum_test_timeout=1
      ;;
  esac
done
if [ "$caller_has_test_timeouts_enabled" -eq 0 ]; then
  app_host_xcodebuild_arguments+=("-test-timeouts-enabled" "YES")
fi
if [ "$caller_has_default_test_timeout" -eq 0 ]; then
  app_host_xcodebuild_arguments+=(
    "-default-test-execution-time-allowance" "${CMUX_APP_HOST_TEST_CASE_TIMEOUT_SECONDS:-300}"
  )
fi
if [ "$caller_has_maximum_test_timeout" -eq 0 ]; then
  app_host_xcodebuild_arguments+=(
    "-maximum-test-execution-time-allowance" "${CMUX_APP_HOST_TEST_CASE_TIMEOUT_SECONDS:-300}"
  )
fi

# Xcode's package-product layout can recreate or empty the top-level
# PackageFrameworks directory while resolving/test-without-building. The app
# host's rpath expects package frameworks there, so restage from the canonical
# test-bundle copy immediately before every invocation. This keeps focused
# gates and the sharded batches identical after any Xcode package operation.
if [ -n "${CMUX_DERIVED_DATA_PATH:-}" ]; then
  package_products_dir="$CMUX_DERIVED_DATA_PATH/Build/Products/Debug"
  package_framework_destination="$package_products_dir/PackageFrameworks"
  stable_framework_destination="${RUNNER_TEMP:-/tmp}/cmux-app-host-package-frameworks"
  package_framework_source="$(find "$package_products_dir" -type d -name 'CmuxAgentJournal*_PackageProduct.framework' -print -quit 2>/dev/null || true)"
  if [ -d "$stable_framework_destination" ] && find "$stable_framework_destination" -name 'CmuxAgentJournal*_PackageProduct.framework' -print -quit | grep -q .; then
    package_framework_source="$(find "$stable_framework_destination" -type d -name 'CmuxAgentJournal*_PackageProduct.framework' -print -quit)"
  fi
  if [ -n "$package_framework_source" ]; then
    if [ -L "$package_framework_destination" ]; then
      rm "$package_framework_destination"
    fi
    mkdir -p "$package_framework_destination"
    package_framework_root="$(dirname "$package_framework_source")"
    rsync -aL "$package_framework_root/" "$package_framework_destination/"
    test -f "$package_framework_destination/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct.framework/Versions/A/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct"
    app_framework_destination="$package_products_dir/cmux DEV.app/Contents/Frameworks"
    mkdir -p "$app_framework_destination"
    rsync -aL "$package_framework_root/" "$app_framework_destination/"
    test -f "$app_framework_destination/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct.framework/Versions/A/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct"
    mkdir -p "$stable_framework_destination"
    rsync -aL "$package_framework_root/" "$stable_framework_destination/"
    export DYLD_LIBRARY_PATH="$stable_framework_destination:$app_framework_destination${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    test -f "$stable_framework_destination/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct.framework/Versions/A/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct"
    app_host_test_runner_environment+=(
      "TEST_RUNNER_DYLD_LIBRARY_PATH=$package_framework_destination:$app_framework_destination"
    )
  fi
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
  log_path="${log_stem}-attempt-${attempt}.log"
  metadata_path="${log_stem}-attempt-${attempt}.meta"
  : >"$log_path"
  attempt_xcodebuild_arguments=("${app_host_xcodebuild_arguments[@]}")
  result_bundle_path=""
  result_bundle_root="${CMUX_APP_HOST_RESULT_BUNDLE_ROOT:-}"
  if [ -z "$result_bundle_root" ] \
    && [ "${CMUX_APP_HOST_CAPTURE_XCRESULTS:-0}" = "1" ]; then
    result_bundle_root="${RUNNER_TEMP:-/tmp}/cmux-app-host-xcresults"
  fi
  if [ -n "$result_bundle_root" ] \
    && [ "$caller_has_result_bundle" -eq 0 ]; then
    mkdir -p "$result_bundle_root"
    result_bundle_path="${result_bundle_root%/}/$(basename "$log_stem")-attempt-${attempt}.xcresult"
    rm -rf -- "$result_bundle_path"
    attempt_xcodebuild_arguments+=("-resultBundlePath" "$result_bundle_path")
  fi
  {
    echo "shard=${CMUX_APP_HOST_SHARD:-unknown}"
    echo "tag=$log_tag"
    echo "attempt=$attempt"
    [ -z "$result_bundle_path" ] || echo "result_bundle=$result_bundle_path"
    printf 'arg=%q\n' "${attempt_xcodebuild_arguments[@]}"
  } >"$metadata_path"
  # Recover only this run key's prior attempt. A live foreign key fails the
  # complete preflight without signaling any PID, so one runner service cannot
  # terminate another service's healthy app host.
  kill_stale_app_host
  set +e
  env \
    "${app_host_test_runner_environment[@]}" \
    CMUX_XCODEBUILD_NONINTERACTIVE_LOG_PATH="$log_path" \
    scripts/ci/xcodebuild_noninteractive.py xcodebuild \
      "${attempt_xcodebuild_arguments[@]}"
  status=$?
  set -e
  echo "exit_status=$status" >>"$metadata_path"

  if [ -n "$result_bundle_path" ] && [ -d "$result_bundle_path" ]; then
    typed_result_stem="${result_bundle_path%.xcresult}"
    # Keep Apple's typed test-result JSON beside the raw bundle. Text output
    # remains useful for streaming diagnostics; these files are the durable,
    # machine-readable verdict evidence for later census/ratchet work.
    xcrun xcresulttool get test-results summary \
      --path "$result_bundle_path" --compact \
      >"${typed_result_stem}.summary.json" \
      2>"${typed_result_stem}.summary.err" || true
    xcrun xcresulttool get test-results tests \
      --path "$result_bundle_path" --compact \
      >"${typed_result_stem}.tests.json" \
      2>"${typed_result_stem}.tests.err" || true
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
    # A restart-budget abort is the one failure that must never be retried:
    # every attempt would crash-loop again and spend the same runner time.
    if [ "$status" -eq "$restart_budget_exit_code" ]; then
      echo "App-host restart budget exceeded on attempt $attempt/$max_attempts; not retrying" >&2
      exit "$status"
    fi
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
      if ! python3 "$ci_script_dir/classify-app-host-test-output.py"         "$log_path" --retry-safe; then
        echo "Preserving app-host failure from attempt $attempt; retry blocked after test execution evidence" >&2
        exit "$status"
      fi
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
