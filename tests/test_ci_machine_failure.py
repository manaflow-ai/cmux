"""Runs the Mac failed before any test started, told apart from test failures (no network)."""

import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import machine_failure  # noqa: E402

PREFIX = "build\tRun selected tests\t2026-09-27T10:45:36.8153730Z "
# Excerpts of run 36313045972's failed log: the step's script listing, then
# what the runner printed.
AUTOMATION_MODE = "\n".join([
    PREFIX + "\x1b[36;1m    echo \"::error::No logged-in GUI user is available for screen recording\"\x1b[0m",
    PREFIX + "##[warning]Could not enable Automation Mode",
    PREFIX + "cmuxUITests-Runner[39090:1308789] [Default] Failed to initialize for UI testing: "
    "Error Domain=com.apple.dt.XCTest.XCTFuture Code=1000 \"Timed out while enabling automation mode.\"",
    PREFIX + "** TEST EXECUTE FAILED **",
])


class MachineFailureTests(unittest.TestCase):
    def test_a_runner_that_never_initialized_is_a_machine_failure(self):
        self.assertIn("Automation Mode", machine_failure.reason(AUTOMATION_MODE))

    def test_a_started_test_makes_it_the_codes_failure(self):
        for started in (
            "Test Case '-[cmuxUITests.SidebarTests testA]' started.",
            "◇ Test testA() started.",
            "◇ Test \"Sidebar opens\" started.",
            "Test case '-[cmuxUITests.SidebarTests testA]' started.",
        ):
            with self.subTest(started=started):
                self.assertIsNone(machine_failure.reason(AUTOMATION_MODE + "\n" + PREFIX + started))

    def test_an_app_crash_at_launch_is_the_codes_failure(self):
        crash = PREFIX + (
            "cmux (4242) encountered an error (Early unexpected exit, operation never finished "
            "bootstrapping - no restart will be attempted. (Underlying Error: Test crashed with "
            "signal abrt before starting test execution.))"
        )
        self.assertIsNone(machine_failure.reason(crash))

    def test_messages_quoted_in_the_script_listing_do_not_count(self):
        listing = PREFIX + "\x1b[36;1m  echo \"::error::screen frame capture failed to start\"\x1b[0m"
        self.assertIsNone(machine_failure.reason(listing))

    def test_an_ordinary_failure_is_not_a_machine_failure(self):
        self.assertIsNone(machine_failure.reason(PREFIX + "error: cannot find 'foo' in scope"))
        self.assertIsNone(machine_failure.reason(""))


if __name__ == "__main__":
    unittest.main()
