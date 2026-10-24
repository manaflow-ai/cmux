#!/usr/bin/env python3
"""The PR autofix lists a pull request's changed paths from git, not the files API.

action-areas, repair and generated-drift each read `pulls/N/files` (a call per
100 files) on every push to a feat-cmux-next pull request, and every such call
spends the repository's shared GITHUB_TOKEN quota. action-areas and repair
already fetch the whole commit graph, so they list the same set from git:
the merge base to the head, with a rename as both of its paths, as
`.filename, .previous_filename` gives. generated-drift reads action-areas'
list. Any failure falls back to the files API, so the checks still conclude.

The step scripts run here as the workflow runs them, against a fixture
repository, with `gh` replaced by a recorder.
"""
from __future__ import annotations

import base64
import gzip
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/cmux-next-pr-autofix.yml").read_text())


def step(job: str, name: str) -> dict:
    return next(s for s in WORKFLOW["jobs"][job]["steps"] if s.get("name") == name)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def write(repo: Path, path: str, text: str) -> None:
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


class Fixture:
    """A base, a pull request branched from it, and a base that moved on since."""

    def __init__(self, root: Path):
        self.repo = root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "feat")
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        body = "".join(f"line {i}\n" for i in range(40))
        write(self.repo, "webviews/src/old name.tsx", body)
        write(self.repo, "docs/kept.md", "kept\n")
        write(self.repo, "docs/gone.md", "gone\n")
        write(self.repo, "Packages/café.swift", "a\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")
        git(self.repo, "checkout", "-qb", "pr")
        git(self.repo, "mv", "webviews/src/old name.tsx", "webviews/src/new.tsx")
        write(self.repo, "webviews/src/new.tsx", body + "one more\n")
        git(self.repo, "rm", "-q", "docs/gone.md")
        write(self.repo, "docs/added.md", "added\n")
        write(self.repo, "Packages/café.swift", "b\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "pr")
        self.head = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "checkout", "-q", "feat")
        write(self.repo, "docs/kept.md", "base moved\n")
        git(self.repo, "commit", "-qam", "base moves on")
        self.base = git(self.repo, "rev-parse", "HEAD")
        # What `.filename, (.previous_filename // empty)` lists for this pull request.
        self.api_set = {"webviews/src/new.tsx", "webviews/src/old name.tsx", "docs/gone.md",
                        "docs/added.md", "Packages/café.swift"}
        self.bin = root / "bin"
        self.bin.mkdir()
        self.gh_log = root / "gh.log"
        gh = self.bin / "gh"
        gh.write_text('#!/usr/bin/env bash\necho "$*" >> "$GH_LOG"\nprintf "%s\\n" $GH_FILES\n')
        gh.chmod(0o755)

    def run(self, script: str, *, cwd: Path, temp: Path, **env: str) -> tuple[subprocess.CompletedProcess, dict]:
        temp.mkdir(exist_ok=True)
        output = temp / "github_output"
        output.write_text("")
        full = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "GH_LOG": str(self.gh_log),
                "RUNNER_TEMP": str(temp), "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "o/r",
                "PR": "1", "BASE_SHA": self.base, "HEAD_SHA": self.head, **env}
        result = subprocess.run(["bash", "-e", "-c", script], cwd=cwd, env=full, capture_output=True, text=True)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)
        return result, outputs

    def gh_calls(self) -> list[str]:
        return self.gh_log.read_text().splitlines() if self.gh_log.exists() else []


class ChangedPathsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.fx = Fixture(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def test_git_lists_the_files_api_set_in_both_jobs(self):
        for job in ("action-areas", "repair"):
            temp = self.root / job
            result, outputs = self.fx.run(step(job, "Changed paths")["run"], cwd=self.fx.repo, temp=temp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(outputs.get("listed"), "true")
            listed = (temp / "changed.txt").read_text(encoding="utf-8").splitlines()
            self.assertEqual(set(listed), self.fx.api_set, job)
            self.assertEqual(len(listed), len(set(listed)), job)
        self.assertEqual(self.fx.gh_calls(), [])

    def test_action_areas_hands_generated_drift_the_same_list(self):
        temp = self.root / "areas"
        _, outputs = self.fx.run(step("action-areas", "Changed paths")["run"], cwd=self.fx.repo, temp=temp)
        decoded = gzip.decompress(base64.b64decode(outputs["changed"])).decode()
        self.assertEqual(decoded, (temp / "changed.txt").read_text(encoding="utf-8"))
        self.assertEqual(WORKFLOW["jobs"]["action-areas"]["outputs"]["changed"],
                         "${{ steps.changed.outputs.changed }}")

    def test_repair_reads_no_api_once_git_listed_the_paths(self):
        temp = self.root / "repair"
        self.fx.run(step("repair", "Changed paths")["run"], cwd=self.fx.repo, temp=temp)
        result, outputs = self.fx.run(step("repair", "Changed areas")["run"], cwd=self.fx.repo, temp=temp,
                                      LISTED="true", CHANGED_FILES="5", AUTOFIX=str(ROOT / "scripts/cmux-next"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fx.gh_calls(), [])
        # Packages/ and webviews/src/ changed: graph, strings and webviews areas.
        self.assertEqual(outputs.get("graph"), "true")
        self.assertEqual(outputs.get("strings"), "true")

    def test_without_a_git_list_repair_reads_the_files_api(self):
        temp = self.root / "fallback"
        result, outputs = self.fx.run(step("repair", "Changed areas")["run"], cwd=self.fx.repo, temp=temp,
                                      LISTED="", CHANGED_FILES="1", AUTOFIX=str(ROOT / "scripts/cmux-next"),
                                      GH_FILES="docs/x.md")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.fx.gh_calls()), 1)
        self.assertIn("pulls/1/files", self.fx.gh_calls()[0])
        self.assertEqual(outputs.get("graph"), "false")

    def test_a_failed_git_listing_leaves_the_api_fallback_on(self):
        temp = self.root / "nogit"
        result, outputs = self.fx.run(step("repair", "Changed paths")["run"], cwd=self.fx.repo, temp=temp,
                                      BASE_SHA="0" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("listed", outputs)
        self.assertTrue(step("repair", "Changed paths").get("continue-on-error"))
        self.assertTrue(step("action-areas", "Changed paths").get("continue-on-error"))

    def drift(self, changed: str, gh_files: str = "") -> tuple[subprocess.CompletedProcess, list[str]]:
        # generated-drift runs from a checkout of the base; the repository root has its script.
        result, _ = self.fx.run(step("generated-drift", "Generated files this pull request did not cause")["run"],
                                cwd=ROOT, temp=self.root / "drift", CHANGED=changed, GH_FILES=gh_files,
                                GITHUB_STEP_SUMMARY=str(self.root / "summary"))
        return result, self.fx.gh_calls()

    def test_generated_drift_reads_action_areas_list(self):
        encoded = base64.b64encode(gzip.compress(b"schemas/settings/settings-schema.json\n")).decode()
        result, calls = self.drift(encoded)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("settings-schema.json", result.stdout)
        self.assertEqual(calls, [])

    def test_generated_drift_reads_the_files_api_without_that_list(self):
        result, calls = self.drift("", gh_files="schemas/settings/settings-schema.json")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        result, _ = self.drift("not base64 !", gh_files="docs/readme.md")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_generated_drift_still_runs_when_action_areas_fails(self):
        job = WORKFLOW["jobs"]["generated-drift"]
        self.assertEqual(job["needs"], ["action-areas"])
        self.assertTrue(job["if"].startswith("${{ !cancelled() && "), job["if"])


if __name__ == "__main__":
    unittest.main()
