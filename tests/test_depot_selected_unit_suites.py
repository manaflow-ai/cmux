#!/usr/bin/env python3
"""Execute the hosted selected-suite shell step without launching Xcode."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/test-depot.yml"
LARGE_TAIL = "post-test diagnostic output\n" * 100_000


class DepotSelectedUnitSuitesTests(unittest.TestCase):
    def run_step(self, outputs, suites="FirstSuite,SecondSuite"):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        step = next(
            step
            for step in workflow["jobs"]["tests"]["steps"]
            if step.get("name") == "Run unit tests"
        )
        with tempfile.TemporaryDirectory(prefix="cmux-depot-suite-") as directory:
            root = Path(directory)
            fixture = root / "outputs.json"
            fixture.write_text(json.dumps(outputs), encoding="utf-8")
            calls = root / "calls.log"
            runner = root / "scripts/ci/xcodebuild_noninteractive.py"
            runner.parent.mkdir(parents=True)
            runner.write_text(
                f"#!{sys.executable}\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "calls = Path(os.environ['SUITE_CALLS'])\n"
                "previous = calls.read_text().splitlines() if calls.exists() else []\n"
                "with calls.open('a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "outputs = json.loads(Path(os.environ['SUITE_OUTPUTS']).read_text())\n"
                "output = outputs[len(previous)]\n"
                "sys.stdout.write(output['text'])\n"
                "sys.exit(output.get('status', 0))\n",
                encoding="utf-8",
            )
            runner.chmod(0o755)
            # The workflow may request cache cleanup on a package-resolution
            # retry. Record that request; never touch the machine's real caches.
            script = 'rm() { printf "cleanup\\n" >> "$SUITE_CLEANUPS"; }\n' + step["run"]
            cleanups = root / "cleanups.log"
            result = subprocess.run(
                ["/bin/bash", "-e", "-c", script],
                cwd=root,
                env={
                    **os.environ,
                    "UNIT_TEST_SUITES": suites,
                    "TEST_RESULTS_ROOT": str(root / "results"),
                    "SUITE_CALLS": str(calls),
                    "SUITE_OUTPUTS": str(fixture),
                    "SUITE_CLEANUPS": str(cleanups),
                },
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
            invocations = (
                [json.loads(line) for line in calls.read_text().splitlines()]
                if calls.exists()
                else []
            )
            cleanup_count = len(cleanups.read_text().splitlines()) if cleanups.exists() else 0
            return result, invocations, cleanup_count

    def test_large_success_logs_do_not_stop_later_selected_suites(self):
        for summary in (
            "Test run with 76 tests in 1 suite passed after 27.220 seconds.\n",
            "Executed 76 tests, with 0 failures (0 unexpected).\n",
        ):
            with self.subTest(summary=summary):
                result, calls, cleanups = self.run_step(
                    [
                        {"text": summary + LARGE_TAIL},
                        {"text": "Test run with 2 tests passed.\n"},
                    ]
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 2)
                self.assertIn("-only-testing:cmuxTests/FirstSuite", calls[0])
                self.assertIn("-only-testing:cmuxTests/SecondSuite", calls[1])
                self.assertEqual(cleanups, 0)

    def test_zero_or_missing_execution_summary_still_fails(self):
        for output in (
            "Test run with 0 tests passed.\n",
            "Executed 0 tests, with 0 failures (0 unexpected).\n",
            "** TEST SUCCEEDED **\n",
        ):
            with self.subTest(output=output):
                result, calls, _ = self.run_step([{"text": output + LARGE_TAIL}])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("No tests executed for FirstSuite", result.stdout + result.stderr)
                self.assertEqual(len(calls), 1)

    def test_singular_success_summary_runs_every_selected_suite(self):
        for summary in (
            "Test run with 1 test in 1 suite passed after 0.075 seconds.\n",
            "Executed 1 test, with 0 failures (0 unexpected).\n",
        ):
            with self.subTest(summary=summary):
                result, calls, cleanups = self.run_step(
                    [
                        {"text": "Test run with 7 tests in 1 suite passed.\n"},
                        {"text": summary + LARGE_TAIL},
                    ]
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(calls), 2)
                self.assertIn("-only-testing:cmuxTests/FirstSuite", calls[0])
                self.assertIn("-only-testing:cmuxTests/SecondSuite", calls[1])
                self.assertEqual(cleanups, 0)

    def test_failed_suite_reports_failure_and_runs_later_suites(self):
        result, calls, _ = self.run_step(
            [{"text": "Executed 2 tests, with 1 failure.\n", "status": 65},
             {"text": "Executed 1 test, with 0 failures.\n"}]
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(calls), 2)

    def test_large_package_resolution_error_retries_once(self):
        result, calls, cleanups = self.run_step(
            [
                {"text": "Could not resolve package dependencies\n" + LARGE_TAIL, "status": 74},
                {"text": "Test run with 2 tests passed.\n"},
            ],
            suites="FirstSuite",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertEqual(cleanups, 2)

    def test_invalid_suite_is_rejected_without_invoking_xcode(self):
        result, calls, _ = self.run_step([], suites="InvalidSuite;exit 0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid unit suite identifier", result.stdout + result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
