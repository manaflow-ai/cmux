#!/usr/bin/env python3
"""The launch's startup stages (startup-tti) are one table in three places: the app's rows of launch-times.jsonl
(LaunchStages in LaunchTimesFile.swift), scripts/ci/launch_stages.py and scripts/measure/launch-ready.swift. These
tests keep the three equal and check the Python spans.

Leo, 2026-11-21: "you can build instrumentation if you havent already to properly measure each part of startup times."
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import launch_stages  # noqa: E402

APP = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextControl/Diagnostics/LaunchTimesFile.swift"
HARNESS = ROOT / "scripts/measure/launch-ready.swift"


def swift_table(path: Path, opener: str) -> tuple:
    """The (stage, marks) rows of the Swift array literal that starts at `opener`."""
    text = path.read_text()
    start = text.index(opener)
    body = text[start:re.compile(r"\n\s*\]\n").search(text, start).start()]
    rows = re.findall(r'\(\s*"([^"]+)"\s*,\s*\[([^\]]*)\]\s*\)', body)
    return tuple((stage, tuple(re.findall(r'"([^"]+)"', marks))) for stage, marks in rows)


class SameTableTests(unittest.TestCase):
    def test_the_app_and_python_tables_are_equal(self):
        self.assertEqual(launch_stages.TABLE, swift_table(APP, "public static let table"))

    def test_the_launch_ready_and_python_tables_are_equal(self):
        self.assertEqual(launch_stages.TABLE, swift_table(HARNESS, "let launchStages"))


class SpansTests(unittest.TestCase):
    MARKS = {
        "main_start": 41.25, "did_finish_launching_start": 120.5, "daemon_connected": 180, "dfl.windows": 300,
        "launch_snapshot_shown": 260.04, "first_window_frame_committed": 512.04, "cef.ready": 700,
        "home.first_page": 830.66, "agent_pane.painted": 790, "window_usable": 900, "terminal_echo": 640,
    }

    def test_each_stage_is_the_earliest_of_its_marks(self):
        self.assertEqual({
            "premain": 41.2, "did_finish_launching": 120.5, "daemon_connected": 180, "first_window_shown": 260.0,
            "first_frame": 512.0, "webview_ready": 700, "first_chat_paint": 790, "first_interaction": 640,
        }, launch_stages.spans(self.MARKS))

    def test_a_stage_no_mark_reached_is_absent_and_bad_marks_are_skipped(self):
        self.assertEqual({"premain": 40}, launch_stages.spans({"main_start": 40, "cef.ready": -1,
                                                              "window_usable": float("nan"), "dfl.windows": "x"}))

    def test_medians_take_each_stage_over_the_rows_that_reached_it(self):
        rows = [{"premain": 40, "first_frame": 500}, {"premain": 60}, {"premain": 50, "first_frame": 700}, None]
        self.assertEqual({"premain": 50, "first_frame": 600}, launch_stages.medians(rows))


if __name__ == "__main__":
    unittest.main()
