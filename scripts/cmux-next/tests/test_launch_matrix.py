#!/usr/bin/env python3
"""The launch correctness matrix (launch_matrix.py, p08-startup done check 13, task p08-startup-071).

1. The checks: a blank still (one color, the traffic lights aside, or fully transparent) and a still that shows
   something; the restored layout (pane trees, windows, a workspace closed while the app was closed); the saved
   picture shown, refused for the case's reason or not shown; the picture over the live window at most 2 s.
2. The matrix names every done-check-13 case in order, the Chromium Host case only with F2 on, and restore-trace.py
   takes every case that relaunches.
3. A case on a stand-in app (no GUI): the warm control passes and fails without its picture, a crash case relaunches
   after a quit first, a launch that never comes up fails the case and still ends the tag, cef-host-kill skips without
   --f2 before any launch, and relaunch-e2e.py --matrix exits 1 on a FAIL row.

Linux and macOS; no app, no GUI session:

    python3 -m unittest scripts/cmux-next/tests/test_launch_matrix.py
"""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402
import home_pixels  # noqa: E402
import launch_matrix as lm  # noqa: E402

relaunch_e2e = bl.load_by_path("relaunch_e2e_matrix", str(HERE / "relaunch-e2e.py"))
restore_trace = bl.load_by_path("restore_trace_matrix", str(HERE / "restore-trace.py"))

DONE_CHECK_13 = ("first-launch", "scale-change", "appearance-flip", "theme-change", "crash-recovery", "crash-streak",
                 "incognito-leftovers", "three-windows-two-displays", "full-screen", "translucent",
                 "workspace-closed-while-closed", "daemon-cold", "daemon-unavailable", "no-window", "url-open",
                 "quit-during-launch")


