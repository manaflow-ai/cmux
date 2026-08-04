#!/usr/bin/env python3
"""Read an xcodebuild log and print its largest reported executed-test count."""

from __future__ import annotations

import io
import re
import sys
from collections.abc import Iterable


SUMMARY_PATTERN = re.compile(
    r"\b(?:Executed|Test run with)\s+(\d+)\s+tests?\b"
)


def executed_test_count(lines: Iterable[str]) -> int:
    """Return the largest numeric XCTest or Swift Testing run summary."""
    largest = 0
    for line in lines:
        for match in SUMMARY_PATTERN.finditer(line):
            largest = max(largest, int(match.group(1)))
    return largest


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: executed_test_count.py <xcodebuild-log>", file=sys.stderr)
        return 2

    try:
        with io.open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
            count = executed_test_count(handle)
    except OSError as error:
        print(f"executed_test_count.py: could not read log: {error}", file=sys.stderr)
        return 2

    print(count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
