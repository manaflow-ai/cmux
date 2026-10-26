#!/usr/bin/env python3
"""cmux-next's macOS cascade: idle minis, Blacksmith 12 vCPU, 6 vCPU, hosted macos-26, then the minis' queue.

side_lane_placement.py gives an idle owned side runner to each job it can and
leaves the rest queued on the owned label. Until this cascade, a busy fleet
meant every remaining job waited there for the rescue's ten-minute budget, and
the bot's attempt 3 then sent the compile jobs to vars.MACOS_RUNNER_26
(Blacksmith 12 vCPU) and the session jobs to Blacksmith 6 vCPU, however full
either was. From 14:00Z to 21:15Z on 2026-10-19, 533 cmux-next and ci.yml jobs
asked for blacksmith-12vcpu-macos-26; the ones that got a runner waited a
median 40 minutes (p90 68). The label never ran more than six at once (five in
11 of the 20 five-minute samples it had a queue), the "about 5" Blacksmith
gives us. Meanwhile the minis' side label queued at p90 29 minutes.

The cascade places the jobs that idle minis did not take, in the placement's
priority order, while each Blacksmith label has a free slot now:
blacksmith-12vcpu-macos-26 (CAPACITY 5) first, then blacksmith-6vcpu-macos-26
(CAPACITY 10), at most MAX_PER_RUN on each label. The rest stay queued on the
owned label as before, where the rescue still watches them.

Only CASCADE_JOBS take part, and only those the workflow says run on this route
(CASCADE_RUNS: not fast-tier while an idle vars.CI_FAST_LANE_RUNNER runner takes
it, not a job path routing or labels skip), so no slot is spent on a job
that never asks for it. The jobs that need a logged-in session (swift-test,
daemon-test, generated-files) keep the gui route. release-compile cascades too
(2026-10-21 ~20:10Z: 76 Release compiles queued on the minis); off a mini it
skips the CEF shim compile, which is advisory and already skipped by a
Blacksmith re-run. On attempt 1 of a feat-cmux-next push it compiles on the
reserved promotion mini (PROMOTE_LABEL, vars.CI_NEXT_PROMOTE_POOL): while a
runner there is idle it stays there and takes no slot, and with none idle it
takes a Blacksmith slot ahead of the other jobs, since it gates the nightly-next
request. It never counts against an idle side mini then: it does not run there.

A slot counted free can still be taken by another run placing in the same
snapshot window, and nothing rescues a job queued on Blacksmith. MAX_PER_RUN
bounds how far a burst of runs can overfill a label.

A free slot is CAPACITY less the jobs in flight and the jobs already queued:
- In flight comes live from the organization's runner groups. Blacksmith
  registers each label's just-in-time runners in its own scale-set group
  ("Blacksmith scale sets - <label>"); a runner online there holds a job or is
  about to take one. That is one request for the group list and one per label.
- Queued comes from the queue janitor's pool snapshot (macos-pool-load), the
  only repository-wide job listing, read with the job's GITHUB_TOKEN. It counts
  only while it is at most QUEUE_SNAPSHOT_MINUTES old: a job sent to a label with
  a backlog would wait behind it, so without a fresh count nothing cascades.
Anything unread places nothing, which is today's route.

A stalled label gets no job, whatever its free slots say (stalled()). On
2026-10-20 Blacksmith's macOS starts stopped (status.blacksmith.sh, "Delayed job
starts on macOS runners"): with no runner online the slots all counted free,
so every run's cascade kept sending jobs to labels where none started, about
80 by 10:50Z. The janitor's snapshot (the same read as the queued counts)
records each label's oldest queued job; by now it has waited that long plus
the snapshot's age. A label is stalled when that wait is STALL_MINUTES or
more, or when the snapshot itself saw it wait IDLE_STALL_MINUTES or more and
the label has no runner online now (age is not added there: an idle scale set
has no runner online, and a job queued at snapshot time may since have run):
a moving Blacksmith label starts a job in a few minutes (6 vCPU: median 2.6
min, p90 14.7, 2026-10-20 01:04Z to 02:35Z).

Then hosted macos-26 takes the overflow (Leo: GitHub-hosted macOS is free on
this public repository and must not sit idle while Blacksmith queues). The
jobs Blacksmith did not take, in HOSTED_JOBS, go to `macos-26` while it has
room: HOSTED_CAPACITY, the organization's hosted macOS concurrency, less this
repository's hosted macOS jobs in the snapshot, at most MAX_PER_RUN a run.
Nothing measures hosted health: an outage there queues at most that many
jobs, and a hosted job that fails falls back only on the bot's attempt 3
(retry_runner); the rescue does not watch hosted jobs. A hosted job gets a
45 min timeout instead of 20, since it builds cold. The
rest stay on the minis' queue as before. HOSTED_JOBS are the jobs whose pins
the hosted image meets: they pin no Xcode path (select-ci-xcode.sh takes
xcode-pins.txt's 26.6, the image default, build 17F113 as on Blacksmith),
their R2 cache keys carry the workspace path (a hosted /Users/runner/work
build never restores a Blacksmith one), and they use no Blacksmith-only
action. The scheme compile stays off hosted: a cold app compile, web bundles
and launch-time budget on about 3 vCPU are unmeasured against its 60 min
budget. Without the snapshot's waits nothing is stalled and nothing goes to
hosted, which is the previous route.

`retry_runner` is the Blacksmith label the bot's overflow attempt (2 or
later: the rescue's re-runs) takes for these jobs: among moving (not stalled)
labels with a free slot, the lowest (in flight + queued) / capacity, the
larger label on a tie (retry_label). With no free, moving slot it is empty, and the job takes the
owned side label: waiting behind the fleet is acceptable, waiting in a
Blacksmith queue is not (Leo, 2026-10-20: 5+ hour waits on 12 vCPU, about 95
PRs behind 318 queued runs). It is written as `free_retry_runner`, a key a
placement script that predates the rule never writes, so a pull request still
running the old script from its base gets the owned fallback instead of a full
label. It is computed with the same reads, at attempt 1, as classic's picker
computes its retry_runner.
"""
from __future__ import annotations

