#!/usr/bin/env python3
"""pr-capture-check and cmux-next-media's route list the changed paths from the merge commit, not the API.

The check runs on every push, label and description edit of a feat-cmux-next
pull request, and each run paged through `pulls/N/files` on the repository's
shared GITHUB_TOKEN quota. It now fetches the merge commit and its first
parent without blobs and diffs them with rename detection: the files API's
`.filename` set (a rename under its new name, a removed path included). When
that fails, the check reads the files API as before, so it still concludes.

The step scripts run here as the workflow runs them, against a local origin,
with `gh` replaced by a recorder.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/pr-capture-check.yml").read_text())
STEPS = WORKFLOW["jobs"]["capture"]["steps"]


def step(name: str) -> dict:
    return next(s for s in STEPS if s.get("name") == name)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def write(repo: Path, path: str, text: str) -> None:
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


class MergeCommitFixture(unittest.TestCase):
    """A base that moved on, a pull request, and its merge commit, reachable only by SHA."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        src = root / "src"
        src.mkdir()
        git(src, "init", "-q", "-b", "feat")
        git(src, "config", "user.email", "t@example.com")
        git(src, "config", "user.name", "t")
        git(src, "config", "uploadpack.allowFilter", "true")
        git(src, "config", "uploadpack.allowAnySHA1InWant", "true")
        body = "".join(f"let line{i} = {i}\n" for i in range(60))
        ui = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Sidebar"
        write(src, f"{ui}/Old Card.swift", body)
        write(src, f"{ui}/Gone.swift", "gone\n")
        write(src, "docs/kept.md", "kept\n")
        write(src, "docs/same.md", "same\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "base")
        git(src, "checkout", "-qb", "pr")
        git(src, "mv", f"{ui}/Old Card.swift", f"{ui}/HoverCard.swift")
        write(src, f"{ui}/HoverCard.swift", body + "let extra = 1\n")
        git(src, "rm", "-q", f"{ui}/Gone.swift")
        write(src, "webviews/src/añadido.tsx", "added\n")
        write(src, "docs/same.md", "changed\n")
        git(src, "add", "-A")
        git(src, "commit", "-qm", "pr")
        self.head = git(src, "rev-parse", "HEAD")
        git(src, "checkout", "-q", "feat")
        write(src, "docs/kept.md", "base moved\n")
        git(src, "commit", "-qam", "base moves on")
        git(src, "merge", "-q", "--no-ff", "pr", "-m", "merge")
        self.merge = git(src, "rev-parse", "HEAD")
        git(src, "reset", "-q", "--hard", "HEAD^1")  # the merge is reachable only by its SHA, as refs/pull/N/merge
        git(src, "update-ref", "refs/pull/1/merge", self.merge)
        # The files API's `.filename` for this pull request.
        self.api_set = {f"{ui}/HoverCard.swift", f"{ui}/Gone.swift", "webviews/src/añadido.tsx", "docs/same.md"}
        # The workflow's checkout: the base branch, depth 1, no credentials.
        self.clone = root / "clone"
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", "feat", f"file://{src}", str(self.clone)],
                       check=True, capture_output=True)
        self.temp = root / "temp"
        self.temp.mkdir()
        self.bin = root / "bin"
        self.bin.mkdir()
        self.gh_log = root / "gh.log"
        (self.bin / "gh").write_text('#!/usr/bin/env bash\necho "$*" >> "$GH_LOG"\nprintf "%s\\n" $GH_FILES\n')
        (self.bin / "gh").chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_step(self, name: str, **env: str) -> tuple[subprocess.CompletedProcess, dict]:
        output = self.temp / "github_output"
        output.write_text("")
        full = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "GH_LOG": str(self.gh_log),
                "RUNNER_TEMP": str(self.temp), "GITHUB_OUTPUT": str(output), **env}
        result = subprocess.run(["bash", "-e", "-c", step(name)["run"]], cwd=self.clone, env=full,
                                capture_output=True, text=True)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)
        return result, outputs

    def gh_calls(self) -> list[str]:
        return self.gh_log.read_text().splitlines() if self.gh_log.exists() else []


