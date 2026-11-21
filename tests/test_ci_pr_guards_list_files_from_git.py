#!/usr/bin/env python3
"""The per-event pull request guards list the changed files from git, and spend no GITHUB_TOKEN call doing it.

language-boundaries.yml and classic-api-guard.yml run on every push, label and description edit of every
pull request: about 510 runs an hour on 2026-11-21 07Z. Each one listed the changed files with
`gh api pulls/N/files` first and read git only when that failed. That is one call (more past 100 files) per
event from the repository's GITHUB_TOKEN hour, the same hour the production promote gates read the staging
runs from; it ran out and held promotes (backend.yml run 44878749398, "API rate limit exceeded for
installation"). pr-body-checks.yml and pr-checks.yml already read git first.

Each test runs the workflow step's own shell script, as Actions would, against a local origin that has the
pull request's merge ref, with a `gh` on PATH that records every call. With the merge ref of this head, the
files come from git and `gh` is never called; with no merge ref, the REST listing is still the fallback.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
PR = "7"

# A recording gh: each call is one line in $GH_LOG; it prints $GH_OUT (as if --jq ran) or fails like a spent quota.
FAKE_GH = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$GH_LOG"
if [ -n "${GH_OUT:-}" ]; then cat "$GH_OUT"; exit 0; fi
echo 'gh: API rate limit exceeded for installation (HTTP 403)' >&2
exit 1
"""


def step(workflow: str, name: str) -> dict:
    jobs = yaml.safe_load((WORKFLOWS / workflow).read_text())["jobs"]
    for job in jobs.values():
        for item in job.get("steps", []):
            if item.get("name") == name:
                return item
    raise AssertionError(f"{workflow} has no step {name!r}")


def git(cwd: Path, *args: str) -> str:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
         "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main", *args],
        cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


class PullRequest:
    """A base commit, a head that adds `added`, their merge commit, and a bare origin holding refs/pull/7/*."""

    def __init__(self, root: Path, added: dict[str, str], merge_ref: bool = True) -> None:
        work = root / "work"
        work.mkdir()
        git(work, "init", "-q")
        (work / "README.md").write_text("base\n")
        git(work, "add", "-A")
        git(work, "commit", "-qm", "base")
        self.base = git(work, "rev-parse", "HEAD")
        git(work, "checkout", "-qb", "head")
        for path, text in added.items():
            (work / path).parent.mkdir(parents=True, exist_ok=True)
            (work / path).write_text(text)
        git(work, "add", "-A")
        git(work, "commit", "-qm", "head")
        self.head = git(work, "rev-parse", "HEAD")
        git(work, "checkout", "-q", "main")
        (work / "README.md").write_text("base moved on\n")
        git(work, "commit", "-qam", "base moves")
        git(work, "merge", "-q", "--no-ff", "-m", "merge", "head")
        merge = git(work, "rev-parse", "HEAD")
        self.origin = root / "origin.git"
        git(root, "init", "-q", "--bare", str(self.origin))
        refs = [f"{self.head}:refs/pull/{PR}/head"] + ([f"{merge}:refs/pull/{PR}/merge"] if merge_ref else [])
        git(work, "push", "-q", self.origin.as_uri(), *refs)


