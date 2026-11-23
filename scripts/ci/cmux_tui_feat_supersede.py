#!/usr/bin/env python3
"""Cancel the older feat-cmux-next push runs of cmux-tui artifacts that never got a runner.

feat-cmux-next tree publishing is latest-wins (Leo: "if i wait for the nightly then i might as
well just update to the thing"). The newest commit's mac-live.json lists the older commits in
live_from, so `cmux app try` takes every one of them live from the newest publication; an older
commit's own publication is worth nothing once a newer one publishes.

tree-preflight's job concurrency group keeps one feat-cmux-next push preflight admitted and one
pending, and GitHub replaces the pending one with each newer push. That covers runs this
definition starts. Runs started by an older definition of the workflow are in a group of their
own commit and are never replaced: on 2026-11-19 about 240 of them sat queued on the owned lane
label (the oldest from 11-11), it hands runners out oldest first, and channels/mac-live.json
moved from fa7b1aaa to edbc6c85 (committed 2026-11-18 18:56Z) at 17:03Z, about 22 h behind,
while none of the last 10 feat-cmux-next commits had a mac-live.json. So each feat-cmux-next
push run calls this once: it cancels every older feat-cmux-next push run of this workflow that
no runner ever took.

Cancelled only when all of these hold (decide()):
  - event push on feat-cmux-next, attempt 1 (a re-run someone or a hand-off asked for stays);
  - created before this run, at another commit;
  - not completed, and no job of it has a runner, a step, or a completed result other than
    skipped: a started run (one that may claim or build a tree key) is never cancelled.
Dispatches (cmux-tui-tree-request.yml, request-nightly-next.sh's backfill) and nightly-next
pushes are never listed, so the tree of a specific commit a nightly needs still publishes.
cmux-tui-artifacts-retry on main skips a cancelled run that a newer feat-cmux-next push run
superseded, so nothing here is re-run.

Every API failure stops the sweep and exits 0: this is delivery, not a gate.

usage: cmux_tui_feat_supersede.py --repo OWNER/NAME --run-id ID [--dry-run] [--max-runs N]
Needs GH_TOKEN with actions: write.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

WORKFLOW = "cmux-tui-artifacts.yml"
BRANCH = "feat-cmux-next"
ACTIVE_STATES = ("queued", "pending", "waiting", "requested")


def never_started(job: dict) -> bool:
    """No runner ever took JOB: no runner name or id, no step, and not completed (a skipped job is fine)."""
    if job.get("runner_name") or job.get("runner_id") or job.get("steps"):
        return False
    if job.get("status") == "completed":
        return job.get("conclusion") == "skipped"
    return True


def decide(run: dict, jobs: list[dict], current: dict) -> tuple[bool, str]:
    """Pure policy: whether CURRENT (this run) cancels RUN, an older feat-cmux-next push run."""
    rid = run.get("id")
    if rid == current.get("id"):
        return False, "this run"
    if run.get("event") != "push" or run.get("head_branch") != BRANCH:
        return False, f"{run.get('event')} on {run.get('head_branch')}: only feat-cmux-next pushes are superseded"
    if int(run.get("run_attempt") or 1) != 1:
        return False, f"attempt {run.get('run_attempt')}: a re-run was asked for"
    if run.get("status") == "completed":
        return False, "already completed"
    if run.get("head_sha") == current.get("head_sha"):
        return False, "same commit"
    # Run ids grow with creation; created_at breaks nothing when both are present.
    if not (isinstance(rid, int) and isinstance(current.get("id"), int) and rid < current["id"]):
        return False, "not older than this run"
    if str(run.get("created_at") or "") > str(current.get("created_at") or "~"):
        return False, "created after this run"
    started = [job.get("name", "?") for job in jobs if not never_started(job)]
    if started:
        return False, "started: " + ", ".join(started[:3])
    return True, f"superseded by {str(current.get('head_sha') or '')[:12]} (run {current.get('id')}); no runner took it"


def _api(method: str, url: str, token: str) -> object:
    request = urllib.request.Request(
        url,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    _status, body, _headers = deadline_http.request(request, 30, raise_errors=True)
    return json.loads(body) if body else None


def older_active_runs(base: str, token: str, limit: int) -> list[dict]:
    runs: dict[int, dict] = {}
    for state in ACTIVE_STATES:
        page = 1
        while len(runs) < limit:
            data = _api("GET", f"{base}/actions/workflows/{WORKFLOW}/runs?branch={BRANCH}&event=push"
                               f"&status={state}&per_page=100&page={page}", token)
            batch = (data or {}).get("workflow_runs") or []
            for run in batch:
                runs.setdefault(run["id"], run)
            if len(batch) < 100:
                break
            page += 1
    return sorted(runs.values(), key=lambda run: run["id"])[:limit]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--dry-run", action="store_true", help="decide and print, never cancel")
    parser.add_argument("--max-runs", type=int, default=400, help="runs read at most (one jobs read each)")
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("GH_TOKEN is required", file=sys.stderr)
        return 2
    base = f"https://api.github.com/repos/{args.repo}"
    cancelled = kept = 0
    try:
        current = _api("GET", f"{base}/actions/runs/{args.run_id}", token)
        if current.get("event") != "push" or current.get("head_branch") != BRANCH:
            print(f"run {args.run_id} is not a feat-cmux-next push; nothing to supersede")
            return 0
        for run in older_active_runs(base, token, args.max_runs):
            if run["id"] >= args.run_id:
                continue
            jobs = _api("GET", f"{base}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100", token)["jobs"]
            cancel, reason = decide(run, jobs, current)
            if not cancel:
                kept += 1
                print(f"keep run {run['id']} ({str(run.get('head_sha'))[:12]}): {reason}")
                continue
            if not args.dry_run:
                try:
                    _api("POST", f"{base}/actions/runs/{run['id']}/cancel", token)
                except urllib.error.HTTPError as error:
                    # 409: it started or finished meanwhile; that run stays.
                    print(f"keep run {run['id']}: cancel answered HTTP {error.code}")
                    kept += 1
                    continue
            cancelled += 1
            print(f"{'would cancel' if args.dry_run else 'cancelled'} run {run['id']} "
                  f"({str(run.get('head_sha'))[:12]}, created {run.get('created_at')}): {reason}")
    except (urllib.error.URLError, deadline_http.RequestTimeout, OSError, ValueError, KeyError, TypeError) as error:
        print(f"::warning title=feat-cmux-next supersede::stopped after {cancelled} cancelled: {error}")
        return 0
    print(f"::notice title=feat-cmux-next supersede::{cancelled} older never-started runs "
          f"{'would be ' if args.dry_run else ''}cancelled, {kept} kept")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
