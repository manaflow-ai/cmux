#!/usr/bin/env python3
"""Repository fetches never recurse into submodules.

`git fetch REMOTE SHA` runs with git's default `fetch.recurseSubmodules=on-demand`. Even a fetch of one named commit
then fetches, inside each submodule, every pin in the history it brings in. One ghostty pin that was later force-pushed
away (`fatal: remote error: upload-pack: not our ref 51cad05...`, `Errors during submodule fetch: ghostty`) then fails
the whole fetch. cmux#60058's launch-ready measurement died that way after 17 hours in the queue, and the split-plan
advisory (cmux#48862) did too. Each script and workflow here fetches commits to read history or to check out its own
tree; `git submodule update` fetches what a checkout needs. So every shell `git fetch` in scripts/ and in
.github/workflows passes `--no-recurse-submodules` (or `--recurse-submodules=no`). A fetch that really wants
submodule commits goes in ALLOWED with the reason.

Usage: python3 tests/test_fetch_no_recurse_submodules.py
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FETCH = re.compile(r"""\bgit(?:\s+-C\s+(?:"[^"]*"|'[^']*'|\S+)|\s+-c\s+\S+)*\s+fetch(?=[\s\\]|$)""")
MESSAGE = re.compile(r"\b(echo|printf|die|log|warn|note)\b")
# "path:text" fragments of fetches that need submodule commits, each with its reason.
ALLOWED: dict[str, str] = {
    # Its schedule runs main's copy (scheduled workflows match main's): the flag lands on main first.
    ".github/workflows/storage-maintenance.yml:git fetch --quiet --filter=blob:none origin":
        "scheduled from main; fix it there",
}


def shell_files() -> list[Path]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "scripts", ".github/workflows"],
                         capture_output=True, text=True, check=True).stdout.split()
    files = []
    for name in out:
        path = ROOT / name
        if not path.is_file():
            continue
        if name.endswith((".sh", ".bash", ".yml", ".yaml")):
            files.append(path)
        elif "." not in path.name:
            first = path.read_bytes()[:200].split(b"\n")[0]
            if first.startswith(b"#!") and b"sh" in first:
                files.append(path)
    return files


def offenders() -> list[str]:
    bad = []
    for path in shell_files():
        try:
            lines = path.read_text().splitlines()
        except UnicodeDecodeError:
            continue
        rel = path.relative_to(ROOT).as_posix()
        for number, line in enumerate(lines, 1):
            text = line.lstrip()
            if text.startswith(("#", "- name:", "name:", "description:")) or "recurse-submodules" in line:
                continue
            match = FETCH.search(line)
            if not match:
                continue
            comment = line.find(" #")
            if comment != -1 and comment < match.start():
                continue
            if MESSAGE.search(line[:match.start()]):
                continue
            if any(rel == key.split(":", 1)[0] and key.split(":", 1)[1] in line for key in ALLOWED):
                continue
            bad.append(f"{rel}:{number}: {text[:160]}")
    return bad


def main() -> int:
    bad = offenders()
    if bad:
        print(f"{len(bad)} git fetch(es) recurse into submodules; pass --no-recurse-submodules "
              "(tests/test_fetch_no_recurse_submodules.py says why):", file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        return 1
    print("every scripts/ and workflow git fetch passes --no-recurse-submodules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
