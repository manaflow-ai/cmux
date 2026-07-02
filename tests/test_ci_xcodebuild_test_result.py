#!/usr/bin/env python3
"""Behavioral guard for CI xcodebuild unit-test result classification."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "check-xcodebuild-test-result.py"


def run_helper(exit_code: int, log_text: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temp_dir:
        log_path = Path(temp_dir) / "xcodebuild.log"
        log_path.write_text(log_text, encoding="utf-8")
        return subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--exit-code",
                str(exit_code),
                str(log_path),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )


def expect_pass(exit_code: int, log_text: str) -> None:
    result = run_helper(exit_code, log_text)
    if result.returncode != 0:
        raise AssertionError(
            f"expected helper to pass, got {result.returncode}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )


def expect_fail(exit_code: int, log_text: str) -> None:
    result = run_helper(exit_code, log_text)
    if result.returncode == 0:
        raise AssertionError(
            f"expected helper to fail\nstdout={result.stdout}\nstderr={result.stderr}"
        )


def test_accepts_nonzero_runner_cleanup_after_zero_unexpected_summaries() -> None:
    # Genuine cleanup noise: every suite ran (terminal completion marker present)
    # and only the runner teardown made the exit non-zero.
    expect_pass(
        65,
        """
Test Suite 'cmuxTests.xctest' started
    Executed 4 tests, with 0 failures (0 unexpected) in 1.000 seconds
    Executed 2 tests, with 0 failures (0 unexpected) in 0.500 seconds
Test Suite 'Selected tests' passed at 2026-06-29 00:00:00.000
    Executed 6 tests, with 0 failures (0 unexpected) in 1.500 seconds
** TEST SUCCEEDED **
""",
    )


def test_accepts_zero_unexpected_failures_when_all_summaries_report_zero_unexpected() -> None:
    # Expected failures (0 unexpected) on a completed run stay tolerated, proven
    # by the terminal completion marker.
    expect_pass(
        65,
        """
Test Suite 'AppDelegateShortcutRoutingTests' failed
    Executed 2 tests, with 1 failure (0 unexpected) in 0.125 seconds
Test Suite 'LaterSuite' passed
    Executed 1 test, with 0 failures (0 unexpected) in 0.010 seconds
Test Suite 'Selected tests' passed at 2026-06-29 00:00:00.000
    Executed 3 tests, with 1 failure (0 unexpected) in 0.140 seconds
** TEST SUCCEEDED **
""",
    )


def test_rejects_timeout_without_terminal_completion_even_when_partial_summaries_are_clean() -> None:
    # Exit 124 means a watchdog killed xcodebuild. Without a terminal completion
    # marker we cannot tell whether every selected suite ran, so an early clean
    # summary must not mask a hang that skipped the rest of the shard (#5641).
    expect_fail(
        124,
        """
xcodebuild unit test timeout after 900s; terminating
Test Suite 'AppHostCleanupSensitiveTests' failed
    Executed 2 tests, with 1 failure (0 unexpected) in 0.125 seconds
Test Suite 'LaterSuite' passed
    Executed 1 test, with 0 failures (0 unexpected) in 0.010 seconds
""",
    )


def test_accepts_timeout_after_terminal_completion_with_zero_unexpected() -> None:
    # The legitimate tolerance: xcodebuild reached its terminal summary (so every
    # selected suite ran) and only the app-host cleanup hung afterward, tripping
    # the idle watchdog. Proof of completion makes the non-zero exit safe to accept.
    expect_pass(
        124,
        """
Test Suite 'AppHostCleanupSensitiveTests' passed
    Executed 2 tests, with 0 failures (0 unexpected) in 0.125 seconds
Test Suite 'Selected tests' passed at 2026-06-29 00:00:00.000
    Executed 2 tests, with 0 failures (0 unexpected) in 0.130 seconds
