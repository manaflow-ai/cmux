#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
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

    def _write_fake_swift(self, temp: pathlib.Path, body: str) -> None:
        # Every call appends "start <suite> <t>" and "end <suite> <t>" lines to
        # $CMUX_SWIFT_TEST_EVENTS, so a test can tell whether suites overlapped.
        fake_swift = temp / "swift"
        fake_swift.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys, time\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['CMUX_SWIFT_TEST_CALLS'], 'a') as calls:\n"
            "    calls.write(' '.join(args) + '\\n')\n"
            "suites = os.environ['FAKE_SUITES'].split()\n"
            "if args[:2] == ['test', 'list']:\n"
            "    for suite in suites:\n"
            "        print(f'ExampleTests.{suite}/testOne()')\n"
            "    raise SystemExit(0)\n"
            "selected = args[args.index('--filter') + 1]\n"
            "suite = next(s for s in suites if s in selected)\n"
            "def event(kind):\n"
            "    with open(os.environ['CMUX_SWIFT_TEST_EVENTS'], 'a') as events:\n"
            "        events.write(f'{kind} {suite} {time.monotonic()}\\n')\n"
            "event('start')\n"
            + body
            + "event('end')\n",
            encoding="utf-8",
        )
        fake_swift.chmod(0o755)

    def _jobs_env(self, temp: pathlib.Path, suites: list[str], jobs: str) -> dict[str, str]:
        env = os.environ.copy()
        env["PATH"] = f"{temp}:{env['PATH']}"
        env["CMUX_SWIFT_TEST_CALLS"] = str(temp / "calls.txt")
        env["CMUX_SWIFT_TEST_EVENTS"] = str(temp / "events.txt")
        env["FAKE_SUITES"] = " ".join(suites)
        env["CMUX_SWIFT_TEST_SUITE_JOBS"] = jobs
        return env

    @staticmethod
    def _overlapped(events_path: pathlib.Path, first: str, second: str) -> bool:
        spans: dict[str, list[float]] = {}
        for line in events_path.read_text(encoding="utf-8").splitlines():
            kind, suite, at = line.split()
            spans.setdefault(suite, [0.0, 0.0])[0 if kind == "start" else 1] = float(at)
        return spans[first][0] < spans[second][1] and spans[second][0] < spans[first][1]

    def test_concurrent_suites_print_whole_blocks_under_their_own_header(self) -> None:
        """CMUX_SWIFT_TEST_SUITE_JOBS runs suites at once; each suite's output stays
        one block after a header that names the suite, never interleaved."""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            suites = ["AlphaSuite", "BetaSuite"]
            self._write_fake_swift(
                temp,
                "for index in range(5):\n"
                "    print(f'{suite} line {index}', flush=True)\n"
                "    time.sleep(0.2)\n"
                "print('Test run with 1 test passed after 0.001 seconds.', flush=True)\n",
            )
            package = temp / "ExampleTests"
            package.mkdir()
            env = self._jobs_env(temp, suites, "2")

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            self.assertTrue(
                self._overlapped(temp / "events.txt", "AlphaSuite", "BetaSuite"),
                "the two suites did not run at the same time",
            )
            lines = completed.stdout.splitlines()
            for suite in suites:
                body = [index for index, line in enumerate(lines) if line.startswith(f"{suite} line ")]
                self.assertEqual(len(body), 5, completed.stdout)
                self.assertEqual(body, list(range(body[0], body[0] + 5)), completed.stdout)
                header = lines[body[0] - 1]
                self.assertIn("--filter", header, completed.stdout)
                self.assertIn(suite, header, completed.stdout)
            calls = (temp / "calls.txt").read_text(encoding="utf-8").splitlines()
            for call in calls[1:]:
                self.assertIn("--ignore-lock", call)

    def test_concurrent_run_exits_with_the_first_failure_in_suite_order(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            suites = ["APassingSuite", "BSlowFailingSuite", "CFastFailingSuite", "DPassingSuite"]
            self._write_fake_swift(
                temp,
                "if suite == 'BSlowFailingSuite':\n"
                "    time.sleep(1)\n"
                "    print('Test run with 1 test failed after 1 seconds.')\n"
                "    event('end')\n"
                "    raise SystemExit(17)\n"
                "if suite == 'CFastFailingSuite':\n"
                "    print('Test run with 1 test failed after 0.001 seconds.')\n"
                "    event('end')\n"
                "    raise SystemExit(23)\n"
                "time.sleep(0.5)\n"
                "print('Test run with 1 test passed after 0.5 seconds.')\n",
            )
            package = temp / "ExampleTests"
            package.mkdir()
            env = self._jobs_env(temp, suites, "4")

            completed = run_runner(package, env)

            # C fails first in time; B is first in suite order and decides the status.
            self.assertEqual(completed.returncode, 17, completed.stdout)
            self.assertTrue(self._overlapped(temp / "events.txt", "BSlowFailingSuite", "CFastFailingSuite"))
            summary = completed.stdout[completed.stdout.index("Swift test suites:"):].splitlines()
            self.assertEqual(summary[0], "Swift test suites: 2 passed, 2 failed", completed.stdout)
            self.assertEqual(
                [line.strip() for line in summary[1:]],
                [
                    "PASS ^ExampleTests\\.APassingSuite/",
                    "FAIL (exit 17) ^ExampleTests\\.BSlowFailingSuite/",
                    "FAIL (exit 23) ^ExampleTests\\.CFastFailingSuite/",
                    "PASS ^ExampleTests\\.DPassingSuite/",
                ],
                completed.stdout,
            )

    def test_summary_lists_every_suite_when_suites_outnumber_jobs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            suites = [f"Suite{index:02d}" for index in range(12)]
            self._write_fake_swift(
                temp,
                "time.sleep(0.05 * (len(suites) - suites.index(suite)) % 0.3)\n"
                "print('Test run with 1 test passed after 0.001 seconds.')\n",
            )
            package = temp / "ExampleTests"
            package.mkdir()
            env = self._jobs_env(temp, suites, "3")

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            summary = completed.stdout[completed.stdout.index("Swift test suites:"):].splitlines()
            self.assertEqual(summary[0], "Swift test suites: 12 passed, 0 failed", completed.stdout)
            self.assertEqual(
                [line.strip() for line in summary[1:]],
                [f"PASS ^ExampleTests\\.{suite}/" for suite in suites],
            )
            starts = [line for line in (temp / "events.txt").read_text().splitlines() if line.startswith("start")]
            self.assertEqual(len(starts), 12)

    def test_one_job_keeps_the_serial_run(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            suites = ["AlphaSuite", "BetaSuite"]
            self._write_fake_swift(
                temp,
                "time.sleep(0.3)\n"
                "print('Test run with 1 test passed after 0.3 seconds.')\n",
            )
            package = temp / "ExampleTests"
            package.mkdir()
            env = self._jobs_env(temp, suites, "1")

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            self.assertFalse(self._overlapped(temp / "events.txt", "AlphaSuite", "BetaSuite"))
            calls = (temp / "calls.txt").read_text(encoding="utf-8").splitlines()
            for call in calls[1:]:
                self.assertNotIn("--ignore-lock", call)

    def test_a_locked_build_database_is_retried_not_reported(self) -> None:
        """Fleet run 19bb98813274 (aws-m4pro-7): with --ignore-lock, two suites at once
        still open .build/build.db; SwiftPM refused one with "database is locked" before
        any test ran, and the suite failed as "no tests found"."""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            attempts = temp / "attempts.txt"
            self._write_fake_swift(
                temp,
                "count = int(open(os.environ['FAKE_ATTEMPTS']).read() or 0) if os.path.exists(os.environ['FAKE_ATTEMPTS']) else 0\n"
                "open(os.environ['FAKE_ATTEMPTS'], 'w').write(str(count + 1))\n"
                "if suite == 'LockedSuite' and count < 2:\n"
                "    print('error: unable to attach DB: error: accessing build database \"/x/.build/build.db\": '\n"
                "          'database is locked Possibly there are two concurrent builds running in the same filesystem location.')\n"
                "    print(\"error: no tests found; create a target in the 'Tests' directory\")\n"
                "    event('end')\n"
                "    raise SystemExit(1)\n"
                "print('Test run with 1 test passed after 0.001 seconds.')\n",
            )
            package = temp / "ExampleTests"
            package.mkdir()
            env = self._jobs_env(temp, ["LockedSuite"], "2")
            env["FAKE_ATTEMPTS"] = str(attempts)

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            self.assertEqual(attempts.read_text(encoding="utf-8"), "3")
            self.assertIn("build database was locked", completed.stdout)
            self.assertIn("PASS ^ExampleTests\\.LockedSuite/", completed.stdout)

    def test_invalid_job_count_is_refused(self) -> None:
        for jobs in ("0", "two", "-3"):
            with self.subTest(jobs=jobs), tempfile.TemporaryDirectory() as temp_dir:
                temp = pathlib.Path(temp_dir)
                self._write_fake_swift(temp, "print('Test run with 1 test passed after 0.001 seconds.')\n")
                package = temp / "ExampleTests"
                package.mkdir()
                env = self._jobs_env(temp, ["AlphaSuite"], jobs)

                completed = run_runner(package, env)

                self.assertEqual(completed.returncode, 2, completed.stdout)
                self.assertIn("CMUX_SWIFT_TEST_SUITE_JOBS", completed.stdout)
                self.assertFalse((temp / "calls.txt").exists())

    def _shard_run(self, shard: str, suites: list[str]) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir)
            self._write_fake_swift(temp, "print('Test run with 1 test passed after 0.001 seconds.')\n")
            package = temp / "ExampleTests"
            package.mkdir()
            env = self._jobs_env(temp, suites, "2")
            env["CMUX_SWIFT_TEST_SHARD"] = shard
            completed = run_runner(package, env)
            calls_path = temp / "calls.txt"
            calls = calls_path.read_text(encoding="utf-8").splitlines() if calls_path.exists() else []
            return completed, calls

    def test_shards_split_the_sorted_suites_round_robin_and_cover_each_once(self) -> None:
        """CMUX_SWIFT_TEST_SHARD=i/n: every shard builds (test list), then runs only
        its suites; together the shards run every suite exactly once."""
        suites = ["Echo", "Alpha", "Delta", "Bravo", "Foxtrot", "Charlie", "Golf"]
        seen: list[str] = []
        for index in range(1, 4):
            completed, calls = self._shard_run(f"{index}/3", suites)
            self.assertEqual(completed.returncode, 0, completed.stdout)
            self.assertIn("test list", calls[0])
            ran = sorted(next(s for s in suites if f".{s}/" in call) for call in calls[1:])
            expected = sorted(suites)[index - 1 :: 3]
            self.assertEqual(ran, expected, completed.stdout)
            self.assertIn(f"Swift test shard {index}/3: {len(expected)} of {len(suites)} suites", completed.stdout)
            self.assertIn(f"Swift test suites: {len(expected)} passed, 0 failed", completed.stdout)
            seen.extend(ran)
        self.assertEqual(sorted(seen), sorted(suites))

    def test_a_shard_without_suites_passes_after_the_build(self) -> None:
        completed, calls = self._shard_run("3/3", ["Alpha", "Bravo"])
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertEqual(len(calls), 1, calls)
        self.assertIn("Swift test shard 3/3: 0 of 2 suites", completed.stdout)

    def test_invalid_shard_is_refused_before_the_build(self) -> None:
        for shard in ("0/2", "3/2", "1", "a/b", "1/0", "/2", "1/2/3"):
            with self.subTest(shard=shard):
                completed, calls = self._shard_run(shard, ["Alpha"])
                self.assertEqual(completed.returncode, 2, completed.stdout)
                self.assertIn("CMUX_SWIFT_TEST_SHARD", completed.stdout)
                self.assertEqual(calls, [])


# The fake toolchain for CMUX_SWIFT_TEST_DIRECT=1: `swift` lists and builds,
# `xcrun` finds the tools, and the fake xctest and swiftpm-testing-helper record
# each run (argv, working directory, the environment SwiftPM gives them) and
# act out FAKE_BEHAVIOR[<test or suite name>]: pass, fail, crash, hang, empty.
FAKE_DIRECT_SWIFT = r"""#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
with open(os.environ["CMUX_SWIFT_TEST_CALLS"], "a") as calls:
    calls.write("swift " + " ".join(args) + "\n")
xctests = os.environ["FAKE_XCTESTS"].split()
swift_tests = os.environ["FAKE_SWIFT_TESTS"].split()
if args[:2] == ["test", "list"]:
    listed = xctests if "--disable-swift-testing" in args else sorted(xctests + swift_tests)
    print("\n".join(listed))
    raise SystemExit(0)
if args[:1] == ["build"] and "--show-bin-path" in args:
    print(os.environ["FAKE_BIN_PATH"])
    raise SystemExit(0)
print("swift was asked to run tests in direct mode")
raise SystemExit(99)
"""

FAKE_DIRECT_XCRUN = r"""#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
root = os.environ["FAKE_TOOLS"]
if args == ["--find", "xctest"]:
    print(root + "/Developer/usr/bin/xctest")
elif args == ["--find", "swift-test"]:
    print(root + "/Toolchain/usr/bin/swift-test")
elif args == ["--sdk", "macosx", "--show-sdk-platform-path"]:
    print(root + "/MacOSX.platform")
elif args == ["--sdk", "macosx", "--show-sdk-path"]:
    print(root + "/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
else:
    raise SystemExit(f"fake xcrun: unexpected {args}")
"""

FAKE_DIRECT_RUNNER = r"""#!/usr/bin/env python3
import json, os, re, signal, sys, time
tool = os.path.basename(sys.argv[0])
args = sys.argv[1:]
env = {key: os.environ.get(key) for key in
       ("SWIFT_TESTING_ENABLED", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "SDKROOT")}
with open(os.environ["CMUX_DIRECT_CALLS"], "a") as calls:
    calls.write(json.dumps({"tool": tool, "args": args, "cwd": os.getcwd(), "env": env}) + "\n")
behavior = json.loads(os.environ.get("FAKE_BEHAVIOR", "{}"))
def act(names):
    for name in names:
        for key, value in behavior.items():
            if key in name:
                return value
    return "pass"
if tool == "xctest":
    selected = args[args.index("-XCTest") + 1].split(",")
    action = act(selected)
    for name in selected:
        print(f"Test Case '-[{name}]' started.", flush=True)
else:
    pattern = args[args.index("--filter") + 1]
    selected = [name for name in os.environ["FAKE_SWIFT_TESTS"].split() if re.search(pattern, name)]
    action = act(selected)
    print("Test run started.", flush=True)
if action == "hang":
    time.sleep(30)
if action == "crash":
    os.kill(os.getpid(), signal.SIGTRAP)
if action == "empty":
    raise SystemExit(0)
failed = action == "fail"
if tool == "xctest":
    verdict = "failed" if failed else "passed"
    print(f"Test Suite 'Selected tests' {verdict} at 2026-10-09 00:00:00.000.")
    print(f"\t Executed {len(selected)} tests, with {int(failed)} failures (0 unexpected) in 0.001 (0.001) seconds")
else:
    print(f"Test run with {len(selected)} tests {'failed' if failed else 'passed'} after 0.001 seconds.")
raise SystemExit(1 if failed else 0)
"""


class DirectBundleSuiteTests(unittest.TestCase):
    """CMUX_SWIFT_TEST_DIRECT=1: after the one build, every suite runs the built
    test bundle the way `swift test` does (xctest -XCTest for XCTest cases,
    swiftpm-testing-helper for Swift Testing), without a SwiftPM process per
    suite. Fleet run 2026-10-09: 8 parallel `swift test --skip-build` processes
    still opened .build/build.db, and "database is locked" failed AccountsModel,
    ActionCatalog, ActionCatalogLocalization, ActionContract and ActionRegistry
    after 3 retries."""

    XCTESTS = ["Example.XcSuite/testA", "Example.XcSuite/testB"]
    SWIFT_TESTS = ["Example.StSuite/one()", "Example.StSuite/two()", "Example.topLevel()"]

    def _setup(self, temp: pathlib.Path, behavior: dict[str, str] | None = None,
               xctests: list[str] | None = None, swift_tests: list[str] | None = None) -> tuple[pathlib.Path, dict[str, str]]:
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        for name, body in (("swift", FAKE_DIRECT_SWIFT), ("xcrun", FAKE_DIRECT_XCRUN)):
            (bin_dir / name).write_text(body, encoding="utf-8")
            (bin_dir / name).chmod(0o755)
        tools = temp / "tools"
        for relative in ("Developer/usr/bin/xctest", "Toolchain/usr/libexec/swift/pm/swiftpm-testing-helper"):
            path = tools / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            # sys.executable, not /usr/bin/env: macOS strips DYLD_* from the
            # environment of SIP-protected binaries, so the record would miss them.
            path.write_text(
                FAKE_DIRECT_RUNNER.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1),
                encoding="utf-8",
            )
            path.chmod(0o755)
        (tools / "Toolchain/usr/bin").mkdir(parents=True)
        (tools / "MacOSX.platform/Developer/SDKs/MacOSX.sdk").mkdir(parents=True)
        package = temp / "Example"
        bundle = package / ".build" / "arm64-apple-macosx" / "debug" / "ExamplePackageTests.xctest"
        (bundle / "Contents" / "MacOS").mkdir(parents=True)
        (bundle / "Contents" / "MacOS" / "ExamplePackageTests").write_text("", encoding="utf-8")
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env['PATH']}"
        env["CMUX_SWIFT_TEST_DIRECT"] = "1"
        env["CMUX_SWIFT_TEST_SUITE_JOBS"] = "2"
        env["CMUX_SWIFT_TEST_CALLS"] = str(temp / "swift-calls.txt")
        env["CMUX_DIRECT_CALLS"] = str(temp / "direct-calls.jsonl")
        env["FAKE_TOOLS"] = str(tools)
        env["FAKE_BIN_PATH"] = str(bundle.parent)
        env["FAKE_XCTESTS"] = " ".join(self.XCTESTS if xctests is None else xctests)
        env["FAKE_SWIFT_TESTS"] = " ".join(self.SWIFT_TESTS if swift_tests is None else swift_tests)
        env["FAKE_BEHAVIOR"] = json.dumps(behavior or {})
        for key in ("DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "SDKROOT", "SWIFT_TESTING_ENABLED", "DEVELOPER_DIR"):
            env.pop(key, None)
        return package, env

    @staticmethod
    def _direct_calls(temp: pathlib.Path) -> list[dict]:
        path = temp / "direct-calls.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def test_suites_run_the_built_bundle_like_swift_test(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir).resolve()
            package, env = self._setup(temp)

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            swift_calls = (temp / "swift-calls.txt").read_text(encoding="utf-8").splitlines()
            self.assertFalse([call for call in swift_calls if "--filter" in call], swift_calls)
            self.assertIn("test list", swift_calls[0])
            self.assertNotIn("--skip-build", swift_calls[0])
            tools = temp / "tools"
            bundle = package / ".build" / "arm64-apple-macosx" / "debug" / "ExamplePackageTests.xctest"
            binary = bundle / "Contents" / "MacOS" / "ExamplePackageTests"
            platform = tools / "MacOSX.platform" / "Developer"
            expected_env = {
                "DYLD_FRAMEWORK_PATH": f"{platform}/Library/Frameworks:{platform}/Library/PrivateFrameworks",
                "DYLD_LIBRARY_PATH": f"{platform}/usr/lib",
                "SDKROOT": str(platform / "SDKs" / "MacOSX.sdk"),
            }
            calls = self._direct_calls(temp)
            xctest = [call for call in calls if call["tool"] == "xctest"]
            helper = [call for call in calls if call["tool"] == "swiftpm-testing-helper"]
            # XCTest: one xctest run with SwiftPM's comma-joined test specifiers.
            self.assertEqual(len(xctest), 1, calls)
            self.assertEqual(
                xctest[0]["args"],
                ["-XCTest", "Example.XcSuite/testA,Example.XcSuite/testB", str(bundle)],
            )
            self.assertEqual(xctest[0]["env"], {**expected_env, "SWIFT_TESTING_ENABLED": "0"})
            # Swift Testing: the helper loads the bundle binary and filters itself.
            self.assertEqual(
                sorted(call["args"][3] for call in helper),
                sorted(["^Example\\.StSuite/", "^Example\\.topLevel\\(\\)($|/)"]),
                calls,
            )
            for call in helper:
                self.assertEqual(
                    call["args"],
                    ["--test-bundle-path", str(binary), "--filter", call["args"][3], str(binary),
                     "--testing-library", "swift-testing"],
                )
                self.assertEqual(call["env"], {**expected_env, "SWIFT_TESTING_ENABLED": None})
            # SwiftPM runs the tests in the package directory.
            for call in calls:
                self.assertEqual(pathlib.Path(call["cwd"]).resolve(), package.resolve())
            self.assertIn("Swift test suites: 3 passed, 0 failed", completed.stdout)

    def test_failures_and_crashes_keep_swift_test_exit_status(self) -> None:
        """swift test exits 1 for a failed test and for a crashed test process
        ("Exited with unexpected signal code"); the summary keeps that."""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir).resolve()
            package, env = self._setup(
                temp, {"XcSuite": "fail", "StSuite": "crash", "topLevel": "empty"}
            )

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 1, completed.stdout)
            summary = completed.stdout[completed.stdout.index("Swift test suites:"):].splitlines()
            self.assertEqual(summary[0], "Swift test suites: 0 passed, 3 failed", completed.stdout)
            self.assertEqual(
                [line.strip() for line in summary[1:]],
                [
                    "FAIL (exit 1) ^Example\\.StSuite/",
                    "FAIL (exit 1) ^Example\\.XcSuite/",
                    "FAIL (exit 1) ^Example\\.topLevel\\(\\)($|/)",
                ],
                completed.stdout,
            )
            self.assertIn("Exited with unexpected signal code 5", completed.stdout)
            self.assertIn("no completed nonzero", completed.stdout)

    def test_a_hung_bundle_is_retried_then_reported_as_timed_out(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir).resolve()
            package, env = self._setup(temp, {"StSuite": "hang"}, xctests=[], swift_tests=["Example.StSuite/one()"])
            env["CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS"] = "1"

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 124, completed.stdout)
            self.assertIn("retrying ^Example\\.StSuite/ once", completed.stdout)
            self.assertEqual(len(self._direct_calls(temp)), 2)
            self.assertIn("FAIL (timed out) ^Example\\.StSuite/", completed.stdout)

    def test_shards_split_suites_in_direct_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir).resolve()
            package, env = self._setup(temp)
            env["CMUX_SWIFT_TEST_SHARD"] = "2/3"

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            self.assertIn("Swift test shard 2/3: 1 of 3 suites", completed.stdout)
            calls = self._direct_calls(temp)
            self.assertEqual([call["tool"] for call in calls], ["xctest"], calls)

    def test_a_missing_test_bundle_fails_before_the_suites(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir).resolve()
            package, env = self._setup(temp)
            env["FAKE_BIN_PATH"] = str(temp / "nowhere")

            completed = run_runner(package, env)

            self.assertNotEqual(completed.returncode, 0, completed.stdout)
            self.assertIn("no .xctest bundle", completed.stdout)
            self.assertEqual(self._direct_calls(temp), [])

    def test_invalid_direct_value_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir).resolve()
            package, env = self._setup(temp)
            env["CMUX_SWIFT_TEST_DIRECT"] = "yes"

            completed = run_runner(package, env)

            self.assertEqual(completed.returncode, 2, completed.stdout)
            self.assertIn("CMUX_SWIFT_TEST_DIRECT", completed.stdout)
            self.assertFalse((temp / "swift-calls.txt").exists())


if __name__ == "__main__":
    unittest.main()
