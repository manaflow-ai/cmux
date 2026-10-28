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
import re
import sys
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
sys.modules[spec.name] = heavy  # a @dataclass reads its module from sys.modules
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

    def test_a_nested_helper_type_is_not_read_as_a_suite(self) -> None:
        # run 40705037968 filtered on CmuxNextAppTests.Harness, a class nested in a suite: 0 tests ran.
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "SomeTests"
            target.mkdir()
            (target / "BarTests.swift").write_text(
                "@MainActor @Suite(.serialized)\nstruct BarTests {\n    @MainActor final class Harness {\n"
                "        func go() { CATransaction.flush() }\n    }\n    @Test func a() { Harness().go() }\n}\n")
            found = heavy.heavy_suites(Path(tmp))
        self.assertIn(("SomeTests", "BarTests"), found)
        self.assertNotIn(("SomeTests", "Harness"), found)

    def test_every_suite_found_is_a_top_level_type(self) -> None:
        for target, name in heavy.heavy_suites(TESTS):
            if (target, name) in heavy.ALWAYS:
                continue
            with self.subTest(suite=f"{target}.{name}"):
                files = (TESTS / target).rglob("*.swift")
                self.assertTrue(any(re.search(rf"^(?:@[^\n]*[ \t])?(?:\w+[ \t]+)*(?:struct|class|enum|actor)[ \t]+{name}\b",
                                              f.read_text(errors="replace"), re.M) for f in files))

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
        # Skipped only when there is something to skip: --skip "" skips every test.
        self.assertIn(f'[[ -z "${VAR}" ]] || heavy_skip=(--skip "${VAR}")', broad["run"])
        self.assertEqual(broad["run"].count(f'--skip "${VAR}"'), 1)
        self.assertEqual(broad["run"].count('${heavy_skip[@]+"${heavy_skip[@]}"}'), 2)

    def test_the_changed_suites_pass_skips_the_heavy_suites_too(self) -> None:
        # sr2 on #26809: a change touching AAGroupLineGalleryTests and SidebarScrollCostTests selected both into
        # the one changed-suites process, where the windows piled up again.
        broad = self.step("Run package tests (changed suites first")["run"]
        priority = broad[broad.index('--filter "$SWIFT_PRIORITY_FILTER"'):]
        self.assertTrue(priority.split("then", 1)[0].rstrip().endswith('${heavy_skip[@]+"${heavy_skip[@]}"};'))

    def test_only_the_selected_targets_heavy_suites_run(self) -> None:
        # sr2 on #26809: a control-only change ran all 56 heavy suites (AppKit benches, WebKit downloads).
        derive = self.step("Find the main-thread-heavy suites")["run"]
        self.assertEqual(derive.count('--targets "$SWIFT_TARGETS"'), 2)
        self.assertEqual(heavy.heavy_suites(TESTS, "CmuxNextControlTests"), [])
        browser = heavy.heavy_suites(TESTS, "CmuxNextBrowserTests CmuxNextControlTests")
        self.assertIn(("CmuxNextBrowserTests", "RemoteVideoPageTests"), browser)
        self.assertEqual({t for t, _ in browser}, {"CmuxNextBrowserTests"})
        self.assertGreater(len(heavy.heavy_suites(TESTS, "all")), len(browser))

    def test_a_serial_step_of_their_own_runs_them(self) -> None:
        own = self.step("Run main-thread-heavy suites in their own process")
        # One fresh process per suite: windows one suite leaves open slow every later one.
        self.assertIn(f"for suite in ${VAR}_SUITES", own["run"])
        self.assertIn('--filter "${suite//./\\\\.}\\\\b"', own["run"])
        self.assertIn('exit "$status"', own["run"])
        derive = self.step("Find the main-thread-heavy suites")
        self.assertIn(f"{VAR}_SUITES=", derive["run"])
        self.assertIn("swift-test-with-hang-sampler.sh", own["run"])
        self.assertIn("--no-parallel", own["run"])
        self.assertIn("timeout-minutes", own)
        self.assertIn("!cancelled()", own["if"])


if __name__ == "__main__":
    unittest.main()
