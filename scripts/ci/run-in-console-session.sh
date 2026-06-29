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

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
if [ -n "$console_user" ] && [ "$console_user" != "root" ] \
  && console_uid="$(id -u "$console_user" 2>/dev/null)" && sudo -n true 2>/dev/null; then
  console_home="$( (dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null || true) | awk '{print $2}')"
  [ -n "$console_home" ] || console_home="$HOME"

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
    CFFIXED_USER_HOME)
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
