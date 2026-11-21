"""Is this still my process? ALIVE, DEAD or UNKNOWN, and UNKNOWN is never acted on.

One helper, kept as identical copies in cmuxterm-hq (tools/fleet-reconcilers/process_identity.py, where the capture
launch uses it) and leo-workspace (tools/process_identity.py, where owned_scratch uses it); change both together.
cmuxterm-hq and cmux also carry it in tests/ beside process_gone.py, pinned in tests/process_gone.pin.

status(pid) says whether a pid runs, has exited (a zombie counts) or cannot be told, for a process the caller
started and has not reaped (for process_gone's died() and running(), which import this module).

A pid alone does not name a process: the kernel gives a dead process's pid to the next one. So a process is named by
its pid and its start time (start_time), and check(pid, start) says whether that process still runs:

    ALIVE     the pid runs, and its start time is the recorded one
    DEAD      no process has the pid (or it is a zombie), or the pid runs with another start time (it was reused)
    UNKNOWN   the start time could not be read: /proc/<pid>/stat unreadable for another reason than "no such
              process", `ps` failed or timed out. Nothing is proven, so a caller keeps what it has: it never deletes
              the owner's files, never signals, never takes over (docs/handbook/state-file-read-half-written.md).

Treating a failed read as "dead" reclaims a live owner's work and crashes its run; treating it as "alive" lets a
stranger with a reused pid keep, or be sent, what was the owner's. Standard library only, Python 3.9.
"""
import errno
import os
import subprocess
from pathlib import Path

ALIVE, DEAD, UNKNOWN = "alive", "dead", "unknown"
PS_TIMEOUT_S = 10


def exists(pid):
    """True or False when the kernel says, None when it cannot tell."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return None
    return True


def _proc_ticks(pid):
    """("ticks:<start>", zombie) from /proc, DEAD when there is no such process, UNKNOWN when it cannot be read."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError as error:
        if error.errno in (errno.ENOENT, errno.ESRCH):
            return DEAD
        return UNKNOWN
    try:
        rest = stat[stat.rindex(")") + 2:].split()
        return "ticks:" + rest[19], rest[0] in ("Z", "X")
    except (IndexError, ValueError):
        return UNKNOWN


def _ps_lstart(pid):
    """"lstart:<start>" from ps, DEAD when ps finds no such process, UNKNOWN when ps failed or timed out."""
    try:
        got = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=PS_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return UNKNOWN
    text = " ".join(got.stdout.split())
    if text:
        return "lstart:" + text
    return DEAD if got.returncode == 1 and exists(pid) is False else UNKNOWN


def status(pid, timeout=None):
    """ALIVE while PID runs (not a zombie), DEAD once it has exited (a zombie counts: it has exited, only its parent
    has not reaped it), UNKNOWN when neither /proc nor `ps` could say. No start time: for a pid this caller started
    itself and has not reaped, which no one else can have. TIMEOUT bounds the ps call (PS_TIMEOUT_S by default), so
    a wait with a deadline is not held past it by a ps that hangs."""
    if exists(pid) is False:
        return DEAD
    if Path("/proc/self/stat").exists():
        got = _proc_ticks(pid)
        return (DEAD if got[1] else ALIVE) if isinstance(got, tuple) else got
    try:
        got = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=PS_TIMEOUT_S if timeout is None else timeout)
    except (OSError, subprocess.SubprocessError):
        return UNKNOWN
    letter = got.stdout.strip()[:1]
    if letter:
        return DEAD if letter in ("Z", "X") else ALIVE
    # ps prints nothing both for a pid it does not know (exit 1) and when it failed: only the kernel's own "no such
    # process" makes the empty answer a DEAD.
    return DEAD if got.returncode == 1 and exists(pid) is False else UNKNOWN


def start_time(pid):
    """PID's start time as a string a reused pid does not share ("ticks:N" from /proc, "lstart:..." from ps where
    there is no /proc), DEAD when there is no such process, UNKNOWN when it could not be read."""
    if exists(pid) is False:
        return DEAD
    if Path("/proc/self/stat").exists():
        got = _proc_ticks(pid)
        if isinstance(got, tuple):
            return DEAD if got[1] else got[0]
        return got
    return _ps_lstart(pid)


def check(pid, start):
    """ALIVE, DEAD or UNKNOWN for the process PID that started at START (a start_time() string; a bare `ps -o
    lstart=` string, as older records kept, reads as "lstart:" + it). The method is the one START was read with."""
    if exists(pid) is False:
        return DEAD
    if not isinstance(start, str) or not start:
        return UNKNOWN
    if start.startswith("ticks:"):
        got = _proc_ticks(pid)
        if not isinstance(got, tuple):
            return got
        now, zombie = got
        return DEAD if zombie else (ALIVE if now == start else DEAD)
    want = start if start.startswith("lstart:") else "lstart:" + " ".join(start.split())
    now = _ps_lstart(pid)
    if now in (DEAD, UNKNOWN):
        return now
    return ALIVE if now == want else DEAD
