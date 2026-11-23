#!/usr/bin/env python3
"""The per-run workflow_run handlers spend as few GitHub API calls as they can (no network).

Every workflow in manaflow-ai/cmux shares one GITHUB_TOKEN budget. On
2026-10-06 it ran out ("API rate limit exceeded for installation") and the
required CLA and migration checks failed on every pull request. The handlers
that run on every CI, fast guard and CLA run now read what the event already
carries, read in the order that lets most runs stop after the first call, and
start no job when there is nothing to do. These cases pin the calls each makes.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import classify_failures as cf  # noqa: E402
import guard_attribution as ga  # noqa: E402

sys.path.insert(0, str(ROOT / "tests"))

REPO = "manaflow-ai/cmux"
HEAD = "a" * 40


# ---------------------------------------------------------------- CI failure attribution


os.environ["PR_STATUS_SETTLE_SECONDS"] = "0"  # no wait before the status comment's check


class CountingGitHub:
    """classify_failures' GitHub with every read recorded."""

    repo = REPO

    def __init__(self, *, comments: list[dict] | None = None, state: str = "open", head: str = HEAD,
                 latest: dict | None = None, files: list[str] | None = None):
        self._comments, self.state, self.head = comments or [], state, head
        self.files = files or []
        self.latest = latest or {"run_attempt": 1, "status": "completed"}
        self.reads: list[str] = []
        self.writes: list[tuple[str, str]] = []

    def pull(self, number: int) -> dict:
        self.reads.append(f"pull {number}")
        return {"number": number, "state": self.state, "head": {"sha": self.head}, "merged_at": None}

    def comments(self, number: int) -> list[dict]:
        self.reads.append(f"comments {number}")
        return self._comments

    def run(self, run_id: int) -> dict:
        self.reads.append(f"run {run_id}")
        return self.latest

    def get(self, path: str) -> object:
        self.reads.append(path)
        if "/files?" in path:
            return [{"filename": f} for f in self.files] if "page=1" in path else []
        if "labels=main-full-suite-failure" in path:
            return []
        if "pulls?state=" in path:
            return []
        raise AssertionError(f"unexpected read {path}")

    def request(self, method: str, path: str, body: object = None) -> dict:
        self.writes.append((method, path))
        # Kept as GitHub would, so the status comment's check after a write reads what it wrote.
        if method == "POST" and path.endswith("/issues/7/comments"):
            self._comments = [*self._comments, {"id": 1000, "body": body["body"], "user": {"login": cf.BOT}}]  # type: ignore[index]
        elif method == "PATCH" and "/issues/comments/" in path:
            cid = int(path.rsplit("/", 1)[1])
            self._comments = [dict(c, body=body["body"]) if c["id"] == cid else c  # type: ignore[index]
                              for c in self._comments]
        return {}


RUN = {"id": 42, "head_sha": HEAD, "head_branch": "topic", "head_repository": {"full_name": REPO},
       "pull_requests": [{"number": 7, "base": {"repo": {"url": f"https://api.github.com/repos/{REPO}"}}}]}
BOT_COMMENT = {"id": 99, "body": cf.MARKER + "\nred", "user": {"login": cf.BOT}}


def report(verdicts: list[str], conclusion: str = "failure", macos_blocked: str = "") -> dict:
    jobs = [{"name": f"job {i}", "verdict": v, "why": "because", "evidence": "", "url": None, "runner": "r"}
            for i, v in enumerate(verdicts)]
    return {"run_id": 42, "attempt": 1, "head_sha": HEAD, "run_url": "https://run", "conclusion": conclusion,
            "jobs": jobs, "macos_ran": not macos_blocked, "macos_blocked": macos_blocked}


def act(gh: CountingGitHub, rep: dict) -> dict:
    return cf.act(gh, cf.Writer(gh, dry_run=False), RUN, rep)  # type: ignore[arg-type]