** TEST SUCCEEDED **
Idle timed out after 300s: xcodebuild -scheme cmux-unit test
""",
    )


def test_rejects_timeout_marker_without_completion_even_with_nonstandard_exit_code() -> None:
    # Defense in depth: if an intermediate shell normalizes the watchdog exit
    # code, the watchdog's own marker line still proves the run was killed before
    # completing, so a clean partial summary must not be accepted.
    expect_fail(
        1,
        """
Idle timed out after 300s: xcodebuild -scheme cmux-unit test
Test Suite 'EarlySuite' passed
    Executed 1 test, with 0 failures (0 unexpected) in 0.010 seconds
""",
    )


def test_rejects_timeout_when_xcodebuild_prints_only_zero_test_summaries() -> None:
    expect_fail(
        124,
        """
xcodebuild unit test timeout after 900s; terminating
Test Suite 'SkippedBundle' started
    Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds
""",
    )


def test_rejects_nonzero_abort_after_early_clean_summary_without_completion() -> None:
    # An app-host abort can return a non-timeout non-zero code (e.g. 65) after
    # only the first suite printed a clean summary. Without a terminal completion
    # marker the later suites may never have run, so the early clean summary must
    # not mask the skipped remainder (#5641) -- the same hole as a timeout.
    expect_fail(
        65,
        """
Test Suite 'EarlySuite' passed
    Executed 2 tests, with 0 failures (0 unexpected) in 0.125 seconds
xcodebuild: error: Test runner exited before all tests completed.
""",
    )


def test_rejects_test_failed_banner_without_aggregate_completion() -> None:
    # xcodebuild prints "** TEST FAILED **" for an aborted/crashed test action,
    # not only a completed-but-failed one. With only an early clean summary and
    # no top-level suite completion line, that banner does not prove every suite
    # ran, so the non-zero exit must still fail (#5641).
    expect_fail(
        65,
        """
Test Suite 'EarlySuite' passed
    Executed 2 tests, with 0 failures (0 unexpected) in 0.125 seconds
Restarting after unexpected exit, crash, or test timeout in LaterSuite.testThing(); summary will include totals from previous launches.
** TEST FAILED **
""",
    )


def test_rejects_unexpected_failure_even_when_last_suite_is_clean() -> None:
    expect_fail(
        65,
        """
Test Suite 'BrowserDeveloperToolsVisibilityPersistenceTests' failed
    Executed 3 tests, with 1 failure (1 unexpected) in 2.000 seconds
Test Suite 'LaterSuite' passed
    Executed 1 test, with 0 failures (0 unexpected) in 0.010 seconds
""",
    )


def test_rejects_zero_test_summaries_without_any_executed_tests() -> None:
    # Even a completed run (terminal marker present) is rejected when no suite
    # actually executed a test -- a filter that matched nothing must not pass.
    expect_fail(
        65,
        """
Test Suite 'SkippedBundle' started
    Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds
Test Suite 'Selected tests' passed at 2026-06-29 00:00:00.000
    Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds
** TEST SUCCEEDED **
""",
    )


def test_rejects_logs_without_xctest_execution_summaries() -> None:
    expect_fail(
        65,
        """
xcodebuild: error: Failed to build project cmux with scheme cmux-unit.
""",
    )


def test_rejects_failed_aggregate_when_no_summary_explains_the_failure() -> None:
    # A *failed* top-level aggregate proves the run reached its end, but not that
    # the failure was benign. Here every parsed summary is clean (0 failures) yet
    # the aggregate failed: the failing action came from a crashed/aborted suite
    # that printed no summary, so accepting it would reopen the #5641 masking
    # hole (a passed top-level aggregate or "** TEST SUCCEEDED **" is absent).
    expect_fail(
        65,
        """
Test Suite 'EarlySuite' passed
    Executed 2 tests, with 0 failures (0 unexpected) in 0.125 seconds
