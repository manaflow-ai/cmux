#!/usr/bin/env python3
"""retry-nightly-next on its third failure in a row (scripts/ci/nightly-steps/retry-ask-push-group.sh) pages the
`nightly-next-feed-stale` issue through scripts/ci/nightly_next_retry_exhausted.py, naming the head, the first
failing step and its error line. Before, it only printed a warning and exited 0, and the feed went 24 h stale behind
four failed runs on 2026-11-18/19 with nobody told.
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_next_retry_exhausted.py"
RETRY = ROOT / "scripts/ci/nightly-steps/retry-ask-push-group.sh"
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
spec = importlib.util.spec_from_file_location("retry_exhausted", SCRIPT)
mod = importlib.util.module_from_spec(spec)
sys.modules["retry_exhausted"] = mod
spec.loader.exec_module(mod)

SHA = "34acb4912e60f0d2679f7a768a079c9dc02881a6"
ERROR = "error: tree 1111111111111111111111111111111111111111 is not published and no candidate manifest is uploaded after 45 min"
JOBS = [
    {"id": 1, "name": "decide", "conclusion": "success", "completed_at": "2026-11-19T01:00:00Z", "steps": []},
    {"id": 2, "name": "nightly-next-one", "conclusion": "failure", "completed_at": "2026-11-19T02:10:00Z", "steps": [
        {"number": 30, "name": "Build nightly app (Release)", "conclusion": "success"},
        {"number": 41, "name": "Bundle the cmux-tui client", "conclusion": "failure"},
        {"number": 42, "name": "Thin bundle to the variant architecture", "conclusion": "skipped"}]},
    {"id": 3, "name": "report-nightly-failure", "conclusion": "failure", "completed_at": "2026-11-19T02:00:00Z", "steps": []},
]
LOG = [
    "2026-11-19T02:09:58.0000000Z the cmux-tui artifacts run of 34acb4912e60 is building tree 1111\n",
    f"2026-11-19T02:09:59.0000000Z {ERROR}\n",
    "2026-11-19T02:10:00.0000000Z ##[error]Process completed with exit code 1.\n",
    "2026-11-19T02:10:01.0000000Z ##[error]a later step's error\n",
]


class FakeGitHub:
    def __init__(self, open_issues):
        self.open_issues = open_issues
        self.writes = []

    def call(self, method, path, body=None):
        if method == "GET" and "/jobs" in path:
            return {"jobs": JOBS}
        if method == "GET" and path.startswith("/issues?labels=nightly-next-feed-stale"):
            return self.open_issues
        self.writes.append((method, path, body))
        return {"number": 900}

    def job_log(self, job_id):
        assert job_id == 2, job_id
        return iter(LOG)


class RetryExhausted(unittest.TestCase):
    def test_comments_on_the_open_feed_stale_issue_with_head_step_and_error(self):
        # A labelled pull request (lower number) is not the incident: the issues list returns both.
        gh = FakeGitHub([{"number": 812}, {"number": 500, "pull_request": {}}, {"number": 640}])
        body = mod.message(gh, "44478285964", "1", SHA, "https://github.com", "o/r")
        self.assertEqual(mod.post(gh, body), "commented on #640")
        [(method, path, sent)] = gh.writes
        self.assertEqual((method, path), ("POST", "/issues/640/comments"))
        self.assertIn(SHA, sent["body"])
        self.assertIn("nightly-next-one / Bundle the cmux-tui client", sent["body"])
        self.assertIn(ERROR, sent["body"])
        self.assertIn("actions/runs/44478285964", sent["body"])
        self.assertNotIn("report-nightly-failure", sent["body"])

    def test_opens_the_issue_when_none_is_open(self):
        gh = FakeGitHub([])
        mod.post(gh, mod.message(gh, "1", "1", SHA, "https://github.com", "o/r"))
        [(method, path, sent)] = gh.writes
        self.assertEqual((method, path), ("POST", "/issues"))
        self.assertEqual(sent["labels"], ["nightly-next-feed-stale"])
        self.assertIn(ERROR, sent["body"])

    def test_error_line_prefers_a_named_error_over_the_exit_code(self):
        self.assertEqual(mod.error_line(["x\n", "##[error]tree X has no runner\n"]), "tree X has no runner")
        self.assertEqual(mod.error_line(["x\n", "why\n", "##[error]Process completed with exit code 1.\n"]), "why")

    def test_the_retry_script_runs_the_pager_on_exhaustion(self):
        # The detector for the bare-warning exit: a third failure must reach the pager, and the job must be allowed
        # to write issues.
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "python3"
            fake.write_text(f"#!/bin/sh\necho \"$@\" > {tmp}/called\n")
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", RETRY="2", SHA=SHA, RUN_ID="7",
                       RUN_ATTEMPT="1", GITHUB_REPOSITORY="o/r")
            subprocess.run(["bash", str(RETRY)], env=env, check=True, capture_output=True)
            called = (Path(tmp) / "called").read_text()
        self.assertIn("nightly_next_retry_exhausted.py", called)
        self.assertIn(f"--sha {SHA}", called)
        job = WORKFLOW.read_text().split("\n  retry-nightly-next:\n", 1)[1].split("\n  report-nightly-failure:\n", 1)[0]
        self.assertIn("issues: write", job)


def retry_calls(next_head: str, tip: str | None, tick_ok: bool = True) -> tuple[list[str], str]:
    """retry-ask-push-group.sh after a failed first run of SHA (RETRY empty), with nightly-next at `next_head` and
    feat-cmux-next at `tip` (None: the read fails); the gh calls it made, and its output."""
    with tempfile.TemporaryDirectory() as tmp:
        tip_answer = "exit 1" if tip is None else f"echo {tip}"
        tick = "exit 0" if tick_ok else "exit 1"
        (Path(tmp) / "gh").write_text(
            f'#!/bin/sh\necho "$*" >> {tmp}/calls\n'
            f'case "$*" in *heads/nightly-next*) echo {next_head};; *heads/feat-cmux-next*) {tip_answer};;\n'
            f'  *nightly-next-tick.yml*) {tick};; esac\n')
        (Path(tmp) / "gh").chmod(0o755)
        env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", RETRY="", SHA=SHA, RUN_ID="7", RUN_ATTEMPT="1",
                   GITHUB_REPOSITORY="o/r")
        proc = subprocess.run(["bash", str(RETRY)], env=env, check=True, capture_output=True, text=True, timeout=60)
        calls = Path(tmp) / "calls"
        return (calls.read_text().splitlines() if calls.exists() else []), proc.stdout


class RetryBuildsTheTip(unittest.TestCase):
    """Leo, 2026-11-25: "why so long that they didnt publish either tho cuz it's been 5h". Run 45589863477 retried
    92c8d92d9 (its Cargo.toml broken, the tip already fixed) while 6c8931ce2 waited: a failed commit that
    feat-cmux-next moved past is not retried; main's tick is asked to promote the newest buildable commit."""

    NEWER = "6c8931ce22be5d14b26f4b103b652d764f7ab4cc"

    def dispatched_retry(self, calls):
        return [c for c in calls if "nightly_next_loop_retry=" in c]

    def test_moved_tip_asks_the_tick_and_does_not_retry_the_failed_commit(self):
        calls, out = retry_calls(SHA, self.NEWER)
        self.assertEqual(self.dispatched_retry(calls), [])
        self.assertTrue(any("nightly-next-tick.yml" in c and "--ref main" in c for c in calls), calls)
        self.assertIn(self.NEWER, out)

    def test_failed_commit_still_the_tip_is_retried_as_itself(self):
        calls, _ = retry_calls(SHA, SHA)
        self.assertEqual(len(self.dispatched_retry(calls)), 1, calls)
        self.assertIn("nightly_next_loop_retry=1", self.dispatched_retry(calls)[0])
        self.assertFalse(any("nightly-next-tick.yml" in c for c in calls), calls)

    def test_unread_tip_or_refused_tick_retries_as_before(self):
        for tip, tick_ok in ((None, True), (self.NEWER, False)):
            calls, _ = retry_calls(SHA, tip, tick_ok)
            self.assertEqual(len(self.dispatched_retry(calls)), 1, (tip, tick_ok, calls))

    def test_moved_nightly_next_still_leaves_to_its_push_run(self):
        calls, _ = retry_calls(self.NEWER, self.NEWER)
        self.assertEqual(self.dispatched_retry(calls), [])
        self.assertFalse(any("nightly-next-tick.yml" in c for c in calls), calls)


if __name__ == "__main__":
    unittest.main()
