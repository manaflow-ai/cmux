#!/usr/bin/env python3
"""The fast-checks checkout disk keeps its Git object store from run to run.

"Sanitize persistent checkout metadata" drops the refs, config and index a prior run
wrote, but it removed .git/refs and left no HEAD it wrote itself. Git does not count a
directory without refs/ as a repository, so actions/checkout logged "fatal: --local can
only be used inside a git repository", deleted the whole sticky disk and fetched cold:
every run sampled on 2026-11-27 spent about 26 s on that fetch (ci-min-per-pr-14, Leo:
"de facto, im asking for 99% fewer minutes of ci time, period").

This runs the step's own script against a used checkout and holds it to two things: Git
still reads the directory as a repository with its objects, and no ref, hook or config
of the prior run survives.
"""

from __future__ import annotations

import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "fast-checks.yml"


def sanitize_script() -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        r"^      - name: Sanitize persistent checkout metadata\n.*?^        run: \|\n(.*?)(?=^      - |\Z)",
        text,
        re.S | re.M,
    )
    if not match:
        raise AssertionError("no Sanitize persistent checkout metadata step")
    return textwrap.dedent(match.group(1))


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class WarmCheckoutTest(unittest.TestCase):
    def test_used_checkout_stays_a_repository_with_its_objects(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            repo = workspace / ".fast-checks-checkout"
            repo.mkdir()
            git(repo, "init", "-q")
            git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "prior")
            commit = git(repo, "rev-parse", "HEAD")
            git(repo, "tag", "prior-tag")
            git(repo, "config", "core.fsmonitor", "/bin/false")
            (repo / ".git" / "hooks" / "post-checkout").write_text("#!/bin/sh\nexit 1\n")

            subprocess.run(["bash", "-e", "-c", sanitize_script()], cwd=workspace, check=True)

            self.assertEqual(git(repo, "rev-parse", "--git-dir"), ".git")
            self.assertEqual(git(repo, "cat-file", "-t", commit), "commit")
            self.assertEqual(git(repo, "for-each-ref"), "")
            self.assertFalse((repo / ".git" / "hooks").exists())
            self.assertNotIn("fsmonitor", (repo / ".git" / "config").read_text())
            self.assertEqual((repo / ".git" / "HEAD").read_text(), "ref: refs/heads/main\n")

    def test_fresh_disk_is_left_for_checkout_to_initialize(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            subprocess.run(["bash", "-e", "-c", sanitize_script()], cwd=workspace, check=True)
            self.assertFalse((workspace / ".fast-checks-checkout" / ".git").exists())


if __name__ == "__main__":
    unittest.main()