class FailureAttributionCalls(unittest.TestCase):
    def setUp(self) -> None:
        summary = tempfile.NamedTemporaryFile(delete=False)
        summary.close()
        self.summary = Path(summary.name)
        self.addCleanup(self.summary.unlink)
        os.environ["GITHUB_STEP_SUMMARY"] = str(self.summary)
        self.addCleanup(os.environ.pop, "GITHUB_STEP_SUMMARY", None)

    def test_a_green_run_where_nothing_was_reported_reads_only_the_comments(self) -> None:
        gh = CountingGitHub()
        result = act(gh, report([], conclusion="success"))
        self.assertEqual(gh.reads, ["comments 7"])  # was: pull 7, comments 7
        self.assertEqual(gh.writes, [])
        self.assertFalse(result["rerun"])
        # The job summary still says it passes.
        self.assertIn("CI passes on", self.summary.read_text())

    def test_a_green_run_with_a_comment_still_updates_it(self) -> None:
        gh = CountingGitHub(comments=[BOT_COMMENT])
        act(gh, report([], conclusion="success"))
        # The comments are read once before the write, and once after it: the status comment's
        # other lines belong to other jobs, so a write is checked (scripts/ci/pr_status.py).
        self.assertEqual(gh.reads, ["comments 7", "pull 7", "comments 7"])
        self.assertEqual(gh.writes, [("PATCH", f"repos/{REPO}/issues/comments/99")])

    def test_a_green_run_with_a_comment_on_a_moved_head_marks_it_pending(self) -> None:
        gh = CountingGitHub(comments=[{**BOT_COMMENT, "body": cf.MARKER + "\n" + cf.head_marker(HEAD, "failed")}],
                            head="b" * 40)
        self.assertTrue(act(gh, report([], conclusion="success"))["line"].startswith("marked pending"))
        self.assertEqual(gh.writes, [("PATCH", f"repos/{REPO}/issues/comments/99")])

    def test_a_green_run_whose_macos_jobs_never_ran_still_comments(self) -> None:
        gh = CountingGitHub(files=["Sources/App.swift"])
        act(gh, report([], conclusion="success", macos_blocked="`changes` failure"))
        self.assertEqual(gh.reads[:2], ["pull 7", "comments 7"])
        self.assertEqual(gh.writes, [("POST", f"repos/{REPO}/issues/7/comments")])

    def test_a_cancelled_run_with_no_failed_job_and_no_comment_reads_only_the_comments(self) -> None:
        gh = CountingGitHub()
        act(gh, report([], conclusion="cancelled"))
        self.assertEqual(gh.reads, ["comments 7"])
        self.assertEqual(gh.writes, [])

    def test_a_code_failure_never_reads_the_run_again(self) -> None:
        gh = CountingGitHub()
        result = act(gh, report([cf.CODE]))
        self.assertNotIn("run 42", gh.reads)  # was read on every red run
        self.assertIn("is not a machine failure", result["line"])
        self.assertEqual(gh.writes, [("POST", f"repos/{REPO}/issues/7/comments")])

    def test_a_machine_failure_reads_the_run_before_re_running(self) -> None:
        gh = CountingGitHub()
        self.assertTrue(act(gh, report([cf.MACHINE]))["rerun"])
        self.assertIn("run 42", gh.reads)
        gh = CountingGitHub(latest={"run_attempt": 2, "status": "completed"})
        self.assertFalse(act(gh, report([cf.MACHINE]))["rerun"])

    def test_a_started_run_without_a_comment_reads_only_the_comments(self) -> None:
        gh = CountingGitHub()
        writer = cf.Writer(gh, dry_run=False)  # type: ignore[arg-type]
        run = {**RUN, "status": "requested", "html_url": "https://run/2"}
        self.assertEqual(cf.act_requested(gh, writer, run)["line"], "nothing to mark")  # type: ignore[arg-type]
        self.assertEqual(gh.reads, ["comments 7"])  # was: pull 7, comments 7
        gh = CountingGitHub(comments=[{**BOT_COMMENT, "body": cf.MARKER + "\n" + cf.head_marker("c" * 40, "failed")}])
        writer = cf.Writer(gh, dry_run=False)  # type: ignore[arg-type]
        self.assertTrue(cf.act_requested(gh, writer, run)["line"].startswith("marked pending"))  # type: ignore[arg-type]
        self.assertEqual(gh.reads, ["comments 7", "pull 7", "comments 7"])  # the last checks the write
        gh = CountingGitHub(comments=[BOT_COMMENT], state="closed")
        writer = cf.Writer(gh, dry_run=False)  # type: ignore[arg-type]
        self.assertEqual(cf.act_requested(gh, writer, run)["line"],  # type: ignore[arg-type]
                         "skipped: not the open pull request's head")
        self.assertEqual(gh.writes, [])


# ---------------------------------------------------------------- CI guard attribution


