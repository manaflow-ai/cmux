"""Wait for a killed process to exit before asserting that it is gone.

A SIGKILL takes effect on the target's own schedule. On a busy machine the killed process can still be in the process
table, running its exit, after the code that killed it has returned and after a reader of its output has seen EOF.
Once it has exited it is a zombie until its parent reaps it, and `os.kill(pid, 0)` still succeeds on a zombie. So a
test that checks once, `os.kill(pid, 0)` inside `assertRaises(ProcessLookupError)`, fails now and then under load
while the code under test is right. tests/test_lint_process_gone_checks.py flags that check.

died(pid) is True once PID has exited (a zombie counts), within WITHIN seconds. group_died(pgid) is True once no
process is left in the group; a group's zombies count as members until they are reaped, so it waits for the reap.
A test child that sleeps for 30 s or more is still alive at the deadline, so a kill that never happened still fails.

Tests run under `python3 -I`, which puts no script folder on sys.path; load this file by path (see the callers).
"""
import os
import select
import time

WITHIN = 10.0  # seconds: far past a SIGKILL's delivery on a loaded host, far short of a test child's sleep 30


def _zombie(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            stat = f.read()
    except OSError:
        return False
    return stat[stat.rindex(")") + 2:][:1] in ("Z", "X")


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
            return bool(select.select([fd], [], [], within)[0])
        finally:
            os.close(fd)
    deadline = time.monotonic() + within
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False  # another user's process: this pid was reused, or never ours
        if _zombie(pid):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)


def group_died(pgid, within=WITHIN):
    """True once process group PGID has no member left, within WITHIN seconds."""
    deadline = time.monotonic() + within
    while True:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
