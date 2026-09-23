#!/usr/bin/env python3
"""Exercise the package CI step with SwiftPM process results and console output."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]


def package_step(name: str) -> str:
    workflow = (ROOT / ".github/workflows/ci-macos.yml").read_text()
    job = workflow.split("\n  swift-package-tests:\n", 1)[1].split("\n  tests-build-and-lag:\n", 1)[0]
    step = job.split(f"      - name: {name}\n", 1)[1]
    body = step.split("        run: |\n", 1)[1]
    lines = []
    for line in body.splitlines():
        if line.strip() and not line.startswith("          "):
            break
        lines.append(line[10:] if line else "")
    return "\n".join(lines) + "\n"


class SwiftPackageExecutionTests(unittest.TestCase):
    def run_step(
        self, output: str, status: int = 0, package: str = "CmuxComputerUse",
        step: str = "Run Swift package unit tests",
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="swift-package-execution-") as directory:
            root = Path(directory)
            (root / "Packages/macOS" / package).mkdir(parents=True)
            (root / "scripts").mkdir()
            (root / "scripts/ci").symlink_to(ROOT / "scripts/ci", target_is_directory=True)
            binaries = root / "bin"
            binaries.mkdir()
            swift = binaries / "swift"
            swift.write_text(textwrap.dedent("""\
                #!/usr/bin/env bash
                cat "$FAKE_SWIFT_OUTPUT"
                exit "$FAKE_SWIFT_STATUS"
                """))
            swift.chmod(0o755)
            log = root / "swift-output.txt"
            log.write_text(output)
            selected = root / "selected.txt"
            selected.write_text(package + "\n")
            env = {
                **os.environ,
                "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                "FAKE_SWIFT_OUTPUT": str(log),
                "FAKE_SWIFT_STATUS": str(status),
                "SELECTED_PACKAGES": str(selected),
                "SELECTED_COUNT": "1",
                "RUNNER_TEMP": str(root),
            }
            return subprocess.run(
                ["bash", "-c", package_step(step)], cwd=root, env=env,
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20,
            )

    def test_success_requires_a_completed_nonempty_test_run(self) -> None:
        for output in (
            "Build complete!\n✔ Test run with 0 tests passed after 0.001 seconds.\n",
            "Build complete!\n◇ Test run started.\n◇ Test example() started.\n",
            "Build complete!\n",
        ):
            with self.subTest(output=output):
                result = self.run_step(output)
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_completed_swift_testing_and_xctest_runs_pass(self) -> None:
        for output in (
            "✔ Test run with 1 test in 1 suite passed after 0.001 seconds.\n",
            "✔ Test run with 2 tests passed after 0.001 seconds.\n",
            "Test Suite 'All tests' passed at 2026-09-23 00:00:00.\n"
            "\tExecuted 2 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n"
            "✔ Test run with 0 tests passed after 0.001 seconds.\n",
        ):
            with self.subTest(output=output):
                result = self.run_step(output)
                self.assertEqual(result.returncode, 0, result.stdout)

    def test_cosmetic_binary_diagnostic_cannot_hide_zero_tests(self) -> None:
        result = self.run_step(
            "error: unexpected binary framework\n"
            "✔ Test run with 0 tests passed after 0.001 seconds.\n",
            status=1, package="CmuxTerminal",
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_cosmetic_binary_diagnostic_still_allows_real_success(self) -> None:
        result = self.run_step(
            "error: unexpected binary framework\n"
            "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.\n",
            status=1, package="CmuxTerminal",
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_assertion_failure_exit_stays_red(self) -> None:
        result = self.run_step(
            "✘ Test run with 2 tests failed after 0.001 seconds with 1 issue.\n", status=1,
        )
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_binary_diagnostic_exception_does_not_hide_other_process_failures(self) -> None:
        passed = "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.\n"
        for output, status in (
            (passed, 1),
            ("error: unexpected binary framework\n" + passed, 42),
            ("error: unexpected binary framework\n" + passed
             + "error: Exited with unexpected signal code 10\n", 1),
        ):
            with self.subTest(output=output, status=status):
                result = self.run_step(output, status=status, package="CmuxTerminal")
                self.assertEqual(result.returncode, status, result.stdout)

    def test_bonsplit_also_requires_completed_nonempty_execution(self) -> None:
        for output, expected in (
            ("✔ Test run with 0 tests passed after 0.001 seconds.\n", 1),
            ("✔ Test run with 1 test passed after 0.001 seconds.\n", 0),
        ):
            with self.subTest(output=output):
                result = self.run_step(output, step="Run Bonsplit package tests")
                self.assertEqual(result.returncode, expected, result.stdout)


if __name__ == "__main__":
    unittest.main()
