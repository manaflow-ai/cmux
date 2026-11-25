#!/usr/bin/env python3
"""Reconcile live runner variables using the declared policy in a trusted checkout.

The scheduled workflow lives on main. Its policy and clients remain in that
checkout; this entry point is checked out from feat-cmux-next beside it.
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib
import json
import os
import re
from pathlib import Path
import sys
import time
from typing import Any, Mapping

FLEET_LINUX = "cmux-fleet-linux-x64"
ROUTE_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ROUTE_VARIABLE = re.compile(r"^(?:[A-Z][A-Z0-9_]*|RUNNER_POOLS\.[a-z][a-z0-9_]*)$")


def spec_problems(policy: Any, pools: Mapping[str, Any]) -> list[str]:
    """Only the audited Linux pool may add the existing secretless JIT route."""
    ephemeral = {name: dict(spec) for name, spec in pools.items()}
    linux = ephemeral.get("linux")
    if linux and FLEET_LINUX in linux["members"]:
        linux["members"] = [label for label in linux["members"] if label != FLEET_LINUX]
        if "linux_ephemeral" not in pools:
            return ["fleet Linux requires a separate linux_ephemeral pool for legacy secret-bearing jobs"]
    return policy.spec_problems(ephemeral)


def mirror_pool(pools: Mapping[str, Any], name: str, fallback: str) -> str:
    return "linux_ephemeral" if name == "LINUX_RUNNER" and "linux_ephemeral" in pools else fallback


def record_moves(policy: Any, previous: Mapping[str, Any], value: dict[str, Any],
                 mirrors: list[tuple[str, str]], live: Mapping[str, Any], pools: Mapping[str, Any],
                 *, now: dt.datetime) -> None:
    """The bounded _moved wire format from #30390, consumed by HQ's queued-only rescue."""
    changes = [(f"RUNNER_POOLS.{name}", previous.get(name), value.get(name)) for name in pools]
    changes += [(name, live.get(name), label) for name, label in mirrors]
    current = {f"RUNNER_POOLS.{name}": value.get(name) for name in pools}
    current.update(live)
    current.update(mirrors)
    kept = []
    for entry in previous.get("_moved", []) if isinstance(previous.get("_moved"), list) else []:
        if not isinstance(entry, Mapping) or not all(isinstance(entry.get(k), str)
                                                    for k in ("variable", "from", "to", "at")):
            continue
        stamp = policy.parse_time(entry["at"])
        if (ROUTE_VARIABLE.fullmatch(entry["variable"]) and ROUTE_LABEL.fullmatch(entry["from"])
                and ROUTE_LABEL.fullmatch(entry["to"]) and entry["from"] != entry["to"]
                and stamp is not None and dt.timedelta(minutes=-5) <= now - stamp <= dt.timedelta(hours=6)
                and current.get(entry["variable"]) != entry["from"]):
            kept.append({key: entry[key] for key in ("variable", "from", "to", "at")})
    for variable, old, new in changes:
        if (not isinstance(old, str) or not isinstance(new, str) or old == new
                or not ROUTE_LABEL.fullmatch(old) or not ROUTE_LABEL.fullmatch(new)):
            continue
        kept = [entry for entry in kept if (entry["variable"], entry["from"]) != (variable, old)]
        kept.append({"variable": variable, "from": old, "to": new, "at": policy.iso(now)})
    if kept or "_moved" in previous:
        value["_moved"] = kept[-16:]


def load_policy(source_root: Path) -> Any:
    """Load main's policy and its clients together, never this entry point's deps."""
    source = source_root.resolve() / "scripts" / "ci"
    if not (source / "runner_pools.py").is_file():
        raise ValueError(f"no runner-pool policy in {source}")
    sys.path.insert(0, str(source))
    policy = importlib.import_module("runner_pools")
    if Path(policy.__file__).resolve().parent != source:
        raise ValueError("runner-pool policy was imported from a different checkout")
    return policy


