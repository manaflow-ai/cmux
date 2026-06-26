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


def test_accepts_nonzero_runner_cleanup_after_zero_failure_summaries() -> None:
    expect_pass(
        65,
        """
Test Suite 'cmuxTests.xctest' started
    Executed 4 tests, with 0 failures (0 unexpected) in 1.000 seconds
    Executed 2 tests, with 0 failures (0 unexpected) in 0.500 seconds
""",
    )


def test_rejects_assertion_failure_even_when_last_suite_has_zero_unexpected() -> None:
    expect_fail(
        65,
        """
Test Suite 'AppDelegateShortcutRoutingTests' failed
    Executed 2 tests, with 1 failure (0 unexpected) in 0.125 seconds
Test Suite 'LaterSuite' passed
    Executed 1 test, with 0 failures (0 unexpected) in 0.010 seconds
""",
    )


def test_rejects_timeout_even_when_xcodebuild_prints_zero_test_summaries() -> None:
    expect_fail(
        124,
        """
xcodebuild unit test timeout after 900s; terminating
Test Suite 'SkippedBundle' started
    Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds
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
    test_accepts_nonzero_runner_cleanup_after_zero_failure_summaries()
    test_rejects_assertion_failure_even_when_last_suite_has_zero_unexpected()
    test_rejects_timeout_even_when_xcodebuild_prints_zero_test_summaries()
    test_rejects_logs_without_xctest_execution_summaries()
    print("PASS: xcodebuild test result policy rejects masked failures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
