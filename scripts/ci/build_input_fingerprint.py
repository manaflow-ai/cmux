#!/usr/bin/env python3
"""Hash everything compile admission can read, so equal hashes mean an equal build.

The hash covers the git tree entries (mode, object id, path) of every tracked
path except those known not to reach the Xcode build, plus any extra strings the
caller pins (the selected Xcode). Two commits with the same fingerprint compile
the same sources with the same toolchain, whatever else differs between them.
"""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from detect_ci_change_areas import is_macos_change  # noqa: E402

CI_WORKFLOW = ".github/workflows/ci.yml"


def reaches_the_build(path: str) -> bool:
    """False only for paths the router already calls macOS-neutral, and for CI
    plumbing the Xcode build never opens: guard tests, other workflows, Markdown."""
    if path == CI_WORKFLOW:
        return True
    if path.startswith((".github/", "tests/", "tests_v2/")) or path.endswith(".md"):
        return False
    return is_macos_change(path)


def fingerprint(tree_lines: list[str], extra: list[str]) -> str:
    digest = hashlib.sha256()
    for line in sorted(tree_lines):
        # "<mode> <type> <object>\t<path>"
        path = line.split("\t", 1)[1]
        if reaches_the_build(path):
            digest.update(line.encode("utf-8") + b"\n")
    for value in extra:
        digest.update(b"extra:" + value.encode("utf-8") + b"\n")
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--extra", action="append", default=[])
    args = parser.parse_args(argv)
    lines = subprocess.check_output(
        ["git", "-c", "core.quotepath=off", "ls-tree", "-r", args.revision], text=True
    ).splitlines()
    print(fingerprint(lines, args.extra))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