def plan(policy: Any, raw: str | None, pools: Mapping[str, Any], health: Any,
         snapshot: Any, *, now: dt.datetime) -> tuple[dict[str, Any], list[str]]:
    """Keep negative probe evidence until a later start, and never select a dead label."""
    current, notes = policy.parse_value(raw, pools)
    dead, started, evidence_notes = policy.label_evidence(health, snapshot, now=now)
    notes += evidence_notes
    fleet = FLEET_LINUX in pools.get("linux", {}).get("members", [])
    # A stalled probe does not become a successful probe merely by aging. A
    # fresh positive receipt (from either source) still clears its dead mark.
    if isinstance(health, Mapping):
        checked = policy.parse_time(health.get("checked"))
        labels = health.get("labels")
        if checked is not None and checked <= now + dt.timedelta(minutes=1) and isinstance(labels, Mapping):
            dead |= {label for label, state in labels.items() if state == "stalled"} - started
    if fleet:
        # A probe really requests the JIT label; merely listing an idle runner
        # is not a lease or evidence that a job started. Paid overflow requires
        # that probe's recorded three-minute no-start, never a missing read.
        labels = health.get("labels", {}) if isinstance(health, Mapping) else {}
        checked = policy.parse_time(health.get("checked")) if isinstance(health, Mapping) else None
        try:
            minutes = float(health.get("minutes", 0)) if isinstance(health, Mapping) else 0
        except (TypeError, ValueError):
            minutes = 0
        stalled_receipt = (checked is not None and checked <= now + dt.timedelta(minutes=1)
                           and labels.get(FLEET_LINUX) == "stalled" and minutes >= 3)
        if FLEET_LINUX not in started and not stalled_receipt and current.get("linux") != FLEET_LINUX:
            raise ValueError("no fleet start or recorded three-minute no-start; do not publish a guessed route")
        if FLEET_LINUX in dead and not stalled_receipt:
            raise ValueError("fleet appears stalled but has no three-minute probe receipt; no overflow write")
    value, changes = policy.reconcile(
        current, pools, dead_now=dead, served_now=started, now=now,
        covered=policy.evidence_covers(health, snapshot, pools, now=now))
    # The older policy chooses candidates[0] when all are dead. Refuse the
    # write rather than advertise a known stalled member as a live route.
    for name in pools:
        if value[name] in value.get(policy.DEAD_KEY, {}):
            if name == "linux_ephemeral" and value.get("linux") == FLEET_LINUX:
                # Blacksmith being entirely unavailable must not stop audited
                # secretless work on a fleet that just started its probe.
                value[name] = None
                notes.append("linux_ephemeral unavailable: all measured labels stalled; legacy mirror stays put")
                continue
            raise ValueError(f"pools.{name}: every declared member is stalled; no live route to publish")
    # A newly deployed consumer may add a pool before this checkout sees its
    # declaration. The writer owns declared keys only; retain the rest.
    try:
        previous = json.loads(raw or "{}")
    except ValueError:
        previous = {}
    if isinstance(previous, dict):
        old_marks = previous.get(policy.DEAD_KEY)
        known = {label for spec in pools.values() for label in policy.members(spec)}
        if isinstance(old_marks, dict):
            value[policy.DEAD_KEY].update({label: since for label, since in old_marks.items()
                                          if label not in known and policy.parse_time(since) is not None})
        value = {**previous, **value}
    return value, notes + changes


def run(policy: Any, env: Mapping[str, str], *, check: bool = False,
        dry_run: bool = False, switch: Any = None, api: Any = None,
        now: dt.datetime | None = None) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    pools = policy.load_pools()
    problems = spec_problems(policy, pools)
    if problems:
        raise ValueError("; ".join(problems))
    if switch is None:
        if check:
            raw = env.get(policy.VARIABLE)
            live = {name: env.get(name) for name in policy.MIRRORS}
            record = env.get(policy.OVERFLOW_RECORD)
        else:
            raise ValueError("no variable client; no routing writes")
    else:
        # Job-start values cannot protect against another completed writer.
        # Any failed live read aborts before the first mutation.
        raw = switch.get_variable(policy.VARIABLE)
        live = {name: switch.get_variable(name) for name in policy.MIRRORS}
        record = switch.get_variable(policy.OVERFLOW_RECORD)
    health = policy._health(switch, env)
    snapshot = None
    if api is not None:
        try:
            snapshot = api.snapshot(now=now)
        except Exception as error:
            print(f"::warning::No fresh runner snapshot: {error}")
    value, notes = plan(policy, raw, pools, health, snapshot, now=now)
    for note in notes:
        print(note)
    current, dropped = policy.parse_value(raw, pools)
    if check:
        available_pools = dict(pools)
        unavailable = "linux_ephemeral" in value and value["linux_ephemeral"] is None
        if unavailable:
            available_pools.pop("linux_ephemeral", None)
        problems = dropped + policy.value_problems(current, available_pools)
        if unavailable:
            problems.append("linux_ephemeral is unavailable: all trusted overflow labels stalled")
        owned = policy.switch_owned(record)
        for name, original_pool in policy.MIRRORS.items():
            pool = mirror_pool(pools, name, original_pool)
            if owned is not None and name not in owned and live.get(name) not in policy.members(pools[pool]):
                problems.append(f"{name} is not a member of {pool}")
        for name in pools:
            if current.get(name) in value.get(policy.DEAD_KEY, {}):
                problems.append(f"{policy.VARIABLE}.{name} selects stalled {current[name]}")
        for name, pool in policy.MIRRORS.items():
            if live.get(name) in value.get(policy.DEAD_KEY, {}):
                problems.append(f"{name} selects stalled {live[name]}")
        for problem in problems:
            print(f"::error::{problem}")
        return bool(problems)
    # Keep global legacy variables on their explicitly ephemeral pool. Their
    # existing consumers include jobs holding secrets on feat-cmux-next.
    mirror_value = dict(value)
    for name, original_pool in policy.MIRRORS.items():
        pool = mirror_pool(pools, name, original_pool)
        mirror_value[original_pool] = value[pool]
    recover = dict(live)
    # Recover a previously misrouted fleet value too, without adopting any
    # unrelated manually selected owned runner.
    if recover.get("LINUX_RUNNER") == FLEET_LINUX:
        recover["LINUX_RUNNER"] = ""
    mirrors = policy.mirror_writes(mirror_value, recover, record=record)
    try:
        previous = json.loads(raw or "{}")
    except ValueError:
        previous = {}
    record_moves(policy, previous if isinstance(previous, dict) else {}, value, mirrors, live, pools, now=now)
    while len(policy.render(value).encode()) > 48 * 1024 and value.get("_moved"):
        value["_moved"].pop(0)
    if len(policy.render(value).encode()) > 48 * 1024:
        raise ValueError("RUNNER_POOLS exceeds GitHub's variable limit; no routing writes")
    writes = []
    if policy.render(value) != (raw or "").strip():
        writes.append((policy.VARIABLE, policy.render(value)))
    writes += mirrors
    if writes and not dry_run and switch.get_variable(policy.VARIABLE) != raw:
        raise ValueError("RUNNER_POOLS changed during planning; leave the newer writer's value intact")
    for name, val in writes:
        print(f"{name}{' would be' if dry_run else ' ='} {val}")
        if not dry_run:
            switch.set_variable(name, val)
    if "linux_ephemeral" in value and value["linux_ephemeral"] is None:
        print("::error::Fleet routing published, but no trusted ephemeral capacity exists for LINUX_RUNNER")
        return 1
    return 0


