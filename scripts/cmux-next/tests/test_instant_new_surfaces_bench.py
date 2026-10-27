#!/usr/bin/env python3
"""instant-new-surfaces-bench.py's report (new_surfaces_report.py, p12-perf-process-030): the old summary keys,
the perf_stats percentiles, the result-v1 series names that the new-surface-frames target and the stories match,
the missed-run counts, and one bench run's series through perf-lab ingest.

Runs on any host (Linux included): no app, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_instant_new_surfaces_bench.py
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
PERF_LAB = HERE.parent / "perf-lab"
sys.path.insert(0, str(HERE))
import new_surfaces_report as report  # noqa: E402


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ingest = load("perf_lab_ingest", PERF_LAB / "ingest.py")
pr = ingest.perf_result
store = ingest.store

VECTOR = [3.1, 4.0, 4.2, 5.5, 6.0, 7.9, 8.3, 9.0, 12.4, 20.1]
OLD_KEYS = {"n", "missed", "key_p50", "key_max", "visible_p50", "visible_p95", "visible_max", "frames_p50",
            "frames_p95", "frames_max", "first_frame_ms_p50", "confirmed_p50", "confirmed_p95"}
SHA = "a" * 40
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="f" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)


def create(command, phase="idle", visible=12.0, run=0, engine="none", missed=0):
    return {"command": command, "phase": phase, "run": run, "key_ms": 1.5, "visible_ms": visible,
            "confirmed_ms": None if visible is None else visible + 30, "engine": engine,
            "frames": {"first_tick_ms": 4.0, "intervals_ms": [8.33, 8.33, 8.33], "missed": missed}}


def close(visible=9.0, commit=3.0, dropped=0):
    return {"key_ms": 1.0, "key_to_frame_ms": visible, "commit_ms": commit, "dropped": dropped,
            "intervals_ms": [8.3, 8.4, 12.6]}


def bench_rows(session_phases=("idle",), browser=False):
    """One bench run: Cmd-T (each closed by a measured Cmd-W), Cmd-N, and with `browser` Cmd-Shift-L on Chromium."""
    rows = []
    for phase in session_phases:
        for index in range(3):
            row = create("new_tab", phase, run=index)
            row["close"] = close(visible=None if index == 2 else 9.0, commit=None if index == 2 else 3.0)
            rows.append(row)
            rows.append(create("new_workspace", phase, visible=None if index == 1 else 15.0, run=index))
            if browser:
                rows.append(create("new_browser", phase, run=index, engine="cef"))
    return rows


def target_patterns(target_id):
    targets = json.loads((PERF_LAB / "targets.json").read_text())
    target = next(t for t in (targets["targets"] if isinstance(targets, dict) else targets) if t["id"] == target_id)
    return [check["metric"] for row in target["rows"] for check in row["checks"]]


class SummaryTests(unittest.TestCase):
    def test_summary_keeps_every_old_key_and_adds_p99(self):
        rows = [create("new_tab", visible=v, run=i) for i, v in enumerate(VECTOR)]
        out = report.summary(rows, ["new_tab"])["idle/new_tab"]
        self.assertLessEqual(OLD_KEYS, set(out))
        self.assertTrue({"key_p95", "key_p99", "visible_p99", "frames_p99", "confirmed_p99", "dropped_max",
                         "dropped_total"} <= set(out))
        self.assertEqual((out["n"], out["missed"]), (10, 0))

    def test_fixed_vector_percentiles_old_nearest_rank_and_new_interpolated(self):
        def nearest_rank(values, q):  # the bench's private pct before the R8 migration
            values = sorted(values)
            return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]

        self.assertEqual([nearest_rank(VECTOR, q) for q in (.5, .95, .99, 1)], [6.0, 20.1, 20.1, 20.1])
        rows = [create("new_tab", visible=v, run=i) for i, v in enumerate(VECTOR)]
        out = report.summary(rows, ["new_tab"])["idle/new_tab"]
        for key, value in {"visible_p50": 6.95, "visible_p95": 16.635, "visible_p99": 19.407, "visible_max": 20.1}.items():
            self.assertAlmostEqual(out[key], value, places=6, msg=key)

    def test_close_summary_counts_a_leg_that_gave_no_frame_as_missed(self):
        out = report.close_summary(bench_rows())["idle/cmd_w"]
        self.assertEqual((out["n"], out["missed"]), (3, 1))
        self.assertEqual(out["key_to_frame_max"], 9.0)
        self.assertEqual(out["frame_n"], 9)


class SeriesTests(unittest.TestCase):
    def test_names_light_stress_and_other_phases(self):
        light = report.result_series(bench_rows(), ["new_tab", "new_workspace"], "light", "new-surfaces")
        for name in ("cmd_w.light.key_to_frame", "cmd_w.light.dropped", "cmd_w.light.commit", "cmd_w.light.frame",
                     "cmd_t.light.dropped", "cmd_n.light.dropped", "cmd_t.light.key_to_frame"):
            self.assertIn(name, light)
        stress = report.result_series(bench_rows(), ["new_tab"], "stress", "new-surfaces-stress")
        self.assertIn("cmd_t.stress.dropped", stress)
        self.assertIn("cmd_w.stress.key_to_frame", stress)
        phases = report.result_series(bench_rows(("idle@10ws", "load")), ["new_tab"], "light", "new-surfaces")
        self.assertIn("cmd_t.light.idle_10ws.dropped", phases)
        self.assertIn("cmd_t.light.load.dropped", phases)
        self.assertIn("cmd_w.light.load.key_to_frame", phases)

    def test_every_dropped_name_matches_the_new_surface_frames_target_only_in_its_idle_form(self):
        patterns = target_patterns("new-surface-frames")
        series = report.result_series(bench_rows(("idle", "load")), ["new_tab", "new_workspace"], "light", "x")
        for name in ("cmd_t.light.dropped", "cmd_n.light.dropped", "cmd_w.light.dropped"):
            self.assertTrue(any(re.fullmatch(p, name) for p in patterns), name)
        claimed = sorted(n for n in series if any(re.fullmatch(p, n) for p in patterns))
        self.assertEqual(claimed, ["cmd_n.light.dropped", "cmd_t.light.dropped", "cmd_w.light.dropped"])

    def test_the_stories_claim_the_rows_the_bench_writes(self):
        expected = {"new-surfaces": ("light", ["new_tab", "new_workspace"]),
                    "new-surfaces-matrix": ("light", ["new_tab", "new_workspace"]),
                    "new-surfaces-stress": ("stress", ["new_tab", "new_workspace"])}
        for story, (session, commands) in expected.items():
            doc = json.loads((PERF_LAB / "stories.d" / f"{story}.json").read_text())
            patterns = [m["name"] for m in doc["metrics"]]
            series = report.result_series(bench_rows(), commands, session, story)
            for name in (f"cmd_w.{session}.key_to_frame", f"cmd_w.{session}.dropped", f"cmd_t.{session}.dropped",
                         f"cmd_n.{session}.dropped", f"cmd_w.{session}.key_to_frame.missed_runs"):
                self.assertIn(name, series)
                self.assertTrue(any(re.fullmatch(p, name) for p in patterns), f"{story}: {name}")

    def test_a_failed_run_is_a_missed_run_not_a_missing_series(self):
        rows = bench_rows()
        for row in rows:
            if row.get("close"):
                row["close"] = close(visible=None, commit=None, dropped=None)
        series = report.result_series(rows, ["new_tab", "new_workspace"], "light", "new-surfaces")
        self.assertEqual(series["cmd_w.light.key_to_frame.missed_runs"].samples, [3])
        self.assertEqual(series["cmd_w.light.dropped.missed_runs"].samples, [3])
        self.assertEqual(series["cmd_n.light.key_to_frame.missed_runs"].samples, [1])
        self.assertEqual(series["cmd_t.light.key_to_frame.missed_runs"].samples, [0])
        kept, skipped = report.recordable(series)
        kept = dict(kept)
        self.assertEqual(skipped["cmd_w.light.key_to_frame"], "not recorded: no samples")
        self.assertEqual(kept["cmd_w.light.key_to_frame.missed_runs"].samples, [3])
        self.assertEqual(kept["cmd_n.light.key_to_frame"].samples, [15.0, 15.0])
        self.assertNotIn("cmd_w.light.frame.missed_runs", series)

    def test_browser_series_is_its_own_story_per_engine(self):
        series = report.result_series(bench_rows(browser=True), ["new_tab", "new_browser"], "light", "new-surfaces")
        browser = series["cmd_shift_l.light.key_to_frame"]
        self.assertEqual((browser.story, browser.engine), ("new-surfaces-chromium", "chromium"))
        self.assertEqual((series["cmd_t.light.dropped"].story, series["cmd_t.light.dropped"].engine),
                         ("new-surfaces", "none"))


class IngestTests(unittest.TestCase):
    def test_one_bench_run_with_a_browser_series_is_stored_whole(self):
        series = report.result_series(bench_rows(browser=True), ["new_tab", "new_workspace", "new_browser"], "light",
                                      "new-surfaces")
        kept, _ = report.recordable(series)
        run = pr.Run(id="run1", started_at="2026-10-26T12:00:00.000000Z")
        results = [pr.Result(story=s.story, metric=metric, unit=s.unit, better="lower", samples=s.samples,
                             build=pr.Build(sha=SHA, config="bench", measure_version=2), host=HOST, engine=s.engine,
                             session="light", run=run, features={"perfPath.x": pr.Feature(state="on", source="default")},
                             features_hash="fh1", safe_mode="inactive")
                   for metric, s in kept]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "results"
            pr.write_ndjson(out, results)
            db = store.Store(Path(tmp) / "lab.sqlite3")
            db.migrate()
            try:
                got = ingest.ingest_paths(db, [out], commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
                self.assertEqual(got.rejected, [])
                self.assertEqual(got.added_runs, 2)
                stored = db.run_metrics("run1/new-surfaces")
                self.assertIn("cmd_w.light.dropped", stored)
                self.assertIn("cmd_w.light.key_to_frame.missed_runs", stored)
                self.assertIn("cmd_shift_l.light.key_to_frame", db.run_metrics("run1/new-surfaces-chromium"))
            finally:
                db.close()


if __name__ == "__main__":
    unittest.main()