import dataclasses
import datetime as dt
import json
import time
import urllib.parse
import urllib.request
from typing import Any, Callable, Mapping, Sequence

LARGE = "blacksmith-12vcpu-macos-26"
SMALL = "blacksmith-6vcpu-macos-26"
LABELS = (LARGE, SMALL)
# GitHub-hosted macOS 26 (Xcode 26.6 default): free here, capped by the organization's concurrency.
HOSTED = "macos-26"
HOSTED_CAPACITY = 5
HOSTED_JOBS = ("fast-tier", "swift-canary")
STALL_MINUTES = 25
IDLE_STALL_MINUTES = 5
# simple_pool_picker.CAPACITY's figures for these labels. 12 vCPU: at most six
# at once, five whenever it had a queue (2026-10-19); 6 vCPU: ten online at 21:40Z.
CAPACITY = {LARGE: 5, SMALL: 10}
# Headless compile and test jobs. A job missing here never leaves the minis on attempt 1.
CASCADE_JOBS = ("fast-tier", "swift-canary", "cmux-scheme-compile", "release-compile")
# The jobs a feat-cmux-next push runs on the promotion mini (PROMOTE_LABEL) instead of the side label.
PROMOTE_JOBS = ("release-compile",)
MAX_PER_RUN = 2
# The step has two minutes, and the placement's own reads come first.
READ_BUDGET_SECONDS = 45
QUEUE_SNAPSHOT_MINUTES = 15
SCALE_SET_GROUP = "Blacksmith scale sets - {label}"
API = "https://api.github.com"


@dataclasses.dataclass(frozen=True)
class Placement:
    jobs: Mapping[str, tuple[str, ...]]  # Blacksmith label or HOSTED -> the jobs it takes now
    retry_runner: str
    why: str


def in_flight(groups: Sequence[Mapping[str, Any]], runners_of: Callable[[int], Sequence[Mapping[str, Any]]],
              ) -> dict[str, int] | None:
    """Each label's online just-in-time runners, from its scale-set group; None when a group is missing."""
    by_name = {str(group.get("name") or ""): group.get("id") for group in groups if isinstance(group, Mapping)}
    counts: dict[str, int] = {}
    for label in LABELS:
        group = by_name.get(SCALE_SET_GROUP.format(label=label))
        if not isinstance(group, int):
            return None
        counts[label] = sum(1 for runner in runners_of(group) if runner.get("status") == "online")
    return counts


