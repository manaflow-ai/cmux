#!/usr/bin/env python3
"""aa.py: A/A pairing, CV of median and p99, false-alert rate and the noisy-series list on a fixture store.

  python3 -m unittest scripts/perf-lab/tests/test_aa.py
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import math
import sys
import tempfile
import unittest
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, filename: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, LAB / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load("perf_lab_store", "store.py")
aa = _load("perf_lab_aa", "aa.py")
lab = _load("perf_lab_lab", "lab.py")

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
HOST_A = store.Host(name="cmux15", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-15")
HOST_B = store.Host(name="cmux16", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-16")
STEADY = [10.0, 10.1, 9.9, 10.0, 10.2, 9.8, 10.0, 10.1, 9.9, 10.0]


@dataclass(frozen=True)
class FakeChangePoint:
    extended_start: int
    extended_end: int
    median_before: float
    median_after: float


class NoChangePoints:
    def change_points(self, values, config):
        return []


class ThresholdDetector:
    """Flags the first value more than 20 % away from the first one, like a step detector; records configs."""

    def __init__(self):
        self.calls = 0
        self.configs = []

    def change_points(self, values, config):
        self.calls += 1
        self.configs.append(dict(config))
        for index, value in enumerate(values):
            if abs(value / values[0] - 1) > 0.2:
                return [FakeChangePoint(index, index, values[0], value)]
        return []


class ScriptedDetector:
    """Returns the scripted change points for each prefix length."""

    def __init__(self, by_length):
        self.by_length = by_length

    def change_points(self, values, config):
        return self.by_length.get(len(values), [])


class CountingDetector:
    """Records the length of every window it is given; finds nothing."""

    def __init__(self, inner=None):
        self.inner = inner
        self.lengths = []

    def change_points(self, values, config):
        self.lengths.append(len(values))
        return self.inner.change_points(values, config) if self.inner else []


class RefusingDetector:
    def change_points(self, values, config):
        raise AssertionError("the noisy-series list must not run the detector")


MONITORED_CONFIG = {"min_relative_change": 0.1}


def monitor_all_but_unmonitored(series):
    return None if series.story == "unmonitored.story" else MONITORED_CONFIG


class Fixture:
    def __init__(self, directory: Path):
        self.path = directory / "lab.db"
        self.db = store.Store(self.path, clock=lambda: NOW)
        self.db.migrate()
        self.count = 0

    def close(self):
        self.db.close()

    def job(self, controller_job_id: str) -> int:
        stamp = NOW.isoformat()
        self.db._db.execute("INSERT INTO jobs (controller_job_id, kind, state, created_at, updated_at) "
                            "VALUES (?, 'aa', 'done', ?, ?)", (controller_job_id, stamp, stamp))
        self.db._db.commit()
        row = self.db._db.execute("SELECT id FROM jobs WHERE controller_job_id = ?", (controller_job_id,)).fetchone()
        return row[0]

    def run(self, *, kind="aa", host=HOST_A, sha="a" * 40, pos=100, started_at, story="terminal.key-frame.light",
            metrics, job_id=None):
        self.count += 1
        run = store.Run(run_uuid=f"run-{self.count}", kind=kind, measure_version="m1", story=story, engine="webkit",
                        macos_major=26, macos_build="26.1", features_hash="f0", safe_mode="off",
                        started_at=started_at, job_id=job_id, tier="T0")
        build = store.Build(sha=sha, config="bench", commit_pos=pos)
        self.db.insert_run(run, build=build, host=host, metrics=[
            store.Metric(name=name, unit=unit, better="lower", samples=samples) for name, unit, samples in metrics])

    def pair(self, *, night: int, a, b, host=HOST_A, metric="key_to_frame_ms", unit="ms",
             story="terminal.key-frame.light", start=None, gap=timedelta(minutes=10)):
        start = start or NOW - timedelta(days=night, hours=6)
        sha = f"{night:040d}"
        for offset, samples in ((0, a), (1, b)):
            self.run(host=host, sha=sha, pos=1000 - night, started_at=start + offset * gap,
                     story=story, metrics=[(metric, unit, samples)])

    def waterfall(self, host, *, days_ago=1):
        self.run(kind="waterfall", host=host, sha="e" * 40, pos=4000, started_at=NOW - timedelta(days=days_ago),
                 metrics=[("key_to_frame_ms", "ms", STEADY)])


def _scaled(samples, factor):
    return [value * factor for value in samples]


def _expected_cv(pairs):
    return math.sqrt(sum(((a - b) / ((a + b) / 2)) ** 2 for a, b in pairs) / (2 * len(pairs)))


def _args(db, **overrides):
    values = dict(db=str(db), since_live=False, days=None, cv_over=None, p99_cv_over=None, min_pairs=aa.MIN_PAIRS,
                  json=True)
    values.update(overrides)
    return argparse.Namespace(**values)


def _series(story="home-idle", metric="home.typing.key_dispatch", build_config="bench"):
    return aa.SeriesInfo(id=1, key=f"{story}/{metric}", story=story, metric=metric, engine="webkit",
                         host_class="m4pro-24g-120hz", macos_major=26, build_config=build_config, unit="ms",
                         better="lower")


class DuplicateCVTests(unittest.TestCase):
    def test_root_mean_square_cv_of_pairs(self):
        pairs = [(100.0, 110.0), (100.0, 100.0), (50.0, 45.0)]
        self.assertAlmostEqual(aa.duplicate_cv(pairs), _expected_cv(pairs), places=12)

    def test_identical_pairs_have_zero_cv(self):
        self.assertEqual(aa.duplicate_cv([(3.0, 3.0), (0.0, 0.0)]), 0.0)

    def test_no_usable_pair_is_none(self):
        self.assertIsNone(aa.duplicate_cv([]))
        self.assertIsNone(aa.duplicate_cv([(1.0, -1.0)]))

    def test_level_series_puts_b_at_a_level(self):
        self.assertEqual(aa.level_series([(10.0, 11.0), (20.0, 20.0), (0.0, 5.0), (30.0, 15.0)]),
                         [22.0, 20.0, 10.0])
        self.assertEqual(aa.level_series([(0.0, 1.0)]), [])


class ChangePointCountTests(unittest.TestCase):
    def test_one_step_counted_once_over_prefixes(self):
        values = [1.0, 1.0, 1.5, 1.0, 1.0]
        detector = ThresholdDetector()
        self.assertEqual(aa.change_points(values, detector, MONITORED_CONFIG), aa.Steps(1, 1))
        self.assertEqual(detector.calls, len(values))
        self.assertEqual(detector.configs, [MONITORED_CONFIG] * len(values))

    def test_replay_is_one_call_per_point_on_at_most_one_window(self):
        # alerts.detect sees the newest max_window_size points; a replay that hands the detector every whole
        # prefix is quadratic and fails here.
        detector = CountingDetector()
        aa.change_points([1.0] * 200, detector, {})
        self.assertEqual(len(detector.lengths), 200)
        self.assertEqual(max(detector.lengths), aa._alerts().DEFAULT_MAX_WINDOW_SIZE)
        self.assertEqual(sum(detector.lengths), sum(min(n, 50) for n in range(1, 201)))
        small = CountingDetector()
        aa.change_points([1.0] * 30, small, {"max_window_size": 8})
        self.assertEqual(max(small.lengths), 8)

    def test_window_indexes_map_back_to_the_series(self):
        # At length 12 with a window of 8, window index 1 is series index 5; at length 13 window index 0 is
        # series index 5 again: the same alert.
        windows = {12: [FakeChangePoint(1, 1, 1.0, 2.0)], 13: [FakeChangePoint(0, 0, 1.0, 2.0)]}
        ends = iter(range(1, 21))

        class ByEnd:
            def change_points(self, values, config):
                return windows.get(next(ends), [])

        self.assertEqual(aa.change_points([1.0] * 20, ByEnd(), {"max_window_size": 8}), aa.Steps(1, 1))
        # Without the offset, index 1 then 0 would be two disjoint alerts.
        windows[13] = [FakeChangePoint(4, 4, 1.0, 2.0)]
        ends = iter(range(1, 21))
        self.assertEqual(aa.change_points([1.0] * 20, ByEnd(), {"max_window_size": 8}), aa.Steps(2, 2))

    def test_overlapping_ranges_are_one_alert_and_disjoint_ones_two(self):
        detector = ScriptedDetector({
            3: [FakeChangePoint(1, 2, 1.0, 2.0)],
            4: [FakeChangePoint(2, 3, 1.0, 2.0)],  # overlaps 1..2: the same alert, as alerts._record drops it
            6: [FakeChangePoint(5, 5, 2.0, 1.0), FakeChangePoint(1, 1, 1.0, 2.0)],
        })
        self.assertEqual(aa.change_points([1.0] * 6, detector, {}), aa.Steps(1, 2))

    def test_only_a_regression_step_is_an_alert(self):
        improvement = ScriptedDetector({4: [FakeChangePoint(2, 2, 2.0, 1.0)]})
        self.assertEqual(aa.change_points([1.0] * 4, improvement, {}, "lower"), aa.Steps(0, 1))
        self.assertEqual(aa.change_points([1.0] * 4, improvement, {}, "higher"), aa.Steps(1, 1))
        # An improvement still holds its range, as alerts._record stores it: an overlapping step is not new.
        detector = ScriptedDetector({4: [FakeChangePoint(2, 2, 2.0, 1.0)], 5: [FakeChangePoint(2, 3, 1.0, 2.0)]})
        self.assertEqual(aa.change_points([1.0] * 5, detector, {}), aa.Steps(0, 1))

    def test_a_step_with_equal_medians_is_not_an_alert(self):
        detector = ScriptedDetector({4: [FakeChangePoint(2, 2, 1.0, 1.0)]})
        self.assertEqual(aa.change_points([1.0] * 4, detector, {}), aa.Steps(0, 0))


class ScreenedDetectorTests(unittest.TestCase):
    def series(self):
        steady = [10.0 * (1 + 0.01 * ((i * 7) % 5 - 2)) for i in range(60)]
        return {"steady": steady, "stepped": steady[:30] + [value * 1.5 for value in steady[30:]],
                "dip": steady[:20] + [value * 0.7 for value in steady[20:40]] + steady[40:]}

    def test_screen_answers_as_the_catapult_detector(self):
        alerts = aa._alerts()
        plain = alerts.CatapultDetector()
        screened = aa.catapult_detector()
        steps = 0
        for name, values in self.series().items():
            for config in ({}, {"min_segment_size": 3, "min_relative_change": 0.05}, {"min_absolute_change": 100.0}):
                for end in (1, 12, 26, 37, 45, 60):
                    window = values[max(0, end - 50):end]
                    expected = plain.change_points(window, config)
                    steps += len(expected)
                    with self.subTest(series=name, config=config, end=end):
                        self.assertEqual(screened.change_points(window, config), expected)
        self.assertGreater(steps, 0)

    def test_steady_a_a_noise_never_reaches_the_permutation_test(self):
        inner = CountingDetector()
        screened = aa.ScreenedDetector(inner, aa._load("perf_lab_anomaly", "anomaly.py"))
        self.assertEqual(aa.change_points(self.series()["steady"], screened, {}), aa.Steps(0, 0))
        self.assertEqual(inner.lengths, [])
        aa.change_points(self.series()["stepped"], screened, {})
        self.assertGreater(len(inner.lengths), 0)


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fixture = Fixture(Path(self.tmp.name))

    def tearDown(self):
        self.fixture.close()
        self.tmp.cleanup()

    def report(self, detector=None, **overrides):
        out = io.StringIO()
        code = aa.aa_report(_args(self.fixture.path, **overrides), clock=lambda: NOW,
                            detector=detector or NoChangePoints(), configs=monitor_all_but_unmonitored, out=out)
        self.assertEqual(code, 0)
        return json.loads(out.getvalue())

    def test_cv_of_median_and_p99(self):
        factors = [1.00, 1.04, 0.97, 1.02]
        for night, factor in enumerate(factors, start=1):
            self.fixture.pair(night=night, a=STEADY, b=_scaled(STEADY, factor))
        result = self.report(days=30)
        (row,) = result["series"]
        self.assertEqual(row["pairs"], 4)
        median, p99 = aa.perf_stats.pct(STEADY, 0.5), aa.perf_stats.pct(STEADY, 0.99)
        self.assertAlmostEqual(row["cv_median"], _expected_cv([(median, median * f) for f in factors]), places=9)
        self.assertAlmostEqual(row["cv_p99"], _expected_cv([(p99, p99 * f) for f in factors]), places=9)
        # A whole-sample shift of 2 % or more is a real A/B difference to Pinpoint's compare at n = 10. Of the
        # three, B is slower (a regression of a lower-is-better series) at 1.04 and 1.02; 0.97 is an improvement.
        different = [f for f in factors
                     if aa.perf_stats.compare(STEADY, _scaled(STEADY, f)).original.result == aa.perf_stats.DIFFERENT]
        self.assertEqual(different, [1.04, 0.97, 1.02])
        self.assertEqual(row["compare_different_two_sided"], 3)
        self.assertEqual(row["compare_different_strict"], 2)
        self.assertEqual(row["false_alerts"], 2)
        summary = result["summary"]
        self.assertEqual(summary["series_days"], 4)
        self.assertAlmostEqual(summary["false_alerts_per_100_series_days"], 50.0)
        self.assertEqual(summary["median_cv_share_within"], 1.0)
        # No waterfall host in the window: the per-host A/A check cannot pass.
        self.assertEqual(summary["checks"], {"aa_runs_per_host": False, "false_alerts": False, "median_cv": True,
                                             "p99_cv": True})
        self.assertEqual(summary["aa_runs_by_host"], {"cmux15": 4})
        self.assertEqual(summary["waterfall_hosts"], [])
        self.assertEqual(summary["hosts_under_min_aa_runs"], [])

    def test_an_improvement_of_b_is_not_a_false_alert(self):
        faster = _scaled(STEADY, 0.6)
        for night in range(1, 6):
            self.fixture.pair(night=night, a=STEADY, b=faster if night == 3 else list(STEADY))
        (row,) = self.report(detector=ThresholdDetector(), days=30)["series"]
        self.assertEqual(row["compare_different_two_sided"], 1)
        self.assertEqual(row["compare_different_strict"], 0)
        self.assertEqual(row["compare_different_bisect"], 0)
        self.assertEqual(row["anomaly_steps_two_sided"], 1)
        self.assertEqual(row["anomaly_alerts"], 0)
        self.assertEqual(row["false_alerts"], 0)

    def test_every_waterfall_host_needs_three_a_a_runs(self):
        host_c = store.Host(name="cmux17", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-17")
        for host in (HOST_A, HOST_B, host_c):
            self.fixture.waterfall(host)
        for night in range(1, 4):
            self.fixture.pair(night=night, a=STEADY, b=list(STEADY), host=HOST_A)
        self.fixture.pair(night=1, a=STEADY, b=list(STEADY), host=HOST_B)
        summary = self.report(days=30)["summary"]
        self.assertEqual(summary["waterfall_hosts"], ["cmux15", "cmux16", "cmux17"])
        self.assertEqual(summary["aa_runs_by_host"], {"cmux15": 3, "cmux16": 1, "cmux17": 0})
        self.assertEqual(summary["hosts_under_min_aa_runs"], ["cmux16", "cmux17"])
        self.assertFalse(summary["checks"]["aa_runs_per_host"])
        for night in range(2, 4):
            self.fixture.pair(night=night, a=STEADY, b=list(STEADY), host=HOST_B)
            self.fixture.pair(night=night, a=STEADY, b=list(STEADY), host=host_c)
        self.fixture.pair(night=4, a=STEADY, b=list(STEADY), host=host_c)
        summary = self.report(days=30)["summary"]
        self.assertEqual(summary["hosts_under_min_aa_runs"], [])
        self.assertTrue(summary["checks"]["aa_runs_per_host"])

    def test_a_job_that_runs_past_midnight_utc_is_one_pair_and_one_run(self):
        # Pass A at 23:50 UTC and pass B at 00:10 UTC are one scheduler lab day (it starts at 09:00 UTC).
        night = NOW.replace(hour=23, minute=50) - timedelta(days=2)
        self.fixture.pair(night=1, a=STEADY, b=_scaled(STEADY, 1.01), start=night, gap=timedelta(minutes=20))
        pairs = aa.pair_runs(aa.read_aa_runs(self.fixture.path, NOW - timedelta(days=30)))
        self.assertEqual(len(pairs), 1)
        self.assertEqual(aa.read_host_runs(self.fixture.path, NOW - timedelta(days=30)).aa_runs, {"cmux15": 1})

    def test_a_a_runs_are_counted_by_job(self):
        start = NOW - timedelta(hours=6)
        metrics = [("key_to_frame_ms", "ms", STEADY)]
        first, second = self.fixture.job("aa-1"), self.fixture.job("aa-2")
        for offset, job in ((0, first), (1, first), (2, second), (3, second)):
            self.fixture.run(started_at=start + timedelta(minutes=offset), job_id=job, metrics=metrics)
        runs = aa.read_aa_runs(self.fixture.path, NOW - timedelta(days=1))
        self.assertEqual(len(aa.pair_runs(runs)), 2)
        self.assertEqual(aa.read_host_runs(self.fixture.path, NOW - timedelta(days=1)).aa_runs, {"cmux15": 2})

    def test_pairs_never_mix_hosts_or_artifacts_and_waterfall_runs_are_ignored(self):
        start = NOW - timedelta(hours=6)
        metrics = [("key_to_frame_ms", "ms", STEADY)]
        self.fixture.run(host=HOST_A, sha="1" * 40, pos=1, started_at=start, metrics=metrics)
        self.fixture.run(host=HOST_B, sha="1" * 40, pos=1, started_at=start + timedelta(minutes=1), metrics=metrics)
        self.fixture.run(host=HOST_A, sha="2" * 40, pos=2, started_at=start + timedelta(minutes=2), metrics=metrics)
        self.fixture.run(kind="waterfall", host=HOST_A, sha="1" * 40, pos=1,
                         started_at=start + timedelta(minutes=3), metrics=metrics)
        runs = aa.read_aa_runs(self.fixture.path, NOW - timedelta(days=1))
        self.assertEqual(len(runs), 3)
        self.assertEqual(aa.pair_runs(runs), [])

    def test_runs_of_one_job_pair_in_time_order(self):
        start = NOW - timedelta(hours=6)
        for offset, factor in ((0, 1.0), (1, 1.1), (2, 1.0), (3, 1.3)):
            self.fixture.run(started_at=start + timedelta(minutes=offset), job_id=None,
                             metrics=[("key_to_frame_ms", "ms", _scaled(STEADY, factor))])
        pairs = aa.pair_runs(aa.read_aa_runs(self.fixture.path, NOW - timedelta(days=1)))
        self.assertEqual([(p.a[0], round(p.b[0], 6)) for p in pairs], [(10.0, 11.0), (10.0, 13.0)])

    def test_false_alert_rate_counts_compare_and_anomaly(self):
        # Night 2 is a real difference between A and B; the detector also sees it in the median series.
        shifted = _scaled(STEADY, 1.5)
        for night in range(1, 11):
            self.fixture.pair(night=night, a=STEADY, b=shifted if night == 2 else list(STEADY))
        detector = ThresholdDetector()
        result = self.report(detector=detector, days=30)
        (row,) = result["series"]
        comparison = aa.perf_stats.compare(STEADY, shifted)
        self.assertEqual(comparison.original.result, aa.perf_stats.DIFFERENT)
        self.assertEqual(row["compare_different_strict"], 1)
        self.assertEqual(row["compare_different_bisect"], 1)
        self.assertEqual(row["anomaly_alerts"], 1)
        self.assertEqual(row["anomaly_steps_two_sided"], 1)
        self.assertEqual(row["false_alerts"], 2)
        self.assertAlmostEqual(row["false_alerts_per_100"], 20.0)
        self.assertEqual({json.dumps(c, sort_keys=True) for c in detector.configs},
                         {json.dumps(MONITORED_CONFIG, sort_keys=True)})
        summary = result["summary"]
        self.assertAlmostEqual(summary["false_alerts_per_100_series_days"], 20.0)
        self.assertFalse(summary["checks"]["false_alerts"])

    def test_identical_samples_are_never_a_compare_alert(self):
        for night in range(1, 6):
            self.fixture.pair(night=night, a=STEADY, b=list(STEADY))
        (row,) = self.report(days=30)["series"]
        self.assertEqual(row["compare_different_strict"], 0)
        self.assertEqual(row["cv_median"], 0.0)

    def test_unmonitored_series_are_left_out(self):
        for night in range(1, 4):
            self.fixture.pair(night=night, a=STEADY, b=_scaled(STEADY, 1.3), story="unmonitored.story")
            self.fixture.pair(night=night, a=STEADY, b=list(STEADY))
        result = self.report(days=30)
        self.assertEqual([row["story"] for row in result["series"]], ["terminal.key-frame.light"])
        self.assertEqual(result["summary"]["series_days"], 3)
        self.assertEqual(result["summary"]["unmonitored_series"], 1)

    def test_noisy_series_listed_by_median_or_p99_cv(self):
        quiet, noisy_median, noisy_tail = "quiet_ms", "noisy_ms", "tail_ms"
        tail_b = STEADY[:-1] + [15.0]
        for night in range(1, 5):
            factor = 1.15 if night % 2 else 0.88
            self.fixture.pair(night=night, a=STEADY, b=_scaled(STEADY, 1.01), metric=quiet)
            self.fixture.pair(night=night, a=STEADY, b=_scaled(STEADY, factor), metric=noisy_median)
            self.fixture.pair(night=night, a=STEADY, b=tail_b, metric=noisy_tail)
        listed = self.report(detector=RefusingDetector(), days=30, cv_over=0.05)
        self.assertEqual([row["metric"] for row in listed], [noisy_median, noisy_tail])
        self.assertEqual({row["false_alerts"] for row in listed}, {None})
        self.assertGreater(listed[0]["cv_median"], 0.05)
        self.assertLessEqual(listed[1]["cv_median"], 0.05)
        self.assertGreater(listed[1]["cv_p99"], 0.10)
        only_median = self.report(days=30, cv_over=0.05, p99_cv_over=10.0)
        self.assertEqual([row["metric"] for row in only_median], [noisy_median])

    def test_series_with_too_few_pairs_is_not_listed_or_judged(self):
        self.fixture.waterfall(HOST_A)
        for night in range(1, 3):
            self.fixture.pair(night=night, a=STEADY, b=_scaled(STEADY, 1.5))
        self.assertEqual(self.report(days=30, cv_over=0.05), [])
        summary = self.report(days=30)["summary"]
        self.assertEqual(summary["latency_series_judged"], 0)
        self.assertIsNone(summary["median_cv_share_within"])
        self.assertFalse(summary["checks"]["median_cv"])
        self.assertEqual(summary["hosts_under_min_aa_runs"], ["cmux15"])

    def test_cv_share_judges_latency_series_only(self):
        for night in range(1, 4):
            self.fixture.pair(night=night, a=STEADY, b=list(STEADY))
            self.fixture.pair(night=night, a=STEADY, b=_scaled(STEADY, 1.5 if night % 2 else 0.6),
                              metric="wakeups", unit="count")
        summary = self.report(days=30)["summary"]
        self.assertEqual(summary["latency_series_judged"], 1)
        self.assertEqual(summary["median_cv_share_within"], 1.0)

    def test_since_live_starts_at_the_first_waterfall_run(self):
        self.fixture.pair(night=20, a=STEADY, b=_scaled(STEADY, 1.5))
        self.fixture.run(kind="waterfall", started_at=NOW - timedelta(days=10), sha="f" * 40, pos=5000,
                         metrics=[("key_to_frame_ms", "ms", STEADY)])
        for night in range(1, 4):
            self.fixture.pair(night=night, a=STEADY, b=list(STEADY))
        result = self.report(since_live=True)
        self.assertEqual(result["summary"]["series_days"], 3)
        self.assertEqual(result["series"][0]["cv_median"], 0.0)
        self.assertEqual(self.report(days=30)["summary"]["series_days"], 4)

    def test_not_live_without_a_waterfall_run(self):
        self.fixture.pair(night=1, a=STEADY, b=STEADY)
        with self.assertRaises(aa.AAError):
            self.report(since_live=True)

    def test_text_report_prints_the_done_check(self):
        for night in range(1, 4):
            self.fixture.pair(night=night, a=STEADY, b=list(STEADY))
        out = io.StringIO()
        aa.aa_report(_args(self.fixture.path, days=30, json=False), clock=lambda: NOW, detector=NoChangePoints(),
                     configs=monitor_all_but_unmonitored, out=out)
        text = out.getvalue()
        self.assertIn("false alerts: 0 (0.00 per 100 series-days, limit 1) ok", text)
        self.assertIn("A/A runs: 0 waterfall hosts, need >= 3 each (no waterfall host in the window) FAIL", text)
        self.assertIn("host cmux15: 3 A/A runs\n", text)
        self.fixture.waterfall(HOST_A)
        self.fixture.waterfall(HOST_B)
        out = io.StringIO()
        aa.aa_report(_args(self.fixture.path, days=30, json=False), clock=lambda: NOW, detector=NoChangePoints(),
                     configs=monitor_all_but_unmonitored, out=out)
        text = out.getvalue()
        self.assertIn("A/A runs: 2 waterfall hosts, need >= 3 each FAIL", text)
        self.assertIn("host cmux16: 0 A/A runs (under the minimum)", text)

    def test_catapult_detector_finds_no_step_in_steady_a_a_and_one_in_a_shift(self):
        detector = aa.catapult_detector()
        steady = [10.0 * (1 + 0.01 * ((i * 7) % 5 - 2)) for i in range(20)]
        self.assertEqual(aa.change_points(steady, detector, {}), aa.Steps(0, 0))
        stepped = steady[:10] + [value * 1.5 for value in steady[10:]]
        self.assertEqual(aa.change_points(stepped, detector, {}), aa.Steps(1, 1))
        self.assertEqual(aa.change_points(stepped, detector, {}, "higher"), aa.Steps(0, 1))
        floored = {"min_absolute_change": 100.0}
        self.assertEqual(aa.change_points(stepped, detector, floored), aa.Steps(0, 0))


class SubscriptionConfigTests(unittest.TestCase):
    def configs(self, entry):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "subscriptions.json"
            path.write_text(json.dumps({"build_configs": ["bench"], "subscriptions": [entry]}))
            return aa.subscription_configs(path)

    def test_matching_series_gets_its_override_raised_to_the_catalog_floor(self):
        entry = {"name": "home", "kind": "family", "owner": "PL-typing", "match": {"story": "home-idle"},
                 "anomaly_config": {"min_absolute_change": 0.5, "min_relative_change": 0.2}}
        config = self.configs(entry)
        # home-idle's home.typing.key_dispatch floor is 1.0 in stories.d; a subscription never goes below it.
        self.assertEqual(config(_series()), {"min_absolute_change": 1.0, "min_relative_change": 0.2})
        entry["anomaly_config"]["min_absolute_change"] = 2.0
        self.assertEqual(self.configs(entry)(_series())["min_absolute_change"], 2.0)

    def test_unmatched_series_or_build_config_is_unmonitored(self):
        config = self.configs({"name": "home", "kind": "family", "owner": "PL-typing",
                               "match": {"story": "home-idle"}})
        self.assertIsNone(config(_series(story="other-story")))
        self.assertIsNone(config(_series(build_config="debug")))
        self.assertEqual(config(_series(metric="no.floor.metric")), {})

    def test_bad_subscriptions_file_is_a_typed_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "subscriptions.json"
            path.write_text("{")
            with self.assertRaises(aa.AAError):
                aa.subscription_configs(path)

    def test_the_checked_in_subscriptions_load(self):
        self.assertTrue(callable(aa.subscription_configs()))


class CLITests(unittest.TestCase):
    def test_missing_store_is_a_typed_error(self):
        with self.assertRaises(aa.AAError):
            aa.aa_report(_args("/nonexistent/lab.db", days=1), detector=NoChangePoints(),
                         configs=monitor_all_but_unmonitored, out=io.StringIO())

    def test_main_reports_errors_with_exit_2(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(aa.main(["--days", "1", "--db", ""]), 2)
        self.assertIn("lab.py aa: no lab store", stderr.getvalue())

    def test_lab_py_dispatches_aa(self):
        self.assertIn("aa", lab.discover(LAB))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(lab.main(["aa", "--db", "/nonexistent/lab.db", "--days", "1"]), 2)
        self.assertIn("lab.py aa: /nonexistent/lab.db: no lab store", stderr.getvalue())

    def test_lab_py_rejects_both_windows(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            lab.main(["aa", "--since-live", "--days", "3"])

    def test_lab_py_runs_the_report_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Fixture(Path(tmp))
            try:
                for night in range(1, 4):
                    fixture.pair(night=night, a=STEADY, b=list(STEADY), story="home-idle",
                                 metric="home.typing.key_dispatch")
            finally:
                fixture.close()
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(lab.main(["aa", "--db", str(fixture.path), "--days", "30", "--json"]), 0)
        result = json.loads(out.getvalue())
        self.assertEqual(result["summary"]["series_days"], 3)
        self.assertEqual(result["summary"]["false_alerts"], 0)


if __name__ == "__main__":
    unittest.main()
