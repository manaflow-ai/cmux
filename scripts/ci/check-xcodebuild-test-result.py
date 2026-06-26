#!/usr/bin/env python3
"""Decide whether a non-zero xcodebuild test exit can be accepted."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SUMMARY_RE = re.compile(r"Executed.*tests?.*with.*failures?")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exit-code", required=True, type=int)
    parser.add_argument("log_path", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.exit_code == 0:
        return 0

    output = args.log_path.read_text(encoding="utf-8", errors="replace")
    summary = ""
    for line in output.splitlines():
        if SUMMARY_RE.search(line):
            summary = line

    if "(0 unexpected)" in summary:
        print("All failures are expected, treating as pass")
        return 0

    print("Unexpected test failures detected")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
