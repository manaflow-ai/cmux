#!/usr/bin/env python3
"""bench_launch's GUI-session preflight reads the console user the way the hq worker that grants gui-session-v1 does:
the IOConsoleUsers session with kCGSSessionOnConsoleKey, not scutil's last-login Name.

Portable (Linux and macOS): every console read is a fake subprocess.run, so it runs where CI's Python runs.

    python3 -I scripts/cmux-next/tests/test_bench_launch_console.py
"""
from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bench_launch as bl  # noqa: E402


def ioreg_root(*sessions):
    """`ioreg -n Root -d1 -a` output whose IOConsoleUsers are `sessions` (name, on_console, locked)."""
    import plistlib
    return plistlib.dumps([{"IOConsoleUsers": [
        {"kCGSSessionUserNameKey": name, "kCGSSessionOnConsoleKey": on, "kCGSessionLoginDoneKey": True,
         "CGSSessionScreenIsLocked": locked} for name, on, locked in sessions]}])


def fake_console_reads(ioreg_out, scutil_name):
    """subprocess.run for the console reads: ioreg answers `ioreg_out` (None: it fails), scutil names `scutil_name`."""
    def run(argv, *args, **kwargs):
        if argv[0].endswith("ioreg"):
            if ioreg_out is None:
                raise OSError("no ioreg")
            return subprocess.CompletedProcess(argv, 0, stdout=ioreg_out, stderr=b"")
        if argv[0].endswith("scutil"):
            return subprocess.CompletedProcess(argv, 0, stdout=f"<dictionary> {{\n  Name : {scutil_name}\n}}\n", stderr="")
        raise AssertionError(f"unexpected command {argv}")
    return run


class ConsoleUserTests(unittest.TestCase):
    """The console user is the session WindowServer has on the console (IOConsoleUsers kCGSSessionOnConsoleKey), the
    same read as the hq worker that grants gui-session-v1 (build-fleet console_session.go readConsoleUser, hq#13240).
    Not scutil's State:/Users/ConsoleUser Name: that is the last account to log in. 2026-11-19, step 8c947a3b on
    cmux9s: the hidden Screen Sharing account cmuxci-gui-03 was the last login while cmux held the console; the worker
    started the step in cmux's session, and split-spring refused it as no-gui-session after a 20 min build."""

    HIDDEN_CI_SESSIONS = (("cmuxci-gui-01", False, False), ("cmux", True, False), ("cmuxci-gui-03", False, False))

    def test_hidden_screen_sharing_logins_do_not_take_the_console_from_the_on_console_session(self):
        with mock.patch.object(bl.subprocess, "run", fake_console_reads(ioreg_root(*self.HIDDEN_CI_SESSIONS), "cmuxci-gui-03")):
            self.assertEqual(bl.console_user(), "cmux")

    def test_the_on_console_sessions_lock_is_the_one_reported(self):
        sessions = (("cmuxci-gui-03", False, True), ("cmux", True, False))
        with mock.patch.object(bl.subprocess, "run", fake_console_reads(ioreg_root(*sessions), "cmuxci-gui-03")):
            self.assertIs(bl.screen_locked("cmux"), False)

    def test_no_session_on_the_console_or_no_answer_is_nobody(self):
        for out in (ioreg_root(("cmuxci-gui-03", False, False)), ioreg_root(), b"not a plist", None):
            with mock.patch.object(bl.subprocess, "run", fake_console_reads(out, "cmux")):
                self.assertIsNone(bl.console_user(), f"ioreg {out!r} named a console user")



if __name__ == "__main__":
    unittest.main()
