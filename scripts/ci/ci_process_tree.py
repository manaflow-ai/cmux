#!/usr/bin/env python3
"""Find and stop a command's whole process tree, not just its process group.

SwiftPM starts `swiftpm-testing-helper` in its own process group, so
`os.killpg` on the command a CI script launched leaves the helper, which is the
process actually running the tests, alive after a timeout. These helpers walk
parent links instead.
"""

from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path
from typing import Optional

TERM_GRACE_SECONDS = 5.0
KILL_REAP_SECONDS = 1.0


def process_tree(root: int) -> list[tuple[int, str]]:
    """The root's descendants (and itself), by parent link.

    SwiftPM starts `swiftpm-testing-helper` in its own process group, so a
    process-group lookup or `killpg` misses the process that actually hangs.
    """
    try:
        listing = subprocess.run(
            ["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "comm="],
            check=False,
            capture_output=True,
            text=True,
            # Cancellation is on the runner's short signal grace period. A
            # stuck `ps` must not make cleanup outlive that window.
            timeout=1,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    children: dict[int, list[int]] = {}
    names: dict[int, str] = {}
    for row in listing.splitlines():
        fields = row.split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            pid, parent = int(fields[0]), int(fields[1])
            children.setdefault(parent, []).append(pid)
            names[pid] = Path(fields[2].strip()).name
    tree, pending = [], [root]
    while pending:
        pid = pending.pop()
        if pid in names:
            tree.append((pid, names[pid]))
        pending.extend(child for child in children.get(pid, ()) if child != pid)
    return tree


def wait_group_gone(pgid: int, seconds: Optional[float] = None) -> None:
    """Return once no process is left in group PGID, or after SECONDS. SIGKILL is delivered asynchronously: a
    member that was sent it may still be running for a moment, and a caller that returns then (and its retry, or
    the test that checks) would see it alive (cmux#41767 review F1)."""
    # KILL_REAP_SECONDS is read now, not at definition, so a caller (or a test) that lowers it is obeyed.
    deadline = time.monotonic() + (KILL_REAP_SECONDS if seconds is None else seconds)
    while True:
        try:
            os.killpg(pgid, 0)
        except (ProcessLookupError, PermissionError):
            return
        if time.monotonic() >= deadline:
            return
        time.sleep(0.02)


def signal_pid(pid: int, signum: int) -> None:
    try:
        os.kill(pid, signum)
    except (ProcessLookupError, PermissionError):
        pass


def terminate(
    process: subprocess.Popen,
    first_signal: int = signal.SIGTERM,
    tree: Optional[list[tuple[int, str]]] = None,
) -> None:
    """Stop the command's process group and every descendant that left it."""
    # Capture the tree first: once the leader dies its children are reparented
    # and can no longer be found from it.
    # Foreground commands need not lead a process group. Include the owned root
    # even if ps could not take a snapshot, so it still receives both signals.
    strays = [pid for pid, _ in (tree if tree is not None else process_tree(process.pid))]
    if process.pid not in strays:
        strays.append(process.pid)
    # macOS refuses killpg with EPERM once the reaped leader's group holds only
    # exiting members (cmux-lawrence-2, 2026-10-09): the group is as good as
    # gone, and the strays below are still signalled one by one.
    try:
        os.killpg(process.pid, first_signal)
    except (ProcessLookupError, PermissionError):
        pass
    for pid in strays:
        signal_pid(pid, first_signal)
    try:
        process.wait(timeout=TERM_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    for pid in strays:
        signal_pid(pid, signal.SIGKILL)
    # A SIGKILL can still fail to become waitable immediately (for example
    # while a runner is losing its parent). Never let cancellation hang here.
    try:
        process.wait(timeout=KILL_REAP_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    # The group's other members got SIGKILL whether or not the leader had exited; return once they are gone.
    wait_group_gone(process.pid)


def terminate_pid(
    pid: int,
    first_signal: int = signal.SIGTERM,
    tree: Optional[list[tuple[int, str]]] = None,
) -> None:
    """Stop a child identified by PID, including descendants outside its group.

    PTY wrappers use ``os.waitpid`` rather than ``subprocess.Popen`` and cannot
    use :func:`terminate` directly. Keep the same parent-tree plus process-group
    coverage for those children, and reap the direct child before returning.
    """
    strays = [child_pid for child_pid, _ in (tree if tree is not None else process_tree(pid))]
    try:
        os.killpg(pid, first_signal)
    except (ProcessLookupError, PermissionError):
        pass
    # A caller may use a child that is not its group's leader. Always address
    # the owned root directly too, including when the snapshot is unavailable.
    signal_pid(pid, first_signal)
    for child_pid in strays:
        signal_pid(child_pid, first_signal)

    reaped = False
    deadline = time.monotonic() + TERM_GRACE_SECONDS
    while time.monotonic() < deadline:
        try:
            finished, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            reaped = True
            break
        if finished:
            reaped = True
            break
        time.sleep(0.05)

    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    if not reaped:
        signal_pid(pid, signal.SIGKILL)
    for child_pid in strays:
        signal_pid(child_pid, signal.SIGKILL)
    if not reaped:
        deadline = time.monotonic() + KILL_REAP_SECONDS
        while time.monotonic() < deadline:
            try:
                finished, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                break
            if finished:
                break
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    wait_group_gone(pid)


def run_bounded(
    command: list[str],
    *,
    timeout: float,
    capture_output: bool = False,
    input: Optional[str | bytes] = None,
    check: bool = False,
    **popen: object,
) -> subprocess.CompletedProcess:
    """subprocess.run's shape and answers, but a timeout stops the command's whole tree.

    subprocess.run kills only the process it started: a `git submodule update` that timed out left its `git clone`
    and transport running, and the retry over the same checkout failed at once (cmux#41752 review F1). Here the
    command runs in its own session, and on a timeout terminate() stops its process group and every descendant
    and reaps the command before TimeoutExpired is raised (with the output read so far)."""
    if capture_output:
        popen.setdefault("stdout", subprocess.PIPE)
        popen.setdefault("stderr", subprocess.PIPE)
    if input is not None:
        popen["stdin"] = subprocess.PIPE
    process = subprocess.Popen(command, start_new_session=True, **popen)
    try:
        out, err = process.communicate(input=input, timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate(process)
        try:
            out, err = process.communicate(timeout=TERM_GRACE_SECONDS)
        except (subprocess.TimeoutExpired, ValueError):
            out, err = None, None
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        raise subprocess.TimeoutExpired(command, timeout, output=out, stderr=err) from None
    except BaseException:
        terminate(process)
        raise
    done = subprocess.CompletedProcess(command, process.returncode, out, err)
    if check:
        done.check_returncode()
    return done