class CapturePathsTests(MergeCommitFixture):
    def test_the_merge_commit_lists_the_files_api_set(self):
        result, outputs = self.run_step("List the changed paths", MERGE_SHA=self.merge, HEAD_SHA=self.head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs.get("listed"), "true")
        listed = (self.temp / "paths.txt").read_text(encoding="utf-8").splitlines()
        self.assertEqual(set(listed), self.api_set)
        self.assertEqual(self.gh_calls(), [])

    def test_the_check_reads_no_api_once_git_listed_the_paths(self):
        self.run_step("List the changed paths", MERGE_SHA=self.merge, HEAD_SHA=self.head)
        # The base checkout has no pr_capture_check.py; give the step this repository's.
        (self.clone / "scripts/ci").mkdir(parents=True)
        (self.clone / "scripts/cmux-next/media").mkdir(parents=True)
        for path in ("scripts/ci/pr_capture_check.py", "scripts/cmux-next/media/path_map.py"):
            (self.clone / path).write_text((ROOT / path).read_text())
        result, _ = self.run_step("Check the description for a real capture", LISTED="true",
                                  BODY="No capture: test fixture", LABELS="", PR="1", REPOSITORY="o/r",
                                  HEAD_SHA="a" * 40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Native UI change", result.stdout)
        self.assertEqual(self.gh_calls(), [])

    def test_a_merge_of_another_head_is_not_trusted(self):
        # A stale merge commit (of an earlier head) must not stand in for this head's changes.
        result, outputs = self.run_step("List the changed paths", MERGE_SHA=self.merge, HEAD_SHA="b" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("listed", outputs)

    def test_a_failed_listing_falls_back_to_the_files_api(self):
        result, outputs = self.run_step("List the changed paths", MERGE_SHA="0" * 40, HEAD_SHA=self.head)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("listed", outputs)
        self.assertTrue(step("List the changed paths").get("continue-on-error"))
        (self.clone / "scripts/ci").mkdir(parents=True)
        (self.clone / "scripts/cmux-next/media").mkdir(parents=True)
        for path in ("scripts/ci/pr_capture_check.py", "scripts/cmux-next/media/path_map.py"):
            (self.clone / path).write_text((ROOT / path).read_text())
        result, _ = self.run_step("Check the description for a real capture", LISTED="",
                                  BODY="", LABELS="", PR="1", REPOSITORY="o/r", HEAD_SHA="a" * 40,
                                  GH_FILES="docs/readme.md")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.gh_calls()), 1)
        self.assertIn("pulls/1/files", self.gh_calls()[0])


MEDIA = yaml.safe_load((ROOT / ".github/workflows/cmux-next-media.yml").read_text())


class MediaRoutePathsTests(MergeCommitFixture):
    """cmux-next-media's route reads the same merge-commit diff instead of pulls/N/files and compare."""

    def media_step(self, name: str, **env: str) -> tuple[subprocess.CompletedProcess, dict]:
        for path in ("scripts/ci/media_auto_tour.py", "scripts/cmux-next/media/path_map.py"):
            (self.clone / path).parent.mkdir(parents=True, exist_ok=True)
            (self.clone / path).write_text((ROOT / path).read_text())
        script = next(s for s in MEDIA["jobs"]["route"]["steps"] if s.get("name") == name)["run"]
        output = self.temp / "github_output"
        if not output.exists():
            output.write_text("")
        full = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "GH_LOG": str(self.gh_log),
                "RUNNER_TEMP": str(self.temp), "GITHUB_OUTPUT": str(output), "GITHUB_SHA": self.merge,
                "GITHUB_REPOSITORY": "o/r", "EVENT": "pull_request", "PR": "1", "LABELS": "[]",
                "ACTION": "synchronize", "DRAFT": "false", **env}
        result = subprocess.run(["bash", "-e", "-c", script], cwd=self.clone, env=full, capture_output=True, text=True)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)
        return result, outputs

    def test_the_route_reads_no_api_for_a_pull_request(self):
        result, outputs = self.media_step("Decide whether this pull request gets a tour")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(outputs.get("listed"), "true")
        self.assertEqual(set((self.temp / "changed.txt").read_text(encoding="utf-8").splitlines()), self.api_set)
        result, _ = self.media_step("List the changed paths", LISTED="true", BASE="b" * 40, HEAD="c" * 40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        both = self.api_set | {"Packages/macOS/CmuxNext/Sources/CmuxNextApp/Sidebar/Old Card.swift"}
        self.assertEqual(set((self.temp / "changed-paths.txt").read_text(encoding="utf-8").splitlines()), both)
        self.assertEqual(self.gh_calls(), [])

    def test_the_route_falls_back_to_the_files_api(self):
        result, outputs = self.media_step("Decide whether this pull request gets a tour", GITHUB_SHA="0" * 40,
                                          GH_FILES="docs/readme.md")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("listed", outputs)
        self.assertEqual(len(self.gh_calls()), 1)
        self.assertIn("pulls/1/files", self.gh_calls()[0])


if __name__ == "__main__":
    unittest.main()
