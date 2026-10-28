#!/usr/bin/env python3
"""field.py: SELECT-only queries, the credential kept out of argv and logs, and aggregation on fixture rows.

  python3 -m unittest scripts/perf-lab/tests/test_field.py
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
import re
import stat
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


field = _load("perf_lab_field", "field.py")
lab = _load("perf_lab_lab", "lab.py")
dashboard = _load("perf_lab_dashboard", "dashboard.py")

PASSWORD = "pscale_pw_S3cret+/x"
ENCODED_PASSWORD = PASSWORD.replace('+', '%2B').replace('/', '%2F')
URL = (f"postgresql://field-ro.{field.BRANCH_ID}:{ENCODED_PASSWORD}@us-east-3.pg.psdb.cloud:5432/postgres"
       "?sslmode=verify-full")
BEGIN = "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"
ENVIRON = {field.URL_ENV: URL, "PATH": "/usr/bin", "HOME": "/home/lab", "UNRELATED_TOKEN": "nope"}


def stall(*buckets):
    return [{"lowMs": low, "highMs": high, "count": count} for low, high, count in buckets]


def interval(category, name, *buckets, count=None):
    return {"category": category, "name": name, "count": count or sum(b[2] for b in buckets),
            "buckets": stall(*buckets)}


def row(*, version="0.71.0", build="2001", chip="Apple M4 Pro", memory=24, stalls=(), active=None,
        intervals=(), features=None, trials=None):
    out = {"kind": "report", "app_version": version, "app_build": build, "chip": chip, "memory_gb": memory,
           "stall_histogram": stall(*stalls), "intervals": list(intervals)}
    if active is not None:
        out["active_seconds"] = active
    if features is not None:
        out["features_hash"] = features
    if trials is not None:
        out["features"] = trials
    return out


def entry(name, state, source="trial"):
    """One task-151 `features[]` entry."""
    return {"name": name, "state": state, "source": source}


def trial_installs(count, trial, *, version="0.71.0", build="2001", chip="Apple M4 Pro", memory=24):
    return {"kind": "trial_installs", "app_version": version, "app_build": build, "chip": chip, "memory_gb": memory,
            "trial": trial, "installs": count}


def installs(count, *, version="0.71.0", build="2001", chip="Apple M4 Pro", memory=24, features=None):
    return {"kind": "installs", "app_version": version, "app_build": build, "chip": chip, "memory_gb": memory,
            "features_hash": features, "installs": count}


class FakePsql:
    """Records each psql call; answers the privilege check and the reports query."""

    def __init__(self, *, rows=(), privileges=None, code=0, stderr=""):
        self.calls = []
        self.rows = list(rows)
        self.privileges = privileges or {name.lower(): False for name in field.WRITE_PRIVILEGES}
        self.code = code
        self.stderr = stderr

    def __call__(self, argv, env, script):
        self.calls.append((list(argv), dict(env), script))
        if self.code:
            return self.code, "", self.stderr
        if "has_table_privilege" in script:
            return 0, json.dumps(self.privileges) + "\n", ""
        return 0, "".join(json.dumps(r) + "\n" for r in self.rows), ""


class SelectOnlyTests(unittest.TestCase):
    def test_generated_queries_pass(self):
        for script in (field.privilege_query(), field.reports_query(since_hours=168, channel="nightly")):
            statements = field.assert_select_only(script)
            self.assertEqual(statements[0], "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            self.assertEqual(statements[-1], "ROLLBACK")
            self.assertTrue(all(s.startswith("SELECT ") for s in statements[1:-1]))

    def test_refuses_writes_and_meta_commands(self):
        bad = [
            f"{BEGIN}; INSERT INTO hang_reports VALUES (1); ROLLBACK;",
            f"{BEGIN}; SELECT 1; DROP TABLE hang_reports; ROLLBACK;",
            f"{BEGIN}; SELECT * INTO copy_t FROM hang_reports; ROLLBACK;",
            BEGIN + "; SELECT 1 \\gexec ROLLBACK;",
            "BEGIN TRANSACTION READ ONLY; SELECT 1; ROLLBACK;",
            f"{BEGIN}; SELECT set_config('x', 'y', false); SET ROLE postgres; ROLLBACK;",
            "SELECT 1;",
            "BEGIN; SELECT 1; COMMIT;",
            "",
        ]
        for script in bad:
            with self.subTest(script=script), self.assertRaises(field.FieldError):
                field.assert_select_only(script)

    def test_literal_keywords_are_data(self):
        field.assert_select_only("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY; "
                                 "SELECT 'INSERT; DROP' AS x; ROLLBACK;")

    def test_reports_query_takes_only_closed_values(self):
        with self.assertRaises(field.FieldError):
            field.reports_query(since_hours=24, channel="nightly' OR 1=1 --")
        for hours in (0, field.MAX_SINCE_HOURS + 1, "24"):
            with self.subTest(hours=hours), self.assertRaises(field.FieldError):
                field.reports_query(since_hours=hours, channel="nightly")

    def test_reports_query_reads_no_frames_and_install_ids_only_as_a_count(self):
        script = field.reports_query(since_hours=24, channel="nightly")
        self.assertNotIn("frames", script)
        self.assertNotIn("'hangs'", script)
        self.assertNotIn("md5", script)
        self.assertEqual(script.count("install_id"), 2)
        self.assertEqual(script.count("'installs', count(DISTINCT install_id)"), 2)
        self.assertIn("GROUP BY app_version, app_build, chip, memory_gb, COALESCE(", script)
        self.assertIn("GROUP BY app_version, app_build, chip, memory_gb, trials.entry->>'name', "
                      "trials.entry->>'state'", script)

    def test_trial_installs_read_the_trial_entries_of_task_151s_features(self):
        """The split reads the key task 151 sends (`features[]`, source `trial`), not one no client writes."""
        script = field.reports_query(since_hours=24, channel="nightly")
        self.assertIn("CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(payload->'features') = 'array' "
                      "THEN payload->'features' ELSE '[]'::jsonb END) AS trials(entry)", script)
        self.assertIn("AND trials.entry->>'source' = 'trial' GROUP BY", script)
        self.assertIn("'trial', (trials.entry->>'name') || '=' || (trials.entry->>'state')", script)
        self.assertIn("'features', payload->'features'", script)
        self.assertNotIn("field_trials", script)
        self.assertNotIn("fieldTrials", script)


class CredentialTests(unittest.TestCase):
    def test_url_becomes_pg_variables(self):
        credential = field.credential_from_url(URL)
        self.assertEqual(credential.env["PGPASSWORD"], PASSWORD)
        self.assertEqual(credential.env["PGUSER"], f"field-ro.{field.BRANCH_ID}")
        self.assertEqual(credential.env["PGHOST"], "us-east-3.pg.psdb.cloud")
        self.assertEqual(credential.env["PGSSLMODE"], "verify-full")
        self.assertIn("default_transaction_read_only=on", credential.env["PGOPTIONS"])
        self.assertNotIn(PASSWORD, repr(credential))

    def test_missing_or_bad_credential(self):
        with self.assertRaisesRegex(field.FieldError, field.URL_ENV):
            field.credential_from_environment({})
        for url in ("mysql://u:p@h/db", "postgres://h/db", "postgres://user@h/db"):
            with self.subTest(url=url), self.assertRaises(field.FieldError):
                field.credential_from_url(url)

    def test_a_url_for_another_branch_database_or_host_is_refused_before_psql(self):
        staging = URL.replace(f".{field.BRANCH_ID}:", ".qjkoajlaike8:")  # cmux-prod/staging
        refused = {
            "staging branch": staging,
            "no branch suffix": URL.replace(f"field-ro.{field.BRANCH_ID}:", "field-ro:"),
            "not PlanetScale": URL.replace("us-east-3.pg.psdb.cloud", "db.example.com"),
            "look-alike host": URL.replace("us-east-3.pg.psdb.cloud", "us-east-3.pg.psdb.cloud.evil.test"),
        }
        for name, url in refused.items():
            psql = FakePsql(rows=[row()])
            with self.subTest(name), self.assertRaisesRegex(field.FieldError, "refusing") as caught:
                field.field_command(argparse.Namespace(since="7d", channel="nightly", fixture=None, out=None,
                                                       json=True),
                                    runner=psql, environ=ENVIRON | {field.URL_ENV: url}, out=io.StringIO())
            self.assertEqual(psql.calls, [])
            self.assertNotIn(PASSWORD, str(caught.exception))
        with self.assertRaisesRegex(field.FieldError, "cmux/cmux-prod/main .*'qjkoajlaike8'"):
            field.credential_from_url(staging)

    def test_branch_id_matches_the_release_rails_pin(self):
        trees = (LAB.parent / "cmux-next" / "release" / "trees.ts").read_text(encoding="utf-8")
        match = re.search(r'database: "cmux-prod",.*?branches: \{[^}]*production: "main"[^}]*\},\s*'
                          r'branchIds: \{[^}]*production: "([a-z0-9]+)"', trees, re.DOTALL)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), field.BRANCH_ID)

    def test_report_source_names_the_target(self):
        out = io.StringIO()
        args = argparse.Namespace(since="7d", channel="nightly", fixture=None, out=None, json=True)
        field.field_command(args, runner=FakePsql(rows=[row()]), environ=ENVIRON, out=out)
        self.assertEqual(json.loads(out.getvalue())["source"],
                         "hang_reports (org cmux, database cmux-prod, branch main)")

    def test_credential_never_in_argv_and_url_env_not_passed(self):
        psql = FakePsql(rows=[row()])
        credential = field.credential_from_environment(ENVIRON)
        field.fetch_reports(since_hours=24, channel="nightly", credential=credential, runner=psql, environ=ENVIRON)
        self.assertEqual(len(psql.calls), 2)
        for argv, env, script in psql.calls:
            joined = " ".join(argv)
            for secret in (PASSWORD, URL, "psdb.cloud", "field-ro"):
                self.assertNotIn(secret, joined)
                self.assertNotIn(secret, script)
            self.assertNotIn(field.URL_ENV, env)
            self.assertNotIn("UNRELATED_TOKEN", env)
            self.assertEqual(env["PGPASSWORD"], PASSWORD)
            self.assertEqual(argv[-2:], ["--file", "-"])
            self.assertIn("--no-psqlrc", argv)

    def test_psql_error_is_redacted(self):
        psql = FakePsql(code=2, stderr=f"FATAL: password authentication failed: {PASSWORD} at {URL}")
        credential = field.credential_from_environment(ENVIRON)
        with self.assertRaises(field.FieldError) as caught:
            field.fetch_reports(since_hours=24, channel="nightly", credential=credential, runner=psql, environ=ENVIRON)
        self.assertNotIn(PASSWORD, str(caught.exception))
        self.assertNotIn(URL, str(caught.exception))
        self.assertIn("<redacted>", str(caught.exception))

    def test_a_role_that_can_write_is_refused_before_reading(self):
        privileges = {name.lower(): False for name in field.WRITE_PRIVILEGES} | {"insert": True}
        psql = FakePsql(rows=[row()], privileges=privileges)
        credential = field.credential_from_environment(ENVIRON)
        with self.assertRaisesRegex(field.FieldError, "INSERT"):
            field.fetch_reports(since_hours=24, channel="nightly", credential=credential, runner=psql, environ=ENVIRON)
        self.assertEqual(len(psql.calls), 1)

    def test_missing_privilege_answer_counts_as_write(self):
        psql = FakePsql(privileges={"insert": False})
        credential = field.credential_from_environment(ENVIRON)
        with self.assertRaisesRegex(field.FieldError, "UPDATE"):
            field.check_read_only(credential, runner=psql, environ=ENVIRON)


class AggregationTests(unittest.TestCase):
    def test_percentile_interpolates_inside_the_bucket(self):
        histogram = {(0, 10): 50, (10, 20): 50}
        self.assertEqual(field.percentile(histogram, 0.5), 10.0)
        self.assertEqual(field.percentile(histogram, 0.75), 15.0)
        self.assertEqual(field.percentile(histogram, 1.0), 20.0)
        self.assertIsNone(field.percentile({}, 0.5))

    def test_overlapping_buckets_give_monotone_quantiles(self):
        # Report A's MetricKit bucket (0, 100) covers report B's (10, 20): walking (low, high) order gave
        # p50 = 100 and p95 = 19. On the union edges A's 10 share out 1 / 1 / 8 over (0,10), (10,20), (20,100).
        histogram = {}
        field.merge(histogram, [(0, 100, 10)])
        field.merge(histogram, [(10, 20, 10)])
        self.assertEqual(field.disjoint(histogram), [(0, 10, 1.0), (10, 20, 11.0), (20, 100, 8.0)])
        p50, p95, p99 = (field.percentile(histogram, q) for _, q in field.PERCENTILES)
        self.assertLessEqual(p50, p95)
        self.assertLessEqual(p95, p99)
        self.assertAlmostEqual(p50, 10 + 10 * 9 / 11)
        self.assertAlmostEqual(p95, 90.0)
        mixed = {(0, 4): 3, (2, 8): 6, (5, 5): 2, (4, 16): 4, (8, 8): 1}
        quantiles = [field.percentile(mixed, step / 100) for step in range(1, 101)]
        self.assertEqual(quantiles, sorted(quantiles))
        self.assertAlmostEqual(sum(share for _, _, share in field.disjoint(mixed)), sum(mixed.values()))

    def test_rate_per_build_hardware_class_and_arm(self):
        rows = [
            # 2 hangs (>= 250 ms) in 1 h, plus stalls under 250 ms that do not count.
            row(stalls=[(50, 100, 9), (100, 250, 4), (250, 500, 1), (2000, 5000, 1)], active=3600),
            # 1 hang in 1 h.
            row(stalls=[(500, 1000, 1)], active=3600),
            # no active time: counted, but not in the rate.
            row(stalls=[(1000, 2000, 7)]),
            row(version="0.71.1", build="2002", stalls=[(250, 500, 2)], active=7200),
            row(chip="Apple M1", memory=16, stalls=[(250, 500, 1)]),
            row(stalls=[(250, 500, 4)], active=1800, features="f00d"),
            # The distinct install counts, one row per raw key; two raw chip spellings land in one class.
            installs(1),
            installs(1, chip="apple m4 pro"),
            installs(1, version="0.71.1", build="2002"),
            installs(1, chip="Apple M1", memory=16),
            installs(1, features="f00d"),
        ]
        groups = {(g.build, g.hardware_class, g.arm): g for g in field.aggregate(rows)}
        self.assertEqual(set(groups), {
            ("0.71.0 (2001)", "apple-m4-pro/24gb", field.NO_ARM),
            ("0.71.1 (2002)", "apple-m4-pro/24gb", field.NO_ARM),
            ("0.71.0 (2001)", "apple-m1/16gb", field.NO_ARM),
            ("0.71.0 (2001)", "apple-m4-pro/24gb", "f00d"),
        })
        main = groups[("0.71.0 (2001)", "apple-m4-pro/24gb", field.NO_ARM)]
        self.assertEqual((main.reports, main.installs), (3, 2))
        self.assertEqual(main.hangs_over_250ms, 10)
        self.assertEqual(main.timed_reports, 2)
        self.assertAlmostEqual(main.hangs_per_1000_active_hours, 3 / 2 * 1000)
        self.assertAlmostEqual(groups[("0.71.1 (2002)", "apple-m4-pro/24gb", field.NO_ARM)]
                               .hangs_per_1000_active_hours, 1000.0)
        self.assertIsNone(groups[("0.71.0 (2001)", "apple-m1/16gb", field.NO_ARM)].hangs_per_1000_active_hours)
        self.assertAlmostEqual(groups[("0.71.0 (2001)", "apple-m4-pro/24gb", "f00d")]
                               .hangs_per_1000_active_hours, 8000.0)

    def test_metrics_split_by_field_trial_arm(self):
        """task 152: a 50/50 study's arms are their own groups beside the features groups; each report counts once
        in the total."""
        rows = [
            row(stalls=[(250, 500, 1)], active=3600, features="f1",
                trials=[entry("slackThing", "on"), entry("otherThing", "off")],
                intervals=[interval("action", "tab.close", (0, 8, 4))]),
            row(stalls=[(250, 500, 3)], active=3600, features="f2", trials=[entry("slackThing", "off")]),
            row(stalls=[(250, 500, 5)], active=3600, features="f2",
                trials=[entry("slackThing", "off"), entry("bad name", "on"), entry("aThing", "enabled"),
                        {"name": "bThing", "state": "on"}, 7, "slackThing=on"]),
            # Forced by a higher input than the arm: in no trial group.
            row(stalls=[(250, 500, 6)], active=3600, features="f3",
                trials=[entry("slackThing", "on", "remote"), entry("prefetchThing", "off", "env"),
                        entry("killThing", "off", "local")]),
            row(stalls=[(250, 500, 2)], active=3600),
            trial_installs(1, "slackThing=on"),
            trial_installs(2, "slackThing=off"),
            trial_installs(4, "not a tag"),
            trial_installs(4, "slackThing=enabled"),
        ]
        groups = field.aggregate(rows)
        study = {g.arm: g for g in groups if g.split == field.TRIAL_SPLIT}
        self.assertEqual(set(study), {"slackThing=on", "slackThing=off", "otherThing=off"})
        self.assertEqual((study["slackThing=on"].reports, study["slackThing=on"].installs), (1, 1))
        self.assertEqual((study["slackThing=off"].reports, study["slackThing=off"].installs), (2, 2))
        self.assertAlmostEqual(study["slackThing=on"].hangs_per_1000_active_hours, 1000.0)
        self.assertAlmostEqual(study["slackThing=off"].hangs_per_1000_active_hours, 4000.0)
        self.assertEqual(study["slackThing=on"].action, {"tab.close": {(0, 8): 4}})
        features = {g.arm for g in groups if g.split == field.FEATURES_SPLIT}
        self.assertEqual(features, {"f1", "f2", "f3", field.NO_ARM})
        self.assertEqual([g.split for g in groups], [field.FEATURES_SPLIT] * 4 + [field.TRIAL_SPLIT] * 3)
        result = field.report(groups, since_hours=None, channel="nightly", source="fixture")
        self.assertEqual(result["reports"], 5)
        arms = {(r["arm"], r["metric"]): r["value"] for r in result["rows"]}
        self.assertEqual(arms[("slackThing=off", "hangs_over_250ms")], 8)
        for item in result["rows"]:
            dashboard.FieldRow(**item)
        self.assertIn("trial slackThing=off: 2 reports, 2 installs", field.render_text(result))

    def test_trial_tags_keep_only_well_formed_trial_entries(self):
        self.assertEqual(field.trial_tags([entry("zThing", "on"), entry("aThing", "off"), entry("aThing", "off"),
                                           entry("rThing", "on", "remote"), entry("1bad", "on"), None]),
                         ["aThing=off", "zThing=on"])
        self.assertEqual(field.trial_tags(None), [])
        self.assertEqual(field.trial_tags({"name": "aThing", "state": "on", "source": "trial"}), [])

    def test_action_and_turn_histograms(self):
        rows = [
            row(intervals=[interval("action", "workspace.create", (0, 10, 8), (10, 20, 2)),
                           interval("action", "main_turn", (0, 4, 90), (4, 8, 10)),
                           interval("motion", "sidebar.toggle", (0, 16, 5))]),
            row(intervals=[interval("action", "workspace.create", (0, 10, 2), (10, 20, 8)),
                           interval("key", "input_queueing", (0, 2, 10))]),
        ]
        [group] = field.aggregate(rows)
        self.assertEqual(group.action, {"workspace.create": {(0, 10): 10, (10, 20): 10}})
        self.assertEqual(group.turn, {"main_turn": {(0, 4): 90, (4, 8): 10}, "input_queueing": {(0, 2): 10}})
        metrics = {r["metric"]: r for r in field.field_rows([group])}
        self.assertEqual(metrics["action.workspace.create.p50"]["value"], 10.0)
        self.assertEqual(metrics["action.workspace.create.p95"]["samples"], 20)
        self.assertEqual(metrics["turn.main_turn.p50"]["value"], 2.2222)
        self.assertNotIn("action.sidebar.toggle.p50", metrics)
        self.assertIsNone(metrics["hangs_over_250ms_per_1000_active_hours"]["value"])

    def test_malformed_parts_are_skipped(self):
        rows = [row(stalls=[]) | {"stall_histogram": [{"lowMs": 300, "highMs": 200, "count": 5},
                                                        {"lowMs": "250", "highMs": 500, "count": 5},
                                                        {"lowMs": 250, "highMs": 500, "count": -3}, "x",
                                                        {"lowMs": 250, "highMs": 500, "count": 2}],
                                    "intervals": "nope", "active_seconds": "3600"},
                {"chip": None, "memory_gb": "24"}]
        groups = field.aggregate(rows)
        self.assertEqual([g.hangs_over_250ms for g in groups], [2, 0])
        self.assertEqual(groups[0].timed_reports, 0)
        self.assertEqual(groups[1].hardware_class, "unknown/unknown")
        self.assertEqual(groups[1].build, "unknown")

    def test_rows_are_dashboard_field_rows(self):
        rows = field.field_rows(field.aggregate([row(active=3600, stalls=[(250, 500, 1)],
                                                     intervals=[interval("action", "tab.close", (0, 8, 4))])]))
        for item in rows:
            dashboard.FieldRow(**item)
        self.assertIn("No field data", dashboard.render_field([]))
        self.assertIn("hangs_over_250ms_per_1000_active_hours",
                      dashboard.render_field([dashboard.FieldRow(**item) for item in rows]))


class CommandTests(unittest.TestCase):
    def test_since(self):
        self.assertEqual(field.parse_since("7d"), 168)
        self.assertEqual(field.parse_since("48h"), 48)
        for text in ("7", "0d", "-1d", "7w", "91d", "7d; drop"):
            with self.subTest(text=text), self.assertRaises(field.FieldError):
                field.parse_since(text)

    def test_lab_field_fixture_json(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "rows.jsonl"
            fixture.write_text("\n".join(json.dumps(r) for r in [row(active=3600, stalls=[(250, 500, 3)])]) + "\n")
            out_path = Path(directory) / "out" / "field.json"
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = lab.main(["field", "--fixture", str(fixture), "--json", "--out", str(out_path)])
            self.assertEqual(code, 0)
            result = json.loads(stdout.getvalue())
            self.assertEqual(json.loads(out_path.read_text()), result)
        self.assertEqual(result["source"], "fixture")
        self.assertEqual(result["reports"], 1)
        self.assertEqual(result["groups"][0]["hangs_over_250ms_per_1000_active_hours"], 3000.0)

    def test_live_read_through_fake_psql_prints_no_credential(self):
        psql = FakePsql(rows=[row(active=3600, stalls=[(250, 500, 1)], intervals=[
            interval("action", "workspace.create", (0, 10, 4))])])
        out = io.StringIO()
        args = argparse.Namespace(since="7d", channel="nightly", fixture=None, out=None, json=False)
        self.assertEqual(field.field_command(args, runner=psql, environ=ENVIRON, out=out), 0)
        text = out.getvalue()
        self.assertIn("1000.0 per 1000 active hours", text)
        self.assertIn("action.workspace.create.p50", text)
        self.assertNotIn(PASSWORD, text)
        self.assertIn("make_interval(hours => 168)", psql.calls[1][2])

    def _run_fixture(self, fixture, out=None):
        stderr, stdout = io.StringIO(), io.StringIO()
        args = argparse.Namespace(since="7d", channel="nightly", fixture=str(fixture), out=out, json=True)
        with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(stdout):
            code = field.run("field", args)
        return code, stderr.getvalue()

    def test_a_fixture_that_is_not_utf8_exits_2(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "rows.jsonl"
            fixture.write_bytes(b'{"app_version": "\xff"}\n')
            code, stderr = self._run_fixture(fixture)
        self.assertEqual(code, 2)
        self.assertIn("lab.py field: the fixture is not UTF-8", stderr)

    def test_an_unwritable_out_exits_2(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "rows.jsonl"
            fixture.write_text(json.dumps(row()) + "\n")
            blocker = Path(directory) / "file"
            blocker.write_text("")
            code, stderr = self._run_fixture(fixture, out=str(blocker / "sub" / "field.json"))
        self.assertEqual(code, 2)
        self.assertIn("lab.py field: cannot write --out:", stderr)

    def test_a_failed_replace_leaves_no_temporary_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "field.json"
            with unittest.mock.patch.object(field.os, "replace", side_effect=OSError(28, "No space left on device")):
                with self.assertRaises(OSError):
                    field.write_atomically(target, "{}\n")
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_out_is_readable_by_other_users(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "field.json"
            field.write_atomically(target, "{}\n")
            self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o644)
            self.assertEqual([p.name for p in Path(directory).iterdir()], ["field.json"])

    def test_no_credential_exits_2_without_running_psql(self):
        stderr = io.StringIO()
        args = argparse.Namespace(since="7d", channel="nightly", fixture=None, out=None, json=True)
        with contextlib.redirect_stderr(stderr), unittest.mock.patch.dict("os.environ", {}, clear=True):
            self.assertEqual(field.run("field", args), 2)
        self.assertIn(field.URL_ENV, stderr.getvalue())


def site(site_id, kind, count, total_ms=0):
    """One task-226 `blocking_sites[]` entry."""
    return {"site": site_id, "kind": kind, "count": count, "total_ms": total_ms}


# The client's ids (HangReportWireFormatTests.blockingSitesJSON).
STORE_SITE = "8ef2dbd38483c034"  # CmuxNextApp/WorkspaceStore.swift:42
SIDEBAR_SITE = "2fc36eeebd7c605e"  # CmuxNextSidebar/SidebarModel.swift:9


class BlockingSiteTests(unittest.TestCase):
    """Task 226: the top main-thread blocking sites per build, by hashed site id."""

    def test_the_query_reads_the_reports_blocking_sites(self):
        script = field.reports_query(since_hours=24, channel="nightly")
        self.assertIn("'blocking_sites', payload->'blocking_sites'", script)
        field.assert_select_only(script)

    def test_site_id_matches_the_clients(self):
        self.assertEqual(field.site_id("CmuxNextApp/WorkspaceStore.swift:42"), STORE_SITE)
        self.assertEqual(field.site_id("CmuxNextSidebar/SidebarModel.swift:9"), SIDEBAR_SITE)

    def test_sites_add_per_build_most_calls_first_and_skip_malformed_entries(self):
        rows = [row(build="2001") | {"blocking_sites": [site(STORE_SITE, "file-io", 4, 9), site(SIDEBAR_SITE, "sqlite", 6),
                                                        site("Sources/App.swift", "file-io", 9),
                                                        site(STORE_SITE.upper(), "file-io", 9),
                                                        site(SIDEBAR_SITE, "File IO", 9), site(SIDEBAR_SITE, "sqlite", 0),
                                                        "x"]},
                row(build="2001") | {"blocking_sites": [site(STORE_SITE, "file-io", 5, 3)]},
                row(build="2002") | {"blocking_sites": "nope"}]
        groups = field.aggregate(rows)
        self.assertEqual(groups[0].top_blocking_sites(),
                         [(STORE_SITE, "file-io", 9, 12, 2), (SIDEBAR_SITE, "sqlite", 6, 0, 1)])
        self.assertEqual(groups[1].top_blocking_sites(), [])
        metrics = {r["metric"]: (r["value"], r["unit"], r["samples"]) for r in field.field_rows(groups[:1])}
        self.assertEqual(metrics[f"blocking_site.{STORE_SITE}.file-io"], (9, "calls", 2))
        self.assertEqual(metrics[f"blocking_site.{STORE_SITE}.file-io.total_ms"], (12, "ms", 2))
        for item in field.field_rows(groups):
            dashboard.FieldRow(**item)

    def test_a_group_reports_at_most_the_top_sites(self):
        sites = [site(f"{index:016x}", "sleep", index + 1) for index in range(field.TOP_BLOCKING_SITES + 4)]
        group = field.aggregate([row() | {"blocking_sites": sites}])[0]
        self.assertEqual([calls for _, _, calls, _, _ in group.top_blocking_sites()],
                         list(range(field.TOP_BLOCKING_SITES + 4, 4, -1)))

    def test_sites_from_a_checkout_name_each_id(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Packages" / "macOS" / "CmuxNext" / "Sources" / "CmuxNextApp" / "Workspace"
            source.mkdir(parents=True)
            (source / "WorkspaceStore.swift").write_text("\n" * 50)
            hidden = root / ".claude" / "worktrees" / "x" / "Sources" / "CmuxNextSidebar"
            hidden.mkdir(parents=True)
            (hidden / "SidebarModel.swift").write_text("\n" * 20)
            fixture = root / "rows.jsonl"
            fixture.write_text(json.dumps(row() | {"blocking_sites": [site(STORE_SITE, "file-io", 3, 7),
                                                                      site(SIDEBAR_SITE, "sqlite", 1)]}) + "\n")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = lab.main(["field", "--fixture", str(fixture), "--json", "--sites-from", str(root)])
            self.assertEqual(code, 0)
            sites = json.loads(stdout.getvalue())["groups"][0]["blocking_sites"]
            self.assertEqual([(s["site"], s["location"]) for s in sites],
                             [(STORE_SITE, "CmuxNextApp/WorkspaceStore.swift:42"), (SIDEBAR_SITE, None)])
            text = field.render_text(field.report(field.aggregate([json.loads(fixture.read_text())]), since_hours=None,
                                                  channel="nightly", source="fixture"))
            self.assertIn(f"blocking {STORE_SITE} file-io: 3 calls, 7 ms (n=1)", text)

    def test_a_missing_sites_checkout_exits_2(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "rows.jsonl"
            fixture.write_text(json.dumps(row() | {"blocking_sites": [site(STORE_SITE, "file-io", 1)]}) + "\n")
            stderr = io.StringIO()
            args = argparse.Namespace(since="7d", channel="nightly", fixture=str(fixture), out=None, json=True,
                                      sites_from=str(Path(directory) / "missing"))
            with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(field.run("field", args), 2)
        self.assertIn("--sites-from is not a directory", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
