#!/usr/bin/env python3
"""split_move_metrics: one move per mover, content on its pane, pixel reversals, reloads, the verdict (python3 scripts/cmux-next/test_split_move_metrics.py)."""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import split_move_metrics as smm  # noqa: E402

T = 8.33


def pane(pid, x, w, cx=None, cw=None):
    """A ScreenContentView+MotionSample pane row: frame at x `x`, width `w`; its content at `cx`, `cw` (the frame's
    when not given)."""
    cx, cw = x if cx is None else cx, w if cw is None else cw
    return [pid, x, 0, w, 500, 1, 0, x, 0, w, 500, cw, 500, 1, cx, 0, cw, 500]


def trace(ticks, t0=None):
    out = {"refresh_ms": T, "samples": [{"t": i * T, "panes": rows} for i, rows in enumerate(ticks)]}
    if t0 is not None:
        out["t0_s"] = t0
    return out


def frame(ms, ob=0.0, of=0.0, cb=0.0, cf=0.0, blank=False):
    return {"ms": ms, "outside_vs_before": ob, "outside_vs_final": of, "content_vs_before": cb, "content_vs_final": cf,
            "blank": blank}


BEFORE = [pane("pane_aaaaaa", 0, 500), pane("pane_bbbbbb", 500, 500)]
SWAPPED = [pane("pane_aaaaaa", 500, 500), pane("pane_bbbbbb", 0, 500)]


class LayoutTests(unittest.TestCase):
    def test_a_move_that_shows_whole_in_one_tick_breaks_nothing(self):
        stats = smm.layout_stats(trace([BEFORE] * 3 + [SWAPPED] * 6))
        self.assertEqual((stats["moved_after_commit"], stats["content_off_pane"], stats["frames_to_rest"]), (0, 0, 0))
        self.assertAlmostEqual(stats["commit_ms"], 3 * T, places=1)

    def test_one_move_toward_the_final_rect_over_several_ticks_breaks_nothing(self):
        steps = [[pane("pane_aaaaaa", x, 500), pane("pane_bbbbbb", 500 - x, 500)] for x in (200, 350, 430, 480, 500)]
        stats = smm.layout_stats(trace([BEFORE] * 2 + steps + [SWAPPED] * 4))
        self.assertEqual(stats["moved_after_commit"], 0)
        self.assertEqual(stats["frames_to_rest"], 4)
        self.assertEqual(stats["series"]["pane aaaaaa frame"][:5], [300.0, 150.0, 70.0, 20.0, 0.0])

    def test_a_mover_that_starts_after_the_commit_tick_is_late(self):
        held = [pane("pane_aaaaaa", 500, 500, cx=0), pane("pane_bbbbbb", 0, 500)]  # the content still where it was
        stats = smm.layout_stats(trace([BEFORE] * 2 + [held] * 4 + [SWAPPED] * 4))
        self.assertEqual(stats["broke"], {"pane aaaaaa content": {"late": 1, "again": 0, "back": 0, "px": 500.0}})
        self.assertEqual((stats["moved_after_commit"], stats["moved_after_commit_frames"], stats["moved_after_commit_px"]), (1, 1, 500.0))
        self.assertEqual((stats["content_off_pane"], stats["content_off_pane_px"]), (4, 500.0))

    def test_a_second_move_after_a_stop_counts_as_again(self):
        narrow = [pane("pane_aaaaaa", 500, 500, cw=460), pane("pane_bbbbbb", 0, 500)]  # the content lays out twice
        stats = smm.layout_stats(trace([BEFORE] * 2 + [narrow] * 5 + [SWAPPED] * 4))
        self.assertEqual(stats["broke"]["pane aaaaaa content"]["again"], 1)
        self.assertEqual(stats["content_off_pane"], 5)

    def test_a_step_away_from_the_final_rect_counts_as_back(self):
        steps = [[pane("pane_aaaaaa", x, 500), pane("pane_bbbbbb", 500 - x, 500)] for x in (300, 540, 500)]
        stats = smm.layout_stats(trace([BEFORE] * 2 + steps + [SWAPPED] * 3))
        self.assertGreaterEqual(stats["broke"]["pane aaaaaa frame"]["back"], 1)

    def test_one_skipped_tick_inside_a_move_is_the_same_move(self):
        steps = [[pane("pane_aaaaaa", x, 500), pane("pane_bbbbbb", 500 - x, 500)] for x in (200, 200, 400, 500)]
        self.assertEqual(smm.layout_stats(trace([BEFORE] * 2 + steps + [SWAPPED] * 3))["moved_after_commit"], 0)

    def test_what_moved_before_the_input_is_left_out(self):
        moved = trace([[pane("pane_aaaaaa", 100, 500)]] * 2 + [BEFORE[:1]] * 6 + [[pane("pane_aaaaaa", 500, 500)]] * 4, t0=100.0)
        stats = smm.layout_stats(moved, sent_host_s=100.0 + 7.5 * T / 1000)
        self.assertTrue(stats["aligned"])
        self.assertEqual(stats["moved_after_commit"], 0)
        self.assertAlmostEqual(stats["commit_ms"], 0.5 * T, places=0)

    def test_nothing_moved(self):
        stats = smm.layout_stats(trace([BEFORE] * 6))
        self.assertIsNone(stats["commit_ms"])
        self.assertEqual(stats["moved_after_commit"], 0)


