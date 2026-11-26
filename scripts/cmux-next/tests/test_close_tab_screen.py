#!/usr/bin/env python3
"""new_surface_frames.py and new_surface_screen.py: one Close Tab key (Cmd-W), from the screen's frames and the pane's tabs.

No app, no display, no fleet: the frames are rows in the form that the app's frame_strip writes, and the app is a
function that answers the tool's calls, with a list of tabs and a clock that only the tool's pauses move. The
tool's sender of the New Tab keys runs here before the recording's call, on that clock, and not in a thread. A key
sequence opens its tabs here at the call, with the times that the steps plan. So this proves the tool's own
reading, its cases, the times at which it plans its keys and its INVALID rules, not that a recording on a Mac
gives such rows, that the app takes the keys at those times, or that a sequence's keys come to the app's key path.

    python3 -I scripts/cmux-next/tests/test_close_tab_screen.py
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True  # the imports leave no cache folder in the checkout
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_new_surface_frames as base  # noqa: E402

nsf, new_surface_screen = base.nsf, base.new_surface_screen
# The pane as before the key, with the strip's numbers, then the close: each region at its last picture in one frame.
OLD_ROW = dict(content=base.OLD, outside=base.STILL, strip=(0, 0.2))
GONE = dict(content=base.NEW, outside=base.STILL, strip=(0.2, 0))
STRIP_LATE = dict(content=base.NEW, outside=base.STILL, strip=(0, 0.2))  # the next tab's content, the closed tab still in the strip
BLANK = dict(content=(0.3, 0.3), outside=base.STILL, strip=(0.2, 0), blank=True)  # the closed tab's content gone, no content yet
SAME = dict(content=base.STILL, outside=base.STILL, strip=(0.2, 0))  # the tab that shows has the closed tab's picture
SENT = 2.0  # the Close Tab key went in this long before the reply's zero
AT = {"frame": 3, "ms": 19.0, "file": "frame-004.png"}  # the first frame of the display in which a change of `shot` can be


def shot(pictures, spans=()):
    """A recording of one Close Tab key: a row of the old picture, then one frame of the display for each picture."""
    return base.take([OLD_ROW] + list(pictures), spans=list(spans), before_send_ms=SENT)


def tabs(*ids, shown):
    return {"tabs": [{"id": name, "kind": "terminal" if name.startswith("term") else "newTab"} for name in ids], "selected": shown}


def opened(before_ms):
    """The app's mark of a New Tab key's opening that began `before_ms` before the Close Tab key went in."""
    return {"name": "newTab.open", "ms": -(before_ms + SENT), "duration_ms": 6.0}


class CloseFactTests(unittest.TestCase):
    def fact(self, pictures, before, after, keys=0, spans=()):
        self.assertTrue(hasattr(nsf, "close_of"), "new_surface_frames.py has no `close_of`: a Close Tab key has no row")
        reply = shot(pictures, spans)
        row = nsf.one_key(reply, "w", asked_hz=120)
        fact, faults = nsf.close_of(row, reply["spans"], before, after, keys)
        return fact, faults

    def test_an_idle_close_says_which_tab_shows_and_the_frame_in_which_the_closed_tabs_content_is_gone(self):
        fact, faults = self.fact([GONE] * 239, tabs("term-0", "term-1", "page-2", shown="page-2"), tabs("term-0", "term-1", shown="term-1"))
        self.assertEqual(faults, [])
        self.assertEqual(fact["closed"], [{"id": "page-2", "kind": "newTab", "index": 2, "was_shown": True}])
        self.assertEqual(fact["closed_is"], "the shown tab (newTab)")
        self.assertEqual(fact["shown_after"], {"id": "term-1", "kind": "terminal", "index": 1, "of": 2, "is": "the tab to the left of the closed tab"})
        self.assertEqual((fact["content_gone"], fact["content_shown"], fact["strip_first"]), (AT, AT, AT))
        self.assertEqual(fact["order"], "the strip and the content area changed in the same frame")
        self.assertEqual((fact["tabs_before"], fact["tabs_after"], fact["new_tab_keys"], fact["new_tab_change_can_be_in_the_frames"]), (3, 2, 0, False))

    def test_the_tab_that_shows_is_named_by_its_place_from_the_closed_tab(self):
        right, _ = self.fact([GONE] * 239, tabs("term-0", "page-1", "term-2", shown="page-1"), tabs("term-0", "term-2", shown="term-2"))
        self.assertEqual(right["shown_after"]["is"], "the tab to the right of the closed tab")
        far, _ = self.fact([GONE] * 239, tabs("term-0", "term-1", "term-2", "page-3", shown="page-3"), tabs("term-0", "term-1", "term-2", shown="term-0"))
        self.assertEqual(far["shown_after"]["is"], "another tab (3 places to the left of the closed tab)")
        # A close of a tab that was not the shown one, and a key that closed nothing: each a fact with its own words.
        other, faults = self.fact([GONE] * 239, tabs("term-0", "page-1", shown="page-1"), tabs("page-1", shown="page-1"))
        self.assertEqual((other["closed_is"], other["shown_after"]["is"], faults),
                         ("a tab that was not the shown one (terminal)", "the tab that was shown before the key (the closed tab was not the shown one)", []))
        none, faults = self.fact([GONE] * 239, tabs("term-0", "page-1", shown="page-1"), tabs("term-0", "page-1", shown="page-1"))
        self.assertEqual((none["closed_is"], none["shown_after"]["is"]), ("no tab", "no tab closed"))
        self.assertTrue(faults[0].startswith("input: 0 New Tab key-downs and 1 Close Tab key sent: the pane had 2 tabs before them and has 2 after them"), faults)

    def test_the_order_of_the_strip_and_the_content_area_is_in_the_row(self):
        late, _ = self.fact([STRIP_LATE] * 2 + [GONE] * 237, tabs("term-0", "page-1", shown="page-1"), tabs("term-0", shown="term-0"))
        self.assertEqual((late["content_gone"]["frame"], late["strip_first"]["frame"]), (3, 5))
        self.assertEqual(late["order"], "the strip changed 2 frames after the content area")
        early, _ = self.fact([dict(OLD_ROW, strip=(0.2, 0))] + [GONE] * 238, tabs("term-0", "page-1", shown="page-1"), tabs("term-0", shown="term-0"))
        self.assertEqual(early["order"], "the strip changed 1 frames before the content area")
        # Each frame directly before the 2 first changes has a row: the 2 frames are proved.
        self.assertEqual((late.get("strip_first_can_be_frames_earlier"), late.get("content_gone_can_be_frames_earlier")), (0, 0))

    def test_a_frame_with_no_row_directly_before_the_strips_first_change_makes_the_order_a_range(self):
        two = (tabs("term-0", "page-1", shown="page-1"), tabs("term-0", shown="term-0"))
        # The content gone in frame 3, no row for frame 4, the strip's change in the row of frame 5: the strip can
        # have changed in frame 4. `after` is proved (frame 3's row has the old strip), the count of frames is not.
        hole, faults = self.fact([STRIP_LATE, None] + [GONE] * 237, *two)
        self.assertEqual(faults, [])
        self.assertEqual((hole["content_gone"]["frame"], hole["strip_first"]["frame"]), (3, 5))
        self.assertEqual((hole.get("strip_first_can_be_frames_earlier"), hole.get("content_gone_can_be_frames_earlier")), (1, 0))
        self.assertEqual(hole["order"], "the strip changed 1 to 2 frames after the content area (frames with no row directly before "
                                        "the first change: the strip's 1, the content area's 0)")
        # The strip's change in the row of frame 4 with no row for frame 3, the content gone in frame 5.
        before, _ = self.fact([None, dict(OLD_ROW, strip=(0.2, 0))] + [GONE] * 237, *two)
        self.assertEqual((before["strip_first"]["frame"], before["content_gone"]["frame"]), (4, 5))
        self.assertEqual(before["order"], "the strip changed 1 to 2 frames before the content area (frames with no row directly before "
                                          "the first change: the strip's 1, the content area's 0)")
        # No row for frame 3, and both changed in the row of frame 4: which one changed first is not proved.
        both, _ = self.fact([None] + [GONE] * 238, *two)
        self.assertEqual((both["strip_first"]["frame"], both["content_gone"]["frame"]), (4, 4))
        self.assertEqual(both["order"], "not proved: the strip changed from 1 frames before to 1 frames after the content area (frames with "
                                        "no row directly before the first change: the strip's 1, the content area's 1)")
        self.assertEqual((both.get("strip_first_can_be_frames_earlier"), both.get("content_gone_can_be_frames_earlier")), (1, 1))
        # The first row after the key has both changes, and the display's frame before it (frame 1) has no row.
        reply = base.take([GONE] * 239, spans=[], before_send_ms=SENT)
        first, _ = nsf.close_of(nsf.one_key(reply, "w", asked_hz=120), reply["spans"], *two, 0)
        self.assertEqual((first["strip_first"]["frame"], first["content_gone"]["frame"]), (2, 2))
        self.assertEqual((first.get("strip_first_can_be_frames_earlier"), first.get("content_gone_can_be_frames_earlier")), (1, 1))
        self.assertTrue(first["order"].startswith("not proved: the strip changed from 1 frames before to 1 frames after "), first["order"])
        # The case's line says in how many of its valid rows `strip_first` is the latest frame and not a proved one.
        rows = [{"invalid": [], "close_tab": fact} for fact in (hole, before, self.fact([STRIP_LATE] * 2 + [GONE] * 237, *two)[0])]
        summary = nsf.close_summary(rows)
        self.assertEqual(summary.get("strip_first_not_proved"), 2)
        # Frame 5's row is at 33 ms after the reply's zero (4 frame times, whole ms), and the key went in 2 ms before it.
        self.assertIn("strip's first change frame 5 (max 5), 35 ms (max 35) [in 2 of the 3 rows a frame with no row is directly before "
                      "it: there it is the latest frame]; order: ", nsf.close_cell(summary))
        self.assertIn(" strip_first=[5, 35.0] strip_first_can_be_frames_earlier=1 ", new_surface_screen.close_said({"close_tab": hole}))
        self.assertNotIn("can_be_frames_earlier", new_surface_screen.close_said({"close_tab": rows[2]["close_tab"]}))

    def test_a_frame_with_no_row_before_the_content_areas_change_alone_and_two_such_frames_make_a_range_too(self):
        two = (tabs("term-0", "page-1", shown="page-1"), tabs("term-0", shown="term-0"))
        # The strip's change in the row of frame 3 (proved: frame 2 has a row), no row for frame 4, the content gone
        # in the row of frame 5: the content can have gone in frame 4. `before` is proved, the count of frames is not.
        content, _ = self.fact([dict(OLD_ROW, strip=(0.2, 0)), None] + [GONE] * 237, *two)
        self.assertEqual((content["strip_first"]["frame"], content["content_gone"]["frame"]), (3, 5))
        self.assertEqual((content.get("strip_first_can_be_frames_earlier"), content.get("content_gone_can_be_frames_earlier")), (0, 1))
        self.assertEqual(content["order"], "the strip changed 1 to 2 frames before the content area (frames with no row directly before "
                                           "the first change: the strip's 0, the content area's 1)")
        # 2 frames with no row directly before the strip's change, and directly before the content's: the count is 2.
        strip, _ = self.fact([STRIP_LATE, None, None] + [GONE] * 236, *two)
        self.assertEqual((strip["content_gone"]["frame"], strip["strip_first"]["frame"]), (3, 6))
        self.assertEqual((strip.get("strip_first_can_be_frames_earlier"), strip.get("content_gone_can_be_frames_earlier")), (2, 0))
        self.assertEqual(strip["order"], "the strip changed 1 to 3 frames after the content area (frames with no row directly before "
                                         "the first change: the strip's 2, the content area's 0)")
        far, _ = self.fact([dict(OLD_ROW, strip=(0.2, 0)), None, None] + [GONE] * 236, *two)
        self.assertEqual((far.get("strip_first_can_be_frames_earlier"), far.get("content_gone_can_be_frames_earlier")), (0, 2))
        self.assertEqual(far["order"], "the strip changed 1 to 3 frames before the content area (frames with no row directly before "
                                       "the first change: the strip's 0, the content area's 2)")

    def test_the_line_of_a_close_tab_row_with_a_display_reason_says_not_known_for_the_order(self):
        # The order is a count of frames, and a row with a `display` reason has a frame time that does not see a
        # frame with no row: the row's line gives no order, and says why. The reason does not have to be the first.
        fact, _ = self.fact([STRIP_LATE] * 2 + [GONE] * 237, tabs("term-0", "page-1", shown="page-1"), tabs("term-0", shown="term-0"))
        self.assertEqual(fact["order"], "the strip changed 2 frames after the content area")
        said = new_surface_screen.close_said
        self.assertTrue(said({"close_tab": fact, "invalid": []}).endswith(" order='the strip changed 2 frames after the content area'"))
        self.assertTrue(said({"close_tab": fact, "invalid": ["input: 1 key sent"]}).endswith(" order='the strip changed 2 frames after the content area'"))
        low = said({"close_tab": fact, "invalid": ["no-row: 1 of the 3 frames have no row", "display: 8 steps one after the other"]})
        self.assertTrue(low.endswith(" blank=0 order='not known (the asked display rate is not proved)'"), low)
        self.assertNotIn("frames after the content area", low)
        none = said({"close_tab": fact, "invalid": [nsf.NO_RATE]})
        self.assertTrue(none.endswith(" blank=0 order='not known (no asked display rate)'"), none)

    def test_frames_with_the_closed_tabs_content_gone_and_no_content_yet_are_counted(self):
        fact, faults = self.fact([BLANK] * 3 + [GONE] * 236, tabs("term-0", "page-1", shown="page-1"), tabs("term-0", shown="term-0"))
        self.assertEqual(faults, [])
        self.assertEqual((fact["content_gone"]["frame"], fact["content_shown"]["frame"], fact["content_shown"]["ms"]), (3, 6, 44.0))
        self.assertEqual((fact["blank_frames"], fact["content_between_frames"]), (3, 3))

    def test_a_close_100_ms_after_a_new_tab_key_says_the_true_time_between_the_keys(self):
        marks = [opened(100.0), {"name": "closeLocalTab", "ms": -1.5, "duration_ms": 0.5}]
        fact, faults = self.fact([GONE] * 239, tabs("term-0", shown="term-0"), tabs("term-0", shown="term-0"), keys=1, spans=marks)
        self.assertEqual(faults, [])
        self.assertEqual((fact["closed"], fact["closed_is"], fact["closed_new_tabs"], fact["new_tabs_left"]), ([], "a new tab of the recording", 1, 0))
        self.assertEqual(fact["shown_after"]["is"], "the tab that was shown before the New Tab keys")
        self.assertEqual((fact["new_tab_marks_before_ms"], fact["last_new_tab_key_before_ms"], fact["close_marks_ms"]), ([100.0], 100.0, [0.5]))
        self.assertIs(fact["new_tab_change_can_be_in_the_frames"], True)

    def test_a_close_after_a_hold_names_the_new_tab_that_shows(self):
        after = tabs("term-0", "new-1", "new-2", "new-3", "new-4", "new-5", shown="new-5")
        fact, faults = self.fact([GONE] * 239, tabs("term-0", shown="term-0"), after, keys=6, spans=[opened(100.0)])
        self.assertEqual(faults, [])
        self.assertEqual((fact["closed_is"], fact["closed_new_tabs"], fact["new_tabs_left"]), ("a new tab of the recording", 1, 5))
        self.assertEqual(fact["shown_after"]["is"], "a new tab of the recording (place 5 of the 5 that are left, from the left)")

    def test_two_new_tab_pages_with_one_picture_are_no_fault_and_the_row_says_that_the_content_did_not_change(self):
        after = tabs("term-0", "new-1", shown="new-1")
        # The picture before the key is also the last picture: only the strip changes, in the second row.
        reply = base.take([dict(SAME, strip=(0, 0.2))] + [SAME] * 239, spans=[opened(100.0)], before_send_ms=SENT)
        row = nsf.one_key(reply, "w", asked_hz=120)
        self.assertTrue(row["invalid"][0].startswith("content: "), row["invalid"])  # the reader of an opening's rule
        self.assertTrue(hasattr(nsf, "close_of"), "new_surface_frames.py has no `close_of`")
        fact, faults = nsf.close_of(row, reply["spans"], tabs("term-0", shown="term-0"), after, 2)
        self.assertEqual((faults, fact["content_gone"], fact["content_shown"], fact["strip_first"]), ([], None, None, AT))
        self.assertEqual(fact["not_a_fault_for_a_close"], row["invalid"])
        self.assertEqual(fact["order"], "the strip changed and the content area did not (one picture before and after the key)")

    def test_a_close_that_took_a_tab_from_before_the_new_tab_keys_is_a_fact(self):
        fact, faults = self.fact([GONE] * 239, tabs("term-0", "term-1", shown="term-1"), tabs("term-0", "new-2", shown="new-2"), keys=1, spans=[opened(100.0)])
        self.assertEqual(faults, [])
        self.assertEqual((fact["closed"], fact["closed_is"], fact["closed_new_tabs"], fact["new_tabs_left"]),
                         ([{"id": "term-1", "kind": "terminal", "index": 1, "was_shown": True}], "a tab that was there before the New Tab keys (terminal)", 0, 1))

    def test_a_row_whose_keys_are_not_proved_is_invalid(self):
        one, shown = tabs("term-0", shown="term-0"), tabs("term-0", "new-1", shown="new-1")
        _, count = self.fact([GONE] * 239, one, shown, keys=1, spans=[opened(100.0)])
        self.assertTrue(count[0].startswith("input: 1 New Tab key-downs and 1 Close Tab key sent: the pane had 1 tabs before them and has 2 after them"), count)
        _, no_mark = self.fact([GONE] * 239, one, one, keys=1)
        self.assertTrue(no_mark[0].startswith("input: no `newTab.open` mark in the recording before the Close Tab key went in"), no_mark)
        _, late = self.fact([GONE] * 239, one, one, keys=1, spans=[opened(100.0), opened(-7.0)])
        self.assertTrue(late[0].startswith("input: a `newTab.open` mark starts 7 ms after the Close Tab key went in"), late)
        fact, not_read = self.fact([GONE] * 239, None, one)
        self.assertTrue(not_read[0].startswith("tabs: "), not_read)
        self.assertEqual((fact.get("shown_after"), fact["content_gone"]), (None, AT))

    def test_a_case_counts_what_shows_and_gives_the_frames(self):
        self.assertTrue(hasattr(nsf, "close_summary"), "new_surface_frames.py has no `close_summary`")
        rows = []
        for pictures in ([GONE] * 239, [BLANK] * 3 + [GONE] * 236):
            reply = shot(pictures)
            row = nsf.one_key(reply, "w", asked_hz=120)
            row["close_tab"], _ = nsf.close_of(row, reply["spans"], tabs("term-0", "page-1", shown="page-1"), tabs("term-0", shown="term-0"), 0)
            rows.append(row)
        summary = nsf.close_summary(rows)
        self.assertEqual((summary["shows"], summary["closed"]), ({"the tab to the left of the closed tab": 2}, {"the shown tab (newTab)": 2}))
        self.assertEqual(summary["content_gone"], {"frame": {"p50": 3.0, "max": 3}, "ms": {"p50": 19.0, "max": 19.0}})
        self.assertEqual(summary["content_shown"]["frame"], {"p50": 4.5, "max": 6})
        # An INVALID row is counted in `n` only: its frames (the second row's, 6) are not in the case's numbers.
        rows[1]["invalid"] = ["input: a made reason"]
        valid_only = nsf.close_summary(rows)
        self.assertEqual((valid_only["n"], valid_only["valid"], valid_only["shows"]), (2, 1, {"the tab to the left of the closed tab": 1}))
        self.assertEqual(valid_only["content_shown"]["frame"], {"p50": 3, "max": 3})
        said = nsf.close_cell(summary)
        self.assertIn("shows after the close: the tab to the left of the closed tab 2/2", said)
        self.assertIn("closed tab's content gone frame 3 (max 3), 19 ms (max 19)", said)
        self.assertIn("content of the tab that shows final frame 4.5 (max 6)", said)


class CloseApp(base.FakeApp):
    """The app with one pane's tabs: Control-` and Cmd-T put a tab to the right of the shown tab and show it, Cmd-W
    closes the shown tab and shows the tab to its left. `now` is the clock: only the tool's pauses move it."""

    def __init__(self, folder, pictures=None, **more):
        super().__init__(folder, [OLD_ROW] + [GONE] * 239 if pictures is None else pictures, **more)
        self.ids, self.kinds, self.shown, self.serial = ["tab-0"], {"tab-0": "terminal"}, "tab-0", 0
        self.now, self.sent = 1000.0, SENT
        # Each New Tab key by `debug.key`: its params and its time; `refuse_keys`: the numbers of the ones that the app refuses.
        self.keys, self.key_times, self.open_times, self.refuse_keys = [], [], [], set()
        self.asked, self.strip_times = [], []  # each recording of a Close Tab key: its params and its time
        # `closes`: False for a Close Tab key that closes nothing. `mark_before`: how long before the Close Tab key
        # the opening mark of a New Tab key of the last 50 ms starts (None: the recording has no such mark).
        self.closes, self.mark_before, self.focus = True, 100.0, True
        # Each key sequence by `debug.key`: its params. `refuse_sequence`: the app's refusal of each one.
        self.sequences, self.refuse_sequence = [], None
        # An app that a person works in: it is active and its shell window is the key window (a hold runs only then).
        self.active = self.is_key = True

    def clock(self):
        return self.now

    def pause(self, seconds):
        self.now += seconds
        super().pause(seconds)

    def start(self, work):
        work()  # the tool's sender, to its end, before the recording's call
        return lambda: None

    def open(self, kind):
        self.serial += 1
        name = f"tab-{self.serial}"
        self.ids.insert(self.ids.index(self.shown) + 1, name)
        self.kinds[name], self.shown = kind, name

    def close_shown(self):
        at = self.ids.index(self.shown)
        self.kinds.pop(self.ids.pop(at))
        self.shown = self.ids[max(0, at - 1)] if self.ids else None

    def terminal_tab(self):
        self.open("terminal")

    def close_new(self, count):
        self.closed.append(count)
        for _ in range(count):
            self.close_shown()

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        action = params.get("action")
        if method == "debug.focus":
            mine = {"pane": "pane-1", "selected": self.shown, "tab_count": len(self.ids), "tabs": [f"{name}:{self.kinds[name]}" for name in self.ids]}
            other = {"pane": "pane-0", "selected": "far-0", "tab_count": 1, "tabs": ["far-0:terminal"]}
            # `focus` False: the app lists its window with no pane.
            return self.focus_fact(model={"pane": "pane-1", "resolved_tab": self.shown}, consistent=True, topology=[other, mine] if self.focus else [])
        if method == "debug.key" and "sequence" in params:
            self.sequences.append(params)
            if self.refuse_sequence:
                return {"error": self.refuse_sequence}
            at = self.now
            for step in params["sequence"]:
                at += step.get("after_ms", 0) / 1000
                if step["key_code"] == 17 and step["down"]:  # a key-down of T, a repeat or not: one tab
                    self.open("newTab")
                    self.open_times.append(at)
                    self.openings.append({"spare": True, "ms": 1000.0 + len(self.openings)})
            return {"scheduled": len(params["sequence"]), "base_s": 5.0, "duration_ms": (at - self.now) * 1000, "key_window": params.get("key_window")}
        if method == "debug.key":
            self.keys.append(params)
            self.key_times.append(self.now)
            if len(self.keys) in self.refuse_keys:
                return {"error": "no window"}
            self.open("newTab")
            self.open_times.append(self.now)
            self.openings.append({"spare": True, "ms": 1000.0 + len(self.openings)})
            return {"handled": "router"}
        if action == "switch_and_type":
            return {"tabs": [{"id": name} for name in self.ids]}
        if action == "frame_strip" and params.get("key") == "w":
            self.strips += 1
            self.asked.append(params)
            self.strip_times.append(self.now)
            if self.strips in self.refused:
                return {"error": "no window"}
            spans = []
            if self.mark_before is not None and any(self.now - at <= 0.05 for at in self.open_times):
                spans.append(opened(self.mark_before))
            if self.closes:
                spans.append({"name": "closeLocalTab", "ms": -1.5, "duration_ms": 0.5})
                self.close_shown()
            reply = base.take(self.pictures, spans=spans, before_send_ms=self.sent)
            os.makedirs(params["dir"], exist_ok=True)
            for frame in reply["frames"]:
                Path(params["dir"], frame["file"]).write_bytes(b"png")
            return reply
        return super().rpc(method, params, timeout)


