#!/usr/bin/env python3
"""one_motion_series: movers, when each moved, and the spreads (python3 scripts/cmux-next/test_one_motion_series.py)."""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from one_motion_series import progress, series, summarize  # noqa: E402


def pane(pid, fx, fw, cx, cw):
    """A ScreenContentView+MotionSample pane row with the host frame at x `fx`, width `fw`, the content at `cx`, `cw`."""
    return [pid, fx, 0, fw, 500, 1, 0, fx, 0, fw, 500, cw, 500, 1, cx, 0, cw, 500]


def trace(frames):
    """[{t, sidebar, panes}] from [(sidebar width, [pane rows])], one frame each 8 ms."""
    return [{"t": i * 8.0, "sidebar": [w, w], "panes": rows} for i, (w, rows) in enumerate(frames)]


class SeriesTests(unittest.TestCase):
    def test_movers_are_the_sidebar_each_pane_frame_and_content(self):
        samples = trace([(300, [pane("pane_aaaaaa", 300, 700, 300, 700)])])
        self.assertEqual(sorted(series(samples)), ["pane aaaaaa content", "pane aaaaaa frame", "sidebar"])

    def test_panes_that_follow_the_sidebar_move_as_one(self):
        widths = [300, 300, 200, 100, 0, 0]
        samples = trace([(w, [pane("pane_aaaaaa", w, 1000 - w, w, 1000 - w)]) for w in widths])
        result = summarize("sidebar-hide", samples, 8.0, 8.0)
        self.assertEqual(result["spread_start_ms"], 0)
        self.assertEqual(result["spread_end_ms"], 0)
        self.assertEqual(result["content_lag_ms"], {"pane aaaaaa": 0})

    def test_content_held_to_the_landing_lags_its_frame(self):
        # The frame shrinks over three frames; its content keeps its width and lays out two frames after the landing.
        frames = [(300, [pane("pane_aaaaaa", 300, 700, 300, 700)]), (300, [pane("pane_aaaaaa", 300, 600, 300, 700)]),
                  (300, [pane("pane_aaaaaa", 300, 500, 300, 700)]), (300, [pane("pane_aaaaaa", 300, 400, 300, 700)]),
                  (300, [pane("pane_aaaaaa", 300, 400, 300, 700)]), (300, [pane("pane_aaaaaa", 300, 400, 300, 400)])]
        result = summarize("split-right", trace(frames), 0.0, 8.0)
        frame, content = result["movers"]["pane aaaaaa frame"], result["movers"]["pane aaaaaa content"]
        self.assertEqual((frame["start_ms"], frame["end_ms"]), (8.0, 24.0))
        self.assertEqual((content["start_ms"], content["end_ms"]), (40.0, 40.0))
        self.assertEqual(result["content_lag_ms"], {"pane aaaaaa": 16.0})
        self.assertEqual(result["spread_start_ms"], 32.0)
        self.assertNotIn("sidebar", result["movers"])

    def test_progress_runs_from_start_to_landing_on_the_widest_travel(self):
        points = [(0, (300.0, 0.0, 700.0)), (8, (300.0, 0.0, 550.0)), (16, (300.0, 0.0, 400.0))]
        self.assertEqual([p for _, p in progress(points)], [0.0, 0.5, 1.0])

    def test_a_value_that_returns_to_its_start_is_drawn_by_its_swing(self):
        points = [(0, (10.0,)), (8, (30.0,)), (16, (10.0,))]
        self.assertEqual([p for _, p in progress(points)], [0.0, 1.0, 0.0])
        self.assertIsNone(progress([(0, (1.0,)), (8, (1.2,))]))


if __name__ == "__main__":
    unittest.main()
