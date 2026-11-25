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
matches than its row only prints a note to lower the row (exit 0): the
pre-push hook judges the push against the INSTALLED copy of this
baseline, so a refusal there would refuse every push that moves a site.

It runs in the local pre-push gate only (no CI step: agents run their
checks themselves), which refuses a push whose tree has a raw-spawn finding
the base tree did not have. An error in the guard itself prints a warning
and passes (fail open): a bug here must not block every push. Its rules are
tested by scripts/cmux-next/tests/check-no-raw-spawn.test.sh, which
tests/test_cmux_next_prepush_gate.py runs.

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
    r"|\bprocess::Command::new\b"
    r"|\.pre_exec\s*\("
    r"|\blibc::(?:fork|vfork|posix_spawnp?|execvp?e?|execl[pe]?|forkpty)\s*\("
    r"|\bnix::unistd::fork\b"
)
# `use std::process::{..., Command, ...}`, on one line or several.
PROCESS_GROUP = re.compile(r"\buse\s+(?:std|tokio)::process::\{[^}]*\}")
COMMAND_WORD = re.compile(r"\bCommand\b")
HELPER_COMMAND_IMPORT = re.compile(r"\buse\s+cmux_process::(?:Command\b|\{[^}]*\bCommand\b)")
COMMAND_NEW = re.compile(r"(?<![\w:])Command::new\s*\(")
COMMENT = re.compile(r"^\s*(//|/\*|\*(\s|/|$))")
# Every pattern needs one of these words: a file without them is skipped
# unread past its bytes (most of the 1,600 files), which keeps the guard
# under a second.
TRIGGERS = (b"Command", b"pre_exec", b"fork", b"posix_spawn", b"libc::exec")


def matching_lines(text: str) -> list[tuple[int, str]]:
    """Each line with a raw spawn, once, comments left out. The patterns run
    on the whole text (a regex per file, not per line)."""
    hit_offsets = [match.start() for match in ALWAYS.finditer(text)]
    for group in PROCESS_GROUP.finditer(text):
        hit_offsets.extend(group.start() + word.start() for word in COMMAND_WORD.finditer(group.group()))
    if not HELPER_COMMAND_IMPORT.search(text):
        hit_offsets.extend(match.start() for match in COMMAND_NEW.finditer(text))
    if not hit_offsets:
        return []
    lines = text.split("\n")
    numbers = sorted({text.count("\n", 0, offset) + 1 for offset in hit_offsets})
    return [(n, lines[n - 1].rstrip()) for n in numbers if not COMMENT.match(lines[n - 1])]


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
                    with open(path, "rb") as f:
                        raw = f.read()
                except OSError:
                    continue
                if not any(word in raw for word in TRIGGERS):
                    continue
                text = raw.decode("utf-8", errors="replace")
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
            print(
                f"check-no-raw-spawn: {rel} now has {count} raw-spawn line(s), baseline {allowed}. "
                f"Lower its row in {BASELINE} to {count}" + (" (delete the row)" if count == 0 else "") + ".",
                file=sys.stderr,
            )
    if status == 0:
        print(f"check-no-raw-spawn: ok ({sum(len(v) for v in hits.values())} baselined line(s) in {len(hits)} file(s))")
    return status


def guarded_main(argv: list[str]) -> int:
    """`main`, failing open on a bug in the guard (not on a finding)."""
    try:
        return main(argv)
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - fail open on any guard bug
        print(f"check-no-raw-spawn: WARNING: the guard failed ({type(error).__name__}: {error}); "
              "not applied. Tell the Performance Lead (PL-holder) with this line.", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(guarded_main(sys.argv[1:]))
