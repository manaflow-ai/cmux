#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || ! "$1" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <timeout-seconds> <command> [args...]" >&2
  exit 64
fi
seconds="$1"
shift

# Prefer GNU coreutils when present, while keeping the operator workflow
# usable on macOS hosts that have neither `timeout` nor `gtimeout`.
for candidate in gtimeout timeout; do
  if command -v "$candidate" >/dev/null && "$candidate" --version 2>&1 | grep -q 'GNU coreutils'; then
    exec "$candidate" --kill-after=5s "${seconds}s" "$@"
  fi
done

exec python3 - "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

seconds = float(sys.argv[1])
argv = sys.argv[2:]
if not argv:
    raise SystemExit("missing command")
process = subprocess.Popen(argv, start_new_session=True)

def terminate(_signum, _frame):
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    raise SystemExit(128 + _signum)

signal.signal(signal.SIGINT, terminate)
signal.signal(signal.SIGTERM, terminate)
try:
    raise SystemExit(process.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    terminate(signal.SIGTERM, None)
PY
