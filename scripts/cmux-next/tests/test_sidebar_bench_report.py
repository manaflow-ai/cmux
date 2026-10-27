#!/usr/bin/env python3
"""The sidebar row benches' statistics and result-v1 series (sidebar_bench_report.py, p12-perf-process-054): the
perf_stats percentiles against the private ones they replace, the report keys the benches kept, the names the lab
stories claim, the hitch time ratio, the running app's pid and bundle, and one run's series through perf_result and perf-lab ingest.

Runs on any host (Linux included): no app, no daemon, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_sidebar_bench_report.py
"""

from __future__ import annotations

import importlib.util
import io
import json
import re
import statistics
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = HERE.parent / "perf-lab"
STORIES = PERF_LAB / "stories.d"
sys.path.insert(0, str(HERE))
import sidebar_bench_report as report  # noqa: E402


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ingest = load("perf_lab_ingest", PERF_LAB / "ingest.py")
pr = report.perf_result
store = ingest.store

VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]
SHA = "b" * 40
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="e" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)
BENCHES = ("sidebar-rows-perf-live.py", "sidebar-rows-perf-release.py", "sidebar-mirror-rebuild-perf.py",
           "sidebar-stress-bench.py")


# The private percentiles the benches had before the migration (R8: old and new on one fixed vector).
def old_floor_rank(values, p):  # sidebar-rows-perf-live.py and sidebar-rows-perf-release.py percentile
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(p / 100 * len(ordered)))], 2)


def old_round_rank(values, q):  # sidebar-stress-bench.py percentiles' pick
    s = sorted(values)
    return round(s[min(len(s) - 1, int(round((len(s) - 1) * q)))], 3)


def story(story_id):
    return json.loads((STORIES / f"{story_id}.json").read_text())


def claimed(doc, series):
    """The story metric that full-matches the series' name with its unit, or None."""
    return next((m for m in doc["metrics"] if re.fullmatch(m["name"], series.metric) and m["unit"] == series.unit),
                None)


def live_raw():
    ticks = {"reply_ms": VECTOR, "cpu_us_per_tick": 41.5, "main_us_per_tick": 12.25}
    scrolls = {"no_ticks": {"event_rpc_ms": VECTOR, "hitch_total_ms": [33.0, 0.0], "hitch_ratio": [1.65, 0.0]},
               "ticking": {"event_rpc_ms": VECTOR, "hitch_total_ms": [], "hitch_ratio": []}}
    return ticks, scrolls


def release_modes():
    return {"noticks": [{"total_ms": 40.0, "updates_ms": [4.0, 5.0]}, {"total_ms": 30.0, "updates_ms": [6.0]}],
            "ticks": [{"total_ms": 55.5, "updates_ms": [7.0]}]}


def stress_samples():
    return {("1000", "scroll.event_rpc"): VECTOR, ("1000", "scroll_ticking.event_rpc"): VECTOR,
            ("1000", "switch.click_to_idle"): [20.0, 22.5], ("1000", "drag.post_rpc"): [1.5],
            ("1000", "scroll_hitches.hitch_ratio"): [0.0], ("1000", "ticks.main_per_tick"): [0.4],
            ("100", "scroll.event_rpc"): [2.0]}


