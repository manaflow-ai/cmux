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

    def test_dispatch_runs_count_when_asked(self):
        def read(path):
            if "/workflows/" in path:
                if "event=workflow_dispatch" in path:
                    return {"workflow_runs": [
                        {"id": 10, "created_at": "2026-11-23T22:40:00Z", "display_title": "cmux NEXT DEV daily · a"},
                        {"id": 9, "created_at": "2026-11-23T22:30:00Z", "display_title": "cmux-next base tier · b"}]}
                return {"workflow_runs": [{"id": 8, "created_at": "2026-11-23T22:45:00Z"},
                                          {"id": 7, "created_at": "2026-11-23T22:00:00Z"}]}
            rid = int(path.split("/runs/")[1].split("/")[0])
            verdict = {8: "skipped", 9: "failure", 7: "success", 10: "success"}[rid]
            return {"jobs": [{"name": "kit", "conclusion": verdict, "html_url": f"job/{rid}"}]}
        self.assertEqual(brs.decide(args(), PR, now=NOW, read=read), ["base_red=false"])
        self.assertEqual(brs.decide(args(events="push,workflow_dispatch"), PR, now=NOW, read=read),
                         ["base_red=false"])  # the DEV daily run's green is newest
        out = brs.decide(args(events="push,workflow_dispatch", dispatch_title="cmux-next base tier"), PR, now=NOW,
                         read=read)
        self.assertEqual(out, ["base_red=true", "base_run=job/9"])
        # Two newer push runs that skip the job do not crowd out the dispatch under --runs 1.
        self.assertEqual(brs.decide(args(events="push,workflow_dispatch", dispatch_title="cmux-next base tier",
                                         runs=1), PR, now=NOW, read=read)[0], "base_red=true")

    def test_audit_runs_in_full(self):
        self.assertTrue(any(brs.audited(10, str(i), "1", "kit") for i in range(100)))
        self.assertFalse(brs.audited(0, "7", "1", "kit"))
        out = brs.decide(args(audit_percent=100), PR, now=NOW, read=reader([(3, [("kit", "failure")])]))
        self.assertEqual(out[0], "base_red=false")

    def test_decide_many_one_read_set_for_every_job(self):
        calls = []
        base = reader([(5, [("a", "failure"), ("b", "skipped")]), (4, [("b", "success"), ("c", "failure")]),
                       (3, [("c", "success")])])

        def read(path):
            calls.append(path)
            return base(path)
        out = brs.decide_many(args(job=["a", "b", "c", "d"]), PR, now=NOW, read=read)
        self.assertEqual(out, ['red_jobs=["a","c"]'])
        self.assertEqual(len(calls), 4, calls)  # the list, then each run once; d has no verdict, so all are read

    def test_decide_many_stops_reading_once_every_job_is_decided(self):
        calls = []
        base = reader([(5, [("a", "success"), ("b", "failure")]), (4, [("a", "failure")])])

        def read(path):
            calls.append(path)
            return base(path)
        self.assertEqual(brs.decide_many(args(job=["a", "b"]), PR, now=NOW, read=read), ['red_jobs=["b"]'])
        self.assertEqual(len(calls), 2)

    def test_decide_many_fails_open_and_skips_only_pull_requests(self):
        def boom(path):
            raise RuntimeError("HTTP 403")
        self.assertEqual(brs.decide_many(args(job=["a"]), PR, boom), ["red_jobs=[]"])
        red = reader([(3, [("a", "failure")])])
        self.assertEqual(brs.decide_many(args(job=["a"]), dict(PR, GITHUB_EVENT_NAME="push"), now=NOW, read=red),
                         ["red_jobs=[]"])
        old = reader([(3, [("a", "failure")])], created="2026-11-23T10:00:00Z")
        self.assertEqual(brs.decide_many(args(job=["a"]), PR, now=NOW, read=old), ["red_jobs=[]"])

    def test_decide_many_audit_runs_the_job(self):
        red = reader([(3, [("a", "failure"), ("b", "failure")])])
        self.assertEqual(brs.decide_many(args(job=["a", "b"], audit_percent=100), PR, now=NOW, read=red),
                         ["red_jobs=[]"])

    def test_a_red_past_twelve_skipped_base_runs_still_skips(self):
        """2026-11-25: 462 of 548 base push cargo rows were skipped, so 12 runs often held no verdict and the PR ran."""
        runs = [(100 - i, [("kit", "skipped")]) for i in range(20)] + [(50, [("kit", "failure")])]
        self.assertEqual(brs.decide(args(runs=12), PR, now=NOW, read=reader(runs)), ["base_red=false"])
        self.assertEqual(brs.decide(args(runs=60), PR, now=NOW, read=reader(runs))[0], "base_red=true")

    def test_a_failed_read_keeps_the_verdicts_already_read(self):
        base = reader([(5, [("a", "failure")]), (4, [("b", "success")])])

        def read(path):
            if "/runs/4/" in path:
                raise TimeoutError("deadline")
            return base(path)
        self.assertEqual(brs.decide_many(args(job=["a", "b"]), PR, now=NOW, read=read), ['red_jobs=["a"]'])

        def none_found(path):
            if "/runs/" in path and "/workflows/" not in path:
                raise TimeoutError("deadline")
            return base(path)
        self.assertEqual(brs.decide_many(args(job=["a"]), PR, now=NOW, read=none_found), ["red_jobs=[]"])

    def test_cmux_next_cargo_reads_past_the_skipped_base_runs(self):
        with open(os.path.join(WORKFLOWS, "cmux-next.yml"), encoding="utf-8") as fh:
            text = fh.read()
        line = next(x for x in text.splitlines() if 'decide-many --workflow cmux-next.yml' in x)
        runs = int(line.split("--runs ")[1].split()[0])
        # 0.85 ** 12 = 14% of PRs found no verdict; 0.85 ** 40 = 0.15%.
        self.assertGreaterEqual(runs, 40, line)

    def test_workflows_wire_the_switch_and_full_ci(self):
        wired = {
            "cmux-next-guards.yml": ["tooling-tests"],
            "cloud-journey-pr.yml": ["journey-staging"],
            "cmux-next.yml": ["cmux-next fast tier (cargo)", "cmux-next generated files"],
        }
        for name, jobs in wired.items():
            with open(os.path.join(WORKFLOWS, name), encoding="utf-8") as fh:
                text = fh.read()
            self.assertIn("scripts/ci/base_red_skip.py decide", text, name)
            for job in jobs:
                self.assertIn(f'--job "{job}"', text, name)
                if job == "cmux-next fast tier (cargo)":  # decide-many: the job reads its own name in the list
                    self.assertIn(f"outputs.base_red_jobs || '[]'), '{job}')", text, name)
            self.assertIn("format('{0}', vars.CI_SKIP_WHILE_BASE_RED) != '0'", text, name)
            self.assertIn("'full-ci'", text, name)
        with open(os.path.join(WORKFLOWS, "cmux-next-ios-kit.yml"), encoding="utf-8") as fh:
            self.assertNotIn("base_red_skip.py", fh.read(), "Leo wants every PR to get a proper kit run")


if __name__ == "__main__":
    unittest.main()
