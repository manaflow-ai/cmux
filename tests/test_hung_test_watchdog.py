#!/usr/bin/env python3
"""Regression tests for scripts/ci/hung_test_watchdog.py."""

from __future__ import annotations

import importlib.util
import os
import pathlib
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "hung_test_watchdog.py"

spec = importlib.util.spec_from_file_location("hung_test_watchdog", SCRIPT)
watchdog = importlib.util.module_from_spec(spec)
assert spec.loader is not None
# dataclasses resolves annotations through sys.modules.
sys.modules[spec.name] = watchdog
spec.loader.exec_module(watchdog)


def progress_after(output: str) -> "watchdog.InFlight":
    progress = watchdog.TestProgress(clock=lambda: 0.0)
    for line in textwrap.dedent(output).strip("\n").splitlines():
        progress.feed(line)
    return progress.in_flight()


def names(items: list) -> list[str]:
    return [item.name for item in items]


class TestProgressParserTests(unittest.TestCase):
    def test_finished_tests_leave_nothing_in_flight(self) -> None:
        state = progress_after("""
            ◇ Test run started.
            ↳ Testing Library Version: 1902
            ◇ Suite MobileShellAltScreenNoticeTests started.
            ◇ Test firstPasses() started.
            ✔ Test firstPasses() passed after 0.004 seconds.
            ◇ Test secondFails() started.
            ✘ Test secondFails() recorded an issue at A.swift:9:5: Expectation failed: 1 == 2
            ✘ Test secondFails() failed after 0.010 seconds with 1 issue.
            ◇ Test knownIssue() started.
            ✔ Test knownIssue() passed after 0.002 seconds with 1 known issue.
            ✘ Suite MobileShellAltScreenNoticeTests failed after 0.020 seconds with 1 issue.
            ✘ Test run with 3 tests in 1 suite failed after 0.021 seconds with 1 issue.
        """)
        self.assertEqual(state.tests, [])
        self.assertEqual(state.suites, [])

    def test_unfinished_test_and_its_suite_are_reported(self) -> None:
        state = progress_after("""
            ◇ Suite MobileShellAltScreenNoticeTests started.
            ◇ Test alternateScreenNotifies() started.
            ✔ Test alternateScreenNotifies() passed after 0.004 seconds.
            ◇ Test sameActiveScreenRenderGridDoesNotNotifyAlternateScreenObservers() started.
        """)
        self.assertEqual(
            names(state.tests),
            ["sameActiveScreenRenderGridDoesNotNotifyAlternateScreenObservers()"],
        )
        self.assertEqual(names(state.suites), ["MobileShellAltScreenNoticeTests"])
        self.assertEqual(
            watchdog.hung_summary(state),
            "while running sameActiveScreenRenderGridDoesNotNotifyAlternateScreenObservers() "
            "(suite MobileShellAltScreenNoticeTests)",
        )

    def test_parameterized_test_cases_are_not_misread_as_hung_tests(self) -> None:
        state = progress_after("""
            ◇ Test rejectsPeerAddresses(_:) started.
            ◇ Test case passing 1 argument addresses → ["100.71.210.41", "203.0.113.10"] to rejectsPeerAddresses(_:) started.
            ◇ Test case passing 1 argument addresses → ["not-an-address"] to rejectsPeerAddresses(_:) started.
            ✔ Test rejectsPeerAddresses(_:) with 2 test cases passed after 0.146 seconds.
            ◇ Test decodes(url:kind:) started.
            ◇ Test case passing 2 arguments url → "a", kind → .b to decodes(url:kind:) started.
            ✘ Test decodes(url:kind:) recorded an issue with 2 arguments url → "a", kind → .b at D.swift:3:1: Expectation failed
            ✘ Test decodes(url:kind:) with 1 test case failed after 0.010 seconds with 1 issue.
        """)
        self.assertEqual(state.tests, [])

    def test_unfinished_parameterized_test_names_its_last_case(self) -> None:
        # The argument value itself contains " to ", which a split on the last
        # " to " would take as the test name.
        state = progress_after("""
            ◇ Test maps(input:) started.
            ◇ Test case passing 1 argument input → "a to b" to maps(input:) started.
            ◇ Test case passing 1 argument input → "c to maps(input:)" to maps(input:) started.
        """)
        self.assertEqual(names(state.tests), ["maps(input:)"])
        self.assertEqual(state.tests[0].cases_started, 2)
        self.assertEqual(
            state.tests[0].last_case,
            'passing 1 argument input → "c to maps(input:)"',
        )
        report = "\n".join(watchdog.format_report(state, 0.0))
        self.assertIn("last of 2 started case(s)", report)
        self.assertNotIn("case passing", watchdog.hung_summary(state))

    def test_display_names_and_skips(self) -> None:
        state = progress_after("""
            ◇ Test "multiple binary-only changes use the plural file count" started.
            ✔ Test "multiple binary-only changes use the plural file count" passed after 0.005 seconds.
            ➜ Test exportUsesJapaneseCatalogCopy() skipped: "Command-line SwiftPM copies string catalogs"
            ➜ Test plainSkip() skipped.
            ◇ Test "waits for a reply" started.
        """)
        self.assertEqual(names(state.tests), ['"waits for a reply"'])

    def test_issue_text_that_looks_like_a_finish_does_not_close_the_test(self) -> None:
        state = progress_after("""
            ◇ Test pollsUntilReady() started.
            ✘ Test pollsUntilReady() recorded an issue at P.swift:1:1: Issue: step passed after 3 seconds.
        """)
        self.assertEqual(names(state.tests), ["pollsUntilReady()"])

    def test_same_name_in_two_suites_is_counted_per_start(self) -> None:
        state = progress_after("""
            ◇ Test roundTrips() started.
            ◇ Test roundTrips() started.
            ✔ Test roundTrips() passed after 0.001 seconds.
        """)
        self.assertEqual(names(state.tests), ["roundTrips()"])
        self.assertEqual(state.tests[0].line, 2)

    def test_ansi_colored_output_is_parsed(self) -> None:
        state = progress_after(
            "\x1b[1;90m◇\x1b[0m Test \x1b[1mcolored()\x1b[0m started.\r\n"
            "\x1b[1;90m◇\x1b[0m Test stuck() started.\n"
            "\x1b[1;32m✔\x1b[0m Test \x1b[1mcolored()\x1b[0m passed after 0.001 seconds.\n"
        )
        self.assertEqual(names(state.tests), ["stuck()"])

    def test_xctest_current_case_on_darwin_and_linux(self) -> None:
        state = progress_after("""
            Test Suite 'All tests' started at 2026-09-23 14:54:55.001.
            Test Case '-[BonsplitTests.BonsplitTests testClips]' started.
            Test Case '-[BonsplitTests.BonsplitTests testClips]' passed (0.002 seconds).
            Test Case '-[BonsplitTests.BonsplitTests testSkips]' started.
            Test Case '-[BonsplitTests.BonsplitTests testSkips]' skipped (0.001 seconds).
            Test Case 'LinuxTests.testWaits' started at 2026-09-23 14:54:55.100
            Test Case '-[BonsplitTests.BonsplitTests testHangs]' started.
            Test Case 'LinuxTests.testWaits' failed (0.5 seconds)
        """)
        self.assertEqual(names(state.xctest_cases), ["-[BonsplitTests.BonsplitTests testHangs]"])
        self.assertEqual(
            watchdog.hung_summary(state),
            "while running -[BonsplitTests.BonsplitTests testHangs]",
        )

    def test_nothing_in_flight_names_the_last_output(self) -> None:
        state = progress_after("""
            [882/884] Compiling CmuxMobileShell Shell.swift
        """)
        self.assertEqual(
            watchdog.hung_summary(state),
            "no test was in flight; last output: [882/884] Compiling CmuxMobileShell Shell.swift",
        )

    def test_summary_bounds_the_named_tests(self) -> None:
        state = progress_after("\n".join(f"◇ Test t{index}() started." for index in range(8)))
        self.assertEqual(
            watchdog.hung_summary(state),
            "while running t0(), t1(), t2(), t3(), t4() and 3 more",
        )

    def test_annotation_escaping(self) -> None:
        self.assertEqual(watchdog.escape_annotation("a%b\nc\r"), "a%25b%0Ac%0D")
        self.assertEqual(watchdog.escape_property("Hung: a,b"), "Hung%3A a%2Cb")


