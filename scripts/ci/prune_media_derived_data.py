#!/usr/bin/env python3
"""Bound the cmux-next tour's DerivedData on an owned Mac.

    prune_media_derived_data.py --keep-tag TAG [--keep-tag TAG ...]
        [--root DIR] [--slots K] [--keep-others N] [--min-idle-minutes M]

Every tour (.github/workflows/cmux-next-media.yml) builds a base and a head app
with reload.sh --tag, into DerivedData/cmux-ci-media-pr-<N>-{base,head} for a
pull request and cmux-ci-media-feat-cmux-next-{base,head} for merges. Each is
about 9 GiB and nothing removed them: on 2026-10-14 one mini held 8 and a merge
tour failed reload.sh's 40 GiB free-space floor (run 38614931315).

A tour now builds in the slot it claims on the Mac (media_tag_lock.py claim,
DerivedData/cmux-ci-media-slot<N>-{base,head}). Slots below --slots are the
warm pairs the next tours reuse, so they are always kept.

Before building, the tour runs this with its own two tags. It removes the
least recently used other cmux-ci-media-* dirs (the old per-pull-request
dirs, and overflow slots at or above K), oldest first, until at most
--keep-others remain. A dir is never removed when:

  - a process has a file in it open (lsof); if lsof cannot list open files,
    nothing is removed. The one exception is a dead tour's own app: when every
    process holding the dir runs from inside it, no tour holds its tag and no
    build touched it within --min-idle-minutes, those processes are ended
    (SIGTERM, then SIGKILL) and the dir goes. Run 39199091515 left its chief
    host and acpmux daemon running from cmux-ci-media-pr-21726-head, which
    kept 10 GiB on cmux10s for days,
  - a build touched it within --min-idle-minutes (longer than the tour's
    timeout, so a tour still building elsewhere on this Mac is safe),
  - a tour holds its tag (media_tag_lock.py in --lock-dir): it may be about
    to build into the dir it left idle. The prune takes the tag's lock itself
    while it deletes, so a tour that asks for the tag meanwhile waits,
  - it is a symlink or not a directory, or its name is not cmux-ci-media-<tag>.

Nothing outside cmux-ci-media-* is listed, so other tags' DerivedData is never
touched. Removal is best effort and always exits 0 unless the arguments are bad.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

PREFIX = "cmux-"
MEDIA_NAME = re.compile(r"^cmux-ci-media-[A-Za-z0-9._-]+$")
WARM_SLOT = re.compile(r"^cmux-ci-media-slot(0|[1-9][0-9]*)-(?:base|head)$")
TAG = re.compile(r"^ci-media-[A-Za-z0-9._-]+$")

# Paths a build writes every time (a new log in Logs/Build, products and
# intermediates), checked beside the dir itself. The dir's own time changes only
# when a top-level entry is added, so it alone would make a warm dir look idle.
ACTIVITY_PATHS = (
    "",
    "info.plist",
    "Logs",
    "Logs/Build",
    "Build",
    "Build/Products",
    "Build/Products/Debug",
    "Build/Intermediates.noindex",
    "Index.noindex",
    "SourcePackages",
)


def last_used(path: Path) -> float:
    newest = 0.0
    for relative in ACTIVITY_PATHS:
        try:
            newest = max(newest, (path / relative).lstat().st_mtime)
        except OSError:
            continue
    return newest


def open_paths() -> list[tuple[int, str]] | None:
    """(pid, path) for every file any visible process has open, or None if lsof failed."""
    try:
        result = subprocess.run(
            ["lsof", "-w", "-Fpn"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"lsof failed ({error}); removing nothing")
        return None
    paths = []
    pid = 0
    for line in result.stdout.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid = int(line[1:])
        elif line.startswith("n/"):
            paths.append((pid, line[1:]))
    if not paths:
        # lsof always sees this process's own files; none means it saw nothing.
        print(f"lsof listed no open files (exit {result.returncode}); removing nothing")
        return None
    return paths


def inside(entry: str, path: Path) -> bool:
    real = os.path.realpath(path)
    return entry in (str(path), real) or entry.startswith((str(path) + os.sep, real + os.sep))


def holders(path: Path, opened: list[tuple[int, str]]) -> set[int]:
    """The processes with a file in path open."""
    return {pid for pid, entry in opened if inside(entry, path)}


def executable(pid: int) -> str | None:
    """The file pid runs: /proc on Linux, else ps (the full path on macOS)."""
    try:
        return os.readlink(f"/proc/{pid}/exe")
    except OSError:
        pass
    try:
        done = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout.strip() or None


def own_leftovers(path: Path, pids: set[int]) -> bool:
    """True when every holder runs from inside path: a dead tour's app, chief host or daemon."""
    if not pids or os.getpid() in pids or os.getppid() in pids:
        return False
    for pid in pids:
        running = executable(pid)
        if not running or not inside(running, path):
            return False
    return True


