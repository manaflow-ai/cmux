#!/usr/bin/env python3
"""Decide whether a non-zero xcodebuild test exit can be accepted.

Xcode can occasionally return non-zero after XCTest has already printed
terminal summaries, usually from app-host cleanup on shared macOS runners.
The legacy workflow accepted that shape when the final summary had
``(0 unexpected)``. Keep that contract, but inspect every summary so an earlier
suite with unexpected failures cannot be hidden by a later clean summary.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SUMMARY_RE = re.compile(
    r"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?\s+\((\d+)\s+unexpected\)"
)

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

    summaries: list[tuple[int, int, int, str]] = []
    for line in output.splitlines():
        summary_match = SUMMARY_RE.search(line)
        if summary_match:
            tests = int(summary_match.group(1))
            failures = int(summary_match.group(2))
            unexpected = int(summary_match.group(3))
            summaries.append((tests, failures, unexpected, line.strip()))

    if not summaries:
        print("Unexpected test failures detected: no XCTest execution summaries found")
        return 1

    unexpected_summaries = [
        line
        for _tests, _failures, unexpected, line in summaries
        if unexpected != 0
    ]
    if unexpected_summaries:
        print("Unexpected test failures detected in XCTest summaries:")
        for line in unexpected_summaries:
            print(f"  {line}")
        return 1

    if not any(tests > 0 for tests, _failures, _unexpected, _line in summaries):
        print("Unexpected test failures detected: no XCTest summary executed any tests")
        return 1

    print("XCTest summaries reported zero unexpected failures; accepting non-zero xcodebuild exit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
