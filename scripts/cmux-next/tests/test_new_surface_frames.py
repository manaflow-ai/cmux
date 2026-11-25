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
import subprocess
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


def take(pictures, capture="screencapturekit", spans=None, before=2, at_zero=False, **fields):
    """A recording: `before` frames before the reply's zero (the app's rows start at the last one), then one frame
    of the display for each entry of `pictures` ((content, outside) or a dict of row()'s arguments). The rows have
    no frame AT the reply's zero: the step over it is 2 frame times, and a reply whose zero is later than the key
    (the key's own work) then has a frame with no row after the key. `at_zero`: the display's frame at the zero has
    its row too (the old picture), so each frame from the key on has one."""
    rows = [row(-index, OLD, ROW_OLD) for index in range(before, 0, -1)] + ([row(0, OLD, ROW_OLD)] if at_zero else [])
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
        sent = nsf.one_key(take([(NEW, ROW_NEW)] * 240, before_send_ms=4.0, at_zero=True), "n", asked_hz=120)
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
        # The 4 frames with no row are directly before the first content: the page can have come in one of them,
        # 4 frame times before its row at most. The first frame is then no number: the row is INVALID.
        self.assertEqual((got["first_is_final"], got["frames_not_seen_from_content"]), (None, 4))
        self.assertEqual(got["invalid"], ["no-row: 4 of the 6 frames from the key to content_first have no row (frames 2, 3, 4, 5; the "
                                          "longest step between rows 42 ms): content_first can be at most 33.3 ms early"])

    def test_a_frame_number_counts_the_frames_before_the_first_row(self):
        # No row for the first 5 frames of the display after the key; the first row has the page.
        got = nsf.one_key(take([None] * 5 + [(NEW, ROW_NEW)] * 235), "n", asked_hz=120)
        self.assertEqual((got["content_first"]["frame"], got["content_first"]["ms"], got["frames_not_delivered"]), (6, 50, 5))
        self.assertEqual((got["tab"]["frame"], got["final"]["frame"], got["first_is_final"]), (6, 6, None))
        # The frame's number is the display's, and it is no proved first frame: the page can have come in each of the 5.
        self.assertEqual(got["first_frame_span"], {"frames": 6, "rows": 1, "no_row": 5, "no_row_frames": [1, 2, 3, 4, 5],
                                                   "longest_gap_ms": 50.0, "early_ms_at_most": 41.7})
        self.assertEqual([reason.split(":")[0] for reason in got["invalid"]], ["no-row"])

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
        # A recorder that gives each second frame of a 120 Hz display. The frame time stays the display's, so the
        # page's row is frame 2 and frame 1 has no row: the first frame is no number. (The part that moves is this
        # one row: its step is judged from 4 rows on, in FirstFrameSpanTests.)
        rows = take([(NEW, ROW_NEW)] * 240)
        for frame in rows["frames"]:
            frame["ms"] *= 2
        got = nsf.one_key(rows, "n", asked_hz=120)
        # No 8 steps of the rows come at the asked rate: the rows do not judge it, and that is a reason of its own.
        self.assertEqual([reason.split(":")[0] for reason in got["invalid"]], ["no-row", "display"])
        self.assertIn("display: the asked rate is not judged", got["invalid"][1])
        self.assertEqual((got["refresh_ms"], got["content_first"]["frame"], got["content_first"]["ms"]), (round(STEP, 3), 2, 16))
        self.assertAlmostEqual(got["refresh_measured_ms"], 2 * STEP, delta=0.1)
        self.assertEqual(nsf.one_key(rows, "n")["invalid"], [])  # no asked rate: the rows' own step, with no sign

    def test_the_zero_is_the_start_of_the_keys_own_work(self):
        # The app's reply: its zero is the END of the key's work, so `cmdN.start` began 33 ms before it, and its rows
        # start at the last frame before that zero. The page is in the frame 42 ms after the reply's zero.
        marks = [{"name": "cmdN.start", "ms": -33.0, "duration_ms": 33.0}, {"name": "newTab.open", "ms": -20.0, "duration_ms": 9.0}]
        reply = take([(OLD, ROW_OLD)] * 4 + [(NEW, ROW_NEW)] * 236, spans=marks, before=1)
        got = nsf.one_key(reply, "n", asked_hz=120)
        self.assertEqual((got["key_work_ms"], got["zero"]), (33.0, nsf.ZERO))
        self.assertEqual(got["content_first"], {"frame": 9, "ms": 75.0, "file": "frame-007.png"})
        # The app's `before` row is 25 ms after the key: frame 3. The 2 frames before it (inside the key's own work)
        # have no row, and this recording has none at the reply's zero (frame 4). Each of them is before a row that
        # still shows the old picture, so the page cannot have come earlier: the row is valid for its time, and it
        # says in how many frames a partial state is not seen.
        self.assertEqual((got["frames_after_key"], got["frames_not_delivered"], got["first_is_final"]), (241, 3, True))
        self.assertEqual((got["first_frame_span"]["no_row_frames"], got["first_frame_span"]["early_ms_at_most"]), ([1, 2, 4], 0.0))
        self.assertEqual((got["invalid"], got.get("partial_state_not_seen")), ([], 3))
        self.assertEqual(got["pictures"]["before"], "frame-001.png")
        at_zero = nsf.one_key(take([(OLD, ROW_OLD)] * 4 + [(NEW, ROW_NEW)] * 236, before=1), "n", asked_hz=120)
        self.assertEqual((at_zero["key_work_ms"], at_zero["content_first"]["frame"], at_zero["content_first"]["ms"]), (0.0, 5, 42))

    def test_the_zero_of_a_new_tab_is_its_earliest_opening_mark(self):
        marks = [{"name": "newTab.open", "ms": -3.0}, {"name": "newTab.take", "ms": -9.0}, {"name": "cmdN.start", "ms": -50.0}]
        got = nsf.one_key(take([(NEW, STILL)] * 240, spans=marks, at_zero=True), "t", asked_hz=120)
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
        self.assertEqual((got["key_work_ms"], got["zero"]), (40.0, ZERO_SENT))
        self.assertEqual(got["content_first"], {"frame": 10, "ms": 82.0, "file": "frame-007.png"})
        # The 3 frames inside the key's 40 ms and the one at the reply's zero have no row. Rows of the old picture
        # come after each of them (frames 6 to 9), so the first frame's time is proved.
        self.assertEqual((got["first_frame_span"]["no_row_frames"], got["invalid"], got.get("partial_state_not_seen")), ([1, 2, 3, 5], [], 4))
        self.assertNotEqual(ZERO_SENT, nsf.ZERO)
        # The key's send time is the zero also when the spans have no opening mark of the key.
        bare = nsf.one_key(take([(NEW, ROW_NEW)] * 240, spans=[], before_send_ms=12.5, at_zero=True), "n", asked_hz=120)
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
        # The records are a fact by kind (RecordsByKindTests): only a count that 2 keys cannot make is a fault.
        self.assertEqual(nsf.input_proof("n", 2, 1, 2, self.MARKS)[0], [])
        self.assertEqual(nsf.input_proof("n", 2, 5, 2, self.MARKS)[0], ["input: 2 keys sent, the app recorded 5 openings (0 to 4 are possible for Cmd-N)"])
        self.assertEqual(nsf.input_proof("n", 2, 2, 1, self.MARKS)[0], ["input: 2 keys sent, 1 more workspaces after them"])
        self.assertEqual(nsf.input_proof("t", 2, 2, 2, self.MARKS)[0], ["input: 2 keys sent, 1 `newTab.open` marks"])