def end_processes(pids: set[int], grace: float = 10.0) -> bool:
    """SIGTERM, then SIGKILL after grace seconds; True once all of them are gone."""
    def alive() -> set[int]:
        left = set()
        for pid in pids:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            except PermissionError:
                pass
            # An exited process its parent has not reaped yet holds no files.
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
            if state.stdout.strip().startswith("Z"):
                continue
            left.add(pid)
        return left

    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in alive():
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        deadline = time.monotonic() + (grace if sig == signal.SIGTERM else 5.0)
        while alive() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not alive():
            return True
    return False


def claim_tag(path: Path, lock_dir: Path) -> int | None:
    """Take this dir's tag lock (media_tag_lock.py) without waiting, or None when a tour holds it or the lock
    cannot be opened. The caller keeps the returned fd until the dir is gone: a tour that asks for the tag in
    the meantime waits, so it never builds into a dir that is being removed."""
    tag = path.name[len(PREFIX):]
    for side in ("-base", "-head"):
        if tag.endswith(side):
            tag = tag[: -len(side)]
    try:
        lock_dir.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock_dir / f"{tag}.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644)
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def allocated_gib(path: Path) -> float:
    total = 0
    for current, dirs, files in os.walk(path):
        for name in dirs + files:
            try:
                total += os.lstat(os.path.join(current, name)).st_blocks * 512
            except (OSError, AttributeError):
                continue
    return total / 2**30


def media_dirs(root: Path, keep: set[str], slots: int) -> list[Path]:
    found = []
    try:
        entries = sorted(root.iterdir())
    except OSError as error:
        print(f"{root}: cannot list ({error}); removing nothing")
        return []
    for entry in entries:
        if entry.name in keep or not MEDIA_NAME.match(entry.name):
            continue
        slot = WARM_SLOT.match(entry.name)
        if slot and int(slot.group(1)) < slots:
            continue
        if entry.is_symlink() or not entry.is_dir():
            print(f"{entry.name}: not a plain directory; leaving it")
            continue
        found.append(entry)
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path,
                        default=Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData")
    parser.add_argument("--keep-tag", action="append", default=[], required=True,
                        help="a reload.sh tag this run builds; its DerivedData is kept")
    parser.add_argument("--keep-others", type=int, default=2,
                        help="media dirs to keep besides this run's own (default 2, one pair)")
    parser.add_argument("--slots", type=int, default=0,
                        help="warm tour slots on this Mac; their dirs are always kept (default 0)")
    parser.add_argument("--lock-dir", type=Path, default=Path.home() / "Library/Caches/cmux-ci-media/locks",
                        help="media_tag_lock.py's lock dir: a dir whose tag a tour holds is kept")
    parser.add_argument("--min-idle-minutes", type=int, default=150,
                        help="never remove a dir a build touched more recently (default 150)")
    args = parser.parse_args()
    for tag in args.keep_tag:
        if not TAG.match(tag):
            parser.error(f"--keep-tag {tag!r} is not a ci-media-* tag")
    if args.keep_others < 0 or args.min_idle_minutes < 0 or args.slots < 0:
        parser.error("--slots, --keep-others and --min-idle-minutes must not be negative")

    keep = {PREFIX + tag for tag in args.keep_tag}
    candidates = media_dirs(args.root, keep, args.slots)
    print(f"{len(candidates)} media DerivedData dir(s) in {args.root} outside this tour's and the "
          f"{args.slots} warm slots'; keeping at most {args.keep_others}")
    if len(candidates) <= args.keep_others:
        return 0
    opened = open_paths()
    if opened is None:
        return 0

    cutoff = time.time() - args.min_idle_minutes * 60
    remaining = len(candidates)
    freed = 0.0
    for path in sorted(candidates, key=last_used):
        if remaining <= args.keep_others:
            break
        if last_used(path) > cutoff:
            print(f"{path.name}: built within {args.min_idle_minutes} min; keeping it")
            continue
        held = holders(path, opened)
        if held and not own_leftovers(path, held):
            print(f"{path.name}: open in a process; keeping it")
            continue
        claim = claim_tag(path, args.lock_dir)
        if claim is None:
            # Tours of other tags run beside this one; that tour holds its tag before it builds into it.
            print(f"{path.name}: a tour holds its tag (or its lock cannot be opened); keeping it")
            continue
        try:
            if held:
                print(f"{path.name}: only its own app's processes {sorted(held)} hold it; ending them")
                again = open_paths() if end_processes(held) else None
                if again is None or holders(path, again):
                    print(f"{path.name}: still open; keeping it")
                    continue
            size = allocated_gib(path)
            shutil.rmtree(path)
        except OSError as error:
            print(f"{path.name}: could not remove ({error}); keeping it")
            continue
        finally:
            os.close(claim)
        remaining -= 1
        freed += size
        print(f"{path.name}: removed ({size:.1f} GiB)")
    print(f"freed {freed:.1f} GiB; {remaining} other media dir(s) left")
    return 0


if __name__ == "__main__":
    sys.exit(main())
