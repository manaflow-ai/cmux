#!/usr/bin/env python3
"""The fast-checks checkout disk keeps its Git object store from run to run.

"Sanitize persistent checkout metadata" drops the refs, config and index a prior run
wrote, but it removed .git/refs and left no HEAD it wrote itself. Git does not count a
directory without refs/ as a repository, so actions/checkout logged "fatal: --local can
only be used inside a git repository", deleted the whole sticky disk and fetched cold:
every run sampled on 2026-11-27 spent about 26 s on that fetch (ci-min-per-pr-14, Leo:
"de facto, im asking for 99% fewer minutes of ci time, period").

That left HEAD unborn (refs/heads/main), so checkout's `git reset --hard HEAD` still
failed ("ambiguous argument 'HEAD'"), it deleted the disk anyway and fetched cold: 30-40 s
of every run (run 46049698131). The step now points HEAD at the prior run's commit when
the store has it, and tags it, since a fetch offers only refs as haves.

This runs the step's own script against a used checkout and holds it to: Git still reads
the directory as a repository with its objects; no ref, hook or config of the prior run
survives; checkout's own clean, reset and fetch keep the store and fetch only what is new.
"""

from __future__ import annotations

import os
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
            git(repo, "checkout", "-q", "--detach")  # actions/checkout leaves HEAD detached
            git(repo, "tag", "prior-tag")
            git(repo, "config", "core.fsmonitor", "/bin/false")
            (repo / ".git" / "hooks" / "post-checkout").write_text("#!/bin/sh\nexit 1\n")

            subprocess.run(["bash", "-e", "-c", sanitize_script()], cwd=workspace, check=True)

            self.assertEqual(git(repo, "rev-parse", "--git-dir"), ".git")
            self.assertEqual(git(repo, "cat-file", "-t", commit), "commit")
            # Only the step's own tag, at the prior commit: prior-tag is gone.
            self.assertEqual(git(repo, "for-each-ref", "--format=%(refname) %(objectname)"),
                             f"refs/tags/fast-checks-warm {commit}")
            self.assertFalse((repo / ".git" / "hooks").exists())
            self.assertNotIn("fsmonitor", (repo / ".git" / "config").read_text())
            self.assertEqual((repo / ".git" / "HEAD").read_text(), f"{commit}\n")

    def test_checkout_resets_and_fetches_only_what_is_new(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            origin = workspace / "origin"
            origin.mkdir()
            git(origin, "init", "-q")
            git(origin, "config", "uploadpack.allowAnySHA1InWant", "true")
            for n in range(2):
                (origin / "f").write_text("\n".join(f"{i} {n}" for i in range(20000)))
                git(origin, "add", "f")
                git(origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", str(n))
            prior, new = git(origin, "rev-parse", "HEAD~1"), git(origin, "rev-parse", "HEAD")
            repo = workspace / ".fast-checks-checkout"
            repo.mkdir()
            git(repo, "init", "-q")
            git(repo, "fetch", "-q", "--depth=1", f"file://{origin}", prior)
            git(repo, "-c", "advice.detachedHead=false", "checkout", "-q", prior)
            (repo / "output.log").write_text("a prior command's output\n")

            subprocess.run(["bash", "-e", "-c", sanitize_script()], cwd=workspace, check=True)

            # actions/checkout's own sequence on an existing repository (clean: true).
            git(repo, "clean", "-ffdx")
            git(repo, "reset", "--hard", "HEAD")
            self.assertFalse((repo / "output.log").exists())
            self.assertTrue((repo / "f").exists())
            trace = subprocess.run(
                ["git", "-c", "protocol.version=2", "fetch", "--no-tags", "--prune", "--depth=2",
                 f"file://{origin}", new],
                cwd=repo, check=True, capture_output=True, text=True,
                env={**os.environ, "GIT_TRACE_PACKET": "1"},
            ).stderr
            self.assertIn(f"fetch> have {prior}", trace)

    def test_cold_checkout_switch_keeps_the_old_unborn_head(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            repo = workspace / ".fast-checks-checkout"
            repo.mkdir()
            git(repo, "init", "-q")
            git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "prior")
            git(repo, "checkout", "-q", "--detach")
            subprocess.run(["bash", "-e", "-c", sanitize_script()], cwd=workspace, check=True,
                           env={**os.environ, "CMUX_FAST_CHECKS_COLD_CHECKOUT": "1"})
            self.assertEqual(git(repo, "for-each-ref"), "")
            self.assertEqual((repo / ".git" / "HEAD").read_text(), "ref: refs/heads/main\n")

    def test_a_head_naming_a_missing_commit_is_dropped(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            repo = workspace / ".fast-checks-checkout"
            repo.mkdir()
            git(repo, "init", "-q")
            (repo / ".git" / "HEAD").write_text("0123456789abcdef0123456789abcdef01234567\n")
            subprocess.run(["bash", "-e", "-c", sanitize_script()], cwd=workspace, check=True)
            self.assertEqual(git(repo, "for-each-ref"), "")
            self.assertEqual((repo / ".git" / "HEAD").read_text(), "ref: refs/heads/main\n")

    def test_fresh_disk_is_left_for_checkout_to_initialize(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            subprocess.run(["bash", "-e", "-c", sanitize_script()], cwd=workspace, check=True)
            self.assertFalse((workspace / ".fast-checks-checkout" / ".git").exists())


if __name__ == "__main__":
    unittest.main()