TITLE = "a title of the person's work"  # the shell window's title in the app's list of windows: in no report


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
        # `records`: the spare flags of the opening records that each frame_strip makes (None: one, of a spare, for
        # each opening). The app's records and its openings are not one count: a Cmd-N of a reserved workspace makes none.
        self.records = None
        # The app at its launch is not active and has no key window, as an app that takes no keyboard, and no call
        # of the tool changes that. `window_calls`: each `debug.window.focus` call's params. `shell_window`: the
        # app's one shell window in `debug.window_list` (a test changes a field of it; no report may keep its
        # `title`). `other_windows`: each other entry of that list.
        self.active, self.is_key, self.window_calls = False, False, []
        self.shell_window = {"id": 41, "kind": "main", "title": TITLE, "frame": {"x": 40.0, "y": 230.0, "width": 1200.0, "height": 900.0},
                             "visible": True, "parent": None, "class": "ShellWindow", "level": 0, "ignores_mouse": False,
                             "occluded": False, "miniaturized": False, "alpha": 1.0}
        self.other_windows = []

    def focus_fact(self, **window):
        """The app's `debug.focus` answer: whether the app is active, and its one window (a test's own fields in `window`)."""
        return {"app_active": self.active, "windows": [{"id": "window-1", "is_key": self.is_key, **window}]}

    def window_focus(self, params):
        """`debug.window.focus`: the app keeps the call's params. The call makes no app active here."""
        self.window_calls.append(params)
        return {"key": "window-1" if self.is_key else None, "front": "window-1"}

    def window_list(self):
        """The app's `debug.window_list` answer: its shell window (`key` as the app says) and each other window."""
        return {"windows": [{**self.shell_window, "key": self.is_key}, *self.other_windows]}

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
        if method == "debug.focus":
            return self.focus_fact()
        if method == "debug.window.focus":
            return self.window_focus(params)
        if method == "debug.window_list":
            return self.window_list()
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
            for flag in [True] * opened if self.records is None else self.records:
                self.recorded += 1
                self.openings.append({"spare": flag, "ms": 1000.0 + self.recorded})
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
                  screen_tgz=None, display="ready 7 8.33 main=7", display_hz=120.0, build=None, page_engine="cef", split=1, key_tabs=[],
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

    def test_a_run_with_no_asked_display_rate_has_no_valid_row(self):
        # With no asked rate the frame time is the median step of the recording's rows, and a frame with no row
        # directly before the page is then not seen: the same pictures that are valid at an asked rate are not valid.
        # The rate of a run with no `--display-hz` is the arguments' own: None. The run goes on to its last case.
        parser = argparse.ArgumentParser()
        new_surface_screen.add_arguments(parser)
        absent = parser.parse_args([]).display_hz
        self.assertIsNone(absent)
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240), display_hz=absent, runs=1)
        self.assertEqual((report["exit_code"], report.get("stopped")), (0, None))
        self.assertEqual([[reason.split(":")[0] for reason in row["invalid"]] for row in report["rows"]], [["display"]] * 2)
        self.assertEqual([(case["valid"], case["invalid"]) for case in report["cases"].values()], [(0, ["display"])] * 2)
        self.assertIsNone(report["display_hz_asked"])
        # The row's line and the case's line give no count of the frames with no row: the count is not known.
        lines = said.getvalue().splitlines()
        rows = [line for line in lines if line.startswith("NEW-SURFACE-SCREEN-ROW ")]
        cases = [line for line in lines if line.startswith("NEW-SURFACE-SCREEN cmd-")]
        self.assertEqual((len(rows), len(cases)), (2, 2))
        for line in rows:
            self.assertIn(" no_row_to_content_first=not known early_ms_at_most=not known (no asked display rate)", line)
            self.assertNotIn("no_row_to_content_first=0", line)
        for line in cases:
            self.assertIn("valid 0/1 (INVALID: display); frames with no row from the key to content_first: not known (no asked display rate); tab ", line)
            self.assertNotIn("ms early", line)
        # A run with no asked rate has no check of it: its head has no sentence of that check's limit.
        self.assertNotIn("against the rows", "; ".join(report["head"]))
        # The saved report has no number for what is not known.
        saved = json.loads(Path(self.folder, "report.json").read_text())["cases"]
        self.assertEqual([(case.get("first_frame_no_row", "no such fact"), case["recorder_lost"], case.get("no_row_not_known_rows"))
                          for case in saved.values()], [(None, None, 1)] * 2)

    def test_the_line_of_a_row_with_no_asked_display_rate_says_not_known_for_the_second_keys_frames_too(self):
        span = {"frames": 3, "rows": 3, "no_row": 0, "no_row_frames": [], "longest_gap_ms": 9.0, "early_ms_at_most": 0.0}
        row = {"gap_ms": 100.0, "invalid": [], "first_frame_span": span,
               "second_first": {"frame": 3, "ms": 25, "after_mark_ms": 21.0, "span": span, "moving_at_the_mark": False}}
        self.assertEqual(new_surface_screen.holes(row),
                         " no_row_to_content_first=0/3 longest_gap_ms=9 early_ms_at_most=0 second_first=[3, 25] after_mark_ms=21 "
                         "second_no_row=0/3 second_early_ms_at_most=0 moving_at_the_mark=False")
        row["invalid"] = [nsf.NO_RATE]
        self.assertEqual(new_surface_screen.holes(row),
                         " no_row_to_content_first=not known early_ms_at_most=not known (no asked display rate) second_first=[3, 25] "
                         "after_mark_ms=21 second_no_row=not known second_early_ms_at_most=not known moving_at_the_mark=False")
        # A row whose rows do not agree with the asked rate: its counts are not known too, with its own words.
        row["invalid"] = ["display: 8 steps one after the other took 67 ms"]
        self.assertEqual(new_surface_screen.holes(row),
                         " no_row_to_content_first=not known early_ms_at_most=not known (the asked display rate is not proved) "
                         "second_first=[3, 25] after_mark_ms=21 second_no_row=not known second_early_ms_at_most=not known moving_at_the_mark=False")

    def test_a_given_display_rate_that_is_not_a_finite_number_above_0_stops_at_the_modes_arguments(self):
        self.assertTrue(hasattr(new_surface_screen, "given_rate"), "new_surface_screen.py has no `given_rate`: `--display-hz` takes any number")
        parser = argparse.ArgumentParser()
        new_surface_screen.add_arguments(parser)
        self.assertEqual([parser.parse_args([f"--display-hz={rate}"]).display_hz for rate in ("120", "59.94")], [120.0, 59.94])
        for bad in ("inf", "-inf", "nan", "0", "0.0", "-120", "1e999", "fast"):
            with self.subTest(bad):
                said = io.StringIO()
                with self.assertRaises(SystemExit) as stop, contextlib.redirect_stderr(said):
                    parser.parse_args([f"--display-hz={bad}"])
                self.assertEqual(stop.exception.code, 2)
                self.assertIn(f"argument --display-hz: {bad}: --display-hz takes a finite number above 0", said.getvalue())

    def test_the_driver_with_a_given_display_rate_that_is_no_rate_stops_before_its_first_case(self):
        # The driver itself, as the entry starts it: the stop is at its arguments, so before a launch, a socket and a
        # case. An error line, an exit code that is not 0, and no line of a run.
        driver = str(Path(new_surface_screen.__file__).resolve().parent / "cmd-n-paint-e2e.py")
        for bad in ("inf", "0", "-120"):
            with self.subTest(bad):
                done = subprocess.run([sys.executable, "-I", "-B", driver, "--socket", os.path.join(self.folder, "no.sock"), "--out", self.folder,
                                       "--screen", f"--display-hz={bad}"], capture_output=True, text=True, timeout=60, check=False)
                self.assertEqual((done.returncode, done.stdout), (2, ""), done.stderr[-400:])
                self.assertIn(f"error: argument --display-hz: {bad}: --display-hz takes a finite number above 0", done.stderr)

    def test_the_entry_refuses_a_display_rate_that_is_not_a_number_above_0_before_its_build(self):
        # By a run of the entry's own check (its `if` to its `fi`) in bash: the entry whole needs a Mac build.
        entry = Path(new_surface_screen.__file__).resolve().parent.parent / "measure" / "instant-new-surfaces.sh"
        lines = entry.read_text().splitlines()
        starts = [index for index, line in enumerate(lines) if line.startswith('if [[ "$screen" == 1 && -n "$vdisplay_hz"')]
        self.assertEqual(len(starts), 1, "the entry's check of --vdisplay with --screen")
        check = "\n".join(lines[starts[0]:lines.index("fi", starts[0]) + 1])
        self.assertLess(starts[0], next(index for index, line in enumerate(lines) if "./scripts/reload.sh" in line and not line.lstrip().startswith("#")))

        def checked(rate, screen="1", locale=None):
            done = subprocess.run(["bash", "-c", f'screen="$1" vdisplay_hz="$2"\n{check}\necho went on', "check", screen, rate],
                                  capture_output=True, text=True, encoding="utf-8", timeout=60, check=False,
                                  env={**os.environ, "LC_ALL": locale} if locale else None)
            return done.returncode, done.stdout, done.stderr.strip()

        for bad in ("0", "0.0", "00", "-120", "inf", "nan", "fast", "1e3", "120."):
            self.assertEqual(checked(bad), (2, "", f"instant-new-surfaces: --screen: --vdisplay={bad} is not a rate in Hz above 0"), bad)
        for good in ("120", "59.94", "0.5", "60.0"):
            self.assertEqual(checked(good), (0, "went on\n", ""), good)
        # A run with no --vdisplay, and a run with no --screen: the check is not theirs.
        self.assertEqual((checked(""), checked("0", screen="0")), ((0, "went on\n", ""), (0, "went on\n", "")))
        # The match has the C locale: in a UTF-8 locale `[0-9]` also takes the digits of other scripts (here 3
        # Arabic-Indic digits). The driver's `float` takes them as 120 and the display's helper reads its rate with
        # `atof`, so the display and the asked rate could differ. By a run in each UTF-8 locale that this host has.
        self.assertIn("LC_ALL=C", check.splitlines()[0])
        # The C locale is the match's only: after the check the script has the locale that it had.
        kept = subprocess.run(["bash", "-c", f'screen=1 vdisplay_hz=120 LC_ALL=POSIX\n{check}\necho "$LC_ALL"'],
                              capture_output=True, text=True, encoding="utf-8", timeout=60, check=False)
        self.assertEqual((kept.returncode, kept.stdout), (0, "POSIX\n"))
        other = "\u0661\u0662\u0660"
        try:
            names = subprocess.run(["locale", "-a"], capture_output=True, text=True, timeout=60, check=False).stdout.split()
        except OSError:
            names = []
        for name in [name for name in names if name.lower().replace("-", "").endswith(".utf8")][:8]:
            self.assertEqual(checked(other, locale=name), (2, "", f"instant-new-surfaces: --screen: --vdisplay={other} is not a rate in Hz above 0"), name)
            self.assertEqual(checked("59.94", locale=name), (0, "went on\n", ""), name)

    def test_the_mode_itself_takes_no_value_that_is_not_a_finite_number_above_0_as_a_rate(self):
        # An options object that no argument check made (a caller that is not the driver): the mode's own guard.
        for rate in (float("inf"), float("-inf"), float("nan"), 0, -120.0):
            with contextlib.redirect_stdout(io.StringIO()):
                report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240), display_hz=rate, keys="n", runs=1)
            self.assertEqual(report["rows"][0]["invalid"], [nsf.NO_RATE], rate)
            self.assertIsNone(report["display_hz_asked"], rate)

    def test_a_run_whose_rows_prove_that_the_asked_rate_is_too_low_has_no_valid_row_and_no_count(self):
        # The made rows of a 120 Hz display, through the mode with 60 asked: Rule 1 does not see frame 2.
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(FakeApp(self.folder, HIDDEN_AT_120), display_hz=60.0, keys="n", runs=1)
        self.assertEqual([[reason.split(":")[0] for reason in row["invalid"]] for row in report["rows"]], [["display"]])
        self.assertEqual(report["display_hz_asked"], 60.0)
        lines = said.getvalue().splitlines()
        row = next(line for line in lines if line.startswith("NEW-SURFACE-SCREEN-ROW "))
        self.assertIn(" no_row_to_content_first=not known early_ms_at_most=not known (the asked display rate is not proved)", row)
        case = next(line for line in lines if line.startswith("NEW-SURFACE-SCREEN cmd-n/idle"))
        self.assertIn("frames with no row from the key to content_first: not known (the asked display rate is not proved); tab ", case)
        head = next(line for line in lines if line.startswith("NEW-SURFACE-SCREEN-HEAD "))
        self.assertIn("cmd-n/idle not known (the asked display rate is not proved)", head)
        self.assertNotIn("cmd-n/idle 0 of 1", head)
        # The row's line has the number that the rule judged, also for an INVALID row; the head has no margin
        # sentence, because the run has no valid row.
        self.assertIn(" refresh_ms=16.667 rate_share=0.63 capture=", row)
        self.assertNotIn("SMALL MARGIN", head)
        # The saved report has no number for what is not known.
        saved = json.loads(Path(self.folder, "report.json").read_text())["cases"]["cmd-n/idle"]
        self.assertEqual((saved.get("first_frame_no_row", "no such fact"), saved["recorder_lost"], saved.get("no_row_not_known_rows")), (None, None, 1))

    def test_the_rows_line_and_the_head_say_the_margin_of_the_asked_rate(self):
        # Rows of a 120 Hz display with 104 asked: 8 steps take 66 ms, which is 0.858 of 8 asked frame times (76.9 ms).
        # That is above the limit 0.85 and below 0.88: the row keeps its other reasons only, and the head says it.
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240), display_hz=104.0, keys="n", runs=1)
        self.assertEqual((report["rows"][0].get("rate_share"), report["rows"][0]["invalid"]), (0.858, []))
        lines = said.getvalue().splitlines()
        self.assertIn(": valid ", next(line for line in lines if line.startswith("NEW-SURFACE-SCREEN-ROW ")))
        self.assertIn(" rate_share=0.858 capture=", next(line for line in lines if line.startswith("NEW-SURFACE-SCREEN-ROW ")))
        head = next(line for line in lines if line.startswith("NEW-SURFACE-SCREEN-HEAD "))
        self.assertIn("THE ASKED DISPLAY RATE HAS A SMALL MARGIN: in 1 of the 1 valid rows the smallest time of 8 steps one after the other "
                      "is below 0.88 of 8 asked frame times (the smallest: 0.858 in cmd-n-idle-0; below 0.85 a row is INVALID by `display`)", head)
        # The head's order: the rows that the recorder lost, the limit of the asked rate's check, the margin, and
        # then the app's settings lines.
        rate = report["head"][-3 - len(report["settings"]["lines"]):len(report["head"]) - len(report["settings"]["lines"])]
        self.assertEqual([said.split(":")[0] for said in rate],
                         ["rows lost to the recorder (INVALID by `no-row` or `refresh`, a fault of the tool's yield)",
                          "the asked display rate (104 Hz) against the rows", "THE ASKED DISPLAY RATE HAS A SMALL MARGIN"])
        self.assertEqual(rate[1], nsf.rate_limit_sentence(104.0))
        # At the display's own rate the margin is large: no sentence.
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240), keys="n", runs=1)
        self.assertEqual((report["rows"][0].get("rate_share"), report["rows"][0]["invalid"]), (0.99, []))
        self.assertNotIn("SMALL MARGIN", said.getvalue())
        # The limit of the check is in the head of each run with an asked rate, directly after the recorder's rows.
        at = report["head"].index(nsf.rate_limit_sentence(120.0))
        self.assertTrue(report["head"][at - 1].startswith("rows lost to the recorder ("), report["head"])
        self.assertEqual(report["head"][at + 1:], report["settings"]["lines"])

    def test_the_asked_display_rate_gets_to_the_reader_of_a_key(self):
        # Frame 2 has no row and the page is in frame 3; after it the recorder gives a row for each third frame of the
        # display. Only the asked rate's frame time sees frame 2: by the rows' own median step (25 ms) the page's
        # row is frame 1 and no frame is before it.
        # (25 ms after 8 steps at the display's rate: without those the asked rate is not judged.)
        report, _ = self.run_mode(FakeApp(self.folder, JUDGED_AT_120), keys="t", runs=1)
        row = report["rows"][0]
        self.assertEqual((row["refresh_ms"], row["content_first"]["frame"]), (round(STEP, 3), 3))
        self.assertEqual([reason.split(":")[0] for reason in row["invalid"]], ["no-row"])

    def test_a_key_that_opened_nothing_is_an_invalid_row(self):
        report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240, opens=1), keys="n", gaps="100", runs=1)
        # The proof is the count of workspaces (and the marks); 1 record for 2 Cmd-N is a fact and no fault.
        self.assertEqual(report["rows"][0]["invalid"], ["input: 2 keys sent, 1 more workspaces after them"])
        self.assertEqual(report["rows"][0]["opening_records"]["keys_with_no_record"], 1)
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


