#!/usr/bin/env python3
"""The launch and relaunch journeys on perf_stats, BenchApp and result-v1 (p12-perf-process-064).

1. launch_journey_report: every percentile is perf_stats.pct (the soak's medians equal statistics.median); each
   journey's rows become the series its story declares, from finished runs only, with raw samples.
2. The relaunch seam: a real BenchApp starts a stand-in app, the journey relaunches it on the same tag (no fresh
   state, the tag teardown remembered), and launch-connect's launch-mark pipe reaches each launch through
   BenchApp(pass_fds) and is closed in this process after the spawn.
3. The series go through a real BenchApp.record and the real perf-lab ingest; every written metric fullmatches its
   story's patterns with the story's engine and session. A journey that did not finish writes no result-v1.
4. --story is refused before any launch for a story of another engine or session, a sanitizer soak, --long-top.
5. The four scripts leave the bench-migration queues (MQ1, MQ2, MQ3); each story's needs are the debug methods its
   script calls, and each story runs its script.

Linux and macOS; no app, no GUI session (the session read is injected, the control socket is patched):

    python3 -m unittest scripts/cmux-next/tests/test_launch_journey_results.py
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import plistlib
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = ROOT / "scripts/perf-lab"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_launch as bl  # noqa: E402
import launch_journey_report as journey  # noqa: E402
from test_bench_launch import FEATURES, HOST, OK_SESSION, record_bundle, result_lines  # noqa: E402

perf_stats = bl.load_by_path("perf_stats", str(PERF_LAB / "perf_stats.py"))
ingest = bl.load_by_path("perf_lab_ingest", str(PERF_LAB / "ingest.py"))
queues = bl.load_by_path("perf_lab_queues", str(PERF_LAB / "queues.py"))
connect = bl.load_by_path("launch_connect_journey", str(HERE / "launch-connect-journey.py"))
relaunch_e2e = bl.load_by_path("relaunch_e2e", str(HERE / "relaunch-e2e.py"))
soak = bl.load_by_path("readiness_soak_journey", str(HERE / "readiness-soak.py"))

SCRIPTS = ("launch-connect-journey.py", "relaunch-e2e.py", "downloads-relaunch-live.py", "readiness-soak.py")
STORIES = {"launch-connect-journey.py": "launch-connect", "relaunch-e2e.py": "relaunch-e2e",
           "readiness-soak.py": "readiness-soak"}
SHA = "e" * 40
VECTOR = [3.1, 4.7, 5.0, 5.2, 6.8, 7.4, 8.0, 9.9, 12.5, 30.2]


def story_file(story_id):
    return json.loads((PERF_LAB / "stories.d" / f"{story_id}.json").read_text())


class RecordingCase(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="launch-journey-")
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def bench(self, tag, session="light"):
        bench = bl.BenchApp(record_bundle(self.folder, tag, commit=SHA), out=self.out, teardown=False,
                            host=lambda: dict(HOST), perf_session=session)
        bench.features = FEATURES  # what launch() read
        return bench

    def by_metric(self):
        return {line["metric"]: line for line in result_lines(self.out)}

    def no_results(self):
        return not (os.path.isdir(self.out) and list(Path(self.out).glob("*.ndjson")))

    def ingest(self):
        """The out folder through the real perf-lab ingest: {story: (engine, session, {metric: samples})}."""
        db = ingest.store.Store(Path(self.folder) / "lab.sqlite3")
        db.migrate()
        try:
            got = ingest.ingest_paths(db, [self.out], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
            self.assertEqual([r.line() for r in got.rejected], [])
            runs = db._db.execute("SELECT run_uuid, engine, session FROM runs").fetchall()
            return {row["run_uuid"].split("/", 1)[1]: (row["engine"], row["session"], db.run_metrics(row["run_uuid"]))
                    for row in runs}
        finally:
            db.close()

    def assert_story_contract(self, story_id):
        """Every written line is `story_id`'s, fullmatches one of its patterns with that pattern's unit, and carries
        the story's engine and session."""
        story = story_file(story_id)
        lines = result_lines(self.out)
        self.assertTrue(lines)
        for line in lines:
            self.assertEqual(line["story"], story_id)
            units = [m["unit"] for m in story["metrics"] if re.fullmatch(m["name"], line["metric"])]
            self.assertEqual(units, [line["unit"]], f"{story_id} declares {line['metric']} once with its unit")
            self.assertEqual((line["engine"], line["session"]), (story["engine"], story["session"]), line["metric"])
            self.assertEqual(line["better"], "lower")


