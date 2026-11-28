#!/usr/bin/env python3
"""scripts/measure/ios_tab_zoom.py: the tab grid zoom bench's report fails on the work budget only."""
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_tab_zoom", ROOT / "scripts/measure/ios_tab_zoom.py")
zoom = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(zoom)

CONSOLE = """\
t = 1.0s TABZOOM_SUMMARY scene=many direction=to_grid zooms=6 frames=240 duration_ms_max=420.1 worst_ms=33.4 first_frame_ms_max=41.0 over_8_3ms=12 over_16_7ms=3 max_fps=120
TABZOOM_SUMMARY scene=many direction=to_page zooms=6 frames=230 duration_ms_max=400.0 worst_ms=8.4 first_frame_ms_max=8.3 over_8_3ms=0 over_16_7ms=0 max_fps=120
TABZOOM_MAIN zoom=0 direction=to_grid main_max_ms=38.2 main_busy_ms=120.5 iterations_4ms=9 worst_at=TabOverview.body
TABZOOM_WORK zoom=0 direction=to_grid frames=40 screen=40 grid=1 cards=27
TABZOOM_WORK zoom=1 direction=to_page frames=38 screen=38 grid=2 cards=27
"""


class TabZoomReportTests(unittest.TestCase):
    def run_report(self, console: str) -> tuple[int, dict]:
        with tempfile.TemporaryDirectory() as tmp:
            c = Path(tmp) / "ui-console.txt"
            c.write_text(console)
            out = Path(tmp) / "report.json"
            code = zoom.main(["--console", str(c), "--out", str(out)])
            return code, json.loads(out.read_text())

    def test_within_the_work_budget_passes_and_slow_frames_only_warn(self) -> None:
        code, report = self.run_report(CONSOLE)
        self.assertEqual(code, 0)
        self.assertEqual(report["failures"], [])
        self.assertTrue(any("first frame 41.0" in w for w in report["warnings"]))
        self.assertTrue(any("3 frames over 16.7" in w for w in report["warnings"]))
        self.assertIn("| many | to_grid | 6 | 41.0 |", report["table_md"])
        self.assertEqual(report["work"][0]["cards"], 27)

    def test_a_grid_that_reruns_every_frame_fails(self) -> None:
        code, report = self.run_report(CONSOLE + "TABZOOM_WORK zoom=2 direction=to_grid frames=40 screen=40 grid=40 cards=1080\n")
        self.assertEqual(code, 1)
        self.assertEqual(len(report["failures"]), 1)
        self.assertIn("grid 40", report["failures"][0])

    def test_no_bench_lines_fails(self) -> None:
        code, _ = self.run_report("nothing here\n")
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
