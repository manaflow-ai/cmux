#!/usr/bin/env python3
"""Suites that hold the main thread outside the test's control run in their own process.

RemoteVideoPageTests makes real WebKit downloads, and WebKit decides a download's destination
on the main thread inside a kernel call that held it for 70 to 300+ s on CI minis. In the shared
"selected targets" pass every main-actor test beside it stalled, and the stuck watchdog killed
the run with thousands of tests unfinished. The broad pass skips it; a step of its own runs it.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next.yml"
ISOLATED = ("RemoteVideoPageTests",)


def swift_test_steps() -> list[dict]:
    jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
    return jobs["swift-test"]["steps"]


class MainThreadIsolation(unittest.TestCase):
    def setUp(self) -> None:
        self.steps = swift_test_steps()
        broad = [s for s in self.steps if s.get("name", "").startswith("Run package tests (changed suites first")]
        self.assertEqual(len(broad), 1, "the broad Swift test step is missing or renamed")
        self.broad = broad[0]["run"]

    def test_the_broad_pass_skips_each_isolated_suite(self) -> None:
        for suite in ISOLATED:
            self.assertRegex(self.broad, rf"--skip {re.escape(suite)}\b", f"the broad pass still runs {suite}")

    def test_each_isolated_suite_runs_in_a_step_of_its_own(self) -> None:
        for suite in ISOLATED:
            own = [s for s in self.steps if re.search(rf"--filter {re.escape(suite)}\b", s.get("run", ""))]
            self.assertEqual(len(own), 1, f"no step of its own runs {suite}")
            step = own[0]
            self.assertIn("swift-test-with-hang-sampler.sh", step["run"], f"{suite} runs without the hang sampler")
            self.assertIn("timeout-minutes", step, f"{suite}'s step has no timeout")
            self.assertIn("!cancelled()", step.get("if", ""), f"{suite}'s step is skipped after a red step")


if __name__ == "__main__":
    unittest.main()
