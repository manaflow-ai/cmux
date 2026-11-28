#!/usr/bin/env python3
"""fixit-handoff (scripts/ci/oops/fixit_handoff.py): a base or nightly type check red with no machine fix finds its
culprit, checks the revert on the tip, and pushes it directly when clear, else opens the revert's own pull request.
A temporary git history and a fake type check (`! grep -rq BROKEN .`); no network.

Run: python3 -I tests/test_ci_fixit_handoff.py"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci" / "oops"))
import fixit_handoff as fh  # noqa: E402

FAKE_CHECK = "! grep -rq BROKEN ."
ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@example.com"}


def git(cwd: Path, *argv: str) -> str:
    return subprocess.run(["git", *argv], cwd=cwd, check=True, capture_output=True, text=True, env=ENV).stdout.strip()


class History:
    """A repository with webviews/ files, one commit per (path, text, subject)."""

    def __init__(self, root: Path):
        self.repo = root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "feat-cmux-next")
        (self.repo / "webviews").mkdir()
        self.shas: list[str] = []
        self.commit("webviews/a.ts", "ok\n", "start")

    def commit(self, path: str, text: str, subject: str) -> str:
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", subject)
        self.shas.append(git(self.repo, "rev-parse", "HEAD"))
        return self.shas[-1]


class FakeApi:
    def __init__(self, author: str = "someone", commit_author: str | None = "someone"):
        self.calls: list[tuple[str, str, dict | None]] = []
        self.author = author
        self.commit_author = commit_author

    def __call__(self, path, *, method="GET", fields=None, tokens=None, **_):
        self.calls.append((method, path, fields))
        if path.endswith("/rules/branches/feat-cmux-next"):
            return [{"type": "pull_request", "ruleset_id": 7}, {"type": "non_fast_forward", "ruleset_id": 7}]
        if path.endswith("/rulesets/7"):
            return {"name": "feat-cmux-next protection"}
        if "/pulls?state=open" in path:
            return []
        if method == "GET" and "/pulls/" in path:
            return {"user": {"login": self.author}}
        if method == "GET" and "/commits/" in path:
            if self.commit_author == "unreadable":
                raise RuntimeError("HTTP 502")
            return {"author": {"login": self.commit_author} if self.commit_author else None,
                    "committer": {"login": "web-flow"}}
        if method == "POST" and path.endswith("/pulls"):
            return {"html_url": "https://github.com/o/r/pull/9"}
        return None


class FindTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.h = History(Path(self.tmp.name))
        for i in range(5):
            self.h.commit(f"webviews/g{i}.ts", "fine\n", f"green {i} (#{100 + i})")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def find(self, red: str | None = None, max_back: int = 64) -> dict:
        tip = self.h.shas[-1]
        return fh.find(self.h.repo, tip, red or tip, "webviews", FAKE_CHECK, max_back)

    def test_green_tip_does_nothing(self) -> None:
        got = self.find()
        self.assertEqual(got["culprit"], "")
        self.assertIn("already fixed", got["reason"])

    def test_names_the_first_red_and_verifies_the_revert(self) -> None:
        culprit = self.h.commit("webviews/turns.ts", "BROKEN foldsPrompt\n", "Agent chat: header (#49052)")
        red = self.h.commit("webviews/b.ts", "fine\n", "later (#49060)")
        for i in range(6):
            self.h.commit(f"webviews/l{i}.ts", "fine\n", f"later {i} (#{49100 + i})")
        got = self.find(red=red)
        self.assertEqual(got["culprit"], culprit)
        self.assertEqual(got["good"], self.h.shas[self.h.shas.index(culprit) - 1])
        self.assertEqual(got["pr"], "49052")
        self.assertEqual((got["clear"], got["verified"], got["applies"]), ("true", "true", "true"))

    def test_a_red_commit_not_on_the_branch_starts_from_the_tip(self) -> None:
        culprit = self.h.commit("webviews/turns.ts", "BROKEN\n", "breaks (#1)")
        self.h.commit("webviews/c.ts", "fine\n", "later (#2)")
        got = self.find(red=self.h.shas[0])  # a reported red that checks green here: the tip is used
        self.assertEqual(got["culprit"], culprit)

    def test_a_revert_that_conflicts_is_not_clear(self) -> None:
        culprit = self.h.commit("webviews/turns.ts", "BROKEN\n", "breaks (#1)")
        self.h.commit("webviews/turns.ts", "BROKEN twice\n", "edits the same line (#2)")
        got = self.find()
        self.assertEqual(got["culprit"], culprit)
        self.assertEqual((got["clear"], got["applies"]), ("false", "false"))
        self.assertIn("conflicts", got["reason"])

    def test_a_second_break_leaves_the_revert_red(self) -> None:
        culprit = self.h.commit("webviews/one.ts", "BROKEN\n", "breaks (#1)")
        self.h.commit("webviews/two.ts", "BROKEN\n", "breaks too (#2)")
        got = self.find()
        self.assertEqual(got["culprit"], culprit)
        self.assertEqual((got["clear"], got["verified"]), ("false", "false"))

    def test_no_green_within_max_back(self) -> None:
        self.h.commit("webviews/one.ts", "BROKEN\n", "breaks (#1)")
        for i in range(4):
            self.h.commit(f"webviews/x{i}.ts", "fine\n", f"x {i}")
        got = self.find(max_back=3)
        self.assertEqual(got["culprit"], "")
        self.assertIn("no green", got["reason"])

    def test_a_setup_that_cannot_run_names_no_culprit(self) -> None:
        """A failed install (a download) is not a red type check: no culprit, nothing clear, nothing reverted."""
        self.h.commit("webviews/turns.ts", "BROKEN\n", "Agent chat: header (#49052)")
        self.h.commit("webviews/b.ts", "fine\n", "later (#49060)")
        tip = self.h.shas[-1]
        flaky = "exit 1"  # a setup that never succeeds (a download that keeps failing)
        got = fh.find(self.h.repo, tip, tip, "webviews", FAKE_CHECK, 64, setup=flaky)
        self.assertEqual(got["culprit"], "")
        self.assertEqual(got["clear"], "false")
        self.assertIn("could not run", got["reason"])

    def test_a_setup_that_fails_once_is_retried(self) -> None:
        culprit = self.h.commit("webviews/turns.ts", "BROKEN\n", "Agent chat: header (#49052)")
        self.h.commit("webviews/b.ts", "fine\n", "later (#49060)")
        tip = self.h.shas[-1]
        marker = Path(self.tmp.name) / "setup-ran"
        once = f"test -e {marker} && exit 0; touch {marker}; exit 1"  # the first setup fails, every later one passes
        got = fh.find(self.h.repo, tip, tip, "webviews", FAKE_CHECK, 64, setup=once)
        self.assertEqual(got["culprit"], culprit)
        self.assertEqual(got["clear"], "true")

    def test_off_switch(self) -> None:
        self.h.commit("webviews/one.ts", "BROKEN\n", "breaks (#1)")
        out = Path(self.tmp.name) / "out"
        with mock.patch.dict(os.environ, {"FIXIT_HANDOFF": "0"}):
            fh.main(["find", "--repo-dir", str(self.h.repo), "--github-output", str(out), "--check-cmd", FAKE_CHECK])
        self.assertEqual(out.read_text(), "culprit=\n")


class LandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.h = History(root)
        self.h.commit("webviews/g.ts", "fine\n", "green (#10)")
        self.culprit = self.h.commit("webviews/turns.ts", "BROKEN\n", "Agent chat: header (#49052)")
        self.tip = self.h.commit("webviews/b.ts", "fine\n", "later (#49060)")
        self.remote = root / "remote.git"
        git(root, "clone", "-q", "--bare", str(self.h.repo), str(self.remote))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def args(self, **over) -> Namespace:
        base = dict(repo="o/r", repo_dir=str(self.h.repo), branch="feat-cmux-next", check="webviews",
                    culprit=self.culprit, tip=self.tip, good=self.h.shas[1], clear="true", verified="true",
                    reason="its revert on the tip is green", origin="https://example/run/1", push_url=str(self.remote),
                    github_output=None, summary=None)
        base.update(over)
        return Namespace(**base)

    def land(self, api: FakeApi, **over) -> dict:
        pushed: list[str] = []

        def start(repo, branch, sha):
            pushed.append(f"start {branch} {sha[:7]}")

        def push_branch(url, refspec):
            pushed.append(refspec)
            subprocess.run(["git", "push", "-q", url, refspec], cwd=self.h.repo, check=True, capture_output=True)

        out = fh.land(self.args(**over), api=api, start=start, push_branch=push_branch)
        out["_branch_calls"] = pushed
        return out

    def remote_head(self, ref: str = "feat-cmux-next") -> str:
        return git(self.remote, "rev-parse", ref)

    def test_clear_fix_is_pushed_directly(self) -> None:
        api = FakeApi()
        with mock.patch.dict(os.environ, {"FIXIT_HANDOFF": "1"}):
            out = self.land(api)
        self.assertEqual(out["action"], "pushed")
        self.assertEqual(self.remote_head(), out["pushed"])
        self.assertEqual(git(self.remote, "rev-parse", "feat-cmux-next^"), self.tip)
        self.assertFalse((self.h.repo / "webviews/turns.ts").exists())
        self.assertIn("fixit-handoff", git(self.remote, "log", "-1", "--format=%B", "feat-cmux-next"))
        self.assertFalse(any(m == "POST" for m, _, _ in api.calls))

    def test_ruleset_refusal_is_quoted_then_a_pr_opens(self) -> None:
        hook = self.remote / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\ngrep -q ' refs/heads/feat-cmux-next$' || exit 0\n"
                        "echo 'error: GH013: Repository rule violations found for refs/heads/feat-cmux-next.' >&2\n"
                        "echo '- Changes must be made through a pull request.' >&2\nexit 1\n")
        hook.chmod(0o755)
        api = FakeApi()
        with mock.patch.dict(os.environ, {"FIXIT_HANDOFF": "1"}):
            out = self.land(api)
        self.assertEqual(out["action"], "pr")
        self.assertIn("GH013", out["refusal"])
        self.assertIn("feat-cmux-next protection (ruleset 7: non_fast_forward, pull_request)", out["refusal"])
        self.assertEqual(self.remote_head(), self.tip)  # the branch is untouched; no second push to it
        posts = [f for m, p, f in api.calls if m == "POST"]
        self.assertEqual(posts[0]["head"], "revert/pr-49052")
        self.assertIn("GH013", posts[0]["body"])
        self.assertEqual(out["_branch_calls"], [f"start revert/pr-49052 {self.tip[:7]}",
                                                "+HEAD:refs/heads/revert/pr-49052"])

    def test_teammate_culprit_opens_a_held_pr(self) -> None:
        api = FakeApi(author="lawrencecchen")
        with mock.patch.dict(os.environ, {"FIXIT_HANDOFF": "1"}):
            out = self.land(api)
        self.assertEqual(out["action"], "held")
        self.assertEqual(self.remote_head(), self.tip)
        body = [f for m, p, f in api.calls if m == "POST"][0]["body"]
        self.assertTrue(body.startswith("HOLD: lawrencecchen's merge."))

    def no_pr_culprit(self) -> None:
        """A culprit pushed straight to the branch: no `(#N)` in its subject."""
        git(self.h.repo, "checkout", "-q", self.h.shas[1])
        self.culprit = self.h.commit("webviews/turns.ts", "BROKEN\n", "Agent chat: header straight to the branch")
        self.tip = self.h.commit("webviews/b.ts", "fine\n", "later (#49060)")
        git(self.h.repo, "branch", "-f", "feat-cmux-next", self.tip)
        git(self.h.repo, "checkout", "-q", "feat-cmux-next")
        git(self.h.repo, "push", "-q", "--force", str(self.remote), "feat-cmux-next")

    def test_a_teammate_commit_without_a_pr_opens_a_held_pr(self) -> None:
        self.no_pr_culprit()
        api = FakeApi(commit_author="lawrencecchen")
        with mock.patch.dict(os.environ, {"FIXIT_HANDOFF": "1"}):
            out = self.land(api)
        self.assertEqual(out["action"], "held")
        self.assertEqual(self.remote_head(), self.tip)
        self.assertIn(("GET", f"repos/o/r/commits/{self.culprit}", None), api.calls)
        body = [f for m, p, f in api.calls if m == "POST"][0]["body"]
        self.assertTrue(body.startswith("HOLD: lawrencecchen's merge."))

    def test_an_unknown_or_unread_author_without_a_pr_is_held(self) -> None:
        self.no_pr_culprit()
        for commit_author in (None, "unreadable"):
            with self.subTest(commit_author=commit_author), mock.patch.dict(os.environ, {"FIXIT_HANDOFF": "1"}):
                out = self.land(FakeApi(commit_author=commit_author))
                self.assertEqual(out["action"], "held")
                self.assertEqual(self.remote_head(), self.tip)
                git(self.h.repo, "checkout", "-q", "--force", "feat-cmux-next")

    def test_an_outside_commit_without_a_pr_is_pushed(self) -> None:
        self.no_pr_culprit()
        with mock.patch.dict(os.environ, {"FIXIT_HANDOFF": "1"}):
            out = self.land(FakeApi(commit_author="someone"))
        self.assertEqual(out["action"], "pushed")

    def test_not_clear_opens_a_pr(self) -> None:
        api = FakeApi()
        out = self.land(api, clear="false", verified="false", reason="still red with it reverted")
        self.assertEqual(out["action"], "pr")
        self.assertEqual(self.remote_head(), self.tip)
        self.assertIn("look before landing", [f for m, p, f in api.calls if m == "POST"][0]["body"])

    def test_pr_mode_never_pushes_the_branch(self) -> None:
        with mock.patch.dict(os.environ, {"FIXIT_HANDOFF": "pr"}):
            out = self.land(FakeApi())
        self.assertEqual(out["action"], "pr")
        self.assertEqual(self.remote_head(), self.tip)

    def test_off_does_nothing(self) -> None:
        api = FakeApi()
        with mock.patch.dict(os.environ, {"FIXIT_HANDOFF": "0"}):
            out = self.land(api)
        self.assertEqual(out["action"], "none")
        self.assertEqual(api.calls, [])

    def test_an_open_revert_is_not_opened_twice(self) -> None:
        api = FakeApi()
        api_calls = api.__call__

        def existing(path, **kw):
            if "/pulls?state=open" in path:
                return [{"html_url": "https://github.com/o/r/pull/5"}]
            return api_calls(path, **kw)

        out = fh.land(self.args(), api=existing)
        self.assertEqual(out["action"], "exists")
        self.assertEqual(self.remote_head(), self.tip)


class RecordTest(unittest.TestCase):
    def test_fixit_compile_writes_the_record_and_signal_reads_it(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git_root = root / "w"
            git_root.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=git_root, check=True)
            cmd = ["sh", "-c", "echo 'src/a.ts(1,1): error TS2304: Cannot find name foldsPrompt.'; exit 2"]
            env = {**os.environ, "FIXIT_HANDOFF_OUT": str(root / "handoff"), "FIXIT_COMPILE_TS_RUNNER": "false",
                   "FIXIT_COMPILE_OUT": str(root / "patches")}
            got = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/oops/fixit_compile.py"), "run",
                                  "--kind", "tsc", "--name", "tc", "--", *cmd], cwd=git_root, env=env,
                                 capture_output=True, text=True)
            self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
            record = json.loads((root / "handoff" / "tc.json").read_text())
            self.assertEqual((record["fixer"], record["kind"], record["errors"]), ("fixit-handoff", "tsc", 1))
            self.assertFalse((root / "patches").exists())
            sig = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/oops/fixit_handoff.py"), "signal",
                                  "--dir", str(root / "handoff")], capture_output=True, text=True)
            self.assertEqual(sig.stdout.strip(), "nofix=true")
            sig = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/oops/fixit_handoff.py"), "signal",
                                  "--dir", str(root / "none")], capture_output=True, text=True)
            self.assertEqual(sig.stdout.strip(), "nofix=false")


class WorkflowTest(unittest.TestCase):
    """The type check jobs stay read-only; only the hand-off's land job holds a write token, behind the kill switch."""

    def load(self, name: str) -> dict:
        return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())

    def test_handoff_workflow(self) -> None:
        wf = self.load(fh.WORKFLOW)
        jobs = wf["jobs"]
        self.assertEqual(jobs["find"]["permissions"], {"contents": "read"})
        self.assertNotIn("environment", jobs["find"])
        self.assertIn("(vars.FIXIT_HANDOFF || '1') != '0'", jobs["find"]["if"])
        self.assertEqual(jobs["land"]["environment"], "ci-routing-agent")
        self.assertIn("GLAEDA_ROUTE_APP_KEY", json.dumps(jobs["land"]))
        self.assertIn("feat-cmux-next", jobs["land"]["if"])

    def test_callers_dispatch_from_a_job_of_their_own(self) -> None:
        for name, check_jobs in (("nightly.yml", ("check-nightly-webviews", "nightly-next-one")),):
            jobs = self.load(name)["jobs"]
            dispatch = jobs["fixit-handoff"]
            self.assertEqual(dispatch["permissions"], {"actions": "write"})
            self.assertIn("(vars.FIXIT_HANDOFF || '1') != '0'", dispatch["if"])
            self.assertIn(fh.WORKFLOW, json.dumps(dispatch["steps"]))
            for job in check_jobs:
                self.assertIn("fixit_nofix", jobs[job]["outputs"])
            self.assertEqual(jobs["check-nightly-webviews"]["permissions"], {"contents": "read"})
        post = self.load("cmux-next-post-merge.yml")["jobs"]["fixit-handoff"]
        self.assertEqual(post["permissions"], {"actions": "write"})
        self.assertIn("(vars.FIXIT_HANDOFF || '1') != '0'", post["if"])
        web = self.load("ci-web.yml")
        self.assertIn("fixit_nofix", (web.get("on") or web[True])["workflow_call"]["outputs"])
        for job in ("web-typecheck", "webviews-typecheck"):
            self.assertIn("fixit_nofix", web["jobs"][job]["outputs"])


if __name__ == "__main__":
    unittest.main()