class GuardStep:
    """One workflow step run in a fresh checkout of the base's scripts, with the recording gh."""

    def __init__(self, root: Path, pr: PullRequest, copies: list[str]) -> None:
        self.root, self.pr = root, pr
        self.checkout = root / "checkout"
        self.checkout.mkdir()
        git(self.checkout, "init", "-q")
        git(self.checkout, "remote", "add", "origin", pr.origin.as_uri())
        for rel in copies:
            (self.checkout / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / rel, self.checkout / rel)
        self.bin = root / "bin"
        self.bin.mkdir()
        (self.bin / "gh").write_text(FAKE_GH)
        (self.bin / "gh").chmod(0o755)
        self.log = root / "gh.log"
        self.temp = root / "runner-temp"
        self.temp.mkdir()

    def run(self, workflow: str, name: str, env: dict[str, str], gh_out: str | None = None) -> subprocess.CompletedProcess:
        item = step(workflow, name)
        full = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        full.update(PATH=f"{self.bin}:{os.environ['PATH']}", GH_LOG=str(self.log), RUNNER_TEMP=str(self.temp),
                    GH_TOKEN="test-token-not-real", REPOSITORY="manaflow-ai/cmux", PR=PR,
                    HEAD_SHA=self.pr.head, BASE_SHA=self.pr.base, **env)
        if gh_out is not None:
            out = self.root / "gh.out"
            out.write_text(gh_out)
            full["GH_OUT"] = str(out)
        return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", item["run"]],
                              cwd=self.checkout, env=full, capture_output=True, text=True, timeout=120)

    def gh_calls(self) -> list[str]:
        return self.log.read_text().splitlines() if self.log.exists() else []


LANGUAGE = ("language-boundaries.yml", "Check the changed files against the language boundaries")
LANGUAGE_FILES = ["scripts/ci/language_boundaries.py", ".github/language-boundaries.toml"]
# Swift in the React chat UI: language_boundaries.py refuses it, so a pass would mean the file went unread.
SWIFT_IN_CHAT_UI = {"webviews/src/agent-session/Transcript.swift": "struct Transcript {}\n"}
CLASSIC = ("classic-api-guard.yml", "Check the changed paths against classic's auto-deploys")
CLASSIC_FILES = ["scripts/ci/classic_api_guard.py", "scripts/ci/classic-auto-deploy.json"]
# A guarded classic API path into main with no `Classic API change:` line fails.
CLASSIC_API = {"web/services/vms/workflows.ts": "export {}\n"}


class PullRequestGuardsReadGit(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="pr-guards-git-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_language_boundaries_reads_the_merge_ref_without_the_files_api(self) -> None:
        guard = GuardStep(self.root, PullRequest(self.root, SWIFT_IN_CHAT_UI), LANGUAGE_FILES)
        done = guard.run(*LANGUAGE, env={"LABELS_JSON": "[]", "CHANGED_FILES": "1"})
        self.assertEqual(guard.gh_calls(), [], done.stdout + done.stderr)
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("Transcript.swift", done.stdout + done.stderr)

    def test_language_boundaries_falls_back_to_the_files_api_without_a_merge_ref(self) -> None:
        guard = GuardStep(self.root, PullRequest(self.root, SWIFT_IN_CHAT_UI, merge_ref=False), LANGUAGE_FILES)
        listing = '{"status":"added","path":"webviews/src/agent-session/Transcript.swift","old":""}\n'
        done = guard.run(*LANGUAGE, env={"LABELS_JSON": "[]", "CHANGED_FILES": "1"}, gh_out=listing)
        self.assertEqual(len(guard.gh_calls()), 1, guard.gh_calls())
        self.assertIn(f"pulls/{PR}/files", guard.gh_calls()[0])
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_classic_api_guard_reads_the_merge_ref_without_the_files_api(self) -> None:
        guard = GuardStep(self.root, PullRequest(self.root, CLASSIC_API), CLASSIC_FILES)
        done = guard.run(*CLASSIC, env={"BASE": "main", "BODY": "No reason line.", "CHANGED_FILES": "1"})
        self.assertEqual(guard.gh_calls(), [], done.stdout + done.stderr)
        self.assertNotEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("web/services/vms/workflows.ts", done.stdout + done.stderr)

    def test_classic_api_guard_passes_a_reasoned_change_from_git(self) -> None:
        guard = GuardStep(self.root, PullRequest(self.root, CLASSIC_API), CLASSIC_FILES)
        body = "Classic API change: the VM workflow keeps its contract."
        done = guard.run(*CLASSIC, env={"BASE": "main", "BODY": body, "CHANGED_FILES": "1"})
        self.assertEqual(guard.gh_calls(), [], done.stdout + done.stderr)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
