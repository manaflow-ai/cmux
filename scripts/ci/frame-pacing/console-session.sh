#!/usr/bin/env bash
# Run "$@" in the logged-in console user's Aqua (GUI) session.
#
# usage: console-session.sh COMMAND [ARGS...]
#
# The fling bench opens windows on a virtual display, which only works from
# the console user's GUI session. A runner agent outside it (a root or daemon
# context) hops in with `sudo -n launchctl asuser`, as main's
# scripts/ci/run-in-console-session.sh does for app-host tests (cmux-next
# deleted that one with the legacy app in #15659). With no console user or no
# passwordless sudo it runs the command where it is, which is right for a
# runner that is already the console user's LaunchAgent.
#
# Only these variables cross, and only when set: PATH DEVELOPER_DIR
# GITHUB_WORKSPACE RUNNER_TEMP CI GITHUB_ACTIONS CMUX_TAG. HOME is the console
# user's, and the command starts in GITHUB_WORKSPACE.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 COMMAND [ARGS...]" >&2
  exit 2
fi

console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
if [ -n "$console_user" ] && [ "$console_user" != root ] && [ "$console_user" != loginwindow ] \
  && console_uid="$(id -u "$console_user" 2>/dev/null)" && sudo -n true 2>/dev/null; then
  console_home="$( (dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null || true) | awk '{print $2}')"
  [ -n "$console_home" ] || console_home="$HOME"
  env_pairs=()
  for var in PATH DEVELOPER_DIR GITHUB_WORKSPACE RUNNER_TEMP CI GITHUB_ACTIONS CMUX_TAG; do
    if [ -n "${!var+set}" ]; then
      env_pairs+=("$var=${!var}")
    fi
  done
  echo "Running in console user '$console_user' (uid $console_uid) Aqua session: $*" >&2
  exec sudo -n launchctl asuser "$console_uid" sudo -n -u "$console_user" \
    env HOME="$console_home" "${env_pairs[@]}" \
    bash -c 'cd "${GITHUB_WORKSPACE:-.}" && exec "$@"' bash "$@"
fi

# A LaunchAgent already runs in Aqua without sudo; anything else draws nothing.
if [ "$(launchctl managername 2>/dev/null || true)" != Aqua ]; then
  echo "::warning::Not in a console user's Aqua session (console user '${console_user:-none}', no passwordless sudo hop); the bench's windows may not draw." >&2
fi
exec "$@"
