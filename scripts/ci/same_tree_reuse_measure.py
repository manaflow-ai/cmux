#!/usr/bin/env python3
"""How many pull request job-runs ran on a tree that already had a green run of the same job.

    same_tree_reuse_measure.py --runs DIR --jobs FEED.jsonl --repo-dir CHECKOUT [--prs LIST] [--json OUT]

The before number for scripts/ci/same_tree_reuse.py, and its detector over time: when this stays above zero for a
wired job, reuse is missing hits it should take; for a denied job it says what the deny costs.

- --runs: Actions run listings (`GET /repos/OWNER/REPO/actions/runs?event=pull_request&branch=REF`, any number of
  pages, one JSON file each, `<pr>.json` or `<pr>.pN.json`). Each run gives its workflow file, head commit tree and
  start time; no further API call.
- --jobs: job timings, one JSON object a line with `run`, `job`, `id`, `attempt`, `conclusion`, `seconds` (the
  fleet timing feed's shape).
- --repo-dir: a checkout with feat-cmux-next's first-parent history, for the base tip at each run's start.

Three keys, from narrow to broad:
  exact_commit  the same run (a re-run of a job that passed: should be 0, GitHub re-runs only failed jobs);
  merge_tree    head tree + base tip at the run's start: what a pull_request job tests (its merge commit's tree);
  head_tree     the head tree alone: the upper bound, right only for a job that checks out the head.
A job-run counts as a duplicate when an earlier job-run of the same workflow and job on the same key passed.
"""
from __future__ import annotations

import argparse
import bisect
import glob
import json
import os
import subprocess
import sys
from datetime import datetime


def ts(text: str) -> float:
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def load_runs(directory: str, prs: set[int] | None) -> dict[int, dict]:
    runs = {}
    for path in glob.glob(os.path.join(directory, "*.json")):
        try:
            pr = int(os.path.basename(path).split(".")[0])
        except ValueError:
            continue
        if prs is not None and pr not in prs:
            continue
        for run in json.load(open(path)).get("workflow_runs", []):
            runs[run["id"]] = {"pr": pr, "path": run["path"], "tree": (run.get("head_commit") or {}).get("tree_id"),
                               "sha": run["head_sha"], "created": ts(run["created_at"])}
    return runs


def base_tips(repo_dir: str, since: str = "2026-01-01") -> tuple[list[int], list[str]]:
    out = subprocess.run(["git", "-C", repo_dir, "log", "--first-parent", "--format=%ct %T", "origin/feat-cmux-next",
                          f"--since={since}"], capture_output=True, text=True, check=True).stdout
    tips = sorted((int(a), b) for a, b in (line.split() for line in out.splitlines() if line.strip()))
    return [t for t, _ in tips], [tree for _, tree in tips]


def analyse(jobs: list[dict], key) -> dict:
    seen = set()
    per: dict[str, list[float]] = {}
    total_n = total_s = dup_n = dup_s = 0
    for job in sorted(jobs, key=lambda j: (j["created"], j["attempt"], j["id"])):
        if job["conclusion"] in ("skipped", None):
            continue
        k = key(job)
        name = f'{job["path"]}::{job["job"]}'
        row = per.setdefault(name, [0, 0.0, 0, 0.0])
        seconds = job["seconds"] or 0
        total_n += 1
        total_s += seconds
        row[0] += 1
        row[1] += seconds
        if k in seen and seconds:
            dup_n += 1
            dup_s += seconds
            row[2] += 1
            row[3] += seconds
        if job["conclusion"] == "success":
            seen.add(k)
    return {"job_runs": total_n, "minutes": round(total_s / 60), "dup_job_runs": dup_n, "dup_minutes": round(dup_s / 60),
            "per": {k: {"runs": v[0], "min": round(v[1] / 60, 1), "dup_runs": v[2], "dup_min": round(v[3] / 60, 1)}
                    for k, v in per.items()}}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--runs", required=True, action="append")
    parser.add_argument("--jobs", required=True)
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--prs", help="a file whose lines start with the PR numbers to count")
    parser.add_argument("--json")
    args = parser.parse_args(argv)
    prs = {int(line.split()[0]) for line in open(args.prs) if line.strip()} if args.prs else None
    runs = {}
    for directory in args.runs:
        runs.update(load_runs(directory, prs))
    times, trees = base_tips(args.repo_dir)

    def base_at(t: float) -> str | None:
        i = bisect.bisect_right(times, t) - 1
        return trees[i] if i >= 0 else None

    jobs = []
    with open(args.jobs) as feed:
        for line in feed:
            if '"run":' not in line:
                continue
            job = json.loads(line)
            run = runs.get(job.get("run"))
            if run:
                jobs.append({**job, **run})
    out = {
        "prs": len({j["pr"] for j in jobs}), "runs": len(runs),
        "exact_commit": analyse(jobs, lambda j: (j["path"], j["job"], j["sha"], j["run"])),
        "merge_tree": analyse(jobs, lambda j: (j["path"], j["job"], j["tree"], base_at(j["created"]))),
        "head_tree": analyse(jobs, lambda j: (j["path"], j["job"], j["tree"])),
    }
    for name in ("exact_commit", "merge_tree", "head_tree"):
        o = out[name]
        print(f"{name}: {o['dup_job_runs']} of {o['job_runs']} job-runs, {o['dup_minutes']} of {o['minutes']} min "
              "on a tree that already had a green run of the same job")
    if args.json:
        with open(args.json, "w") as handle:
            json.dump(out, handle, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
