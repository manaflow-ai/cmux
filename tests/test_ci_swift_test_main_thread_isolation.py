#!/usr/bin/env python3
"""Suites that hold the test process's main thread for minutes run in a process of their own.

RemoteVideoPageTests makes real WebKit downloads; WebKit decides a download's destination on the main thread
inside a kernel call that held it for 70 to 300+ s. The frame benchmarks commit Core Animation transactions
frame by frame on the main thread, and each commit lays out every window the process holds:
SidebarHugeGroupTests.oneGroup10k (about 1 s alone) held it for over 11 minutes in the shared pass. Either one
stalled every main-actor test beside it, and the stuck watchdog killed the run with hundreds of tests unfinished.
The broad pass skips them; a step of their own runs them, one test at a time.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next.yml"
HEAVY = ("CmuxNextBrowserTests.RemoteVideoPageTests", "CmuxNextAppTests.SidebarHugeGroupTests")
VAR = "CMUX_NEXT_MAIN_THREAD_HEAVY"


class MainThreadIsolation(unittest.TestCase):
    def setUp(self) -> None:
        job = yaml.safe_load(WORKFLOW.read_text())["jobs"]["swift-test"]
        self.pattern = job["env"].get(VAR, "")
        self.steps = job["steps"]
        broad = [s for s in self.steps if s.get("name", "").startswith("Run package tests (changed suites first")]
        self.assertEqual(len(broad), 1, "the broad Swift test step is missing or renamed")
        self.broad = broad[0]["run"]

    def test_the_pattern_names_each_heavy_suite(self) -> None:
        self.assertTrue(self.pattern, f"the swift-test job has no {VAR}")
        for suite in HEAVY:
            self.assertRegex(f"{suite}/aTest()", self.pattern, f"{VAR} does not match {suite}")
        self.assertNotRegex("CmuxNextAppTests.SidebarHugeGroupTestsExtra/aTest()", self.pattern)

    def test_the_broad_pass_skips_them(self) -> None:
        self.assertIn(f'--skip "${VAR}"', self.broad, "the broad pass still runs the main-thread-heavy suites")

    def test_a_step_of_their_own_runs_them_one_at_a_time(self) -> None:
        own = [s for s in self.steps if f'--filter "${VAR}"' in s.get("run", "")]
        self.assertEqual(len(own), 1, "no step of its own runs the main-thread-heavy suites")
        step = own[0]
        self.assertIn("swift-test-with-hang-sampler.sh", step["run"])
        self.assertIn("--no-parallel", step["run"])
        self.assertIn("timeout-minutes", step)
        self.assertIn("!cancelled()", step.get("if", ""), "the step is skipped after a red step")
        for target in ("CmuxNextBrowserTests", "CmuxNextAppTests"):
            self.assertIn(f"contains(env.SWIFT_TARGETS, '{target}')", step["if"])


if __name__ == "__main__":
    unittest.main()
