#!/usr/bin/env python3
"""The namespace autofix commit is authored by the pull request author, not the bot.

CLA Assistant makes every primary commit author sign. github-actions[bot] cannot
sign, so a "lint: apply namespace autofix" commit authored by the bot failed the
CLA check once its pull request targeted main (#53995, run 45622756282). The
commit now carries the pull request author (who signs anyway, as the opener)
and names github-actions[bot] in a Co-authored-by trailer, which never signs.
This runs the workflow's own commit lines in a scratch repository.
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/namespace-autofix.yml"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"


def fix_step() -> dict:
    doc = yaml.safe_load(WORKFLOW.read_text())
    for step in doc["jobs"]["autofix"]["steps"]:
        if step.get("id") == "fix":
            return step
    raise AssertionError("namespace-autofix.yml has no step with id fix")


def commit_block(script: str) -> str:
    """The lines from the author checks through the commit, as the step runs them."""
    start = script.index('case "$PR_AUTHOR_ID" in')
    end = script.index('auth="$(printf')
    block = script[start:end]
    # The scratch repository has no hooks; the flag only matters on the runner.
    return block.replace("git -c core.hooksPath=/dev/null commit", "git commit")


class NamespaceAutofixAuthorTest(unittest.TestCase):
    def setUp(self):
        self.step = fix_step()
        self.block = commit_block(self.step["run"])

    def run_block(self, login: str, user_id: str) -> subprocess.CompletedProcess:
        tmp = tempfile.mkdtemp()
        env = {
            "PATH": os.environ["PATH"],
            "HOME": tmp,
            "GIT_CONFIG_NOSYSTEM": "1",
            "PR_AUTHOR_LOGIN": login,
            "PR_AUTHOR_ID": user_id,
        }
        subprocess.run(["git", "init", "-q", tmp], check=True, env=env)
        Path(tmp, "a.swift").write_text("x\n")
        subprocess.run(["git", "-C", tmp, "add", "a.swift"], check=True, env=env)
        result = subprocess.run(
            ["bash", "-c", "set -euo pipefail\n" + self.block],
            cwd=tmp, env=env, capture_output=True, text=True,
        )
        result.repo = tmp  # type: ignore[attr-defined]
        return result

    def log(self, repo: str, fmt: str) -> str:
        return subprocess.run(
            ["git", "-C", repo, "log", "-1", f"--format={fmt}"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    def test_author_comes_from_the_pull_request_user(self):
        env = self.step["env"]
        self.assertEqual(env["PR_AUTHOR_LOGIN"], "${{ github.event.pull_request.user.login }}")
        self.assertEqual(env["PR_AUTHOR_ID"], "${{ github.event.pull_request.user.id }}")

    def test_commit_is_authored_by_the_pull_request_author(self):
        for login, user_id in (("alice", "12345"), ("manaflow-glaeda-route[bot]", "99")):
            with self.subTest(login=login):
                result = self.run_block(login, user_id)
                self.assertEqual(result.returncode, 0, result.stderr)
                repo = result.repo  # type: ignore[attr-defined]
                self.assertEqual(self.log(repo, "%ae"), f"{user_id}+{login}@users.noreply.github.com")
                self.assertEqual(self.log(repo, "%an"), login)
                self.assertNotEqual(self.log(repo, "%ae"), BOT_EMAIL)
                self.assertEqual(self.log(repo, "%ce"), BOT_EMAIL)
                self.assertEqual(self.log(repo, "%s"), "lint: apply namespace autofix")
                self.assertIn(
                    f"Co-authored-by: github-actions[bot] <{BOT_EMAIL}>",
                    self.log(repo, "%(trailers:only,unfold)"),
                )

    def test_malformed_author_fails_before_committing(self):
        for login, user_id in (("alice", ""), ("alice", "12a"), ("", "1"), ("a;b", "1"), ("a b", "1")):
            with self.subTest(login=login, user_id=user_id):
                result = self.run_block(login, user_id)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error::", result.stdout)

    def test_no_bot_only_author_remains(self):
        # The bot identity is the committer only; nothing commits with it as author.
        self.assertIsNone(re.search(r"git config user\.email[^\n]*\n\s*git[^\n]*commit", self.block))


if __name__ == "__main__":
    unittest.main()