def options(folder, **changed):
    return base.options(folder, **{**dict(keys="w", runs=1, close_cases="idle,key,downs,hold", close_gap_ms=100.0, hold_keys=6,
                                          hold_delay_ms=375.0, hold_repeat_ms=90.0), **changed})


class CloseScreenTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="close-tab-screen-test-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.folder, ignore_errors=True))

    def run_mode(self, app, **changed):
        def make(socket_path, count, live, url, deadline, out):
            return {"asked_more": count, "live_shells": live, "maker_exit": 0, "maker_said_made": count, "seed_s": 0.0}
        try:
            screen = new_surface_screen.Screen(options(self.folder, **changed), app.rpc, app.tools(), sleep=app.pause, make_session=make,
                                               clock=app.clock, start=app.start)
        except TypeError as error:
            self.fail(f"new_surface_screen.Screen takes no clock and no starter of its sender: the tool has no Close Tab case ({error})")
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report = screen.run()
        return report, said.getvalue()

    def test_the_close_tab_key_has_its_four_cases_and_each_row_says_which_tab_shows(self):
        app = CloseApp(self.folder)
        report, _ = self.run_mode(app)
        # The name of a case says its sender: key-downs with no repeat flag are not a hold of the key.
        self.assertEqual(list(report["cases"]), [
            "cmd-w/idle", "cmd-w/100 ms after a New Tab key", "cmd-w/100 ms after 6 New Tab key-downs at a hold's times, no repeat flag",
            "cmd-w/100 ms after a hold of the New Tab key (6 key-downs: 1 and 5 repeats with the repeat flag)"])
        rows = report["rows"]
        self.assertEqual([row["label"] for row in rows], ["cmd-w-idle-0", "cmd-w-key100-0", "cmd-w-downs100-0", "cmd-w-hold100-0"])
        self.assertEqual([row["invalid"] for row in rows], [[], [], [], []])
        self.assertEqual([row["close_tab"]["new_tab_keys"] for row in rows], [0, 1, 6, 6])
        self.assertEqual([row["close_tab"]["shown_after"]["is"] for row in rows],
                         ["the tab to the left of the closed tab", "the tab that was shown before the New Tab keys"]
                         + ["a new tab of the recording (place 5 of the 5 that are left, from the left)"] * 2)
        self.assertEqual([row["close_tab"]["closed_is"] for row in rows], ["the shown tab (newTab)"] + ["a new tab of the recording"] * 3)
        self.assertEqual([(row["close_tab"]["content_gone"], row["close_tab"]["content_shown"]) for row in rows], [(AT, AT)] * 4)
        self.assertEqual([row["tabs_before"] for row in rows], [3, 2, 2, 2])
        # One recording for each row, of the Close Tab key alone: the app's recorder sends no second key.
        self.assertEqual([(asked["key"], asked.get("repeat"), asked["above"], asked["capture"], asked["duration_ms"]) for asked in app.asked],
                         [("w", None, True, "screencapturekit", 2000.0)] * 4)
        # Each recording's tabs are closed again, and no more of them than the tool opened.
        self.assertEqual((app.closed, app.ids), ([1, 1, 6, 6], ["tab-0"]))
        self.assertEqual(report["cases"]["cmd-w/idle"]["close"]["shows"], {"the tab to the left of the closed tab": 1})

    def test_a_close_tab_row_of_a_run_with_no_asked_display_rate_is_invalid(self):
        # The same pictures as the test above, which are valid at an asked rate.
        report, said = self.run_mode(CloseApp(self.folder), display_hz=None)
        self.assertEqual([[reason.split(":")[0] for reason in row["invalid"]] for row in report["rows"]], [["display"]] * 4)
        # Each row's line gives no order of the strip and the content area: a count of frames is not known there.
        lines = [line for line in said.splitlines() if line.startswith("NEW-SURFACE-SCREEN-ROW ")]
        self.assertEqual(len(lines), 4)
        for line in lines:
            self.assertIn(" order='not known (no asked display rate)' ", line)

    def test_the_asked_display_rate_gets_to_the_reader_of_a_close_tab_key(self):
        # The closed tab's content is gone in the third row; after it the recorder gives a row for each third frame of
        # the display. The frame's number is the asked rate's, not that of the rows' own median step (25 ms).
        report, _ = self.run_mode(CloseApp(self.folder, [OLD_ROW, OLD_ROW, GONE] + [None, None, GONE] * 79), close_cases="idle")
        row = report["rows"][0]
        self.assertEqual((row["refresh_ms"], row["close_tab"]["content_gone"]["frame"]), (round(base.STEP, 3), 4))

    def test_a_close_tab_row_of_a_launch_that_is_not_clean_or_of_a_session_with_a_fault_is_invalid(self):
        def make(socket_path, count, live, url, deadline, out):
            return {"asked_more": count, "live_shells": live, "maker_exit": 0, "maker_said_made": count, "seed_s": 0.0}
        app = CloseApp(self.folder)
        screen = new_surface_screen.Screen(options(self.folder, close_cases="idle"), app.rpc, app.tools(), sleep=app.pause, make_session=make,
                                           clock=app.clock, start=app.start)
        screen.launch_fault = "launch: the app did not start from a clean state"
        with contextlib.redirect_stdout(io.StringIO()):
            report = screen.run()
        self.assertEqual(report["rows"][0]["invalid"], ["launch: the app did not start from a clean state"])
        # A session that is not the asked one: the maker made no workspace, so the app lists fewer than were asked.
        report, _ = self.run_mode(CloseApp(self.folder), close_cases="idle", workspaces=400)
        self.assertEqual([reason.split(":")[0] for reason in report["rows"][0]["invalid"]], ["session"])

    def test_the_new_tab_keys_are_one_key_down_for_each_call_at_the_times_of_a_held_key(self):
        app = CloseApp(self.folder)
        report, _ = self.run_mode(app)
        sent = [row["close_tab"]["new_tab_keys_sent_ms"] for row in report["rows"]]
        self.assertEqual(sent, [[], [-100.0]] + [[-835.0, -460.0, -370.0, -280.0, -190.0, -100.0]] * 2)
        # The idle case's own New Tab key (the tab that it closes) and the 7 of the `key` and `downs` cases: no repeat flag.
        self.assertEqual(app.keys, [{"key": "t", "modifiers": ["command"]}] * 8)
        self.assertEqual([row["close_tab"].get("new_tab_keys_by") for row in report["rows"]],
                         [None] + ["one `debug.key` call for each key-down, by the tool's clock: no repeat flag, not the app's event queue"] * 2
                         + ["one key sequence of `debug.key` in the app's event queue, by the app's clock: the first key-down, then repeats with the repeat flag"])
        # The idle case's tab is there 1.5 s before its recording starts: its opening is in no frame of the recording.
        self.assertGreaterEqual(app.strip_times[0] - app.key_times[0], 1.5)
        self.assertEqual(report["rows"][0]["close_tab"]["new_tab_marks_before_ms"], [])
        self.assertEqual([row["close_tab"]["last_new_tab_key_before_ms"] for row in report["rows"][1:]], [100.0, 100.0, 100.0])

    def test_the_hold_is_one_key_sequence_with_the_repeat_flag_in_the_shell_window(self):
        app = CloseApp(self.folder)
        report, _ = self.run_mode(app, close_cases="hold")
        # Command down, T down, 5 repeats of T at a held key's times, T up and Command up before the Close Tab key.
        t_down, t_again = {"key_code": 17, "down": True, "after_ms": 2.0}, {"key_code": 17, "down": True, "after_ms": 90.0, "repeat": True}
        self.assertEqual(app.sequences, [{"key_window": "shell", "sequence": [
            {"key_code": 55, "down": True}, t_down, {**t_again, "after_ms": 375.0}, t_again, t_again, t_again, t_again,
            {"key_code": 17, "down": False, "after_ms": 40.0}, {"key_code": 55, "down": False, "after_ms": 5.0}]}])
        self.assertEqual((app.keys, report["rows"][0]["invalid"]), ([], []))
        self.assertEqual(report["rows"][0]["close_tab"]["sequence"], {"scheduled": 9, "key_window": "shell", "sent_ms": -837.0})
        # The recording starts 120 ms before the Close Tab key's planned time: 20 ms before the last repeat.
        self.assertAlmostEqual(app.strip_times[0] - app.open_times[-1], -0.02, places=6)

    def test_a_key_sequence_that_the_app_refused_is_an_invalid_row_with_no_recording(self):
        app = CloseApp(self.folder)
        app.refuse_sequence = "the shell window did not become key"
        report, _ = self.run_mode(app, close_cases="hold")
        self.assertEqual(report["rows"][0]["invalid"], ['input: the app refused the hold\'s key sequence: "the shell window did not become key"'])
        self.assertEqual((app.asked, app.closed, app.ids), ([], [1], ["tab-0"]))

    def test_a_new_tab_key_that_the_app_refused_makes_the_row_invalid(self):
        app = CloseApp(self.folder)
        app.refuse_keys = {1}
        report, _ = self.run_mode(app, close_cases="key")
        reasons = report["rows"][0]["invalid"]
        self.assertTrue(any(reason.startswith("input: the New Tab key-down 1 of 1 was refused") for reason in reasons), reasons)
        self.assertEqual(app.ids, ["tab-0"])

    def test_a_close_tab_key_that_closed_nothing_is_an_invalid_row_and_its_tabs_are_closed_again(self):
        app = CloseApp(self.folder)
        app.closes = False
        report, _ = self.run_mode(app, close_cases="idle")
        row = report["rows"][0]
        self.assertTrue(row["invalid"][0].startswith("input: 0 New Tab key-downs and 1 Close Tab key sent"), row["invalid"])
        self.assertEqual((row["close_tab"]["shown_after"]["is"], app.closed, app.ids), ("no tab closed", [2], ["tab-0"]))

    def test_a_recording_that_the_app_refused_closes_what_the_tool_opened(self):
        app = CloseApp(self.folder)
        app.refused = {1}
        report, _ = self.run_mode(app, close_cases="downs")
        self.assertTrue(report["rows"][0]["invalid"][0].startswith("frame_strip: "), report["rows"][0]["invalid"])
        self.assertEqual((app.closed, app.ids), ([7], ["tab-0"]))

    def test_an_idle_close_of_a_page_in_another_engine_is_an_invalid_row(self):
        report, _ = self.run_mode(CloseApp(self.folder, engine="webkit"), close_cases="idle")
        self.assertEqual(report["rows"][0]["invalid"], ["engine: the closed tab's page ran in webkit, cef was asked"])

    def test_tabs_that_the_app_does_not_list_make_the_row_invalid(self):
        app = CloseApp(self.folder)
        app.focus = False
        report, _ = self.run_mode(app, close_cases="idle")
        self.assertTrue(report["rows"][0]["invalid"][0].startswith("tabs: "), report["rows"][0]["invalid"])

    def test_a_rows_line_and_a_cases_line_say_the_close(self):
        _, said = self.run_mode(CloseApp(self.folder), close_cases="idle")
        line = next(line for line in said.splitlines() if "-ROW cmd-w-idle-0" in line)
        self.assertIn(": valid ", line)
        self.assertIn(" closed='the shown tab (newTab)' shows='the tab to the left of the closed tab' content_gone=[3, 19.0] "
                      "shown=[3, 19.0] strip_first=[3, 19.0] between=0 blank=0", line)
        case = next(line for line in said.splitlines() if line.startswith("NEW-SURFACE-SCREEN cmd-w/idle: "))
        self.assertIn("shows after the close: the tab to the left of the closed tab 1/1", case)

    def test_the_limit_of_opening_records_is_one_recordings(self):
        count = new_surface_screen.openings
        # 12 runs of each case: a recording of 2 keys can make 4 records, a hold of 6 key-downs 12. The app keeps 64.
        self.assertEqual(count(options(self.folder, keys="n,t", gaps="0,100", runs=12)), 4)
        self.assertEqual(count(options(self.folder, keys="n,t,w", gaps="0,100", runs=12)), 12)
        self.assertEqual(count(options(self.folder, keys="w", hold_keys=31)), 62)
        self.assertEqual(count(options(self.folder, keys="w", hold_keys=31, close_cases="idle,key")), 2)

    def test_each_case_keeps_pictures_up_to_its_own_limit(self):
        # Each row keeps its pictures here (`--keep-keys` 2). With a limit of 4 for a case, the second row of each
        # case keeps none, and the first row of the NEXT case keeps its own again.
        with mock.patch.object(new_surface_screen, "PICTURES_A_CASE", 4, create=True):
            report, _ = self.run_mode(CloseApp(self.folder), runs=2, keep_keys=2)
        self.assertEqual([bool(row.get("kept_pictures")) for row in report["rows"]], [True, False] * 4)


if __name__ == "__main__":
    unittest.main()
