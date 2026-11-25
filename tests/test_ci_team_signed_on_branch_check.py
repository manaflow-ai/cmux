#!/usr/bin/env python3
"""cmux-tui-team-signed.yml's "Check the commit" step, run as written: it answers by git transport, never a REST call.

The step used `gh api repos/.../compare/COMMIT...feat-cmux-next`, which shared the repository's installation budget
with every workflow and was refused in nearly every run of 2026-11-24 and 11-25 ("API rate limit exceeded for
installation"), so few trees were Team-signed and hot-apply.py could not put merged daemon fixes into a NIGHTLY.

The static half always runs. The live half (CMUX_TEAM_SIGNED_LIVE=1, network) fetches manaflow-ai/cmux, a public
repository: a commit on feat-cmux-next passes, one that never merged is refused.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-team-signed.yml"
ON_BRANCH = "a8645c9d0dedc12540b8e426c86977a7b03a8c78"  # webviews: serve dev JSON imports ... (#54081)
NEVER_MERGED = "0b085c0714f432f926fa12a9389405283f9630d1"  # a pull request's head (cmux#55401), not on feat-cmux-next


def step() -> dict:
    doc = yaml.safe_load(WORKFLOW.read_text())
    return next(s for s in doc["jobs"]["plan"]["steps"] if s.get("name") == "Check the commit")


class CheckTheCommitStep(unittest.TestCase):
    def test_it_spends_no_rest_call(self):
        run = step()["run"]
        self.assertNotIn("gh api", run)
        self.assertIn("merge-base --is-ancestor", run)

    @unittest.skipUnless(os.environ.get("CMUX_TEAM_SIGNED_LIVE") == "1", "network: CMUX_TEAM_SIGNED_LIVE=1")
    def test_live_on_branch_passes_and_never_merged_is_refused(self):
        run = step()["run"]
        for commit, want in ((ON_BRANCH, 0), (NEVER_MERGED, 1)):
            with tempfile.TemporaryDirectory() as tmp, self.subTest(commit=commit):
                env = dict(os.environ, COMMIT=commit, REPO="manaflow-ai/cmux", RUNNER_TEMP=tmp,
                           GH_TOKEN="", GIT_TERMINAL_PROMPT="0")
                done = subprocess.run(["bash", "-c", run], env=env, capture_output=True, text=True, timeout=600)
                self.assertEqual(done.returncode, want, done.stdout + done.stderr)
                if want == 0:
                    self.assertIn("is on feat-cmux-next", done.stdout)


if __name__ == "__main__":
    unittest.main()
