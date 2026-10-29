#!/usr/bin/env python3
"""Decide whether the optional reverse test impact report has work to do."""

from __future__ import annotations

import argparse
import re
from collections.abc import Iterable
from pathlib import Path

APP_PATH_RE = re.compile(r"^(?:Sources/|CLI/|Packages/(?:macOS|Shared)/[^/]+/Sources/)")


def should_report(paths: Iterable[str] | None) -> bool:
    """Return true for app paths, and fail open when the diff is unavailable."""
    if paths is None:
        return True
    return any(APP_PATH_RE.match(path.strip()) for path in paths)


def read_paths(path: Path) -> list[str] | None:
    """Read a changed-path list, treating a missing or unreadable list as unknown."""
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--files-from", type=Path, required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    args = parser.parse_args()
    value = "true" if should_report(read_paths(args.files_from)) else "false"
    with args.github_output.open("a", encoding="utf-8") as output:
        output.write(f"reverse_test_impact={value}\n")
    print(f"reverse_test_impact={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
