#!/usr/bin/env python3
"""Print tests that started without a matching verdict in an xcodebuild log."""

from __future__ import annotations

import argparse
import io
import re
import sys
from collections.abc import Iterable


EVENT_PATTERN = re.compile(
    r"\bTest (?P<swift_started>[A-Za-z0-9_]+\(\)) started\b"
    r"|(?:✔|✘) Test (?P<swift_completed>[A-Za-z0-9_]+\(\))"
    r"|Test Case '-\[(?P<xctest_started>[A-Za-z0-9_.]+ [A-Za-z0-9_]+)\]' started"
    r"|Test Case '-\[(?P<xctest_completed>[A-Za-z0-9_.]+ [A-Za-z0-9_]+)\]' (?:passed|failed)"
)


def tests_without_verdict(lines: Iterable[str]) -> list[str]:
    """Track pending tests in log order with one streaming pass."""
    pending: dict[str, None] = {}
    for line in lines:
        for match in EVENT_PATTERN.finditer(line):
            started = match.group("swift_started") or match.group("xctest_started")
            completed = match.group("swift_completed") or match.group("xctest_completed")
            if started:
                pending.setdefault(started, None)
            elif completed:
                pending.pop(completed, None)
    return list(pending)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", help="xcodebuild log to inspect")
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()
    if args.limit < 1:
        parser.error("--limit must be a positive integer")
    return args


def main() -> int:
    args = parse_args()
    try:
        with io.open(args.log, encoding="utf-8", errors="replace") as handle:
            missing = tests_without_verdict(handle)
    except OSError as error:
        print(f"lost_test_verdicts.py: could not read log: {error}", file=sys.stderr)
        return 2

    for name in missing[: args.limit]:
        print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
