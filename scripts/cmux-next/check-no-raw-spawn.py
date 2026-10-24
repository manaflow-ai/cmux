#!/usr/bin/env python3
"""NO-RAW-SPAWN ratchet (reviews 1 and 2 of pl-holder-11).

The cmux daemon is multithreaded and receives descriptors it must never pass
on: a terminal's PTY master and its output ring arrive over the holder link.
On macOS a received descriptor stays inheritable from the `recvmsg` to the
`fcntl(F_SETFD)` after it, and a child another daemon thread spawns in that
window inherits it for its whole life. Only the spawning side can close that
window: every child of the daemon starts through `cmux_process::Command`
(`posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` on macOS), which passes
descriptors 0-2 and the ones it is given, and no other.

This guard fails on a raw spawn in the daemon's crates (cmux-tui-core,
cmux-tui, cmux-tui-platform, cmux-pty; product code, not tests):
  - naming std's or tokio's process `Command` (a `use` of it, or its path);
  - `Command::new(` in a file that does not import `cmux_process`'s
    `Command` by name (a glob such as `use super::*` cannot be read here,
    so a file says which `Command` it means: `use cmux_process::Command`,
    or the path `cmux_process::Command::new`);
  - `pre_exec` (std's fork-and-exec hook);
  - `libc::fork`, `vfork`, `posix_spawn`, `posix_spawnp`, an `exec*` call,
    `forkpty`, `nix::unistd::fork`.
Other crates are separate processes that never receive these descriptors.

Existing sites are listed in scripts/cmux-next/raw-spawn-baseline.tsv with
the number of matching lines per FILE and the owner that moves them. A file
with more matches than its row, or with matches and no row, fails: a site
moved out of one file cannot come back in another. A file with fewer
matches than its row also fails until the row is lowered, so the ratchet
only goes down.

Usage: scripts/cmux-next/check-no-raw-spawn.py [repo-root] [--list]
  --list  print every matching line and exit 0.
"""

from __future__ import annotations

import os
import re
import sys

CRATES = ("cmux-tui-core", "cmux-tui", "cmux-tui-platform", "cmux-pty")
SKIP_DIRS = {"target", ".build", "tests", "benches", "examples", "fixtures"}
BASELINE = "scripts/cmux-next/raw-spawn-baseline.tsv"

ALWAYS = re.compile(
    r"\b(?:std|tokio)::process::Command\b"
    r"|\buse\s+(?:std|tokio)::process::\{[^}]*\bCommand\b"
    r"|\bprocess::Command::new\b"
    r"|\.pre_exec\s*\("
    r"|\blibc::(?:fork|vfork|posix_spawnp?|execvp?e?|execl[pe]?|forkpty)\s*\("
    r"|\bnix::unistd::fork\b"
)
HELPER_COMMAND_IMPORT = re.compile(r"\buse\s+cmux_process::(?:Command\b|\{[^}]*\bCommand\b)", re.S)
GROUP_START = re.compile(r"\buse\s+(?:std|tokio)::process::\{")
COMMAND_IN_GROUP = re.compile(r"\bCommand\b")
COMMAND_NEW = re.compile(r"(?<![\w:])Command::new\s*\(")
COMMENT = re.compile(r"^\s*(//|/\*|\*(\s|/|$))")


def matching_lines(text: str) -> list[tuple[int, str]]:
    helper_command = bool(HELPER_COMMAND_IMPORT.search(text))
    found = []
    in_group = False
    for number, line in enumerate(text.splitlines(), 1):
        if COMMENT.match(line):
            continue
        # A multi-line `use std::process::{ ..., Command, ... };`
        if GROUP_START.search(line) and "}" not in line:
            in_group = True
        hit = bool(ALWAYS.search(line))
        if in_group and COMMAND_IN_GROUP.search(line):
            hit = True
        if not hit and not helper_command and COMMAND_NEW.search(line):
            hit = True
        if in_group and "}" in line:
            in_group = False
        if hit:
            found.append((number, line.rstrip()))
    return found


def scan(root: str) -> dict[str, list[tuple[int, str]]]:
    hits: dict[str, list[tuple[int, str]]] = {}
    for crate in CRATES:
        base = os.path.join(root, "cmux-tui", "crates", crate, "src")
        if not os.path.isdir(base):
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
                    with open(path, encoding="utf-8", errors="replace") as f:
                        text = f.read()
                except OSError:
                    continue
                found = matching_lines(text)
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
                print(f"check-no-raw-spawn: bad baseline row: {line!r}", file=sys.stderr)
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
                f"check-no-raw-spawn: {rel} has {len(found)} raw-spawn line(s), baseline {allowed}. "
                "A daemon child must start through cmux_process::Command (it passes descriptors "
                "0-2 and the ones it is given; a raw spawn can pass a PTY master or ring the "
                "daemon is receiving on another thread).",
                file=sys.stderr,
            )
            for number, line in found:
                print(f"  {rel}:{number}: {line.strip()}", file=sys.stderr)
    for rel, (allowed, _) in sorted(baseline.items()):
        count = len(hits.get(rel, []))
        if count < allowed:
            status = 1
            print(
                f"check-no-raw-spawn: {rel} now has {count} raw-spawn line(s), baseline {allowed}. "
                f"Lower its row in {BASELINE} to {count}" + (" (delete the row)" if count == 0 else "") + ".",
                file=sys.stderr,
            )
    if status == 0:
        print(f"check-no-raw-spawn: ok ({sum(len(v) for v in hits.values())} baselined line(s) in {len(hits)} file(s))")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