def fake_test_command(body: str) -> list[str]:
    return [sys.executable, "-u", "-c", textwrap.dedent(body)]


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_exit(pid: int, seconds: float = 5.0) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.05)
    return False


class WatchdogProcessTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.temp = pathlib.Path(self._temp.name)
        self.env = os.environ.copy()
        # A fake `sample` stands in for the macOS tool; tests that expect no
        # sampling hide any real one behind an empty PATH entry first.
        self.env["PATH"] = f"{self.temp}:{self.env['PATH']}"

    def tearDown(self) -> None:
        self._temp.cleanup()

    def watchdog(
        self, *args: str, command: list[str], deadline: float = 30.0
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args, "--", *command],
            cwd=ROOT,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=deadline,
        )

    def install_fake_sample(self) -> pathlib.Path:
        calls = self.temp / "sample-calls.txt"
        fake = self.temp / "sample"
        fake.write_text(
            "#!/bin/sh\n"
            f"echo \"$@\" >> '{calls}'\n"
            "while [ $# -gt 0 ]; do\n"
            "  if [ \"$1\" = -file ]; then shift; echo \"FAKE STACK REPORT\" > \"$1\"; fi\n"
            "  shift\n"
            "done\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)
        return calls

    def test_silence_names_the_hung_test_kills_it_and_fails(self) -> None:
        pid_file = self.temp / "child.pid"
        calls = self.install_fake_sample()
        completed = self.watchdog(
            "--silence-seconds", "1",
            "--label", "CmuxMobileShell",
            command=fake_test_command(f"""
                import os, signal
                open({str(pid_file)!r}, "w").write(str(os.getpid()))
                print("◇ Suite MobileShellAltScreenNoticeTests started.")
                print("◇ Test passes() started.")
                print("✔ Test passes() passed after 0.001 seconds.")
                print("◇ Test sameActiveScreenRenderGridDoesNotNotifyAlternateScreenObservers() started.")
                signal.pause()
            """),
        )
        self.assertEqual(completed.returncode, 124, completed.stdout)
        self.assertIn(
            "::error title=Hung test in CmuxMobileShell::CmuxMobileShell timed out after 1s "
            "with no output, while running "
            "sameActiveScreenRenderGridDoesNotNotifyAlternateScreenObservers() "
            "(suite MobileShellAltScreenNoticeTests)",
            completed.stdout,
        )
        self.assertIn("Swift Testing tests started but not finished (1):", completed.stdout)
        self.assertNotIn("  passes()", completed.stdout)
        # The fake sampler found a process in the command's group.
        self.assertIn("FAKE STACK REPORT", completed.stdout)
        self.assertRegex(calls.read_text(encoding="utf-8"), r"^\d+ 3 -file ")
        self.assertTrue(wait_for_exit(int(pid_file.read_text())), "hung child survived")
        # "timed out" appears once, so log greps count one per stalled attempt.
        self.assertEqual(completed.stdout.count("timed out"), 1, completed.stdout)

    def test_block_buffered_test_output_still_names_the_running_test(self) -> None:
        # No `-u` and no flush: through a pipe this Python child block-buffers
        # stdout, as the Swift Testing helper does, and the stall would leave
        # the report naming nothing (or a test that already finished). On the
        # watchdog's pseudo-terminal it is line-buffered.
        completed = self.watchdog(
            "--silence-seconds", "1",
            "--sample-seconds", "0",
            command=[sys.executable, "-c", textwrap.dedent("""
                import os, signal
                print(f"stdout is a tty: {os.isatty(1)}")
                print("◇ Test alreadyPassed() started.")
                print("✔ Test alreadyPassed() passed after 0.001 seconds.")
                print("◇ Test presenceRoutesForHiddenDuplicateRefreshOnlyTheEmittingRow() started.")
                signal.pause()
            """)],
        )
        self.assertEqual(completed.returncode, 124, completed.stdout)
        self.assertIn("stdout is a tty: True", completed.stdout)
        self.assertIn(
            "while running presenceRoutesForHiddenDuplicateRefreshOnlyTheEmittingRow()",
            completed.stdout,
        )
        self.assertNotIn("\r\n", completed.stdout)

    def test_terminal_defaults_keep_output_line_oriented_unless_set(self) -> None:
        probe = fake_test_command("""
            import os
            print(os.environ.get("TERM"), os.environ.get("NO_COLOR"))
        """)
        self.env.pop("TERM", None)
        self.env.pop("NO_COLOR", None)
        defaulted = self.watchdog("--silence-seconds", "5", command=probe)
        self.assertEqual(defaulted.stdout, "dumb 1\n")
        self.env["TERM"] = "xterm-256color"
        self.env["NO_COLOR"] = ""
        kept = self.watchdog("--silence-seconds", "5", command=probe)
        self.assertEqual(kept.stdout, "xterm-256color \n")

    def test_test_helper_in_its_own_process_group_is_sampled_and_killed(self) -> None:
        # SwiftPM starts swiftpm-testing-helper in a new process group, so
        # killpg on the command alone leaves the hung helper running.
        helper_pid = self.temp / "helper.pid"
        helper = self.temp / "swiftpm-testing-helper"
        # A real binary under the helper's name. A shebang script shows up as
        # its interpreter on macOS, and a copied system binary fails its code
        # signature there; a symlink keeps the invoked name on both systems.
        os.symlink(shutil.which("sleep"), helper)
        calls = self.install_fake_sample()
        completed = self.watchdog(
            "--silence-seconds", "1",
            command=fake_test_command(f"""
                import signal, subprocess
                child = subprocess.Popen([{str(helper)!r}, "600"], start_new_session=True)
                open({str(helper_pid)!r}, "w").write(str(child.pid))
                print("◇ Test stuck() started.")
                signal.pause()
            """),
        )
        self.assertEqual(completed.returncode, 124, completed.stdout)
        pid = int(helper_pid.read_text())
        # The helper matched the test-process pattern, so only it was sampled.
        self.assertEqual(calls.read_text(encoding="utf-8").split()[0], str(pid))
        self.assertTrue(wait_for_exit(pid), "helper outside the process group survived")

    def test_steady_output_slower_than_the_window_in_total_passes(self) -> None:
        completed = self.watchdog(
            "--silence-seconds", "3",
            command=fake_test_command("""
                import time
                for index in range(8):
                    print(f"◇ Test t{index}() started.")
                    time.sleep(0.5)
                    print(f"✔ Test t{index}() passed after 0.5 seconds.")
            """),
        )
        # Eight 0.5 s tests span more than the 3 s window, yet all finish. The
        # window starts at spawn, so it also absorbs interpreter startup on a
        # loaded host.
        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertEqual(completed.stdout.count(" passed after 0.5 seconds."), 8)
        self.assertNotIn("::error", completed.stdout)

    def test_exit_status_and_output_pass_through_and_log_is_written(self) -> None:
        log = self.temp / "nested" / "tests.log"
        completed = self.watchdog(
            "--silence-seconds", "5",
            "--log", str(log),
            command=fake_test_command("""
                import sys
                print("Test run with 1 test passed after 0.001 seconds.")
                print("partial line without newline", end="")
                sys.stderr.write("\\nstderr line\\n")
                raise SystemExit(3)
            """),
        )
        self.assertEqual(completed.returncode, 3, completed.stdout)
        expected = (
            "Test run with 1 test passed after 0.001 seconds.\n"
            "partial line without newline\nstderr line\n"
        )
        self.assertEqual(completed.stdout, expected)
        self.assertEqual(log.read_text(encoding="utf-8"), expected)

    def test_signal_death_maps_to_shell_status(self) -> None:
        completed = self.watchdog(
            "--silence-seconds", "5",
            command=fake_test_command("""
                import os, signal
                # SIGUSR1 terminates without a core dump, which could take
                # longer than the silence window on a loaded host.
                os.kill(os.getpid(), signal.SIGUSR1)
            """),
        )
        self.assertEqual(completed.returncode, 128 + signal.SIGUSR1, completed.stdout)

    def test_total_timeout_fires_on_a_chatty_command(self) -> None:
        completed = self.watchdog(
            "--timeout-seconds", "1",
            "--sample-seconds", "0",
            "--label", "ExampleSuite",
            command=fake_test_command("""
                import time
                print("Test Case '-[Example.Tests testLoops]' started.")
                while True:
                    print("still working")
                    time.sleep(0.1)
            """),
        )
        self.assertEqual(completed.returncode, 124, completed.stdout[-2000:])
        self.assertEqual(completed.stdout.count("timed out after 1s"), 1)
        self.assertIn(
            "ExampleSuite timed out after 1s, while running -[Example.Tests testLoops]",
            completed.stdout,
        )

    def test_missing_sampler_is_reported_not_fatal(self) -> None:
        self.env["PATH"] = os.pathsep.join(
            entry for entry in self.env["PATH"].split(os.pathsep)
            if not (pathlib.Path(entry) / "sample").exists()
        )
        completed = self.watchdog(
            "--silence-seconds", "0.5",
            command=fake_test_command("""
                import signal
                print("◇ Test stuck() started.")
                signal.pause()
            """),
        )
        self.assertEqual(completed.returncode, 124, completed.stdout)
        self.assertIn("Stack sampling skipped", completed.stdout)
        self.assertIn("while running stuck()", completed.stdout)

    def test_detached_descendant_holding_the_pipe_does_not_extend_the_run(self) -> None:
        completed = self.watchdog(
            "--silence-seconds", "20",
            command=["/bin/sh", "-c", "sleep 30 & echo 'Test run with 1 test passed after 0.1 seconds.'"],
            # The descendant outlives this deadline; returning before it is the point.
            deadline=10,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout)

    def test_runner_cancellation_names_the_running_test(self) -> None:
        pid_file = self.temp / "child.pid"
        process = subprocess.Popen(
            [
                sys.executable, str(SCRIPT),
                "--silence-seconds", "60",
                "--label", "CmuxMobileShell",
                "--",
                *fake_test_command(f"""
                    import os, signal
                    open({str(pid_file)!r}, "w").write(str(os.getpid()))
                    print("◇ Test waitsForever() started.", flush=True)
                    signal.pause()
                """),
            ],
            cwd=ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        try:
            # Without a deadline, a watchdog that forwards nothing would block
            # this read until the job timeout.
            readable, _, _ = select.select([process.stdout], [], [], 20)
            self.assertTrue(readable, "watchdog forwarded no output within 20 s")
            first = process.stdout.readline()
            self.assertIn("waitsForever() started", first)
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=20)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        self.assertEqual(process.returncode, 128 + signal.SIGTERM, output)
        self.assertIn(
            "::error title=Cancelled test in CmuxMobileShell::CmuxMobileShell was stopped by "
            "SIGTERM (job cancelled or job timeout reached), while running waitsForever()",
            output,
        )
        self.assertTrue(wait_for_exit(int(pid_file.read_text())), "child survived cancellation")

    def test_requires_a_bound(self) -> None:
        completed = self.watchdog(command=["true"])
        self.assertEqual(completed.returncode, 2)
        self.assertIn("set --silence-seconds, --timeout-seconds, or both", completed.stderr)


if __name__ == "__main__":
    unittest.main()
