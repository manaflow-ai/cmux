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
  scripts/ci/cleanup-app-host-home.sh|*/scripts/ci/cleanup-app-host-home.sh)
    cleanup_app_host_home_requested=1
    ;;
esac

# App-host CI redirects Apple and XDG state while retaining the console user's
# real HOME for Xcode and the GUI login session. Never let a reused runner's
# personal SSH agent leak into tests that model agent forwarding explicitly.
if [ -n "${CFFIXED_USER_HOME:-}" ]; then
  unset SSH_AUTH_SOCK
fi

prepare_app_host_home_for_console_user() {
  local console_user="$1"
  local cleanup_requested="$2"
  [ -n "${CFFIXED_USER_HOME:-}" ] || return 0

  if [ -z "${RUNNER_TEMP:-}" ]; then
    echo "FAIL: app-host isolation requires a runner temporary directory" >&2
    return 1
  fi

  # A previous invocation may already have made the mode-700 home console-user
  # owned. Resolve it through the passwordless sudo boundary before validating
  # and handing it back to that same user.
  local app_host_home app_host_xdg_config_home runner_temp
  if [ "$cleanup_requested" = "1" ] \
    && ! sudo -n test -e "$CFFIXED_USER_HOME" \
    && ! sudo -n test -L "$CFFIXED_USER_HOME"; then
    # Cleanup itself owns the already-absent case and can now run as the console
    # user without a mutable path for this preparation step to traverse.
    return 0
  fi
  app_host_home="$(sudo -n /bin/bash -c 'cd "$1" 2>/dev/null && pwd -P' bash "$CFFIXED_USER_HOME")" || {
    echo "FAIL: app-host isolation directory is unavailable" >&2
    return 1
  }
  if [ "$cleanup_requested" != "1" ]; then
    app_host_xdg_config_home="$(sudo -n /bin/bash -c 'cd "$1" 2>/dev/null && pwd -P' bash "${XDG_CONFIG_HOME:-}")" || {
      echo "FAIL: app-host XDG configuration directory is unavailable" >&2
      return 1
    }
    cmux_validate_resolved_app_host_isolation \
      "$app_host_home" "$app_host_xdg_config_home" || return 1
    app_host_home="$CMUX_RESOLVED_APP_HOST_HOME"
  fi

  runner_temp="$(cd "$RUNNER_TEMP" 2>/dev/null && pwd -P)" || {
    echo "FAIL: runner temporary directory is unavailable" >&2
    return 1
  }

  case "$app_host_home" in
    "$runner_temp"/*) ;;
    *)
      echo "FAIL: app-host isolation directory is outside the runner temporary directory" >&2
      return 1
      ;;
  esac
  if [ "$cleanup_requested" = "1" ]; then
    case "${app_host_home##*/}" in
      ah-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *)
        echo "FAIL: refusing to prepare a path without the app-host home name" >&2
        return 1
        ;;
    esac
  fi

  sudo -n chown -R "$console_user" "$app_host_home"
  sudo -n chmod -R u+rwX,go-rwx "$app_host_home"
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
    CMUX_CI_APP_HOST_ISOLATION_REQUIRED CFFIXED_USER_HOME XDG_CONFIG_HOME CARGO_HOME RUSTUP_HOME)
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