class PercentileTests(unittest.TestCase):
    def test_fixed_vector_old_private_percentiles_and_the_perf_stats_ones(self):
        # Old (live and release, floor rank): p50 7.9, p90 20.1, p95 20.1. Old (stress, rounded rank; round(4.5) is
        # 4): p50 6.0, p95 20.1, p99 20.1. New (perf_stats, linear interpolation): p50 6.95, p90 13.17, p95 16.63,
        # p99 19.41.
        self.assertEqual([old_floor_rank(VECTOR, p) for p in (50, 90, 95)], [7.9, 20.1, 20.1])
        self.assertEqual([old_round_rank(VECTOR, q) for q in (0.5, 0.95, 0.99)], [6.0, 20.1, 20.1])
        self.assertEqual([report.pct(VECTOR, p) for p in (50, 90, 95, 99)], [6.95, 13.17, 16.63, 19.41])

    def test_pct_is_perf_stats_pct_and_none_when_empty(self):
        self.assertEqual(report.pct(VECTOR, 95, 6), round(report.perf_stats.pct(VECTOR, 0.95), 6))
        self.assertIsNone(report.pct([], 50))
        self.assertIsNone(report.pct([None, True], 50))  # neither is a sample

    def test_median_equals_statistics_median(self):
        self.assertAlmostEqual(report.median(VECTOR), statistics.median(VECTOR))
        self.assertAlmostEqual(report.median(VECTOR[:-1]), statistics.median(VECTOR[:-1]))
        self.assertIsNone(report.median([]))

    def test_live_latency_block_keeps_its_keys_and_adds_p99(self):
        block = report.latency_stats(VECTOR, 1000 / 60)
        self.assertEqual(block, {"samples": 10, "p50_ms": 6.95, "p95_ms": 16.63, "p99_ms": 19.41, "max_ms": 20.1,
                                 "over_frame": 1})
        self.assertEqual(report.latency_stats([], 16.7)["p50_ms"], None)

    def test_update_block_keeps_p50_p90_and_adds_p95_p99(self):
        self.assertEqual(report.update_stats(VECTOR), {"update_p50_ms": 6.95, "update_p90_ms": 13.17,
                                                       "update_p95_ms": 16.63, "update_p99_ms": 19.41})

    def test_stress_block_keeps_its_keys(self):
        block = report.percentiles(VECTOR)
        self.assertEqual(block, {"n": 10, "p50": 6.95, "p95": 16.635, "p99": 19.407, "max": 20.1, "mean": 8.05})
        self.assertEqual(report.percentiles([]), {})


class SeriesTests(unittest.TestCase):
    def test_live_series_names_units_and_skips_an_empty_mode(self):
        series = {s.metric: s for s in report.live_series(1000, *live_raw())}
        self.assertEqual(series["sidebar_rows_live.1000.ticks.reply_delay"].samples, VECTOR)
        self.assertEqual(series["sidebar_rows_live.1000.ticks.app_cpu_per_tick"].unit, "us")
        ratio = series["sidebar_rows_live.1000.scroll_no_ticks.hitch_ratio"]
        self.assertEqual((ratio.unit, ratio.samples), ("percent", [1.65, 0.0]))  # a hitch-free recording is a 0
        self.assertNotIn("sidebar_rows_live.1000.scroll_no_ticks.hitch", series)  # no per-hitch series
        self.assertNotIn("sidebar_rows_live.1000.scroll_ticking.hitch_total", series)  # no valid recording
        self.assertIn("sidebar_rows_live.1000.scroll_ticking.event_rpc", series)

    def test_release_series_pools_app_updates_of_the_valid_runs(self):
        series = {s.metric: s for s in report.release_series(1000, release_modes(), {"app_cpu_us_per_tick": 80.2})}
        self.assertEqual(series["sidebar_scroll_release.1000.noticks.hitch_total"].samples, [40.0, 30.0])
        self.assertEqual(series["sidebar_scroll_release.1000.noticks.app_update"].samples, [4.0, 5.0, 6.0])
        self.assertEqual(series["sidebar_scroll_release.1000.ticks.app_cpu_per_tick"].samples, [80.2])
        self.assertNotIn("sidebar_scroll_release.1000.ticks.app_cpu_per_tick",
                         {s.metric for s in report.release_series(1000, release_modes())})

    def test_mirror_series_per_cycle(self):
        series = {s.metric: s for s in report.mirror_series(1000, [{"mirror_ms": 0.5, "main_ms": 1.25},
                                                                   {"mirror_ms": 0.75, "main_ms": 1.0}])}
        self.assertEqual(series["sidebar_mirror_rebuild.1000.mirror_per_cycle"].samples, [0.5, 0.75])
        self.assertEqual(series["sidebar_mirror_rebuild.1000.main_per_cycle"].samples, [1.25, 1.0])

    def test_stress_series_by_size_then_metric(self):
        series = report.stress_series(stress_samples())
        metrics = [s.metric for s in series]
        self.assertEqual(metrics[0], "sidebar_stress.100.scroll.event_rpc")
        self.assertIn("sidebar_stress.1000.ticks.main_per_tick", metrics)
        units = {s.metric: s.unit for s in series}
        self.assertEqual(units["sidebar_stress.1000.scroll_hitches.hitch_ratio"], "percent")
        self.assertEqual(units["sidebar_stress.1000.drag.post_rpc"], "ms")

    def test_hitch_ratio_is_hitch_time_per_gesture_time(self):
        self.assertEqual(report.hitch_ratio(50.0, 2.0), 2.5)  # 50 ms of hitches in a 2 s gesture
        self.assertEqual(report.hitch_ratio(0.0, 2.0), 0.0)  # no hitch: the best result, still one sample
        # One big hitch left after the small ones go is less hitch time, so the ratio goes down, not up.
        self.assertLess(report.hitch_ratio(40.0, 2.0), report.hitch_ratio(40.0 + 3 * 8.0, 2.0))
        for total, seconds in ((None, 2.0), (10.0, None), (10.0, 0.0), (True, 2.0)):
            self.assertIsNone(report.hitch_ratio(total, seconds))