class GuardGitHub:
    repo = REPO

    def __init__(self, comments: list[dict]):
        self._comments, self.reads = comments, 0

    def comments(self, number: int) -> list[dict]:
        self.reads += 1
        return self._comments


class GuardAttributionCalls(unittest.TestCase):
    RUN = {"head_sha": HEAD, "conclusion": "success", "html_url": "u", "pull_requests": [
        {"number": 7, "base": {"repo": {"url": f"https://api.github.com/repos/{REPO}"}}}]}

    def test_a_green_pr_with_a_guard_comment_reads_the_comments_once(self) -> None:
        bot = {"login": "github-actions[bot]"}
        gh = GuardGitHub([{"id": 3, "body": ga.PR_MARKER + "\nold", "user": bot}, {"id": 4, "body": "unrelated", "user": bot}])
        rep = ga.analyze_pr(gh, self.RUN, ROOT, "")  # type: ignore[arg-type]
        self.assertEqual(rep["state"], "green")
        self.assertEqual(rep["comments"], [{"id": 3, "body": ga.PR_MARKER + "\nold", "user": bot}])
        rep = json.loads(json.dumps(rep))  # the artifact between analyze and report
        writer = ga.Writer(None, True)
        ga.report_pr(writer, gh, REPO, rep)  # type: ignore[arg-type]
        self.assertEqual(gh.reads, 1)  # was 2: analyze, then report again
        self.assertEqual(writer.log[0].splitlines()[0], f"--- would PATCH repos/{REPO}/issues/comments/3")

    def test_a_green_pr_never_reported_on_stays_a_noop(self) -> None:
        gh = GuardGitHub([{"id": 4, "body": "unrelated"}])
        rep = ga.analyze_pr(gh, self.RUN, ROOT, "")  # type: ignore[arg-type]
        self.assertEqual(rep["state"], "noop")
        self.assertNotIn("comments", rep)

    def test_a_red_report_still_reads_the_comments(self) -> None:
        gh = GuardGitHub([])
        ga.report_pr(ga.Writer(None, True), gh, REPO,  # type: ignore[arg-type]
                     {"branch": "pr", "state": "red", "pr": 7, "sha": "abc", "run_url": "u", "steps": []})
        self.assertEqual(gh.reads, 1)


class CmuxBotTokenWorkflowShape(unittest.TestCase):
    """High-volume bot jobs use the dedicated installation budget when configured."""

    JOBS = {
        "ci-queue-janitor.yml": ("sweep",),
        "ci-compile-attribution.yml": ("analyze", "report", "fix"),
        "ci-owned-pool-rescue.yml": ("rescue",),
    }
    PERMISSIONS = {
        "permission-actions": "write",
        "permission-checks": "read",
        "permission-contents": "read",
        "permission-issues": "write",
        "permission-pull-requests": "write",
    }

    def test_bot_jobs_mint_and_use_the_scoped_app_token(self) -> None:
        for filename, job_names in self.JOBS.items():
            document = yaml.safe_load((ROOT / ".github/workflows" / filename).read_text())
            for job_name in job_names:
                with self.subTest(workflow=filename, job=job_name):
                    job = document["jobs"][job_name]
                    steps = job["steps"]
                    mint = next(step for step in steps if step.get("id") == "cmux-bot-token")
                    self.assertEqual(mint["uses"],
                                     "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1")
                    self.assertIn("vars.CMUX_BOT_APP_ID != ''", mint["if"])
                    self.assertTrue(mint["continue-on-error"])
                    self.assertEqual(mint["with"]["app-id"], "${{ vars.CMUX_BOT_APP_ID }}")
                    self.assertEqual(mint["with"]["private-key"], "${{ secrets.CMUX_BOT_APP_KEY }}")
                    self.assertEqual({key: mint["with"][key] for key in self.PERMISSIONS}, self.PERMISSIONS)

                    # Every shell step that can call gh receives the App token,
                    # while the expression keeps forks and rollouts working.
                    token_envs = [(step.get("id"), step.get("env", {}).get("GH_TOKEN")) for step in steps]
                    token_envs = [(step_id, value) for step_id, value in token_envs if value is not None]
                    self.assertTrue(token_envs)
                    for step_id, value in token_envs:
                        if filename == "ci-queue-janitor.yml" and step_id == "fresh":
                            self.assertEqual(value, "${{ github.token }}")
                        else:
                            self.assertIn("steps.cmux-bot-token.outputs.token", value)


if __name__ == "__main__":
    unittest.main()
