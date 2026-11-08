#!/usr/bin/env python3
"""split_scale_metrics: frame times, retargets, blank and partial frames, flatness (python3 scripts/cmux-next/test_split_scale_metrics.py)."""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import split_scale_metrics as ssm  # noqa: E402


def pane(pid, x, w):
    """A ScreenContentView+MotionSample pane row at x `x`, width `w` (frame and content alike)."""
    return [pid, x, 0, w, 500, 1, 0, x, 0, w, 500, w, 500, 1, x, 0, w, 500]


def trace(widths, dt=8.33, refresh=8.33, times=None):
    """A trace of one pane whose width goes through `widths`, one sample per tick."""
    times = times or [i * dt for i in range(len(widths))]
    return {"refresh_ms": refresh, "samples": [{"t": t, "panes": [pane("pane_aaaaaa", 0, w)]} for t, w in zip(times, widths)]}


def frame(ms, ob=0.0, of=0.0, cb=0.0, cf=0.0, blank=False):
    return {"ms": ms, "outside_vs_before": ob, "outside_vs_final": of, "content_vs_before": cb, "content_vs_final": cf,
            "blank": blank}


class TraceTests(unittest.TestCase):
    def test_a_smooth_deceleration_has_no_retarget(self):
        stats = ssm.trace_stats(trace([1000, 1000, 800, 680, 610, 570, 552, 545, 543, 543, 543]))
        self.assertEqual(stats["retargets"], 0)
        self.assertEqual(stats["dropped_frames"], 0)
        self.assertAlmostEqual(stats["frame_p95_ms"], 8.33, places=1)

    def test_a_reversal_is_a_retarget(self):
        stats = ssm.trace_stats(trace([1000, 800, 650, 600, 640, 700, 700, 700]))
        self.assertEqual(stats["retargets"], 1)
        self.assertIn("pane aaaaaa frame", stats["retargeted"])

    def test_speeding_up_again_mid_flight_is_a_retarget(self):
        stats = ssm.trace_stats(trace([1000, 900, 840, 810, 795, 700, 640, 610, 600, 600]))
        self.assertGreaterEqual(stats["retargets"], 1)

    def test_a_dropped_frame_is_counted_and_is_no_retarget(self):
        times = [0, 8.33, 16.67, 25, 50, 58.3, 66.7, 75]
        stats = ssm.trace_stats(trace([1000, 1000, 800, 700, 600, 580, 575, 575], times=times))
        self.assertEqual(stats["dropped_frames"], 1)
        self.assertEqual(stats["frame_max_ms"], 25.0)
        self.assertEqual(stats["retargets"], 0)

    def test_frames_before_and_after_the_motion_are_left_out(self):
        widths = [1000] * 20 + [900, 850, 840] + [840] * 30
        stats = ssm.trace_stats(trace(widths))
        self.assertEqual(stats["moved_frames"], 3)


class StripTests(unittest.TestCase):
    def test_first_and_settled_frames(self):
        frames = [frame(-10), frame(5), frame(12, ob=0.2, of=0.1, cb=0.3, cf=0.2)] + \
                 [frame(20 + i * 8, ob=0.2, cb=0.3) for i in range(8)]
        stats = ssm.strip_stats({"frames": frames, "first_change_ms": 12})
        self.assertEqual(stats["first_frame_ms"], 12)
        self.assertEqual(stats["settled_ms"], 20)
        self.assertEqual(stats["partial_frames"], 0)

    def test_content_that_paints_after_the_layout_landed_is_partial(self):
        frames = [frame(10, ob=0.2, of=0.1, cb=0.3, cf=0.4), frame(20, ob=0.2, cb=0.3, cf=0.4, blank=True),
                  frame(30, ob=0.2, cb=0.3, cf=0.2)] + [frame(40 + i * 8, ob=0.2, cb=0.3) for i in range(8)]
        stats = ssm.strip_stats({"frames": frames})
        self.assertEqual(stats["first_frame_ms"], 10)
        self.assertEqual(stats["partial_frames"], 2)
        self.assertEqual(stats["blank_frames"], 1)
        self.assertEqual(stats["settled_ms"], 40)

    def test_a_strip_that_never_settles_has_no_settled_time(self):
        frames = [frame(10 + i * 8, ob=0.2, of=0.1 if i % 2 else 0.0, cb=0.3) for i in range(10)]
        self.assertIsNone(ssm.strip_stats({"frames": frames})["settled_ms"])


class SummaryTests(unittest.TestCase):
    def summary(self, settled, **extra):
        return {"first_frame_ms": 10, "settled_ms": settled, "frame_p95_ms": 8.3, "blank_frames": 0, "retargets": 0,
                "unsettled": 0, "refresh_ms": 8.33, **extra}

    def test_rounds_take_the_median_and_the_worst_blank(self):
        rows = [{"settled_ms": 100, "blank_frames": 0}, {"settled_ms": 140, "blank_frames": 2}, {"settled_ms": 90, "blank_frames": 0}]
        s = ssm.summarize(rows)
        self.assertEqual(s["settled_ms"], 100)
        self.assertEqual(s["blank_frames"], 2)

    def test_verdict_and_p95_target_by_refresh(self):
        self.assertTrue(ssm.verdict(self.summary(100))["pass"])
        self.assertFalse(ssm.verdict(self.summary(130))["settled"])
        self.assertFalse(ssm.verdict(self.summary(100, frame_p95_ms=12))["p95"])
        self.assertTrue(ssm.verdict(self.summary(100, frame_p95_ms=12, refresh_ms=16.7))["p95"])

    def test_flatness_is_the_worst_cell_over_the_smallest(self):
        cells = {"s1-empty-w1": {"split_right": self.summary(100)}, "s9-browser-w30": {"split_right": self.summary(150)},
                 "s4-empty-w1": {"split_right": self.summary(110)}}
        flat = ssm.flatness(cells)["split_right"]
        self.assertEqual(flat["worst_cell"], "s9-browser-w30")
        self.assertEqual(flat["ratio"], 1.5)
        self.assertFalse(flat["pass"])
        head = ssm.headline(cells, ssm.flatness(cells))
        self.assertEqual((head["cell"], head["settled_ms"], head["ratio"]), ("s9-browser-w30", 150, 1.5))

    def test_the_table_fits_one_screen(self):
        cells = {f"s{s}-empty-w1": {t: self.summary(100 + s) for t in ("split_right", "close_right")} for s in (1, 4, 9)}
        report = {"cells": cells, "flatness": ssm.flatness(cells), "refresh_ms": 8.33}
        lines = ssm.table(report).splitlines()
        self.assertLess(len(lines), 25)
        self.assertTrue(all(len(line) < 130 for line in lines))


if __name__ == "__main__":
    unittest.main()
