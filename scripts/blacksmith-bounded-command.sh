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
import time

seconds = float(sys.argv[1])
argv = sys.argv[2:]
if not argv:
    raise SystemExit("missing command")
pending_signal = None

# The handler only records the signal; the main flow does all waiting and
# killing. A handler that called Popen.wait itself could run while the
# interrupted Popen.wait held its non-reentrant waitpid lock, and then never
# reap the child: the bound hung, and the Testbox demo's cleanup never began
# to stop the box (main CI fast guards, 2026-11-17).
def record(signum, _frame):
    global pending_signal
    if pending_signal is None:
        pending_signal = signum

# A caller that ignores INT or TERM (a cleanup that must finish) keeps that:
# the child inherits the ignore, and so does this bound.
for signum in (signal.SIGINT, signal.SIGTERM):
    if signal.getsignal(signum) != signal.SIG_IGN:
        signal.signal(signum, record)
process = subprocess.Popen(argv, start_new_session=True)

def reap():
    """The child's exit code once it has ended, else None. Never blocks."""
    if process.returncode is None:
        pid, status = os.waitpid(process.pid, os.WNOHANG)
        if pid:
            process.returncode = os.waitstatus_to_exitcode(status)
    return process.returncode

# Poll instead of blocking, so a signal is acted on within 50 ms wherever it
# lands; a sleep that a signal interrupts resumes, at most 50 ms.
deadline = time.monotonic() + seconds
while pending_signal is None:
    if reap() is not None:
        raise SystemExit(process.returncode)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        pending_signal = signal.SIGTERM
        break
    time.sleep(min(0.05, remaining))

signum = pending_signal
try:
    os.killpg(process.pid, signal.SIGTERM)
except ProcessLookupError:
    pass
grace = time.monotonic() + 5
while reap() is None and time.monotonic() < grace:
    time.sleep(0.05)
if reap() is None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
raise SystemExit(128 + signum)
PY
