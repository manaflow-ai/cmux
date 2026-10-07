#!/usr/bin/env python3

import json
import os
import pathlib
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "ci" / "run-swift-testing-suites.sh"


def run_runner(package: pathlib.Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen(
        [str(RUNNER), str(package)],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    deadline = time.monotonic() + 30
    while process.poll() is None:
        if time.monotonic() >= deadline:
            process.kill()
            output, _ = process.communicate()
            raise AssertionError(f"runner failed to exit within test deadline\n{output}")
        time.sleep(0.05)
    output, _ = process.communicate()
    return subprocess.CompletedProcess(process.args, process.returncode, output)


class SwiftTestingSuiteTimeoutTests(unittest.TestCase):
    def test_success_exit_requires_completed_nonzero_execution(self) -> None:
        for output in (
            "Test run with 0 tests passed after 0.001 seconds.",
            "Test run started.\nTest one() passed after 0.001 seconds.",
        ):
            with self.subTest(output=output), tempfile.TemporaryDirectory() as temp_dir:
                temp = pathlib.Path(temp_dir)
                fake_swift = temp / "swift"
                fake_swift.write_text(
                    "#!/usr/bin/env python3\n"
                    "import sys\n"
                    "if sys.argv[1:3] == ['test', 'list']:\n"
                    "    print('ExampleTests.Suite/testOne()')\n"
                    "else:\n"
                    f"    print({json.dumps(output)})\n",
                    encoding="utf-8",
                )
                fake_swift.chmod(0o755)
                env = os.environ.copy()
                env["PATH"] = f"{temp}:{env['PATH']}"
                completed = run_runner(temp, env)
                self.assertNotEqual(completed.returncode, 0, completed.stdout)
                self.assertIn("no completed nonzero", completed.stdout)

    def test_suite_processes_reuse_the_list_build(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            calls = temp / "calls.txt"
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"$CMUX_SWIFT_TEST_CALLS\"\n"
                "if [[ \"$*\" == *\"test list\"* ]]; then\n"
                "  echo 'ExampleTests.FirstSuite/testOne()'\n"
                "  echo 'ExampleTests.SecondSuite/testTwo()'\n"
                "  exit 0\n"
                "fi\n"
                "echo 'Test run with 1 test passed after 0.001 seconds.'\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / "ExampleTests"
            package.mkdir()
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["CMUX_SWIFT_TEST_CALLS"] = str(calls)

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            invocations = calls.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(invocations), 3, invocations)
            self.assertIn("test list", invocations[0])
            self.assertNotIn("--skip-build", invocations[0])
            for invocation in invocations[1:]:
                self.assertIn("--filter", invocation)
                self.assertIn("--skip-build", invocation)

    def test_top_level_tests_are_not_dropped_when_a_suite_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env python3\n"
                "import re, sys\n"
                "tests = ['ExampleTests.PassingSuite/testOne()', "
                "'ExampleTests.failsOutsideSuite()']\n"
                "if sys.argv[1:3] == ['test', 'list']:\n"
                "    print('\\n'.join(tests))\n"
                "    raise SystemExit(0)\n"
                "selected = [name for name in tests if "
                "re.search(sys.argv[sys.argv.index('--filter') + 1], name)]\n"
                "failed = 'ExampleTests.failsOutsideSuite()' in selected\n"
                "print(f'Test run with {len(selected)} tests "
                "{\"failed\" if failed else \"passed\"} after 0.001 seconds.')\n"
                "raise SystemExit(17 if failed else 0)\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / "ExampleTests"
            package.mkdir()
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 17, completed.stdout)
            self.assertIn("1 tests failed", completed.stdout)

    def test_timeout_retry_reuses_the_existing_build(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            calls = temp / "calls.txt"
            attempts = temp / "attempts.txt"
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"$CMUX_SWIFT_TEST_CALLS\"\n"
                "if [[ \"$*\" == *\"test list\"* ]]; then\n"
                "  echo 'ExampleTests.RetrySuite/testOne()'\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$*\" != *\"--skip-build\"* ]]; then\n"
                "  exit 91\n"
                "fi\n"
                "count=0\n"
                "if [[ -f \"$CMUX_SWIFT_TEST_ATTEMPTS\" ]]; then count=$(cat \"$CMUX_SWIFT_TEST_ATTEMPTS\"); fi\n"
                "count=$((count + 1))\n"
                "printf '%s' \"$count\" > \"$CMUX_SWIFT_TEST_ATTEMPTS\"\n"
                "if [[ \"$count\" -eq 1 ]]; then exit 124; fi\n"
                "echo 'Test run with 1 test passed after 0.001 seconds.'\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / "ExampleTests"
            package.mkdir()
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["CMUX_SWIFT_TEST_CALLS"] = str(calls)
            env["CMUX_SWIFT_TEST_ATTEMPTS"] = str(attempts)

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            invocations = calls.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(invocations), 3, invocations)
            self.assertEqual(attempts.read_text(encoding="utf-8"), "2")
            for invocation in invocations[1:]:
                self.assertIn("--skip-build", invocation)
            self.assertIn("retrying ^ExampleTests\\.RetrySuite/ once", completed.stdout)

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

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 124, completed.stdout)
            self.assertEqual(completed.stdout.count("timed out after 1s"), 2)
            self.assertIn("retrying ^ExampleTests\\.HangingSuite/ once", completed.stdout)


    def test_a_failing_suite_does_not_stop_the_suites_after_it(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            calls = temp / "calls.txt"
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"$CMUX_SWIFT_TEST_CALLS\"\n"
                "if [[ \"$*\" == *\"test list\"* ]]; then\n"
                "  echo 'ExampleTests.AFailingSuite/testOne()'\n"
                "  echo 'ExampleTests.BHangingSuite/testTwo()'\n"
                "  echo 'ExampleTests.CPassingSuite/testThree()'\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$*\" == *AFailingSuite* ]]; then\n"
                "  echo 'Test run with 1 test failed after 0.001 seconds.'\n"
                "  exit 17\n"
                "fi\n"
                "if [[ \"$*\" == *BHangingSuite* ]]; then\n"
                "  sleep 30\n"
                "fi\n"
                "echo 'Test run with 1 test passed after 0.001 seconds.'\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            package = temp / "ExampleTests"
            package.mkdir()
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["CMUX_SWIFT_TEST_CALLS"] = str(calls)
            env["CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS"] = "1"

            completed = run_runner(package, env)

            # The first failure's status, after every suite ran.
            self.assertEqual(completed.returncode, 17, completed.stdout)
            invocations = calls.read_text(encoding="utf-8").splitlines()
            self.assertTrue(any("CPassingSuite" in call for call in invocations), invocations)
            self.assertIn("Swift test suites: 1 passed, 2 failed", completed.stdout)
            self.assertIn("FAIL (exit 17) ^ExampleTests\\.AFailingSuite/", completed.stdout)
            self.assertIn("FAIL (timed out) ^ExampleTests\\.BHangingSuite/", completed.stdout)
            self.assertIn("PASS ^ExampleTests\\.CPassingSuite/", completed.stdout)


    def test_cmux_next_builds_the_web_bundles_before_the_swift_build(self) -> None:
        """The bundles are build output (cx-vn5). Without them AgentPaneView.init returns nil
        and the pane suites crash on the fleet (_setIgnoreFocusEngine, aws-m4pro-2 and -3)."""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            calls = temp / "calls.txt"
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "printf 'swift %s\\n' \"$*\" >> \"$CMUX_SWIFT_TEST_CALLS\"\n"
                "if [[ \"$*\" == *\"test list\"* ]]; then echo 'ExampleTests.Suite/testOne()'; exit 0; fi\n"
                "echo 'Test run with 1 test passed after 0.001 seconds.'\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            ensure = temp / "ensure"
            ensure.write_text(
                "#!/usr/bin/env bash\n"
                "printf 'ensure %s\\n' \"$PWD\" >> \"$CMUX_SWIFT_TEST_CALLS\"\n"
                "exit \"${FAKE_ENSURE_STATUS:-0}\"\n",
                encoding="utf-8",
            )
            ensure.chmod(0o755)
            next_package = temp / "Packages" / "macOS" / "CmuxNext"
            next_package.mkdir(parents=True)
            other_package = temp / "Packages" / "macOS" / "CmuxCore"
            other_package.mkdir(parents=True)
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["CMUX_SWIFT_TEST_CALLS"] = str(calls)
            env["CMUX_ENSURE_WEB_BUNDLES"] = str(ensure)

            completed = run_runner(next_package, env)
            self.assertEqual(completed.returncode, 0, completed.stdout)
            invocations = calls.read_text(encoding="utf-8").splitlines()
            self.assertEqual(invocations[0], f"ensure {ROOT}", invocations)
            self.assertIn("test list", invocations[1])

            calls.write_text("", encoding="utf-8")
            completed = run_runner(other_package, env)
            self.assertEqual(completed.returncode, 0, completed.stdout)
            self.assertFalse(
                [line for line in calls.read_text(encoding="utf-8").splitlines() if line.startswith("ensure")]
            )

            calls.write_text("", encoding="utf-8")
            env["FAKE_ENSURE_STATUS"] = "3"
            completed = run_runner(next_package, env)
            self.assertNotEqual(completed.returncode, 0, completed.stdout)
            self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), [f"ensure {ROOT}"])

    def test_string_catalogs_compile_after_the_build_and_before_the_suites(self) -> None:
        """cx-v2k: swift build copies String Catalogs uncompiled, so QuitAlertContent,
        RefusalLocalization, TerminalHostLossBanner, TerminalStatusBannerTranslation and
        SettingsText failed on the fleet only (cmux-next.yml compiles them)."""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            calls = temp / "calls.txt"
            fake_swift = temp / "swift"
            fake_swift.write_text(
                "#!/usr/bin/env bash\n"
                "printf 'swift %s\\n' \"$*\" >> \"$CMUX_SWIFT_TEST_CALLS\"\n"
                "if [[ \"$*\" == *\"test list\"* ]]; then echo 'ExampleTests.Suite/testOne()'; exit 0; fi\n"
                "echo 'Test run with 1 test passed after 0.001 seconds.'\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)
            compile_catalogs = temp / "compile"
            compile_catalogs.write_text(
                "#!/usr/bin/env bash\n"
                "printf 'compile %s\\n' \"$PWD\" >> \"$CMUX_SWIFT_TEST_CALLS\"\n"
                "exit \"${FAKE_COMPILE_STATUS:-0}\"\n",
                encoding="utf-8",
            )
            compile_catalogs.chmod(0o755)
            package = temp / "ExampleTests"
            (package / "Sources" / "Example" / "Resources").mkdir(parents=True)
            (package / "Sources" / "Example" / "Resources" / "Localizable.xcstrings").write_text("{}", encoding="utf-8")
            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["CMUX_SWIFT_TEST_CALLS"] = str(calls)
            env["CMUX_COMPILE_STRING_CATALOGS"] = str(compile_catalogs)

            completed = run_runner(package, env)
            self.assertEqual(completed.returncode, 0, completed.stdout)
            invocations = calls.read_text(encoding="utf-8").splitlines()
            self.assertIn("test list", invocations[0])
            self.assertEqual(invocations[1], f"compile {package.resolve()}", invocations)
            self.assertIn("--skip-build", invocations[2])

            calls.write_text("", encoding="utf-8")
            env["FAKE_COMPILE_STATUS"] = "4"
            completed = run_runner(package, env)
            self.assertNotEqual(completed.returncode, 0, completed.stdout)
            self.assertFalse([line for line in calls.read_text(encoding="utf-8").splitlines() if "--skip-build" in line])

if __name__ == "__main__":
    unittest.main()
