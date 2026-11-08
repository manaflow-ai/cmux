#!/usr/bin/env python3
"""split_scale_metrics: frame times, retargets, input-aligned layout times, blank and partial frames, failed rounds, flatness (python3 scripts/cmux-next/test_split_scale_metrics.py)."""
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


class SideWayTests(unittest.TestCase):
    """The side pane toggle's direction from the panes' summed width (side_toggle in the bench)."""

    def two_panes(self, widths):
        return {"refresh_ms": 8.33, "samples": [{"t": i * 8.33, "panes": [pane("pane_aaaaaa", 0, w), pane("pane_bbbbbb", w, w)]}
                                                for i, w in enumerate(widths)]}

    def test_narrowed_panes_opened_the_sidebar(self):
        stats = ssm.trace_stats(self.two_panes([600, 600, 450, 450]))
        self.assertEqual(stats["pane_width_change"], -300.0)
        self.assertEqual(ssm.side_way(stats), "opened")

    def test_widened_panes_closed_it(self):
        self.assertEqual(ssm.side_way(ssm.trace_stats(self.two_panes([450, 450, 600]))), "closed")

    def test_still_panes_or_no_trace_say_nothing(self):
        self.assertIsNone(ssm.side_way(ssm.trace_stats(self.two_panes([600, 600, 600]))))
        self.assertIsNone(ssm.side_way({"pane_width_change": None}))
        self.assertIsNone(ssm.trace_stats({"samples": []})["pane_width_change"])

    def test_panes_that_came_back_go_by_their_peak(self):
        stats = ssm.trace_stats(self.two_panes([450, 520, 600, 520, 450]))
        self.assertEqual((stats["pane_width_change"], stats["pane_width_peak"]), (0.0, 300.0))
        self.assertEqual(ssm.side_way(stats), "closed")
        self.assertTrue(ssm.side_returned(stats))
        self.assertFalse(ssm.side_returned(ssm.trace_stats(self.two_panes([450, 600]))))

    def test_a_pane_that_came_or_went_is_left_out(self):
        samples = [{"t": 0, "panes": [pane("pane_aaaaaa", 0, 600)]},
                   {"t": 8.33, "panes": [pane("pane_aaaaaa", 0, 450), pane("pane_cccccc", 450, 450)]}]
        self.assertEqual(ssm.pane_width_change(samples), -150.0)

    def test_the_way_survives_transition(self):
        strip = {"frames": [frame(0), frame(10, ob=0.3)], "sent_host_s": 1.0}
        row = ssm.transition(strip, dict(self.two_panes([600, 600, 450]), t0_s=1.0))
        self.assertEqual(ssm.side_way(row), "opened")


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


class TransitionTests(unittest.TestCase):
    def aligned(self, widths, sent_t=16.66):
        t = trace(widths)
        t["t0_s"] = 100.0
        return t, 100.0 + sent_t / 1000

    def strip(self, sent, frames):
        return {"frames": frames, "sent_host_s": sent}

    def test_layout_times_come_from_the_trace_lined_up_with_the_input(self):
        t, sent = self.aligned([1000, 1000, 1000, 1000, 800, 650, 600, 600, 600, 600])
        frames = [frame(10 + i * 8, ob=0.2, cb=0.3) for i in range(10)]
        row = ssm.transition(self.strip(sent, frames), t, static=True)
        self.assertNotIn("error", row)
        self.assertAlmostEqual(row["first_frame_ms"], 16.7, places=0)
        self.assertAlmostEqual(row["settled_ms"], 33.3, places=0)

    def test_static_content_that_paints_late_delays_settled(self):
        t, sent = self.aligned([1000, 1000, 1000, 800, 700, 700, 700])
        frames = [frame(10, ob=0.2, of=0.1, cb=0.3, cf=0.4), frame(60, ob=0.2, cb=0.3, cf=0.4)] + \
                 [frame(90 + i * 8, ob=0.2, cb=0.3) for i in range(8)]
        row = ssm.transition(self.strip(sent, frames), t, static=True)
        self.assertEqual(row["settled_ms"], 90)
        self.assertEqual(row["partial_frames"], 1)

    def test_streaming_content_is_timed_by_the_layout_alone(self):
        t, sent = self.aligned([1000, 1000, 1000, 800, 700, 700, 700])
        frames = [frame(10 + i * 8, ob=0.2, of=0.1 + (i % 2) * 0.05, cb=0.3, cf=0.2) for i in range(12)]
        row = ssm.transition(self.strip(sent, frames), t, static=False)
        self.assertNotIn("error", row)
        self.assertAlmostEqual(row["settled_ms"], 16.7, places=0)
        self.assertIsNone(row["partial_frames"])

    def test_motion_before_the_input_is_left_out(self):
        t, sent = self.aligned([900, 950, 1000, 1000, 1000, 1000], sent_t=25)
        row = ssm.transition(self.strip(sent, [frame(5)]), t, static=False)
        self.assertIn("nothing moved", row["error"])

    def test_a_failed_strip_fails_the_round(self):
        t, sent = self.aligned([1000, 1000, 800, 700, 700])
        row = ssm.transition({"error": "no frames"}, t, static=True)
        self.assertIn("strip", row["error"])


class SummaryTests(unittest.TestCase):
    def summary(self, settled, **extra):
        return {"first_frame_ms": 10, "settled_ms": settled, "frame_p95_ms": 8.3, "blank_frames": 0, "retargets": 0,
                "unsettled": 0, "refresh_ms": 8.33, "rounds": 3, "failed_rounds": 0, **extra}

    def test_rounds_take_the_median_and_the_worst_blank(self):
        rows = [{"settled_ms": 100, "blank_frames": 0}, {"settled_ms": 140, "blank_frames": 2}, {"settled_ms": 90, "blank_frames": 0}]
        s = ssm.summarize(rows)
        self.assertEqual(s["settled_ms"], 100)
        self.assertEqual(s["blank_frames"], 2)

    def test_a_failed_round_fails_the_cell(self):
        s = ssm.summarize([{"settled_ms": 50, "first_frame_ms": 8, "frame_p95_ms": 8, "blank_frames": 0, "retargets": 0},
                           {"error": "the key made no pane"}])
        self.assertEqual(s["failed_rounds"], 1)
        self.assertFalse(ssm.verdict(s, 8.33)["pass"])
        head = ssm.headline({"s1-empty-w1": {"split_right": s}}, {})
        self.assertIsNone(head["settled_ms"])

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
