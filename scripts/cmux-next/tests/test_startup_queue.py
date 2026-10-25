#!/usr/bin/env python3
"""startup-queue.py: one fixture per mode (blocking, gaps, profile, mainjobs, globaljobs, arms), the --json and
--check output, the fleet guard, and the live run loop against a fake bench-startup module.

Runs on any host (Linux included): no app, no fleet, no network.

    python3 scripts/cmux-next/tests/test_startup_queue.py
"""

from __future__ import annotations

import contextlib
import gzip
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("startup_queue", HERE / "startup-queue.py")
sq = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sq)

FLEET = {"CMUX_CI_STEP_KEY": "step-1"}


def blocking_run(complete, sites, overflow=0, **marks):
    return {"marks": {"startup_complete": complete, **marks},
            "result": {"mode": "record", "overflow": overflow, "sites": sites}}


def census_run(first_frame=200.0, complete=900.0, **result):
    return {"milestones": {"first_window_frame_committed": first_frame, "startup_complete": complete}, **result}


def meta(pid, tid=None, process=None, thread=None):
    if process:
        return {"ph": "M", "pid": pid, "name": "process_name", "args": {"name": process}}
    return {"ph": "M", "pid": pid, "tid": tid, "name": "thread_name", "args": {"name": thread}}


def cpu(name, ts_ms, dur_ms, pid=10, tid=1):
    return {"ph": "X", "pid": pid, "tid": tid, "ts": ts_ms * 1000, "dur": dur_ms * 1000, "name": name, "cat": "cpu"}


def mark(name, ts_ms, pid=10, signpost=False):
    if signpost:
        return {"ph": "i", "s": "t", "pid": pid, "tid": 99, "ts": ts_ms * 1000, "name": "launch.mark",
                "cat": "signpost.launch", "args": {"message": name}}
    return {"ph": "i", "s": "t", "pid": pid, "tid": 99, "ts": ts_ms * 1000, "name": name}


def launch_trace(load_ms, init_ms=1.5, signpost=False):
    """App pid 10, main tid 1; another process's main thread (pid 20) must be ignored.

    0-20 ms: main > AppDelegate.didFinishLaunching > SettingsController.load (load_ms) and a one-time init.
    The first frame lands at 30 ms, startup completes at 100 ms. A 6 ms turn at 50 ms, a 2 ms turn at 70 ms."""
    return [
        meta(10, process="app: cmux DEV"), meta(10, 1, thread="Main Thread 1"),
        meta(20, process="daemon: cmux-tui"), meta(20, 2, thread="Main Thread 2"),
        cpu("main", 0, 20), cpu("CmuxNextApp AppDelegate.didFinishLaunching", 0, 20),
        cpu("CmuxNextSettings SettingsController.load", 0, load_ms),
        cpu("CmuxNextApp one-time initialization function for catalog", 15, init_ms),
        cpu("CmuxNextApp SettingsController.load", 40, 5),  # after the first frame: not counted
        cpu("main", 50, 6), cpu("CmuxNextHome HomeService.start", 50, 5),
        cpu("main", 70, 2), cpu("CmuxNextApp tiny", 70, 2),
        cpu("main", 120, 10), cpu("CmuxNextApp afterComplete", 120, 10),  # after startup_complete
        cpu("CmuxNextDaemon busy", 0, 50, pid=20, tid=2),
        mark("main_start", 0, signpost=signpost), mark("first_window_frame_committed", 30, signpost=signpost),
        mark("startup_complete", 100, signpost=signpost),
    ]


class Files:
    def __init__(self):
        self.folder = tempfile.mkdtemp(prefix="startup-queue-test-")

    def json(self, name, data, compress=False):
        path = os.path.join(self.folder, name)
        payload = json.dumps(data).encode()
        with open(path, "wb") as out:
            out.write(gzip.compress(payload) if compress else payload)
        return path


def read_doc(path):
    with open(path) as source:
        return json.load(source)


def run_cli(argv, env=None, system="Linux"):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = sq.main(argv, env=env or {}, system=system)
        except SystemExit as exit_:
            code = exit_.code
    return code, out.getvalue(), err.getvalue()


