#!/usr/bin/env python3
"""Run every iOS UI test on main each night and keep one issue open while it is red.

iOS pull requests run the non-UI suite (`-skip-testing:cmuxUITests`), and the
App Review checks run a few named journeys. Nothing else ran the rest of
`ios/cmuxUITests`, so a UI test could stay red for months with nobody seeing it
(`testSignedOutOnboardingCompletesBeforeShowingSignIn` failed from August to
November, found by #40459), and App Review was the first to run the app's paths.

ios-ui-tests-nightly.yml dispatches test-ios.yml on main with
`test_filter=cmuxUITests`, the whole UI target on iPhone and iPad. `report`
syncs the tracking issue with each completed run of that dispatch: a red run
opens or reopens the issue (or comments once per run), a green run closes it.
The open/comment/close rule is main_full_suite.py's.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from main_full_suite import failing_jobs, issue_plan  # noqa: E402

WORKFLOW_PATH = ".github/workflows/test-ios.yml"
UI_TARGET_FILTER = "cmuxUITests"
ISSUE_LABEL = "ios-ui-nightly-red"
ISSUE_TITLE = "iOS UI tests on main are red"
MAX_LISTED_JOBS = 20


def is_whole_ui_run(run: Mapping[str, object], branch: str) -> bool:
    """A dispatch of test-ios.yml on the branch that ran the whole UI target.

    test-ios.yml's run-name puts the filter between ` · ` separators, so the
    whole target reads ` · cmuxUITests · ` and a class (`cmuxUITests/Foo`) never
    matches.
    """
    return (
        run.get("path") == WORKFLOW_PATH
        and run.get("event") == "workflow_dispatch"
        and run.get("head_branch") == branch
        and f" · {UI_TARGET_FILTER} · " in str(run.get("display_title") or "")
    )


def failure_body(run: Mapping[str, object], jobs: list[Mapping[str, object]]) -> str:
    lines = [
        f"Every iOS UI test (`test_filter={UI_TARGET_FILTER}`) on `main` at {run.get('head_sha')} failed: "
        f"{run.get('html_url')}",
        "",
    ]
    if jobs:
        lines.append("Failing jobs (each uploads `ios-test-results-<family>` with the .xcresult and logs):")
        for job in jobs[:MAX_LISTED_JOBS]:
            lines.append(f"- [{job.get('name')}]({job.get('html_url')})")
        if len(jobs) > MAX_LISTED_JOBS:
            lines.append(f"- ...and {len(jobs) - MAX_LISTED_JOBS} more")
    else:
        lines.append("No individual job reported failure; see the run summary.")
    lines += [
        "",
        "Pull requests skip these UI tests, so this nightly is where a broken app path shows "
        "before App Review finds it. Rerun one class with "
        "`gh workflow run test-ios.yml --ref main -f test_filter=cmuxUITests/<Class>`. "
        "This issue closes itself on the next green nightly.",
    ]
    return "\n".join(lines)


def gh(args: list[str]) -> str:
    return subprocess.run(["gh", "api", *args], check=True, capture_output=True, text=True).stdout


def gh_json_lines(args: list[str]) -> list[dict]:
    return [json.loads(line) for line in gh(args).splitlines() if line.strip()]


def tracking_issue(repo: str) -> dict | None:
    """The oldest issue that ever carried the label, open or closed, so every report lands on one issue."""
    issues = gh_json_lines([
        "-X", "GET", f"repos/{repo}/issues",
        "-f", f"labels={ISSUE_LABEL}", "-f", "state=all", "-f", "sort=created", "-f", "direction=asc",
        "-f", "per_page=1", "--jq", ".[] | tojson",
    ])
    return issues[0] if issues else None


def issue_mentions(repo: str, issue: Mapping[str, object], text: str) -> bool:
    if text in str(issue.get("body") or ""):
        return True
    bodies = gh_json_lines([
        f"repos/{repo}/issues/{issue['number']}/comments", "--paginate", "--jq", ".[] | .body | tojson",
    ])
    return any(text in str(body) for body in bodies)


def ensure_label(repo: str) -> None:
    probe = subprocess.run(["gh", "api", f"repos/{repo}/labels/{ISSUE_LABEL}"], capture_output=True, text=True)
    if probe.returncode == 0:
        return
    gh([
        f"repos/{repo}/labels", "-f", f"name={ISSUE_LABEL}", "-f", "color=b60205",
        "-f", "description=The nightly run of every iOS UI test on main is failing",
    ])


def command_report(args: argparse.Namespace) -> int:
    run = gh_json_lines([f"repos/{args.repo}/actions/runs/{args.run_id}", "--jq", "tojson"])[0]
    if not is_whole_ui_run(run, args.branch) or run.get("status") != "completed":
        print(f"Run {args.run_id} is not a completed whole-UI-target run on {args.branch}; nothing to report.")
        return 0

    conclusion = str(run.get("conclusion") or "")
    run_url = str(run.get("html_url") or "")
    issue = tracking_issue(args.repo)
    is_open = bool(issue) and issue.get("state") == "open"
    already_reported = is_open and issue_mentions(args.repo, issue, run_url)
    plan = issue_plan(conclusion, is_open, already_reported)
    print(f"Run {run.get('id')} ({conclusion}) -> {plan}")

    if plan in {"open", "comment"}:
        jobs = failing_jobs(gh_json_lines([
            f"repos/{args.repo}/actions/runs/{run['id']}/jobs", "--paginate",
            "-X", "GET", "-f", "filter=latest", "-f", "per_page=100",
            "--jq", ".jobs[] | {id, name, conclusion, html_url} | tojson",
        ]))
        body = failure_body(run, jobs)
        if plan == "open" and issue is None:
            ensure_label(args.repo)
            gh([
                f"repos/{args.repo}/issues",
                "-f", f"title={ISSUE_TITLE}", "-f", f"body={body}", "-f", f"labels[]={ISSUE_LABEL}",
            ])
            return 0
        if plan == "open":
            gh(["-X", "PATCH", f"repos/{args.repo}/issues/{issue['number']}", "-f", "state=open"])
        gh([f"repos/{args.repo}/issues/{issue['number']}/comments", "-f", f"body={body}"])
    elif plan == "close":
        gh([
            f"repos/{args.repo}/issues/{issue['number']}/comments",
            "-f", f"body=Every iOS UI test on `main` passes again at {run.get('head_sha')}: {run_url}",
        ])
        gh([
            "-X", "PATCH", f"repos/{args.repo}/issues/{issue['number']}",
            "-f", "state=closed", "-f", "state_reason=completed",
        ])
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--branch", default="main")
    commands = parser.add_subparsers(dest="command", required=True)
    report = commands.add_parser("report", help="sync the tracking issue with a completed whole-UI-target run")
    report.add_argument("--run-id", required=True)
    report.set_defaults(handler=command_report)
    args = parser.parse_args(argv)
    if not args.repo:
        parser.error("--repo or GITHUB_REPOSITORY is required")
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
