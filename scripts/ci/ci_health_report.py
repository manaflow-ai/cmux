#!/usr/bin/env python3
"""Measure where CI time goes, so waste stops being something people discover by hand.

Everything that has ever been found about this repo's CI waste -- a macOS pool
that saturates near a dozen concurrent jobs while queue waits run into hours,
runs cancelled after they had already paid for macOS minutes, a full suite red
for days, workflows whose runs are almost entirely skipped, nightly rebuilding
on every main push, reruns of a tree nobody changed -- was found by somebody
querying the Actions API by hand. This report asks those questions on a
schedule instead.

It only measures. Cancelling wasted demand is scripts/ci/queue_janitor.py's
job (#13721); this script deliberately has no write access to runs, and reuses
the janitor's `parse_time`, `is_macos_job` and `linux_only_workflow_paths`
helpers rather than restating them.

What it reports for a window:

  * runner minutes by workflow, by job and by runner label, split by
    conclusion (success, failure, cancelled, skipped);
  * queue wait (created -> started) percentiles per runner label, which is the
    number that separates "our builds got slower" from "the pool is capped";
  * wasteful patterns: runs cancelled after real macOS work, one job failing
    across unrelated heads (a main-broken signal, not a flaky PR), workflows
    whose runs are overwhelmingly skipped, and repeat runs of an unchanged
    tree;
  * the same headline numbers for the previous window, so a regression shows
    up as a change rather than as a number nobody has a baseline for.

API usage is bounded by page caps rather than by time: nothing is cached, the
call count is stated in the summary, and a rate limit or API failure degrades
the report to partial data instead of failing the run.

Every function above `GitHub` is pure over already-fetched JSON, which is what
tests/test_ci_health_report.py exercises over fixtures.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from collections.abc import Callable, Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any

# The janitor already owns "what does a timestamp mean", "is this a macOS job"
# and "can this workflow schedule macOS work at all". Importing them keeps one
# answer in the tree instead of two that can drift apart.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from queue_janitor import (  # noqa: E402
    is_macos_job,
    linux_only_workflow_paths,
    parse_time,
)


API = "https://api.github.com"
UTC = dt.timezone.utc

DEFAULT_WINDOW_HOURS = 6
DEFAULT_MAX_RUN_PAGES = 12
DEFAULT_MAX_JOB_LISTINGS = 120
DEFAULT_JOBS_PER_WORKFLOW = 3
MAX_JOB_PAGES = 2
MAX_COMMENT_PAGES = 5
RUNS_PER_PAGE = 100

# Thresholds that turn a number into an action. docs/ci/health-report.md says
# what each one means and what to do when it trips.
QUEUE_P90_ALERT_MINUTES = 20.0
CANCELLED_SHARE_ALERT = 0.35
FAILURE_SHARE_ALERT = 0.20
SKIPPED_WORKFLOW_RATIO = 0.90
SKIPPED_WORKFLOW_MIN_RUNS = 20
CANCELLED_MACOS_WASTE_MINUTES = 5.0
REPEATED_FAILURE_MIN_HEADS = 3
UNCHANGED_TREE_MIN_RUNS = 2

START_MARKER = "<!-- ci-health-report:start -->"
END_MARKER = "<!-- ci-health-report:end -->"
REPORT_TITLE_PREFIX = "[CI Health]"

# The four buckets the report splits minutes by, plus a catch-all. `timed_out`
# and `startup_failure` are failures that cost the same minutes as a failure.
CONCLUSION_BUCKETS = {
    "success": "success",
    "failure": "failure",
    "timed_out": "failure",
    "startup_failure": "failure",
    "cancelled": "cancelled",
    "skipped": "skipped",
}
BUCKETS = ("success", "failure", "cancelled", "skipped", "other")


# ---------------------------------------------------------------------------
# Window and shape
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Window:
    """A half-open [start, end) span of run creation times."""

    start: dt.datetime
    end: dt.datetime

    @property
    def hours(self) -> float:
        return (self.end - self.start).total_seconds() / 3600.0

    def query(self) -> str:
        return f"{iso(self.start)}..{iso(self.end)}"

    def label(self) -> str:
        return f"{self.start.strftime('%Y-%m-%d %H:%M')} → {self.end.strftime('%Y-%m-%d %H:%M')} UTC"


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def windows(now: dt.datetime, hours: int) -> tuple[Window, Window]:
    """The window being reported and the one immediately before it."""
    span = dt.timedelta(hours=hours)
    current = Window(now - span, now)
    return current, Window(now - 2 * span, now - span)


def bucket_of(conclusion: str | None) -> str:
    return CONCLUSION_BUCKETS.get(conclusion or "", "other")


def run_conclusion(run: Mapping[str, Any]) -> str:
    """A run's conclusion, or its status while it has not reached one."""
    if run.get("status") != "completed":
        return str(run.get("status") or "unknown")
    return str(run.get("conclusion") or "unknown")


def workflow_name(run: Mapping[str, Any]) -> str:
    return str(run.get("name") or run.get("path") or "unknown")


def is_fork_run(run: Mapping[str, Any], repo: str) -> bool:
    head = ((run.get("head_repository") or {}).get("full_name")) or ""
    return bool(head) and head.lower() != repo.lower()


