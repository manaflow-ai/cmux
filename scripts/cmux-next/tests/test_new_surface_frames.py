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


def streamed(reply, idle=(), own=(), lost=(), **changed):
    """`reply` as a build with the recorder's counts of its stream writes it (`screen_stream`): each row's file has
    the row's place in the recording as its number, and each row is a complete buffer but the places `idle` (idle
    buffers: the last picture again). `own`: the places of the rows with the handler's own time. `lost`: the buffers
    that made no row, each (ms after the reply's zero, why: a status's raw number, -1 no status, -2 no picture,
    -3 idle before a picture) and, as the build that says a buffer's clock writes it, a third value (1: the time is
    the handler's own, 0: the display's). `changed`: the fields of `screen_stream` that a test sets itself."""
    rows = [dict(frame) for frame in reply["frames"]]
    times = [round(STEP * (int(frame["file"][6:9]) - 2), 1) for frame in rows]
    for place, frame in enumerate(rows):
        frame["file"] = f"frame-{place:03d}.png"
    status = "".join("i" if place in idle else "c" for place in range(len(rows)))
    whys = [entry[1] for entry in lost]
    counts = {"buffers": len(rows) + len(lost), "rows": len(rows), "row_status": status, "row_ms": times,
              "complete": status.count("c") + whys.count(-2), "idle": status.count("i") + whys.count(-3),
              "other_status": {str(why): whys.count(why) for why in sorted(set(whys)) if why >= 0},
              "no_status": whys.count(-1), "no_picture": whys.count(-2), "idle_before_a_picture": whys.count(-3),
              "own_time_rows": sorted(own), "no_display_time": len(own), "display_time_later": 0,
              "no_row": [[float(value) for value in entry] for entry in lost],
              "lag_ms_max": 3.2, "lag_ms_mean": 1.1, "work_ms_max": 2.5, "work_ms_mean": 0.9}
    return {**reply, "frames": rows, "screen_stream": {**counts, **changed}}


def gap_kinds(span):
    """The frames with no row of a stream's span, by the kind of their gap (the kinds with a gap only)."""
    return {kind: span[kind]["frames"] for kind in nsf.STREAM_KINDS if span[kind]["gaps"]}


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


