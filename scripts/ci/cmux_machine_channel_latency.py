#!/usr/bin/env python3
"""Merge-to-channel minutes for feat-cmux-next merges: one harness for before and after (PR_HEAD_FAST_LANE).

For each of the newest feat-cmux-next commits it reports the minutes from the merge (the squash commit's
committer time, GitHub's merged_at) to the end of the first successful job that pointed the Cloud machine
channel at that commit or a newer one (a coalesced push carries the older merges): cmux-machine-channel.yml's
point-x86_64 / point-linux, or cmux-tui-artifacts.yml's point jobs. It names whether that run built (cargo)
or took the PR head's build.

    python3 scripts/ci/cmux_machine_channel_latency.py --recent 30 --skip 5

Read-only, stdlib only. GH_TOKEN, or `gh api` when it is unset (a lane VM's broker).
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
import urllib.request
from datetime import datetime

REPO = "manaflow-ai/cmux"
BRANCH = "feat-cmux-next"
WORKFLOWS = ("cmux-machine-channel.yml", "cmux-tui-artifacts.yml")
POINT = "point the Cloud machine channel"


def api(path: str) -> object:
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        # A lane VM's broker sheds reads when busy ("retry after Ns"): back off, bounded.
        for wait in (15, 30, 60, 120, 0):
            out = subprocess.run(["gh", "api", f"repos/{REPO}/{path}"], capture_output=True, text=True, timeout=180)
            if out.returncode == 0:
                return json.loads(out.stdout)
            if "HTTP 404" in out.stderr:
                return {}  # a workflow file that no longer exists has no runs
            if "in the last 10 minutes" in out.stderr and wait:
                time.sleep(150)  # the broker's per-caller jobs-read window
                continue
            if "retry after" not in out.stderr or not wait:
                raise RuntimeError(out.stderr.strip()[:300])
            time.sleep(wait)
    req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/{path}",
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def is_point(name: str) -> bool:
    return name.split(" / ")[-1].startswith(POINT)  # "... at this commit's x86_64 Linux build" is a point job


def is_build(name: str) -> bool:
    return name.split(" / ")[-1].startswith("build x86_64-unknown-linux-musl")


def workflow_ids() -> dict[int, str]:
    """Numeric ids of WORKFLOWS (by file name a workflow absent from main 404s; by id it lists)."""
    ids: dict[int, str] = {}
    for page in range(1, 11):
        wfs = api(f"actions/workflows?per_page=100&page={page}").get("workflows", [])
        ids.update({w["id"]: w["path"].rsplit("/", 1)[-1] for w in wfs if w["path"].rsplit("/", 1)[-1] in WORKFLOWS})
        if len(wfs) < 100:
            return ids
    return ids


def pointed_runs(since: datetime) -> dict[str, tuple]:
    """head sha -> (point job completed, workflow, run id, built here) for feat-cmux-next pushes since `since`."""
    out: dict[str, tuple] = {}
    for wf_id, wf in workflow_ids().items():
        for page in range(1, 11):
            runs = api(f"actions/workflows/{wf_id}/runs?branch={BRANCH}&event=push&per_page=100&page={page}").get(
                "workflow_runs", [])
            for run in runs:
                if ts(run["created_at"]) < since:
                    continue
                # A coalesced run skips build and point and ends within minutes: read jobs only of runs that worked.
                if (ts(run["updated_at"]) - ts(run.get("run_started_at") or run["created_at"])).total_seconds() < 360:
                    continue
                jobs = api(f"actions/runs/{run['id']}/jobs?per_page=100").get("jobs", [])
                ok = [j for j in jobs if j.get("conclusion") == "success"]
                built = any(is_build(j["name"]) for j in ok)
                for j in ok:
                    if is_point(j["name"]) and j.get("completed_at"):
                        done = ts(j["completed_at"])
                        have = out.get(run["head_sha"])
                        if have is None or done < have[0]:
                            out[run["head_sha"]] = (done, wf, run["id"], built)
            if not runs or ts(runs[-1]["created_at"]) < since:
                break
    return out


def measure(commits: list[dict], pointed: dict[str, tuple]) -> list[dict]:
    """Each merge's minutes until the channel named it or a newer commit (the coalesced push that carried it)."""
    rows = []
    for i, c in enumerate(commits):
        merged = ts(c["commit"]["committer"]["date"])
        row = {"sha": c["sha"][:12], "merged": merged.isoformat(), "subject": c["commit"]["message"].splitlines()[0][:70]}
        best = None
        for later in commits[: i + 1]:  # newest first: index <= i is this commit or a descendant on the branch
            hit = pointed.get(later["sha"])
            if hit and (best is None or hit[0] < best[0]):
                best = (*hit, later["sha"])
        if best:
            row.update(pointed=best[0].isoformat(), minutes=round((best[0] - merged).total_seconds() / 60, 1),
                       workflow=best[1], run=best[2], via=best[4][:12],
                       path=("cargo here" if best[3] else "PR head build") + ("" if best[4] == c["sha"] else " (coalesced)"))
        rows.append(row)
    return rows


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--recent", type=int, default=30, help="the newest N feat-cmux-next commits")
    ap.add_argument("--skip", type=int, default=0, help="leave out the newest K (their channel may not have moved yet)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    commits = api(f"commits?sha={BRANCH}&per_page={min(args.recent + args.skip, 100)}")
    since = min(ts(c["commit"]["committer"]["date"]) for c in commits)
    rows = measure(commits, pointed_runs(since))[args.skip:]
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        for r in rows:
            print(f"{r['sha']}  {r.get('minutes', '-'):>6}  {r.get('path', 'not pointed'):<26} {r.get('via', '')}  {r['subject']}")
    mins = [r["minutes"] for r in rows if "minutes" in r]
    if mins:
        print(f"p50 {statistics.median(mins):.1f} min, max {max(mins):.1f} over {len(mins)} pointed of {len(rows)}",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
