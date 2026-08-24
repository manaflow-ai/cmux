#!/usr/bin/env bash
# Run "$@" inside the logged-in console user's Aqua (GUI) login session.
#
# Why: `xcodebuild test` needs testmanagerd's control service, which only exists
# in the console user's GUI login-session bootstrap namespace. On a self-hosted
# Mac whose runner agent is NOT itself in that session (e.g. a root/daemon
# context), the test command runs in the wrong bootstrap, can't find
# com.apple.testmanagerd.control ("No such process"), and times out initiating
# the control session, so 0 tests run. Hopping into the console user's session
# (launchctl asuser) puts the command in the right bootstrap.
#
# Safe by construction:
#   - If no real console user is logged in (console owner is root/loginwindow),
#     or passwordless sudo is unavailable, it falls back to running in the
#     current bootstrap. That is exactly today's behavior, so it can never make
#     a runner worse; it only helps runners that DO have a logged-in user the
#     command was failing to reach.
#   - On a runner whose agent is already in the console session, the hop is into
#     the same session (effectively a no-op).
#
# This mirrors the proven elevation used by perf-activation.yml and the
# automation-mode setup used by the ui-regressions job.
set -euo pipefail

ci_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/app-host-isolation.sh
source "$ci_script_dir/app-host-isolation.sh"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

cleanup_app_host_home_requested=0
case "$1" in
  scripts/ci/cleanup-app-host-home.sh|"$ci_script_dir/cleanup-app-host-home.sh")
    cleanup_app_host_home_requested=1
    ;;
esac

# App-host CI publishes neutral paths while retaining the console user's real
# HOME and configuration redirects for Xcode and the GUI login session. Never
# let a reused runner's personal SSH agent leak into isolated app-host tests.
if [ -n "${CMUX_APP_HOST_HOME:-}" ]; then
  unset SSH_AUTH_SOCK
fi

