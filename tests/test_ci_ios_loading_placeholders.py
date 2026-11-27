#!/usr/bin/env python3
"""scripts/ci/check-ios-loading-placeholders.py fails a change that adds a loading
placeholder to the iPhone app, and only for lines the change adds.

Builds a throwaway git repo, commits a base with an existing placeholder, then
checks each kind of added line against it.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/check-ios-loading-placeholders.py"
VIEW = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileWorkspaces/Thing.swift"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


class LoadingPlaceholderCheck(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        self.write(VIEW, 'struct Thing { var body: some View { Text("Loading chats…") } }\n')
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")
        self.base = git(self.repo, "rev-parse", "HEAD").strip()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, rel: str, text: str) -> None:
        p = self.repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def run_check(self, rel: str, added: str) -> subprocess.CompletedProcess[str]:
        p = self.repo / rel
        old = p.read_text() if p.exists() else ""
        self.write(rel, old + added)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "change")
        return subprocess.run(
            [sys.executable, str(SCRIPT), self.base], cwd=self.repo, capture_output=True, text=True
        )

    def test_existing_placeholder_on_base_passes(self) -> None:
        r = self.run_check(VIEW, "let x = 1\n")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_each_kind_fails(self) -> None:
        for line, rule in [
            ("ProgressView()\n", "spinner"),
            ('ProgressView("Working")\n', "spinner"),
            (".redacted(reason: .placeholder)\n", "redacted"),
            ("RowSkeleton()\n", "skeleton"),
            ('Text("Updating…")\n', "loading-text"),
            ('Text("Connecting to your Mac...")\n', "loading-text"),
            ('Text("Waiting for the Mac…")\n', "loading-text"),
            ('CmuxSpinner(label: Text("x"))\n', "spinner"),
            ('Text("Loading members")\n', "loading-text"),
            ("skeleton(caption)\n", "skeleton"),
        ]:
            with self.subTest(line=line):
                self.setUp()
                r = self.run_check(VIEW, line)
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn(rule, r.stdout)
                self.tearDown()

    def test_reasoned_allow_passes_and_bare_allow_fails(self) -> None:
        r = self.run_check(VIEW, "// placeholder-ok: first sign-in, nothing cached\nProgressView()\n")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.tearDown()
        self.setUp()
        r = self.run_check(VIEW, "// placeholder-ok\nProgressView()\n")
        self.assertEqual(r.returncode, 1, r.stdout)

    def test_out_of_scope_paths_pass(self) -> None:
        for rel in (
            "Packages/macOS/CmuxNext/Sources/X.swift",
            "cmux-next-ios/CmuxMobileKit/Tests/XTests.swift",
            "cmux-next-ios/notes.md",
        ):
            with self.subTest(rel=rel):
                r = self.run_check(rel, "ProgressView()\n")
                self.assertEqual(r.returncode, 0, r.stdout)

    def test_real_states_pass(self) -> None:
        for line in (
            'Text("Waiting for approval")\n',
            'WorkingLabel().cmuxMobileShimmer()\n',
            "struct SkeletonList: View {\n",
            'case .loading: "Loading"\n',
            "ProgressView(value: page.progress)\n",
            "private func skeleton(_ caption: String) -> some View {\n",
        ):
            with self.subTest(line=line):
                self.setUp()
                r = self.run_check(VIEW, line)
                self.assertEqual(r.returncode, 0, r.stdout)
                self.tearDown()

    def test_comment_lines_pass(self) -> None:
        r = self.run_check(VIEW, "// no ProgressView() here, we draw cached rows\n")
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_packages_ios_in_scope(self) -> None:
        r = self.run_check("Packages/iOS/CmuxMobileSupport/Sources/Y.swift", "ProgressView()\n")
        self.assertEqual(r.returncode, 1, r.stdout)


if __name__ == "__main__":
    unittest.main()
