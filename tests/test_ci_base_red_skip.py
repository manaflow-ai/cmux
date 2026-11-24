#!/usr/bin/env python3
"""scripts/ci/base_red_skip.py: a PR job red on the base is skipped; green, unknown or unread runs it."""
from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "ci"))
import base_red_skip as brs  # noqa: E402

WORKFLOWS = os.path.join(ROOT, ".github", "workflows")


def args(**kw):
    base = dict(workflow="w.yml", job="kit", base="feat-cmux-next", runs=6, max_age_hours=12.0, audit_percent=0)
    base.update(kw)
    return argparse.Namespace(**base)


NOW = dt.datetime(2026, 11, 23, 23, 0, tzinfo=dt.timezone.utc)


def reader(runs, created="2026-11-23T22:00:00Z"):
    """runs: list of (run id, [(job name, conclusion)]), newest first."""
    def read(path):
        if "/workflows/" in path:
            return {"workflow_runs": [{"id": rid, "html_url": f"run/{rid}", "created_at": created} for rid, _ in runs]}
        rid = int(path.split("/runs/")[1].split("/")[0])
        jobs = dict(runs)[rid]
        return {"jobs": [{"name": n, "conclusion": c, "html_url": f"job/{rid}/{n}"} for n, c in jobs]}
    return read


PR = {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "7", "GITHUB_RUN_ATTEMPT": "1"}


class BaseRedSkip(unittest.TestCase):
    def test_red_on_base_skips(self):
        out = brs.decide(args(), PR, now=NOW, read=reader([(3, [("kit", "failure")])]))
        self.assertEqual(out, ["base_red=true", "base_run=job/3/kit"])

    def test_green_on_base_runs(self):
        self.assertEqual(brs.decide(args(), PR, now=NOW, read=reader([(3, [("kit", "success")])])), ["base_red=false"])

    def test_skipped_and_cancelled_are_passed_over(self):
        runs = [(5, [("kit", "skipped")]), (4, [("kit", "cancelled"), ("other", "failure")]), (3, [("kit", "success")])]
        self.assertEqual(brs.decide(args(), PR, now=NOW, read=reader(runs)), ["base_red=false"])
        runs[2] = (3, [("kit", "failure")])
        self.assertEqual(brs.decide(args(), PR, now=NOW, read=reader(runs))[0], "base_red=true")

    def test_no_verdict_within_runs_runs(self):
        runs = [(5, [("kit", "skipped")]), (4, [("kit", "failure")])]
        self.assertEqual(brs.decide(args(runs=1), PR, now=NOW, read=reader(runs)), ["base_red=false"])

    def test_old_red_runs(self):
        old = reader([(3, [("kit", "failure")])], created="2026-11-23T10:00:00Z")
        self.assertEqual(brs.decide(args(), PR, now=NOW, read=old), ["base_red=false"])
        self.assertEqual(brs.decide(args(max_age_hours=24.0), PR, now=NOW, read=old)[0], "base_red=true")

    def test_unread_base_fails_open(self):
        def boom(path):
            raise RuntimeError("HTTP 403")
        self.assertEqual(brs.decide(args(), PR, boom), ["base_red=false"])

    def test_push_runs_never_skip(self):
        env = dict(PR, GITHUB_EVENT_NAME="push")
        self.assertEqual(brs.decide(args(), env, now=NOW, read=reader([(3, [("kit", "failure")])])), ["base_red=false"])

    def test_audit_runs_in_full(self):
        self.assertTrue(any(brs.audited(10, str(i), "1", "kit") for i in range(100)))
        self.assertFalse(brs.audited(0, "7", "1", "kit"))
        out = brs.decide(args(audit_percent=100), PR, now=NOW, read=reader([(3, [("kit", "failure")])]))
        self.assertEqual(out[0], "base_red=false")

    def test_workflows_wire_the_switch_and_full_ci(self):
        wired = {
            "cmux-next-guards.yml": "tooling-tests",
            "cloud-journey-pr.yml": "journey-staging",
        }
        for name, job in wired.items():
            with open(os.path.join(WORKFLOWS, name), encoding="utf-8") as fh:
                text = fh.read()
            self.assertIn("scripts/ci/base_red_skip.py decide", text, name)
            self.assertIn(f'--job "{job}"', text, name)
            self.assertIn("format('{0}', vars.CI_SKIP_WHILE_BASE_RED) != '0'", text, name)
            self.assertIn("'full-ci'", text, name)
        with open(os.path.join(WORKFLOWS, "cmux-next-ios-kit.yml"), encoding="utf-8") as fh:
            self.assertNotIn("base_red_skip.py", fh.read(), "Leo wants every PR to get a proper kit run")


if __name__ == "__main__":
    unittest.main()
