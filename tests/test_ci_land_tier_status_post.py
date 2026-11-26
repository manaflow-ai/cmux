#!/usr/bin/env python3
"""The pr router's cmux/land-tier post survives a spent GITHUB_TOKEN budget.

The router posts `cmux/land-tier` (pending on the cheap tier, success once the full tier runs). It used to post on the
job's GITHUB_TOKEN alone, under continue-on-error: when the repository's token budget was spent ("API rate limit
exceeded for installation", run 45657671903, 2026-11-25 16:47Z), the run read green, the status stayed the cheap
tier's `pending` at a head the full tier had run on, and land-judge waited on it as a running check: 29 of the 119 cmux
lands waiting on running checks at 17:50Z waited on that status alone.

Now it posts on the cmux-bot App's token first (minted with statuses: write, as cmux-next.yml's same-tree statuses
are), falls back to the job's token, retries both, and says so in a warning when neither got through.

Run: python3 tests/test_ci_land_tier_status_post.py
"""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/pr-router.yml"

FAKE_GH = """#!/bin/sh
echo "$GH_TOKEN $*" >> "$CALLS"
case " $FAIL_TOKENS " in *" $GH_TOKEN "*)
  echo "gh: API rate limit exceeded for installation." >&2; exit 1;;
esac
exit 0
"""


def route_steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["route"]["steps"]


def step(name: str) -> dict:
    found = [s for s in route_steps() if s.get("name") == name]
    assert found, f"pr-router.yml's route job has no step {name!r}"
    return found[0]


class LandTierStatusPost(unittest.TestCase):
    def run_post(self, app_token: str, fail: str, state: str = "success") -> tuple[int, list[str], str]:
        script = step("Post the land tier status")["run"]
        with tempfile.TemporaryDirectory() as tmp:
            gh = Path(tmp, "gh")
            gh.write_text(FAKE_GH)
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            calls = Path(tmp, "calls")
            env = {"PATH": f"{tmp}:{os.environ['PATH']}", "CALLS": str(calls), "FAIL_TOKENS": fail,
                   "APP_TOKEN": app_token, "JOB_TOKEN": "job", "REPO": "manaflow-ai/cmux", "SHA": "a" * 40,
                   "STATE": state, "RUN_URL": "https://example.invalid/run", "LAND_STATUS_RETRY_S": "0"}
            done = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True, text=True, timeout=30)
            lines = calls.read_text().splitlines() if calls.exists() else []
        return done.returncode, lines, done.stdout + done.stderr

    def test_the_app_token_posts_first(self) -> None:
        code, calls, _ = self.run_post("app", fail="")
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith("app api repos/manaflow-ai/cmux/statuses/"), calls)
        self.assertIn("state=success", calls[0])
        self.assertIn("context=cmux/land-tier", calls[0])

    def test_a_spent_job_token_does_not_leave_the_status_unposted(self) -> None:
        # the regression: GITHUB_TOKEN refused for the installation's rate limit; the App's token posts it
        code, calls, _ = self.run_post("app", fail="job")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["app"])

    def test_a_refused_app_token_falls_back_to_the_job_token(self) -> None:
        code, calls, _ = self.run_post("app", fail="app")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["app", "job"])

    def test_no_app_token_posts_on_the_job_token(self) -> None:
        code, calls, _ = self.run_post("", fail="")
        self.assertEqual(code, 0)
        self.assertEqual([c.split()[0] for c in calls], ["job"])

    def test_both_refused_retries_then_warns(self) -> None:
        code, calls, said = self.run_post("app", fail="app job", state="pending")
        self.assertEqual(code, 1)
        self.assertEqual(len(calls), 6)  # three rounds of both tokens
        self.assertIn("::warning::cmux/land-tier (pending) was not posted", said)

    def test_the_token_is_minted_with_statuses_write_for_same_repo_heads_only(self) -> None:
        mint = step("Mint the land tier status token")
        self.assertTrue(str(mint["uses"]).startswith("actions/create-github-app-token@"))
        self.assertEqual(mint["with"]["permission-statuses"], "write")
        self.assertTrue(mint.get("continue-on-error"))
        self.assertIn("head.repo.full_name == github.repository", mint["if"])
        names = [s.get("name") for s in route_steps()]
        self.assertLess(names.index("Mint the land tier status token"), names.index("Post the land tier status"))
        post = step("Post the land tier status")
        self.assertIn("steps.land-status-token.outputs.token", post["env"]["APP_TOKEN"])


if __name__ == "__main__":
    unittest.main()
