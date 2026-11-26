#!/usr/bin/env python3
"""mobile-core-package takes a Mac only when a Mac step would run.

mobile-core-linux runs CMUXMobileCore, CmuxMobilePairedMac and CmuxMobileShellModel on Linux for every event;
the Mac job's three test steps run only for a focused dispatch (inputs.swift_package) or the full-ci label. Before
this check the job itself had no such clause, so 223 runs in the 24 h to 2026-11-25T20Z each held a Mac for
checkout and Xcode selection and ran no test (905 Mac minutes). Leo, 2026-11-25: "freeing up the Mac's from doing
things that don't need Mac's asap".
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "test-ios.yml"
STEPS = ("Run CMUXMobileCore package tests", "Run CmuxMobilePairedMac package tests",
         "Run CmuxMobileShellModel package tests")
JOB_GATE = "(inputs.swift_package != '' || contains(github.event.pull_request.labels.*.name, 'full-ci'))"


class MobileCorePackageMacWhenAsked(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        self.job = self.jobs["mobile-core-package"]

    def test_job_runs_only_when_a_mac_step_would(self) -> None:
        self.assertIn(JOB_GATE, " ".join(str(self.job["if"]).split()))

    def test_every_test_step_is_focused_or_full_ci(self) -> None:
        steps = {s.get("name"): s for s in self.job["steps"]}
        for name in STEPS:
            cond = str(steps[name].get("if", ""))
            self.assertIn("env.MAC_RUNS_LINUX_PACKAGES == 'true'", cond, name)
            self.assertIn("inputs.swift_package ==", cond, name)
        env = str(self.job["env"]["MAC_RUNS_LINUX_PACKAGES"])
        self.assertEqual(env, "${{ contains(github.event.pull_request.labels.*.name, 'full-ci') }}")

    def test_linux_job_covers_the_packages(self) -> None:
        body = yaml.safe_dump(self.jobs["mobile-core-linux"])
        for package in ("CMUXMobileCore", "CmuxMobilePairedMac", "CmuxMobileShellModel"):
            self.assertRegex(body, re.escape(package))

    def test_ios_tests_reads_a_skip_as_routed_off(self) -> None:
        gate = self.jobs["ios-tests"]
        self.assertIn("mobile-core-package", gate["needs"])
        run = "\n".join(str(s.get("run", "")) for s in gate["steps"])
        self.assertIn('set(results) - {"detect-ios-changes"}', run)


if __name__ == "__main__":
    unittest.main()
