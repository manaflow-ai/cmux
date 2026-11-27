#!/usr/bin/env python3
"""nightly.yml retry-nightly-next, after the loop's second retry failed too: tell the feed's owner.

retry-ask-push-group.sh used to print only a warning ("nightly-next failed after two retries in a row") and exit 0,
so a loop that stopped retrying was heard by nobody: on 2026-11-18/19 four nightly-next-one runs failed at
"Bundle the cmux-tui client" while the feed went 24 h stale. This comments on the open `nightly-next-feed-stale`
issue (the one nightly_next_feed_watch.py keeps, which pages the coordinator), or opens it, with the head, the first
failing job and step of this run, and that step's error line.

Usage: nightly_next_retry_exhausted.py --repo OWNER/REPO --run-id N --attempt N --sha SHA
Env: GH_TOKEN (issues: write, actions: read). Exit 0 posted, 1 GitHub refused or could not be read.
Tested by tests/test_nightly_next_retry_exhausted.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import subprocess

LABEL = "nightly-next-feed-stale"
# This run's own bookkeeping jobs: they fail because the build did, never first.
SKIP_JOBS = {"retry-nightly-next", "report-nightly-failure", "close-nightly-failure-issue"}
FAILED = ("failure", "timed_out", "cancelled")
LOG_STAMP = re.compile(r"^\ufeff?\d{4}-\d\d-\d\dT[0-9:.]+Z ")
LOG_MAX_LINES = 2_000_000


class GitHub:
    """GitHub through `gh api`: the job installs gh_budget_wait.sh as `gh`, so a spent rate limit is waited out
    (as every other gh call in the job) instead of losing the comment."""

    def __init__(self, repo: str):
        self.repo = repo

    def _gh(self, args: list[str], body: dict | None = None) -> str:
        # Past the wrapper's longest rate-limit wait (GH_BUDGET_WAIT_MAX_SECONDS, 3600); the job's own timeout bounds it too.
        try:
            done = subprocess.run(["gh", "api", *args], input=json.dumps(body) if body is not None else None,
                                  capture_output=True, text=True, errors="replace", timeout=3900)
        except subprocess.TimeoutExpired as error:
            raise OSError(f"gh api {' '.join(args)}: timed out after 3900 s") from error
        if done.returncode != 0:
            raise OSError(f"gh api {' '.join(args)}: exit {done.returncode}: {done.stderr.strip()[-300:]}")
        return done.stdout

    def call(self, method: str, path: str, body: dict | None = None):
        args = ["-X", method, f"repos/{self.repo}{path}"]
        if body is not None:
            args += ["--input", "-"]
        text = self._gh(args, body)
        return json.loads(text) if text.strip() else {}

    def job_log(self, job_id: int):
        """The job's log lines (gh follows the redirect to the signed blob URL)."""
        return self._gh([f"repos/{self.repo}/actions/jobs/{job_id}/logs"]).splitlines(keepends=True)


def first_failed(jobs: list[dict]) -> tuple[dict | None, str]:
    """The run's first failed job (by completion) and its first failed step's name."""
    failed = [job for job in jobs if job.get("conclusion") in FAILED and job.get("name") not in SKIP_JOBS]
    if not failed:
        return None, ""
    job = min(failed, key=lambda j: j.get("completed_at") or "9999")
    steps = sorted((s for s in job.get("steps") or [] if s.get("conclusion") in FAILED), key=lambda s: s.get("number") or 0)
    return job, steps[0]["name"] if steps else ""


def error_line(lines) -> str:
    """The failing step's own words: the last output line before the log's first `##[error]`, or that
    error's text when it says more than the exit code."""
    last = ""
    for count, raw in enumerate(lines):
        if count >= LOG_MAX_LINES:
            break
        line = LOG_STAMP.sub("", raw).strip()
        if line.startswith("##[error]"):
            text = line[len("##[error]"):].strip()
            if text and not text.startswith("Process completed with exit code"):
                return text[:400]
            return last[:400]
        if line and not line.startswith("##["):
            last = line
    return last[:400]


def message(gh, run_id: str, attempt: str, sha: str, server: str, repo: str) -> str:
    run_url = f"{server}/{repo}/actions/runs/{run_id}"
    try:
        jobs = gh.call("GET", f"/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")["jobs"]
    except (OSError, KeyError, ValueError, TypeError) as error:
        jobs = []
        print(f"::warning::could not read the jobs of {run_url}: {error!r}")
    job, step = first_failed(jobs)
    where = "no failed job recorded"
    line = ""
    if job is not None:
        where = f"{job.get('name', '?')} / {step}" if step else str(job.get("name", "?"))
        try:
            line = error_line(gh.job_log(job["id"]))
        except Exception as error:  # noqa: BLE001 - a lost error line never loses the comment
            print(f"::warning::could not read the log of job {job.get('id')}: {error!r}")
    head = f"nightly-next stopped retrying: run {run_url} (attempt {attempt}) on head `{sha}` failed after two loop retries in a row."
    failing = f"First failing step: \"{where}\"" + (f"\n\n```\n{line}\n```" if line else " (no error line read).")
    tail = "The loop retries no more until the next nightly-next push or the feed watch's dispatch starts it again."
    return f"{head}\n\n{failing}\n\n{tail}"


def post(gh, body: str) -> str:
    # The issues list also returns pull requests: only an issue is the feed-stale incident.
    open_issues = sorted((i for i in gh.call("GET", f"/issues?labels={LABEL}&state=open&per_page=100") if "pull_request" not in i),
                         key=lambda i: i["number"])
    if open_issues:
        number = open_issues[0]["number"]
        gh.call("POST", f"/issues/{number}/comments", {"body": body})
        return f"commented on #{number}"
    issue = gh.call("POST", "/issues", {"title": "nightly-next feed: the build loop stopped retrying", "body": body, "labels": [LABEL]})
    return f"opened #{issue.get('number', '?')}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args(argv)
    if not os.environ.get("GH_TOKEN"):
        print("GH_TOKEN is required", file=sys.stderr)
        return 1
    gh = GitHub(args.repo)
    body = message(gh, args.run_id, args.attempt, args.sha, os.environ.get("GITHUB_SERVER_URL", "https://github.com"), args.repo)
    print(body)
    try:
        print(post(gh, body))
    except (OSError, KeyError, ValueError, TypeError) as error:
        print(f"::error::nightly-next stopped retrying and the {LABEL} issue could not be updated: {error!r}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