HALF = (0.01, 0.01)  # the window outside the pane with one new row of two: unlike before, unlike the last picture
PART = (0.3, 0.05)  # the page, not yet as it stays


class FirstFrameSpanTests(unittest.TestCase):
    """A first frame is a number only when each frame of the display from the key to it has a row."""

    def test_a_first_frame_with_a_row_for_each_frame_before_it_has_its_span_and_is_valid(self):
        got = nsf.one_key(take([(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        self.assertEqual((got["content_first"]["frame"], got["invalid"]), (3, []))
        self.assertEqual(got.get("first_frame_span"), {"frames": 3, "rows": 3, "no_row": 0, "no_row_frames": [],
                                                       "longest_gap_ms": 9.0, "early_ms_at_most": 0.0})

    def test_a_frame_with_no_row_directly_before_the_first_content_makes_the_row_invalid_and_says_how_early_it_can_be(self):
        # Frame 2 has no row. The page is in frame 3's row: it can have come in frame 2, one frame time earlier.
        got = nsf.one_key(take([(OLD, ROW_OLD), None] + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        self.assertEqual((got["content_first"]["frame"], got["content_first"]["ms"]), (3, 25))
        self.assertEqual(got.get("first_frame_span"), {"frames": 3, "rows": 2, "no_row": 1, "no_row_frames": [2],
                                                       "longest_gap_ms": 17.0, "early_ms_at_most": 8.3})
        self.assertEqual(got["invalid"], ["no-row: 1 of the 3 frames from the key to content_first have no row (frames 2; the longest "
                                          "step between rows 17 ms): content_first can be at most 8.3 ms early"])

    def test_a_frame_with_no_row_before_a_row_that_shows_the_old_picture_leaves_the_time_proved_and_a_partial_state_not_seen(self):
        # Frame 1 has no row; frame 2's row still shows the picture before the key, so the page's first frame is not
        # frame 1. The time is proved. What frame 1 showed is not: a page that came and went is not seen.
        got = nsf.one_key(take([None, (OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        span = got.get("first_frame_span") or {}
        self.assertEqual((span.get("no_row"), span.get("no_row_frames"), span.get("early_ms_at_most")), (1, [1], 0.0))
        self.assertEqual((got["invalid"], got.get("partial_state_not_seen", "no such field")), ([], 1))
        # A row with a row for each frame says 0, and a row with the frame directly before the page says its count too.
        whole = nsf.one_key(take([(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        direct = nsf.one_key(take([(OLD, ROW_OLD), None] + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        self.assertEqual((whole.get("partial_state_not_seen", "no such field"), direct.get("partial_state_not_seen", "no such field")), (0, 1))

    def test_a_frame_with_no_row_before_a_row_that_is_not_the_old_picture_can_hide_the_page(self):
        # Frame 2 has no row and frame 3's row is blank: not the page, and not the old picture. No row of the old
        # picture is between frame 2 and the page's row (frame 4), so the page can have come in frame 2.
        blank = dict(content=(0.9, 0.9), outside=ROW_OLD, blank=True)
        got = nsf.one_key(take([(OLD, ROW_OLD), None, blank] + [(NEW, ROW_NEW)] * 237), "n", asked_hz=120)
        span = got.get("first_frame_span") or {}
        # How early: from frame 2 to the page's row in frame 4 = 2 frame times of 8.33 ms = 16.7 ms. It is not the
        # count of the frames with no row (1 frame = 8.3 ms): the blank row between them does not rule frame 2 out.
        self.assertEqual((got["content_first"]["frame"], span.get("no_row_frames"), span.get("early_ms_at_most")), (4, [2], 16.7))
        self.assertEqual([reason.split(":")[0] for reason in got["invalid"]], ["no-row"])
        # 3 blank rows between them: from frame 2 to the page's row in frame 6 = 4 frame times = 33.3 ms.
        later = nsf.one_key(take([(OLD, ROW_OLD), None, blank, blank, blank] + [(NEW, ROW_NEW)] * 235), "n", asked_hz=120)
        span = later.get("first_frame_span") or {}
        self.assertEqual((later["content_first"]["frame"], span.get("no_row_frames"), span.get("early_ms_at_most")), (6, [2], 33.3))
        self.assertEqual([reason.rsplit(": ", 1)[1] for reason in later["invalid"]], ["content_first can be at most 33.3 ms early"])
        # 2 frames with no row, one of them directly before the page: from the first one (frame 2) = 3 frame times.
        both = nsf.one_key(take([(OLD, ROW_OLD), None, blank, None] + [(NEW, ROW_NEW)] * 236), "n", asked_hz=120)
        span = both.get("first_frame_span") or {}
        self.assertEqual((both["content_first"]["frame"], span.get("no_row_frames"), span.get("early_ms_at_most")), (5, [2, 4], 25.0))
        # A blank row in frame 2, BEFORE the first frame with no row (frame 3): frame 2 has a row that is not the
        # page, so only frame 3 can hide the page = 1 frame time, not 2 from the frame after the old picture's row.
        after = nsf.one_key(take([(OLD, ROW_OLD), blank, None] + [(NEW, ROW_NEW)] * 237), "n", asked_hz=120)
        span = after.get("first_frame_span") or {}
        self.assertEqual((after["content_first"]["frame"], span.get("no_row_frames"), span.get("early_ms_at_most")), (4, [3], 8.3))

    def test_the_still_part_of_a_recording_is_not_judged_by_the_step_of_its_rows(self):
        # A row for each of the first 8 frames (the page comes in frame 3 and is whole in frame 4); in the still part
        # after them the recorder gives a row for each third frame of the display.
        pictures = [(OLD, ROW_OLD)] * 2 + [(PART, ROW_NEW)] + [(NEW, ROW_NEW)] * 5 + [None, None, (NEW, ROW_NEW)] * 78
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual(got["invalid"], [])
        # The frame's number is the display's: the rows' own step over the whole recording is 3 frame times.
        self.assertEqual((got["refresh_ms"], got["content_first"]["frame"], got["content_final"]["frame"]), (round(STEP, 3), 3, 4))
        self.assertAlmostEqual(got["refresh_measured_ms"], 3 * STEP, delta=0.6)
        self.assertEqual((got["frames_not_delivered"], got["frames_after_key"], got["take_ms"]), (156, 86, 2017))

    def test_rows_that_come_slower_than_the_display_in_the_part_that_moves_are_invalid(self):
        # A row for each SECOND frame of the display while the page comes (frames 2 to 10), then a row for each frame.
        pictures = [None, (OLD, ROW_OLD), None, (OLD, ROW_OLD), None, (PART, ROW_NEW), None, (PART, ROW_NEW), None] + [(NEW, ROW_NEW)] * 231
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual([reason.split(":")[0] for reason in got["invalid"]], ["no-row", "refresh"])
        self.assertEqual((got["refresh_ms"], got["content_first"]["frame"], got["content_final"]["frame"]), (round(STEP, 3), 6, 10))
        self.assertAlmostEqual(got.get("refresh_moving_ms") or 0, 2 * STEP, delta=0.6)
        self.assertEqual(got["first_frame_span"]["no_row_frames"], [1, 3, 5])

    def test_a_row_keeps_the_time_of_each_of_its_rows(self):
        got = nsf.one_key(take([(NEW, ROW_NEW)] * 3 + [None] + [(NEW, ROW_NEW)] * 236), "n", asked_hz=120)
        self.assertEqual(((got.get("rows_ms") or [])[:4], len(got.get("rows_ms") or [])), ([8, 17, 25, 42], 239))

    def test_a_case_says_the_frames_with_no_row_of_each_of_its_rows_also_of_the_invalid_ones(self):
        good = nsf.one_key(take([(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        holed = nsf.one_key(take([(OLD, ROW_OLD), None] + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        # A third row: its one frame with no row is before a row of the old picture. The case counts the 2 kinds apart.
        before_old = nsf.one_key(take([None, (OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        case = nsf.summarize([good, holed, before_old])
        self.assertEqual((case["valid"], case["invalid"]), (2, ["no-row"]))
        self.assertEqual(case.get("first_frame_no_row"), {"rows": 3, "with_a_frame_with_no_row": 2, "time_not_proved": 1,
                                                          "time_proved_partial_state_not_seen": 1, "no_row": {"p50": 1, "max": 1},
                                                          "longest_gap_ms": {"p50": 17.0, "max": 17.0},
                                                          "early_ms_at_most": {"p50": 0.0, "max": 8.3}})
        self.assertIn("frames with no row from the key to content_first, over EACH of 3 rows (also the INVALID ones): in 2 rows "
                      "(1 with one directly before content_first: the time is not proved; 1 with each before a row of the old picture: "
                      "the time is proved, a partial state is not seen), p50 1 max 1, the longest step between rows max 17 ms, "
                      "content_first at most 8.3 ms early", nsf.cell(case))


# Rows of a 120 Hz display: the old picture in frame 1, no row in frame 2 (the page can have come in it), the page
# from frame 3, then a still part in which the recorder gives a row for each third frame of the display.
HIDDEN_AT_120 = [(OLD, ROW_OLD), None] + [(NEW, ROW_NEW)] * 6 + [None, None, (NEW, ROW_NEW)] * 78
# The same with 9 rows one after the other from the page's frame: 8 steps at the display's rate, so the rate is judged.
JUDGED_AT_120 = [(OLD, ROW_OLD), None] + [(NEW, ROW_NEW)] * 9 + [None, None, (NEW, ROW_NEW)] * 77
EACH_FRAME = [(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW)] * 238  # a row for each frame of a 120 Hz display, the page in frame 3


def at_step(reply, step_ms):
    """The rows of `reply` with one row each `step_ms` from its first row (whole ms, as the app's rows are)."""
    first = reply["frames"][0]["ms"]
    for index, frame in enumerate(reply["frames"]):
        frame["ms"] = round(first + index * step_ms)
    return reply


def kinds(got):
    return [reason.split(":")[0] for reason in got["invalid"]]


class AskedRateTests(unittest.TestCase):
    """An asked rate that is lower than the display's makes Rule 1 blind: the rows say that the rate is too low."""

    def test_the_made_rows_are_invalid_by_no_row_at_the_displays_own_rate(self):
        got = nsf.one_key(take(JUDGED_AT_120), "n", asked_hz=120)
        self.assertEqual((kinds(got), got["content_first"]["frame"], got["first_frame_span"]["no_row_frames"]), (["no-row"], 3, [2]))

    def test_rows_of_a_120_hz_display_with_60_asked_have_the_display_reason(self):
        # 60 asked: the frame time is the asked one (16.667 ms), the page's row is then frame 2 and no frame has no row.
        got = nsf.one_key(take(HIDDEN_AT_120), "n", asked_hz=60)
        self.assertEqual((got["refresh_ms"], got["content_first"]["frame"], got["first_frame_span"]["no_row"]), (16.667, 2, 0))
        self.assertEqual(kinds(got), ["display"])
        self.assertIn("8 steps one after the other", got["invalid"][0])

    def test_rows_of_a_120_hz_display_with_45_asked_have_the_display_reason(self):
        got = nsf.one_key(take(HIDDEN_AT_120), "n", asked_hz=45)
        self.assertEqual((got["refresh_ms"], got["content_first"]["frame"], got["first_frame_span"]["no_row"]), (22.222, 2, 0))
        self.assertEqual(kinds(got), ["display"])

    def test_an_asked_rate_that_the_rows_own_step_takes_the_place_of_has_the_display_reason(self):
        # 30 and 1 asked: the rows come faster than the asked rate by more than 15 %, so the frame time is the rows' own
        # median step (the still part's: 3 frame times of the display).
        for rate in (30, 1):
            got = nsf.one_key(take(HIDDEN_AT_120), "n", asked_hz=rate)
            self.assertEqual(got["refresh_ms"], got["refresh_measured_ms"], rate)
            self.assertEqual(kinds(got), ["display"], rate)

    def test_a_frame_time_that_is_not_the_asked_one_has_the_display_reason_also_when_the_sum_of_8_steps_passes(self):
        # Steps of 4, 4 and 17 ms by turns: the median step is 4 ms, so the frame time is the rows' own (not the asked
        # 8.33 ms), and the smallest sum of 8 steps is 58 ms = 0.87 of 8 asked frame times, which the sum's rule passes.
        reply = take([(NEW, ROW_NEW)] * 240)
        at = reply["frames"][0]["ms"]
        for index, frame in enumerate(reply["frames"][1:]):
            at += (4, 4, 17)[index % 3]
            frame["ms"] = at
        got = nsf.one_key(reply, "n", asked_hz=120)
        self.assertEqual((got.get("rate_share"), got["refresh_ms"]), (0.87, 4.0))
        self.assertIn("display", kinds(got))
        self.assertIn("the frame time is the rows' own median step", next(reason for reason in got["invalid"] if reason.startswith("display")))

    def test_a_recording_with_too_few_rows_to_judge_the_asked_rate_is_invalid(self):
        # The rule needs 8 steps one after the other: 9 rows in the whole recording (2 of them are before the key).
        self.assertEqual(getattr(nsf, "RATE_STEPS", None), 8)
        few = nsf.one_key(take([(OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 5), "n", asked_hz=120)
        self.assertEqual(few["frames_after_key"], 6)
        self.assertIn("display", kinds(few))
        self.assertIn("the recording has 8 rows", next(reason for reason in few["invalid"] if reason.startswith("display")))
        enough = nsf.one_key(take([(OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 6), "n", asked_hz=120)
        self.assertEqual(enough["frames_after_key"], 7)
        self.assertNotIn("display", kinds(enough))

    def test_single_short_steps_of_a_recording_at_the_right_rate_are_no_fault(self):
        # A row's time has a jitter of some ms (the rows' times are whole ms): a recording at the display's own rate
        # has steps of 4 and 5 ms, each next to a long one. The time of 8 steps one after the other stays near 8 frames.
        reply = take([(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW)] * 238)
        jitter = (0, 2, -2, 2, -2, 0, 1, -1)
        for index, frame in enumerate(reply["frames"]):
            if frame["ms"] > 30:
                frame["ms"] += jitter[index % len(jitter)]
        times = [frame["ms"] for frame in reply["frames"]]
        self.assertGreater(sum(1 for a, b in zip(times, times[1:]) if b - a <= 5), 40)
        got = nsf.one_key(reply, "n", asked_hz=120)
        self.assertEqual((got["invalid"], got["content_first"]["frame"]), ([], 3))

    def test_each_row_has_the_smallest_time_of_8_steps_as_a_share_of_8_asked_frame_times(self):
        # The row has the number that the rule judges, valid or not: each take so shows its own margin to the limit.
        def share(reply, rate):
            times = sorted(frame["ms"] for frame in reply["frames"])
            return round(min(b - a for a, b in zip(times, times[8:])) / (8 * 1000 / rate), 3)
        good = take([(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW)] * 238)
        self.assertEqual(share(good, 120), 0.99)  # 66 ms: the rows' times are whole ms
        self.assertEqual(nsf.one_key(good, "n", asked_hz=120).get("rate_share", "no such fact"), 0.99)
        self.assertEqual(share(take(HIDDEN_AT_120), 60), 0.63)
        low = nsf.one_key(take(HIDDEN_AT_120), "n", asked_hz=60)
        self.assertEqual((low.get("rate_share", "no such fact"), kinds(low)), (0.63, ["display"]))
        # Not known: no asked rate, and a recording with fewer than 9 rows.
        self.assertIsNone(nsf.one_key(good, "n").get("rate_share", "no such fact"))
        self.assertIsNone(nsf.one_key(take([(OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 5), "n", asked_hz=120).get("rate_share", "no such fact"))

    def test_a_take_whose_valid_rows_have_a_small_margin_to_the_limit_says_so_in_one_sentence(self):
        self.assertTrue(hasattr(nsf, "rate_margin_sentence"), "new_surface_frames.py has no `rate_margin_sentence`")
        rows = [{"invalid": [], "rate_share": 0.87, "label": "cmd-t-idle-0"}, {"invalid": ["no-row: 1 of"], "rate_share": 0.86, "label": "cmd-t-idle-1"},
                {"invalid": [], "rate_share": 0.93, "label": "cmd-t-idle-2"}, {"invalid": [], "rate_share": None, "label": "cmd-t-idle-3"},
                {"invalid": [], "rate_share": 0.879, "label": "cmd-t-idle-4"}]
        self.assertEqual(nsf.rate_margin_sentence(rows),
                         "THE ASKED DISPLAY RATE HAS A SMALL MARGIN: in 2 of the 4 valid rows the smallest time of 8 steps one after the "
                         "other is below 0.88 of 8 asked frame times (the smallest: 0.87 in cmd-t-idle-0; below 0.85 a row is INVALID by "
                         "`display`)")
        # 0.88 and more in each valid row: no sentence. The INVALID row's own number does not count.
        self.assertIsNone(nsf.rate_margin_sentence([rows[1], rows[2], rows[3], {"invalid": [], "rate_share": 0.88}]))
        self.assertIsNone(nsf.rate_margin_sentence([]))

    def test_a_rate_that_is_not_a_finite_number_above_0_is_no_asked_rate_for_the_reader(self):
        self.assertTrue(hasattr(nsf, "asked_rate"), "new_surface_frames.py has no `asked_rate`: the mode and the reader have 2 rules")
        self.assertEqual([nsf.asked_rate(rate) for rate in (120, 59.94, 0, -120.0, float("inf"), float("-inf"), float("nan"), None, True, "120")],
                         [120, 59.94, None, None, None, None, None, None, None, None])
        # A whole number that is too large for a float is no rate, and no error of the reader.
        try:
            self.assertIsNone(nsf.asked_rate(10 ** 400))
        except OverflowError as error:
            self.fail(f"asked_rate(10 ** 400) raised OverflowError: {error}")

    def test_the_head_does_not_count_the_rows_lost_to_the_recorder_of_a_case_with_a_display_reason(self):
        # No asked rate: the count of rows with a frame with no row is not known, and `0 of 1` reads as `none lost`.
        blind = nsf.summarize([{"invalid": [nsf.NO_RATE]}])
        blind["recorder_lost"] = nsf.recorder_lost([{"invalid": [nsf.NO_RATE]}])
        low = nsf.one_key(take(HIDDEN_AT_120), "n", asked_hz=60)
        too_low = nsf.summarize([low])
        too_low["recorder_lost"] = nsf.recorder_lost([low])
        good = nsf.one_key(take([(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW)] * 238), "n", asked_hz=120)
        seen = nsf.summarize([good])
        seen["recorder_lost"] = nsf.recorder_lost([good])
        self.assertEqual(nsf.recorder_sentence({"cmd-n/idle": blind, "cmd-t/idle": too_low, "cmd-w/idle": seen}),
                         "rows lost to the recorder (INVALID by `no-row` or `refresh`, a fault of the tool's yield): "
                         "cmd-n/idle not known (no asked display rate); "
                         "cmd-t/idle not known (the asked display rate is not proved); cmd-w/idle 0 of 1")
        self.assertIn("frames with no row from the key to content_first: not known (the asked display rate is not proved)",
                      nsf.cell(too_low))
        # The saved report has no number there: no count of rows with a frame with no row, and no count of lost rows.
        self.assertEqual((too_low.get("first_frame_no_row", "no such fact"), too_low["recorder_lost"], too_low.get("no_row_not_known_rows")),
                         (None, None, 1))
        self.assertEqual((seen["first_frame_no_row"]["rows"], seen["recorder_lost"], seen.get("no_row_not_known_rows")),
                         (1, {"rows": 0, "of": 1, "not_known": 0, "no_row": 0, "refresh": 0}, 0))

    def test_a_case_with_rows_of_both_kinds_says_how_many_are_not_known_and_counts_the_others(self):
        low = nsf.one_key(take(HIDDEN_AT_120), "n", asked_hz=60)  # `display`: its counts are not known
        lost = nsf.one_key(take(JUDGED_AT_120), "n", asked_hz=120)  # `no-row`: a row that the recorder lost
        good = nsf.one_key(take(EACH_FRAME), "n", asked_hz=120)
        self.assertEqual((kinds(low), kinds(lost), kinds(good)), (["display"], ["no-row"], []))
        case = nsf.summarize([low, lost, good])
        case["recorder_lost"] = nsf.recorder_lost([low, lost, good])
        self.assertEqual((case["no_row_not_known"], case.get("no_row_not_known_rows")), ("the asked display rate is not proved", 1))
        self.assertEqual(case["recorder_lost"], {"rows": 1, "of": 2, "not_known": 1, "no_row": 1, "refresh": 0})
        self.assertEqual((case["first_frame_no_row"]["rows"], case["first_frame_no_row"]["with_a_frame_with_no_row"]), (2, 1))
        self.assertEqual(nsf.recorder_sentence({"cmd-n/idle": case}),
                         "rows lost to the recorder (INVALID by `no-row` or `refresh`, a fault of the tool's yield): cmd-n/idle not known "
                         "for 1 of 3 rows (the asked display rate is not proved), 1 of the 2 others (no-row 1, refresh 0)")
        self.assertIn("valid 1/3 (INVALID: display, no-row); frames with no row from the key to content_first: not known for 1 of 3 "
                      "rows (the asked display rate is not proved); over EACH of 2 other rows (also the INVALID ones): in 1 rows (1 with "
                      "one directly before content_first: the time is not proved; ", nsf.cell(case))
        # A summary of an older tool has no count of such rows: its case is `not known` as before.
        older = {name: value for name, value in case.items() if name != "no_row_not_known_rows"}
        older["recorder_lost"] = {"rows": 1, "of": 3, "no_row": 1, "refresh": 0}
        self.assertIn("cmd-n/idle not known (the asked display rate is not proved)", nsf.recorder_sentence({"cmd-n/idle": older}))
        self.assertIn("; frames with no row from the key to content_first: not known (the asked display rate is not proved); tab ", nsf.cell(older))

    def test_a_display_reason_that_is_not_the_first_reason_of_a_row_makes_its_counts_not_known(self):
        self.assertEqual(nsf.rate_not_known(["no-row: 1 of the 3 frames have no row", "display: 8 steps one after the other"]),
                         "the asked display rate is not proved")
        self.assertEqual(nsf.rate_not_known(["no-row: 1 of the 3 frames have no row", nsf.NO_RATE]), "no asked display rate")
        self.assertIsNone(nsf.rate_not_known(["no-row: 1 of the 3 frames have no row", "frames: the take ended"]))
        # By made rows: frame 2 has no row (`no-row` first), and no 8 steps of the rows come at the asked rate.
        got = nsf.one_key(take(HIDDEN_AT_120), "n", asked_hz=120)
        self.assertEqual((kinds(got), nsf.rate_not_known(got["invalid"])), (["no-row", "display"], "the asked display rate is not proved"))

    def test_the_invalid_decision_has_its_limit_at_0_85_of_8_asked_frame_times(self):
        # A row for each frame of a 120 Hz display: 8 steps take 66 ms at the least (the rows' times are whole ms).
        # 102 asked: 66 ms of 78.43 ms = 0.841, INVALID. 103 asked: 66 ms of 77.67 ms = 0.8497, and the judged number
        # is the rounded one (0.85): valid, at the limit itself.
        low = nsf.one_key(take(EACH_FRAME), "n", asked_hz=102)
        self.assertEqual((low.get("rate_share"), kinds(low)), (0.841, ["display"]))
        self.assertIn("display: 8 steps one after the other of the rows took 0.841 of 8 asked frame times (9.80 ms each; under 0.85)", low["invalid"][0])
        at = nsf.one_key(take(EACH_FRAME), "n", asked_hz=103)
        self.assertEqual((at.get("rate_share"), at["invalid"], at["refresh_ms"]), (0.85, [], 9.709))

    def test_the_limit_is_one_number_for_the_decision_the_frame_time_and_the_words(self):
        # With another limit each of its 3 uses follows: at 0.4, a row for each frame of a 120 Hz display with 60 asked
        # (0.495) passes the decision, keeps the asked frame time and has 8 steps at the asked rate.
        with mock.patch.object(nsf, "RATE_SHARE", 0.4):
            got = nsf.one_key(take(EACH_FRAME), "n", asked_hz=60)
            self.assertEqual((got.get("rate_share"), got["refresh_ms"], got["invalid"]), (0.495, 16.667, []))
        # The words of the reason for a frame time that is the rows' own have the limit's number, not a copy of it.
        reply = take(EACH_FRAME)
        at = reply["frames"][0]["ms"]
        for index, frame in enumerate(reply["frames"][1:]):
            at += (4, 4, 17)[index % 3]
            frame["ms"] = at
        for share, said in ((0.85, "by more than 15 %"), (0.8, "by more than 20 %")):
            with mock.patch.object(nsf, "RATE_SHARE", share):
                got = nsf.one_key(reply, "n", asked_hz=120)
                self.assertIn(f"display: the rows come faster than the asked rate {said}, so the frame time is the rows' own",
                              "; ".join(got["invalid"]), share)

    def test_a_recording_with_no_8_steps_at_the_asked_rate_is_not_judged_and_is_invalid(self):
        # A 120 Hz display with 60 asked, the page hidden in frame 2. The recorder gives some rows one after the
        # other and then a row for each third frame: the smallest sum of 8 steps is then a sum of long and short
        # steps, and it is above the limit from 4 rows down. Such a sum proves no rate, so the row is not judged.
        for dense, share in ((4, 0.877), (3, 1.005), (2, 1.125), (1, 1.252)):
            pictures = [(OLD, ROW_OLD), None] + [(NEW, ROW_NEW)] * dense + [None, None, (NEW, ROW_NEW)] * 78
            got = nsf.one_key(take(pictures), "n", asked_hz=60)
            self.assertEqual((got.get("rate_share"), kinds(got)), (share, ["display"]), dense)
            self.assertIn("display: the asked rate is not judged: no 8 steps one after the other of the recording's "
                          f"{81 + dense} rows come at the asked rate (16.67 ms each; the sum of 8 steps is {share:g} of 8 asked frame "
                          "times at the least", got["invalid"][0])
            self.assertEqual(nsf.rate_not_known(got["invalid"]), "the asked display rate is not proved", dense)
        # With 5 rows or more one after the other the sum itself is under the limit: the rate is proved too low.
        proved = nsf.one_key(take([(OLD, ROW_OLD), None] + [(NEW, ROW_NEW)] * 5 + [None, None, (NEW, ROW_NEW)] * 78), "n", asked_hz=60)
        self.assertEqual(proved.get("rate_share"), 0.75)
        self.assertIn("took 0.75 of 8 asked frame times", proved["invalid"][0])
        # 9 rows, one each 25 ms, with 60 asked: 1.5 of 8 asked frame times, and not judged.
        slow = nsf.one_key(at_step(take([(OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 6), 25), "n", asked_hz=60)
        self.assertEqual((slow.get("rate_share"), kinds(slow)[0]), (1.5, "display"))
        self.assertIn("display: the asked rate is not judged", slow["invalid"][0])
        # At the display's own rate the same rule holds: 6 rows one after the other (5 steps) do not judge 120 asked,
        # 9 rows (8 steps) do. A row for each frame with an asked rate that is too HIGH by more than about 15 % is not
        # judged (the rows' times are whole ms, which moves the limit by about 1 %: 139 asked passes, 141 does not).
        self.assertEqual(kinds(nsf.one_key(take(HIDDEN_AT_120), "n", asked_hz=120)), ["no-row", "display"])
        self.assertEqual(kinds(nsf.one_key(take(JUDGED_AT_120), "n", asked_hz=120)), ["no-row"])
        high = nsf.one_key(take(EACH_FRAME), "n", asked_hz=141)
        self.assertEqual((high.get("rate_share"), kinds(high)), (1.163, ["display"]))
        self.assertIn("display: the asked rate is not judged", high["invalid"][0])
        # The reason's cause is true for each such recording: here each step is 10 ms (a 100 Hz display, 120 asked).
        even = nsf.one_key(at_step(take(EACH_FRAME), 10), "n", asked_hz=120)
        self.assertEqual(kinds(even), ["display"])
        self.assertTrue(even["invalid"][0].endswith("at the least: the rows come slower than the asked rate, or their steps are not even)"),
                        even["invalid"][0])
        # 8 steps with one frame of the display that has no row are rows at the asked rate only when their times have
        # nearly no jitter, as here (the 9 rows of the test of too few rows: the step over the reply's zero is 2 frame
        # times). The frame with no row takes 1.0 of the room of 1.2 frame times.
        self.assertTrue(nsf.rate_on_grid(take([(OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 6)["frames"], STEP))
        # 8 rows at the rate (7 steps) and a ninth row 3 frames later: not 8 steps at the rate.
        self.assertFalse(nsf.rate_on_grid(take([(OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 5 + [None, None, (NEW, ROW_NEW)])["frames"], STEP))

    def test_the_room_of_rows_at_the_asked_rate_is_1_2_asked_frame_times_between_the_earliest_and_the_latest_row(self):
        # 9 rows, one each 10 ms, and the fifth one late: the latest row less the earliest one, against a row for each
        # asked frame time, is that row's delay. The room is (1 - 0.85) * 8 = 1.2 asked frame times, so 12 ms here.
        def late(by_ms):
            return [{"ms": 10 * index + (by_ms if index == 4 else 0)} for index in range(9)]
        self.assertEqual([nsf.rate_on_grid(late(by), 10) for by in (0, 10, 11.5, 12.5, 15)], [True, True, True, False, False])
        # The room is between the earliest and the latest row: one row 7 ms early and one 7 ms late are 14 ms.
        self.assertFalse(nsf.rate_on_grid([{"ms": 10 * index + {2: -7, 6: 7}.get(index, 0)} for index in range(9)], 10))

    def test_what_the_check_of_the_asked_rate_does_not_find_is_said_in_the_head_and_is_true_by_made_rows(self):
        self.assertTrue(hasattr(nsf, "rate_limit_sentence"), "new_surface_frames.py has no `rate_limit_sentence`")
        self.assertEqual(nsf.rate_limit_sentence(120.0),
                         "the asked display rate (120 Hz) against the rows: a row is INVALID by `display` when 8 steps one after the "
                         "other of its rows took less than 0.85 of 8 asked frame times, and when no 9 rows one after the other come at "
                         "the asked rate (not judged; 9 rows in 9 frames of the display are what the check needs: with one frame with "
                         "no row in them it judges only rows with nearly no jitter); an asked rate that is too low is found only when "
                         "enough rows come one after the other at the display's own rate (9 are enough for an error above about 15 %): "
                         "rows that come each 2nd or 3rd frame of a faster display pass, and rows with steps of 1 and 2 frames by "
                         "turns can pass; an error of about 15 % or less is not found (rows of a 132 Hz display with 120 asked pass "
                         "with no word)")
        self.assertIn("the asked display rate (59.94 Hz) against the rows: ", nsf.rate_limit_sentence(59.94))
        self.assertEqual([nsf.rate_limit_sentence(rate) for rate in (None, 0, float("inf"))], [None, None, None])
        # The sentence's numbers are the limit's and the steps', not copies of them.
        with mock.patch.object(nsf, "RATE_SHARE", 0.8), mock.patch.object(nsf, "RATE_STEPS", 6):
            said = nsf.rate_limit_sentence(120.0)
        for words in ("when 6 steps one", "less than 0.8 of 6 asked", "no 7 rows one", "7 rows in 7 frames", "(7 are enough for an error above about 20 %)",
                      "an error of about 20 % or less is not found"):
            self.assertIn(words, said)
        # The sentence's examples, by made rows. Rows of a 132 Hz display with 120 asked: valid, with a wrong frame
        # for the page (its row is at 13 ms, which is frame 2 of 120 Hz), and the head's margin sentence does not come.
        fast = nsf.one_key(at_step(take(EACH_FRAME), 1000 / 132), "n", asked_hz=120)
        self.assertEqual((fast.get("rate_share"), fast["invalid"], fast["content_first"]["frame"]), (0.9, [], 2))
        self.assertIsNone(nsf.rate_margin_sentence([fast]))
        # A 120 Hz display whose rows come each second frame, with 60 asked: valid, as rows of a 60 Hz display.
        half = nsf.one_key(at_step(take(EACH_FRAME), 2 * STEP), "n", asked_hz=60)
        self.assertEqual((half.get("rate_share"), half["invalid"], half["first_frame_span"]["no_row"]), (0.997, [], 0))
        # Each third frame with 40 asked: valid too. Steps of 2 and 1 frames by turns with 80 asked, which is 33 % too
        # low: valid, with no word, when the rows' median step is the long one, and INVALID when it is the short one
        # (the frame time is then the rows' own). 9 rows one after the other at the display's rate: 80 asked is INVALID.
        third = nsf.one_key(at_step(take(EACH_FRAME), 3 * STEP), "n", asked_hz=40)
        turns = nsf.one_key(take([(OLD, ROW_OLD)] + [(NEW, ROW_NEW), None, (NEW, ROW_NEW)] * 79), "n", asked_hz=80)
        self.assertEqual((third["invalid"], turns["invalid"], nsf.rate_margin_sentence([third, turns])), ([], [], None))
        self.assertEqual((third.get("rate_share"), turns.get("rate_share")), (1.0, 1.0))
        short = nsf.one_key(take([(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW), (NEW, ROW_NEW), None] * 79), "n", asked_hz=80)
        self.assertEqual((kinds(short), kinds(nsf.one_key(take(EACH_FRAME), "n", asked_hz=80))), (["display"], ["display"]))


class SecondFirstTests(unittest.TestCase):
    """The second key's own first frame, from that key's own opening mark."""
    MARKS = [{"name": "cmdN.start", "ms": 0.0}, {"name": "cmdN.start", "ms": 104.0}]
    # The first key's page and row are on the screen from frame 4 of the recording; the second key was due at
    # 100 ms, its mark began 4 ms after that, and its row is in the third frame after its due time.
    PICTURES = [(OLD, ROW_OLD)] * 3 + [(NEW, HALF)] * 11 + [(NEW, ROW_NEW)] * 240

    def test_the_second_keys_first_frame_is_the_first_row_after_its_mark_with_the_tabs_region_unlike_the_row_before(self):
        got = nsf.one_key(take(self.PICTURES, spans=self.MARKS), "n", gap_ms=100, asked_hz=120)
        self.assertEqual(got["invalid"], [])
        self.assertEqual(got.get("second_first"), {
            "region": "outside", "mark_ms": 4.0, "frame": 3, "ms": 25, "file": "frame-017.png", "after_mark_ms": 21.0,
            "content": "final", "moving_at_the_mark": False,
            "span": {"frames": 3, "rows": 3, "no_row": 0, "no_row_frames": [], "longest_gap_ms": 9.0, "early_ms_at_most": 0.0}})
        self.assertEqual(got["pictures"].get("second_first"), "frame-017.png")
        self.assertEqual(nsf.summarize([got]).get("second_first"), {"frame": {"p50": 3, "max": 3}, "ms": {"p50": 25, "max": 25}})

    def test_a_frame_with_no_row_before_the_second_keys_first_frame_makes_the_row_invalid(self):
        pictures = list(self.PICTURES)
        pictures[13] = None  # the second frame after the second key's due time has no row
        got = nsf.one_key(take(pictures, spans=self.MARKS), "n", gap_ms=100, asked_hz=120)
        second = got.get("second_first") or {}
        self.assertEqual((second.get("frame"), second.get("span")), (3, {"frames": 3, "rows": 2, "no_row": 1, "no_row_frames": [2],
                                                                         "longest_gap_ms": 17.0, "early_ms_at_most": 8.3}))
        self.assertEqual(got["invalid"], ["no-row: 1 of the 3 frames from the second key's mark to second_first have no row (frames 2; "
                                          "the longest step between rows 17 ms): second_first can be at most 8.3 ms early"])

    def test_a_frame_with_no_row_before_a_row_in_which_the_tabs_region_did_not_move_leaves_the_second_keys_time_proved(self):
        # The second key's row comes in the FOURTH frame after its due time. The second frame has no row, and the third
        # frame's row has the region as the first frame's: the second key's change was not in the frame with no row.
        pictures = [(OLD, ROW_OLD)] * 3 + [(NEW, HALF)] * 12 + [(NEW, ROW_NEW)] * 240
        pictures[13] = None
        got = nsf.one_key(take(pictures, spans=self.MARKS), "n", gap_ms=100, asked_hz=120)
        second = got.get("second_first") or {}
        self.assertEqual((second.get("frame"), second.get("span")), (4, {"frames": 4, "rows": 3, "no_row": 1, "no_row_frames": [2],
                                                                         "longest_gap_ms": 17.0, "early_ms_at_most": 0.0}))
        self.assertEqual(got["invalid"], [])

    def test_a_row_says_why_it_has_no_second_first(self):
        one = nsf.one_key(take([(NEW, ROW_NEW)] * 240), "n", asked_hz=120)
        self.assertEqual((one.get("second_first", 0), one.get("second_first_source")), (None, "one key"))
        no_mark = nsf.one_key(take(self.PICTURES), "n", gap_ms=100, asked_hz=120)
        self.assertEqual((no_mark.get("second_first", 0), no_mark.get("second_first_source")),
                         (None, "not known: the spans have no second `cmdN.start` mark"))
        tabs = [{"name": "newTab.open", "ms": 0.0}, {"name": "newTab.open", "ms": 104.0}]
        no_strip = nsf.one_key(take([(NEW, STILL)] * 252, spans=tabs), "t", gap_ms=100, asked_hz=120)
        self.assertEqual((no_strip.get("second_first", 0), no_strip.get("second_first_source")),
                         (None, "not known: the rows carry no strip numbers"))
        still = nsf.one_key(take([(NEW, ROW_NEW)] * 252, spans=self.MARKS), "n", gap_ms=100, asked_hz=120)
        self.assertEqual((still.get("second_first", 0), still.get("second_first_source")),
                         (None, "not known: no row after the second key's `cmdN.start` mark has the outside region unlike the row before it"))

    def test_a_region_that_still_moves_at_the_second_keys_mark_is_said(self):
        # The first key's tab grows in the strip for 20 frames: the strip is unlike the row before it in each row at
        # the second key's mark (103 ms) too, so the first row after the mark is only the earliest one that can be its.
        tabs = [{"name": "newTab.open", "ms": 0.0}, {"name": "newTab.open", "ms": 103.0}]
        pictures = [dict(content=NEW, outside=STILL, strip=(0.01 * min(index, 20), 0.01 * max(0, 20 - index))) for index in range(1, 253)]
        got = nsf.one_key(take(pictures, spans=tabs), "t", gap_ms=100, asked_hz=120)
        second = got.get("second_first") or {}
        self.assertEqual((second.get("region"), second.get("frame"), second.get("ms"), second.get("after_mark_ms"), second.get("moving_at_the_mark")),
                         ("strip", 1, 8, 5.0, True))


class RecordsByKindTests(unittest.TestCase):
    """The app's opening records are a fact by kind; the proof of the input is its marks and its count of tabs or workspaces."""
    N1, N2 = [{"name": "cmdN.start", "ms": 0.0}], [{"name": "cmdN.start", "ms": 0.0}, {"name": "cmdN.start", "ms": 103.0}]
    T1, T2 = [{"name": "newTab.open", "ms": 0.0}], [{"name": "newTab.open", "ms": 0.0}, {"name": "newTab.open", "ms": 104.0}]

    def test_the_four_kinds_of_rows_of_a_take_are_each_a_proved_input(self):
        # (key, keys sent, the new records' spare flags, the marks): a Cmd-N that took the workspace reserved at idle makes
        # no record; a second Cmd-N with no reservation makes one; a Cmd-T of a spare one; a Cmd-T of a cold page two.
        for key, keys, spare, marks in (("n", 1, [], self.N1), ("n", 2, [True], self.N2), ("n", 2, [], self.N2),
                                        ("t", 1, [True], self.T1), ("t", 2, [True, False, False], self.T2)):
            with self.subTest(key=key, keys=keys, spare=spare):
                self.assertEqual(nsf.input_proof(key, keys, len(spare), keys, marks)[0], [])

    def test_the_records_of_a_row_are_a_fact_by_kind(self):
        fact = getattr(nsf, "records_fact", lambda *_: "the reader has no fact about the records")
        self.assertEqual(fact("n", 1, []), {"count": 0, "spare": [], "possible": [0, 2], "keys_with_no_record": 1})
        self.assertEqual(fact("n", 2, [True]), {"count": 1, "spare": [True], "possible": [0, 4], "keys_with_no_record": 1})
        self.assertEqual(fact("t", 1, [True]), {"count": 1, "spare": [True], "possible": [1, 2], "more_than_the_keys": 0})
        self.assertEqual(fact("t", 2, [True, False, False]), {"count": 3, "spare": [True, False, False], "possible": [2, 4], "more_than_the_keys": 1})

    def test_a_count_of_records_that_the_keys_cannot_make_is_a_fault(self):
        self.assertEqual(nsf.input_proof("t", 2, 1, 2, self.T2)[0], ["input: 2 keys sent, the app recorded 1 openings (2 to 4 are possible for Cmd-T)"])
        self.assertEqual(nsf.input_proof("t", 1, 3, 1, self.T1)[0], ["input: 1 keys sent, the app recorded 3 openings (1 to 2 are possible for Cmd-T)"])
        self.assertEqual(nsf.input_proof("n", 1, 3, 1, self.N1)[0], ["input: 1 keys sent, the app recorded 3 openings (0 to 2 are possible for Cmd-N)"])

    def test_the_marks_and_the_count_stay_the_proof(self):
        self.assertEqual(nsf.input_proof("n", 2, 0, 1, self.N2)[0], ["input: 2 keys sent, 1 more workspaces after them"])
        self.assertEqual(nsf.input_proof("t", 2, 2, 2, self.T1)[0], ["input: 2 keys sent, 1 `newTab.open` marks"])


class ScreenRowTests(unittest.TestCase):
    """The mode's rows and printed lines with the frames that have no row, the second key's frame and the records."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="new-surface-screen-test-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.folder, ignore_errors=True))

    def run_mode(self, app, launch_fault=None, **changed):
        def make(socket_path, count, live, url, deadline, out):
            app.workspaces += count
            return {"asked_more": count, "live_shells": live, "maker_exit": 0, "maker_said_made": count, "seed_s": 0.0}
        screen = new_surface_screen.Screen(options(self.folder, **changed), app.rpc, app.tools(), sleep=app.pause, make_session=make)
        screen.launch_fault = launch_fault
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report = screen.run()
        return report, said.getvalue()

    def test_a_cmd_n_that_makes_no_record_is_a_valid_row_and_the_row_has_the_fact(self):
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 252)
        app.records = []  # each Cmd-N took a workspace that the app reserved at idle
        report, said = self.run_mode(app, keys="n", gaps="0,100", runs=1)
        self.assertEqual([row["invalid"] for row in report["rows"]], [[], []])
        self.assertEqual([row.get("opening_records") for row in report["rows"]],
                         [{"count": 0, "spare": [], "possible": [0, 2], "keys_with_no_record": 1},
                          {"count": 0, "spare": [], "possible": [0, 4], "keys_with_no_record": 2}])
        self.assertEqual([" records=[]" in line for line in said.splitlines() if "-ROW cmd-n-" in line], [True, True])

    def test_a_cmd_t_of_a_cold_page_makes_two_records_and_is_a_valid_row(self):
        app = FakeApp(self.folder, [(NEW, STILL)] * 252)
        app.records = [True, False, False]
        report, said = self.run_mode(app, keys="t", gaps="100", runs=1)
        self.assertEqual((report["rows"][0]["invalid"], (report["rows"][0].get("opening_records") or {}).get("more_than_the_keys")), ([], 1))
        self.assertIn(" records=[true, false, false]", said)

    def test_a_rows_line_says_the_frames_with_no_row_and_how_early_its_first_frame_can_be(self):
        report, said = self.run_mode(FakeApp(self.folder, [(OLD, ROW_OLD), None] + [(NEW, ROW_NEW)] * 238), keys="n", runs=1)
        line = next(line for line in said.splitlines() if "-ROW cmd-n-idle-0" in line)
        self.assertIn("INVALID no-row: 1 of the 3 frames from the key to content_first have no row", line)
        self.assertIn(" no_row_to_content_first=1/3 longest_gap_ms=17 early_ms_at_most=8.3 partial state: not seen in 1 frames", line)
        self.assertIn("over EACH of 1 rows (also the INVALID ones): in 1 rows (1 with one directly before content_first: the time is "
                      "not proved; 0 with each before a row of the old picture: the time is proved, a partial state is not seen), p50 1 max 1", said)
        self.assertEqual(report["cases"]["cmd-n/idle"]["valid"], 0)
        valid, said = self.run_mode(FakeApp(self.folder, [(OLD, ROW_OLD)] * 2 + [(NEW, ROW_NEW)] * 238), keys="n", runs=1)
        self.assertIn(": valid ", said)
        self.assertIn(" no_row_to_content_first=0/3 longest_gap_ms=9 early_ms_at_most=0", said)
        self.assertNotIn("partial state", next(line for line in said.splitlines() if "-ROW cmd-n-idle-0" in line))

    def test_a_rows_line_says_that_a_partial_state_is_not_seen_when_its_time_is_proved(self):
        # Frame 1 has no row and frame 2's row shows the old picture: a valid row, with the count and the words.
        report, said = self.run_mode(FakeApp(self.folder, [None, (OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 238), keys="n", runs=1)
        line = next(line for line in said.splitlines() if "-ROW cmd-n-idle-0" in line)
        self.assertIn(": valid ", line)
        self.assertIn(" no_row_to_content_first=1/3 longest_gap_ms=17 early_ms_at_most=0 partial state: not seen in 1 frames", line)
        self.assertEqual((report["cases"]["cmd-n/idle"]["valid"], report["rows"][0].get("partial_state_not_seen")), (1, 1))
        # The same for the second key's own span: the second frame after its due time has no row, the third did not move.
        pictures = [(OLD, ROW_OLD)] * 3 + [(NEW, HALF)] * 10 + [None, (NEW, HALF)] + [(NEW, ROW_NEW)] * 240
        report, said = self.run_mode(FakeApp(self.folder, pictures), keys="n", gaps="100", runs=1)
        self.assertEqual(report["rows"][0]["invalid"], [])
        self.assertIn(" second_no_row=1/4 second_early_ms_at_most=0 second key's partial state: not seen in 1 frames moving_at_the_mark=False", said)

    def test_a_row_of_two_keys_says_the_second_keys_own_first_frame_and_keeps_its_picture(self):
        app = FakeApp(self.folder, [(OLD, ROW_OLD)] * 3 + [(NEW, HALF)] * 11 + [(NEW, ROW_NEW)] * 240)
        report, said = self.run_mode(app, keys="n", gaps="100", runs=1)
        row = report["rows"][0]
        self.assertEqual((row["invalid"], (row.get("second_first") or {}).get("frame")), ([], 3))
        self.assertIn(" second_first=[3, 25.0] after_mark_ms=25 second_no_row=0/3 second_early_ms_at_most=0 moving_at_the_mark=False", said)
        self.assertEqual(row["kept_pictures"].get("second_first"), "cmd-n-gap100-0-second_first-frame-017.png")
        still, said = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 252), keys="n", gaps="100", runs=1)
        self.assertIn(" second_first=none", said)

    def test_a_launch_that_is_not_a_clean_one_makes_each_row_invalid(self):
        fault = "launch: run.json says `recovery` true: the launch follows a crash"
        report, said = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240), launch_fault=fault, keys="n,t", runs=1)
        self.assertEqual([row["invalid"] for row in report["rows"]], [[fault], [fault]])
        self.assertEqual([case["invalid"] for case in report["cases"].values()], [["launch"], ["launch"]])


if __name__ == "__main__":
    unittest.main()
