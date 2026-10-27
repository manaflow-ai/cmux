#!/usr/bin/env python3
"""field_metrickit.py: every schema-2 metric field decodes, wire limits skip a report, series per build and
hardware class, the Field tab shows launch p50/p95 and hitch ms/s per Nightly, and the read is field.py's.

  python3 -m unittest scripts/perf-lab/tests/test_field_metrickit.py
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
import unittest.mock
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


fm = _load("perf_lab_field_metrickit", "field_metrickit.py")
field = _load("perf_lab_field", "field.py")
lab = _load("perf_lab_lab", "lab.py")
dashboard = _load("perf_lab_dashboard", "dashboard.py")

PASSWORD = "pscale_pw_S3cret+/x"
URL = (f"postgresql://field-ro.{field.BRANCH_ID}:{PASSWORD.replace('+', '%2B').replace('/', '%2F')}"
       "@us-east-3.pg.psdb.cloud:5432/postgres?sslmode=verify-full")
ENVIRON = {field.URL_ENV: URL, "PATH": "/usr/bin", "HOME": "/home/lab"}
OPEN = fm.MAX_MS


def b(low, high, count):
    return {"lowMs": low, "highMs": high, "count": count}


# One query row: the keys reports_query selects, with the payload parts of a schema-2 report
# (HangReport.Metrics, stallHistogram and IntervalHistogram as the client encodes them).
ROW = {
    "app_version": "0.71.0", "app_build": "2001", "chip": "Apple M4 Pro", "memory_gb": 24,
    "features_hash": "0123456789abcdef", "schema": 2,
    "metrics": {
        "hangTime": [b(0, 100, 40), b(100, 400, 10)],
        "launchFirstDraw": [b(200, 300, 6), b(300, 400, 3), b(1000, 2000, 1)],
        "launchResume": [b(10, 20, 4)],
        "launchOptimizedFirstDraw": [b(100, 200, 2)],
        "launchExtended": [b(500, 1000, 1)],
        "scrollHitchMsPerS": 1.5,
        "hitchMsPerS": 4.0,
    },
    "stall_histogram": [b(50, 100, 12), b(250, 500, 3), b(10_000, OPEN, 1)],
    "intervals": [
        {"category": "action", "name": "action.commit", "count": 100,
         "buckets": [b(0, 10, 90), b(10, 20, 10)], "hitchMsPerS": None},
        {"category": "motion", "name": "motion.frame", "count": 1200,
         "buckets": [b(0, 10, 1100), b(10, 20, 100)], "hitchMsPerS": 0.4},
        {"category": "main", "name": "main_turn", "count": 5, "buckets": [b(0, 4, 5)]},
    ],
}


def row(**overrides):
    out = copy.deepcopy(ROW)
    out.update(overrides)
    return out


def metrics(**overrides):
    out = copy.deepcopy(ROW["metrics"])
    out.update(overrides)
    return out


def by_metric(rows, build=None):
    return {r["metric"]: r for r in rows if build is None or r["build"] == build}


class FakePsql:
    def __init__(self, *, rows=(), privileges=None):
        self.calls = []
        self.rows = list(rows)
        self.privileges = privileges or {name.lower(): False for name in field.WRITE_PRIVILEGES}

    def __call__(self, argv, env, script):
        self.calls.append((list(argv), dict(env), script))
        if "has_table_privilege" in script:
            return 0, json.dumps(self.privileges) + "\n", ""
        return 0, "".join(json.dumps(r) + "\n" for r in self.rows), ""


class DecodeTests(unittest.TestCase):
    def test_every_metric_field_decodes(self):
        report = fm.decode_report(ROW)
        self.assertEqual(report.histograms["hangTime"], ((0, 100, 40), (100, 400, 10)))
        self.assertEqual(report.histograms["launchFirstDraw"], ((200, 300, 6), (300, 400, 3), (1000, 2000, 1)))
        self.assertEqual(report.histograms["launchResume"], ((10, 20, 4),))
        self.assertEqual(report.histograms["launchOptimizedFirstDraw"], ((100, 200, 2),))
        self.assertEqual(report.histograms["launchExtended"], ((500, 1000, 1),))
        self.assertEqual(report.ratios, {"scrollHitchMsPerS": 1.5, "hitchMsPerS": 4.0})
        self.assertEqual(report.stalls, ((50, 100, 12), (250, 500, 3), (10_000, 10_000, 1)))
        self.assertEqual([i.name for i in report.intervals], ["action.commit", "motion.frame"])
        self.assertEqual(report.intervals[0].buckets, ((0, 10, 90), (10, 20, 10)))
        self.assertIsNone(report.intervals[0].hitch_ms_per_s)
        self.assertEqual(report.intervals[1].hitch_ms_per_s, 0.4)

    def test_every_wire_key_of_metrics_is_decoded(self):
        swift = (LAB.parent.parent / "Packages/macOS/CmuxNext/Sources/CmuxNextHangReports/HangReport.swift")
        text = swift.read_text(encoding="utf-8")
        start = text.index("public struct Metrics")
        body = text[start:text.index("public init()", start)]
        declared = {line.split("public var ", 1)[1].split(":", 1)[0].strip()
                    for line in body.splitlines() if "public var " in line}
        decoded = {key for key, _ in fm.HISTOGRAM_METRICS} | {key for key, _ in fm.RATIO_METRICS}
        self.assertEqual(declared, decoded)

    def test_schema_3_keeps_its_schema_2_fields(self):
        report = fm.decode_report(row(schema=3))
        self.assertEqual(report.ratios["hitchMsPerS"], 4.0)

    def test_absent_and_null_fields_are_empty(self):
        report = fm.decode_report({"schema": 2})
        self.assertTrue(all(buckets == () for buckets in report.histograms.values()))
        self.assertEqual(report.ratios, {"scrollHitchMsPerS": None, "hitchMsPerS": None})
        self.assertEqual((report.stalls, report.intervals), ((), ()))
        report = fm.decode_report(row(metrics={"hangTime": None, "hitchMsPerS": None}, stall_histogram=None,
                                      intervals=None))
        self.assertEqual(report.histograms["hangTime"], ())

    def test_zero_count_buckets_are_dropped(self):
        self.assertEqual(fm.decode_buckets([b(0, 10, 0), b(10, 20, 2)], "x"), ((10, 20, 2),))

    def test_wire_limit_breaks_skip_the_report_by_reason(self):
        cases = {
            "schema": [row(schema=1), row(schema=None), row(schema=True), row(schema="2")],
            "bad_metrics": [row(metrics=[1])],
            "over_limit": [row(metrics=metrics(hangTime=[b(i, i + 1, 1) for i in range(fm.MAX_BUCKETS + 1)])),
                           row(intervals=[ROW["intervals"][0]] * (fm.MAX_INTERVALS + 1))],
            "bad_bucket": [row(metrics=metrics(launchResume=[b(20, 10, 1)])),
                           row(metrics=metrics(launchResume=[b(0, fm.MAX_MS + 1, 1)])),
                           row(metrics=metrics(launchResume=[b(0, 10, True)])),
                           row(metrics=metrics(launchResume=[b(0, 10, -1)])),
                           row(metrics=metrics(launchResume=[{"lowMs": 0, "count": 1}])),
                           row(metrics=metrics(launchResume={"lowMs": 0})),
                           row(stall_histogram=[b(0, 10.5, 1)])],
            "bad_ratio": [row(metrics=metrics(hitchMsPerS=1001)), row(metrics=metrics(hitchMsPerS=float("nan"))),
                          row(metrics=metrics(scrollHitchMsPerS=-1)), row(metrics=metrics(hitchMsPerS="4")),
                          row(intervals=[dict(ROW["intervals"][1], hitchMsPerS=True)])],
            "bad_interval": [row(intervals=[dict(ROW["intervals"][0], category="stall")]),
                             row(intervals=[dict(ROW["intervals"][0], name="Action Commit")]),
                             row(intervals=[dict(ROW["intervals"][0], count=-1)]),
                             row(intervals=["action.commit"]), row(intervals={"name": "x"})],
        }
        for reason, rows in cases.items():
            with self.subTest(reason):
                result = fm.aggregate(rows)
                self.assertEqual(result.skipped, {reason: len(rows)})
                self.assertEqual((result.reports, result.groups), (0, []))


class AggregationTests(unittest.TestCase):
    def test_series_per_build_hardware_class_and_arm(self):
        second = row(metrics=metrics(launchFirstDraw=[b(200, 300, 4)], hitchMsPerS=2.0, scrollHitchMsPerS=None))
        other_build = row(app_build="2002", metrics={"launchFirstDraw": [b(100, 200, 1)]}, stall_histogram=[],
                          intervals=[])
        result = fm.aggregate([ROW, second, other_build, row(schema=1)])
        self.assertEqual(result.reports, 3)
        self.assertEqual(result.skipped, {"schema": 1})
        self.assertEqual([(g.build, g.hardware_class, g.arm, g.reports) for g in result.groups],
                         [("0.71.0 (2001)", field.hardware_class("Apple M4 Pro", 24), "0123456789abcdef", 2),
                          ("0.71.0 (2002)", "apple-m4-pro/24gb", "0123456789abcdef", 1)])
        rows = by_metric(fm.field_rows(result.groups), "0.71.0 (2001)")
        # Merged launchFirstDraw: (200,300,10), (300,400,3), (1000,2000,1); p50 rank 7 of 14.
        self.assertAlmostEqual(rows["launch.first_draw.p50"]["value"], 270.0)
        self.assertEqual(rows["launch.first_draw.p50"]["samples"], 14)
        self.assertEqual(rows["launch.first_draw.p50"]["unit"], "ms")
        self.assertAlmostEqual(rows["launch.first_draw.p95"]["value"],
                               field.percentile({(200, 300): 10, (300, 400): 3, (1000, 2000): 1}, 0.95), places=3)
        # One ratio per report: p50 and p95 of [4.0, 2.0]; the null scroll ratio is no sample.
        self.assertAlmostEqual(rows["hitch.ms_per_s.p50"]["value"], 3.0)
        self.assertAlmostEqual(rows["hitch.ms_per_s.p95"]["value"], 3.9)
        self.assertEqual((rows["hitch.ms_per_s.p50"]["unit"], rows["hitch.ms_per_s.p50"]["samples"]), ("ms/s", 2))
        self.assertEqual(rows["hitch.scroll_ms_per_s.p50"]["samples"], 1)
        self.assertEqual(rows["metrickit.reports"]["value"], 2)
        for series in ("launch.resume", "launch.optimized_first_draw", "launch.extended", "hang.time", "hang.stall",
                       "interval.action.commit", "interval.motion.frame"):
            self.assertIn(f"{series}.p50", rows)
            self.assertIn(f"{series}.p95", rows)
        self.assertIn("interval.motion.frame.hitch_ms_per_s.p95", rows)
        self.assertNotIn("interval.action.commit.hitch_ms_per_s.p50", rows)
        self.assertFalse(any("main_turn" in metric for metric in rows))
        other = by_metric(fm.field_rows(result.groups), "0.71.0 (2002)")
        self.assertEqual(sorted(other), ["launch.first_draw.p50", "launch.first_draw.p95", "metrickit.reports"])

    def test_an_open_stall_bucket_counts_at_its_low_edge(self):
        rows = by_metric(fm.field_rows(fm.aggregate([ROW]).groups))
        self.assertAlmostEqual(rows["hang.stall.p50"]["value"], 50 + 50 * 8 / 12, places=3)
        self.assertEqual(rows["hang.stall.p95"]["value"], 10_000)
        self.assertEqual(rows["hang.stall.p95"]["samples"], 16)

    def test_action_commit_percentiles(self):
        rows = by_metric(fm.field_rows(fm.aggregate([ROW]).groups))
        self.assertAlmostEqual(rows["interval.action.commit.p50"]["value"], 50 / 90 * 10, places=3)
        self.assertAlmostEqual(rows["interval.action.commit.p95"]["value"], 15.0)

    def test_a_report_without_an_arm_or_hardware_lands_in_field_pys_buckets(self):
        result = fm.aggregate([row(features_hash=None, chip=None, memory_gb=None, app_build=None)])
        self.assertEqual([(g.build, g.hardware_class, g.arm) for g in result.groups],
                         [("0.71.0", "unknown/unknown", field.NO_ARM)])

    def test_report_names_the_target_of_each_series(self):
        result = fm.report(fm.aggregate([ROW]), since_hours=None, channel="nightly", source="fixture")
        self.assertEqual(result["targets"]["launch.first_draw.p50"], "launch")
        self.assertEqual(result["targets"]["hang.time.p95"], "hangs")
        self.assertEqual(result["targets"]["hitch.ms_per_s.p50"], "motion-dropped")
        self.assertNotIn("interval.action.commit.p50", result["targets"])
        target_ids = {t["id"] for t in json.loads((LAB / "targets.json").read_text(encoding="utf-8"))["targets"]}
        self.assertLessEqual(set(fm.SERIES_TARGETS.values()), target_ids)


class FieldTabTests(unittest.TestCase):
    def test_field_tab_shows_launch_p50_p95_and_hitch_per_nightly(self):
        rows = fm.field_rows(fm.aggregate([ROW, row(app_build="2002")]).groups)
        html = dashboard.render_field([dashboard.FieldRow(**item) for item in rows])
        for build in ("0.71.0 (2001)", "0.71.0 (2002)"):
            self.assertIn(build, html)
        for metric in ("launch.first_draw.p50", "launch.first_draw.p95", "hitch.ms_per_s.p50",
                       "hitch.scroll_ms_per_s.p95"):
            self.assertEqual(html.count(f"<td>{metric}</td>"), 2, metric)
        self.assertIn("<td class=\"num\">1.50 ms/s</td>", html)
        self.assertIn("<td class=\"num\">283 ms</td>", html)
        self.assertNotIn("http", html.split("<body", 1)[-1].replace("http-equiv", ""))


class ReadTests(unittest.TestCase):
    def test_query_is_select_only_and_reads_no_frames_or_install_id(self):
        script = fm.reports_query(since_hours=168, channel="nightly")
        statements = field.assert_select_only(script)
        self.assertEqual(len(statements), 3)
        for absent in ("frames", "install_id", "'hangs'", "payload->'features'"):
            self.assertNotIn(absent, script)
        self.assertIn("channel = 'nightly'", script)

    def test_query_takes_only_closed_values(self):
        with self.assertRaises(field.FieldError):
            fm.reports_query(since_hours=24, channel="nightly' OR 1=1 --")
        for hours in (0, field.MAX_SINCE_HOURS + 1, "24", True):
            with self.subTest(hours=hours), self.assertRaises(field.FieldError):
                fm.reports_query(since_hours=hours, channel="nightly")

    def test_live_read_checks_privileges_first_and_keeps_the_credential_out_of_argv(self):
        psql = FakePsql(rows=[ROW])
        out = io.StringIO()
        args = argparse.Namespace(since="7d", channel="nightly", fixture=None, out=None, json=True)
        self.assertEqual(fm.metrickit_command(args, runner=psql, environ=ENVIRON, out=out), 0)
        self.assertEqual(len(psql.calls), 2)
        self.assertIn("has_table_privilege", psql.calls[0][2])
        self.assertIn("make_interval(hours => 168)", psql.calls[1][2])
        for argv, env, script in psql.calls:
            self.assertFalse(any(PASSWORD in part or "psdb.cloud" in part for part in argv))
            self.assertNotIn(PASSWORD, script)
            self.assertNotIn(field.URL_ENV, env)
            self.assertEqual(env["PGPASSWORD"], PASSWORD)
        result = json.loads(out.getvalue())
        self.assertNotIn(PASSWORD, out.getvalue())
        self.assertEqual((result["source"], result["since_hours"], result["reports"]), (field.SOURCE, 168, 1))

    def test_a_role_that_can_write_is_refused_before_reading(self):
        psql = FakePsql(rows=[ROW], privileges={"insert": True, "update": False, "delete": False, "truncate": False})
        args = argparse.Namespace(since="7d", channel="nightly", fixture=None, out=None, json=True)
        with self.assertRaisesRegex(field.FieldError, "INSERT"):
            fm.metrickit_command(args, runner=psql, environ=ENVIRON, out=io.StringIO())
        self.assertEqual(len(psql.calls), 1)


class CommandTests(unittest.TestCase):
    def test_lab_field_metrickit_fixture(self):
        self.assertIn("field-metrickit", lab.discover())
        with tempfile.TemporaryDirectory() as tmp:
            fixture, out_path = Path(tmp) / "rows.jsonl", Path(tmp) / "out" / "metrickit.json"
            fixture.write_text("".join(json.dumps(r) + "\n" for r in (ROW, row(schema=1))), encoding="utf-8")
            out = io.StringIO()
            args = argparse.Namespace(since="7d", channel="nightly", fixture=str(fixture), out=str(out_path),
                                      json=False)
            self.assertEqual(fm.metrickit_command(args, environ={}, out=out), 0)
            text = out.getvalue()
            self.assertIn("field-metrickit: 1 nightly reports (fixture)", text)
            self.assertIn("skipped schema: 1", text)
            self.assertIn("launch.first_draw.p95", text)
            written = json.loads(out_path.read_text(encoding="utf-8"))
            self.assertEqual(written["skipped"], {"schema": 1})

    def test_no_credential_exits_2(self):
        args = argparse.Namespace(since="7d", channel="nightly", fixture=None, out=None, json=True)
        stderr = io.StringIO()
        original, sys.stderr = sys.stderr, stderr
        try:
            with unittest.mock.patch.dict("os.environ", {}, clear=True):
                self.assertEqual(fm.run("field-metrickit", args), 2)
        finally:
            sys.stderr = original
        self.assertIn(field.URL_ENV, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
