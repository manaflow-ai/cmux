#!/usr/bin/env python3
"""Hold a cmux-next media tour's tag for the rest of its job.

    media_tag_lock.py hold --tag ci-media-pr-123 [--wait SECONDS]

A tour builds into per-tag DerivedData (cmux-<tag>-base, cmux-<tag>-head)
kept warm across runs of one pull request, and launches apps whose sockets
and daemon session come from the tag. Several tours run on one Mac at once,
each on its own runner; the workflow's concurrency group keeps two runs of a
pull request apart, but not a cancelled run that is still stopping, a
dispatch, or a merge tour beside a dispatch on the shared feat-cmux-next tag.
Two tours building into one DerivedData at once break its module cache
("ghostty.h has been modified since the module file was built").

`hold` waits for the tag's lock (one file per tag under --lock-dir), then
leaves a background process holding it and returns. The holder lets go when
the job's Runner.Worker exits (the runner also ends a job's leftover
processes) or after --max-hold seconds, so a lost job never keeps a tag.
"""

from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import re
import subprocess
import sys
import time

DEFAULT_LOCK_DIR = Path.home() / "Library/Caches/cmux-ci-media/locks"
WORKER = "Runner.Worker"


def worker_pid(start: int) -> int | None:
    """The nearest Runner.Worker among start's ancestors, from ps."""
    pid = start
    for _ in range(64):
        if pid <= 1:
            return None
        done = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True, text=True)
        fields = done.stdout.strip().split(None, 1)
        if len(fields) != 2:
            return None
        if os.path.basename(fields[1]) == WORKER:
            return pid
        pid = int(fields[0])
    return None


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def acquire(path: Path, wait: float) -> int | None:
    """An fd holding path's exclusive lock, or None after wait seconds."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644)
    deadline = time.monotonic() + wait
    said = False
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            pass
        if not said:
            holder = path.read_text(errors="replace").strip() or "unknown"
            print(f"waiting for {path.name}: held by {holder}", flush=True)
            said = True
        if time.monotonic() >= deadline:
            os.close(fd)
            return None
        time.sleep(2)


def hold(fd: int, path: Path, worker: int | None, max_hold: float) -> None:
    """Fork a holder that keeps fd until the worker exits or max_hold passes; the caller returns."""
    os.ftruncate(fd, 0)
    os.pwrite(fd, f"run {os.environ.get('GITHUB_RUN_ID', '?')} on {os.environ.get('RUNNER_NAME', '?')}\n".encode(), 0)
    if os.fork():
        os.close(fd)
        return
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for target in (0, 1, 2):
        os.dup2(devnull, target)
    deadline = time.monotonic() + max_hold
    while time.monotonic() < deadline and (worker is None or alive(worker)):
        time.sleep(5)
    os._exit(0)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    held = sub.add_parser("hold")
    held.add_argument("--tag", required=True)
    held.add_argument("--lock-dir", type=Path, default=DEFAULT_LOCK_DIR)
    held.add_argument("--wait", type=float, default=7200)
    held.add_argument("--max-hold", type=float, default=3 * 3600)
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", args.tag):
        parser.error("--tag must be a simple tag name")
    path = args.lock_dir / f"{args.tag}.lock"
    fd = acquire(path, args.wait)
    if fd is None:
        print(f"::error::{path.name} was still held after {args.wait:.0f}s", flush=True)
        return 1
    worker = worker_pid(os.getppid())
    if worker is None:
        print(f"no {WORKER} above this step; the tag is held for at most {args.max_hold:.0f}s", flush=True)
    hold(fd, path, worker, args.max_hold)
    print(f"holding {path.name}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
