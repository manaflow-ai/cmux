#!/usr/bin/env python3
"""Run main's runner-pool policy, then spill the linux pool off a backed-up size, not only a dead one.

On 2026-11-02 at about 04:40Z blacksmith-4vcpu-ubuntu-2404, which RUNNER_POOLS.linux and LINUX_RUNNER both named
(about 100 runs-on read the pool, about 285 read LINUX_RUNNER), had 428 jobs queued beside 535 running, the oldest
about 45 minutes (721 queued earlier), while blacksmith-16vcpu-ubuntu-2404 had about 11 queued. main's
scripts/ci/runner_pools.py moves a pool only off a member it judges dead, and a size that keeps starting jobs is
never dead, however long its queue, so nothing moved.

The scheduled overflow watch (ci-cloud-overflow-probe.yml) lives on main and keeps main's policy and clients; this
entry point is checked out from feat-cmux-next beside it at a pinned commit, the way runner_pool_reconcile.py is.
Each pass it

- runs main's runner_pools.main() unchanged, with a switch that records its writes instead of making them, so the
  dead-member rule, the probe and janitor evidence and the --check schema stay main's;
- samples the Linux queue itself (sample_load()): queued and in-progress runs created WAITED_MINUTES to
  SAMPLE_WINDOW ago, listed in age slices and spread evenly over each (at most MAX_RUNS), their jobs read with
  the job's own GITHUB_TOKEN (actions: read), counted per Blacksmith Linux label as queued, running and `waited`
  (queued WAITED_MINUTES or more, the stall-aware failover's bound). The counts are a lower bound;
- applies spill_choice() to the linux pool: when SPILL_WAITED or more sampled jobs on the pool's live member have
  waited and a later live member has at most SPILL_ROOM_WAITED, the pool moves there, recorded in RUNNER_POOLS'
  `_spill`. It comes back once the member it left shows a drain on a complete sample (nothing waited, at most
  SPILL_RETURN_QUEUED queued, at most SPILL_RETURN_SHARE of what it ran when the pool left) after SPILL_MIN_HOLD,
  or when the target backs up while the member left does not, or after SPILL_MAX_HOLD in any case: if the member
  is still backed up the next pass spills again, so a spill never outlives the backlog by more than about an hour;
- writes RUNNER_POOLS and the LINUX_RUNNER mirror (main's mirror_writes(), so the overflow switch's record still
  wins) only when something changed.

An unreadable sample never moves the pool and keeps a spill as it is until SPILL_MAX_HOLD. The spill target must be
a live member of the declared pool (main's .github/runners.json), so a spill never leaves the runner set; every
linux member is accepted by the bounded `vars.LINUX_RUNNER` selectors (main's tests/test_ci_runner_pools.py).
Nothing here cancels or moves a queued job: jobs already bound to the backed-up size drain there.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.parse
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runner_pool_reconcile  # noqa: E402  (load_policy(): main's policy, never this checkout's)

UTC = dt.timezone.utc
VARIABLE = "RUNNER_POOLS"
SPILL_KEY = "_spill"
QUEUE_AWARE_POOLS = ("linux",)
LINUX_LABEL = re.compile(r"^blacksmith-[0-9]+vcpu-ubuntu-[0-9][\w.-]*$")
# A sampled queued job counts as `waited` once it has waited this long.
WAITED_MINUTES = 3
# The sample: runs in flight created WAITED_MINUTES to SAMPLE_WINDOW ago, at most MAX_RUNS of them.
MAX_RUNS = 60
# The client reads one page of each run's jobs (cloud_overflow_switch.GitHub.jobs(): per_page=100).
JOB_PAGE = 100
SAMPLE_WINDOW = dt.timedelta(minutes=90)
# The window is listed in slices between these ages (oldest first), WAITED_MINUTES to SAMPLE_WINDOW.
SLICE_EDGES = (dt.timedelta(minutes=30), dt.timedelta(minutes=10))
SPILL_WAITED = 15
SPILL_ROOM_WAITED = 3
SPILL_MIN_HOLD = dt.timedelta(minutes=20)
SPILL_MAX_HOLD = dt.timedelta(minutes=60)
SPILL_RETURN_QUEUED = 5
SPILL_RETURN_SHARE = 0.7
COMPLETE = "_complete"
ZERO = {"queued": 0, "running": 0, "waited": 0}


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo is not None else None


def list_runs(client: Any, status: str, start: dt.datetime, end: dt.datetime) -> list[dict[str, Any]]:
    """One page (100) of `status` runs created between start and end, newest first."""
    query = urllib.parse.urlencode({"status": status, "per_page": 100, "created": f"{iso(start)}..{iso(end)}"})
    return list(client.request("GET", f"/actions/runs?{query}").get("workflow_runs") or [])


def sample_load(client: Any, *, now: dt.datetime, max_runs: int = MAX_RUNS) -> dict[str, Any] | None:
    """Blacksmith Linux label -> {queued, running, waited} over the newest in-flight runs; None when unreadable.

    COMPLETE says whether every in-flight run created WAITED_MINUTES to SAMPLE_WINDOW ago was read: only then can the
    sample prove a drain."""
    # Runs created between WAITED_MINUTES and SAMPLE_WINDOW ago: a younger run's jobs cannot have waited yet, and a
    # backed-up label's waiting jobs sit in the older runs. The first live passes (2026-11-02 07:13Z, 07:34Z, 07:43Z)
    # read the newest runs only (the unfiltered listing's first page, then the newest at least 3 minutes old) and saw
    # 0 waited 4 vCPU jobs while 44 had waited over 10 minutes in runs about 45 minutes old.
    # Each slice is listed on its own (a listing page holds the newest 100 runs), so a busy hour's newest runs never
    # hide the older ones; each slice gives an evenly spread share of MAX_RUNS.
    edges = [now - SAMPLE_WINDOW, *(now - age for age in SLICE_EDGES), now - dt.timedelta(minutes=WAITED_MINUTES)]
    recent: list[Mapping[str, Any]] = []
    # Each sampled run stands for this many runs of its slice: the counts are scaled up by it, so a backlog spread
    # thinly over a busy slice still shows (a lower bound still, since a full listing page hides more runs).
    weight: dict[int, float] = {}
    complete = True
    share = max(1, max_runs // (len(edges) - 1))
    for start, end in zip(edges, edges[1:]):
        try:
            pages = [list_runs(client, status, start, end) for status in ("queued", "in_progress")]
        except Exception as error:  # noqa: BLE001 - an unread listing is no evidence
            print(f"::warning title=Linux pool spill::could not list runs ({error}); no queue sample")
            return None
        listed = {run["id"]: run for page in pages for run in page
                  if isinstance(run, Mapping) and isinstance(run.get("id"), int)}
        taken = {run["id"] for run in recent}
        found = sorted((run for run in listed.values() if run["id"] not in taken
                        and (created := parse_time(run.get("created_at"))) is not None and start <= created <= end),
                       key=lambda run: (str(run.get("created_at")), run["id"]))
        # A full page may have hidden more runs; a slice over its share is only partly read.
        if any(len(page) >= 100 for page in pages) or len(found) > share:
            complete = False
        population = len(found)
        if len(found) > share:
            step = len(found) / share
            found = [found[int(index * step)] for index in range(share)]
        for run in found:
            weight[run["id"]] = population / len(found)
        recent += found
    counts: dict[str, dict[str, float]] = {}
    for run in recent:
        try:
            jobs = client.jobs(run["id"])
        except Exception:  # noqa: BLE001 - one unread run only makes the sample partial
            complete = False
            continue
        if len(jobs) >= JOB_PAGE:
            # One page of jobs; a run with more may hide queued ones (review of cmux#31884).
            complete = False
        for job in jobs:
            status = job.get("status")
            if status not in ("queued", "in_progress"):
                continue
            label = next((str(label) for label in job.get("labels") or () if LINUX_LABEL.match(str(label))), None)
            if label is None:
                continue
            entry = counts.setdefault(label, {key: 0.0 for key in ZERO})
            if status == "in_progress":
                entry["running"] += weight[run["id"]]
                continue
            entry["queued"] += weight[run["id"]]
            created = parse_time(job.get("created_at"))
            if created is not None and now - created >= dt.timedelta(minutes=WAITED_MINUTES):
                entry["waited"] += weight[run["id"]]
    load: dict[str, Any] = {label: {key: round(value) for key, value in entry.items()} for label, entry in counts.items()}
    load[COMPLETE] = complete
    return load


def valid_spill(spill: object, listed: Sequence[str]) -> bool:
    if not isinstance(spill, Mapping):
        return False
    running = spill.get("running")
    return (spill.get("from") in listed and spill.get("to") in listed and spill.get("from") != spill.get("to")
            and parse_time(spill.get("since")) is not None
            and isinstance(running, int) and not isinstance(running, bool) and running >= 0)


def spill_choice(name: str, candidates: Sequence[str], dead: Mapping[str, Any], base: str,
                 spill: Mapping[str, Any] | None, load: Mapping[str, Any] | None, *,
                 now: dt.datetime) -> tuple[str, dict[str, Any] | None, list[str]]:
    """(member, spill record or None, lines) for a pool whose first live member (main's choice) is `base`."""
    if name not in QUEUE_AWARE_POOLS:
        return base, None, []
    later = candidates[candidates.index(base) + 1:] if base in candidates else []
    if spill is not None:
        target = str(spill.get("to"))
        if spill.get("from") != base or target not in later or target in dead:
            return base, None, [f"pools.{name}: spill {spill.get('from')} -> {target} ended; "
                                f"{base} is the first live member"]
        since = parse_time(spill.get("since"))
        held = now - since if since is not None else SPILL_MAX_HOLD
        if held >= SPILL_MAX_HOLD:
            return base, None, [f"pools.{name}: spill to {target} reached {SPILL_MAX_HOLD}; back to {base} "
                                "(the next pass spills again if it is still backed up)"]
        if load is None:
            return target, dict(spill), []
        left, took = load.get(base, ZERO), load.get(target, ZERO)
        if took["waited"] >= SPILL_WAITED and left["waited"] < SPILL_WAITED and load.get(COMPLETE) is True:
            return base, None, [f"pools.{name}: {target} is backed up too ({took['waited']} sampled jobs waited) "
                                f"and {base} is not; back to {base}"]
        if held >= SPILL_MIN_HOLD and load.get(COMPLETE) is True and left["waited"] == 0 \
                and left["queued"] <= SPILL_RETURN_QUEUED \
                and left["running"] <= SPILL_RETURN_SHARE * int(spill.get("running") or 0):
            return base, None, [f"pools.{name}: {base} drained ({left['queued']} queued, {left['running']} running, "
                                f"{spill.get('running')} when the pool left); back to {base}"]
        return target, dict(spill), []
    if load is None:
        return base, None, []
    left = load.get(base, ZERO)
    if left["waited"] < SPILL_WAITED:
        return base, None, []
    for member in later:
        if member in dead:
            continue
        room = load.get(member, ZERO)
        if room["waited"] <= SPILL_ROOM_WAITED:
            record = {"from": base, "to": member, "since": iso(now), "running": left["running"]}
            return member, record, [f"pools.{name}: {base} backed up ({left['waited']} of {left['queued']} sampled "
                                    f"queued jobs waited {WAITED_MINUTES}+ min, {left['running']} running); "
                                    f"spill to {member} ({room['waited']} waited)"]
    return base, None, [f"pools.{name}: {base} backed up ({left['waited']} sampled jobs waited) and no later live "
                        "member has room; staying"]


class Recorder:
    """The switch main's policy writes through: reads go to the real variables, writes are only recorded."""

    def __init__(self, real: Any, env: Mapping[str, str]) -> None:
        self.real, self.env, self.writes = real, env, {}

    def get_variable(self, name: str) -> str | None:
        if name in self.writes:
            return self.writes[name]
        if self.real is not None:
            return self.real.get_variable(name)
        return self.env.get(name)

    def set_variable(self, name: str, value: str) -> None:
        self.writes[name] = value


def apply(policy: Any, raw: str | None, policy_value: str | None, pools: Mapping[str, Any],
          load: Mapping[str, Any] | None, *, now: dt.datetime) -> tuple[dict[str, Any], list[str]]:
    """The RUNNER_POOLS value after the spill step: main's next value (`policy_value`, else the current one) with the
    linux pool spilled or brought back, and `_spill` carried from the current raw value."""
    chosen, _ = policy.parse_value(policy_value if policy_value is not None else raw, pools)
    try:
        previous = json.loads(raw) if (raw or "").strip() else {}
    except ValueError:
        previous = {}
    spills = previous.get(SPILL_KEY) if isinstance(previous, Mapping) else None
    spills = spills if isinstance(spills, Mapping) else {}
    value = dict(chosen)
    dead = value.get(policy.DEAD_KEY) or {}
    lines: list[str] = []
    kept: dict[str, Any] = {}
    for name in QUEUE_AWARE_POOLS:
        if name not in pools or name not in value:
            continue
        listed = policy.members(pools[name])
        spill = spills.get(name)
        if spill is not None and not valid_spill(spill, listed):
            lines.append(f"{VARIABLE}.{SPILL_KEY}.{name} is not a spill between two of its members; dropped")
            spill = None
        member, record, said = spill_choice(name, listed, dead, value[name], spill, load, now=now)
        lines += said
        if member != value[name]:
            lines.append(f"pools.{name}: {value[name]} -> {member}")
        value[name] = member
        if record is not None:
            kept[name] = record
    if kept:
        value[SPILL_KEY] = kept
    else:
        value.pop(SPILL_KEY, None)
    return value, lines


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, *, policy: Any = None,
         switch: Any = None, client: Any = None, api: Any = None, now: dt.datetime | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--policy-root", type=Path, default=Path.cwd(),
                        help="the main checkout whose scripts/ci/runner_pools.py and .github/runners.json decide")
    parser.add_argument("--dry-run", action="store_true",
                        default=(env.get("DRY_RUN", "").strip().lower() in {"1", "true", "yes"}))
    args = parser.parse_args(argv)
    now = now or dt.datetime.now(UTC)
    policy = policy or runner_pool_reconcile.load_policy(args.policy_root)
    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    if switch is None and (env.get("SWITCH_TOKEN") or "").strip() and repo:
        switch = policy.Variables(str(env["SWITCH_TOKEN"]).strip(), repo)
    if client is None and (env.get("GH_TOKEN") or "").strip() and repo:
        import cloud_overflow_switch  # noqa: PLC0415 - main's client, loaded beside its policy
        client = cloud_overflow_switch.GitHub(str(env["GH_TOKEN"]).strip(), repo)

    # The current value, read live: the job-start value may predate the switch step's writes.
    raw = env.get(VARIABLE)
    if switch is not None:
        try:
            live = switch.get_variable(VARIABLE)
            raw = live if live is not None else raw
        except Exception as error:  # noqa: BLE001 - fall back to the job-start value
            print(f"::warning title=Linux pool spill::could not read {VARIABLE} live ({error}); using the job's value")
    recorder = Recorder(switch, env)
    policy_env = {**env, VARIABLE: raw or "", "DRY_RUN": "false"}
    code = policy.main([], policy_env, api=api, switch=recorder, now=now)
    if code != 0:
        return code
    pools = policy.load_pools(args.policy_root / ".github" / "runners.json")
    load = sample_load(client, now=now) if client is not None else None
    if load is not None:
        print("linux queue sample: " + json.dumps(load, sort_keys=True))
    value, lines = apply(policy, raw, recorder.writes.get(VARIABLE), pools, load, now=now)
    for line in lines:
        print(line)
    try:
        before = json.loads(raw) if (raw or "").strip() else {}
    except ValueError:
        before = {}
    before = before if isinstance(before, dict) else {}
    strip = lambda mapping: {k: v for k, v in mapping.items() if k != policy.UPDATED_KEY}  # noqa: E731
    if strip(value) != strip(before) or policy.UPDATED_KEY not in before:
        value[policy.UPDATED_KEY] = iso(now)
    else:
        value[policy.UPDATED_KEY] = before[policy.UPDATED_KEY]
    writes: list[tuple[str, str]] = []
    rendered = policy.render(value)
    if rendered != (raw or "").strip():
        writes.append((VARIABLE, rendered))
    live_mirrors, record, readable = policy._live(switch, env)
    if readable:
        writes += policy.mirror_writes(value, live_mirrors, record=record)
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Linux pool spill\n\n" + ("\n".join(f"- {line}" for line in lines) or "- no change")
                         + "\n\n")
    if not writes:
        print(f"{VARIABLE} and its mirrors unchanged")
        return 0
    if switch is not None and VARIABLE in dict(writes):
        # Another writer may have changed RUNNER_POOLS (a dead mark, say) while this pass sampled: never
        # overwrite it with a value planned from the old one; the next pass plans from the new one.
        try:
            again = switch.get_variable(VARIABLE)
        except Exception as error:  # noqa: BLE001 - unread means unknown: do not write over it
            print(f"::warning title=Linux pool spill::could not re-read {VARIABLE} ({error}); writing nothing")
            return 0
        if (again or "").strip() != (raw or "").strip():
            print(f"::warning title=Linux pool spill::{VARIABLE} changed during this pass; writing nothing")
            return 0
    if args.dry_run:
        for name, text in writes:
            print(f"{name} would be {text} (dry run)")
        return 0
    if switch is None:
        for name, text in writes:
            print(f"::error title=Linux pool spill::no switch token (GLAEDA_ROUTE_APP_ID); {name} should be {text}")
        return 1
    for name, text in writes:
        switch.set_variable(name, text)
        print(f"{name} = {text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
