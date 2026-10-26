#!/usr/bin/env python3
"""The palette and omnibar bench migration (p12-perf-process-053): palette-open-stages.py, omnibar-click-bench.py,
bench-command-pan.py and perceived-speed.py take their percentiles from perf_stats, report p99, write result-v1
through BenchApp.record, and each has a perf-lab story whose metric patterns match the names it writes.

Runs on any host (Linux included): no app, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_palette_omnibar_bench_migration.py
"""

from __future__ import annotations

import ast
import importlib.util
import json
import re
import statistics
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = HERE.parent / "perf-lab"
STORIES = PERF_LAB / "stories.d"
BENCHES = ("palette-open-stages.py", "omnibar-click-bench.py", "bench-command-pan.py", "perceived-speed.py")
VECTOR = [3.1, 4.7, 5.0, 5.2, 6.8, 7.3, 8.9, 9.4, 12.6, 30.2]


def load(name: str, path: Path, argv: list[str] | None = None):
    if name in sys.modules:
        return sys.modules[name]
    saved = sys.argv
    sys.argv = argv or [str(path)]
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    finally:
        sys.argv = saved
    return module


queues = load("perf_lab_queues", PERF_LAB / "queues.py")
perf_stats = load("perf_stats", PERF_LAB / "perf_stats.py")
perceived = load("perceived_speed", HERE / "perceived-speed.py")
# --dry-run: the module's argument check passes without --app and --out; nothing launches at import.
pan = load("bench_command_pan", HERE / "bench-command-pan.py", ["bench-command-pan.py", "--dry-run"])


class FakeLauncher:
    """BenchApp.record's signature; keeps every call and returns a result path."""

    def __init__(self):
        self.calls = []

    def record(self, story, metric, unit, samples, better, engine, target_ref=None):
        self.calls.append({"story": story, "metric": metric, "unit": unit, "samples": list(samples), "better": better,
                           "engine": engine})
        return f"/out/result-{len(self.calls)}.ndjson"


def story(name: str) -> dict:
    return json.loads((STORIES / f"{name}.json").read_text())


