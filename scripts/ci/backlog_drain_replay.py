#!/usr/bin/env python3
"""Measure how a post-outage Actions backlog drained, and replay it under the cron/supersede/trivial policy.

Input: a snapshot of the controller's webhook feed for one repository, shaped
{generated_at, runs: [{id, status, created_at, updated_at, path, event, head_sha, head_branch,
pr_heads, ...}], jobs: [{run_id, status, created_at, started_at, labels, runner, received_at, ...}]}.
Read it from the controller with
  curl -s 'http://<controller>/v1/github/actions?repo=manaflow-ai/cmux&recent=0&since=<seq>' > feed.json

Before (measured). A run waits from created_at until its first job takes a runner (started_at of a
job with a runner). The feed keeps jobs only from `jobs_from` (the oldest job received_at); a run
that finished or started before that has no job rows, and its updated_at stands in for its start, an
upper bound. A run still `queued` with no job taken by the snapshot never started. Queue depth is
the number of runs waiting at each instant; the pre-outage depth is the largest depth in the
--pre window. The backlog has drained at the first instant after --resume when the depth is back at
or below it. Runs created before --stale-before that still say queued are stale feed entries and
are dropped.

After (replay). The same arrivals (every run created from --stall-start to the snapshot), served
from --resume onward at each pool's measured start throughput: the most run starts the pool (the
first job's runner label) took in any --bucket-minute window while the feed had job rows. A run
with no job rows takes its workflow's usual pool. Each pool serves its queue in order of creation.
The policy:
  * cron and maintenance runs (schedule or workflow_run events of the workflows
    scripts/ci/cron_concurrency.py lets share a group) collapse to one waiting run per workflow
    and branch: a newer arrival replaces the waiting one, as GitHub's concurrency does;
  * a pull request run still waiting when a newer run of the same workflow arrives for the same
    pull request at another head is dropped (cancel-in-progress, or the janitor's superseded pass);
  * trivial checks (cron_concurrency.trivial_checks() plus --extra-trivial) are served first.
The baseline replay serves the same arrivals with none of that, so the two replays differ only in
policy. Every run is assumed to need one start on one pool; runs never served in reality (lost by
GitHub) are served in both replays as if they were real demand.

  python3 scripts/ci/backlog_drain_replay.py FEED.json [--json]
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import heapq
import json
import math
import sys
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

PR_EVENTS = frozenset({"pull_request", "pull_request_target"})
CRON_EVENTS = frozenset({"schedule", "workflow_run"})
# Short Linux PR checks that live only on feat-cmux-next (pull request runs follow the base's copy), found by
# the same rule as cron_concurrency.is_trivial() on that branch's files.
DEFAULT_EXTRA_TRIVIAL = ("pr-body-checks.yml",)


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def clock(value: dt.datetime | None) -> str:
    return value.strftime("%H:%MZ") if value else "-"


def minutes(delta: dt.timedelta) -> float:
    return delta.total_seconds() / 60


@dataclass
class Run:
    id: int
    workflow: str
    event: str
    branch: str
    sha: str
    created: dt.datetime
    start: dt.datetime | None
    approx: bool
    pool: str | None
    prs: tuple[int, ...]
    trivial: bool = False
    collapsible: bool = False


@dataclass
class Feed:
    generated: dt.datetime
    jobs_from: dt.datetime
    runs: list[Run]
    starts_by_pool: dict[str, list[dt.datetime]] = field(default_factory=dict)


def load_feed(data: Mapping, *, stale_before: dt.datetime) -> Feed:
    generated = parse_time(data.get("generated_at")) or dt.datetime.now(dt.timezone.utc)
    jobs_by_run: dict[int, list[Mapping]] = collections.defaultdict(list)
    received = []
    for job in data.get("jobs") or ():
        jobs_by_run[int(job["run_id"])].append(job)
        if job.get("received_at"):
            received.append(parse_time(job["received_at"]))
    jobs_from = min(received) if received else generated
    runs: list[Run] = []
    for raw in data.get("runs") or ():
        created = parse_time(raw.get("created_at"))
        if created is None or created < stale_before:
            continue
        taken = sorted(((parse_time(j["started_at"]), j) for j in jobs_by_run.get(int(raw["id"]), ())
                        if j.get("runner") and j.get("started_at")), key=lambda item: item[0])
        start, approx, pool = None, False, None
        if taken:
            start, first = taken[0]
            pool = ",".join(first.get("labels") or ()) or None
        elif raw.get("status") in ("completed", "in_progress"):
            start, approx = parse_time(raw.get("updated_at")), True
        if start is not None and start < created:
            start = created
        prs = tuple(int(p["number"]) for p in raw.get("pr_heads") or () if p.get("number") is not None)
        runs.append(Run(int(raw["id"]), str(raw.get("path") or "").rsplit("/", 1)[-1], str(raw.get("event") or ""),
                        str(raw.get("head_branch") or ""), str(raw.get("head_sha") or ""), created, start, approx,
                        pool, prs))
    feed = Feed(generated, jobs_from, runs)
    for run in runs:
        if run.pool and run.start and not run.approx:
            feed.starts_by_pool.setdefault(run.pool, []).append(run.start)
    # A run with no job rows takes its workflow's usual pool, else the busiest pool.
    usual: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for run in runs:
        if run.pool:
            usual[run.workflow][run.pool] += 1
    busiest = max(feed.starts_by_pool, key=lambda p: len(feed.starts_by_pool[p]), default="unknown")
    for run in runs:
        if run.pool is None:
            run.pool = usual[run.workflow].most_common(1)[0][0] if usual[run.workflow] else busiest
    return feed


def classify(runs: Iterable[Run], trivial: set[str]) -> None:
    import cron_concurrency as cc

    for run in runs:
        run.trivial = run.workflow in trivial
        run.collapsible = cc.collapsible_run(run.workflow, run.event)


def trivial_set(extra_trivial: Sequence[str]) -> set[str]:
    """The trivial pull request check files (cron_concurrency.trivial_checks()) plus `extra_trivial`."""
    import cron_concurrency as cc

    return set(cc.trivial_checks(cc.workflows(ROOT))) | set(extra_trivial)


# --- measured service, minus what the policy removes -----------------------------------------------------------

def removals(runs: Sequence[Run], *, resume: dt.datetime, generated: dt.datetime, sweep_minutes: int,
             age: dt.timedelta, cap: int) -> dict[int, tuple[dt.datetime, str]]:
    """When the policy takes a waiting run out of the queue, for runs that were still waiting then.

    * A cron or maintenance run that did start is replaced the moment a newer run of its workflow and branch
      arrives (the shared concurrency group), if it had not started by then. A run GitHub never started is
      not: the queue janitor's own group was shared and still kept 18 such runs, so only the pass below
      takes those out.
    * A run GitHub never started (status queued, no job) is cancelled by the queue janitor's superseded pass:
      at the first sweep (every `sweep_minutes` from `resume`) at least `age` after its creation, once a newer
      cron run of its workflow exists, or, for a pull request run, once a run at another head of its pull
      request exists; at most `cap` a sweep, oldest first. One at its pull request's newest head stays.
    """
    removed: dict[int, tuple[dt.datetime, str]] = {}
    by_key: dict[tuple[str, str], list[Run]] = collections.defaultdict(list)
    for run in sorted(runs, key=lambda r: (r.created, r.id)):
        if run.collapsible:
            by_key[(run.workflow, run.branch)].append(run)
    for chain in by_key.values():
        for older, newer in zip(chain, chain[1:]):
            if older.start is not None and older.start > newer.created:
                removed[older.id] = (newer.created, "cron collapsed")
    # A pull request's head moved at the first run created at another sha for it.
    moved: dict[tuple[int, str], dt.datetime] = {}
    heads: dict[int, list[tuple[dt.datetime, str]]] = collections.defaultdict(list)
    for run in runs:
        for pr in run.prs:
            heads[pr].append((run.created, run.sha))
    for pr, seen in heads.items():
        seen.sort()
        for sha in {sha for _, sha in seen}:
            later = [t for t, other in seen if other != sha and t > min(t2 for t2, s2 in seen if s2 == sha)]
            if later:
                moved[(pr, sha)] = min(later)
    ghosts = []
    for run in runs:
        if run.start is not None or run.id in removed:
            continue
        if run.collapsible:
            chain = by_key[(run.workflow, run.branch)]
            newer = [r.created for r in chain if r.created > run.created]
            if newer:
                ghosts.append((max(run.created + age, min(newer)), run, "stuck cron superseded"))
        elif run.event in PR_EVENTS and run.prs:
            when = [moved[(pr, run.sha)] for pr in run.prs if (pr, run.sha) in moved]
            if when:
                ghosts.append((max(run.created + age, min(when)), run, "stuck PR run superseded"))
    ghosts.sort(key=lambda item: (item[0], item[1].created))
    sweep = resume
    queue: list[tuple[dt.datetime, Run, str]] = []
    index = 0
    while sweep <= generated + dt.timedelta(hours=6) and (index < len(ghosts) or queue):
        while index < len(ghosts) and ghosts[index][0] <= sweep:
            queue.append(ghosts[index])
            index += 1
        queue.sort(key=lambda item: item[1].created)
        for _, run, why in queue[:cap]:
            removed[run.id] = (sweep, why)
        queue = queue[cap:]
        sweep += dt.timedelta(minutes=sweep_minutes)
    return removed


def measured_with_policy(feed: Feed, args, pre_depth: int) -> dict:
    removed = removals(feed.runs, resume=args.resume, generated=feed.generated, sweep_minutes=args.sweep_minutes,
                       age=dt.timedelta(minutes=args.ghost_minutes), cap=args.ghost_cap)
    curve = []
    at = args.pre_start
    while at <= feed.generated:
        waiting = sum(1 for r in feed.runs if r.created <= at and (r.start is None or r.start > at)
                      and not (r.id in removed and removed[r.id][0] <= at))
        curve.append((at, waiting))
        at += dt.timedelta(minutes=args.step)
    drained = next((t for t, d in curve if t >= args.resume and d <= pre_depth), None)
    stuck = [r for r in feed.runs if r.start is None and r.id not in removed and r.created <= args.recovered]
    stuck_trivial_at_head = sum(1 for r in stuck if r.trivial and r.created >= args.stall_start)
    left = collections.Counter("trivial PR check" if r.trivial else r.event for r in stuck)
    return {"curve": curve, "drained": drained, "removed": dict(collections.Counter(w for _, w in removed.values())),
            "stuck_trivial_at_head": stuck_trivial_at_head, "never_started_left": dict(left.most_common())}


# --- measured ------------------------------------------------------------------------------------------------------

def depth_at(runs: Sequence[Run], at: dt.datetime) -> tuple[int, int]:
    """(runs waiting at `at`, of which never started by the snapshot)."""
    waiting = never = 0
    for run in runs:
        if run.created <= at and (run.start is None or run.start > at):
            waiting += 1
            never += run.start is None
    return waiting, never


def percentile(values: Sequence[float], q: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return math.nan
    return ordered[min(len(ordered) - 1, max(0, math.ceil(q * len(ordered)) - 1))]


def wait_stats(waits: Sequence[float]) -> dict:
    """p50/p95 in minutes; a run never served counts as infinitely long."""
    return {"runs": len(waits), "never": sum(1 for w in waits if math.isinf(w)),
            "p50": percentile(waits, 0.50), "p95": percentile(waits, 0.95)}


def measured(feed: Feed, args) -> dict:
    curve = []
    at = args.pre_start
    while at <= feed.generated:
        curve.append((at, *depth_at(feed.runs, at)))
        at += dt.timedelta(minutes=args.step)
    pre = max(d for t, d, _ in curve if args.pre_start <= t <= args.pre_end)
    drained = next((t for t, d, _ in curve if t >= args.resume and d <= pre), None)
    real_drained = next((t for t, d, n in curve if t >= args.resume and d - n <= pre), None)
    window = [r for r in feed.runs if args.stall_start <= r.created <= args.recovered and r.trivial]
    waits = [minutes(r.start - r.created) if r.start else math.inf for r in window]
    return {"pre_depth": pre, "curve": curve, "drained": drained, "real_drained": real_drained,
            "trivial": wait_stats(waits),
            "trivial_started_only": wait_stats([w for w in waits if not math.isinf(w)]),
            "never_started": sum(1 for r in feed.runs if r.start is None and r.created <= args.recovered),
            "approx_starts": sum(1 for r in feed.runs if r.approx and r.created >= args.stall_start)}


# --- replay --------------------------------------------------------------------------------------------------------

def pool_rates(feed: Feed, bucket_minutes: int) -> dict[str, float]:
    """Run starts per minute: the busiest --bucket-minute window each pool had while jobs were recorded."""
    rates = {}
    for pool, starts in feed.starts_by_pool.items():
        buckets = collections.Counter(int((s - feed.jobs_from).total_seconds() // (bucket_minutes * 60))
                                      for s in starts if s >= feed.jobs_from)
        rates[pool] = max(buckets.values(), default=0) / bucket_minutes
    return rates


def replay(runs: Sequence[Run], rates: Mapping[str, float], *, resume: dt.datetime, policy: bool,
           pre_depth: int, window: tuple[dt.datetime, dt.datetime]) -> dict:
    """Serve arrivals per pool at its rate from `resume`.

    Returns the instant the waiting count is back at `pre_depth` (the drain), the instant the last
    arrival is served, what the policy dropped, and the trivial checks' waits for runs created in
    `window` (the outage), the same set the measured numbers use."""
    arrivals = sorted(runs, key=lambda r: (r.created, r.id))
    floor_rate = min((r for r in rates.values() if r > 0), default=1.0)
    queues: dict[str, list] = collections.defaultdict(list)
    pending: dict[int, Run] = {}
    waiting_cron: dict[tuple[str, str], int] = {}
    waiting_pr: dict[tuple[str, int | str], list[int]] = collections.defaultdict(list)
    dropped = collections.Counter()
    served: dict[int, dt.datetime] = {}
    credit: dict[str, float] = collections.defaultdict(float)
    index = 0
    now = min(arrivals[0].created, resume) if arrivals else resume
    step = dt.timedelta(seconds=10)
    last = now
    drained = None

    def drop(run_id: int, why: str) -> None:
        if run_id in pending:
            del pending[run_id]
            dropped[why] += 1

    while index < len(arrivals) or pending:
        while index < len(arrivals) and arrivals[index].created <= now:
            run = arrivals[index]
            index += 1
            if policy and run.collapsible:
                key = (run.workflow, run.branch)
                if key in waiting_cron:
                    drop(waiting_cron[key], "cron collapsed")
                waiting_cron[key] = run.id
            if policy and run.event in PR_EVENTS:
                for pr in run.prs or (run.branch,):
                    for other in waiting_pr[(run.workflow, pr)]:
                        other_run = pending.get(other)
                        if other_run is not None and other_run.sha != run.sha:
                            drop(other, "superseded head")
                    waiting_pr[(run.workflow, pr)].append(run.id)
            pending[run.id] = run
            heapq.heappush(queues[run.pool], (0 if policy and run.trivial else 1, run.created, run.id))
        if now >= resume:
            for pool, queue in queues.items():
                credit[pool] += max(rates.get(pool, 0.0), floor_rate) * step.total_seconds() / 60
                while queue and credit[pool] >= 1:
                    _, _, run_id = heapq.heappop(queue)
                    if run_id not in pending:
                        continue
                    run = pending.pop(run_id)
                    served[run_id] = now
                    credit[pool] -= 1
                    last = now
                if not queue:
                    credit[pool] = min(credit[pool], 1.0)
            if drained is None and len(pending) <= pre_depth:
                drained = now
        now += step
    by_id = {r.id: r for r in runs}
    waits = [minutes(served[i] - by_id[i].created) for i in served
             if by_id[i].trivial and window[0] <= by_id[i].created <= window[1]]
    return {"drained": drained, "last_served": last, "served": len(served), "dropped": dict(dropped),
            "trivial": wait_stats(waits)}


# --- report --------------------------------------------------------------------------------------------------------

def fmt_wait(stats: Mapping) -> str:
    def one(value: float) -> str:
        return "never" if math.isinf(value) else ("-" if math.isnan(value) else f"{value:.1f} min")
    return f"p50 {one(stats['p50'])}, p95 {one(stats['p95'])} (n={stats['runs']}, never served {stats['never']})"


def main(argv: list[str] | None = None) -> int:
    utc = dt.timezone.utc
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("feed", type=Path)
    parser.add_argument("--stall-start", type=parse_time, default=dt.datetime(2026, 11, 11, 20, 17, tzinfo=utc))
    parser.add_argument("--resume", type=parse_time, default=dt.datetime(2026, 11, 11, 20, 49, tzinfo=utc))
    parser.add_argument("--recovered", type=parse_time, default=dt.datetime(2026, 11, 11, 21, 38, tzinfo=utc))
    parser.add_argument("--pre-start", type=parse_time, default=dt.datetime(2026, 11, 11, 19, 30, tzinfo=utc))
    parser.add_argument("--pre-end", type=parse_time, default=dt.datetime(2026, 11, 11, 20, 15, tzinfo=utc))
    parser.add_argument("--stale-before", type=parse_time, default=dt.datetime(2026, 11, 10, tzinfo=utc))
    parser.add_argument("--step", type=int, default=10, help="minutes between depth readings")
    parser.add_argument("--bucket-minutes", type=int, default=5)
    parser.add_argument("--extra-trivial", nargs="*", default=list(DEFAULT_EXTRA_TRIVIAL))
    parser.add_argument("--sweep-minutes", type=int, default=10, help="queue janitor cron interval")
    parser.add_argument("--ghost-minutes", type=int, default=30, help="queue_janitor.SUPERSEDED_QUEUED_AGE")
    parser.add_argument("--ghost-cap", type=int, default=30, help="queue_janitor.SUPERSEDED_QUEUED_MAX_CANCELS")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    feed = load_feed(json.loads(args.feed.read_text(encoding="utf-8")), stale_before=args.stale_before)
    classify(feed.runs, trivial_set(args.extra_trivial))
    before = measured(feed, args)
    cleaned = measured_with_policy(feed, args, before["pre_depth"])
    rates = pool_rates(feed, args.bucket_minutes)
    arrivals = [r for r in feed.runs if r.created >= args.stall_start]
    window = (args.stall_start, args.recovered)
    base = replay(arrivals, rates, resume=args.resume, policy=False, pre_depth=before["pre_depth"], window=window)
    after = replay(arrivals, rates, resume=args.resume, policy=True, pre_depth=before["pre_depth"], window=window)

    if args.json:
        print(json.dumps({"before": {k: v for k, v in before.items() if k != "curve"},
                          "measured_with_policy": {k: v for k, v in cleaned.items() if k != "curve"},
                          "baseline": base,
                          "after": after, "rates": rates}, default=str, indent=2))
        return 0
    print(f"feed at {feed.generated:%Y-%m-%dT%H:%MZ}; job rows from {clock(feed.jobs_from)}; "
          f"{len(feed.runs)} runs since {args.stale_before:%Y-%m-%d}, {len(arrivals)} arrivals since "
          f"{clock(args.stall_start)}")
    print(f"pre-outage depth (max {clock(args.pre_start)}-{clock(args.pre_end)}): {before['pre_depth']}")
    print("depth curve (waiting / of which never started by the snapshot / waiting with the policy's removals):")
    for (at, waiting, never), (_, kept) in zip(before["curve"], cleaned["curve"]):
        print(f"  {clock(at)} {waiting:5d} / {never:4d} / {kept:5d}")
    drained = before["drained"]
    print("measured drain:", f"{minutes(drained - args.resume):.0f} min after {clock(args.resume)}" if drained
          else f"NOT drained by {clock(feed.generated)}: {before['never_started']} runs created by "
               f"{clock(args.recovered)} never started")
    real = before["real_drained"]
    print("measured drain of runs that did start:",
          f"{clock(real)} ({minutes(real - args.resume):.0f} min after {clock(args.resume)})" if real else "not drained")
    print(f"measured trivial-check wait (created {clock(args.stall_start)}-{clock(args.recovered)}): "
          f"{fmt_wait(before['trivial'])}; started ones only: {fmt_wait(before['trivial_started_only'])}")
    print(f"  ({before['approx_starts']} runs have no job rows; their finish time stands in for their start)")
    for name, result in (("baseline replay", base), ("policy replay", after)):
        drain = result["drained"]
        print(f"{name}: back to depth {before['pre_depth']} at {clock(drain)} "
              f"({minutes(drain - args.resume):.0f} min after {clock(args.resume)}), " if drain else
              f"{name}: never back to depth {before['pre_depth']}, ", end="")
        print(f"{result['served']} served, dropped {result['dropped'] or 'none'}; "
              f"trivial {fmt_wait(result['trivial'])}")
    drain = cleaned["drained"]
    print("measured service with the policy's removals: "
          + (f"back to depth {before['pre_depth']} at {clock(drain)} ({minutes(drain - args.resume):.0f} min after "
             f"{clock(args.resume)})" if drain else f"not back to depth {before['pre_depth']} by {clock(feed.generated)}")
          + f"; removed {cleaned['removed']}; never-started runs left, by kind: {cleaned['never_started_left']}")
    top = sorted(rates.items(), key=lambda kv: -kv[1])[:8]
    print("pool start rates (runs/min):", ", ".join(f"{p} {r:.1f}" for p, r in top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
