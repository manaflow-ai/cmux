#!/usr/bin/env python3
"""cmux-next's macOS cascade: idle minis, then Blacksmith 12 vCPU, then 6 vCPU, then the minis' queue.

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
(CASCADE_RUNS: not fast-tier when vars.CI_FAST_LANE_RUNNER gives it its own
runner, not a job path routing or labels skip), so no slot is spent on a job
that never asks for it. The jobs that need a logged-in session (swift-test,
daemon-test, generated-files) keep the gui route, and release-compile stays on
the minis: only a mini fetches Chromium and compiles the CEF shim.

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

`retry_runner` is the Blacksmith label the bot's overflow attempt (3 or later)
takes for these jobs: simple_pool_picker's rule, the lowest (in flight +
queued) / capacity, the larger label on a tie. It is computed with the same
reads, at attempt 1, as classic's picker computes its retry_runner.
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
# simple_pool_picker.CAPACITY's figures for these labels. 12 vCPU: at most six
# at once, five whenever it had a queue (2026-10-19); 6 vCPU: ten online at 21:40Z.
CAPACITY = {LARGE: 5, SMALL: 10}
# Headless compile and test jobs. A job missing here never leaves the minis on attempt 1.
CASCADE_JOBS = ("fast-tier", "swift-canary", "cmux-scheme-compile")
MAX_PER_RUN = 2
# The step has two minutes, and the placement's own reads come first.
READ_BUDGET_SECONDS = 45
QUEUE_SNAPSHOT_MINUTES = 15
SCALE_SET_GROUP = "Blacksmith scale sets - {label}"
API = "https://api.github.com"


@dataclasses.dataclass(frozen=True)
class Placement:
    jobs: Mapping[str, tuple[str, ...]]  # Blacksmith label -> the jobs it takes now
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


def queued(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> dict[str, int] | None:
    """Each label's queued jobs from a janitor snapshot at most QUEUE_SNAPSHOT_MINUTES old, else None."""
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
    counts: dict[str, int] = {}
    for label in LABELS:
        entry = pools.get(label) or {}
        try:
            counts[label] = max(0, int(entry.get("queued", 0))) if isinstance(entry, Mapping) else 0
        except (TypeError, ValueError):
            counts[label] = 0
    return counts


def cascade(jobs: Sequence[str], live: Mapping[str, int], waiting: Mapping[str, int]) -> dict[str, tuple[str, ...]]:
    """Give `jobs`, in order, the free slots of LARGE and then SMALL; a job with none left gets nothing."""
    free = {label: CAPACITY[label] - live.get(label, 0) - waiting.get(label, 0) for label in LABELS}
    placed: dict[str, list[str]] = {label: [] for label in LABELS}
    for job in jobs:
        label = next((label for label in LABELS if free[label] > 0), None)
        if label is None:
            break
        placed[label].append(job)
        if len(placed[label]) >= MAX_PER_RUN:
            free[label] = 0
        free[label] -= 1
    return {label: tuple(names) for label, names in placed.items()}


def retry_label(live: Mapping[str, int], waiting: Mapping[str, int]) -> str:
    """simple_pool_picker._pick_blacksmith's overflow rule: lowest (in flight + queued) / capacity."""
    return min(LABELS, key=lambda label: ((live.get(label, 0) + waiting.get(label, 0)) / CAPACITY[label],
                                          LABELS.index(label)))


def skipped(env: Mapping[str, str]) -> str:
    """Why this run places nothing on Blacksmith before reading anything, or ""."""
    label = (env.get("SIDE_LABEL") or "").strip()
    if (env.get("GITHUB_RUN_ATTEMPT") or "").strip() not in ("", "1"):
        return "a re-run keeps its own route"
    if not label.startswith("glaeda-side-"):
        return f"`{label or 'no label'}` is not an owned side label"
    return ""


def place(env: Mapping[str, str], owned: Sequence[str], live: Mapping[str, int] | None,
          waiting: Mapping[str, int] | None) -> Placement:
    """The Blacksmith jobs of attempt 1, after the idle minis took `owned`."""
    empty = {label: () for label in LABELS}
    if skipped(env):
        return Placement(empty, "", skipped(env))
    if live is None:
        return Placement(empty, "", "Blacksmith's runner groups could not be read; no job leaves the minis' queue")
    retry = retry_label(live, waiting or {})
    if waiting is None:
        return Placement(empty, retry, f"no pool snapshot under {QUEUE_SNAPSHOT_MINUTES} min old to count "
                                       "Blacksmith's queue; no job leaves the minis' queue")
    runs = set((env.get("CASCADE_RUNS") or "").split())
    # idle_placement() hands the idle minis to the first JOBS, running or not, and
    # every side job takes the side label whatever owned_jobs says: so the idle
    # minis count against the jobs that run here, in order, before Blacksmith.
    running = [job for job in (env.get("JOBS") or "").split() if job in CASCADE_JOBS and job in runs]
    candidates = running[len(owned):]
    placed = cascade(candidates, live, waiting)
    load = ", ".join(f"`{label}` {live[label]} in flight + {waiting[label]} queued of {CAPACITY[label]}"
                     for label in LABELS)
    moved = "; ".join(f"`{label}` takes {', '.join(names)}" for label, names in placed.items() if names)
    left = [job for job in candidates if not any(job in names for names in placed.values())]
    why = f"Blacksmith: {load}. " + (moved or "No free Blacksmith slot")
    if left:
        why += f"; {', '.join(left)} stay queued on the owned label"
    return Placement(placed, retry, why + f"; overflow goes to `{retry}`")


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
         clock: Callable[[], float] = time.monotonic) -> tuple[dict[str, int] | None, dict[str, int] | None]:
    """(in flight, queued) for place(); each None when its read fails or READ_BUDGET_SECONDS ran out."""
    started = clock()
    live = waiting = None
    if skipped(env):
        return live, waiting
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
        return live, None
    if live is not None and snapshot_token and repository:
        try:
            waiting = queued(pool.GitHub(snapshot_token, repository).snapshot(now=now), now)
        except Exception as error:  # noqa: BLE001 - fail closed, as above
            log(f"::warning title=macOS cascade::could not read the pool snapshot ({error})")
    return live, waiting


def delimited(jobs: Sequence[str]) -> str:
    return f" {' '.join(jobs)} " if jobs else ""


def write(placement: Placement, env: Mapping[str, str]) -> None:
    """Outputs blacksmith_12_jobs, blacksmith_6_jobs (space-delimited, as owned_jobs) and retry_runner."""
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"blacksmith_12_jobs={delimited(placement.jobs.get(LARGE, ()))}\n"
                         f"blacksmith_6_jobs={delimited(placement.jobs.get(SMALL, ()))}\n"
                         f"retry_runner={placement.retry_runner}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"\n{placement.why}\n")
