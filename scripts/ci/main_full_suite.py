#!/usr/bin/env python3
"""Run the full CI suite on main continuously and keep one issue for a red main.

Pull requests run a subset of the suite unless labeled `full-ci`, and the
merge queue that used to run the full suite before landing is off. Without a
full-suite run on main, a break outside that subset would never show.

Runs are continuous, one at a time: a push to main starts one when none is in
flight, and each run's completion starts the next on the newest HEAD. A red
result therefore covers only the commits that landed during one run, instead
of a three-hour window. The three-hour schedule stays as a backstop.

`gate` decides whether main's HEAD still needs a full-suite run. It holds when
the run that just completed was already at HEAD, so an idle main never loops,
and when another full-suite run on main is in flight for any commit, since that
run's completion dispatches the next one. An in-flight run older than
STALE_IN_FLIGHT does not hold: a run GitHub never starts would otherwise stop
every later dispatch. Every workflow_dispatch CI run is a full-suite run
(choose_ci_suite.py), so any dispatch run on main for this SHA that is queued,
running, or finished green or red means there is nothing to do. A cancelled run
does not count. Any API error fails open and dispatches.

`report` syncs the single tracking issue with a completed dispatch run on main:
a red run opens the issue or comments on it once, and a green run closes it.
A red report carries the "New since" section main_regression_attribution.py
writes: which tests newly fail and the pull requests suspected of it.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections.abc import Iterable, Mapping
from datetime import datetime, timedelta, timezone

CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
CI_WORKFLOW_FILE = "ci.yml"
DISPATCH_EVENT = "workflow_dispatch"
TESTED_CONCLUSIONS = frozenset({"success", "failure"})
FAILED_JOB_CONCLUSIONS = frozenset({"failure", "timed_out"})
ISSUE_LABEL = "main-full-suite-failure"
ISSUE_TITLE = "Main full-suite CI is red"
MAX_LISTED_JOBS = 40
# Well past a full-suite run plus a long runner queue.
STALE_IN_FLIGHT = timedelta(hours=6)


def is_main_full_suite_run(run: Mapping[str, object], branch: str) -> bool:
    return (
        run.get("event") == DISPATCH_EVENT
        and run.get("head_branch") == branch
        and run.get("path") == CI_WORKFLOW_PATH
    )


def created_before(run: Mapping[str, object], cutoff: datetime) -> bool:
    try:
        created = datetime.fromisoformat(str(run.get("created_at")).replace("Z", "+00:00"))
    except ValueError:
        return False
    return created < cutoff


def dispatch_decision(
    runs: Iterable[Mapping[str, object]], head_sha: str, branch: str = "main", now: datetime | None = None,
) -> tuple[bool, str]:
    """Return (dispatch, reason) for main's HEAD given its earlier CI runs."""
    cutoff = (now or datetime.now(timezone.utc)) - STALE_IN_FLIGHT
    candidates = [
        run for run in runs
        if is_main_full_suite_run(run, branch) and run.get("head_sha") == head_sha
    ]
    for run in candidates:
        if run.get("status") != "completed" and not created_before(run, cutoff):
            return False, f"run {run.get('id')} for {head_sha} is already {run.get('status')}"
    for run in candidates:
        if run.get("conclusion") in TESTED_CONCLUSIONS:
            return False, f"run {run.get('id')} already tested {head_sha} ({run.get('conclusion')})"
    return True, f"no completed full-suite run for {head_sha}"


def in_flight_run(
    runs: Iterable[Mapping[str, object]], branch: str = "main", now: datetime | None = None,
) -> Mapping[str, object] | None:
    """A queued or running full-suite run on the branch, for any commit, that is not stale."""
    cutoff = (now or datetime.now(timezone.utc)) - STALE_IN_FLIGHT
    for run in runs:
        if (
            is_main_full_suite_run(run, branch)
            and run.get("status") != "completed"
            and not created_before(run, cutoff)
        ):
            return run
    return None


def in_flight_reason(
    runs: Iterable[Mapping[str, object]], branch: str = "main", now: datetime | None = None,
) -> str | None:
    """Why another full-suite run in flight holds this dispatch, or None."""
    busy = in_flight_run(runs, branch, now)
    if busy is None:
        return None
    return (
        f"run {busy.get('id')} for {busy.get('head_sha')} is still {busy.get('status')}; "
        "its completion dispatches the next run on the newest HEAD"
    )


