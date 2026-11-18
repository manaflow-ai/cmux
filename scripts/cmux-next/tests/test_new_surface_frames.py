#!/usr/bin/env python3
"""new_surface_frames.py and new_surface_screen.py: one Cmd-T or Cmd-N from the frames of the screen.

No app, no display, no fleet: the frames are rows in the form that the app's frame_strip writes, and the app is a
function that answers the tool's calls. So this proves the tool's own reading and its INVALID rules, not that a
recording on a Mac gives such rows.

    python3 -I scripts/cmux-next/tests/test_new_surface_frames.py
"""
import argparse
import contextlib
import io
import json
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True  # the imports leave no cache folder in the checkout
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import new_surface_frames as nsf  # noqa: E402
import new_surface_screen  # noqa: E402

STEP = 1000 / 120
OLD, NEW = (0, 0.3), (0.3, 0)  # a region as before the key, and as in the last picture
ROW_OLD, ROW_NEW = (0, 0.01), (0.01, 0)  # the window outside the pane: the same two
STILL = (0, 0)  # a region that the key does not change
# The name of the zero of a reply that says when its key went in (a test fails by its own rule when the reader has none).
ZERO_SENT = getattr(nsf, "ZERO_SENT", "the reader has no name for the zero of a key's send time")


def row(index, content, outside, blank=False, desync=False, strip=None, start=0.0):
    out = {"ms": round(start + STEP * index), "file": f"frame-{index + 2:03d}.png", "content_vs_before": content[0],
           "content_vs_final": content[1], "outside_vs_before": outside[0], "outside_vs_final": outside[1],
           "blank": blank, "desync": desync, "flatness": 0.5}
    if strip:
        out["strip_vs_before"], out["strip_vs_final"] = strip
    return out


# A key whose own work took no time: its opening marks start at the reply's zero. The app's reply has them before it.
AT_ZERO = [{"name": "cmdN.start", "ms": 0.0, "duration_ms": 0.0}, {"name": "newTab.open", "ms": 0.0, "duration_ms": 0.0}]


def take(pictures, capture="screencapturekit", spans=None, before=2, **fields):
    """A recording: `before` frames before the reply's zero (the app's rows start at the last one), then one frame
    of the display for each entry of `pictures` ((content, outside) or a dict of row()'s arguments)."""
    rows = [row(-index, OLD, ROW_OLD) for index in range(before, 0, -1)]
    for index, picture in enumerate(pictures):
        if picture is None:
            continue  # a frame that the recorder did not deliver
        rows.append(row(index + 1, **picture) if isinstance(picture, dict) else row(index + 1, *picture))
    return {"frames": rows, "capture": capture, "spans": AT_ZERO if spans is None else spans, "frame_count": len(rows),
            "mean_interval_ms": STEP, "strip_intermediate": 0.0, "lead_ms": 120.0, **fields}


