#!/usr/bin/env python3
"""sign-release-notes fetches only the published span, never every branch and tag.

Nightly-next run 37526646874 lost its signed release notes: the job's checkout
fetched the full history of every branch and tag of manaflow-ai/cmux and did
not finish inside the job's 10-minute timeout. The notes need only the commits
from the nightly-next tag to the built commit, plus the highlight files at that
commit. scripts/cmux-next/fetch-release-notes-span.sh fetches exactly that,
blobless and with a bounded depth that it deepens until the span is complete.
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
FETCH = ROOT / "scripts" / "cmux-next" / "fetch-release-notes-span.sh"
NOTES = ROOT / "scripts" / "cmux-next" / "release-notes.py"


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def job_block(name):
    text = WORKFLOW.read_text()
    match = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.MULTILINE | re.DOTALL)
    assert match, f"nightly.yml has no {name} job"
    return match.group(1)


class WorkflowTests(unittest.TestCase):
    def test_sign_release_notes_never_fetches_all_history(self):
        block = job_block("sign-release-notes")
        self.assertNotRegex(block, r"fetch-depth:\s*0\b", "a full-history checkout timed out in run 37526646874")
        self.assertNotRegex(block, r"fetch-tags:\s*true\b", "every tag is not needed, only nightly-next")
        self.assertIn("scripts/cmux-next/fetch-release-notes-span.sh", block)


class FetchSpanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.remote = self.tmp / "remote"
        self.remote.mkdir()
        r = str(self.remote)
        git(r, "init", "-q", "-b", "main")
        git(r, "config", "user.email", "t@example.com")
        git(r, "config", "user.name", "t")
        git(r, "config", "uploadpack.allowFilter", "true")
        git(r, "config", "uploadpack.allowAnySHA1InWant", "true")
        for i in range(30):
            git(r, "commit", "-q", "--allow-empty", "-m", f"old {i}")
        git(r, "-c", "tag.gpgsign=false", "tag", "nightly-next")
        os.makedirs(self.remote / "release-notes/next/highlights")
        (self.remote / "release-notes/next/highlights/card.md").write_text("title: A card\n\nBody.\n")
        git(r, "add", ".")
        git(r, "commit", "-q", "-m", "updates: the card")
        for i in range(12):
            git(r, "commit", "-q", "--allow-empty", "-m", f"new {i}")
        self.head = git(r, "rev-parse", "HEAD")
        # Unrelated branches and tags the job must not download.
        git(r, "checkout", "-q", "-b", "side", "HEAD~20")
        git(r, "commit", "-q", "--allow-empty", "-m", "side only")
        self.side = git(r, "rev-parse", "HEAD")
        git(r, "-c", "tag.gpgsign=false", "tag", "unrelated")
        git(r, "checkout", "-q", "main")
        # The job's starting state: a depth-1 checkout of the built commit.
        self.work = self.tmp / "work"
        subprocess.run(["git", "clone", "-q", "--no-local", "--depth", "1", "--no-tags",
                        "--branch", "main", self.remote.as_uri(), str(self.work)], check=True)

    def fetch(self, depth):
        env = {**os.environ, "RELEASE_NOTES_FETCH_DEPTH": str(depth), "RELEASE_NOTES_DEEPEN_STEP": "4"}
        subprocess.run(["bash", str(FETCH), "origin", self.head, "nightly-next"], cwd=self.work,
                       env=env, check=True, capture_output=True, text=True)

    def test_fetches_the_span_and_nothing_else(self):
        self.fetch(depth=3)  # shallower than the span: the script must deepen
        w = str(self.work)
        since = git(w, "rev-parse", "-q", "--verify", "refs/tags/nightly-next^{commit}")
        self.assertEqual(git(w, "rev-list", "--count", f"{since}..{self.head}"), "13")
        self.assertEqual(git(w, "tag", "--list"), "nightly-next")
        # The fetch makes origin a promisor; without this, cat-file would fetch the commit itself.
        missing = subprocess.run(["git", "cat-file", "-e", self.side], cwd=w,
                                 env={**os.environ, "GIT_NO_LAZY_FETCH": "1"}, capture_output=True).returncode
        self.assertNotEqual(missing, 0, "fetched a commit from an unrelated branch")
        out = self.tmp / "notes"
        subprocess.run([sys.executable, str(NOTES), "build", "--build", "1", "--short", "1.0.0-nightly.1",
                        "--date", "2026-10-07", "--head", self.head, "--since", since, "--out", str(out)],
                       cwd=w, check=True, capture_output=True, text=True)
        notes = (out / "1.json").read_text()
        self.assertIn("A card", notes)
        self.assertIn("new 11", notes)
        self.assertNotIn("old 29", notes)

    def test_missing_tag_still_fetches_the_head(self):
        git(str(self.remote), "tag", "-d", "nightly-next")
        self.fetch(depth=5)
        self.assertEqual(git(str(self.work), "tag", "--list"), "")
        git(str(self.work), "cat-file", "-e", self.head)


if __name__ == "__main__":
    unittest.main()
