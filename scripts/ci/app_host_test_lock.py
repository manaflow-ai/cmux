#!/usr/bin/env python3
"""Acquire a machine-local exclusive lock, then exec a command holding it.

Used by run-app-host-xcodebuild.sh to serialize GUI app-host tests on a single
self-hosted Mac: a GUI test host owns the machine's one login session +
testmanagerd while it runs, so only one may run at a time per machine.

This uses fcntl.flock, a real kernel advisory lock keyed to the open file
description. The admitted command inherits that exact open file description.
Its fork/exec descendants therefore retain the machine lease until they exit,
even if the direct command returns a hard timeout failure first. The kernel,
not a cleanup timer, prevents a draining PTY descendant from overlapping the
next app-host test.

The parent wrapper and admitted process tree share this one lock capability.
The app host that XCTest launches through system services is outside that tree,
so it is owned separately by its app-authored process receipt. Different
machines use different local lock files, so cross-machine parallelism is
preserved.

Usage: app_host_test_lock.py <lock_file> <wait_seconds> <command> [args...]
Exits 1 if the lock is not acquired within <wait_seconds> (never runs unlocked).
CMUX_APP_HOST_XCODEBUILD_TOTAL_TIMEOUT_SECONDS is the command's execution
budget. It starts after this lock is acquired, so queue time cannot consume the
budget needed by the admitted app-host test.
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
    total_timeout_raw = os.environ.get(
        "CMUX_APP_HOST_XCODEBUILD_TOTAL_TIMEOUT_SECONDS", ""
    )
    if total_timeout_raw:
        if (
            not total_timeout_raw
            or total_timeout_raw.startswith("0")
            or any(char < "0" or char > "9" for char in total_timeout_raw)
        ):
            sys.stderr.write(
                "invalid CMUX_APP_HOST_XCODEBUILD_TOTAL_TIMEOUT_SECONDS: "
                f"{total_timeout_raw!r}\n"
            )
            return 2

    # Non-inheritable by default (PEP 446). Popen's pass_fds below grants this
    # one capability only to the admitted process tree.
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
            sleep_seconds = min(2, max(0, deadline - time.monotonic()))
            if sleep_seconds > 0:
                time.sleep(sleep_seconds)

    try:
        os.ftruncate(fd, 0)
        os.write(fd, ("%d\n" % os.getpid()).encode())
    except OSError:
        pass
    sys.stderr.write("Holding app-host test lock: %s (pid %d)\n" % (lock_file, os.getpid()))

    # Run the command as a child and wait. The lock stays held by this parent for
    # at least the child's lifetime; forward termination signals so a cancelled
    # CI job tears the child down too. A descendant that remains in the kernel
    # exit path keeps the same lease after the direct child exits. Preserve the
    # validated execution budget unchanged; the command wrapper starts its
    # monotonic deadline now.
    proc = subprocess.Popen(command, pass_fds=(fd,))

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
