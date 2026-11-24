#!/usr/bin/env python3
"""launch_shift: what moved after a relaunch's first frame, from a --record-launch recording."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import launch_shift as ls  # noqa: E402

PAGE = "".join(f"{(i * 7) % 200 + 20:02x}" for i in range(256))  # a drawn window: cells far apart
BLANK = "10" * 256


def changed(cells, count, by=40):
    """`cells` with its first `count` cells brighter by `by`."""
    values = [int(cells[i:i + 2], 16) for i in range(0, 512, 2)]
    for i in range(count):
        values[i] = min(255, values[i] + by)
    return "".join(f"{v:02x}" for v in values)


def recording(cells, moved=None, window=None, layouts=None, ended="time"):
    n = len(cells)
    return {"times": [i / 60 for i in range(n)], "processMs": [900 + i * 16.7 for i in range(n)], "cells": cells,
            "moved": moved or [0] * n, "movedViews": [[f"SidebarView moved 0,0,240,600 -> 0,0,312,600"] if m else []
                                                     for m in (moved or [0] * n)],
            "window": window or [[80, 220, 1100, 700]] * n, "viewLayouts": [0] * n,
            "windowLayouts": layouts or [0] * n, "endedBy": ended}


class LaunchShiftTests(unittest.TestCase):
    def test_a_still_launch_has_no_change(self):
        w = ls.window(recording([PAGE] * 30))
        self.assertEqual(w["first_paint_ms"], 900)
        self.assertFalse(w["blank_first"])
        self.assertEqual((w["geometry_frames"], w["pixel_frames"], w["blank_frames"], w["last_change_ms"]), (0, 0, 0, 0))
        self.assertEqual(w["first_vs_final"], 0)

    def test_a_blank_first_frame_that_fills_in_counts(self):
        w = ls.window(recording([BLANK] * 3 + [PAGE] * 10))
        self.assertTrue(w["blank_first"])
        self.assertEqual(w["pixel_frames"], 1)
        self.assertEqual(w["last_change_ms"], 50)
        self.assertGreater(w["first_vs_final"], 0.9)

    def test_a_caret_or_a_counter_is_under_the_share(self):
        cells = [PAGE, changed(PAGE, 2), PAGE, changed(PAGE, 2)] * 5
        self.assertEqual(ls.window(recording(cells))["pixel_frames"], 0)

    def test_a_flash_counts_as_blank_and_pixels(self):
        w = ls.window(recording([PAGE] * 5 + [BLANK] + [PAGE] * 5))
        self.assertEqual(w["blank_frames"], 1)
        self.assertEqual(w["pixel_frames"], 2)  # into the flash and out of it

    def test_moved_views_and_a_moved_window_count_once_per_frame(self):
        moved = [0, 0, 3, 0, 0]
        window = [[80, 220, 1100, 700]] * 4 + [[80, 220, 1200, 700]]
        w = ls.window(recording([PAGE] * 5, moved=moved, window=window, layouts=[0, 1, 2, 0, 1]))
        self.assertEqual(w["geometry_frames"], 2)
        self.assertEqual(w["window_moves"], 1)
        self.assertEqual(w["layout_passes"], 4)
        self.assertEqual(w["views"], {"SidebarView": 1})
        self.assertEqual(w["last_change_ms"], 67)

    def test_the_folder_summary_reads_every_window(self):
        with tempfile.TemporaryDirectory() as root:
            for n, rec in ((1, recording([BLANK, PAGE], ended="closed")), (2, recording([PAGE] * 4, moved=[0, 1, 0, 0]))):
                os.makedirs(os.path.join(root, f"window-{n}"))
                with open(os.path.join(root, f"window-{n}", "frames.json"), "w") as f:
                    json.dump(rec, f)
            os.makedirs(os.path.join(root, "window-3"))
            self.assertFalse(ls.recorded(root))
            unfinished = ls.summarize(root)["total"]
            self.assertEqual((unfinished["windows"], unfinished["errors"]), (3, 1))
            os.rmdir(os.path.join(root, "window-3"))
            self.assertTrue(ls.recorded(root))
            summary = ls.summarize(root)
            total = summary["total"]
            self.assertEqual((total["windows"], total["blank_first"], total["closed_while_recorded"]), (2, 1, 1))
            self.assertEqual((total["geometry_frames"], total["pixel_frames"]), (1, 1))
            self.assertIn("| total |", ls.table(summary))

    def test_process_wide_layouts_are_not_summed_across_windows(self):
        with tempfile.TemporaryDirectory() as root:
            for n in (1, 2):
                os.makedirs(os.path.join(root, f"window-{n}"))
                with open(os.path.join(root, f"window-{n}", "frames.json"), "w") as f:
                    json.dump(recording([PAGE] * 3, layouts=[0, 2, 3]), f)
            self.assertEqual(ls.summarize(root)["total"]["layout_passes"], 5)

    def test_frames_without_cells_still_count_geometry(self):
        rec = recording([PAGE] * 3, moved=[0, 2, 0])
        del rec["cells"]
        w = ls.window(rec)
        self.assertIsNone(w["blank_first"])
        self.assertEqual((w["geometry_frames"], w["pixel_frames"]), (1, 0))


class PerceivedTests(unittest.TestCase):
    """settled_match_ms, first_frame_is_final, shift_score, alpha_changes and tti_ms (Leo, 2026-11-24: perceived
    speed over anything; layout shifts are bad)."""

    def test_a_launch_final_at_its_first_frame(self):
        rec = recording([PAGE] * 40)
        rec["movedRects"] = [[] for _ in range(40)]
        rec["alpha"] = [1.0] * 40
        w = ls.window(rec)
        self.assertEqual(w["settled_match_ms"], w["first_paint_ms"])
        self.assertEqual(w["settled_match_ms"], 900)
        self.assertTrue(w["first_frame_is_final"])
        self.assertTrue(w["settled"])
        self.assertEqual(w["shift_score"], 0)
        self.assertFalse(w["shift_score_approx"])
        self.assertEqual(w["alpha_changes"], 0)

    def test_a_frame_that_fills_in_late_sets_the_settled_match(self):
        w = ls.window(recording([BLANK] * 3 + [PAGE] * 40))
        self.assertFalse(w["first_frame_is_final"])
        self.assertEqual(w["settled_match_ms"], round(900 + 3 * 16.7))
        # Under the pixel threshold (a caret) still matches the settled frame.
        w = ls.window(recording([changed(PAGE, 2)] + [PAGE] * 40))
        self.assertTrue(w["first_frame_is_final"])

    def test_one_view_sliding_100_pt(self):
        n = 40
        rec = recording([PAGE] * n, moved=[0, 0, 1] + [0] * (n - 3))
        rec["window"] = [[0, 0, 1000, 600]] * n
        rec["movedRects"] = [[] for _ in range(n)]
        rec["movedRects"][2] = [{"name": "SidebarView", "from": [0, 0, 240, 600], "to": [100, 0, 240, 600]}]
        w = ls.window(rec)
        diagonal = (1000 ** 2 + 600 ** 2) ** 0.5
        expected = (100 / diagonal) * ((340 * 600) / (1000 * 600))
        self.assertAlmostEqual(w["shift_score"], round(expected, 4))
        self.assertFalse(w["shift_score_approx"])
        self.assertFalse(w["first_frame_is_final"])
        self.assertEqual(w["settled_match_ms"], round(900 + 2 * 16.7))

    def test_shift_math(self):
        self.assertEqual(ls.move_distance([0, 0, 240, 600], [0, 0, 312, 600]), 72)
        self.assertAlmostEqual(ls.shift_of([0, 0, 100, 100], [0, 0, 100, 100], [0, 0, 1000, 1000]), 0)
        # The impact is capped at the window.
        self.assertLessEqual(ls.shift_of([0, 0, 1000, 1000], [500, 0, 1000, 1000], [0, 0, 1000, 1000]),
                             500 / (2 ** 0.5 * 1000))

    def test_a_moved_window_counts_as_the_whole_window(self):
        n = 40
        rec = recording([PAGE] * n, window=[[0, 0, 1000, 600]] * 2 + [[0, 0, 1100, 600]] * (n - 2))
        rec["movedRects"] = [[] for _ in range(n)]
        w = ls.window(rec)
        self.assertGreater(w["shift_score"], 0)
        self.assertEqual(w["settled_match_ms"], round(900 + 2 * 16.7))

    def test_an_older_recording_approximates_the_score(self):
        w = ls.window(recording([PAGE] * 10, moved=[0, 1, 0, 1, 0, 0, 0, 0, 0, 0]))
        self.assertTrue(w["shift_score_approx"])
        self.assertAlmostEqual(w["shift_score"], 0.2)
        self.assertIsNone(w["alpha_changes"])

    def test_an_alpha_change_counts(self):
        rec = recording([PAGE] * 40)
        rec["alpha"] = [0.0, 0.5] + [1.0] * 38
        w = ls.window(rec)
        self.assertEqual(w["alpha_changes"], 2)
        self.assertFalse(w["first_frame_is_final"])
        self.assertEqual(w["settled_match_ms"], round(900 + 2 * 16.7))

    def test_not_settled_when_the_last_change_is_recent(self):
        w = ls.window(recording([PAGE] * 10 + [BLANK]))
        self.assertFalse(w["settled"])

    def test_tti_reads_the_earliest_input_mark(self):
        self.assertEqual(ls.tti({"window_usable": 700.4, "terminal_input_accepted": 655.5}), (656, "terminal_input_accepted"))
        self.assertEqual(ls.tti({"first_key_down": 630}), (630, "first_key_down"))
        self.assertEqual(ls.tti({"main_start": 3}), (None, None))
        rec = recording([PAGE] * 5)
        rec["launchMarks"] = {"window_usable": 812.0}
        self.assertEqual((ls.window(rec)["tti_ms"], ls.window(rec)["tti_mark"]), (812, "window_usable"))

    def test_the_launch_total_and_headline(self):
        with tempfile.TemporaryDirectory() as root:
            first = recording([BLANK, PAGE], ended="closed")
            second = recording([BLANK] * 2 + [PAGE] * 40)
            second["launchMarks"] = {"window_usable": 1200}
            second["alpha"] = [1.0] * 42
            for n, rec in ((1, first), (2, second)):
                os.makedirs(os.path.join(root, f"window-{n}"))
                with open(os.path.join(root, f"window-{n}", "frames.json"), "w") as f:
                    json.dump(rec, f)
            total = ls.summarize(root)["total"]
            self.assertEqual(total["settled_match_ms"], round(900 + 2 * 16.7))  # the closed window does not count
            self.assertFalse(total["first_frame_is_final"])
            self.assertEqual((total["tti_ms"], total["tti_mark"]), (1200, "window_usable"))
            self.assertEqual(total["alpha_changes"], 0)
            line = ls.headline(total)
            self.assertTrue(line.startswith(f"PERCEIVED settled_match_ms=933 shift_score={total['shift_score']} "
                                            "tti_ms=1200 first_frame_is_final=false"), line)
            self.assertTrue(ls.table(ls.summarize(root)).startswith("PERCEIVED "))
            # A harness's own marks fill in a recording that carries none.
            del second["launchMarks"]
            with open(os.path.join(root, "window-2", "frames.json"), "w") as f:
                json.dump(second, f)
            self.assertEqual(ls.summarize(root, marks={"terminal_input_accepted": 990})["total"]["tti_ms"], 990)


class RelaunchBenchMedianTests(unittest.TestCase):
    def test_the_medians_carry_the_perceived_numbers(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("relaunch_shift_bench", Path(__file__).resolve().parent.parent / "relaunch-shift-bench.py")
        bench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bench)
        rounds = [{"total": {"settled_match_ms": ms, "shift_score": score, "tti_ms": 800, "tti_mark": "window_usable",
                             "first_frame_is_final": final, "alpha_changes": 0}}
                  for ms, score, final in ((900, 0, True), (1300, 0.12, False), (950, 0.02, True))]
        median = bench.median_of(rounds)
        self.assertEqual((median["settled_match_ms"], median["shift_score"], median["tti_ms"]), (950, 0.02, 800))
        self.assertTrue(median["first_frame_is_final"])
        self.assertEqual(median["first_frame_final_rounds"], "2/3")
        self.assertTrue(ls.headline(median).startswith(
            "PERCEIVED settled_match_ms=950 shift_score=0.02 tti_ms=800 first_frame_is_final=true"))


if __name__ == "__main__":
    unittest.main()
