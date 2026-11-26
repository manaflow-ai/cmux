#!/usr/bin/env python3
"""One console-user rule everywhere: the account of IOConsoleUsers' session on the console, never scutil's ConsoleUser.

The rule lives in three places that must change together: the fleet worker's gate (cmuxterm-hq build-fleet
console_session.go readConsoleUser), bench_launch.py console_user() and the app's open-panel warm-up
(CmuxNextDesign OpenPanelWarmGate). On 2026-11-18 the fleet's hidden CI accounts (cmuxci-gui-0N) began logging in to
each mini's own Screen Sharing, each into a session of its own off the console. That sets scutil's
State:/Users/ConsoleUser Name to the last of them while the build user's session stays on the console. The worker
moved to IOConsoleUsers that day and kept sending GUI steps to those minis, but bench_launch.py still read scutil and
refused every one with no-gui-session ("the console session belongs to cmuxci-gui-01, not cmux"), and the app's
warm-up turned itself off there. This test is the detector for that class: no code reads scutil's ConsoleUser or
SCDynamicStoreCopyConsoleUser, and a shell script that needs the console user asks bench_launch.py (`console-user`)
instead of keeping a copy of the rule.

Pure apart from `git grep` over this checkout. Runs anywhere:

    python3 -m unittest discover -s scripts/cmux-next/tests -p 'test_console_holder_rule.py'
"""

from __future__ import annotations

import contextlib
import io
import plistlib
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402

# Code that reads the console user the old way: scutil's ConsoleUser key (as its input line) or the SCDynamicStore
# call. A comment naming the key ("not scutil's State:/Users/ConsoleUser") is not a read and does not match.
OLD_READS = r'show State:/Users/ConsoleUser|SCDynamicStoreCopyConsoleUser\('
CODE = ["*.py", "*.sh", "*.swift", "*.rs", "*.go", "*.m", "*.mm", "*.c", "*.ts", "*.js", "*.yml", "*.yaml"]


class NoOldConsoleUserReadTests(unittest.TestCase):
    def test_no_code_reads_scutils_console_user(self):
        found = subprocess.run(["git", "-C", str(ROOT), "grep", "-n", "-E", OLD_READS, "--", *CODE,
                                ":!scripts/cmux-next/tests/test_console_holder_rule.py"],
                               capture_output=True, text=True)
        self.assertIn(found.returncode, (0, 1), found.stderr)
        self.assertEqual(found.stdout, "",
                         "these read scutil's ConsoleUser, which a Screen Sharing login to another account takes "
                         "over; read IOConsoleUsers' session on the console (bench_launch.console_user, "
                         "OpenPanelWarmGate.consoleHolderUID):\n" + found.stdout)

    def test_the_console_session_hop_asks_bench_launch(self):
        script = (ROOT / "scripts/ci/frame-pacing/console-session.sh").read_text()
        self.assertNotIn("/dev/console", script,
                         "console-session.sh picks the account to hop into: /dev/console's owner is not the session "
                         "on the console")
        self.assertIn("bench_launch.py\" console-user", script)


class ConsoleUserCommandTests(unittest.TestCase):
    def run_command(self, sessions):
        plist = plistlib.dumps([{"IOConsoleUsers": sessions}])
        out = io.StringIO()
        with mock.patch.object(bl.subprocess, "run", return_value=mock.Mock(stdout=plist, returncode=0)), \
                contextlib.redirect_stdout(out):
            code = bl.main(["console-user"])
        return code, out.getvalue()

    def test_prints_the_account_on_the_console_not_a_screen_sharing_one(self):
        code, out = self.run_command([
            {"kCGSSessionUserNameKey": "cmuxci-gui-01", "kCGSSessionOnConsoleKey": False, "kCGSessionLoginDoneKey": True},
            {"kCGSSessionUserNameKey": "cmux", "kCGSSessionOnConsoleKey": True, "kCGSessionLoginDoneKey": True},
        ])
        self.assertEqual((code or 0, out), (0, "cmux\n"))

    def test_prints_nothing_when_nobody_is_on_the_console(self):
        code, out = self.run_command([
            {"kCGSSessionUserNameKey": "cmuxci-gui-01", "kCGSSessionOnConsoleKey": False, "kCGSessionLoginDoneKey": True},
        ])
        self.assertEqual((code or 0, out), (0, ""))


if __name__ == "__main__":
    unittest.main()
