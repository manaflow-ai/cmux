#!/usr/bin/env python3
"""Move jobs off a runner label that has stopped starting jobs: the dead-label re-dispatch.

GitHub binds a job's runner label when it creates the job. When a label stops
starting jobs, every job already queued on it waits there, and pointing the
runner variables elsewhere (cloud_overflow_switch.py) only moves jobs created
after the switch. On 2026-10-28 the Blacksmith 16 vCPU Linux label started
nothing from about 22:12Z and about 1,300 runs sat queued while the 32 vCPU
label beside it served. Leo: "Bro, I thought we already had logic to
automatically route shit. How can we still have pins like this? I hate pins.
Like, just pin the set of the shit that isn't hilariously slow."

A label is dead (dead_labels()) when, in the queue janitor's inventory:
  - a job on it has been queued with no runner for DEAD_AFTER (3 min) since it
    could first run (starved_labels.wait_start(): a running sibling, which may
    be its `needs`, means its wait has not begun), and
  - no job asking for a subset of its labels started within DEAD_AFTER. An owned
    fleet label (``glaeda-*``) also counts a running job as service: a busy
    pool of minis is not dead. A Blacksmith label does not: its VMs keep
    running jobs they took before the stall, so only a start shows it serves;
  - some other label of the same family (DECLARED_SETS: Linux or macOS) did
    start a job within DEAD_AFTER. That is the live member a re-run can land
    on, and the proof that the inventory sees starts at all. When nothing in
    the family started (an org-wide stall, or every pool backed up), nothing
    moves: a re-run would only queue again.

A run holding such a job is re-dispatched (plan()): force-cancelled, then its
failed and cancelled jobs re-run, which evaluates runs-on again against the
current runner variables, so the job takes the route the variables name now.
It is never re-dispatched when:
  - a job of it is running (cancelling would throw that work away; a later
    sweep takes the run once the job ends);
  - it is a nightly, DEV or promote run whose build has started
    (delivery_workflows.build_started(), the check the agents' cancel guard and
    the janitor's superseded pass use): "Never cancel a NEXT nightly, dev or
    promote build or its Release compile once it has started";
  - it is a release, merge-queue or tag event, or a release, publish,
    notarization, TestFlight or App Store workflow;
  - it is on attempt MAX_ATTEMPT or later: something re-ran it twice already;
  - the dead label is the route a re-run takes again (`routes`: the live value
    of LINUX_RUNNER and the other runner variables, and the labels workflows
    fall back to when those are unset). The re-run would queue on the same
    label; the overflow switch moves that route first, and a later sweep
    re-dispatches the run.
The re-run follows the cancel in the same sweep (redispatch()), so nobody
loses a run. A run whose cancel has not settled within SETTLE_SECONDS is named
in the summary as an error to re-run by hand.
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import re
import time
from collections.abc import Callable, Iterable, Mapping, Sequence
from typing import Any

import starved_labels
from delivery_workflows import attempt_jobs, build_started, is_delivery_run

DEAD_AFTER = dt.timedelta(minutes=3)
MAX_ATTEMPT = 3
DEFAULT_MAX_REDISPATCH = 20
MAX_REDISPATCH_LIMIT = 50
SETTLE_SECONDS = 90
POLL_SECONDS = 5

# The labels a job may be routed to, by family. "Live member" means a label of
# the job's family that started a job within DEAD_AFTER. GitHub-hosted labels
# are no member: no job runs there (Leo, 2026-10-27).
DECLARED_SETS: dict[str, re.Pattern[str]] = {
    "linux": re.compile(r"^blacksmith-\d+vcpu-ubuntu-\d+(-arm)?$"),
    "macos": re.compile(r"^(glaeda-[a-z0-9.+-]+|blacksmith-\d+vcpu-macos-\d+)$"),
}
FLEET_PREFIX = starved_labels.FLEET_PREFIX
# Workflows fall back to this when LINUX_RUNNER is unset (docs/ci-runners.md), so it is a route then.
DEFAULT_LINUX_ROUTE = "blacksmith-4vcpu-ubuntu-2404"

PROTECTED_EVENTS = frozenset({"release", "merge_group", "create", "delete", "deployment", "deployment_status"})
PROTECTED_WORKFLOW = re.compile(r"release|publish|notar|testflight|app[-_ ]?store", re.IGNORECASE)
TAG_LIKE_REF = re.compile(r"^(v\d|cmux-tui-v\d|.*-v\d+\.\d+)")


def parse_time(value: Any) -> dt.datetime | None:
    return starved_labels.parse_time(value if isinstance(value, str) else None)


def label_key(job: Mapping[str, Any]) -> frozenset[str]:
    return frozenset(str(label).lower() for label in job.get("labels") or ())


def family(labels: Iterable[str]) -> str | None:
    """The declared family every label of a job belongs to, or None (a hosted label, or a mix)."""
    labels = list(labels)
    found = {name for label in labels for name, pattern in DECLARED_SETS.items() if pattern.match(label)}
    if len(found) != 1 or not all(any(p.match(label) for p in DECLARED_SETS.values()) for label in labels):
        return None
    return next(iter(found))


def _fleet(labels: frozenset[str]) -> bool:
    return any(label.startswith(FLEET_PREFIX) for label in labels)


def started_within(job: Mapping[str, Any], now: dt.datetime, window: dt.timedelta) -> bool:
    """A runner took the job within `window`. A queued job's started_at is set when it is queued, so the
    runner decides."""
    if not job.get("runner_name"):
        return False
    started = parse_time(job.get("started_at"))
    return started is not None and dt.timedelta(0) <= now - started <= window


def _serves(job: Mapping[str, Any], now: dt.datetime, window: dt.timedelta) -> bool:
    if started_within(job, now, window):
        return True
    # A running job on an owned label proves a listener is online (starved_labels).
    return job.get("status") == "in_progress" and _fleet(label_key(job))


@dataclasses.dataclass(frozen=True)
class DeadLabel:
    labels: frozenset[str]
    family: str
    oldest: dt.timedelta
    queued: int
    live: tuple[str, ...]  # labels of the family that started a job within the window

    def name(self) -> str:
        return ",".join(sorted(self.labels))

    def as_json(self) -> dict[str, Any]:
        return {"label": self.name(), "family": self.family, "queued": self.queued,
                "oldest_queued_minutes": int(self.oldest.total_seconds() // 60), "live": list(self.live)}


def dead_labels(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], *,
                now: dt.datetime, evidence: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
                after: dt.timedelta = DEAD_AFTER) -> list[DeadLabel]:
    """The label sets with a job stuck past `after` and no start within it, while their family has a live member."""
    all_jobs = [job for run in runs for job in jobs_by_run.get(run.get("id"), ())]
    all_jobs += [job for jobs in (evidence or {}).values() for job in jobs]
    served = [label_key(job) for job in all_jobs if _serves(job, now, after)]
    started = {label for job in all_jobs if started_within(job, now, after) for label in label_key(job)}
    waits: dict[frozenset[str], list[dt.timedelta]] = {}
    for run in runs:
        run_jobs = list(jobs_by_run.get(run.get("id"), ()))
        for job in run_jobs:
            labels = label_key(job)
            if not starved_labels.stuck(job) or not labels or family(labels) is None:
                continue
            if any(labels <= other for other in served):
                continue
            # Siblings stuck on another unserved label are no gate (starved_labels.wait_start()).
            suspects = frozenset(id(other) for other in run_jobs if starved_labels.stuck(other)
                                 and not any(label_key(other) <= s for s in served))
            wait = starved_labels.wait_start(job, run_jobs, suspects)
            if wait is None or wait[1]:
                continue  # a running or queued sibling may be its gate
            if now - wait[0] >= after:
                waits.setdefault(labels, []).append(now - wait[0])
    found = []
    for labels, ages in sorted(waits.items(), key=lambda item: sorted(item[0])):
        kind = family(labels)
        live = tuple(sorted(label for label in started - labels
                            if kind and DECLARED_SETS[kind].match(label)))
        if kind and live:
            found.append(DeadLabel(labels, kind, max(ages), len(ages), live))
    return found


def protected_reason(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]]) -> str | None:
    """Why a run holding a job on a dead label is left alone, or None."""
    event, branch = str(run.get("event") or ""), str(run.get("head_branch") or "")
    if not event:
        return "its event could not be read"
    if event in PROTECTED_EVENTS:
        return f"a {event} run"
    if branch and TAG_LIKE_REF.match(branch):
        return f"tag-like ref {branch}"
    if PROTECTED_WORKFLOW.search(f"{run.get('name') or ''} {run.get('path') or ''}"):
        return "a release, publish, notarization, TestFlight or App Store workflow"
    attempt = run.get("run_attempt")
    if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
        return "its attempt could not be read"
    if attempt >= MAX_ATTEMPT:
        return f"already on attempt {attempt}"
    if is_delivery_run(run.get("path"), run.get("name"), run.get("display_title")):
        mine = attempt_jobs(run, jobs)
        if mine is None:
            return "a nightly, DEV or promote run whose attempt's jobs could not be read"
        started = build_started(mine)
        if started:
            return f"a nightly, DEV or promote run that has started ({started})"
    running = next((job for job in jobs if job.get("status") == "in_progress"), None)
    if running is not None:
        return f"its job {running.get('name')!r} is running; a later sweep takes it once that ends"
    return None


@dataclasses.dataclass(frozen=True)
class Redispatch:
    run: Mapping[str, Any]
    job: str
    label: str
    why_not: str | None  # None: re-dispatch it

    def line(self) -> str:
        what = f"run {self.run.get('id')} ({self.run.get('name')}): `{self.job}` stuck on `{self.label}`"
        return f"{what}; left alone: {self.why_not}" if self.why_not else what


def plan(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
         dead: Sequence[DeadLabel], *, routes: Iterable[str] = (), exclude: Iterable[int] = (),
         max_runs: int = DEFAULT_MAX_REDISPATCH) -> list[Redispatch]:
    """One decision per run holding a stuck job on a dead label, oldest run first; at most `max_runs` go."""
    by_labels = {item.labels: item for item in dead}
    routed = {str(route).strip().lower() for route in routes if str(route or "").strip()}
    skip = set(exclude)
    decisions: list[Redispatch] = []
    going = 0
    for run in sorted(runs, key=lambda r: (str(r.get("created_at") or ""), r.get("id") or 0)):
        if run.get("id") in skip or run.get("status") not in ("queued", "in_progress", "waiting", "pending"):
            continue
        jobs = list(jobs_by_run.get(run.get("id"), ()))
        stuck = next((job for job in jobs if starved_labels.stuck(job) and label_key(job) in by_labels), None)
        if stuck is None:
            continue
        labels = label_key(stuck)
        name = by_labels[labels].name()
        why = protected_reason(run, jobs)
        if why is None and labels & routed:
            why = (f"`{name}` is the route a re-run takes again; the overflow switch moves that route first")
        if why is None and going >= max_runs:
            why = f"this sweep's cap of {max_runs} re-dispatches is used; the next sweep takes it"
        if why is None:
            going += 1
        decisions.append(Redispatch(run, str(stuck.get("name") or ""), name, why))
    return decisions


def routes_from_env(env: Mapping[str, str]) -> list[str]:
    """The labels a re-run is routed to now: DEAD_LABEL_ROUTES (whitespace separated live runner variable
    values), plus DEFAULT_LINUX_ROUTE when LINUX_RUNNER (DEAD_LABEL_LINUX_RUNNER) is unset."""
    routes = (env.get("DEAD_LABEL_ROUTES") or "").split()
    if not (env.get("DEAD_LABEL_LINUX_RUNNER") or "").strip():
        routes.append(DEFAULT_LINUX_ROUTE)
    return routes


def redispatch(github: Any, decisions: Sequence[Redispatch], *, dry_run: bool,
               now: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep,
               settle_seconds: float = SETTLE_SECONDS) -> tuple[dict[int, str], int]:
    """Force-cancel every run that goes, then re-run each once its cancel settles. ({run id: result}, failures).

    `github` is queue_janitor.GitHub: force_cancel(id), run(id) and rerun_failed(id)."""
    going = [d for d in decisions if d.why_not is None]
    results: dict[int, str] = {}
    failures = 0
    if dry_run:
        return {int(d.run["id"]): "would force-cancel and re-run (dry run)" for d in going}, 0
    pending: dict[int, int] = {}
    for decision in going:
        run_id = int(decision.run["id"])
        try:
            github.force_cancel(run_id)
            pending[run_id] = int(decision.run.get("run_attempt") or 1)
        except RuntimeError as error:
            if type(error).__name__ == "RateLimited":
                raise
            results[run_id] = f"force-cancel failed ({error})"
            failures += 1
    deadline = now() + settle_seconds
    while pending:
        for run_id, attempt in list(pending.items()):
            try:
                run = github.run(run_id)
            except RuntimeError:
                continue
            if run.get("run_attempt") != attempt:
                results[run_id] = "cancelled; someone else re-ran it meanwhile"
                del pending[run_id]
            elif run.get("status") == "completed":
                try:
                    github.rerun_failed(run_id)
                    results[run_id] = "force-cancelled and re-run on the current route"
                except RuntimeError as error:
                    if type(error).__name__ == "RateLimited":
                        raise
                    results[run_id] = f"force-cancelled, but the re-run failed ({error}); re-run it by hand"
                    failures += 1
                del pending[run_id]
        if pending and now() >= deadline:
            for run_id in pending:
                results[run_id] = (f"force-cancelled, but still finishing after {int(settle_seconds)} s; "
                                   "re-run it by hand")
                failures += 1
            break
        if pending:
            sleep(POLL_SECONDS)
    return results, failures


def render_summary(dead: Sequence[DeadLabel], decisions: Sequence[Redispatch], results: Mapping[int, str]) -> str:
    if not dead:
        return ""
    lines = ["", "### Dead runner labels", ""]
    for item in dead:
        lines.append(f"- `{item.name()}`: {item.queued} job(s) queued past {int(DEAD_AFTER.total_seconds() // 60)} "
                     f"min (oldest {int(item.oldest.total_seconds() // 60)} min) and none started; live in its "
                     f"family: {', '.join(f'`{label}`' for label in item.live)}")
    for decision in decisions:
        result = results.get(int(decision.run["id"]))
        lines.append(f"- {decision.line()}" + (f": {result}" if result else ""))
        if result and ("by hand" in result or "failed" in result):
            print(f"::error title=Dead-label re-dispatch::run {decision.run['id']}: {result}")
    return "\n".join(lines) + "\n"
