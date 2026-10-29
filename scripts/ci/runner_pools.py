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

This script is the one writer. Each pass (ci-cloud-overflow-probe.yml's watch job, every 10
minutes, with the token the overflow switch already uses) it:

- reads which labels are dead: the queue janitor's snapshot (`dead_labels`, a label a job waited
  on past its bound while another member of its family started jobs) and the overflow probe (a
  label it waited on with no runner);
- marks them in RUNNER_POOLS' `_dead` (label -> when it was last seen dead). A mark expires after
  DEAD_TTL, and a started probe on that label clears it at once, so a pool returns to its first
  member once that member serves again;
- points each pool at its first member not marked dead. When every member is marked, the pool
  keeps its first member: a job then waits, and the janitor moves it when one recovers;
- writes RUNNER_POOLS only when something changed.

RUNNER_POOLS never names a reused machine: every member is an ephemeral Blacksmith label, so a
job reading it can never land on an owned Mac, whoever started it (a fork's pull request
included), and a signing job's pool is always ephemeral (signing_runner_variables.py). Owned Macs
come first through a picker's output (the routing order: owned Macs, then Blacksmith macOS),
never through a pool. A pool that must run GitHub-hosted (npm and PyPI provenance accept only
GitHub's OIDC) says `"hosted": true` with its reason; no other pool may name a GitHub-hosted label.

--check validates a RUNNER_POOLS value: every pool set, each to one of its own members.
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

ROOT = Path(__file__).resolve().parents[2]
RUNNERS = ROOT / ".github" / "runners.json"
VARIABLE = "RUNNER_POOLS"
DEAD_KEY = "_dead"
UPDATED_KEY = "_updated"
# A dead mark lasts this long unless seen again. The janitor sees a dead label again within about
# 13 minutes (3 minutes of waiting plus its 10-minute sweep), so a label that is still dead is
# marked again before its mark expires, and one that recovered is used again within half an hour.
DEAD_TTL = dt.timedelta(minutes=30)
UTC = dt.timezone.utc
EPHEMERAL = re.compile(r"^blacksmith-\d+vcpu-[a-z0-9.-]+$")
HOSTED = re.compile(r"^(?:ubuntu|macos|windows)(?:-[\w.-]+)?$")
KEY = re.compile(r"^[a-z][a-z0-9_]*$")


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


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


def parse_value(raw: str | None) -> dict[str, Any]:
    if not (raw or "").strip():
        return {}
    value = json.loads(str(raw))
    if not isinstance(value, dict):
        raise ValueError(f"{VARIABLE} is not a JSON object")
    return value


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


def dead_from_snapshot(snapshot: Mapping[str, Any] | None) -> set[str]:
    """Labels the janitor saw dead (dead_labels, cmux#27114)."""
    out: set[str] = set()
    for key in ("dead_labels",):
        for entry in (snapshot or {}).get(key) or ():
            label = entry.get("label") if isinstance(entry, Mapping) else None
            if isinstance(label, str):
                # A job's label set is joined with commas; every member of the set is a single label here.
                out |= {part.strip() for part in label.split(",") if part.strip()}
    return out


def reconcile(current: Mapping[str, Any], pools: Mapping[str, Mapping[str, Any]], *,
              dead_now: Iterable[str], served_now: Iterable[str], now: dt.datetime) -> tuple[dict[str, Any], list[str]]:
    """The next RUNNER_POOLS value and a line per change."""
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
            lines.append(f"{label}: the probe started a job there; it takes jobs again")
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
    try:
        current = parse_value(env.get(VARIABLE))
    except ValueError as error:
        print(f"::error title=Runner pools::{VARIABLE} is unreadable ({error}); the next pass rewrites it")
        current = {}
    if args.check:
        found = value_problems(current, pools)
        for problem in found:
            print(f"::error title=Runner pools::{problem}")
        return 1 if found else 0

    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    if api is None and env.get("GH_TOKEN") and repo:
        api = pr_runner_pool.GitHub(str(env["GH_TOKEN"]), repo)
    snapshot = None
    if api is not None:
        try:
            snapshot = api.snapshot(now=now)
        except Exception as error:  # noqa: BLE001 - a missing snapshot only means no janitor evidence
            print(f"::warning title=Runner pools::no janitor snapshot ({error}); judging on the probe alone")
    dead = dead_from_snapshot(snapshot)
    probe = (env.get("PROBE_LABEL") or "").strip()
    outcome = (env.get("PROBE_OUTCOME") or "").strip()
    served = set()
    if probe and outcome == "stalled":
        dead.add(probe)
    elif probe and outcome == "started":
        served.add(probe)
    value, lines = reconcile(current, pools, dead_now=dead, served_now=served, now=now)
    for line in lines:
        print(line)
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Runner pools\n\n" + ("\n".join(f"- {line}" for line in lines) or "- no change")
                         + "\n\n```json\n" + json.dumps(value, indent=2, sort_keys=True) + "\n```\n")
    if render(value) == render(current):
        print(f"{VARIABLE} unchanged")
        return 0
    if args.dry_run:
        print(f"{VARIABLE} would be {render(value)} (dry run)")
        return 0
    if switch is None and (env.get("SWITCH_TOKEN") or "").strip() and repo:
        import cloud_overflow_switch  # noqa: PLC0415 - its GitHub client writes variables
        switch = cloud_overflow_switch.GitHub(str(env["SWITCH_TOKEN"]).strip(), repo)
    if switch is None:
        print(f"::error title=Runner pools::no switch token (GLAEDA_ROUTE_APP_ID); {VARIABLE} stays "
              f"{render(current) or 'unset'}; it should be {render(value)}")
        return 1
    switch.set_variable(VARIABLE, render(value))
    print(f"{VARIABLE} = {render(value)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
