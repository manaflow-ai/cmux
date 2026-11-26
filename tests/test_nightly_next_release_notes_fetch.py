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
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

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

    def test_every_span_fetch_is_authenticated(self):
        # nightly-next run 45725593921 (2026-11-26): published-in's anonymous fetch got four 403s and
        # posted no PR comments. Each caller passes the job's token to the script.
        for name in ("published-in", "sign-release-notes"):
            block = job_block(name)
            step = block[block.index("fetch-release-notes-span.sh") - 400:block.index("fetch-release-notes-span.sh")]
            self.assertIn("RELEASE_NOTES_FETCH_TOKEN: ${{ github.token }}", step, name)
        text = WORKFLOW.read_text()
        notes = text[text.index("name: Prepare nightly release notes and appcast summaries"):]
        notes = notes[:notes.index("publish-prepare-release-notes.sh")]
        self.assertIn("RELEASE_NOTES_FETCH_TOKEN: ${{ github.token }}", notes)


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

    def test_a_token_authenticates_each_fetch_through_the_environment_only(self):
        real_git = subprocess.run(["bash", "-c", "command -v git"], capture_output=True, text=True, check=True).stdout.strip()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        log = self.tmp / "git.log"
        (bin_dir / "git").write_text(
            "#!/usr/bin/env bash\n"
            f"if [[ \"$1\" == fetch ]]; then {{ echo \"argv: $*\"; env | grep '^GIT_CONFIG_' | sort; }} >> {log}; fi\n"
            f"exec {real_git} \"$@\"\n")
        (bin_dir / "git").chmod(0o755)
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "RELEASE_NOTES_FETCH_DEPTH": "3",
               "RELEASE_NOTES_DEEPEN_STEP": "4", "RELEASE_NOTES_FETCH_TOKEN": "s3cret-token"}
        for key in [k for k in env if k.startswith("GIT_CONFIG_")]:
            del env[key]
        subprocess.run(["bash", str(FETCH), "origin", self.head, "nightly-next"], cwd=self.work,
                       env=env, check=True, capture_output=True, text=True)
        text = log.read_text()
        self.assertIn("GIT_CONFIG_KEY_0=http.https://github.com/.extraheader", text)
        self.assertIn("GIT_CONFIG_VALUE_0=AUTHORIZATION: basic eC1hY2Nlc3MtdG9rZW46czNjcmV0LXRva2Vu", text)
        self.assertNotIn("s3cret-token", "\n".join(l for l in text.splitlines() if l.startswith("argv:")))
        self.assertNotIn("s3cret", (self.work / ".git" / "config").read_text())
        self.assertNotIn("eC1hY2Nlc3M", (self.work / ".git" / "config").read_text())

    def test_missing_tag_still_fetches_the_head(self):
        git(str(self.remote), "tag", "-d", "nightly-next")
        self.fetch(depth=5)
        self.assertEqual(git(str(self.work), "tag", "--list"), "")
        git(str(self.work), "cat-file", "-e", self.head)


class MergedBranchCutShortTests(unittest.TestCase):
    """Build 4485813982701: the span's merge base was fetched, but a branch merged into the span was cut by the
    depth, and its cut commit read as a root that added every highlight file in the tree (425 shipped, 2 real)."""

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
        os.makedirs(self.remote / "release-notes/next/highlights")
        for i in range(5):
            (self.remote / f"release-notes/next/highlights/old-{i}.md").write_text(f"title: Old {i}\n\nBody.\n")
        git(r, "add", ".")
        git(r, "commit", "-q", "-m", "old highlights")
        git(r, "checkout", "-q", "-b", "side")
        for i in range(12):
            git(r, "commit", "-q", "--allow-empty", "-m", f"side {i}")
        (self.remote / "release-notes/next/highlights/fresh.md").write_text("title: Fresh\n\nBody.\n")
        git(r, "add", ".")
        git(r, "commit", "-q", "-m", "a fresh highlight")
        git(r, "checkout", "-q", "main")
        git(r, "commit", "-q", "--allow-empty", "-m", "published")
        self.since = git(r, "rev-parse", "HEAD")
        git(r, "merge", "-q", "--no-ff", "-m", "merge side", "side")
        self.head = git(r, "rev-parse", "HEAD")
        self.work = self.tmp / "work"
        subprocess.run(["git", "clone", "-q", "--no-local", "--depth", "1", "--no-tags",
                        "--branch", "main", self.remote.as_uri(), str(self.work)], check=True)

    def notes(self):
        out = self.tmp / "notes"
        return subprocess.run([sys.executable, str(NOTES), "build", "--build", "1", "--short", "1.0.0-nightly.1",
                               "--date", "2026-11-21", "--head", self.head, "--since", self.since, "--out", str(out)],
                              cwd=self.work, capture_output=True, text=True), out / "1.json"

    def test_the_fetch_deepens_past_a_cut_merged_branch(self):
        env = {**os.environ, "RELEASE_NOTES_FETCH_DEPTH": "4", "RELEASE_NOTES_DEEPEN_STEP": "4"}
        subprocess.run(["bash", str(FETCH), "origin", self.head, "nightly-next", self.since], cwd=self.work,
                       env=env, check=True, capture_output=True, text=True)
        result, path = self.notes()
        self.assertEqual(result.returncode, 0, result.stderr)
        notes = path.read_text()
        self.assertIn("Fresh", notes)
        self.assertNotIn("Old 0", notes)

    def test_build_refuses_a_span_cut_short(self):
        w = str(self.work)
        git(w, "fetch", "-q", "--no-tags", "--filter=blob:none", "--depth=4", "origin", self.head, self.since)
        git(w, "merge-base", self.since, self.head)  # the old check passed here
        result, path = self.notes()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cut short", result.stderr)
        self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
