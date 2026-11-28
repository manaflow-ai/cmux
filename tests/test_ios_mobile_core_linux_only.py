#!/usr/bin/env python3
"""The mobile-core packages test on Linux only; no Mac job holds a runner for them.

mobile-core-linux runs CMUXMobileCore, CmuxMobilePairedMac and CmuxMobileShellModel on Linux for every event,
including a focused dispatch (inputs.swift_package with inputs.test_filter). The Mac job mobile-core-package is
gone; a full-ci PR still cross-checks the packages on macOS inside ios-simulator-build, which already holds a Mac,
so the Darwin-only tests (CoreImage QR bitmaps, os.Logger) keep running there. Leo, 2026-11-25: "freeing up the
Mac's from doing things that don't need Mac's asap".
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "test-ios.yml"
PACKAGES = ("Packages/Shared/CMUXMobileCore", "Packages/iOS/CmuxMobilePairedMac", "Packages/iOS/CmuxMobileShellModel")


class MobileCoreLinuxOnly(unittest.TestCase):
    def setUp(self) -> None:
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def test_no_mac_package_job(self) -> None:
        self.assertNotIn("mobile-core-package", self.jobs)
        routes = json.loads((ROOT / ".github" / "runners.json").read_text(encoding="utf-8"))
        self.assertNotIn("test-ios.yml#mobile-core-package", json.dumps(routes))

    def test_linux_job_covers_the_packages_and_focused_dispatch(self) -> None:
        job = self.jobs["mobile-core-linux"]
        rows = (ROOT / "scripts" / "ci" / "swift-linux-packages.txt").read_text(encoding="utf-8")
        for package in PACKAGES:
            self.assertIn(package, rows)
        cond = " ".join(str(job["if"]).split())
        self.assertIn("(inputs.swift_package != '' || inputs.test_filter == '')", cond)
        run = "\n".join(str(s.get("run", "")) for s in job["steps"])
        self.assertIn("FOCUSED_SWIFT_PACKAGE", run)
        self.assertIn('targets="${SWIFT_TEST_FILTER:-$targets}"', run)

    def test_full_ci_cross_checks_on_the_mac_that_is_already_held(self) -> None:
        steps = self.jobs["ios-simulator-build"]["steps"]
        step = next(s for s in steps if s.get("name") == "Mac cross-check of the mobile-core packages (full-ci)")
        self.assertEqual(step["if"], "${{ (contains(github.event.pull_request.labels.*.name, 'full-ci')"
                                     " && (github.event.pull_request.base.ref != 'feat-cmux-next'"
                                     " || (github.event.action == 'labeled' && github.event.label.name == 'full-ci')"
                                     " || (vars.CI_FULL_CI_ONE_SHOT || '1') == '0')) }}")
        for package in PACKAGES:
            self.assertIn(package, step["run"])
        self.assertIn("require_selected_test_execution.sh", step["run"])

    def test_ios_tests_gates_on_the_linux_job(self) -> None:
        needs = self.jobs["ios-tests"]["needs"]
        self.assertIn("mobile-core-linux", needs)
        self.assertNotIn("mobile-core-package", needs)


if __name__ == "__main__":
    unittest.main()
