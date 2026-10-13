#!/bin/bash
# Stop what run-host.sh started (cnx-hostd, the cmux-tui session daemon, acpmux).
# Your sign-in, logs and acpmux sessions stay in $CNX_HOST_HOME (default ~/.cnx-host);
# `run-host.sh --sign-out` forgets the sign-in, and deleting the folder removes everything.
# --prod stops the production host (~/.cnx-host-prod) instead.
set -uo pipefail
if [[ "${1:-}" == --prod ]]; then home=${CNX_HOST_HOME:-$HOME/.cnx-host-prod}; else home=${CNX_HOST_HOME:-$HOME/.cnx-host}; fi
here=$(cd "$(dirname "$0")" && pwd)
# Ask the session daemon to stop first (its terminals end with it).
for sock in "$home"/sock/*.sock; do
  [[ -S "$sock" ]] && "$here/bin/cmux-tui" daemon stop --socket "$sock" --end-terminals >/dev/null 2>&1
done
for svc in hostd cmux-tui acpmux; do
  pidf="$home/run/$svc.pid"
  [[ -f "$pidf" ]] || continue
  pid=$(cat "$pidf")
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    echo "stopped $svc ($pid)"
  fi
  rm -f "$pidf"
done
rm -f "$home"/sock/*.sock
echo "cnx host stopped."