def runner_label(job: Mapping[str, Any]) -> str:
    """The runner label a job asked for, as one string.

    A job can declare several labels; joining them keeps a `[self-hosted, macos]`
    request from being counted as if it were the same pool as a bare `macos`.
    """
    labels = [str(label) for label in (job.get("labels") or ()) if str(label).strip()]
    if not labels:
        return str(job.get("runner_group_name") or "unknown")
    return "+".join(sorted(labels))


@dataclasses.dataclass(frozen=True)
class JobRow:
    """One job, joined to the run that scheduled it."""

    workflow: str
    job: str
    label: str
    bucket: str
    conclusion: str
    minutes: float
    queue_seconds: float | None
    macos: bool
    run_id: int
    run_url: str
    run_attempt: int
    head_sha: str
    branch: str
    event: str
    fork: bool


def job_rows(run: Mapping[str, Any], jobs: Iterable[Mapping[str, Any]], repo: str) -> list[JobRow]:
    """Flatten one run's jobs into rows the aggregations read.

    A job that never started bought no runner minutes but can still have waited,
    so its queue wait is kept and its minutes are zero.
    """
    fork = is_fork_run(run, repo)
    rows: list[JobRow] = []
    for job in jobs:
        created = parse_time(job.get("created_at"))
        started = parse_time(job.get("started_at"))
        completed = parse_time(job.get("completed_at"))
        minutes = 0.0
        if started and completed and completed > started:
            minutes = (completed - started).total_seconds() / 60.0
        queue_seconds: float | None = None
        if created and started and started >= created:
            queue_seconds = (started - created).total_seconds()
        conclusion = str(job.get("conclusion") or job.get("status") or "unknown")
        rows.append(
            JobRow(
                workflow=workflow_name(run),
                job=str(job.get("name") or "unknown"),
                label=runner_label(job),
                bucket=bucket_of(job.get("conclusion")),
                conclusion=conclusion,
                minutes=minutes,
                queue_seconds=queue_seconds,
                macos=is_macos_job(job),
                run_id=int(run.get("id") or 0),
                run_url=str(run.get("html_url") or ""),
                run_attempt=int(run.get("run_attempt") or 1),
                head_sha=str(run.get("head_sha") or ""),
                branch=str(run.get("head_branch") or ""),
                event=str(run.get("event") or ""),
                fork=fork,
            )
        )
    return rows


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------


def count_by_bucket(runs: Iterable[Mapping[str, Any]]) -> dict[str, int]:
    counts = {bucket: 0 for bucket in BUCKETS}
    for run in runs:
        conclusion = run_conclusion(run)
        if run.get("status") != "completed":
            counts["other"] = counts.get("other", 0) + 1
            continue
        counts[bucket_of(conclusion)] = counts.get(bucket_of(conclusion), 0) + 1
    return counts


def share(part: float, whole: float) -> float:
    return part / whole if whole else 0.0


@dataclasses.dataclass(frozen=True)
class MinuteCell:
    minutes: dict[str, float]
    jobs: int

    @property
    def total(self) -> float:
        return sum(self.minutes.values())


def aggregate_minutes(
    rows: Iterable[JobRow], key: Callable[[JobRow], Any]
) -> dict[Any, MinuteCell]:
    """Runner minutes for each key, split by conclusion bucket."""
    minutes: dict[Any, dict[str, float]] = defaultdict(lambda: {bucket: 0.0 for bucket in BUCKETS})
    jobs: dict[Any, int] = defaultdict(int)
    for row in rows:
        group = key(row)
        minutes[group][row.bucket] = minutes[group].get(row.bucket, 0.0) + row.minutes
        jobs[group] += 1
    return {group: MinuteCell(dict(values), jobs[group]) for group, values in minutes.items()}


def top_cells(cells: Mapping[Any, MinuteCell], limit: int) -> list[tuple[Any, MinuteCell]]:
    return sorted(cells.items(), key=lambda pair: (-pair[1].total, str(pair[0])))[:limit]


