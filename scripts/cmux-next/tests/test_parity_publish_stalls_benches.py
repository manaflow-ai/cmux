#!/usr/bin/env python3
"""bench-config-parity, bench-control-publish and bench-stalls on perf_stats, BenchApp and result-v1
(p12-perf-process-066).

1. Every percentile is perf_stats.pct (old against new on a fixed vector).
2. The parity story: one `bench_parity.action_commit_delta_pct` sample per interleaved Release/bench pair, written
   through a real BenchApp.record of the Release bundle (config release) and the real perf-lab ingest; a run with lost
   signposts, failed actions or a pair with no action.commit writes nothing and fails; two commits, a bench-checks
   bundle or one tag for both arms are refused before any launch.
3. control-publish and stalls write their series (raw samples) through BenchApp.record, matching their stories.
4. The three benches leave the bench-migration queues (MQ1, MQ2, MQ3); each story runs its bench and needs the
   debug methods it calls.
5. The parity story is not measurable until the lab can hand it a Release and a bench build: no shard, round, build
   or runner selection holds it, and the runner's argv parses except for the missing --bench.
6. Launches (a real BenchApp of a script bundle): the lab host validation is outside stalls' launch.key_echo, and a
   launch that fails after its spawn still ends its tag (stalls on a later run, parity on any run).

Linux and macOS; no app, no GUI session:

    python3 -m unittest scripts/cmux-next/tests/test_parity_publish_stalls_benches.py
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import shutil
import statistics
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = ROOT / "scripts/perf-lab"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_launch as bl  # noqa: E402
import tag_teardown  # noqa: E402
from test_bench_launch import FEATURES, HOST, OK_SESSION, record_bundle, result_lines  # noqa: E402

perf_stats = bl.load_by_path("perf_stats", str(PERF_LAB / "perf_stats.py"))
catalog = bl.load_by_path("perf_lab_catalog", str(PERF_LAB / "catalog.py"))
scheduler = bl.load_by_path("perf_lab_scheduler", str(PERF_LAB / "scheduler.py"))
gen_shard_map = bl.load_by_path("perf_lab_gen_shard_map", str(PERF_LAB / "gen_shard_map.py"))
run_story = bl.load_by_path("perf_lab_run_story", str(PERF_LAB / "run_story.py"))
ingest = bl.load_by_path("perf_lab_ingest", str(PERF_LAB / "ingest.py"))
queues = bl.load_by_path("perf_lab_queues", str(PERF_LAB / "queues.py"))
parity = bl.load_by_path("bench_config_parity", str(HERE / "bench-config-parity.py"))
publish = bl.load_by_path("bench_control_publish", str(HERE / "bench-control-publish.py"))
stalls = bl.load_by_path("bench_stalls", str(HERE / "bench-stalls.py"))

BENCHES = {"bench-config-parity.py": "bench-parity", "bench-control-publish.py": "control-publish",
           "bench-stalls.py": "stalls"}
SHA = "e" * 40
VECTOR = [3.1, 4.7, 5.0, 5.2, 6.8, 7.4, 8.0, 9.9, 12.5, 30.2]


def story_file(story_id):
    return json.loads((PERF_LAB / "stories.d" / f"{story_id}.json").read_text())


class RecordingCase(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="parity-publish-stalls-")
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def bench(self, tag, commit=SHA, stamped="bench", marker=True, session="light", build_config=None):
        app = bl.BenchApp(record_bundle(self.folder, tag, commit=commit, marker=marker, stamped=stamped),
                          out=self.out, teardown=False, host=lambda: dict(HOST), perf_session=session,
                          build_config=build_config)
        app.features = FEATURES  # what launch() read
        return app

    def by_metric(self):
        return {line["metric"]: line for line in result_lines(self.out)}

    def assert_story_contract(self, story_id):
        """Every written line is `story_id`'s, fullmatches one of its patterns with that pattern's unit, and carries
        the story's engine, session and config."""
        story = story_file(story_id)
        lines = result_lines(self.out)
        self.assertTrue(lines)
        for line in lines:
            self.assertEqual(line["story"], story_id)
            units = [m["unit"] for m in story["metrics"] if re.fullmatch(m["name"], line["metric"])]
            self.assertEqual(units, [line["unit"]], f"{story_id} declares {line['metric']} once with its unit")
            self.assertEqual((line["engine"], line["session"]), (story["engine"], story["session"]), line["metric"])
            self.assertEqual(line["build"]["config"], story["config"], line["metric"])
            self.assertEqual(line["better"], "lower")

    def ingest(self):
        """The out folder through the real perf-lab ingest: {story: {metric: samples}}."""
        db = ingest.store.Store(Path(self.folder) / "lab.sqlite3")
        db.migrate()
        try:
            got = ingest.ingest_paths(db, [self.out], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
            self.assertEqual([r.line() for r in got.rejected], [])
            runs = db._db.execute("SELECT run_uuid FROM runs").fetchall()
            return {row["run_uuid"].split("/", 1)[1]: db.run_metrics(row["run_uuid"]) for row in runs}
        finally:
            db.close()


class StatisticsTests(unittest.TestCase):
    def test_the_fixed_vector_of_the_commit(self):
        # Old: control-publish p50 statistics.median and p90 s[int(0.9 * (n - 1))]; stalls and parity
        # statistics.median. New: perf_stats.pct (linear interpolation).
        ordered = sorted(VECTOR)
        self.assertEqual((statistics.median(VECTOR), ordered[int(0.9 * (len(ordered) - 1))]), (7.1, 12.5))
        summary = publish.publish_summary(VECTOR)
        self.assertEqual({k: summary[k] for k in ("count", "p50", "p90", "p95", "p99", "max")},
                         {"count": 10, "p50": 7.1, "p90": 14.27, "p95": 22.235, "p99": 28.607, "max": 30.2})
        self.assertEqual(publish.rename_summary(VECTOR), {"p50": 7.1, "p95": 22.23, "p99": 28.61, "max": 30.2})

    def test_stalls_summary_and_per_tab_median_are_perf_stats(self):
        self.assertEqual(stalls.summarize(VECTOR), {"median": perf_stats.pct(VECTOR, 0.5),
                                                    "p99": perf_stats.pct(VECTOR, 0.99), "min": 3.1, "max": 30.2})
        row = stalls.finish({"tab.later_max_gap_ms": [9.0, 4.0, 5.0, 7.0], "tab.first_surface_ms": [],
                             "launch.key_echo_ms": 412.0})
        self.assertEqual(row, {"tab.later_max_gap_ms": 6.0, "tab.first_surface_ms": None, "launch.key_echo_ms": 412.0})

    def test_parity_verdict_medians_are_perf_stats(self):
        runs = [parity_run(kind, i, commit) for i, (kind, commit) in
                enumerate([("release", 1.0), ("bench", 1.02), ("release", 1.1), ("bench", 1.04), ("release", 0.9),
                           ("bench", 1.3)])]
        table, ok = parity.verdict(runs)
        row = next(r for r in table if r["metric"] == "action.commit * p50")
        self.assertEqual((row["median_release"], row["median_bench"]), (1.0, 1.04))
        self.assertEqual(row["spread"], round(1.3 - 1.02, 3))
        self.assertTrue(ok)
        self.assertIn("action.commit * p99", {r["metric"] for r in table})


def parity_run(kind, index, commit_p50, lost=0, errors=0):
    rows = {"action.commit *": {"n": 80, "p50": commit_p50, "p95": commit_p50 * 2, "p99": commit_p50 * 3},
            "action.perform *": {"n": 80, "p50": commit_p50 / 2, "p95": commit_p50, "p99": commit_p50 * 1.5}}
    return {"kind": kind, "run": index, "idle_cpu_pct": 0.2, "lost": lost, "action_errors": errors, "rows": rows}


class ParityStoryTests(RecordingCase):
    def release(self, tag="parrel"):
        return self.bench(tag, stamped="release", marker=False)

    def test_one_delta_per_pair_through_the_release_bench_app(self):
        runs = [parity_run("release", 0, 2.0), parity_run("bench", 0, 2.04),
                parity_run("release", 1, 2.5), parity_run("bench", 1, 2.45)]
        where, ok = parity.record_parity(self.release(), "bench-parity", runs)
        self.assertTrue(ok, where)
        line = self.by_metric()[parity.PARITY_METRIC]
        self.assertEqual(line["samples"], [2.0, -2.0])
        self.assertEqual((line["unit"], line["build"]["config"], line["build"]["sha"]), ("percent", "release", SHA))
        self.assert_story_contract("bench-parity")
        self.assertEqual(list(self.ingest()), ["bench-parity"])

    def test_the_done_check_reads_this_metric(self):
        done_checks = bl.load_by_path("perf_lab_done_checks", str(PERF_LAB / "done_checks.py"))
        check = next(c for c in done_checks.CHECKS if c.name == "release-grade")
        self.assertEqual(check.threshold["parity_metric"], parity.PARITY_METRIC)
        self.assertTrue(re.fullmatch(story_file("bench-parity")["metrics"][0]["name"], parity.PARITY_METRIC))

    def test_an_unfair_sample_writes_nothing(self):
        cases = {
            "lost": [parity_run("release", 0, 2.0, lost=1), parity_run("bench", 0, 2.0)],
            "errors": [parity_run("release", 0, 2.0), parity_run("bench", 0, 2.0, errors=3)],
            "no commit row": [parity_run("release", 0, 2.0), {**parity_run("bench", 0, 2.0), "rows": {}}],
            "half a pair": [parity_run("release", 0, 2.0)],
        }
        for name, runs in cases.items():
            with self.subTest(name):
                where, ok = parity.record_parity(self.release(f"r{len(name)}{name[0]}"), "bench-parity", runs)
                self.assertFalse(ok)
                self.assertTrue(where.startswith("not recorded"), where)
        self.assertFalse(os.path.isdir(self.out) and list(Path(self.out).glob("*.ndjson")))

    def test_arms_are_refused_before_any_launch(self):
        release = record_bundle(self.folder, "arel", commit=SHA, stamped="release")
        cases = {
            "another commit": (release, record_bundle(self.folder, "abench", commit="f" * 40, marker=True,
                                                      stamped="bench")),
            "bench-checks": (release, record_bundle(self.folder, "achecks", commit=SHA, marker=True,
                                                    stamped="bench-checks")),
            "a release as bench": (release, record_bundle(self.folder, "arel2", commit=SHA, stamped="release")),
        }
        reasons = {"another commit": "two builds of one commit", "bench-checks": "built with --config bench-checks",
                   "a release as bench": "is a release bundle"}
        for name, (rel, bench) in cases.items():
            with self.subTest(name), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaisesRegex(SystemExit, reasons[name]):
                    parity.main(["--release", rel, "--bench", bench, "--story", "bench-parity", "--out", self.out])
        other = os.path.join(self.folder, "other")
        os.makedirs(other)
        same_tag = record_bundle(other, "arel", commit=SHA, marker=True, stamped="bench")
        with self.assertRaisesRegex(SystemExit, "both bundles are tag"):
            parity.main(["--release", release, "--bench", same_tag, "--out", self.out])

    def test_the_story_runner_passes_release_as_app(self):
        launched = []
        original = parity.one_run, parity.BenchApp
        parity.one_run = lambda kind, app, opts, index: (launched.append((kind, app.tag)) or
                                                         parity_run(kind, index, 2.0 if kind == "release" else 2.01))
        bench = record_bundle(self.folder, "mbench", commit=SHA, marker=True, stamped="bench")
        release = record_bundle(self.folder, "mrel", commit=SHA, stamped="release")

        def make(bundle, **kwargs):
            app = bl.BenchApp(bundle, teardown=False, host=lambda: dict(HOST), **kwargs)
            app.features = FEATURES
            return app

        parity.BenchApp = make
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                code = parity.main(["--app", release, "--bench", bench, "--tag", "x", "--story", "bench-parity",
                                    "--runs", "2", "--out", self.out])
        finally:
            parity.one_run, parity.BenchApp = original
        self.assertEqual(code, 0)
        self.assertEqual(launched, [("release", "mrel"), ("bench", "mbench")] * 2)
        self.assertEqual(self.by_metric()[parity.PARITY_METRIC]["samples"], [0.5, 0.5])
        report = json.loads(Path(self.out, "parity.json").read_text())
        self.assertEqual(report["action_commit_delta_pct"], [0.5, 0.5])


class ControlPublishTests(RecordingCase):
    def test_a_run_records_both_series(self):
        written = publish.record_series(self.bench("pub", session="stress"), "control-publish", VECTOR, [5.0, 6.0])
        self.assertFalse([w for w in written.values() if w.startswith("not recorded")], written)
        lines = self.by_metric()
        self.assertEqual(lines["control_publish.publish"]["samples"], VECTOR)
        self.assertEqual(lines["control_publish.rename_to_snapshot"]["samples"], [5.0, 6.0])
        self.assert_story_contract("control-publish")

    def test_empty_samples_are_reported_not_raised(self):
        written = publish.record_series(self.bench("pube", session="stress"), "control-publish", [], [5.0])
        self.assertTrue(written["control_publish.publish"].startswith("not recorded"))

    def test_app_or_tag_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            publish.parse_args([])
        self.assertEqual(publish.parse_args(["--app", "a.app", "--story", "control-publish"]).session, "stress")


class StallsTests(RecordingCase):
    RUNS = [
        {"launch.key_echo_ms": 410.0, "launch.stole_focus": 0, "launch.to_first_content_ms": None,
         "daemon.ensure_ms": 30.5, "palette.open1_frame_ms": 12.0, "tab.first_max_gap_ms": [9.0],
         "tab.later_max_gap_ms": [4.0, 6.0], "tab.later_surface_ms": [2.0, 2.5]},
        {"launch.key_echo_ms": 400.0, "launch.stole_focus": 1, "launch.to_first_content_ms": 120.0,
         "daemon.ensure_ms": 31.0, "palette.open1_frame_ms": 11.0, "tab.first_max_gap_ms": [8.0],
         "tab.later_max_gap_ms": [5.0, 7.0], "tab.later_surface_ms": [2.1]},
    ]

    def test_series_keep_raw_samples_and_drop_checks(self):
        series = stalls.series(self.RUNS)
        self.assertEqual(series["stalls.launch.key_echo"], [410.0, 400.0])
        self.assertEqual(series["stalls.launch.to_first_content"], [120.0])
        self.assertEqual(series["stalls.tab.later_max_gap"], [4.0, 6.0, 5.0, 7.0])
        self.assertNotIn("stalls.launch.stole_focus", series)

    def test_every_series_fits_the_story(self):
        written = stalls.record_series(self.bench("stl"), "stalls", self.RUNS)
        self.assertFalse([w for w in written.values() if w.startswith("not recorded")], written)
        self.assert_story_contract("stalls")
        self.assertEqual(self.by_metric()["stalls.daemon.ensure"]["samples"], [30.5, 31.0])

    def test_every_metric_the_run_makes_fits_the_story(self):
        keys = ["launch.key_echo_ms", "launch.to_did_finish_launching_ms", "launch.did_finish_launching_ms",
                "launch.to_first_window_frame_ms", "launch.to_snapshot_applied_ms", "launch.to_snapshot_layout_ms",
                "launch.to_first_terminal_ms", "launch.to_daemon_connected_ms", "launch.to_snapshot_loaded_ms",
                "launch.to_first_content_ms", "daemon.login_env_ms", "daemon.ensure_ms", "daemon.handshake_ms",
                "launch.max_stall_ms", "launch.max_stall_cpu_ms", "launch.first_surface_ms"]
        keys += [f"palette.open{i}_{m}_ms" for i in (1, 2) for m in ("frame", "max_gap", "stall_cpu")]
        keys += [f"tab.{w}_{m}_ms" for w in ("first", "later") for m in ("max_gap", "stall_cpu", "surface")]
        source = (HERE / "bench-stalls.py").read_text()
        patterns = [m["name"] for m in story_file("stalls")["metrics"]]
        for key in keys:
            with self.subTest(key):
                self.assertTrue(f'"{key}"' in source or key.startswith(("palette.", "tab.")), key)
                self.assertTrue(any(re.fullmatch(p, stalls.metric_name(key)) for p in patterns), key)

    def test_two_builds_of_one_tag_are_refused(self):
        app = record_bundle(self.folder, "same", commit=SHA, marker=True, stamped="bench")
        with self.assertRaises(SystemExit):
            stalls.main(["--app", app, "--app", app, "--out", self.out])


class QueueAndStoryTests(unittest.TestCase):
    def test_the_benches_leave_the_bench_migration_queues(self):
        names = {f"scripts/cmux-next/{name}" for name in BENCHES}
        for query in (queues.private_stats, queues.self_launch, queues.p95_without_p99):
            self.assertEqual(sorted(names & {item.key for item in query(str(ROOT))}), [], query.__name__)

    def test_no_bench_keeps_its_own_launch_or_median(self):
        for name in BENCHES:
            text = (HERE / name).read_text()
            self.assertNotIn("subprocess.Popen(", text, name)
            self.assertNotIn("statistics.median(", text, name)

    def test_each_story_needs_the_debug_methods_its_bench_calls(self):
        for name, story_id in BENCHES.items():
            with self.subTest(story=story_id):
                called = set(re.findall(r'"(debug\.[a-z_.]*[a-z_])"', (HERE / name).read_text()))
                needs = {n.split(":", 1)[1] for n in story_file(story_id)["needs"] if n.startswith("debug:")}
                self.assertEqual(needs, called)

    def test_each_story_runs_its_bench(self):
        for name, story_id in BENCHES.items():
            story = story_file(story_id)
            self.assertEqual(story["command"][0], f"scripts/cmux-next/{name}")
            self.assertEqual(story["command"][story["command"].index("--story") + 1], story_id)

    def test_the_parity_story_is_the_release_config(self):
        self.assertEqual(story_file("bench-parity")["config"], "release")
        self.assertEqual(parity.PARITY_STORY, "bench-parity")


class NotMeasurableParityStoryTests(unittest.TestCase):
    """The lab cannot run bench-parity yet: it builds only bench and bench-checks artifacts, one per run, and the
    runner appends only --app --tag --out. The story is defined and linted, but no shard, round, build or runner
    selection holds it, so it is never a story that fails every T1 round (review of p12-perf-process-066)."""

    @classmethod
    def setUpClass(cls):
        cls.catalog = catalog.load_catalog(ROOT)
        cls.story = next(s for s in cls.catalog.stories if s.id == "bench-parity")

    def test_the_catalog_defines_it_as_not_measurable_without_a_lint_problem(self):
        self.assertFalse(self.story.measurable())
        self.assertIn("--bench", self.story.not_measurable)
        self.assertEqual([p for p in self.catalog.problems if p.startswith(self.story.path)], [])

    def test_no_shard_round_or_build_is_planned_for_it(self):
        self.assertNotIn("bench-parity", {s.id for s in gen_shard_map.catalog_stories(ROOT)})
        self.assertNotIn("bench-parity", {s.id for s in scheduler.stories_from_catalog(self.catalog)})
        self.assertNotIn(("T1", "bench-parity"), scheduler.ShardMap.load(PERF_LAB / "shard_map.json").sharded())
        self.assertIn("control-publish", {s.id for s in scheduler.stories_from_catalog(self.catalog)})

    def test_the_runner_refuses_it_by_name_and_leaves_it_out_of_a_shard(self):
        stories, problems = run_story.load_stories(str(ROOT))
        with self.assertRaisesRegex(run_story.Refusal, "bench-parity .*not measurable yet"):
            run_story.select_stories(stories, "bench", "bench-parity", None, "T1", problems)
        release = {"bench-parity": stories["bench-parity"]}
        self.assertEqual(run_story.select_stories(release, "release", None, "0/1", "T1"), [])

    def test_the_runner_argv_parses_and_misses_only_the_bench_build(self):
        argv = run_story.story_argv(self.story, "/lab/R.app", "labtag", "/lab/out", root=str(ROOT))
        self.assertEqual(argv[1], str(ROOT / "scripts/cmux-next/bench-config-parity.py"))
        self.assertEqual(run_story.contract_problems(self.story, root=str(ROOT)), [])
        opts = parity.parse_args(argv[2:] + ["--bench", "/lab/B.app"])
        self.assertEqual((opts.release, opts.bench, opts.tag, opts.out, opts.story),
                         ("/lab/R.app", "/lab/B.app", "labtag", "/lab/out", "bench-parity"))
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as refused:
            parity.parse_args(argv[2:])
        self.assertEqual(refused.exception.code, 2)
        self.assertIn("--bench", err.getvalue())


class CountingTeardown(tag_teardown.TagTeardown):
    """A real TagTeardown (its done flag, remember() and end()) over no processes; counts the end()s that ran."""

    def __init__(self, app):
        super().__init__(app, log=lambda line: None)
        self.ended = 0

    def processes(self):
        return []

    def install(self):
        pass

    def end(self):
        if not self.done:
            self.ended += 1
        super().end()


class FakeStallsClient:
    """The app's control socket for one stalls run: the terminal and window are up, the typed keys echo."""

    def __init__(self, _path, timeout=10):
        pass

    def call(self, method, params=None):
        results = {"debug.timings": {"launch_ms_since_process_start": {"first_terminal_surface_created": 50.0,
                                                                        "first_window_frame_committed": 40.0}},
                   "surface.read_text": {"text": "$ qzq"}, "debug.focus": {"app_active": False, "key_window": None},
                   "debug.hangs": {"max_gap_ms": 3.0, "records": []}}
        return {"result": results.get(method, {})}

    def close(self):
        pass


class LaunchCase(unittest.TestCase):
    """A real BenchApp of a script bundle (no GUI, Linux too): the control socket is a stand-in (``rpc_at``
    patched), and the script makes its socket file. MAIN exits 1 from its `fail_from`-th start on (a launch that
    spawns, then never answers)."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="parity-stalls-launch-")
        self.tag = f"pslaunch{os.getpid()}"
        self.socket_file = f"/tmp/cmux-debug-{self.tag}.sock"
        self.starts = os.path.join(self.folder, "starts")
        self.saved_env = dict(os.environ)
        os.environ.update(BENCH_LAUNCH_LIMITS="inherit", BENCH_LAUNCH_PMSET="/nonexistent/pmset",
                          BENCH_LAUNCH_LPM_MARKER=os.path.join(self.folder, "lpm.json"))
        for name in (bl.LAB_VDISPLAY_OUT, bl.LAB_HOST_FILE, bl.LAB_CONFIG, bl.LAB_SESSION):
            os.environ.pop(name, None)
        self.lab_checks = []
        self.app = None

    def tearDown(self):
        if self.app and self.app.process and self.app.process.poll() is None:
            self.app.process.kill()
            self.app.process.wait()
        os.environ.clear()
        os.environ.update(self.saved_env)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(self.socket_file)
        shutil.rmtree(self.folder, ignore_errors=True)

    def make_app(self, fail_from=None, lab_seconds=0.0):
        fail = f'[ "$(wc -l < "{self.starts}")" -ge {fail_from} ] && exit 1\n' if fail_from else ""
        main = f'#!/bin/sh\necho start >> "{self.starts}"\n{fail}touch "{self.socket_file}"\nexec sleep 300\n'

        def lab_check(pids):
            time.sleep(lab_seconds)  # host_env's nettop window, shortened
            self.lab_checks.append(sorted(pids))
            return {"ok": True, "reasons": []}

        self.app = bl.BenchApp(record_bundle(self.folder, self.tag, commit=SHA, marker=True, stamped="bench",
                                             main=main),
                               out=os.path.join(self.folder, "out"), teardown=False, session=lambda: OK_SESSION,
                               host=lambda: dict(HOST), config={}, window=None, screen="last", lab_check=lab_check)
        self.app.teardown = CountingTeardown(self.app.app)
        return self.app

    def rpc(self, path, method, params=None, timeout=60):
        if method in ("debug.quit", "app.quit"):
            self.app.process.terminate()
            with contextlib.suppress(FileNotFoundError):
                os.unlink(self.socket_file)
            return {}
        if method == "features.list":
            return {"features": [], "features_hash": "fh", "safe_mode": "off"}
        return {"ok": True}

    def patched(self):
        stack = contextlib.ExitStack()
        stack.enter_context(mock.patch.object(bl, "rpc_at", self.rpc))
        stack.enter_context(mock.patch.object(stalls, "Client", FakeStallsClient))
        stack.enter_context(mock.patch.object(bl, "host_facts", lambda: {"macos": "test"}))  # no sw_vers on Linux
        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
        return stack


class StallsLaunchTests(LaunchCase):
    def test_the_lab_host_validation_is_not_inside_key_echo(self):
        app = self.make_app(lab_seconds=2.5)
        with self.patched():
            metrics, _ = stalls.one_run(app, 0, startup_only=True)
            stalls.one_run(app, 0, startup_only=True)
        self.assertIsNotNone(metrics["launch.key_echo_ms"])
        self.assertLess(metrics["launch.key_echo_ms"], 2500)
        self.assertEqual(len(self.lab_checks), 1, "once per build, while its first measured launch runs")
        self.assertTrue(list(Path(app.out).glob(f"{bl.LAB_CHECK_PREFIX}*.json")))

    def test_a_later_launch_that_fails_after_its_spawn_still_ends_the_tag(self):
        app = self.make_app(fail_from=2)
        with self.patched():
            stalls.one_run(app, 0, startup_only=True)
            with self.assertRaises(bl.LaunchError):
                stalls.one_run(app, 0, startup_only=True)
        self.assertEqual(Path(self.starts).read_text().count("start"), 2)
        self.assertEqual(app.teardown.ended, 2)


class ParityLaunchTests(LaunchCase):
    def test_a_launch_that_fails_after_its_spawn_is_stopped(self):
        app = self.make_app(fail_from=1)
        opts = argparse.Namespace(out=os.path.join(self.folder, "parity"), settle=0, idle=0, rounds=0)
        with self.patched(), self.assertRaises(bl.LaunchError):
            parity.one_run("bench", app, opts, 0)
        self.assertIsNotNone(app.process)
        self.assertIsNotNone(app.process.poll())
        self.assertEqual(app.teardown.ended, 1)


if __name__ == "__main__":
    unittest.main()
