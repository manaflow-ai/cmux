#!/usr/bin/env python3
"""prepush-gate.py sidebar_owner_by_commit: a commit that adds a kind of sidebar row (a case of `SidebarRowKey`, or of
a fold's `SidebarDoneFoldID.Kind`) needs a `Sidebar-Look:` quote that names that row. #49506 added an
"Automatic (N)" fold row under a Leo quote that named no row (Leo 2026-11-27: "WE NEED TO NOT HAVE THOSE THINGS
MERGE"; #55721 removed it).

  python3 scripts/cmux-next/tests/test_prepush_sidebar_row_kind.py
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# tests/git_fixture_env.py turns off git's background maintenance in temp repos.
_git_fixture_env = importlib.util.spec_from_file_location(
    "git_fixture_env",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "git_fixture_env.py"),
)
git_fixture_env = importlib.util.module_from_spec(_git_fixture_env)
_git_fixture_env.loader.exec_module(git_fixture_env)

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("prepush_gate", HERE.parent / "prepush-gate.py")
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
sys.modules["prepush_gate"] = gate
SPEC.loader.exec_module(gate)

FOLD = gate.SIDEBAR_CODE + "Logic/SidebarLayout+DoneFold.swift"
ROW = gate.SIDEBAR_CODE + "Logic/SidebarRow.swift"
FOLD_BASE = """public nonisolated struct SidebarDoneFoldID: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// "Done (N)".
        case done
        case settled
    }
    public var kind: Kind
}
"""
ROW_BASE = """public nonisolated enum SidebarRowKey: Hashable, Sendable {
    case section(SectionID)
    case doneFold(SidebarDoneFoldID)
}
"""
# #49506's own trailer, word for word.
LEO_49506 = ('Sidebar-Look: Leo: "ALSO NEED YALL TO HELP ORGANIZE THIS MF SIDEBAR ... A LOT OF THESE SESSIONS ID '
             'IMAGINE DIDNT NECESSSARILY NEED TO SHOW UP ON THE SIDE BY DEFAULT"')


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
                          cwd=repo, check=True, capture_output=True, text=True).stdout.strip()


class SidebarRowKindTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "r"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        self.write(FOLD, FOLD_BASE)
        self.write(ROW, ROW_BASE)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")

    def write(self, path: str, text: str) -> None:
        (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / path).write_text(text)

    def commit(self, path: str, text: str, message: str) -> str:
        self.write(path, text)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", message)
        return git(self.repo, "rev-parse", "HEAD")

    def kinds_found(self, head: str) -> list[str]:
        return [f for _, f in gate.sidebar_owner_by_commit(self.repo, self.base, head) if "new kind of sidebar row" in f]

    def test_49506_automatic_fold_under_a_quote_naming_no_row_fails(self):
        head = self.commit(FOLD, FOLD_BASE.replace("case settled", "case settled\n        case automatic"),
                           "Sidebar: fold automatic sessions behind an Automatic (N) row\n\n" + LEO_49506)
        found = self.kinds_found(head)
        self.assertEqual(len(found), 1, found)
        self.assertIn("`automatic`", found[0])

    def test_the_commits_own_words_after_the_quote_do_not_count(self):
        head = self.commit(FOLD, FOLD_BASE.replace("case settled", "case settled\n        case automatic"),
                           "fold\n\n" + LEO_49506 + ' They fold into "Automatic (N)".')
        self.assertEqual(len(self.kinds_found(head)), 1)

    def test_a_quote_that_names_the_row_passes(self):
        head = self.commit(FOLD, FOLD_BASE.replace("case settled", "case settled\n        case archived"),
                           'fold archived\n\nSidebar-Look: "better ui for archived stuff instead of just greying them '
                           'out" (Lawrence 18470)')
        self.assertEqual(self.kinds_found(head), [])

    def test_a_row_key_case_with_a_payload_is_a_new_row(self):
        head = self.commit(ROW, ROW_BASE.replace("case section(SectionID)", "case section(SectionID)\n    case tab(TabID)"),
                           "tab rows\n\nSidebar-Look: no visual change")
        found = self.kinds_found(head)
        self.assertEqual(len(found), 1, found)
        self.assertIn("`tab`", found[0])

    def test_editing_or_removing_cases_and_comments_adds_no_row(self):
        head = self.commit(FOLD, FOLD_BASE.replace("        case settled\n", "").replace('"Done (N)".', "the Done row."),
                           "drop settled\n\nSidebar-Look: no visual change")
        self.assertEqual(self.kinds_found(head), [])

    def test_a_commit_that_makes_the_enum_adds_no_row(self):
        flat = "public nonisolated struct SidebarDoneFoldID: Hashable, Sendable {\n    public var section: Int\n}\n"
        self.commit(FOLD, flat, "flat\n\nSidebar-Look: no visual change")
        self.base = git(self.repo, "rev-parse", "HEAD")
        head = self.commit(FOLD, FOLD_BASE, "kinds\n\nSidebar-Look: no visual change")
        self.assertEqual(self.kinds_found(head), [])

    def test_an_owner_logged_sha_passes(self):
        head = self.commit(FOLD, FOLD_BASE.replace("case settled", "case settled\n        case automatic"),
                           "fold\n\n" + LEO_49506)
        self.write(gate.SIDEBAR_NOTE, f"- {head[:11]} reviewed\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "log it\n\nSidebar-Look: no visual change")
        self.assertEqual(self.kinds_found(git(self.repo, "rev-parse", "HEAD")), [])


if __name__ == "__main__":
    unittest.main()
