#!/usr/bin/env python3
"""The frame-pacing harness as lab stories (p12-perf-process-209).

scripts/ci/frame-pacing/bench.sh --mode instant|golden|fling --app PATH --tag TAG --out DIR runs one story of
scripts/perf-lab/stories.d/frame_pacing.*.json against a prebuilt app; golden.py, browser_resize.py and summarize.py
take their percentiles from perf_stats and give result-v1 rows. MQ1 lists no frame-pacing file, and the Cmd-T and
Cmd-N rows of the new-surface-frames target are claimed by these stories too.

  python3 -m unittest scripts/perf-lab/tests/test_frame_pacing_stories.py
"""
from __future__ import annotations

import importlib.util
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = HERE.parents[2]
BENCH_DIR = ROOT / "scripts" / "ci" / "frame-pacing"
STORIES = ("frame_pacing.instant", "frame_pacing.golden", "frame_pacing.fling")
REFRESH = 1000 / 120
# A fixed vector for the percentile change (R8).
VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]

sys.path.insert(0, str(BENCH_DIR))


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


catalog = load("perf_lab_catalog_for_frame_pacing", LAB / "catalog.py")
queues = load("perf_lab_queues_for_frame_pacing", LAB / "queues.py")
run_story = load("perf_lab_run_story_for_frame_pacing", LAB / "run_story.py")
perf_stats = load("perf_stats", LAB / "perf_stats.py")
golden = load("golden", BENCH_DIR / "golden.py")
summarize = load("summarize", BENCH_DIR / "summarize.py")
browser_resize = load("browser_resize", BENCH_DIR / "browser_resize.py")
lab_story = load("frame_pacing_lab_story", BENCH_DIR / "lab_story.py")
lab_rows = sys.modules["lab_rows"]


def old_percentile(values, p):
    """golden.py's and browser_resize.py's percentile before this change (nearest rank, Python's round)."""
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))] if ordered else 0.0


def eased(start, end, frames, rest=6):
    moving = [start + (end - start) * (1 - math.cos(math.pi * (k + 1) / frames)) / 2 for k in range(frames)]
    return [start] * rest + moving + [end] * rest


def tabs_trace(widths, *, spare, gap_at=None):
    samples, t = [], 0.0
    for index, width in enumerate(widths):
        tabs = [["tab-a", 0, 180, 1], ["tab-b", 180, 180, 1]]
        if width > 0:
            tabs = [["tab-a", 0, 180, 1], ["new-tab", 180, width, 1], ["tab-b", 180 + width, 180, 1]]
        samples.append({"t": round(t, 2), "tabs": tabs, "strip": [413, 413]})
        t += REFRESH * (3 if index == gap_at else 1)
    return {"refresh_ms": REFRESH, "samples": samples, "opening": {"spare": spare}, "looping": []}


def sidebar_trace(widths):
    return {"refresh_ms": REFRESH, "samples": [{"t": i * REFRESH, "sidebar": [w, w]} for i, w in enumerate(widths)],
            "looping": []}


def write_golden_run(out: Path, *, cold_gap_at=None) -> None:
    """The files `golden.py drive` writes for a run as designed; the cold Cmd-T's trace misses two frames at
    `cold_gap_at` (one interval of three refresh periods)."""
    out.mkdir(parents=True, exist_ok=True)

    def save(name, data):
        (out / f"{name}.json").write_text(json.dumps(data))

    save("new_tab_cold", tabs_trace(eased(0, 200, 0, rest=14), spare=False, gap_at=cold_gap_at))
    save("new_tab_warm", {**tabs_trace(eased(0, 200, 0, rest=14), spare=True), "spare_ready": True})
    save("sidebar_collapse", sidebar_trace(eased(260, 0, 28)))
    save("sidebar_expand", sidebar_trace(eased(0, 260, 28)))
    save("reduce_new_tab", {**tabs_trace(eased(0, 200, 0, rest=14), spare=False), "reduce_motion": True})
    save("reduce_sidebar_collapse", {**sidebar_trace(eased(260, 0, 0, rest=14)), "reduce_motion": True})
    save("reduce_sidebar_expand", {**sidebar_trace(eased(0, 260, 0, rest=14)), "reduce_motion": True})
    tops = [1000 + 2.5 * i for i in range(360)]
    save("transcript_follow", {"scroll_top": tops, "scroll_height": [top + 600 for top in tops],
                               "frame_ms": [i * REFRESH for i in range(360)]})
    drags = []
    for start, end in ((1100, 1400), (1400, 1100)):
        drags.append({"samples": [{"t": i * REFRESH, "window": [w, 720], "strip": [w - 300]}
                                  for i, w in enumerate(eased(start, end, 90))]})
    save("window_resize", {"drags": drags})