def probe(policy: Any, env: Mapping[str, str]) -> int:
    """Keep the existing outage switch scoped to Blacksmith; observe fleet separately."""
    cloud = importlib.import_module("cloud_overflow_switch")
    pools = policy.load_pools()
    problems = spec_problems(policy, pools)
    if problems:
        raise ValueError("; ".join(problems))
    labels = tuple(policy.members(pools.get("linux_ephemeral", pools["linux"])))
    if not all(policy.EPHEMERAL.fullmatch(label) for label in labels):
        raise ValueError("the outage switch may probe only declared ephemeral Blacksmith labels")
    # This is configuration for the existing switch, not a replacement for its
    # secret/restore/cancellation policy. In particular a fleet start must not
    # count as Blacksmith recovering, or prevent a genuine Blacksmith outage.
    cloud.PROBE_LABELS = labels
    scoped_env = dict(env, PROBE_MINUTES="3")
    code = cloud.main([], scoped_env)
    if FLEET_LINUX not in policy.members(pools["linux"]) or env.get("PROBE_LABEL_DRILL"):
        return code
    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    api = cloud.GitHub(env["GH_TOKEN"], repo)
    run_id, attempt = int(env["GITHUB_RUN_ID"]), int(env.get("GITHUB_RUN_ATTEMPT") or 1)
    all_labels = (FLEET_LINUX, *labels)
    outcome, stalled = cloud.wait_for_probe(api, run_id, attempt, 3, all_labels,
                                           now=lambda: dt.datetime.now(dt.timezone.utc), sleep=time.sleep,
                                           log=lambda line: print(line, flush=True))
    if outcome != "unknown" and env.get("DRY_RUN", "").lower() not in {"1", "true", "yes"}:
        if not env.get("SWITCH_TOKEN"):
            raise ValueError("no switch token to publish observed probe health")
        health = cloud.label_health(all_labels, stalled, checked=policy.iso(dt.datetime.now(dt.timezone.utc)),
                                    run=f"https://github.com/{repo}/actions/runs/{run_id}", minutes=3)
        cloud.GitHub(env["SWITCH_TOKEN"], repo).set_variable(policy.HEALTH_VARIABLE, json.dumps(health))
    # A queued fleet probe must not retain the workflow's concurrency group
    # after all Blacksmith probes started. Existing final cleanup owns it.
    if outcome != "started" and env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"outcome={outcome}\n")
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    policy = load_policy(args.source_root)
    env = os.environ
    if args.probe:
        return probe(policy, env)
    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    switch = policy.Variables(env["SWITCH_TOKEN"], repo) if env.get("SWITCH_TOKEN") and repo else None
    api = policy.pr_runner_pool.GitHub(env["GH_TOKEN"], repo) if env.get("GH_TOKEN") and repo else None
    try:
        return run(policy, env, check=args.check,
                   dry_run=args.dry_run or env.get("DRY_RUN", "").lower() in {"1", "true", "yes"},
                   switch=switch, api=api)
    except (ValueError, RuntimeError) as error:
        print(f"::error::Runner pools: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
