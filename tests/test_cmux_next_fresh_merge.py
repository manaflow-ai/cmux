#!/usr/bin/env python3
"""scripts/cmux-next/fresh-merge.py merges a Swift or Rust PR only once it is fresh.

Fresh: feat-cmux-next has no Swift (or Rust) change the head has not merged.
A stale head gets the tip merged in and pushed, and merges only after the
Swift canary (or the --check command) passes on that merged head. Runs against
a local bare origin and a fake gh that serves pull request state and the
canary result, and records merges: the test never reaches GitHub.

The fake gh can lag like GitHub does after a push: for state["lag"] reads it
keeps showing the head it showed last (state["shown"]). A fake glaeda-gh and a
git wrapper that fails a fetch the way a racing worktree does cover
--wait-checks and the fetch retry.
"""
import json
import os
import shutil
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
    if state.get("moved_to") and head not in state["checks"]:  # someone else pushed after the script did
        head = state["moved_to"]
    if state.get("shown") and head != state["shown"] and state.get("lag", 0) > 0:
        state["lag"] -= 1  # GitHub has not caught up with the push yet
        head = state["shown"]
    state["shown"] = head
    open(%(state)r, "w").write(json.dumps(state))
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

FAKE_GLAEDA = """#!/usr/bin/env python3
import json, sys
open(%(log)r, "a").write(json.dumps(["glaeda-gh", *sys.argv[1:]]) + "\\n")
"""

