#!/usr/bin/env python3
"""Move a stalled acpmux fleet channel without a person.

Every Linux host's `acpmux-update.timer` installs what
https://files.cmux.com/cmux-tui/channels/feat-cmux-next.json names, every 15 minutes. Only a
`cmux-tui-artifacts.yml` run's point-feat-channel job moves that file, so when a run dies (pool
runner exit 143, a flaky daemon test) the channel holds its last build until someone reruns it
(2026-11-24/25: a304d6a4 for 13 h while about 600 commits landed; docs/handbook in cmuxterm-hq,
channel-stops-following-its-branch.md).

Each tick (cmux-tui-channel-heal.yml, every 15 minutes) this reads the channel's commit, measures
how old the oldest feat-cmux-next first-parent commit it lacks is, and when that passes the bound
and no artifacts run on feat-cmux-next is queued or running, it takes one action:

  rerun     the newest failed run's failed jobs (it reuses that run's build), when that run is
            recent and has attempts left;
  dispatch  otherwise, a workflow_dispatch of cmux-tui-artifacts.yml on feat-cmux-next, which
            points the channel since cmux#55368.

The point job stays the only writer: it moves forward only, to a daemon-tested tree, so a rerun or
dispatch can never move the channel back. One action a tick, and none while a run is in flight,
so ticks never stack runs.

A rerun or a dispatch cannot fix a red that the merged code causes (a test that fails on every
run). From 2026-11-25 21:43Z to 2026-11-26 21:26Z every feat-cmux-next run failed the daemon tests
(full disk, then a compile error, then 36 settings rows missing from published-keys.txt) and this
job stayed green every tick for about 24 h. So after it acts, once the lag passes HEAL_ALARM_MIN
(default 180) the job prints an ::error naming the lag and the newest failed run and exits 1: the
scheduled run goes red, which is the alarm that the channel needs a fix, not another rerun.

Usage: cmux_tui_channel_heal.py [--dry-run]
Env: GH_TOKEN (actions: write), GITHUB_REPOSITORY, CHANNEL_URL, BRANCH (default feat-cmux-next),
     HEAL_LAG_MIN (default 45), HEAL_RERUN_MAX_AGE_H (default 6), HEAL_MAX_ATTEMPT (default 3),
     HEAL_ALARM_MIN (default 180; 0 turns the alarm off).
"""

from __future__ import annotations

import calendar
import json
import os
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass

WORKFLOW = "cmux-tui-artifacts.yml"


@dataclass
class Run:
    id: int
    status: str
    conclusion: str | None
    attempt: int
    created: float  # unix seconds


def parse_runs(payload: dict) -> list[Run]:
    runs = []
    for r in payload.get("workflow_runs", []):
        created = calendar.timegm(time.strptime(r["created_at"], "%Y-%m-%dT%H:%M:%SZ"))
        runs.append(Run(int(r["id"]), r["status"], r.get("conclusion"), int(r.get("run_attempt") or 1), created))
    return runs


def decide(lag_min: float | None, runs: list[Run], now: float, *, lag_bound: float = 45,
           rerun_max_age_h: float = 6, max_attempt: int = 3) -> tuple[str, int | None, str]:
    """Return (action, run_id, why). action is fresh, waiting, rerun or dispatch."""
    if lag_min is not None and lag_min < lag_bound:
        return "fresh", None, f"oldest missing commit {lag_min:.0f} min old (bound {lag_bound:.0f})"
    lag_txt = "unknown" if lag_min is None else f"{lag_min:.0f} min"
    for r in runs:
        if r.status in ("queued", "in_progress", "waiting", "pending", "requested"):
            return "waiting", r.id, f"lag {lag_txt}; run {r.id} is {r.status}"
    for r in runs:  # newest first, as the API lists them
        if r.status != "completed":
            continue
        if r.conclusion == "failure" and r.attempt < max_attempt and now - r.created < rerun_max_age_h * 3600:
            return "rerun", r.id, f"lag {lag_txt}; newest failed run {r.id} (attempt {r.attempt})"
        break
    return "dispatch", None, f"lag {lag_txt}; no recent failed run to rerun"


