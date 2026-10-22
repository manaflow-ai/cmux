#!/usr/bin/env python3
"""Alert when a fleet runner label takes no jobs: the starved-label alert.

A self-hosted fleet label (``glaeda-*``) whose runners all stopped listening
looks like an ordinary queue from GitHub's side: the job waits, nothing fails,
and nobody hears about it (PR #23047's `cmux-next app compile (build fleet)`
sat queued on glaeda-side-light-xcode-26.6 for over two hours on 2026-10-22).
The workflow tokens cannot list org runners, so this judges a label from the
jobs the queue janitor already listed: a label is starved when a job on it has
been queued with no runner for STARVED_AFTER and no job on it is running or
started in that window. A running job proves a listener is online, so a pool
that is merely busy is not starved.

Every glaeda-* label is in scope. Nothing in the tree says which runner label
a merge-blocking job asks for (cmux-next's build-fleet compile takes
vars.CI_COMPILE_CHECK_GATEWAY), so the alert covers the whole fleet.

queue_janitor.py calls starved() and writes the result into the
macos-pool-load snapshot as ``starved``. ci-queue-janitor.yml then runs this
script on that snapshot: one ::error:: annotation and a step-summary line per
starved label, and one open issue per label titled ISSUE_PREFIX + label,
updated while it stays starved and closed when it recovers. Issues use the
cmux-bot App token the janitor already mints with issues: write; without it a
starved label fails this step instead. The heal itself runs on the minis:
glaeda-mini-health kickstarts a stopped runner LaunchAgent (runner_stopped),
and a listener its gate holds off for a root-only fault is reported there.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import sys
import urllib.parse
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any

STARVED_AFTER = dt.timedelta(minutes=10)
FLEET_PREFIX = "glaeda-"
ISSUE_PREFIX = "Runner label starved: "
ISSUE_LABEL = "ci-runner-starved"


def parse_time(value: str | None) -> dt.datetime | None:
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


def fleet_key(job: Mapping[str, Any]) -> str:
    """The fleet labels a job asked for, joined; "" when it asked for none."""
    return "+".join(sorted({str(label) for label in job.get("labels") or () if str(label).startswith(FLEET_PREFIX)}))


def starved(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], *,
            now: dt.datetime, after: dt.timedelta = STARVED_AFTER) -> list[dict[str, Any]]:
    """The fleet labels with a job queued past `after` and none running or started within it."""
    waiting: dict[str, list[Mapping[str, Any]]] = {}
    served: set[frozenset[str]] = set()
    for run in runs:
        for job in jobs_by_run.get(run.get("id"), ()):
            key = fleet_key(job)
            if not key:
                continue
            status = job.get("status")
            started = parse_time(job.get("started_at"))
            if status == "queued" and not job.get("runner_name"):
                waiting.setdefault(key, []).append(job)
            elif status == "in_progress" or (job.get("runner_name") and started and now - started <= after):
                served.add(frozenset(key.split("+")))
    found = []
    for key, jobs in sorted(waiting.items()):
        oldest = min(jobs, key=lambda job: parse_time(job.get("created_at")) or now)
        age = now - (parse_time(oldest.get("created_at")) or now)
        labels = frozenset(key.split("+"))
        if age < after or any(labels <= runner_labels for runner_labels in served):
            continue
        found.append({"label": key, "oldest_queued_minutes": int(age.total_seconds() // 60), "queued": len(jobs),
                      "job": str(oldest.get("name") or ""), "job_url": str(oldest.get("html_url") or "")})
    return found


def format_minutes(minutes: int) -> str:
    return f"{minutes}m" if minutes < 60 else f"{minutes // 60}h{minutes % 60:02d}m"


def issue_title(label: str) -> str:
    return ISSUE_PREFIX + label


def describe(entry: Mapping[str, Any]) -> str:
    return (f"`{entry['label']}`: {entry['queued']} job(s) queued, the oldest "
            f"({entry['job']}, {entry['job_url']}) for {format_minutes(int(entry['oldest_queued_minutes']))}, "
            f"and no job on it running or started in the last {int(STARVED_AFTER.total_seconds() // 60)} minutes")


def issue_body(entry: Mapping[str, Any], generated_at: str) -> str:
    return (f"The CI queue janitor's sweep at {generated_at} found {describe(entry)}.\n\n"
            "No runner with this label is taking jobs. On the minis, `glaeda-mini-health` reports why "
            "(`runner_stopped` is kickstarted there; a listener held off for `toolchain_mismatch` or "
            "`node_ineligible` needs its operator). This issue is updated every sweep while the label stays "
            "starved and closed by the first sweep that finds it served.\n\n"
            "Source: `scripts/ci/starved_labels.py` (ci-queue-janitor.yml).")


@dataclasses.dataclass
class IssuePlan:
    open: list[Mapping[str, Any]]
    update: list[tuple[Mapping[str, Any], Mapping[str, Any]]]
    close: list[Mapping[str, Any]]


def plan_issues(found: Iterable[Mapping[str, Any]], open_issues: Iterable[Mapping[str, Any]]) -> IssuePlan:
    by_title = {str(issue.get("title")): issue for issue in open_issues
                if str(issue.get("title") or "").startswith(ISSUE_PREFIX)}
    plan = IssuePlan([], [], [])
    for entry in found:
        issue = by_title.pop(issue_title(entry["label"]), None)
        if issue is None:
            plan.open.append(entry)
        else:
            plan.update.append((issue, entry))
    plan.close = sorted(by_title.values(), key=lambda issue: issue["number"])
    return plan


def sync_issues(github: Any, found: Sequence[Mapping[str, Any]], generated_at: str) -> list[str]:
    """Open, update and close the per-label issues; returns one line per action."""
    repo = github.repo
    query = urllib.parse.urlencode({"labels": ISSUE_LABEL, "state": "open", "per_page": 100})
    open_issues = [issue for issue in github.request("GET", f"/repos/{repo}/issues?{query}") or []
                   if "pull_request" not in issue]
    plan = plan_issues(found, open_issues)
    lines = []
    for entry in plan.open:
        created = github.request("POST", f"/repos/{repo}/issues", {
            "title": issue_title(entry["label"]), "body": issue_body(entry, generated_at), "labels": [ISSUE_LABEL]})
        lines.append(f"opened #{created.get('number')} for `{entry['label']}`")
    for issue, entry in plan.update:
        github.request("PATCH", f"/repos/{repo}/issues/{issue['number']}", {"body": issue_body(entry, generated_at)})
        lines.append(f"updated #{issue['number']} for `{entry['label']}`")
    for issue in plan.close:
        github.request("POST", f"/repos/{repo}/issues/{issue['number']}/comments",
                       {"body": f"Recovered: the sweep at {generated_at} found this label served or idle."})
        github.request("PATCH", f"/repos/{repo}/issues/{issue['number']}", {"state": "closed", "state_reason": "completed"})
        lines.append(f"closed #{issue['number']} ({issue['title'][len(ISSUE_PREFIX):]} recovered)")
    return lines


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", type=Path, default=Path(env["POOL_LOAD_OUT"]) if env.get("POOL_LOAD_OUT") else None)
    parser.add_argument("--summary", type=Path,
                        default=Path(env["GITHUB_STEP_SUMMARY"]) if env.get("GITHUB_STEP_SUMMARY") else None)
    args = parser.parse_args(argv)
    try:
        snapshot = json.loads(args.snapshot.read_text(encoding="utf-8")) if args.snapshot else {}
    except (OSError, ValueError) as error:
        snapshot = {}
        print(f"starved-labels: no snapshot to read ({error})", file=sys.stderr)
    if "starved" not in snapshot:
        # The sweep could not list jobs: no answer, so no issue is opened or closed.
        print("::warning title=Runner label starved::the janitor wrote no starved-label result this sweep")
        return 0
    found = list(snapshot["starved"])
    generated_at = str(snapshot.get("generated_at") or "")
    lines = ["", "### Starved runner labels", ""]
    for entry in found:
        print(f"::error title=Runner label starved::{entry['label']} took no job for "
              f"{format_minutes(int(entry['oldest_queued_minutes']))}: {entry['job_url']}")
        lines.append(f"- **Starved** {describe(entry)}.")
    if not found:
        lines.append("Every fleet label with a queued job is taking jobs.")
    code = 0
    token = env.get("GH_TOKEN") or ""
    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    if not token or not repo:
        if found:
            print("::error title=Runner label starved::no cmux-bot token, so no tracking issue could be opened")
            lines.append("- No cmux-bot token this sweep: the tracking issues were not opened or updated.")
            code = 1
    else:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from queue_janitor import GitHub  # noqa: PLC0415 the janitor imports this module

        try:
            lines.extend(f"- {line}" for line in sync_issues(GitHub(token, repo), found, generated_at))
        except RuntimeError as error:
            print(f"::error title=Runner label starved::tracking issues: {error}")
            lines.append(f"- Tracking issues could not be synced: {error}")
            code = 1
    text = "\n".join(lines) + "\n"
    print(text)
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as handle:
            handle.write(text)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