Test Suite 'Selected tests' failed at 2026-06-29 00:00:00.000
""",
    )


def test_rejects_failed_aggregate_when_only_earlier_suite_has_expected_failure() -> None:
    # Cubic/codex P1: a shard can print one early expected failure (0 unexpected),
    # then the runner aborts in a later suite, and xcodebuild still emits
    # "Test Suite 'Selected tests' failed at ..." with NO paired aggregate
    # summary. The earlier expected failure must not excuse the failed aggregate
    # -- the later suite never ran, so its failures would be masked (#5641). Only
    # the aggregate's OWN paired execution summary proves completion; here it is
    # absent, so the run is rejected.
    expect_fail(
        65,
        """
Test Suite 'EarlySuite' failed at 2026-06-29 00:00:00.000.
    Executed 3 tests, with 1 failure (0 unexpected) in 1.000 seconds
xcodebuild: error: Test runner exited before all tests completed.
Test Suite 'Selected tests' failed at 2026-06-29 00:00:00.000
""",
    )


def test_accepts_failed_aggregate_when_its_paired_summary_records_expected_failures() -> None:
    # The real app-host case #5641 must keep green (mirrors the live shard 1/4
    # log): app-host restarts churn the run, xcodebuild finishes the whole plan
    # and prints the *failed* top-level aggregate together with its OWN paired
    # execution summary -- 9 failures, 0 unexpected -- and never
    # "** TEST SUCCEEDED **". The aggregate's paired summary proves every selected
    # suite was attempted, so the non-zero exit is accepted.
    expect_pass(
        65,
        """
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
Test Suite 'cmuxTests.xctest' failed at 2026-07-02 04:54:52.238.
    Executed 225 tests, with 9 failures (0 unexpected) in 19.892 seconds
Test Suite 'Selected tests' failed at 2026-07-02 04:54:52.238.
    Executed 225 tests, with 9 failures (0 unexpected) in 19.892 seconds
""",
    )


def test_accepts_failed_aggregate_whose_paired_summary_counts_skipped_tests() -> None:
    # Real app-host shards print the paired aggregate summary with a skipped-test
    # clause inserted before the failure count: "Executed 183 tests, with 1 test
    # skipped and 11 failures (0 unexpected)" (verbatim from the live shard 2/4
    # log). The summary parser must tolerate that "N test skipped and" clause;
    # otherwise the aggregate's own execution summary is unparseable, completion
    # cannot be proven, and a legitimate completed run whose every failure is
    # expected is falsely rejected. Swift Testing passed here, so accept.
    expect_pass(
        65,
        """
✔ Test run with 439 tests in 48 suites passed after 40.272 seconds.
Test Suite 'cmuxTests.xctest' failed at 2026-07-02 09:25:47.512.
    Executed 183 tests, with 1 test skipped and 11 failures (0 unexpected) in 5.786 seconds
Test Suite 'Selected tests' failed at 2026-07-02 09:25:47.512.
    Executed 183 tests, with 1 test skipped and 11 failures (0 unexpected) in 5.786 seconds
""",
    )


def test_rejects_swift_testing_failed_run_even_when_xctest_side_is_all_expected() -> None:
    # The #5641 masking, one framework over. Swift Testing runs alongside XCTest
    # in the app-host shards and prints its OWN run-level summary. It has no
    # "unexpected" concept and never emits an "Executed N tests, with M failures
    # (K unexpected)" line, so when every XCTest summary is clean/expected
    # (0 unexpected) a Swift Testing failure is invisible to the XCTest scan and
    # would be accepted -- masking real failures. Mirrors the live shard 2/4 log:
    # "Test run with 439 tests in 48 suites failed ... with 38 issues" while the
    # XCTest side reports only expected (0 unexpected) failures. Must reject.
    expect_fail(
        65,
        """
✘ Test run with 439 tests in 48 suites failed after 40.272 seconds with 38 issues.
Test Suite 'cmuxTests.xctest' failed at 2026-07-02 09:25:47.512.
    Executed 183 tests, with 11 failures (0 unexpected) in 5.786 seconds
