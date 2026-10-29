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
import re
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
            "result": {"compiled_in": True, "mode": "record", "overflow": overflow, "sites": sites}}


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

    def test_a_site_without_first_ms_is_counted_and_warned(self):
        hits, warnings, _ = sq.blocking_hits([blocking_run(900, [{"kind": "fileRead", "location": "A.swift:1",
                                                                  "count": 1}])], "startup_complete")
        self.assertEqual([(h["location"], h["first_ms_known"]) for h in hits], [("A.swift:1", False)])
        self.assertIn("launch window is not proved", warnings[-1])
        files = Files()
        out = os.path.join(files.folder, "o.json")
        run_cli(["blocking", files.json("r.json", [blocking_run(900, [{"kind": "k", "location": "L", "count": 1}])]),
                 "--json", out])
        self.assertTrue(any("not proved" in w for w in read_doc(out)["warnings"]))

    def test_a_run_without_the_until_mark_is_left_out(self):
        late = {"result": {"compiled_in": True,
                           "sites": [{"kind": "fileRead", "location": "Late.swift:1", "count": 1, "first_ms": 9999}]}}
        hits, warnings, used = sq.blocking_hits(sq.capture_runs([late]), "startup_complete")
        self.assertEqual((hits, used), ([], 0))
        self.assertIn("no startup_complete mark", warnings[0])
        files = Files()
        self.assertEqual(run_cli(["blocking", files.json("r.json", late), "--check"])[0], 2)

    def test_overflow_is_a_warning(self):
        _, warnings, _ = sq.blocking_hits([blocking_run(900, [], overflow=4)], "startup_complete")
        self.assertIn("4 sites past", warnings[0])

    def test_only_main_thread_sites_are_hits(self):
        # One line reached on the main thread and on the pool is two debug.blocking sites; only the main one is
        # a main-thread blocking hit, with its own count.
        run = blocking_run(900, [{"context": "main", "kind": "fileIO", "location": "A.swift:1", "count": 2},
                                 {"context": "pool", "kind": "fileIO", "location": "A.swift:1", "count": 7},
                                 {"context": "pool", "kind": "syncWait", "location": "P.swift:9", "count": 1}])
        hits, _, used = sq.blocking_hits([run], "startup_complete")
        self.assertEqual(used, 1)
        self.assertEqual([(h["location"], h["count"]) for h in hits], [("A.swift:1", 2)])

    def test_pool_overflow_is_not_a_main_thread_warning(self):
        run = blocking_run(900, [], overflow=3)
        run["result"]["contexts"] = {"main": {"sites": 0, "count": 0, "overflow": 0},
                                     "pool": {"sites": 0, "count": 0, "overflow": 3}}
        _, warnings, _ = sq.blocking_hits([run], "startup_complete")
        self.assertFalse(any("past the detector" in w for w in warnings))
        run["result"]["contexts"]["main"]["overflow"] = 2
        _, warnings, _ = sq.blocking_hits([run], "startup_complete")
        self.assertIn("2 sites past", warnings[0])

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
        raw = files.json("raw.json", [{"marks": {"startup_complete": 1}, "result": {"compiled_in": True, "sites": []}}])
        self.assertEqual(run_cli(["blocking", raw, "--check"])[0], 0)

    def test_a_report_from_a_build_without_the_detector_is_refused_not_clean(self):
        # A `--config bench` app answers debug.blocking with no detector, so its empty
        # sites are no evidence; only `compiled_in: true` (Debug, `--config bench-checks`) counts.
        files = Files()
        for result in ({"compiled_in": False, "mode": "record", "overflow": 0, "sites": []},
                       {"mode": "record", "overflow": 0, "sites": []}):
            run = {"marks": {"startup_complete": 1}, "result": result}
            hits, warnings, used = sq.blocking_hits([run], "startup_complete")
            self.assertEqual((hits, used), ([], 0), result)
            self.assertIn("--config bench-checks", warnings[0])
            code, _, err = run_cli(["blocking", files.json("nodetector.json", [run]), "--check"])
            self.assertEqual(code, 2, "no usable run: refused, never a pass")
            self.assertIn("no blocking detector", err)


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

    def test_a_mark_in_some_runs_only_does_not_hide_the_others_gap(self):
        runs = [{"a": 0, "c": 100}] * 4 + [{"a": 0, "b": 2, "c": 3}]
        hits = sq.mark_gaps(runs, 5.0, "t warm")
        self.assertEqual([(h["from"], h["to"], h["p50_ms"], h["n"]) for h in hits], [("a", "c", 100.0, 4)])

    def test_value_marks_are_not_times(self):
        runs = [{"main_start": 10, "first_window_frame_committed": 200, "launch.pageins_first_frame": 4100,
                 "launch.pageins_run_loop_start": 3800, "launch.main_cpu_ms": 56.5, "launch.temperature": "warm", "launch.interrupted": None}] * 3
        hits = sq.mark_gaps(runs, 5.0, "t warm")
        self.assertEqual([(h["from"], h["to"], h["p50_ms"]) for h in hits],
                         [("main_start", "first_window_frame_committed", 190.0)])

    def test_every_value_the_app_sends_is_a_value_mark(self):
        """The value names the app sends (task 007's StartupCounterReader `*Name` constants, and the run loop's
        page-ins of LaunchSlices) are VALUE_MARKS here and in bench-startup.py, so no count or CPU time lands on a
        launch timeline as a time."""
        sources = HERE.parent.parent / "Packages/macOS/CmuxNext/Sources"
        counters = (sources / "CmuxNextLaunch/StartupCounterReader.swift").read_text()
        slices = (sources / "CmuxNextSignposts/LaunchSlices+Mark.swift").read_text()
        sent = set(re.findall(r'public static let \w+Name = "(launch\.[a-z_.]+)"', counters))
        sent |= set(re.findall(r'public static let pageinsValueMark = "(launch\.[a-z_.]+)"', slices))
        self.assertEqual(sent, {"launch.pageins_run_loop_start", "launch.pageins_first_frame", "launch.main_cpu_ms"})
        spec = importlib.util.spec_from_file_location("bench_startup", HERE / "bench-startup.py")
        bench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bench)
        self.assertLessEqual(sent, sq.VALUE_MARKS)
        self.assertLessEqual(sent, set(bench.VALUE_MARKS))

    def test_bad_input_is_an_input_error_not_a_hit(self):
        files = Files()
        for data in ({"t": "oops"}, {"t": {"warm": "x"}}, {"t": {"warm": [1, 2]}}, [1]):
            code, _, err = run_cli(["gaps", files.json("bad.json", data), "--check"])
            self.assertEqual(code, 2, data)
            self.assertIn("bench-startup", err)

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
                                                              "enqueued_ms": 10}], main_turns=[])}
        hits, _, used = sq.mainjobs_hits(sq.capture_runs(reply), "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual((used, [h["caller"] for h in hits]), (1, ["X.y"]))

    def test_unscheduled_turns_report_a_median_and_rank_apart_from_jobs(self):
        turns = [{"start_ms": 300 + i, "duration_ms": ms, "task": None, "allowlisted": False, "site": "Sidebar.reload"}
                 for i, ms in enumerate((1, 2, 30))]
        job = [{"caller": "Home.start", "kind": "main_actor", "run_ms": 2, "enqueued_ms": 50}]
        hits, _, _ = sq.mainjobs_hits(sq.capture_runs([census_run(main_jobs=job, main_turns=turns)]),
                                      "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual([h["kind"] for h in hits], ["main_actor", "unscheduled_turn"])
        turn = hits[1]
        self.assertEqual((turn["count"], turn["p50_ms"], turn["max_ms"]), (3, 2.0, 30.0), "a median, not the 11 ms mean")

    def test_runs_without_milestones_are_left_out(self):
        files = Files()
        path = files.json("s.json", {"result": {"milestones": {}, "main_jobs": []}})
        code, _, err = run_cli(["mainjobs", path])
        self.assertEqual(code, 2)
        self.assertIn("no first_window_frame_committed, startup_complete mark", err)


    def test_a_census_not_armed_or_without_its_hook_is_left_out(self):
        job = [{"caller": "Home.start", "kind": "main_actor", "run_ms": 2, "enqueued_ms": 50}]
        runs = sq.capture_runs([
            census_run(main_job_census={"armed": False}),
            census_run(main_job_census={"armed": True, "hook": "missing"}, main_jobs=[], main_turns=[]),
            census_run(main_job_census={"armed": True, "hook": "installed"}, main_jobs=job, main_turns=[])])
        hits, warnings, used = sq.mainjobs_hits(runs, "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual((used, [h["caller"] for h in hits]), (1, ["Home.start"]))
        self.assertIn("run 1: the main-job census was not armed (CMUX_NEXT_MAIN_JOB_CENSUS=1), left out", warnings)
        self.assertIn("run 2: main-actor job hook missing, left out", warnings)

    def test_a_full_census_ring_is_a_warning_not_a_refusal(self):
        state = {"armed": True, "hook": "installed", "dropped_jobs": 12, "dropped_turns": 0}
        runs = sq.capture_runs([census_run(main_job_census=state, main_jobs=[], main_turns=[])])
        _, warnings, used = sq.mainjobs_hits(runs, "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual(used, 1)
        self.assertEqual(warnings, ["run 1: the census ring was full: 12 jobs not recorded"])

    def test_the_census_kinds_rank_as_enqueuers(self):
        jobs = [{"caller": "LaunchWarmup.start()", "kind": "main_delivery", "priority": "utility", "run_ms": 1.5,
                 "enqueued_ms": 40},
                {"caller": "run_loop.wake", "kind": "run_loop_wake", "priority": None, "run_ms": 3, "enqueued_ms": 80}]
        turns = [{"start_ms": 300, "duration_ms": 4, "task": None, "allowlisted": True, "site": "outside_run_loop",
                  "jobs": 0, "job_ms": 0}]
        runs = sq.capture_runs([census_run(main_job_census={"armed": True, "hook": "installed"}, main_jobs=jobs,
                                           main_turns=turns)])
        hits, _, _ = sq.mainjobs_hits(runs, "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual([(h["kind"], h["caller"]) for h in hits],
                         [("run_loop_wake", "run_loop.wake"), ("main_delivery", "LaunchWarmup.start()")])

    def test_run_loop_block_posts_and_timer_fires_rank_by_their_enqueuer(self):
        jobs = [{"caller": "Sidebar.reload()", "kind": "run_loop_block", "priority": "userInteractive", "run_ms": 0.1,
                 "enqueued_ms": 10 + i} for i in range(5)]
        jobs += [{"caller": "timer Feed.poll", "kind": "timer", "priority": "default", "run_ms": 2.5, "enqueued_ms": 90},
                 {"caller": "timer Feed.poll", "kind": "main_actor", "priority": "default", "run_ms": 0.2, "enqueued_ms": 91}]
        runs = sq.capture_runs([census_run(main_job_census={"armed": True, "hook": "installed"}, main_jobs=jobs,
                                           main_turns=[])])
        hits, _, _ = sq.mainjobs_hits(runs, "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual([(h["kind"], h["caller"], h["p50_count"]) for h in hits],
                         [("timer", "timer Feed.poll", 1), ("run_loop_block", "Sidebar.reload()", 5)])


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

    def test_no_priority_detached_tasks_and_global_queues_are_counted(self):
        # A Task.detached with no priority runs at .medium (21); DispatchQueue.global() at QoS default.
        jobs = [{"caller": "Index.detached", "priority": 21, "lane": None, "enqueued_ms": 100, "run_ms": 1},
                {"caller": "Cache.global", "priority": "default", "lane": None, "enqueued_ms": 110, "run_ms": 1},
                {"caller": "Model.medium", "priority": "medium", "lane": None, "enqueued_ms": 120, "run_ms": 1}]
        hits, _, _ = sq.globaljobs_hits(sq.capture_runs([census_run(global_jobs=jobs)]), "startup_complete")
        self.assertEqual({(h["caller"], tuple(h["priorities"])) for h in hits},
                         {("Index.detached", ("default",)), ("Cache.global", ("default",)), ("Model.medium", ("default",))})

    def test_the_census_reply_is_read_as_the_app_sends_it(self):
        # debug.startup.global_jobs (task 082): raw TaskPriority numbers, 0 for none, no lane, run_ms null (the hook
        # sees the enqueue).
        jobs = [{"caller": "Feed.refresh()", "via": None, "priority": 17, "origin": "off_main", "enqueued_ms": 40.5,
                 "run_ms": None},
                {"caller": "Scan.all()", "via": None, "priority": 0, "origin": "main", "enqueued_ms": 42, "run_ms": None},
                {"caller": "Open.page()", "via": None, "priority": 25, "origin": "main", "enqueued_ms": 43, "run_ms": None}]
        state = {"armed": True, "hook": "installed", "frozen": True, "tasks": 3, "pending_tasks": 0, "dropped_tasks": 0,
                 "resumptions": 12, "actor_jobs": 3, "untracked_tasks": 0}
        hits, warnings, used = sq.globaljobs_hits(
            sq.capture_runs([census_run(global_jobs=jobs, global_job_census=state)]), "startup_complete")
        self.assertEqual((used, warnings), (1, []))
        self.assertEqual([(h["caller"], h["priorities"], h["via"], h["total_ms"]) for h in hits],
                         [("Feed.refresh()", ["utility"], [], 0.0), ("Scan.all()", ["unspecified"], [], 0.0)])

    def test_a_background_work_task_before_completion_is_a_hit(self):
        # BackgroundWork.task starts its Task.detached at once: the launch fence holds only lane items, so a
        # work.task(.bestEffort) or work.task(.idle) during launch is Q12 work, named by its caller.
        jobs = [{"caller": "Index.rebuild()", "via": "background_work_task", "priority": 9, "origin": "main",
                 "enqueued_ms": 41, "run_ms": None},
                {"caller": "Feed.prefetch()", "via": "background_work_task", "priority": 17, "origin": "off_main",
                 "enqueued_ms": 44, "run_ms": None},
                {"caller": "Late.sweep()", "via": "background_work_task", "priority": 9, "origin": "main",
                 "enqueued_ms": 950, "run_ms": None},
                {"caller": "Lane.job", "lane": "files", "priority": 9, "enqueued_ms": 10, "run_ms": 1}]
        state = {"armed": True, "hook": "installed", "tasks": 3}
        hits, _, _ = sq.globaljobs_hits(
            sq.capture_runs([census_run(global_jobs=jobs, global_job_census=state)]), "startup_complete")
        self.assertEqual([(h["caller"], h["priorities"], h["via"]) for h in hits],
                         [("Feed.prefetch()", ["utility"], ["background_work_task"]),
                          ("Index.rebuild()", ["background"], ["background_work_task"])])
        self.assertIn("(via background_work_task)", hits[1]["summary"])

    def test_a_census_that_did_not_record_is_left_out(self):
        runs = sq.capture_runs([census_run(global_jobs=[], global_job_census={"armed": False}),
                                census_run(global_jobs=[], global_job_census={"armed": True, "hook": "busy"}),
                                census_run(global_jobs=[], global_job_census={"armed": True, "hook": "installed",
                                                                              "dropped_tasks": 7, "untracked_tasks": 0})])
        _, warnings, used = sq.globaljobs_hits(runs, "startup_complete")
        self.assertEqual(used, 1)
        self.assertIn("run 1: the global-job census was not armed", warnings[0])
        self.assertIn("run 2: global-enqueue hook busy", warnings[1])
        self.assertIn("run 3: the census did not keep 7 tasks past the ring", warnings[2])
        self.assertEqual(len(warnings), 3)


class CensusFieldTests(unittest.TestCase):
    """A debug.startup result from a build without the census (008 without 080/082/085) is not a clean launch."""

    MILESTONES_ONLY = {"milestones": {"first_window_frame_committed": 100, "startup_complete": 300}}

    def test_each_census_mode_refuses_a_result_without_its_arrays(self):
        files = Files()
        path = files.json("s.json", self.MILESTONES_ONLY)
        for mode, field in (("mainjobs", "main_jobs"), ("globaljobs", "global_jobs"), ("arms", "arms")):
            code, _, err = run_cli([mode, path, "--check"])
            self.assertEqual(code, 2, mode)
            self.assertIn(f"no {field}", err)

    def test_a_run_without_the_arrays_is_left_out_with_a_warning(self):
        runs = sq.capture_runs([census_run(main_jobs=[]), census_run(main_jobs=[], main_turns=[])])
        _, warnings, used = sq.mainjobs_hits(runs, "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual(used, 1)
        self.assertIn("run 1: no main_turns", warnings[0])

    def test_interrupted_is_read_by_presence(self):
        runs = sq.capture_runs([{"marks": {"launch.interrupted": 0}, "result": census_run(arms=[])},
                                census_run(arms=[], interrupted=1),
                                {"marks": {"launch.interrupted": False}, "result": census_run(arms=[])}])
        _, warnings, used = sq.arms_hits(runs, "startup_complete")
        self.assertEqual(used, 1)
        self.assertEqual(sum("interrupted" in w for w in warnings), 2)


class CaptureModeTests(unittest.TestCase):
    def test_a_saved_capture_of_the_other_method_is_refused(self):
        files = Files()
        startup = files.json("startup.json", {"mode": "mainjobs", "runs": [{"marks": {}, "result": census_run(
            main_jobs=[], main_turns=[])}]})
        blocking = files.json("blocking.json", {"mode": "blocking", "runs": [{"marks": {}, "result": census_run(
            main_jobs=[], main_turns=[], arms=[])}]})
        for mode, path in (("blocking", startup), ("mainjobs", blocking), ("arms", blocking)):
            code, _, err = run_cli([mode, path, "--check"])
            self.assertEqual(code, 2, mode)
            self.assertIn("capture", err)
        self.assertEqual(run_cli(["arms", startup])[0], 2, "no arms array: a mainjobs capture has none")
        self.assertEqual(run_cli(["mainjobs", startup])[0], 0, "same method family")

    def test_a_result_without_sites_is_not_a_blocking_result(self):
        files = Files()
        path = files.json("s.json", census_run(main_jobs=[], main_turns=[]))
        code, _, err = run_cli(["blocking", path, "--check"])
        self.assertEqual(code, 2)
        self.assertIn("no sites", err)


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

    def test_the_census_reply_is_read_as_the_app_sends_it(self):
        # debug.startup.arms (task 085): one record per armed object, `count` arms before its first fire, the first
        # fire also after completion, and the census summary.
        arms = [{"kind": "timer", "owner": "ChromiumWarmup", "site": "CmuxNextChromiumWarmup/ChromiumWarmup.swift:88",
                 "armed_ms": 412.3, "count": 3, "first_fire_ms": 3420.1},
                {"kind": "main_deadline", "owner": "Sidebar.hover", "site": "CmuxNextSidebar/Hover.swift:12",
                 "armed_ms": 650, "count": 1, "first_fire_ms": None},
                {"kind": "watcher", "owner": "FolderChanges", "site": "CmuxNextDesign/BackdropCatalogStore.swift:67",
                 "armed_ms": 701.5, "count": 1, "first_fire_ms": None},
                {"kind": "timer", "owner": "Late.timer", "site": "Late.swift:4", "armed_ms": 950, "count": 1,
                 "first_fire_ms": 960}]
        state = {"armed": True, "closed": True, "dropped": 0, "capacity": 4096}
        hits, warnings, used = sq.arms_hits(sq.capture_runs([census_run(arms=arms, arm_census=state)]),
                                            "startup_complete")
        self.assertEqual((used, warnings), (1, []))
        self.assertEqual([(h["kind"], h["owner"], h["p50_first_fire_ms"], h["fired"], h["p50_arms_before_fire"])
                          for h in hits],
                         [("timer", "ChromiumWarmup", 3420.1, 1, 3), ("main_deadline", "Sidebar.hover", None, 0, 1),
                          ("watcher", "FolderChanges", None, 0, 1)])
        self.assertIn("3 arms before it", hits[0]["summary"])

    def test_a_census_that_did_not_record_is_left_out(self):
        runs = sq.capture_runs([census_run(arms=[], arm_census={"armed": False, "closed": False, "dropped": 0}),
                                census_run(arms=[], arm_census={"armed": True, "closed": True, "dropped": 12}),
                                census_run(arms=[])])
        _, warnings, used = sq.arms_hits(runs, "startup_complete")
        self.assertEqual(used, 2, "a full census still counts; a result with no summary is kept")
        self.assertIn("run 1: the arm census was not armed", warnings[0])
        self.assertIn("run 2: the census did not keep 12 arms past its capacity", warnings[1])
        self.assertEqual(len(warnings), 2)


class FleetGuardTests(unittest.TestCase):
    def test_a_mac_without_a_fleet_step_is_refused_before_anything_starts(self):
        refusal = sq.fleet_refusal({"HOME": "/Users/someone"}, "Darwin")
        self.assertIn("never on a person's Mac", refusal)
        code, _, err = run_cli(["blocking", "--app", "/x/cmux DEV t.app"], env={}, system="Darwin")
        self.assertEqual(code, 2)
        self.assertIn("never on a person's Mac", err)

    def test_fleet_markers_pass(self):
        for env in (FLEET, {"NX_JOB_ID": "job-1"}, {"GITHUB_ACTIONS": "true"}):
            self.assertIsNone(sq.fleet_refusal(env, "Darwin"), env)

    def test_an_artifacts_folder_alone_is_not_a_fleet_marker(self):
        for env in ({"NX_ARTIFACTS": "/tmp/a"}, {"GITHUB_ACTIONS": "false"}):
            self.assertIn("never on a person's Mac", sq.fleet_refusal(env, "Darwin"), env)

    def test_linux_never_launches(self):
        self.assertIn("Linux", sq.fleet_refusal(FLEET, "Linux"))

    def test_inputs_and_app_are_exclusive(self):
        self.assertEqual(run_cli(["arms"])[0], 2)
        self.assertEqual(run_cli(["arms", "x.json", "--app", "/x/cmux DEV t.app"])[0], 2)


class FakeLaunch:
    """One app process; the first launch with no daemon running starts one (a new tag pid)."""

    def __init__(self, bench, tag, scratch, extra_env=None):
        self.marks = {"first_window_frame_committed": 210.0, "startup_complete": 800.0}
        bench.launched.append((tag, scratch, dict(extra_env or {})))
        if not bench.pids:
            bench.pids.append(100 + len(bench.launched))

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
        self.APPS, self.stopped, self.reply, self.launched = {}, [], reply, []
        self.pids = [11] if daemon else []  # 11: a daemon that ran before the tool

    def Launch(self, tag, scratch, extra_env=None):  # noqa: N802 (bench-startup's class name)
        return FakeLaunch(self, tag, scratch, extra_env)

    def app_tag(self, path):
        return "t1"

    def app_pids(self, tag):
        return []

    def tag_pids(self, tag):
        return list(self.pids)

    def stop(self, pids):
        self.stopped.append(list(pids))
        self.pids = [pid for pid in self.pids if pid not in pids]

    def app_client(self, tag):
        return FakeClient(self.reply)


class CollectTests(unittest.TestCase):
    def setUp(self):
        quiet = contextlib.redirect_stderr(io.StringIO())  # the per-run progress lines
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)

    def test_each_run_is_read_at_the_mark_and_a_daemon_from_before_is_left_running(self):
        bench = FakeBench(lambda method: {"ok": True, "result": {"method": method, "compiled_in": True,
                                                                 "sites": []}})
        runs = sq.collect(bench, "/x/cmux DEV t1.app", 3, "warm", "startup_complete", 5, "debug.blocking")
        self.assertEqual([r["result"]["method"] for r in runs], ["debug.blocking"] * 3)
        self.assertEqual(runs[0]["marks"]["startup_complete"], 800.0)
        self.assertEqual([tag for tag, _, _ in bench.launched], ["t1"] * 3, "a running daemon needs no priming launch")
        self.assertEqual(bench.stopped, [[]], "the daemon that ran before the tool is not its to stop")
        self.assertEqual(bench.pids, [11])
        hits, _, used = sq.blocking_hits(runs, "startup_complete")
        self.assertEqual((hits, used), ([], 3))

    def test_a_live_report_without_the_detector_stops_at_the_first_launch(self):
        bench = FakeBench(lambda method: {"ok": True, "result": {"compiled_in": False, "mode": "record", "sites": []}})
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(sq.QueueError) as caught:
            sq.collect(bench, "/x/cmux DEV t1.app", 3, "warm", "startup_complete", 5, "debug.blocking")
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("--config bench-checks", err.getvalue())
        self.assertEqual(len(bench.launched), 1, "refused at the first launch, not after every run")

    def test_launches_are_activated_and_scratch_folders_removed(self):
        bench = FakeBench(lambda method: {"result": {}}, daemon=False)
        sq.collect(bench, "/x/cmux DEV t1.app", 2, "warm", "startup_complete", 5, "debug.startup")
        self.assertEqual({env.get("CMUX_NEXT_NO_ACTIVATE") for _, _, env in bench.launched}, {"0"},
                         "a noActivate launch is an interrupted launch (task 108)")
        scratches = {scratch for _, scratch, _ in bench.launched}
        self.assertEqual(len(scratches), 2)
        self.assertFalse(any(os.path.exists(scratch) for scratch in scratches))

    def test_cold_stops_the_daemon_and_purges_every_run(self):
        purges = []
        bench = FakeBench(lambda method: {"result": {}})
        sq.collect(bench, "/x/cmux DEV t1.app", 2, "cold", "startup_complete", 5, "debug.startup",
                   purge_cache=lambda: purges.append(1))
        self.assertEqual(len(purges), 2)
        self.assertEqual(bench.stopped[:1], [[11]])
        self.assertEqual(bench.pids, [], "the daemon the cold runs started is stopped at the end")

    def test_warm_primes_when_no_daemon_runs_and_stops_the_daemon_it_started(self):
        bench = FakeBench(lambda method: {"result": {}}, daemon=False)
        sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "startup_complete", 5, "debug.startup")
        self.assertEqual(len(bench.launched), 2, "one priming launch, one measured launch")
        self.assertEqual((bench.stopped, bench.pids), ([[101]], []))

    def test_a_build_without_the_method_names_the_build_it_needs(self):
        bench = FakeBench(lambda method: {"ok": False, "error": {"code": "method_not_found"}})
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "startup_complete", 5, "debug.startup")
        self.assertIn("CMUX_BENCH_HOOKS", err.getvalue())

    def test_mainjobs_arms_the_census_and_merges_its_method_into_debug_startup(self):
        census = {"main_job_census": {"armed": True, "hook": "installed"}, "main_jobs": [], "main_turns": []}

        def reply(method):
            if method == "debug.startup.main_jobs":
                return {"ok": True, "result": census}
            return {"ok": False, "error": {"code": "method_not_found"}}  # a build without task 008's method

        bench = FakeBench(reply)
        runs = sq.collect(bench, "/x/cmux DEV t1.app", 2, "warm", "startup_complete", 5, "debug.startup",
                          extra_method=sq.MODE_METHOD["mainjobs"], extra_env=sq.MODE_ENV["mainjobs"])
        self.assertEqual([r["result"] for r in runs], [census, census])
        self.assertEqual({(env.get("CMUX_NEXT_MAIN_JOB_CENSUS"), env.get("CMUX_NEXT_NO_ACTIVATE"))
                          for _, _, env in bench.launched}, {("1", "0")})
        hits, _, used = sq.mainjobs_hits(runs, "first_window_frame_committed", "startup_complete", 1.0, 5)
        self.assertEqual((hits, used), ([], 2))

    def test_the_census_method_is_required(self):
        bench = FakeBench(lambda method: {"ok": False, "error": {"code": "method_not_found"}})
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "startup_complete", 5, "debug.startup",
                       extra_method="debug.startup.main_jobs")
        self.assertIn("debug.startup.main_jobs", err.getvalue())

    def test_a_census_mode_arms_its_recorder_and_merges_its_method(self):
        # A build without debug.startup (task 008) still answers the census's own method.
        replies = {"debug.startup": {"ok": False, "error": {"code": "method_not_found"}},
                   "debug.startup.global_jobs": {"ok": True, "result": {"global_jobs": [], "global_job_census": {
                       "armed": True, "hook": "installed"}}}}
        bench = FakeBench(lambda method: replies[method], daemon=False)
        runs = sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "startup_complete", 5, sq.method_of("globaljobs"),
                          extra_method=sq.MODE_METHOD["globaljobs"], extra_env=sq.MODE_ENV["globaljobs"])
        self.assertEqual(runs[0]["result"], {"global_jobs": [], "global_job_census": {"armed": True, "hook": "installed"}})
        self.assertEqual({env.get("CMUX_NEXT_GLOBAL_JOB_CENSUS") for _, _, env in bench.launched}, {"1"},
                         "the priming launch and the measured one")
        self.assertEqual({env.get("CMUX_NEXT_NO_ACTIVATE") for _, _, env in bench.launched}, {"0"})

    def test_the_arms_mode_arms_its_census_and_merges_its_method(self):
        census = {"arms": [], "arm_census": {"armed": True, "closed": True, "dropped": 0, "capacity": 4096}}
        replies = {"debug.startup": {"ok": False, "error": {"code": "method_not_found"}},
                   "debug.startup.arms": {"ok": True, "result": census}}
        bench = FakeBench(lambda method: replies[method], daemon=False)
        runs = sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "startup_complete", 5, sq.method_of("arms"),
                          extra_method=sq.MODE_METHOD["arms"], extra_env=sq.MODE_ENV["arms"])
        self.assertEqual(runs[0]["result"], census)
        self.assertEqual({env.get("CMUX_NEXT_ARM_CENSUS") for _, _, env in bench.launched}, {"1"},
                         "the priming launch and the measured one")

    def test_a_settle_window_runs_between_the_mark_and_the_census_read(self):
        # The census writes first fires after completion: the read waits --settle-s past the mark, so a launch arm
        # that first fires by +10 s is not reported as never firing.
        events = []
        census = {"arms": [], "arm_census": {"armed": True, "closed": True, "dropped": 0, "capacity": 4096}}

        def reply(method):
            events.append(("query", method))
            return {"ok": True, "result": census} if method == "debug.startup.arms" else {"ok": False}

        bench = FakeBench(reply)
        sq.collect(bench, "/x/cmux DEV t1.app", 2, "warm", "startup_complete", 5, sq.method_of("arms"),
                   extra_method=sq.MODE_METHOD["arms"], extra_env=sq.MODE_ENV["arms"], settle_s=10.0,
                   sleep=lambda seconds: events.append(("settle", seconds)))
        self.assertEqual(events, [("settle", 10.0), ("query", "debug.startup"), ("query", "debug.startup.arms")] * 2)

    def test_arms_settles_ten_seconds_by_default_and_other_modes_do_not(self):
        self.assertEqual(sq.settle_seconds(sq.parse(["arms", "--app", "/x/cmux DEV t.app"])), 10.0)
        self.assertEqual(sq.settle_seconds(sq.parse(["arms", "--app", "/x/cmux DEV t.app", "--settle-s", "0"])), 0.0)
        self.assertEqual(sq.settle_seconds(sq.parse(["globaljobs", "--app", "/x/cmux DEV t.app"])), 0.0)
        self.assertEqual(sq.settle_seconds(sq.parse(["mainjobs", "--app", "/x/cmux DEV t.app", "--settle-s", "2.5"])), 2.5)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            sq.parse(["arms", "--app", "/x/cmux DEV t.app", "--settle-s", "-1"])

    def test_no_settle_reads_at_the_mark(self):
        slept = []
        bench = FakeBench(lambda method: {"ok": True, "result": {"compiled_in": True, "sites": []}})
        sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "startup_complete", 5, "debug.blocking",
                   sleep=slept.append)
        self.assertEqual(slept, [])

    def test_a_missing_mark_names_until_mark(self):
        bench = FakeBench(lambda method: {"result": {}})
        with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            sq.collect(bench, "/x/cmux DEV t1.app", 1, "warm", "first_live_content_frame", 5, "debug.startup")
        self.assertIn("--until-mark", err.getvalue())


if __name__ == "__main__":
    unittest.main()