class StatisticsTests(unittest.TestCase):
    def test_percentiles_are_perf_stats(self):
        for q in (0.5, 0.95, 0.99):
            self.assertEqual(journey.percentile(VECTOR, q), perf_stats.pct(VECTOR, q))
        self.assertEqual(journey.percentile(VECTOR, 0.99, digits=1), round(perf_stats.pct(VECTOR, 0.99), 1))
        self.assertIsNone(journey.percentile([None, "x", True], 0.5))

    def test_the_fixed_vector_of_the_commit(self):
        # Old readiness-soak snapshot.get p50 s[n//2] and p99 s[int(0.99n)]; new perf_stats.pct (linear interpolation).
        ordered = sorted(VECTOR)
        self.assertEqual((ordered[len(ordered) // 2], ordered[int(len(ordered) * 0.99)]), (7.4, 30.2))
        self.assertEqual([round(perf_stats.pct(VECTOR, q), 3) for q in (0.5, 0.95, 0.99)], [7.1, 22.235, 28.607])

    def test_the_soaks_median_is_the_old_statistics_median(self):
        for values in (VECTOR, VECTOR[:7], [4.0], [2.0, 9.0]):
            self.assertEqual(journey.percentile(values, 0.5, digits=2), round(statistics.median(values), 2), values)


class BenchStandIn:
    """A real BenchApp on a stand-in app (a shell script that sends one launch mark to CMUX_NEXT_LAUNCH_MARKS_FD when
    it has one, makes the /tmp control socket file and sleeps); the control socket is patched."""

    def __init__(self, case):
        self.case = case
        self.tag = f"lj-{os.getpid()}"
        self.socket_file = f"/tmp/cmux-debug-{self.tag}.sock"
        # bash, not sh: dash (Linux /bin/sh) refuses `>&N` for a descriptor above 9, and the pipe may get one.
        script = ("#!/bin/bash\n"
                  'if [ -n "$CMUX_NEXT_LAUNCH_MARKS_FD" ]; then printf \'main_start 1.5\\n\' >&"$CMUX_NEXT_LAUNCH_MARKS_FD"; fi\n'
                  f": > '{self.socket_file}'\n"
                  "exec sleep 300\n")
        self.app = record_bundle(case.folder, self.tag, commit=SHA, main=script)
        self.made = []

    def __call__(self, app, **kwargs):
        bench = bl.BenchApp(app, teardown=False, session=lambda: OK_SESSION, host=lambda: dict(HOST), **kwargs)
        self.made.append(bench)
        return bench

    def rpc(self, path, method, params=None, timeout=60):
        if method == "debug.windows":
            return {"windows": [{"id": 1}]}
        if method == "features.list":
            return {"features": [], "features_hash": "fh", "safe_mode": "off"}
        if method == "debug.quit":
            for bench in self.made:
                if bench.process and bench.process.poll() is None:
                    bench.process.terminate()
            return {}
        return {"error": {"code": "method_not_found", "message": method}}

    def close(self):
        for bench in self.made:
            if bench.process and bench.process.poll() is None:
                bench.process.kill()
                bench.process.wait()
        with contextlib.suppress(FileNotFoundError):
            os.unlink(self.socket_file)


class RelaunchSeamTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="launch-journey-seam-")
        self.saved_env = dict(os.environ)
        os.environ.update(BENCH_LAUNCH_LIMITS="inherit", BENCH_LAUNCH_PMSET="/nonexistent/pmset",
                          BENCH_LAUNCH_LPM_MARKER=os.path.join(self.folder, "lpm.json"))
        self.stand_in = BenchStandIn(self)
        patcher = mock.patch.object(bl, "rpc_at", self.stand_in.rpc)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self.stand_in.close()
        os.environ.clear()
        os.environ.update(self.saved_env)
        shutil.rmtree(self.folder, ignore_errors=True)

    def end(self, bench):
        bench.process.terminate()
        bench.process.wait()

    def test_launch_connect_sends_each_launch_its_own_mark_pipe_and_relaunches_on_the_same_tag(self):
        args = types.SimpleNamespace(app=self.stand_in.app, out=os.path.join(self.folder, "out"), session="light",
                                     timeout=20)
        tag = connect.Tag(args, self.stand_in)
        self.assertEqual(tag.tag, self.stand_in.tag)
        with contextlib.redirect_stdout(io.StringIO()):
            first = connect.Launch(tag, args, first=True)
            self.assertTrue(first.wait_for("main_start", 10), "the first launch's mark came through the pipe")
            self.assertEqual(first.marks, {"main_start": 1.5})
            self.assertIsNotNone(first.started)
            self.assertEqual(tag.bench.pass_fds, (), "the pipe is passed only to the launch")
            self.assertNotIn("CMUX_NEXT_LAUNCH_MARKS_FD", tag.bench.extra_env)
            self.assertEqual(tag.bench.launched_env["CMUX_NEXT_NO_ACTIVATE"], "1", "the bench env")
            self.end(tag.bench)
            self.assertFalse(first.wait_for("__never__", 5), "the write end is closed here: EOF once the app ended")
            os.close(first.read_fd)
            second = connect.Launch(tag, args, first=False)
            self.assertTrue(second.wait_for("main_start", 10))
            self.assertFalse(tag.bench.fresh_state, "a relaunch keeps the tag's saved state")
            self.assertEqual(len(self.stand_in.made), 1, "one BenchApp for every launch of the journey")
            tag.bench.stop(quit_timeout=10)
            os.close(second.read_fd)

    def test_relaunch_refuses_a_running_app_and_remembers_each_launch(self):
        bench = self.stand_in(self.stand_in.app, out=os.path.join(self.folder, "out"))
        remembered = []
        bench.teardown = types.SimpleNamespace(remember=lambda: remembered.append(bench.process.pid),
                                               install=lambda: None, end=lambda: None, processes=lambda: [])
        with contextlib.redirect_stdout(io.StringIO()):
            bench.launch(timeout=20)
            with self.assertRaises(journey.StillRunning):
                journey.relaunch(bench, timeout=20)
            first_pid = bench.process.pid
            self.end(bench)
            journey.relaunch(bench, timeout=20, probe_first_answer=True)
            self.assertNotEqual(bench.process.pid, first_pid)
            self.assertEqual(remembered, [bench.process.pid])
            self.assertIsNotNone(bench.first_answer_ms)
            bench.stop(quit_timeout=10)


def connect_row(name, frame=120.0, usable=300.0, connecting=None):
    marks = {} if frame is None else {"first_window_frame_committed": frame}
    return {"launch": name, "marks": marks, "usable_ms": usable, "connecting_screen_ms": connecting}


class LaunchConnectTests(RecordingCase):
    def test_a_finished_journey_records_each_launch(self):
        rows = [connect_row("first"), connect_row("warm", 80.0, 150.0), connect_row("restart", 90.0, 900.0, 400.0)]
        tag = types.SimpleNamespace(bench=self.bench("lc"))
        written = connect.record(tag, "launch-connect", rows, ["first", "warm", "restart"], log=lambda _: None)
        self.assertTrue(journey.any_written(written))
        lines = self.by_metric()
        self.assertEqual(lines["launch_connect.restart.connecting_screen"]["samples"], [400.0])
        self.assertEqual(lines["launch_connect.warm.usable"]["samples"], [150.0])
        self.assertNotIn("launch_connect.first.connecting_screen", lines, "no connecting screen: no sample")
        self.assert_story_contract("launch-connect")
        self.assertEqual(sorted(self.ingest()), ["launch-connect"])

    def test_a_journey_that_did_not_finish_writes_nothing(self):
        tag = types.SimpleNamespace(bench=self.bench("lc2"))
        for rows in ([connect_row("first")], [connect_row("first"), connect_row("warm", usable=None)],
                     [connect_row("first", frame=None), connect_row("warm")]):
            with self.subTest(rows=rows):
                got = connect.record(tag, "launch-connect", rows, ["first", "warm"], log=lambda _: None)
                self.assertTrue(got.startswith("none: "), got)
        self.assertTrue(self.no_results())

    def test_story_needs_an_app_and_a_story_of_its_engine(self):
        for argv in (["--story", "launch-connect"], ["--app", "a.app", "--story", "typing"],
                     ["--app", "a.app", "--story", "nope"]):
            with self.subTest(argv=argv), mock.patch.dict(os.environ, {"NX_APP": ""}), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                connect.parse_args(argv)
            self.assertEqual(raised.exception.code, 2)
        self.assertEqual(connect.parse_args(["--app", "a.app", "--story", "launch-connect"]).story, "launch-connect")


class RelaunchE2ETests(RecordingCase):
    def setUp(self):
        super().setUp()
        self.saved = (relaunch_e2e.bench, list(relaunch_e2e.relaunches), list(relaunch_e2e.failures))

    def tearDown(self):
        relaunch_e2e.bench = self.saved[0]
        relaunch_e2e.relaunches[:] = self.saved[1]
        relaunch_e2e.failures[:] = self.saved[2]
        super().tearDown()

    def run_record(self, tag, relaunches, failures, finished=True):
        relaunch_e2e.bench = self.bench(tag)
        relaunch_e2e.relaunches[:] = relaunches
        relaunch_e2e.failures[:] = failures
        return relaunch_e2e.record("relaunch-e2e", finished, log=lambda _: None)

    def test_every_relaunch_records_its_first_answer_per_mode_and_the_failed_checks(self):
        written = self.run_record("re", [("kill", 410.0), ("quit", 380.5), ("crash", 520.0), ("kill", 400.0)],
                                  ["round 1 after kill: surface:3 attach phase replaying after 20 s"])
        self.assertTrue(journey.any_written(written))
        lines = self.by_metric()
        self.assertEqual(lines["relaunch_e2e.kill.first_answer"]["samples"], [410.0, 400.0])
        self.assertEqual(lines["relaunch_e2e.failed_checks"]["samples"], [1.0])
        self.assert_story_contract("relaunch-e2e")
        self.assertEqual(sorted(self.ingest()), ["relaunch-e2e"])

    def test_a_stopped_run_or_a_silent_relaunch_writes_nothing(self):
        self.assertTrue(self.run_record("re2", [("kill", 400.0)], [], finished=False).startswith("none: "))
        self.assertTrue(self.run_record("re3", [("kill", None)], []).startswith("none: "))
        self.assertTrue(self.no_results())

    def test_story_refusals(self):
        for argv in (["--tag", "t", "--story", "relaunch-e2e", "--long-top", "60"],
                     ["--tag", "t", "--story", "typing"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as raised:
                relaunch_e2e.parse_args(argv)
            self.assertEqual(raised.exception.code, 2)
        self.assertEqual(relaunch_e2e.parse_args(["--tag", "t", "--story", "relaunch-e2e"]).session, "light")


def soak_sample(elapsed, phase="load", app_mb=500.0, ping=1.0, snapshot=4.0):
    row = lambda cpu, mb, fds: {"count": 1, "cpu_percent": cpu, "footprint_mb": mb, "wakeups_per_s": 3.0,  # noqa: E731
                                "fds": fds}
    return {"at": "t", "elapsed_s": elapsed, "phase": phase, "running": 0, "ping_ms": ping, "snapshot_ms": snapshot,
            "zombies": 0, "turns": 4, "turns_done": 4,
            "processes": {"app": row(4.0, app_mb, 100), "daemon": row(1.0, 200.0, 50), "acpmux": row(0.5, 80.0, 20)}}


class ReadinessSoakTests(RecordingCase):
    def soak(self, rows, story="readiness-soak", completed=True, engine="chromium", hours=1.0, tag="soak"):
        run = soak.Soak.__new__(soak.Soak)
        run.args = types.SimpleNamespace(
            app_config=None, stress=False, zombie_gate="warn", warmup=0, settle=0, idle=0, hours=hours,
            max_growth_mb=300, max_growth_percent=25, max_fd_growth=100, max_app_cpu=10, max_daemon_cpu=5,
            max_idle_app_cpu=1, max_idle_daemon_cpu=0.5, max_idle_acpmux_cpu=0.5, idle_cpu_gate="warn",
            terminals=0, browsers=4, agents=0, story=story)
        run.out = os.path.join(self.folder, "soak")
        os.makedirs(run.out, exist_ok=True)
        with open(os.path.join(run.out, "samples.jsonl"), "w") as handle:
            handle.writelines(json.dumps(r) + "\n" for r in rows)
        run.samples = open(os.path.join(run.out, "samples.jsonl"), "a")
        run.setup = {"terminals": 0, "browsers": 4, "agents": 0, "browser_engine": engine}
        run.events = [{"at": "t", "kind": "hang", "detail": "slow"}]
        run.zombies, run.sanitizer_count, run.app = {}, 0, "/tmp/app"
        run.completed = completed
        run.bench = self.bench(tag)
        return run

    def rows(self):
        return [soak_sample(s, app_mb=500.0 + s / 60, ping=1.0 + s / 3600) for s in range(0, 3601, 300)]

    def test_a_whole_soak_records_its_series_and_its_failed_criteria(self):
        with contextlib.redirect_stdout(io.StringIO()):
            result = self.soak(self.rows()).report()
        self.assertTrue(journey.any_written(result["results"]), result["results"])
        self.assertIn("1 hang event(s)", result["failures"])
        lines = self.by_metric()
        self.assertEqual(lines["readiness_soak.events.hang"]["samples"], [1.0])
        self.assertEqual(lines["readiness_soak.events.crash"]["samples"], [0.0])
        self.assertEqual(len(lines["readiness_soak.app.cpu"]["samples"]), 13)
        self.assertEqual(lines["readiness_soak.app.footprint_growth"]["unit"], "bytes")
        self.assertNotIn("readiness_soak.app.idle_cpu", lines, "no quiet phase: no idle samples")
        self.assertEqual(result["snapshot_ms_p99"], journey.percentile([4.0] * 13, 0.99, digits=1))
        self.assert_story_contract("readiness-soak")
        self.assertEqual(sorted(self.ingest()), ["readiness-soak"])

    def test_an_app_that_exits_during_the_loop_is_one_crash(self):
        # BenchApp starts the app as this process's child: an exit with no crash report (SIGKILL, jetsam) leaves a
        # zombie with the same PID, which the process table still lists.
        app = subprocess.Popen([sys.executable, "-c", "import os, time; time.sleep(0.6); os._exit(0)"])
        run = soak.Soak.__new__(soak.Soak)
        run.args = types.SimpleNamespace(hours=2.5 / 3600, idle=0, turn_every=300, sample=0.2, app_config=None)
        run.app, run.work, run.tag = os.path.join(self.folder, "cmux DEV gone.app"), self.folder, "gone"
        run.quiet_file = os.path.join(self.folder, "quiet")
        run.setup, run.events, run.agents, run.pids = {"identity": {"pid": app.pid}}, [], {}, {}
        run.app_pid, run.app_exit, run.seen_pids, run.started = app.pid, None, set(), soak.time.time()
        run.zombies, run.zombies_last, run.sanitizer, run.chromium_off = {}, set(), None, False
        run.bench = types.SimpleNamespace(process=app)
        run.samples = open(os.path.join(self.folder, "samples.jsonl"), "w")
        run.crash_reports = lambda: []
        run.sample = lambda before, kinds, wall: {}
        run.check_control = lambda: (1.0, 4.0)
        run.acp = types.SimpleNamespace(sessions=lambda: {})
        try:
            with mock.patch.object(soak, "usage", lambda pid: None), contextlib.redirect_stdout(io.StringIO()):
                run.loop()
        finally:
            run.samples.close()
            if app.poll() is None:
                app.kill()
                app.wait()
        crashes = [e for e in run.events if e["kind"] == "crash"]
        self.assertEqual(len(crashes), 1, run.events)
        self.assertEqual(crashes[0]["returncode"], 0)
        self.assertEqual(run.pids["app"], [])
        self.assertNotIn(app.pid, run.kinds(), "an exited app's PID is not the app")
        whole = self.soak(self.rows())
        whole.events = run.events
        with contextlib.redirect_stdout(io.StringIO()):
            result = whole.report()
        self.assertIn("1 crash event(s)", result["failures"])
        self.assertEqual(self.by_metric()["readiness_soak.events.crash"]["samples"], [1.0])

    def test_a_short_stopped_or_webkit_soak_writes_nothing_and_fails(self):
        for index, kwargs in enumerate(({"completed": False}, {"engine": "webkit"}, {"hours": 4.0})):
            with self.subTest(**kwargs), contextlib.redirect_stdout(io.StringIO()):
                result = self.soak(self.rows(), tag=f"soak{index}", **kwargs).report()
            self.assertTrue(str(result["results"]).startswith("none: "), result["results"])
            self.assertFalse(result["ok"])
            self.assertTrue(any(f.startswith("result-v1: ") for f in result["failures"]))
        self.assertTrue(self.no_results())

    def test_no_story_no_result(self):
        with contextlib.redirect_stdout(io.StringIO()):
            result = self.soak(self.rows(), story=None).report()
        self.assertNotIn("results", result)
        self.assertTrue(self.no_results())

    def test_story_refusals(self):
        base = ["--app", "a.app", "--hours", "1", "--warmup", "60", "--idle", "60"]
        for extra in (["--story", "readiness-soak", "--app-config", "asan"],
                      ["--story", "readiness-soak", "--browsers", "0"],
                      ["--story", "readiness-soak", "--stress"],
                      ["--session", "stress"]):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as raised:
                soak.parse_args(base + extra)
            self.assertEqual(raised.exception.code, 2)
        self.assertEqual(soak.parse_args(base + ["--story", "readiness-soak", "--session", "light"]).story,
                         "readiness-soak")

    def test_the_soak_copy_is_named_for_the_tag_its_bundle_id_has(self):
        app = os.path.join(self.folder, "cmux DEV split-spring.app")
        os.makedirs(os.path.join(app, "Contents"))
        with open(os.path.join(app, "Contents/Info.plist"), "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.debug.split.spring.soak42",
                           "CFBundleExecutable": "cmux DEV"}, handle)
        tag, _ = soak.bundle_tag(app)
        self.assertEqual(tag, "split-spring-soak42")
        self.assertEqual(bl.tag_of(os.path.join(self.folder, "cmux DEV split-spring-soak42.app")), tag)

    def test_the_launch_env_lets_the_fake_agents_start(self):
        run = soak.Soak.__new__(soak.Soak)
        run.acpmux_home = "/tmp/acpmux-home"
        env = run.launch_env()
        self.assertEqual(env["ACPMUX_HOME"], "/tmp/acpmux-home")
        self.assertIsNone(env["ACPMUX_AGENT_LAUNCH"], "the bench env's deny would refuse the fake agent")
        self.assertIsNone(env["CMUX_NEXT_AGENT_PANE_MOCK"])


class QueueAndStoryTests(unittest.TestCase):
    def test_the_scripts_leave_the_bench_migration_queues(self):
        names = {f"scripts/cmux-next/{name}" for name in SCRIPTS + ("launch_journey_report.py",)}
        for query in (queues.private_stats, queues.self_launch, queues.p95_without_p99):
            self.assertEqual(sorted(names & {item.key for item in query(str(ROOT))}), [], query.__name__)

    def test_no_script_sorts_its_own_percentile(self):
        for name in SCRIPTS:
            text = (HERE / name).read_text()
            self.assertNotRegex(text, r"len\(\w+\) // 2\]|int\(len\(\w+\) \* 0\.99\)|statistics\.median", name)

    def test_each_story_needs_the_debug_methods_its_script_calls(self):
        # debug.windows is BenchApp's launch readiness probe, which every launch has.
        for name, story_id in STORIES.items():
            with self.subTest(story=story_id):
                called = set(re.findall(r'"(debug\.[a-z_.]*[a-z_])"', (HERE / name).read_text())) - {"debug.windows"}
                needs = {n.split(":", 1)[1] for n in story_file(story_id)["needs"] if n.startswith("debug:")}
                self.assertEqual(needs, called)

    def test_each_story_runs_its_script(self):
        for name, story_id in STORIES.items():
            story = story_file(story_id)
            self.assertEqual(story["command"][0], f"scripts/cmux-next/{name}")
            self.assertEqual(story["command"][story["command"].index("--story") + 1], story_id)

    def test_the_soak_story_parses_and_leaves_a_load_phase(self):
        command = story_file("readiness-soak")["command"]
        args = soak.parse_args(command[1:] + ["--app", "a.app"])
        self.assertLess(args.warmup + args.idle, args.hours * 3600)


if __name__ == "__main__":
    unittest.main()
