#!/usr/bin/env python3
"""Whether a workflow's own job already passed at this pull request head: the same-head rerun rule for jobs the PR
router does not start.

usage: same_head_job.py --job "JOB NAME"   (in a job step; writes skip=true|false to $GITHUB_OUTPUT)

pr_router.py's same-head rule (SAME_HEAD_RERUN_VAR) keeps a routed callee off when an earlier router run at this very
head sha ran it green. A workflow on its own pull_request trigger (cmux-next-guards.yml's App Store shelf, ...) gets
no such check: a reopen, ready_for_review or full-ci-free label event at a head it already passed reran the whole job.
In the 24 h to 11-28 03Z that was about 900 runner-min a day for the App Store shelf alone. This reads the same
helpers: same_head_applies (switch, own-repo head, no full-ci), earlier_router_runs (this workflow's earlier runs at
the head, at most SAME_HEAD_RUNS), proved (every job green, a minute or more of success) and workflow_moved (the
workflow file unchanged on the base since that run started). The newest earlier run in which JOB ran long decides; a red,
cancelled or unfinished one runs it, and a short green (this rule's own skip) defers to an older run. Anything unread or any error runs it (skip=false). Leo, 2026-11-23:
"de facto, im asking for 99% fewer minutes of ci time, period."
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


def decide(event: dict, job: str, workflow: str, current: str, repo: str, token: str, switch: str = "1",
           runs_reader=None, jobs_reader=None, moved=None) -> tuple[bool, str]:
    """(skip, why) for JOB of WORKFLOW (a .github/workflows file name) at EVENT's head. The readers default to
    head_tier.runs_at, pr_router.run_jobs and pr_router.workflow_moved (tests pass fakes)."""
    import head_tier
    import pr_router as router
    if not router.same_head_applies(event, switch):
        return False, "the rule does not apply (switch off, fork head, no head sha or full-ci)"
    pr = event.get("pull_request") or {}
    sha = str((pr.get("head") or {}).get("sha") or "")
    runs_reader = runs_reader or head_tier.runs_at
    jobs_reader = jobs_reader or router.run_jobs
    moved = moved or router.workflow_moved
    earlier = router.earlier_router_runs(runs_reader(repo, sha, token), current, workflow)
    if not earlier:
        return False, f"no earlier {workflow} run at {sha[:12]} was read"
    for run in earlier:
        jobs = jobs_reader(run, repo, token)
        if not isinstance(jobs, list):
            return False, f"run {run.get('id')}'s jobs were not read"
        mine = router.jobs_under(jobs, job)
        if not mine or all(j.get("conclusion") == "skipped" for j in mine if isinstance(j, dict)):
            continue
        if not router.proved(mine):
            if all(isinstance(j, dict) and j.get("status") == "completed" and j.get("conclusion") in router.GREEN_JOB
                   for j in mine):
                continue  # a short green: this rule's own skip or a head with no input; an older run decides
            return False, f"run {run.get('id')} ran it and it was not green"
        since = str(run.get("created_at") or run.get("run_started_at") or "")
        base = str((pr.get("base") or {}).get("ref") or "")
        if moved(repo, base, f".github/workflows/{workflow}", since, token) is not False:
            return False, f"{workflow} changed on {base} since run {run.get('id')}, or that was not read"
        return True, (f"{router.SAME_HEAD_RERUN_REASON}: run {run.get('id')} ran it green at this exact head with this "
                      f"workflow file (full-ci, or vars.{router.SAME_HEAD_RERUN_VAR}=0, runs it)")
    return False, f"no earlier {workflow} run at {sha[:12]} ran it"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--job", required=True, help="the job's display name, as the jobs API lists it")
    args = ap.parse_args(argv)
    skip, why = False, "unread"
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        ref = os.environ.get("GITHUB_WORKFLOW_REF", "")
        workflow = ref.split("@")[0].rsplit("/", 1)[-1]
        import pr_router as router
        skip, why = decide(event, args.job, workflow, os.environ.get("GITHUB_RUN_ID", ""),
                           os.environ.get("GITHUB_REPOSITORY", ""),
                           os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or "",
                           os.environ.get(router.SAME_HEAD_RERUN_VAR, "1"))
    except Exception as exc:  # fail open: anything unread runs the job
        skip, why = False, f"error ({type(exc).__name__}: {exc}); running it"
    print(f"same head: {'skip' if skip else 'run'}: {why}")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(f"skip={'true' if skip else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
