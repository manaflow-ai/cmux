#!/usr/bin/env bash
# Run "$@" in the logged-in console user's Aqua (GUI) session.
#
# usage: [CONSOLE_SESSION=auto|own] console-session.sh COMMAND [ARGS...]
#
# The fling bench opens windows on a virtual display, which only works from
# the console user's GUI session. A runner agent outside it (a root or daemon
# context) hops in with `sudo -n launchctl asuser`, as main's
# scripts/ci/run-in-console-session.sh does for app-host tests (cmux-next
# deleted that one with the legacy app in #15659). Already in Aqua, with no
# console user, or with no passwordless sudo for launchctl it runs the command
# where it is, which is right for a runner that is already the console user's
# LaunchAgent.
#
# Only these variables cross, and only when set: PATH DEVELOPER_DIR
# GITHUB_WORKSPACE RUNNER_TEMP CI GITHUB_ACTIONS CMUX_TAG. HOME is the console
# user's, and the command starts in GITHUB_WORKSPACE.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 COMMAND [ARGS...]" >&2
  exit 2
fi

# CONSOLE_SESSION picks the session: auto (default) hops into the console user's session when it can and runs
# here otherwise; own runs in the invoking user's own GUI login (gui/<uid>) through a LaunchAgent this script
# bootstraps, with no sudo: the route for a Mac whose console belongs to another account (an agent screen) and
# whose sudoers does not let this user become it. Any hop or bootstrap that fails says why on a
# CONSOLE-SESSION-FAIL line, so a caller's exit is never a bare 1.
mode="${CONSOLE_SESSION:-auto}"
case "$mode" in auto|own) ;; *) echo "CONSOLE-SESSION-FAIL reason=unknown CONSOLE_SESSION '$mode' (auto|own)" >&2; exit 2 ;; esac

pass_vars=(PATH DEVELOPER_DIR GITHUB_WORKSPACE RUNNER_TEMP CI GITHUB_ACTIONS CMUX_TAG)

# run_own COMMAND...: run it as a LaunchAgent in this user's own gui/<uid> domain, stream its output, exit with its code.
run_own() {
  local uid label dir var rc waited bound
  uid="$(id -u)"
  if ! launchctl print "gui/$uid" >/dev/null 2>&1; then
    echo "CONSOLE-SESSION-FAIL reason=no GUI login for $(id -un) (launchctl print gui/$uid failed); log that user in or use CONSOLE_SESSION=auto" >&2
    exit 4
  fi
  label="com.cmux.console-session.$$"
  dir="$(mktemp -d "${TMPDIR:-/tmp}/console-session.XXXXXX")"
  {
    echo '#!/bin/bash'
    for var in "${pass_vars[@]}"; do
      [ -n "${!var+set}" ] && printf 'export %s=%q\n' "$var" "${!var}"
    done
    printf 'cd %q 2>/dev/null || true\n' "${GITHUB_WORKSPACE:-$PWD}"
    printf '%q ' "$@"
    printf '>%q 2>&1\necho $? >%q\n' "$dir/out" "$dir/rc.tmp"
    printf 'mv %q %q\n' "$dir/rc.tmp" "$dir/rc"
  } >"$dir/run.sh"
  chmod 755 "$dir/run.sh"
  : >"$dir/out"
  cat >"$dir/agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$dir/run.sh</string></array>
<key>RunAtLoad</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
  echo "Running in $(id -un)'s own Aqua session (gui/$uid, LaunchAgent $label): $*" >&2
  if ! launchctl bootstrap "gui/$uid" "$dir/agent.plist" 2>"$dir/bootstrap.err"; then
    echo "CONSOLE-SESSION-FAIL reason=launchctl bootstrap gui/$uid failed: $(tr '\n' ' ' <"$dir/bootstrap.err")" >&2
    exit 4
  fi
  tail -n +1 -f "$dir/out" &
  local tailer=$!
  bound="${CONSOLE_SESSION_TIMEOUT:-7200}" waited=0
  while [ ! -f "$dir/rc" ] && [ "$waited" -lt "$bound" ]; do sleep 1; waited=$((waited + 1)); done
  sleep 1
  kill "$tailer" 2>/dev/null || true
  wait "$tailer" 2>/dev/null || true
  launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
  if [ ! -f "$dir/rc" ]; then
    echo "CONSOLE-SESSION-FAIL reason=command still running after ${bound}s (CONSOLE_SESSION_TIMEOUT) in gui/$uid" >&2
    exit 124
  fi
  rc="$(cat "$dir/rc")"
  rm -rf "$dir"
  exit "$rc"
}

[ "$mode" = own ] && run_own "$@"

console_user="$(stat -f %Su /dev/console 2>/dev/null || true)"
manager="$(launchctl managername 2>/dev/null || true)"
# A runner already in Aqua needs no hop, and a hop needs launchctl itself under sudo: a Mac whose sudoers
# grants other commands (purge, fs_usage) but not launchctl runs the command where it is.
if [ "$manager" != Aqua ] && [ -n "$console_user" ] && [ "$console_user" != root ] && [ "$console_user" != loginwindow ] \
  && console_uid="$(id -u "$console_user" 2>/dev/null)" && sudo -n -l launchctl >/dev/null 2>&1; then
  # Try the whole hop before taking it: sudo may grant launchctl yet refuse the second hop to the console user
  # (air-blue, 2026-11-21: "sudo: a password is required" and a bare exit 1). A refused hop says why and runs in
  # this user's own GUI login when there is one.
  hop_err="$(mktemp "${TMPDIR:-/tmp}/console-session-hop.XXXXXX")"
  if ! sudo -n launchctl asuser "$console_uid" sudo -n -u "$console_user" /usr/bin/true >/dev/null 2>"$hop_err"; then
    echo "CONSOLE-SESSION-FAIL reason=hop into console user '$console_user' refused: $(tr '\n' ' ' <"$hop_err")" >&2
    rm -f "$hop_err"
    if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
      echo "console-session: falling back to CONSOLE_SESSION=own" >&2
      run_own "$@"
    fi
    echo "::warning::no hop and no GUI login of $(id -un)'s own; running where it is, the bench's windows may not draw." >&2
    exec "$@"
  fi
  rm -f "$hop_err"
  console_home="$( (dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null || true) | awk '{print $2}')"
  [ -n "$console_home" ] || console_home="$HOME"
  env_pairs=()
  for var in "${pass_vars[@]}"; do
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
if [ "$manager" != Aqua ]; then
  echo "::warning::Not in a console user's Aqua session (console user '${console_user:-none}', no passwordless sudo hop); the bench's windows may not draw." >&2
fi
exec "$@"