def alarm(lag_min: float | None, runs: list[Run], alarm_min: float) -> str | None:
    """The ::error line when the channel has lagged past ALARM_MIN minutes, else None (also when the lag is unknown
    or the alarm is off). It names the newest completed failed run, whose log holds the red to fix."""
    if alarm_min <= 0 or lag_min is None or lag_min < alarm_min:
        return None
    failed = next((r for r in runs if r.status == "completed" and r.conclusion == "failure"), None)
    where = f"; newest failed run {failed.id} (attempt {failed.attempt})" if failed else ""
    return (f"::error title=feat-cmux-next channel stalled::the channel lacks commits up to {lag_min / 60:.1f} h old "
            f"(alarm at {alarm_min / 60:.1f} h){where}. A rerun does not fix a red the merged code causes: read that "
            f"run's failed job and fix base.")


def gh(method: str, path: str, body: dict | None = None) -> dict:
    args = ["gh", "api", "-X", method, path]
    if body is not None:
        args += ["--input", "-"]
    out = subprocess.run(args, input=json.dumps(body) if body is not None else None, text=True,
                         capture_output=True, check=True).stdout
    return json.loads(out) if out.strip() else {}


def channel_commit(url: str) -> str:
    # files.cmux.com (Cloudflare) answers urllib's default User-Agent with 403, error code 1010.
    req = urllib.request.Request(f"{url}?heal={int(time.time())}", headers={"User-Agent": "cmux-ci/cmux-tui-channel-heal"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return str(json.load(resp).get("commit") or "")


def lag_minutes(commit: str, branch: str, now: float) -> float | None:
    """Age in minutes of the oldest first-parent commit on origin/BRANCH that COMMIT lacks.
    0 when nothing is missing; None when git cannot tell (commit not in the fetched history)."""
    ok = subprocess.run(["git", "cat-file", "-e", f"{commit}^{{commit}}"], capture_output=True)
    if not commit or ok.returncode != 0:
        return None
    out = subprocess.run(["git", "log", "--first-parent", "--format=%ct", f"{commit}..origin/{branch}"],
                         text=True, capture_output=True, check=True).stdout.split()
    if not out:
        return 0.0
    return (now - int(out[-1])) / 60


def main() -> int:
    dry = "--dry-run" in sys.argv[1:]
    repo = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    branch = os.environ.get("BRANCH", "feat-cmux-next")
    url = os.environ.get("CHANNEL_URL", f"https://files.cmux.com/cmux-tui/channels/{branch}.json")
    now = time.time()
    commit = channel_commit(url)
    lag = lag_minutes(commit, branch, now)
    runs = parse_runs(gh("GET", f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={branch}&per_page=20"))
    action, run_id, why = decide(lag, runs, now,
                                 lag_bound=float(os.environ.get("HEAL_LAG_MIN", "45")),
                                 rerun_max_age_h=float(os.environ.get("HEAL_RERUN_MAX_AGE_H", "6")),
                                 max_attempt=int(os.environ.get("HEAL_MAX_ATTEMPT", "3")))
    print(f"channel-heal: channel {commit[:12] or '?'} action={action} {why}")
    line = alarm(lag, runs, float(os.environ.get("HEAL_ALARM_MIN", "180")))
    if dry or action in ("fresh", "waiting"):
        if line:
            print(line)
        return 1 if line and not dry else 0
    if action == "rerun":
        gh("POST", f"repos/{repo}/actions/runs/{run_id}/rerun-failed-jobs")
        print(f"channel-heal: reran the failed jobs of https://github.com/{repo}/actions/runs/{run_id}")
    else:
        gh("POST", f"repos/{repo}/actions/workflows/{WORKFLOW}/dispatches", {"ref": branch})
        print(f"channel-heal: dispatched {WORKFLOW} on {branch}")
    if line:
        print(line)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
