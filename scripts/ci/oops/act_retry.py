"""act_retry: class a (infra) of ci-oops. A red that is the machine's, not the code's, is re-run on a fresh runner.

Runner died, OOM kill, network, a runner's setup refusal, a cache or download miss, a Blacksmith or pool stall: the job
is re-run (POST .../actions/jobs/ID/rerun for one job, .../runs/ID/rerun-failed-jobs when every failed job of the run
is infra or several are), never left red, waking no one, counted by its CI_OOPS line. A re-run takes a fresh runner of
the job's label; cmux's pickers (pr_runner_pool.py, the owned-pool rescue) move attempt 2 and later down the
RUNNER_POOLS ladder themselves, so this actor does not pick a label.

Guards, each read again from GitHub just before the re-run (the owned-pool rescue, the stale-runs janitor or a person
may have acted since the red):
- the run is finished and still at the attempt that went red (a newer attempt: someone re-ran it, `skipped`);
- the pull request's head is still the run's head (a newer push makes this run moot, `skipped`);
- the run is no nightly, DEV, promote, release, TestFlight, App Store, notarize or publish build (PROTECTED: those are
  re-run by their owners, `blocking`; 1e's panic.json also keeps them red before any actor runs);
- attempts: the red attempt is below MAX_ATTEMPTS (or the rule's own `retries` + 1, for an OOM a bigger rung should
  take); past it the outcome is `gave_up` and the job stays red as today, with its CI_OOPS line saying why.
"""
from __future__ import annotations

import json
import os
import re
import subprocess

MAX_ATTEMPTS = 3  # attempts 1 and 2 are re-run; a red attempt 3 stays red (gave_up)
PROTECTED = re.compile(r"nightly|\bdev build|promot|release|testflight|app ?store|notari[sz]|publish", re.IGNORECASE)


def gh(method: str, path: str, runner=subprocess.run):
    got = runner(["gh", "api", "-X", method, path], capture_output=True, text=True, timeout=120)
    if got.returncode != 0:
        raise RuntimeError(f"gh api {method} {path}: {(got.stderr or got.stdout).strip()[:300]}")
    return json.loads(got.stdout) if got.stdout.strip() else {}


# A job refused before it started because its label is one this repository cannot run: GitHub's hosted runners on a
# private repository whose Actions billing is refused ("recent account payments have failed"), as hq's RUNNER_POOLS
# named about 11:40-12:21Z on 2026-11-19 (hq#14387 run 44517256143, hq#14433 run 44520476170). A re-run evaluates
# runs-on again with the variables as they are then, so while RUNNER_POOLS still names a hosted label the re-run would
# be refused the same way: the red waits (pending, the sweep asks again next pass) until the pool writer fixes the
# variable. CI_OOPS_RUNNER_POOLS is the workflow's own vars.RUNNER_POOLS, for CI_OOPS_POOLS_REPO (its repository).
HOSTED_LABEL = re.compile(r"^(?:ubuntu|macos|windows)-(?:latest|\d[\w.-]*)$")
DEAD_LABEL_NOTE = "its runner label cannot run here yet"


def dead_label(ctx: dict, env=None) -> str:
    """Why a re-run now would be refused like the red (a hosted label still in RUNNER_POOLS), else ""."""
    env = os.environ if env is None else env
    labels = [str(x) for x in ctx.get("labels") or []]
    hosted = [x for x in labels if HOSTED_LABEL.match(x)]
    if not hosted or ctx.get("repo") != env.get("CI_OOPS_POOLS_REPO"):
        return ""
    try:
        pools = json.loads(env.get("CI_OOPS_RUNNER_POOLS") or "{}")
    except ValueError:
        return ""
    values = [v for v in (pools.values() if isinstance(pools, dict) else []) if isinstance(v, str)]
    still = sorted({v for v in values if HOSTED_LABEL.match(v)})
    if not still:
        return ""
    return f"{DEAD_LABEL_NOTE}: the job ran on {hosted[0]} and RUNNER_POOLS still names {', '.join(still)}"


def plan(verdict: dict, ctx: dict, run: dict, pr_head: str | None) -> tuple[str, str, str | None]:
    """(outcome, note, endpoint) for this red: the endpoint is the re-run POST path, or None when no re-run is due."""
    repo, run_id = ctx.get("repo"), ctx.get("run_id")
    attempt = int(ctx.get("run_attempt") or 1)
    name = " ".join(str(x or "") for x in (ctx.get("workflow"), ctx.get("workflow_path"), run.get("name"), run.get("path")))
    if PROTECTED.search(name):
        return "blocking", f"protected workflow ({name.strip()[:80]}): its owner re-runs it", None
    if run.get("status") not in (None, "completed"):
        return "skipped", f"run is {run.get('status')}: someone re-ran it already", None
    now_attempt = int(run.get("run_attempt") or attempt)
    if now_attempt > attempt:
        return "skipped", f"run is at attempt {now_attempt} already (red was attempt {attempt})", None
    head = ctx.get("head_sha")
    if pr_head and head and pr_head != head:
        return "skipped", f"PR head moved to {pr_head[:10]}: this run is superseded", None
    cap = MAX_ATTEMPTS
    if isinstance(verdict.get("retries"), int):
        cap = min(cap, verdict["retries"] + 1)
    if attempt >= cap:
        return "gave_up", f"attempt {attempt} is the last this rule earns ({cap}): stays red", None
    dead = dead_label(ctx)
    if dead:
        return "skipped", dead, None  # pending: the sweep asks again next pass, once the pool is fixed
    jobs = [j for j in (ctx.get("class_jobs") or [ctx.get("job_id")]) if j]
    if ctx.get("all_failed") or len(jobs) != 1:
        return "retried", f"re-ran the failed jobs of attempt {attempt}", f"repos/{repo}/actions/runs/{run_id}/rerun-failed-jobs"
    return "retried", f"re-ran job {ctx.get('job')!r} of attempt {attempt}", f"repos/{repo}/actions/jobs/{jobs[0]}/rerun"


def act(verdict: dict, ctx: dict, dry_run: bool, runner=subprocess.run) -> dict:
    repo, run_id = ctx.get("repo"), ctx.get("run_id")
    if not repo or not run_id:
        return {"outcome": "gave_up", "note": "no repo or run_id in ctx"}
    try:
        run = gh("GET", f"repos/{repo}/actions/runs/{run_id}", runner)
        pr_head = None
        if ctx.get("pr"):
            pr_head = (gh("GET", f"repos/{repo}/pulls/{ctx['pr']}", runner).get("head") or {}).get("sha")
    except RuntimeError as err:
        return {"outcome": "gave_up", "note": f"unread: {err}"[:300]}
    outcome, note, endpoint = plan(verdict, ctx, run, pr_head)
    if endpoint is None:
        got = {"outcome": outcome, "note": note}
        if note.startswith(DEAD_LABEL_NOTE):
            got["pending"] = True
        return got
    if dry_run:
        return {"outcome": "retried", "note": "dry run: would POST " + endpoint, "dry_run": True}
    try:
        gh("POST", endpoint, runner)
    except RuntimeError as err:
        return {"outcome": "gave_up", "note": f"re-run refused: {err}"[:300]}
    return {"outcome": outcome, "note": note, "next_attempt": int(ctx.get("run_attempt") or 1) + 1}
