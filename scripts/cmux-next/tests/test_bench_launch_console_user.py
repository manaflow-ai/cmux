#!/usr/bin/env python3
"""bench_launch.py's GUI-session gate names the account whose session is on the console, the way the fleet worker's
gate does (cmuxterm-hq build-fleet/cmd/worker console_session.go readConsoleUser, screen_share.go
consoleHolderFromIOReg): IOConsoleUsers' entry with kCGSSessionOnConsoleKey, not scutil's State:/Users/ConsoleUser.

2026-11-18: the hidden CI accounts cmuxci-gui-0N log in to each mini's own Screen Sharing (hq `fleet gui-ci-users`),
which gives each its own session off the console and sets scutil's ConsoleUser Name to it, while the build user's
session stays on the console. The worker moved to IOConsoleUsers that day; this gate still read scutil, so every GUI
bench on those minis refused with no-gui-session ("the console session belongs to cmuxci-gui-01, not cmux") after
its app build (perf cron step 4cb39eda6ae1 on cmux22, 2026-11-19).

Pure: the ioreg plist is a fixture. Runs anywhere.

    python3 -I scripts/cmux-next/tests/test_bench_launch_console_user.py
"""

from __future__ import annotations

import plistlib
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402


def session(name, on_console, login_done=True, locked=False):
    return {"kCGSSessionUserNameKey": name, "kCGSSessionOnConsoleKey": on_console, "kCGSessionLoginDoneKey": login_done,
            "CGSSessionScreenIsLocked": locked, "kCGSSessionUserIDKey": 501}


def ioreg(*sessions):
    return plistlib.dumps([{"IOConsoleUsers": list(sessions)}])


class ConsoleUserTests(unittest.TestCase):
    def read(self, plist):
        with mock.patch.object(bl.subprocess, "run", return_value=mock.Mock(stdout=plist, returncode=0)) as run:
            user = bl.console_user()
        self.assertEqual(run.call_args.args[0][0], "/usr/sbin/ioreg", "the holder comes from IOConsoleUsers")
        return user

    def test_a_screen_sharing_session_off_the_console_is_not_the_console_user(self):
        plist = ioreg(session("cmuxci-gui-01", False), session("cmux", True))
        self.assertEqual(self.read(plist), "cmux")

    def test_the_console_holder_is_the_entry_on_the_console(self):
        self.assertEqual(self.read(ioreg(session("cmux", True))), "cmux")
        self.assertEqual(self.read(ioreg(session("cmux", False), session("other", True))), "other")

    def test_nobody_on_the_console_or_no_answer_is_nobody(self):
        self.assertIsNone(self.read(ioreg(session("cmux", False))), "only background sessions: the login window")
        self.assertIsNone(self.read(ioreg()), "no console user at all")
        self.assertIsNone(self.read(ioreg(session("cmux", True, login_done=False))), "a login still in progress")
        self.assertIsNone(self.read(b"not a plist"), "an unreadable answer fails closed")
        self.assertIsNone(self.read(ioreg(session("loginwindow", True))))

    def test_ioreg_that_does_not_run_is_nobody(self):
        with mock.patch.object(bl.subprocess, "run", side_effect=OSError("no ioreg")):
            self.assertIsNone(bl.console_user())


if __name__ == "__main__":
    unittest.main()
