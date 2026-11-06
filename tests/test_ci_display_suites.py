#!/usr/bin/env python3
"""scripts/ci/display-suites.txt declares the suites whose own display skip traits (or a test's) ask for a display,
and scripts/ci/display_suites.py finds a suite by its own trait or a test's.

cmux-ci reads the committed list at a step's ref to send a package-test-lane suite step that names a display
suite to a display worker (the gui-session-v1 label), so a suite with a display trait missing from the list, or
a listed suite that lost its trait, fails here.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("display_suites", ROOT / "scripts/ci/display_suites.py")
display_suites = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(display_suites)


class ListInSyncTest(unittest.TestCase):
    def test_the_committed_list_is_the_traits(self):
        done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/display_suites.py"), "--check"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_the_list_names_the_known_display_suites(self):
        rows = display_suites.display_suites(ROOT)
        for row in ("Packages/macOS/CmuxNext CmuxNextAppTests.SidebarMultiViewHomeTests",
                    "Packages/macOS/CmuxNext CmuxNextAppTests.SidebarRowsMoveOnRenderServerTests"):
            self.assertIn(row, rows)
        self.assertFalse([row for row in rows if "FirstLaunchTests" in row], "a cmux-tui trait is no display trait")


class DerivationTest(unittest.TestCase):
    def test_a_suite_trait_names_its_declaration(self):
        source = ('@MainActor @Suite(.serialized, .enabled(if: !NSScreen.screens.isEmpty, "the drag tests need a display"))\n'
                  "struct DragTests {\n    @Test func a() {}\n}\n")
        self.assertEqual(display_suites.suites_in(source), {"DragTests"})

    def test_a_test_trait_names_the_type_around_it(self):
        source = ("@MainActor @Suite struct Outer {\n"
                  "    @Test func plain() {}\n"
                  "}\n"
                  "struct Animated {\n"
                  '    @Test(.enabled("needs an awake display and animations on, or every insert snaps anyway") {\n'
                  "        await Self.animatesHere()\n"
                  "    })\n"
                  "    func insert() async {}\n"
                  "    struct Helper { let x = 1 }\n"
                  "}\n")
        self.assertEqual(display_suites.suites_in(source), {"Animated"})

    def test_a_trait_split_across_lines_counts(self):
        source = ("@MainActor\n@Suite(\n    .serialized,\n    .enabled(\n        if: !NSScreen.screens.isEmpty,\n"
                  '        "the drag tests need a display"\n    )\n)\nstruct SplitSuite {}\n'
                  "struct SplitTest {\n"
                  "    @Test(\n        .enabled(\n"
                  '            "needs an awake display and animations on, "\n'
                  '            + "or every insert snaps anyway"\n'
                  "        ) { await Self.animatesHere() }\n    )\n"
                  "    func insert() async {}\n"
                  "    class func helper() {}\n"
                  "}\n")
        self.assertEqual(display_suites.suites_in(source), {"SplitSuite", "SplitTest"})

    def test_braces_and_words_in_strings_and_comments_count_for_nothing(self):
        source = ("struct Outer {\n"
                  '    let art = """\n    } struct Fake { .enabled(if: x, "needs a display")\n    """\n'
                  "    /* } nested /* { */ .disabled(\"no screen\") */\n"
                  '    @Test(.enabled(if: hasScreen, "needs a display")) func a() {}\n'
                  "}\n"
                  "struct After {\n    @Test func b() {}\n}\n")
        self.assertEqual(display_suites.suites_in(source), {"Outer"})

    def test_a_condition_that_reads_the_screen_counts_with_no_comment(self):
        """P0 display run 20b78078: TitlebarDoubleClickTests' `.enabled(if: NSScreen.main != nil)` gave no reason, so
        it was not listed and its --display step went to a worker with no screen. NSScreen in a comment or a string
        is no condition."""
        source = ("@MainActor struct TitlebarDoubleClickTests {\n"
                  "    @Test(.enabled(if: NSScreen.main != nil)) func zooms() throws {}\n"
                  "}\n"
                  "struct Words {\n"
                  '    @Test(.enabled(if: flag, "reads NSScreen later")) func a() {}\n'
                  "    // @Test(.enabled(if: NSScreen.main != nil))\n"
                  "    @Test func b() { _ = NSScreen.main }\n"
                  "}\n")
        self.assertEqual(display_suites.suites_in(source), {"TitlebarDoubleClickTests"})

    def test_other_skips_and_comments_are_no_display(self):
        source = ('@Suite(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))\n'
                  "struct Daemon {\n"
                  '    // @Test(.enabled(if: x, "needs a display"))\n'
                  '    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))\n'
                  "    func gallery() {}\n"
                  '    @Test(.disabled("no /usr/bin/sqlite3")) func db() {}\n'
                  "}\n")
        self.assertEqual(display_suites.suites_in(source), set())

    def test_check_reports_both_directions(self):
        tmp = Path(tempfile.mkdtemp(prefix="display-suites-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        tests = tmp / "Packages/macOS/Pkg/Tests/PkgTests"
        tests.mkdir(parents=True)
        (tmp / "Packages/macOS/Pkg/Package.swift").write_text("// swift-tools-version: 6.0\n")
        (tests / "A.swift").write_text('@Suite(.enabled(if: hasScreen, "zooming needs a screen: run on a GUI host"))\n'
                                       "struct ZoomTests {\n}\n")
        (tmp / "scripts/ci").mkdir(parents=True)
        (tmp / display_suites.LIST).write_text(display_suites.HEADER + "Packages/macOS/Pkg PkgTests.GoneTests\n")
        done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/display_suites.py"), "--root", str(tmp),
                               "--check"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 1)
        self.assertIn("missing Packages/macOS/Pkg PkgTests.ZoomTests", done.stderr)
        self.assertIn("lists Packages/macOS/Pkg PkgTests.GoneTests, which has no display skip trait", done.stderr)
        subprocess.run([sys.executable, str(ROOT / "scripts/ci/display_suites.py"), "--root", str(tmp), "--fix"],
                       check=True)
        self.assertEqual(subprocess.run([sys.executable, str(ROOT / "scripts/ci/display_suites.py"), "--root",
                                         str(tmp), "--check"]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
