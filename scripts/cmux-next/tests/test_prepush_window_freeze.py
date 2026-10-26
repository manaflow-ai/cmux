#!/usr/bin/env python3
"""prepush-gate.py window_freezes: a push that changes a path the coordinator's WINDOW freezes is refused unless
each commit that changes it carries `Freeze-Token: <the FREEZE line's token>` (token=none never matches).
2026-10-25 (Lawrence): "freeze for all" on cmux.xcodeproj/project.pbxproj; landq honored it, direct pushes did not.

  python3 scripts/cmux-next/tests/test_prepush_window_freeze.py
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("prepush_gate", HERE.parent / "prepush-gate.py")
assert SPEC and SPEC.loader
gate = importlib.util.module_from_spec(SPEC)
sys.modules["prepush_gate"] = gate
SPEC.loader.exec_module(gate)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
                          cwd=repo, check=True, capture_output=True, text=True).stdout.strip()


class WindowFreezeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "r"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        (self.repo / "cmux.xcodeproj").mkdir()
        (self.repo / "cmux.xcodeproj" / "project.pbxproj").write_text("base\n")
        (self.repo / "README").write_text("base\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        self.window = Path(self.tmp.name) / "WINDOW"

    def commit(self, path: str, message: str) -> str:
        (self.repo / path).write_text(message + "\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", message)
        return git(self.repo, "rev-parse", "HEAD")

    def test_a_frozen_path_needs_the_lines_token(self):
        self.window.write_text("FREEZE: cmux.xcodeproj/project.pbxproj token=none\n"
                               "# LIFTED 2026-10-11T04:34:50Z (chief): FREEZE: README token=abc\n")
        head = self.commit("cmux.xcodeproj/project.pbxproj", "change the project")
        found = gate.window_freezes(self.repo, self.base, head, self.window)
        self.assertEqual(len(found), 1)
        self.assertIn("cmux.xcodeproj/project.pbxproj", found[0])
        self.assertIn("Freeze-Token", found[0])
        self.assertEqual(gate.window_freezes(self.repo, self.base, self.commit("README", "a lifted path"), self.window)[1:], [])

    def test_the_granted_token_lets_the_commit_through(self):
        self.window.write_text("FREEZE: cmux.xcodeproj/project.pbxproj token=0e7a8e0e3b9c\n")
        head = self.commit("cmux.xcodeproj/project.pbxproj", "fix the project\n\nFreeze-Token: 0e7a8e0e3b9c")
        self.assertEqual(gate.window_freezes(self.repo, self.base, head, self.window), [])
        head = self.commit("cmux.xcodeproj/project.pbxproj", "again\n\nFreeze-Token: wrong")
        self.assertEqual(len(gate.window_freezes(self.repo, self.base, head, self.window)), 1)

    def test_no_window_file_checks_nothing(self):
        head = self.commit("cmux.xcodeproj/project.pbxproj", "change the project")
        self.assertEqual(gate.window_freezes(self.repo, self.base, head, Path(self.tmp.name) / "missing"), [])


if __name__ == "__main__":
    unittest.main()
