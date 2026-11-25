#!/usr/bin/env python3
"""Live hit rate of a shadow content-addressed check: would-skip runs over eligible runs, and minutes they took.

Jobs and their seconds come from the controller's timing feed (no GitHub quota); each job's verdict comes from
its `ci-receipt shadow` annotation (one `gh api` call per job, newest first, at most --limit). A job with no such
annotation scanned nothing (no project selected) or predates the shadow step, and is not eligible.

  python3 scripts/ci/receipt_shadow_rate.py --since 2026-11-20T13:00:00Z [--limit 300]
"""
from __future__ import annotations

import argparse
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

FEED = "http://100.89.225.106:18765/v1/github/timing/records"
WORKFLOW = "cmux-next React Doctor"
JOB = "React Doctor (changed React projects)"
VERDICT = re.compile(r"would_skip=(true|false)")


def epoch(stamp: str) -> int:
    return int(datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())


def jobs(repo: str, since: int) -> list[dict]:
    found, cursor = {}, since
    while True:
        status, body, _ = deadline_http.request(f"{FEED}?repo={repo}&since={cursor}&limit=20000", 120)
        if status != 200:
            raise SystemExit(f"timing feed answered {status}")
        page = json.loads(body)
        records = page.get("records", [])
        for r in records:
            if r.get("workflow") == WORKFLOW and r.get("job") == JOB:
                found[(r["id"], r.get("attempt"))] = r
        if not page.get("more") or not records:
            return sorted(found.values(), key=lambda r: r["at"], reverse=True)
        cursor = max(cursor + 1, epoch(records[-1]["at"]))


def verdict(repo: str, job_id: int) -> str | None:
    out = subprocess.run(["gh", "api", f"repos/{repo}/check-runs/{job_id}/annotations"], capture_output=True,
                         text=True, timeout=60)
    if out.returncode != 0:
        return None
    for note in json.loads(out.stdout or "[]"):
        if note.get("title") == "ci-receipt shadow":
            match = VERDICT.search(note.get("message", ""))
            if match:
                return match.group(1)
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--since", required=True, help="UTC, e.g. 2026-11-20T13:00:00Z (after the shadow step landed)")
    parser.add_argument("--repo", default="manaflow-ai/cmux")
    parser.add_argument("--limit", type=int, default=300, help="newest jobs to read verdicts for")
    args = parser.parse_args(argv)
    rows = jobs(args.repo, epoch(args.since))
    counts = {"true": [0, 0], "false": [0, 0]}
    read = 0
    for r in rows[: args.limit]:
        v = verdict(args.repo, r["id"])
        read += 1
        if v:
            counts[v][0] += 1
            counts[v][1] += r.get("seconds") or 0
    eligible = counts["true"][0] + counts["false"][0]
    rate = counts["true"][0] / eligible if eligible else 0.0
    print(json.dumps({"since": args.since, "jobs_in_feed": len(rows), "jobs_read": read, "eligible": eligible,
                      "would_skip": counts["true"][0], "hit_rate": round(rate, 3),
                      "would_skip_minutes": round(counts["true"][1] / 60, 1),
                      "eligible_minutes": round((counts["true"][1] + counts["false"][1]) / 60, 1)}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
