#!/usr/bin/env python3
"""NO-RAW-FLOCK ratchet (lane c-agenthost, the lock-by-close audit).

An flock lock belongs to the open file description, not to the descriptor.
A child forked while the descriptor is open shares that description until it
execs, so a lock released only by `close` stays held in the child's copy: a
second daemon, a CLI or the next update then waits for it, or reads "busy"
as "another owner is alive". The lock audit found 37 such sites and gave
each an unlock before its close. New code takes a file lock through
`cmux_file_lock::FileLock` (crates/cmux-file-lock), whose Drop unlocks and
then closes.

This guard fails on a new raw file-lock call in cmux-tui product code
(cmux-tui/crates/*/src, every crate but cmux-file-lock; tests are out of
scope, as in check-no-raw-spawn.py):
  - `flock(` (libc, rustix, nix or a bare import), `FlockArg::`,
    `FlockOperation::`;
  - fs4's `FileExt::lock(`, `FileExt::try_lock(`, `FileExt::lock_exclusive(`,
    `FileExt::lock_shared(` and their `try_` forms;
  - a method call `.lock_exclusive(`, `.lock_shared(`,
    `.try_lock_exclusive(` or `.try_lock_shared(` (fs4 and std alike).

Blind spot: std's `File::lock()` and `File::try_lock()` have the names of
`Mutex::lock()` and `Mutex::try_lock()`, so a method call of that form is
not read here (this guard reads text, not types). Only their qualified forms
(`File::lock(&f)`, `FileExt::lock(&f)`) and the `_shared` forms count.

Existing sites are listed in scripts/cmux-next/raw-flock-baseline.tsv with
the number of matching lines per FILE (lead decision 2026-11-13: every site
that stays after the audit, most of them with an unlocking Drop around the
call; their reasons are in the lane notes). A file with more matches than
its row, or with matches and no row, fails. A file with fewer matches than
its row only prints a note to lower the row (exit 0): the pre-push hook
judges a push against the INSTALLED copy of this baseline.

It runs through prepush-gate.py (no CI step of its own). An error in the guard
itself prints a warning and passes (fail open). Its rules are tested by
scripts/cmux-next/tests/check-no-raw-flock.test.sh, which
tests/test_cmux_next_prepush_gate.py runs.

Usage: scripts/cmux-next/check-no-raw-flock.py [repo-root] [--list]
  --list  print every matching line and exit 0.
"""

from __future__ import annotations

import os
import re
import sys

CRATES_DIR = os.path.join("cmux-tui", "crates")
OWN_CRATE = "cmux-file-lock"
SKIP_DIRS = {"target", ".build", "tests", "benches", "examples", "fixtures"}
BASELINE = "scripts/cmux-next/raw-flock-baseline.tsv"

RAW_LOCK = re.compile(
    r"(?<![\w:])(?<!fn )(?:(?:libc|rustix::fs|nix::fcntl)::)?flock\s*\("
    r"|\bFlock(?:Arg|Operation)::"
    r"|\b(?:FileExt|File)::(?:try_)?lock(?:_exclusive|_shared)?\s*\("
    r"|\.(?:try_)?lock_(?:exclusive|shared)\s*\("
)
COMMENT = re.compile(r"^\s*(//|/\*|\*(\s|/|$))")
# Every pattern needs one of these words: a file without them is skipped unread past its bytes.
TRIGGERS = (b"flock", b"Flock", b"lock_exclusive", b"lock_shared", b"FileExt::", b"File::")


def matching_lines(text: str) -> list[tuple[int, str]]:
    """Each line with a raw lock call, once, comments left out."""
    offsets = [match.start() for match in RAW_LOCK.finditer(text)]
    if not offsets:
        return []
    lines = text.split("\n")
    numbers = sorted({text.count("\n", 0, offset) + 1 for offset in offsets})
    return [(n, lines[n - 1].rstrip()) for n in numbers if not COMMENT.match(lines[n - 1])]


def scan(root: str) -> dict[str, list[tuple[int, str]]]:
    hits: dict[str, list[tuple[int, str]]] = {}
    crates = os.path.join(root, CRATES_DIR)
    if not os.path.isdir(crates):
        return hits
    for crate in sorted(os.listdir(crates)):
        base = os.path.join(crates, crate, "src")
        if crate == OWN_CRATE or not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for name in sorted(filenames):
                if not name.endswith(".rs"):
                    continue
                if name == "tests.rs" or name.endswith(("_tests.rs", "_test.rs")):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                try:
                    with open(path, "rb") as f:
                        raw = f.read()
                except OSError:
                    continue
                if not any(word in raw for word in TRIGGERS):
                    continue
                found = matching_lines(raw.decode("utf-8", errors="replace"))
                if found:
                    hits[rel] = found
    return hits


def read_baseline(root: str) -> dict[str, tuple[int, str]]:
    rows: dict[str, tuple[int, str]] = {}
    path = os.path.join(root, BASELINE)
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3 or not parts[1].isdigit() or not parts[2]:
                print(f"check-no-raw-flock: bad baseline row: {line!r}", file=sys.stderr)
                sys.exit(2)
            rows[parts[0]] = (int(parts[1]), parts[2])
    return rows


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    root = os.path.abspath(args[0]) if args else os.getcwd()
    hits = scan(root)
    if "--list" in argv:
        for rel, found in sorted(hits.items()):
            for number, line in found:
                print(f"{rel}:{number}: {line.strip()}")
        return 0
    baseline = read_baseline(root)
    status = 0
    for rel, found in sorted(hits.items()):
        allowed = baseline.get(rel, (0, ""))[0]
        if len(found) > allowed:
            status = 1
            print(
                f"check-no-raw-flock: {rel} has {len(found)} raw file-lock line(s), baseline {allowed}. "
                "Take a file lock through cmux_file_lock::FileLock (take, try_take, take_within): its Drop "
                "unlocks before the close, so a forked child that still holds the descriptor does not keep "
                "the lock.",
                file=sys.stderr,
            )
            for number, line in found:
                print(f"  {rel}:{number}: {line.strip()}", file=sys.stderr)
    for rel, (allowed, _) in sorted(baseline.items()):
        count = len(hits.get(rel, []))
        if count < allowed:
            print(
                f"check-no-raw-flock: {rel} now has {count} raw file-lock line(s), baseline {allowed}. "
                f"Lower its row in {BASELINE} to {count}" + (" (delete the row)" if count == 0 else "") + ".",
                file=sys.stderr,
            )
    if status == 0:
        print(f"check-no-raw-flock: ok ({sum(len(v) for v in hits.values())} baselined line(s) in {len(hits)} file(s))")
    return status


def guarded_main(argv: list[str]) -> int:
    """`main`, failing open on a bug in the guard (not on a finding)."""
    try:
        return main(argv)
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - fail open on any guard bug
        print(f"check-no-raw-flock: WARNING: the guard failed ({type(error).__name__}: {error}); "
              "not applied. Tell the lane owner of the lock audit (c-agenthost) with this line.", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(guarded_main(sys.argv[1:]))
