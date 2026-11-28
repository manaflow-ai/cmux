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
#     or passwordless sudo is unavailable for any command the hop runs, it
#     falls back to running in the current bootstrap. That is exactly today's
#     behavior, so it can never make a runner worse; it only helps runners that
#     DO have a logged-in user the command was failing to reach. One exception:
#     an isolated app-host run (CMUX_CI_APP_HOST_ISOLATION_REQUIRED=1) on a
#     runner whose sudoers allows only some of those commands, and that is not
#     already in the console user's Aqua session, fails at once and names the
#     refused command, since its tests could not reach testmanagerd.
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

# Every app-host test command must write to a regular file before crossing into
# the console session. Test-launched tmux/SSH descendants may intentionally
# outlive xcodebuild; inheriting the Actions stdout pipe from this wrapper would
# let one detached child keep the CI step alive after the test runner exits.
# run-and-capture owns the live follower separately, so descendants inherit only
# the regular capture file. Explicit callers already inside run-and-capture set
# CMUX_CI_FILE_CAPTURE_ACTIVE and skip this one common boundary.
if [ "${CMUX_CI_FILE_CAPTURE_ACTIVE:-0}" != "1" ]; then
  app_host_command=0
  for command_arg in "$@"; do
    case "$command_arg" in
      */run-app-host-xcodebuild.sh|run-app-host-xcodebuild.sh)
        app_host_command=1
        break
        ;;
    esac
  done
  if [ "$app_host_command" = "1" ]; then
    capture_tag="${CMUX_TAG:-untagged}"
    capture_tag="$(printf '%s' "$capture_tag" | tr -c 'A-Za-z0-9._-' '_')"
    capture_path="${RUNNER_TEMP:-/tmp}/cmux-app-host-console-capture-${capture_tag}-pid-$$.log"
    exec /bin/bash "$ci_script_dir/run-and-capture.sh" "$capture_path" "$0" "$@"
  fi
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

# Passwordless sudo for `true` alone does not make the hop possible: a sudoers
# that names only some commands passes `sudo -n true` and then refuses the
# `sudo -n test` that preparation starts with. Probe every command form the
# hop runs, so such a runner takes the fallback below instead of failing on
# the first preparation check with "isolation directory is unavailable".
console_hop_sudo_refusal=""
probe_console_hop_sudo() {
  local console_user="$1" console_uid="$2" form
  sudo -n true 2>/dev/null || { console_hop_sudo_refusal="sudo -n true"; return 1; }
  local -a forms=(
    "test -e /"
    "stat -f %Su /"
    "/bin/bash -c :"
    "env true"
    "-u $console_user true"
    "launchctl asuser $console_uid true"
  )
  # chown/chmod are not run here: running them before cleanup authenticates
  # its scope is a privileged mutation, and `/bin/bash -c :` passing already
  # means sudoers grants a root shell.
  for form in "${forms[@]}"
  do
    # shellcheck disable=SC2086 # each form is a fixed list of words
    if ! sudo -n $form >/dev/null 2>&1; then
      console_hop_sudo_refusal="sudo -n $form"
      return 1
    fi
  done
}