class PixelTests(unittest.TestCase):
    def test_one_frame_to_the_final_picture(self):
        stats = smm.pixel_stats({"frames": [frame(-8), frame(8), frame(16, ob=0.4, cb=0.5)] + [frame(24 + 8 * i, ob=0.4, cb=0.5) for i in range(8)]})
        self.assertEqual((stats["pixel_after_commit"], stats["pixel_reversals"], stats["pixel_after_commit_ms"]), (0, 0, 0.0))

    def test_frames_still_off_the_final_picture_after_the_first_changed_one(self):
        shares = [0.5, 0.3, 0.1, 0.02, 0.0, 0.0]
        stats = smm.pixel_stats({"frames": [frame(8 * (i + 1), ob=0.4, of=s) for i, s in enumerate(shares)]})
        self.assertEqual(stats["pixel_after_commit"], 3)
        self.assertAlmostEqual(stats["pixel_after_commit_ms"], 24.0)
        self.assertEqual(stats["pixel_reversals"], 0)

    def test_a_share_that_rises_again_is_a_reversal(self):
        shares = [0.5, 0.1, 0.0, 0.3, 0.0, 0.0]
        stats = smm.pixel_stats({"frames": [frame(8 * (i + 1), cb=0.4, cf=s) for i, s in enumerate(shares)]})
        self.assertEqual(stats["pixel_reversals"], 1)
        self.assertEqual(stats["pixel_after_commit"], 3)


class MoveTests(unittest.TestCase):
    STRIP = {"sent_host_s": 100.0 + 2.5 * T / 1000, "first_change_ms": 8,
             "frames": [frame(-8)] + [frame(8 * (i + 1), ob=0.4, cb=0.4) for i in range(10)]}

    def test_a_clean_move_passes(self):
        row = smm.move(self.STRIP, trace([BEFORE] * 3 + [SWAPPED] * 8, t0=100.0), tabs_before=["t1", "t2"], tabs_after=["t2", "t1"])
        self.assertIsNone(row.get("error"))
        self.assertEqual(row["reloads"], 0)
        self.assertTrue(smm.verdict(smm.summarize([row, row]))["pass"])

    def test_a_tab_made_again_is_a_reload(self):
        row = smm.move(self.STRIP, trace([BEFORE] * 3 + [SWAPPED] * 8, t0=100.0), tabs_before=["t1", "t2"], tabs_after=["t2", "t9"])
        self.assertEqual(row["reloads"], 1)
        self.assertIn("reloads 1", smm.verdict(smm.summarize([row]))["failures"])
        expected = smm.move(self.STRIP, trace([BEFORE] * 3 + [SWAPPED] * 8, t0=100.0), tabs_before=["t1"], tabs_after=["t1", "t9"], expected_new=1)
        self.assertEqual(expected["reloads"], 0)

    def test_a_move_inside_one_layout_is_no_error_when_the_pixels_changed(self):
        row = smm.move(self.STRIP, trace([BEFORE] * 12, t0=100.0))
        self.assertIsNone(row.get("error"))
        self.assertIsNone(row["commit_ms"])

    def test_the_worst_round_fails_the_cell_and_the_table_names_it(self):
        held = [pane("pane_aaaaaa", 500, 500, cx=0), pane("pane_bbbbbb", 0, 500)]
        good = smm.move(self.STRIP, trace([BEFORE] * 3 + [SWAPPED] * 8, t0=100.0))
        bad = smm.move(self.STRIP, trace([BEFORE] * 3 + [held] * 3 + [SWAPPED] * 5, t0=100.0))
        summary = smm.summarize([good, bad])
        judged = smm.verdict(summary)
        self.assertFalse(judged["pass"])
        self.assertIn("moved_after_commit 1", judged["failures"])
        self.assertIn("content_off_pane 3", judged["failures"])
        text = smm.table({"cells": {"half-newtab": {"swap": summary}}, "verdicts": {"half-newtab": {"swap": judged}}})
        self.assertIn("FAIL", text)
        self.assertIn("half-newtab", text)

    def test_a_failed_round_fails_the_cell(self):
        self.assertFalse(smm.verdict(smm.summarize([{"error": "the gesture moved nothing"}]))["pass"])

    def test_partial_frames_are_not_judged_for_streaming_content(self):
        summary = {"rounds": 1, "failed": 0, **{key: 0 for key in smm.JUDGED}, "partial_frames": None}
        self.assertTrue(smm.verdict(summary, static=False)["pass"])
        self.assertFalse(smm.verdict(summary, static=True)["pass"])


if __name__ == "__main__":
    unittest.main()