def write_png(path, width, height, pixel):
    """An 8-bit RGB PNG whose pixel (x, y) is `pixel(x, y)`."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def glass(x, y):
    return (30, 32, 36)


def glass_with_lights(x, y):
    return (255, 95, 87) if y < 2 and x < 3 else glass(x, y)


def sidebar_and_pane(x, y):
    if x < 30:
        return (52, 54, 60) if y % 10 else (220, 220, 220)  # the sidebar with a text line every 10 rows
    return (16, 16, 16)


def topology(workspaces, windows=1, loaded=True):
    """`snapshot.get` topology: workspaces {name: [[tabs per pane] per screen]}."""
    return {"loaded": loaded, "daemon_state": "connected", "windows": [{"id": f"win_{i}"} for i in range(windows)],
            "workspaces": [{"id": f"ws_{i}", "name": name,
                            "screens": [{"panes": [{"id": f"pane_{i}_{j}_{k}", "tabs": [{"id": "t"}] * tabs}
                                                   for k, tabs in enumerate(screen)]} for j, screen in enumerate(shape)]}
                           for i, (name, shape) in enumerate(workspaces.items())]}


class StillTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()

    def still(self, pixel, width=100, height=60):
        path = os.path.join(self.folder, f"{pixel.__name__}.png")
        write_png(path, width, height, pixel)
        return path

    def blank(self, path):
        return lm.blank_problem(path, read=home_pixels.read_png)

    def test_window_material_alone_is_blank_with_or_without_the_traffic_lights(self):
        self.assertIn("blank", self.blank(self.still(glass)))
        self.assertIn("blank", self.blank(self.still(glass_with_lights)))

    def test_a_sidebar_beside_a_pane_is_not_blank(self):
        self.assertIsNone(self.blank(self.still(sidebar_and_pane)))

    def test_a_fully_transparent_still_is_blank(self):
        self.assertIn("transparent", lm.blank_problem("x.png", read=lambda _: (2, 1, ([bytearray(8)], 4))))

    def test_an_unreadable_still_is_a_problem(self):
        path = os.path.join(self.folder, "bad.png")
        Path(path).write_bytes(b"not a png")
        self.assertIn("unreadable", self.blank(path))


class LayoutTests(unittest.TestCase):
    BEFORE = {"main": [[1, 1, 1]], lm.SECOND_WORKSPACE: [[1]]}

    def test_the_same_pane_trees_restore_cleanly_whatever_their_order(self):
        expected = lm.layout_of(topology(self.BEFORE))
        got = lm.layout_of(topology(dict(reversed(list(self.BEFORE.items())))))
        self.assertEqual(lm.layout_problems(expected, got), [])

    def test_a_wrong_pane_tree_a_lost_window_and_an_unloaded_topology_fail(self):
        expected = lm.layout_of(topology(self.BEFORE, windows=2))
        wrong = lm.layout_problems(expected, lm.layout_of(topology({"main": [[1, 1]], lm.SECOND_WORKSPACE: [[1]]})))
        self.assertEqual(len(wrong), 2, wrong)
        self.assertIn("pane trees differ", wrong[0])
        self.assertIn("1 windows restored, 2 expected", wrong[1])
        self.assertEqual(lm.layout_problems(expected, lm.layout_of(topology(self.BEFORE, loaded=False))),
                         ["the topology never loaded"])

    def test_a_workspace_closed_while_the_app_was_closed_stays_closed(self):
        expected = lm.layout_of(topology(self.BEFORE))
        closed = {lm.SECOND_WORKSPACE}
        self.assertEqual(lm.layout_problems(expected, lm.layout_of(topology({"main": [[1, 1, 1]]})), closed=closed), [])
        back = lm.layout_problems(expected, lm.layout_of(topology(self.BEFORE)), closed=closed)
        self.assertIn(f"closed workspace {lm.SECOND_WORKSPACE!r} came back", back)

    def test_contains_allows_more_tabs_but_no_missing_workspace(self):
        expected = lm.layout_of(topology(self.BEFORE))
        grown = lm.layout_of(topology({"main": [[2, 1, 1]], lm.SECOND_WORKSPACE: [[1]]}))
        self.assertEqual(lm.layout_problems(expected, grown, "contains"), [])
        self.assertTrue(lm.layout_problems(expected, lm.layout_of(topology({"main": [[1]]})), "contains"))

    def test_dock_panes_are_not_part_of_the_tree(self):
        topo = topology({"main": [[1]]})
        topo["workspaces"][0]["screens"][0]["panes"].append({"id": "dock", "dock": "bottom", "tabs": [{}]})
        self.assertEqual(lm.layout_of(topo)["workspaces"], [("main", ((1,),))])


class FirstFrameTests(unittest.TestCase):
    BEFORE = {"main": [[1, 1, 1]], lm.SECOND_WORKSPACE: [[1]]}

    def test_a_first_frame_that_lists_a_closed_workspace_fails_even_before_the_topology_loads(self):
        expected, closed = lm.layout_of(topology(self.BEFORE)), {lm.SECOND_WORKSPACE}
        first = lm.layout_of(topology(self.BEFORE, loaded=False))
        self.assertEqual(lm.first_frame_problems(expected, first, closed=closed),
                         [f"the first frame lists closed workspace {lm.SECOND_WORKSPACE!r}"])
        clean = lm.layout_of(topology({"main": [[1, 1, 1]]}, loaded=False))
        self.assertEqual(lm.first_frame_problems(expected, clean, closed=closed), [])

    def test_a_first_frame_with_a_wrong_pane_tree_or_an_unknown_workspace_fails(self):
        expected = lm.layout_of(topology(self.BEFORE))
        wrong = lm.layout_of(topology({"main": [[1, 1]], "other": [[1]]}, loaded=False))
        problems = lm.first_frame_problems(expected, wrong)
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("'main' with pane tree ((1, 1),)", problems[0])
        self.assertIn("'other', which was not open", problems[1])

    def test_a_workspace_not_drawn_yet_and_the_skip_mode_are_not_checked(self):
        expected = lm.layout_of(topology(self.BEFORE))
        provisional = lm.layout_of(topology({"main": [], lm.SECOND_WORKSPACE: []}, loaded=False))
        self.assertEqual(lm.first_frame_problems(expected, provisional), [])
        self.assertEqual(lm.first_frame_problems(expected, lm.layout_of(topology({"x": [[9]]})), "skip"), [])


class PictureTests(unittest.TestCase):
    SHOWN = {lm.DECODED_MARK: 40.0, lm.SHOWN_MARK: 90.0, lm.REMOVED_MARK: 600.0}
    MISMATCH = {lm.DECODED_MARK: 40.0, lm.MISMATCH_MARK: 80.0}  # what LaunchSnapshotWindow.show records

    def test_each_expectation(self):
        self.assertEqual(lm.picture_problems(self.SHOWN, "shown"), [])
        self.assertIn("refused: mismatch", lm.picture_problems(self.MISMATCH, "shown")[0])
        self.assertIn("showed", lm.picture_problems(self.SHOWN, "not-shown")[0])
        self.assertIn("showed", lm.picture_problems(self.SHOWN, "refused", ("theme",))[0])
        self.assertEqual(lm.picture_problems(self.MISMATCH, "not-shown"), [])
        self.assertEqual(lm.picture_problems(self.SHOWN, "any"), [])

    def test_a_shown_picture_cuts_out_exactly_the_changed_regions(self):
        sidebar = {**self.SHOWN, lm.STALE_PREFIX + "sidebar": 85.0}
        self.assertEqual(lm.picture_problems(sidebar, "shown", stale=("sidebar",)), [])
        self.assertIn("cut out no region; expected sidebar", lm.picture_problems(self.SHOWN, "shown", stale=("sidebar",))[0])
        # An unchanged window whose region is cut: the launch's layout differs from the quit's.
        self.assertIn("cut out sidebar; expected none", lm.picture_problems(sidebar, "shown")[0])
        self.assertEqual(lm.picture_problems(sidebar, "any"), [])

    def test_the_mismatch_the_app_records_is_a_refusal_for_every_meta_reason(self):
        for reasons in (("frame", "screen", "scale"), ("appearance", "theme"), ("theme",), ("sidebarLayout",), ()):
            with self.subTest(reasons=reasons):
                self.assertEqual(lm.picture_problems(self.MISMATCH, "refused", reasons), [])

    def test_a_meta_reason_needs_a_recorded_refusal(self):
        self.assertIn("no refusal was recorded", lm.picture_problems({lm.DECODED_MARK: 40.0}, "refused", ("theme",))[0])
        self.assertEqual(lm.picture_problems({lm.DECODED_MARK: 40.0, "launch_picture_refused.theme": 80.0}, "refused",
                                             ("theme",)), [])

    def test_crash_and_incognito_need_only_a_picture_read_and_not_shown(self):
        # No launch path records launch_picture_refused.crashRecovery yet (WindowPictureStore.takeFront(matching:)).
        read = {lm.DECODED_MARK: 40.0}
        self.assertEqual(lm.picture_problems(read, "refused", ("crashRecovery",)), [])
        self.assertEqual(lm.picture_problems({**read, "launch_picture_refused.crashRecovery": 80.0}, "refused",
                                             ("crashRecovery",)), [])
        self.assertIn("meta mismatch", lm.picture_problems(self.MISMATCH, "refused", ("incognitoLeftovers",))[0])
        self.assertIn("expected crashRecovery", lm.picture_problems({**read, "launch_picture_refused.theme": 80.0},
                                                                    "refused", ("crashRecovery",))[0])

    def test_no_picture_read_is_a_harness_problem_not_a_refusal(self):
        self.assertIn("harness: no saved picture was read",
                      lm.picture_problems({lm.MISMATCH_MARK: 80.0}, "refused", ("theme",))[0])

    def test_the_picture_stays_at_most_its_bound(self):
        self.assertEqual(lm.stale_problems(self.SHOWN), [])
        self.assertEqual(lm.stale_problems({}), [])
        late = {lm.SHOWN_MARK: 90.0, lm.REMOVED_MARK: 90.0 + lm.STALE_LIMIT_MS + lm.STALE_SLACK_MS + 1}
        self.assertIn("stayed", lm.stale_problems(late)[0])
        self.assertIn("never left", lm.stale_problems({lm.SHOWN_MARK: 90.0})[0])


class MatrixTableTests(unittest.TestCase):
    def test_the_matrix_runs_every_done_check_13_case_in_order_plus_the_control_and_the_f2_case(self):
        names = [case.name for case in lm.CASES]
        self.assertEqual([n for n in names if n in DONE_CHECK_13], list(DONE_CHECK_13))
        self.assertEqual(set(names) - set(DONE_CHECK_13), {"warm", "cef-host-kill"})
        self.assertEqual([case.name for case in lm.CASES if case.needs_f2], ["cef-host-kill"])
        self.assertEqual(lm.CASE["warm"].picture, "shown", "the control proves a picture can show at all")

    def test_selection_and_its_errors(self):
        self.assertEqual([c.name for c in lm.select("crash-recovery,first-launch")], ["first-launch", "crash-recovery"])
        self.assertEqual(len(lm.select("all")), len(lm.CASES))
        with self.assertRaises(ValueError):
            lm.select("first-launch,nope")

    def test_with_the_picture_off_no_case_shows_one(self):
        self.assertEqual({lm.expected_picture(case, False) for case in lm.CASES}, {"not-shown"})

    def test_restore_trace_takes_every_case_that_relaunches(self):
        self.assertEqual(restore_trace.parse_args(["--app", "a.app", "--case", "theme-change"]).case, "theme-change")
        self.assertNotIn("first-launch", lm.RELAUNCH_CASES)
        with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
            restore_trace.parse_args(["--app", "a.app", "--case", "first-launch"])

    def test_relaunch_e2e_refuses_a_matrix_with_a_story_or_an_unknown_case(self):
        self.assertEqual(relaunch_e2e.parse_args(["--tag", "t", "--matrix", "all"]).matrix, "all")
        for argv in (["--tag", "t", "--matrix", "nope"], ["--tag", "t", "--matrix", "all", "--story", "relaunch-e2e"]):
            with self.subTest(argv=argv), self.assertRaises(SystemExit), mock.patch("sys.stderr"):
                relaunch_e2e.parse_args(argv)

    def test_prepare_bench_turns_the_picture_on_and_adds_the_case_config(self):
        bench = mock.Mock(local_features={}, config={}, window=(40, 40, 1440, 900), screen="last")
        lm.prepare_bench(bench, lm.CASE["translucent"], picture=True)
        self.assertEqual(bench.local_features, {lm.PICTURE_FEATURE: True})
        self.assertEqual(bench.config["appearance"]["backgroundOpacity"], 0.6)
        lm.prepare_bench(bench, lm.CASE["three-windows-two-displays"], picture=False)
        self.assertEqual((bench.window, bench.screen, bench.local_features[lm.PICTURE_FEATURE]), (None, None, False))

    def test_no_picture_case_launches_under_a_test_placement(self):
        # LaunchSnapshotWindow.open shows no picture while CMUX_NEXT_TEST_WINDOW_* places the window.
        folder = tempfile.mkdtemp()
        app = os.path.join(folder, "cmux DEV t.app")
        os.makedirs(app)
        for case in lm.CASES:
            with self.subTest(case=case.name):
                bench = bl.BenchApp(app, out=os.path.join(folder, case.name), config={}, window=(40, 40, 1100, 720),
                                    screen="last")
                lm.prepare_bench(bench, case, picture=True)
                self.assertEqual(lm.test_placement_keys(bench.environment()), [])

    def test_run_matrix_makes_its_benches_without_a_test_placement(self):
        made = []

        def bench_app(app, **kwargs):
            made.append(kwargs)
            return mock.Mock(local_features={}, config={}, window=kwargs["window"], screen=kwargs["screen"])

        with mock.patch.object(lm, "run_case", return_value={"case": "warm", "result": lm.PASS}):
            lm.run_matrix("/x/cmux DEV t.app", "warm", tempfile.mkdtemp(), bench_app=bench_app, log=lambda _: None)
        self.assertEqual((made[0]["window"], made[0]["screen"]), (None, None))


# ---------------------------------------------------------------- a stand-in app

class FakeProcess:
    def __init__(self, pid):
        self.pid, self.returncode = pid, None

    def poll(self):
        return self.returncode

    def end(self, code):
        if self.returncode is None:
            self.returncode = code

    def wait(self, timeout=None):
        if self.returncode is None:
            raise subprocess.TimeoutExpired("app", timeout)
        return self.returncode

    def kill(self):
        self.end(-9)

    def terminate(self):
        self.end(-15)

    def send_signal(self, sig):
        self.end(-sig)


class FakeBench:
    """The BenchApp surface launch_matrix uses: launches, the socket, stop. The app keeps its layout across launches
    and records `picture_marks` on each relaunch. `screens` is [(backing scale, [x, y, w, h])] per NSScreen; the
    window is 100x60 points and its still is that many points times its screen's scale. `debug.window_frame` replies
    in the app's shape (DebugLayers.setWindowFrame: [x, y, w, h] lists). `provisional`, when set, is the topology of
    each launch's first `snapshot.get` (the launch snapshot's model the first frame draws)."""

    def __init__(self, folder, still=sidebar_and_pane, fail_launch=None, screens=((2.0, [0, 0, 1512, 982]),)):
        self.app, self.tag, self.scratch, self.cli, self.socket = "/x/cmux DEV t.app", "t", folder, "/x/cmux", "/s"
        self.extra_env, self.config, self.local_features = {}, {}, {}
        self.window, self.screen, self.fresh_state, self.teardown, self.features = None, None, True, None, None
        self.process, self.launches, self.stopped, self.actions = None, [], False, []
        self.workspaces = {"Workspace 1": [[1]]}
        self.still, self.fail_launch = still, fail_launch
        self.screens, self.on_screen, self.full_screen = list(screens), 0, False
        self.marks = {}
        self.picture_marks = {lm.DECODED_MARK: 40.0, lm.SHOWN_MARK: 90.0, lm.REMOVED_MARK: 700.0}
        self.provisional, self.first_read = None, False

    def launch(self, timeout=None, **kwargs):
        if self.fail_launch is not None and len(self.launches) == self.fail_launch:
            raise bl.LaunchError("crashed", {"detail": "stand-in launch failed"})
        self.launches.append(kwargs)
        self.process = FakeProcess(100 + len(self.launches))
        self.marks = dict(self.picture_marks) if len(self.launches) > 1 else {}
        self.first_read = len(self.launches) > 1
        return self

    def stop(self):
        self.stopped = True
        if self.process:
            self.process.end(0)

    def state_root(self):
        return self.scratch

    def window_frame(self, params):
        if "screen" in params:
            index = len(self.screens) - 1 if params["screen"] == "last" else params["screen"]
            if not 0 <= index < len(self.screens):
                return {"error": "no such screen"}
            self.on_screen = index
        whole = self.screens[self.on_screen][1]
        frame = list(whole) if self.full_screen else [whole[0] + 40, whole[1] + 40, 100, 60]
        return {"frame": frame, "screen": f"Display {self.on_screen}", "visible_frame": whole, "screen_frame": whole}

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "action.run":
            name = params["action"]
            self.actions.append(name)
            if name == "quitKeepSessions":
                self.process.end(0)
                os.makedirs(os.path.join(self.scratch, lm.PICTURES_FOLDER), exist_ok=True)
                Path(self.scratch, lm.PICTURES_FOLDER, "screen.txt").write_text(str(self.on_screen))
            elif name in ("splitRight", "splitDown"):
                self.workspaces["Workspace 1"][0].append(1)
            elif name == "toggleFullScreen":
                self.full_screen = not self.full_screen
            return {}
        if method == "snapshot.get":
            if self.first_read and self.provisional is not None:
                self.first_read = False
                return {"topology": topology(self.provisional, loaded=False)}
            self.first_read = False
            return {"topology": topology(self.workspaces)}
        if method == "debug.window_frame":
            return self.window_frame(params)
        if method == "debug.window_list":
            return {"windows": [{"id": 7, "kind": "main", "visible": True,
                                 "frame": {"x": 40, "y": 40, "width": 100, "height": 60}}]}
        if method == "debug.window_snapshot":
            scale = self.screens[self.on_screen][0]
            write_png(params["path"], int(100 * scale), int(60 * scale), self.still)
            return {"path": params["path"], "width": int(100 * scale), "height": int(60 * scale)}
        if method == "debug.timings":
            return {"launch_ms_since_process_start": self.marks}
        if method == "debug.crash.app":
            self.process.end(-11)
            return {}
        return {"error": f"stand-in has no {method}"}


class FakeRun(lm.Run):
    """Run on the stand-in: the CLI's new-workspace and the daemon's workspace requests go to the stand-in, the clock
    is a counter."""

    def __init__(self, bench, out, log=None, **kwargs):
        self.clock = [0.0]
        super().__init__(bench, out, log=lambda _: None, now=lambda: self.clock[0],
                         sleep=lambda s: self.clock.__setitem__(0, self.clock[0] + s), **kwargs)

    def cli(self, *args, timeout=60):
        if args[:1] == ("new-workspace",):
            self.bench.workspaces[args[args.index("--name") + 1]] = [[1]]
        return subprocess.CompletedProcess(args, 0, "", "")

    def daemon(self, cmd, **fields):
        if cmd == "list-workspaces":
            return {"data": {"workspaces": [{"key": name, "name": name} for name in self.bench.workspaces]}}
        if cmd == "close-workspace":
            self.bench.workspaces.pop(fields["key"], None)
            return {"ok": True}
        return {"error": f"stand-in daemon has no {cmd}"}


class ScreenTests(unittest.TestCase):
    """screens(), other_scale_screen() and full_screen() on `debug.window_frame` replies in the app's shape."""

    TWO_SCALES = ((2.0, [0, 0, 1512, 982]), (1.0, [1512, 0, 1920, 1080]))

    def run_on(self, bench):
        return FakeRun(bench, os.path.join(bench.scratch, "case"))

    def test_screens_reads_each_screen_scale_from_the_list_frames(self):
        bench = FakeBench(tempfile.mkdtemp(), screens=self.TWO_SCALES)
        found = lm.screens(self.run_on(bench))
        self.assertEqual(found, [(0, 2.0, [0, 0, 1512, 982]), (1, 1.0, [1512, 0, 1920, 1080])])

    def test_other_scale_screen_skips_with_one_scale(self):
        bench = FakeBench(tempfile.mkdtemp(), screens=((2.0, [0, 0, 1512, 982]), (2.0, [1512, 0, 1512, 982])))
        with self.assertRaises(lm.Skip):
            lm.other_scale_screen(self.run_on(bench))

    def test_other_scale_screen_keeps_the_first_screens_pictures_and_moves_the_window(self):
        bench = FakeBench(tempfile.mkdtemp(), screens=self.TWO_SCALES)
        run = self.run_on(bench)
        bench.launch()
        lm.other_scale_screen(run)
        self.assertEqual(bench.on_screen, 1, "the relaunch's window is on the other screen")
        self.assertEqual(Path(run.pictures_aside, "screen.txt").read_text(), "0")
        run.quit()  # the case's own quit saves the other screen's pictures
        lm.restore_first_pictures(run)
        self.assertEqual(Path(bench.scratch, lm.PICTURES_FOLDER, "screen.txt").read_text(), "0")

    def test_full_screen_compares_the_list_frames(self):
        bench = FakeBench(tempfile.mkdtemp())
        lm.full_screen(self.run_on(bench))  # toggles it on: the frame is the screen's, no Skip
        self.assertTrue(bench.full_screen)
        with self.assertRaises(lm.Skip):
            lm.full_screen(self.run_on(bench))  # toggles it off: the window is not full screen


class RunCaseTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()

    def run_case(self, name, bench=None, **kwargs):
        bench = bench or FakeBench(self.folder)
        run = FakeRun(bench, os.path.join(self.folder, name), **kwargs)
        return lm.run_case(run, lm.CASE[name]), bench

    def test_the_warm_control_passes_with_its_picture_and_its_layout(self):
        row, bench = self.run_case("warm")
        self.assertEqual(row["result"], lm.PASS, row["problems"])
        self.assertTrue(row["screenshot"].endswith("first-1.png") and os.path.exists(row["screenshot"]))
        self.assertEqual(len(bench.launches), 2, "a fresh launch and the checked relaunch")
        self.assertTrue(bench.stopped)
        self.assertTrue(lm.line(row).startswith(f"PASS warm "), lm.line(row))

    def test_the_warm_control_fails_without_its_picture(self):
        bench = FakeBench(self.folder)
        bench.picture_marks = {}
        row, _ = self.run_case("warm", bench)
        self.assertEqual(row["result"], lm.FAIL)
        self.assertIn("did not show", row["problems"][0])

    def test_a_blank_first_frame_fails(self):
        row, _ = self.run_case("warm", FakeBench(self.folder, still=glass))
        self.assertEqual(row["result"], lm.FAIL)
        self.assertTrue(any("blank" in p for p in row["problems"]), row["problems"])

    def test_a_crash_case_quits_and_relaunches_first_so_a_picture_is_on_disk(self):
        bench = FakeBench(self.folder)
        bench.picture_marks = {lm.DECODED_MARK: 40.0}
        row, _ = self.run_case("crash-recovery", bench)
        self.assertEqual(row["result"], lm.PASS, row["problems"])
        self.assertEqual(len(bench.launches), 3)
        self.assertEqual(bench.actions.count("quitKeepSessions"), 1)

    def test_the_theme_change_passes_on_the_mismatch_mark_the_app_records(self):
        bench = FakeBench(self.folder)
        bench.picture_marks = {lm.DECODED_MARK: 40.0, lm.MISMATCH_MARK: 80.0}
        row, _ = self.run_case("theme-change", bench)
        self.assertEqual(row["result"], lm.PASS, row["problems"])

    def test_scale_change_runs_on_two_scales_and_skips_on_one(self):
        bench = FakeBench(self.folder, screens=ScreenTests.TWO_SCALES)
        bench.picture_marks = {lm.DECODED_MARK: 40.0, lm.MISMATCH_MARK: 80.0}
        row, _ = self.run_case("scale-change", bench)
        self.assertEqual(row["result"], lm.PASS, row["problems"])
        row, _ = self.run_case("scale-change", FakeBench(tempfile.mkdtemp()))
        self.assertEqual(row["result"], lm.SKIP, row)

    def test_full_screen_and_three_windows_give_a_row(self):
        row, _ = self.run_case("full-screen", FakeBench(self.folder))
        self.assertIn(row["result"], (lm.PASS, lm.FAIL))
        self.assertFalse(any("AttributeError" in p for p in row["problems"]), row["problems"])
        row, _ = self.run_case("three-windows-two-displays", FakeBench(tempfile.mkdtemp()))
        self.assertEqual((row["result"], row["skip"]), (lm.SKIP, "one display"))

    def test_workspace_closed_while_closed_checks_the_first_frame(self):
        bench = FakeBench(self.folder)
        bench.picture_marks = {lm.DECODED_MARK: 40.0, lm.STALE_PREFIX + "sidebar": 85.0, lm.SHOWN_MARK: 90.0,
                               lm.REMOVED_MARK: 600.0}
        row, _ = self.run_case("workspace-closed-while-closed", bench)
        self.assertEqual(row["result"], lm.PASS, row["problems"])
        whole = FakeBench(tempfile.mkdtemp())
        whole.picture_marks = {lm.DECODED_MARK: 40.0, lm.SHOWN_MARK: 90.0, lm.REMOVED_MARK: 600.0}
        row, _ = self.run_case("workspace-closed-while-closed", whole)
        self.assertEqual(row["result"], lm.FAIL)
        self.assertIn("the picture cut out no region; expected sidebar", row["problems"])
        stale = FakeBench(tempfile.mkdtemp())
        stale.picture_marks = dict(bench.picture_marks)
        stale.provisional = {"Workspace 1": [[1, 1, 1]], lm.SECOND_WORKSPACE: [[1]]}  # the first frame lists it
        row, _ = self.run_case("workspace-closed-while-closed", stale)
        self.assertEqual(row["result"], lm.FAIL)
        self.assertIn(f"the first frame lists closed workspace {lm.SECOND_WORKSPACE!r}", row["problems"])

    def test_translucent_needs_the_whole_picture_shown(self):
        # The backdrop rule: a translucent window's theme fingerprint and layout match, so its picture shows uncut.
        bench = FakeBench(self.folder)
        bench.picture_marks = {lm.DECODED_MARK: 40.0, lm.SHOWN_MARK: 90.0, lm.REMOVED_MARK: 600.0}
        row, _ = self.run_case("translucent", bench)
        self.assertEqual(row["result"], lm.PASS, row["problems"])
        refused = FakeBench(tempfile.mkdtemp())
        refused.picture_marks = {lm.DECODED_MARK: 40.0, lm.MISMATCH_MARK: 80.0}
        row, _ = self.run_case("translucent", refused)
        self.assertEqual(row["result"], lm.FAIL)
        self.assertIn("the saved picture did not show (refused: mismatch)", row["problems"])
        cut = FakeBench(tempfile.mkdtemp())
        cut.picture_marks = {lm.DECODED_MARK: 40.0, lm.STALE_PREFIX + "pane": 85.0, lm.SHOWN_MARK: 90.0,
                             lm.REMOVED_MARK: 600.0}
        row, _ = self.run_case("translucent", cut)
        self.assertEqual(row["result"], lm.FAIL)
        self.assertIn("the picture cut out pane; expected none", row["problems"])

    def test_a_launch_that_never_comes_up_fails_the_case_and_ends_the_tag(self):
        row, bench = self.run_case("crash-recovery", FakeBench(self.folder, fail_launch=1))
        self.assertEqual(row["result"], lm.FAIL)
        self.assertIn("did not come up: crashed", row["problems"][-1])
        self.assertTrue(bench.stopped)

    def test_an_unexpected_error_is_a_fail_row(self):
        with mock.patch.object(lm, "build_layout", side_effect=AttributeError("'list' object has no attribute 'get'")):
            row, bench = self.run_case("warm")
        self.assertEqual(row["result"], lm.FAIL)
        self.assertIn("harness: AttributeError", row["problems"][-1])
        self.assertTrue(bench.stopped)

    def test_cef_host_kill_skips_without_f2_before_any_launch(self):
        row, bench = self.run_case("cef-host-kill")
        self.assertEqual((row["result"], bench.launches), (lm.SKIP, []))
        self.assertIn("--f2", row["skip"])

    def test_relaunch_e2e_matrix_exits_1_on_a_fail_row(self):
        app = os.path.join(self.folder, "cmux DEV t.app")
        os.makedirs(app)
        for rows, code in (([{"result": lm.PASS}], 0), ([{"result": lm.SKIP}, {"result": lm.FAIL}], 1)):
            with self.subTest(code=code), mock.patch.object(relaunch_e2e.launch_matrix, "run_matrix",
                                                            return_value=rows) as ran:
                self.assertEqual(relaunch_e2e.main(["--tag", "t", "--app", app, "--matrix", "warm",
                                                    "--out", self.folder]), code)
                self.assertEqual(ran.call_args.args[1], "warm")


