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


if __name__ == "__main__":
    unittest.main()
