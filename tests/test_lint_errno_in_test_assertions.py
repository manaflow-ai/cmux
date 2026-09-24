#!/usr/bin/env python3
"""Behavior tests for scripts/lint-errno-in-test-assertions.py.

Runs under plain python3: `python3 tests/test_lint_errno_in_test_assertions.py`.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = REPO_ROOT / "scripts" / "lint-errno-in-test-assertions.py"
SPEC = importlib.util.spec_from_file_location("errno_assertion_lint", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
LINT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = LINT
SPEC.loader.exec_module(LINT)


def lines(source: str) -> list:
    findings = LINT.scan_source(textwrap.dedent(source), "cmuxTests/Fixture.swift")
    return [(finding.line, finding.macro) for finding in findings]


class RejectsErrnoInsideAssertions(unittest.TestCase):
    def test_errno_asserted_after_a_separate_probe(self) -> None:
        self.assertEqual(
            lines(
                """\
                #expect(kill(pid, 0) == -1)
                #expect(errno == ESRCH)
                """
            ),
            [(2, "#expect")],
        )

    def test_errno_on_the_right_of_the_probe_in_one_expectation(self) -> None:
        self.assertEqual(
            lines("#expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH, \"reaped\")\n"),
            [(1, "#expect")],
        )

    def test_require_and_xctest_assertions(self) -> None:
        self.assertEqual(
            lines(
                """\
                try #require(errno == EAGAIN)
                XCTAssertEqual(errno, EINTR)
                XCTAssertEqual(bindResult, 0, String(cString: strerror(errno)))
                _ = try XCTUnwrap(POSIXErrorCode(rawValue: errno))
                """
            ),
            [(1, "#require"), (2, "XCTAssertEqual"), (3, "XCTAssertEqual"), (4, "XCTUnwrap")],
        )

    def test_module_qualified_errno(self) -> None:
        self.assertEqual(lines("#expect(Darwin.errno == EBADF)\n"), [(1, "#expect")])
        self.assertEqual(lines("#expect(Glibc . errno == EBADF)\n"), [(1, "#expect")])

    def test_multiline_macro_reports_the_errno_line(self) -> None:
        self.assertEqual(
            lines(
                """\
                #expect(
                    result == -1,
                    "unexpected errno"
                )
                #expect(
                    POSIXErrorCode(rawValue:
                        errno) == .ESRCH,
                    "the child must be gone"
                )
                """
            ),
            [(7, "#expect")],
        )

    def test_string_interpolation_is_code(self) -> None:
        self.assertEqual(
            lines('#expect(result == 0, "failed: \\(String(cString: strerror(errno)))")\n'),
            [(1, "#expect")],
        )

    def test_closure_that_reads_errno_before_its_own_call(self) -> None:
        # Both closures run inside the assertion, after the probe outside them.
        self.assertEqual(
            lines(
                """\
                let result = kill(pid, 0)
                #expect({ errno == ESRCH }())
                #expect(pid.map { _ in errno == ESRCH } == true)
                """
            ),
            [(2, "#expect"), (3, "#expect")],
        )

    def test_closure_whose_first_call_takes_errno_as_an_argument(self) -> None:
        # The argument is evaluated before the call runs, so each closure reads
        # errno set outside it, after the assertion started.
        self.assertEqual(
            lines(
                """\
                #expect({ POSIXErrorCode(rawValue: errno) == .ESRCH }())
                #expect(pid.map { _ in String(cString: strerror(errno)) } == "No such process")
                #expect({ ESRCH == Int32(errno) }())
                """
            ),
            [(1, "#expect"), (2, "#expect"), (3, "#expect")],
        )

    def test_division_is_not_a_regex_literal(self) -> None:
        self.assertEqual(
            lines(
                """\
                #expect(total / errno == 1)
                #expect(a/b == errno)
                #expect(x /y/ errno)
                """
            ),
            [(1, "#expect"), (2, "#expect"), (3, "#expect")],
        )

    def test_nested_assertions_report_once(self) -> None:
        self.assertEqual(lines("#expect(try #require(errno) == EBADF)\n"), [(1, "#expect")])


class AcceptsCapturedErrno(unittest.TestCase):
    def test_capture_first_fix(self) -> None:
        self.assertEqual(
            lines(
                """\
                let killResult = kill(pid, 0)
                let killErrno = errno
                #expect(killResult == -1)
                #expect(killErrno == ESRCH)
                """
            ),
            [],
        )

    def test_errno_outside_any_assertion(self) -> None:
        self.assertEqual(
            lines(
                """\
                if written < 0, errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                precondition(bound == 0, "bind failed errno=\\(errno)")
                """
            ),
            [],
        )

    def test_comments_and_string_text(self) -> None:
        self.assertEqual(
            lines(
                """\
                #expect(redactor.redacted("errno=0") == "errno=0") // errno
                #expect(log.contains(#"errno="#))
                /* #expect(errno == EBADF) */
                #expect(message == \"\"\"
                    failed with errno 2
                    \"\"\")
                """
            ),
            [],
        )

    def test_closure_body_inside_the_arguments(self) -> None:
        # The macro passes a closure literal through untouched, so the closure
        # reads errno straight after its own syscall.
        self.assertEqual(
            lines("#expect(pid.map { kill($0, 0) != 0 && errno == ESRCH } == true)\n"),
            [],
        )

    def test_regex_literal_text(self) -> None:
        self.assertEqual(
            lines(
                """\
                #expect("errno".firstMatch(of: /errno/) != nil)
                #expect(log.contains(#/errno=\\d+/#))
                #expect(log.contains(##/
                    errno
                    /##))
                """
            ),
            [],
        )

    def test_immediately_invoked_closure_with_its_own_call(self) -> None:
        self.assertEqual(
            lines("#expect({ kill(pid, 0) == -1 && errno == ESRCH }())\n"),
            [],
        )

    def test_members_and_labels_named_errno(self) -> None:
        self.assertEqual(
            lines(
                """\
                #expect(failure.errno == 61)
                #expect(Report(errno: code).isKnown)
                #expect(readErrno == EAGAIN && bind_errno == 0)
                """
            ),
            [],
        )


class CommandLine(unittest.TestCase):
    def run_lint(self, files: dict) -> tuple:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative, text in files.items():
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(textwrap.dedent(text), encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "add", "-A"], cwd=root, check=True)
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                status = LINT.main(["--root", str(root)])
            return status, stdout.getvalue(), stderr.getvalue()

    def test_fails_with_the_fix_on_a_package_test(self) -> None:
        status, _, stderr = self.run_lint(
            {
                "Packages/macOS/Pkg/Tests/PkgTests/ProbeTests.swift": """\
                    #expect(read(fd, &byte, 1) == -1)
                    #expect(errno == EAGAIN)
                    """,
            }
        )
        self.assertEqual(status, 1)
        self.assertIn("Packages/macOS/Pkg/Tests/PkgTests/ProbeTests.swift:2", stderr)
        self.assertIn("let killErrno = errno", stderr)

    def test_scans_only_test_sources(self) -> None:
        status, stdout, _ = self.run_lint(
            {
                "Sources/Probe.swift": "#expect(errno == EAGAIN)\n",
                "cmuxTests/ProbeTests.swift": "let e = errno\n#expect(e == EAGAIN)\n",
            }
        )
        self.assertEqual(status, 0)
        self.assertIn("1 Swift test files", stdout)


if __name__ == "__main__":
    unittest.main()
