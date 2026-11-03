#!/usr/bin/env python3
"""chat_open_frames: a sidebar click's first content frame and final frame from frame_strip rows."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import chat_open_frames as cof  # noqa: E402


def frame(ms, before, final, flat=0.5, blank=False):
    return {"ms": ms, "content_vs_before": before, "content_vs_final": final, "flatness": flat, "blank": blank}


def strip(*pictures, step=8):
    """Frames before the click, then one per `pictures` entry: (vs before, vs final, flatness)."""
    rows = [frame(-16, 0, 0.3), frame(-8, 0, 0.3)]
    rows += [frame(step * (i + 1), *p) for i, p in enumerate(pictures)]
    return rows


class FinalFrameTests(unittest.TestCase):
    def test_first_content_frame_is_final(self):
        rows = strip((0, 0.3), (0, 0.3), *[(0.3, 0)] * 12)
        out = cof.final_frame(rows, settle_frames=10)
        self.assertEqual(out["first_content_ms"], 24)
        self.assertEqual(out["final_frame_ms"], 24)
        self.assertTrue(out["first_is_final"])
        self.assertEqual(out["between_frames"], 0)

    def test_text_first_then_real_view(self):
        # Text-only frames, then the real view a while later: content first, final later, frames between.
        rows = strip((0, 0.3), *[(0.2, 0.1)] * 5, *[(0.3, 0)] * 12)
        out = cof.final_frame(rows, settle_frames=10)
        self.assertEqual(out["first_content_ms"], 16)
        self.assertEqual(out["final_frame_ms"], 56)
        self.assertFalse(out["first_is_final"])
        self.assertEqual(out["between_frames"], 5)

    def test_blank_frame_is_not_content(self):
        rows = strip((0.4, 0.4, 0.999), *[(0.3, 0)] * 12)
        rows[2]["blank"] = True
        out = cof.final_frame(rows, settle_frames=10)
        self.assertEqual(out["first_content_ms"], 16)
        self.assertEqual(out["blank_frames"], 1)
        self.assertTrue(out["first_is_final"])

    def test_unsettled_strip_has_no_final_frame(self):
        rows = strip((0.3, 0.1), (0.3, 0.1), *[(0.3, 0)] * 3)
        out = cof.final_frame(rows, settle_frames=10)
        self.assertFalse(out["settled"])
        self.assertIsNone(out["final_frame_ms"])
        self.assertFalse(cof.valid(out))

    def test_rows_without_content_fields_are_an_error(self):
        out = cof.final_frame([{"ms": 8, "blank": False}])
        self.assertIn("error", out)
        self.assertFalse(cof.valid(out))

    def test_click_that_changed_nothing_has_no_content(self):
        out = cof.final_frame(strip(*[(0, 0)] * 12), settle_frames=10)
        self.assertIsNone(out["first_content_ms"])
        self.assertFalse(cof.valid(out))


class DriftAndSummaryTests(unittest.TestCase):
    def test_row_drift_takes_the_largest_row_move(self):
        watch = {"frames": 90, "first_content_ms": 40, "scroll_jumps": [{"at_ms": 70}],
                 "shifts": [{"element": "row#3", "from": {"x": 0, "y": 100, "w": 10, "h": 10}, "to": {"x": 0, "y": 112, "w": 10, "h": 10}},
                            {"element": "composer", "from": {"x": 0, "y": 0, "w": 1, "h": 1}, "to": {"x": 0, "y": 90, "w": 1, "h": 1}}]}
        self.assertEqual(cof.row_drift(watch), {"rows_moved": 1, "max_row_px": 12, "scroll_jumps": 1, "page_first_content_ms": 40})
        self.assertEqual(cof.row_drift({"frames": 3, "shifts": []})["max_row_px"], 0)
        self.assertIsNone(cof.row_drift(None))
        self.assertIsNone(cof.row_drift({"error": "no pane shows an agent tab"}))

    def test_summary_needs_every_click_settled(self):
        good = dict(cof.final_frame(strip(*[(0.3, 0)] * 12)), drift={"max_row_px": 0})
        bad = cof.final_frame(strip(*[(0, 0)] * 12))
        whole = cof.summarize([good, good])
        self.assertTrue(whole["complete"])
        self.assertEqual(whole["final_frame_ms"], 8)
        self.assertEqual(whole["first_is_final"], 2)
        self.assertIn("first=final 2/2", cof.cell(whole))
        part = cof.summarize([good, bad])
        self.assertFalse(part["complete"])
        self.assertIsNone(part["final_frame_ms"])
        self.assertEqual(cof.cell(part), "FAILED (1/2 settled)")


if __name__ == "__main__":
    unittest.main()
