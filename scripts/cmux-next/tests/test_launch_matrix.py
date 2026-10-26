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


class PictureTests(unittest.TestCase):
    SHOWN = {lm.SHOWN_MARK: 90.0, lm.REMOVED_MARK: 600.0}

    def test_each_expectation(self):
        refused = {"launch_picture_refused.crashRecovery": 80.0}
        self.assertEqual(lm.picture_problems(self.SHOWN, "shown"), [])
        self.assertTrue(lm.picture_problems(refused, "shown"))
        self.assertEqual(lm.picture_problems(refused, "refused", ("crashRecovery",)), [])
        self.assertIn("expected theme", lm.picture_problems(refused, "refused", ("theme",))[0])
        self.assertIn("no refusal", lm.picture_problems({}, "refused", ("theme",))[0])
        self.assertIn("showed", lm.picture_problems(self.SHOWN, "not-shown")[0])
        self.assertEqual(lm.picture_problems(refused, "not-shown"), [])
        self.assertEqual(lm.picture_problems(self.SHOWN, "any"), [])

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
        bench = mock.Mock(local_features={}, config={}, window=lm.FRAME, screen="last")
        lm.prepare_bench(bench, lm.CASE["translucent"], picture=True)
        self.assertEqual(bench.local_features, {lm.PICTURE_FEATURE: True})
        self.assertEqual(bench.config["appearance"]["backgroundOpacity"], 0.6)
        lm.prepare_bench(bench, lm.CASE["three-windows-two-displays"], picture=False)
        self.assertEqual((bench.window, bench.screen, bench.local_features[lm.PICTURE_FEATURE]), (None, None, False))


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
    and shows its saved picture when `picture_marks` says so."""

    def __init__(self, folder, still=sidebar_and_pane, fail_launch=None):
        self.app, self.tag, self.scratch, self.cli, self.socket = "/x/cmux DEV t.app", "t", folder, "/x/cmux", "/s"
        self.extra_env, self.config, self.local_features = {}, {}, {}
        self.window, self.screen, self.fresh_state, self.teardown, self.features = lm.FRAME, "last", True, None, None
        self.process, self.launches, self.stopped, self.actions = None, [], False, []
        self.workspaces = {"Workspace 1": [[1]]}
        self.still, self.fail_launch = still, fail_launch
        self.marks = {}
        self.picture_marks = {lm.SHOWN_MARK: 90.0, lm.REMOVED_MARK: 700.0}

    def launch(self, timeout=None, **kwargs):
        if self.fail_launch is not None and len(self.launches) == self.fail_launch:
            raise bl.LaunchError("crashed", {"detail": "stand-in launch failed"})
        self.launches.append(kwargs)
        self.process = FakeProcess(100 + len(self.launches))
        self.marks = dict(self.picture_marks) if len(self.launches) > 1 else {}
        return self

    def stop(self):
        self.stopped = True
        if self.process:
            self.process.end(0)

    def state_root(self):
        return self.scratch

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "action.run":
            name = params["action"]
            self.actions.append(name)
            if name == "quitKeepSessions":
                self.process.end(0)
            elif name in ("splitRight", "splitDown"):
                self.workspaces["Workspace 1"][0].append(1)
            return {}
        if method == "snapshot.get":
            return {"topology": topology(self.workspaces)}
        if method == "debug.window_list":
            return {"windows": [{"id": 7, "kind": "main", "visible": True,
                                 "frame": {"x": 40, "y": 40, "width": 100, "height": 60}}]}
        if method == "debug.window_snapshot":
            write_png(params["path"], 100, 60, self.still)
            return {"path": params["path"], "width": 100, "height": 60}
        if method == "debug.timings":
            return {"launch_ms_since_process_start": self.marks}
        if method == "debug.crash.app":
            self.process.end(-11)
            return {}
        return {"error": f"stand-in has no {method}"}


class FakeRun(lm.Run):
    """Run on the stand-in: the CLI's new-workspace goes to the stand-in, the clock is a counter."""

    def __init__(self, bench, out, **kwargs):
        self.clock = [0.0]
        super().__init__(bench, out, log=lambda _: None, now=lambda: self.clock[0],
                         sleep=lambda s: self.clock.__setitem__(0, self.clock[0] + s), **kwargs)

    def cli(self, *args, timeout=60):
        if args[:1] == ("new-workspace",):
            self.bench.workspaces[args[args.index("--name") + 1]] = [[1]]
        return subprocess.CompletedProcess(args, 0, "", "")


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
        bench.picture_marks = {"launch_picture_refused.crashRecovery": 80.0}
        row, _ = self.run_case("crash-recovery", bench)
        self.assertEqual(row["result"], lm.PASS, row["problems"])
        self.assertEqual(len(bench.launches), 3)
        self.assertEqual(bench.actions.count("quitKeepSessions"), 1)

    def test_a_launch_that_never_comes_up_fails_the_case_and_ends_the_tag(self):
        row, bench = self.run_case("crash-recovery", FakeBench(self.folder, fail_launch=1))
        self.assertEqual(row["result"], lm.FAIL)
        self.assertIn("did not come up: crashed", row["problems"][-1])
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


if __name__ == "__main__":
    unittest.main()
