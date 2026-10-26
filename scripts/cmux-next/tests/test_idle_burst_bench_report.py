#!/usr/bin/env python3
"""The idle, fsync and burst benches' result-v1 series (idle_burst_bench_report.py, p12-perf-process-063): the names
the lab stories claim, the perf_stats percentiles against the private ones they replace, the story commands through
each bench's own parser, and one run's series through perf_result and perf-lab ingest.

Runs on any host (Linux included): no app, no daemon, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_idle_burst_bench_report.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
PERF_LAB = HERE.parent / "perf-lab"
STORIES = PERF_LAB / "stories.d"
sys.path.insert(0, str(HERE))
import bench_launch  # noqa: E402
import idle_burst_bench_report as report  # noqa: E402


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ingest = load("perf_lab_ingest", PERF_LAB / "ingest.py")
idle_budget = load("idle_budget_063", HERE / "idle-budget.py")
burst = load("burst_bench_063", HERE / "burst-bench.py")
fsync = load("fsync_bench_063", HERE / "fsync-bench.py")
pr = report.perf_result
store = ingest.store

VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]
FORTY = [float(v) for v in range(1, 41)]  # fsync-bench's 40 calls per mode
SHA = "b" * 40
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="f" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)
BUILD = pr.Build(sha=SHA, config="bench", measure_version=2)
STORY_IDS = ("idle-budget", "idle-budget-webkit", "idle-budget-stress", "browser-idle-cost", "burst", "burst-stress",
             "fsync")


# The private percentiles the benches had before the migration (old and new on one fixed vector).
def old_burst(values, q):  # burst-bench.py percentiles(): index floor
    v = sorted(values)
    return round(v[min(len(v) - 1, int(q * len(v)))], 2)


def old_fsync(values):  # fsync-bench.py: ts[20] and ts[37] of 40 sorted calls
    ts = sorted(values)
    return ts[20], ts[37]


def story(story_id):
    return json.loads((STORIES / f"{story_id}.json").read_text())


def claimed(doc, series):
    """The story metric that full-matches the series' name with its unit, or None."""
    return next((m for m in doc["metrics"] if re.fullmatch(m["name"], series.metric) and m["unit"] == series.unit),
                None)


def idle_entry():
    return {"kinds": {"app": {"wakeups_per_s": 0.4, "wakeups_max": 2.0, "main_wakes_per_s": 0.1, "threads": 30,
                              "threads_max": 31, "energy_mw_billed": 12.5, "gpu_ms_per_s": 0.3,
                              "disk_bytes_per_s": 64.0, "network_bytes": 0, "log_lines": 2},
                      "terminal-host": {"wakeups_per_s": 0.2, "threads_max": 5}},
            "sums": {"app+daemon": {"wakeups_per_s": 0.6, "energy_mw_billed": 14.0, "energy_mw_cpu": 9.0},
                     "tree": {"wakeups_per_s": 0.9}}}


def idle_series(session, failed=False):
    rows = {} if failed else idle_budget.cron_rows({"sessions": {session: idle_entry()}}, {})
    return report.idle_budget_series(session, idle_budget.SESSIONS[session], rows, failed=failed)


def browser_results(tabs=5):
    classes = {kind: {"cpu_percent": 0.4, "wakeups_per_s": 3.0, "footprint_total": 120_000_000, "bytes_written": 0}
               for kind in ("gpu", "renderer", "network-service")}
    return {"tabs": tabs, "console_marker_lines_on_disk": 0,
            "phases": [{"phase": phase, "classes": classes, "total_cpu_percent": 1.2, "cef_log_bytes_per_min": 120}
                       for phase in ("static", "loading", "chatty")]}


def burst_row(scenario, invalid=(), errors=()):
    return {"scenario": scenario, "invalid": list(invalid), "errors": list(errors), "lost": 0, "extra": 0,
            "commit_missed": 1, "frames": {"missed": 3}, "input_to_next_commit_samples_ms": [4.0, 6.5, None, 9.25]}


class PercentileTests(unittest.TestCase):
    def test_fixed_vector_old_private_percentiles_and_the_perf_stats_ones(self):
        self.assertEqual([old_burst(VECTOR, q) for q in (.5, .95, .99)], [7.9, 20.1, 20.1])
        self.assertEqual(report.percentiles(VECTOR), {"n": 10, "p50": 6.95, "p95": 16.63, "p99": 19.41, "max": 20.1})
        self.assertEqual(old_fsync(FORTY), (21.0, 38.0))
        self.assertEqual(report.latency_block(FORTY),
                         {"n": 40, "p50_ms": 20.5, "p95_ms": 38.05, "p99_ms": 39.61, "max_ms": 40.0})
        self.assertEqual(report.fsync_line("fsync", FORTY), "fsync p50 20.50 p95 38.05 p99 39.61 ms n=40")

    def test_burst_bench_uses_the_shared_percentiles(self):
        self.assertIs(burst.percentiles, report.percentiles)
        self.assertIsNone(report.percentiles([None, True]))
        self.assertEqual(report.latency_block([]), {"n": 0})


