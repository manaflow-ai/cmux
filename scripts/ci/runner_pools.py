#!/usr/bin/env python3
"""Keep the RUNNER_POOLS repository variable pointed at a live member of each runner pool.

Leo, 2026-10-28: "Bro, I thought we already had logic to automatically route shit. How can we
still have pins like this? I hate pins. Like, just pin the set of the shit that isn't hilariously
slow." and "Where the fuck are the generalized solution to all these fucking problems that these
incessant fucking pins?"

One routing source. `.github/runners.json` declares each pool once (`pools`: a class of work and
its ordered members). The repository variable RUNNER_POOLS holds, for each pool, the member jobs
run on now, as one JSON object. A job writes

    runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux }}

and never a label of its own (tests/test_ci_runner_set.py). A picker's output still comes first
where a run needs its own choice (owned Macs, warm affinity); the pool is what follows it.

This script is the one writer, and it only chooses: each pass (ci-cloud-overflow-probe.yml's
watch job, every 10 minutes, with the token the overflow switch already uses) it

- reads per-label start evidence (label_evidence()):
  - the overflow probe's per-label health, CI_CLOUD_LABEL_HEALTH (`labels`: label -> "started"
    or "stalled"; the switch probes every linux pool member), read live through the API so it is this run's and not the job's start value;
    used while its `checked` is at most HEALTH_MAX_AGE old;
  - the queue janitor's snapshot (macos-pool-load), only while its `generated_at` is at most
    SNAPSHOT_MAX_AGE old: a Blacksmith label in `pools` whose oldest
    queued job has waited BLACKSMITH_STALL_MINUTES (simple_pool_picker.blacksmith_stalled(): on
    a first-in, first-out queue nothing started there since), and the dead-label entries
    (`dead_labels`, cmux#27114: `label` joined with "," and `live`, members that started jobs).
    The snapshot's `starved` and `unserved` describe owned (glaeda-*) labels, which are never
    pool members, so they are not read;
- marks dead labels in RUNNER_POOLS' `_dead` (label -> when last seen dead). A mark expires after
  DEAD_TTL unless seen again; evidence that the label started a job clears it at once;
- points each pool at its first member with no mark. With every member marked, the pool keeps
  its first member;
- writes RUNNER_POOLS only when something changed. A value that does not match the schema
  (parse_value()) is replaced from the declared defaults, never crashed on.

LINUX_RUNNER predates RUNNER_POOLS and most Linux runs-on still read it (`vars.LINUX_RUNNER || ...`),
so each pass also writes the linux pool's live member to it (MIRRORS, mirror_writes()) unless the
overflow switch's record is set, and --check fails while it names a label outside the pool.

Moving jobs already queued on a dead member is not done here: GitHub binds a job's label when it
creates the job, and the queue janitor's dead-label re-dispatch (cmux#27114) re-runs those jobs,
which then read the pool's new member.

RUNNER_POOLS never names a reused machine: every member is an ephemeral Blacksmith label, so a
job reading it can never land on an owned Mac, whoever started it (a fork's pull request
included). Owned Macs come first through a picker's output (the routing order: owned Macs, then
Blacksmith macOS), never through a pool, and signing jobs move through the signing picker. A pool
that must run GitHub-hosted (npm and PyPI provenance accept only GitHub's OIDC) says
`"hosted": true` with its reason; no other pool may name a GitHub-hosted label.

--check validates a RUNNER_POOLS value (every pool set, each to one of its own members) and the
MIRRORS variables (each a member of its pool while the overflow record is unset).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_runner_pool  # noqa: E402  (its GitHub client reads the janitor snapshot)
import simple_pool_picker  # noqa: E402  (the one Blacksmith stall rule)

ROOT = Path(__file__).resolve().parents[2]
RUNNERS = ROOT / ".github" / "runners.json"
VARIABLE = "RUNNER_POOLS"
# Written by the overflow switch every probe run (cloud_overflow_switch.HEALTH_VARIABLE, label_health()).
HEALTH_VARIABLE = "CI_CLOUD_LABEL_HEALTH"
# Variables older than RUNNER_POOLS that runs-on still read (`vars.LINUX_RUNNER || '<label>'`, about 250
# jobs over main and feat-cmux-next), each with the pool it follows. Nothing kept them live: on
# 2026-10-31 LINUX_RUNNER still held blacksmith-4vcpu-ubuntu-2404, a size outside the runner set that
# had stopped starting jobs, while RUNNER_POOLS.linux was blacksmith-32vcpu-ubuntu-2404; about 520
# jobs sat queued on it, the oldest for over an hour. Each pass now writes the pool's live member to
# them too (mirror_writes()), and --check fails while one names a label outside its pool.
MIRRORS = {"LINUX_RUNNER": "linux"}
# While the overflow switch's record is set, the switch owns those variables (cloud_overflow_switch.py).
OVERFLOW_RECORD = "CI_CLOUD_OVERFLOW_SAVED"
DEAD_KEY = "_dead"
UPDATED_KEY = "_updated"
# A dead mark lasts this long unless seen again. The probe runs every 10 minutes and the janitor
# sweeps about as often, so a label that is still dead is marked again before its mark expires,
# and one that recovered is used again within half an hour (or at once when it starts a job).
DEAD_TTL = dt.timedelta(minutes=30)
# Probe health older than this is from a run that did not finish; it decides nothing.
HEALTH_MAX_AGE = dt.timedelta(minutes=25)
# A janitor snapshot older than this (or undated, or from the future) decides nothing: the age the
# pool picker reads it at (pr_runner_pool.MAX_SNAPSHOT_MINUTES).
SNAPSHOT_MAX_AGE = dt.timedelta(minutes=pr_runner_pool.MAX_SNAPSHOT_MINUTES)
UTC = dt.timezone.utc
EPHEMERAL = re.compile(r"^blacksmith-\d+vcpu-[a-z0-9.-]+$")
HOSTED = re.compile(r"^(?:ubuntu|macos|windows)(?:-[\w.-]+)?$")
KEY = re.compile(r"^[a-z][a-z0-9_]*$")


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: object) -> dt.datetime | None:
    """An ISO 8601 time with a zone; None for anything else (a naive time included)."""
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo is not None else None


def load_pools(path: Path = RUNNERS) -> dict[str, dict[str, Any]]:
    pools = json.loads(path.read_text(encoding="utf-8"))["pools"]
    return {name: spec for name, spec in pools.items() if not name.startswith("$")}


def members(spec: Mapping[str, Any]) -> list[str]:
    return list(dict.fromkeys(spec["members"]))


def spec_problems(pools: Mapping[str, Mapping[str, Any]]) -> list[str]:
    """What is wrong with the declared pools (tests/test_ci_runner_pools.py)."""
    found = []
    for name, spec in pools.items():
        where = f"pools.{name}"
        if not KEY.match(name):
            found.append(f"{where}: a pool name is lower case with underscores, so fromJSON(...).{name} reads it")
        listed = spec.get("members")
        if not isinstance(listed, list) or not listed or not all(isinstance(m, str) and m for m in listed):
            found.append(f"{where}: members is a non-empty list of labels")
            continue
        if not str(spec.get("why", "")).strip():
            found.append(f"{where}: says why (what work it runs)")
        for member in listed:
            if HOSTED.match(member):
                if not spec.get("hosted"):
                    found.append(f"{where}: {member} is GitHub-hosted, which is not in the runner set")
            elif not EPHEMERAL.match(member):
                found.append(f"{where}: {member} is not an ephemeral Blacksmith label; owned Macs come only "
                             "through a picker, never a pool")
        if spec.get("hosted") and not str(spec.get("hosted_why", "")).strip():
            found.append(f"{where}: a hosted pool names why it cannot run on the set (hosted_why)")
    return found


def parse_value(raw: str | None, pools: Mapping[str, Mapping[str, Any]]) -> tuple[dict[str, Any], list[str]]:
    """The usable part of a RUNNER_POOLS value, and why any of it was dropped.

    A pool naming a label that is not its member, a `_dead` that is not an object of label ->
    zoned time, or a value that is not a JSON object is dropped, and reconcile() fills it again
    from the declared members: a malformed variable is repaired, never crashed on.
    """
    if not (raw or "").strip():
        return {}, []
    try:
        value = json.loads(str(raw))
    except ValueError as error:
        return {}, [f"{VARIABLE} is not JSON ({error}); rewriting it from .github/runners.json"]
    if not isinstance(value, dict):
        return {}, [f"{VARIABLE} is not a JSON object; rewriting it from .github/runners.json"]
    clean: dict[str, Any] = {}
    dropped: list[str] = []
    for name, spec in pools.items():
        if name not in value:
            continue
        if isinstance(value[name], str) and value[name] in members(spec):
            clean[name] = value[name]
        else:
            dropped.append(f"{VARIABLE}.{name}={value[name]!r} is not a member of pools.{name}; reset")
    marks = value.get(DEAD_KEY, {})
    if isinstance(marks, dict):
        good = {label: since for label, since in marks.items()
                if isinstance(label, str) and parse_time(since) is not None}
        if len(good) != len(marks):
            dropped.append(f"{VARIABLE}.{DEAD_KEY} holds entries that are not label -> zoned time; dropped")
        clean[DEAD_KEY] = good
    else:
        dropped.append(f"{VARIABLE}.{DEAD_KEY} is not an object; reset")
    if isinstance(value.get(UPDATED_KEY), str) and parse_time(value[UPDATED_KEY]) is not None:
        clean[UPDATED_KEY] = value[UPDATED_KEY]
    return clean, dropped


def value_problems(value: Mapping[str, Any], pools: Mapping[str, Mapping[str, Any]]) -> list[str]:
    """Why a RUNNER_POOLS value would misroute a job: a missing pool, or a label that is not its member."""
    found = []
    for name, spec in sorted(pools.items()):
        label = value.get(name)
        if not isinstance(label, str) or not label:
            found.append(f"{VARIABLE} has no {name}: every job reading fromJSON(vars.{VARIABLE}).{name} fails")
        elif label not in members(spec):
            found.append(f"{VARIABLE}.{name}={label!r} is not a member of pools.{name} "
                         f"({', '.join(spec['members'])})")
    return found


def mirror_writes(value: Mapping[str, Any], live: Mapping[str, str | None], *,
                  record: str | None) -> list[tuple[str, str]]:
    """(variable, label) for each MIRRORS variable that does not hold its pool's live member.

    Nothing while the overflow switch's record is set: the switch moved those variables and puts them
    back. A variable is moved only when it is unset or holds a Blacksmith label; any other value is a
    deliberate choice, left alone here and named by --check (mirror_problems()).
    """
    if (record or "").strip():
        return []
    writes = []
    for name, pool in MIRRORS.items():
        want = value.get(pool)
        current = (live.get(name) or "").strip()
        if not isinstance(want, str) or not want or current == want:
            continue
        if current and not EPHEMERAL.match(current):
            continue
        writes.append((name, want))
    return writes


def mirror_problems(live: Mapping[str, str | None], pools: Mapping[str, Mapping[str, Any]], *,
                    record: str | None) -> list[str]:
    """Why a MIRRORS variable misroutes its jobs: it names no member of its pool (overflow off)."""
    if (record or "").strip():
        return []
    found = []
    for name, pool in MIRRORS.items():
        current = (live.get(name) or "").strip()
        allowed = members(pools[pool]) if pool in pools else []
        if current not in allowed:
            found.append(f"{name}={current or 'unset'} is not a member of pools.{pool} ({', '.join(allowed)}): "
                         f"every `vars.{name} || ...` runs-on waits on it; runner_pools.py writes the live member")
    return found


def _labels(joined: object) -> set[str]:
    """A label set as the janitor writes it: joined with "," (dead_labels) or "+" (fleet keys)."""
    if not isinstance(joined, str):
        return set()
    return {part.strip() for part in re.split(r"[,+]", joined) if part.strip()}


def label_evidence(health: Mapping[str, Any] | None, snapshot: Mapping[str, Any] | None, *,
                   now: dt.datetime) -> tuple[set[str], set[str], list[str]]:
    """(dead, started, notes): the labels seen starting nothing, the labels seen starting a job."""
    dead: set[str] = set()
    started: set[str] = set()
    notes: list[str] = []
    if isinstance(health, Mapping):
        checked = parse_time(health.get("checked"))
        labels = health.get("labels")
        if checked is None or not isinstance(labels, Mapping):
            notes.append(f"{HEALTH_VARIABLE} is unreadable; no probe evidence")
        elif not (dt.timedelta(minutes=-1) <= now - checked <= HEALTH_MAX_AGE):
            notes.append(f"{HEALTH_VARIABLE} is from {iso(checked)}, outside the last {HEALTH_MAX_AGE}; no probe evidence")
        else:
            for label, state in labels.items():
                if state == "stalled":
                    dead.add(str(label))
                elif state == "started":
                    started.add(str(label))
    generated = parse_time(snapshot.get("generated_at")) if isinstance(snapshot, Mapping) else None
    if isinstance(snapshot, Mapping) and generated is None:
        notes.append("the janitor snapshot has no readable generated_at; no snapshot evidence")
    elif generated is not None and not (dt.timedelta(minutes=-1) <= now - generated <= SNAPSHOT_MAX_AGE):
        notes.append(f"the janitor snapshot is from {iso(generated)}, outside the last {SNAPSHOT_MAX_AGE}; "
                     "no snapshot evidence")
    elif generated is not None and pr_runner_pool.snapshot_truncated(snapshot):
        notes.append(f"{pr_runner_pool.snapshot_truncated(snapshot)}; no snapshot evidence")
    elif generated is not None:
        age = max(0.0, (now - generated).total_seconds() / 60)
        for label, load in (snapshot.get("pools") or {}).items():
            if not (isinstance(label, str) and EPHEMERAL.match(label) and isinstance(load, Mapping)):
                continue
            try:
                queued = int(load.get("queued") or 0)
                oldest = float(load.get("oldest_queued_minutes") or 0)
            except (TypeError, ValueError):
                continue
            if simple_pool_picker.blacksmith_stalled(queued, oldest + age):
                dead.add(label)
        for entry in snapshot.get("dead_labels") or ():
            if isinstance(entry, Mapping):
                dead |= _labels(entry.get("label"))
                live = entry.get("live")
                if isinstance(live, list):
                    started |= {str(label) for label in live if isinstance(label, str)}
    # A label both started and stalled in one pass (two probes, or a probe and a stale queue) started.
    return dead - started, started, notes


def reconcile(current: Mapping[str, Any], pools: Mapping[str, Mapping[str, Any]], *,
              dead_now: Iterable[str], served_now: Iterable[str], now: dt.datetime) -> tuple[dict[str, Any], list[str]]:
    """The next RUNNER_POOLS value and a line per change. `current` is parse_value()'s output."""
    lines: list[str] = []
    marks: dict[str, str] = {}
    for label, since in (current.get(DEAD_KEY) or {}).items():
        seen = parse_time(since)
        if seen is not None and now - seen < DEAD_TTL:
            marks[label] = since
        else:
            lines.append(f"{label}: dead mark expired; it may take jobs again")
    for label in sorted(set(served_now)):
        if marks.pop(label, None):
            lines.append(f"{label}: started a job; it takes jobs again")
    for label in sorted(set(dead_now)):
        if label not in marks:
            lines.append(f"{label}: dead (no job started there while one waited)")
        marks[label] = iso(now)
    known = {label for spec in pools.values() for label in members(spec)}
    marks = {label: since for label, since in marks.items() if label in known}
    value: dict[str, Any] = {}
    for name, spec in sorted(pools.items()):
        candidates = members(spec)
        chosen = next((label for label in candidates if label not in marks), candidates[0])
        if current.get(name) != chosen:
            lines.append(f"pools.{name}: {current.get(name) or 'unset'} -> {chosen}")
        value[name] = chosen
    value[DEAD_KEY] = dict(sorted(marks.items()))
    comparable = {key: current.get(key) for key in value}
    if comparable != value or UPDATED_KEY not in current:
        value[UPDATED_KEY] = iso(now)
    else:
        value[UPDATED_KEY] = current[UPDATED_KEY]
    return value, lines