# Fails the first fetch the way a fetch racing another worktree's does.
RACY_GIT = """#!/bin/sh
if [ "$1" = fetch ] && [ ! -e %(marker)s ]; then
  : > %(marker)s
  echo "error: cannot lock ref 'refs/remotes/origin/lane/pr': incorrect old value provided" >&2
  exit 1
fi
exec %(git)s "$@"
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
        glaeda = bin_dir / "glaeda-gh"
        glaeda.write_text(FAKE_GLAEDA % {"log": str(self.log)})
        glaeda.chmod(0o755)
        self.bin_dir = bin_dir
        self.env.update(PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}", FRESH_MERGE_POLL_SECONDS="0",
                        FRESH_MERGE_GRACE_SECONDS="0", FRESH_MERGE_HEAD_POLL_SECONDS="0",
                        FRESH_MERGE_FETCH_RETRY_SECONDS="0")

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

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def merges(self):
        return [call for call in self.calls() if call[:2] == ["pr", "merge"]]

    def glaeda_waits(self):
        return [call for call in self.calls() if call[:1] == ["glaeda-gh"]]

    def update_state(self, **changes):
        state = json.loads(self.state.read_text())
        state.update(changes)
        self.state.write_text(json.dumps(state))

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

    def test_github_head_lag_after_its_push_is_waited_out(self):
        # #20725, #20388, #20779: GitHub showed the old head right after the push.
        head = self.open_pull_request("App/B.swift")
        self.advance_base("App/C.swift")
        self.update_state(shown=head, lag=3)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        fresh = self.branch_head()
        self.assertNotEqual(fresh, head)
        self.assertEqual(len(self.merges()), 1)
        self.assertIn(fresh, self.merges()[0])

    def test_head_lag_that_never_clears_times_out_without_merging(self):
        head = self.open_pull_request("App/B.swift")
        self.advance_base("App/C.swift")
        self.update_state(shown=head, lag=10_000)
        self.env["FRESH_MERGE_HEAD_SECONDS"] = "0"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.merges(), [])
        self.assertIn("still shows", result.stderr)
        self.assertNotIn("moved", result.stderr)

    def test_a_third_head_while_waiting_is_a_move(self):
        self.open_pull_request("App/B.swift")
        self.advance_base("App/C.swift")
        self.update_state(moved_to="f" * 40)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.merges(), [])
        self.assertIn("moved to ffffffffffff", result.stderr)

    def test_branch_ahead_of_github_waits_for_github_to_catch_up(self):
        head = self.open_pull_request("App/B.swift")
        self.update_state(shown=head, lag=2)
        git(self.work, "checkout", "-q", "lane/pr")
        newer = self.commit("App/D.swift", "pr\n")
        git(self.work, "push", "-q", "origin", "lane/pr")
        git(self.work, "checkout", "-q", "feat-cmux-next")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.merges()), 1)
        self.assertIn(newer, self.merges()[0])

    def test_fetch_racing_another_worktree_is_retried(self):
        head = self.open_pull_request("App/B.swift")
        racy = self.bin_dir / "git"
        racy.write_text(RACY_GIT % {"marker": str(Path(self.temporary.name) / "raced"),
                                    "git": shutil.which("git")})
        racy.chmod(0o755)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((Path(self.temporary.name) / "raced").exists())
        self.assertIn(head, self.merges()[0])

    def checks_on(self, head, *checks):
        state = json.loads(self.state.read_text())
        state["checks"][head] = [{"__typename": "CheckRun", "status": "COMPLETED", **check} for check in checks]
        self.state.write_text(json.dumps(state))

    def test_wait_checks_refuses_a_red_check_on_the_head(self):
        head = self.open_pull_request("docs/c.md")
        self.checks_on(head, {"name": "react-apps-check", "workflowName": "cmux-next", "conclusion": "FAILURE"},
                       {"name": "Tour the app", "workflowName": "cmux-next media", "conclusion": "FAILURE"})
        result = self.run_script("--wait-checks")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.merges(), [])
        self.assertIn("react-apps-check", result.stderr)
        self.assertNotIn("Tour the app", result.stderr)
        self.assertEqual(len(self.glaeda_waits()), 1)

    def test_wait_checks_merges_when_only_waived_checks_are_red(self):
        head = self.open_pull_request("docs/c.md")
        self.checks_on(head,
                       {"name": "cmux-next swift test (macOS 27, report-only)", "workflowName": "cmux-next",
                        "conclusion": "FAILURE"},
                       {"name": "Tour the app", "workflowName": "cmux-next media", "conclusion": "FAILURE"},
                       {"name": "action export areas", "workflowName": "cmux-next PR autofix",
                        "conclusion": "CANCELLED"},
                       {"name": "Vercel Agent Review", "conclusion": "NEUTRAL"},
                       {"name": "react-apps-check", "workflowName": "cmux-next", "conclusion": "SUCCESS"})
        result = self.run_script("--wait-checks")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(head, self.merges()[0])
        wait = self.glaeda_waits()[0]
        self.assertEqual(wait[1:6], ["wait", "pr", "manaflow-ai/cmux#7", "--until", "done"])
        self.assertEqual(wait[wait.index("--sha") + 1], head)

    def test_a_cancelled_gate_check_still_blocks_wait_checks(self):
        head = self.open_pull_request("docs/c.md")
        self.checks_on(head, {"name": "cmux-next checks (god files, concurrency, crash safety, l10n)",
                              "workflowName": "cmux-next", "conclusion": "CANCELLED"})
        result = self.run_script("--wait-checks")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.merges(), [])

    def assert_wait_checks_refuses(self, checks):
        head = self.open_pull_request("docs/c.md")
        state = json.loads(self.state.read_text())
        state["checks"][head] = checks
        self.state.write_text(json.dumps(state))
        result = self.run_script("--wait-checks")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.merges(), [])

    def test_wait_checks_refuses_a_check_still_running(self):
        self.assert_wait_checks_refuses([{"__typename": "CheckRun", "name": "react-apps-check",
                                          "workflowName": "cmux-next", "status": "IN_PROGRESS", "conclusion": ""}])

    def test_wait_checks_refuses_a_pending_status_context(self):
        self.assert_wait_checks_refuses([{"__typename": "StatusContext", "context": "vercel", "state": "PENDING"}])

    def test_wait_checks_waives_only_whole_word_bot_jobs(self):
        self.assert_wait_checks_refuses([{"__typename": "CheckRun", "name": "Build both architectures",
                                          "workflowName": "cmux-next", "status": "COMPLETED",
                                          "conclusion": "CANCELLED"}])

    def test_wait_checks_refuses_a_head_with_no_checks(self):
        self.assert_wait_checks_refuses([])

    def test_without_wait_checks_it_never_calls_glaeda(self):
        self.open_pull_request("docs/c.md")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.glaeda_waits(), [])


if __name__ == "__main__":
    unittest.main()