class MatrixRunTests(unittest.TestCase):
    def test_one_case_that_raises_does_not_stop_the_matrix_and_the_report_is_written(self):
        out = tempfile.mkdtemp()

        def bench_app(app, out, **kwargs):
            return FakeBench(out)

        real = lm.build_layout
        calls = []

        def build_layout(run):
            calls.append(run)
            if len(calls) == 1:
                raise AttributeError("'list' object has no attribute 'get'")
            return real(run)

        with mock.patch.object(lm, "Run", FakeRun), mock.patch.object(lm, "build_layout", side_effect=build_layout):
            rows = lm.run_matrix("/x/cmux DEV t.app", "warm,theme-change", out, bench_app=bench_app,
                                 log=lambda _: None)
        self.assertEqual([(r["case"], r["result"]) for r in rows], [("warm", lm.FAIL), ("theme-change", lm.FAIL)])
        self.assertIn("harness: AttributeError", rows[0]["problems"][-1])
        self.assertIn("showed; expected refused", " ".join(rows[1]["problems"]))  # the stand-in's picture shows
        report = json.loads(Path(out, "launch-matrix.json").read_text())
        self.assertEqual([c["case"] for c in report["cases"]], ["warm", "theme-change"])


class FakeTraceApp:
    """perf-gate.py's App surface restore-trace.py uses, on a FakeBench."""

    def __init__(self, bench):
        self.bench = bench

    def launch(self):
        self.bench.launch()

    def stop(self):
        self.bench.stop()

    def quiet_counters(self):
        pass

    def topology(self):
        return self.bench.rpc("snapshot.get")["topology"]

    def rpc(self, method, params=None, timeout=60):
        return self.bench.rpc(method, params, timeout)

    def action(self, name, args=None, target=None):
        return self.bench.rpc("action.run", {"action": name, "args": args or {}})


