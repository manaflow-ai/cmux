#!/usr/bin/env python3

import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "ci" / "run-swift-testing-suites.sh"
GHOSTTY_DIAGNOSTIC = (
    "error: unexpected binary name at /checkout/GhosttyKit.xcframework/"
    "macos-arm64_x86_64/ghostty-internal.a. Static libraries should be prefixed with lib\n"
)
PASSING_RUN = "✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.\n"
TEST_LIST = "ExampleTests.GeometrySuite/testGeometry()\n"


class SwiftTestingSuiteResultTests(unittest.TestCase):
    def run_scenario(
        self,
        *,
        package_name="CmuxTerminal",
        list_output=TEST_LIST,
        list_status=0,
        suite_output=PASSING_RUN,
        suite_status=0,
    ):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            scenario = temp / "scenario.json"
            scenario.write_text(json.dumps({
                "list": {"output": list_output, "status": list_status},
                "suite": {"output": suite_output, "status": suite_status},
            }), encoding="utf-8")
            invocations = temp / "invocations.jsonl"
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys\n"
                "with open(os.environ['SWIFT_INVOCATIONS'], 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "scenario = json.loads(pathlib.Path(os.environ['SWIFT_SCENARIO']).read_text())\n"
                "result = scenario['list' if sys.argv[1:3] == ['test', 'list'] else 'suite']\n"
                "print(result['output'], end='', flush=True)\n"
                "sys.exit(result['status'])\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / package_name
            package.mkdir()
            env = os.environ.copy()
            env.update({
                "PATH": f"{temp}:{env['PATH']}",
                "SWIFT_SCENARIO": str(scenario),
                "SWIFT_INVOCATIONS": str(invocations),
                "CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS": "2",
            })
            completed = subprocess.run(
                [str(RUNNER), str(package)], cwd=ROOT, env=env,
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=10, check=False,
            )
            calls = [json.loads(line) for line in invocations.read_text().splitlines()]
            return completed, calls

    def test_known_ghostty_diagnostic_does_not_fail_a_completed_passing_suite(self):
        completed, calls = self.run_scenario(
            list_output=GHOSTTY_DIAGNOSTIC + TEST_LIST, list_status=1,
            suite_output=GHOSTTY_DIAGNOSTIC + PASSING_RUN, suite_status=1,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertEqual(len(calls), 2)
        self.assertIn(PASSING_RUN.strip(), completed.stdout)

    def test_nonzero_results_without_the_exact_exception_remain_failures(self):
        cases = [
            ("CmuxTerminal", 1, PASSING_RUN),
            ("OtherPackage", 1, GHOSTTY_DIAGNOSTIC + PASSING_RUN),
            ("CmuxTerminal", 1, GHOSTTY_DIAGNOSTIC.replace("GhosttyKit", "OtherKit") + PASSING_RUN),
            ("CmuxTerminal", 2, GHOSTTY_DIAGNOSTIC + PASSING_RUN),
            ("CmuxTerminal", 139, GHOSTTY_DIAGNOSTIC + PASSING_RUN),
            ("CmuxTerminal", 1, GHOSTTY_DIAGNOSTIC + "error: compile failed\n" + PASSING_RUN),
            ("CmuxTerminal", 1, GHOSTTY_DIAGNOSTIC + "✘ Test broke failed with 1 issue.\n" + PASSING_RUN),
            ("CmuxTerminal", 1, GHOSTTY_DIAGNOSTIC + PASSING_RUN + "Segmentation fault: 11\n"),
        ]
        for package, status, output in cases:
            with self.subTest(package=package, status=status, output=output):
                completed, calls = self.run_scenario(
                    package_name=package, suite_output=output, suite_status=status,
                )
                self.assertNotEqual(completed.returncode, 0, completed.stdout)
                self.assertEqual(len(calls), 2, "non-timeout failures must not be retried")

    def test_empty_or_incomplete_runs_never_pass(self):
        for status in (0, 1):
            for output in (
                "Build complete!\n",
                "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.\n",
                "✔ Suite GeometrySuite passed after 0.001 seconds.\n",
            ):
                with self.subTest(status=status, output=output):
                    completed, _ = self.run_scenario(
                        suite_status=status,
                        suite_output=(GHOSTTY_DIAGNOSTIC if status else "") + output,
                    )
                    self.assertNotEqual(completed.returncode, 0, completed.stdout)

    def test_positive_xctest_results_are_not_mistaken_for_an_empty_run(self):
        completed, _ = self.run_scenario(suite_output=(
            "Test Suite 'Selected tests' passed at 2026-09-17 05:38:08.026.\n"
            "\t Executed 13 tests, with 0 failures (0 unexpected) in 0.018 (0.020) seconds\n"
            "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.\n"
        ))
        self.assertEqual(completed.returncode, 0, completed.stdout)

    def test_failed_discovery_never_runs_a_partial_list(self):
        cases = [
            (1, TEST_LIST),
            (1, "error: compile failed\n" + TEST_LIST),
            (1, GHOSTTY_DIAGNOSTIC.replace("GhosttyKit", "OtherKit") + TEST_LIST),
            (1, GHOSTTY_DIAGNOSTIC + "error: compile failed\n" + TEST_LIST),
            (139, GHOSTTY_DIAGNOSTIC + TEST_LIST),
        ]
        for status, output in cases:
            with self.subTest(status=status, output=output):
                completed, calls = self.run_scenario(list_status=status, list_output=output)
                self.assertNotEqual(completed.returncode, 0, completed.stdout)
                self.assertEqual(len(calls), 1, "a failed discovery must not execute suites")

    def test_discovery_ignores_build_paths_and_deduplicates_real_suites(self):
        completed, calls = self.run_scenario(list_output=(
            "/checkout/.build/arm64-apple-macosx/debug/GeneratedTests.swift: warning: generated\n"
            + TEST_LIST + "ExampleTests.GeometrySuite/testOtherGeometry()\n"
        ))
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertEqual(len(calls), 2, calls)
        self.assertEqual(calls[1][-1], "GeometrySuite")

    def test_large_output_does_not_hide_real_compile_errors(self):
        output = GHOSTTY_DIAGNOSTIC + "error: compile failed\n" + ("build output\n" * 10000)
        completed, calls = self.run_scenario(list_status=1, list_output=output + TEST_LIST)
        self.assertNotEqual(completed.returncode, 0, completed.stdout[-1000:])
        self.assertEqual(len(calls), 1)


class SwiftTestingSuiteTimeoutTests(unittest.TestCase):
    def test_hung_suite_is_terminated_before_the_job_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"$*\" == *\"test list\"* ]]; then\n"
                "  echo 'ExampleTests.HangingSuite/testNeverFinishes()'\n"
                "  exit 0\n"
                "fi\n"
                "sleep 30\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / "ExampleTests"
            package.mkdir()
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS"] = "1"

            completed = subprocess.run(
                [str(RUNNER), str(package)],
                cwd=ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=5,
                check=False,
            )

            self.assertEqual(completed.returncode, 124, completed.stdout)
            self.assertEqual(completed.stdout.count("timed out after 1s"), 2)
            self.assertIn("retrying HangingSuite once", completed.stdout)


if __name__ == "__main__":
    unittest.main()
