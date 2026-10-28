#!/usr/bin/env python3
"""Suites that hold the test process's main thread for minutes run in a process of their own.

Each Core Animation commit in the shared swift test process lays out every window it holds:
SidebarHugeGroupTests.oneGroup10k (about 1 s alone) and SidebarLagTests held the main thread for 5 to 11+
minutes there, and RemoteVideoPageTests' WebKit downloads held it in a kernel call for 300+ s. Every
main-actor test beside them stalled and the stuck watchdog killed the run. scripts/cmux-next/main-thread-heavy-suites.py
names them from the test sources; the broad pass skips them and a serial step runs them.
"""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next.yml"
SCRIPT = ROOT / "scripts" / "cmux-next" / "main-thread-heavy-suites.py"
TESTS = ROOT / "Packages" / "macOS" / "CmuxNext" / "Tests"
VAR = "CMUX_NEXT_MAIN_THREAD_HEAVY"

spec = importlib.util.spec_from_file_location("heavy", SCRIPT)
heavy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(heavy)


class HeavySuites(unittest.TestCase):
    def test_the_suites_that_stalled_the_shared_pass_are_found(self) -> None:
        found = {f"{t}.{n}" for t, n in heavy.heavy_suites(TESTS)}
        for suite in ("CmuxNextBrowserTests.RemoteVideoPageTests", "CmuxNextAppTests.SidebarHugeGroupTests",
                      "CmuxNextAppTests.SidebarLagTests", "CmuxNextAppTests.LayoutDragBench"):
            self.assertIn(suite, found)
        self.assertNotIn("CmuxNextAppTests.TestProcessExitTests", found)

    def test_a_suite_that_uses_a_frame_driving_helper_is_heavy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "SomeTests"
            target.mkdir()
            (target / "Bench.swift").write_text("final class FooBench {\n    func drawFrame() { CATransaction.flush() }\n}\n")
            (target / "FooTests.swift").write_text("@MainActor @Suite struct FooTests {\n    @Test func a() { FooBench().drawFrame() }\n}\n")
            (target / "PlainTests.swift").write_text("struct PlainTests {\n    @Test func a() {}\n}\n")
            found = heavy.heavy_suites(Path(tmp))
        self.assertIn(("SomeTests", "FooTests"), found)
        self.assertNotIn(("SomeTests", "PlainTests"), found)
        self.assertNotIn(("SomeTests", "FooBench"), found)

    def test_the_pattern_matches_whole_suite_names_only(self) -> None:
        pattern = heavy.pattern([("CmuxNextAppTests", "SidebarLagTests")])
        self.assertRegex("CmuxNextAppTests.SidebarLagTests/aTest()", pattern)
        self.assertNotRegex("CmuxNextAppTests.SidebarLagTestsExtra/aTest()", pattern)


class Workflow(unittest.TestCase):
    def setUp(self) -> None:
        self.steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["swift-test"]["steps"]
        self.names = [s.get("name", "") for s in self.steps]

    def step(self, prefix: str) -> dict:
        found = [s for s in self.steps if s.get("name", "").startswith(prefix)]
        self.assertEqual(len(found), 1, f"no single step named {prefix!r}")
        return found[0]

    def test_the_list_is_derived_before_the_broad_pass_which_skips_it(self) -> None:
        derive = self.step("Find the main-thread-heavy suites")
        self.assertIn("main-thread-heavy-suites.py", derive["run"])
        self.assertIn(f"{VAR}=", derive["run"])
        broad = self.step("Run package tests (changed suites first")
        self.assertLess(self.steps.index(derive), self.steps.index(broad))
        self.assertIn(f'--skip "${VAR}"', broad["run"])

    def test_a_serial_step_of_their_own_runs_them(self) -> None:
        own = self.step("Run main-thread-heavy suites in their own process")
        self.assertIn(f'--filter "${VAR}"', own["run"])
        self.assertIn("swift-test-with-hang-sampler.sh", own["run"])
        self.assertIn("--no-parallel", own["run"])
        self.assertIn("timeout-minutes", own)
        self.assertIn("!cancelled()", own["if"])


if __name__ == "__main__":
    unittest.main()