class SeriesTests(unittest.TestCase):
    def test_idle_budget_rows_go_to_the_session_story(self):
        placed = {name: report.idle_budget_story(name, spec) for name, spec in idle_budget.SESSIONS.items()}
        self.assertEqual(placed["light"], ("idle-budget", "chromium", "light"))
        self.assertEqual(placed["tabs-static"], ("idle-budget", "chromium", "light"))
        self.assertEqual(placed["light-webkit"], ("idle-budget-webkit", "webkit", "light"))
        self.assertEqual(placed["stress-static"], ("idle-budget-stress", "chromium", "stress"))
        self.assertIsNone(placed["chrome-static"])
        self.assertEqual(report.idle_budget_series("chrome-static", idle_budget.SESSIONS["chrome-static"], {}), [])

    def test_idle_budget_cron_rows_are_one_sample_each_and_failed_is_counted(self):
        series = {s.metric: s for s in idle_series("light")}
        self.assertEqual(series["idle_budget.light.app.wakeups_per_s"].samples, [0.4])
        self.assertEqual(series["idle_budget.light.app.gpu_ms_per_s"].unit, "ms")
        self.assertEqual(series["idle_budget.light.app_daemon.energy_mw_billed"].unit, "mW")
        self.assertEqual(series["idle_budget.light.tree.wakeups_per_s"].samples, [0.6])
        self.assertEqual(report.idle_budget_metric("light", "idle_budget.light.other:cmux DEV.app.threads"),
                         "idle_budget.light.other_cmux_DEV_app.threads")
        self.assertEqual(series["idle_budget.light.failed"].samples, [0])
        failed = idle_series("light", failed=True)
        self.assertEqual([(s.metric, s.samples) for s in failed], [("idle_budget.light.failed", [1])])

    def test_browser_idle_phases_classes_and_failures(self):
        series = {s.metric: s for s in report.browser_idle_series(browser_results(), ["a FAIL"])}
        self.assertEqual(series["browser_idle.tabs-5.static.gpu.footprint"].samples, [120_000_000])
        self.assertEqual(series["browser_idle.tabs-5.chatty.cef_log_bytes_per_s"].samples, [2.0])
        self.assertEqual(series["browser_idle.tabs-5.failures"].samples, [1])

    def test_burst_invalid_rows_write_only_their_invalid_count(self):
        rows = [burst_row("cmdw-terminal"), burst_row("cmdd", invalid=["no commit"]), burst_row("mixed", errors=["x"])]
        series = {s.metric: s for s in report.burst_series("light", rows)}
        self.assertEqual(series["burst.light.cmdw-terminal.input_to_next_commit"].samples, [4.0, 6.5, 9.25])
        self.assertEqual(series["burst.light.cmdw-terminal.frames_missed"].samples, [3])
        self.assertEqual(series["burst.light.cmdw-terminal.invalid"].samples, [0])
        self.assertEqual([m for m in series if ".cmdd." in m], ["burst.light.cmdd.invalid"])
        self.assertEqual(series["burst.light.mixed.invalid"].samples, [1])
        self.assertEqual({s.story for s in report.burst_series("stress", rows)}, {"burst-stress"})

    def test_fsync_modes_every_call(self):
        series = report.fsync_series({"fsync": [1.0, 2.0], "barrier": [], "fullfsync": [None, 3.0]})
        self.assertEqual([(s.metric, s.samples) for s in series], [("fsync.fsync.call", [1.0, 2.0]),
                                                                   ("fsync.fullfsync.call", [3.0])])


