#!/usr/bin/env python3
"""A workflow that lists a pull request's files over the API also has a git route (no network).

github.token's quota is the repository's, shared with every job, and it runs dry ("API rate limit
exceeded for installation"). namespace-autofix.yml went red on it until it fell back to git's
merge-base diff (cmux#59292), keeping non-ASCII paths (cmux#59545); cmux-next-pr-autofix-push.yml
had the same single-source listing. This pins both:

- the detector: any workflow calling `pulls/N/files` also lists the files through git (a merge base
  or the PR's merge ref), or is named in KNOWN_API_ONLY with the reason it is not yet;
- the push workflow's step, run as written with a `gh` that fails, lists through git exactly what
  the files API would: a rename's two paths, a deletion, a non-ASCII path, and none of the files
  the base changed after the branch point.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
PUSH = WORKFLOWS / "cmux-next-pr-autofix-push.yml"

API_LISTING = re.compile(r"pulls/[^\s\"'/]+/files")
GIT_ROUTE = re.compile(r"git(?: -C \S+)? merge-base|refs/pull/[^\s\"']+/merge")

# Workflows that still list over the API alone, each with why. A detector, not a pass: an entry
# that gains a git route must leave this list (the test says so).
KNOWN_API_ONLY = {
    # Lists through scripts/ci/classic_api_guard.py with two quotas (an App token, then
    # github.token once on a refusal); a patch on the quota, not git.
    "classic-api-guard.yml": "two quotas through classic_api_guard.py",
    # Same-tree check first, then the glaeda App token and github.token: two quotas.
    "backend-migrations.yml": "same-tree shortcut, then two quotas",
    # A failed listing already runs the tests (should_run stays true): fails open, never red.
    "cloud-machine-tests.yml": "a failed listing runs the tests",
}


class DetectorTest(unittest.TestCase):
    def test_every_api_listing_has_a_git_route(self) -> None:
        missing, stale = [], []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            text = path.read_text(encoding="utf-8")
            if not API_LISTING.search(text):
                continue
            has_git = bool(GIT_ROUTE.search(text))
            if path.name in KNOWN_API_ONLY:
                if has_git:
                    stale.append(path.name)
            elif not has_git:
                missing.append(path.name)
        self.assertEqual(
            missing,
            [],
            "These workflows list a PR's files only over the API, which fails when the shared "
            "installation quota runs dry. Fall back to git's merge-base diff as "
            "namespace-autofix.yml does (cmux#59292, cmux#59545).",
        )
        self.assertEqual(stale, [], "These now have a git route; drop them from KNOWN_API_ONLY.")


def git(cwd: Path, *args: str) -> str:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.com",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
    }
    return subprocess.run(
        ["git", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always", *args],
        cwd=cwd, env=env, check=True, capture_output=True, text=True,
    ).stdout.strip()


def commit(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "--quiet", "-m", message)
    return git(repo, "rev-parse", "HEAD")


class PushFallbackTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        steps = yaml.safe_load(PUSH.read_text(encoding="utf-8"))["jobs"]["push"]["steps"]
        self.script = next(s for s in steps if s.get("name") == "Apply and commit")["run"]

        # origin: feat-cmux-next, a PR branch off it, then more base commits after the branch point.
        origin = self.tmp / "origin"
        origin.mkdir()
        git(origin, "init", "--quiet")
        for i in range(5):
            (origin / f"base{i}.txt").write_text(f"{i}\n")
            commit(origin, f"base {i}")
        (origin / "old.txt").write_text("rename me\n")
        (origin / "gone.txt").write_text("delete me\n")
        commit(origin, "base files")
        git(origin, "branch", "-M", "feat-cmux-next")
        git(origin, "checkout", "--quiet", "-b", "pr")
        git(origin, "mv", "old.txt", "new.txt")
        git(origin, "rm", "--quiet", "gone.txt")
        (origin / "Packages").mkdir()
        (origin / "Packages" / "é.swift").write_text("let x = 1\n")
        commit(origin, "pr 1")
        for i in range(3):
            (origin / f"pr{i}.txt").write_text(f"{i}\n")
            self.head = commit(origin, f"pr more {i}")
        git(origin, "checkout", "--quiet", "feat-cmux-next")
        for i in range(4):
            (origin / f"later{i}.txt").write_text(f"{i}\n")
            commit(origin, f"base later {i}")
        git(origin, "update-ref", "refs/pull/7/head", self.head)

        # The job's checkouts: head/ at the head SHA, depth 1; base/ holds the apply script.
        work = self.tmp / "work"
        work.mkdir()
        git(work, "clone", "--quiet", "--depth=1", "--branch", "pr", origin.as_uri(), "head")
        apply = work / "base" / "scripts" / "cmux-next" / "pr-autofix-apply.sh"
        apply.parent.mkdir(parents=True)
        # Records the --changed list and changes nothing, so the step ends at "nothing to push".
        apply.write_text('#!/bin/sh\ncp "$4" "$RUNNER_TEMP/seen.txt"\n')
        apply.chmod(apply.stat().st_mode | stat.S_IXUSR)
        self.work = work

        bindir = self.tmp / "bin"
        bindir.mkdir()
        self.bindir = bindir
        self.runner_temp = self.tmp / "runner"
        self.runner_temp.mkdir()

    def fake_gh(self, body: str) -> None:
        gh = self.bindir / "gh"
        gh.write_text("#!/bin/sh\n" + textwrap.dedent(body))
        gh.chmod(0o755)

    def run_step(self) -> subprocess.CompletedProcess[str]:
        env = {
            "PATH": f"{self.bindir}:{os.environ['PATH']}",
            "HOME": str(self.tmp),
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_ALLOW_PROTOCOL": "file",
            "RUNNER_TEMP": str(self.runner_temp),
            "GITHUB_OUTPUT": str(self.tmp / "out"),
            "GITHUB_STEP_SUMMARY": str(self.tmp / "summary"),
            "GITHUB_REPOSITORY": "manaflow-ai/cmux",
            "HEAD_SHA": self.head,
            "BASE_REF": "feat-cmux-next",
            "PR": "7",
            "RUN_URL": "https://example.invalid/run",
        }
        return subprocess.run(
            ["bash", "-c", self.script], cwd=self.work, env=env, capture_output=True, text=True,
        )

    def seen(self) -> list[str]:
        return sorted((self.runner_temp / "seen.txt").read_text(encoding="utf-8").splitlines())

    def test_api_failure_lists_through_git(self) -> None:
        self.fake_gh("echo 'API rate limit exceeded for installation' >&2\nexit 1\n")
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("using git's merge-base diff instead", result.stdout)
        self.assertEqual(
            self.seen(),
            sorted(["Packages/é.swift", "gone.txt", "new.txt", "old.txt", "pr0.txt", "pr1.txt", "pr2.txt"]),
        )

    def test_api_listing_is_used_when_it_answers(self) -> None:
        self.fake_gh("printf 'from-api.txt\\n'\n")
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.seen(), ["from-api.txt"])

    def test_no_merge_base_refuses(self) -> None:
        self.fake_gh("exit 1\n")
        self.script = self.script.replace("for deepen in 100 400 1600 6400", "for deepen in")
        result = self.run_step()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Both sources of the PR's files failed", result.stdout)
        self.assertFalse((self.runner_temp / "seen.txt").exists())


if __name__ == "__main__":
    unittest.main()