def latest_tested_run(runs: Iterable[Mapping[str, object]], branch: str = "main") -> Mapping[str, object] | None:
    """The newest completed full-suite run on the branch that went green or red."""
    tested = [
        run for run in runs
        if is_main_full_suite_run(run, branch)
        and run.get("status") == "completed"
        and run.get("conclusion") in TESTED_CONCLUSIONS
    ]
    tested.sort(key=lambda run: str(run.get("created_at") or ""), reverse=True)
    return tested[0] if tested else None


def failing_jobs(jobs: Iterable[Mapping[str, object]]) -> list[Mapping[str, object]]:
    return [job for job in jobs if job.get("conclusion") in FAILED_JOB_CONCLUSIONS]


def issue_plan(conclusion: str, has_open_issue: bool, already_reported: bool) -> str:
    """One of open, comment, close, none."""
    if conclusion == "failure":
        if not has_open_issue:
            return "open"
        return "none" if already_reported else "comment"
    if conclusion == "success" and has_open_issue:
        return "close"
    return "none"


def failure_body(run: Mapping[str, object], jobs: list[Mapping[str, object]], extra: str = "") -> str:
    lines = [
        f"Full-suite CI on `main` failed at {run.get('head_sha')}: {run.get('html_url')}",
        "",
    ]
    if jobs:
        lines.append("Failing jobs:")
        for job in jobs[:MAX_LISTED_JOBS]:
            lines.append(f"- [{job.get('name')}]({job.get('html_url')})")
        if len(jobs) > MAX_LISTED_JOBS:
            lines.append(f"- ...and {len(jobs) - MAX_LISTED_JOBS} more")
    else:
        lines.append("No individual job reported failure; see the run summary.")
    if extra.strip():
        lines += ["", extra.strip()]
    lines += [
        "",
        "Pull requests run a subset of the suite, so this run is the first place "
        "a regression outside that subset shows up. This issue closes itself on the next green run.",
    ]
    return "\n".join(lines)


def gh_json_lines(args: list[str]) -> list[dict]:
    output = subprocess.run(["gh", "api", *args], check=True, capture_output=True, text=True).stdout
    return [json.loads(line) for line in output.splitlines() if line.strip()]


def list_runs(repo: str, branch: str, extra: list[str]) -> list[dict]:
    return gh_json_lines([
        "-X", "GET", f"repos/{repo}/actions/workflows/{CI_WORKFLOW_FILE}/runs",
        "-f", f"branch={branch}", "-f", f"event={DISPATCH_EVENT}", "-f", "per_page=50", *extra,
        "--jq", ".workflow_runs[] | tojson",
    ])


def write_output(path: str | None, values: Mapping[str, str]) -> None:
    for key, value in values.items():
        print(f"{key}={value}")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")


def command_gate(args: argparse.Namespace) -> int:
    if args.force:
        dispatch, reason = True, "forced by workflow_dispatch input"
    elif args.completed_sha and args.completed_sha == args.head_sha:
        # Checked before any API call, so a failed lookup cannot fail open into
        # re-running the commit that just finished, cancelled or not.
        dispatch, reason = False, (
            f"main has not moved since the run that just completed at {args.head_sha}; "
            "the schedule retries it if that run was cancelled"
        )
    else:
        try:
            held = in_flight_reason(list_runs(args.repo, args.branch, []), args.branch)
            if held is not None:
                dispatch, reason = False, held
            else:
                runs = list_runs(args.repo, args.branch, ["-f", f"head_sha={args.head_sha}"])
                dispatch, reason = dispatch_decision(runs, args.head_sha, args.branch)
        except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
            dispatch, reason = True, f"could not read earlier runs ({error}); dispatching"
    print(reason)
    write_output(args.github_output, {"dispatch": "true" if dispatch else "false"})
    return 0


def open_issue(repo: str) -> dict | None:
    issues = gh_json_lines([
        "-X", "GET", f"repos/{repo}/issues",
        "-f", f"labels={ISSUE_LABEL}", "-f", "state=open", "-f", "per_page=1",
        "--jq", ".[] | tojson",
    ])
    return issues[0] if issues else None


