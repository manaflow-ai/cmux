"""gh-merge-green --revert: one command opens a revert PR for a merged PR and lands it.

The cases run scripts/ci/revert_pr.py against real temporary git repositories and a fake gh
on PATH, so the revert commit, the pushed branch and the PR request are the real ones.
"""
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts/ci/revert_pr.py"
REPO = "o/r"

FAKE_GH = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, sys
    state_path = os.environ["FAKE_GH_STATE"]
    state = json.load(open(state_path))
    state["calls"].append(sys.argv[1:])
    json.dump(state, open(state_path, "w"))
    args = sys.argv[1:]
    if args[:2] == ["pr", "view"]:
        print(json.dumps(state["pr"]))
    elif args[:2] == ["pr", "list"]:
        print(json.dumps(state["open_reverts"]))
    elif args[:2] == ["pr", "create"]:
        print("https://github.com/o/r/pull/99")
    elif args[:2] == ["pr", "checks"]:
        pass
    else:
        sys.exit("fake gh: unexpected " + " ".join(args))
    ''')


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class RevertTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.origin = self.tmp / "origin.git"
        git(self.tmp, "init", "-q", "--bare", "-b", "main", str(self.origin))
        self.checkout = self.tmp / "checkout"
        git(self.tmp, "clone", "-q", str(self.origin), str(self.checkout))
        for key, value in (("user.name", "T"), ("user.email", "t@example.com")):
            git(self.checkout, "config", key, value)
        self.commit("a.txt", "one\n", "base")
        self.merged = self.commit("a.txt", "two\n", "fix: a nit (#7)")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(FAKE_GH)
        (bin_dir / "gh").chmod(0o755)
        self.merge_log = self.tmp / "merge.log"
        merge = bin_dir / "merge"
        merge.write_text(f"#!/bin/sh\necho \"$@\" >> {self.merge_log}\n")
        merge.chmod(0o755)
        self.state = self.tmp / "gh.json"
        self.write_state(state="MERGED", open_reverts=[])
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_GH_STATE=str(self.state),
                        GH_REVERT_MERGE_CMD=str(merge), GIT_AUTHOR_NAME="T", GIT_AUTHOR_EMAIL="t@example.com",
                        GIT_COMMITTER_NAME="T", GIT_COMMITTER_EMAIL="t@example.com")

    def commit(self, name, text, message):
        (self.checkout / name).write_text(text)
        git(self.checkout, "add", name)
        git(self.checkout, "commit", "-q", "-m", message)
        git(self.checkout, "push", "-q", "origin", "main")
        return git(self.checkout, "rev-parse", "HEAD")

    def write_state(self, state, open_reverts):
        pr = {"number": 7, "state": state, "title": "fix: a nit", "baseRefName": "main",
              "mergeCommit": {"oid": self.merged} if state == "MERGED" else None,
              "body": "## Summary\n\nA nit.\n\n## Changelog\n\nFixed: the nit.\n"}
        self.state.write_text(json.dumps({"pr": pr, "open_reverts": open_reverts, "calls": []}))

    def run_tool(self, *extra):
        return subprocess.run([sys.executable, str(TOOL), f"{REPO}#7", "--checkout", str(self.checkout), *extra],
                              env=self.env, capture_output=True, text=True)

    def calls(self):
        return json.loads(self.state.read_text())["calls"]

    def test_a_merged_pr_gets_a_revert_pr_that_lands_through_gh_merge_green(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        tip = git(self.origin, "rev-parse", "refs/heads/revert/pr-7")
        self.assertEqual(git(self.origin, "show", f"{tip}:a.txt"), "one")
        self.assertEqual(git(self.origin, "rev-parse", f"{tip}^"), git(self.origin, "rev-parse", "main"))
        message = git(self.origin, "log", "-1", "--format=%B", tip)
        self.assertIn('Revert "fix: a nit" (#7)', message)
        self.assertIn(f"This reverts commit {self.merged}.", message)
        create = next(c for c in self.calls() if c[:2] == ["pr", "create"])
        self.assertEqual(create[create.index("--base") + 1], "main")
        self.assertEqual(create[create.index("--head") + 1], "revert/pr-7")
        body = create[create.index("--body") + 1]
        self.assertIn("Reverts #7", body)
        self.assertIn("## Changelog", body)
        self.assertEqual(self.merge_log.read_text().split(), [f"{REPO}#99"])

    def test_an_unmerged_pr_is_refused(self):
        self.write_state(state="OPEN", open_reverts=[])
        result = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not merged", result.stderr)
        self.assertEqual(git(self.origin, "branch", "--list", "revert/pr-7"), "")
        self.assertFalse(self.merge_log.exists())

    def test_a_conflicting_revert_names_the_files_and_pushes_nothing(self):
        self.commit("a.txt", "three\n", "later change")
        result = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("a.txt", result.stderr)
        self.assertEqual(git(self.origin, "branch", "--list", "revert/pr-7"), "")
        self.assertFalse(any(c[:2] == ["pr", "create"] for c in self.calls()))
        self.assertEqual(git(self.checkout, "status", "--porcelain"), "")

    def test_an_open_revert_pr_is_landed_instead_of_a_second_one(self):
        self.write_state(state="MERGED", open_reverts=[{"number": 42}])
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[:2] == ["pr", "create"] for c in self.calls()))
        self.assertEqual(self.merge_log.read_text().split(), [f"{REPO}#42"])

    def test_gh_merge_green_revert_runs_the_revert_tool(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/gh-merge-green"), "--revert", "--help"],
                                env=dict(os.environ, GH_MERGE_GREEN_NO_AUTO_UPDATE="1"), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("revert", result.stdout.lower())
        self.assertIn("OWNER/REPO#NUMBER", result.stdout)


if __name__ == "__main__":
    unittest.main()