console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
if [ -n "$console_user" ] && [ "$console_user" != "root" ] \
  && [ "$console_user" != "loginwindow" ] \
  && console_uid="$(id -u "$console_user" 2>/dev/null)" \
  && probe_console_hop_sudo "$console_user" "$console_uid"; then
  console_home="$( (dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null || true) | awk '{print $2}')"
  [ -n "$console_home" ] || console_home="$HOME"
  prepare_app_host_home_for_console_user \
    "$console_user" "$cleanup_app_host_home_requested"

  # Forward only environment variables that are actually set, with their real
  # values, so we mirror the current environment exactly. Never inject an empty
  # value for an unset var (that would defeat a `${VAR:-default}` downstream).
  # HOME is set explicitly to the console user's home.
  forward=(PATH DEVELOPER_DIR GITHUB_WORKSPACE RUNNER_TEMP CI GITHUB_ACTIONS \
    CMUX_DERIVED_DATA_PATH CMUX_CI_RUNTIME_SOURCE_ROOT CMUX_TAG CMUX_SKIP_ZIG_BUILD \
    CMUX_UNIT_TEST_TIMEOUT_SECONDS \
    CMUX_XCODEBUILD_NONINTERACTIVE_IDLE_TIMEOUT_SECONDS \
    CMUX_XCODEBUILD_NONINTERACTIVE_POST_TEST_TIMEOUT_SECONDS \
    CMUX_XCODEBUILD_NONINTERACTIVE_TIMEOUT_SECONDS \
    CMUX_APP_HOST_XCODEBUILD_ATTEMPTS \
    CMUX_CI_RUNTIME_SOURCE_ROOT \
    CMUX_RENDERER_MEMORY_REGRESSION \
    CMUX_APP_HOST_CAPTURE_XCRESULTS CMUX_APP_HOST_RESULT_BUNDLE_ROOT CMUX_APP_HOST_TEST_CASE_TIMEOUT_SECONDS \
    GITHUB_REPOSITORY_ID GITHUB_RUN_ID GITHUB_RUN_ATTEMPT CMUX_APP_HOST_SHARD CMUX_APP_HOST_XCTESTRUN CMUX_NUMERIC_LOCALE_XCTESTRUN CMUX_CI_RUNTIME_SOURCE_ROOT CMUX_CI_APP_HOST_ISOLATION_REQUIRED CMUX_APP_HOST_KEY CMUX_APP_HOST_HOME CMUX_APP_HOST_XDG_CONFIG_HOME CMUX_APP_HOST_RECEIPT_DIR CMUX_APP_HOST_CLEANUP_CONFIRMATION CMUX_APP_HOST_CONFIRMATION_FILE \
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

# A LaunchAgent already inherits Aqua even when it cannot sudo. Console owner
# alone is insufficient: an SSH/daemon process can run as that same account.
if [ -z "$console_user" ] || [ "$console_user" = "root" ] \
  || [ "$console_user" = "loginwindow" ]; then
  echo "::warning::No logged-in console user on this runner; running in the current bootstrap. GUI XCTest requires an active console login." >&2
else
  current_uid="$(id -u 2>/dev/null || true)"
  session_manager="$(launchctl managername 2>/dev/null || true)"
  if [ -n "${console_uid:-}" ] && [ "$current_uid" = "$console_uid" ] \
    && [ "$session_manager" = "Aqua" ]; then
    echo "Console session: already running as console user '$console_user' (uid $console_uid) in Aqua; no sudo hop needed." >&2
  elif [ -n "$console_hop_sudo_refusal" ] && [ "$console_hop_sudo_refusal" != "sudo -n true" ] \
    && [ "${CMUX_CI_APP_HOST_ISOLATION_REQUIRED:-0}" = "1" ]; then
    # Partial sudoers on an isolated app-host run: the current bootstrap cannot
    # reach testmanagerd, so falling back would spend the shard's whole test
    # watchdog running zero tests. Say what the host must fix instead.
    echo "::error::Runner ${RUNNER_NAME:-unknown} allows passwordless 'sudo -n true' but asks for a password for '$console_hop_sudo_refusal', which the console-session hop needs; current uid=${current_uid:-unknown}, session=${session_manager:-unknown}. Fix this runner's sudoers (NOPASSWD for the hop's commands) or run the runner as a console-user LaunchAgent." >&2
    exit 1
  else
    echo "::warning::Cannot enter console user '$console_user' Aqua session without passwordless sudo${console_hop_sudo_refusal:+ (refused: $console_hop_sudo_refusal)} on runner ${RUNNER_NAME:-unknown}; current uid=${current_uid:-unknown}, session=${session_manager:-unknown}. Running in the current bootstrap; verify the runner is a console-user LaunchAgent before GUI XCTest." >&2
  fi
fi
exec "$@"
