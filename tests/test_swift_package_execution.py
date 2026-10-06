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


LANE = ROOT / "scripts/ci/package-test-lane.sh"
# The workflow step names, and the lane script phase each one's code lives in.
PHASES = {"Run Swift package unit tests": "packages"}


def package_step(name: str) -> str:
    return f"bash '{LANE}' {PHASES[name]}\n"


class SwiftPackageExecutionTests(unittest.TestCase):
    def run_step(
        self, output: str, status: int = 0, package: str = "CmuxUpdater",
        step: str = "Run Swift package unit tests", ghosttykit: bool = False,
        selected_packages: list[str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="swift-package-execution-") as directory:
            root = Path(directory)
            selected_packages = selected_packages or [package]
            for selected_package in selected_packages:
                (root / "Packages/macOS" / selected_package).mkdir(parents=True)
            if ghosttykit:
                # A binaryTarget on the root xcframework, like a GhosttyKit package's manifest.
                (root / "Packages/macOS" / package / "Package.swift").write_text(
                    '.binaryTarget(name: "GhosttyKit", path: "../../../GhosttyKit.xcframework")\n'
                )
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
            selected.write_text("".join(f"{selected_package}\n" for selected_package in selected_packages))
            env = {
                **os.environ,
                "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                "FAKE_SWIFT_OUTPUT": str(log),
                "FAKE_SWIFT_STATUS": str(status),
                "SELECTED_PACKAGES": str(selected),
                "SELECTED_COUNT": str(len(selected_packages)),
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
            status=1, package="GhosttyFixture", ghosttykit=True,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_cosmetic_binary_diagnostic_still_allows_real_success(self) -> None:
        result = self.run_step(
            "error: unexpected binary framework\n"
            "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.\n",
            status=1, package="GhosttyFixture", ghosttykit=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_cosmetic_binary_diagnostic_ignores_swiftpm_warning_error_text(self) -> None:
        result = self.run_step(
            "error: unexpected binary framework\n"
            "warning: 'swift-crypto': skipping cache due to an error: The file “maintenance.lock” doesn’t exist.\n"
            "✔ Test run with 227 tests in 27 suites passed after 0.001 seconds.\n",
            status=1, package="GhosttyFixture", ghosttykit=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_cosmetic_binary_diagnostic_still_rejects_source_error(self) -> None:
        result = self.run_step(
            "error: unexpected binary framework\n"
            "Foo.swift:1:2: error: x\n"
            "✔ Test run with 227 tests in 27 suites passed after 0.001 seconds.\n",
            status=1, package="GhosttyFixture", ghosttykit=True,
        )
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_binary_diagnostic_is_tolerated_only_for_ghosttykit_packages(self) -> None:
        result = self.run_step(
            "error: unexpected binary framework\n"
            "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.\n",
            status=1,
        )
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_assertion_failure_exit_stays_red(self) -> None:
        result = self.run_step(
            "✘ Test run with 2 tests failed after 0.001 seconds with 1 issue.\n", status=1,
        )
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_a_failed_package_is_reported_and_later_packages_still_run(self) -> None:
        # A failure must not hide the results of the packages after it, and
        # the summary table names the failed package; the lane fails at the end.
        result = self.run_step(
            "Foo.swift:1:2: error: broken package\n",
            status=1,
            selected_packages=["FirstPackage", "SecondPackage"],
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout.count("::group::swift test "), 2, result.stdout)
        table = result.stdout.split("Swift package test results:\n", 1)[1]
        self.assertRegex(table, r"FirstPackage +failed \(exit 1\)")
        self.assertRegex(table, r"SecondPackage +failed \(exit 1\)")

    def test_binary_diagnostic_exception_does_not_hide_other_process_failures(self) -> None:
        passed = "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.\n"
        for output, status in (
            (passed, 1),
            ("error: unexpected binary framework\n" + passed, 42),
            ("error: unexpected binary framework\n" + passed
             + "error: Exited with unexpected signal code 10\n", 1),
        ):
            with self.subTest(output=output, status=status):
                result = self.run_step(output, status=status, package="GhosttyFixture", ghosttykit=True)
                self.assertEqual(result.returncode, status, result.stdout)


if __name__ == "__main__":
    unittest.main()