class BlockingTests(unittest.TestCase):
    def test_sites_first_hit_before_the_mark_ranked_by_runs(self):
        runs = [
            blocking_run(900, [{"kind": "fileRead", "location": "A.swift:1", "count": 3},
                               {"kind": "lockWait", "location": "B.swift:2", "count": 1, "first_ms": 950}]),
            blocking_run(900, [{"kind": "fileRead", "location": "A.swift:1", "count": 2},
                               {"kind": "lockWait", "location": "B.swift:2", "count": 1, "first_ms": 400}]),
            blocking_run(900, [], **{"launch.interrupted": True}),
        ]
        hits, warnings, used = sq.blocking_hits(runs, "startup_complete")
        self.assertEqual(used, 2)
        self.assertEqual([(h["location"], h["runs"], h["count"]) for h in hits], [("A.swift:1", 2, 5), ("B.swift:2", 1, 1)])
        self.assertIn("interrupted", warnings[0])

    def test_overflow_is_a_warning(self):
        _, warnings, _ = sq.blocking_hits([blocking_run(900, [], overflow=4)], "startup_complete")
        self.assertIn("4 sites past", warnings[0])

    def test_cli_reads_a_raw_capture_and_writes_json(self):
        files = Files()
        raw = files.json("raw.json", {"mode": "blocking", "runs": [
            blocking_run(900, [{"kind": "sync", "location": "C.swift:3", "count": 1}])]})
        out = os.path.join(files.folder, "out.json")
        code, stdout, _ = run_cli(["blocking", raw, "--json", out, "--check"])
        self.assertEqual(code, 1, "--check exits 1 with a hit")
        doc = read_doc(out)
        self.assertEqual((doc["queue"], doc["template"], doc["runs"]), ("Q5", "038", 1))
        self.assertEqual(doc["hits"][0]["location"], "C.swift:3")
        self.assertIn("C.swift:3", stdout)

    def test_a_clean_launch_passes_check(self):
        files = Files()
        raw = files.json("raw.json", [{"marks": {"startup_complete": 1}, "result": {"sites": []}}])
        self.assertEqual(run_cli(["blocking", raw, "--check"])[0], 0)


class GapsTests(unittest.TestCase):
    BENCH = {"nx": {"warm": [
        {"main_start": 10, "did_finish_launching_start": 40, "first_window_frame_committed": 60,
         "launch.temperature": "warm", "stalls": []},
        {"main_start": 12, "did_finish_launching_start": 50, "first_window_frame_committed": 63},
        {"main_start": 11, "did_finish_launching_start": 45, "first_window_frame_committed": 61},
        {"main_start": 0, "did_finish_launching_start": 900, "first_window_frame_committed": 901,
         "launch.interrupted": True},
    ], "cold": [{"main_start": 30, "first_window_frame_committed": 330}]}}

    def test_median_gaps_over_the_threshold(self):
        files = Files()
        code, _, _ = run_cli(["gaps", files.json("warm.json", self.BENCH), "--min-ms", "5", "--mode-filter", "warm",
                              "--json", os.path.join(files.folder, "o.json")])
        self.assertEqual(code, 0)
        doc = read_doc(os.path.join(files.folder, "o.json"))
        self.assertEqual(doc["runs"], 3, "the interrupted run is left out")
        self.assertEqual([(h["from"], h["to"], h["p50_ms"]) for h in doc["hits"]],
                         [("main_start", "did_finish_launching_start", 34.0),
                          ("did_finish_launching_start", "first_window_frame_committed", 16.0)])
        self.assertTrue(any("interrupted" in w for w in doc["warnings"]))

    def test_threshold_drops_small_gaps_and_modes_are_separate(self):
        hits, _, used = sq.gaps_hits([Files().json("b.json", self.BENCH)], 20.0, None)
        self.assertEqual(used, 4)
        self.assertEqual({(h["run_set"], h["from"]) for h in hits}, {("nx warm", "main_start"), ("nx cold", "main_start")})

    def test_gaps_has_no_live_mode(self):
        self.assertEqual(run_cli(["gaps", "--app", "/x/cmux DEV t.app"])[0], 2)


