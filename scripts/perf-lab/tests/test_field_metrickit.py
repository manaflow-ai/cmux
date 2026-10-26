#!/usr/bin/env python3
"""field_metrickit.py: schema-2 decode of every metric field, histogram percentiles and field rows.

  python3 -m unittest scripts/perf-lab/tests/test_field_metrickit.py

The fixture payload has the shape of hang-reports-DESIGN.md section 4 (what HangReport.encoder writes).
"""
from __future__ import annotations

import copy
import dataclasses
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

FIELD_PY = Path(__file__).resolve().parent.parent / "field_metrickit.py"
_SPEC = importlib.util.spec_from_file_location("perf_lab_field_metrickit", FIELD_PY)
fm = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = fm
_SPEC.loader.exec_module(fm)

SECRET = "s3cr3t-Pa55"


def bucket(low, high, count):
    return {"lowMs": low, "highMs": high, "count": count}


PAYLOAD = {
    "schema": 2,
    "reportId": "5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11",
    "installId": "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20",
    "day": "2026-10-23",
    "app": {"version": "0.70.0", "build": "2123456789012", "channel": "nightly"},
    "os": {"version": "15.7.4"},
    "hardware": {"arch": "arm64", "chip": "Apple M4 Pro", "cores": 14, "memoryGB": 48},
    "counts": {"windows": "1", "workspaces": "11-30", "panes": "6-10", "tabs": "31-100"},
    "hangs": [{"source": "metrickit", "kind": "hang", "durationMs": 2340, "cpuMs": None, "frames": []}],
    "cpuExceptions": [],
    "stallHistogram": [bucket(50, 100, 12), bucket(250, 500, 3), bucket(10_000, 86_400_000, 1)],
    "metrics": {
        "hangTime": [bucket(0, 100, 40), bucket(100, 400, 10)],
        "launchFirstDraw": [bucket(200, 300, 6), bucket(300, 400, 3), bucket(1000, 2000, 1)],
        "launchResume": [bucket(10, 20, 4)],
        "launchOptimizedFirstDraw": [bucket(100, 200, 2)],
        "launchExtended": [bucket(500, 1000, 1)],
        "scrollHitchMsPerS": 1.5,
        "hitchMsPerS": 4.0,
    },
    "intervals": [
        {"category": "action", "name": "action.commit", "count": 100,
         "buckets": [bucket(0, 10, 90), bucket(10, 20, 10)], "hitchMsPerS": None},
        {"category": "motion", "name": "motion.frame", "count": 1200,
         "buckets": [bucket(0, 10, 1100), bucket(10, 20, 100)], "hitchMsPerS": 0.4},
    ],
}


def row(payload=None, **overrides):
    base = {"app_version": "0.70.0", "app_build": "2123456789012", "channel": "nightly", "arch": "arm64",
            "chip": "Apple M4 Pro", "cores": 14, "memory_gb": 48,
            "payload": copy.deepcopy(PAYLOAD if payload is None else payload)}
    base.update(overrides)
    return base


def rows_by_metric(result, build=None):
    return {r.metric: r for r in result.rows if build is None or r.build == build}


