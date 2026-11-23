#!/usr/bin/env python3
"""The cmux NEXT health gate (scripts/ci/nightly_next_health.py, .github/workflows/nightly-next-health.yml).

Leo, 2026-11-19 (paraphrased): we want to be a professional software organization, so agents look these
practices up and build them. A failing real-session health verdict pulls the build from the feed within one
15-minute tick, through the existing rollback jobs, and never a build newer than the one judged.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "nightly_next_health.py"
WORKFLOW = ROOT / ".github" / "workflows" / "nightly-next-health.yml"
DRILL = ROOT / ".github" / "workflows" / "nightly-next-rollback-drill.yml"
GUARD = ROOT / "scripts" / "ci" / "nightly-next-guard.py"

spec = importlib.util.spec_from_file_location("nightly_next_health", SCRIPT)
health = importlib.util.module_from_spec(spec)
sys.modules["nightly_next_health"] = health
spec.loader.exec_module(health)

NOW = dt.datetime(2026, 11, 19, 12, 0, tzinfo=dt.timezone.utc)


def item(build: int, channel: str = "cmux-next") -> str:
    return (f"<item><sparkle:channel>{channel}</sparkle:channel><sparkle:version>{build}</sparkle:version>"
            f"<sparkle:shortVersionString>1.0.0-nightly.{build}</sparkle:shortVersionString>"
            f'<enclosure url="https://files-next.cmux.com/nightly-next/cmux-nightly-next-macos-arm64-{build}.dmg" '
            f'length="1"/></item>')


FEED = "<rss><channel>" + item(300) + item(200) + item(100) + "</channel></rss>"


def reading(b300: dict | None = None, b200: dict | None = None, why: str | None = None) -> dict:
    builds = {}
    if b300 is not None:
        builds["300"] = {"sessions": 0, "crashed": 0, "abnormal": 0, "hangs": 0, **b300}
    if b200 is not None:
        builds["200"] = {"sessions": 0, "crashed": 0, "abnormal": 0, "hangs": 0, **b200}
    return {"source": "sentry", "builds": builds, "why": why}


class Feed(unittest.TestCase):
    def test_newest_nightly_build_skips_dev_ring(self):
        feed = "<rss>" + item(400, "cmux-next-dev") + item(300) + "</rss>"
        self.assertEqual(health.nightly_builds(feed)[0], (300, "1.0.0-nightly.300"))

    def test_release_name_matches_crash_reporting_policy(self):
        # CrashReportingPolicy.release: "cmux-next@\(shortVersion)+\(build)"
        self.assertEqual(health.release_name(300, "1.0.0-nightly.300"), "cmux-next@1.0.0-nightly.300+300")


class Judge(unittest.TestCase):
    def judge(self, r, existing=None, build=None, feed=FEED):
        return health.judge(feed, r, existing, NOW, build)

    def test_crashes_over_floor_and_previous_fail_and_pull(self):
        out = self.judge(reading({"sessions": 10, "crashed": 3}, {"sessions": 40, "crashed": 0}))
        self.assertEqual(out["health"]["verdict"], "fail")
        self.assertEqual(out["action"], "rollback")
        self.assertEqual(out["serving"], "200")
        self.assertIn("crash-free sessions 70.00%", out["health"]["why"])
        self.assertEqual(out["health"]["failed_at"], "2026-11-19T12:00:00Z")

    def test_one_crash_never_fails(self):
        out = self.judge(reading({"sessions": 3, "crashed": 1}, {"sessions": 40}))
        self.assertNotEqual(out["health"]["verdict"], "fail")
        self.assertEqual(out["action"], "none")

    def test_no_worse_than_previous_does_not_fail(self):
        out = self.judge(reading({"sessions": 10, "crashed": 2}, {"sessions": 10, "crashed": 4}))
        self.assertEqual(out["health"]["verdict"], "pass")

    def test_hang_rate_over_floor_and_twice_previous_fails(self):
        out = self.judge(reading({"sessions": 10, "hangs": 5}, {"sessions": 20, "hangs": 1}))
        self.assertEqual(out["health"]["verdict"], "fail")
        self.assertIn("app hangs", out["health"]["why"])

    def test_hangs_like_previous_pass(self):
        out = self.judge(reading({"sessions": 10, "hangs": 3}, {"sessions": 10, "hangs": 3}))
        self.assertEqual(out["health"]["verdict"], "pass")

    def test_enough_clean_sessions_pass_at_once(self):
        out = self.judge(reading({"sessions": health.MIN_SESSIONS}, {"sessions": 10}))
        self.assertEqual(out["health"]["verdict"], "pass")
        self.assertEqual(out["health"]["first_verdict_at"], "2026-11-19T12:00:00Z")

    def test_few_sessions_pending_then_pass_after_window(self):
        out = self.judge(reading({"sessions": 1}))
        self.assertEqual(out["health"]["verdict"], "pending")
        self.assertEqual(out["health"]["first_session_at"], "2026-11-19T12:00:00Z")
        later = health.judge(FEED, reading({"sessions": 1}), out["health"],
                             NOW + dt.timedelta(seconds=health.PASS_AFTER_S), None)
        self.assertEqual(later["health"]["verdict"], "pass")
        self.assertEqual(later["health"]["first_session_at"], "2026-11-19T12:00:00Z")

    def test_no_session_is_pending(self):
        out = self.judge(reading({}))
        self.assertEqual(out["health"]["verdict"], "pending")
        self.assertIsNone(out["health"]["first_session_at"])

    def test_sentry_unreadable_is_unknown_and_never_pulls(self):
        out = self.judge(reading(why="Sentry answered HTTP 403"))
        self.assertEqual(out["health"]["verdict"], "unknown")
        self.assertEqual(out["action"], "none")

    def test_half_a_reading_is_unknown_and_never_pulls(self):
        # The newest build read, the build before it did not (a 429): no comparison, no pull.
        out = self.judge(reading({"sessions": 10, "crashed": 3}, why="Sentry answered HTTP 429"))
        self.assertEqual(out["health"]["verdict"], "unknown")
        self.assertEqual(out["action"], "none")

    def test_sentry_unreadable_is_blind(self):
        # The gate said unknown on every tick from 2026-11-19 to 2026-11-22 (Sentry HTTP 403) and stayed green:
        # a gate that cannot read can never pull, so the judge says so (blind) and the workflow reports it.
        out = self.judge(reading(why="Sentry answered HTTP 403 for /organizations/manaflow/sessions/"))
        self.assertIs(out["blind"], True)
        self.assertEqual(out["action"], "none")

    def test_half_a_reading_is_blind(self):
        out = self.judge(reading({"sessions": 10, "crashed": 3}, why="Sentry answered HTTP 429"))
        self.assertIs(out["blind"], True)

    def test_a_reading_is_never_blind(self):
        for r in (reading({"sessions": 10}, {"sessions": 10}), reading({}),
                  reading({"sessions": 20, "crashed": 5}, {"sessions": 10})):
            self.assertIs(self.judge(r)["blind"], False)

    def test_blind_report_names_the_build_the_reason_and_the_fix(self):
        out = self.judge(reading(why="Sentry answered HTTP 403 for /organizations/manaflow/sessions/ "
                                     "(the token needs org:read and event:read)"))
        report = health.blind_report(out, "https://github.com/manaflow-ai/cmux/actions/runs/1")
        self.assertEqual(report["title"], health.BLIND_TITLE)
        self.assertIn("300", report["body"])
        self.assertIn("HTTP 403", report["body"])
        self.assertIn("SENTRY_AUTH_TOKEN", report["body"])
        self.assertIn("actions/runs/1", report["body"])

    def test_a_pass_flips_to_fail_on_a_later_tick(self):
        first = self.judge(reading({"sessions": 10}, {"sessions": 10}))
        later = health.judge(FEED, reading({"sessions": 20, "crashed": 4}, {"sessions": 10}), first["health"],
                             NOW + dt.timedelta(minutes=15), None)
        self.assertEqual(later["health"]["verdict"], "fail")
        self.assertEqual(later["action"], "rollback")
        self.assertEqual(later["health"]["first_verdict_at"], "2026-11-19T12:00:00Z")

    def test_never_pulls_a_build_that_is_not_newest(self):
        r = {"source": "sentry", "why": None, "builds": {"200": {"sessions": 10, "crashed": 5, "hangs": 0}}}
        out = self.judge(r, build=200)
        self.assertEqual(out["health"]["verdict"], "fail")
        self.assertEqual(out["action"], "none")
        self.assertIn("newer than 200", out["why"])

    def test_never_empties_the_feed(self):
        feed = "<rss>" + item(300) + "</rss>"
        out = self.judge(reading({"sessions": 10, "crashed": 5}), feed=feed)
        self.assertEqual(out["action"], "none")


class SentryRead(unittest.TestCase):
    def test_reads_sessions_and_hangs_for_the_two_newest_builds(self):
        calls = []

        def get(path, params):
            calls.append((path, dict(params)))
            q = dict(params)["query"]
            if path.endswith("/sessions/"):
                crashed = 2 if "+300" in q else 0
                return {"intervals": ["2026-11-19T11:30:00Z", "2026-11-19T11:35:00Z"],
                        "groups": [{"by": {"session.status": "healthy"}, "totals": {"sum(session)": 8},
                                    "series": {"sum(session)": [0, 8]}},
                                   {"by": {"session.status": "crashed"}, "totals": {"sum(session)": crashed},
                                    "series": {"sum(session)": [0, crashed]}}]}
            return {"data": [{"count()": 4 if "+300" in q else 1}]}

        r = health.sentry_read(FEED, None, get)
        self.assertIsNone(r["why"])
        self.assertEqual(sorted(r["builds"]), ["200", "300"])
        self.assertEqual(r["builds"]["300"], {"sessions": 10, "crashed": 2, "abnormal": 0, "hangs": 4,
                                              "first_session_at": "2026-11-19T11:35:00Z",
                                              "release": "cmux-next@1.0.0-nightly.300+300"})
        session_queries = [p["query"] for path, p in calls if path.endswith("/sessions/")]
        self.assertIn('release:"cmux-next@1.0.0-nightly.300+300"', session_queries)
        self.assertTrue(all(p["environment"] == "nightly-next" for _, p in calls))

    def test_a_refused_read_says_why(self):
        def get(path, params):
            raise health.SourceError("Sentry answered HTTP 403 for x (the token needs org:read and event:read)")

        r = health.sentry_read(FEED, None, get)
        self.assertEqual(r["builds"], {})
        self.assertIn("403", r["why"])


class Cli(unittest.TestCase):
    def run_script(self, *args, env=None):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True,
                              env={**os.environ, **(env or {})})

    def test_drill_reading_fails_the_bad_canary_and_pulls_it(self):
        with tempfile.TemporaryDirectory() as d:
            feed, reading_path, out = Path(d, "feed.xml"), Path(d, "r.json"), Path(d, "v.json")
            feed.write_text(FEED)
            self.assertEqual(self.run_script("recent", "--feed", str(feed)).stdout.strip(), "300 200 100")
            done = self.run_script("drill-reading", "--build", "300", "--now", "2026-11-19T12:00:00Z",
                                   "--out", str(reading_path))
            self.assertEqual(done.returncode, 0, done.stderr)
            done = self.run_script("judge", "--feed", str(feed), "--reading", str(reading_path), "--build", "300",
                                   "--now", "2026-11-19T12:00:00Z", "--out", str(out))
            self.assertEqual(done.returncode, 0, done.stderr)
            result = json.loads(done.stdout)
            self.assertEqual(result["action"], "rollback")
            self.assertEqual(json.loads(out.read_text())["verdict"], "fail")

    def test_blind_report_cli_prints_title_and_body(self):
        with tempfile.TemporaryDirectory() as d:
            result = Path(d, "result.json")
            result.write_text(json.dumps(health.judge(FEED, reading(why="Sentry answered HTTP 403"), None, NOW)))
            done = self.run_script("blind-report", "--result", str(result), "--run-url", "https://x/runs/2")
            self.assertEqual(done.returncode, 0, done.stderr)
            report = json.loads(done.stdout)
            self.assertEqual(report["title"], health.BLIND_TITLE)
            self.assertIn("https://x/runs/2", report["body"])

    def test_no_token_reads_nothing_and_says_so(self):
        with tempfile.TemporaryDirectory() as d:
            feed, out = Path(d, "feed.xml"), Path(d, "r.json")
            feed.write_text(FEED)
            done = self.run_script("sentry-read", "--feed", str(feed), "--out", str(out), env={"SENTRY_AUTH_TOKEN": ""})
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(json.loads(out.read_text())["why"], "no SENTRY_AUTH_TOKEN")


class Workflow(unittest.TestCase):
    def setUp(self):
        self.wf = yaml.safe_load(WORKFLOW.read_text())
        self.drill = yaml.safe_load(DRILL.read_text())

    def test_every_15_minutes(self):
        on = self.wf[True] if True in self.wf else self.wf["on"]
        self.assertEqual([c["cron"] for c in on["schedule"]], ["7,22,37,52 * * * *"])

    def test_rollback_pulls_only_the_judged_build_while_newest(self):
        job = self.wf["jobs"]["rollback"]
        self.assertEqual(job["uses"], "./.github/workflows/nightly-next-rollback.yml")
        self.assertEqual(job["with"]["bad_build"], "${{ needs.judge.outputs.build }}")
        self.assertEqual(job["with"]["if_newest"], "${{ needs.judge.outputs.build }}")
        self.assertIn("NIGHTLY_NEXT_HEALTH_GATE != 'report'", job["if"])

    def test_judge_holds_the_token_only_on_nightly_next(self):
        job = self.wf["jobs"]["judge"]
        self.assertEqual(job["environment"], "release-next")
        self.assertIn("github.ref == 'refs/heads/nightly-next'", job["if"])

    def test_drill_step_health_calls_the_gate_on_the_drill_folder(self):
        job = self.drill["jobs"]["health"]
        self.assertEqual(job["uses"], "./.github/workflows/nightly-next-health.yml")
        self.assertIs(job["with"]["drill"], True)
        self.assertEqual(self.drill["jobs"]["rollback"]["if"], "inputs.step == 'pull'")
        self.assertIn("health", self.drill["jobs"]["receipt"]["needs"])

    def test_a_blind_gate_reports_once_and_turns_the_run_red(self):
        self.assertIn("blind", self.wf["jobs"]["judge"]["outputs"])
        job = self.wf["jobs"]["blind"]
        self.assertEqual(job["needs"], "judge")
        self.assertIn("needs.judge.outputs.blind == 'true'", job["if"])
        self.assertIn("!inputs.drill", job["if"])
        self.assertEqual(job["permissions"], {"issues": "write"})
        script = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertIn("gh issue list", script)
        self.assertIn("gh issue create", script)
        self.assertIn("exit 1", script)
        # Reporting is all it does: no rollback waits on it and it holds no feed token.
        self.assertNotIn("environment", job)
        self.assertNotIn("blind", str(self.wf["jobs"]["rollback"].get("needs")))

    def test_guard_lets_the_gate_write_health_files_and_keeps_the_drill_apart(self):
        env = {**os.environ, "NIGHTLY_NEXT_R2_BUCKET": "cmux-nightly-next", "NIGHTLY_NEXT_R2_PREFIX": "nightly-next/",
               "GITHUB_WORKFLOW_REF": "manaflow-ai/cmux/.github/workflows/nightly-next-health.yml@refs/heads/nightly-next"}
        ok = subprocess.run([sys.executable, str(GUARD), "r2-key", "cmux-nightly-next",
                             "nightly-next/next/health/300.json"], env=env, capture_output=True)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        refused = subprocess.run([sys.executable, str(GUARD), "r2-key", "cmux-nightly-next",
                                  "nightly-next/drill/health/300.json"], env=env, capture_output=True)
        self.assertEqual(refused.returncode, 1)
        env["GITHUB_WORKFLOW_REF"] = "manaflow-ai/cmux/.github/workflows/nightly-next-rollback-drill.yml@refs/heads/nightly-next"
        drill = subprocess.run([sys.executable, str(GUARD), "r2-key", "cmux-nightly-next",
                                "nightly-next/drill/health/300.json"], env=env, capture_output=True)
        self.assertEqual(drill.returncode, 0, drill.stderr)


if __name__ == "__main__":
    unittest.main()
