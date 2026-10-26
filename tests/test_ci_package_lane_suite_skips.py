#!/usr/bin/env python3
"""package-test-lane.sh suite: a suite none of whose tests ran reads "skipped", never "passed".

2026-10-26 false green: on aws-m4pro-6 (no display) the log said
`Suite SidebarMultiViewHomeTests skipped: "the drag tests need a display"` while the
summary table said `SidebarMultiViewHomeTests passed 10s`, and the lane printed
"All 4 suites passed.": Swift Testing's run summary counts skipped tests
("Test run with 2 tests in 1 suite passed"). CMUX_TEST_REQUIRE_GUI=1 changed
nothing. A fake `swift` prints each suite's recorded output; a fake `xcrun` names
an SDK.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, os.fspath(ROOT / "scripts/ci"))
import require_swift_test_execution as guard  # noqa: E402

FAKE_SWIFT = """#!/bin/bash
case "$1" in
  build) echo "Build complete! (0.1s)"; exit 0 ;;
  package) exit 0 ;;
  test)
    while [ "$#" -gt 0 ]; do [ "$1" = --filter ] && filter="$2"; shift; done
    cat "$FAKE_SWIFT_OUTPUTS/$filter.out"
    exit 0 ;;
esac
exit 0
"""

FAKE_XCRUN = """#!/bin/bash
echo "$FAKE_SDK"
"""

# Recorded from the aws-m4pro-6 job (cmux-ci step 1eabb2b7, 2026-10-26).
SKIPPED_SUITE = """\
Test Suite 'Selected tests' started at 2026-10-26 01:30:15.887.
Test Suite 'Selected tests' passed at 2026-10-26 01:30:15.888.
\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
◇ Test run started.
↳ Testing Library Version: 1902
➜ Suite SidebarMultiViewHomeTests skipped: "the drag tests need a display"
➜ Test aRowDroppedOnHomesBottomEdgeStacksItUnderHome(points:) skipped: "the drag tests need a display"
➜ Test aRowDroppedOnHomesRightEdgeShowsItsWorkspaceBesideHome() skipped: "the drag tests need a display"
✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.
"""

RAN_SUITE = """\
◇ Test run started.
◇ Suite SidebarMultiViewPressTests started.
✔ Test aPressChangesNoSelectionInAnyFrameUntilItsRelease() passed after 0.147 seconds.
✔ Test aReleaseOverAnotherRowNavigatesNowhere() passed after 0.014 seconds.
✔ Suite SidebarMultiViewPressTests passed after 0.253 seconds.
✔ Test run with 2 tests in 1 suite passed after 0.253 seconds.
"""

PARTLY_SKIPPED_SUITE = """\
◇ Test run started.
✔ Test aGalleryIndependentCheck() passed after 0.010 seconds.
➜ Test theGalleryWritesItsCrops() skipped
✔ Test run with 2 tests in 1 suite passed after 0.011 seconds.
"""


class SkipReportTest(unittest.TestCase):
    def test_a_run_of_skips_ran_nothing(self):
        ran, skipped, reasons = guard.skip_report(SKIPPED_SUITE)
        self.assertEqual((ran, skipped), (0, 2))
        self.assertEqual(reasons[0], 'suite SidebarMultiViewHomeTests: "the drag tests need a display"')
        self.assertIn('2 tests: "the drag tests need a display"', reasons)

    def test_a_run_that_ran_has_no_skips(self):
        self.assertEqual(guard.skip_report(RAN_SUITE), (2, 0, []))

    def test_a_passing_test_named_like_a_skip_is_not_one(self):
        ran, skipped, _ = guard.skip_report(
            "✔ Test aSkippedRowStays() passed after 0.1 seconds.\n"
            "✔ Test run with 1 test passed after 0.1 seconds.\n")
        self.assertEqual((ran, skipped), (1, 0))

    def test_the_skips_of_an_xctest_run_are_counted(self):
        ran, skipped, _ = guard.skip_report(
            "Test Suite 'All tests' passed at 2026-09-23 00:00:00.000.\n"
            "Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.0 (0.0) seconds\n")
        self.assertEqual((ran, skipped), (2, 1))


class SuiteSkipTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lane-suite-skips-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "cmux"
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copytree(ROOT / "scripts/ci", self.repo / "scripts/ci")
        pkg = self.repo / "Packages/macOS/Pkg"
        pkg.mkdir(parents=True)
        (pkg / "Package.swift").write_text("// swift-tools-version: 6.0\n")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, body in (("swift", FAKE_SWIFT), ("xcrun", FAKE_XCRUN)):
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.outputs = self.tmp / "outputs"
        self.outputs.mkdir()
        for name, output in (("SidebarMultiViewHomeTests", SKIPPED_SUITE), ("SidebarMultiViewPressTests", RAN_SUITE),
                             ("AAGalleryTests", PARTLY_SKIPPED_SUITE)):
            (self.outputs / f"{name}.out").write_text(output, encoding="utf-8")
        (self.tmp / "sdk").mkdir()
        self.env = {**{k: v for k, v in os.environ.items() if k not in ("CMUX_TEST_REQUIRE_GUI", "GITHUB_STEP_SUMMARY")},
                    "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_SWIFT_OUTPUTS": os.fspath(self.outputs),
                    "FAKE_SDK": os.fspath(self.tmp / "sdk"), "DEVELOPER_DIR": os.fspath(self.tmp),
                    "RUNNER_TEMP": os.fspath(self.tmp)}

    def suite(self, *filters, **env):
        return subprocess.run(["bash", "scripts/ci/package-test-lane.sh", "suite", "Packages/macOS/Pkg", ",".join(filters)],
                              cwd=self.repo, env={**self.env, **env}, capture_output=True, text=True, timeout=300)

    def row(self, out: str, suite: str) -> str:
        rows = [line for line in out.splitlines() if line.startswith(suite + " ")]
        self.assertEqual(len(rows), 1, out)
        return " ".join(rows[0].split()[1:-1])

    def test_a_skipped_suite_reads_skipped_and_is_not_counted_as_passed(self):
        done = self.suite("SidebarMultiViewHomeTests", "SidebarMultiViewPressTests", "AAGalleryTests")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.row(done.stdout, "SidebarMultiViewHomeTests"), "skipped")
        self.assertEqual(self.row(done.stdout, "SidebarMultiViewPressTests"), "passed")
        self.assertEqual(self.row(done.stdout, "AAGalleryTests"), "passed, 1 skipped")
        self.assertNotIn("All 3 suites passed", done.stdout)
        self.assertIn("2 of 3 suites passed; 1 skipped (none of their tests ran).", done.stdout)
        self.assertIn('SidebarMultiViewHomeTests: skipped suite SidebarMultiViewHomeTests: "the drag tests need a display"',
                      done.stdout)
        self.assertIn("::warning title=Swift suite skipped::SidebarMultiViewHomeTests", done.stdout)

    def test_every_suite_ran_reads_all_passed(self):
        done = self.suite("SidebarMultiViewPressTests")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("All 1 suites passed.", done.stdout)

    def test_a_skip_fails_when_the_job_asked_for_a_gui_session(self):
        for filters in (("SidebarMultiViewHomeTests", "SidebarMultiViewPressTests"), ("AAGalleryTests",)):
            with self.subTest(filters=filters):
                done = self.suite(*filters, CMUX_TEST_REQUIRE_GUI="1")
                self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertIn("with CMUX_TEST_REQUIRE_GUI=1", done.stdout)
                self.assertIn("1 of", done.stdout)
                self.assertNotIn("suites passed", done.stdout)
        done = self.suite("SidebarMultiViewPressTests", CMUX_TEST_REQUIRE_GUI="1")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
