#!/usr/bin/env python3
"""One build per host in a fixed build root, taken without waiting.

    exec 9>>LOCK; host_build_lock.py acquire LOCK --fd 9
        exit 0: the open file description behind fd 9 now holds flock(2) on LOCK;
        exit 1: another build holds it (its record is printed); 2: any other error.
    host_build_lock.py probe LOCK      exit 0: free; 1: held (for tests and diagnostics)

compile-dev-release.sh builds the DEV Release app from one fixed tree per host, so the
compilation cache's keys (which hold the absolute paths) match across the host's runner
instances, and two of them must never build there at once. The lock is the kernel's: flock(2)
on the caller's descriptor, which the caller and every child it starts (canonical-build-root,
xcodebuild, ditto) share. It is held while any of them is alive and released by the kernel when
the last one exits, however it exits: a job killed with SIGKILL while its xcodebuild still runs
keeps the root until that xcodebuild is gone too, and never leaves a lock behind. There is no
pid file to go stale. The file's content only names the holder for a busy caller's log.

Nothing waits: a held lock is exit 1 at once, and the caller builds on its own per-runner path.
"""
from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import sys
import time


def holder(lock: str) -> str:
    try:
        with open(lock, encoding="utf-8", errors="replace") as f:
            return f.read(512).strip() or "unknown"
    except OSError:
        return "unknown"


def try_lock(fd: int) -> bool:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError as e:
        if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            return False
        raise


def acquire(lock: str, fd: int) -> int:
    st, fst = os.stat(lock), os.fstat(fd)
    if (st.st_dev, st.st_ino) != (fst.st_dev, fst.st_ino):
        print(f"host_build_lock: fd {fd} is not {lock}", file=sys.stderr)
        return 2
    if not try_lock(fd):
        print(f"host_build_lock: {lock} is held by {holder(lock)}", file=sys.stderr)
        return 1
    record = {"pid": os.getppid(), "runner": os.environ.get("RUNNER_NAME", ""),
              "run": os.environ.get("GITHUB_RUN_ID", ""), "since": int(time.time())}
    os.ftruncate(fd, 0)
    os.write(fd, (json.dumps(record) + "\n").encode())
    return 0


def probe(lock: str) -> int:
    try:
        fd = os.open(lock, os.O_RDWR | os.O_CLOEXEC)
    except FileNotFoundError:
        return 0
    try:
        return 0 if try_lock(fd) else 1
    finally:
        os.close(fd)  # the only reference: a lock taken here goes with it


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("command", choices=("acquire", "probe"))
    ap.add_argument("lock")
    ap.add_argument("--fd", type=int)
    args = ap.parse_args(argv)
    try:
        if args.command == "probe":
            return probe(args.lock)
        if args.fd is None:
            print("host_build_lock: acquire needs --fd", file=sys.stderr)
            return 2
        return acquire(args.lock, args.fd)
    except OSError as e:
        print(f"host_build_lock: {args.command} {args.lock}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
