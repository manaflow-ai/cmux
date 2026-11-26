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

    def _retry_with_fake_gh(self, tmp: str, dispatch_failures: int, backoff: str) -> subprocess.CompletedProcess:
        # A fake gh: the head read answers SHA; the first N dispatches fail as GitHub's HTTP 500 did in run
        # 45744507889, then one succeeds. Each call is logged.
        fake = Path(tmp) / "gh"
        fake.write_text(
            "#!/bin/sh\n"
            f"echo \"$*\" >> {tmp}/calls\n"
            f"case \"$1\" in api) echo {SHA}; exit 0;; esac\n"
            f"n=$(grep -c '^workflow run' {tmp}/calls)\n"
            f"if [ \"$n\" -le {dispatch_failures} ]; then echo 'could not create workflow dispatch event: HTTP 500' >&2; exit 1; fi\n")
        fake.chmod(0o755)
        env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", RETRY="0", SHA=SHA, RUN_ID="7",
                   RUN_ATTEMPT="1", GITHUB_REPOSITORY="o/r", RETRY_BACKOFF_SECONDS=backoff)
        return subprocess.run(["bash", str(RETRY)], env=env, capture_output=True, text=True)

    def test_a_failed_dispatch_backs_off_and_tries_again(self):
        # Run 45744507889: one HTTP 500 on the dispatch ended the retry loop. Now it backs off and dispatches again,
        # reading the head again first.
        with tempfile.TemporaryDirectory() as tmp:
            done = self._retry_with_fake_gh(tmp, dispatch_failures=1, backoff="0 0")
            calls = (Path(tmp) / "calls").read_text().splitlines()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual([c.split()[0] for c in calls], ["api", "workflow", "api", "workflow"])
        self.assertIn("trying again in 0 s", done.stdout)

    def test_dispatch_failures_past_the_backoff_fail_the_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = self._retry_with_fake_gh(tmp, dispatch_failures=9, backoff="0 0")
            calls = (Path(tmp) / "calls").read_text().splitlines()
        self.assertEqual(done.returncode, 1)
        self.assertEqual(sum(c.startswith("workflow run") for c in calls), 3)

    def test_the_retry_job_reads_scripts_from_the_mirror_before_github(self):
        job = WORKFLOW.read_text().split("\n  retry-nightly-next:\n", 1)[1].split("\n  fixit-handoff:\n", 1)[0]
        mirror = job.index("Read scripts/ci from the host's git mirror")
        checkout = job.index("uses: actions/checkout@")
        self.assertLess(mirror, checkout)
        self.assertIn("if: steps.mirror-scripts.outputs.ok != 'true'", job[mirror:checkout + 200])


if __name__ == "__main__":
    unittest.main()