class ProfileTests(unittest.TestCase):
    def test_symbols_turns_and_static_inits(self):
        files = Files()
        traces = []
        for index, load in enumerate((8, 9, 12)):
            folder = os.path.join(files.folder, f"run{index}")
            os.mkdir(folder)
            with open(os.path.join(folder, "trace.json.gz"), "wb") as out:
                out.write(gzip.compress(json.dumps({"traceEvents": launch_trace(load, signpost=index == 2)}).encode()))
            traces.append(folder)
        hits, warnings, used = sq.profile_hits(traces, "first_window_frame_committed", "startup_complete", 2.0, 4.0, 1.0)
        self.assertEqual((used, warnings), (3, []))
        by_kind = {}
        for hit in hits:
            by_kind.setdefault(hit["kind"], {})[hit["site"]] = hit
        symbols = by_kind["symbol"]
        self.assertEqual(symbols["CmuxNextSettings SettingsController.load"]["p50_ms"], 9.0)
        self.assertEqual(symbols["CmuxNextApp AppDelegate.didFinishLaunching"]["p50_ms"], 20.0)
        self.assertNotIn("main", symbols, "generic frames are not owners")
        self.assertNotIn("CmuxNextDaemon busy", symbols, "only the app's main thread counts")
        self.assertNotIn("CmuxNextApp SettingsController.load", symbols, "after the first frame")
        turns = by_kind["turn"]
        # A turn's owner is its deepest frame over half the turn: the 12 ms load owns run 3's first turn.
        self.assertEqual(set(turns), {"CmuxNextApp AppDelegate.didFinishLaunching", "CmuxNextSettings SettingsController.load",
                                      "CmuxNextApp SettingsController.load", "CmuxNextHome HomeService.start"})
        self.assertEqual(turns["CmuxNextApp AppDelegate.didFinishLaunching"]["count"], 2)
        self.assertEqual(turns["CmuxNextHome HomeService.start"]["count"], 3)
        self.assertEqual(turns["CmuxNextHome HomeService.start"]["at_ms"], [50.0, 50.0, 50.0])
        self.assertEqual(by_kind["static_init"]["CmuxNextApp one-time initialization function for catalog"]["p50_ms"], 1.5)

    def test_startup_trace_turn_slices_win_over_cpu_runs(self):
        events = launch_trace(10) + [{"ph": "X", "pid": 10, "tid": 7, "ts": 80_000, "dur": 9_000,
                                      "cat": "startup.main_turn", "name": "turn", "args": {"site": "Restore.apply"}}]
        _, turns, _ = sq.profile_run(events, "first_window_frame_committed", "startup_complete")
        self.assertEqual([t["site"] for t in turns], ["Restore.apply"])

    def test_a_trace_without_the_marks_is_left_out(self):
        files = Files()
        bad = files.json("t.json", {"traceEvents": [e for e in launch_trace(10) if e.get("name") != "startup_complete"]})
        good = files.json("g.json.gz", {"traceEvents": launch_trace(10)}, compress=True)
        code, stdout, err = run_cli(["profile", bad, good])
        self.assertEqual(code, 0)
        self.assertIn("startup_complete not in the trace", err)
        self.assertIn("over 1 runs", stdout)

    def test_no_usable_trace_is_an_error(self):
        files = Files()
        bad = files.json("t.json", {"traceEvents": []})
        self.assertEqual(run_cli(["profile", bad])[0], 2)


