#!/usr/bin/env python3
"""Acquire a machine-local exclusive lock, then exec a command holding it.

Used by run-app-host-xcodebuild.sh to serialize GUI app-host tests on a single
self-hosted Mac: a GUI test host owns the machine's one login session +
testmanagerd while it runs, so only one may run at a time per machine.

This uses fcntl.flock, a real kernel advisory lock keyed to the open file
description. The kernel releases it automatically when the holding process exits
(even on crash), so there is no stale lock to detect and no time-based or
pid-based recovery race: correctness does not depend on any cleanup running.

ONLY this parent wrapper holds the lock. The command runs as a child via
subprocess, and the lock fd is never inherited by it (os.open fds are
non-inheritable by default per PEP 446, and subprocess closes non-stdio fds), so
xcodebuild and any app-host it spawns cannot keep the lock alive. An orphaned
app-host therefore cannot hold the lock; the lock is released the instant this
wrapper exits. Different machines use different local lock files, so
cross-machine parallelism is preserved.

Usage: app_host_test_lock.py <lock_file> <wait_seconds> <command> [args...]
Exits 1 if the lock is not acquired within <wait_seconds> (never runs unlocked).
"""

import errno
import fcntl
import os
import signal
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) < 4:
        sys.stderr.write(
            "usage: app_host_test_lock.py <lock_file> <wait_seconds> <command> [args...]\n"
        )
        return 2

    lock_file = sys.argv[1]
    try:
        wait_seconds = float(sys.argv[2])
    except ValueError:
        sys.stderr.write(f"invalid wait_seconds: {sys.argv[2]!r}\n")
        return 2
    command = sys.argv[3:]

    # Non-inheritable by default (PEP 446): children never receive this fd, so
    # only this parent process can hold the lock.
    fd = os.open(lock_file, os.O_CREAT | os.O_RDWR, 0o644)

    deadline = time.monotonic() + wait_seconds
    announced = False
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as exc:
            if exc.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                raise
            if time.monotonic() >= deadline:
                sys.stderr.write(
                    "FAIL: app-host test lock %s not acquired within %ss; "
                    "refusing to run a second GUI test host on this Mac "
                    "(re-run the job)\n" % (lock_file, int(wait_seconds))
                )
                return 1
            if not announced:
                sys.stderr.write(
                    "Waiting for app-host test lock %s "
                    "(another GUI test host holds this Mac)...\n" % lock_file
                )
                announced = True
            time.sleep(2)

    try:
        os.ftruncate(fd, 0)
        os.write(fd, ("%d\n" % os.getpid()).encode())
    except OSError:
        pass
    sys.stderr.write("Holding app-host test lock: %s (pid %d)\n" % (lock_file, os.getpid()))

    # Run the command as a child and wait. The lock stays held by this parent for
    # exactly the child's lifetime; forward termination signals so a cancelled CI
    # job tears the child down too. close_fds (subprocess default on POSIX) keeps
    # the lock fd out of the child.
    proc = subprocess.Popen(command)

    def _forward(signum, _frame):
        try:
            proc.send_signal(signum)
        except ProcessLookupError:
            pass

    for _sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(_sig, _forward)

    return proc.wait()


if __name__ == "__main__":
    sys.exit(main())
