#!/usr/bin/env python3
"""A routed job checks each need's result itself, and the web rollup gate always runs.

A job whose if calls no status function gets GitHub's implicit success(), which reads every ancestor, not just its
needs: after `changes` (always()) routed web=true, run 41892308895's whole-run attempt 3 skipped `web`, its shards
and the webview verdict, and the verdict could not be refreshed without a new commit. So each of these jobs says
!cancelled() and checks the result of each job it needs, and a failed or skipped router still skips them.
The web rollup gate must run on a cancel and fail closed, because a skipped gate reads as passing.
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

WORKFLOWS = Path(__file__).resolve().parents[1] / ".github/workflows"
RESULT_CHECKED = {"ci.yml": ("guards", "ghosttykit-release-check", "browser", "remote-daemon", "web",
                             "dogfood-build"),
                  "cmux-next.yml": ("web-bundles", "request-nightly-next")}


def jobs(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))["jobs"]


def needs(job: dict) -> list[str]:
    value = job.get("needs") or []
    return [value] if isinstance(value, str) else list(value)


class RoutedJobsCheckTheirNeeds(unittest.TestCase):
    def test_routed_jobs_skip_on_a_failed_or_skipped_need(self):
        for workflow, names in RESULT_CHECKED.items():
            workflow_jobs = jobs(workflow)
            for name in names:
                with self.subTest(job=f"{workflow}#{name}"):
                    condition = " ".join(str(workflow_jobs[name]["if"]).split())
                    self.assertIn("!cancelled()", condition)
                    for need in needs(workflow_jobs[name]):
                        self.assertIn(f"needs.{need}.result == 'success'", condition)

    def test_the_web_rollup_gate_always_runs(self):
        self.assertEqual(jobs("web-validation.yml")["web-validation"]["if"], "always()")


if __name__ == "__main__":
    unittest.main()
