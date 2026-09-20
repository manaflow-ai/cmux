#!/usr/bin/env python3

import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/classify-app-host-test-output.py"
TEST_DEPOT_WORKFLOW = ROOT / ".github/workflows/test-depot.yml"
TEST_DEPOT_RUN_UNIT_TESTS = next(
    step["run"]
    for step in yaml.safe_load(TEST_DEPOT_WORKFLOW.read_text(encoding="utf-8"))["jobs"]["tests"]["steps"]
    if step.get("name") == "Run unit tests"
)
SPEC = importlib.util.spec_from_file_location("classify_app_host_test_output", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class AppHostTestOutputTests(unittest.TestCase):
    def test_all_expected_failures_are_tolerated(self) -> None:
        passed, message = MODULE.classify(
            "Executed 4 tests, with 1 failure (0 unexpected)\n"
            "Executed 8 tests, with 2 failures (0 unexpected)\n"
        )

        self.assertTrue(passed)
        self.assertIn("2 XCTest summary", message)

    def test_unexpected_failure_in_earlier_summary_is_not_masked(self) -> None:
        passed, message = MODULE.classify(
            "Executed 4 tests, with 1 failure (1 unexpected)\n"
            "Executed 8 tests, with 2 failures (0 unexpected)\n"
        )

        self.assertFalse(passed)
        self.assertIn("1 unexpected failure", message)

    def test_missing_summary_is_not_tolerated(self) -> None:
        passed, message = MODULE.classify("xcodebuild aborted before reporting results\n")

        self.assertFalse(passed)
        self.assertIn("no trustworthy XCTest summary", message)

    def test_zero_summary_is_not_tolerated(self) -> None:
        passed, message = MODULE.classify(
            "Executed 0 tests, with 0 failures (0 unexpected)\n"
        )

        self.assertFalse(passed)
        self.assertIn("zero executed tests", message)

    def test_timeout_or_restart_cannot_be_erased_by_a_passing_subset(self) -> None:
        fixture = (ROOT / "tests/fixtures/app-host-timeout-restart.txt").read_text()
        for output in (
            fixture,
            fixture.replace("Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.\n", ""),
            fixture.replace("✘ Test remoteManualInputPreservesLiteralAndNamedKeyOrder() recorded an issue: Time limit was exceeded: 300.000 seconds\n", ""),
            "\n".join("2026-09-20T07:30:00.000Z \x1b[31m" + line + "\x1b[0m" for line in fixture.splitlines()),
        ):
            with self.subTest(output=output):
                passed, message = MODULE.classify(output)
                self.assertFalse(passed)
                self.assertIn("incomplete app-host test run", message)

    def test_timeout_words_in_successful_test_names_or_app_logs_are_not_failures(self) -> None:
        passed, _ = MODULE.classify(
            "2026-09-20 07:11:24 cmux DEV[4667:30096] Receive failed: Operation timed out\n"
            "✔ Test handlesTimeoutAndRestart() passed after 0.001 seconds.\n"
            "Executed 2 tests, with 0 failures (0 unexpected)\n"
            "✔ Test run with 6 tests in 1 suite passed after 2.562 seconds.\n"
        )
        self.assertTrue(passed)

    def test_real_wrapper_and_cli_reject_timeout_restart_final_pass_replay(self) -> None:
        fixture = (ROOT / "tests/fixtures/app-host-timeout-restart.txt").read_text()
        with tempfile.TemporaryDirectory() as directory:
            output_path = pathlib.Path(directory) / "output.log"
            replay = subprocess.run(
                [sys.executable, str(ROOT / "scripts/ci/xcodebuild_noninteractive.py"),
                 sys.executable, "-c", "import sys; print(" + repr(fixture) + "); sys.exit(65)"],
                env={**os.environ, "CMUX_XCODEBUILD_NONINTERACTIVE_LOG_PATH": str(output_path)},
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(replay.returncode, 65, replay.stderr)
            gate = subprocess.run(
                [sys.executable, str(SCRIPT), str(output_path)],
                capture_output=True, text=True, check=False,
            )
        self.assertEqual(gate.returncode, 1, gate.stdout + gate.stderr)
        self.assertIn("incomplete app-host test run", gate.stderr)

    def test_diagnoses_compile_failure_before_tests(self) -> None:
        diagnosis = MODULE.diagnose(
            "Sources/AppDelegate.swift:8:3: error: cannot find type 'Missing' in scope\n"
            "Testing failed:\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "pre-test build/setup failure")
        self.assertEqual(diagnosis["executed_tests"], 0)
        self.assertIn("cannot find type", diagnosis["first_causal_line"])

    def test_diagnoses_app_host_failure_before_tests(self) -> None:
        diagnosis = MODULE.diagnose(
            "The test runner timed out while preparing to run tests.\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "pre-test app-host failure")
        self.assertEqual(diagnosis["executed_tests"], 0)

    def test_ignores_build_signature_when_finding_app_host_cause(self) -> None:
        diagnosis = MODULE.diagnose(
            "Build description Signal 5 is a digest label, not a crash marker\n"
            "The test runner timed out while preparing to run tests.\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "pre-test app-host failure")
        self.assertIn("test runner timed out", diagnosis["first_causal_line"])

    def test_diagnoses_crash_before_tests_as_app_host_failure(self) -> None:
        diagnosis = MODULE.diagnose(
            "Fatal error: Initial workspace creation failed\n"
            "*** Program crashed: Signal 5 ***\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "pre-test app-host failure")
        self.assertIn("Fatal error", diagnosis["first_causal_line"])

    def test_diagnoses_contextual_signal_name_as_app_host_failure(self) -> None:
        diagnosis = MODULE.diagnose(
            "Received signal SIGABRT from the app host\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "pre-test app-host failure")

    def test_diagnoses_numeric_signal_without_banner_in_crash_context(self) -> None:
        diagnosis = MODULE.diagnose(
            "terminated by signal 9\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "pre-test app-host failure")

    def test_diagnoses_assertion_failure_after_tests(self) -> None:
        diagnosis = MODULE.diagnose(
            "✘ Test notification() recorded an issue\n"
            "Test run with 9 tests in 1 suite failed after 0.1 seconds.\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "test assertion failure")
        self.assertEqual(diagnosis["executed_tests"], 9)

    def test_diagnoses_app_host_failure_before_assertion_failure(self) -> None:
        diagnosis = MODULE.diagnose(
            "Test run with 9 tests in 1 suite failed after 0.1 seconds.\n"
            "Restarting after unexpected exit, crash, or test timeout.\n",
            exit_code=65,
        )

        self.assertEqual(diagnosis["category"], "post-test app-host failure")
        self.assertEqual(diagnosis["executed_tests"], 9)

    def test_diagnoses_pass(self) -> None:
        diagnosis = MODULE.diagnose(
            "Test run with 3 tests in 1 suite passed after 0.1 seconds.\n",
            exit_code=0,
        )

        self.assertEqual(diagnosis["category"], "tests passed")
        self.assertEqual(diagnosis["executed_tests"], 3)

    def test_cli_diagnose_mode_does_not_change_default_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_path = pathlib.Path(temporary_directory) / "output.log"
            output_path.write_text(
                "Executed 1 test, with 1 failure (1 unexpected)\n",
                encoding="utf-8",
            )
            gated = subprocess.run(
                [sys.executable, str(SCRIPT), str(output_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            diagnostic = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(output_path),
                    "--suite",
                    "ExampleTests",
                    "--exit-code",
                    "65",
                    "--diagnose",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertNotEqual(gated.returncode, 0)
        self.assertEqual(diagnostic.returncode, 0)
        self.assertIn("category=test assertion failure", diagnostic.stdout)

    def test_cli_rejects_option_as_suite_value(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_path = pathlib.Path(temporary_directory) / "output.log"
            output_path.write_text(
                "Test run with 1 test in 1 suite passed after 0.001 seconds.\n",
                encoding="utf-8",
            )
            malformed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(output_path),
                    "--suite",
                    "--diagnose",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(malformed.returncode, 2)

    def test_full_suite_keeps_nonzero_app_host_exit_red_with_clean_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            fake_ci = root / "scripts/ci"
            fake_ci.mkdir(parents=True)
            shutil.copy2(SCRIPT, fake_ci / SCRIPT.name)
            fake_runner = fake_ci / "xcodebuild_noninteractive.py"
            fake_runner.write_text(
                "#!/usr/bin/env python3\n"
                "print('Executed 2 tests, with 0 failures (0 unexpected)')\n"
                "raise SystemExit(65)\n",
                encoding="utf-8",
            )
            fake_runner.chmod(0o755)
            environment = {
                **os.environ,
                "UNIT_TEST_SUITES": "",
                "TEST_RESULTS_ROOT": str(root / "results"),
            }
            completed = subprocess.run(
                ["bash", "-c", TEST_DEPOT_RUN_UNIT_TESTS],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertNotEqual(completed.returncode, 0)

    def test_selected_suite_requires_positive_summary_and_keeps_log_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            fake_ci = root / "scripts/ci"
            fake_ci.mkdir(parents=True)
            shutil.copy2(SCRIPT, fake_ci / SCRIPT.name)
            fake_runner = fake_ci / "xcodebuild_noninteractive.py"
            fake_runner.write_text(
                "#!/usr/bin/env python3\n"
                "import os\n"
                "if os.environ.get('FAKE_TEST_MODE') == 'compile':\n"
                "    print('Sources/Foo.swift:1:1: error: cannot find Missing in scope')\n"
                "    raise SystemExit(65)\n"
                "print('Test run with 2 tests in 1 suite passed after 0.01 seconds.')\n",
                encoding="utf-8",
            )
            fake_runner.chmod(0o755)

            for mode, expected_success in (("pass", True), ("compile", False)):
                results = root / f"results-{mode}"
                environment = {
                    **os.environ,
                    "UNIT_TEST_SUITES": "Foo",
                    "TEST_RESULTS_ROOT": str(results),
                    "FAKE_TEST_MODE": mode,
                }
                completed = subprocess.run(
                    ["bash", "-c", TEST_DEPOT_RUN_UNIT_TESTS],
                    cwd=root,
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(completed.returncode == 0, expected_success)
                self.assertTrue((results / "Foo.log").is_file())
                self.assertTrue((results / "all-suites.log").is_file())
                if expected_success:
                    self.assertIn("category=tests passed", completed.stdout)
                else:
                    self.assertIn("category=pre-test build/setup failure", completed.stdout)

    def test_singular_summary_is_supported(self) -> None:
        passed, _ = MODULE.classify("Executed 1 test, with 0 failures (0 unexpected)\n")

        self.assertTrue(passed)


if __name__ == "__main__":
    unittest.main()