Test Suite 'Selected tests' failed at 2026-07-02 09:25:47.512.
    Executed 183 tests, with 11 failures (0 unexpected) in 5.786 seconds
""",
    )


def test_accepts_swift_testing_individual_failures_retried_to_green_with_no_run_summary() -> None:
    # Mirrors the live *passing* shard 1/4 log: Swift Testing prints per-attempt
    # "✘ Test foo() failed" / "recorded an issue" events (15 of them on that green
    # shard) that were RETRIED to green, so it emits NO run-level
    # "Test run with N tests in M suites failed" summary at all. Those per-attempt
    # events must NOT be read as failures -- doing so would false-red a shard that
    # actually passed -- and the absent run-level summary must NOT be treated as an
    # abort. With the XCTest side completed (passed aggregate), the non-zero exit
    # is accepted. This pins the gate to the run-level *failed* summary only.
    expect_pass(
        65,
        """
◇ Test run started.
✘ Test webDownloadQuarantineMetadata() recorded an issue at DownloadTests.swift:213:9: Expectation failed
✘ Test webDownloadQuarantineMetadata() failed after 0.512 seconds.
✘ Test browserTabRestoreOrdering() failed after 0.031 seconds.
Test Suite 'cmuxTests.xctest' passed at 2026-07-02 09:25:47.512.
    Executed 183 tests, with 0 failures (0 unexpected) in 5.786 seconds
Test Suite 'Selected tests' passed at 2026-07-02 09:25:47.512.
    Executed 183 tests, with 0 failures (0 unexpected) in 5.786 seconds
""",
    )


def test_accepts_when_swift_testing_passes_alongside_completed_xctest() -> None:
    # Guard against a false rejection from the Swift Testing gate: when Swift
    # Testing prints a *passed* run-level summary and XCTest reached terminal
    # completion, the non-zero exit stays acceptable.
    expect_pass(
        65,
        """
✔ Test run with 439 tests in 48 suites passed after 40.272 seconds.
Test Suite 'Selected tests' passed at 2026-07-02 09:25:47.512.
    Executed 183 tests, with 0 failures (0 unexpected) in 5.786 seconds
** TEST SUCCEEDED **
""",
    )


def main() -> int:
    test_accepts_nonzero_runner_cleanup_after_zero_unexpected_summaries()
    test_accepts_zero_unexpected_failures_when_all_summaries_report_zero_unexpected()
    test_rejects_timeout_without_terminal_completion_even_when_partial_summaries_are_clean()
    test_accepts_timeout_after_terminal_completion_with_zero_unexpected()
    test_rejects_timeout_marker_without_completion_even_with_nonstandard_exit_code()
    test_rejects_nonzero_abort_after_early_clean_summary_without_completion()
    test_rejects_test_failed_banner_without_aggregate_completion()
    test_rejects_timeout_when_xcodebuild_prints_only_zero_test_summaries()
    test_rejects_unexpected_failure_even_when_last_suite_is_clean()
    test_rejects_zero_test_summaries_without_any_executed_tests()
    test_rejects_logs_without_xctest_execution_summaries()
    test_rejects_failed_aggregate_when_no_summary_explains_the_failure()
    test_rejects_failed_aggregate_when_only_earlier_suite_has_expected_failure()
    test_accepts_failed_aggregate_when_its_paired_summary_records_expected_failures()
    test_accepts_failed_aggregate_whose_paired_summary_counts_skipped_tests()
    test_rejects_swift_testing_failed_run_even_when_xctest_side_is_all_expected()
    test_accepts_swift_testing_individual_failures_retried_to_green_with_no_run_summary()
    test_accepts_when_swift_testing_passes_alongside_completed_xctest()
    print("PASS: xcodebuild test result policy rejects masked failures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
