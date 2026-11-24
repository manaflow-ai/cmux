#!/usr/bin/env python3
"""split_resize.py's lockstep count on synthetic divider drags: frames where the pane's area or its top-right
buttons are not where the divider put them that frame (Leo: "i want all our resizing at any cpu to be able to
happen in lockstep"), and the drag frame time p95.
Run: python3 -I scripts/ci/frame-pacing/tests/test_split_resize_lockstep.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import split_resize as sr  # noqa: E402

R = 1000 / 120


def drag(lag_area_at=(), lag_buttons_at=(), slow_at=()):
    """A divider moving 800 → 700 over 10 frames, the browser pane right of it (host width = 1600 - divider)."""
    samples, t = [], 0.0
    for i in range(14):
        x = 800 - 10 * min(i, 10)
        width = 1600 - x - 1 + (20 if i in lag_area_at else 0)
        buttons = 1590 - (12 if i in lag_buttons_at else 0)
        samples.append({
            "t": t, "window": [1600, 1000],
            "dividers": [["d", x, 0, 1, 1000]],
            "page": [[width, 0, width, 0, 1000.0 + t]],
            "controls": [[1400, 1600, 0, 1600, buttons]],
        })
        t += R * (3 if i in slow_at else 1)
    return {"gesture": "divider", "pane": "browser", "samples": samples}


class Lockstep(unittest.TestCase):
    def test_in_lockstep(self):
        verdict = sr.judge_drag(drag(), R)
        self.assertEqual(verdict["lockstep_lag_frames"], 0, verdict)
        self.assertEqual(verdict["controls_lag_frames"], 0)
        self.assertTrue(verdict["controls_measured"])
        self.assertAlmostEqual(verdict["frame_ms"]["p95"], round(R, 2))

    def test_buttons_trailing_count(self):
        verdict = sr.judge_drag(drag(lag_buttons_at=(3, 4)), R)
        self.assertEqual(verdict["controls_lag_frames"], 2)
        self.assertEqual(verdict["lockstep_lag_frames"], 2)

    def test_area_trailing_counts(self):
        verdict = sr.judge_drag(drag(lag_area_at=(5,)), R)
        self.assertEqual(verdict["lockstep_lag_frames"], 1, verdict)

    def test_slow_frames_raise_p95(self):
        verdict = sr.judge_drag(drag(slow_at=(2, 3, 4)), R)
        self.assertGreater(verdict["frame_ms"]["p95"], 2 * R)

    def test_summary_and_row(self):
        verdict = sr.judge({"pane": "browser", "drags": [drag(lag_buttons_at=(2,))]}, R)
        self.assertEqual(verdict["lockstep_lag_frames"], 1)
        self.assertIn("out of lockstep in 1 frames", sr.markdown_row({**verdict, "gesture": "divider"}))


if __name__ == "__main__":
    unittest.main()
