#!/usr/bin/env python3
"""language-boundaries spends no GITHUB_TOKEN call on a label it never reads, and lists files from git.

GitHub runs every pull_request_target workflow from the default branch's copy, so this file on main is the one
that runs for every pull request into feat-cmux-next. On 2026-11-21 it ran 828 times in the hour 15:51-16:51Z, and
each run listed the changed files with `gh api pulls/N/files` (one GITHUB_TOKEN call, more past 100 files). Most
runs were label events: cmux-bot adds harness:, area: and kind: labels, about 870 an hour, and each started the
check again. The repository's GITHUB_TOKEN hour ran out at 16:22Z, 29 minutes before its reset, and the production
promote gates read their staging runs from the same hour.

The check is advisory (its step runs with continue-on-error), so a skipped run hides no failure: a label event
starts its job only for the two approval labels it reads (leo-approved-port, react-port-ok). The job holds the
concurrency group, so a skipped label run never cancels a real check in flight. A run that does start reads the
changed files from the pull request's merge ref (git, no API call) and keeps the REST listing for a merge ref that
lags the head.

Run: python3 tests/test_ci_language_boundaries_spends_no_rest.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from test_ci_fix_cause_labels_start_no_jobs import event, jobs_started  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "language-boundaries.yml"
STEP = "Check the changed files against the language boundaries"
PR = "7"

# A recording gh: each call is one line in $GH_LOG; it prints $GH_OUT (as if --jq ran) or fails like a spent hour.
FAKE_GH = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$GH_LOG"
if [ -n "${GH_OUT:-}" ]; then cat "$GH_OUT"; exit 0; fi
echo 'gh: API rate limit exceeded for installation (HTTP 403)' >&2
exit 1
"""

# Stands in for the base's scripts/ci/language_boundaries.py (it lives on feat-cmux-next): prints the files it got.
FAKE_CHECK = """import sys
args = sys.argv[1:]
files, fmt = args[args.index("--files") + 1], args[args.index("--format") + 1]
data = open(files, "rb").read()
names = [part.decode() for part in data.split(b"\\0") if part] if fmt == "git-z" else data.decode().splitlines()
print("format", fmt)
print("\\n".join(names))
"""


def document() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())


def git(cwd: Path, *args: str) -> str:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(
        ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
         "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main", *args],
        cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


class LabelEvents(unittest.TestCase):
    def started(self, action: str, label: str) -> list[str]:
        return jobs_started(document(), event(action, label, state="open"))

    def test_a_triage_label_starts_no_job(self) -> None:
        for action in ("labeled", "unlabeled"):
            for label in ("harness:claude", "area: build-and-ci", "kind:chore", "risk:normal"):
                with self.subTest(action=action, label=label):
                    self.assertEqual(self.started(action, label), [])

    def test_an_approval_label_still_runs_the_check(self) -> None:
        for action in ("labeled", "unlabeled"):
            for label in ("leo-approved-port", "react-port-ok"):
                with self.subTest(action=action, label=label):
                    self.assertEqual(self.started(action, label), ["language-boundaries"])

    def test_a_push_runs_the_check(self) -> None:
        context = event("synchronize", "harness:claude", state="open")
        context["github"]["event"].pop("label")
        self.assertEqual(jobs_started(document(), context), ["language-boundaries"])

    def test_a_skipped_label_run_holds_no_concurrency_group(self) -> None:
        # A workflow-level group would let the skipped run cancel the real check in flight.
        self.assertNotIn("concurrency", document())
        self.assertIn("concurrency", document()["jobs"]["language-boundaries"])


class FilesFromGit(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="language-boundaries-git-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        work = self.root / "work"
        work.mkdir()
        git(work, "init", "-q")
        (work / "README.md").write_text("base\n")
        git(work, "add", "-A")
        git(work, "commit", "-qm", "base")
        self.base = git(work, "rev-parse", "HEAD")
        git(work, "checkout", "-qb", "topic")
        (work / "webviews" / "src").mkdir(parents=True)
        (work / "webviews" / "src" / "Transcript.swift").write_text("struct Transcript {}\n")
        git(work, "add", "-A")
        git(work, "commit", "-qm", "head")
        self.head = git(work, "rev-parse", "HEAD")
        git(work, "checkout", "-q", "main")
        (work / "README.md").write_text("base moved on\n")
        git(work, "commit", "-qam", "base moves")
        git(work, "merge", "-q", "--no-ff", "-m", "merge", "topic")
        self.merge = git(work, "rev-parse", "HEAD")
        self.work = work

    def run_step(self, merge_ref: bool, gh_out: str | None = None) -> tuple[subprocess.CompletedProcess, list[str]]:
        origin = self.root / "origin.git"
        git(self.root, "init", "-q", "--bare", str(origin))
        refs = [f"{self.head}:refs/pull/{PR}/head"] + ([f"{self.merge}:refs/pull/{PR}/merge"] if merge_ref else [])
        git(self.work, "push", "-q", origin.as_uri(), *refs)
        checkout = self.root / "checkout"
        checkout.mkdir()
        git(checkout, "init", "-q")
        git(checkout, "remote", "add", "origin", origin.as_uri())
        (checkout / "scripts" / "ci").mkdir(parents=True)
        (checkout / "scripts" / "ci" / "language_boundaries.py").write_text(FAKE_CHECK)
        (checkout / ".github").mkdir()
        (checkout / ".github" / "language-boundaries.toml").write_text("")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        log = self.root / "gh.log"
        temp = self.root / "runner-temp"
        temp.mkdir()
        step = next(s for s in document()["jobs"]["language-boundaries"]["steps"] if s.get("name") == STEP)
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(PATH=f"{bin_dir}:{os.environ['PATH']}", GH_LOG=str(log), RUNNER_TEMP=str(temp),
                   GH_TOKEN="test-token-not-real", REPOSITORY="manaflow-ai/cmux", PR=PR, HEAD_SHA=self.head,
                   BASE_SHA=self.base, LABELS_JSON="[]", CHANGED_FILES="1")
        if gh_out is not None:
            (self.root / "gh.out").write_text(gh_out)
            env["GH_OUT"] = str(self.root / "gh.out")
        done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
                              cwd=checkout, env=env, capture_output=True, text=True, timeout=120)
        return done, (log.read_text().splitlines() if log.exists() else [])

    def test_the_merge_ref_lists_the_files_with_no_api_call(self) -> None:
        done, calls = self.run_step(merge_ref=True)
        self.assertEqual(calls, [], done.stdout + done.stderr)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("format git-z", done.stdout)
        self.assertIn("webviews/src/Transcript.swift", done.stdout)

    def test_without_a_merge_ref_the_files_api_is_the_fallback(self) -> None:
        listing = '{"status":"added","path":"webviews/src/Transcript.swift","old":""}\n'
        done, calls = self.run_step(merge_ref=False, gh_out=listing)
        self.assertEqual(len(calls), 1, calls)
        self.assertIn(f"pulls/{PR}/files", calls[0])
        self.assertIn("format json", done.stdout)


if __name__ == "__main__":
    unittest.main()
