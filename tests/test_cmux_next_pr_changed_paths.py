#!/usr/bin/env python3
"""The PR autofix lists a pull request's changed paths from git, not the files API.

action-areas, repair and generated-drift each read `pulls/N/files` (a call per
100 files) on every push to a feat-cmux-next pull request, and every such call
spends the repository's shared GITHUB_TOKEN quota. action-areas and repair
fetch the commit graph back to the merge base, so they list the same set from git:
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

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

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
        self.assertIn("(!cancelled() && ", job["if"], job["if"])  # after the draft-head term (tests/test_head_tier.py)


FETCH_HISTORY = ROOT / "scripts/cmux-next/fetch-pr-history.sh"


class HistoryFetchTests(unittest.TestCase):
    """fetch-pr-history.sh: a depth 1 clone gets the history back to the merge base, not every branch's.

    The remote has a long base history, a PR branched off it a few commits back, a base that moved on, a merge
    commit of the two, and an unrelated branch whose commits no fetch should bring.
    """

    MOVES = 80  # base commits since the PR branched: more than 8, fewer than 128

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.remote = git_fixture_env.init_repo(root / "remote", "-b", "feat")
        r = self.remote
        git(r, "config", "uploadpack.allowFilter", "true")
        git(r, "config", "uploadpack.allowAnySHA1InWant", "true")
        # One fast-import stream: about 490 commits in a second, not one process each.
        stream, mark = [], 0

        def commit(ref: str, path: str, text: str, parents: list[str]) -> str:
            nonlocal mark
            mark += 1
            data = text.encode()
            stream.append(f"commit {ref}\nmark :{mark}\ncommitter t <t@example.com> {1700000000 + mark} +0000\n"
                          f"data 1\nc\n" + "".join(f"{'from' if i == 0 else 'merge'} {p}\n" for i, p in enumerate(parents))
                          + f"M 100644 inline {path}\ndata {len(data)}\n{text}\n")
            return f":{mark}"

        tip = None
        for i in range(400):  # longer than the deepest try: a whole history would show
            tip = commit("refs/heads/feat", "base.txt", f"{i}\n", [tip] if tip else [])
        fork = tip
        other = fork
        for i in range(5):
            other = commit("refs/heads/other", "other.txt", f"{i}\n", [other])
        head = fork
        for i in range(3):
            head = commit("refs/heads/pr", "pr.txt", f"{i}\n", [head])
        base = fork
        for i in range(self.MOVES):
            base = commit("refs/heads/feat", "base.txt", f"moved {i}\n", [base])
        merge = commit("refs/pull/1/merge", "pr.txt", "2\n", [base, head])
        marks = root / "marks"
        subprocess.run(["git", "-C", str(r), "fast-import", "--quiet", f"--export-marks={marks}"],
                       input="".join(stream).encode(), check=True, capture_output=True)
        by_mark = dict(line.split() for line in marks.read_text().splitlines())
        self.fork, self.other, self.head, self.base, self.merge = (by_mark[m] for m in (fork, other, head, base, merge))
        # The checkout as actions/checkout leaves it: init, then the merge commit alone at depth 1, no blobs.
        self.clone = git_fixture_env.init_repo(root / "clone")
        git(self.clone, "remote", "add", "origin", f"file://{r}")
        git(self.clone, "fetch", "-q", "--no-tags", "--depth=1", "--filter=blob:none", "origin", self.merge)
        git(self.clone, "checkout", "-q", "--detach", self.merge)

    def tearDown(self):
        self.tmp.cleanup()

    def fetch(self, **env: str) -> subprocess.CompletedProcess:
        return subprocess.run([str(FETCH_HISTORY), self.merge, self.base, self.head], cwd=self.clone,
                              env={**os.environ, "CMUX_PR_HISTORY_RETRY_S": "0", **env},
                              capture_output=True, text=True)

    def has(self, sha: str) -> bool:
        return subprocess.run(["git", "-C", str(self.clone), "cat-file", "-e", f"{sha}^{{commit}}"],
                              capture_output=True).returncode == 0

    def test_deepens_until_the_merge_base_and_no_further(self):
        result = self.fetch(CMUX_PR_HISTORY_DEPTHS="8 128")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("depth 128", result.stdout)
        self.assertEqual(git(self.clone, "merge-base", self.base, self.head), self.fork)
        self.assertEqual(git(self.clone, "rev-parse", "--is-shallow-repository"), "true")
        self.assertFalse(self.has(self.other), "an unrelated branch's commits came along")
        # What the jobs read: the changed paths and the stale-inputs guard's ancestry.
        self.assertEqual(git(self.clone, "diff", "--name-only", f"{self.base}...{self.head}"), "pr.txt")
        git(self.clone, "merge-base", "--is-ancestor", self.base, f"{self.merge}^1")
        # And the base commit's files, restored as the repair job does.
        out = Path(self.tmp.name) / "restored"
        out.mkdir()
        git(self.clone, f"--work-tree={out}", "restore", "--ignore-skip-worktree-bits", f"--source={self.base}",
            "--worktree", "--", "base.txt")
        self.assertEqual((out / "base.txt").read_text(), f"moved {self.MOVES - 1}\n")

    def test_unshallows_when_the_depths_fall_short(self):
        result = self.fetch(CMUX_PR_HISTORY_DEPTHS="4 16")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("history: whole", result.stdout)
        self.assertEqual(git(self.clone, "rev-parse", "--is-shallow-repository"), "false")
        self.assertEqual(git(self.clone, "merge-base", self.base, self.head), self.fork)

    def test_a_fetch_that_keeps_failing_fails_the_job(self):
        git(self.clone, "remote", "set-url", "origin", f"file://{self.tmp.name}/missing")
        result = self.fetch(CMUX_PR_HISTORY_DEPTHS="8")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.count("::warning::history fetch"), 3, result.stdout)

    def test_both_jobs_fetch_with_it_and_repair_no_longer_clones_every_branch(self):
        for job in ("action-areas", "repair"):
            steps = WORKFLOW["jobs"][job]["steps"]
            checkout = next(s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@"))
            self.assertNotIn("fetch-depth", checkout["with"], job)
            history = step(job, "History of the merge commit")
            self.assertIn("scripts/cmux-next/fetch-pr-history.sh", history["run"], job)
            self.assertLess(steps.index(history), steps.index(step(job, "Changed paths")), job)
        self.assertNotIn("git archive \"$BASE_SHA\"", step("repair", "Autofix scripts from the base")["run"])

    def test_a_stalled_package_dump_leaves_only_the_graph(self):
        dump = step("repair", "Dump the CmuxNext package manifest")
        self.assertTrue(dump.get("continue-on-error"))
        self.assertLessEqual(dump["timeout-minutes"], 10)
        repair = step("repair", "Repair")
        self.assertEqual(repair["env"]["DUMP"], "${{ steps.dump.outcome }}")
        self.assertIn('"${DUMP:-}" == success', repair["run"])


if __name__ == "__main__":
    unittest.main()
