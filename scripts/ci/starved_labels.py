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
The wait counts from when the job could first run (wait_start()): a job behind
a running sibling in its run, which may be its `needs`, is not counted, and one
beside a queued sibling alerts only after STARVED_GATED_AFTER.

Every glaeda-* label is in scope. Nothing in the tree says which runner label
a merge-blocking job asks for (cmux-next's build-fleet compile takes
vars.CI_COMPILE_CHECK_GATEWAY), so the alert covers the whole fleet.

queue_janitor.py calls starved() and writes the result into the
macos-pool-load snapshot as ``starved``. ci-queue-janitor.yml then runs this
script on that snapshot: one ::error:: annotation and a step-summary line per
starved label, and one open issue per label titled ISSUE_PREFIX + label,
updated while it stays starved and closed only on evidence of recovery
(a job on the label running or started, or none queued; see plan_issues()). Issues use the
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
# A queued fleet job beside another queued job of its run (not itself stuck on an
# unserved fleet label) may be waiting on that job as its `needs`, or that job on
# it: the jobs API names no `needs`. Its alert waits this longer bound instead.
STARVED_GATED_AFTER = dt.timedelta(minutes=60)
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


def _served(job: Mapping[str, Any], now: dt.datetime, after: dt.timedelta) -> bool:
    started = parse_time(job.get("started_at"))
    return job.get("status") == "in_progress" or bool(job.get("runner_name") and started and now - started <= after)


def stuck(job: Mapping[str, Any]) -> bool:
    """Queued with no runner."""
    return job.get("status") == "queued" and not job.get("runner_name")


def _covered(labels: frozenset[str], served: Iterable[frozenset[str]]) -> bool:
    """A runner that took a job asking for a superset of `labels` could take this one."""
    return any(labels <= runner_labels for runner_labels in served)


def wait_start(job: Mapping[str, Any], run_jobs: Sequence[Mapping[str, Any]],
               suspects: frozenset[int] = frozenset()) -> tuple[dt.datetime, bool] | None:
    """When a queued job could first have run, and whether a queued sibling may still gate it.

    The jobs API can list a job before its `needs` finished and names no
    `needs`, so any unfinished sibling may be its gate (queue_janitor._gated()).
    A running, waiting or pending one means its wait has not begun: None. A
    queued one may be upstream or downstream, and the API cannot tell, so the
    wait counts but is flagged gated (starved() then waits STARVED_GATED_AFTER):
    a stuck fleet job with queued dependents still alerts. A sibling in
    `suspects` (stuck on an unserved fleet label) is no gate, so two stuck fleet
    jobs never mask each other. The wait counts from the later of its
    `created_at` and the last sibling completion (queue_janitor.lost_wait_start()).
    """
    gated = False
    for other in run_jobs:
        if other is job or other.get("status") == "completed" or id(other) in suspects:
            continue
        if not stuck(other):
            return None
        gated = True
    created = parse_time(job.get("created_at"))
    if created is None:
        return None
    finished = [parse_time(other.get("completed_at")) for other in run_jobs
                if other is not job and other.get("status") == "completed"]
    return max([created, *(moment for moment in finished if moment is not None)]), gated


def _unserved_queues(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], *,
                     now: dt.datetime, after: dt.timedelta,
                     evidence: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
                     ) -> dict[str, list[tuple[Mapping[str, Any], tuple[dt.datetime, bool] | None]]]:
    """Fleet label key -> its queued jobs with their wait_start(), for labels no job is running on or started on within `after`.

    `evidence` (run id -> jobs, completed runs the janitor listed anyway) counts only as service.
    """
    served: set[frozenset[str]] = set()
    for jobs in [*(jobs_by_run.get(run.get("id"), ()) for run in runs), *(evidence or {}).values()]:
        for job in jobs:
            key = fleet_key(job)
            if key and not stuck(job) and _served(job, now, after):
                served.add(frozenset(key.split("+")))

    def unserved_key(key: str) -> bool:
        return not _covered(frozenset(key.split("+")), served)

    run_lists = [list(jobs_by_run.get(run.get("id"), ())) for run in runs]
    suspects = frozenset(id(job) for run_jobs in run_lists for job in run_jobs
                         if fleet_key(job) and stuck(job) and unserved_key(fleet_key(job)))
    waiting: dict[str, list[tuple[Mapping[str, Any], tuple[dt.datetime, bool] | None]]] = {}
    for run_jobs in run_lists:
        for job in run_jobs:
            if id(job) in suspects:
                waiting.setdefault(fleet_key(job), []).append((job, wait_start(job, run_jobs, suspects)))
    return dict(sorted(waiting.items()))


def unserved(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], *,
             now: dt.datetime, after: dt.timedelta = STARVED_AFTER,
             evidence: Mapping[int, Sequence[Mapping[str, Any]]] | None = None) -> list[str]:
    """Fleet labels with a queued job, of any age, and no sign of service: an open alert stays open.

    Recovery needs positive evidence: a job on the label running or started within `after`, or no
    queued job on it at all. A stuck job cancelled and replaced on the same stopped listener leaves a
    replacement younger than the alert threshold, which is not recovery.
    """
    return list(_unserved_queues(runs, jobs_by_run, now=now, after=after, evidence=evidence))


