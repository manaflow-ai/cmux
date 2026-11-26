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

    def test_an_unwritable_homebrew_prefix_is_a_machine_failure(self):
        log = "##[error]The following directories are not writable by your user:\n  /opt/homebrew\n"
        self.assertEqual(machine_failure.reason(log), "the Mac's Homebrew prefix is not writable by the runner user")

    def test_a_missing_pinned_xcode_is_a_machine_failure(self):
        for line in (
            "##[error]Pinned Xcode developer dir does not exist: /Applications/Xcode_26.3.app/Contents/Developer "
            "on runner cmux14-glaeda-1. [cmux-ci machine: xcode-pin-missing] Installed: Xcode.app=26.3",
            "Pinned Xcode developer dir does not exist: /Applications/Xcode_26.3.app/Contents/Developer",
            "Pinned Xcode developer dir has no usable macOS SDK: /Applications/Xcode_26.3.app/Contents/Developer",
            "This macOS 26 runner has no Xcode 26.6, the version scripts/ci/xcode-pins.txt pins for its pool. "
            "Installed: Xcode.app=26.3",
        ):
            with self.subTest(line=line[:40]):
                self.assertEqual(machine_failure.reason(PREFIX + line), "the Mac does not have the Xcode the job pins")

    def test_a_package_brew_could_not_install_is_a_machine_failure(self):
        for line in (
            "##[error][cmux-ci machine: brew-provision] tmux is missing on cmux-austin-mini-1-glaeda-1: "
            "/opt/homebrew is owned by admin and passwordless sudo is unavailable to become them; "
            "provision tmux on that machine",
            "::error::[cmux-ci machine: brew-provision] ffmpeg is missing on this runner: "
            "there is no brew on PATH; provision ffmpeg on that machine",
        ):
            with self.subTest(line=line[:60]):
                self.assertEqual(
                    machine_failure.reason(PREFIX + line),
                    "the Mac is missing a package the tests need and Homebrew could not install it",
                )

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
