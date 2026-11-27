#!/usr/bin/env python3
"""Cancel a pull request's runs on its older heads the moment a newer head is pushed.

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period."

Each workflow's `concurrency: cancel-in-progress` only cancels an older head's run once that workflow's own run on
the new head is created. Workflows the router or a later event starts begin minutes after the push, and the older
head's jobs run until then. On the 24 h to 2026-11-25T23Z, 69k job-minutes (about 46 per merged pull request) ran
after a newer head of the same pull request was pushed (/tmp/ci140/split.md, cause "superseded head").
scripts/ci/shed_superseded_runs.py sweeps every 10 minutes but stops only runs that never started.

.github/workflows/ci-pr-superseded-cancel.yml runs this on every `synchronize` of a same-repository pull request:
it lists the head branch's queued and running runs once per status and cancels each one verdict() names.

A run is cancelled only when every rule holds (verdict()):
  - it is queued or running, and its commit is not the pushed head (the current head is never touched),
  - run_attempt 1 (a rerun someone asked for at that head finishes),
  - event pull_request, pull_request_target, push or workflow_run (shed_superseded_runs.LANE_EVENTS plus the
    target twin), never workflow_dispatch (a lane's `cmux-ci test` at a pinned head) or a schedule,
  - the run's head is this repository and its branch the pull request's head branch, never a protected branch,
  - not a nightly/dev/release/deploy/publish/sign workflow (shed_superseded_runs.PROTECTED_WORKFLOW), not a
    workflow that keeps superseded runs on purpose (KEEP_PATHS) and not this workflow.
A pull request labelled no-janitor keeps everything (the workflow skips the job).

usage: cancel_superseded_pr_runs.py [--dry-run]
env:   GH_TOKEN GH_REPO PR_HEAD_REF PR_HEAD_SHA [SELF_RUN_ID] [DRY_RUN=true]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402
from shed_superseded_runs import LANE_EVENTS, PROTECTED_BRANCH, PROTECTED_WORKFLOW  # noqa: E402

API = "https://api.github.com"
ACTIVE = ("queued", "in_progress", "waiting", "pending", "requested")
EVENTS = frozenset(LANE_EVENTS) | {"pull_request_target"}
SELF_PATH = ".github/workflows/ci-pr-superseded-cancel.yml"
# Workflows whose superseded pull request runs are kept on purpose (tests/test_ci_pr_runs_cancel_superseded.py
# ALLOWED has each reason): debounce runs that end themselves, opt-in measurements a new head runs beside.
KEEP_PATHS = frozenset({
    ".github/workflows/cmux-next-batch.yml",
    ".github/workflows/cloud-resume-matrix.yml",
    ".github/workflows/cloud-wake-echo.yml",
    ".github/workflows/chat-open-perf-report.yml",
})


def verdict(run: dict[str, Any], repo: str, branch: str, head_sha: str, self_run_id: int | None = None) -> str:
    """Why RUN is kept ("keep:...") or "cancel". Pure: no I/O."""
    if self_run_id is not None and run.get("id") == self_run_id:
        return "keep:self"
    if run.get("status") not in ACTIVE:
        return f"keep:status-{run.get('status')}"
    sha = run.get("head_sha") or ""
    if not head_sha or not sha or sha == head_sha:
        return "keep:head"
    if (run.get("run_attempt") or 1) > 1:
        return "keep:attempt"
    if run.get("event") not in EVENTS:
        return f"keep:event-{run.get('event')}"
    if (run.get("head_repository") or {}).get("full_name") != repo:
        return "keep:fork"
    run_branch = run.get("head_branch") or ""
    if not branch or run_branch != branch or PROTECTED_BRANCH.match(run_branch):
        return "keep:branch"
    path = run.get("path") or ""
    if path == SELF_PATH or path in KEEP_PATHS:
        return "keep:workflow"
    if PROTECTED_WORKFLOW.search(run.get("name") or "") or PROTECTED_WORKFLOW.search(path):
        return "keep:protected-workflow"
    return "cancel"


def call(method: str, url: str, token: str) -> tuple[int, Any]:
    req = urllib.request.Request(url, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    status, raw, _ = deadline_http.request(req, 20)
    try:
        return status, json.loads(raw or b"null")
    except ValueError:
        return status, None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    repo = os.environ.get("GH_REPO", "")
    branch = os.environ.get("PR_HEAD_REF", "")
    head = os.environ.get("PR_HEAD_SHA", "")
    self_id = int(os.environ["SELF_RUN_ID"]) if os.environ.get("SELF_RUN_ID", "").isdigit() else None
    dry = args.dry_run or os.environ.get("DRY_RUN") == "true"
    if not (token and repo and branch and head):
        print("::notice::missing GH_TOKEN, GH_REPO, PR_HEAD_REF or PR_HEAD_SHA; nothing cancelled")
        return 0
    runs: dict[int, dict[str, Any]] = {}
    for status in ACTIVE:
        query = urllib.parse.urlencode({"branch": branch, "status": status, "per_page": 100})
        try:
            code, body = call("GET", f"{API}/repos/{repo}/actions/runs?{query}", token)
        except Exception as error:  # noqa: BLE001 - a failed list cancels nothing; the push's own runs still run
            print(f"::warning::listing {status} runs failed: {error}")
            continue
        if code != 200 or not isinstance(body, dict):
            print(f"::warning::listing {status} runs answered {code}")
            continue
        for run in body.get("workflow_runs") or []:
            runs[run["id"]] = run
    cancelled = 0
    lines = []
    for run in runs.values():
        why = verdict(run, repo, branch, head, self_id)
        if why != "cancel":
            continue
        code = 0
        if not dry:
            try:
                code, _ = call("POST", f"{API}/repos/{repo}/actions/runs/{run['id']}/cancel", token)
            except Exception as error:  # noqa: BLE001 - one failed cancel never stops the others
                print(f"::warning::cancel {run['id']} failed: {error}")
                continue
        cancelled += code == 202
        lines.append(f"| {run['id']} | {run.get('name')} | {(run.get('head_sha') or '')[:10]} | {run.get('status')}"
                     f" | {'dry run' if dry else code} |")
    print(f"{len(runs)} active runs on {branch}; {len(lines)} on older heads than {head[:10]}; {cancelled} cancelled")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and lines:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("| run | workflow | head | status | cancel |\n|---|---|---|---|---|\n" + "\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