@dataclasses.dataclass(frozen=True)
class Seen:
    """What else the snapshot says: each label's oldest queued wait by now (minutes), and HOSTED's load."""
    waits: Mapping[str, float]
    hosted: int
    age: float = 0.0  # the snapshot's age in minutes, already in `waits`


def _fresh(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> tuple[float, Mapping[str, Any]] | None:
    """(age in minutes, pools) of a janitor snapshot at most QUEUE_SNAPSHOT_MINUTES old, else None."""
    if not isinstance(snapshot, Mapping):
        return None
    try:
        generated = dt.datetime.fromisoformat(str(snapshot.get("generated_at") or "").replace("Z", "+00:00"))
    except ValueError:
        return None
    if generated.tzinfo is None:
        return None
    age = (now - generated).total_seconds() / 60
    pools = snapshot.get("pools")
    if not -5 <= age <= QUEUE_SNAPSHOT_MINUTES or not isinstance(pools, Mapping):
        return None
    return age, pools


def _field(pools: Mapping[str, Any], label: str, key: str) -> int:
    entry = pools.get(label) or {}
    try:
        return max(0, int(entry.get(key, 0))) if isinstance(entry, Mapping) else 0
    except (TypeError, ValueError):
        return 0


def queued(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> dict[str, int] | None:
    """Each label's queued jobs from a janitor snapshot at most QUEUE_SNAPSHOT_MINUTES old, else None."""
    fresh = _fresh(snapshot, now)
    if fresh is None:
        return None
    return {label: _field(fresh[1], label, "queued") for label in LABELS}


def seen(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> Seen | None:
    """Each label's oldest queued wait by now and HOSTED's queued + running, from the same fresh snapshot."""
    fresh = _fresh(snapshot, now)
    if fresh is None:
        return None
    age, pools = fresh
    age = max(0.0, age)
    waits = {label: float(_field(pools, label, "oldest_queued_minutes")) + age
             if _field(pools, label, "queued") else 0.0 for label in LABELS}
    # Every hosted macOS pool shares the organization's concurrency; the janitor keys a job by its
    # macOS labels joined with commas, so a hosted pool is one whose labels are all macos-*.
    hosted = sum(_field(pools, pool, "queued") + _field(pools, pool, "running") for pool in pools
                 if all(part.startswith("macos-") for part in str(pool).split(",")))
    return Seen(waits=waits, hosted=hosted, age=age)


def stalled(live: Mapping[str, int], waiting: Mapping[str, int], waits: Mapping[str, float],
            age: float = 0.0) -> tuple[str, ...]:
    """The labels whose queue is not moving: a wait of STALL_MINUTES by now, or one of IDLE_STALL_MINUTES
    the snapshot saw (`waits` less its `age`) with no runner online now."""
    return tuple(label for label in LABELS
                 if waiting.get(label, 0) > 0
                 and (waits.get(label, 0.0) >= STALL_MINUTES
                      or live.get(label, 0) == 0 and waits.get(label, 0.0) - age >= IDLE_STALL_MINUTES))


def cascade(jobs: Sequence[str], live: Mapping[str, int], waiting: Mapping[str, int], *,
            stall: Sequence[str] = (), hosted_free: int = 0) -> dict[str, tuple[str, ...]]:
    """Give `jobs`, in order, the free slots of LARGE, then SMALL (unless stalled), then HOSTED for HOSTED_JOBS."""
    free = {label: 0 if label in stall else CAPACITY[label] - live.get(label, 0) - waiting.get(label, 0)
            for label in LABELS}
    free[HOSTED] = min(hosted_free, MAX_PER_RUN)
    placed: dict[str, list[str]] = {label: [] for label in (*LABELS, HOSTED)}
    for job in jobs:
        targets = (*LABELS, HOSTED) if job in HOSTED_JOBS else LABELS
        label = next((label for label in targets if free[label] > 0), None)
        if label is None:
            continue
        placed[label].append(job)
        if len(placed[label]) >= MAX_PER_RUN:
            free[label] = 0
        free[label] -= 1
    return {label: tuple(names) for label, names in placed.items()}


def retry_label(live: Mapping[str, int], waiting: Mapping[str, int], stall: Sequence[str] = ()) -> str:
    """The overflow label: the lowest (in flight + queued) / capacity among moving labels with a free slot, else "".

    "" sends the bot's overflow to the owned side label: a job never falls back
    to a Blacksmith label with no free slot, where it would queue for hours.

    With no free slot anywhere the load ratio misleads: other workflows' long jobs
    hold the 12 vCPU label's five slots for an hour or more. From 01:04Z to 02:35Z on
    2026-10-20 the ratio sent 25 cmux-next jobs there and none started (14 queued
    over 15 minutes, up to 89, then cancelled), while 6 vCPU, whose ten slots turn
    over, started 69 at a median 2.5 minutes.
    """
    load = {label: live.get(label, 0) + waiting.get(label, 0) for label in LABELS}
    free = [label for label in LABELS if load[label] < CAPACITY[label] and label not in stall]
    if not free:
        return ""
    return min(free, key=lambda label: (load[label] / CAPACITY[label], LABELS.index(label)))


def skipped(env: Mapping[str, str]) -> str:
    """Why this run places nothing on Blacksmith before reading anything, or ""."""
    label = (env.get("SIDE_LABEL") or "").strip()
    if (env.get("GITHUB_RUN_ATTEMPT") or "").strip() not in ("", "1"):
        return "a re-run keeps its own route"
    if not label.startswith("glaeda-side-"):
        return f"`{label or 'no label'}` is not an owned side label"
    return ""


def place(env: Mapping[str, str], owned: Sequence[str], live: Mapping[str, int] | None,
          waiting: Mapping[str, int] | None, seen: Seen | None = None, promote_busy: bool = False) -> Placement:
    """The Blacksmith and hosted jobs of attempt 1, after the idle minis took `owned`.

    With PROMOTE_LABEL set (a feat-cmux-next push), PROMOTE_JOBS run on that label: they cascade,
    first, only when `promote_busy` (no idle runner carries it), and never take an idle side mini's turn.
    """
    empty = {label: () for label in (*LABELS, HOSTED)}
    if skipped(env):
        return Placement(empty, "", skipped(env))
    if live is None:
        return Placement(empty, "", "Blacksmith's runner groups could not be read; no job leaves the minis' queue")
    stall = stalled(live, waiting or {}, seen.waits, seen.age) if seen is not None else ()
    if waiting is None:
        # Without the queue count no slot is known free, so the overflow keeps the owned label too.
        return Placement(empty, "", f"no pool snapshot under {QUEUE_SNAPSHOT_MINUTES} min old to count "
                                    "Blacksmith's queue; no job leaves the minis' queue")
    runs = set((env.get("CASCADE_RUNS") or "").split())
    # idle_placement() hands the idle minis to the first JOBS, running or not, and
    # every side job takes the side label whatever owned_jobs says: so the idle
    # minis count against the jobs that run here, in order, before Blacksmith.
    running = [job for job in (env.get("JOBS") or "").split() if job in CASCADE_JOBS and job in runs]
    promoted = [job for job in running if job in PROMOTE_JOBS] if (env.get("PROMOTE_LABEL") or "").strip() else []
    side = [job for job in running if job not in promoted]
    # FIRST_JOBS (a feat-cmux-next push's Release compile, which gates the nightly-next request) take the
    # run's slots first: with MAX_PER_RUN slots a run it was last and found none (2026-10-26 09:21Z, run
    # 40298786351: fast-tier and the scheme compile took 6 vCPU's two). Every side job takes the same
    # label and races for its idle minis, so the count of jobs those minis take is all that is known:
    # it is spent on the run's other jobs first, and a FIRST_JOBS job has a slot whenever one is free.
    first = set((env.get("FIRST_JOBS") or "").split())
    rest = [job for job in side if job not in first]
    leading = [job for job in side if job in first]
    candidates = ((promoted if promote_busy else []) + leading[max(0, len(owned) - len(rest)):]
                  + rest[len(owned):])
    hosted_free = HOSTED_CAPACITY - seen.hosted if seen is not None else 0
    placed = cascade(candidates, live, waiting, stall=stall, hosted_free=hosted_free)
    # The overflow label counts the slots this run's own jobs just took.
    retry = retry_label(live, {label: waiting.get(label, 0) + len(placed.get(label, ())) for label in LABELS}, stall)
    load = ", ".join(f"`{label}` {live[label]} in flight + {waiting[label]} queued of {CAPACITY[label]}"
                     + (f" (stalled: oldest queued {seen.waits[label]:.0f} min)" if label in stall and seen else "")
                     for label in LABELS)
    moved = "; ".join(f"`{label}` takes {', '.join(names)}" for label, names in placed.items() if names)
    left = [job for job in candidates if not any(job in names for names in placed.values())]
    why = f"Blacksmith: {load}. " + (moved or "No free Blacksmith slot")
    if seen is not None:
        why += f"; `{HOSTED}` had {seen.hosted} of {HOSTED_CAPACITY} jobs"
    if left:
        why += f"; {', '.join(left)} stay queued on the owned label"
    return Placement(placed, retry, why + (f"; overflow goes to `{retry}`" if retry
                                           else "; no free Blacksmith slot, so overflow stays on the owned label"))


class Api:
    """The two reads: the route App token lists runner groups, GITHUB_TOKEN (actions: read) the snapshot."""

    def __init__(self, route_token: str, repository: str):
        self.route_token = route_token
        self.repository = repository

    def _get(self, path: str) -> Any:
        request = urllib.request.Request(f"{API}{path}", headers={
            "Accept": "application/vnd.github+json", "Authorization": f"Bearer {self.route_token}",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-next-macos-cascade"})
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)

    def in_flight(self) -> dict[str, int] | None:
        owner, _, name = self.repository.partition("/")
        groups = self._get(f"/orgs/{owner}/actions/runner-groups?per_page=100"
                           f"&visible_to_repository={urllib.parse.quote(name)}").get("runner_groups") or []
        return in_flight(groups, lambda group: self._get(
            f"/orgs/{owner}/actions/runner-groups/{group}/runners?per_page=100").get("runners") or [])


def read(env: Mapping[str, str], pool: Any, *, now: dt.datetime, log: Callable[[str], None] = print,
         clock: Callable[[], float] = time.monotonic,
         ) -> tuple[dict[str, int] | None, dict[str, int] | None, Seen | None]:
    """(in flight, queued, seen) for place(); each None when its read fails or READ_BUDGET_SECONDS ran out."""
    started = clock()
    live = waiting = None
    found: Seen | None = None
    if skipped(env):
        return live, waiting, found
    route, repository = env.get("ROUTE_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if route and repository:
        try:
            live = Api(route, repository).in_flight()
            if live is None:
                log("::warning title=macOS cascade::no `Blacksmith scale sets - <label>` runner group is visible")
        except Exception as error:  # noqa: BLE001 - fail closed: nothing leaves the minis' queue
            log(f"::warning title=macOS cascade::could not list Blacksmith's runner groups ({error})")
    snapshot_token = env.get("SNAPSHOT_TOKEN", "")
    if clock() - started > READ_BUDGET_SECONDS:
        log("::warning title=macOS cascade::the runner groups took too long; the pool snapshot is not read")
        return live, None, None
    if live is not None and snapshot_token and repository:
        try:
            snapshot = pool.GitHub(snapshot_token, repository).snapshot(now=now)
            waiting, found = queued(snapshot, now), seen(snapshot, now)
        except Exception as error:  # noqa: BLE001 - fail closed, as above
            log(f"::warning title=macOS cascade::could not read the pool snapshot ({error})")
    return live, waiting, found


def delimited(jobs: Sequence[str]) -> str:
    return f" {' '.join(jobs)} " if jobs else ""


def write(placement: Placement, env: Mapping[str, str]) -> None:
    """Outputs blacksmith_12_jobs, blacksmith_6_jobs, hosted_jobs (space-delimited, as owned_jobs),
    hosted_runner (HOSTED when hosted_jobs names a job) and free_retry_runner (also as retry_runner)."""
    output = env.get("GITHUB_OUTPUT")
    hosted = placement.jobs.get(HOSTED, ())
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"blacksmith_12_jobs={delimited(placement.jobs.get(LARGE, ()))}\n"
                         f"blacksmith_6_jobs={delimited(placement.jobs.get(SMALL, ()))}\n"
                         f"hosted_jobs={delimited(hosted)}\n"
                         f"hosted_runner={HOSTED if hosted else ''}\n"
                         f"retry_runner={placement.retry_runner}\n"
                         f"free_retry_runner={placement.retry_runner}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"\n{placement.why}\n")
