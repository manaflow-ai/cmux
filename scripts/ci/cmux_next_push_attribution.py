#!/usr/bin/env python3
"""Name the pull requests behind a red cmux-next push run on feat-cmux-next.

Pull requests run only the cmux-next tiers their change reaches, and every
feat-cmux-next push runs them all as a backstop (superseded pushes skip their
Mac jobs, so a burst of merges is checked once, at its newest commit). When a
push run fails, this finds, for each failed job, the newest earlier push run
where the same job passed, and updates the shared status comment on every pull
request merged in that range: one of them broke it, and its lane fixes forward.
The latest processed failure replaces the push-attribution section instead of
adding a timeline comment for each failed run.

The run's code never executes here; it reads the Actions and pulls APIs.

Usage: cmux_next_push_attribution.py --repo OWNER/NAME --run-id ID --sha SHA
       [--workflow cmux-next.yml] [--branch feat-cmux-next] [--dry-run]
       [--events push[,workflow_dispatch]] [--summary FILE]

--events adds workflow_dispatch runs of the branch to the scan: the tree jobs
(daemon tests, scheme compile) of a push whose same-tree cmux-tui was published
after its run probed it pass or fail in a same-tree mode dispatch run, and the
base Mac tier (daemon tests, generated files, scheme compile) runs only in the
`cmux-next base tier` dispatch, at most once every 15 minutes on the tip.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import pr_status

MARKER = "<!-- cmux-next-push-attribution:{run_id} -->"
# Jobs that report rather than check.
IGNORED_JOBS = ("cmux-next push attribution", "cmux-next generated autofix")
SCANNED_RUNS = 40
# Past this many candidates a comment on each is noise (a job red for a long
# while): the run summary lists the range instead.
MAX_COMMENTED_PRS = 5


# cmux-next.yml run names end in the commit the run tested: `cmux-next · <sha>` for a push, and
# `cmux-next base tier · <sha>` or `cmux-next tip daemon suite · <sha>` for a dispatch, whose
# same-tree run tests that commit after the branch moved on (its head_sha is the newer branch head).
TESTED_SHA = re.compile(r" · ([0-9a-f]{40})$")


def tested_sha(run: dict) -> str:
    """The commit a cmux-next.yml run tested: the sha its name ends in, else its head_sha."""
    match = TESTED_SHA.search(run.get("display_title") or run.get("name") or "")
    return match.group(1) if match else run["head_sha"]


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


def first_red_observed(failed: list[str], runs: list[tuple[str, dict[str, str]]], lower: str | None = None,
                      commits: list[str] | None = None) -> dict[str, str | None]:
    """Return a culprit only when every commit in LOWER..RED has a verdict.

    This is a history-backed bounded bisect: it never treats a skipped or
    missing run as green, and it refuses to name a culprit across an untested
    commit. ``commits`` is the compare API's first-parent list, oldest first;
    callers pass it only after validating the lower bound's ancestry.
    """
    found: dict[str, str | None] = {job: None for job in failed}
    verdict = {sha: jobs for sha, jobs in runs}
    order = list(commits or [sha for sha, _ in reversed(runs)])
    if lower and lower in order:
        order = order[order.index(lower) + 1:]
    for sha in order:
        jobs = verdict.get(sha)
        if not jobs:
            return found
        for job in failed:
            conclusion = jobs.get(job)
            if conclusion in (None, "", "skipped", "cancelled"):
                return found
            if found[job] is None and conclusion in ("failure", "timed_out", "startup_failure"):
                found[job] = sha
    return found


def never_passed(failed: list[str], earlier: list[tuple[str, dict[str, str]]]) -> list[str]:
    """Failed jobs with no pass in the scanned runs: red since before the range (or never
    run on a push before), so no merge in it is the culprit, and they must not hide the
    range of the jobs that did pass."""
    return [name for name in failed if not any(jobs.get(name) == "success" for _, jobs in earlier)]


def pull_requests(repo: str, base: str, head: str, branch: str) -> list[int]:
    compare = gh_api(f"repos/{repo}/compare/{base}...{head}")
    numbers: list[int] = []
    for commit in compare.get("commits", []):
        for pull in gh_api(f"repos/{repo}/commits/{commit['sha']}/pulls"):
            if pull.get("base", {}).get("ref") == branch and pull.get("merged_at") and pull["number"] not in numbers:
                numbers.append(pull["number"])
    return numbers


def compare_commits(repo: str, base: str, head: str) -> list[str]:
    """First-parent commit SHAs in a bounded compare response, oldest first."""
    compare = gh_api(f"repos/{repo}/compare/{base}...{head}")
    return [str(commit["sha"]) for commit in reversed(compare.get("commits", []))
            if re.fullmatch(r"[0-9a-f]{40}", str(commit.get("sha", "")))]


def pull_requests_for_commit(repo: str, sha: str, branch: str) -> list[int]:
    """Merged PRs whose merge commit or head commit is SHA, on BRANCH."""
    found: list[int] = []
    for pull in gh_api(f"repos/{repo}/commits/{sha}/pulls"):
        if pull.get("base", {}).get("ref") == branch and pull.get("merged_at"):
            number = pull.get("number")
            if isinstance(number, int):
                found.append(number)
    return found


def comment_body(run_url: str, sha: str, failed: list[str], good: str, numbers: list[int], run_id: int) -> str:
    others = ", ".join(f"#{n}" for n in numbers)
    return "\n".join([
        MARKER.format(run_id=run_id),
        f"The feat-cmux-next push run {run_url} at {sha[:10]} failed: {', '.join(failed)}.",
        f"Those jobs last passed at {good[:10]}. This pull request is one of {len(numbers)} merged since: {others}.",
        "If the failure is in your change, fix forward on feat-cmux-next. Pull requests run only the tiers "
        "their paths reach (docs/ci/cmux-next-tiers.md); label a batch PR full-ci to run them all before merging.",
    ])


def culprit_body(run_url: str, sha: str, job: str, culprit: str, run_id: int) -> str:
    """A bounded, evidence-backed comment for one exact observed culprit."""
    return "\n".join([
        f"<!-- cmux-next-push-culprit:{run_id}:{job} -->",
        f"The `{job}` check first went red after merged commit `{culprit}` (push run {run_url}).",
        f"This run tested `{sha}`; the lower bound was the reconciler's last-known-green when available.",
        "The attribution is based on a completed red run; skipped, missing, and infrastructure results stay unresolved.",
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
    parser.add_argument("--last-known-green", default="",
                        help="reconciler-published lower bound; malformed values are ignored")
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
        (tested_sha(run), run_jobs(args.repo, run["id"]))
        for run in runs
        if run["id"] < args.run_id and tested_sha(run) != args.sha and run.get("status") == "completed"
    ]
    long_red = never_passed(failed, earlier)
    if long_red:
        report(f"{', '.join(long_red)} did not pass in the last {SCANNED_RUNS} push runs; no culprit range for it.")
    failed = [name for name in failed if name not in long_red]
    good = last_green(failed, earlier) if failed else None
    if good is None:
        return 0
    numbers = pull_requests(args.repo, good, args.sha, args.branch)
    run_url = f"{args.server_url}/{args.repo}/actions/runs/{args.run_id}"
    lower = args.last_known_green if re.fullmatch(r"[0-9a-f]{40}", args.last_known_green or "") else good
    try:
        commit_order = compare_commits(args.repo, lower, args.sha)
    except (OSError, ValueError, subprocess.SubprocessError, KeyError):
        commit_order = []
    observed = first_red_observed(failed, earlier, lower, commit_order or None)
    exact: dict[int, str] = {}
    for job, culprit in observed.items():
        if not culprit:
            report(f"{job}: culprit unresolved (no completed red run after the lower bound).")
            continue
        prs = pull_requests_for_commit(args.repo, culprit, args.branch)
        if len(prs) == 1:
            exact[prs[0]] = culprit
            report(f"{job}: culprit #{prs[0]} at {culprit} (first completed red run after lower bound).")
        else:
            report(f"{job}: culprit unresolved at {culprit} ({len(prs)} merged PRs or a direct push).")
    report(f"### cmux-next push attribution\n\nFailed: {', '.join(failed)}. Last passed at {good}. "
           f"Pull requests in range: {', '.join(f'#{n}' for n in numbers) or 'none'}.")
    exact_body = {
        number: culprit_body(run_url, args.sha, "cmux-next", culprit, args.run_id)
        for number, culprit in exact.items()
    }
    for number, body in exact_body.items():
        if args.dry_run:
            print(f"--- would comment on exact culprit #{number}:\n{body}")
        else:
            pr_status.upsert(args.repo, number, "push-culprit", body,
                             legacy="<!-- cmux-next-push-culprit:")
    if not should_comment(numbers):
        if numbers:
            report(f"{len(numbers)} pull requests in range: no comments (more than {MAX_COMMENTED_PRS}). "
                   "The job has been red for a while; its owner needs the run, not each author.")
        return 0
    body = comment_body(run_url, args.sha, failed, good, numbers, args.run_id)
    for number in numbers:
        if args.dry_run:
            print(f"--- would comment on #{number}:\n{body}")
            continue
        pr_status.upsert(args.repo, number, "push-attribution", body,
                         legacy="<!-- cmux-next-push-attribution:")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