class StreamCountsTests(unittest.TestCase):
    """The recorder's counts of its stream say why a frame of the display has no row. They are facts of a row: no
    INVALID reason reads them."""

    # Frames 2 and 3 have no row; the page is in frame 4's row (the row at place 3 of the recording).
    HOLE = [(OLD, ROW_OLD), None, None] + [(NEW, ROW_NEW)] * 237
    # The page is in frame 1; frames 101 and 102 of the still picture have no row (the row after them: place 102).
    LATER = [(NEW, ROW_NEW)] * 100 + [None, None] + [(NEW, ROW_NEW)] * 138
    NO_ROW = ("no-row: 2 of the 4 frames from the key to content_first have no row (frames 2, 3; the longest step between "
              "rows 25 ms): content_first can be at most 16.7 ms early")

    def stream(self, pictures, **said):
        return nsf.one_key(streamed(take(pictures), **said), "n", asked_hz=120)["stream"]

    def test_a_reply_with_no_counts_of_the_stream_has_none(self):
        got = nsf.one_key(take(self.HOLE), "n", asked_hz=120)
        self.assertIn("stream", got)
        self.assertIsNone(got["stream"])
        # A recording with no row after the key: the same field, and with counts the counts alone.
        self.assertIsNone(nsf.one_key(take([]), "n", asked_hz=120)["stream"])
        got = nsf.one_key(streamed(take([])), "n", asked_hz=120)["stream"]
        self.assertEqual((got["rows"], got["counts_agree"], got["to_content_first"], got["steps"]), (2, True, None, None))

    def test_the_counts_are_in_the_row_as_whole_numbers_and_they_agree(self):
        # The app's numbers are JSON doubles: a count comes back as a whole number.
        got = self.stream(self.HOLE, idle=(5, 6), own=(9,), lost=[(20.0, 3), (500.0, -2), (600.0, -1)], rows=240.0)
        names = ("buffers", "rows", "complete", "idle", "other_status", "no_status", "no_picture", "idle_before_a_picture",
                 "own_time_rows", "no_display_time", "display_time_later", "buffers_with_no_row", "no_row_not_listed",
                 "lag_ms_max", "lag_ms_mean", "work_ms_max", "work_ms_mean", "counts_agree")
        self.assertEqual({name: got[name] for name in names},
                         {"buffers": 243, "rows": 240, "complete": 239, "idle": 2, "other_status": {"3": 1}, "no_status": 1,
                          "no_picture": 1, "idle_before_a_picture": 0, "own_time_rows": 1, "no_display_time": 1,
                          "display_time_later": 0, "buffers_with_no_row": 3, "no_row_not_listed": 0, "lag_ms_max": 3.2,
                          "lag_ms_mean": 1.1, "work_ms_max": 2.5, "work_ms_mean": 0.9, "counts_agree": True})
        self.assertIs(type(got["rows"]), int)
        self.assertEqual((got["rows_after_key"], got["content_first_status"]), ({"complete": 236, "idle": 2, "not_known": 0}, "complete"))

    def test_a_gap_with_no_buffer_is_named_by_the_row_after_it(self):
        got = self.stream(self.HOLE)
        self.assertEqual((got["to_content_first"]["gaps"], got["to_content_first"]["frames"], gap_kinds(got["to_content_first"])),
                         (1, 2, {"then_complete": 2}))
        self.assertEqual((got["before_content_first"], got["content_first_status"], gap_kinds(got["whole_take"])),
                         ("then_complete", "complete", {"then_complete": 2}))
        # A gap in the still picture after the first content: an idle buffer comes after it, or a complete one.
        got = self.stream(self.LATER, idle=(102,))
        self.assertEqual((gap_kinds(got["whole_take"]), got["to_content_first"]["gaps"], got["before_content_first"]), ({"then_idle": 2}, 0, "no_gap"))
        self.assertEqual(gap_kinds(self.stream(self.LATER)["whole_take"]), {"then_complete": 2})

    def test_a_gap_with_a_buffer_that_made_no_row_is_named_first(self):
        # A buffer that made no row at 20 ms, between the rows at 8 ms and at 33 ms: another status, no status, a
        # picture that did not copy, an idle buffer before a picture. The row after the gap has the handler's time.
        for why in (3, -1, -2, -3):
            got = self.stream(self.HOLE, own=(3,), lost=[(20.0, why)])
            self.assertEqual((gap_kinds(got["to_content_first"]), got["before_content_first"]), ({"with_a_buffer": 2}, "with_a_buffer"), why)
        # A buffer at another time is not in the gap.
        got = self.stream(self.HOLE, lost=[(100.0, 3)])
        self.assertEqual((gap_kinds(got["to_content_first"]), got["buffers_with_no_row"]), ({"then_complete": 2}, 1))

    def test_a_gap_next_to_a_row_with_the_handlers_own_time_is_named_before_the_status(self):
        for place in (2, 3):  # the row before the gap, the row after it
            self.assertEqual(gap_kinds(self.stream(self.HOLE, own=(place,))["to_content_first"]), {"own_time": 2}, place)
        self.assertEqual(gap_kinds(self.stream(self.HOLE, own=(4,))["to_content_first"]), {"then_complete": 2})

    def test_a_buffer_with_the_handlers_own_time_never_makes_a_gap_with_a_buffer(self):
        # The frame of such a buffer is at its time OR BEFORE it: the gap that its time is in is not known, whatever
        # the buffer's reason and also next to a row with the handler's own time. The row counts such buffers apart.
        one, none = {"gaps": 1, "frames": 2}, {"gaps": 0, "frames": 0}
        for why in (3, -1, -2, -3):
            got = self.stream(self.HOLE, own=(3,), lost=[(20.0, why, 1)])
            self.assertEqual((gap_kinds(got["to_content_first"]), got["before_content_first"], got["no_row_own_time"], got["counts_agree"]),
                             ({"not_known": 2}, "not_known", 1, True), why)
            self.assertEqual((got["own_time_buffer_gaps"], got["kind_not_safe_gaps"], got["lists"]["no_row"]),
                             ({"whole_take": one, "to_content_first": one}, {"whole_take": none, "to_content_first": none}, [[20.0, why, 1]]), why)
        # The same buffer with the display's time is in its gap by that time.
        got = self.stream(self.HOLE, lost=[(20.0, 3, 0)])
        self.assertEqual((gap_kinds(got["to_content_first"]), got["no_row_own_time"], got["own_time_buffer_gaps"], got["lists"]["no_row"]),
                         ({"with_a_buffer": 2}, 0, {"whole_take": none, "to_content_first": none}, [[20.0, 3, 0]]))
        # A buffer with the display's time in the same gap names it; the gap still counts as one with an own-time buffer.
        got = self.stream(self.HOLE, lost=[(20.0, 3, 1), (25.0, -1, 0)])
        self.assertEqual((gap_kinds(got["to_content_first"]), got["no_row_own_time"], got["own_time_buffer_gaps"]["to_content_first"]),
                         ({"with_a_buffer": 2}, 1, one))
        # An entry of 2 values (a build that does not say the clock) reads as before, and the row says `not said`.
        for lost in ([(20.0, 3)], [(20.0, 3), (500.0, -2, 1)]):
            got = self.stream(self.HOLE, lost=lost)
            self.assertEqual((gap_kinds(got["to_content_first"]), got["no_row_own_time"], got["lists"]["no_row"][0], got["counts_agree"]),
                             ({"with_a_buffer": 2}, None, [20.0, 3], True), lost)
        # A third value that is not 0 or 1 is no entry: the list is then not whole, and the gap is not known.
        got = self.stream(self.HOLE, lost=[(20.0, 3)], no_row=[[20.0, 3.0, 2.0]])
        self.assertEqual((gap_kinds(got["to_content_first"]), got["no_row_not_listed"], got["no_row_own_time"], got["lists"]["no_row"]),
                         ({"not_known": 2}, 1, 0, []))

    def test_the_kind_of_a_gap_that_ends_within_the_lag_before_an_own_time_buffer_is_not_safe(self):
        # The gap of frames 2 and 3 ends at the row at 33 ms; the largest lag of a buffer that made a row is 3.2 ms. A
        # buffer with the handler's own time at most 3.2 ms after that row (with the half ms of the rows' whole ms)
        # can be a frame of the gap: the gap keeps its kind, and the row counts it as not safe.
        one, none = {"gaps": 1, "frames": 2}, {"gaps": 0, "frames": 0}

        def not_safe(pictures=self.HOLE, **said):
            got = self.stream(pictures, **said)
            return gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"]["whole_take"], got["own_time_buffer_gaps"]["whole_take"]

        for at in (34.0, 35.0, 36.7):
            self.assertEqual(not_safe(lost=[(at, 3, 1)]), ({"then_complete": 2}, one, none), at)
        self.assertEqual(not_safe(idle=(3,), lost=[(35.0, -1, 1)]), ({"then_idle": 2}, one, none))
        self.assertEqual(not_safe(own=(3,), lost=[(35.0, -1, 1)]), ({"own_time": 2}, one, none))
        # Later than the lag after the row, at the display's time, or before the gap: the kind is safe.
        for lost in ([(36.8, 3, 1)], [(40.0, 3, 1)], [(35.0, 3, 0)], [(35.0, 3)], [(5.0, 3, 1)], []):
            self.assertEqual(not_safe(lost=lost), ({"then_complete": 2}, none, none), lost)
        # A reply with no lag: each gap before such a buffer is not safe.
        for lag in (None, "long", float("nan")):
            self.assertEqual(not_safe(lost=[(40.0, 3, 1)], lag_ms_max=lag), ({"then_complete": 2}, one, none), lag)
            self.assertEqual(not_safe(lost=[(5.0, 3, 1)], lag_ms_max=lag), ({"then_complete": 2}, none, none), lag)
        # The same when no row has the display's time: the reply's lag is then the lag of no buffer.
        each = tuple(range(240))
        self.assertEqual(not_safe(own=each, lost=[(40.0, 3, 1)], lag_ms_max=0.0), ({"own_time": 2}, one, none))
        self.assertEqual(not_safe(own=each[1:], lost=[(40.0, 3, 1)], lag_ms_max=0.0), ({"own_time": 2}, none, none))
        # A gap that names no cause is not counted: it has a buffer with the display's time, or it is not known.
        self.assertEqual(not_safe(lost=[(20.0, 3, 0), (35.0, -1, 1)]), ({"with_a_buffer": 2}, none, none))
        self.assertEqual(not_safe(lost=[(20.0, 3, 1), (35.0, -1, 1)]), ({"not_known": 2}, none, one))
        # 2 gaps (frames 2 and 4 have no row; rows at 25 ms and 42 ms): a buffer at 27 ms is in the second gap, and
        # the first gap ends 2 ms before it.
        twice = [(OLD, ROW_OLD), None, (OLD, ROW_OLD), None] + [(NEW, ROW_NEW)] * 236
        got = self.stream(twice, lost=[(27.0, -1, 1)])
        self.assertEqual((gap_kinds(got["to_content_first"]), got["before_content_first"], got["kind_not_safe_gaps"]["to_content_first"],
                          got["own_time_buffer_gaps"]["to_content_first"]),
                         ({"then_complete": 1, "not_known": 1}, "not_known", {"gaps": 1, "frames": 1}, {"gaps": 1, "frames": 1}))
        # A gap after the first content is in the whole take's count only; a recording with no first content has no such count.
        got = self.stream(self.LATER, lost=[(860.0, 3, 1)])
        self.assertEqual((got["kind_not_safe_gaps"], nsf.apart_of(got, "kind_not_safe_gaps")), ({"whole_take": one, "to_content_first": none}, 0))
        got = nsf.one_key(streamed(take([]), lost=[(35.0, 3, 1)]), "n", asked_hz=120)["stream"]
        self.assertEqual((got["kind_not_safe_gaps"], got["own_time_buffer_gaps"], got["no_row_own_time"], nsf.apart_of(got, "kind_not_safe_gaps")),
                         ({"whole_take": none, "to_content_first": None}, {"whole_take": none, "to_content_first": None}, 1, 0))
        self.assertEqual(nsf.apart_of(self.stream(self.HOLE, lost=[(35.0, 3, 1)]), "kind_not_safe_gaps"), 1)

    def late_row(self, at, own=(3,), sent=0.0, **said):
        """The stream of a recording whose buffers came in this order: a row at 8 ms (the display's time, frame 1), a
        row that the handler took at `at` ms (place 3 of the recording; with no display time when it is in `own`),
        a row at 25 ms (the display's time, frame 3), then each frame from the page's first one (frame 4, 33 ms).
        Frame 2 has no row. `sent`: the key went in that many ms before the reply's zero."""
        reply = take([(OLD, ROW_OLD), None, (OLD, ROW_OLD)] + [(NEW, ROW_NEW)] * 237, before_send_ms=sent)
        reply["frames"] = reply["frames"][:3] + [{**row(3, OLD, ROW_OLD), "ms": at}] + reply["frames"][3:]
        reply = streamed({**reply, "frame_count": len(reply["frames"])}, own=own, **said)
        reply["screen_stream"]["row_ms"][3] = float(at)
        return nsf.one_key(reply, "n", asked_hz=120)["stream"]

    def test_the_kind_of_a_gap_that_ends_before_a_later_row_with_the_handlers_own_time_is_not_safe(self):
        # A row with no display time has the handler's time. The handler took it at 27 ms, later than the display's
        # time (25 ms) of the row that came after it: the reader's order of the rows is 8, 25, 27 ms, the row is not
        # next to the gap of frame 2, and that gap can be its true one. The gap keeps its kind and is not safe.
        one, none = {"gaps": 1, "frames": 1}, {"gaps": 0, "frames": 0}

        def not_safe(got):
            return (gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"]["to_content_first"],
                    got["kind_not_safe_by_row_gaps"]["to_content_first"], got["own_time_buffer_gaps"]["whole_take"])

        got = self.late_row(27)
        self.assertEqual((gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"]), ({"then_complete": 1}, {"whole_take": one, "to_content_first": one}))
        self.assertEqual(not_safe(got), ({"then_complete": 1}, one, one, none))
        self.assertEqual((got["counts_agree"], got["own_time_rows"], got["lists"]["own_time_rows"], got["lists"]["places_after_key"][:4],
                          got["kind_not_safe_gaps"]["whole_take"], got["kind_not_safe_by_row_gaps"]["whole_take"],
                          nsf.apart_of(got, "kind_not_safe_by_row_gaps")), (True, 1, [3], [2, 4, 3, 5], one, one, 1))
        # Each kind that names a cause: the row after the gap is an idle buffer's, or it has the handler's own time too.
        self.assertEqual(not_safe(self.late_row(27, idle=(4,))), ({"then_idle": 1}, one, one, none))
        self.assertEqual(not_safe(self.late_row(27, own=(3, 4))), ({"own_time": 1}, one, one, none))
        # The limit is the largest lag plus 1 ms: the 2 rows' times are whole ms.
        self.assertEqual(not_safe(self.late_row(27, lag_ms_max=1.0)), ({"then_complete": 1}, one, one, none))
        self.assertEqual(not_safe(self.late_row(27, lag_ms_max=0.9)), ({"then_complete": 1}, none, none, none))
        self.assertEqual(not_safe(self.late_row(29)), ({"then_complete": 1}, one, one, none))
        self.assertEqual(not_safe(self.late_row(30)), ({"then_complete": 1}, none, none, none))
        # A lag of 0 ms: the limit is 1 ms. The row 1 ms after the gap's end row counts, the row 2 ms after it does not.
        self.assertEqual(not_safe(self.late_row(26, lag_ms_max=0.0)), ({"then_complete": 1}, one, one, none))
        self.assertEqual(not_safe(self.late_row(27, lag_ms_max=0.0)), ({"then_complete": 1}, none, none, none))
        # 2 rows with the same time, 25 ms: the one that came first has the display's time and ends the gap, the one
        # after it (place 4) has the handler's own time. It counts, also with a lag of 0 ms.
        for lag in (3.2, 0.0):
            self.assertEqual(not_safe(self.late_row(25, own=(4,), lag_ms_max=lag)), ({"then_complete": 1}, one, one, none), lag)
        # A reply with no lag: each gap before such a row is not safe.
        self.assertEqual(not_safe(self.late_row(40)), ({"then_complete": 1}, none, none, none))
        for lag in (None, "long", float("nan")):
            self.assertEqual(not_safe(self.late_row(40, lag_ms_max=lag)), ({"then_complete": 1}, one, one, none), lag)
        # The same row with the display's time is no such row.
        self.assertEqual(not_safe(self.late_row(27, own=())), ({"then_complete": 1}, none, none, none))
        # A gap that names no cause is not counted.
        self.assertEqual(not_safe(self.late_row(27, lost=[(15.0, 3, 0)])), ({"with_a_buffer": 1}, none, none, none))
        self.assertEqual(not_safe(self.late_row(27, lost=[(15.0, 3, 1)])), ({"not_known": 1}, none, none, one))
        # A buffer with no row and a row after one gap: the gap is counted one time, and it is one by a row.
        self.assertEqual(not_safe(self.late_row(27, lost=[(26.0, 3, 1)])), ({"then_complete": 1}, one, one, none))
        got = self.late_row(30, lost=[(26.0, 3, 1)])
        self.assertEqual((gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"], got["kind_not_safe_by_row_gaps"]),
                         ({"then_complete": 1}, {"whole_take": one, "to_content_first": one}, {"whole_take": none, "to_content_first": none}))
        # The key went in 5.2 ms before the reply's zero: each row is 5.2 ms later, frame 1 has no row too, and the 2
        # rows' times are no whole numbers. The row is still 2 ms after the gap's end row, to 3 places.
        got = self.late_row(27, sent=5.2, lag_ms_max=1.0)
        self.assertEqual((gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"]["whole_take"], got["kind_not_safe_by_row_gaps"]["whole_take"]),
                         ({"then_complete": 2}, one, one))

    def test_a_row_with_the_handlers_own_time_next_to_its_gap_or_before_it_makes_no_gap_not_safe(self):
        # The gap of frames 2 and 3 is between the rows at places 2 (8 ms) and 3 (33 ms). Its own end rows name it
        # (`own_time`) and do not make it not safe, also with no lag; a row before it does not; the next row (place
        # 4, 42 ms) does when the lag is 8 ms or more (42 - 33 - 1), or not known.
        one, none = {"gaps": 1, "frames": 2}, {"gaps": 0, "frames": 0}

        def by_row(pictures=self.HOLE, **said):
            got = self.stream(pictures, **said)
            return gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"], got["kind_not_safe_by_row_gaps"]

        both, no = {"whole_take": one, "to_content_first": one}, {"whole_take": none, "to_content_first": none}
        for place in (2, 3):
            for lag in (3.2, None):
                self.assertEqual(by_row(own=(place,), lag_ms_max=lag), ({"own_time": 2}, no, no), (place, lag))
        self.assertEqual(by_row(own=(1,), lag_ms_max=None), ({"then_complete": 2}, no, no))
        self.assertEqual(by_row(own=(4,)), ({"then_complete": 2}, no, no))
        self.assertEqual(by_row(own=(4,), lag_ms_max=7.9), ({"then_complete": 2}, no, no))
        self.assertEqual(by_row(own=(4,), lag_ms_max=8.0), ({"then_complete": 2}, both, both))
        self.assertEqual(by_row(own=(4,), lag_ms_max=None), ({"then_complete": 2}, both, both))
        self.assertEqual(by_row(own=(239,), lag_ms_max=None), ({"then_complete": 2}, both, both))
        # The nearest such row after the gap decides: a far one after a near one changes nothing.
        self.assertEqual(by_row(own=(4, 9), lag_ms_max=8.0), ({"then_complete": 2}, both, both))
        self.assertEqual(by_row(own=(5, 9), lag_ms_max=8.0), ({"then_complete": 2}, no, no))
        # A reply that does not say which rows have the handler's own time: no gap is counted by a row, the row has
        # no list of them, and its counts do not agree.
        for not_said in (None, "3", [1.5]):
            got = self.stream(self.HOLE, own_time_rows=not_said, lag_ms_max=None)
            self.assertEqual((got["kind_not_safe_by_row_gaps"], got["lists"]["own_time_rows"], got["counts_agree"]), (no, None, False), not_said)
        # A gap after the first content is in the whole take's count only; a recording with no row after the key has none.
        after = {"whole_take": one, "to_content_first": none}
        self.assertEqual(by_row(self.LATER, own=(103,), lag_ms_max=None), ({"then_complete": 2}, after, after))
        got = nsf.one_key(streamed(take([]), own=(1,)), "n", asked_hz=120)["stream"]
        self.assertEqual((got["kind_not_safe_by_row_gaps"], nsf.apart_of(got, "kind_not_safe_by_row_gaps")),
                         ({"whole_take": none, "to_content_first": None}, 0))

    def test_a_gap_with_a_buffer_and_an_end_row_with_the_handlers_own_time_is_not_safe(self):
        # The gap of frames 2 and 3 (between the rows at places 2 and 3) has a buffer that made no row, with the
        # display's time, in its window: its kind is `with_a_buffer`, the first in the order. With an end row that
        # has the handler's own time the limit of that window is not the display's time: the gap keeps its kind, is
        # not safe, and is counted apart from the gaps that are not safe by a later row.
        one, none = {"gaps": 1, "frames": 2}, {"gaps": 0, "frames": 0}
        both, no = {"whole_take": one, "to_content_first": one}, {"whole_take": none, "to_content_first": none}

        def by_end(pictures=self.HOLE, **said):
            got = self.stream(pictures, **said)
            return (gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"], got["kind_not_safe_by_end_row_gaps"],
                    got["kind_not_safe_by_row_gaps"])

        got = self.stream(self.HOLE, own=(3,), lost=[(20.0, 3, 0)])
        self.assertEqual((gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"], got["counts_agree"]), ({"with_a_buffer": 2}, both, True))
        self.assertEqual((got["kind_not_safe_by_end_row_gaps"], nsf.apart_of(got, "kind_not_safe_by_end_row_gaps")), (both, 1))
        # The row before the gap or the row after it; a buffer that does not say its clock, or one with each clock;
        # with a lag and with none.
        for place in (2, 3):
            for lost in ([(20.0, 3, 0)], [(20.0, -1)], [(20.0, 3, 1), (25.0, -1, 0)]):
                for lag in (3.2, None):
                    self.assertEqual(by_end(own=(place,), lost=lost, lag_ms_max=lag), ({"with_a_buffer": 2}, both, both, no), (place, lost, lag))
        # No end row with that time (no row, a row before the gap, the next row after it, also with no lag): not counted.
        for own in ((), (1,), (4,)):
            self.assertEqual(by_end(own=own, lost=[(20.0, 3, 0)], lag_ms_max=None), ({"with_a_buffer": 2}, no, no, no), own)
        # The other kinds are not in this count: a gap that is not known, and a gap of the kind `own_time`.
        self.assertEqual(by_end(own=(3,), lost=[(20.0, 3, 1)]), ({"not_known": 2}, no, no, no))
        self.assertEqual(by_end(own=(3,), lost=[(100.0, 3, 0)]), ({"own_time": 2}, no, no, no))
        # A gap that is not safe by a later row is in the count of those, not in this one.
        self.assertEqual(by_end(own=(4,), lag_ms_max=None), ({"then_complete": 2}, both, no, both))
        # A reply that does not say which rows have that time: no gap is counted, and its counts do not agree.
        got = self.stream(self.HOLE, own_time_rows=None, lost=[(20.0, 3, 0)])
        self.assertEqual((got["kind_not_safe_gaps"], got["kind_not_safe_by_end_row_gaps"], got["counts_agree"]), (no, no, False))
        # A gap after the first content is in the whole take's count only; a recording with no row after the key has none.
        after = {"whole_take": one, "to_content_first": none}
        self.assertEqual(by_end(self.LATER, own=(102,), lost=[(845.0, 3, 0)]), ({"with_a_buffer": 2}, after, after, no))
        got = nsf.one_key(streamed(take([]), own=(1,), lost=[(1.0, 3, 0)]), "n", asked_hz=120)["stream"]
        self.assertEqual((got["kind_not_safe_by_end_row_gaps"], nsf.apart_of(got, "kind_not_safe_by_end_row_gaps")),
                         ({"whole_take": none, "to_content_first": None}, 0))

    def test_a_lag_below_0_in_the_reply_is_no_lag(self):
        # The app writes no lag below 0. A reply with one: the lag is not known, so each gap before a buffer or a row
        # with the handler's own time is not safe, as with no lag in the reply. The row keeps the reply's number.
        one, none = {"gaps": 1, "frames": 2}, {"gaps": 0, "frames": 0}
        for lag in (-0.1, -5.0):
            got = self.stream(self.HOLE, lost=[(40.0, 3, 1)], lag_ms_max=lag)
            self.assertEqual((gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"]["whole_take"], got["lag_ms_max"]),
                             ({"then_complete": 2}, one, lag), lag)
            got = self.stream(self.HOLE, own=(239,), lag_ms_max=lag)
            self.assertEqual((got["kind_not_safe_gaps"]["whole_take"], got["kind_not_safe_by_row_gaps"]["whole_take"]), (one, one), lag)
        # A lag of 0 is a lag: the same buffer and the same row are then too far.
        got = self.stream(self.HOLE, lost=[(40.0, 3, 1)], own=(239,), lag_ms_max=0.0)
        self.assertEqual((got["kind_not_safe_gaps"]["whole_take"], got["kind_not_safe_by_row_gaps"]["whole_take"]), (none, none))
        # The head: a lag below 0 is not the largest lag of the rows, and with no other lag the lag is not known.
        low = nsf.one_key(streamed(take(self.HOLE), lag_ms_max=-5.0), "n", asked_hz=120)
        with_lag = nsf.one_key(streamed(take(self.HOLE), lag_ms_max=0.0), "n", asked_hz=120)
        self.assertIn("; the handler's lag at most not known ms; ", nsf.stream_sentence([low]))
        self.assertIn("; the handler's lag at most 0 ms; ", nsf.stream_sentence([low, with_lag]))
        # The same for a lag that is not finite.
        endless = nsf.one_key(streamed(take(self.HOLE), lag_ms_max=float("inf")), "n", asked_hz=120)
        self.assertIn("; the handler's lag at most not known ms; ", nsf.stream_sentence([endless]))

    def test_two_clocks_in_one_gap_a_list_that_is_not_whole_and_two_buffers_after_one_gap(self):
        one, none = {"gaps": 1, "frames": 2}, {"gaps": 0, "frames": 0}
        # An entry of 2 values (read as the display's time) and an entry with the handler's own time in the same gap.
        for lost in ([(20.0, 3), (22.0, -1, 1)], [(20.0, -1, 1), (22.0, 3)]):
            got = self.stream(self.HOLE, lost=lost)
            self.assertEqual((gap_kinds(got["to_content_first"]), got["no_row_own_time"], got["own_time_buffer_gaps"]["to_content_first"],
                              got["kind_not_safe_gaps"]["to_content_first"], got["counts_agree"]), ({"with_a_buffer": 2}, None, one, none, True), lost)
        # A list that is not whole (2 buffers made no row, the reply lists the first one) with a buffer that has the
        # handler's own time. The gap before the listed buffer keeps its kind and is not safe by that buffer; the
        # gap in which that buffer's time is, is not known; a gap after it is not known and not counted.
        part = {"other_status": {"3": 2}, "buffers": 242}
        got = self.stream(self.HOLE, lost=[(35.0, 3, 1)], **part)
        self.assertEqual((got["no_row_not_listed"], got["counts_agree"], gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"]["whole_take"],
                          got["own_time_buffer_gaps"]["whole_take"]), (1, True, {"then_complete": 2}, one, none))
        got = self.stream(self.HOLE, lost=[(20.0, 3, 1)], **part)
        self.assertEqual((gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"]["whole_take"], got["own_time_buffer_gaps"]["whole_take"]),
                         ({"not_known": 2}, none, one))
        got = self.stream(self.LATER, lost=[(35.0, 3, 1)], **part)
        self.assertEqual((got["no_row_not_listed"], gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"]["whole_take"],
                          got["own_time_buffer_gaps"]["whole_take"]), (1, {"not_known": 2}, none, none))
        # 2 buffers with the handler's own time after one gap, each within the lag: the gap is counted one time.
        for lost in ([(34.0, 3, 1), (35.0, -1, 1)], [(35.0, 3, 1), (40.0, -1, 1)], [(35.0, 3, 1), (35.0, 3, 1)]):
            got = self.stream(self.HOLE, lost=lost)
            self.assertEqual((gap_kinds(got["whole_take"]), got["kind_not_safe_gaps"], got["no_row_own_time"]),
                             ({"then_complete": 2}, {"whole_take": one, "to_content_first": one}, 2), lost)

    def test_a_stream_that_made_no_row_keeps_its_counts_alone_in_a_window_list_reply(self):
        # The app's reply for a stream that gave buffers and no row: the frames are the window list's, and the counts
        # are the stream's (the third test of FrameStripStreamReplyTests.swift has this `screen_stream`). The frames
        # are not the stream's rows: the reader keeps the counts and reads no gap of the window list's frames by them.
        said = {"buffers": 2.0, "rows": 0.0, "row_status": "", "complete": 0.0, "idle": 1.0, "other_status": {}, "no_status": 1.0,
                "no_picture": 0.0, "idle_before_a_picture": 1.0, "own_time_rows": [], "no_display_time": 0.0, "display_time_later": 0.0,
                "no_row": [[1.0, -3.0, 0.0], [9.3, -1.0, 1.0]], "row_ms": [],
                "lag_ms_max": 0.0, "lag_ms_mean": 0.0, "work_ms_max": 0.0, "work_ms_mean": 0.0}
        reply = {**take(self.HOLE, capture="window_list"), "capture_error": "ScreenCaptureKit gave no frame", "screen_stream": said}
        got = nsf.one_key(reply, "n", asked_hz=120)
        self.assertEqual((got["stream_fault"], got["stream_kept"], len(got["invalid"]), got["invalid"][0][:8]), (None, None, 2, "capture:"))
        stream = got["stream"]
        self.assertEqual((stream["buffers"], stream["rows"], stream["idle"], stream["buffers_with_no_row"], stream["no_row_own_time"],
                          stream["counts_agree"]), (2, 0, 1, 2, 1, True))
        self.assertEqual((stream["to_content_first"], stream["before_content_first"], stream["whole_take"]["gaps"], stream["steps"],
                          stream["lists"]["places_after_key"], stream["lists"]["no_row"]), (None, None, 0, None, [], [[1.0, -3, 0], [9.3, -1, 1]]))
        # The head's sentence has the row's buffers and none of the window list's frames with no row.
        self.assertIn("2 buffers (complete 0, idle 1, another status 0, no status 1); 2 buffers made no row (another status 0, no status 1, "
                      "no picture 0, idle before a picture 1; 1 of the listed ones have the handler's own time (not said in 0 rows)); "
                      "0 rows have the handler's own time; the frames with no row from the key to content_first: 0 in 0 gaps ",
                      nsf.stream_sentence([got]))

    def test_a_buffers_time_counts_from_the_rows_zero(self):
        # The key went in 2 ms before the reply's zero: each row is 2 ms later, and frame 1 has no row. The buffer at
        # 9 ms of the reply's time is 11 ms after the key, after the row at 10 ms: it is in the second gap, not the first.
        got = nsf.one_key(streamed(take(self.HOLE, before_send_ms=2.0), lost=[(9.0, 3)]), "n", asked_hz=120)
        self.assertEqual((got["content_first"]["frame"], got["content_first"]["ms"]), (5, 35))
        span = got["stream"]["to_content_first"]
        self.assertEqual((span["gaps"], span["frames"], gap_kinds(span), got["stream"]["before_content_first"]),
                         (2, 3, {"with_a_buffer": 2, "then_complete": 1}, "with_a_buffer"))

    def test_a_gap_after_the_last_listed_buffer_is_not_known_when_the_list_is_not_whole(self):
        # 2 buffers made no row and the reply lists the first one only (the recorder keeps a first part of them).
        got = self.stream(self.LATER, lost=[(20.0, 3)], other_status={"3": 2}, buffers=242)
        self.assertEqual((got["buffers_with_no_row"], got["no_row_not_listed"], got["counts_agree"], gap_kinds(got["whole_take"])),
                         (2, 1, True, {"not_known": 2}))
        # A gap before the last listed buffer is in the part that the list has whole.
        got = self.stream(self.HOLE, lost=[(100.0, 3)], other_status={"3": 2}, buffers=242)
        self.assertEqual(gap_kinds(got["to_content_first"]), {"then_complete": 2})

    def test_counts_that_do_not_add_up_are_said(self):
        self.assertTrue(self.stream(self.HOLE)["counts_agree"])
        for changed in ({"buffers": 239}, {"rows": 239}, {"complete": 241}, {"row_status": "c" * 239}, {"other_status": {"x": 1}},
                        {"no_status": None}, {"no_display_time": 1}, {"row_status": "c" * 239 + "x"}, {"row_ms": [0.0]},
                        {"other_status": {"3": 1}}, {"own_time_rows": None}, {"no_row": [[20.0, 3.0]]}):
            self.assertFalse(self.stream(self.HOLE, **changed)["counts_agree"], changed)
        # A status that is no number is not in the row: the row has numbers and its own words only.
        self.assertIsNone(self.stream(self.HOLE, other_status={"x": 1})["other_status"])
        # The app writes a status's raw number in ASCII digits: a digit of another form, or more than 20, is no number.
        for key in ("\u00b2", "\u0663", "1" * 21):
            self.assertIsNone(self.stream(self.HOLE, other_status={key: 0})["other_status"], key)
        self.assertEqual(self.stream(self.HOLE, other_status={"1" * 20: 0})["other_status"], {"1" * 20: 0})

    def test_no_check_reads_the_counts(self):
        for pictures in (self.HOLE, self.LATER):
            reply = streamed(take(pictures), own=(3,), lost=[(20.0, 3)])
            with_counts = nsf.one_key(reply, "n", asked_hz=120)
            without = nsf.one_key({name: value for name, value in reply.items() if name != "screen_stream"}, "n", asked_hz=120)
            self.assertIsNotNone(with_counts.pop("stream"))
            self.assertIsNone(without.pop("stream"))
            self.assertEqual(with_counts, without)
        # A row with a frame with no row before its first content stays INVALID, whatever the counts say of that frame.
        for said in ({}, {"lost": [(20.0, 3)]}, {"own": (3,)}, {"idle": (3,)}):
            self.assertEqual(nsf.one_key(streamed(take(self.HOLE), **said), "n", asked_hz=120)["invalid"], [self.NO_ROW], said)

    def test_the_rows_steps_against_the_displays_grid_are_counted_from_the_times_in_tenths(self):
        whole = [(NEW, ROW_NEW)] * 240
        self.assertEqual(self.stream(whole)["steps"], {"n": 239, "off_grid_to_0_5_ms": 239, "off_grid_to_1_ms": 0, "off_grid_to_2_ms": 0,
                                                       "off_grid_above_2_ms": 0, "one_frame": 239, "one_frame_mean_ms": 8.33})
        # One row 3 ms late: the step to it and the step after it are 3 ms off a whole count of frame times.
        times = streamed(take(whole))["screen_stream"]["row_ms"]
        got = self.stream(whole, row_ms=times[:50] + [times[50] + 3.0] + times[51:])
        self.assertEqual((got["steps"]["off_grid_to_0_5_ms"], got["steps"]["off_grid_above_2_ms"], got["counts_agree"]), (237, 2, True))
        # A reply with no times: no count of steps.
        self.assertIsNone(self.stream(whole, row_ms=None)["steps"])

    def test_the_heads_sentence_sums_the_rows_with_counts(self):
        a = nsf.one_key(streamed(take(self.HOLE), lost=[(20.0, 3)]), "n", asked_hz=120)
        b = nsf.one_key(streamed(take([(NEW, ROW_NEW)] * 240)), "n", asked_hz=120)
        c = nsf.one_key(take(self.HOLE), "n", asked_hz=120)
        self.assertEqual(nsf.stream_sentence([a, b, c]),
                         "the screen stream's counts (2 of the 3 rows have them): 483 buffers (complete 482, idle 0, another status 1, "
                         "no status 0); 1 buffers made no row (another status 1, no status 0, no picture 0, idle before a picture 0; "
                         "0 of the listed ones have the handler's own time (not said in 1 rows)); "
                         "0 rows have the handler's own time; the frames with no row from the key to content_first: 2 in 1 gaps "
                         "(with a buffer 1, own time 0, then idle 0, then complete 0, not known 0); 0 of the gaps end within the "
                         "row's largest lag before a buffer with no row that has the handler's own time, or within that lag plus 1 ms "
                         "before a later buffer that made a row and has it (0 of the gaps), or have the kind with_a_buffer and "
                         "an end row that has it (0 of the gaps), in 0 rows: their kind is not safe, the kinds answer for the "
                         "other gaps only, and the lag is a limit only when the stream gives its buffers in the display's order "
                         "(NOT PROVED); 0 gaps have a buffer with no row and the handler's own time in them; the "
                         "handler's lag at most 3.2 ms; the counts do not agree in 0 rows")
        self.assertIsNone(nsf.stream_sentence([c]))
        self.assertIsNone(nsf.stream_sentence([]))
        # A buffer with the handler's own time 2 ms after the gap's end row (2 rows), and one in the gap (1 row): the
        # head counts the 2 apart.
        d = nsf.one_key(streamed(take(self.HOLE), lost=[(35.0, 3, 1)]), "n", asked_hz=120)
        e = nsf.one_key(streamed(take(self.HOLE), lost=[(20.0, -1, 1)]), "n", asked_hz=120)
        said = nsf.stream_sentence([b, d, d, e])
        self.assertIn("; 3 of the listed ones have the handler's own time (not said in 0 rows)); ", said)
        self.assertIn("(with a buffer 0, own time 0, then idle 0, then complete 2, not known 1); 2 of the gaps end within the row's "
                      "largest lag before a buffer with no row that has the handler's own time, or within that lag plus 1 ms before "
                      "a later buffer that made a row and has it (0 of the gaps), or have the kind with_a_buffer and an end row "
                      "that has it (0 of the gaps), in 2 rows: their kind is not safe, the kinds answer for the other gaps only, "
                      "and the lag is a limit only when the stream gives its buffers in the display's order (NOT PROVED); "
                      "1 gaps have a buffer with no row and the handler's own time in them; ", said)
        # A gap before a later row with the handler's own time (the next row, with no lag in the reply): the head
        # counts it with the gaps that are not safe, and says how many are so by such a row.
        f = nsf.one_key(streamed(take(self.HOLE), own=(4,), lag_ms_max=None), "n", asked_hz=120)
        said = nsf.stream_sentence([d, f, f, e])
        self.assertIn("; 2 rows have the handler's own time; ", said)
        self.assertIn("then complete 3, not known 1); 3 of the gaps end within the row's largest lag before a buffer with no row that "
                      "has the handler's own time, or within that lag plus 1 ms before a later buffer that made a row and has it "
                      "(2 of the gaps), or have the kind with_a_buffer and an end row that has it (0 of the gaps), in 3 rows: "
                      "their kind is not safe, ", said)
        # A gap with a buffer that made no row and an end row with the handler's own time: the head counts it with the
        # gaps that are not safe, and says how many are so by such an end row.
        g = nsf.one_key(streamed(take(self.HOLE), own=(3,), lost=[(20.0, 3, 0)]), "n", asked_hz=120)
        said = nsf.stream_sentence([d, f, g, g])
        self.assertIn("(with a buffer 2, own time 0, then idle 0, then complete 2, not known 0); 4 of the gaps end within the row's "
                      "largest lag before a buffer with no row that has the handler's own time, or within that lag plus 1 ms before "
                      "a later buffer that made a row and has it (1 of the gaps), or have the kind with_a_buffer and an end row "
                      "that has it (2 of the gaps), in 4 rows: their kind is not safe, ", said)

    def test_counts_in_a_form_that_the_reader_does_not_know_end_no_run(self):
        # 2 forms that the app does not write: the list of the buffers with no row is a number, a count is infinite.
        reply = streamed(take(self.HOLE))
        plain = nsf.one_key({name: value for name, value in reply.items() if name != "screen_stream"}, "n", asked_hz=120)
        self.assertEqual((plain["stream"], plain["stream_fault"], plain["stream_kept"], plain["invalid"]), (None, None, None, [self.NO_ROW]))
        for changed, word in (({"no_row": 5}, "TypeError"), ({"buffers": float("inf")}, "OverflowError")):
            got = nsf.one_key({**reply, "screen_stream": {**reply["screen_stream"], **changed}}, "n", asked_hz=120)
            self.assertEqual((got["stream"], got["stream_fault"]), (None, word), changed)
            # Each other number of the row is as with no counts: the row is judged as before.
            self.assertEqual({**got, "stream_fault": None, "stream_kept": None}, plain, changed)
            # The row keeps the reply's counts but the one in the form that the reader does not know.
            self.assertEqual(got["stream_kept"], {name: value for name, value in reply["screen_stream"].items() if name not in changed}, changed)
        # What is kept is numbers and the 2 status letters: no other text of the reply, and no list with a place lost.
        odd = {"no_row": [[20.0, 3.0, 1.0], ["x", 1.0], [1.0], [float("nan"), 2.0]], "row_status": "a text", "row_ms": [1.0, "a"],
               "other_status": {"x": 1.0, "3": 2.0, "4": "many"}, "lag_ms_max": "long", "buffers": float("inf"), "more": "a text"}
        got = nsf.one_key({**reply, "screen_stream": {**reply["screen_stream"], **odd}}, "n", asked_hz=120)
        self.assertEqual((got["stream"], got["stream_fault"]), (None, "OverflowError"))
        self.assertEqual(got["stream_kept"], {**{name: value for name, value in reply["screen_stream"].items() if name not in odd},
                                              "no_row": [[20.0, 3.0, 1.0]], "other_status": {"3": 2.0}})
        # A recording with no row after the key reads the counts one time: the same word.
        got = nsf.one_key(streamed(take([]), no_row=5), "n", asked_hz=120)
        self.assertEqual((got["stream"], got["stream_fault"]), (None, "TypeError"))
        self.assertIsNone(nsf.one_key(streamed(take(self.HOLE)), "n", asked_hz=120)["stream_fault"])

    def test_the_kept_counts_are_no_larger_than_the_app_writes_them_and_a_reply_that_cannot_be_cut_keeps_none(self):
        reply = streamed(take(self.HOLE), buffers=float("inf"))
        said = {name: value for name, value in reply["screen_stream"].items() if name != "buffers"}

        def kept(**changed):
            got = nsf.one_key({**reply, "screen_stream": {**reply["screen_stream"], **changed}}, "n", asked_hz=120)
            self.assertEqual((got["stream"], got["stream_fault"]), (None, "OverflowError"), list(changed))
            return got["stream_kept"]

        def without(*names):
            return {name: value for name, value in said.items() if name not in names}

        self.assertEqual(kept(), said)
        # The app lists 256 buffers with no row at most, and a status is a number in ASCII digits.
        most = [[float(at), 3.0, 0.0] for at in range(256)]
        self.assertEqual(kept(no_row=most), {**said, "no_row": most})
        self.assertEqual(kept(no_row=most + [[256.0, 3.0, 0.0]]), without("no_row"))
        self.assertEqual(kept(other_status={"\u00b2": 1.0, "\u0663": 1.0, "1" * 21: 1.0, "1" * 20: 1.0, "7": 2.0}),
                         {**said, "other_status": {"1" * 20: 1.0, "7": 2.0}})
        self.assertEqual(kept(other_status={str(status): 1.0 for status in range(256)})["other_status"]["255"], 1.0)
        self.assertEqual(kept(other_status={str(status): 1.0 for status in range(257)}), without("other_status"))
        # A list of the rows, or their status letters, with more entries than a recording has rows is left out.
        for name, one in (("row_ms", [1.0]), ("own_time_rows", [1.0]), ("row_status", "c")):
            self.assertEqual(kept(**{name: one * 100_000}), {**said, name: one * 100_000}, name)
            self.assertEqual(kept(**{name: one * 100_001}), without(name), name)
        # A reply that cannot be cut keeps none: the fault's word stays the row's fact.
        for not_counts in (5, None, [1.0], "a text"):
            self.assertIsNone(nsf._kept({"screen_stream": not_counts}), not_counts)
        self.assertIsNone(nsf._kept({}))

        def fails(*_):
            raise ValueError("a fault of the reader")

        with mock.patch.object(nsf, "stream_of", fails):
            got = nsf.one_key({**reply, "screen_stream": 5}, "n", asked_hz=120)
        self.assertEqual((got["stream"], got["stream_fault"], got["stream_kept"], got["invalid"]), (None, "ValueError", None, [self.NO_ROW]))

    def test_a_fault_in_the_read_of_the_counts_against_the_rows_ends_no_run(self):
        read = nsf.stream_of

        def no_rows(reply, every=(), *more):
            if every:
                raise ValueError("rows in a form that the reader does not know")
            return read(reply, every, *more)

        with mock.patch.object(nsf, "stream_of", no_rows):
            got = nsf.one_key(streamed(take(self.HOLE)), "n", asked_hz=120)
        self.assertEqual((got["stream"], got["stream_fault"], got["invalid"]), (None, "ValueError", [self.NO_ROW]))
        self.assertEqual(got["content_first"]["frame"], 4)
        # A fault of the reader's own code on a reply in the right form: the row keeps the reply's counts whole.
        self.assertEqual(got["stream_kept"], streamed(take(self.HOLE))["screen_stream"])

    def test_the_head_says_the_rows_whose_counts_the_reader_did_not_know(self):
        good = nsf.one_key(streamed(take(self.HOLE)), "n", asked_hz=120)
        bad = nsf.one_key(streamed(take(self.HOLE), no_row=5), "n", asked_hz=120)
        worse = nsf.one_key(streamed(take(self.HOLE), buffers=float("inf")), "n", asked_hz=120)
        fault = ("the reader could not read the counts of 3 rows (OverflowError 1, TypeError 2): the reply's form or a fault of the "
                 "reader; each such row keeps the reply's counts (`stream_kept`)")
        said = nsf.stream_sentence([good, bad, worse, bad])
        self.assertTrue(said.startswith("the screen stream's counts (1 of the 4 rows have them): 240 buffers "), said)
        self.assertTrue(said.endswith("; the counts do not agree in 0 rows; " + fault), said)
        # With no row that has counts the head still says it.
        self.assertEqual(nsf.stream_sentence([bad, worse, bad]), "the screen stream's counts (0 of the 3 rows have them): " + fault)
        self.assertTrue(nsf.stream_sentence([good]).endswith("the counts do not agree in 0 rows"))

    def test_the_row_keeps_the_checked_lists_of_the_stream(self):
        # A later reading of the same take by another rule of the kinds has what the app gave: the lists as they
        # came, and the place of each row in them.
        reply = streamed(take(self.HOLE, before_send_ms=2.0), idle=(5,), own=(9, 3), lost=[(20.0, 3), (500.0, -2)])
        got, said = nsf.one_key(reply, "n", asked_hz=120), reply["screen_stream"]
        self.assertEqual(got["stream"]["lists"], {"row_status": said["row_status"], "row_ms": said["row_ms"], "no_row": [[20.0, 3], [500.0, -2]],
                                                  "own_time_rows": [3, 9], "place_before_key": 1, "places_after_key": list(range(2, 240)),
                                                  "shift_ms": 2.0})
        self.assertEqual((len(got["stream"]["lists"]["places_after_key"]), got["stream"]["counts_agree"]), (len(got["rows_ms"]), True))
        self.assertIs(type(got["stream"]["lists"]["no_row"][0][1]), int)
        # A list in a wrong form is not in the row: numbers and the 2 status letters only, no other text of the reply.
        for changed, name in (({"row_status": "c" * 239 + "x"}, "row_status"), ({"row_status": 7}, "row_status"), ({"row_ms": ["a"]}, "row_ms"),
                              ({"row_ms": [float("nan")] * 240}, "row_ms"), ({"own_time_rows": [1.5]}, "own_time_rows"),
                              ({"own_time_rows": "3"}, "own_time_rows")):
            self.assertIsNone(self.stream(self.HOLE, **changed)["lists"][name], changed)
        wrong = [[20.0, 3.0], ["x", 1], [1.0], [float("nan"), 2.0], "20", [30.5, -1.0]]
        self.assertEqual(self.stream(self.HOLE, no_row=wrong)["lists"]["no_row"], [[20.0, 3], [30.5, -1]])
        # A recording with no row after the key: the lists, and no place.
        got = nsf.one_key(streamed(take([])), "n", asked_hz=120)["stream"]["lists"]
        self.assertEqual((got["row_status"], got["place_before_key"], got["places_after_key"]), ("cc", None, []))

    def test_a_reply_whose_rows_start_at_the_last_row_before_the_key_reads_the_same(self):
        # The app's reply has the rows from the last one before the key, each file with its place in the whole
        # recording; the counts and the lists are of each row from the stream's start.
        whole = streamed(take(self.HOLE, before=14), idle=(20,), own=(17,), lost=[(20.0, 3)])
        cut = {**whole, "frames": whole["frames"][13:]}
        a, b = (nsf.one_key(reply, "n", asked_hz=120)["stream"] for reply in (whole, cut))
        self.assertEqual((b["rows"], len(cut["frames"]), b["counts_agree"]), (252, 239, True))
        self.assertEqual((b["lists"]["place_before_key"], b["lists"]["places_after_key"][:2], len(b["lists"]["row_ms"])), (13, [14, 15], 252))
        for name in ("to_content_first", "whole_take", "before_content_first", "content_first_status", "rows_after_key", "steps", "lists"):
            self.assertEqual(b[name], a[name], name)
        self.assertEqual((gap_kinds(b["to_content_first"]), b["rows_after_key"]), ({"with_a_buffer": 2}, {"complete": 237, "idle": 1, "not_known": 0}))

    def test_the_reply_that_the_apps_own_test_wants_has_counts_that_agree(self):
        # The `screen_stream` that the app's own test wants from a tally of 7 buffers: the first test of
        # Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/FrameStripStreamReplyTests.swift (the same numbers, kept the
        # same by hand: change the 2 together). The reader takes each field of it.
        said = {"buffers": 7.0, "rows": 3.0, "row_status": "cic", "complete": 3.0, "idle": 2.0, "other_status": {"2": 1.0},
                "no_status": 1.0, "no_picture": 1.0, "idle_before_a_picture": 1.0, "own_time_rows": [1.0, 2.0],
                "no_display_time": 1.0, "display_time_later": 1.0,
                "no_row": [[-10.0, -1.0, 1.0], [-5.0, -3.0, 0.0], [18.0, -2.0, 1.0], [20.0, 2.0, 0.0]],
                "row_ms": [0.0, 8.4, 16.7], "lag_ms_max": 3.3, "lag_ms_mean": 3.3, "work_ms_max": 2.0, "work_ms_mean": 1.6}
        got = nsf.stream_of({"screen_stream": said})
        self.assertEqual((got["counts_agree"], got["buffers_with_no_row"], got["no_row_not_listed"], got["own_time_rows"], got["no_row_own_time"]),
                         (True, 4, 0, 2, 2))
        self.assertEqual(got["lists"], {"row_status": "cic", "row_ms": [0.0, 8.4, 16.7],
                                        "no_row": [[-10.0, -1, 1], [-5.0, -3, 0], [18.0, -2, 1], [20.0, 2, 0]],
                                        "own_time_rows": [1, 2], "place_before_key": None, "places_after_key": [], "shift_ms": 0.0})
        # A reply that lost one of the fields that the sums need does not agree.
        for name in ("buffers", "rows", "row_status", "complete", "idle", "other_status", "no_status", "no_picture", "idle_before_a_picture",
                     "own_time_rows", "no_display_time", "display_time_later"):
            self.assertFalse(nsf.stream_of({"screen_stream": {key: value for key, value in said.items() if key != name}})["counts_agree"], name)

    def test_a_gap_is_not_known_when_the_row_after_has_no_status_or_a_count_is_no_number(self):
        # The reply's status letters end before the row after the gap (place 3).
        got = self.stream(self.HOLE, row_status="ccc")
        self.assertEqual((gap_kinds(got["to_content_first"]), got["content_first_status"], got["counts_agree"]), ({"not_known": 2}, None, False))
        # A count that is no number: how many buffers made no row is not known, so a gap can hold one.
        got = self.stream(self.HOLE, no_status=None)
        self.assertEqual((gap_kinds(got["to_content_first"]), got["buffers_with_no_row"], got["no_row_not_listed"]), ({"not_known": 2}, None, None))


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
        # `stream`: a build whose reply has the recorder's counts of its stream (`streamed`; a dict: the fields of
        # `screen_stream` that the test sets itself).
        self.stream = False
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
            if self.stream:
                reply = streamed(reply, **(self.stream if isinstance(self.stream, dict) else {}))
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

    def test_the_head_has_the_streams_counts_when_the_app_gives_them(self):
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        app.stream = True
        report, _ = self.run_mode(app, keys="n", runs=1)
        said = nsf.stream_sentence(report["rows"])
        self.assertTrue(said.startswith("the screen stream's counts (1 of the 1 rows have them): 242 buffers (complete 242, "), said)
        # After the recorder's rows and the asked rate's sentences, before the app's settings lines.
        lines = report["settings"]["lines"]
        self.assertEqual(report["head"][len(report["head"]) - len(lines) - 1:], [said] + lines)
        self.assertEqual((report["rows"][0]["stream"]["counts_agree"], report["rows"][0]["invalid"]), (True, []))
        self.assertEqual(json.loads(Path(self.folder, "report.json").read_text())["rows"][0]["stream"]["buffers"], 242)
        # A build with no counts: no sentence, and the head is as it was.
        report, _ = self.run_mode(FakeApp(self.folder, [(NEW, ROW_NEW)] * 240), keys="n", runs=1)
        self.assertEqual([said for said in report["head"] if said.startswith("the screen stream")], [])
        self.assertIsNone(report["rows"][0]["stream"])

    def test_counts_in_a_form_that_the_reader_does_not_know_do_not_end_the_run(self):
        # The list of the buffers with no row is a number: the run goes on to its last recording, each row is judged
        # as with no counts, and the row and the head say the fact.
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        app.stream = {"no_row": 5}
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(app, keys="n", runs=2)
        self.assertEqual([(row["stream"], row["stream_fault"], row["invalid"]) for row in report["rows"]], [(None, "TypeError", [])] * 2)
        self.assertIn("the screen stream's counts (0 of the 2 rows have them): the reader could not read the counts of 2 rows "
                      "(TypeError 2): the reply's form or a fault of the reader; each such row keeps the reply's counts (`stream_kept`)",
                      report["head"])
        # The row's line says the fault's word and the row stays valid; the report's file keeps the reply's counts for a
        # later reading: the numbers and the status letters, and not the list in the form that the reader did not know.
        lines = [line for line in said.getvalue().splitlines() if line.startswith("NEW-SURFACE-SCREEN-ROW ")]
        self.assertEqual([(line.split()[2], " capture=screencapturekit no_row_to_content_first=0/1" in line, line.count(" stream_fault=TypeError "))
                          for line in lines], [("valid", True, 1)] * 2)
        row = json.loads(Path(self.folder, "report.json").read_text())["rows"][1]
        self.assertEqual((row["stream_fault"], row["stream_kept"]["buffers"], row["stream_kept"]["row_status"], "no_row" in row["stream_kept"]),
                         ("TypeError", 242, "c" * 242, False))
        # A row with counts has no such word in its line and keeps nothing more.
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        app.stream = True
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report, _ = self.run_mode(app, keys="n", runs=1)
        self.assertNotIn("stream_fault", said.getvalue())
        self.assertEqual((report["rows"][0]["stream_fault"], report["rows"][0]["stream_kept"]), (None, None))
        # The checked lists are in the report's file too.
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        app.stream = True
        self.run_mode(app, keys="n", runs=1)
        lists = json.loads(Path(self.folder, "report.json").read_text())["rows"][0]["stream"]["lists"]
        self.assertEqual((lists["row_status"], lists["places_after_key"], lists["no_row"]), ("c" * 242, list(range(2, 242)), []))

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