class OneKeyTests(unittest.TestCase):
    def test_a_first_frame_that_is_the_last_picture_has_no_change_after_it(self):
        got = nsf.one_key(take([(NEW, ROW_NEW)] * 240), "n", asked_hz=120)
        self.assertEqual(got["invalid"], [])
        self.assertEqual([got[name]["frame"] for name in ("tab", "content_first", "content_final", "final")], [1, 1, 1, 1])
        self.assertEqual((got["content_first"]["ms"], got["first_is_final"], got["changes_after_content"]), (8, True, 0))
        self.assertEqual((got["frames_after_key"], got["frames_not_delivered"], got["refresh_ms"]), (240, 0, round(STEP, 3)))
        self.assertEqual(got["pictures"], {"before": "frame-001.png", "last": "frame-242.png", "tab": "frame-003.png",
                                           "content_first": "frame-003.png", "content_final": "frame-003.png", "final": "frame-003.png"})

    def test_each_frame_that_changes_after_the_first_content_is_listed_with_its_regions(self):
        # Frame 3: the page, not yet as it stays. Frame 4: the page as it stays, the sidebar still old. Frame 5: all.
        pictures = [(OLD, ROW_OLD)] * 2 + [((0.3, 0.05), ROW_OLD), (NEW, ROW_OLD)] + [(NEW, ROW_NEW)] * 236
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual(got["invalid"], [])
        self.assertEqual([got[name]["frame"] for name in ("content_first", "content_final", "tab", "final")], [3, 4, 5, 5])
        self.assertEqual((got["first_is_final"], got["changes_after_content"]), (False, 1))
        self.assertEqual(got["after_content"], [{"frames": [4, 4], "ms": [33, 33], "count": 1, "file": "frame-006.png",
                                                 "state": {"content": "final", "outside": "before"}}])
        self.assertEqual(got["regions"]["content"]["between_frames"], 1)
        self.assertEqual(got["pictures"]["changed_0"], "frame-006.png")

    def test_a_content_first_frame_that_is_not_the_last_picture_is_not_final(self):
        # No LATER frame is off the last picture in these two, so `changes_after_content` is 0 in both. The
        # content_first frame itself is off it: the page half drawn in it, or the sidebar still old in it.
        half_drawn = [(OLD, ROW_OLD)] * 2 + [((0.3, 0.05), ROW_NEW)] + [(NEW, ROW_NEW)] * 237
        sidebar_late = [(OLD, ROW_OLD)] * 2 + [(NEW, ROW_OLD)] + [(NEW, ROW_NEW)] * 237
        for name, pictures in (("half drawn", half_drawn), ("sidebar late", sidebar_late)):
            with self.subTest(name):
                got = nsf.one_key(take(pictures), "n", asked_hz=120)
                self.assertEqual(got["invalid"], [])
                self.assertEqual([got[at]["frame"] for at in ("content_first", "final")], [3, 4])
                self.assertEqual((got["changes_after_content"], got["first_is_final"]), (0, False))
                self.assertIs(got["content_first_is_last_picture"], False)
        whole = nsf.one_key(take([(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        self.assertEqual((whole["content_first"]["frame"], whole["content_first_is_last_picture"], whole["first_is_final"]),
                         (3, True, True))

    def test_a_blank_frame_is_not_the_first_content(self):
        pictures = [dict(content=(0.9, 0.9), outside=ROW_NEW, blank=True)] + [(NEW, ROW_NEW)] * 239
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual((got["content_first"]["frame"], got["blank_frames"], got["tab"]["frame"]), (2, 1, 1))

    def test_a_second_key_is_counted_from_the_time_at_which_it_was_due(self):
        # The first key's page and row are on the screen at 100 ms; the second key's row comes 3 frames after it.
        half = (0.01, 0.01)  # one new row of two: unlike before, unlike the last picture
        pictures = [(OLD, ROW_OLD)] * 3 + [(NEW, half)] * 11 + [(NEW, ROW_NEW)] * 240
        got = nsf.one_key(take(pictures), "n", gap_ms=100, asked_hz=120)
        self.assertEqual(got["invalid"], [])
        self.assertEqual((got["content_first"], got["content_final"]["frame"]), ({"frame": 1, "ms": 8, "file": "frame-015.png"}, 1))
        self.assertEqual((got["tab"]["frame"], got["tab"]["ms"], got["final"]["frame"]), (3, 25, 3))
        self.assertEqual((got["changes_after_content"], got["after_content"][0]["state"]), (1, {"content": "final", "outside": "between"}))

    def test_a_caret_is_named_and_is_no_change(self):
        caret = (0.3, 0.0003)
        pictures = ([(NEW, ROW_NEW)] * 60 + [(caret, ROW_NEW)] * 60) * 2
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual(got["blinks"], [{"region": "content", "period_ms": 1000, "share": 0.0003, "phases": 4}])
        self.assertEqual((got["first_is_final"], got["changes_after_content"], got["invalid"]), (True, 0, []))

    def test_a_small_change_that_stays_is_not_a_caret(self):
        pictures = [((0.3, 0.0003), ROW_NEW)] * 100 + [(NEW, ROW_NEW)] * 140
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual(got["blinks"], [])
        self.assertEqual((got["content_first"]["frame"], got["content_final"]["frame"], got["changes_after_content"]), (1, 101, 99))

    def test_frames_from_one_window_are_invalid(self):
        got = nsf.one_key(take([(NEW, ROW_NEW)] * 240, capture="window_list"), "n")
        self.assertEqual([reason.split(":")[0] for reason in got["invalid"]], ["capture"])

    def test_a_take_that_ends_before_one_second_after_the_first_content_is_invalid(self):
        got = nsf.one_key(take([(OLD, ROW_OLD)] * 150 + [(NEW, ROW_NEW)] * 90), "n", asked_hz=120)
        self.assertEqual(got["content_first"]["frame"], 151)
        self.assertEqual(got["invalid"], ["frames: the take ended before 1 s after content_first (742 ms after it)"])

    def test_a_region_that_changes_at_the_end_of_the_take_has_no_final_frame(self):
        got = nsf.one_key(take([(NEW, ROW_NEW)] * 200 + [((0.3, 0.05), ROW_NEW)] * 39 + [(NEW, ROW_NEW)]), "n", asked_hz=120)
        self.assertEqual((got["final"], got["content_final"]), (None, None))
        self.assertEqual(got["invalid"], ["frames: content still changed at the recording's last frame"])

    def test_a_take_with_no_content_is_invalid(self):
        got = nsf.one_key(take([(STILL, ROW_NEW)] * 240), "n", asked_hz=120)
        self.assertEqual((got["content_first"], [reason.split(":")[0] for reason in got["invalid"]]), (None, ["content"]))
        self.assertEqual((got["first_is_final"], got["changes_after_content"]), (False, None))

    def test_the_tab_of_a_new_tab_is_read_from_the_strip_or_said_to_be_unknown(self):
        steady = [(NEW, STILL)] * 240
        self.assertEqual(nsf.one_key(take(steady), "t")["tab_source"], "derived: the strip changed in one step with the content")
        self.assertEqual(nsf.one_key(take(steady), "t")["tab"]["frame"], 1)
        slid = nsf.one_key(take(steady, strip_intermediate=5.0), "t")
        self.assertEqual((slid["tab"], slid["tab_source"].split(":")[0], slid["invalid"]), (None, "not known", []))
        apart = nsf.one_key(take([dict(content=NEW, outside=STILL, desync=True)] + steady[1:]), "t")
        self.assertEqual(apart["tab"], None)
        with_strip = [dict(content=NEW, outside=STILL, strip=(0, 0.2))] * 2 + [dict(content=NEW, outside=STILL, strip=(0.2, 0))] * 238
        got = nsf.one_key(take(with_strip), "t")
        self.assertEqual((got["tab"]["frame"], got["tab_source"], got["final"]["frame"], got["changes_after_content"]), (3, "the rows' strip numbers", 3, 1))

    def test_a_strip_that_the_rows_do_not_carry_and_that_moved_is_a_change_after_the_first_content(self):
        # A build whose rows carry no strip numbers. Its reply counts 24 frames after the key in which the strip is at
        # neither picture, and the page is whole in frame 4. The 3 rows before that frame and that frame itself can be
        # 4 of the 24: 20 at least come after the first content. Which frames they are is not known.
        pictures = [(OLD, STILL)] * 3 + [(NEW, STILL)] * 237
        got = nsf.one_key(take(pictures, strip_intermediate=24.0), "t", asked_hz=120)
        self.assertEqual((got["invalid"], got["content_first"]["frame"]), ([], 4))
        self.assertIs(got.get("whole_window"), False)
        self.assertEqual((got["changes_after_content"], got["first_is_final"], got["content_first_is_last_picture"], got["final"]),
                         (20, False, None, None))
        self.assertEqual((got["after_content"][-1]["state"], got["after_content"][-1]["count"], got["after_content"][-1]["frames"]),
                         ({"strip": "between"}, 20, None))
        self.assertNotIn(None, got["pictures"].values())

    def test_a_strip_that_moved_for_no_more_frames_than_came_to_the_first_content_leaves_first_is_final_not_known(self):
        # 2 frames of the strip at neither picture, 3 rows before the first content: each of the 2 can be before it.
        pictures = [(OLD, STILL)] * 3 + [(NEW, STILL)] * 237
        got = nsf.one_key(take(pictures, strip_intermediate=2.0), "t", asked_hz=120)
        self.assertEqual((got.get("whole_window"), got["changes_after_content"], got["first_is_final"], got["final"], got["invalid"]),
                         (False, 0, None, None, []))

    def test_the_first_keys_strip_frames_of_a_gap_row_are_not_changes_after_the_second_key(self):
        # No strip numbers, 2 keys 100 ms apart. After the first Cmd-T the strip has 1 new tab: it is at neither picture (no
        # new tab before, 2 at the end) in each frame up to the second key. The reply counts those frames; no judged row is one.
        got = nsf.one_key(take([(NEW, STILL)] * 252, strip_intermediate=8.0), "t", gap_ms=100, asked_hz=120)
        self.assertEqual((got["changes_after_content"], got["first_is_final"], got.get("whole_window"), got["invalid"]), (0, None, False, []))
        # 20 such frames with 12 rows before the second key: 8 are after it, less the row of the first content.
        got = nsf.one_key(take([(NEW, STILL)] * 252, strip_intermediate=20.0), "t", gap_ms=100, asked_hz=120)
        self.assertEqual((got["changes_after_content"], got["first_is_final"]), (7, False))

    def test_a_case_and_its_line_name_the_zero_of_its_rows(self):
        marks = nsf.one_key(take([(NEW, ROW_NEW)] * 240), "n", asked_hz=120)
        sent = nsf.one_key(take([(NEW, ROW_NEW)] * 240, before_send_ms=4.0), "n", asked_hz=120)
        self.assertEqual((marks["invalid"], sent["invalid"]), ([], []))
        case = nsf.summarize([marks, marks])
        self.assertEqual(case.get("zero"), [nsf.ZERO])
        self.assertIn(f"; zero: {nsf.ZERO}", nsf.cell(case))
        both = nsf.summarize([marks, sent])
        self.assertEqual(both.get("zero"), sorted([nsf.ZERO, ZERO_SENT]))
        self.assertIn("; ROWS OF 2 ZEROS (their times are not one table): ", nsf.cell(both))

    def test_a_frame_with_the_page_new_and_the_strip_old_is_a_change_with_its_frame(self):
        # No strip numbers. The reply's rows say `desync` in the first 3 frames: the page is there, the strip is the old one.
        pictures = [dict(content=NEW, outside=STILL, desync=True)] * 3 + [(NEW, STILL)] * 237
        got = nsf.one_key(take(pictures), "t", asked_hz=120)
        self.assertEqual((got.get("whole_window"), got["content_first_is_last_picture"], got["first_is_final"], got["changes_after_content"]),
                         (False, False, False, 2))
        self.assertEqual(got["after_content"], [{"frames": [2, 3], "ms": [17, 25], "count": 2, "file": "frame-004.png",
                                                 "state": {"content": "final", "outside": "final", "strip": "before"}}])

    def test_the_whole_window_is_seen_with_the_strips_numbers_or_when_the_strip_changed_in_one_step_with_the_content(self):
        with_strip = nsf.one_key(take([dict(content=NEW, outside=STILL, strip=(0.2, 0))] * 240), "t", asked_hz=120)
        in_one_step = nsf.one_key(take([(NEW, STILL)] * 240), "t", asked_hz=120)
        self.assertEqual([(got.get("whole_window"), got["first_is_final"]) for got in (with_strip, in_one_step)], [(True, True)] * 2)

    def test_a_case_says_in_how_many_rows_the_whole_window_is_seen(self):
        seen = nsf.one_key(take([(NEW, STILL)] * 240), "t", asked_hz=120)
        hidden = nsf.one_key(take([(NEW, STILL)] * 240, strip_intermediate=24.0), "t", asked_hz=120)
        summary = nsf.summarize([seen, hidden])
        self.assertEqual((summary.get("whole_window"), summary["first_is_final"]), (1, 1))
        self.assertIn("whole window seen 1/2", nsf.cell(summary))

    def test_a_frame_number_is_the_displays_also_when_frames_were_not_delivered(self):
        pictures = [(OLD, ROW_OLD), None, None, None, None, (NEW, ROW_NEW)] + [(NEW, ROW_NEW)] * 234
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual((got["content_first"]["frame"], got["content_first"]["ms"], got["frames_not_delivered"]), (6, 50, 4))
        # The 4 frames with no row are directly before the first content: the page can have come in one of them.
        self.assertEqual((got["first_is_final"], got["frames_not_seen_from_content"], got["invalid"]), (None, 4, []))

    def test_a_frame_number_counts_the_frames_before_the_first_row(self):
        # No row for the first 5 frames of the display after the key; the first row has the page.
        got = nsf.one_key(take([None] * 5 + [(NEW, ROW_NEW)] * 235), "n", asked_hz=120)
        self.assertEqual((got["content_first"]["frame"], got["content_first"]["ms"], got["frames_not_delivered"]), (6, 50, 5))
        self.assertEqual((got["tab"]["frame"], got["final"]["frame"], got["first_is_final"], got["invalid"]), (6, 6, None, []))

    def test_a_frame_with_no_row_after_the_first_content_makes_first_is_final_not_known(self):
        got = nsf.one_key(take([(NEW, ROW_NEW)] * 10 + [None] + [(NEW, ROW_NEW)] * 229), "n", asked_hz=120)
        self.assertEqual((got["first_is_final"], got["frames_not_seen_from_content"], got["changes_after_content"]), (None, 1, 0))
        self.assertEqual(nsf.summarize([got])["first_is_final"], 0)
        self.assertEqual(nsf.summarize([got])["first_is_final_not_known"], 1)

    def test_the_refresh_is_the_rows_own_when_the_asked_rate_is_not_theirs(self):
        rows = take([(NEW, ROW_NEW)] * 240)
        got = nsf.one_key(rows, "n", asked_hz=60)
        self.assertEqual(got["refresh_ms"], got["refresh_measured_ms"])  # the rows' own: 60 Hz was asked, 120 came
        self.assertAlmostEqual(got["refresh_ms"], STEP, delta=0.05)  # the rows' times are whole ms
        self.assertEqual((got["content_first"]["frame"], got["frames_not_delivered"]), (1, 0))

    def test_rows_that_come_slower_than_the_asked_display_are_invalid(self):
        # A recorder that gives each second frame of a 120 Hz display: its frame numbers would be half of the true ones.
        rows = take([(NEW, ROW_NEW)] * 240)
        for frame in rows["frames"]:
            frame["ms"] *= 2
        got = nsf.one_key(rows, "n", asked_hz=120)
        self.assertEqual([reason.split(":")[0] for reason in got["invalid"]], ["refresh"])
        self.assertEqual(nsf.one_key(rows, "n")["invalid"], [])  # no asked rate: the rows' own step, with no sign

    def test_the_zero_is_the_start_of_the_keys_own_work(self):
        # The app's reply: its zero is the END of the key's work, so `cmdN.start` began 33 ms before it, and its rows
        # start at the last frame before that zero. The page is in the frame 42 ms after the reply's zero.
        marks = [{"name": "cmdN.start", "ms": -33.0, "duration_ms": 33.0}, {"name": "newTab.open", "ms": -20.0, "duration_ms": 9.0}]
        reply = take([(OLD, ROW_OLD)] * 4 + [(NEW, ROW_NEW)] * 236, spans=marks, before=1)
        got = nsf.one_key(reply, "n", asked_hz=120)
        self.assertEqual((got["key_work_ms"], got["zero"], got["invalid"]), (33.0, nsf.ZERO, []))
        self.assertEqual(got["content_first"], {"frame": 9, "ms": 75.0, "file": "frame-007.png"})
        # The app's `before` row is 25 ms after the key: frame 3. The 2 frames before it have no row.
        self.assertEqual((got["frames_after_key"], got["frames_not_delivered"], got["first_is_final"]), (241, 3, True))
        self.assertEqual(got["pictures"]["before"], "frame-001.png")
        at_zero = nsf.one_key(take([(OLD, ROW_OLD)] * 4 + [(NEW, ROW_NEW)] * 236, before=1), "n", asked_hz=120)
        self.assertEqual((at_zero["key_work_ms"], at_zero["content_first"]["frame"], at_zero["content_first"]["ms"]), (0.0, 5, 42))

    def test_the_zero_of_a_new_tab_is_its_earliest_opening_mark(self):
        marks = [{"name": "newTab.open", "ms": -3.0}, {"name": "newTab.take", "ms": -9.0}, {"name": "cmdN.start", "ms": -50.0}]
        got = nsf.one_key(take([(NEW, STILL)] * 240, spans=marks), "t", asked_hz=120)
        self.assertEqual((got["key_work_ms"], got["invalid"]), (9.0, []))

    def test_a_second_key_is_counted_from_its_due_time_after_the_first_keys_zero(self):
        # The first key's work took 30 ms: the second key was due 100 ms after the first key, 70 ms after the reply's zero.
        marks = [{"name": "cmdN.start", "ms": -30.0}, {"name": "cmdN.start", "ms": 100.0}]
        got = nsf.one_key(take([(NEW, ROW_NEW)] * 252, spans=marks), "n", gap_ms=100, asked_hz=120)
        self.assertEqual((got["key_work_ms"], got["invalid"]), (30.0, []))
        self.assertEqual(got["content_first"], {"frame": 1, "ms": 5.0, "file": "frame-011.png"})

    def test_a_reply_with_no_opening_mark_has_no_zero(self):
        got = nsf.one_key(take([(NEW, ROW_NEW)] * 240, spans=[{"name": "newTab.open", "ms": 0.0}]), "n", asked_hz=120)
        self.assertEqual((got["key_work_ms"], got["zero"], [reason.split(":")[0] for reason in got["invalid"]]), (None, None, ["zero"]))

    def test_the_zero_is_the_time_the_key_went_in_when_the_reply_says_it(self):
        # The reply says that the key went in 40 ms before its zero; `cmdN.start` began 7 ms after the key went in.
        # The page is in the frame 42 ms after the reply's zero: 82 ms after the key, not 75 ms after the mark.
        marks = [{"name": "cmdN.start", "ms": -33.0, "duration_ms": 33.0}]
        reply = take([(OLD, ROW_OLD)] * 4 + [(NEW, ROW_NEW)] * 236, spans=marks, before=1, before_send_ms=40.0)
        got = nsf.one_key(reply, "n", asked_hz=120)
        self.assertEqual((got["key_work_ms"], got["zero"], got["invalid"]), (40.0, ZERO_SENT, []))
        self.assertEqual(got["content_first"], {"frame": 10, "ms": 82.0, "file": "frame-007.png"})
        self.assertNotEqual(ZERO_SENT, nsf.ZERO)
        # The key's send time is the zero also when the spans have no opening mark of the key.
        bare = nsf.one_key(take([(NEW, ROW_NEW)] * 240, spans=[], before_send_ms=12.5), "n", asked_hz=120)
        self.assertEqual((bare["key_work_ms"], bare["zero"], bare["invalid"]), (12.5, ZERO_SENT, []))
        # A reply with no such number (an older build's), or with one that is no time, has the mark's zero.
        for value in (None, True, -1.0, "40"):
            old = nsf.one_key({**reply, "before_send_ms": value}, "n", asked_hz=120)
            self.assertEqual((old["key_work_ms"], old["zero"]), (33.0, nsf.ZERO), value)

    def test_a_region_that_goes_back_to_the_picture_before_the_key_is_invalid(self):
        # Frame 2: a terminal's cursor changes 0.02 % of the content area. Frames 3 to 19: as before the key. Frame 20: the page.
        pictures = [(OLD, ROW_OLD), ((0.0002, 0.3), ROW_OLD)] + [(OLD, ROW_OLD)] * 17 + [(NEW, ROW_NEW)] * 221
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual((got["content_first"]["frame"], got["content_first_vs_before"]), (2, 0.0002))
        self.assertEqual(got["invalid"], ["back: content went back to the picture before the key at frame 3, after its first "
                                          "change at frame 2: that change was not the key's"])
        self.assertEqual(nsf.one_key(take([(NEW, ROW_NEW)] * 240), "n", asked_hz=120)["content_first_vs_before"], 0.3)

    def test_one_small_change_that_goes_away_is_a_change_and_not_a_caret(self):
        # 3 phases: at the last picture, off it for 500 ms, at it again. A caret has 4 phases at least.
        pictures = [(NEW, ROW_NEW)] * 100 + [((0.3, 0.0003), ROW_NEW)] * 60 + [(NEW, ROW_NEW)] * 80
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual((got["blinks"], got["changes_after_content"], got["first_is_final"]), ([], 60, False))


class OpenedSinceTests(unittest.TestCase):
    def test_new_records_are_counted_also_when_the_apps_list_is_full(self):
        full = [{"spare": True, "ms": float(n)} for n in range(64)]
        self.assertEqual(nsf.opened_since(full[:3], full[:5]), 2)
        self.assertEqual(nsf.opened_since(full, full), 0)
        # The app keeps its newest 64: 2 new records push the 2 oldest out, and the list is as long as before.
        self.assertEqual(nsf.opened_since(full, full[2:] + [{"spare": True, "ms": 64.0}, {"spare": False, "ms": 65.0}]), 2)
        self.assertEqual(nsf.opened_since([], []), 0)


class InputProofTests(unittest.TestCase):
    MARKS = [{"name": "cmdN.start", "ms": 0.0}, {"name": "newTab.open", "ms": 2.0}, {"name": "cmdN.start", "ms": 103.0}]

    def test_two_keys_two_openings(self):
        self.assertEqual(nsf.input_proof("n", 2, 2, 2, self.MARKS), ([], [0.0, 103.0]))

    def test_one_wrong_count_is_a_fault(self):
        self.assertEqual(nsf.input_proof("n", 2, 1, 2, self.MARKS)[0], ["input: 2 keys sent, the app recorded 1 openings"])
        self.assertEqual(nsf.input_proof("n", 2, 2, 1, self.MARKS)[0], ["input: 2 keys sent, 1 more workspaces after them"])
        self.assertEqual(nsf.input_proof("t", 2, 2, 2, self.MARKS)[0], ["input: 2 keys sent, 1 `newTab.open` marks"])


class FakeApp:
    """The app's answers to the tool's calls: each frame_strip opens `opens` tabs or workspaces for its keys."""

    def __init__(self, folder, pictures, opens=None, engine="cef", workspaces=3, work=0.0, sent=None):
        self.folder, self.pictures, self.opens, self.engine = folder, pictures, opens, engine
        self.workspaces, self.tabs, self.openings, self.calls, self.closed, self.newest = workspaces, 1, [], [], [], []
        # `work`: the ms of each key's own work (the reply's zero is its end). `limit`: the records that the app keeps.
        # `sent`: a build whose reply says how long before its zero the first key went in (`before_send_ms`), and
        # whose later key is due from that time.
        self.work, self.limit, self.recorded, self.sent = work, None, 0, sent
        # `slid`: the reply's count of frames in which the strip is at neither picture (its rows carry no strip numbers).
        self.slid = 0.0
        # `late`: the numbers of the frame_strip calls whose reply is the control's `timeout` while the app's call goes
        # on (`going`: its folder). That call ends in the tool's pause number `ends_in` after the reply (None: never),
        # with its last file. `overlaps`: the frame_strip calls that came while a call went on.
        # `refused`: the numbers of the frame_strip calls that the app refuses before a key goes in.
        self.late, self.going, self.ends_in, self.strips, self.paused, self.overlaps, self.folder_at_the_end = set(), None, None, 0, 0, 0, None
        self.refused = set()
        # `others`: the workspaces that another actor opens in the first pause of a call that goes on.
        self.others = 0

    def pause(self, _seconds):
        """The tool's pause. No clock: the app's call that goes on ends in the pause number `ends_in`."""
        if not self.going:
            return
        self.paused += 1
        if self.paused == 1 and self.others:
            self.workspaces += self.others
            self.newest += ["n"] * self.others
        if self.paused == self.ends_in:
            self.folder_at_the_end = os.path.isdir(self.going)
            os.makedirs(self.going, exist_ok=True)
            Path(self.going, "strip.png").write_bytes(b"png")
            self.going, self.paused = None, 0

    def terminal_tab(self):
        self.tabs += 1
        self.newest.append("t")

    def close_new(self, count):
        """Cmd-W `count` times: the newest thing closes each time (a new workspace with its one tab, or a tab)."""
        self.closed.append(count)
        for _ in range(count):
            if self.newest and self.newest.pop() == "n":
                self.workspaces -= 1
            else:
                self.tabs -= 1

    def tools(self):
        return {"spare_ready": lambda: True, "terminal_tab": self.terminal_tab, "close_new": self.close_new}

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        action = params.get("action")
        self.calls.append((method, action))
        if method == "snapshot.get":
            return {"topology": {"workspaces": [{"id": str(n)} for n in range(self.workspaces)]}}
        if method == "debug.cef":
            return {"state": "ready", "unavailable": None, "default_engine": "cef"}
        if method == "debug.agent_pane":
            return {"engine": self.engine} if action == "engine" else {"error": "the focused pane shows no agent page"}
        if action == "state":
            return {"spares": [{"ready": True}], "openings": list(self.openings)}
        if action == "switch_and_type":
            return {"tabs": [{"id": str(n)} for n in range(self.tabs)]}
        if action == "frame_strip":
            self.strips += 1
            self.overlaps += 1 if self.going else 0
            if self.strips in self.refused:
                return {"error": "no window"}  # the app's refusal before a key goes in
            keys = params.get("repeat", 1)
            opened = keys if self.opens is None else self.opens
            for _ in range(opened):
                self.recorded += 1
                self.openings.append({"spare": True, "ms": 1000.0 + self.recorded})
            if self.limit:
                self.openings = self.openings[-self.limit:]
            self.newest += [params["key"]] * opened
            if params["key"] == "n":
                self.workspaces += opened
            else:
                self.tabs += opened
            if self.strips in self.late:
                # The keys went in; the app still compares and writes its frames when the control's limit ends the wait.
                self.going, self.paused = params["dir"], 0
                os.makedirs(params["dir"], exist_ok=True)
                return {"error": {"code": "timeout", "message": "debug.new_tab did not finish within 14999 ms",
                                  "data": {"deadline_ms": 14999, "method": "debug.new_tab", "not_run": False, "state": "in_progress"}}}
            # The first key's mark starts `work` before the reply's zero; the second key's timer starts at that zero.
            reply = take(self.pictures, spans=[{"name": "cmdN.start" if params["key"] == "n" else "newTab.open",
                                                "ms": 100.0 * n - (self.sent or 0.0) if n else -self.work, "duration_ms": 1.0} for n in range(keys)])
            if self.sent is not None:
                reply["before_send_ms"] = self.sent
            reply["strip_intermediate"] = self.slid
            os.makedirs(params["dir"], exist_ok=True)
            for frame in reply["frames"]:
                Path(params["dir"], frame["file"]).write_bytes(b"png")
            self.strip = params
            return reply
        return {}


def options(folder, **changed):
    fields = dict(out=folder, socket="no socket", keys="n,t", gaps="0", runs=2, duration_ms=2000.0, scale=1.0, tolerance=nsf.TOLERANCE,
                  workspaces=0, live_shells=8, page_url="http://127.0.0.1:9/", seed_deadline=1.0, page_watch=0, keep_keys=1,
                  screen_tgz=None, display="ready 7 8.33 main=7", display_hz=120.0, build=None, page_engine="cef", split=1,
                  json=os.path.join(folder, "report.json"))
    return argparse.Namespace(**{**fields, **changed})


class ScreenTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="new-surface-screen-test-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.folder, ignore_errors=True))

    def run_mode(self, app, **changed):
        report = new_surface_screen.Screen(options(self.folder, **changed), app.rpc, app.tools(), sleep=app.pause,
                                           make_session=self.maker(app)).run()
        return report, app.closed

    def maker(self, app):
        def make(socket_path, count, live, url, deadline, out):
            app.workspaces += count
            return {"asked_more": count, "live_shells": live, "maker_exit": 0, "maker_said_made": count, "seed_s": 0.0}
        return make

    def test_each_case_has_its_rows_its_numbers_and_its_pictures(self):
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        report, closed = self.run_mode(app, gaps="0,100", screen_tgz=os.path.join(self.folder, "kept.tgz"))
        self.assertEqual(sorted(report["cases"]), ["cmd-n/100 ms after a key", "cmd-n/idle", "cmd-t/100 ms after a key", "cmd-t/idle"])
        self.assertEqual([(case["n"], case["valid"], case["first_is_final"]) for case in report["cases"].values()], [(2, 2, 2)] * 4)
        self.assertEqual(report["cases"]["cmd-n/idle"]["content_first"], {"frame": {"p50": 1, "max": 1}, "ms": {"p50": 8, "max": 8}})
        # Each recording's new workspaces are closed again; a Cmd-T's new tabs, then the terminal tab that it started from.
        self.assertEqual(closed, [1, 1, 2, 2, 1, 1, 1, 1, 2, 1, 2, 1])
        self.assertEqual((app.tabs, app.workspaces), (1, 3))
        self.assertEqual([row.get("tabs_before") or row.get("workspaces_before") for row in report["rows"]], [3, 3, 3, 3, 2, 2, 2, 2])
        self.assertEqual((app.strip["above"], app.strip["repeat"], app.strip["repeat_interval_ms"], app.strip["duration_ms"]), (True, 2, 100.0, 2100.0))
        self.assertEqual(app.strip["capture"], "screencapturekit")  # asked for by name: never the window list by the app's choice
        self.assertEqual([row["page_engine"] for row in report["rows"]], ["cef"] * 8)
        self.assertEqual(report["rows"][2]["second_key_late_ms"], 0.0)
        with tarfile.open(os.path.join(self.folder, "kept.tgz")) as archive:
            names = sorted(archive.getnames())
        self.assertIn("new-surface-screen/report.json", names)
        self.assertIn("new-surface-screen/cmd-n-idle-0-content_first-frame-003.png", names)
        self.assertNotIn("new-surface-screen/cmd-n-idle-1-content_first-frame-003.png", names)  # --keep-keys 1, no change
        self.assertEqual(json.loads(Path(self.folder, "report.json").read_text())["display_hz_asked"], 120.0)

    def test_a_key_that_opened_nothing_is_an_invalid_row(self):
        report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240, opens=1), keys="n", gaps="100", runs=1)
        self.assertEqual(report["rows"][0]["invalid"], ["input: 2 keys sent, the app recorded 1 openings",
                                                        "input: 2 keys sent, 1 more workspaces after them"])
        self.assertEqual((report["cases"]["cmd-n/100 ms after a key"]["valid"], report["cases"]["cmd-n/100 ms after a key"]["invalid"]), (0, ["input"]))

    def test_a_page_in_another_engine_is_an_invalid_row(self):
        report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240, engine="webkit"), keys="t", runs=1)
        self.assertEqual(report["rows"][0]["invalid"], ["engine: the page ran in webkit, cef was asked"])

    def late(self, ends_in, **changed):
        """A run of 2 cases of 3 rows whose first frame_strip call answers `timeout` while the app's call goes on for
        `ends_in` of the tool's pauses (None: it does not end)."""
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        app.late, app.ends_in = {1}, ends_in
        report, _ = self.run_mode(app, **{"runs": 3, **changed})
        return app, report

    def test_after_a_timeout_reply_no_key_goes_in_before_the_apps_call_is_at_its_end(self):
        app, _ = self.late(3)
        self.assertEqual(app.overlaps, 0)  # a key in that time shares the app's one list of marks with the old call

    def test_the_folder_of_a_call_that_goes_on_stays_until_the_call_is_at_its_end(self):
        app, _ = self.late(3)
        self.assertIs(app.folder_at_the_end, True)  # the app still writes its frames into it

    def test_a_timeout_reply_ends_its_case_and_the_next_case_has_its_rows(self):
        app, report = self.late(3)
        first, second = report["cases"]["cmd-n/idle"], report["cases"]["cmd-t/idle"]
        self.assertEqual((first["n"], first["valid"], first["invalid"]), (1, 0, ["frame_strip"]))
        self.assertEqual(first.get("ended_early"), "after 1 of 3 rows: frame_strip answered `timeout` and the app's call went on")
        self.assertEqual(report["rows"][0].get("call_went_on"), {"ended": True, "pauses": 3})
        self.assertEqual((second["n"], second["valid"], second.get("ended_early")), (3, 3, None))
        self.assertEqual((app.strips, report.get("stopped")), (4, None))
        self.assertEqual((app.tabs, app.workspaces), (1, 3))  # the late call's new workspace is closed again

    def test_a_call_that_does_not_end_stops_the_run(self):
        app, report = self.late(None)
        self.assertEqual(app.strips, 1)  # no later key: each later row would share the marks and the processor
        self.assertEqual(report["rows"][0].get("call_went_on"), {"ended": False, "pauses": 240})
        self.assertEqual(list(report["cases"]), ["cmd-n/idle"])
        self.assertEqual(report.get("stopped"), "after cmd-n-idle-0: the app's frame_strip call did not end in 240 pauses of 0.5 s: no later recording")
        self.assertEqual(json.loads(Path(self.folder, "report.json").read_text()).get("stopped"), report.get("stopped"))

    def test_the_tool_sends_no_more_cmd_w_than_the_keys_that_it_sent(self):
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        app.late, app.ends_in, app.others = {1}, 3, 1
        _, closed = self.run_mode(app, keys="n", runs=1)
        self.assertEqual(closed, [1])  # the workspace that another actor opened while the call went on is not the tool's to close

    def test_an_old_last_file_in_a_rows_folder_is_not_the_end_of_a_call(self):
        # A run that died left its row's folder with its last file (the driver's --out has a fixed default).
        old = Path(self.folder, "cmd-n-idle-0")
        old.mkdir()
        Path(old, "strip.png").write_bytes(b"old")
        app, report = self.late(3)
        self.assertEqual((report["rows"][0].get("call_went_on"), app.overlaps), ({"ended": True, "pauses": 3}, 0))

    def test_a_stopped_run_has_an_exit_code_that_is_not_zero_and_its_last_line_says_stopped(self):
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            _, report = self.late(None)
        self.assertEqual(report.get("exit_code"), 3)
        self.assertIn("STOPPED after cmd-n-idle-0", said.getvalue().strip().splitlines()[-1])

    def test_a_run_that_was_not_stopped_has_the_exit_code_zero(self):
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240), keys="n", runs=1)
        self.assertEqual(report.get("exit_code"), 0)
        self.assertNotIn("STOPPED", said.getvalue())

    def test_an_error_reply_of_a_call_that_does_not_go_on_keeps_its_case_and_closes_nothing(self):
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        app.refused = {1}
        report, closed = self.run_mode(app, keys="n", runs=3)
        case = report["cases"]["cmd-n/idle"]
        self.assertEqual((case["n"], case["valid"], case.get("ended_early"), app.strips), (3, 2, None, 3))
        self.assertEqual(report["rows"][0]["invalid"], ['frame_strip: "no window"'])
        self.assertEqual((closed, app.tabs, app.workspaces), ([1, 1], 1, 3))  # no key went in: no Cmd-W for that row

    def test_the_session_is_made_to_the_asked_size_and_a_smaller_one_makes_each_row_invalid(self):
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        report, _ = self.run_mode(app, keys="t", runs=1, workspaces=400, live_shells=12)
        self.assertEqual((report["session"]["asked_more"], report["session"]["listed_by_the_app"], report["session"]["as_asked"]), (397, 400, True))
        self.assertEqual(report["rows"][0]["invalid"], [])
        short = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        report = new_surface_screen.Screen(options(self.folder, keys="t", runs=1, workspaces=400), short.rpc, short.tools(),
                                           sleep=lambda _: None, make_session=lambda *_: {"maker_exit": 1}).run()
        self.assertEqual(report["rows"][0]["invalid"], ["session: 400 workspaces asked, the app lists 3"])

    def test_a_row_counts_its_openings_when_the_apps_list_of_records_is_full(self):
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        app.openings = [{"spare": True, "ms": float(n)} for n in range(64)]
        app.limit = 64
        report, _ = self.run_mode(app, keys="n", gaps="0,100", runs=1)
        self.assertEqual([row["invalid"] for row in report["rows"]], [[], []])
        self.assertEqual([row["spare"] for row in report["rows"]], [[True], [True, True]])
        self.assertEqual(len(app.openings), 64)

    def test_the_marks_of_a_row_count_from_the_rows_zero(self):
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 252, work=30.0)
        report, _ = self.run_mode(app, keys="n", gaps="100", runs=1)
        row = report["rows"][0]
        # The second key's timer starts at the end of the first key's work: its opening begins 30 ms after its due time.
        self.assertEqual((row["key_work_ms"], row["opening_marks_ms"], row["second_key_late_ms"], row["invalid"]), (30.0, [0.0, 130.0], 30.0, []))
        self.assertEqual(report["cases"]["cmd-n/100 ms after a key"]["key_work_ms"], {"p50": 30.0, "max": 30.0})

    def test_a_later_key_of_a_reply_with_its_send_time_is_due_from_the_time_the_first_key_went_in(self):
        # The first key went in 35 ms before the reply's zero, its mark began 5 ms after that. The second key's
        # timer counts from the time the first key went in: its opening begins 100 ms after it, and is not late.
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 252, work=30.0, sent=35.0)
        report, _ = self.run_mode(app, keys="n", gaps="100", runs=1)
        row = report["rows"][0]
        self.assertEqual((row["key_work_ms"], row["zero"], row["opening_marks_ms"], row["second_key_late_ms"], row["invalid"]),
                         (35.0, ZERO_SENT, [5.0, 100.0], 0.0, []))

    def test_a_row_whose_first_content_frame_is_not_the_last_picture_keeps_its_pictures_and_says_so(self):
        # No frame AFTER the first content is off the last picture, so `changes_after_content` is 0. The first content
        # frame itself is off it (the sidebar still old in it): the row is not first-is-final, and a person must see it.
        sidebar_late = [(OLD, ROW_OLD)] * 2 + [(NEW, ROW_OLD)] + [(NEW, ROW_NEW)] * 237
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(FakeApp(self.folder, sidebar_late), keys="n", runs=2, keep_keys=0,
                                      screen_tgz=os.path.join(self.folder, "kept.tgz"))
        self.assertEqual([(row["changes_after_content"], row["first_is_final"], row["invalid"]) for row in report["rows"]], [(0, False, [])] * 2)
        with tarfile.open(os.path.join(self.folder, "kept.tgz")) as archive:
            names = archive.getnames()
        for run in (0, 1):
            self.assertIn(f"new-surface-screen/cmd-n-idle-{run}-content_first-frame-005.png", names)
            self.assertIn(f"new-surface-screen/cmd-n-idle-{run}-final-frame-006.png", names)
        lines = [line for line in said.getvalue().splitlines() if "-ROW cmd-n-idle-" in line]
        self.assertEqual([("first_is_final=False" in line, "changes_after_content=0" in line) for line in lines], [(True, True)] * 2)
        # A row that IS first-is-final and past `--keep-keys` keeps none, and its line says True.
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240), keys="n", runs=1, keep_keys=0)
        self.assertEqual((report["rows"][0].get("kept_pictures"), "first_is_final=True" in said.getvalue()), (None, True))

    def test_a_rows_line_says_that_the_strip_is_not_seen_and_the_row_keeps_its_pictures(self):
        # A build whose rows carry no strip numbers; the strip moved for 24 frames and the page is whole in frame 4.
        app = FakeApp(self.folder, [(OLD, STILL)] * 3 + [(NEW, STILL)] * 237)
        app.slid = 24.0
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(app, keys="t", runs=1, keep_keys=0, screen_tgz=os.path.join(self.folder, "kept.tgz"))
        row = report["rows"][0]
        self.assertEqual((row["invalid"], row.get("whole_window"), row["changes_after_content"], row["first_is_final"]), ([], False, 20, False))
        line = next(line for line in said.getvalue().splitlines() if "-ROW cmd-t-idle-0" in line)
        self.assertIn("whole_window=False", line)
        self.assertIn("whole window seen 0/1", said.getvalue())
        self.assertEqual(sorted(row["kept_pictures"]), ["before", "content_final", "content_first", "last"])

    def test_a_fresh_session_moves_the_tags_saved_state_aside(self):
        root = os.path.join(self.folder, "tags", "screen-test-tag")
        os.makedirs(os.path.join(root, "tui"))
        os.environ["BENCH_LAUNCH_STATE_BASE"] = self.folder
        self.addCleanup(os.environ.pop, "BENCH_LAUNCH_STATE_BASE", None)
        new_surface_screen.fresh_session("screen-test-tag")
        self.assertEqual((os.path.exists(root), os.path.isdir(os.path.join(root + ".bench-prev", "tui"))), (False, True))

    def fresh_session_of(self, bundle, running):
        """fresh_session with the bundle `bundle` in this test's folder, while the PIDs `running` run from it (a fake
        of the process read). Gives (the refusal's text or None, the teardowns that ran, the saved session moved)."""
        import bench_launch
        import tag_teardown
        root, app, ended = os.path.join(self.folder, "tags", "screen-test-tag"), os.path.join(self.folder, bundle), []
        os.makedirs(os.path.join(root, "tui"))
        os.makedirs(os.path.join(app, "Contents", "MacOS"))
        os.environ["BENCH_LAUNCH_STATE_BASE"] = self.folder
        self.addCleanup(os.environ.pop, "BENCH_LAUNCH_STATE_BASE", None)

        class Teardown:
            def __init__(self, path):
                self.path = path

            def end(self):
                ended.append(self.path)

        refusal = None
        with mock.patch.object(bench_launch, "bundle_pids", lambda path, inside: running), \
                mock.patch.object(tag_teardown, "TagTeardown", Teardown):
            try:
                new_surface_screen.fresh_session("screen-test-tag", app)
            except SystemExit as stop:
                refusal = str(stop.code)
        return refusal, ended, not os.path.exists(root)

    def test_a_fresh_session_ends_nothing_for_a_path_that_is_no_tagged_bundle(self):
        refusal, ended, moved = self.fresh_session_of("some-folder", [])
        self.assertEqual((ended, moved), ([], False))
        self.assertIn("expected a `cmux DEV <tag>.app` bundle", refusal)

    def test_a_fresh_session_ends_nothing_while_an_app_of_the_bundle_runs(self):
        refusal, ended, moved = self.fresh_session_of("cmux DEV screen-test-tag.app", [4242])
        self.assertEqual((ended, moved), ([], False))
        self.assertIn("tag-in-use", refusal)
        self.assertIn("pid 4242", refusal)

    def test_a_fresh_session_ends_nothing_for_a_bundle_of_another_tag(self):
        refusal, ended, moved = self.fresh_session_of("cmux DEV other.app", [])
        self.assertEqual((ended, moved), ([], False))
        self.assertIn("is not the tag of cmux DEV other.app (other)", refusal)

    def test_a_fresh_session_ends_the_bundles_left_processes_when_no_app_of_it_runs(self):
        refusal, ended, moved = self.fresh_session_of("cmux DEV screen-test-tag.app", [])
        self.assertEqual((refusal, ended, moved), (None, [os.path.realpath(os.path.join(self.folder, "cmux DEV screen-test-tag.app"))], True))

    def fresh_session_by_ps(self, given, runs_from, real=None, tag="screen-test-tag", bundle="cmux DEV screen-test-tag.app"):
        """fresh_session for the bundle at `<folder>/real/<bundle>`, asked by the path `given`, while the system's
        process list (a fake of `ps`'s OUTPUT: the search itself is the real one) has an app that runs from the
        bundle path `runs_from`, a daemon of another bundle and this test's own process. `real`: what the system gives
        as a path's real path (a Mac's `/private` before `/tmp` and `/var`). Gives (the refusal's text or None, the
        teardowns that ran, the saved session moved)."""
        import bench_launch
        import tag_teardown
        root, ended = os.path.join(self.folder, "tags", "screen-test-tag"), []
        os.makedirs(os.path.join(root, "tui"))
        os.makedirs(os.path.join(self.folder, "real", bundle, "Contents", "MacOS"))
        os.symlink(os.path.join(self.folder, "real"), os.path.join(self.folder, "link"))
        os.environ["BENCH_LAUNCH_STATE_BASE"] = self.folder
        self.addCleanup(os.environ.pop, "BENCH_LAUNCH_STATE_BASE", None)
        listed = "\n".join([f"  311 {self.folder}/real/cmux DEV other.app/Contents/Resources/bin/cmux-tui server",
                            f" 4242 {runs_from}/Contents/MacOS/cmux DEV screen-test-tag" if runs_from else "  312 /sbin/launchd",
                            f"{os.getpid():5d} {self.folder}/real/{bundle}/Contents/MacOS/this-test"]) + "\n"
        asked = []

        def ps(command, **_):
            asked.append(command)
            return mock.Mock(stdout=listed, returncode=0)

        class Teardown:
            def __init__(self, path):
                self.path = path

            def end(self):
                ended.append(self.path)

        refusal, true_path = None, os.path.realpath
        patches = [mock.patch.object(bench_launch.subprocess, "run", ps), mock.patch.object(tag_teardown, "TagTeardown", Teardown)]
        if real:
            patches.append(mock.patch.object(os.path, "realpath", lambda path, *a, **k: real(true_path(path))))
        with contextlib.ExitStack() as stack:
            for patch in patches:
                stack.enter_context(patch)
            try:
                new_surface_screen.fresh_session(tag, given)
            except SystemExit as stop:
                refusal = str(stop.code)
        self.assertTrue(asked and all(command[0] == "ps" for command in asked), asked)
        return refusal, ended, not os.path.exists(root)

    def test_a_fresh_session_sees_an_app_that_runs_from_the_path_as_given_through_a_link(self):
        bundle = "cmux DEV screen-test-tag.app"
        given = os.path.join(self.folder, "link", bundle)
        refusal, ended, moved = self.fresh_session_by_ps(given, runs_from=given)
        self.assertEqual((ended, moved), ([], False))
        self.assertIn("tag-in-use", refusal or "no refusal")
        self.assertIn("pid 4242", refusal)

    def test_a_fresh_session_sees_an_app_that_runs_from_the_real_path(self):
        bundle = "cmux DEV screen-test-tag.app"
        real = os.path.realpath(os.path.join(self.folder, "real", bundle))
        refusal, ended, moved = self.fresh_session_by_ps(os.path.join(self.folder, "link", bundle), runs_from=real)
        self.assertEqual((ended, moved), ([], False))
        self.assertIn("pid 4242", refusal or "no refusal")

    def test_a_fresh_session_sees_an_app_that_runs_from_the_real_path_with_no_private_before_it(self):
        # A Mac's real path of `/var/...` and `/tmp/...` begins with `/private`, and a process can list either.
        bundle = "cmux DEV screen-test-tag.app"
        plain = os.path.realpath(os.path.join(self.folder, "real", bundle))
        refusal, ended, moved = self.fresh_session_by_ps(os.path.join(self.folder, "link", bundle), runs_from=plain,
                                                         real=lambda path: "/private" + path)
        self.assertEqual((ended, moved), ([], False))
        self.assertIn("pid 4242", refusal or "no refusal")

    def test_a_fresh_session_with_no_app_of_the_bundle_in_the_process_list_ends_its_left_processes(self):
        # The list has a daemon of ANOTHER bundle and this test's own process from below the bundle: neither is an app of it.
        bundle = "cmux DEV screen-test-tag.app"
        refusal, ended, moved = self.fresh_session_by_ps(os.path.join(self.folder, "link", bundle), runs_from=None)
        self.assertEqual((refusal, ended, moved), (None, [os.path.realpath(os.path.join(self.folder, "real", bundle))], True))

    def test_a_fresh_session_moves_the_state_of_the_bundles_tag_for_a_tag_that_is_written_another_way(self):
        # `--tag "Screen Test Tag"` and the bundle `cmux DEV Screen Test Tag.app` are the tag `screen-test-tag`: its
        # state is under that name, not under the words as typed.
        bundle = "cmux DEV Screen Test Tag.app"
        refusal, ended, moved = self.fresh_session_by_ps(os.path.join(self.folder, "real", bundle), runs_from=None,
                                                         tag="Screen Test Tag", bundle=bundle)
        self.assertEqual((refusal, ended, moved), (None, [os.path.realpath(os.path.join(self.folder, "real", bundle))], True))


if __name__ == "__main__":
    unittest.main()
