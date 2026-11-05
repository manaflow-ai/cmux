#!/usr/bin/env python3
"""The CI paths that have stalled must resolve through the live Linux pool.

The broker can move a fast-check run only when its workflow accepts the
declared overflow set.  These jobs therefore must read RUNNER_POOLS for their
normal route and may not fall back to one Blacksmith label.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
POOL = "fromJSON(vars.RUNNER_POOLS).linux"
TARGETS = {
    "app-platform.yml": {"check"},
    "cmux-next-terminal.yml": {"rust-terminal-linux", "swift-terminal-linux"},
    "fast-checks.yml": {"checks"},
    # 2026-10-31T23:57Z queue alarms: each sat 44-46 min on one Blacksmith size that started nothing
    # (gallery health on 16 vCPU, web validation and PR checks' base-only on 32, the cloud backend check on
    # the capability map's fixed 4 vCPU label).
    "gallery-health.yml": {"health"},
    "web-validation.yml": {"changes", "build", "tests", "database", "web-validation"},
    "pr-checks.yml": {"base-only", "size", "ui-review", "split"},
    "pr-cloud-backend-check.yml": {"cloud-backend"},
}


class RunnerSetTests(unittest.TestCase):
    def test_secret_bearing_changes_takes_ephemeral_hosted_then_measured_retry(self) -> None:
        # The router runs before any picker can, so it is a declared hosted light job
        # (.github/runners.json hosted_light_jobs). Its credentialed body takes a live
        # verified fleet Linux placement when available, then hosted/paid overflow.
        job = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["changes"]
        runs_on = job["runs-on"]
        self.assertIn("needs.portable-placement.outputs.linux_runner", runs_on)
        self.assertIn("needs.portable-placement.outputs.placed_attempt == format('{0}', github.run_attempt)", runs_on)
        self.assertIn("github.run_attempt == 1 && 'ubuntu-24.04'", runs_on)
        self.assertTrue(runs_on.rstrip().endswith(
            "|| vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || fromJSON(vars.RUNNER_POOLS).linux_8 }}"), runs_on)
        self.assertEqual(job["needs"], ["portable-placement"])
        self.assertEqual(yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["portable-placement"]["steps"][-1]["env"]["LINUX_ONLY"], "changes")

    def test_light_report_jobs_take_hosted_ubuntu_first(self) -> None:
        # Declared light jobs (.github/runners.json hosted_light_jobs): a few seconds of report or
        # routing work each, which on 2026-11-02 waited up to a minute behind the saturated
        # blacksmith-4vcpu-ubuntu-2404 queue. Hosted Ubuntu on attempt 1, then a declared retry.
        import json

        declared = json.loads((ROOT / ".github" / "runners.json").read_text())["hosted_light_jobs"]
        hosted = "github.run_attempt == 1 && 'ubuntu-24.04'"
        # The job that holds a pull-requests write token, or runs the checked-out revision's
        # scripts, retries only on ephemeral Blacksmith; the rest may take the reconciled pool.
        ephemeral = "|| vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || fromJSON(vars.RUNNER_POOLS).linux_8 }}"
        cases = {
            ("pr-red-checks-comment.yml", "comment"): ephemeral,
            ("cmux-next.yml", "path_route"): ephemeral,
            ("ci-guards.yml", "guard-status"): f"|| {POOL} }}}}",
            ("pr-checks.yml", "size"): f"|| {POOL} }}}}",
            ("pr-checks.yml", "ui-review"): f"|| {POOL} }}}}",
        }
        for (workflow, name), tail in cases.items():
            with self.subTest(job=f"{workflow}#{name}"):
                self.assertIn(f"{workflow}#{name}", declared)
                runs_on = yaml.safe_load((WORKFLOWS / workflow).read_text())["jobs"][name]["runs-on"]
                # A fork's run keeps the label it had; every other run reads the pool.
                runs_on = re.sub(r"\(github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name"
                                 r" != github\.repository && 'blacksmith-\d+vcpu-ubuntu-2404' \|\| (fromJSON\(vars\.RUNNER_POOLS\)\.[a-z0-9_]+)\)", r"\1", runs_on)
                self.assertIn(hosted, runs_on)
                self.assertTrue(runs_on.rstrip().endswith(tail), runs_on)
                self.assertNotIn("cmux-fleet-linux-x64", runs_on)

    def test_stalled_paths_use_the_live_linux_pool(self) -> None:
        for workflow, names in TARGETS.items():
            document = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8")) or {}
            jobs = document.get("jobs") or {}
            for name in names:
                with self.subTest(workflow=workflow, job=name):
                    runs_on = jobs[name]["runs-on"]
                    self.assertIsInstance(runs_on, str)
                    self.assertIn(POOL, runs_on)
                    self.assertNotIn("vars.LINUX_RUNNER || 'blacksmith-", runs_on)
                    self.assertNotIn("CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-", runs_on)
                    self.assertNotIn("outputs.map", runs_on)
                    # Past the fork branches, no Blacksmith size is written down.
                    self.assertNotIn("'blacksmith-", runs_on.split("github.repository && ")[-1].split("|| ", 1)[-1])
                    self.assertNotRegex(runs_on, r"RUNNER_POOLS\)\.linux_\d")

    def test_cmux_next_pr_quiet_period_comes_before_every_check(self) -> None:
        # A PR run sleeps until about 5 minutes after the PR's last push, so a newer push cancels a
        # run that has spent only the sleep. Leo, 2026-11-05: "i meant can you do all of htem".
        import json

        jobs = yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text())["jobs"]
        gate = jobs["pr-quiet-period"]
        self.assertIn("cmux-next.yml#pr-quiet-period",
                      json.loads((ROOT / ".github" / "runners.json").read_text())["hosted_light_jobs"])
        self.assertNotIn("needs", gate)
        self.assertIn("github.event_name == 'pull_request'", gate["if"])
        self.assertIn("github.run_attempt == 1", gate["if"])
        # landing.md: a leo-named-fix PR lands with no wait.
        self.assertIn("!contains(github.event.pull_request.labels.*.name, 'leo-named-fix')", gate["if"])
        self.assertIn("github.run_attempt == 1 && 'ubuntu-24.04'", gate["runs-on"])
        # A fork's sleep takes hosted Ubuntu too; no Blacksmith label is written down (review F1 of #36353).
        self.assertNotIn("'blacksmith-", gate["runs-on"])
        self.assertTrue(gate["runs-on"].rstrip().endswith(
            "|| vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || fromJSON(vars.RUNNER_POOLS).linux_8 }}"))
        self.assertEqual(gate["permissions"], {})
        self.assertTrue(all(step.get("continue-on-error") for step in gate["steps"]))
        # The two root jobs wait for it, and run when it is skipped (pushes, dispatches, re-runs).
        for name in ("portable-placement", "push-head-preflight"):
            with self.subTest(job=name):
                self.assertEqual(jobs[name]["needs"], ["pr-quiet-period"])
                self.assertTrue(jobs[name]["if"].startswith("${{ !cancelled() && "), jobs[name]["if"])
        # Every other job starts after one of them: nothing heavy skips the wait.
        roots = {"pr-quiet-period", "portable-placement", "push-head-preflight", "dev-landing-place"}
        for name, job in jobs.items():
            if name in roots:
                continue
            with self.subTest(job=name):
                self.assertTrue(job.get("needs"), f"{name} starts before the quiet period ends")
                # The implicit success() reads every ancestor, the skipped gate included (a push, a re-run),
                # so each job after it says how it treats a skipped or failed need (#35871).
                self.assertRegex(str(job.get("if", "")), r"always\(\)|cancelled\(\)|failure\(\)",
                                 f"{name} would skip whenever pr-quiet-period skips")
        self.assertTrue(jobs["dev-landing-place"]["if"].startswith("${{ github.event_name == 'push'"))

    def test_fast_checks_keeps_the_broker_overflow_set(self) -> None:
        runs_on = str((yaml.safe_load((WORKFLOWS / "fast-checks.yml").read_text()) or {})["jobs"]["checks"]["runs-on"])
        self.assertIn("inputs.runner", runs_on)
        self.assertIn("blacksmith-8vcpu-ubuntu-2404", runs_on)
        self.assertIn("blacksmith-16vcpu-ubuntu-2404", runs_on)
        self.assertIn("blacksmith-32vcpu-ubuntu-2404", runs_on)


if __name__ == "__main__":
    unittest.main()
