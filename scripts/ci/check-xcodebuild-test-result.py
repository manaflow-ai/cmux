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
and passed. A *failed* top-level aggregate is weaker. xcodebuild prints it as a
pair -- ``Test Suite 'Selected tests' failed at ...`` immediately followed by
that aggregate's own ``Executed N tests, with M failures (K unexpected)``
summary -- and emits that pair only after the entire selected plan ran to
completion (app-host restarts included). So a failed aggregate satisfies (c)
only when its OWN paired execution summary is present with an expected
(0-unexpected) ``failures > 0`` count. An earlier per-suite summary's failure
does not qualify: a run that aborts (watchdog kill, "Test runner exited before
all tests completed") dies before the aggregate summary prints, so requiring the
aggregate's paired summary -- not merely some earlier failure -- is what keeps a
crashed or skipped remainder from masking. Real app-host shards reach this
branch: a non-zero exit with ``Test Suite 'Selected tests' failed at ...`` +
``Executed 225 tests, with 9 failures (0 unexpected)`` and no
``** TEST SUCCEEDED **``.

The app-host shards also run Swift Testing (``@Test``/``#expect``) beside XCTest.
Swift Testing reports through its own run-level summary
(``Test run with N tests in M suites passed/failed``), has no "unexpected"
concept, and never prints an ``Executed N tests, with M failures (K unexpected)``
line -- so the XCTest summary scan is structurally blind to it. A Swift Testing
failure whose XCTest side is clean would therefore be accepted, which is the
#5641 masking one framework over. So a Swift Testing run whose *failed* run-level
summary is present fails the check regardless of the XCTest tally. Only that
run-level summary counts: individual ``✘ Test foo() failed`` events are
per-attempt and get retried to green on passing shards, so they are not read as
failures.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


# The ``(?:\d+\s+tests?\s+skipped\s+and\s+)?`` group tolerates the skipped-test
# clause xcodebuild inserts before the failure count when a suite has skips --
# ``Executed 183 tests, with 1 test skipped and 11 failures (0 unexpected)`` --
# so the skipped variant still parses to (tests, failures, unexpected). Without
# it the paired aggregate summary is unparseable and a completed run whose
# failures are all expected is falsely rejected.
SUMMARY_RE = re.compile(
    r"Executed\s+(\d+)\s+tests?,\s+with\s+"
    r"(?:\d+\s+tests?\s+skipped\s+and\s+)?"
    r"(\d+)\s+failures?\s+\((\d+)\s+unexpected\)"
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
# aggregate is unconditional proof that every selected suite ran and passed,
# while a *failed* aggregate proves completion only together with its own paired
# execution summary (see _aggregate_failure_summary and main()).
PASSED_COMPLETION_RE = re.compile(
    r"Test Suite '(?:Selected tests|All tests)' passed at "
)
FAILED_COMPLETION_RE = re.compile(
    r"Test Suite '(?:Selected tests|All tests)' failed at "
)


# Swift Testing (the framework behind ``@Test``/``#expect``) runs alongside
# XCTest in the app-host shards and prints its OWN run-level summary after the
# whole plan (retries included) settles::
#
#     ✔ Test run with 439 tests in 48 suites passed after 40.272 seconds.
#     ✘ Test run with 439 tests in 48 suites failed after 40.272 seconds with 38 issues.
#
# It has no "unexpected" concept and never emits an ``Executed N tests, with M
# failures (K unexpected)`` line, so the XCTest summary scan above is structurally
# blind to it: a Swift Testing failure whose XCTest side is clean (0 unexpected)
# would be accepted -- the #5641 masking, one framework over.
#
# Only the *failed* run-level line is a reliable signal. Individual
# ``✘ Test foo() failed`` / ``recorded an issue`` events are per-attempt and get
# retried -- a live *passing* shard's log carries a dozen of them with NO failed
# run-level summary -- so they must NOT be read as failures (that would false-red
# a shard that actually passed). The run-level summary itself can even be absent
# on a passing shard (app-host restarts churn the host process), so a missing
# summary must NOT be treated as an abort either. Matching only the run-level
# ``failed`` summary rejects a genuinely-failed Swift Testing run while never
# tripping on a shard that passed.
SWIFT_TESTING_FAILED_RE = re.compile(
    r"Test run with \d+ tests? in \d+ suites? failed"
)


def swift_testing_failed(output: str) -> bool:
    """True when Swift Testing printed a *failed* run-level summary."""
    return SWIFT_TESTING_FAILED_RE.search(output) is not None


def reached_passing_completion(output: str) -> bool:
    """True only when xcodebuild certified the whole selected set ran and passed.

    ``** TEST SUCCEEDED **`` and a *passed* top-level aggregate are the only
    unconditional proofs. A *failed* aggregate is handled separately in main()
    via its paired execution summary; it is intentionally NOT treated as passing
    completion here.
    """
    if any(marker in output for marker in COMPLETION_MARKERS):
        return True
    return PASSED_COMPLETION_RE.search(output) is not None


def _aggregate_failure_summary(output: str) -> tuple[int, int, int] | None:
    """Totals for the *failed* top-level aggregate, or None if it never printed
    its own execution summary.

    xcodebuild prints the aggregate as a pair::

        Test Suite 'Selected tests' failed at <ts>.
             Executed N tests, with M failures (K unexpected) in ...

    The ``Executed`` line is emitted only after the entire selected plan ran to
    completion (app-host restarts included), so its presence -- not merely some
    earlier per-suite summary -- proves every selected suite was attempted. A run
    killed mid-flight (watchdog, "Test runner exited before all tests completed")
    dies before the pair prints, so None is returned. Returns the totals from the
    ``Executed`` line paired with the last ``... failed at`` aggregate line.
    """
    lines = output.splitlines()
    result: tuple[int, int, int] | None = None
    for index, line in enumerate(lines):
        if FAILED_COMPLETION_RE.search(line) is None:
            continue
        for follow in lines[index + 1 : index + 4]:
            summary_match = SUMMARY_RE.search(follow)
            if summary_match:
                result = (
                    int(summary_match.group(1)),
                    int(summary_match.group(2)),
                    int(summary_match.group(3)),
                )
                break
    return result


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

    # Swift Testing runs beside XCTest in these shards but reports through its own
    # run-level summary, which the XCTest-only scan below cannot see. Gate on its
    # *failed* run-level summary first so a Swift Testing failure can never be
    # masked by a clean XCTest tally -- the #5641 masking generalized to the newer
    # framework. (Only the run-level ``failed`` summary counts: per-attempt
    # ``✘ Test foo() failed`` events get retried to green on passing shards, so
    # they are not treated as failures here.)
    if swift_testing_failed(output):
        print(
            "Unexpected test failures detected: Swift Testing reported a failed run "
            "(its issues carry no XCTest '(N unexpected)' line and would otherwise be "
            "masked)"
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

    # The clean summaries above only prove the suites we can see passed. A
    # non-zero exit is safe to accept only if xcodebuild also certified that the
    # whole selected plan ran: either a *passing* completion (``** TEST SUCCEEDED
    # **`` / a *passed* aggregate) or a *failed* aggregate whose OWN paired
    # execution summary printed with an expected (0-unexpected) ``failures > 0``
    # count. Otherwise the run was aborted or killed before finishing, the
    # visible summaries may be just an early prefix, and the un-run remainder
    # would be silently skipped -- the #5641 masking.
    if not reached_passing_completion(output):
        aggregate = _aggregate_failure_summary(output)
        # ``aggregate`` holds the failed top-level aggregate's own totals. It
        # proves completion only when xcodebuild printed that paired summary AND
        # it records a failure (failures > 0, already known to be 0 unexpected).
        # An earlier per-suite failure does NOT qualify: a run can print one
        # ``(0 unexpected)`` failure, abort in a later suite, and still emit
        # ``Test Suite 'Selected tests' failed at ...`` with no paired summary --
        # tying acceptance to the aggregate's own summary closes that hole.
        if aggregate is None or aggregate[1] == 0:
            timed_out = args.exit_code == TIMEOUT_EXIT_CODE or any(
                marker in output for marker in TIMEOUT_MARKERS
            )
            if FAILED_COMPLETION_RE.search(output) is not None:
                cause = (
                    "printed a failed top-level aggregate without its own execution "
                    "summary recording an expected failure, so the failed action came "
                    "from a crashed/aborted suite outside the completed tally"
                )
            elif timed_out:
                cause = (
                    "was killed by a timeout watchdog before reaching a terminal test "
                    "summary"
                )
            else:
                cause = "exited non-zero before reaching a terminal test summary"
            print(
                f"Unexpected test failures detected: xcodebuild {cause}; cannot "
                "confirm every selected suite ran"
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
