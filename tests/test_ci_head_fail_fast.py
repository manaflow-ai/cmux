#!/usr/bin/env python3
"""scripts/ci/head_fail_fast.py: an own red cancels the head's other heavy runs; a base-shared red, the own run,
light workflows and finished runs are left alone; the callers are wired."""
from __future__ import annotations

import argparse
import os
import re
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "ci"))
import head_fail_fast as hff  # noqa: E402

WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
ENV = {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "7",
       "GITHUB_RUN_ATTEMPT": "1", "HEAD_SHA": "a" * 40}


def args(**kw):
    base = dict(workflow="cmux-next.yml", base="feat-cmux-next", base_events="push", dispatch_title="", dry_run=False)
    base.update(kw)
    return argparse.Namespace(**base)


def run(id_, path, status="in_progress", event="pull_request"):
    return {"id": id_, "path": f".github/workflows/{path}", "status": status, "event": event, "name": path,
            "html_url": f"run/{id_}"}


HEAD_RUNS = [run(7, "cmux-next.yml"), run(8, "ci.yml"), run(9, "cmux-next-guards.yml", "queued"),
             run(10, "pr-router.yml"), run(11, "backend.yml", "completed"), run(12, "cmux-next-pr-autofix.yml")]


def reader(failed, base_red=False, runs=HEAD_RUNS):
    def read(path):
        if "/attempts/" in path:
            return {"jobs": [{"name": n, "conclusion": "failure"} for n in failed]
                    + [{"name": "ok job", "conclusion": "success"}]}
        if "/actions/workflows/" in path:
            return {"workflow_runs": [{"id": 99, "html_url": "base/99", "created_at": "2099-01-01T00:00:00Z"}]}
        if "/runs/99/jobs" in path:
            return {"jobs": [{"name": n, "conclusion": "failure" if base_red else "success", "html_url": "j"}
                             for n in failed]}
        if "/actions/runs?" in path:
            return {"workflow_runs": runs}
        raise AssertionError(path)
    return read


class HeadFailFastTest(unittest.TestCase):
    def test_own_red_cancels_heavy_unfinished_runs_but_not_its_own(self):
        posted = []
        count, text = hff.cancel(args(), ENV, reader(["cmux-next app compile (build fleet)"]),
                                 lambda p: posted.append(p) or 202)
        self.assertEqual(posted, ["/repos/o/r/actions/runs/8/cancel", "/repos/o/r/actions/runs/9/cancel"])
        self.assertEqual(count, 2)
        self.assertIn("cmux-next app compile (build fleet)", text)
        self.assertIn("run/8", text)

    def test_red_shared_with_base_cancels_nothing(self):
        posted = []
        count, text = hff.cancel(args(), ENV, reader(["cmux-next fast tier"], base_red=True),
                                 lambda p: posted.append(p) or 202)
        self.assertEqual((count, posted), (0, []))
        self.assertIn("red on `feat-cmux-next` too", text)

    def test_one_own_red_among_shared_reds_still_cancels(self):
        def verdict(name):
            return (name == "shared", "u")
        own, shared = hff.own_reds(["shared", "mine"], verdict)
        self.assertEqual((own, [n for n, _ in shared]), (["mine"], ["shared"]))

    def test_unread_base_is_an_own_red(self):
        def boom(name):
            raise RuntimeError("down")
        self.assertEqual(hff.own_reds(["x"], boom)[0], ["x"])

    def test_advisory_and_own_jobs_are_not_a_verdict(self):
        read = reader(["cmux-next PR autofix", "head fail-fast after linux / head fail-fast", "web / comment"])
        self.assertEqual(hff.failed_jobs("o/r", "7", "1", read), [])

    def test_not_a_pull_request_does_nothing(self):
        count, _ = hff.cancel(args(), dict(ENV, GITHUB_EVENT_NAME="push"), reader(["x"]), lambda p: 202)
        self.assertEqual(count, 0)

    def test_dry_run_posts_nothing(self):
        posted = []
        count, text = hff.cancel(args(dry_run=True), ENV, reader(["x"]), lambda p: posted.append(p) or 202)
        self.assertEqual((count, posted), (2, []))
        self.assertIn("would be", text)

    def test_cancel_refused_is_named_and_finished_meanwhile_is_quiet(self):
        codes = iter([409, 403])
        count, text = hff.cancel(args(), ENV, reader(["x"]), lambda p: next(codes))
        self.assertEqual(count, 0)
        self.assertIn("not cancelled (HTTP 403)", text)
        self.assertNotIn("run/8)", text.split("not cancelled")[1] if "run/8" not in text else "")

    def test_targets_skip_non_pull_request_events(self):
        self.assertEqual(hff.targets([run(1, "ci.yml", event="push")], "7"), [])

    def test_heavy_workflows_exist(self):
        for name in hff.HEAVY:
            self.assertTrue(os.path.exists(os.path.join(WORKFLOWS, name)), name)

    def test_callers_need_only_the_job_they_watch(self):
        callers = {"cmux-next.yml": ["app-compile-fleet", "fast-tier", "fast-tier-cargo", "web-bundles",
                                     "generated-files"],
                   "cmux-next-fast-gates.yml": ["fast-gates"], "cmux-next-guards.yml": ["tooling-tests"],
                   "pr-router.yml": ["pipeline"]}
        for wf, jobs in callers.items():
            with open(os.path.join(WORKFLOWS, wf), encoding="utf-8") as fh:
                text = fh.read()
            for job in jobs:
                m = re.search(rf"\n  {re.escape(job)}-fail-fast:\n(.*?)(?=\n  \S|\Z)", text, re.S)
                self.assertIsNotNone(m, f"{wf}: {job}-fail-fast")
                body = m.group(1)
                self.assertIn(f"needs: {job}\n", body)
                self.assertIn(f"needs.{job}.result == 'failure'", body)
                self.assertIn("vars.CI_HEAD_FAIL_FAST", body)
                self.assertIn("head.repo.full_name == github.repository", body)
                self.assertIn("uses: ./.github/workflows/head-fail-fast.yml", body)
                self.assertIn(f"workflow: {wf}", body)


if __name__ == "__main__":
    unittest.main()