def percentile(sorted_values: Sequence[float], pct: float) -> float:
    """Nearest-rank percentile; deterministic and dependency-free."""
    if not sorted_values:
        return 0.0
    rank = max(1, min(len(sorted_values), int(-(-pct * len(sorted_values) // 100))))
    return sorted_values[rank - 1]


@dataclasses.dataclass(frozen=True)
class QueueStats:
    label: str
    jobs: int
    p50: float
    p90: float
    p99: float
    worst: float
    macos: bool

    @property
    def alerting(self) -> bool:
        return self.p90 > QUEUE_P90_ALERT_MINUTES


def queue_wait_stats(rows: Iterable[JobRow]) -> list[QueueStats]:
    """Queue wait percentiles in minutes, per runner label.

    On a capped pool this is the metric that moves first: the jobs are not
    slower, they are waiting for a runner that does not exist yet.
    """
    waits: dict[str, list[float]] = defaultdict(list)
    macos: dict[str, bool] = {}
    for row in rows:
        if row.queue_seconds is None:
            continue
        waits[row.label].append(row.queue_seconds / 60.0)
        macos[row.label] = macos.get(row.label, False) or row.macos
    stats = []
    for label, values in waits.items():
        values.sort()
        stats.append(
            QueueStats(
                label=label,
                jobs=len(values),
                p50=percentile(values, 50),
                p90=percentile(values, 90),
                p99=percentile(values, 99),
                worst=values[-1],
                macos=macos.get(label, False),
            )
        )
    stats.sort(key=lambda item: (-item.p90, item.label))
    return stats


def macos_queue_p90(stats: Sequence[QueueStats]) -> float | None:
    """The worst macOS p90 across labels, which is the pool people feel."""
    macos = [item.p90 for item in stats if item.macos]
    return max(macos) if macos else None


# ---------------------------------------------------------------------------
# Wasteful patterns
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class CancelledWaste:
    workflow: str
    job: str
    runs: int
    minutes: float
    worst_minutes: float


def cancelled_macos_waste(
    rows: Iterable[JobRow], threshold_minutes: float = CANCELLED_MACOS_WASTE_MINUTES
) -> list[CancelledWaste]:
    """macOS jobs cancelled only after they had already spent real minutes.

    A cancel one minute in costs nothing; a cancel forty minutes into a compile
    burned a slot on the capped pool that a job somebody was waiting on could
    have had.
    """
    grouped: dict[tuple[str, str], list[float]] = defaultdict(list)
    for row in rows:
        if not row.macos or row.bucket != "cancelled":
            continue
        if row.minutes < threshold_minutes:
            continue
        grouped[(row.workflow, row.job)].append(row.minutes)
    waste = [
        CancelledWaste(workflow, job, len(values), sum(values), max(values))
        for (workflow, job), values in grouped.items()
    ]
    waste.sort(key=lambda item: (-item.minutes, item.workflow, item.job))
    return waste


@dataclasses.dataclass(frozen=True)
class RepeatedFailure:
    workflow: str
    job: str
    heads: int
    failures: int
    branches: tuple[str, ...]


def repeated_job_failures(
    rows: Iterable[JobRow], min_heads: int = REPEATED_FAILURE_MIN_HEADS
) -> list[RepeatedFailure]:
    """One job failing across unrelated heads: main is broken, not a PR.

    Grouping by head SHA is what makes it a main signal. A single PR failing
    the same job ten times is one author's problem; the same job failing on
    heads that share nothing is everybody's.
    """
    heads: dict[tuple[str, str], set[str]] = defaultdict(set)
    branches: dict[tuple[str, str], set[str]] = defaultdict(set)
    counts: dict[tuple[str, str], int] = defaultdict(int)
    for row in rows:
        if row.bucket != "failure":
            continue
        key = (row.workflow, row.job)
        heads[key].add(row.head_sha)
        branches[key].add(row.branch or "(unknown)")
        counts[key] += 1
    repeated = [
        RepeatedFailure(
            workflow,
            job,
            len(heads[(workflow, job)]),
            counts[(workflow, job)],
            tuple(sorted(branches[(workflow, job)])[:4]),
        )
        for (workflow, job) in counts
        if len(heads[(workflow, job)]) >= min_heads
    ]
    repeated.sort(key=lambda item: (-item.heads, -item.failures, item.workflow, item.job))
    return repeated


@dataclasses.dataclass(frozen=True)
class SkippedWorkflow:
    workflow: str
    runs: int
    skipped: int

    @property
    def ratio(self) -> float:
        return share(self.skipped, self.runs)


def mostly_skipped_workflows(
    runs: Iterable[Mapping[str, Any]],
    *,
    ratio: float = SKIPPED_WORKFLOW_RATIO,
    min_runs: int = SKIPPED_WORKFLOW_MIN_RUNS,
) -> list[SkippedWorkflow]:
    """Workflows that mostly exist to decide they had nothing to do.

    A shim that skips is cheap per run and expensive per day: it still queues a
    runner, still writes a check, and still shows up in every list of runs
    anybody reads.
    """
    totals: dict[str, int] = defaultdict(int)
    skipped: dict[str, int] = defaultdict(int)
    for run in runs:
        name = workflow_name(run)
        totals[name] += 1
        if run.get("status") == "completed" and bucket_of(run.get("conclusion")) == "skipped":
            skipped[name] += 1
    found = [
        SkippedWorkflow(name, total, skipped[name])
        for name, total in totals.items()
        if total >= min_runs and share(skipped[name], total) >= ratio
    ]
    found.sort(key=lambda item: (-item.skipped, item.workflow))
    return found


@dataclasses.dataclass(frozen=True)
class UnchangedTreeReruns:
    workflow: str
    head_sha: str
    runs: int
    retries: int
    branch: str


def unchanged_tree_reruns(
    runs: Iterable[Mapping[str, Any]], *, min_runs: int = UNCHANGED_TREE_MIN_RUNS
) -> list[UnchangedTreeReruns]:
    """The same workflow running more than once over one unchanged head.

    Both shapes count: a second run created for a head that already had one
    (a bot editing a PR body re-requests required checks), and a re-run attempt
    of the same run. Neither read a different tree than the first.
    """
    grouped: dict[tuple[str, str, str], set[int]] = defaultdict(set)
    attempts: dict[tuple[str, str, str], int] = defaultdict(int)
    branch: dict[tuple[str, str, str], str] = {}
    for run in runs:
        sha = str(run.get("head_sha") or "")
        if not sha:
            continue
        key = (workflow_name(run), sha, str(run.get("event") or ""))
        grouped[key].add(int(run.get("id") or 0))
        attempts[key] = max(attempts[key], int(run.get("run_attempt") or 1))
        branch.setdefault(key, str(run.get("head_branch") or ""))
    repeated = []
    for key, ids in grouped.items():
        total = len(ids)
        retries = attempts[key] - 1
        if total < min_runs and retries <= 0:
            continue
        repeated.append(UnchangedTreeReruns(key[0], key[1], total, max(0, retries), branch.get(key, "")))
    repeated.sort(key=lambda item: (-(item.runs + item.retries), item.workflow, item.head_sha))
    return repeated


def fork_runs_without_cache(rows: Iterable[JobRow]) -> tuple[int, float]:
    """Jobs from forks and the minutes they spent.

    Fork pull requests cannot read the repository's Actions cache, so every
    minute here is a cache miss somebody is paying for twice.
    """
    minutes = 0.0
    jobs = 0
    for row in rows:
        if not row.fork:
            continue
        jobs += 1
        minutes += row.minutes
    return jobs, minutes


# ---------------------------------------------------------------------------
# Window metrics and comparison
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class WindowMetrics:
    window: Window
    runs_fetched: int
    covered_hours: float
    truncated: bool
    buckets: dict[str, int]
    sampled_runs: int
    sampled_jobs: int
    job_minutes: float
    macos_minutes: float
    macos_queue_p90: float | None
    queue: list[QueueStats]
    rows: list[JobRow]
    runs: list[Mapping[str, Any]]
    partial: tuple[str, ...]

    @property
    def runs_per_hour(self) -> float:
        return share(self.runs_fetched, self.covered_hours)

    @property
    def cancelled_share(self) -> float:
        return share(self.buckets.get("cancelled", 0), self.runs_fetched)

    @property
    def failure_share(self) -> float:
        return share(self.buckets.get("failure", 0), self.runs_fetched)

    @property
    def skipped_share(self) -> float:
        return share(self.buckets.get("skipped", 0), self.runs_fetched)

    @property
    def minutes_per_sampled_run(self) -> float:
        return share(self.job_minutes, self.sampled_runs)


def covered_hours(runs: Sequence[Mapping[str, Any]], window: Window) -> tuple[float, bool]:
    """How much of the window the fetched runs actually cover.

    The runs endpoint returns newest first, so a page cap truncates the *old*
    end of the window. Reporting the covered span (and saying the numbers are
    rates over it) is honest where reporting the window would not be.
    """
    created = [parse_time(run.get("created_at")) for run in runs]
    stamps = [moment for moment in created if moment is not None]
    if not stamps:
        return window.hours, False
    oldest = min(stamps)
    if oldest <= window.start + dt.timedelta(minutes=1):
        return window.hours, False
    return max(0.0, (window.end - oldest).total_seconds() / 3600.0), True


def build_metrics(
    *,
    window: Window,
    runs: Sequence[Mapping[str, Any]],
    rows: Sequence[JobRow],
    sampled_runs: int,
    partial: Sequence[str],
) -> WindowMetrics:
    hours, truncated = covered_hours(runs, window)
    queue = queue_wait_stats(rows)
    return WindowMetrics(
        window=window,
        runs_fetched=len(runs),
        covered_hours=hours,
        truncated=truncated,
        buckets=count_by_bucket(runs),
        sampled_runs=sampled_runs,
        sampled_jobs=len(rows),
        job_minutes=sum(row.minutes for row in rows),
        macos_minutes=sum(row.minutes for row in rows if row.macos),
        macos_queue_p90=macos_queue_p90(queue),
        queue=queue,
        rows=list(rows),
        runs=list(runs),
        partial=tuple(partial),
    )


@dataclasses.dataclass(frozen=True)
class Comparison:
    metric: str
    current: str
    previous: str
    change: str
    alerting: bool


def _delta(current: float | None, previous: float | None, *, unit: str = "", pct: bool = False) -> str:
    if current is None or previous is None:
        return "n/a"
    delta = current - previous
    if pct:
        return f"{delta * 100:+.1f} pt"
    return f"{delta:+.1f}{unit}"


def _fmt(value: float | None, *, unit: str = "", pct: bool = False) -> str:
    if value is None:
        return "n/a"
    if pct:
        return f"{value * 100:.1f}%"
    return f"{value:.1f}{unit}"


def compare(current: WindowMetrics, previous: WindowMetrics) -> list[Comparison]:
    """Headline numbers beside the previous window, so a regression is visible."""
    rows = [
        Comparison(
            "Runs created per hour",
            _fmt(current.runs_per_hour),
            _fmt(previous.runs_per_hour),
            _delta(current.runs_per_hour, previous.runs_per_hour),
            False,
        ),
        Comparison(
            "Cancelled share of runs",
            _fmt(current.cancelled_share, pct=True),
            _fmt(previous.cancelled_share, pct=True),
            _delta(current.cancelled_share, previous.cancelled_share, pct=True),
            current.cancelled_share >= CANCELLED_SHARE_ALERT,
        ),
        Comparison(
            "Failed share of runs",
            _fmt(current.failure_share, pct=True),
            _fmt(previous.failure_share, pct=True),
            _delta(current.failure_share, previous.failure_share, pct=True),
            current.failure_share >= FAILURE_SHARE_ALERT,
        ),
        Comparison(
            "Skipped share of runs",
            _fmt(current.skipped_share, pct=True),
            _fmt(previous.skipped_share, pct=True),
            _delta(current.skipped_share, previous.skipped_share, pct=True),
            False,
        ),
        Comparison(
            "macOS queue wait p90 (min)",
            _fmt(current.macos_queue_p90),
            _fmt(previous.macos_queue_p90),
            _delta(current.macos_queue_p90, previous.macos_queue_p90),
            bool(current.macos_queue_p90 and current.macos_queue_p90 > QUEUE_P90_ALERT_MINUTES),
        ),
        Comparison(
            "Sampled runner minutes per run",
            _fmt(current.minutes_per_sampled_run),
            _fmt(previous.minutes_per_sampled_run),
            _delta(current.minutes_per_sampled_run, previous.minutes_per_sampled_run),
            False,
        ),
    ]
    return rows


# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------


def evenly_spaced(items: Sequence[Any], count: int) -> list[Any]:
    """`count` items spread across `items`, deterministically."""
    if count <= 0 or not items:
        return []
    if len(items) <= count:
        return list(items)
    step = len(items) / count
    return [items[min(len(items) - 1, int(index * step))] for index in range(count)]


def choose_job_runs(
    runs: Sequence[Mapping[str, Any]],
    *,
    per_workflow: int,
    total_cap: int,
    linux_only_paths: frozenset[str] = frozenset(),
) -> list[Mapping[str, Any]]:
    """Pick the runs worth spending a job listing on.

    Job listings are the expensive call, so the sample is spread across
    workflows rather than down the newest runs of the busiest one, and
    macOS-capable workflows go first: they are the ones whose queue wait and
    minutes the report exists to watch.
    """
    by_workflow: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    for run in runs:
        if run.get("status") != "completed":
            continue
        by_workflow[workflow_name(run)].append(run)

    def macos_capable(name: str) -> bool:
        paths = {str(run.get("path") or "") for run in by_workflow[name]}
        return not paths.issubset(linux_only_paths) if linux_only_paths else True

    order = sorted(
        by_workflow,
        key=lambda name: (not macos_capable(name), -len(by_workflow[name]), name),
    )
    picks = {name: evenly_spaced(by_workflow[name], per_workflow) for name in order}

    chosen: list[Mapping[str, Any]] = []
    for index in range(per_workflow):
        for name in order:
            if len(chosen) >= total_cap:
                return chosen
            if index < len(picks[name]):
                chosen.append(picks[name][index])
    return chosen


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def _escape(value: str) -> str:
    return value.replace("|", "\\|")


def _minutes_table(title: str, cells: Sequence[tuple[Any, MinuteCell]], key_header: str) -> list[str]:
    lines = [
        title,
        "",
        f"| {key_header} | total min | success | failure | cancelled | skipped | jobs |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for key, cell in cells:
        name = _escape(" / ".join(key) if isinstance(key, tuple) else str(key))
        lines.append(
            f"| {name} | {cell.total:.0f} | {cell.minutes.get('success', 0.0):.0f} | "
            f"{cell.minutes.get('failure', 0.0):.0f} | {cell.minutes.get('cancelled', 0.0):.0f} | "
            f"{cell.minutes.get('skipped', 0.0):.0f} | {cell.jobs} |"
        )
    return lines


def render_report(
    current: WindowMetrics,
    previous: WindowMetrics,
    *,
    repo: str,
    now: dt.datetime,
    api_calls: int,
    limit: int = 12,
) -> str:
    """The whole report as markdown; identical in the step summary and the issue."""
    lines: list[str] = []
    lines.append(f"## CI health report — {current.window.label()}")
    lines.append("")
    coverage = (
        f"{current.runs_fetched} runs fetched"
        + (
            f" (page cap reached: only the most recent {current.covered_hours:.1f}h of the "
            f"{current.window.hours:.0f}h window is covered, so run counts below are rates over that span)"
            if current.truncated
            else f" covering the whole {current.window.hours:.0f}h window"
        )
    )
    lines.append(
        f"_{coverage}. Job detail sampled from {current.sampled_runs} runs "
        f"({current.sampled_jobs} jobs). {api_calls} API calls, nothing cached. "
        f"Generated {now.strftime('%Y-%m-%d %H:%M UTC')} for `{repo}`._"
    )
    if current.partial or previous.partial:
        reasons = "; ".join(dict.fromkeys(list(current.partial) + list(previous.partial)))
        lines += ["", f"> **Partial data.** {reasons}. Numbers below cover only what was fetched."]
    lines.append("")

    lines.append("### Headline vs previous window")
    lines.append("")
    lines.append(f"_Previous window: {previous.window.label()} ({previous.runs_fetched} runs fetched)._")
    lines.append("")
    lines.append("| Metric | This window | Previous | Change |")
    lines.append("| --- | ---: | ---: | ---: |")
    for row in compare(current, previous):
        flag = " ⚠️" if row.alerting else ""
        lines.append(f"| {row.metric}{flag} | {row.current} | {row.previous} | {row.change} |")
    lines.append("")

    lines.append("### Run conclusions")
    lines.append("")
    lines.append("| Conclusion | Runs | Share |")
    lines.append("| --- | ---: | ---: |")
    for bucket in BUCKETS:
        count = current.buckets.get(bucket, 0)
        if not count:
            continue
        lines.append(f"| {bucket} | {count} | {share(count, current.runs_fetched) * 100:.1f}% |")
    lines.append("")

    lines += _minutes_table(
        "### Runner minutes by workflow (sampled)",
        top_cells(aggregate_minutes(current.rows, lambda row: row.workflow), limit),
        "Workflow",
    )
    lines.append("")
    lines += _minutes_table(
        "### Runner minutes by job (sampled)",
        top_cells(aggregate_minutes(current.rows, lambda row: (row.workflow, row.job)), limit),
        "Workflow / job",
    )
    lines.append("")
    lines += _minutes_table(
        "### Runner minutes by runner label (sampled)",
        top_cells(aggregate_minutes(current.rows, lambda row: row.label), limit),
        "Runner label",
    )
    lines.append("")

    lines.append("### Queue wait, created → started (sampled)")
    lines.append("")
    if current.queue:
        lines.append("| Runner label | jobs | p50 min | p90 min | p99 min | worst |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        for stat in current.queue[:limit]:
            flag = " ⚠️" if stat.alerting else ""
            lines.append(
                f"| {_escape(stat.label)}{flag} | {stat.jobs} | {stat.p50:.1f} | "
                f"{stat.p90:.1f} | {stat.p99:.1f} | {stat.worst:.1f} |"
            )
        lines.append("")
        lines.append(
            f"_p90 above {QUEUE_P90_ALERT_MINUTES:.0f} min on a macOS label is capacity, not builds: "
            "the jobs are waiting for a runner, not running slowly._"
        )
    else:
        lines.append("_No job timing was sampled in this window._")
    lines.append("")

    lines.append("### Wasteful patterns")
    lines.append("")

    waste = cancelled_macos_waste(current.rows)
    lines.append(f"**Cancelled after ≥{CANCELLED_MACOS_WASTE_MINUTES:.0f} min of macOS work**")
    lines.append("")
    if waste:
        lines.append("| Workflow / job | cancelled jobs | minutes burned | worst |")
        lines.append("| --- | ---: | ---: | ---: |")
        for item in waste[:limit]:
            lines.append(
                f"| {_escape(item.workflow)} / {_escape(item.job)} | {item.runs} | "
                f"{item.minutes:.0f} | {item.worst_minutes:.0f} |"
            )
    else:
        lines.append("_None in the sample._")
    lines.append("")

    repeated = repeated_job_failures(current.rows)
    lines.append(f"**Same job failing across ≥{REPEATED_FAILURE_MIN_HEADS} unrelated heads (main-broken signal)**")
    lines.append("")
    if repeated:
        lines.append("| Workflow / job | distinct heads | failures | branches |")
        lines.append("| --- | ---: | ---: | --- |")
        for item in repeated[:limit]:
            lines.append(
                f"| {_escape(item.workflow)} / {_escape(item.job)} | {item.heads} | "
                f"{item.failures} | {_escape(', '.join(item.branches))} |"
            )
    else:
        lines.append("_None in the sample._")
    lines.append("")

    skipped = mostly_skipped_workflows(current.runs)
    lines.append(
        f"**Workflows ≥{SKIPPED_WORKFLOW_RATIO * 100:.0f}% skipped "
        f"(≥{SKIPPED_WORKFLOW_MIN_RUNS} runs in the window)**"
    )
    lines.append("")
    if skipped:
        lines.append("| Workflow | runs | skipped | share |")
        lines.append("| --- | ---: | ---: | ---: |")
        for item in skipped[:limit]:
            lines.append(
                f"| {_escape(item.workflow)} | {item.runs} | {item.skipped} | {item.ratio * 100:.1f}% |"
            )
    else:
        lines.append("_None in the window._")
    lines.append("")

    reruns = unchanged_tree_reruns(current.runs)
    extra = sum(item.runs - 1 + item.retries for item in reruns)
    lines.append("**Reruns of an unchanged tree**")
    lines.append("")
    if reruns:
        lines.append(
            f"{extra} run(s) beyond the first for a head that did not change, across "
            f"{len(reruns)} workflow/head pairs."
        )
        lines.append("")
        lines.append("| Workflow | head | runs | re-run attempts | branch |")
        lines.append("| --- | --- | ---: | ---: | --- |")
        for item in reruns[:limit]:
            lines.append(
                f"| {_escape(item.workflow)} | `{item.head_sha[:8]}` | {item.runs} | "
                f"{item.retries} | {_escape(item.branch)} |"
            )
    else:
        lines.append("_None in the window._")
    lines.append("")

    fork_jobs, fork_minutes = fork_runs_without_cache(current.rows)
    lines.append(
        f"**Fork pull requests (no cache access):** {fork_jobs} sampled job(s), "
        f"{fork_minutes:.0f} runner minutes."
    )
    lines.append("")
    lines.append(
        "_This report only measures. Cancelling wasted demand is the queue janitor's job "
        "(`scripts/ci/queue_janitor.py`). Thresholds and what to do when one trips: "
        "`docs/ci/health-report.md`._"
    )
    return "\n".join(lines) + "\n"


def replace_generated(body: str, generated: str) -> str:
    """Swap the generated section, leaving any human text around it alone."""
    if body.count(START_MARKER) != 1 or body.count(END_MARKER) != 1:
        raise ValueError("comment must contain exactly one start and one end marker")
    start = body.index(START_MARKER) + len(START_MARKER)
    end = body.index(END_MARKER, start)
    if end < start:
        raise ValueError("markers are out of order")
    return body[:start] + "\n" + generated.strip() + "\n" + body[end:]


def new_comment_body(generated: str) -> str:
    return (
        "This comment is refreshed in place by the CI health report workflow. "
        "Notes added above or below the markers are preserved.\n\n"
        f"{START_MARKER}\n{generated.strip()}\n{END_MARKER}\n"
    )


def find_report_comment(comments: Iterable[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    for comment in comments:
        body = str(comment.get("body") or "")
        if START_MARKER in body and END_MARKER in body:
            return comment
    return None


# ---------------------------------------------------------------------------
# GitHub I/O
# ---------------------------------------------------------------------------


class RateLimited(RuntimeError):
    """The API refused more reads; the caller reports what it already has."""


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.calls = 0
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-health-report",
        }

    def request(self, method: str, path: str, body: Any | None = None) -> Any:
        self.calls += 1
        data = json.dumps(body).encode() if body is not None else None
        headers = dict(self.headers)
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(API + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            endpoint = path.split("?")[0]
            remaining = error.headers.get("x-ratelimit-remaining") if error.headers else None
            if error.code in (403, 429) and (remaining == "0" or error.headers is None
                                             or error.headers.get("retry-after")):
                raise RateLimited(f"rate limited on {endpoint} ({error.code})") from error
            raise RuntimeError(f"{method} {endpoint} failed ({error.code})") from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.reason})") from error

    def runs_in_window(self, window: Window, max_pages: int) -> tuple[list[dict[str, Any]], list[str]]:
        runs: dict[int, dict[str, Any]] = {}
        partial: list[str] = []
        for page in range(1, max_pages + 1):
            query = urllib.parse.urlencode(
                {"created": window.query(), "per_page": RUNS_PER_PAGE, "page": page}
            )
            try:
                payload = self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")
            except (RateLimited, RuntimeError) as error:
                partial.append(f"run listing stopped after page {page - 1}: {error}")
                break
            batch = payload.get("workflow_runs") or []
            for run in batch:
                runs[run["id"]] = run
            if len(batch) < RUNS_PER_PAGE:
                break
        else:
            partial.append(f"run listing hit the {max_pages}-page cap")
        return list(runs.values()), partial

    def jobs(self, run_id: int) -> list[dict[str, Any]]:
        jobs: list[dict[str, Any]] = []
        for page in range(1, MAX_JOB_PAGES + 1):
            query = urllib.parse.urlencode({"filter": "latest", "per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/actions/runs/{run_id}/jobs?{query}")
            batch = payload.get("jobs") or []
            jobs.extend(batch)
            if len(batch) < 100:
                break
        return jobs

    def issue(self, number: int) -> dict[str, Any]:
        return self.request("GET", f"/repos/{self.repo}/issues/{number}")

    def issue_comments(self, number: int) -> list[dict[str, Any]]:
        comments: list[dict[str, Any]] = []
        for page in range(1, MAX_COMMENT_PAGES + 1):
            query = urllib.parse.urlencode({"per_page": 100, "page": page})
            batch = self.request("GET", f"/repos/{self.repo}/issues/{number}/comments?{query}")
            if not isinstance(batch, list):
                break
            comments.extend(batch)
            if len(batch) < 100:
                break
        return comments

    def update_comment(self, comment_id: int, body: str) -> None:
        self.request("PATCH", f"/repos/{self.repo}/issues/comments/{comment_id}", {"body": body})

    def create_comment(self, number: int, body: str) -> None:
        self.request("POST", f"/repos/{self.repo}/issues/{number}/comments", {"body": body})


def collect_window(
    github: GitHub,
    window: Window,
    *,
    repo: str,
    max_run_pages: int,
    max_job_listings: int,
    jobs_per_workflow: int,
    linux_only: frozenset[str],
) -> WindowMetrics:
    runs, partial = github.runs_in_window(window, max_run_pages)
    runs.sort(key=lambda run: str(run.get("created_at") or ""), reverse=True)
    chosen = choose_job_runs(
        runs,
        per_workflow=jobs_per_workflow,
        total_cap=max_job_listings,
        linux_only_paths=linux_only,
    )
    rows: list[JobRow] = []
    sampled = 0
    for run in chosen:
        try:
            jobs = github.jobs(int(run["id"]))
        except (RateLimited, RuntimeError) as error:
            partial.append(f"job sampling stopped after {sampled} runs: {error}")
            break
        sampled += 1
        rows.extend(job_rows(run, jobs, repo))
    return build_metrics(window=window, runs=runs, rows=rows, sampled_runs=sampled, partial=partial)


def publish_to_issue(github: GitHub, number: int, generated: str) -> str:
    """Refresh the report comment on the tracking issue; never open an issue."""
    issue = github.issue(number)
    title = str(issue.get("title") or "")
    if not title.startswith(REPORT_TITLE_PREFIX):
        raise RuntimeError(
            f"issue #{number} is titled {title!r}; the tracking issue must start with "
            f"{REPORT_TITLE_PREFIX!r}. Create it by hand and set the repo variable to it."
        )
    existing = find_report_comment(github.issue_comments(number))
    if existing is None:
        github.create_comment(number, new_comment_body(generated))
        return f"posted a new report comment on #{number}"
    body = replace_generated(str(existing.get("body") or ""), generated)
    if body == existing.get("body"):
        return f"report comment on #{number} already current"
    github.update_comment(int(existing["id"]), body)
    return f"updated report comment {existing['id']} on #{number}"


def env_int(name: str, default: int) -> int:
    raw = (os.environ.get(name) or "").strip()
    return int(raw) if raw else default


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--window-hours", type=int, default=None)
    parser.add_argument("--max-run-pages", type=int, default=None)
    parser.add_argument("--max-job-listings", type=int, default=None)
    parser.add_argument("--jobs-per-workflow", type=int, default=None)
    parser.add_argument("--issue", default=os.environ.get("CI_HEALTH_REPORT_ISSUE", ""))
    parser.add_argument("--no-issue", action="store_true", help="render only; never touch the issue")
    parser.add_argument(
        "--workflows-dir",
        type=Path,
        default=Path(__file__).resolve().parents[2] / ".github" / "workflows",
    )
    parser.add_argument(
        "--summary",
        type=Path,
        default=(Path(os.environ["GITHUB_STEP_SUMMARY"]) if os.environ.get("GITHUB_STEP_SUMMARY") else None),
    )
    args = parser.parse_args(argv)

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token or not args.repo:
        print("ci-health-report: GH_TOKEN and GH_REPO are required", file=sys.stderr)
        return 2
    try:
        window_hours = args.window_hours if args.window_hours is not None else env_int("WINDOW_HOURS", DEFAULT_WINDOW_HOURS)
        max_run_pages = args.max_run_pages if args.max_run_pages is not None else env_int("MAX_RUN_PAGES", DEFAULT_MAX_RUN_PAGES)
        max_job_listings = args.max_job_listings if args.max_job_listings is not None else env_int("MAX_JOB_LISTINGS", DEFAULT_MAX_JOB_LISTINGS)
        jobs_per_workflow = args.jobs_per_workflow if args.jobs_per_workflow is not None else env_int("JOBS_PER_WORKFLOW", DEFAULT_JOBS_PER_WORKFLOW)
    except ValueError:
        print("ci-health-report: window and cap settings must be integers", file=sys.stderr)
        return 2
    if window_hours < 1 or not 1 <= max_run_pages <= 100 or not 0 <= max_job_listings <= 400:
        print("ci-health-report: window must be >= 1h, run pages 1..100, job listings 0..400", file=sys.stderr)
        return 2
    if jobs_per_workflow < 1:
        print("ci-health-report: jobs per workflow must be >= 1", file=sys.stderr)
        return 2

    github = GitHub(token, args.repo)
    now = dt.datetime.now(UTC)
    current_window, previous_window = windows(now, window_hours)
    linux_only = linux_only_workflow_paths(args.workflows_dir)

    current = collect_window(
        github, current_window, repo=args.repo, max_run_pages=max_run_pages,
        max_job_listings=max_job_listings, jobs_per_workflow=jobs_per_workflow, linux_only=linux_only,
    )
    # The previous window only has to carry the headline comparison, so it gets
    # a smaller share of the call budget.
    previous = collect_window(
        github, previous_window, repo=args.repo, max_run_pages=max_run_pages,
        max_job_listings=max(5, max_job_listings // 3), jobs_per_workflow=1, linux_only=linux_only,
    )

    report = render_report(current, previous, repo=args.repo, now=now, api_calls=github.calls)
    print(report)
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as handle:
            handle.write(report)

    issue_raw = (args.issue or "").strip()
    if args.no_issue or not issue_raw:
        print("ci-health-report: no tracking issue configured; step summary only", file=sys.stderr)
        return 0
    try:
        issue_number = int(issue_raw)
    except ValueError:
        print(f"ci-health-report: tracking issue {issue_raw!r} is not a number", file=sys.stderr)
        return 2
    try:
        print(f"ci-health-report: {publish_to_issue(github, issue_number, report)}", file=sys.stderr)
    except RateLimited as error:
        print(f"ci-health-report: {error}; step summary still has the report", file=sys.stderr)
        return 0
    except (RuntimeError, ValueError) as error:
        print(f"ci-health-report: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
