#!/usr/bin/env python3
"""Dispatch `cmux ios verify (auto)` again for heads whose simulator steps were parked in the fleet queue and have run.

cmux-next-ios-verify-auto.yml's verify job held a Mac gateway runner while its simulator steps waited in the fleet
queue, whose p90 wait was 272-295 min on 2026-11-28 against the job's 150 min bound: in one hour 4 of 17 verify jobs
were cancelled at 150 min and 2 more ran 114 and 122 min, about 740 of the workflow's 888 runner minutes, and none of
them posted a record (job 141098698495: "step c1ec4df778628e734c89d987 still queued after 141 min"). Now
ios_verify.py --queue-timeout stops waiting (exit 75, the steps keep their place) and the job saves an empty cache
keyed PARKED_PREFIX + "PR-HEAD-ID.ID" (one cheap list here, no artifact or comment). This, on a schedule:

1. lists the parked keys (one API read);
2. drops a key older than MAX_AGE_S, or whose pull request is closed or moved past that head;
3. reads each step with `cmux-ci status ID`; a step still LIVE keeps the key for the next pass. The scheduled job
   runs on cmux-linux, which has no route to the tailnet-only controller (tests/test_ci_gateway_jobs_on_linux.py
   bars a new gateway Mac job), so there every step reads "unread" and the head is dispatched: that run parks
   again after REQUEUE_QUEUE_TIMEOUT if its steps are still queued;
4. otherwise dispatches the verify run for that head (it attaches to the same steps by their keys, which the
   controller answers with the step it has, done or archived, and posts the record), and drops the key.

A dispatched run that finds a step queued again (a step another head superseded) parks it again.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys

PARKED_PREFIX = "ios-verify-parked-"
KEY = re.compile(r"^ios-verify-parked-(\d+)-([0-9a-f]{40})-([0-9a-f.]+)$")
# The controller's states for a step that has not ended yet (build-fleet/ci-client.py); any other answer, an unread
# step included, ends the wait: the dispatched run reattaches by key, or runs the step again.
LIVE = {"queued", "claimed", "leased", "preparing", "running", "artifact_pending"}
MAX_AGE_S = 12 * 3600
MAX_DISPATCH = 10
WORKFLOW = "cmux-next-ios-verify-auto.yml"
REQUEUE_QUEUE_TIMEOUT = "120"


def run(*cmd: str, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout)


def parse(key: str) -> tuple[int, str, list[str]] | None:
    m = KEY.match(key)
    if not m:
        return None
    ids = [i for i in m.group(3).split(".") if i]
    return int(m.group(1)), m.group(2), ids


def age_s(created_at: str, now: dt.datetime) -> float:
    return (now - dt.datetime.fromisoformat(created_at.replace("Z", "+00:00"))).total_seconds()


def parked(repo: str, gh=run) -> list[dict]:
    p = gh("gh", "api", f"repos/{repo}/actions/caches?key={PARKED_PREFIX}&per_page=100")
    if p.returncode != 0:
        raise SystemExit(f"ios verify requeue: caches not listed: {p.stderr.strip()[-300:]}")
    return json.loads(p.stdout or "{}").get("actions_caches") or []


def step_state(step_id: str, ci=run) -> str:
    try:
        p = ci("cmux-ci", "status", step_id)
        return (json.loads(p.stdout) if p.returncode == 0 else {}).get("state") or "unread"
    except (ValueError, subprocess.TimeoutExpired, OSError):
        return "unread"


def decide(entry: dict, repo: str, now: dt.datetime, gh=run, ci=run) -> tuple[str, str]:
    """('drop' | 'wait' | 'dispatch', why) for one parked cache entry."""
    got = parse(entry.get("key") or "")
    if got is None:
        return "drop", "not a parked key"
    pr, sha, ids = got
    if age_s(entry.get("created_at") or entry.get("last_accessed_at") or "", now) > MAX_AGE_S:
        return "drop", f"parked over {MAX_AGE_S // 3600} h"
    p = gh("gh", "api", f"repos/{repo}/pulls/{pr}", "--jq", '[.state, .head.sha] | @tsv')
    if p.returncode != 0:
        return "wait", f"#{pr} not read"
    state, _, head = p.stdout.strip().partition("\t")
    if state != "open":
        return "drop", f"#{pr} is {state}"
    if head != sha:
        return "drop", f"#{pr} moved to {head[:12]}; that head has its own run"
    live = [(i, s) for i in ids if (s := step_state(i, ci)) in LIVE]
    if live:
        return "wait", ", ".join(f"{i} {s}" for i, s in live)
    return "dispatch", f"#{pr} at {sha[:12]}: steps {', '.join(ids) or 'none'} ended"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=os.environ.get("REPO", ""))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    sent = 0
    for entry in parked(a.repo):
        verdict, why = decide(entry, a.repo, now)
        key = entry["key"]
        if verdict == "dispatch" and sent >= MAX_DISPATCH:
            verdict, why = "wait", f"{MAX_DISPATCH} dispatched this pass"
        print(f"{verdict}: {key}: {why}")
        if a.dry_run or verdict == "wait":
            continue
        if verdict == "dispatch":
            pr, sha, _ = parse(key)
            p = run("gh", "workflow", "run", WORKFLOW, "--repo", a.repo, "--ref", "feat-cmux-next",
                    "-f", f"pr={pr}", "-f", f"sha={sha}", "-f", f"queue_timeout={REQUEUE_QUEUE_TIMEOUT}")
            if p.returncode != 0:
                print(f"  dispatch refused: {p.stderr.strip()[-300:]}; kept for the next pass")
                continue
            sent += 1
        d = run("gh", "api", "-X", "DELETE", f"repos/{a.repo}/actions/caches?key={key}")
        if d.returncode != 0:
            print(f"  key not dropped: {d.stderr.strip()[-200:]}")
    print(f"ios verify requeue: {sent} dispatched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