def starved(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], *,
            now: dt.datetime, after: dt.timedelta = STARVED_AFTER,
            evidence: Mapping[int, Sequence[Mapping[str, Any]]] | None = None) -> list[dict[str, Any]]:
    """The fleet labels with a job queued past `after` and none running or started within it."""
    found = []
    for key, entries in _unserved_queues(runs, jobs_by_run, now=now, after=after, evidence=evidence).items():
        bound = {False: after, True: max(after, STARVED_GATED_AFTER)}
        ready = [(job, wait[0]) for job, wait in entries if wait is not None and now - wait[0] >= bound[wait[1]]]
        if not ready:
            continue
        oldest, since = min(ready, key=lambda entry: entry[1])
        age = now - since
        found.append({"label": key, "oldest_queued_minutes": int(age.total_seconds() // 60), "queued": len(entries),
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
    # (duplicate, the oldest issue with its title, which is kept)
    duplicates: list[tuple[Mapping[str, Any], Mapping[str, Any]]] = dataclasses.field(default_factory=list)


def plan_issues(found: Iterable[Mapping[str, Any]], open_issues: Iterable[Mapping[str, Any]], *,
                unserved: Iterable[str] = (), generated_at: str = "", incomplete: bool = False) -> IssuePlan:
    """What to do with each open starved-label issue.

    Sweeps are serialized (the workflow's concurrency group never cancels one in progress), and this
    fences anyway: a title with several open issues keeps its oldest and closes the rest as
    duplicates, a label still queued and unserved keeps its issue open even below the alert
    threshold, and an issue updated at or after this snapshot's time is never closed by it, nor is
    any issue with its title closed as recovered. An `incomplete` inventory (a jobs listing failed)
    closes nothing as recovered: the missing jobs may be the stuck ones.
    """
    by_title: dict[str, list[Mapping[str, Any]]] = {}
    for issue in open_issues:
        if str(issue.get("title") or "").startswith(ISSUE_PREFIX):
            by_title.setdefault(str(issue["title"]), []).append(issue)
    plan = IssuePlan([], [], [])
    snapshot_at = parse_time(generated_at)

    def newer(issue: Mapping[str, Any]) -> bool:
        """Updated at or after this snapshot: a later sweep wrote it, so this one closes it for no reason."""
        updated = parse_time(issue.get("updated_at"))
        return bool(snapshot_at and updated and updated >= snapshot_at)

    keepers: dict[str, Mapping[str, Any]] = {}
    fenced: set[str] = set()
    for title, issues in sorted(by_title.items()):
        issues.sort(key=lambda issue: issue["number"])
        keepers[title] = issues[0]
        if any(newer(issue) for issue in issues):
            fenced.add(title)
        plan.duplicates.extend((issue, issues[0]) for issue in issues[1:] if not newer(issue))
    for entry in found:
        issue = keepers.pop(issue_title(entry["label"]), None)
        if issue is None:
            plan.open.append(entry)
        else:
            plan.update.append((issue, entry))
    held = {issue_title(label) for label in unserved} | fenced
    for title, issue in sorted(keepers.items(), key=lambda item: item[1]["number"]) if not incomplete else ():
        if title not in held:
            plan.close.append(issue)
    return plan


def sync_issues(github: Any, found: Sequence[Mapping[str, Any]], generated_at: str, *,
                unserved: Iterable[str] = (), incomplete: bool = False) -> list[str]:
    """Open, update and close the per-label issues; returns one line per action."""
    repo = github.repo
    # Found by title, not by ISSUE_LABEL: GitHub drops a label that does not exist yet when the token
    # cannot create it, and a lookup by label would then open a new issue every sweep.
    query = urllib.parse.urlencode({"q": f'repo:{repo} is:issue is:open in:title "{ISSUE_PREFIX.strip()}"',
                                    "per_page": 100})
    open_issues = (github.request("GET", f"/search/issues?{query}") or {}).get("items") or []
    plan = plan_issues(found, open_issues, unserved=unserved, generated_at=generated_at, incomplete=incomplete)
    lines = []
    for issue, keeper in plan.duplicates:
        github.request("POST", f"/repos/{repo}/issues/{issue['number']}/comments",
                       {"body": f"Duplicate of #{keeper['number']}, which tracks this label."})
        github.request("PATCH", f"/repos/{repo}/issues/{issue['number']}",
                       {"state": "closed", "state_reason": "not_planned"})
        lines.append(f"closed #{issue['number']} as a duplicate of #{keeper['number']}")
    for entry in plan.open:
        created = github.request("POST", f"/repos/{repo}/issues", {
            "title": issue_title(entry["label"]), "body": issue_body(entry, generated_at), "labels": [ISSUE_LABEL]})
        lines.append(f"opened #{created.get('number')} for `{entry['label']}`")
    for issue, entry in plan.update:
        github.request("PATCH", f"/repos/{repo}/issues/{issue['number']}", {"body": issue_body(entry, generated_at)})
        lines.append(f"updated #{issue['number']} for `{entry['label']}`")
    for issue in plan.close:
        github.request("POST", f"/repos/{repo}/issues/{issue['number']}/comments",
                       {"body": f"Recovered: the sweep at {generated_at} found a job on this label running or "
                                        "started, or none queued."})
        github.request("PATCH", f"/repos/{repo}/issues/{issue['number']}", {"state": "closed", "state_reason": "completed"})
        lines.append(f"closed #{issue['number']} ({issue['title'][len(ISSUE_PREFIX):]} recovered)")
    return lines


def client(token: str, repo: str) -> Any:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from queue_janitor import GitHub  # noqa: PLC0415 the janitor imports this module

    return GitHub(token, repo)


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
    incomplete = bool(snapshot.get("starved_incomplete"))
    if incomplete:
        print("::warning title=Runner label starved::a jobs listing failed this sweep, so no issue is closed as recovered")
        lines.append("- A jobs listing failed this sweep: no tracking issue is closed as recovered.")
    elif not found:
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
        try:
            lines.extend(f"- {line}" for line in sync_issues(client(token, repo), found, generated_at,
                                                            unserved=snapshot.get("unserved") or (),
                                                            incomplete=incomplete))
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