class MainJobsTests(unittest.TestCase):
    def test_enqueuers_by_median_and_unscheduled_turns(self):
        jobs = [{"caller": "Home.start", "kind": "main_actor", "run_ms": 0.6, "enqueued_ms": 50},
                {"caller": "Home.start", "kind": "main_actor", "run_ms": 0.6, "enqueued_ms": 60},
                {"caller": "Late.job", "kind": "main_actor", "run_ms": 9, "enqueued_ms": 300}]
        jobs += [{"caller": "Chatty.tick", "kind": "run_loop_timer", "run_ms": 0.01, "enqueued_ms": i} for i in range(6)]
        turns = [{"start_ms": 400, "duration_ms": 3, "task": None, "allowlisted": False, "site": "Sidebar.reload"},
                 {"start_ms": 410, "duration_ms": 3, "task": "restore", "allowlisted": False, "site": "Restore.apply"},
                 {"start_ms": 420, "duration_ms": 3, "task": None, "allowlisted": True, "site": "Theme.apply"},
                 {"start_ms": 950, "duration_ms": 3, "task": None, "allowlisted": False, "site": "After.complete"}]
        runs = sq.capture_runs([census_run(main_jobs=jobs, main_turns=turns),
                                census_run(main_jobs=jobs[:2], main_turns=turns[:1]),
                                census_run(main_jobs=[], main_turns=[])])
        hits, _, used = sq.mainjobs_hits(runs, "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual(used, 3)
        found = {(h["kind"], h["caller"]): h for h in hits}
        self.assertEqual(set(found), {("main_actor", "Home.start"), ("unscheduled_turn", "Sidebar.reload")})
        self.assertEqual(found[("main_actor", "Home.start")]["p50_ms"], 1.2)
        self.assertEqual(found[("unscheduled_turn", "Sidebar.reload")]["runs"], 2)

    def test_a_control_reply_is_read(self):
        reply = {"ok": True, "result": census_run(main_jobs=[{"caller": "X.y", "kind": "main_queue", "run_ms": 2,
                                                              "enqueued_ms": 10}])}
        hits, _, used = sq.mainjobs_hits(sq.capture_runs(reply), "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual((used, [h["caller"] for h in hits]), (1, ["X.y"]))

    def test_runs_without_milestones_are_left_out(self):
        files = Files()
        path = files.json("s.json", {"result": {"milestones": {}, "main_jobs": []}})
        code, _, err = run_cli(["mainjobs", path])
        self.assertEqual(code, 2)
        self.assertIn("no first_window_frame_committed, startup_complete mark", err)


class GlobalJobsTests(unittest.TestCase):
    def test_non_lane_low_priority_callers_before_completion(self):
        jobs = [{"caller": "Feed.refresh", "priority": "utility", "lane": None, "enqueued_ms": 100, "run_ms": 4},
                {"caller": "Feed.refresh", "priority": 17, "lane": None, "enqueued_ms": 120, "run_ms": 4},
                {"caller": "Scan.all", "priority": None, "enqueued_ms": 300, "run_ms": 1},
                {"caller": "Lane.job", "priority": "background", "lane": "files", "enqueued_ms": 10, "run_ms": 1},
                {"caller": "Urgent.read", "priority": "userInitiated", "lane": None, "enqueued_ms": 10, "run_ms": 1},
                {"caller": "Later.job", "priority": "background", "lane": None, "enqueued_ms": 950, "run_ms": 1}]
        runs = sq.capture_runs([census_run(global_jobs=jobs), census_run(global_jobs=jobs[2:3])])
        hits, _, used = sq.globaljobs_hits(runs, "startup_complete")
        self.assertEqual(used, 2)
        self.assertEqual([(h["caller"], h["runs"], h["count"], h["priorities"]) for h in hits],
                         [("Scan.all", 2, 2, ["unspecified"]), ("Feed.refresh", 1, 2, ["utility"])])


class ArmsTests(unittest.TestCase):
    def test_arms_before_completion_with_first_fire(self):
        arms = [{"kind": "timer", "owner": "LaunchSettle", "site": "LaunchSettle.swift:20", "armed_ms": 150,
                 "first_fire_ms": 1150},
                {"kind": "watcher", "owner": "FolderWatch", "site": "Themes.swift:9", "armed_ms": 300,
                 "first_fire_ms": None},
                {"kind": "observer", "owner": "NSWorkspace", "site": "Apps.swift:4", "armed_ms": 1200}]
        files = Files()
        path = files.json("raw.json", {"runs": [{"marks": {}, "result": census_run(arms=arms)},
                                                {"marks": {}, "result": census_run(arms=arms[:1])}]})
        out = os.path.join(files.folder, "o.json")
        self.assertEqual(run_cli(["arms", path, "--json", out])[0], 0)
        doc = read_doc(out)
        self.assertEqual((doc["queue"], doc["template"]), ("Q13", "086"))
        self.assertEqual([(h["owner"], h["runs"], h["p50_first_fire_ms"]) for h in doc["hits"]],
                         [("LaunchSettle", 2, 1150.0), ("FolderWatch", 1, None)])


class FleetGuardTests(unittest.TestCase):
    def test_a_mac_without_a_fleet_step_is_refused_before_anything_starts(self):
        refusal = sq.fleet_refusal({"HOME": "/Users/someone"}, "Darwin")
        self.assertIn("never on a person's Mac", refusal)
        code, _, err = run_cli(["blocking", "--app", "/x/cmux DEV t.app"], env={}, system="Darwin")
        self.assertEqual(code, 2)
        self.assertIn("never on a person's Mac", err)

    def test_fleet_markers_pass(self):
        for env in (FLEET, {"NX_ARTIFACTS": "/tmp/a"}, {"GITHUB_ACTIONS": "true"}):
            self.assertIsNone(sq.fleet_refusal(env, "Darwin"), env)

    def test_linux_never_launches(self):
        self.assertIn("Linux", sq.fleet_refusal(FLEET, "Linux"))

    def test_inputs_and_app_are_exclusive(self):
        self.assertEqual(run_cli(["arms"])[0], 2)
        self.assertEqual(run_cli(["arms", "x.json", "--app", "/x/cmux DEV t.app"])[0], 2)


class FakeLaunch:
    launched = []

    def __init__(self, tag, scratch, extra_env=None):
        self.marks = {"first_window_frame_committed": 210.0, "startup_complete": 800.0}
        FakeLaunch.launched.append(tag)

    def wait_for(self, mark, timeout, any_of=False):
        return mark in self.marks if isinstance(mark, str) else True

    def quit(self):
        pass


class FakeClient:
    def __init__(self, reply):
        self.reply = reply

    def call(self, method):
        return self.reply(method)

    def close(self):
        pass


class FakeBench:
    FINAL_MARK = "first_terminal_frame"

    def __init__(self, reply, daemon=True):
        self.APPS, self.stopped, self.reply, self.daemon = {}, [], reply, daemon
        self.Launch = FakeLaunch
        FakeLaunch.launched = []

    def app_tag(self, path):
        return "t1"

    def app_pids(self, tag):
        return []

    def tag_pids(self, tag):
        return [11] if self.daemon else []

    def stop(self, pids):
        self.stopped.append(list(pids))

    def app_client(self, tag):
        return FakeClient(self.reply)


class CollectTests(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stderr(io.StringIO())  # the per-run progress lines
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def test_each_run_is_read_at_the_mark_and_the_tag_is_stopped(self):
        bench = FakeBench(lambda method: {"ok": True, "result": {"method": method, "sites": []}})
        runs = sq.collect(bench, "/x/cmux DEV t1.app", 3, "warm", "startup_complete", 5, "debug.blocking")
        self.assertEqual([r["result"]["method"] for r in runs], ["debug.blocking"] * 3)
        self.assertEqual(runs[0]["marks"]["startup_complete"], 800.0)
        self.assertEqual(FakeLaunch.launched, ["t1"] * 3, "a running daemon needs no priming launch")
        self.assertEqual(bench.stopped[-1], [11])
        hits, _, used = sq.blocking_hits(runs, "startup_complete")
        self.assertEqual((hits, used), ([], 3))

    def test_cold_stops_the_daemon_and_purges_every_run(self):
        purges = []
        bench = FakeBench(lambda method: {"result": {}})
        sq.collect(bench, "/x/cmux DEV t1.app", 2, "cold", "startup_complete", 5, "debug.startup",
                   purge_cache=lambda: purges.append(1))
        self.assertEqual(len(purges), 2)
        self.assertEqual(bench.stopped[:1], [[11]])

    def test_warm_primes_when_no_daemon_runs(self):
        bench = FakeBench(lambda method: {"result": {}}, daemon=False)
        sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "startup_complete", 5, "debug.startup")
        self.assertEqual(len(FakeLaunch.launched), 2, "one priming launch, one measured launch")

    def test_a_build_without_the_method_names_the_build_it_needs(self):
        bench = FakeBench(lambda method: {"ok": False, "error": {"code": "method_not_found"}})
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "startup_complete", 5, "debug.startup")
        self.assertIn("CMUX_BENCH_HOOKS", err.getvalue())

    def test_a_missing_mark_names_until_mark(self):
        bench = FakeBench(lambda method: {"result": {}})
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "first_live_content_frame", 5, "debug.startup")
        self.assertIn("--until-mark", err.getvalue())


if __name__ == "__main__":
    unittest.main()