class StoryTests(unittest.TestCase):
    def check_claimed(self, story_id, series):
        doc = story(story_id)
        self.assertEqual((doc["engine"], doc["session"]), ("none", report.SESSION))
        mine = [s for s in series if s.story == story_id]
        self.assertTrue(mine, f"no series for {story_id}")
        for s in mine:
            self.assertIsNotNone(claimed(doc, s), f"{story_id} claims no metric {s.metric} ({s.unit})")

    def test_every_series_a_story_runs_is_claimed_by_it(self):
        self.check_claimed(report.LIVE_STORY, report.live_series(1000, *live_raw()))
        self.check_claimed(report.RELEASE_STORY, report.release_series(1000, release_modes(), {"app_cpu_us_per_tick": 1}))
        self.check_claimed(report.MIRROR_STORY, report.mirror_series(1000, [{"mirror_ms": 0.5, "main_ms": 1.0}]))
        self.check_claimed(report.STRESS_STORY, report.stress_series(stress_samples()))

    def test_story_commands_name_the_bench(self):
        for story_id, script in ((report.LIVE_STORY, BENCHES[0]), (report.RELEASE_STORY, BENCHES[1]),
                                 (report.MIRROR_STORY, BENCHES[2]), (report.STRESS_STORY, BENCHES[3])):
            self.assertEqual(story(story_id)["command"][0], f"scripts/cmux-next/{script}")
        self.assertEqual(story(report.RELEASE_STORY)["config"], "release")

    def test_the_catalog_lints_the_new_stories_clean(self):
        catalog = load("perf_lab_catalog", PERF_LAB / "catalog.py").load_catalog()
        new = {report.LIVE_STORY, report.RELEASE_STORY, report.MIRROR_STORY, report.STRESS_STORY}
        self.assertLessEqual(new, {s.id for s in catalog.stories})
        self.assertEqual([p for p in catalog.problems if any(story_id in p for story_id in new)], [])


class RunningAppTests(unittest.TestCase):
    PS = ("  101 /Applications/cmux DEV other.app/Contents/MacOS/cmux DEV\n"
          "  202 /Users/x/Library/cmux DEV sb.app/Contents/Frameworks/Helper.app/Contents/MacOS/cmux Helper\n"
          "  303 /Users/x/Library/cmux DEV sb.app/Contents/MacOS/cmux DEV -AppleLanguages (en)\n")

    def test_running_bundle_is_the_main_app_of_the_tag(self):
        self.assertEqual(report.running_bundle("sb", self.PS), (303, "/Users/x/Library/cmux DEV sb.app"))
        self.assertEqual(report.running_bundle("none", self.PS), (None, None))

    def test_no_bench_records_nothing(self):
        self.assertFalse(hasattr(report, "attach"))  # an attached app (--tag) has an unknown launch env
        self.assertEqual(report.record_all(None, report.mirror_series(1, [{"mirror_ms": 1.0, "main_ms": 1.0}])), {})


