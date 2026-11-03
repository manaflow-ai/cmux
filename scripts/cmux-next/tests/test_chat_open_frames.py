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
        self.assertFalse(out["first_is_final"])  # a blank flash before the final frame is no first-is-final

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


class TranscriptTests(unittest.TestCase):
    def test_strip_settled_on_chrome_before_the_transcript_is_no_pass(self):
        # The pane drew its chrome at once and settled, but the page's transcript came after the strip ended.
        record = cof.final_frame(strip(*[(0.3, 0)] * 12))
        self.assertTrue(record["first_is_final"])
        record["transcript_ms"] = cof.transcript_ms({"frames": 80, "first_content_ms": None}, 30, 2500)
        self.assertIsNone(record["transcript_ms"])
        self.assertFalse(cof.valid(record))
        self.assertIsNone(cof.transcript_ms({"frames": 80, "first_content_ms": 2400, "first_rows": 4}, 300, 2500))
        # A first paint of chrome with no rows (a page still loading reads as the empty chat) is no transcript.
        self.assertIsNone(cof.transcript_ms({"frames": 80, "first_content_ms": 20, "first_rows": 0}, 30, 2500))
        # A page that does not report its rows proves nothing.
        self.assertIsNone(cof.transcript_ms({"frames": 80, "first_content_ms": 20}, 30, 2500))
        self.assertIsNone(cof.transcript_ms(None, 30, 2500))

    def test_transcript_inside_the_strip_counts_from_the_click(self):
        record = cof.final_frame(strip(*[(0.3, 0)] * 12))
        record["transcript_ms"] = cof.transcript_ms({"frames": 80, "first_content_ms": 20, "first_rows": 6}, 45.5, 2500)
        self.assertEqual(record["transcript_ms"], 65.5)
        self.assertTrue(cof.valid(record))
        # A watch asked before the click counts from the click.
        self.assertEqual(cof.transcript_ms({"frames": 80, "first_content_ms": 20, "first_rows": 6}, -50, 2500), 20)

    def test_a_watch_that_reached_the_page_late_counts_from_when_it_began(self):
        # Asked 200 ms after the click, the call waited for the Chromium page until 3000 ms, and rows showed
        # 100 ms into the watch: the transcript came at 3100 ms, outside the strip, never at 300 (cmux#34151 review).
        clicked, clicked_wall = 100.0, 1_000_000.0
        watch = {"frames": 80, "first_content_ms": 100, "first_rows": 6, "started_wall_ms": clicked_wall * 1000 + 3000}
        started = cof.watch_started_ms(watch, clicked + 0.2, clicked, clicked_wall)
        self.assertEqual(started, 3000)
        self.assertIsNone(cof.transcript_ms(watch, started, 2500))
        # A page that reports no start keeps the ask's time.
        older = {k: v for k, v in watch.items() if k != "started_wall_ms"}
        self.assertEqual(cof.watch_started_ms(older, clicked + 0.2, clicked, clicked_wall), 200)
        self.assertEqual(cof.transcript_ms(older, 200, 2500), 300)
        self.assertIsNone(cof.watch_started_ms(None, clicked + 0.2, clicked, clicked_wall))

    def test_a_blank_frame_breaks_first_is_final(self):
        rows = strip((0.4, 0.4, 0.999), *[(0.3, 0)] * 12)
        rows[2]["blank"] = True
        rows[2]["content_vs_before"] = 0.5
        rows[2]["flatness"] = 0.999
        out = cof.final_frame(rows)
        self.assertFalse(out["first_is_final"])


class DriftAndSummaryTests(unittest.TestCase):
    def test_row_drift_takes_the_largest_row_move(self):
        watch = {"frames": 90, "first_content_ms": 40, "scroll_jumps": [{"at_ms": 70}],
                 "shifts": [{"element": "row#3", "from": {"x": 0, "y": 100, "w": 10, "h": 10}, "to": {"x": 0, "y": 112, "w": 10, "h": 10}},
                            {"element": "composer", "from": {"x": 0, "y": 0, "w": 1, "h": 1}, "to": {"x": 0, "y": 90, "w": 1, "h": 1}}]}
        watch["appeared"] = [{"element": "row#9", "at_ms": 300}, {"element": "chip:model", "at_ms": 90}]
        self.assertEqual(cof.row_drift(watch), {"rows_moved": 1, "max_row_px": 12, "rows_appeared_later": 1, "scroll_jumps": 1,
                                                "page_first_content_ms": 40})
        self.assertEqual(cof.row_drift({"frames": 3, "shifts": []})["max_row_px"], 0)
        self.assertIsNone(cof.row_drift(None))
        self.assertIsNone(cof.row_drift({"error": "no pane shows an agent tab"}))

    def test_summary_needs_every_click_settled(self):
        good = dict(cof.final_frame(strip(*[(0.3, 0)] * 12)), drift={"max_row_px": 0}, transcript_ms=40)
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



class FleetStripTests(unittest.TestCase):
    """Frames shaped like a fleet run's (a cold click from a near-empty terminal, 2026-11-03): the whole content area
    is nearly one color, before (0.9983), blank (0.9994) and final (0.9999) alike, so flatness alone called every
    frame blank and no click had a first content frame. frame_strip's `blank` (flat and unlike both before and the
    final frame, at the bench's 0.001 tolerance) tells them apart."""

    def rows(self):
        out = [frame(-10, 0, 0.0055, 0.9983), frame(0, 0, 0.0055, 0.9983)]
        out += [frame(ms, 0.0017, 0.0044, 0.9994, blank=True) for ms in range(47, 680, 10)]  # the pane, still blank
        out += [frame(689, 0.0055, 0, 0.9999), frame(715, 0.0017, 0.0044, 0.9994, blank=True)]  # content, blank again
        out += [frame(ms, 0.0055, 0, 0.9999) for ms in range(731, 1100, 10)]
        return out

    def test_a_sparse_chat_page_is_content_and_the_blank_between_counts(self):
        out = cof.final_frame(self.rows(), settle_frames=10, tolerance=0.001)
        self.assertEqual(out["first_content_ms"], 689)
        self.assertEqual(out["final_frame_ms"], 731)
        self.assertFalse(out["first_is_final"])
        self.assertEqual(out["between_frames"], 1)
        self.assertGreater(out["blank_frames"], 60)

    def test_a_kept_page_draws_its_final_frame_first(self):
        rows = [frame(-1, 0, 0.0055, 0.9983)] + [frame(ms, 0.0055, 0, 0.9999) for ms in range(28, 400, 10)]
        out = cof.final_frame(rows, settle_frames=10, tolerance=0.001)
        self.assertEqual((out["first_content_ms"], out["final_frame_ms"], out["first_is_final"]), (28, 28, True))

    def test_rows_that_came_after_the_first_paint_date_the_transcript(self):
        page = {"first_content_ms": 222, "first_rows": 0, "frames": 92,
                "appeared": [{"at_ms": 583, "element": "row#6"}, {"at_ms": 520, "element": "row#1"},
                             {"at_ms": 100, "element": "composer"}]}
        self.assertEqual(cof.transcript_ms(page, 30, 2500), 550)
        self.assertIsNone(cof.transcript_ms(dict(page, appeared=[]), 30, 2500))  # a page still loading
        self.assertIsNone(cof.transcript_ms(page, 2000, 2500))  # rows only after the strip ended

if __name__ == "__main__":
    unittest.main()