prepare_app_host_home_for_console_user() {
  local console_user="$1"
  local cleanup_requested="$2"
  [ -n "${CMUX_APP_HOST_HOME:-}" ] || return 0
  cmux_validate_published_app_host_identity_values || return 1

  local app_host_home="$CMUX_RESOLVED_APP_HOST_HOME"
  local app_host_receipt_dir="$CMUX_RESOLVED_APP_HOST_RECEIPT_DIR"
  local app_host_confirmation_file="$CMUX_RESOLVED_APP_HOST_CONFIRMATION_FILE"
  if sudo -n test -L "$app_host_home"; then
    echo "FAIL: refusing app-host preparation through a home symlink" >&2
    return 1
  fi
  if sudo -n test -L "$app_host_receipt_dir"; then
    echo "FAIL: refusing app-host preparation through a receipt symlink" >&2
    return 1
  fi
  if sudo -n test -L "$app_host_confirmation_file"; then
    echo "FAIL: refusing app-host preparation through a confirmation symlink" >&2
    return 1
  fi

  local home_exists=0 receipt_dir_exists=0 confirmation_exists=0
  local resolved_home resolved_receipt_dir
  if sudo -n test -e "$app_host_home"; then
    home_exists=1
    resolved_home="$(sudo -n /bin/bash -c 'cd "$1" 2>/dev/null && pwd -P' bash "$app_host_home")" || {
      echo "FAIL: app-host isolation directory is unavailable" >&2
      return 1
    }
    if [ "$resolved_home" != "$app_host_home" ]; then
      echo "FAIL: app-host isolation directory changed identity" >&2
      return 1
    fi
  elif [ "$cleanup_requested" != "1" ]; then
    echo "FAIL: app-host isolation directory is unavailable" >&2
    return 1
  fi
  if sudo -n test -e "$app_host_receipt_dir"; then
    receipt_dir_exists=1
    resolved_receipt_dir="$(sudo -n /bin/bash -c 'cd "$1" 2>/dev/null && pwd -P' bash "$app_host_receipt_dir")" || {
      echo "FAIL: app-host process receipt directory is unavailable" >&2
      return 1
    }
    if [ "$resolved_receipt_dir" != "$app_host_receipt_dir" ]; then
      echo "FAIL: app-host process receipt directory changed identity" >&2
      return 1
    fi
  elif [ "$cleanup_requested" != "1" ]; then
    echo "FAIL: app-host process receipt directory is unavailable" >&2
    return 1
  fi
  if sudo -n test -e "$app_host_confirmation_file"; then
    confirmation_exists=1
  fi

  local scope_exists=0
  if [ "$home_exists" = "1" ] \
    || [ "$receipt_dir_exists" = "1" ] \
    || [ "$confirmation_exists" = "1" ]; then
    scope_exists=1
  fi

  local validation_function="cmux_validate_published_app_host_identity"
  if [ "$cleanup_requested" = "1" ]; then
    validation_function="cmux_validate_published_app_host_identity_values"
  fi

  # Cleanup may receive paths owned by either the runner account (setup failed
  # before the console hop) or the console account (the app host ran). Validate
  # the root-owned view of the confirmation before changing any ownership.
  if [ "$scope_exists" = "1" ]; then
    sudo -n env \
      GITHUB_REPOSITORY_ID="$GITHUB_REPOSITORY_ID" \
      GITHUB_RUN_ID="$GITHUB_RUN_ID" \
      GITHUB_RUN_ATTEMPT="$GITHUB_RUN_ATTEMPT" \
      CMUX_APP_HOST_SHARD="$CMUX_APP_HOST_SHARD" \
      RUNNER_TEMP="$RUNNER_TEMP" \
      CMUX_APP_HOST_KEY="$CMUX_APP_HOST_KEY" \
      CMUX_APP_HOST_HOME="$CMUX_APP_HOST_HOME" \
      CMUX_APP_HOST_XDG_CONFIG_HOME="$CMUX_APP_HOST_XDG_CONFIG_HOME" \
      CMUX_APP_HOST_RECEIPT_DIR="$CMUX_APP_HOST_RECEIPT_DIR" \
      CMUX_APP_HOST_CLEANUP_CONFIRMATION="$CMUX_APP_HOST_CLEANUP_CONFIRMATION" \
      CMUX_APP_HOST_CONFIRMATION_FILE="$CMUX_APP_HOST_CONFIRMATION_FILE" \
      /bin/bash -c 'source "$1" && "$2" && cmux_validate_app_host_cleanup_confirmation' \
        bash "$ci_script_dir/app-host-isolation.sh" "$validation_function"

    local runner_user scope_path scope_owner
    runner_user="$(id -un)" || {
      echo "FAIL: app-host runner account is unavailable" >&2
      return 1
    }
    for scope_path in \
      "$app_host_home" \
      "$app_host_receipt_dir" \
      "$app_host_confirmation_file"
    do
      if sudo -n test -e "$scope_path"; then
        scope_owner="$(sudo -n stat -f %Su "$scope_path")" || {
          echo "FAIL: app-host scope owner is unavailable" >&2
          return 1
        }
        case "$scope_owner" in
          "$runner_user"|"$console_user") ;;
          *)
            echo "FAIL: app-host scope owner is not trusted" >&2
            return 1
            ;;
        esac
      fi
    done
  fi

  if [ "$home_exists" = "1" ]; then
    sudo -n chown -R -P "$console_user" "$app_host_home"
    sudo -n chmod -R u+rwX,go-rwx "$app_host_home"
  fi
  if [ "$receipt_dir_exists" = "1" ]; then
    sudo -n chown -R -P "$console_user" "$app_host_receipt_dir"
    sudo -n chmod -R u+rwX,go-rwx "$app_host_receipt_dir"
  fi
  if [ "$confirmation_exists" = "1" ]; then
    sudo -n chown "$console_user" "$app_host_confirmation_file"
  fi

  # Re-run the shared validator after ownership transfer. This validates the
  # paths from the same account that will launch or tear down the app host.
  local confirmation_validation_function=:
  if [ "$scope_exists" = "1" ]; then
    confirmation_validation_function="cmux_validate_app_host_cleanup_confirmation"
  fi
  sudo -n -u "$console_user" env \
    GITHUB_REPOSITORY_ID="$GITHUB_REPOSITORY_ID" \
    GITHUB_RUN_ID="$GITHUB_RUN_ID" \
    GITHUB_RUN_ATTEMPT="$GITHUB_RUN_ATTEMPT" \
    CMUX_APP_HOST_SHARD="$CMUX_APP_HOST_SHARD" \
    RUNNER_TEMP="$RUNNER_TEMP" \
    CMUX_APP_HOST_KEY="$CMUX_APP_HOST_KEY" \
    CMUX_APP_HOST_HOME="$CMUX_APP_HOST_HOME" \
    CMUX_APP_HOST_XDG_CONFIG_HOME="$CMUX_APP_HOST_XDG_CONFIG_HOME" \
    CMUX_APP_HOST_RECEIPT_DIR="$CMUX_APP_HOST_RECEIPT_DIR" \
    CMUX_APP_HOST_CLEANUP_CONFIRMATION="$CMUX_APP_HOST_CLEANUP_CONFIRMATION" \
    CMUX_APP_HOST_CONFIRMATION_FILE="$CMUX_APP_HOST_CONFIRMATION_FILE" \
    /bin/bash -c 'source "$1" && "$2" && "$3"' \
      bash "$ci_script_dir/app-host-isolation.sh" \
        "$validation_function" "$confirmation_validation_function"
}

