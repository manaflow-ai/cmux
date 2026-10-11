#!/usr/bin/env python3
"""scripts/cmux-next/fresh-merge.py merges a Swift or Rust PR only once it is fresh.

Fresh: feat-cmux-next has no Swift (or Rust) change the head has not merged.
A stale head gets the tip merged in and pushed, and merges only after the
Swift canary (or the --check command) passes on that merged head. Runs against
a local bare origin and a fake gh that serves pull request state and the
canary result, and records merges: the test never reaches GitHub.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/fresh-merge.py"

FAKE_GH = """#!/usr/bin/env python3
import json, subprocess, sys
state = json.loads(open(%(state)r).read())
args = sys.argv[1:]
open(%(log)r, "a").write(json.dumps(args) + "\\n")
if args[:2] == ["pr", "view"]:
    head = subprocess.run(["git", "-C", %(origin)r, "rev-parse", "refs/heads/" + state["branch"]],
                          capture_output=True, text=True, check=True).stdout.strip()
    checks = state["checks"].get(head)
    if checks is None:  # a head pushed during the test: CI reports the configured canary result
        checks = [{"__typename": "CheckRun", "name": "cmux-next Swift canary", "status": "COMPLETED",
                   "conclusion": state["canary"]}]
    print(json.dumps({"number": 7, "headRefOid": head, "headRefName": state["branch"],
                      "baseRefName": "feat-cmux-next", "isCrossRepository": False,
                      "mergeable": "MERGEABLE", "files": [{"path": p} for p in state["files"]],
                      "statusCheckRollup": checks}))
elif args[:2] == ["pr", "merge"]:
    pass
else:
    sys.exit("unexpected gh call: %%r" %% args)
"""


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True).stdout.strip()


class FreshMergeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-fresh-merge-")
        root = Path(self.temporary.name)
        self.origin, self.work, bin_dir = root / "origin.git", root / "work", root / "bin"
        self.state, self.log = root / "state.json", root / "gh.log"
        bin_dir.mkdir()
        subprocess.run(["git", "init", "-q", "--bare", "-b", "feat-cmux-next", str(self.origin)], check=True)
        subprocess.run(["git", "clone", "-q", str(self.origin), str(self.work)], check=True,
                       capture_output=True)
        git(self.work, "config", "user.email", "t@example.com")
        git(self.work, "config", "user.name", "t")
        git(self.work, "config", "core.hooksPath", "/dev/null")
        git(self.work, "checkout", "-q", "-b", "feat-cmux-next")
        self.commit("App/A.swift", "a\n")
        self.commit("docs/a.md", "a\n")
        git(self.work, "push", "-q", "origin", "feat-cmux-next")
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH % {"state": str(self.state), "log": str(self.log), "origin": str(self.origin)})
        gh.chmod(0o755)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}", FRESH_MERGE_POLL_SECONDS="0",
                        FRESH_MERGE_GRACE_SECONDS="0")

    def tearDown(self):
        self.temporary.cleanup()

    def commit(self, path, text):
        target = self.work / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        git(self.work, "add", path)
        git(self.work, "commit", "-q", "-m", f"change {path}")
        return git(self.work, "rev-parse", "HEAD")

    def open_pull_request(self, path, canary="SUCCESS"):
        git(self.work, "checkout", "-q", "-b", "lane/pr", "origin/feat-cmux-next")
        head = self.commit(path, "pr\n")
        git(self.work, "push", "-q", "origin", "lane/pr")
        git(self.work, "checkout", "-q", "feat-cmux-next")
        self.state.write_text(json.dumps({"branch": "lane/pr", "files": [path], "canary": canary, "checks": {
            head: [{"__typename": "CheckRun", "name": "cmux-next Swift canary", "status": "COMPLETED",
                    "conclusion": "SUCCESS"}]}}))
        return head

    def advance_base(self, path):
        git(self.work, "checkout", "-q", "feat-cmux-next")
        self.commit(path, "base\n")
        git(self.work, "push", "-q", "origin", "feat-cmux-next")

    def run_script(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), "7", *args], cwd=self.work, env=self.env,
                              capture_output=True, text=True, timeout=120)

    def merges(self):
        if not self.log.exists():
            return []
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [call for call in calls if call[:2] == ["pr", "merge"]]

    def branch_head(self):
        return git(self.origin, "rev-parse", "refs/heads/lane/pr")

    def test_swift_head_is_fresh_when_the_tip_changed_no_swift(self):
        head = self.open_pull_request("App/B.swift")
        self.advance_base("docs/b.md")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.branch_head(), head)  # nothing pushed
        self.assertEqual(len(self.merges()), 1)
        self.assertIn(head, self.merges()[0])
        self.assertIn("--squash", self.merges()[0])

    def test_stale_swift_head_merges_the_tip_and_waits_for_the_canary(self):
        head = self.open_pull_request("App/B.swift")
        self.advance_base("App/C.swift")
        tip = git(self.origin, "rev-parse", "refs/heads/feat-cmux-next")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        fresh = self.branch_head()
        self.assertNotEqual(fresh, head)
        self.assertEqual(git(self.origin, "rev-parse", f"{fresh}^1"), head)
        self.assertEqual(git(self.origin, "rev-parse", f"{fresh}^2"), tip)
        self.assertEqual(len(self.merges()), 1)
        self.assertIn(fresh, self.merges()[0])

    def test_red_canary_on_the_merged_head_does_not_merge(self):
        self.open_pull_request("App/B.swift", canary="FAILURE")
        self.advance_base("App/C.swift")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.merges(), [])
        self.assertIn(self.branch_head()[:12], result.stdout + result.stderr)

    def test_stale_rust_head_needs_a_check_on_the_merged_head(self):
        head = self.open_pull_request("cmux-tui/crates/a/src/lib.rs")
        self.advance_base("cmux-tui/crates/b/src/lib.rs")
        result = self.run_script()
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(self.merges(), [])
        fresh = self.branch_head()
        self.assertNotEqual(fresh, head)
        self.assertIn(fresh[:12], result.stdout + result.stderr)

        marker = Path(self.temporary.name) / "checked"
        result = self.run_script("--check", f'echo "$FRESH_SHA" > {marker}')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(marker.read_text().strip(), fresh)
        self.assertEqual(self.branch_head(), fresh)  # already fresh: no second base merge
        self.assertIn(fresh, self.merges()[0])

    def test_pull_request_without_swift_or_rust_merges_as_is(self):
        head = self.open_pull_request("docs/c.md")
        self.advance_base("App/C.swift")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.branch_head(), head)
        self.assertIn(head, self.merges()[0])


if __name__ == "__main__":
    unittest.main()
