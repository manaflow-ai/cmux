#!/usr/bin/env python3
"""Merge-to-channel minutes for feat-cmux-next merges: one harness for before and after (PR_HEAD_FAST_LANE).

For each merge commit SHA it reports the minutes from the merge (the squash commit's committer time, which
is GitHub's merged_at) to the end of the first successful job that pointed the Cloud machine channel at
that commit: cmux-machine-channel.yml's point-x86_64 / point-linux, or cmux-tui-artifacts.yml's
point-machine-channel(-early). It also names whether that run built (cargo) or took the PR head's build.

    gh auth token | GH_TOKEN=... python3 scripts/ci/cmux_machine_channel_latency.py SHA [SHA ...]
    python3 scripts/ci/cmux_machine_channel_latency.py --recent 10   # the newest feat-cmux-next pushes

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
WORKFLOWS = ("cmux-machine-channel.yml", "cmux-tui-artifacts.yml")
POINT_MARKS = ("point the Cloud machine channel", "point-x86_64", "point-linux", "point-machine-channel")


def api(path: str) -> object:
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        # A lane VM's broker sheds reads when busy ("retry after Ns"): back off, bounded.
        for wait in (15, 30, 60, 120, 0):
            out = subprocess.run(["gh", "api", f"repos/{REPO}/{path}"], capture_output=True, text=True, timeout=180)
            if out.returncode == 0:
                return json.loads(out.stdout)
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
    return any(m in name for m in POINT_MARKS) and "build" not in name.split("/")[-1]


def measure(sha: str) -> dict:
    commit = api(f"commits/{sha}")
    merged = ts(commit["commit"]["committer"]["date"])
    best = None
    for wf in WORKFLOWS:
        runs = api(f"actions/workflows/{wf}/runs?head_sha={sha}&event=push&per_page=10").get("workflow_runs", [])
        for run in runs:
            jobs = api(f"actions/runs/{run['id']}/jobs?per_page=100").get("jobs", [])
            built = any("build" in j["name"] and j.get("conclusion") == "success" and "cmux-tui" in j["name"].lower()
                        or "build-machine-channel" in j["name"] and j.get("conclusion") == "success" for j in jobs)
            for j in jobs:
                if is_point(j["name"]) and j.get("conclusion") == "success" and j.get("completed_at"):
                    done = ts(j["completed_at"])
                    if best is None or done < best[0]:
                        best = (done, wf, run["id"], j["name"], built)
    row = {"sha": sha[:12], "merged": merged.isoformat(), "subject": commit["commit"]["message"].splitlines()[0][:70]}
    if best:
        row.update(pointed=best[0].isoformat(), minutes=round((best[0] - merged).total_seconds() / 60, 1),
                   workflow=best[1], run=best[2], job=best[3], path="cargo here" if best[4] else "PR head build")
    return row


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("shas", nargs="*")
    ap.add_argument("--recent", type=int, default=0, help="the newest N feat-cmux-next commits")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    shas = list(args.shas)
    if args.recent:
        shas += [c["sha"] for c in api(f"commits?sha=feat-cmux-next&per_page={args.recent}")]
    rows = [measure(s) for s in shas]
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        for r in rows:
            print(f"{r['sha']}  {r.get('minutes', '-'):>6}  {r.get('path', 'not pointed'):<14} {r.get('run', '')}  {r['subject']}")
    mins = [r["minutes"] for r in rows if "minutes" in r]
    if mins:
        print(f"p50 {statistics.median(mins):.1f} min over {len(mins)} pointed of {len(rows)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