class StoryTests(unittest.TestCase):
    def check_claimed(self, story_id, series):
        doc = story(story_id)
        mine = [s for s in series if s.story == story_id]
        self.assertTrue(mine, f"no series for {story_id}")
        for s in mine:
            self.assertEqual((s.engine, s.session), (doc["engine"], doc["session"]), s.metric)
            self.assertIsNotNone(claimed(doc, s), f"{story_id} claims no metric {s.metric} ({s.unit})")

    def test_every_series_a_story_runs_is_claimed_by_it(self):
        for story_id in ("idle-budget", "idle-budget-webkit", "idle-budget-stress"):
            command = story(story_id)["command"]
            sessions = idle_budget.parse_sessions(command[command.index("--sessions") + 1])
            for session in sessions:
                self.assertEqual(report.idle_budget_story(session, idle_budget.SESSIONS[session])[0], story_id)
                self.check_claimed(story_id, idle_series(session) + idle_series(session, failed=True))
        self.check_claimed("browser-idle-cost", report.browser_idle_series(browser_results(), []))
        rows = [burst_row(name) for name in burst.SCENARIOS] + [burst_row("cmdd", invalid=["x"])]
        self.check_claimed("burst", report.burst_series("light", rows))
        self.check_claimed("burst-stress", report.burst_series("stress", rows))
        self.check_claimed("fsync", report.fsync_series({mode: [1.0] for mode, _ in report.FSYNC_MODES}))

    RUNNER = ["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", "/x/out"]  # what the story runner adds

    def command(self, story_id, script):
        command = story(story_id)["command"]
        self.assertEqual(command[0], f"scripts/cmux-next/{script}")
        return command[1:] + self.RUNNER

    def test_story_commands_parse_with_their_bench(self):
        light = burst.parse(self.command("burst", "burst-bench.py"))
        self.assertEqual((light.phases, light.app, light.out), (["light"], "/x/cmux DEV t.app", "/x/out"))
        self.assertEqual(burst.parse(self.command("burst-stress", "burst-bench.py")).phases, ["stress"])
        self.assertEqual(burst.parse(["--app", "a", "--no-stress"]).phases, ["light"])
        with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
            burst.parse(["--app", "a", "--phases", "heavy"])
        timed = fsync.parse(self.command("fsync", "fsync-bench.py"))
        self.assertEqual((timed.writes, timed.out, timed.story), (40, "/x/out", "fsync"))
        with self.assertRaises(SystemExit), redirect_stderr(io.StringIO()):
            fsync.parse(["--out", "/x/out"])  # a result names the build it measured
        idle = load("browser_idle_cost_063", HERE / "browser-idle-cost-live.py")
        opts = idle.parse(self.command("browser-idle-cost", "browser-idle-cost-live.py"))
        self.assertEqual((opts.tabs, opts.story, opts.out), (5, "browser-idle-cost", "/x/out"))

    def test_the_catalog_lints_the_new_stories_clean(self):
        catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py").load_catalog()
        self.assertLessEqual(set(STORY_IDS), {s.id for s in catalog.stories})
        self.assertEqual([p for p in catalog.problems if any(i in p for i in STORY_IDS)], [])


class RecordTests(unittest.TestCase):
    def ingest(self, tmp, folder):
        db = store.Store(Path(tmp) / "lab.sqlite3")
        db.migrate()
        self.addCleanup(db.close)
        got = ingest.ingest_paths(db, [folder], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
        return db, got

    def test_fsync_write_all_round_trips_and_ingests(self):
        series = report.fsync_series({"fsync": [1.0, 2.5], "barrier": [0.2]})
        run = pr.Run(id="run63", started_at="2026-10-26T12:00:00.000000Z")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            report.write_all(out, series, BUILD, HOST, run=run, root=HERE.parent.parent)
            self.assertEqual(sorted(r.metric for r in pr.read_dir(out)), ["fsync.barrier.call", "fsync.fsync.call"])
            db, got = self.ingest(tmp, out)
            self.assertEqual(got.rejected, [])
            self.assertIn("fsync.fsync.call", db.run_metrics("run63/fsync"))

    def test_idle_budget_sessions_of_one_story_share_the_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            bundle = Path(tmp) / "cmux DEV ib063.app"
            bundle.mkdir()
            run = pr.Run(id="idle63", started_at="2026-10-26T12:00:00.000000Z")
            for session in ("light", "minimized"):
                app = bench_launch.BenchApp(str(bundle), out=str(out), teardown=False, perf_session="light", run=run)
                app.features, app._build, app._host = ({}, None, None), BUILD, HOST
                with redirect_stdout(io.StringIO()):
                    written = idle_budget.record_session(app, session, idle_entry(), {})
                self.assertFalse([v for v in written.values() if v.startswith("not recorded")], written)
            self.assertEqual({r.run.id for r in pr.read_dir(out)}, {"idle63"})
            db, got = self.ingest(tmp, out)
            self.assertEqual(got.rejected, [])
            metrics = db.run_metrics("idle63/idle-budget")
            self.assertIn("idle_budget.light.app.wakeups_per_s", metrics)
            self.assertIn("idle_budget.minimized.failed", metrics)


class BenchSourceTests(unittest.TestCase):
    """The four benches keep no private percentile, launch through BenchApp and print p99 (MQ1, MQ2, MQ3)."""

    BENCHES = ("browser-idle-cost-live.py", "idle-budget.py", "fsync-bench.py", "burst-bench.py")

    def test_no_private_stats_no_self_launch_and_p99(self):
        queues = load("perf_lab_queues", PERF_LAB / "queues.py")
        root = str(HERE.parent.parent)
        keys = {f"scripts/cmux-next/{name}" for name in self.BENCHES}
        for name, run in (("MQ1", queues.private_stats), ("MQ2", queues.self_launch), ("MQ3", queues.p95_without_p99)):
            self.assertEqual([i.key for i in run(root) if i.key in keys], [], name)


if __name__ == "__main__":
    unittest.main()
