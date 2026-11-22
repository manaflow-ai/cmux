#!/usr/bin/env python3
"""The shadow train's judge builds the combined tip without pushing, leaves a conflicting PR out, and reads a
red step table as a verdict (scripts/ci/train_shadow_judge.py)."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import train_shadow_judge as judge  # noqa: E402

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}
RUNNER = """#!/bin/sh
test ! -e red.txt || { echo '::error title=Red::step red-step failed; see its log group'; exit 1; }
"""


def git(root: str, *args: str) -> str:
    done = subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, text=True, env=ENV)
    return done.stdout.strip()


class JudgeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.origin = os.path.join(self.tmp.name, "origin")
        self.work = os.path.join(self.tmp.name, "work")
        os.makedirs(os.path.join(self.origin, "ci"))
        git(self.origin, "init", "--quiet", "-b", "base")
        self.write("ci/run", RUNNER)
        os.chmod(os.path.join(self.origin, "ci/run"), 0o755)
        self.base = self.commit("a.txt", "one\n", "base")
        self.heads = {1: self.pull(1, "b.txt", "two\n"), 2: self.pull(2, "a.txt", "theirs\n"),
                      3: self.pull(3, "a.txt", "ours\n"), 4: self.pull(4, "red.txt", "x\n")}
        git(self.origin, "checkout", "--quiet", "base")
        subprocess.run(["git", "clone", "--quiet", self.origin, self.work], check=True, env=ENV)

    def write(self, name: str, text: str) -> None:
        with open(os.path.join(self.origin, name), "w") as f:
            f.write(text)

    def commit(self, name: str, text: str, message: str) -> str:
        self.write(name, text)
        git(self.origin, "add", "-A")
        git(self.origin, "commit", "--quiet", "-m", message)
        return git(self.origin, "rev-parse", "HEAD")

    def pull(self, number: int, name: str, text: str) -> str:
        git(self.origin, "checkout", "--quiet", "--detach", self.base)
        head = self.commit(name, text, f"pr {number}")
        git(self.origin, "update-ref", f"refs/pull/{number}/head", head)
        return head

    def run_judge(self, *args: str) -> dict:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = judge.main(["--root", self.work, "--base", self.base, *args])
        line = [text for text in out.getvalue().splitlines() if text.startswith(judge.LINE)][-1]
        return {"exit": code, **json.loads(line[len(judge.LINE):])}

    def test_green_batch_keeps_the_clean_members_and_leaves_the_conflict_out(self) -> None:
        branches = git(self.origin, "for-each-ref", "refs/heads")
        got = self.run_judge("--pr", "1", "--pr", "2", "--pr", "3")
        self.assertEqual((got["exit"], got["verdict"]), (0, "green"))
        self.assertEqual([m["number"] for m in got["kept"]], [1, 2])
        self.assertEqual([c["number"] for c in got["conflicts"]], [3])
        self.assertEqual(git(self.work, "rev-list", "--count", f"{self.base}..{got['tip']}"), "2")
        self.assertEqual(git(self.work, "rev-list", "--merges", "--count", got["tip"]), "0")  # one parent each
        self.assertEqual(git(self.origin, "for-each-ref", "refs/heads"), branches)  # nothing pushed
        self.assertEqual(len(git(self.work, "worktree", "list").splitlines()), 1)  # the throwaway tree is gone

    def test_red_batch_is_a_verdict_and_names_the_step(self) -> None:
        got = self.run_judge("--pr", "1", "--pr", "4")
        self.assertEqual((got["exit"], got["verdict"], got.get("failed_step")), (0, "red", "red-step"))

    def test_moved_head_and_dry_run(self) -> None:
        got = self.run_judge("--pr", f"1@{self.heads[2]}", "--pr", "2", "--dry-run")
        self.assertEqual((got["verdict"], [m["number"] for m in got["kept"]]), ("none", [2]))
        self.assertIn("moved", got["conflicts"][0]["why"])


if __name__ == "__main__":
    unittest.main()
