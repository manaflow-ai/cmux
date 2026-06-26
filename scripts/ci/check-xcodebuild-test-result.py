#!/usr/bin/env python3
"""Decide whether a non-zero xcodebuild test exit can be accepted.

Xcode can occasionally return non-zero after XCTest has already reported a
clean run, usually from app-host cleanup on shared macOS runners. Accept that
specific runner-cleanup shape, but never accept assertion failures, crashes,
timeouts, or logs that only contain later zero-test bundle summaries.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SUMMARY_RE = re.compile(
    r"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?\s+\((\d+)\s+unexpected\)"
)
TIMEOUT_MARKERS = (
    "xcodebuild unit test timeout",
    "timed out waiting for xcodebuild",
)
FAILURE_MARKERS = (
    re.compile(r"Assertion Failure"),
    re.compile(r"Failing tests:"),
    re.compile(r"Test (Case|Suite) '.*' failed"),
    re.compile(r"^error: Test failed", re.IGNORECASE),
    re.compile(r"^\s*\u2718 (Suite|Test) "),
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
    if args.exit_code == 124 or any(marker in output for marker in TIMEOUT_MARKERS):
        print("Unexpected test failures detected: xcodebuild timed out")
        return 1

    summaries: list[tuple[int, int, int, str]] = []
    failure_markers: list[str] = []
    for line in output.splitlines():
        summary_match = SUMMARY_RE.search(line)
        if summary_match:
            tests = int(summary_match.group(1))
            failures = int(summary_match.group(2))
            unexpected = int(summary_match.group(3))
            summaries.append((tests, failures, unexpected, line.strip()))
        if any(marker.search(line) for marker in FAILURE_MARKERS):
            failure_markers.append(line.strip())

    if not summaries:
        print("Unexpected test failures detected: no XCTest execution summaries found")
        return 1

    # XCTest's "unexpected" count is not a proxy for assertion failures:
    # ordinary failed assertions can still report "(0 unexpected)".
    failing_summaries = [
        line
        for _tests, failures, unexpected, line in summaries
        if failures != 0 or unexpected != 0
    ]
    if failing_summaries:
        print("Unexpected test failures detected in XCTest summaries:")
        for line in failing_summaries:
            print(f"  {line}")
        return 1

    if failure_markers:
        print("Unexpected test failure markers detected:")
        for line in failure_markers:
            print(f"  {line}")
        return 1

    if not any(tests > 0 for tests, _failures, _unexpected, _line in summaries):
        print("Unexpected test failures detected: no XCTest summary executed any tests")
        return 1

    print("XCTest summaries reported zero failures; treating non-zero xcodebuild exit as runner cleanup failure")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
