#!/usr/bin/env python3
"""Every multi-crate clippy gate reports every crate, not just the first.

`cargo clippy ... -- -D warnings` turns a lint into a compile error, and without
`--keep-going` cargo stops at the first crate that fails: one run buys exactly
one crate's worth of answer, and every later crate stays invisible until someone
fixes the first one and pays for another run. Measured on Linux CI 2026-11-22
(workers/cmux-vm/cli, two crates with one lint each): without the flag the run
named 1 of 2 crates, with it the same tree named both.

cmux-tui.yml and cmux-tui-rust-check.sh's workspace clippy already carry it
(2026-10-29, four fleet rounds that each showed only the next crate's errors).
This test keeps the rest of the class with them.

In class: a `cargo clippy` command that denies warnings (`-D warnings`) and can
lint more than one crate (`--workspace`, `--all`, or two or more `-p`). Out of
class: single-crate gates (nothing to continue to) and the `--message-format=json`
collectors (the panic ratchet and the affected-package list), which deny nothing.

The shell script passes the flag through its `keep_going` array, which
CMUX_RUST_CHECK_FAIL_FAST=1 empties; that counts as carrying the flag.

A detector, not a gate: it is registered `manual` and no workflow step runs it,
so a pull request that adds another multi-crate gate is not made red for it.
Run it yourself after changing a clippy command. Keep it out of a blocking lane
unless Leo asks for a guard.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FILES = sorted((ROOT / ".github/workflows").glob("*.yml")) + [
    ROOT / "scripts/ci/cmux-tui-rust-check.sh"
]
DASH_P = re.compile(r"(?<![\w-])-p\s+\S+")


def commands(path: pathlib.Path) -> list[tuple[int, str]]:
    """Every `cargo clippy` command in the file, with backslash continuations joined."""
    lines = path.read_text().splitlines()
    out: list[tuple[int, str]] = []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if "cargo" not in stripped or "clippy" not in stripped:
            continue
        if stripped.startswith("#") or "--fix" in stripped:
            continue
        joined, j = stripped, i + 1
        while joined.endswith("\\") and j < len(lines):
            joined = joined[:-1] + " " + lines[j].strip()
            j += 1
        out.append((i + 1, joined))
    return out


def multi_crate(cmd: str) -> bool:
    return "--workspace" in cmd or "--all " in cmd or len(DASH_P.findall(cmd)) >= 2


def carries_keep_going(cmd: str) -> bool:
    return "--keep-going" in cmd or "keep_going[@]" in cmd


def main() -> int:
    missing: list[str] = []
    checked = 0
    for path in FILES:
        if not path.exists():
            continue
        for lineno, cmd in commands(path):
            if "-D warnings" not in cmd or not multi_crate(cmd):
                continue
            checked += 1
            if not carries_keep_going(cmd):
                missing.append(
                    f"{path.relative_to(ROOT)}:{lineno}: multi-crate clippy gate without "
                    f"--keep-going, so it reports only the first crate with a lint:\n    {cmd}"
                )
    if not checked:
        print("error: found no multi-crate clippy gate; this test stopped checking anything")
        return 1
    if missing:
        print("\n".join(missing))
        print(
            "\nAdd --keep-going (the shell script: "
            '${keep_going[@]+"${keep_going[@]}"}) so one run names every crate with a lint.'
        )
        return 1
    print(f"ok: {checked} multi-crate clippy gate(s) carry --keep-going")
    return 0


if __name__ == "__main__":
    sys.exit(main())
