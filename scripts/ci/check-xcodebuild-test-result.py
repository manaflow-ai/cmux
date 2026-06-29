#!/usr/bin/env python3
"""Decide whether a non-zero xcodebuild test exit can be accepted.

Xcode can occasionally return non-zero after XCTest has already printed
terminal summaries, usually from app-host cleanup on shared macOS runners.
The legacy workflow accepted that shape when the final summary had
``(0 unexpected)``. Keep that contract, but inspect every summary so an earlier
suite with unexpected failures cannot be hidden by a later clean summary.

A timeout is not cleanup noise. The CI watchdogs
(``scripts/ci/xcodebuild_noninteractive.py`` and ci.yml's ``run_unit_tests``)
return exit code 124 when they kill xcodebuild. If that kill landed before
xcodebuild reached a terminal completion marker, the run was still executing
(or hung) and an arbitrary subset of suites never ran, so an early clean
summary would re-mask exactly the partial/hung runs this gate exists to catch
(#5641). A timeout is therefore only tolerated with proof that xcodebuild
reached its terminal summary first -- the genuine "tests finished, app-host
cleanup lingered" case, which the inner wrapper already converts to exit 0/125
when ``POST_TEST_TIMEOUT`` is set but which surfaces as a raw 124 elsewhere.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SUMMARY_RE = re.compile(
    r"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?\s+\((\d+)\s+unexpected\)"
)

# Exit code both CI watchdogs use when they kill xcodebuild.
TIMEOUT_EXIT_CODE = 124

# Distinctive lines the watchdogs print right before the kill. Matching them is
# a backstop for the case where an intermediate shell normalizes the timeout
# exit code away.
TIMEOUT_MARKERS = (
    "xcodebuild unit test timeout after",  # ci.yml run_unit_tests outer watchdog
    "Idle timed out after",  # xcodebuild_noninteractive.py idle watchdog
)

# xcodebuild prints one of these only once the test action runs to completion.
# Their presence proves every selected suite finished, so a post-completion
# cleanup timeout is safe to accept; their absence after a kill means the run
# was truncated.
COMPLETION_MARKERS = (
    "** TEST SUCCEEDED **",
    "** TEST FAILED **",
)
COMPLETION_RE = re.compile(
    r"Test Suite '(?:Selected tests|All tests)' (?:passed|failed) at "
)


def reached_terminal_completion(output: str) -> bool:
    if any(marker in output for marker in COMPLETION_MARKERS):
        return True
    return COMPLETION_RE.search(output) is not None


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

    timed_out = args.exit_code == TIMEOUT_EXIT_CODE or any(
        marker in output for marker in TIMEOUT_MARKERS
    )
    if timed_out and not reached_terminal_completion(output):
        print(
            "Unexpected test failures detected: xcodebuild was killed by a timeout "
            "watchdog before reaching a terminal test summary"
        )
        return 1

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
