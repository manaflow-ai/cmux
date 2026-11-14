"""Wait for a killed process to exit before asserting that it is gone.

A SIGKILL takes effect on the target's own schedule. On a busy machine the killed process can still be in the process
table, running its exit, after the code that killed it has returned and after a reader of its output has seen EOF
(leo-workspace#4363: 6 of 60 loaded runs of test_leo_forward failed `os.kill(child, 0)` right after the kill). Once
it has exited it is a zombie until its parent reaps it, and `os.kill(pid, 0)` still succeeds on a zombie. So a test
that probes with signal 0 fails now and then under load ("it is gone") or passes on a dead process ("it still runs")
while the code under test is right. A process that was never killed stays alive past the deadline, so a wait here
keeps the test's meaning.

    probe(pid)            process_identity.status(): ALIVE, DEAD (exited: gone, or a zombie) or UNKNOWN, now
    died(pid, within)     True once PID is DEAD, within WITHIN seconds
    running(pid)          True when PID is ALIVE now: the check for a process that must survive
    group_died(pgid, ...) True once no live process is left in the group (zombies are not live)

The answers are process_identity's (beside this file): only the kernel's own "no such process" or a zombie state is
DEAD, and UNKNOWN (a ps that fails, times out or prints nothing for a pid the kernel still has) is never counted as
DEAD nor as ALIVE: died() keeps waiting through it and running() is False on it. On Linux died() waits on a pidfd;
elsewhere (macOS: no pidfd, no /proc) it polls status(), so a zombie counts there too. A group is gone once signal 0
finds no such group, or ps lists its members and process_identity says each is DEAD (a group of zombies is gone,
reaped or not, as macOS's EPERM for it and cmux#41316's orphaned zombies need); a group ps lists no member of, or
with a member UNKNOWN, is not. Every ps call is bounded by the time the wait has left (PS_FLOOR at least).

Source of truth: leo-workspace tools/process_gone.py. cmuxterm-hq and cmux carry byte copies in tests/, pinned to a
leo-workspace commit and sha256 in tests/process_gone.pin; change it there, then copy it over. It needs only the
standard library and process_identity.py. Tests run under `python3 -I`, which puts no script folder on sys.path; load
this file by path.
"""
import importlib.util
import os
import select
import subprocess
import sys
import time
from pathlib import Path


def _sibling(name):
    """The module NAME.py beside this file, loaded by path (tests run under `python3 -I`: no script folder on
    sys.path), once per process."""
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / ("%s.py" % name))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


process_identity = _sibling("process_identity")
ALIVE, DEAD, UNKNOWN = process_identity.ALIVE, process_identity.DEAD, process_identity.UNKNOWN
WITHIN = 10.0  # seconds: far past a SIGKILL's delivery on a loaded host, far short of a test child's sleep 30
PS_FLOOR = 0.25  # seconds: the least a ps call gets, even with the wait's time used up


def probe(pid, timeout=None):
    """ALIVE, DEAD or UNKNOWN for PID now (process_identity.status; TIMEOUT bounds its ps, PS_FLOOR at least)."""
    return process_identity.status(pid, None if timeout is None else max(timeout, PS_FLOOR))


def died(pid, within=WITHIN):
    """True once PID has exited (a zombie included), within WITHIN seconds; False if it is still running then, or if
    its state could not be told by then (UNKNOWN is never DEAD)."""
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
        if probe(pid, deadline - time.monotonic()) == DEAD:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)


def running(pid):
    """True when PID is a live process now: not gone, not a zombie, and not UNKNOWN."""
    return probe(pid) == ALIVE


def _group_members(pgid, timeout):
    """The pids ps lists in process group PGID ([] when it lists none), or None when ps cannot answer within TIMEOUT
    (PS_FLOOR at least)."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,pgid="], capture_output=True, text=True,
                             timeout=max(timeout, PS_FLOOR))
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    members = []
    for line in out.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1] == str(pgid) and fields[0].isdigit():
            members.append(int(fields[0]))
    return members


def _members_dead(pgid, deadline):
    """True when ps lists at least one member of PGID and process_identity says every one is DEAD (a zombie is
    DEAD). A ps that cannot answer, a listing with no member of a group the kernel still has, or any member ALIVE or
    UNKNOWN is not proof, so False."""
    members = _group_members(pgid, deadline - time.monotonic())
    if not members:
        return False
    return all(probe(pid, deadline - time.monotonic()) == DEAD for pid in members)


def group_died(pgid, within=WITHIN):
    """True once process group PGID has no live member left, within WITHIN seconds. A zombie is a dead member: one
    SIGKILLed with its parent gone stays a zombie until init (or a runner's subreaper) reaps it, and signal 0 still
    finds its group (cmux#41316), and macOS refuses signal 0 with EPERM to a group of zombies only. So when signal 0
    does not say "no such group", the members ps lists are judged one by one through process_identity."""
    deadline = time.monotonic() + within
    while True:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            pass  # macOS, for a group of zombies only (or another user's group): the members say which
        if _members_dead(pgid, deadline):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
