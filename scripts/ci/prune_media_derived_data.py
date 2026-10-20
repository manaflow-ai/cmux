#!/usr/bin/env python3
"""Bound the cmux-next tour's DerivedData on an owned Mac.

    prune_media_derived_data.py --keep-tag TAG [--keep-tag TAG ...]
        [--root DIR] [--keep-others N] [--min-idle-minutes M]

Every tour (.github/workflows/cmux-next-media.yml) builds a base and a head app
with reload.sh --tag, into DerivedData/cmux-ci-media-pr-<N>-{base,head} for a
pull request and cmux-ci-media-feat-cmux-next-{base,head} for merges. Each is
about 9 GiB and nothing removed them: on 2026-10-14 one mini held 8 and a merge
tour failed reload.sh's 40 GiB free-space floor (run 38614931315).

Before building, the tour runs this with its own two tags. It removes the
least recently used cmux-ci-media-* dirs other than those, oldest first, until
at most --keep-others remain. A later tour of a pruned pull request only pays
a cold build. A dir is never removed when:

  - a process has a file in it open (lsof); if lsof cannot list open files,
    nothing is removed,
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
import subprocess
import sys
import time
from pathlib import Path

PREFIX = "cmux-"
MEDIA_NAME = re.compile(r"^cmux-ci-media-[A-Za-z0-9._-]+$")
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


def open_paths() -> list[str] | None:
    """Every path any visible process has open, or None if lsof failed."""
    try:
        result = subprocess.run(
            ["lsof", "-w", "-Fn"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"lsof failed ({error}); removing nothing")
        return None
    paths = [line[1:] for line in result.stdout.splitlines() if line.startswith("n/")]
    if not paths:
        # lsof always sees this process's own files; none means it saw nothing.
        print(f"lsof listed no open files (exit {result.returncode}); removing nothing")
        return None
    return paths


def is_open(path: Path, opened: list[str]) -> bool:
    real = os.path.realpath(path)
    prefixes = {str(path) + os.sep, real + os.sep}
    exact = {str(path), real}
    return any(entry in exact or entry.startswith(tuple(prefixes)) for entry in opened)


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


def media_dirs(root: Path, keep: set[str]) -> list[Path]:
    found = []
    try:
        entries = sorted(root.iterdir())
    except OSError as error:
        print(f"{root}: cannot list ({error}); removing nothing")
        return []
    for entry in entries:
        if entry.name in keep or not MEDIA_NAME.match(entry.name):
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
    parser.add_argument("--lock-dir", type=Path, default=Path.home() / "Library/Caches/cmux-ci-media/locks",
                        help="media_tag_lock.py's lock dir: a dir whose tag a tour holds is kept")
    parser.add_argument("--min-idle-minutes", type=int, default=150,
                        help="never remove a dir a build touched more recently (default 150)")
    args = parser.parse_args()
    for tag in args.keep_tag:
        if not TAG.match(tag):
            parser.error(f"--keep-tag {tag!r} is not a ci-media-* tag")
    if args.keep_others < 0 or args.min_idle_minutes < 0:
        parser.error("--keep-others and --min-idle-minutes must not be negative")

    keep = {PREFIX + tag for tag in args.keep_tag}
    candidates = media_dirs(args.root, keep)
    print(f"{len(candidates)} other media DerivedData dir(s) in {args.root}; keeping at most {args.keep_others}")
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
        if is_open(path, opened):
            print(f"{path.name}: open in a process; keeping it")
            continue
        claim = claim_tag(path, args.lock_dir)
        if claim is None:
            # Tours of other tags run beside this one; that tour holds its tag before it builds into it.
            print(f"{path.name}: a tour holds its tag (or its lock cannot be opened); keeping it")
            continue
        try:
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
