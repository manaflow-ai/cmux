#!/usr/bin/env python3
"""Regression tests for scripts/ci/xctest_shard_args.py."""

from __future__ import annotations

import subprocess
import tempfile
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "xctest_shard_args.py"


def run_helper(tests_dir: Path, *args: str) -> str:
    return subprocess.check_output(
        [
            "python3",
            str(HELPER),
            "--tests-dir",
            str(tests_dir),
            "--shard-count",
            "1",
            "--shard-index",
            "0",
            *args,
        ],
        text=True,
    ).strip()


def test_discovers_xctest_methods_and_ignores_helpers() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tests_dir = Path(tmp)
        (tests_dir / "SampleTests.swift").write_text(
            textwrap.dedent(
                """
                import XCTest

                final class SampleTests: XCTestCase {
                    func testAlpha() {}
                    func helper() {}
                    func testBeta() {}
                }
                """
            ),
            encoding="utf-8",
        )

        output = run_helper(tests_dir)

    assert "-only-testing:cmuxTests/SampleTests/testAlpha" in output
    assert "-only-testing:cmuxTests/SampleTests/testBeta" in output
    assert "helper" not in output


def test_excludes_explicit_identifiers() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tests_dir = Path(tmp)
        (tests_dir / "SampleTests.swift").write_text(
            textwrap.dedent(
                """
                import XCTest

                final class SampleTests: XCTestCase {
                    func testAlpha() {}
                    func testBeta() {}
                }
                """
            ),
            encoding="utf-8",
        )

        output = run_helper(tests_dir, "--exclude", "cmuxTests/SampleTests/testAlpha")

    assert "testAlpha" not in output
    assert "-only-testing:cmuxTests/SampleTests/testBeta" in output


def test_discovers_swift_testing_suite_types() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tests_dir = Path(tmp)
        (tests_dir / "SuiteTests.swift").write_text(
            textwrap.dedent(
                """
                import Testing

                @Suite("Display name")
                struct SuiteTests {
                    @Test func coversBehavior() {}
                }
                """
            ),
            encoding="utf-8",
        )

        output = run_helper(tests_dir)

    assert "-only-testing:cmuxTests/SuiteTests" in output
