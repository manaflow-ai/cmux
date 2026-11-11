"""Wait for a killed process to exit before asserting that it is gone.

A SIGKILL takes effect on the target's own schedule. On a busy machine the killed process can still be in the process
table, running its exit, after the code that killed it has returned and after a reader of its output has seen EOF.
Once it has exited it is a zombie until its parent reaps it, and `os.kill(pid, 0)` still succeeds on a zombie. So a
test that probes with signal 0 fails now and then under load ("it is gone") or passes on a dead process ("it still
runs") while the code under test is right. tests/test_lint_process_gone_checks.py flags every raw signal-0 probe in a test.

died(pid) is True once PID has exited (a zombie counts), within WITHIN seconds. running(pid) is True when PID is live
now (not gone, not a zombie): the check for a process that must survive. group_died(pgid) is True once no process is
left in the group; a group's zombies count as members until they are reaped, so it waits for the reap,
except where signal 0 to the group is refused (macOS, for a group of zombies only): there a group
whose members are all zombies is gone. On Linux
died() waits on a pidfd; elsewhere (macOS: no pidfd, no /proc) it polls signal 0 and `ps -o stat=`, so a zombie
counts there too. A test child that sleeps for 30 s or more is still alive at the deadline, so a kill that never
happened still fails.

Tests run under `python3 -I`, which puts no script folder on sys.path; load this file by path (see the callers).
"""
import os
import select
import subprocess
import time

WITHIN = 10.0  # seconds: far past a SIGKILL's delivery on a loaded host, far short of a test child's sleep 30


def _state(pid):
    """PID's one-letter process state ("Z" for a zombie), or "" when no process has it, or None when unknown.

    Linux reads /proc; macOS has no /proc, so `ps -o stat= -p PID` answers there (and on Linux without /proc)."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            stat = f.read()
        return stat[stat.rindex(")") + 2:][:1]
    except FileNotFoundError:
        if os.path.isdir("/proc/self"):
            return ""  # /proc works and has no entry: the pid is gone
    except (OSError, ValueError):
        pass
    try:
        out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip()[:1]  # ps prints nothing (and exits 1) for a pid it does not know


def _exited(pid):
    """True when PID is gone or a zombie, False when it runs, None when it cannot be told."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        pass  # another user's process: its state still answers below
    state = _state(pid)
    if state is None:
        return None
    return state in ("", "Z", "X")


def died(pid, within=WITHIN):
    """True once PID has exited (a zombie included), within WITHIN seconds; False if it is still running then."""
    try:
        fd = os.pidfd_open(pid)  # Linux: readable once the process has exited
    except ProcessLookupError:
        return True
    except (AttributeError, OSError):
        fd = None
    if fd is not None:
        try:
            poller = select.poll()  # no fd limit: select.select() refuses an fd at or above FD_SETSIZE (1024)
            poller.register(fd, select.POLLIN)
            return bool(poller.poll(max(within, 0) * 1000))
        finally:
            os.close(fd)
    deadline = time.monotonic() + within
    while True:
        if _exited(pid):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)


def running(pid):
    """True when PID is a live process now: not gone, and not a zombie. The check for one that must survive."""
    return not died(pid, within=0)


def _group_states(pgid):
    """The one-letter states of process group PGID's members ([] when it has none), or None when ps cannot answer."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return [stat[:1] for g, stat in (line.split(None, 1) for line in out.stdout.splitlines() if len(line.split()) >= 2)
            if g == str(pgid)]


def group_died(pgid, within=WITHIN):
    """True once process group PGID has no live member left, within WITHIN seconds."""
    deadline = time.monotonic() + within
    while True:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            # macOS answers EPERM for a group that holds only zombies (and for another user's group): its members'
            # states say which. A ps that cannot answer keeps the group alive.
            states = _group_states(pgid)
            if states is not None and all(s in ("Z", "X") for s in states):
                return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