def resize_drag(lag: int) -> dict:
    """A browser resize drag whose host follows the window at once and whose page window trails it by `lag`."""
    widths = eased(1000, 1300, 30)
    samples = []
    for i, w in enumerate(widths):
        page_w = widths[max(0, i - lag)]
        samples.append({"t": i * REFRESH, "window": [w + 200, 720], "page": [[w, 600, page_w, 600, 1000 + i * REFRESH]]})
    return {"samples": samples, "page_frames": [[1000 + i * REFRESH, w] for i, w in enumerate(widths)]}


class Story:
    def story(self, mode):
        return lab_story.StoryMetrics(LAB / "stories.d" / f"frame_pacing.{mode}.json")


class CatalogTests(unittest.TestCase):
    def test_the_three_stories_lint_clean_and_take_the_runner_flags(self):
        cat = catalog.load_catalog(ROOT)
        mine = [p for p in cat.problems if "frame_pacing" in p]
        self.assertEqual(mine, [])
        stories = {s.id: s for s in cat.stories}
        for name in STORIES:
            self.assertIn(name, stories)
            self.assertEqual(stories[name].command[0], "scripts/ci/frame-pacing/bench.sh")
            self.assertEqual(run_story.contract_problems(stories[name], str(ROOT)), [])
        self.assertEqual({stories[n].tier for n in STORIES}, {"T1"})

    def test_mq1_lists_no_frame_pacing_file(self):
        found = [item.key for item in queues.private_stats(str(ROOT))]
        self.assertEqual([key for key in found if key.startswith("scripts/ci/frame-pacing/")], [])

    def test_the_new_surface_target_rows_for_cmd_t_and_cmd_n_are_claimed_by_frame_pacing_too(self):
        claims = catalog.claimed_checks(catalog.load_catalog(ROOT))
        self.assertIn("frame_pacing.instant", claims[("new-surface-frames", r"cmd_t\.[^.]+\.dropped")])
        self.assertIn("frame_pacing.instant", claims[("new-surface-frames", r"cmd_n\.[^.]+\.dropped")])
        self.assertIn("frame_pacing.golden", claims[("new-surface-frames", r"cmd_t\.[^.]+\.dropped")])

    def test_every_threshold_reference_resolves_to_the_number_the_judge_uses(self):
        cat = catalog.load_catalog(ROOT)
        refs = {m.name: m.target_ref for s in cat.stories if s.id in STORIES for m in s.metrics if m.target_ref}
        self.assertEqual(catalog.resolve_ref(ROOT, refs[r"golden\.sidebar_collapse\.intermediate"]),
                         golden.THRESHOLDS["sidebar_collapse"]["min_intermediate"])
        self.assertEqual(catalog.resolve_ref(ROOT, refs[r"fling\.full\.frame_interval"]), summarize.P50_LIMIT_MS["1"])
        self.assertEqual(catalog.resolve_ref(ROOT, refs[r"fling\.(capped|full)\.dropped_fraction"]),
                         summarize.DROPPED_LIMIT)


class PercentileTests(unittest.TestCase):
    def test_the_judges_use_perf_stats(self):
        self.assertIs(lab_rows.perf_stats, sys.modules["perf_stats"])
        for module in (golden, browser_resize):
            self.assertFalse(hasattr(module, "percentile") or hasattr(module, "_percentile"), module.__name__)
        intervals = [REFRESH] * 19 + [3 * REFRESH]
        stats, _ = golden.frame_budget(intervals, REFRESH, golden.THRESHOLDS["sidebar_collapse"])
        self.assertAlmostEqual(stats["p95_ms"], round(perf_stats.pct(intervals, 0.95), 2))

    def test_old_and_new_values_on_the_fixed_vector(self):
        # Nearest rank (old) against linear interpolation (perf_stats.pct): p95 20.1 -> 16.635, p50 6.0 -> 6.95.
        self.assertEqual(old_percentile(VECTOR, 0.95), 20.1)
        self.assertAlmostEqual(perf_stats.pct(VECTOR, 0.95), 16.635)
        self.assertEqual(old_percentile(VECTOR, 0.5), 6.0)
        self.assertAlmostEqual(perf_stats.pct(VECTOR, 0.5), 6.95)

    def test_summarize_medians_match_the_old_statistics_median(self):
        import statistics
        self.assertAlmostEqual(perf_stats.pct(VECTOR, 0.5), statistics.median(VECTOR))
        self.assertAlmostEqual(perf_stats.pct(VECTOR[:9], 0.5), statistics.median(VECTOR[:9]))


