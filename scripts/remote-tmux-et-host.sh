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
mkdir -p "$DIR/logs" "$DIR/tmux"
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

cat <<INFO
name:       $NAME
port:       $PORT
state:      $DIR
tmux tmpdir:$DIR/tmux
client:     et -p $PORT --macserver -c '<command>' $USER@127.0.0.1
INFO
