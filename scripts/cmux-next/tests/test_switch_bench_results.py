#!/usr/bin/env python3
"""The switch benches' result-v1 series (p12-perf-process-052).

1. activation-perf.py: every phase's rows become activation.<phase>.<series> with every raw sample (total is round
   trip + drain, resyncs is a count, a row without a number is left out), written by a real BenchApp.record through
   the real perf_result.py; its App launches through BenchApp with the activation env.
2. bench_tab_switch.py: a raw `debug.frames` stop reply splits into the report's summary (no per-frame arrays) and
   the recorded samples; each scenario's series becomes switch_repeat.<scenario>.<series>; an empty series is
   reported as not recorded and writes nothing.
3. The four benches compute percentiles with perf_stats.pct and define no private one; tab-switch-matrix.py and
   tab-switch-stages.py also report p99.
4. Each switch story in stories.d names a metric pattern that matches what its bench writes.

Linux and macOS (off macOS, bench_tab_switch.py loads with a stand-in for bench_idle, which needs libproc); no app,
no GUI session.

    python3 -m unittest scripts/cmux-next/tests/test_switch_bench_results.py
"""

from __future__ import annotations

import ast
import json
import os
import re
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_launch as bl  # noqa: E402
from test_bench_launch import FEATURES, HOST, record_bundle, result_lines  # noqa: E402

activation = bl.load_by_path("activation_perf", str(HERE / "activation-perf.py"))


def load_repeat():
    """bench_tab_switch.py; off macOS with a stand-in for bench_idle (it loads libproc at import), removed again."""
    if sys.platform == "darwin":
        return bl.load_by_path("bench_tab_switch", str(HERE / "bench_tab_switch.py"))
    stub = types.ModuleType("bench_idle")
    stub.Client = stub.usage = stub.wait_for_socket = None
    had = sys.modules.get("bench_idle")
    sys.modules["bench_idle"] = stub
    try:
        return bl.load_by_path("bench_tab_switch", str(HERE / "bench_tab_switch.py"))
    finally:
        if had is None:
            del sys.modules["bench_idle"]
        else:
            sys.modules["bench_idle"] = had


repeat = load_repeat()
perf_stats = bl.load_by_path("perf_stats", str(ROOT / "scripts/perf-lab/perf_stats.py"))
BENCHES = ("tab-switch-matrix.py", "tab-switch-stages.py", "activation-perf.py", "bench_tab_switch.py")


class RecordingCase(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="switch-bench-")
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def bench(self, tag):
        bench = bl.BenchApp(record_bundle(self.folder, tag, commit="c" * 40), out=self.out, teardown=False,
                            host=lambda: dict(HOST))
        bench.features = FEATURES  # what launch() read
        return bench

    def by_metric(self):
        return {line["metric"]: line for line in result_lines(self.out)}


def activation_rows(observers, round_trip, drain, resyncs):
    return [{"observers_ms": o, "round_trip_ms": r, "drain_ms": d, "resyncs": c, "error": None}
            for o, r, d, c in zip(observers, round_trip, drain, resyncs)]


class ActivationTests(RecordingCase):
    def test_every_phase_records_its_raw_samples(self):
        report = {"light_rows": activation_rows([0.4, 0.6], [1.0, 2.0], [0.5, 0.25], [3, 4]),
                  "heavy_app_only_rows": activation_rows([2.0, None], [5.0, 6.0], [1.0, 1.5], [40, None]),
                  "rows": activation_rows([3.0, 4.5, 6.0], [7.0, 8.0, 9.0], [2.0, 2.5, 3.0], [10, 12, 64])}
        written = activation.record(self.bench("act"), "activation", report)
        self.assertEqual(len(written), 15)
        self.assertFalse([m for m, path in written.items() if path.startswith("not recorded")], written)
        lines = self.by_metric()
        self.assertEqual(lines["activation.light.observers"]["samples"], [0.4, 0.6])
        self.assertEqual(lines["activation.light.total"]["samples"], [1.5, 2.25])
        self.assertEqual(lines["activation.heavy_app_only.observers"]["samples"], [2.0], "a row without a number is left out")
        self.assertEqual(lines["activation.heavy.resyncs"]["samples"], [10, 12, 64])
        self.assertEqual(lines["activation.heavy.resyncs"]["unit"], "count")
        self.assertEqual(lines["activation.heavy.drain"]["unit"], "ms")
        self.assertEqual(lines["activation.light.round_trip"]["engine"], "none")
        self.assertEqual(lines["activation.heavy.round_trip"]["engine"], "chromium")
        self.assertEqual({line["story"] for line in lines.values()}, {"activation"})
        self.assertEqual({line["better"] for line in lines.values()}, {"lower"})

    def test_a_phase_without_rows_is_not_recorded(self):
        written = activation.record(self.bench("act0"), "activation", {"rows": activation_rows([1.0], [2.0], [3.0], [4])})
        self.assertEqual(written["activation.light.observers"], "not recorded: no samples")
        self.assertNotIn("activation.light.observers", self.by_metric())
        self.assertIn("activation.heavy.observers", self.by_metric())

    def test_summary_adds_p99_from_perf_stats_and_keeps_its_keys(self):
        rows = activation_rows([float(v) for v in range(1, 21)], [1.0] * 20, [0.5] * 20, [2] * 20)
        summary = activation.summarize(rows, {"count": 0})
        self.assertEqual(summary["observers_ms"]["p95"], perf_stats.pct(range(1, 21), 0.95))
        self.assertEqual(summary["observers_ms"]["p99"], perf_stats.pct(range(1, 21), 0.99))
        self.assertEqual(set(summary["total_ms"]), {"p50", "p95", "p99"})
        self.assertEqual(set(summary["observers_ms"]), {"p50", "p95", "p99", "max"})

    def test_app_launches_through_bench_app_with_the_activation_env(self):
        app = activation.App(record_bundle(self.folder, "actapp", commit="c" * 40), self.out, 30)
        env = app.bench.environment()
        self.assertEqual(env["CMUX_NEXT_HANG_THRESHOLD_MS"], "30")
        self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_SCREEN"], "last")
        self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_FRAME"], "40,40,1440,900")
        self.assertEqual(env["CMUX_NEXT_NO_ACTIVATE"], "1")
        self.assertEqual(env["CMUX_NEXT_CONFIG_FILE"], app.config)
        self.assertEqual(json.load(open(app.config))["appearance"], {"backgroundOpacity": 1})
        self.assertEqual(app.bench.log_path, os.path.join(self.out, "app.log"))
        self.assertIsNone(app.process, "no process before launch()")
        self.assertEqual(app.socket, app.bench.socket)
        self.assertEqual(app.tag, "actapp")


