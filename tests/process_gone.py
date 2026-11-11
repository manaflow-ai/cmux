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
    group_died(pgid, ...) True once no process is left in the group

The answers are process_identity's (beside this file): only the kernel's own "no such process" or a zombie state is
DEAD, and UNKNOWN (a ps that fails, times out or prints nothing for a pid the kernel still has) is never counted as
DEAD nor as ALIVE: died() keeps waiting through it and running() is False on it. On Linux died() waits on a pidfd;
elsewhere (macOS: no pidfd, no /proc) it polls status(), so a zombie counts there too. A group's zombies count as
members until they are reaped, so group_died() waits for the reap, except where signal 0 to the group is refused
(macOS, for a group of zombies only): there a group whose members ps lists, all zombies, is gone, and a group ps lists
no member of is UNKNOWN. Every ps call is bounded by the time the wait has left (PS_FLOOR at least).

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


def _group_states(pgid, timeout):
    """The one-letter states of process group PGID's members ([] when ps lists none), or None when ps cannot answer
    within TIMEOUT (PS_FLOOR at least)."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, text=True,
                             timeout=max(timeout, PS_FLOOR))
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
            # states say which. A ps that cannot answer, or lists no member of a group the kernel still has, says
            # nothing (UNKNOWN), so the group is not gone.
            states = _group_states(pgid, deadline - time.monotonic())
            if states and all(s in ("Z", "X") for s in states):
                return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
