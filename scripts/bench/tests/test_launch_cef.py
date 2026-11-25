"""launch-ready-cef.py: the app's `CEF ready` log line becomes Chromium's start marks, in ms from process start."""
from __future__ import annotations

import datetime
import importlib.util
import json
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "measure" / "launch-ready-cef.py"
spec = importlib.util.spec_from_file_location("launch_ready_cef", SCRIPT)
cef = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cef)


def event(message: str, at: datetime.datetime) -> str:
    return json.dumps({"timestamp": at.strftime("%Y-%m-%d %H:%M:%S.%f%z"), "eventMessage": message, "processID": 42})


class CefMarks(unittest.TestCase):
    start = datetime.datetime(2026, 11, 18, 4, 30, 0, tzinfo=datetime.timezone(datetime.timedelta(hours=-8)))

    def row(self) -> dict:
        return {"pid": 42, "start_epoch_ms": self.start.timestamp() * 1000, "marks": {"first_window_frame_committed": 1200.0}}

    def test_ready_line(self) -> None:
        at = self.start + datetime.timedelta(milliseconds=4500)
        text = "\n".join([
            "Filtering the log data using ...",
            event("keychain item: none", self.start + datetime.timedelta(milliseconds=4000)),
            event("CEF ready trigger=launch shim_abi=ab12 fork_api=7 load=0.412 seconds map=0.31 seconds "
                  "initialize=0.0912 seconds", at),
            event("CEF ready trigger=tab load=1 seconds initialize=1 seconds", at + datetime.timedelta(seconds=1)),
        ])
        row = cef.add_marks(self.row(), text)
        self.assertTrue(row["cef_started"])
        self.assertEqual(row["cef_trigger"], "launch")
        marks = row["marks"]
        self.assertAlmostEqual(marks["cef.ready"], 4500.0, places=1)
        self.assertAlmostEqual(marks["cef.initialize_dur"], 91.2, places=1)
        self.assertAlmostEqual(marks["cef.initialize_start"], 4408.8, places=1)
        self.assertAlmostEqual(marks["cef.load_dur"], 412.0, places=1)
        self.assertAlmostEqual(marks["cef.map_dur"], 310.0, places=1)
        self.assertEqual(marks["first_window_frame_committed"], 1200.0)

    def test_no_ready_line(self) -> None:
        row = cef.add_marks(self.row(), event("keychain item: none", self.start))
        self.assertFalse(row["cef_started"])
        self.assertEqual(set(row["marks"]), {"first_window_frame_committed"})


if __name__ == "__main__":
    unittest.main()