def constant(script: str, name: str) -> tuple:
    """The literal value of the top-level assignment `name = ...` in scripts/cmux-next/`script`."""
    for node in ast.parse((HERE / script).read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return tuple(ast.literal_eval(node.value))
    raise AssertionError(f"{script} has no top-level {name}")


def matches(doc: dict, metric: str, unit: str) -> bool:
    return any(re.fullmatch(m["name"], metric) and m["unit"] == unit for m in doc["metrics"])


class QueueTests(unittest.TestCase):
    def test_no_bench_is_in_mq1_mq2_or_mq3(self):
        paths = {f"scripts/cmux-next/{name}" for name in BENCHES}
        for queue in (queues.private_stats, queues.self_launch, queues.p95_without_p99):
            hits = sorted(item.key for item in queue(str(ROOT)) if item.key in paths)
            self.assertEqual(hits, [], f"{queue.__name__} still lists {hits}")

    def test_every_bench_loads_perf_stats_and_records(self):
        for name in BENCHES:
            text = (HERE / name).read_text()
            self.assertIn('load_by_path("perf_stats"', text, name)
            self.assertIn(".record(", text, name)


class PercentileTests(unittest.TestCase):
    def test_shared_percentiles_on_the_fixed_vector(self):
        # The old private helpers gave p50/p90/p95/p99 = 7.3/30.2/30.2/30.2 (palette, int(n*q)) and 6.8/12.6/30.2/30.2
        # (omnibar and command-pan, round(q*(n-1))); perf_stats interpolates between closest ranks.
        got = {q: round(perf_stats.pct(VECTOR, q), 3) for q in (0.5, 0.9, 0.95, 0.99)}
        self.assertEqual(got, {0.5: 7.05, 0.9: 14.36, 0.95: 22.28, 0.99: 28.616})

    def test_perceived_speed_frame_interval_is_still_the_median(self):
        gaps = [1 / 60, 1 / 60, 2 / 60, 1 / 60, 1 / 120, 3 / 60]
        self.assertAlmostEqual(perf_stats.pct(gaps, 0.5), statistics.median(gaps))

    def test_command_pan_spread_has_p99(self):
        self.assertEqual(pan.spread(VECTOR), {"n": 10, "p50_ms": 7.05, "p95_ms": 22.28, "p99_ms": 28.62, "max_ms": 30.2})
        self.assertIsNone(pan.spread([]))
        self.assertEqual(pan.pct([None, 1.0, 3.0], 0.5), 2.0)


def interval(at, ms, age="1.5", missed=False, target="layout"):
    return {"name": "key.scroll_frame", "at_s": at, "ms": ms, "missed": missed, "fields": {"age_ms": age},
            "end_fields": {"target": target}}


def pan_round(mode, index, window, intervals, missed=0):
    return {"session": "light", "mode": mode, "round": index, "window_s": window, "events": 3, "layout_took": 3,
            "delivered_to": {"LayoutRootView": 3}, "frames": len(intervals), "refresh_ms": 8.33, "p50_ms": 8.3,
            "p95_ms": 9.0, "p99_ms": 9.5, "max_ms": max(intervals), "missed": missed, "intervals_ms": intervals}


class CommandPanTests(unittest.TestCase):
    def setUp(self):
        pan.opts.story = "command-pan"
        pan.opts.target = "terminal"

    def tearDown(self):
        pan.opts.story = None

    def test_layout_scrolls_keeps_the_rounds_layout_events(self):
        runs = [pan_round("command", 0, (10.0, 11.0), [8.3])]
        signposts = [interval(10.2, 2.0), interval(10.4, 3.0, missed=True), interval(10.5, 4.0, target="pane"),
                     interval(12.0, 5.0), interval(10.6, 6.0, age="-1")]
        samples, missed = pan.layout_scrolls(signposts, runs)
        self.assertEqual(samples, {"scroll_frame": [2.0, 6.0], "input_to_frame": [3.5]})
        self.assertEqual(missed, 1)

    def test_summarize_keeps_the_report_keys_and_records_each_series(self):
        app, report = FakeLauncher(), {"runs": [], "summary": [], "problems": [], "results": {}}
        runs = [pan_round("command", 0, (10.0, 11.0), [8.3, 8.4, 16.7], missed=1),
                pan_round("command", 2, (20.0, 21.0), [8.3, 8.3])]
        row = pan.summarize(app, "light", "command", runs, report, [interval(10.2, 2.0), interval(20.5, 3.0)])
        old_keys = {"session", "mode", "target", "rounds", "refresh_ms", "missed_total", "frames_total", "p95_ms",
                    "max_ms", "events_to_layout", "events", "scroll_frame", "input_to_frame", "missed_commits"}
        self.assertLessEqual(old_keys, set(row))
        self.assertEqual(row["p99_ms"], 9.5)
        self.assertEqual(row["intervals"]["n"], 5)
        self.assertEqual(report["problems"], [])
        recorded = {c["metric"]: c for c in app.calls}
        self.assertEqual(sorted(recorded), ["command.frame_interval", "command.input_to_frame", "command.missed",
                                            "command.scroll_frame"])
        self.assertEqual(recorded["command.frame_interval"]["samples"], [8.3, 8.4, 16.7, 8.3, 8.3])
        self.assertEqual(recorded["command.missed"], {**recorded["command.missed"], "unit": "count", "samples": [1, 0]})
        self.assertEqual({c["engine"] for c in app.calls}, {"none"})
        for name in ("command-pan", "command-pan-stress"):
            doc = story(name)
            for call in app.calls:
                self.assertTrue(matches(doc, call["metric"], call["unit"]), f"{name}: {call['metric']}")


class PerceivedSpeedTests(unittest.TestCase):
    def run_folder(self, out: Path, name: str, surface: str, metrics: dict):
        folder = out / name
        folder.mkdir()
        (folder / "meta.json").write_text(json.dumps({"surface": surface, "trigger": 0.4}))
        (folder / "metrics.json").write_text(json.dumps(metrics))

    def test_samples_and_records_skip_runs_that_opened_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            opened = {"first_frame_ms": 16.0, "settle_ms": 120.0, "diff_area": 0.01, "shift": 0.2, "repaints": 3,
                      "dropped": 0}
            self.run_folder(out, "palette-1", "palette", opened)
            self.run_folder(out, "palette-2", "palette", {**opened, "first_frame_ms": 33.0, "settle_ms": None})
            self.run_folder(out, "palette-3", "palette", {"first_frame_ms": None, "settle_ms": None, "diff_area": 0.0,
                                                          "shift": 0.0, "repaints": 0, "dropped": 0})
            samples = perceived.surface_samples(str(out))
            self.assertEqual(samples["palette"]["first_frame_ms"], [16.0, 33.0])
            self.assertEqual(samples["palette"]["settle_ms"], [120.0])
            launcher = FakeLauncher()
            written = perceived.record_results(launcher, "perceived-speed", "chromium", str(out))
        self.assertEqual(sorted(written), sorted(f"palette.{m}" for m, _ in perceived.RESULT_METRICS))
        units = {c["metric"]: c["unit"] for c in launcher.calls}
        self.assertEqual(units["palette.diff_area"], "ratio")
        self.assertEqual(units["palette.dropped"], "count")

    def test_story_matches_every_name_the_run_writes(self):
        doc = story("perceived-speed")
        for surface in perceived.SURFACES:
            for metric, unit in perceived.RESULT_METRICS:
                self.assertTrue(matches(doc, f"{surface}.{metric}", unit), f"{surface}.{metric}")


class StoryTests(unittest.TestCase):
    def test_palette_and_omnibar_stories_match_the_bench_names(self):
        # palette-open-stages.py: `<slug(surface)>.<slug(key)>.<stage>`; omnibar-click-bench.py: `<phase>.<value>`.
        # Both scripts run at import, so their name lists are read from their syntax trees.
        stages = constant("palette-open-stages.py", "STAGES")
        for name, surfaces in (("palette-open", ("terminal", "chromium", "chromium-page-window", "markdown", "home")),
                               ("palette-open-webkit", ("terminal", "webkit", "markdown", "home"))):
            doc = story(name)
            for surface in surfaces:
                for key in ("cmd-shift-p", "cmd-p"):
                    for stage in stages:
                        self.assertTrue(matches(doc, f"{surface}.{key}.{stage}", "ms"), f"{name}: {surface}.{key}.{stage}")
        values = constant("omnibar-click-bench.py", "RESULT_KEYS") + constant("omnibar-click-bench.py", "TIMING_KEYS")
        for name in ("omnibar-click", "omnibar-click-webkit"):
            doc = story(name)
            for phase in ("idle", "load"):
                for value in values:
                    self.assertTrue(matches(doc, f"{phase}.{value}", "ms"), f"{name}: {phase}.{value}")

    def test_story_commands_pass_their_own_story_id(self):
        for name in ("palette-open", "palette-open-webkit", "omnibar-click", "omnibar-click-webkit", "command-pan",
                     "command-pan-stress", "perceived-speed"):
            command = story(name)["command"]
            self.assertEqual(command[command.index("--story") + 1], name)


if __name__ == "__main__":
    unittest.main()
