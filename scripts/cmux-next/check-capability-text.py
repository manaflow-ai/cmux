#!/usr/bin/env python3
"""Fails when a cmux-tui error text tells the user to update the app or daemon.

A capability error ("this daemon lacks X") is a version skew, and the fix is
almost never an update: the matching CLI is already installed next to the
daemon, or the daemon restarts with this CLI. So the text names that CLI or
one exact command (plans/cmux-next/version-skew.md, step 4); the CLI re-execs
the daemon's CLI itself where it may (cli/skew.rs).

Scans string literals in cmux-tui/crates/**/*.rs, outside test files and
comment lines and #[cfg(test)] modules, for "update/upgrade the (cmux) app
or daemon", "update/upgrade cmux(-tui)", "update and relaunch" and the
Japanese "<アプリ|デーモン|cmux|{app}> ... を更新". ALLOWED lists the texts where an
update really is the fix, each with its reason.

Usage: check-capability-text.py [--root DIR]   (default: the repository root)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ENGLISH = re.compile(
    r"\b(?:update|upgrade)\s+(?:the\s+|your\s+)?(?:cmux(?:-tui)?\s+)?(?:app|daemon)\b"
    r"|\b(?:update|upgrade)\s+cmux\b|\bupdate\s+and\s+relaunch\b",
    re.I,
)
JAPANESE = re.compile(r"(?:アプリ|デーモン|cmux|\{app\})[^。\"]{0,16}を更新")
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')

# (path relative to the root, substring of the line): an update is the real fix.
ALLOWED = [
    # A machine-server manifest needs a cmux newer than any installed one:
    # the app-bundled server can only get it from a newer app.
    ("cmux-tui/crates/cmux-server-core/src/reexec.rs", "cmux, so update the app"),
    # Saved state written by a newer cmux: no installed build can open it.
    ("cmux-tui/crates/cmux-tui/src/localization/startup.rs", "saved_state_requires_newer"),
    # A remote host's cmux-tui is older than this client's remote-link
    # protocol: no local CLI can serve that host, so updating its cmux-tui is
    # the fix (a remote route never re-execs; cx-ytw1).
    ("cmux-tui/crates/cmux-tui/src/localization/remote_client.rs", "remote_link_unknown_option"),
]


def is_test_file(path: Path) -> bool:
    parts = path.parts
    return (
        "tests" in parts
        or path.name in ("tests.rs", "test.rs")
        or path.name.endswith("_tests.rs")
        or path.name.endswith("_test.rs")
    )


def violations(root: Path) -> list[str]:
    found = []
    crates = root / "cmux-tui" / "crates"
    for path in sorted(crates.rglob("*.rs")):
        relative = path.relative_to(root)
        if is_test_file(relative) or "target" in relative.parts:
            continue
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for number, line in enumerate(lines, 1):
            # A trailing `#[cfg(test)] mod … {` holds the file's tests.
            if line.strip() == "#[cfg(test)]" and number < len(lines) and re.match(r"\s*mod \w+ \{", lines[number]):
                break
            if line.lstrip().startswith("//"):
                continue
            # A literal may continue on the next line (a trailing `\`).
            text = line + (lines[number] if number < len(lines) and line.rstrip().endswith("\\") else "")
            literals = " ".join(STRING.findall(text)) or (line if line.rstrip().endswith('"') or line.lstrip().startswith(('"', "cmux,")) else "")
            if not (ENGLISH.search(literals) or JAPANESE.search(literals)):
                continue
            if any(str(relative) == allowed and snippet in text for allowed, snippet in ALLOWED):
                continue
            found.append(f"{relative}:{number}: {line.strip()}")
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    found = violations(args.root)
    if found:
        print("capability error texts must not tell the user to update the app or daemon;")
        print("name the matching CLI or one exact command (plans/cmux-next/version-skew.md step 4):")
        for line in found:
            print(f"  {line}")
        return 1
    print("capability texts: no 'update the app/daemon' advice")
    return 0


if __name__ == "__main__":
    sys.exit(main())
