#!/usr/bin/env python3
"""scripts/ci/entry_logs.py: a frozen append-only log grows only as one file per entry in its directory.

The logs a rule makes many pull requests add to were among the most conflicted files on feat-cmux-next
(sidebar-owner.md: 47 GitHub conflicts among 96 PRs in 14 days; parity-mac.md: 29 among 107). Two PRs that
each add a new file never conflict.
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/entry_logs.py"
_spec = importlib.util.spec_from_file_location("entry_logs", SCRIPT)
entry_logs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(entry_logs)

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}
LOG = "cmux-next-ios/verify/parity-mac.md"


class TheTree(unittest.TestCase):
    def test_every_frozen_log_has_its_entry_directory_with_a_readme(self):
        for log, directory in entry_logs.ENTRY_LOGS.items():
            with self.subTest(log=log):
                self.assertTrue((ROOT / log).is_file(), log)
                self.assertTrue(directory.endswith("/"), directory)
                readme = ROOT / directory / "README.md"
                self.assertTrue(readme.is_file(), readme)
                self.assertIn(directory, (ROOT / log).read_text(encoding="utf-8").splitlines()[0],
                              "the frozen log's first line points at its entry directory")

    def test_the_sidebar_gate_reads_the_same_directory(self):
        gate = (ROOT / "scripts/cmux-next/prepush-gate.py").read_text(encoding="utf-8")
        self.assertIn('SIDEBAR_ENTRIES = "plans/cmux-next/sidebar-owner/"', gate)
        self.assertEqual(entry_logs.ENTRY_LOGS["plans/cmux-next/sidebar-owner.md"], "plans/cmux-next/sidebar-owner/")

    def test_the_fast_gates_run_it(self):
        gates = (ROOT / "scripts/ci/cmux_next_fast_gates.py").read_text(encoding="utf-8")
        self.assertIn('"scripts/ci/entry_logs.py", "check", "--base", base, "--head", merge', gates)


class Check(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.write(LOG, "# log\n\n| a | works |\n| b | missing |\n")
        self.base = self.commit("base")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], env=ENV, text=True, capture_output=True,
                              check=True).stdout.strip()

    def write(self, path: str, text: str) -> None:
        (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
        (self.repo / path).write_text(text, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def run_check(self) -> subprocess.CompletedProcess:
        return subprocess.run(["python3", "-I", str(SCRIPT), "check", "--repo", str(self.repo), "--base", self.base,
                               "--head", "HEAD"], env=ENV, text=True, capture_output=True)

    def test_a_new_row_in_the_frozen_log_fails_and_names_the_directory(self):
        self.write(LOG, "# log\n\n| new | works |\n| a | works |\n| b | missing |\n")
        self.commit("add a row")

        result = self.run_check()

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("::error title=Entry logs::", result.stdout)
        self.assertIn("cmux-next-ios/verify/parity-mac/", result.stdout)

    def test_changing_an_old_row_in_place_passes(self):
        self.write(LOG, "# log\n\n| a | works |\n| b | works (round 4) |\n")
        self.commit("b works now")

        self.assertEqual(self.run_check().returncode, 0)

    def test_a_new_entry_file_passes(self):
        self.write("cmux-next-ios/verify/parity-mac/2026-11-25-new.md", "# new\n\n- State: works\n")
        self.commit("add an entry")

        self.assertEqual(self.run_check().returncode, 0)

    def test_two_entry_files_from_two_branches_merge_without_a_conflict(self):
        self.git("checkout", "-q", "-b", "one")
        self.write("cmux-next-ios/verify/parity-mac/2026-11-25-one.md", "# one\n")
        self.commit("one")
        self.git("checkout", "-q", "main")
        self.git("checkout", "-q", "-b", "two")
        self.write("cmux-next-ios/verify/parity-mac/2026-11-25-two.md", "# two\n")
        self.commit("two")

        merged = subprocess.run(["git", "-C", str(self.repo), "merge-tree", "--write-tree", "one", "two"], env=ENV,
                                text=True, capture_output=True)

        self.assertEqual(merged.returncode, 0, merged.stdout)


if __name__ == "__main__":
    unittest.main()
