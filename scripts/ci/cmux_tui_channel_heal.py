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

CLOUD_MACHINE (cmux_tui_channel_heal.py --cloud-machine; the workflow's second step): the Cloud machine channel
(files.cmux.com/cmux-tui/channels/cloud-machine.json) is moved only by cmux-machine-channel.yml's point jobs, on push,
and nothing reran a failed build: 2026-11-28 the kernel OOM-killed the acpmux rustc on both legs of runs 46151055654
and 46154021183 and the channel held f3ac175f for about 3 h (cmuxterm-hq goals/fix-running-cloud-channel.md, bound
60 min; cmux#64759, cmux#64901). That workflow pushes on nearly every merge and has no workflow_dispatch, so this
mode never dispatches and never waits for runs in flight (some always are). When the oldest missing cmux-tui/ change
on the branch is over CLOUD_LAG_MIN (25) minutes old, it takes the newest completed run that ran long enough to have
built (CLOUD_MIN_RUN_MIN, 8 minutes: a run whose plan a newer push replaced ends in seconds, and those are routine),
reads its jobs once, and reruns its failed jobs when a build-machine-channel job failed and it has attempts left.
None while a rerun (attempt > 1) is in flight, so reruns never stack. The point stays forward-only, so a rerun of
an older commit never moves the channel back. Two GitHub reads a tick at most.

Usage: cmux_tui_channel_heal.py [--dry-run] [--cloud-machine]
Env: GH_TOKEN (actions: write), GITHUB_REPOSITORY, CHANNEL_URL, BRANCH (default feat-cmux-next),
     HEAL_LAG_MIN (default 45), HEAL_RERUN_MAX_AGE_H (default 6), HEAL_MAX_ATTEMPT (default 3),
     HEAL_ALARM_MIN (default 180; 0 turns the alarm off).
"""

from __future__ import annotations

import base64
import calendar
import json
import os
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass

WORKFLOW = "cmux-tui-artifacts.yml"


CLOUD_WORKFLOW = "cmux-machine-channel.yml"
CLOUD_CHANNEL_URL = "https://files.cmux.com/cmux-tui/channels/cloud-machine.json"
# The Cloud channel's lag is the NOW metric's (cmuxterm-hq tools/fleet-reconcilers/now_deploy_lag.py, cloud-channel):
# changes under cmux-tui/ only, since a merge that changes no build input moves no channel. The runs read takes 100
# (one call): pushes come about once a minute, and a failed 15-minute build ends behind the 20 or so started since.
CLOUD_LAG_PATHS = ("cmux-tui/",)
IN_FLIGHT = ("queued", "in_progress", "waiting", "pending", "requested")


@dataclass
class Run:
    id: int
    status: str
    conclusion: str | None
    attempt: int
    created: float  # unix seconds
    minutes: float = 0.0  # run_started_at to updated_at: how long the attempt ran


def _ts(value: str | None) -> float | None:
    return calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")) if value else None


def parse_runs(payload: dict) -> list[Run]:
    runs = []
    for r in payload.get("workflow_runs", []):
        created = _ts(r["created_at"])
        started, updated = _ts(r.get("run_started_at")) or created, _ts(r.get("updated_at"))
        minutes = (updated - started) / 60 if updated is not None else 0.0
        runs.append(Run(int(r["id"]), r["status"], r.get("conclusion"), int(r.get("run_attempt") or 1), created,
                        minutes))
    return runs


def cloud_candidate(lag_min: float | None, runs: list[Run], now: float, *, lag_bound: float = 25,
                    min_run_min: float = 8, rerun_max_age_h: float = 6,
                    max_attempt: int = 2) -> tuple[str, int | None, str]:
    """The Cloud machine channel's first step: (fresh | waiting | candidate | none, run_id, why). A candidate is the
    run whose jobs to read (build_failed decides the rerun). No dispatch: cmux-machine-channel.yml has none."""
    if lag_min is not None and lag_min < lag_bound:
        return "fresh", None, f"oldest missing cmux-tui/ change {lag_min:.0f} min old (bound {lag_bound:.0f})"
    lag_txt = "unknown" if lag_min is None else f"{lag_min:.0f} min"
    for r in runs:
        if r.status in IN_FLIGHT and r.attempt > 1:
            return "waiting", r.id, f"lag {lag_txt}; rerun {r.id} (attempt {r.attempt}) is {r.status}"
    for r in runs:  # newest first
        if r.status != "completed" or r.minutes < min_run_min or now - r.created >= rerun_max_age_h * 3600:
            continue
        if r.conclusion in ("failure", "cancelled") and r.attempt < max_attempt:
            return "candidate", r.id, f"lag {lag_txt}; newest built run {r.id} ended {r.conclusion}"
        return "none", r.id, f"lag {lag_txt}; newest built run {r.id} ended {r.conclusion} (attempt {r.attempt})"
    return "none", None, f"lag {lag_txt}; no recent run that built"


def build_failed(jobs: dict) -> list[str]:
    """The failed build-machine-channel jobs of a run's latest attempt (a cancelled one counts: a newer push's
    pending job replaced it). A failed twin, point or roll alone is not rerun: it waits on another run's build."""
    return [j.get("name", "") for j in jobs.get("jobs", [])
            if j.get("name", "").startswith("build-machine-channel") and j.get("conclusion") == "failure"]


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


HERE = os.path.dirname(os.path.abspath(__file__))


class GhError(RuntimeError):
    pass


def gh(method: str, path: str, body: dict | None = None) -> dict:
    """`gh api` through scripts/ci/gh_budget_wait.sh, so a spent github.token budget is waited out (within
    the job's 5 minutes) instead of failing the tick. 2026-11-25 20:43Z and 21:29Z: the runs read exited 1
    and the tick died on a bare CalledProcessError, gh's own stderr captured and never printed."""
    wrapper = os.path.join(HERE, "gh_budget_wait.sh")
    args = (["bash", wrapper] if os.path.isfile(wrapper) else ["gh"]) + ["api", "-X", method, path]
    if body is not None:
        args += ["--input", "-"]
    env = dict(os.environ)
    env.setdefault("GH_BUDGET_WAIT_MAX_SECONDS", "150")
    proc = subprocess.run(args, input=json.dumps(body) if body is not None else None, text=True,
                          capture_output=True, env=env)
    if proc.returncode != 0:
        said = " | ".join((proc.stderr or proc.stdout or "").strip().splitlines()[-4:]) or "no output"
        raise GhError(f"gh api -X {method} {path} exited {proc.returncode}: {said}")
    return json.loads(proc.stdout) if proc.stdout.strip() else {}


def channel_commit(url: str) -> str:
    # files.cmux.com (Cloudflare) answers urllib's default User-Agent with 403, error code 1010.
    req = urllib.request.Request(f"{url}?heal={int(time.time())}", headers={"User-Agent": "cmux-ci/cmux-tui-channel-heal"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        doc = json.load(resp)
    # cloud-machine.json is signed: {"payload": base64 of the JSON that names the commit, "signature": ...}.
    if isinstance(doc.get("payload"), str) and "commit" not in doc:
        doc = json.loads(base64.b64decode(doc["payload"]))
    return str(doc.get("commit") or "")


def lag_minutes(commit: str, branch: str, now: float, paths: tuple[str, ...] = ()) -> float | None:
    """Age in minutes of the oldest first-parent commit on origin/BRANCH that COMMIT lacks (touching PATHS, when
    given). 0 when nothing is missing; None when git cannot tell (commit not in the fetched history)."""
    ok = subprocess.run(["git", "cat-file", "-e", f"{commit}^{{commit}}"], capture_output=True)
    if not commit or ok.returncode != 0:
        return None
    out = subprocess.run(["git", "log", "--first-parent", "--format=%ct", f"{commit}..origin/{branch}",
                          *(["--", *paths] if paths else [])],
                         text=True, capture_output=True, check=True).stdout.split()
    if not out:
        return 0.0
    return (now - int(out[-1])) / 60


def cloud_main(dry: bool) -> int:
    repo = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    branch = os.environ.get("BRANCH", "feat-cmux-next")
    now = time.time()
    commit = channel_commit(os.environ.get("CLOUD_CHANNEL_URL", CLOUD_CHANNEL_URL))
    lag = lag_minutes(commit, branch, now, CLOUD_LAG_PATHS)
    runs = parse_runs(gh("GET", f"repos/{repo}/actions/workflows/{CLOUD_WORKFLOW}/runs?branch={branch}"
                                f"&event=push&per_page=100"))
    action, run_id, why = cloud_candidate(lag, runs, now,
                                          lag_bound=float(os.environ.get("CLOUD_LAG_MIN", "25")),
                                          min_run_min=float(os.environ.get("CLOUD_MIN_RUN_MIN", "8")),
                                          max_attempt=int(os.environ.get("CLOUD_MAX_ATTEMPT", "2")))
    line = alarm(lag, runs, float(os.environ.get("CLOUD_ALARM_MIN", "120")))
    if line:
        line = line.replace("feat-cmux-next channel stalled", "Cloud machine channel stalled")
    if action == "candidate":
        failed = build_failed(gh("GET", f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"))
        if failed:
            why += f"; failed builds: {', '.join(failed)}"
            action = "rerun"
        else:
            action, why = "none", why + "; no build-machine-channel job failed"
    print(f"cloud-channel-heal: channel {commit[:12] or '?'} action={action} {why}")
    if action == "rerun" and not dry:
        gh("POST", f"repos/{repo}/actions/runs/{run_id}/rerun-failed-jobs")
        print(f"cloud-channel-heal: reran the failed jobs of https://github.com/{repo}/actions/runs/{run_id}")
    if line:
        print(line)
        return 0 if dry else 1
    return 0


def main() -> int:
    dry = "--dry-run" in sys.argv[1:]
    if "--cloud-machine" in sys.argv[1:]:
        return cloud_main(dry)
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
    try:
        sys.exit(main())
    except GhError as err:
        print(f"::error title=channel heal could not reach GitHub::{err}", flush=True)
        sys.exit(1)