def issue_mentions(repo: str, issue: Mapping[str, object], text: str) -> bool:
    if text in str(issue.get("body") or ""):
        return True
    bodies = gh_json_lines([
        f"repos/{repo}/issues/{issue['number']}/comments", "--paginate",
        "--jq", ".[] | .body | tojson",
    ])
    return any(text in str(body) for body in bodies)


def ensure_label(repo: str) -> None:
    probe = subprocess.run(["gh", "api", f"repos/{repo}/labels/{ISSUE_LABEL}"], capture_output=True, text=True)
    if probe.returncode == 0:
        return
    subprocess.run([
        "gh", "api", f"repos/{repo}/labels",
        "-f", f"name={ISSUE_LABEL}", "-f", "color=b60205",
        "-f", "description=Full-suite CI on main is failing",
    ], check=True, capture_output=True, text=True)


def read_extra_section(path: str | None) -> str:
    """The new-failure attribution, when main_regression_attribution.py wrote one."""
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def command_report(args: argparse.Namespace) -> int:
    if args.run_id:
        run = gh_json_lines([f"repos/{args.repo}/actions/runs/{args.run_id}", "--jq", "tojson"])[0]
        if not is_main_full_suite_run(run, args.branch) or run.get("status") != "completed":
            print(f"Run {args.run_id} is not a completed full-suite CI run on {args.branch}; nothing to report.")
            return 0
    else:
        run = latest_tested_run(list_runs(args.repo, args.branch, ["-f", "status=completed"]), args.branch)
        if run is None:
            print(f"No completed full-suite CI run on {args.branch} yet.")
            return 0

    conclusion = str(run.get("conclusion") or "")
    run_url = str(run.get("html_url") or "")
    issue = open_issue(args.repo)
    already_reported = bool(issue) and issue_mentions(args.repo, issue, run_url)
    plan = issue_plan(conclusion, issue is not None, already_reported)
    print(f"Run {run.get('id')} ({conclusion}) -> {plan}")

    if plan in {"open", "comment"}:
        jobs = failing_jobs(gh_json_lines([
            f"repos/{args.repo}/actions/runs/{run['id']}/jobs", "--paginate",
            "-X", "GET", "-f", "filter=latest", "-f", "per_page=100",
            "--jq", ".jobs[] | {name, conclusion, html_url} | tojson",
        ]))
        body = failure_body(run, jobs, read_extra_section(args.extra_section))
        if plan == "open":
            ensure_label(args.repo)
            subprocess.run([
                "gh", "api", f"repos/{args.repo}/issues",
                "-f", f"title={ISSUE_TITLE}", "-f", f"body={body}", "-f", f"labels[]={ISSUE_LABEL}",
            ], check=True, capture_output=True, text=True)
        else:
            subprocess.run([
                "gh", "api", f"repos/{args.repo}/issues/{issue['number']}/comments", "-f", f"body={body}",
            ], check=True, capture_output=True, text=True)
    elif plan == "close":
        subprocess.run([
            "gh", "api", f"repos/{args.repo}/issues/{issue['number']}/comments",
            "-f", f"body=Full-suite CI on `main` is green again at {run.get('head_sha')}: {run_url}",
        ], check=True, capture_output=True, text=True)
        subprocess.run([
            "gh", "api", "-X", "PATCH", f"repos/{args.repo}/issues/{issue['number']}",
            "-f", "state=closed", "-f", "state_reason=completed",
        ], check=True, capture_output=True, text=True)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--branch", default="main")
    commands = parser.add_subparsers(dest="command", required=True)

    gate = commands.add_parser("gate", help="decide whether main's HEAD still needs a full-suite run")
    gate.add_argument("--head-sha", required=True)
    gate.add_argument("--force", action="store_true")
    gate.add_argument("--completed-sha", help="head SHA of the full-suite run whose completion triggered this gate")
    gate.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    gate.set_defaults(handler=command_gate)

    report = commands.add_parser("report", help="sync the tracking issue with a completed run")
    report.add_argument("--run-id", help="defaults to the newest green or red full-suite run")
    report.add_argument("--extra-section", help="markdown to add to a failure report, e.g. new-failure attribution")
    report.set_defaults(handler=command_report)

    args = parser.parse_args(argv)
    if not args.repo:
        parser.error("--repo or GITHUB_REPOSITORY is required")
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
