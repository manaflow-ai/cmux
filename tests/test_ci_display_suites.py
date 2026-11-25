#!/usr/bin/env python3
"""scripts/ci/display_suites.py derives the suites whose own display skip traits (or a test's) ask for a display,
finding a suite by its own trait or a test's. The list is derived wherever it is read and never committed.
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


class DerivedNeverCommittedTest(unittest.TestCase):
    """The list is derived from the suites' traits wherever it is read, never committed. A committed copy went
    stale on every pull request that added a display test (generated_files_guard.py refuses a new committed
    generated file, so the PR autofix could not write it) and stayed stale until the post-merge base autofix."""

    def test_no_committed_list(self):
        self.assertFalse((ROOT / "scripts/ci/display-suites.txt").exists(),
                         "scripts/ci/display-suites.txt is committed: derive it with scripts/ci/display_suites.py")
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--", "scripts/ci/display-suites*"],
                                 capture_output=True, text=True)
        if tracked.returncode == 0:
            self.assertEqual(tracked.stdout.strip(), "", "a display suite list is tracked: derive it instead")

    def test_no_mode_writes_or_checks_a_copy(self):
        """--fix and --check stay only as no-ops for base's trusted autofix copy (TrustedBaseAutofixStepTest): they
        exit 0 and write, print and check nothing, even where the derived list would have rows."""
        tmp = Path(tempfile.mkdtemp(prefix="display-suites-modes-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        tests = tmp / "Packages/macOS/Pkg/Tests/PkgTests"
        tests.mkdir(parents=True)
        (tmp / "Packages/macOS/Pkg/Package.swift").write_text("// swift-tools-version: 6.0\n")
        (tests / "A.swift").write_text('@Suite(.enabled(if: hasScreen, "needs a display")) struct ZoomTests {}\n')
        (tmp / "scripts/ci").mkdir(parents=True)
        stale = tmp / "scripts/ci/display-suites.txt"
        stale.write_text("a stale copy\n")
        before = sorted(p.relative_to(tmp).as_posix() for p in tmp.rglob("*"))
        for mode in ("--fix", "--check"):
            done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/display_suites.py"), "--root", str(tmp), mode],
                                  capture_output=True, text=True)
            self.assertEqual((done.returncode, done.stdout), (0, ""), f"display_suites.py {mode} is no no-op: {done}")
            self.assertEqual(stale.read_text(), "a stale copy\n", f"display_suites.py {mode} rewrote a copy")
            self.assertEqual(sorted(p.relative_to(tmp).as_posix() for p in tmp.rglob("*")), before,
                             f"display_suites.py {mode} wrote a file")

    def test_the_derived_list_prints_the_rows(self):
        done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/display_suites.py")],
                              capture_output=True, text=True, check=True)
        rows = [line for line in done.stdout.splitlines() if line and not line.startswith("#")]
        self.assertEqual(rows, display_suites.display_suites(ROOT))
        self.assertTrue(all(len(row.split()) == 2 and "." in row.split()[1] for row in rows), rows)

    def test_the_list_names_the_known_display_suites(self):
        rows = display_suites.display_suites(ROOT)
        for row in ("Packages/macOS/CmuxNext CmuxNextAppTests.SidebarMultiViewHomeTests",
                    "Packages/macOS/CmuxNext CmuxNextAppTests.SidebarRowsMoveOnRenderServerTests"):
            self.assertIn(row, rows)
        self.assertFalse([row for row in rows if "FirstLaunchTests" in row], "a cmux-tui trait is no display trait")


# feat-cmux-next's base-autofix.sh step 1e4 at 785cd859043c (lines 312-324), byte for byte. The pull request autofix
# runs a trusted copy of base's scripts (`git archive "$BASE_SHA" scripts/cmux-next scripts/ci`) against the pull
# request's tree, so until this change is on base, every pull request's autofix runs this step against a tree whose
# display_suites.py has no committed copy to keep (run 43196743424: `unrecognized arguments: --fix`, exit 2). Remove
# this copy, and display_suites.py's transitional --fix and --check, once no base the autofix can archive has step 1e4.
BASE_STEP_1E4 = r'''display_list=scripts/ci/display-suites.txt
if [[ -f "$repo/scripts/ci/display_suites.py" ]]; then
  before="$(cksum < "$repo/$display_list" 2>/dev/null || true)"
  python3 -I "$repo/scripts/ci/display_suites.py" --root "$repo" --fix
  if [[ "$before" != "$(cksum < "$repo/$display_list")" ]]; then
    if frozen "$display_list"; then
      git -C "$repo" checkout --quiet -- "$display_list" 2>/dev/null || rm -f "$repo/$display_list"
      echo "skipped (frozen): $display_list (stale; python3 scripts/ci/display_suites.py --fix)"
    else
      echo "fixed: regenerated $display_list"
    fi
  fi
fi
'''


class TrustedBaseAutofixStepTest(unittest.TestCase):
    """The pull request autofix runs base's base-autofix.sh against this tree: its step 1e4 must pass and write
    no list."""

    def test_base_step_1e4_passes_and_writes_no_list(self):
        tmp = Path(tempfile.mkdtemp(prefix="display-suites-base-step-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "scripts/ci").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/ci/display_suites.py", tmp / "scripts/ci/display_suites.py")
        tests = tmp / "Packages/macOS/Pkg/Tests/PkgTests"
        tests.mkdir(parents=True)
        (tmp / "Packages/macOS/Pkg/Package.swift").write_text("// swift-tools-version: 6.0\n")
        (tests / "A.swift").write_text('@Suite(.enabled(if: hasScreen, "needs a display")) struct ZoomTests {}\n')
        script = 'set -euo pipefail\nrepo="$1"\nfrozen() { return 1; }\n' + BASE_STEP_1E4
        done = subprocess.run(["bash", "-c", script, "base-autofix.sh", str(tmp)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, f"base's step 1e4 fails on this tree: {done.stderr}")
        self.assertEqual(done.stdout, "", "base's step 1e4 reported a repair: there is no list to regenerate")
        self.assertFalse((tmp / "scripts/ci/display-suites.txt").exists(), "base's step 1e4 wrote a list")


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

    def test_root_derives_another_tree(self):
        tmp = Path(tempfile.mkdtemp(prefix="display-suites-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        tests = tmp / "Packages/macOS/Pkg/Tests/PkgTests"
        tests.mkdir(parents=True)
        (tmp / "Packages/macOS/Pkg/Package.swift").write_text("// swift-tools-version: 6.0\n")
        (tests / "A.swift").write_text('@Suite(.enabled(if: hasScreen, "zooming needs a screen: run on a GUI host"))\n'
                                       "struct ZoomTests {\n}\n")
        # Tests of a folder with no Package.swift are no package's: not listed.
        stray = tmp / "Packages/macOS/Loose/Tests/LooseTests"
        stray.mkdir(parents=True)
        (stray / "B.swift").write_text('@Suite(.enabled(if: hasScreen, "needs a display")) struct LooseTests {}\n')
        done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/display_suites.py"), "--root", str(tmp)],
                              capture_output=True, text=True, check=True)
        self.assertEqual(done.stdout, display_suites.HEADER + "Packages/macOS/Pkg PkgTests.ZoomTests\n")
        self.assertEqual(sorted(p.relative_to(tmp).as_posix() for p in tmp.rglob("*") if p.is_file()),
                         ["Packages/macOS/Loose/Tests/LooseTests/B.swift", "Packages/macOS/Pkg/Package.swift",
                          "Packages/macOS/Pkg/Tests/PkgTests/A.swift"], "deriving the list writes no file")

if __name__ == "__main__":
    unittest.main()
