#!/usr/bin/env python3
"""Read an xcodebuild log and print its largest reported executed-test count."""

from __future__ import annotations

import io
import re
import sys


SUMMARY_PATTERNS = (
    re.compile(r"\bExecuted\s+(\d+)\s+tests?\b"),
    re.compile(r"\bTest run with\s+(\d+)\s+tests?\b"),
)


def executed_test_count(log: str) -> int:
    """Return the largest numeric XCTest or Swift Testing run summary."""
    counts = [
        int(match.group(1))
        for pattern in SUMMARY_PATTERNS
        for match in pattern.finditer(log)
    ]
    return max(counts, default=0)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: executed_test_count.py <xcodebuild-log>", file=sys.stderr)
        return 2

    try:
        with io.open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
            log = handle.read()
    except OSError as error:
        print(f"executed_test_count.py: could not read log: {error}", file=sys.stderr)
        return 2

    print(executed_test_count(log))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
