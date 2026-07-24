#!/bin/bash
# ============================================================================
# Brings up a REAL EternalTerminal server on loopback, so the transport seam can
# be exercised against `et` itself rather than a mock.
#
# ET is not ssh: it terminates the connection on the server side and reconnects
# internally after a network change, which is the whole reason the seam exists.
# The only way to know cmux's argv and its reconnect ownership are right is to
# carry a real `tmux -CC` control stream over a real et.
#
# Usage: scripts/remote-tmux-et-host.sh [name] [port]
# Exit 0 with the connection details on stdout, non-zero if it could not start.
# ============================================================================
set -uo pipefail

NAME="${1:-cmux-ethost}"
PORT="${2:-2039}"

command -v et >/dev/null 2>&1 || { echo "et not installed" >&2; exit 2; }
command -v etserver >/dev/null 2>&1 || { echo "etserver not installed" >&2; exit 2; }

STATE_ROOT="$HOME/Library/Caches/cmux/remote-tmux-et"
DIR="$STATE_ROOT/$NAME"
if [ -L "$STATE_ROOT" ] || [ -L "$DIR" ]; then
  echo "refusing symlinked et state path" >&2; exit 1
fi
umask 077
mkdir -p "$DIR/logs"
chmod 700 "$DIR"

# etserver wants a pidfile it can write; /var/run needs root, so keep it local.
PIDFILE="$DIR/etserver.pid"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  echo "already running (pid $(cat "$PIDFILE"))"
else
  # Bind loopback only. This is a test server on a developer machine, and an
  # et server accepts real shells — it must not be reachable off-box.
  etserver --port "$PORT" --bindip 127.0.0.1 --pidfile "$PIDFILE" \
           --logdir "$DIR/logs" --daemon >"$DIR/logs/start.out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "etserver failed to start (rc=$rc):" >&2
    tail -5 "$DIR/logs/start.out" >&2
    exit "$rc"
  fi
fi

# Wait for the port rather than sleeping: startup is fast but not instant.
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
  sleep 0.5
done
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "etserver is not accepting connections on $PORT" >&2
  tail -20 "$DIR/logs"/* 2>/dev/null >&2
  exit 1
fi

# A session for the mirror to attach to, on the server both transports reach.
#
# It has to be the server a plain login shell resolves to, because cmux splits the work:
# one-shot commands like the `has-session` check before an attach ride ssh, while the
# control stream rides et. Putting the session on a private TMUX_TMPDIR isolates it from
# the ssh side, so the attach fails with "can't find session" even though the session
# exists. A real et host has both transports landing on the same default server, so the
# harness matches that.
SESSION="${CMUX_ET_SESSION:-etmirror}"
OWNED="$DIR/owned-sessions"
if tmux has-session -t "$SESSION" 2>/dev/null; then
  # Never adopt a session this harness did not create: teardown kills what it owns, and a
  # developer's own session of the same name must survive.
  grep -qxF "$SESSION" "$OWNED" 2>/dev/null \
    || { echo "tmux session '$SESSION' already exists and is not ours; set CMUX_ET_SESSION" >&2; exit 1; }
else
  tmux new-session -d -s "$SESSION" -c "$HOME" 2>>"$DIR/logs/start.out" \
    || { echo "could not create tmux session $SESSION" >&2; exit 1; }
  echo "$SESSION" >>"$OWNED"
fi
SOCKET="$(tmux display-message -p -t "$SESSION" '#{socket_path}' 2>/dev/null)"

cat <<INFO
name:       $NAME
port:       $PORT
state:      $DIR
session:    $SESSION (socket $SOCKET)
client:     et -p $PORT --macserver -c '<command>' $USER@127.0.0.1
INFO
