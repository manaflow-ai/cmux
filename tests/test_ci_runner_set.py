#!/usr/bin/env python3
"""The CI paths that have stalled must resolve through the live Linux pool.

The broker can move a fast-check run only when its workflow accepts the
declared overflow set.  These jobs therefore must read RUNNER_POOLS for their
normal route and may not fall back to one Blacksmith label.
"""

from __future__ import annotations

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
        # (.github/runners.json hosted_light_jobs): ephemeral hosted Ubuntu on attempt 1, Blacksmith
        # 8 vCPU on a re-run, never LINUX_RUNNER's one size (run 41385632466 sat on its 4 vCPU queue)
        # and never a persistent fleet label, since the job mints GLAEDA_ROUTE_APP_KEY tokens.
        job = yaml.safe_load((WORKFLOWS / "ci.yml").read_text())["jobs"]["changes"]
        runs_on = job["runs-on"]
        self.assertNotIn(POOL, runs_on)
        self.assertNotIn("LINUX_RUNNER", runs_on)
        self.assertIn("github.run_attempt == 1 && 'ubuntu-24.04'", runs_on)
        self.assertTrue(runs_on.rstrip().endswith(
            "|| vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-8vcpu-ubuntu-2404' }}"), runs_on)
        self.assertNotIn("cmux-fleet-linux-x64", runs_on)
        self.assertNotIn("glaeda-", runs_on)

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

    def test_fast_checks_keeps_the_broker_overflow_set(self) -> None:
        runs_on = str((yaml.safe_load((WORKFLOWS / "fast-checks.yml").read_text()) or {})["jobs"]["checks"]["runs-on"])
        self.assertIn("inputs.runner", runs_on)
        self.assertIn("blacksmith-8vcpu-ubuntu-2404", runs_on)
        self.assertIn("blacksmith-16vcpu-ubuntu-2404", runs_on)
        self.assertIn("blacksmith-32vcpu-ubuntu-2404", runs_on)


if __name__ == "__main__":
    unittest.main()
