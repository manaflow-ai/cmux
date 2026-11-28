"""update_launch_budget.py: the Update flow area's 2 s launch budget reads the update arm, and fails open."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "bench" / "update_launch_budget.py"
sys.path.insert(0, str(SCRIPT.parent))
import update_launch_budget as U  # noqa: E402


def row(frame=600.0, home=900.0, chromium_exit=0, rendered=1.2, exit_=None, arm=U.ARM):
    return {"arm": arm, "before": {"main_start_at": 30.0, "chromium_exit": chromium_exit}, "rendered_at": rendered,
            "exit": exit_, "marks": {"first_window_frame_committed": frame, "home.first_page": home}}


class ReadingTest(unittest.TestCase):
    def test_median_of_rounds_by_app_marks(self):
        ms, _ = U.reading({"launches": [row(home=900.0), row(home=1500.0), row(home=2600.0)]})
        self.assertEqual(ms, 1500.0)

    def test_failed_prewarm_round_is_left_out(self):
        ms, detail = U.reading({"launches": [row(home=800.0), row(home=9000.0, chromium_exit=1)]})
        self.assertEqual((ms, detail), (800.0, "1 of 2 rounds"))

    def test_other_arms_and_no_marks_are_no_reading(self):
        self.assertIsNone(U.reading({"launches": [row(arm="fresh-copy")]})[0])
        self.assertIsNone(U.reading({"launches": [row(rendered=None)]})[0])


class CommandTest(unittest.TestCase):
    def run_report(self, report: dict) -> subprocess.CompletedProcess:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(report, f)
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--report", f.name], capture_output=True, text=True)

    def test_reading_prints_bench_seconds(self):
        res = self.run_report({"launches": [row(home=2400.0)]})
        self.assertEqual(res.returncode, 0)
        self.assertIn("bench_seconds=2.4000", res.stdout)

    def test_no_reading_fails_open_as_missing(self):
        res = self.run_report({"launches": []})
        self.assertEqual(res.returncode, U.NO_READING)
        self.assertIn("fail open", res.stdout)

    def test_no_dmg_fails_open(self):
        res = subprocess.run([sys.executable, "-I", str(SCRIPT), "--dmg", "/nonexistent.dmg"], capture_output=True,
                             text=True)
        self.assertEqual(res.returncode, 127)
        self.assertIn("fail open", res.stdout)


if __name__ == "__main__":
    unittest.main()
