#!/usr/bin/env python3
"""Behavioral tests for the selected-test count gate."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts" / "ci" / "require_xcode_tests_ran.py"


def run_validator(log: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temporary_directory:
        log_path = Path(temporary_directory) / "xcodebuild.log"
        log_path.write_text(log)
        return subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                str(log_path),
                "cmuxUITests/cmuxUITests/testEdgeSwipeBackDoesNotScrollTerminal",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )


def test_rejects_zero_executed_tests() -> None:
    result = run_validator(
        """
        Test Suite 'Selected tests' passed at 2026-07-31 00:00:00.000.
             Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds
        ** TEST SUCCEEDED **
        """
    )

    assert result.returncode == 1
    assert "executed 0 tests" in result.stderr


def test_accepts_a_selected_xctest() -> None:
    result = run_validator(
        """
        Test Case '-[cmuxUITests.cmuxUITests testEdgeSwipeBackDoesNotScrollTerminal]' passed.
        Test Suite 'Selected tests' passed at 2026-07-31 00:00:00.000.
             Executed 1 test, with 0 failures (0 unexpected) in 1.000 seconds
        ** TEST SUCCEEDED **
        """
    )

    assert result.returncode == 0
    assert "Executed tests" in result.stdout


def test_rejects_missing_test_summaries() -> None:
    result = run_validator("** TEST SUCCEEDED **\n")

    assert result.returncode == 1
    assert "could not determine" in result.stderr.lower()


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: xcode selected-test count gate")