def render(value: Mapping[str, Any]) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _health(switch: Any, env: Mapping[str, str]) -> Mapping[str, Any] | None:
    """The probe's per-label health: live through the API when a client can read it, else the job's env."""
    raw = None
    if switch is not None and hasattr(switch, "get_variable"):
        try:
            raw = switch.get_variable(HEALTH_VARIABLE)
        except Exception as error:  # noqa: BLE001 - missing health only means no probe evidence
            print(f"::warning title=Runner pools::could not read {HEALTH_VARIABLE} ({error}); using the job's value")
    if raw is None:
        raw = env.get(HEALTH_VARIABLE)
    try:
        value = json.loads(raw) if (raw or "").strip() else None
    except ValueError:
        value = None
    return value if isinstance(value, Mapping) else None


class Variables:
    """Read and write repository variables with the switch's token (cloud_overflow_switch.GitHub)."""

    def __init__(self, token: str, repo: str) -> None:
        import cloud_overflow_switch  # noqa: PLC0415 - its client already writes variables
        self.client = cloud_overflow_switch.GitHub(token, repo)

    def get_variable(self, name: str) -> str | None:
        try:
            return str(self.client.request("GET", f"/actions/variables/{name}").get("value"))
        except RuntimeError as error:
            if "(404)" in str(error):
                return None
            raise

    def set_variable(self, name: str, value: str) -> None:
        self.client.set_variable(name, value)


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, *,
         api: Any = None, switch: Any = None, now: dt.datetime | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="validate the live RUNNER_POOLS and exit")
    parser.add_argument("--dry-run", action="store_true",
                        default=(env.get("DRY_RUN", "").strip().lower() in {"1", "true", "yes"}))
    args = parser.parse_args(argv)
    now = now or dt.datetime.now(UTC)
    pools = load_pools()
    problems = spec_problems(pools)
    if problems:
        for problem in problems:
            print(f"::error title=Runner pools::{problem}")
        return 1
    current, dropped = parse_value(env.get(VARIABLE), pools)
    if args.check:
        mirrored = {name: env.get(name) for name in MIRRORS}
        found = dropped + value_problems(current, pools) + mirror_problems(
            mirrored, pools, record=env.get(OVERFLOW_RECORD))
        for problem in found:
            print(f"::error title=Runner pools::{problem}")
        return 1 if found else 0
    for note in dropped:
        print(f"::warning title=Runner pools::{note}")

    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    if switch is None and (env.get("SWITCH_TOKEN") or "").strip() and repo:
        switch = Variables(str(env["SWITCH_TOKEN"]).strip(), repo)
    if api is None and env.get("GH_TOKEN") and repo:
        api = pr_runner_pool.GitHub(str(env["GH_TOKEN"]), repo)
    snapshot = None
    if api is not None:
        try:
            snapshot = api.snapshot(now=now)
        except Exception as error:  # noqa: BLE001 - a missing snapshot only means no janitor evidence
            print(f"::warning title=Runner pools::no janitor snapshot ({error}); judging on the probe alone")
    dead, started, notes = label_evidence(_health(switch, env), snapshot, now=now)
    for note in notes:
        print(note)
    value, lines = reconcile(current, pools, dead_now=dead, served_now=started, now=now)
    for line in lines:
        print(line)
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Runner pools\n\n" + ("\n".join(f"- {line}" for line in lines) or "- no change")
                         + "\n\n```json\n" + json.dumps(value, indent=2, sort_keys=True) + "\n```\n")
    writes: list[tuple[str, str]] = []
    if render(value) == (env.get(VARIABLE) or "").strip():
        print(f"{VARIABLE} unchanged")
    else:
        writes.append((VARIABLE, render(value)))
    # The mirrored variables and the switch's record, read live: the switch step just before this one
    # may have moved them, so the job-start values could undo its failover.
    live, record, readable = _live(switch, env)
    if readable:
        writes += mirror_writes(value, live, record=record)
    if not writes:
        return 0
    if args.dry_run:
        for name, raw in writes:
            print(f"{name} would be {raw} (dry run)")
        return 0
    if switch is None:
        for name, raw in writes:
            print(f"::error title=Runner pools::no switch token (GLAEDA_ROUTE_APP_ID); {name} stays "
                  f"{env.get(name) or 'unset'}; it should be {raw}")
        return 1
    for name, raw in writes:
        switch.set_variable(name, raw)
        print(f"{name} = {raw}")
    return 0


def _live(switch: Any, env: Mapping[str, str]) -> tuple[dict[str, str | None], str | None, bool]:
    """(MIRRORS values, the overflow record, whether they were read) through the API, else the job's env."""
    names = (*MIRRORS, OVERFLOW_RECORD)
    if switch is not None and hasattr(switch, "get_variable"):
        try:
            got = {name: switch.get_variable(name) for name in names}
        except Exception as error:  # noqa: BLE001 - an unread variable is never overwritten on a guess
            print(f"::warning title=Runner pools::could not read {', '.join(names)} ({error}); not moving them")
            return {}, None, False
    else:
        # A step that does not hand them in has not read them: unset is not the same as unknown.
        if any(name not in env for name in names):
            return {}, None, False
        got = {name: env.get(name) for name in names}
    record = got.pop(OVERFLOW_RECORD)
    return got, record, True


if __name__ == "__main__":
    sys.exit(main())