class DecodeTests(unittest.TestCase):
    def test_every_metric_field_decodes(self):
        report = fm.decode_payload(PAYLOAD)
        B = fm.Bucket
        self.assertEqual(report.histograms["hangTime"], (B(0, 100, 40), B(100, 400, 10)))
        self.assertEqual(report.histograms["launchFirstDraw"], (B(200, 300, 6), B(300, 400, 3), B(1000, 2000, 1)))
        self.assertEqual(report.histograms["launchResume"], (B(10, 20, 4),))
        self.assertEqual(report.histograms["launchOptimizedFirstDraw"], (B(100, 200, 2),))
        self.assertEqual(report.histograms["launchExtended"], (B(500, 1000, 1),))
        self.assertEqual(report.ratios, {"scrollHitchMsPerS": 1.5, "hitchMsPerS": 4.0})
        self.assertEqual(report.stall_histogram, (B(50, 100, 12), B(250, 500, 3), B(10_000, 86_400_000, 1)))
        self.assertEqual(report.intervals[0], fm.Interval("action", "action.commit", 100,
                                                          (B(0, 10, 90), B(10, 20, 10)), None))
        self.assertEqual(report.intervals[1].hitch_ms_per_s, 0.4)

    def test_every_wire_metric_key_is_decoded(self):
        self.assertEqual(set(PAYLOAD["metrics"]), fm.METRICS_KEYS)

    def test_empty_metrics_decode_to_empty(self):
        report = fm.decode_payload({"schema": 2, "metrics": {"hangTime": [], "scrollHitchMsPerS": None}})
        self.assertTrue(all(not buckets for buckets in report.histograms.values()))
        self.assertEqual(report.ratios, {"scrollHitchMsPerS": None, "hitchMsPerS": None})
        self.assertEqual((report.stall_histogram, report.intervals), ((), ()))

    def assertRefused(self, payload, reason):
        with self.assertRaises(fm.FieldDecodeError) as caught:
            fm.decode_payload(payload)
        self.assertEqual(caught.exception.reason, reason)

    def test_refuses_other_schemas(self):
        for schema in (1, 3, "2", None):
            self.assertRefused({**PAYLOAD, "schema": schema}, "schema")

    def test_refuses_what_the_server_would(self):
        def mutate(fn):
            payload = copy.deepcopy(PAYLOAD)
            fn(payload)
            return payload
        self.assertRefused(mutate(lambda p: p["metrics"].update(extra=1)), "unknown_key")
        self.assertRefused(mutate(lambda p: p["metrics"]["hangTime"].append({"lowMs": 0, "highMs": 1})), "missing_key")
        self.assertRefused(mutate(lambda p: p["metrics"]["hangTime"].__setitem__(0, bucket(5, 1, 1))), "out_of_range")
        self.assertRefused(mutate(lambda p: p["metrics"]["hangTime"].__setitem__(0, bucket(0, 1, -1))), "out_of_range")
        self.assertRefused(mutate(lambda p: p["metrics"]["hangTime"].__setitem__(0, bucket(0, 86_400_001, 1))),
                           "out_of_range")
        self.assertRefused(mutate(lambda p: p["metrics"]["hangTime"].__setitem__(0, bucket(0, 1.5, 1))), "bad_type")
        self.assertRefused(mutate(lambda p: p["metrics"]["hangTime"].__setitem__(0, bucket(0, True, 1))), "bad_type")
        self.assertRefused(mutate(lambda p: p["metrics"].update(launchResume=[bucket(0, 1, 1)] * 33)), "over_limit")
        self.assertRefused(mutate(lambda p: p["metrics"].update(hitchMsPerS=float("nan"))), "bad_type")
        self.assertRefused(mutate(lambda p: p["metrics"].update(hitchMsPerS=-1)), "bad_type")
        self.assertRefused(mutate(lambda p: p["intervals"][0].update(category="stall")), "bad_interval")
        self.assertRefused(mutate(lambda p: p["intervals"][0].update(name="Has Space")), "bad_interval")
        self.assertRefused(mutate(lambda p: p.update(intervals=p["intervals"] * 33)), "over_limit")
        self.assertRefused(mutate(lambda p: p["intervals"][0].update(message="x")), "unknown_key")