class GoldenRowTests(unittest.TestCase, Story):
    def test_a_run_as_designed_gives_rows_the_story_lists(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            write_golden_run(out)
            verdicts = golden.judge(out)
            rows = golden.rows(out, verdicts)
        story = self.story("golden")
        for row in rows:
            story.spec(row)  # raises StoryMismatch for a row the story does not list
        by = {row.metric: row for row in rows}
        self.assertEqual(by["golden.sidebar_collapse.pass"].samples, (1.0,))
        self.assertGreaterEqual(by["golden.sidebar_collapse.intermediate"].samples[0], 8)
        self.assertTrue(all(abs(v - 1.0) < 0.01 for v in by["golden.sidebar_collapse.frame_periods"].samples))
        self.assertEqual(by["cmd_t.light.dropped"].samples, (0, 0))
        # Not measured in this run: no rows, never a 0 that reads as a pass.
        self.assertFalse(any(row.metric.startswith(("golden.browser_resize", "golden.dark_load_flash")) for row in rows))

    def test_a_cmd_t_trace_with_a_long_frame_records_its_missed_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            write_golden_run(out, cold_gap_at=10)
            rows = {row.metric: row for row in golden.rows(out, golden.judge(out), "light")}
        self.assertEqual(rows["cmd_t.light.dropped"].samples, (1, 0))

    def test_a_trace_without_per_frame_samples_is_not_measured(self):
        # A build whose debug.motion has no trace_* answers with an empty report: no rows, not a pass of 0 frames.
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            write_golden_run(out)
            (out / "sidebar_collapse.json").write_text(json.dumps({"running": False, "spans": []}))
            (out / "new_tab_cold.json").write_text(json.dumps({"running": False, "acted": {}, "opening": None}))
            verdicts = golden.judge(out)
            rows = {row.metric for row in golden.rows(out, verdicts)}
        self.assertIn("not measured", verdicts["sidebar_collapse"]["problems"][0])
        self.assertFalse(any(m.startswith("golden.sidebar_collapse.") for m in rows))
        self.assertFalse(any(m.startswith("golden.new_tab_cold.") for m in rows))

    def test_browser_resize_rows_carry_every_lag(self):
        verdict = browser_resize.judge({"drags": [resize_drag(2), resize_drag(1)]}, REFRESH)
        rows = {row.metric: row for row in browser_resize.rows(verdict)}
        story = self.story("golden")
        for row in rows.values():
            story.spec(row)
        self.assertEqual(max(rows["golden.browser_resize.window_lag_frames"].samples), 2)
        self.assertEqual(len(rows["golden.browser_resize.stale_frames"].samples), 2)
        self.assertEqual(verdict["window_lag_max"], 2)


class FlingTests(unittest.TestCase, Story):
    def write_fling(self, out: Path, mode: str, n: int, intervals, dropped: int, blank: int) -> None:
        fling = {"frames": len(intervals) + 1, "p50_ms": perf_stats.pct(intervals, 0.5),
                 "p95_ms": perf_stats.pct(intervals, 0.95), "dropped_frames": dropped}
        perf = {"frames": len(intervals), "blank_frames": blank, "samples": [{"interval_ms": i} for i in intervals]}
        (out / f"{mode}-{n}.json").write_text(json.dumps({"fling": fling, "perf": perf}))

    def test_rows_hold_every_frame_and_each_fling(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            self.write_fling(out, "1", 1, [8.3] * 50 + [25.0], 1, 0)
            self.write_fling(out, "1", 2, [8.3] * 60, 0, 2)
            self.write_fling(out, "0", 1, [16.7] * 30, 0, 0)
            rows = {row.metric: row for row in summarize.rows(out)}
            mode = summarize.load_mode(out, "1")
        story = self.story("fling")
        for row in rows.values():
            story.spec(row)
        self.assertEqual(len(rows["fling.full.frame_interval"].samples), 111)
        self.assertEqual(rows["fling.full.dropped"].samples, (1, 0))
        self.assertEqual(rows["fling.full.blank_frames"].samples, (0, 2))
        self.assertEqual(rows["fling.capped.dropped_fraction"].samples, (0.0,))
        self.assertEqual(mode.dropped, 1)

    def test_run_fling_drives_both_rates_and_keeps_raw_frames(self):
        calls = []

        def rpc(method, params=None, timeout=60):
            calls.append((method, params or {}))
            action = (params or {}).get("action")
            if action == "readiness":
                return {"pane": "p1"}
            if action == "fling":
                return {"frames": 11, "p50_ms": 8.3, "p95_ms": 9.0, "dropped_frames": 0}
            if action == "perf_stats":
                return {"blank_frames": 0, "samples": [{"interval_ms": 8.3}] * 10}
            return {}

        with tempfile.TemporaryDirectory() as tmp:
            rows = {row.metric for row in lab_story.run_fling(rpc, Path(tmp), 2, wait=lambda check, seconds: check())}
            files = sorted(p.name for p in Path(tmp).iterdir())
        self.assertEqual(files, ["0-1.json", "0-2.json", "1-1.json", "1-2.json"])
        rates = [p["enabled"] for m, p in calls if p.get("action") == "full_rate"]
        self.assertEqual(rates, [False, True])
        self.assertTrue(all(p.get("raw") for m, p in calls if p.get("action") == "perf_stats"))
        self.assertTrue(all(p.get("pane") == "p1" for m, p in calls if p.get("action") in ("fling", "seed_rows")))
        self.assertIn("fling.full.frame_interval", rows)


class LabStoryTests(unittest.TestCase, Story):
    def test_a_row_the_story_does_not_list_is_refused(self):
        with self.assertRaises(lab_story.StoryMismatch):
            self.story("fling").spec(lab_rows.Row("fling.full.unknown", "ms", "lower", (1.0,)))
        with self.assertRaises(lab_story.StoryMismatch):
            self.story("fling").spec(lab_rows.Row("fling.full.dropped", "ms", "lower", (1.0,)))

    def test_instant_runs_the_workflow_bench_with_the_lab_story_and_no_budget(self):
        seen = []
        with tempfile.TemporaryDirectory() as tmp:
            code = lab_story.main(["--mode", "instant", "--app", "/x/cmux DEV t.app", "--tag", "t", "--out", tmp,
                                   "--config", "bench"], execv=lambda path, argv: seen.append(argv))
        self.assertEqual(code, 0)
        argv = seen[0]
        self.assertTrue(argv[1].endswith("scripts/cmux-next/instant-new-surfaces-bench.py"))
        flags = dict(zip(argv[2::2], argv[3::2]))
        self.assertEqual((flags["--story"], flags["--tag"], flags["--out"], flags["--build-config"]),
                         ("frame_pacing.instant", "t", tmp, "bench"))
        self.assertFalse(any("budget" in arg for arg in argv))

    def test_golden_and_fling_record_through_benchapp_with_the_story_reference(self):
        recorded = []

        class FakeApp:
            socket = "/nonexistent.sock"

            def launch(self):
                pass

            def stop(self):
                pass

            def rpc(self, method, params=None, timeout=60):
                action = (params or {}).get("action")
                if action == "fling":
                    return {"frames": 11, "p50_ms": 8.3, "p95_ms": 9.0, "dropped_frames": 0}
                if action == "perf_stats":
                    return {"blank_frames": 0, "samples": [{"interval_ms": 8.3}] * 10}
                return {"pane": "p1"} if action == "readiness" else {}

            def record(self, story, metric, unit, samples, better, engine, target_ref=None):
                recorded.append((story, metric, unit, better, engine, target_ref))
                return f"/out/{metric}.ndjson"

        original = lab_story.wait_until
        lab_story.wait_until = lambda check, seconds, step=0.5: check()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                code = lab_story.main(["--mode", "fling", "--app", "/x/a.app", "--tag", "t", "--out", tmp,
                                       "--flings", "1"], app_factory=lambda opts, work: FakeApp())
        finally:
            lab_story.wait_until = original
        self.assertEqual(code, 0)
        by = {metric: (story, ref) for story, metric, _, _, _, ref in recorded}
        self.assertEqual(by["fling.full.frame_interval"][0], "frame_pacing.fling")
        self.assertEqual((by["fling.full.frame_interval"][1].path, by["fling.full.frame_interval"][1].key),
                         ("scripts/ci/frame-pacing/summarize.py", "P50_LIMIT_MS/1"))
        self.assertIsNone(by["fling.full.dropped"][1])

    def test_bench_sh_hands_flag_arguments_to_lab_story(self):
        done = subprocess.run(["bash", str(BENCH_DIR / "bench.sh"), "--mode", "nonsense"], capture_output=True,
                              text=True, timeout=60)
        self.assertEqual(done.returncode, 2)
        self.assertIn("--mode", done.stderr)


if __name__ == "__main__":
    unittest.main()