class RepeatTests(RecordingCase):
    def test_raw_frames_split_into_the_summary_and_the_samples(self):
        reply = {"p50_ms": 8.3, "p99_ms": 16.7, "missed": 1, "intervals_ms": [8.3, 8.4, 16.7], "main_ms": [1.0, 2.0],
                 "view_layouts_per_frame": [0, 1], "window_layouts_per_frame": [0, 0], "render_draws_per_frame": [1]}
        summary, raw = repeat.split_raw_frames(reply)
        self.assertEqual(summary, {"p50_ms": 8.3, "p99_ms": 16.7, "missed": 1})
        self.assertEqual(raw, {"intervals_ms": [8.3, 8.4, 16.7], "main_ms": [1.0, 2.0]})
        self.assertEqual(repeat.split_raw_frames({"p50_ms": 1.0})[1], {"intervals_ms": [], "main_ms": []})

    def test_each_scenario_records_its_series(self):
        samples = {"tab-repeat": {"frame_interval": [8.3, 8.4], "main_busy": [1.5, 2.5], "stalls": [0]},
                   "workspace-repeat": {"frame_interval": [], "main_busy": [3.0], "stalls": [2]}}
        written = repeat.record(self.bench("rep"), "tab-switch-repeat", samples)
        self.assertEqual(written["switch_repeat.workspace-repeat.frame_interval"], "not recorded: no samples")
        lines = self.by_metric()
        self.assertEqual(sorted(lines), ["switch_repeat.tab-repeat.frame_interval", "switch_repeat.tab-repeat.main_busy",
                                         "switch_repeat.tab-repeat.stalls", "switch_repeat.workspace-repeat.main_busy",
                                         "switch_repeat.workspace-repeat.stalls"])
        self.assertEqual(lines["switch_repeat.tab-repeat.frame_interval"]["samples"], [8.3, 8.4])
        self.assertEqual(lines["switch_repeat.workspace-repeat.stalls"]["unit"], "count")
        self.assertEqual(lines["switch_repeat.tab-repeat.main_busy"]["engine"], "chromium")


class SharedStatsTests(unittest.TestCase):
    def test_no_bench_defines_a_private_percentile(self):
        for name in BENCHES:
            tree = ast.parse((HERE / name).read_text())
            private = [node.name for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)
                       and re.fullmatch(r"_*(pct|percentiles?|quantiles?|p\d{2,3}|med|median)", node.name)]
            self.assertEqual(private, [], name)

    def test_the_benches_take_pct_from_perf_stats_and_report_p99(self):
        for name in ("tab-switch-matrix.py", "tab-switch-stages.py", "activation-perf.py"):
            text = (HERE / name).read_text()
            self.assertIn('load_by_path("perf_stats"', text, name)
            self.assertIn("pct = perf_stats.pct", text, name)
            self.assertIn("p99", text, name)

    def test_shared_pct_on_the_commit_vector(self):
        """The values the commit message quotes for the old nearest-rank pct and perf_stats.pct."""
        vector = [3.1, 4.7, 5.0, 5.2, 6.8, 7.4, 8.0, 9.9, 12.5, 30.2]
        got = {q: round(perf_stats.pct(vector, q), 3) for q in (0.5, 0.9, 0.95, 0.99)}
        self.assertEqual(got, {0.5: 7.1, 0.9: 14.27, 0.95: 22.235, 0.99: 28.607})


class StoryTests(unittest.TestCase):
    def story(self, story_id):
        return json.loads((ROOT / "scripts/perf-lab/stories.d" / f"{story_id}.json").read_text())

    def assert_claims(self, story_id, metrics):
        patterns = [m["name"] for m in self.story(story_id)["metrics"]]
        for metric in metrics:
            self.assertTrue(any(re.fullmatch(p, metric) for p in patterns), f"{story_id} does not match {metric}")

    def test_switch_stories_match_their_benches_metrics(self):
        self.assert_claims("tab-switch", ["tab_switch.webkit.10.e2e", "tab_switch.webkit.10.apply",
                                          "tab_switch.webkit.10.click.commit", "tab_switch.webkit.10.content_frame"])
        self.assert_claims("tab-switch-stages", ["tab_switch_stages.ctrl_tab.chromium.apply",
                                                 "tab_switch_stages.click.terminal.e2e", "tab_switch_stages.ctrl_shift_tab.confirm"])
        self.assert_claims("activation", [m for m, *_ in activation.phase_series({"rows": []})])
        self.assert_claims("tab-switch-repeat", ["switch_repeat.tab-mixed.frame_interval", "switch_repeat.workspace-repeat.stalls"])
        for story_id in ("tab-switch-stages", "activation", "tab-switch-repeat"):
            self.assertEqual(self.story(story_id)["owner"], "PL-switch")


if __name__ == "__main__":
    unittest.main()
