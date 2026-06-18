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


def test_discovers_swift_testing_suite_types_with_intervening_attributes() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tests_dir = Path(tmp)
        (tests_dir / "AttributedSuiteTests.swift").write_text(
            textwrap.dedent(
                """
                import Testing

                @Suite(.serialized)
                @MainActor
                final class AttributedSuiteTests {
                    @Test func coversBehavior() {}
                }
                """
            ),
            encoding="utf-8",
        )

        output = run_helper(tests_dir)

    assert "-only-testing:cmuxTests/AttributedSuiteTests" in output


def test_discovers_implicit_swift_testing_suite_types() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tests_dir = Path(tmp)
        (tests_dir / "ImplicitSuiteTests.swift").write_text(
            textwrap.dedent(
                """
                import Testing

                struct ImplicitSuiteTests {
                    @Test func coversBehavior() {}
                }
                """
            ),
            encoding="utf-8",
        )

        output = run_helper(tests_dir)

    assert "-only-testing:cmuxTests/ImplicitSuiteTests" in output


def test_discovers_tests_added_by_extensions() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tests_dir = Path(tmp)
        (tests_dir / "ExtensionTests.swift").write_text(
            textwrap.dedent(
                """
                import Testing
                import XCTest

                final class LegacyTests: XCTestCase {}

                extension LegacyTests {
                    func testExtensionRegression() {}
                }

                struct SwiftTestingBase {}

                extension SwiftTestingBase {
                    @Test func coversBehavior() {}
                }
                """
            ),
            encoding="utf-8",
        )

        output = run_helper(tests_dir)

    assert "-only-testing:cmuxTests/LegacyTests/testExtensionRegression" in output
    assert "-only-testing:cmuxTests/LegacyTests" not in output.split()
    assert "-only-testing:cmuxTests/SwiftTestingBase" in output


def test_ignores_comment_and_string_declaration_words() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tests_dir = Path(tmp)
        (tests_dir / "CommentTests.swift").write_text(
            textwrap.dedent(
                '''
                import Testing

                // This comment mentions class of bug, actor as owner, enum to parse, and struct kit.
                struct CommentTests {
                    let text = "class Fake { @Test func bogus() {} }"

                    @Test func coversBehavior() {}
                }
                '''
            ),
            encoding="utf-8",
        )

        output = run_helper(tests_dir)

    assert "-only-testing:cmuxTests/CommentTests" in output
    assert "cmuxTests/of" not in output
    assert "cmuxTests/as" not in output
    assert "cmuxTests/to" not in output
    assert "cmuxTests/kit" not in output


def test_string_and_comment_braces_do_not_steal_later_tests() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tests_dir = Path(tmp)
        (tests_dir / "BraceLiteralTests.swift").write_text(
            textwrap.dedent(
                '''
                import XCTest

                final class LiteralOwnerTests: XCTestCase {
                    let json = """
                    {
                        "key": "value"
                    """

                    /*
                    {
                    */
                }

                final class LaterOwnerTests: XCTestCase {
                    func testRealOwner() {}
                }
                '''
            ),
            encoding="utf-8",
        )

        output = run_helper(tests_dir)

    assert "-only-testing:cmuxTests/LaterOwnerTests/testRealOwner" in output
    assert "cmuxTests/LiteralOwnerTests/testRealOwner" not in output


def main() -> int:
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
            print(f"{name}: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
