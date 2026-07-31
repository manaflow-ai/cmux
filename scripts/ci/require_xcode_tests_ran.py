#!/usr/bin/env python3
"""Fail a selected-test run unless xcodebuild reports at least one test."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def executed_test_count(log: str) -> int | None:
    xctest_counts = [
        int(value) for value in re.findall(r"Executed\s+(\d+)\s+tests?\b", log)
    ]
    swift_testing_counts = [
        int(value)
        for value in re.findall(r"Test run with\s+(\d+)\s+tests?\b", log)
    ]
    counts = xctest_counts + swift_testing_counts
    return max(counts) if counts else None


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: require_xcode_tests_ran.py <xcodebuild-log> <test-selector>",
            file=sys.stderr,
        )
        return 2

    log_path = Path(sys.argv[1])
    selector = sys.argv[2]
    try:
        log = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"::error::Could not read xcodebuild log {log_path}: {error}", file=sys.stderr)
        return 1

    count = executed_test_count(log)
    if count is None:
        print(
            f"::error::Could not determine executed test count for {selector} "
            "from xcodebuild output",
            file=sys.stderr,
        )
        return 1
    if count == 0:
        print(f"::error::{selector} executed 0 tests", file=sys.stderr)
        return 1

    print(f"Executed tests for {selector}: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
