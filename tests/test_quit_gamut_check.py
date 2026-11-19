#!/usr/bin/env python3
"""scripts/ci/quit_gamut_check.py: a round that measured nothing never passes.

Step d9dc7a55 of the 2d0ebd4bf7e5 baseline had cold-cache, loaded and after-run rows with every number null and no
failure: `action.run quit` timed out before the app started it ("not_run", deadline 1999 ms), the app was still up
20 s later, and quit_app handed that back as "could not be asked", so each row was "not run" and left out of the
status. These check that such a quit is a failed quit, that any row with no first window, settled or prior-chat
number and no failure fails as "no measurement: <why>", and that the table and summary say so. No process is
started: the app's process is a fake with a fake pid, and os.kill / os.killpg raise if anything reaches them.
"""
from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import quit_gamut_check as gamut  # noqa: E402

FAKE_PID = 4_000_002
NOT_RUN = {"code": "timeout", "message": "action.run did not finish within 1999 ms",
           "data": {"deadline_ms": 1999, "method": "action.run", "not_run": True, "state": "not_run", "waiting_on": []}}


def refuse_signal(*args, **kwargs):
    raise AssertionError(f"a test reached a signal call: {args}")


class StuckProcess:
    """An app process that does not end when asked: wait() times out until kill()."""

    pid = FAKE_PID

    def __init__(self):
        self.killed = False

    def wait(self, timeout=None):
        if not self.killed:
            raise subprocess.TimeoutExpired("cmux", timeout)
        return -9

    def kill(self):
        self.killed = True

    def poll(self):
        return -9 if self.killed else None


class FakeApp:
    sock = "/nonexistent/s.sock"

    def __init__(self):
        self.process = StuckProcess()
        self.closed = False

    def close_marks(self):
        self.closed = True


class QuitTests(unittest.TestCase):
    def test_a_scripted_quit_the_app_never_started_and_never_ended_is_a_failed_quit(self):
        app = FakeApp()
        with mock.patch.object(gamut.l5, "call", return_value={"error": NOT_RUN}), \
                mock.patch.object(os, "kill", refuse_signal), mock.patch.object(os, "killpg", refuse_signal):
            for path in ("cold-cache", "loaded", "after-run", "scripted"):
                app.process = StuckProcess()
                with self.subTest(path=path), self.assertRaises(gamut.QuitFailed) as caught:
                    gamut.quit_app(app, path)
                self.assertIn("did not end within 20 s", str(caught.exception))
                self.assertIn("did not finish within 1999 ms", str(caught.exception))
                self.assertTrue(app.process.killed)
                self.assertTrue(app.closed)


class NoMeasurementTests(unittest.TestCase):
    def test_a_not_run_row_with_no_number_fails_and_says_why(self):
        row = {"path": "cold-cache", "state": "idle", "failures": [], "quit_ms": None,
               "not_run": "action.run quit: did not finish within 1999 ms"}
        gamut.judge_measured(row)
        self.assertEqual(row["failures"], ["no measurement: action.run quit: did not finish within 1999 ms"])

    def test_a_row_with_no_number_and_no_reason_still_fails(self):
        row = gamut.judge_measured({"path": "loaded", "state": "idle", "failures": []})
        self.assertEqual(row["failures"], ["no measurement: the round recorded no number"])

    def test_a_measured_or_failed_row_is_left_alone(self):
        measured = gamut.judge_measured({"path": "loaded", "state": "idle", "failures": [], "first_window_ms": 547})
        self.assertEqual(measured["failures"], [])
        failed = gamut.judge_measured({"path": "kill", "state": "idle", "failures": ["setup: x"]})
        self.assertEqual(failed["failures"], ["setup: x"])

    def test_the_table_says_no_for_a_not_run_row_and_marks_a_harness_failure(self):
        rows = [gamut.judge_measured({"path": "after-run", "state": "idle", "failures": [],
                                      "not_run": "action.run quit: [Errno 2] No such file or directory"}),
                {"path": "fresh-install", "state": "first-run", "failures": ["prompt could not be answered: x"],
                 "harness_failure": "prompt could not be answered: x", "prompt_route": None}]
        text = gamut.table(rows)
        self.assertIn("| after-run | idle | NO, not run |", text)
        self.assertIn("no measurement: action.run quit: [Errno 2]", text)
        self.assertIn("| fresh-install | first-run | NO (harness) |", text)


if __name__ == "__main__":
    unittest.main()