class PercentileTests(unittest.TestCase):
    B = fm.Bucket

    def test_catapult_approximate_percentile(self):
        # 10 values: floor(9 * 0.5) = 4 skipped -> 5th value is in [200, 300) -> center 250.
        buckets = (self.B(200, 300, 6), self.B(300, 400, 3), self.B(1000, 2000, 1))
        self.assertEqual(fm.histogram_percentile(buckets, 0.5), 250)
        # floor(9 * 0.95) = 8 skipped -> 9th value is in [300, 400) -> 350.
        self.assertEqual(fm.histogram_percentile(buckets, 0.95), 350)
        self.assertEqual(fm.histogram_percentile(buckets, 1.0), 1500)
        self.assertEqual(fm.histogram_percentile(buckets, 0.0), 250)

    def test_open_top_bucket_reports_its_low_edge(self):
        self.assertEqual(fm.histogram_percentile((self.B(10_000, fm.MAX_MS, 3),), 0.95), 10_000)

    def test_empty_is_none(self):
        self.assertIsNone(fm.histogram_percentile((), 0.5))
        self.assertIsNone(fm.histogram_percentile((self.B(0, 10, 0),), 0.5))
        with self.assertRaises(ValueError):
            fm.histogram_percentile((self.B(0, 10, 1),), 1.5)

    def test_merge_sums_repeated_edges(self):
        merged = fm.merge_buckets([(self.B(0, 10, 2), self.B(10, 20, 0)), (self.B(0, 10, 3), self.B(5, 10, 1))])
        self.assertEqual(merged, (self.B(0, 10, 5), self.B(5, 10, 1)))


class AggregateTests(unittest.TestCase):
    def test_one_report_gives_launch_hitch_hang_and_action_rows(self):
        result = fm.aggregate([row()])
        self.assertEqual((result.reports, result.skipped), (1, {}))
        by = rows_by_metric(result)
        self.assertEqual({r.build for r in result.rows}, {"0.70.0+2123456789012"})
        self.assertEqual({r.hardware_class for r in result.rows}, {"arm64/apple-m4-pro/48gb/14c"})
        self.assertEqual({r.arm for r in result.rows}, {"default"})
        self.assertEqual((by["launch.first_draw.p50"].value, by["launch.first_draw.p95"].value), (250, 350))
        self.assertEqual((by["launch.first_draw.p50"].unit, by["launch.first_draw.p50"].samples), ("ms", 10))
        self.assertEqual(by["launch.resume.p50"].value, 15)
        self.assertEqual(by["launch.optimized_first_draw.p95"].value, 150)
        self.assertEqual(by["launch.extended.p50"].value, 750)
        self.assertEqual((by["hang.time.p50"].value, by["hang.time.p95"].value), (50, 250))
        # 16 stalls: p95 skips floor(15 * 0.95) = 14 -> the 15th value is in [250, 500) -> 375.
        self.assertEqual((by["hang.stall.p50"].value, by["hang.stall.p95"].value), (75, 375))
        self.assertEqual((by["hang.stalls_over_250ms"].value, by["hang.stalls_over_250ms"].unit), (4, "count"))
        self.assertEqual((by["hitch.scroll.p50"].value, by["hitch.scroll.p50"].unit), (1.5, "ms/s"))
        self.assertEqual(by["hitch.all.p95"].value, 4.0)
        self.assertEqual((by["interval.action.commit.p50"].value, by["interval.action.commit.p95"].value), (5, 15))
        self.assertEqual(by["interval.action.commit.p50"].samples, 100)
        self.assertNotIn("interval.action.commit.hitch.p50", by)
        self.assertEqual(by["interval.motion.frame.hitch.p50"].value, 0.4)

    def test_reports_fold_per_build_and_hardware_class(self):
        second = copy.deepcopy(PAYLOAD)
        second["metrics"].update(scrollHitchMsPerS=3.5, launchFirstDraw=[bucket(1000, 2000, 10)])
        other_build = row(app_build="2123456789999")
        other_mac = row(chip="Apple M2", memory_gb=16, cores=8)
        result = fm.aggregate([row(), row(second), other_build, other_mac])
        grouped = {(r.build, r.hardware_class) for r in result.rows}
        self.assertEqual(grouped, {("0.70.0+2123456789012", "arm64/apple-m4-pro/48gb/14c"),
                                   ("0.70.0+2123456789999", "arm64/apple-m4-pro/48gb/14c"),
                                   ("0.70.0+2123456789012", "arm64/apple-m2/16gb/8c")})
        folded = {r.metric: r for r in result.rows
                  if r.build == "0.70.0+2123456789012" and r.hardware_class == "arm64/apple-m4-pro/48gb/14c"}
        # 20 first draws: 6 + 3 in the low buckets, 11 in [1000, 2000): p50 skips 9 -> [1000, 2000).
        self.assertEqual((folded["launch.first_draw.p50"].value, folded["launch.first_draw.p50"].samples), (1500, 20))
        # Two reports: scroll hitch 1.5 and 3.5 -> perf_stats.pct linear p50 2.5, p95 3.4.
        self.assertEqual(folded["hitch.scroll.p50"].value, 2.5)
        self.assertAlmostEqual(folded["hitch.scroll.p95"].value, 3.4)
        self.assertEqual(folded["hitch.scroll.p50"].samples, 2)
        self.assertEqual(folded["hang.stalls_over_250ms"].value, 8)
        self.assertEqual(result.reports, 4)

    def test_bad_rows_are_skipped_whole_and_counted(self):
        broken = copy.deepcopy(PAYLOAD)
        broken["metrics"]["launchResume"] = [bucket(9, 1, 1)]
        rows = [row(), row(broken), row({**PAYLOAD, "schema": 1}), row(channel="release"),
                row(app_build=None), row(chip=None), row(payload="{not json"), row(payload=json.dumps(PAYLOAD))]
        result = fm.aggregate(rows)
        self.assertEqual(result.reports, 2)
        self.assertEqual(result.skipped, {"bad_json": 1, "channel": 1, "no_build": 1, "no_hardware": 1,
                                          "out_of_range": 1, "schema": 1})
        self.assertEqual(rows_by_metric(result)["launch.resume.p50"].samples, 8)

    def test_no_channel_filter_keeps_every_channel(self):
        self.assertEqual(fm.aggregate([row(channel="release")], channel=None).reports, 1)

    def test_report_without_metrics_gives_only_the_stall_count(self):
        result = fm.aggregate([row({"schema": 2, "metrics": {}})])
        self.assertEqual([(r.metric, r.value) for r in result.rows], [("hang.stalls_over_250ms", 0.0)])


