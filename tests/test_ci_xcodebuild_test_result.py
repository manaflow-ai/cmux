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
    print("PASS: xcodebuild test result policy rejects masked failures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
