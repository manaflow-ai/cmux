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

Completion evidence comes in two strengths. ``** TEST SUCCEEDED **`` or a
*passed* top-level aggregate is unconditional proof: the whole selected set ran
and passed. A *failed* top-level aggregate is weaker -- a crashed or aborted
suite that never printed a summary can still leave xcodebuild emitting
``Test Suite 'Selected tests' failed at ...``. So a failed aggregate satisfies
(c) only when a visible XCTest summary explains the failure with an expected
(0-unexpected) ``failures > 0`` count; a failed aggregate over only clean
summaries means the failure came from outside the parsed suites and is rejected.
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

# ``** TEST SUCCEEDED **`` is printed only when the whole action passed, which
# cannot happen unless every selected suite ran -- so it proves completion.
# ``** TEST FAILED **`` is deliberately NOT here: xcodebuild prints that banner
# for an aborted/crashed action too, so it can appear after only an early prefix
# of suites ran and is not proof of completion on its own.
COMPLETION_MARKERS = ("** TEST SUCCEEDED **",)

# The top-level XCTest aggregate summary ("Selected tests"/"All tests" for a
# -only-testing / full run). xcodebuild emits it only after every selected suite
# finishes, so it proves completion for a failed run where ``** TEST SUCCEEDED **``
# is absent. This mirrors xcodebuild_noninteractive.py's SELECTED_TESTS_DONE_RE.
#
# The ``passed`` and ``failed`` variants are tracked separately: a *passed*
# aggregate is unconditional proof that every selected suite ran and passed, but
# a *failed* aggregate is weaker -- a crashed or aborted suite that printed no
# summary can still leave xcodebuild emitting ``Test Suite 'Selected tests'
# failed at ...``. main() therefore accepts a bare failed aggregate only when a
# visible summary explains it with an expected (0-unexpected) failure.
PASSED_COMPLETION_RE = re.compile(
    r"Test Suite '(?:Selected tests|All tests)' passed at "
)
FAILED_COMPLETION_RE = re.compile(
    r"Test Suite '(?:Selected tests|All tests)' failed at "
)


def reached_terminal_completion(output: str) -> bool:
    if any(marker in output for marker in COMPLETION_MARKERS):
        return True
    return (
        PASSED_COMPLETION_RE.search(output) is not None
        or FAILED_COMPLETION_RE.search(output) is not None
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

    # ``** TEST SUCCEEDED **`` or a *passed* top-level aggregate proves the whole
    # selected set ran and passed. A *failed* top-level aggregate proves the run
    # reached its end, but not that the failure was benign: a crashed or aborted
    # suite that printed no summary can still leave xcodebuild emitting
    # ``Test Suite 'Selected tests' failed at ...``. Accept a failed aggregate
    # only when a visible XCTest summary explains it -- an expected failure
    # (failures > 0, already known to be 0 unexpected above). If every summary is
    # clean (0 failures) yet the aggregate failed, the failure came from outside
    # the parsed suites (crash/abort/skipped remainder) -- the #5641 masking.
    strong_completion = (
        any(marker in output for marker in COMPLETION_MARKERS)
        or PASSED_COMPLETION_RE.search(output) is not None
    )
    if not strong_completion and FAILED_COMPLETION_RE.search(output) is not None:
        if not any(failures > 0 for _tests, failures, _unexpected, _line in summaries):
            print(
                "Unexpected test failures detected: xcodebuild reported a failed "
                "top-level aggregate but no XCTest summary recorded a failure, so the "
                "failed action came from a crashed/aborted suite outside the parsed "
                "summaries; cannot confirm every selected suite ran"
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
