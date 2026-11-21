#!/usr/bin/env python3
"""scripts/ci/relaunch_restore_check.py reads where each quit went from the quitting app's own marks.

The app streams its quit's marks (quit.requested through quit.replied, QuitCoordinator) to the launch-marks pipe it
was started with. The check keeps that pipe open past the launch and, once the app is gone, reads what is left:
each `quit.*` mark in ms after quit.requested, so a slow quit names its stage (a round's quit_ms alone does not).
"""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import relaunch_restore_check as l5  # noqa: E402


class QuitMarks(unittest.TestCase):
    def test_quit_marks_are_relative_to_the_request_and_in_order(self) -> None:
        text = "\n".join([
            "reveal.pane 547.0",
            "quit.requested 90000.0",
            "quit.decided 90004.5",
            "quit.saved 90200.0",
            "quit.state_files 90210.0",
            "quit.decided 99999.0",  # a repeat keeps the first
            "quit.replied 91300.4",
            "garbage",
        ])
        self.assertEqual(l5.quit_marks(text), {"quit.requested": 0, "quit.decided": 4, "quit.saved": 200,
                                               "quit.state_files": 210, "quit.replied": 1300})

    def test_no_request_mark_gives_nothing(self) -> None:
        self.assertEqual(l5.quit_marks("quit.saved 10.0\n"), {})

    def test_an_ended_writers_pipe_is_read_to_its_end_and_closed(self) -> None:
        read, write = os.pipe()
        os.set_blocking(read, False)
        os.write(write, b"quit.requested 1.0\nquit.replied 2.0\n")
        os.close(write)
        self.assertEqual(l5.read_ended(read), "quit.requested 1.0\nquit.replied 2.0\n")
        with self.assertRaises(OSError):
            os.fstat(read)
        self.assertEqual(l5.read_ended(None), "")


if __name__ == "__main__":
    unittest.main()
