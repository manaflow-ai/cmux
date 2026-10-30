#!/usr/bin/env python3
"""Will an active feat-cmux-next publisher really test its tree's daemon tests?

A published tree is promotable to nightly-next only with
tree/<key>/daemon-tests.json, which its publisher writes once its
"cmux_next_ daemon tests" job passes (older runs named it with a
parenthesised runner suffix; every such name counts). cmux-tui-artifacts.yml's
tree-preflight and tree-owner-wait let every later push of the same key skip
those tests while that publisher is an active feat-cmux-next push. On
2026-10-21 the publisher's job sat queued for hours on a pool pull requests
had filled (CI_NEXT_DAEMON_POOL then named the pull request side label). The
variable was moved at 06:04Z, but a job keeps the label it was queued with, so
every newer push kept deferring to it and nightly-next stayed stuck.

So a run defers only while the publisher's job is on its way. It tests the
tree itself (exit 1) when the publisher's daemon-test job:
  - ended without success (skipped, cancelled, failed): no marker is coming;
  - is queued for a label the current pool (--pool) no longer names;
  - has been queued longer than --max-queued-minutes.
It keeps deferring (exit 0) while the job runs, passed, is queued briefly on
the current pool, or does not exist yet (the publisher's needs still run).
Every API failure answers "test here" (exit 1), as the run lookup before it.

Usage: cmux_tui_publisher_testing.py --run-id ID [--pool LABEL] [--max-queued-minutes 20]
Environment: GH_TOKEN (actions read), API_URL and REPOSITORY (the calling
steps' names; GITHUB_API_URL and GITHUB_REPOSITORY otherwise). It reads through
curl like the steps around it, so their tests' fake curl answers it too.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys

JOB_NAME = "cmux_next_ daemon tests"


def is_daemon_job(name: str | None) -> bool:
    """The gate job by its name: bare now, with a "(...)" runner suffix in older runs."""
    return name == JOB_NAME or (name or "").startswith(JOB_NAME + " (")


def jobs(run_id: str) -> list[dict]:
    base = (os.environ.get("API_URL") or os.environ.get("GITHUB_API_URL") or "https://api.github.com").rstrip("/")
    repo = os.environ.get("REPOSITORY") or os.environ["GITHUB_REPOSITORY"]
    body = subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "--connect-timeout", "5", "--max-time", "15",
         "-u", f"x-access-token:{os.environ.get('GH_TOKEN', '')}", "-H", "Accept: application/vnd.github+json",
         f"{base}/repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"],
        capture_output=True, text=True, check=True, timeout=30).stdout
    return json.loads(body)["jobs"]


def verdict(all_jobs: list[dict], pool: str, max_queued_minutes: float, now: dt.datetime) -> tuple[bool, str]:
    """(publisher tests it, why)."""
    job = next((j for j in all_jobs if is_daemon_job(j.get("name"))), None)
    if job is None:
        return True, "its daemon-test job is not created yet"
    status, conclusion = job.get("status"), job.get("conclusion")
    if status == "completed":
        if conclusion == "success":
            return True, "its daemon tests passed; the marker follows"
        return False, f"its daemon-test job ended {conclusion}"
    if status != "queued":
        return True, f"its daemon-test job is {status}"
    labels = job.get("labels") or []
    if pool and pool not in labels:
        return False, f"its daemon-test job is queued for {', '.join(labels) or '?'}, not the current pool {pool}"
    created = dt.datetime.fromisoformat(job["created_at"].replace("Z", "+00:00"))
    waited = (now - created).total_seconds() / 60
    if waited > max_queued_minutes:
        return False, f"its daemon-test job has been queued {waited:.0f} min (limit {max_queued_minutes:g})"
    return True, f"its daemon-test job has been queued {waited:.0f} min"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--pool", default="")
    parser.add_argument("--max-queued-minutes", type=float, default=20.0)
    args = parser.parse_args(argv)
    try:
        testing, why = verdict(jobs(args.run_id), args.pool.strip(), args.max_queued_minutes,
                               dt.datetime.now(dt.timezone.utc))
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError) as error:
        testing, why = False, f"its jobs could not be read ({error})"
    print(f"publisher run {args.run_id}: {why}")
    return 0 if testing else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
