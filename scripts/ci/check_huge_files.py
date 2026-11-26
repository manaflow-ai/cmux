#!/usr/bin/env python3
"""Huge files: no Swift or Rust source file crosses 100,000 bytes, and one already over it never grows.

NOW's `code_shape.huge_files` counts the NEXT app's Swift and Rust source files over 100,000 bytes (about 2,500
lines); the next-no-huge-files goal splits them. The count was 41 on 2026-11-08, 18 after the first splits, then
regrew to 22 and 25 as later work landed in the old parents and new files crossed the line. This check holds the
line at review time: a pull request that makes a file newly exceed the limit, adds a new file over it, or grows a
file that is already over it fails, naming each file, its size before and after, and how to split it.

The scope is NOW's (cmuxterm-hq tools/fleet-reconcilers/now_code_shape.py, `language()`): `.swift` files under
`Packages/macOS/` or `Packages/Shared/` inside a `Sources/` directory, and `.rs` files under `cmux-tui/`, leaving out
tests, fixtures, benches, galleries, vendored and generated code, and the dev-only paths in DEV. Keep the three
patterns in step with NOW's so the gate and the goal count the same files.

The comparison is against the base the pull request merges into, so there is no baseline file to edit: a file
shrinks below the limit and stays there, and a renamed file keeps its old size as its budget (a pure move passes).

  check_huge_files.py check --base SHA [--head REF]   fail when BASE..HEAD makes or grows a file over the limit
  check_huge_files.py list [--ref REF]                 today's offenders, largest first (the burn-down list)

The fast gates run `check` on every feat-cmux-next pull request merged with its base
(scripts/ci/cmux_next_fast_gates.py). It never runs on a push to the base.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

LIMIT = 100_000
ROOTS = ("Packages/macOS/", "Packages/Shared/", "cmux-tui/")
TEST = re.compile(r"(^|/)(Tests?|tests?|UITests|fixtures|benches|bench|gallery)(/|$)|(^|/)tests?\.rs$|_tests?\.rs$")
VENDOR = re.compile(r"(^|/)(vendor|Vendor|third_party|generated|Generated)(/|$)|\+Generated\.swift$|\.generated\.")
DEV = re.compile(r"^cmux-tui/(.+/)?examples/|^cmux-tui/crates/(coord-sim|cmux-duress)/"
                 r"|^cmux-tui/.+/(?!ssh_bench\.rs$)[^/]+_bench\.rs$|^cmux-tui/.+/(test_support|testkit)(/|\.rs$)"
                 r"|(^|/)(BackdropArt\+Entries\.swift|IconName\+Members\.swift|relay_wire\.rs|unicode_tables\.rs)$")
HOW = ("split it with pure moves (no behavior change in the same pull request): a coherent responsibility into a "
       "child module (Rust `mod.rs` + children, Swift extensions in `Type+Area.swift`), inline tests into a "
       "`_tests.rs` file or the package's Tests target; keep each part at 90,000 bytes or less for headroom")


def in_scope(path: str) -> bool:
    """Whether NOW's code_shape counts PATH as NEXT app Swift or Rust source."""
    if TEST.search(path) or VENDOR.search(path) or DEV.search(path):
        return False
    if path.endswith(".swift") and path.startswith(("Packages/macOS/", "Packages/Shared/")) and "/Sources/" in path:
        return True
    return path.endswith(".rs") and path.startswith("cmux-tui/")


def git(repo: Path, *args: str, stdin: str | None = None) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], input=stdin, capture_output=True, text=True,
                          check=True).stdout


def sizes(repo: Path, blobs: list[str]) -> dict[str, int]:
    """Each blob's size in bytes, in one batch."""
    wanted = sorted(set(blobs))
    if not wanted:
        return {}
    out = git(repo, "cat-file", "--batch-check=%(objectname) %(objectsize)", stdin="".join(f"{b}\n" for b in wanted))
    found = {}
    for line in out.splitlines():
        name, _, size = line.partition(" ")
        if size.isdigit():
            found[name] = int(size)
    return found


def changes(repo: Path, base: str, head: str) -> list[tuple[str, str | None, int | None, int]]:
    """(path, old path, old bytes, new bytes) for each in-scope file BASE..HEAD adds, modifies or renames into."""
    raw = git(repo, "-c", "diff.renameLimit=0", "diff", "--raw", "-z", "-M", "--no-abbrev", "--diff-filter=AMR",
              base, head, "--", "*.swift", "*.rs")
    fields = raw.split("\0")
    rows = []
    i = 0
    while i < len(fields) - 1:
        meta = fields[i].split()
        status = meta[4]
        if status[0] == "R":
            old_path, path = fields[i + 1], fields[i + 2]
            i += 3
        else:
            old_path, path = (None if status == "A" else fields[i + 1]), fields[i + 1]
            i += 2
        if in_scope(path):
            rows.append((path, old_path, None if status == "A" else meta[2], meta[3]))
    known = sizes(repo, [blob for _, _, old, new in rows for blob in (old, new) if blob])
    return [(path, old_path, known.get(old) if old else None, known[new]) for path, old_path, old, new in rows]


def findings(repo: Path, base: str, head: str) -> list[str]:
    found = []
    for path, old_path, old, new in changes(repo, base, head):
        if new <= LIMIT or (old is not None and new <= old):
            continue
        moved = f" (moved from {old_path})" if old_path and old_path != path else ""
        if old is None:
            what = f"new file is {new:,} bytes, over the {LIMIT:,}-byte limit"
        elif old <= LIMIT:
            what = f"{old:,} -> {new:,} bytes{moved}: now over the {LIMIT:,}-byte limit"
        else:
            what = f"{old:,} -> {new:,} bytes{moved}: already over the {LIMIT:,}-byte limit and grew by {new - old:,}"
        keep = f"{LIMIT:,} bytes" if old is None or old <= LIMIT else f"its base size ({old:,} bytes)"
        found.append(f"{path}: {what}. Keep it at or under {keep}, or {HOW}.")
    return found


def offenders(repo: Path, ref: str) -> list[tuple[int, str]]:
    """(bytes, path) for each in-scope file over the limit at REF, largest first."""
    out = git(repo, "ls-tree", "-r", "-l", "-z", ref, "--", *ROOTS)
    rows = []
    for entry in out.split("\0"):
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        kind, size = meta.split()[1], meta.split()[3]
        if kind == "blob" and size.isdigit() and int(size) > LIMIT and in_scope(path):
            rows.append((int(size), path))
    return sorted(rows, key=lambda row: (-row[0], row[1]))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    check = sub.add_parser("check")
    check.add_argument("--base", required=True)
    check.add_argument("--head", default="HEAD")
    check.add_argument("--repo", default=".")
    listing = sub.add_parser("list")
    listing.add_argument("--ref", default="HEAD")
    listing.add_argument("--repo", default=".")
    args = ap.parse_args(argv)
    repo = Path(args.repo)
    if args.cmd == "list":
        rows = offenders(repo, args.ref)
        for size, path in rows:
            print(f"{size:>9,}  {path}")
        print(f"{len(rows)} Swift and Rust source file(s) over {LIMIT:,} bytes at {args.ref}", file=sys.stderr)
        return 0
    found = findings(repo, args.base, args.head)
    for finding in found:
        print(f"::error title=Huge files::{finding}")
    print(f"huge files: {len(found)} file(s) made or grown over {LIMIT:,} bytes by {args.base[:11]}..{args.head[:11]}",
          file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