console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
if [ -n "$console_user" ] && [ "$console_user" != "root" ] \
  && console_uid="$(id -u "$console_user" 2>/dev/null)" && sudo -n true 2>/dev/null; then
  console_home="$( (dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null || true) | awk '{print $2}')"
  [ -n "$console_home" ] || console_home="$HOME"
  prepare_app_host_home_for_console_user \
    "$console_user" "$cleanup_app_host_home_requested"

  # Forward only environment variables that are actually set, with their real
  # values, so we mirror the current environment exactly. Never inject an empty
  # value for an unset var (that would defeat a `${VAR:-default}` downstream).
  # HOME is set explicitly to the console user's home.
  forward=(PATH DEVELOPER_DIR GITHUB_WORKSPACE RUNNER_TEMP \
    CMUX_DERIVED_DATA_PATH CMUX_TAG CMUX_SKIP_ZIG_BUILD \
    CMUX_UNIT_TEST_TIMEOUT_SECONDS \
    CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS \
    CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS \
    CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_SECONDS \
    CMUX_APP_HOST_XCODEBUILD_ATTEMPTS \
    GITHUB_REPOSITORY_ID GITHUB_RUN_ID GITHUB_RUN_ATTEMPT CMUX_APP_HOST_SHARD CMUX_CI_APP_HOST_ISOLATION_REQUIRED CMUX_APP_HOST_KEY CMUX_APP_HOST_HOME CMUX_APP_HOST_XDG_CONFIG_HOME CMUX_APP_HOST_RECEIPT_DIR CMUX_APP_HOST_CLEANUP_CONFIRMATION CMUX_APP_HOST_CONFIRMATION_FILE \
    CFFIXED_USER_HOME XDG_CONFIG_HOME CARGO_HOME RUSTUP_HOME)
  if [ "${CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER:-0}" = "1" ]; then
    forward+=(CMUX_CI_APP_HOST_CLEANUP_TEST_HELPER CMUX_APP_HOST_LSOF CMUX_FAKE_LSOF_STATE)
  fi
  env_pairs=()
  for var in "${forward[@]}"; do
    if [ -n "${!var+set}" ]; then
      env_pairs+=("$var=${!var}")
    fi
  done

  echo "Elevating into console user '$console_user' (uid $console_uid) Aqua session for: $*" >&2
  exec sudo -n launchctl asuser "$console_uid" sudo -n -u "$console_user" -E \
    env HOME="$console_home" "${env_pairs[@]}" \
    bash -c 'cd "$GITHUB_WORKSPACE" && exec "$@"' bash "$@"
fi

echo "::warning::No logged-in console user (or no passwordless sudo) on this runner; running in the current bootstrap. XCTest will fail here if this runner has no GUI session." >&2
exec "$@"