class FakeGate:
    def __init__(self, app, opts):
        self.app, self.grid_workspace = app, "ws_0"

    def build_grid(self):
        self.app.bench.workspaces["Workspace 1"] = [[1, 1, 1, 1]]


class RestoreTraceCaseTests(unittest.TestCase):
    def trace(self, bench, *patches):
        out = tempfile.mkdtemp()
        with mock.patch.object(restore_trace.pg, "App", lambda app, out: FakeTraceApp(bench)), \
                mock.patch.object(restore_trace.pg, "Gate", FakeGate), \
                mock.patch.object(restore_trace.matrix, "Run", FakeRun), mock.patch("builtins.print"):
            for patch in patches:
                patch.start()
            try:
                code = restore_trace.main(["--app", "a.app", "--out", out, "--seconds", "0",
                                           "--case", "workspace-closed-while-closed"])
            finally:
                for patch in patches:
                    patch.stop()
        lines = [json.loads(text) for text in Path(out, "restore-trace.jsonl").read_text().splitlines()]
        return code, next(line["case"] for line in lines if "case" in line)

    def test_workspace_closed_while_closed_makes_its_workspace_and_gives_a_row(self):
        bench = FakeBench(tempfile.mkdtemp())
        bench.picture_marks = {lm.DECODED_MARK: 40.0, lm.STALE_PREFIX + "sidebar": 85.0, lm.SHOWN_MARK: 90.0,
                               lm.REMOVED_MARK: 600.0}
        code, row = self.trace(bench)
        self.assertEqual((code, row["result"]), (0, lm.PASS), row["problems"])
        self.assertNotIn(lm.SECOND_WORKSPACE, bench.workspaces)

    def test_a_harness_error_in_the_case_is_a_fail_row(self):
        bench = FakeBench(tempfile.mkdtemp())
        code, row = self.trace(bench, mock.patch.object(restore_trace.matrix, "add_second_workspace"))
        self.assertEqual((code, row["result"]), (1, lm.FAIL))
        self.assertIn(f"the daemon lists no workspace {lm.SECOND_WORKSPACE!r}", row["problems"][-1])
        self.assertTrue(bench.stopped)

    def test_a_relaunch_that_never_comes_up_is_a_fail_row(self):
        bench = FakeBench(tempfile.mkdtemp(), fail_launch=1)
        code, row = self.trace(bench)
        self.assertEqual((code, row["result"]), (1, lm.FAIL))
        self.assertIn("did not come up: crashed", row["problems"][-1])


if __name__ == "__main__":
    unittest.main()
