#!/usr/bin/env python3
"""Execute a packaged cmux TUI artifact and verify its stamped identity."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-commit", required=True)
    parser.add_argument("--ghostty-commit", required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    expected = (
        f"cmux-tui {args.version} "
        f"({args.build_commit}; ghostty {args.ghostty_commit})"
    )
    try:
        completed = subprocess.run(
            [str(args.binary), "--version"],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise SystemExit(f"artifact execution failed: {error}") from error

    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise SystemExit(
            f"artifact execution failed with status {completed.returncode}: {detail}"
        )

    lines = completed.stdout.splitlines()
    if lines != [expected] or completed.stderr:
        actual = completed.stdout.rstrip("\r\n")
        detail = f"; stderr: {completed.stderr.strip()}" if completed.stderr else ""
        raise SystemExit(
            f"identity mismatch: expected {expected!r}, got {actual!r}{detail}"
        )

    print(expected)


if __name__ == "__main__":
    main()
