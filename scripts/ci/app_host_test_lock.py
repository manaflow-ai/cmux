#!/usr/bin/env python3
"""Acquire a machine-local exclusive lock, then exec a command holding it.

Used by run-app-host-xcodebuild.sh to serialize GUI app-host tests on a single
self-hosted Mac: a GUI test host owns the machine's one login session +
testmanagerd while it runs, so only one may run at a time per machine.

This uses fcntl.flock, a real kernel advisory lock keyed to the open file
description. The kernel releases it automatically when the holding process exits
(even on crash), so there is no stale lock to detect and no time-based or
pid-based recovery race: correctness does not depend on any cleanup running.

The lock fd has its close-on-exec flag cleared and is inherited across exec, so
the lock stays held for the entire lifetime of the exec'd command and is
released the instant that process ends. Different machines use different local
lock files, so cross-machine parallelism is preserved.

Usage: app_host_test_lock.py <lock_file> <wait_seconds> <command> [args...]
Exits 1 if the lock is not acquired within <wait_seconds> (never runs unlocked).
"""

import errno
import fcntl
import os
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

    fd = os.open(lock_file, os.O_CREAT | os.O_RDWR, 0o644)
    # Keep the lock across exec: clear FD_CLOEXEC so the inheriting process holds
    # it until it exits, then the kernel releases it.
    flags = fcntl.fcntl(fd, fcntl.F_GETFD)
    fcntl.fcntl(fd, fcntl.F_SETFD, flags & ~fcntl.FD_CLOEXEC)

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
        os.write(fd, ("%d\n" % os.getpid()).encode())
    except OSError:
        pass
    sys.stderr.write("Holding app-host test lock: %s (pid %d)\n" % (lock_file, os.getpid()))

    os.execvp(command[0], command)
    return 127  # unreachable if exec succeeds


if __name__ == "__main__":
    sys.exit(main())
