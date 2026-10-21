#!/usr/bin/env python3
"""Hold a cmux-next media tour's tag for the rest of its job.

    media_tag_lock.py hold --tag ci-media-pr-123 [--wait SECONDS]
    media_tag_lock.py claim --slots K [--github-env FILE]

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
--worker-pid PID ties the hold to that process instead of the nearest
Runner.Worker above the step, and --worker-pid 0 to --max-hold alone; tests
use it so a hold neither depends on the job they run in nor on timing.

`claim` is how a tour picks its tag. It takes the first free tag of
ci-media-slot0, ci-media-slot1, ... without waiting, holds it like `hold`, and
writes TOUR_SLOT and TOUR_TAG to --github-env. A tag per pull request left a
~9.5 GiB pair per pull request toured on a Mac, and each pull request's first
tour built cold (the base alone took 35 min, job 115856352658). A slot's
DerivedData has the same path whichever pull request tours in it, so the
first K slots are K warm pairs the next tours reuse and the prune keeps. When
all K are held the tour takes the next slot up rather than wait while it holds
a runner; prune_media_derived_data.py --slots K removes those once idle.
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
# Overflow slots past K are tried in order; a Mac never runs this many tours.
MAX_SLOTS = 64
WORKER_PID_HELP = (f"hold until this process exits instead of the nearest {WORKER} above this step; "
                   "0 holds for --max-hold only")


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


def job_worker(args: argparse.Namespace) -> int | None:
    """The process whose exit ends the hold: --worker-pid when given (0 for none), else the job's Runner.Worker."""
    if args.worker_pid is not None:
        return args.worker_pid or None
    return worker_pid(os.getppid())


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


def try_lock(path: Path) -> int | None:
    """An fd holding path's exclusive lock, or None while another process holds it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def slot_tag(slot: int) -> str:
    return f"ci-media-slot{slot}"


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
        time.sleep(1)
    os._exit(0)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    held = sub.add_parser("hold")
    held.add_argument("--tag", required=True)
    held.add_argument("--lock-dir", type=Path, default=DEFAULT_LOCK_DIR)
    held.add_argument("--wait", type=float, default=7200)
    held.add_argument("--max-hold", type=float, default=3 * 3600)
    held.add_argument("--worker-pid", type=int, help=WORKER_PID_HELP)
    claimed = sub.add_parser("claim")
    claimed.add_argument("--slots", type=int, default=2, help="warm slots per Mac (default 2)")
    claimed.add_argument("--lock-dir", type=Path, default=DEFAULT_LOCK_DIR)
    claimed.add_argument("--github-env", type=Path, help="append TOUR_SLOT and TOUR_TAG here")
    claimed.add_argument("--max-hold", type=float, default=3 * 3600)
    claimed.add_argument("--worker-pid", type=int, help=WORKER_PID_HELP)
    args = parser.parse_args(argv)
    if args.worker_pid is not None and args.worker_pid < 0:
        parser.error("--worker-pid must be a process id, or 0 for none")
    if args.command == "claim":
        if not 1 <= args.slots <= MAX_SLOTS:
            parser.error(f"--slots must be 1..{MAX_SLOTS}")
        return claim(args)
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", args.tag):
        parser.error("--tag must be a simple tag name")
    path = args.lock_dir / f"{args.tag}.lock"
    fd = acquire(path, args.wait)
    if fd is None:
        print(f"::error::{path.name} was still held after {args.wait:.0f}s", flush=True)
        return 1
    worker = job_worker(args)
    if worker is None:
        print(f"no {WORKER} above this step; the tag is held for at most {args.max_hold:.0f}s", flush=True)
    hold(fd, path, worker, args.max_hold)
    print(f"holding {path.name}", flush=True)
    return 0


def claim(args: argparse.Namespace) -> int:
    for slot in range(MAX_SLOTS):
        path = args.lock_dir / f"{slot_tag(slot)}.lock"
        try:
            fd = try_lock(path)
        except OSError as error:
            print(f"::warning::cannot lock {path}: {error}", flush=True)
            continue
        if fd is not None:
            break
    else:
        print(f"::error::all {MAX_SLOTS} tour slots in {args.lock_dir} are held", flush=True)
        return 1
    worker = job_worker(args)
    if worker is None:
        print(f"no {WORKER} above this step; the slot is held for at most {args.max_hold:.0f}s", flush=True)
    hold(fd, path, worker, args.max_hold)
    kind = "warm" if slot < args.slots else f"overflow, all {args.slots} warm slots are held"
    print(f"holding {path.name}: tour slot {slot} ({kind})", flush=True)
    if args.github_env:
        with open(args.github_env, "a") as handle:
            handle.write(f"TOUR_SLOT={slot}\nTOUR_TAG={slot_tag(slot)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
