#!/usr/bin/env python3
"""Decide whether a non-zero xcodebuild test exit can be accepted.

Xcode can return non-zero after a test action *completed* -- app-host cleanup
noise on shared macOS runners, or a watchdog killing a process that lingered
after every suite finished. The legacy workflow accepted that shape when the
final summary had ``(0 unexpected)``, but a bare summary scan cannot tell
"completed, then cleanup noise" apart from "aborted/hung partway through": both
can show only early clean summaries while later suites never ran. That is
exactly the masking #5641 is about.

So a non-zero exit is accepted only when (a) every parsed XCTest summary reports
zero unexpected failures, (b) at least one summary executed tests, and (c) the
log proves xcodebuild reached its terminal completion marker, which guarantees
every selected suite ran rather than an early prefix. The CI watchdogs
(``scripts/ci/xcodebuild_noninteractive.py`` and ci.yml's ``run_unit_tests``)
return exit code 124 when they kill xcodebuild; that and other mid-run aborts
fail (c) unless terminal completion was already reached.
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
# Their presence proves every selected suite finished, so a subsequent non-zero
# exit (cleanup noise or a watchdog kill of a lingering process) is safe to
# accept; their absence means the run was truncated before finishing.
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

    # The clean summaries above only prove the suites we can see passed. A
    # non-zero exit is cleanup noise (safe to accept) only if xcodebuild also
    # reached its terminal completion marker; otherwise the run was aborted or
    # killed before finishing, the visible summaries may be just an early prefix,
    # and the un-run remainder would be silently skipped -- the #5641 masking.
    if not reached_terminal_completion(output):
        timed_out = args.exit_code == TIMEOUT_EXIT_CODE or any(
            marker in output for marker in TIMEOUT_MARKERS
        )
        cause = "was killed by a timeout watchdog" if timed_out else "exited non-zero"
        print(
            f"Unexpected test failures detected: xcodebuild {cause} before reaching a "
            "terminal test summary; cannot confirm every selected suite ran"
        )
        return 1

    if not any(tests > 0 for tests, _failures, _unexpected, _line in summaries):
        print("Unexpected test failures detected: no XCTest summary executed any tests")
        return 1

    print(
        "XCTest summaries reported zero unexpected failures and xcodebuild reached "
        "terminal completion; accepting non-zero xcodebuild exit"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
