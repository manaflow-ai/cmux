#!/usr/bin/env python3
"""The nightly-next train's drive job never runs code from inputs.tip.

The drive job (nightly-next-train.yml) mints the release App token, which can
push contents and workflows. It must check out the dispatched feat-cmux-next
head, and before the token exists it must refuse a tip that is not an
ancestor of that head; otherwise anyone who can dispatch the workflow could
run an unreviewed commit's code with the token. This test reads the job and
runs its real tip check against a scratch repository.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly-next-train.yml"
CHECK_STEP = "Check the tip is on feat-cmux-next"
MINT_STEP = "Mint release App token"


def drive_steps() -> list[dict]:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return document["jobs"]["drive"]["steps"]


def step_index(steps: list[dict], name: str) -> int:
    names = [step.get("name") for step in steps]
    if name not in names:
        raise AssertionError(f"drive job has no step {name!r}")
    return names.index(name)


def git(repo: str, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True,
                          text=True, env=env).stdout.strip()


class DrivePinTests(unittest.TestCase):
    def test_checkout_is_the_dispatched_head(self):
        steps = drive_steps()
        checkouts = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 1)
        self.assertEqual(checkouts[0]["with"]["ref"], "${{ github.sha }}")

    def test_tip_reaches_scripts_only_through_env(self):
        for step in drive_steps():
            self.assertNotIn("inputs.tip", str(step.get("run", "")), step.get("name"))
            self.assertNotIn("inputs.tip", str(step.get("with", "")), step.get("name"))

    def test_tip_check_runs_before_the_token_and_always(self):
        steps = drive_steps()
        check = step_index(steps, CHECK_STEP)
        self.assertLess(check, step_index(steps, MINT_STEP))
        self.assertNotIn("if", steps[check])
        self.assertNotIn("continue-on-error", steps[check])

    def test_tip_check_refuses_commits_off_the_head(self):
        script = drive_steps()[step_index(drive_steps(), CHECK_STEP)]["run"]
        with tempfile.TemporaryDirectory() as repo:
            git(repo, "init", "-q", "-b", "feat-cmux-next")
            git(repo, "commit", "-q", "--allow-empty", "-m", "base")
            base = git(repo, "rev-parse", "HEAD")
            git(repo, "commit", "-q", "--allow-empty", "-m", "head")
            head = git(repo, "rev-parse", "HEAD")
            git(repo, "checkout", "-q", "-b", "side", base)
            git(repo, "commit", "-q", "--allow-empty", "-m", "unreviewed")
            side = git(repo, "rev-parse", "HEAD")
            git(repo, "checkout", "-q", "feat-cmux-next")

            def run(tip: str) -> int:
                env = {**os.environ, "TIP": tip, "GITHUB_SHA": head}
                return subprocess.run(["bash", "-c", script], cwd=repo, env=env,
                                      capture_output=True).returncode

            self.assertEqual(run(""), 0)
            self.assertEqual(run(head), 0)
            self.assertEqual(run(base), 0)
            self.assertNotEqual(run(side), 0)
            self.assertNotEqual(run(head[:12]), 0)
            self.assertNotEqual(run("main"), 0)
            self.assertNotEqual(run(head + "\n::warning::x"), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
