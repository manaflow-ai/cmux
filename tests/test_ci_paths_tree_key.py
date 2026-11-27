#!/usr/bin/env python3
"""scripts/ci/paths_tree_key.py: the input-tree key of a job whose inputs are its workflow's pull_request.paths."""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import paths_tree_key as K  # noqa: E402

WORKFLOW = """name: w

on:
  pull_request:
    types: [opened, synchronize]
    paths:
      - backend/**
      # a comment between entries
      - "libs/a/**"
      - 'web/x.ts'
      - .github/workflows/w.yml
  push:
    branches: [main]
    paths:
      - other/**

jobs:
  t:
    runs-on: ubuntu-24.04
    steps:
      - run: true
"""


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True).stdout.strip()


class ParseTest(unittest.TestCase):
    def test_reads_only_the_pull_request_paths(self):
        self.assertEqual(K.pull_request_paths(WORKFLOW),
                         ["backend/**", "libs/a/**", "web/x.ts", ".github/workflows/w.yml"])

    def test_no_paths_is_no_list(self):
        self.assertIsNone(K.pull_request_paths("on:\n  pull_request:\n    types: [opened]\njobs: {}\n"))
        self.assertIsNone(K.pull_request_paths("on:\n  push:\n    paths:\n      - a/**\n"))

    def test_pathspec(self):
        self.assertEqual(K.pathspec("backend/**"), "backend")
        self.assertEqual(K.pathspec("web/x.ts"), "web/x.ts")
        for pattern in ("!backend/**", "**/*.md", "backend/*.ts", "a/b?"):
            self.assertIsNone(K.pathspec(pattern), pattern)

    def test_backend_workflow_has_a_key(self):
        # The workflow this was written for: every pattern maps to a path, so its shards get a key.
        text = (ROOT / ".github/workflows/backend.yml").read_text(encoding="utf-8")
        patterns = K.pull_request_paths(text)
        self.assertTrue(patterns and "backend/**" in patterns)
        self.assertTrue(all(K.pathspec(p) for p in patterns), patterns)


class KeyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        self.write(".github/workflows/w.yml", WORKFLOW)
        self.write("backend/a.ts", "a")
        self.write("libs/a/b.ts", "b")
        self.write("docs/readme.md", "d")
        self.first = self.commit()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel: str, text: str):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self) -> str:
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "c")
        return git(self.repo, "rev-parse", "HEAD")

    def key(self, commit: str, job: str = "t-1") -> str | None:
        return K.key(".github/workflows/w.yml", job, commit, cwd=str(self.repo))

    def test_a_change_outside_the_paths_keeps_the_key(self):
        self.write("docs/readme.md", "changed")
        self.assertEqual(self.key(self.first), self.key(self.commit()))

    def test_a_change_to_any_input_is_a_new_key(self):
        before = self.key(self.first)
        for rel in ("backend/a.ts", "libs/a/b.ts", "web/x.ts"):  # web/x.ts: absent, then present
            self.write(rel, "new " + rel)
            after = self.key(self.commit())
            self.assertNotEqual(before, after, rel)
            before = after

    def test_the_workflow_file_is_an_input(self):
        before = self.key(self.first)
        self.write(".github/workflows/w.yml", WORKFLOW.replace("runs-on: ubuntu-24.04", "runs-on: ubuntu-22.04"))
        self.assertNotEqual(before, self.key(self.commit()))

    def test_each_job_has_its_own_key(self):
        self.assertNotEqual(self.key(self.first, "t-1"), self.key(self.first, "t-2"))

    def test_an_unmapped_pattern_gives_no_key(self):
        self.write(".github/workflows/w.yml", WORKFLOW.replace("- 'web/x.ts'", "- 'web/*.ts'"))
        self.assertIsNone(self.key(self.commit()))

    def test_an_unknown_commit_gives_no_key(self):
        self.assertIsNone(self.key("0" * 40))


if __name__ == "__main__":
    unittest.main()
