#!/usr/bin/env python3
"""The palette and omnibar bench migration (p12-perf-process-053): palette-open-stages.py, omnibar-click-bench.py,
bench-command-pan.py and perceived-speed.py take their percentiles from perf_stats, report p99, write result-v1
through BenchApp.record, and each has a perf-lab story whose metric patterns match the names it writes.

Runs on any host (Linux included): no app, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_palette_omnibar_bench_migration.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import statistics
import subprocess
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
# Both parse their arguments and launch only under __main__.
palette = load("palette_open_stages", HERE / "palette-open-stages.py")
omnibar = load("omnibar_click_bench", HERE / "omnibar-click-bench.py")
bench_story = load("bench_story", HERE / "bench_story.py")


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
            self.assertIn('"perf_stats.py")', text, name)
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
        stages = palette.STAGES
        for name, surfaces in (("palette-open", ("terminal", "chromium", "chromium-page-window", "markdown", "home")),
                               ("palette-open-webkit", ("terminal", "webkit", "markdown", "home"))):
            doc = story(name)
            for surface in surfaces:
                for key in ("cmd-shift-p", "cmd-p"):
                    for stage in stages:
                        self.assertTrue(matches(doc, f"{surface}.{key}.{stage}", "ms"), f"{name}: {surface}.{key}.{stage}")
        values = omnibar.RESULT_KEYS + omnibar.TIMING_KEYS
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

    def test_story_commands_name_their_story_engine(self):
        for name in ("palette-open", "palette-open-webkit", "omnibar-click", "omnibar-click-webkit"):
            doc = story(name)
            command = doc["command"]
            self.assertEqual(command[command.index("--engines") + 1], doc["engine"], name)
            self.assertIsNone(bench_story.story_problem(name, doc["engine"]), name)


def palette_open(key, panel=None):
    return {"input": 0.4, "model": 2.0, "panel": panel, "present": 1.0, "commit": 3.0, "key": key, "rpc": 9.0,
            "created_panel": False, "stall_max_ms": None, "count250": 0, "stalls": []}


class PaletteTests(unittest.TestCase):
    def test_summarize_keeps_p50_p90_max_and_adds_p95_p99(self):
        line = palette.summarize("terminal Cmd-P", [palette_open(v) for v in VECTOR])
        self.assertEqual(line["key"], {"p50": 7.05, "p90": 14.36, "p95": 22.28, "p99": 28.62, "max": 30.2})
        self.assertEqual(sorted(line), sorted(set(palette.STAGES) - {"panel"}))  # no open reported a panel stage

    def test_record_results_writes_one_series_per_surface_key_and_stage(self):
        launcher = FakeLauncher()
        timed = [("terminal", "Cmd-Shift-P", [palette_open(5.0), palette_open(6.0)]),
                 ("chromium page window", "Cmd-P", [palette_open(7.0, panel=1.5), palette_open(8.0)])]
        written = palette.record_results(launcher, "palette-open", "chromium", timed)
        calls = {c["metric"]: c for c in launcher.calls}
        self.assertEqual(sorted(written), sorted(calls))
        self.assertEqual(calls["terminal.cmd-shift-p.key"]["samples"], [5.0, 6.0])
        self.assertEqual(calls["chromium-page-window.cmd-p.key"]["samples"], [7.0, 8.0])
        self.assertEqual(calls["chromium-page-window.cmd-p.panel"]["samples"], [1.5])  # only one open reported it
        self.assertNotIn("terminal.cmd-shift-p.panel", calls)
        self.assertEqual({(c["story"], c["engine"], c["unit"], c["better"]) for c in launcher.calls},
                         {("palette-open", "chromium", "ms", "lower")})
        for call in launcher.calls:
            self.assertTrue(matches(story("palette-open"), call["metric"], call["unit"]), call["metric"])


def omnibar_click(phase, engine, focused):
    return {"phase": phase, "engine_asked": engine, "attached_ms": focused - 4, "selected_ms": focused - 2,
            "focused_ms": focused, "dispatch_to_attached_ms": focused - 5, "dispatch_to_selected_ms": focused - 3,
            "dispatch_to_focused_ms": focused - 1, "press_ms": 1.2, "attached_frames_after_press": 1,
            "selected_frames_after_press": 1, "focused_frames_after_press": 2,
            "spans": [{"name": "app.sendEvent.down", "ms": 0.8, "at": 0.1}]}


class OmnibarTests(unittest.TestCase):
    def test_summary_keeps_the_old_keys_and_adds_p99(self):
        missed = {**omnibar_click("idle", "webkit", 50.0), "focused_ms": None}
        rows = [omnibar_click("idle", "webkit", v + 10) for v in VECTOR] + [missed]
        timings = {("idle", "webkit"): [{"input_ms": v, "key_to_frame_ms": v + 1} for v in VECTOR]}
        out = omnibar.summary(rows, ["webkit"], timings)
        self.assertEqual(sorted(out), ["idle/webkit"])
        row = out["idle/webkit"]
        old = {"n", "missed", "attached_p50", "attached_p95", "selected_p50", "selected_p95", "focused_p50",
               "focused_p95", "focused_max", "mouse_down_dispatch_p50", "mouse_down_dispatch_max", "input_ms_n",
               "key_to_frame_ms_n"}
        for key in ("press_ms", "dispatch_to_attached_ms", "dispatch_to_selected_ms", "dispatch_to_focused_ms",
                    "attached_frames_after_press", "selected_frames_after_press", "focused_frames_after_press",
                    "input_ms", "key_to_frame_ms"):
            old |= {f"{key}_p50", f"{key}_p95", f"{key}_max"}
        self.assertLessEqual(old, set(row))
        self.assertEqual((row["n"], row["missed"], row["input_ms_n"]), (11, 1, 10))
        self.assertAlmostEqual(row["focused_p99"], 38.616)  # the missed run gives no sample
        self.assertAlmostEqual(row["input_ms_p99"], 28.616)
        self.assertEqual(row["mouse_down_dispatch_p99"], 0.8)

    def test_record_results_writes_one_series_per_phase_and_value(self):
        launcher = FakeLauncher()
        rows = [omnibar_click("idle", "chromium", 12.0), {**omnibar_click("idle", "chromium", 14.0), "focused_ms": None},
                omnibar_click("load", "chromium", 30.0)]
        timings = {("idle", "chromium"): [{"input_ms": 0.5, "key_to_frame_ms": 9.0}, {"input_ms": None}]}
        written = omnibar.record_results(launcher, "omnibar-click", "chromium", rows, timings)
        calls = {c["metric"]: c for c in launcher.calls}
        self.assertEqual(sorted(written), sorted(calls))
        self.assertEqual(calls["idle.focused_ms"]["samples"], [12.0])
        self.assertEqual(calls["idle.attached_ms"]["samples"], [8.0, 10.0])
        self.assertEqual(calls["load.focused_ms"]["samples"], [30.0])
        self.assertEqual(calls["idle.input_ms"]["samples"], [0.5])
        self.assertNotIn("load.input_ms", calls)  # no debug.timings click of that phase
        self.assertEqual({(c["story"], c["engine"]) for c in launcher.calls}, {("omnibar-click", "chromium")})
        for call in launcher.calls:
            self.assertTrue(matches(story("omnibar-click"), call["metric"], call["unit"]), call["metric"])


def run_script(script, *args, cwd=None):
    return subprocess.run([sys.executable, "-I", str(script), *args], capture_output=True, text=True, timeout=60,
                          cwd=cwd)


class StoryEngineTests(unittest.TestCase):
    def test_story_problem_needs_the_story_of_the_runs_engine(self):
        self.assertIsNone(bench_story.story_problem("palette-open", "chromium"))
        self.assertIsNone(bench_story.story_problem("omnibar-click-webkit", "webkit"))
        self.assertIsNone(bench_story.story_problem("command-pan", "none"))
        self.assertIn("'chromium'", bench_story.story_problem("palette-open", "webkit"))
        self.assertIn("not in", bench_story.story_problem("no-such-story", "webkit"))
        self.assertIn("not a story id", bench_story.story_problem("../stories.d/palette-open", "chromium"))

    def test_benches_refuse_a_story_of_another_engine_before_launching(self):
        app = ["--tag", "t", "--app", "/nonexistent/cmux DEV t.app"]
        for script, chromium in (("palette-open-stages.py", "palette-open"), ("omnibar-click-bench.py", "omnibar-click")):
            for args, expect in ((["--engines", "webkit", "--story", chromium], "has engine 'chromium'"),
                                 (["--story", chromium], "one engine"),
                                 (["--engines", "safari"], "--engines takes")):
                with self.subTest(script=script, args=args):
                    done = run_script(HERE / script, *app, *args)
                    self.assertEqual(done.returncode, 2, done.stderr)
                    self.assertIn(expect, done.stderr)
        done = run_script(HERE / "bench-command-pan.py", "--dry-run", "--sessions", "light", "--target", "chromium",
                          "--story", "command-pan")
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("has engine 'none'", done.stderr)


class PerceivedSpeedAloneTests(unittest.TestCase):
    """perceived-speed-slot.sh copies perceived-speed.py, perf_stats.py and pinpoint_thresholds.py alone onto a
    capture-slot host and runs find-socket, `run --socket` and analyze there."""

    def test_socket_paths_import_nothing_of_the_repo(self):
        with tempfile.TemporaryDirectory() as folder:
            script = shutil.copy(HERE / "perceived-speed.py", folder)
            found = run_script(script, "find-socket", "com.cmuxterm.app.debug.x", "--since", "0", folder, cwd=folder)
            self.assertEqual((found.returncode, found.stdout, found.stderr), (1, "", ""))
            for command in ("analyze", "run", "table"):
                done = run_script(script, command, "--help", cwd=folder)
                self.assertEqual(done.returncode, 0, done.stderr)

    def test_table_uses_the_perf_stats_copied_next_to_it(self):
        with tempfile.TemporaryDirectory() as folder:
            script = shutil.copy(HERE / "perceived-speed.py", folder)
            run = Path(folder) / "out" / "palette-1"
            run.mkdir(parents=True)
            (run / "meta.json").write_text(json.dumps({"surface": "palette", "trigger": 0.4}))
            (run / "metrics.json").write_text(json.dumps({"first_frame_ms": 16.0, "settle_ms": 120.0, "diff_area": 0.01,
                                                          "shift": 0.2, "repaints": 3, "dropped": 0}))
            missing = run_script(script, "table", str(run.parent), cwd=folder)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("no perf_stats.py", missing.stderr)
            for name in ("perf_stats.py", "pinpoint_thresholds.py"):
                shutil.copy(PERF_LAB / name, folder)
            done = run_script(script, "table", str(run.parent), cwd=folder)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn("| palette | 1 | 1.00% | 0.200 | 16 | 120 |", done.stdout)

    def test_slot_script_copies_what_the_script_loads(self):
        text = (HERE / "perceived-speed-slot.sh").read_text()
        copy = next(line for line in text.splitlines() if line.startswith("scp ") and "perceived-speed.py" in line)
        for name in ("perceived-speed.py", "perf-lab/perf_stats.py", "perf-lab/pinpoint_thresholds.py"):
            self.assertIn(name, copy)


if __name__ == "__main__":
    unittest.main()
