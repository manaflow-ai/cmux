#!/usr/bin/env python3
"""aa.py: A/A pairing, CV of median and p99, false-alert rate and the noisy-series list on a fixture store.

  python3 -m unittest scripts/perf-lab/tests/test_aa.py
"""
from __future__ import annotations

import argparse
import importlib.util
import io
import json
import math
import sys
import tempfile
import unittest
import unittest.mock
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, LAB / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load("perf_lab_store", "store.py")
aa = _load("perf_lab_aa", "aa.py")

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
HOST_A = store.Host(name="cmux15", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-15")
HOST_B = store.Host(name="cmux16", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-16")
STEADY = [10.0, 10.1, 9.9, 10.0, 10.2, 9.8, 10.0, 10.1, 9.9, 10.0]


@dataclass(frozen=True)
class FakeChangePoint:
    x_value: int


def no_change_points(series):
    return []


class ThresholdDetector:
    """Flags the first ratio over 1.2 (or under 1/1.2) once it is in the series, like a step detector."""

    def __init__(self):
        self.calls = 0

    def __call__(self, series):
        self.calls += 1
        for x, ratio in series:
            if ratio > 1.2 or ratio < 1 / 1.2:
                return [FakeChangePoint(x)]
        return []


def monitor_all_but_unmonitored(series):
    return series.story != "unmonitored.story"


class Fixture:
    def __init__(self, directory: Path):
        self.path = directory / "lab.db"
        self.db = store.Store(self.path, clock=lambda: NOW)
        self.db.migrate()
        self.count = 0

    def close(self):
        self.db.close()

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
             story="terminal.key-frame.light"):
        start = NOW - timedelta(days=night, hours=6)
        sha = f"{night:040d}"
        for offset, samples in ((0, a), (1, b)):
            self.run(host=host, sha=sha, pos=1000 - night, started_at=start + timedelta(minutes=offset * 10),
                     story=story, metrics=[(metric, unit, samples)])


def _scaled(samples, factor):
    return [value * factor for value in samples]


def _expected_cv(pairs):
    return math.sqrt(sum(((a - b) / ((a + b) / 2)) ** 2 for a, b in pairs) / (2 * len(pairs)))


def _args(db, **overrides):
    values = dict(db=str(db), since_live=False, days=None, cv_over=None, p99_cv_over=None, min_pairs=aa.MIN_PAIRS,
                  json=True)
    values.update(overrides)
    return argparse.Namespace(**values)


class DuplicateCVTests(unittest.TestCase):
    def test_root_mean_square_cv_of_pairs(self):
        pairs = [(100.0, 110.0), (100.0, 100.0), (50.0, 45.0)]
        self.assertAlmostEqual(aa.duplicate_cv(pairs), _expected_cv(pairs), places=12)

    def test_identical_pairs_have_zero_cv(self):
        self.assertEqual(aa.duplicate_cv([(3.0, 3.0), (0.0, 0.0)]), 0.0)

    def test_no_usable_pair_is_none(self):
        self.assertIsNone(aa.duplicate_cv([]))
        self.assertIsNone(aa.duplicate_cv([(1.0, -1.0)]))

    def test_change_points_counted_once_over_prefixes(self):
        series = [(0, 1.0), (1, 1.0), (2, 1.5), (3, 1.0), (4, 1.0)]
        detector = ThresholdDetector()
        self.assertEqual(aa.change_points(series, detector), 1)
        self.assertEqual(detector.calls, len(series))


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fixture = Fixture(Path(self.tmp.name))

    def tearDown(self):
        self.fixture.close()
        self.tmp.cleanup()

    def report(self, detector=no_change_points, **overrides):
        out = io.StringIO()
        code = aa.run(_args(self.fixture.path, **overrides), clock=lambda: NOW, detector=detector,
                      monitored=monitor_all_but_unmonitored, out=out)
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
        # A whole-sample shift of 2 % or more is a real A/B difference to Pinpoint's compare at n = 10.
        strict = sum(aa.perf_stats.compare(STEADY, _scaled(STEADY, f)).original.result == aa.perf_stats.DIFFERENT
                     for f in factors)
        self.assertEqual(strict, 3)
        self.assertEqual(row["false_alerts"], strict)
        summary = result["summary"]
        self.assertEqual(summary["series_days"], 4)
        self.assertAlmostEqual(summary["false_alerts_per_100_series_days"], 75.0)
        self.assertEqual(summary["median_cv_share_within"], 1.0)
        self.assertEqual(summary["checks"], {"false_alerts": False, "median_cv": True, "p99_cv": True})
        self.assertEqual(summary["aa_runs_by_host"], {"cmux15": 4})
        self.assertEqual(summary["hosts_under_min_aa_runs"], [])

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
        # Night 2 is a real difference between A and B; the ratio detector also sees it in the median and p99.
        shifted = _scaled(STEADY, 1.5)
        for night in range(1, 11):
            self.fixture.pair(night=night, a=STEADY, b=shifted if night == 2 else list(STEADY))
        result = self.report(detector=ThresholdDetector(), days=30)
        (row,) = result["series"]
        comparison = aa.perf_stats.compare(STEADY, shifted)
        self.assertEqual(comparison.original.result, aa.perf_stats.DIFFERENT)
        self.assertEqual(row["compare_different_strict"], 1)
        self.assertEqual(row["compare_different_bisect"], 1)
        self.assertEqual(row["anomaly_alerts_median"], 1)
        self.assertEqual(row["anomaly_alerts_p99"], 1)
        self.assertEqual(row["false_alerts"], 3)
        self.assertAlmostEqual(row["false_alerts_per_100"], 30.0)
        summary = result["summary"]
        self.assertAlmostEqual(summary["false_alerts_per_100_series_days"], 30.0)
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

    def test_noisy_series_listed_by_median_or_p99_cv(self):
        quiet, noisy_median, noisy_tail = "quiet_ms", "noisy_ms", "tail_ms"
        tail_b = STEADY[:-1] + [15.0]
        for night in range(1, 5):
            factor = 1.15 if night % 2 else 0.88
            self.fixture.pair(night=night, a=STEADY, b=_scaled(STEADY, 1.01), metric=quiet)
            self.fixture.pair(night=night, a=STEADY, b=_scaled(STEADY, factor), metric=noisy_median)
            self.fixture.pair(night=night, a=STEADY, b=tail_b, metric=noisy_tail)
        listed = self.report(days=30, cv_over=0.05)
        self.assertEqual([row["metric"] for row in listed], [noisy_median, noisy_tail])
        self.assertGreater(listed[0]["cv_median"], 0.05)
        self.assertLessEqual(listed[1]["cv_median"], 0.05)
        self.assertGreater(listed[1]["cv_p99"], 0.10)
        only_median = self.report(days=30, cv_over=0.05, p99_cv_over=10.0)
        self.assertEqual([row["metric"] for row in only_median], [noisy_median])

    def test_series_with_too_few_pairs_is_not_listed_or_judged(self):
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
        aa.run(_args(self.fixture.path, days=30, json=False), clock=lambda: NOW, detector=no_change_points,
               monitored=monitor_all_but_unmonitored, out=out)
        text = out.getvalue()
        self.assertIn("false alerts: 0 (0.00 per 100 series-days, limit 1) ok", text)
        self.assertIn("host cmux15: 3 A/A runs", text)


class CLITests(unittest.TestCase):
    def test_missing_store_is_a_typed_error(self):
        with self.assertRaises(aa.AAError):
            aa.run(_args("/nonexistent/lab.db", days=1), detector=no_change_points,
                   monitored=monitor_all_but_unmonitored, out=io.StringIO())

    def test_main_reports_errors_with_exit_2(self):
        stderr = io.StringIO()
        real = sys.stderr
        sys.stderr = stderr
        try:
            self.assertEqual(aa.main(["--days", "1"]), 2)
        finally:
            sys.stderr = real
        self.assertIn("lab.py aa: no lab store", stderr.getvalue())

    def test_register_adds_the_aa_subcommand(self):
        parser = argparse.ArgumentParser()
        aa.register(parser.add_subparsers())
        args = parser.parse_args(["aa", "--db", "x.db", "--cv-over", "0.05", "--json"])
        self.assertEqual((args.db, args.cv_over, args.json), ("x.db", 0.05, True))
        with self.assertRaises(SystemExit), unittest.mock.patch("sys.stderr", io.StringIO()):
            parser.parse_args(["aa", "--since-live", "--days", "3"])


if __name__ == "__main__":
    unittest.main()
