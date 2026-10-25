#!/usr/bin/env python3
"""One holder per host for a fixed build root, taken without waiting.

    host_build_lock.py acquire LOCK --pid PID   exit 0: PID holds LOCK; 1: a live process holds it
    host_build_lock.py release LOCK --pid PID   drop LOCK when PID holds it (always exit 0)

compile-dev-release.sh builds the DEV Release app from one fixed tree per host, so the
compilation cache's keys (which hold the absolute paths) match across the host's runner
instances. Two of them must never build there at once. LOCK records its holder: the pid and that
process's start time. A holder that is gone, or whose pid now names another process (pid reuse:
the start time differs), is stale and is replaced, so a job killed with SIGKILL never keeps the
host's root. The check and the write run under flock(2) on LOCK.guard, held only for them, so two
runners cannot both take a free or stale lock. Nothing waits on a holder: a busy lock is exit 1 at
once and the caller builds on its own per-runner path. Any other error is exit 2 (also a
fallback for the caller).
"""
from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import subprocess
import sys
import time

GUARD_SECONDS = 5.0  # the guard covers a read and a write; past this something is wrong


def start_time(pid: int) -> str:
    """The process's start time as ps prints it, or "" when there is no such process."""
    if pid <= 0:
        return ""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return ""
    except PermissionError:
        pass  # alive, another user's
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                         env={**os.environ, "LC_ALL": "C", "TZ": "UTC"}, timeout=10)
    return " ".join(out.stdout.split())


def read_holder(lock: str) -> dict | None:
    try:
        with open(lock, encoding="utf-8") as f:
            holder = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return {}  # unreadable: nobody can be shown to hold it, so it is stale
    return holder if isinstance(holder, dict) else {}


def alive(holder: dict | None) -> bool:
    if not holder:
        return False
    try:
        pid = int(holder.get("pid", 0))
    except (TypeError, ValueError):
        return False
    started = start_time(pid)
    return bool(started) and started == holder.get("started")


class Guard:
    def __init__(self, lock: str):
        self.path = lock + ".guard"
        self.fd = -1

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
        deadline = time.monotonic() + GUARD_SECONDS
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as e:
                if e.errno not in (errno.EWOULDBLOCK, errno.EAGAIN) or time.monotonic() > deadline:
                    raise
                time.sleep(0.02)

    def __exit__(self, *exc):
        os.close(self.fd)  # closing the only descriptor drops the flock


def acquire(lock: str, pid: int) -> int:
    started = start_time(pid)
    if not started:
        print(f"host_build_lock: no process {pid} to hold {lock}", file=sys.stderr)
        return 2
    with Guard(lock):
        holder = read_holder(lock)
        if holder and holder.get("pid") == pid and holder.get("started") == started:
            return 0
        if alive(holder):
            print(f"host_build_lock: {lock} is held by pid {holder.get('pid')} "
                  f"({holder.get('runner') or '?'}, run {holder.get('run') or '?'})", file=sys.stderr)
            return 1
        if holder is not None:
            print(f"host_build_lock: replacing the stale holder of {lock}: {json.dumps(holder)}", file=sys.stderr)
        record = {"pid": pid, "started": started, "runner": os.environ.get("RUNNER_NAME", ""),
                  "run": os.environ.get("GITHUB_RUN_ID", ""), "since": int(time.time())}
        tmp = f"{lock}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(record, f)
        os.replace(tmp, lock)
    return 0


def release(lock: str, pid: int) -> int:
    try:
        with Guard(lock):
            holder = read_holder(lock)
            if holder and holder.get("pid") == pid:
                os.unlink(lock)
    except OSError as e:
        print(f"host_build_lock: could not release {lock}: {e} (the next taker finds it stale)", file=sys.stderr)
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("command", choices=("acquire", "release"))
    ap.add_argument("lock")
    ap.add_argument("--pid", type=int, required=True)
    args = ap.parse_args(argv)
    lock = os.path.abspath(args.lock)
    try:
        if args.command == "acquire":
            return acquire(lock, args.pid)
        return release(lock, args.pid)
    except (OSError, subprocess.SubprocessError) as e:
        print(f"host_build_lock: {args.command} {lock}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
