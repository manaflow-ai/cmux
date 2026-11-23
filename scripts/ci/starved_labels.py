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
Each alert then says why from the fleet gates' own reading (carriers()): full
(every carrier runs a job or is held for units or load: capacity) or offline
(carriers down with no hold: an outage), since GitHub shows both as offline.

Every glaeda-* label is in scope, and the owned Linux labels (FLEET_LINUX_LABELS).
Nothing in the tree says which runner label
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

The alert also acts (rescue_plan()). A label starved past RESCUE_AFTER (30
minutes) has each run stuck on it that long get its rescue started: one
ci-owned-pool-rescue.yml dispatch with that run_id, the per-run watch, which
moves a job waiting past owned_pool_rescue.OWNED_WAIT_BOUND_SECONDS to
Blacksmith by that script's own rules (what it keeps on the owned pool, it
keeps). On 2026-11-17 cmux#45115 (glaeda-ios-sim+glaeda-std-xcode-26.6) stayed
open 539 minutes with 16 jobs queued and every carrier held off by its mini's
gate (fleet-build host locks, capacity units, a fleet lease), and the alert
only paged. Each run is dispatched once per RESCUE_REPEAT, recorded in the
issue body (RESCUE_MARK), since a second dispatch for the same run cancels its
watch (the rescue's per-run concurrency group), and RESCUE_RUNS_PER_SWEEP a
sweep at most.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import re
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
# The owned Linux label: ephemeral runners a reconciler boots per queued job. When that reconciler cannot
# boot one, a job waits here as silently as on a held glaeda label (run 43807536777: 13 h, 2026-11-16).
FLEET_LINUX = "cmux-fleet-linux-x64"
# The persistent Linux pool: its runners carry both cmux-linux and FLEET_LINUX, and same-repository
# jobs name cmux-linux, so a pool that stops listening starves that label too.
PERSISTENT_LINUX = "cmux-linux"
FLEET_LINUX_LABELS = frozenset({FLEET_LINUX, PERSISTENT_LINUX})
# Every persistent pool runner registers both FLEET_LINUX_LABELS (cmuxterm-hq runner_pool.py POOL_LABELS), so a job
# running on either label proves a listener for the other (pool_served()). Without that, a pool busy with cmux-linux
# jobs read cmux-fleet-linux-x64's queue as starved, and the reverse (router-review F1 on #47956).
POOL_SHARED_LABELS = FLEET_LINUX_LABELS
ISSUE_PREFIX = "Runner label starved: "
ISSUE_LABEL = "ci-runner-starved"
# A run stuck this long on a starved label gets its rescue started (rescue_plan()).
RESCUE_AFTER = dt.timedelta(minutes=30)
# A run's watch job runs at most 195 minutes (owned_pool_rescue.JOB_TIMEOUT_SECONDS: 150 watching, 40 to settle, 5
# margin), plus its own start; a dispatch sooner would cancel it, since one run's watches share a concurrency group
# (owned-pool-rescue-RUN-ATTEMPT) with cancel-in-progress.
RESCUE_REPEAT = dt.timedelta(minutes=210)
# The sources ci-owned-pool-rescue.yml watches on their own `workflow_run: requested` event, in that same group: a
# dispatch for one of their runs would cancel that watch (perhaps between its cancel and its re-run, leaving a nightly
# cancelled), so the alert never starts one for them. cmux-next.yml is listed there for `completed` only, whose group
# has its own suffix. A test keeps this equal to the workflow's SOURCE_WORKFLOW_PATHS less cmux-next.yml.
REQUEST_WATCHED_PATHS = frozenset({".github/workflows/ios-screenshots.yml", ".github/workflows/cmux-next-dev-daily.yml"})
# Sources the rescue workflow's sweeper watches instead (nightly.yml since #49606: owned_pool_rescue.GitHub.nightly_runs());
# the sweeper already rescues them, so the alert starts no second watch for them either.
SWEEPER_WATCHED_PATHS = frozenset({".github/workflows/nightly.yml"})
RESCUE_RUNS_PER_SWEEP = 6
RESCUE_WORKFLOW = "ci-owned-pool-rescue.yml"
# The runs whose rescue this alert started, and when, in the issue body: <!-- starved-rescue: RUN@ISO ... -->.
RESCUE_MARK = re.compile(r"<!-- starved-rescue:([^>]*)-->")
# carriers(): a gate reading older than this is stale, as queue_janitor.FLEET_GATES_STALE_S (a test keeps them equal).
CARRIER_READING_STALE_S = 300
# carriers()' states, least to most severe: a label over several parts reads as its worst part.
CARRIER_STATES = ("listening", "full", "unknown", "offline", "none")


def parse_time(value: str | None) -> dt.datetime | None:
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


def fleet_key(job: Mapping[str, Any]) -> str:
    """The fleet labels a job asked for, joined; "" when it asked for none."""
    return "+".join(sorted({str(label) for label in job.get("labels") or ()
                            if str(label).startswith(FLEET_PREFIX) or str(label) in FLEET_LINUX_LABELS}))


def _served(job: Mapping[str, Any], now: dt.datetime, after: dt.timedelta) -> bool:
    started = parse_time(job.get("started_at"))
    return job.get("status") == "in_progress" or bool(job.get("runner_name") and started and now - started <= after)


def run_of(job: Mapping[str, Any]) -> tuple[int, int] | None:
    """(run id, attempt) of a job: the jobs API's run_id and run_attempt, or the run in its html_url."""
    run = job.get("run_id")
    if not isinstance(run, int) or isinstance(run, bool):
        match = re.search(r"/runs/(\d+)/", str(job.get("html_url") or ""))
        run = int(match.group(1)) if match else None
    if not run:
        return None
    attempt = job.get("run_attempt")
    return run, attempt if isinstance(attempt, int) and not isinstance(attempt, bool) and attempt > 0 else 1


def stuck(job: Mapping[str, Any]) -> bool:
    """Queued with no runner."""
    return job.get("status") == "queued" and not job.get("runner_name")


def pool_served(labels: frozenset[str]) -> frozenset[str]:
    """The labels a runner that took a job on `labels` carries: a persistent pool runner carries every
    POOL_SHARED_LABELS label, so a job on one of them is service for all of them."""
    return labels | POOL_SHARED_LABELS if labels & POOL_SHARED_LABELS else labels


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
                served.add(pool_served(frozenset(key.split("+"))))

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
    path_of = {run.get("id"): str(run.get("path") or "") for run in runs}
    for key, entries in _unserved_queues(runs, jobs_by_run, now=now, after=after, evidence=evidence).items():
        bound = {False: after, True: max(after, STARVED_GATED_AFTER)}
        ready = [(job, wait[0]) for job, wait in entries if wait is not None and now - wait[0] >= bound[wait[1]]]
        if not ready:
            continue
        oldest, since = min(ready, key=lambda entry: entry[1])
        age = now - since
        # The runs stuck past RESCUE_AFTER, oldest wait first, that rescue_plan() may start a rescue for: attempt 1 only
        # (a dispatch watches any attempt, owned_pool_rescue.dispatch_target(), but this alert stays the loop guard),
        # and no workflow whose own workflow_run watch holds that run's group (REQUEST_WATCHED_PATHS).
        rescuable: list[list[int]] = []
        for job, at in sorted(ready, key=lambda entry: entry[1]):
            got = run_of(job)
            if (got and got[1] == 1 and list(got) not in rescuable and now - at >= RESCUE_AFTER
                    and path_of.get(got[0]) not in REQUEST_WATCHED_PATHS | SWEEPER_WATCHED_PATHS):
                rescuable.append(list(got))
        found.append({"label": key, "oldest_queued_minutes": int(age.total_seconds() // 60), "queued": len(entries),
                      "job": str(oldest.get("name") or ""), "job_url": str(oldest.get("html_url") or ""),
                      "runs": rescuable})
    return found


def format_minutes(minutes: int) -> str:
    return f"{minutes}m" if minutes < 60 else f"{minutes // 60}h{minutes % 60:02d}m"


def issue_title(label: str) -> str:
    return ISSUE_PREFIX + label


def _carrier_state(row: Mapping[str, Any]) -> str:
    held = row.get("held_offline") or {}
    if row.get("listening"):
        return "listening"
    if row.get("busy") or held.get("total"):
        return "full"
    if row.get("down") and not row.get("unreported"):
        return "offline"
    if row.get("unreported"):
        return "unknown"
    return "none"


def carriers(label: str, gates: Mapping[str, Any] | None, now: dt.datetime) -> dict[str, Any]:
    """What the label's carriers are doing, from the fleet gates' own reading (the snapshot's `gates`).

    GitHub lists a runner whose gate holds its listener off as offline, the same as a dead one, so the jobs alone
    cannot tell a full label from a broken one (cmux#45614, #45620-#45622 read as outages while every carrier ran or
    was held for capacity units). `state` is CARRIER_STATES' worst over the label's parts (a part the reading
    leaves out counts as unknown; a full one with some carriers down says so in the issue):
      full       no idle listener; carriers run jobs or their gate holds them (units, CPU, livelock, other): capacity
      offline    carriers registered but down (offline with no gate hold), none running or held: an outage
      listening  a listener is up and idle, yet the job did not start
      none       the reading lists the label with no carrier at all
      unknown    no fresh reading, the label or a part of it is not in it, or its minis' probes failed (also down
                 carriers beside unreported ones)
    """
    reading = (gates or {}).get("labels") if isinstance(gates, Mapping) else None
    as_of = parse_time(str((gates or {}).get("as_of") or "")) if isinstance(gates, Mapping) else None
    if not isinstance(reading, Mapping) or as_of is None:
        return {"state": "unknown", "why": "no fleet gate reading (CI_FLEET_GATES) in this sweep"}
    if (now - as_of).total_seconds() > CARRIER_READING_STALE_S:
        return {"state": "unknown", "why": f"the fleet gate reading is from {as_of.strftime('%H:%M:%SZ')}, stale"}
    parts = [(part, reading.get(part)) for part in label.split("+")]
    if not any(isinstance(row, Mapping) for _, row in parts):
        return {"state": "unknown", "why": "the fleet gate reading does not list this label"}
    # A part the reading leaves out is unknown: the job needs runners carrying every part.
    state = max((_carrier_state(row) if isinstance(row, Mapping) else "unknown" for _, row in parts),
                key=CARRIER_STATES.index)
    parts = [(part, row) for part, row in parts if isinstance(row, Mapping)]
    counts = []
    for part, row in parts:
        held = row.get("held_offline") or {}
        holds = ", ".join(f"{held[key]} {key}" for key in ("units", "cpu", "livelock", "other") if held.get(key))
        counts.append(f"`{part}` {int(row.get('listening') or 0)} listening, {int(row.get('busy') or 0)} busy, "
                      f"{int(held.get('total') or 0)} held" + (f" ({holds})" if holds else "")
                      + f", {int(row.get('down') or 0)} down, {int(row.get('unreported') or 0)} unreported")
    down = sum(int(row.get("down") or 0) for _, row in parts)
    return {"state": state, "why": "; ".join(counts), "down": down, "as_of": as_of.strftime("%Y-%m-%dT%H:%M:%SZ")}


CARRIER_SENTENCE = {
    "full": ("Its carriers are full, not offline: none listens because each runs a job or its gate holds it for "
             "capacity units, CPU or another limit. This is capacity. Units holds while smaller jobs keep running "
             "mean a large job starves behind smaller ones sharing its units (glaeda's starved-job reserve, "
             "STARVED_RESERVE, holds the units for it)."),
    "offline": ("Its carriers are offline: registered but down, with no gate hold and none running a job. This is "
                "an outage. On the minis, `glaeda-mini-health` reports why (`runner_stopped` is kickstarted there; "
                "a listener held off for `toolchain_mismatch` or `node_ineligible` needs its operator)."),
    "listening": ("A carrier's listener is up and idle, yet the job has not started: look at the job's labels and "
                  "the runner group before the minis."),
    "none": "No runner carries this label: the job asks for a label the fleet does not serve.",
    "unknown": ("No runner with this label is taking jobs, and the fleet gate reading cannot say whether its "
                "carriers are full or offline. On the minis, `glaeda-mini-health` reports why (`runner_stopped` is "
                "kickstarted there; a listener held off for `toolchain_mismatch` or `node_ineligible` needs its "
                "operator)."),
}


def describe(entry: Mapping[str, Any]) -> str:
    seen = entry.get("carriers") if isinstance(entry.get("carriers"), Mapping) else None
    return (f"`{entry['label']}`: {entry['queued']} job(s) queued, the oldest "
            f"({entry['job']}, {entry['job_url']}) for {format_minutes(int(entry['oldest_queued_minutes']))}, "
            f"and no job on it running or started in the last {int(STARVED_AFTER.total_seconds() // 60)} minutes"
            + (f"; carriers {seen['state']} ({seen['why']})" if seen else ""))


def rescued_runs(body: object) -> dict[int, dt.datetime]:
    """Run id -> when this alert last started its rescue, from an issue body's RESCUE_MARK."""
    out: dict[int, dt.datetime] = {}
    for mark in RESCUE_MARK.findall(str(body or "")):
        for item in mark.split():
            run, _, at = item.partition("@")
            when = parse_time(at)
            if run.isdigit() and when is not None:
                out[int(run)] = max(when, out.get(int(run), when))
    return out


def rescue_plan(entry: Mapping[str, Any], rescued: Mapping[int, dt.datetime], now: dt.datetime,
                room: int = RESCUE_RUNS_PER_SWEEP) -> list[tuple[int, int]]:
    """The (run, attempt) pairs to start a rescue for: the entry's runs stuck past RESCUE_AFTER (starved()), oldest
    first, each at most once per RESCUE_REPEAT, `room` at most. None for the persistent pool's label: a job there
    names it literally, so the rescue cannot move it, and it would only spend the sweep's rescue slots."""
    if entry.get("label") == PERSISTENT_LINUX:
        return []
    plan: list[tuple[int, int]] = []
    for pair in entry.get("runs") or ():
        if len(plan) >= room:
            break
        run, attempt = int(pair[0]), int(pair[1])
        last = rescued.get(run)
        if last is None or now - last >= RESCUE_REPEAT:
            plan.append((run, attempt))
    return plan


def start_rescues(github: Any, entry: Mapping[str, Any], rescued: dict[int, dt.datetime], now: dt.datetime,
                  room: int, lines: list[str]) -> int:
    """Dispatch rescue_plan()'s runs on main, recording each in `rescued`; returns how many started. Best effort:
    a refused dispatch is a line, never a failed alert."""
    started = 0
    for run, attempt in rescue_plan(entry, rescued, now, room):
        try:
            github.request("POST", f"/repos/{github.repo}/actions/workflows/{RESCUE_WORKFLOW}/dispatches",
                           {"ref": "main", "inputs": {"run_id": str(run), "run_attempt": str(attempt)}})
        except RuntimeError as error:
            lines.append(f"could not start run {run}'s rescue for `{entry['label']}`: {error}")
            continue
        rescued[run] = now
        started += 1
        lines.append(f"started run {run}'s rescue ({RESCUE_WORKFLOW}) for `{entry['label']}`")
    return started


def issue_body(entry: Mapping[str, Any], generated_at: str, rescued: Mapping[int, dt.datetime] | None = None) -> str:
    rescued = dict(rescued or {})
    acted = (f"A run stuck here {int(RESCUE_AFTER.total_seconds() // 60)} minutes gets its rescue started "
             f"(`{RESCUE_WORKFLOW}` with its run_id), which moves a job waiting past the owned bound to Blacksmith"
             + (f"; started for run(s) {', '.join(str(run) for run in sorted(rescued))}. " if rescued else ". "))
    mark = " ".join(f"{run}@{at.astimezone(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}"
                    for run, at in sorted(rescued.items()))
    seen = entry.get("carriers") or {}
    down = int(seen.get("down") or 0) if seen.get("state") == "full" else 0
    return (f"The CI queue janitor's sweep at {generated_at} found {describe(entry)}.\n\n"
            + CARRIER_SENTENCE[str(seen.get("state") or "unknown")] + " "
            + (f"{down} of its carriers are down with no hold, though: between jobs, or an outage on those minis "
               "(`glaeda-mini-health` says which). " if down else "")
            + acted + "This issue is updated every sweep while the "
            "label stays starved and closed by the first sweep that finds it served.\n\n"
            "Source: `scripts/ci/starved_labels.py` (ci-queue-janitor.yml)."
            + (f"\n\n<!-- starved-rescue: {mark} -->" if mark else ""))


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
                unserved: Iterable[str] = (), incomplete: bool = False,
                now: dt.datetime | None = None) -> list[str]:
    """Open, update and close the per-label issues, and start the stuck runs' rescues (rescue_plan()); returns one
    line per action."""
    repo = github.repo
    # Found by title, not by ISSUE_LABEL: GitHub drops a label that does not exist yet when the token
    # cannot create it, and a lookup by label would then open a new issue every sweep.
    query = urllib.parse.urlencode({"q": f'repo:{repo} is:issue is:open in:title "{ISSUE_PREFIX.strip()}"',
                                    "per_page": 100})
    open_issues = (github.request("GET", f"/search/issues?{query}") or {}).get("items") or []
    plan = plan_issues(found, open_issues, unserved=unserved, generated_at=generated_at, incomplete=incomplete)
    lines: list[str] = []
    now = now or parse_time(generated_at) or dt.datetime.now(dt.timezone.utc)
    room = RESCUE_RUNS_PER_SWEEP
    for issue, keeper in plan.duplicates:
        github.request("POST", f"/repos/{repo}/issues/{issue['number']}/comments",
                       {"body": f"Duplicate of #{keeper['number']}, which tracks this label."})
        github.request("PATCH", f"/repos/{repo}/issues/{issue['number']}",
                       {"state": "closed", "state_reason": "not_planned"})
        lines.append(f"closed #{issue['number']} as a duplicate of #{keeper['number']}")
    for entry in plan.open:
        rescued: dict[int, dt.datetime] = {}
        room -= start_rescues(github, entry, rescued, now, room, lines)
        created = github.request("POST", f"/repos/{repo}/issues", {
            "title": issue_title(entry["label"]), "body": issue_body(entry, generated_at, rescued),
            "labels": [ISSUE_LABEL]})
        lines.append(f"opened #{created.get('number')} for `{entry['label']}`")
    for issue, entry in plan.update:
        rescued = rescued_runs(issue.get("body"))
        room -= start_rescues(github, entry, rescued, now, room, lines)
        github.request("PATCH", f"/repos/{repo}/issues/{issue['number']}",
                       {"body": issue_body(entry, generated_at, rescued)})
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
    generated_at = str(snapshot.get("generated_at") or "")
    # The gate reading is judged against the sweep that wrote it (the snapshot is read seconds later, same job).
    now = parse_time(generated_at) or dt.datetime.now(dt.timezone.utc)
    found = [{**entry, "carriers": carriers(str(entry["label"]), snapshot.get("gates"), now)}
             for entry in snapshot["starved"]]
    lines = ["", "### Starved runner labels", ""]
    for entry in found:
        print(f"::error title=Runner label starved::{entry['label']} took no job for "
              f"{format_minutes(int(entry['oldest_queued_minutes']))}, carriers {entry['carriers']['state']}: "
              f"{entry['job_url']}")
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