class RecordTests(unittest.TestCase):
    def test_record_all_sets_the_stress_session_and_reports_a_refused_one(self):
        class Bench:
            perf_session = "light"
            calls = []

            def record(self, story_id, metric, unit, samples, better, engine, target_ref=None):
                self.calls.append((story_id, metric, self.perf_session, engine, better))
                if metric.endswith("main_per_cycle"):
                    raise report.RecordError("no features snapshot")
                return f"/out/{metric}.ndjson"

        bench = Bench()
        with redirect_stdout(io.StringIO()) as printed:
            written = report.record_all(bench, report.mirror_series(1000, [{"mirror_ms": 0.5, "main_ms": 1.0}]))
        self.assertEqual({c[2:] for c in bench.calls}, {("stress", "none", "lower")})
        self.assertEqual(written["sidebar-mirror-rebuild/sidebar_mirror_rebuild.1000.mirror_per_cycle"],
                         "/out/sidebar_mirror_rebuild.1000.mirror_per_cycle.ndjson")
        self.assertTrue(written["sidebar-mirror-rebuild/sidebar_mirror_rebuild.1000.main_per_cycle"]
                        .startswith("not recorded"))
        self.assertIn("not recorded: no features snapshot", printed.getvalue())

    def test_series_round_trip_through_perf_result_and_ingest(self):
        run = pr.Run(id="run054", started_at="2026-10-26T12:00:00.000000Z")
        build = pr.Build(sha=SHA, config="bench", measure_version=2)
        series = report.stress_series(stress_samples())
        results = [pr.Result(story=s.story, metric=s.metric, unit=s.unit, better="lower", samples=s.samples,
                             build=build, host=HOST, engine="none", session=report.SESSION, run=run) for s in series]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            pr.write_ndjson(out, results, repo_root=ROOT)
            back = pr.read_dir(out)
            self.assertEqual(sorted(r.metric for r in back), sorted(s.metric for s in series))
            db = store.Store(Path(tmp) / "lab.sqlite3")
            db.migrate()
            try:
                got = ingest.ingest_paths(db, [out], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
                self.assertEqual(got.rejected, [])
                self.assertIn("sidebar_stress.1000.scroll.event_rpc", db.run_metrics("run054/sidebar-stress"))
            finally:
                db.close()


class BenchSourceTests(unittest.TestCase):
    """The four benches keep no private percentile, launch only through BenchApp and name p99 (MQ1, MQ2, MQ3)."""

    def test_no_private_stats_no_self_launch_and_p99(self):
        queues = load("perf_lab_queues", PERF_LAB / "queues.py")
        keys = {f"scripts/cmux-next/{name}" for name in BENCHES}
        for name, run in (("MQ1", queues.private_stats), ("MQ2", queues.self_launch), ("MQ3", queues.p95_without_p99)):
            self.assertEqual([i.key for i in run(str(ROOT)) if i.key in keys], [], name)

    def test_no_bench_uses_statistics_or_open(self):
        for name in BENCHES:
            source = (HERE / name).read_text()
            self.assertNotIn("statistics.", source, name)
            self.assertNotIn('["open", "-n"', source, name)

    def test_result_v1_is_written_after_the_report_and_only_for_a_launched_app(self):
        for name in BENCHES[0], BENCHES[2]:  # live and mirror: attach with --tag, launch with --app
            source = (HERE / name).read_text()
            body = source[source.index("def measure():"):]
            self.assertLess(body.index("write_summary("), body.index("report.record_all("), name)
            self.assertIn("if BENCH is None:", body, name)
            self.assertNotIn("report.attach", source, name)
        stress = (HERE / BENCHES[3]).read_text()
        body = stress[stress.index("def main():"):]
        cleanup = body[body.index("    finally:"):]
        self.assertNotIn("record_all", cleanup)  # never from a failed run, never before the cleanup
        self.assertLess(cleanup.index("results.json"), cleanup.index("bench.stop()"))
        self.assertIn("        finally:\n            if opts.stop:\n                bench.stop()", cleanup)

    def test_every_bench_takes_app_and_tag(self):
        """The lab runner (task 008) passes --app, --tag and --out to a story command."""
        for name in BENCHES:
            done = subprocess.run([sys.executable, "-I", str(HERE / name), "--help"], capture_output=True, text=True,
                                  timeout=60)
            self.assertEqual(done.returncode, 0, f"{name}: {done.stderr[-400:]}")
            for flag in ("--app", "--tag", "--out"):
                self.assertIn(flag, done.stdout, f"{name} {flag}")

    def test_the_report_module_and_bench_launch_import_under_python_isolated(self):
        code = ("import runpy, sys; m = runpy.run_path(sys.argv[1]); "
                "print(m['pct']([1.0, 2.0, 3.0], 50), m['RecordError'].__name__)")
        done = subprocess.run([sys.executable, "-I", "-c", code, str(HERE / "sidebar_bench_report.py")],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr[-600:])
        self.assertEqual(done.stdout.split(), ["2.0", "RecordError"])


if __name__ == "__main__":
    unittest.main()
