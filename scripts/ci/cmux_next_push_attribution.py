#!/usr/bin/env python3
"""Name the pull requests behind a red cmux-next push run on feat-cmux-next.

Pull requests run only the cmux-next tiers their change reaches, and every
feat-cmux-next push runs them all as a backstop (superseded pushes skip their
Mac jobs, so a burst of merges is checked once, at its newest commit). When a
push run fails, this finds, for each failed job, the newest earlier push run
where the same job passed, and comments on every pull request merged in that
range: one of them broke it, and its lane fixes forward.

The run's code never executes here; it reads the Actions and pulls APIs.

Usage: cmux_next_push_attribution.py --repo OWNER/NAME --run-id ID --sha SHA
       [--workflow cmux-next.yml] [--branch feat-cmux-next] [--dry-run]
       [--events push[,workflow_dispatch]] [--summary FILE]

--events adds workflow_dispatch runs of the branch to the scan: the tree jobs
(daemon tests, scheme compile) of a push whose same-tree cmux-tui was published
after its run probed it pass or fail in a same-tree mode dispatch run.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

MARKER = "<!-- cmux-next-push-attribution:{run_id} -->"
# Jobs that report rather than check.
IGNORED_JOBS = ("cmux-next push attribution", "cmux-next generated autofix")
SCANNED_RUNS = 40
# Past this many candidates a comment on each is noise (a job red for a long
# while): the run summary lists the range instead.
MAX_COMMENTED_PRS = 5


def should_comment(numbers: list[int]) -> bool:
    return 0 < len(numbers) <= MAX_COMMENTED_PRS


def gh_api(path: str) -> object:
    output = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return json.loads(output)


def run_jobs(repo: str, run_id: int) -> dict[str, str]:
    """Job name -> conclusion for one run's latest attempt."""
    jobs = gh_api(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")["jobs"]
    return {job["name"]: job.get("conclusion") or "" for job in jobs}


def failed_jobs(jobs: dict[str, str]) -> list[str]:
    return sorted(name for name, conclusion in jobs.items()
                  if conclusion in ("failure", "timed_out") and name not in IGNORED_JOBS)


def last_green(failed: list[str], earlier: list[tuple[str, dict[str, str]]]) -> str | None:
    """The newest earlier head SHA where every failed job passed.

    `earlier` is (head_sha, job conclusions), newest first. A job that was
    skipped (a superseded push) says nothing; only a pass counts. The range
    starts at the oldest of the per-job last passes, so it holds every
    candidate for each failed job.
    """
    found: dict[str, int] = {}
    for index, (_, jobs) in enumerate(earlier):
        for name in failed:
            if name not in found and jobs.get(name) == "success":
                found[name] = index
        if len(found) == len(failed):
            return earlier[max(found.values())][0]
    return None


def pull_requests(repo: str, base: str, head: str, branch: str) -> list[int]:
    compare = gh_api(f"repos/{repo}/compare/{base}...{head}")
    numbers: list[int] = []
    for commit in compare.get("commits", []):
        for pull in gh_api(f"repos/{repo}/commits/{commit['sha']}/pulls"):
            if pull.get("base", {}).get("ref") == branch and pull.get("merged_at") and pull["number"] not in numbers:
                numbers.append(pull["number"])
    return numbers


def comment_body(run_url: str, sha: str, failed: list[str], good: str, numbers: list[int], run_id: int) -> str:
    others = ", ".join(f"#{n}" for n in numbers)
    return "\n".join([
        MARKER.format(run_id=run_id),
        f"The feat-cmux-next push run {run_url} at {sha[:10]} failed: {', '.join(failed)}.",
        f"Those jobs last passed at {good[:10]}. This pull request is one of {len(numbers)} merged since: {others}.",
        "If the failure is in your change, fix forward on feat-cmux-next. Pull requests run only the tiers "
        "their paths reach (docs/ci/cmux-next-tiers.md); label a batch PR full-ci to run them all before merging.",
    ])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--workflow", default="cmux-next.yml")
    parser.add_argument("--branch", default="feat-cmux-next")
    parser.add_argument("--server-url", default="https://github.com")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--events", default="push",
                        help="comma-separated run events to scan for the last pass (push, workflow_dispatch)")
    args = parser.parse_args(argv)

    def report(text: str) -> None:
        print(text)
        if args.summary:
            with args.summary.open("a", encoding="utf-8") as stream:
                stream.write(text + "\n")

    failed = failed_jobs(run_jobs(args.repo, args.run_id))
    if not failed:
        report("No failed check job in this run.")
        return 0
    events = [event for event in args.events.split(",") if event in ("push", "workflow_dispatch")] or ["push"]
    runs = sorted(
        (
            run
            for event in events
            for run in gh_api(
                f"repos/{args.repo}/actions/workflows/{args.workflow}/runs"
                f"?branch={args.branch}&event={event}&per_page={SCANNED_RUNS}"
            )["workflow_runs"]
        ),
        key=lambda run: run["id"],
        reverse=True,
    )[:SCANNED_RUNS]
    earlier = [
        (run["head_sha"], run_jobs(args.repo, run["id"]))
        for run in runs
        if run["id"] < args.run_id and run["head_sha"] != args.sha and run.get("status") == "completed"
    ]
    good = last_green(failed, earlier)
    if good is None:
        report(f"{', '.join(failed)} did not pass in the last {SCANNED_RUNS} push runs; no culprit range.")
        return 0
    numbers = pull_requests(args.repo, good, args.sha, args.branch)
    run_url = f"{args.server_url}/{args.repo}/actions/runs/{args.run_id}"
    report(f"### cmux-next push attribution\n\nFailed: {', '.join(failed)}. Last passed at {good}. "
           f"Pull requests in range: {', '.join(f'#{n}' for n in numbers) or 'none'}.")
    if not should_comment(numbers):
        if numbers:
            report(f"{len(numbers)} pull requests in range: no comments (more than {MAX_COMMENTED_PRS}). "
                   "The job has been red for a while; its owner needs the run, not each author.")
        return 0
    body = comment_body(run_url, args.sha, failed, good, numbers, args.run_id)
    marker = MARKER.format(run_id=args.run_id)
    for number in numbers:
        comments = gh_api(f"repos/{args.repo}/issues/{number}/comments?per_page=100")
        if any(marker in (comment.get("body") or "") for comment in comments):
            continue
        if args.dry_run:
            print(f"--- would comment on #{number}:\n{body}")
            continue
        subprocess.run(["gh", "pr", "comment", str(number), "--repo", args.repo, "--body", body], check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
