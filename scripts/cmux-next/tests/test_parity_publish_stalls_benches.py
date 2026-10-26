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

Linux and macOS; no app, no GUI session:

    python3 -m unittest scripts/cmux-next/tests/test_parity_publish_stalls_benches.py
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import shutil
import statistics
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = ROOT / "scripts/perf-lab"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_launch as bl  # noqa: E402
from test_bench_launch import FEATURES, HOST, record_bundle, result_lines  # noqa: E402

perf_stats = bl.load_by_path("perf_stats", str(PERF_LAB / "perf_stats.py"))
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


if __name__ == "__main__":
    unittest.main()