class ReadTests(unittest.TestCase):
    URL = f"postgresql://reader:{SECRET}@aws.connect.psdb.cloud:6432/cmux-prod?sslmode=verify-full"

    def test_select_is_read_only_and_validated(self):
        sql = fm.select_sql(since_days=7, channel="nightly")
        self.assertTrue(sql.startswith("BEGIN READ ONLY;"))
        self.assertIn("FROM hang_reports WHERE received_at >= now() - interval '7 days' AND channel = 'nightly'", sql)
        statements = [s.strip().split()[0].upper() for s in sql.split(";") if s.strip()]
        self.assertEqual(statements, ["BEGIN", "SELECT", "COMMIT"])
        for bad in ({"since_days": 0, "channel": None}, {"since_days": True, "channel": None},
                    {"since_days": 7, "channel": "nightly'; DROP TABLE x; --"}):
            with self.assertRaises(ValueError):
                fm.select_sql(**bad)

    def test_libpq_environment(self):
        env = fm.libpq_environment(self.URL)
        self.assertEqual(env["PGHOST"], "aws.connect.psdb.cloud")
        self.assertEqual((env["PGPORT"], env["PGUSER"], env["PGPASSWORD"]), ("6432", "reader", SECRET))
        self.assertEqual((env["PGDATABASE"], env["PGSSLMODE"], env["PGSSLROOTCERT"]), ("cmux-prod", "verify-full", "system"))
        self.assertIn("default_transaction_read_only=on", env["PGOPTIONS"])
        weak = fm.libpq_environment("postgres://u:p@h/db?sslmode=require")
        self.assertEqual(weak["PGSSLMODE"], "require")
        self.assertNotIn("PGSSLROOTCERT", weak)
        with self.assertRaises(fm.FieldReadError):
            fm.libpq_environment("mysql://u:p@h/db")

    def test_credential_never_in_argv_and_rows_parse(self):
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            out = json.dumps(row()) + "\n\n"
            return subprocess.CompletedProcess(argv, 0, stdout=out, stderr="")

        environ = {fm.DATABASE_URL_ENV: self.URL, "PGHOST": "stray", "PATH": "/usr/bin"}
        rows = fm.read_rows(since_days=7, channel="nightly", environ=environ, run=run)
        self.assertEqual(len(rows), 1)
        argv, kwargs = calls[0]
        self.assertEqual(argv[0], "psql")
        self.assertFalse(any(SECRET in arg or "psdb" in arg for arg in argv))
        self.assertNotIn(SECRET, kwargs["input"])
        self.assertNotIn(fm.DATABASE_URL_ENV, kwargs["env"])
        self.assertEqual((kwargs["env"]["PGHOST"], kwargs["env"]["PGPASSWORD"]), ("aws.connect.psdb.cloud", SECRET))
        self.assertEqual(kwargs["env"]["PATH"], "/usr/bin")

    def test_failure_message_hides_the_password(self):
        def run(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 2, stdout="", stderr=f"FATAL: password {SECRET} rejected\nmore")

        with self.assertRaises(fm.FieldReadError) as caught:
            fm.read_rows(since_days=7, channel=None, environ={fm.DATABASE_URL_ENV: self.URL}, run=run)
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertIn("psql exited 2", str(caught.exception))

    def test_missing_credential(self):
        with self.assertRaises(fm.FieldReadError):
            fm.read_rows(since_days=7, channel=None, environ={}, run=lambda *a, **k: self.fail("ran psql"))

    def test_cli_reads_a_rows_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rows.ndjson"
            path.write_text("\n".join(json.dumps(r) for r in (row(), row(channel="dev"))) + "\n")
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(fm.main(["--rows", str(path), "--json"]), 0)
            doc = json.loads(out.getvalue())
            self.assertEqual((doc["reports"], doc["skipped"]), (1, {"channel": 1}))
            self.assertIn("launch.first_draw.p95", {r["metric"] for r in doc["rows"]})
            text = io.StringIO()
            with redirect_stdout(text):
                self.assertEqual(fm.main(["--rows", str(path), "--channel", "dev"]), 0)
            self.assertIn("interval.action.commit.p50\t5 ms", text.getvalue())


DASHBOARD_PY = FIELD_PY.parent / "dashboard.py"


@unittest.skipUnless(DASHBOARD_PY.exists(), "dashboard.py (task 013) is not on this branch")
class FieldTabTests(unittest.TestCase):
    def test_field_tab_shows_launch_percentiles_and_hitch_per_nightly(self):
        spec = importlib.util.spec_from_file_location("perf_lab_dashboard_for_field", DASHBOARD_PY)
        dashboard = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = dashboard
        spec.loader.exec_module(dashboard)
        self.assertEqual([f.name for f in dataclasses.fields(dashboard.FieldRow)],
                         [f.name for f in dataclasses.fields(fm.FieldRow)])
        result = fm.aggregate([row(), row(app_build="2123456789999")])
        html = dashboard.render_field([dashboard.FieldRow(**dataclasses.asdict(r)) for r in result.rows])
        for build in ("0.70.0+2123456789012", "0.70.0+2123456789999"):
            self.assertIn(build, html)
        for metric in ("launch.first_draw.p50", "launch.first_draw.p95", "hitch.scroll.p50", "hitch.all.p95"):
            self.assertIn(metric, html)
        self.assertIn("1.50 ms/s", html)


if __name__ == "__main__":
    unittest.main()
