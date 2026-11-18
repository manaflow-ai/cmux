#!/usr/bin/env python3
"""new_surface_frames.py and new_surface_screen.py: one Cmd-T or Cmd-N from the frames of the screen.

No app, no display, no fleet: the frames are rows in the form that the app's frame_strip writes, and the app is a
function that answers the tool's calls. So this proves the tool's own reading and its INVALID rules, not that a
recording on a Mac gives such rows.

    python3 -I scripts/cmux-next/tests/test_new_surface_frames.py
"""
import argparse
import json
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # the imports leave no cache folder in the checkout
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import new_surface_frames as nsf  # noqa: E402
import new_surface_screen  # noqa: E402

STEP = 1000 / 120
OLD, NEW = (0, 0.3), (0.3, 0)  # a region as before the key, and as in the last picture
ROW_OLD, ROW_NEW = (0, 0.01), (0.01, 0)  # the window outside the pane: the same two
STILL = (0, 0)  # a region that the key does not change


def row(index, content, outside, blank=False, desync=False, strip=None, start=0.0):
    out = {"ms": round(start + STEP * index), "file": f"frame-{index + 2:03d}.png", "content_vs_before": content[0],
           "content_vs_final": content[1], "outside_vs_before": outside[0], "outside_vs_final": outside[1],
           "blank": blank, "desync": desync, "flatness": 0.5}
    if strip:
        out["strip_vs_before"], out["strip_vs_final"] = strip
    return out


def take(pictures, capture="screencapturekit", spans=None, **fields):
    """A recording: 2 frames before the key, then one frame of the display for each entry of `pictures`
    ((content, outside) or a dict of row()'s arguments)."""
    rows = [row(-2, OLD, ROW_OLD), row(-1, OLD, ROW_OLD)]
    for index, picture in enumerate(pictures):
        if picture is None:
            continue  # a frame that the recorder did not deliver
        rows.append(row(index + 1, **picture) if isinstance(picture, dict) else row(index + 1, *picture))
    return {"frames": rows, "capture": capture, "spans": spans or [], "frame_count": len(rows), "mean_interval_ms": STEP,
            "strip_intermediate": 0.0, "lead_ms": 120.0, **fields}


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

    def test_a_frame_number_is_the_displays_also_when_frames_were_not_delivered(self):
        pictures = [(OLD, ROW_OLD), None, None, None, None, (NEW, ROW_NEW)] + [(NEW, ROW_NEW)] * 234
        got = nsf.one_key(take(pictures), "n", asked_hz=120)
        self.assertEqual((got["content_first"]["frame"], got["content_first"]["ms"], got["frames_not_delivered"]), (6, 50, 4))

    def test_the_refresh_is_the_rows_own_when_the_asked_rate_is_not_theirs(self):
        rows = take([(NEW, ROW_NEW)] * 240)
        got = nsf.one_key(rows, "n", asked_hz=60)
        self.assertEqual(got["refresh_ms"], got["refresh_measured_ms"])  # the rows' own: 60 Hz was asked, 120 came
        self.assertAlmostEqual(got["refresh_ms"], STEP, delta=0.05)  # the rows' times are whole ms
        self.assertEqual((got["content_first"]["frame"], got["frames_not_delivered"]), (1, 0))


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

    def __init__(self, folder, pictures, opens=None, engine="cef", workspaces=3):
        self.folder, self.pictures, self.opens, self.engine = folder, pictures, opens, engine
        self.workspaces, self.tabs, self.openings, self.calls, self.closed, self.newest = workspaces, 1, [], [], [], []

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
            keys = params.get("repeat", 1)
            opened = keys if self.opens is None else self.opens
            self.openings += [{"spare": True}] * opened
            self.newest += [params["key"]] * opened
            if params["key"] == "n":
                self.workspaces += opened
            else:
                self.tabs += opened
            reply = take(self.pictures, spans=[{"name": "cmdN.start" if params["key"] == "n" else "newTab.open", "ms": 100.0 * n,
                                                "duration_ms": 1.0} for n in range(keys)])
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
        report = new_surface_screen.Screen(options(self.folder, **changed), app.rpc, app.tools(), sleep=lambda _: None,
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

    def test_the_session_is_made_to_the_asked_size_and_a_smaller_one_makes_each_row_invalid(self):
        app = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        report, _ = self.run_mode(app, keys="t", runs=1, workspaces=400, live_shells=12)
        self.assertEqual((report["session"]["asked_more"], report["session"]["listed_by_the_app"], report["session"]["as_asked"]), (397, 400, True))
        self.assertEqual(report["rows"][0]["invalid"], [])
        short = FakeApp(self.folder, [(NEW, ROW_NEW)] * 240)
        report = new_surface_screen.Screen(options(self.folder, keys="t", runs=1, workspaces=400), short.rpc, short.tools(),
                                           sleep=lambda _: None, make_session=lambda *_: {"maker_exit": 1}).run()
        self.assertEqual(report["rows"][0]["invalid"], ["session: 400 workspaces asked, the app lists 3"])


if __name__ == "__main__":
    unittest.main()
