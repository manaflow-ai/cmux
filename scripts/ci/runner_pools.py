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
    or "stalled"; the switch probes every x64 Linux size a pool can point at, cloud_overflow_switch.HEALTH_LABELS),
    read live through the API so it is this run's and not the job's start value;
    used while its `checked` is at most HEALTH_MAX_AGE old. A "stalled" counts only beside a fresh, complete
    janitor snapshot (below), which tells a dead size from one the vCPU cap keeps full; without one a stall
    adds no mark (2026-11-18 11:37Z: a 403 snapshot read and four sizes falsely marked dead);
  - the queue janitor's snapshot (macos-pool-load), only while its `generated_at` is at most
    SNAPSHOT_MAX_AGE old: a Blacksmith label in `pools` whose oldest
    queued job has waited BLACKSMITH_STALL_MINUTES (simple_pool_picker.blacksmith_stalled()) while
    nothing runs there and `label_started` shows no start since that job began to wait
    (started_nothing_while_queued(): the queue is not first in, first out, so the wait alone
    proves nothing), and the dead-label entries
    (`dead_labels`, cmux#27114: `label` joined with "," and `live`, members that started jobs).
    The snapshot's `starved` and `unserved` describe owned (glaeda-*) labels, which are never
    pool members, so they are not read;
  - a label whose `label_started` is within RECENT_START is serving and never dead, whatever the
    probe saw (recently_started()): under Blacksmith's org vCPU cap a probe can wait out its
    minutes on a size that keeps starting jobs. This holds for a truncated snapshot too (the queue
    outgrew one sweep): its queue counts are partial and decide nothing, but its starts are starts;
- marks dead labels in RUNNER_POOLS' `_dead` (label -> when last seen dead). A mark expires after
  DEAD_TTL unless seen again; evidence that the label started a job clears it at once. A mark expires
  only on a pass whose evidence covers its label (evidence_covers()): the probe's health for the sizes
  it probes, the janitor's snapshot for the rest. Unknown stays unknown: in watch run 41279880300
  (2026-11-01 06:12-06:23Z) every read returned 403, the marks expired with no evidence at all, and
  the linux pool went from 16 back to the stalled 32 vCPU size;
- remembers in `_served` (label -> when first seen) each owned Mac fleet Linux VM label (OWNED_EPHEMERAL_LINUX) the
  evidence above saw start a job, and passes over such a label until it has: its runners are one-job scale-set
  clones that register only when a job is handed to them, so with no reader queued there nothing ever marked it dead
  and the pool led with a label no runner had ever taken (2026-11-22 ~07:26Z, linux_owned_small on
  glaeda-linux-arm64; unproven());
- points each pool at its first member with no mark. With every member marked it keeps its first member: a pool
  never names a label outside its declared members (allowed()). A release valve to the next smaller size
  (cmux#45852) sent linux_16 and linux_8 to 2 vCPU on 2026-11-18 from 13:18Z, where cmux-tui's thin legs took
  25-44 min instead of 2-8 and 7 aarch64 legs failed with rustc OOM (job 134837837144). A Blacksmith
  Linux pool lists its smaller sizes before its larger ones (grows_before_shrinking(), checked by
  spec_problems()), so a size stalled by the org's vCPU cap moves its jobs down, never up into the sizes the
  cap starves first;
- writes RUNNER_POOLS only when something changed. A value that does not match the schema
  (parse_value()) is replaced from the declared defaults, never crashed on.

LINUX_RUNNER predates RUNNER_POOLS and most Linux runs-on still read it (`vars.LINUX_RUNNER || ...`),
so each pass also writes the linux pool's live member to it (MIRRORS, mirror_writes()) unless the
overflow switch's record names it among the variables it changed, and --check fails while it names a
label outside the pool.

Other variables hold one raw Blacksmith Linux label that runs-on reads ahead of a pool (RAW_LABEL_VARS:
LINUX_BUILD_RUNNER, LINUX_RUNNER_DARWIN_CROSS, CI_TRUSTED_RUNNER, ...). Each pass moves one that names a `_dead`
label to the nearest live size of the same image, records the label it left in RUNNER_POOLS' `_raw_home`, and
moves it back once that label leaves `_dead` (raw_homes(), raw_writes()); each move is a workflow warning. A value
that is not a Blacksmith Linux pool label is left alone.

Moving jobs already queued on a dead member is not done here: GitHub binds a job's label when it
creates the job. The queue janitor reports dead labels (cmux#27114) but re-runs nothing for a pool
that starts no job at all, so on 2026-11-18 runs queued on dead 4, 8 and 16 vCPU waited hours.
The watch's next step, `cloud_overflow_switch.py --rescue-dead`, force-cancels and re-runs those
runs once (dead_labels() there), and they then read the pool's new member.

Every member is a Blacksmith label or, as a pool's first member only, an owned Linux label: one of the owned Mac
fleet's Linux VM labels (OWNED_EPHEMERAL_LINUX: one job per fresh VM clone, so it is ephemeral too), or, for an x64
pool not marked `"ephemeral_only": true`, the owned GCP pool's label (OWNED_GCP_LINUX), which Blacksmith's runners
never take, so those pools run on our machines and Blacksmith is only their overflow. A job reading a pool can never
land on an owned Mac, whoever started it; a job that needs a fresh machine (secrets, write tokens, a fork's pull
request) reads an ephemeral_only pool (linux_4) or sends a fork's pull request to a Blacksmith label before it.
An owned Linux member is a small fleet: once its oldest queued job has waited BLACKSMITH_STALL_MINUTES, running or
not, it is marked dead (label_evidence()) and the pool takes its Blacksmith members until that queue drains. Owned Macs come first through a picker's output (the routing order: owned Macs, then
Blacksmith macOS), never through a pool, and signing jobs move through the signing picker. A pool
that must run GitHub-hosted (npm and PyPI provenance accept only GitHub's OIDC) says
`"hosted": true` with its reason; no other pool may name a GitHub-hosted label.

--check validates a RUNNER_POOLS value (every pool set, each to one of its own members) and the
MIRRORS variables (each a member of its pool unless the overflow record changed it).
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
# The persistent Linux pool's labels (cmux-runner-pool VMs; signing_runner_variables.SIGNING_ISOLATION_DEFERRED).
PERSISTENT_LINUX_POOL_LABELS = frozenset({"cmux-fleet-linux-x64", "cmux-linux"})
# Variables that hold one raw Blacksmith Linux label and that runs-on reads ahead of a Linux pool or literal
# (`vars.X || ... fromJSON(vars.RUNNER_POOLS).linux_16`, `vars.X || 'blacksmith-...-ubuntu-2404'`), on main or
# feat-cmux-next. They follow no pool, so moving a pool off a dead label left them on it: on 2026-11-18
# LINUX_BUILD_RUNNER and LINUX_RUNNER_DARWIN_CROSS still named blacksmith-32vcpu-ubuntu-2404 (dead since 23:11Z the
# day before) until they were moved by hand at 04:40Z, with about 1,706 jobs queued there that never started. Each
# pass moves such a variable off a label `_dead` names to the nearest live size of its image (raw_substitute()),
# keeps where it came from in RUNNER_POOLS' `_raw_home`, and moves it back once that label leaves `_dead`
# (raw_homes(), raw_writes()). A value that is no Blacksmith Linux pool label (an owned runner, a hosted label,
# unset) is never touched. tests/test_ci_runner_pools.py fails when a main workflow reads another variable that way.
# macOS variables are never here: macOS moves through its pickers and the overflow switch.
RAW_LABEL_VARS = (
    "CI_CLASSIC_NIGHTLY_MINI",
    "CI_COMPILE_CHECK_GATEWAY",
    "CI_CONTROL_RUNNER",
    "CI_LINUX_GATE_OWNED_RUNNER",
    "CI_NIGHTLY_NEXT_BUILD_RUNNER",
    "CI_TEST_COMPILE_GATEWAY",
    "CI_TRUSTED_RUNNER",
    "LINUX_ARM64_RUNNER",
    "LINUX_BUILD_RUNNER",
    "LINUX_RUNNER_DARWIN_CROSS",
)
RAW_HOME_KEY = "_raw_home"
# The smallest size a RAW_LABEL_VARS variable may move to (memory_floor()): the cmux-tui tree build's fat-LTO legs
# (cmux-tui-build-package.yml plan-build) were SIGKILLed out of memory on 4 and 2 vCPU on 2026-11-18.
RAW_LABEL_MIN_VCPU = {"LINUX_BUILD_RUNNER": 8, "LINUX_RUNNER_DARWIN_CROSS": 8}
BLACKSMITH_LINUX = re.compile(r"^blacksmith-(\d+)vcpu-(ubuntu-[a-z0-9.-]+)$")
# While the overflow switch's record is set, the switch owns those variables (cloud_overflow_switch.py).
OVERFLOW_RECORD = "CI_CLOUD_OVERFLOW_SAVED"
DEAD_KEY = "_dead"
# The queue janitor snapshot's map of label -> when a runner last took a job asking for it
# (queue_janitor.LABEL_STARTED_KEY).
LABEL_STARTED_KEY = "label_started"
UPDATED_KEY = "_updated"
# Owned Mac fleet Linux VM labels seen starting a job at least once: label -> when first seen (unproven()).
SERVED_KEY = "_served"
# A label the janitor's `label_started` shows starting a job this recently is serving, whatever a probe saw: it is
# never marked dead, and a mark on it clears (label_evidence()). Blacksmith caps the org on vCPUs at once, so under
# load a probe can wait out its PROBE_MINUTES on a size that keeps starting jobs: at 02:00:26Z on 2026-11-18
# RUNNER_POOLS marked blacksmith-4vcpu-ubuntu-2404 dead while it had completed 11 jobs and ran 6 since 01:05Z.
RECENT_START = dt.timedelta(minutes=15)
LINUX_SIZE = re.compile(r"^blacksmith-(\d+)vcpu-(ubuntu-\d+(?:-arm)?)$")
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
# The owned Mac fleet's Linux VM labels a pool may lead with (pr_runner_pool.OWNED_EPHEMERAL_LINUX): each runner
# there is a just-in-time runner on a fresh VM clone that takes one job and is discarded, so the ephemeral property
# every pool member needs holds. Named one by one, never a pattern, and only as a pool's first member with a
# Blacksmith member after it (spec_problems()): the fleet is small (one clone per mini at first), so its pool
# overflows to Blacksmith once its queue waits (label_evidence()). Leo, 2026-11-19: "dont we have linux vms set up
# on everybody yet? we shuold" ... "on the fleet".
OWNED_EPHEMERAL_LINUX = frozenset(pr_runner_pool.OWNED_EPHEMERAL_LINUX)


def owned_ephemeral(label: object) -> bool:
    """One of the owned Mac fleet's Linux VM labels (OWNED_EPHEMERAL_LINUX)."""
    return isinstance(label, str) and label in OWNED_EPHEMERAL_LINUX


# The owned GCP Linux pool's label (pr_runner_pool.OWNED_GCP_LINUX). Blacksmith's runners never take it, so an x64
# pool led by it runs on our machines until its queue waits the stall cutoff, then overflows to its Blacksmith
# members (label_evidence(), as for OWNED_EPHEMERAL_LINUX). The persistent pool's runners carry it too, so a pool whose
# jobs need a fresh machine (`"ephemeral_only": true`: secret-bearing and write-token jobs, a fork's pull request,
# the nightly promotion) never leads with it (spec_problems()). Leo, 2026-11-21: "i just am like fundamentally
# opposed to paying for ci when i exist".
OWNED_GCP_LINUX = frozenset(pr_runner_pool.OWNED_GCP_LINUX)


def owned_gcp(label: object) -> bool:
    """The owned GCP Linux pool's label (OWNED_GCP_LINUX)."""
    return isinstance(label, str) and label in OWNED_GCP_LINUX


# The Freestyle Linux rung's label (pr_runner_pool.OWNED_FREESTYLE_LINUX): an 8 vCPU Freestyle VM per queued
# same-repository job. Blacksmith's runners never take it. It follows the owned GCP lead in an x64 pool whose jobs
# need no fresh machine and fit 8 vCPU, with a Blacksmith x64 member after both (spec_problems()): a full GCP pool
# moves to Freestyle, and a full Freestyle rung moves to Blacksmith (label_evidence()'s full mark). GCP and
# Freestyle form the pool's owned prefix in either order, each at most once; .github/runners.json puts GCP first
# because the same jobs took 9.4 min a run on Freestyle against 5.0 on GCP (2026-11-25/26, its linux pool's why). Leo, 2026-11-19: "We still keep
# Blacksmith sometimes, but stop fucking relying on it. We can't rely on it. [...] I don't know why you guys are
# fixated on GCP when we literally have the partnership with Freestyle. We could use Freestyle. [...] So we should
# just be able to size them accordingly."
OWNED_FREESTYLE_LINUX = frozenset(pr_runner_pool.OWNED_FREESTYLE_LINUX)


def owned_freestyle(label: object) -> bool:
    """The Freestyle Linux rung's label (OWNED_FREESTYLE_LINUX)."""
    return isinstance(label, str) and label in OWNED_FREESTYLE_LINUX


def owned_lead(label: object) -> bool:
    """An owned Linux label a pool may lead with: the Mac fleet's VMs (owned_ephemeral()), the Freestyle rung
    (owned_freestyle()) or the GCP pool (owned_gcp()), the last two in either order. None has a size or is probed; a full one overflows."""
    return owned_ephemeral(label) or owned_gcp(label) or owned_freestyle(label)


def owned_prefix(listed: Sequence[object]) -> list[str]:
    """A pool's leading owned x64 members (the GCP lead, the Freestyle rung), which the outage override keeps first."""
    lead: list[str] = []
    for member in listed:
        if not (owned_gcp(member) or owned_freestyle(member)):
            break
        lead.append(str(member))
    return lead


KEY = re.compile(r"^[a-z][a-z0-9_]*$")
# The retired outage override. cmux#45710 (2026-11-17) let CI_LINUX_HOSTED_RUNNER put GitHub-hosted Ubuntu first in
# every x64 Linux pool during a Blacksmith outage. It stayed set: on 2026-11-19 14:00-20:10Z about 2,470 cmux jobs ran on
# GitHub-hosted runners (the timing feed), median queue about 5.9 h. Leo, 2026-11-19: "Like, why the
# f*** do you keep having the f***ing GitHub hosted runners? F*** GitHub." No pool leads with a GitHub-hosted label
# any more: the variable is ignored when routing, and `--check` (ci-repo-variables.yml, every 15 minutes) fails while
# it is set, so a stale one is red within the quarter hour. Outage capacity is an owned rung (GCP lane runners,
# Freestyle, the Mac Linux VMs) declared as a pool member, never GitHub.
HOSTED_OVERRIDE = "CI_LINUX_HOSTED_RUNNER"
X64_UBUNTU = re.compile(r"^blacksmith-\d+vcpu-ubuntu-\d+$")


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


def load_pools(path: Path = RUNNERS, env: Mapping[str, str] | None = None) -> dict[str, dict[str, Any]]:
    """The declared pools. `env` is accepted for older callers and changes nothing: no variable adds a member."""
    del env
    pools = json.loads(path.read_text(encoding="utf-8"))["pools"]
    return {name: spec for name, spec in pools.items() if not name.startswith("$")}


def members(spec: Mapping[str, Any]) -> list[str]:
    return list(dict.fromkeys(spec["members"]))


X64_SIZE = re.compile(r"^blacksmith-(\d+)vcpu-(ubuntu-\d+)$")


# A pool whose first member is this large runs memory-bound work (fat-LTO release compiles, large suites) and
# declares min_vcpu, the smallest size its jobs fit in (spec_problems()).
MEMORY_FLOOR_REQUIRED_FROM = 16


def memory_floor(spec: Mapping[str, Any]) -> int:
    """The smallest x64 size, in vCPU, a pool's jobs fit in (its `min_vcpu`), else 0: no floor.

    Blacksmith gives 4 GB per vCPU, so the size is also the memory. On 2026-11-18 the release valve moved linux_16
    (the fat-LTO cmux-tui release compile, cmux-tui-build-package.yml) to 4 and then 2 vCPU: rustc on acpmux was
    SIGKILLed out of memory (run 44289517882, jobs 134784646044 and 134784646088 on blacksmith-4vcpu-ubuntu-2404),
    the next 12 feat-cmux-next tree builds failed the same way on 2 vCPU, no tree published, and NEXT nightlies
    44293483500 and 44283774674 failed at "Bundle the cmux-tui client". A job waiting for a size it fits in is late;
    one sent below it is certain to fail."""
    value = spec.get("min_vcpu", 0)
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else 0


def allowed(spec: Mapping[str, Any], pools: Mapping[str, Mapping[str, Any]]) -> list[str]:
    """Every label RUNNER_POOLS may hold for a pool: its declared members, nothing else. A size outside them may be
    too small for the pool's jobs: a busy size makes a job slower, a too-small one makes it fail (rustc OOM on
    2 vCPU, 2026-11-18)."""
    return members(spec)


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
            elif owned_ephemeral(member):
                if member != listed[0] or not any(EPHEMERAL.match(other) for other in listed[1:]):
                    found.append(f"{where}: {member} is an owned Linux VM label; it may only lead a pool, with a "
                                 "Blacksmith member after it to overflow to (OWNED_EPHEMERAL_LINUX)")
            elif owned_gcp(member):
                at = listed.index(member)
                if not all(owned_freestyle(other) for other in listed[:at]) \
                        or not any(X64_SIZE.match(other) for other in listed[at + 1:]):
                    found.append(f"{where}: {member} is the owned GCP Linux label; it may only lead an x64 pool or "
                                 "follow its Freestyle lead, with a Blacksmith x64 member after it to overflow to "
                                 "(OWNED_GCP_LINUX)")
                if spec.get("ephemeral_only"):
                    found.append(f"{where}: {member} is the owned GCP Linux label, whose persistent runners take it "
                                 "too; an ephemeral_only pool's jobs need a fresh machine (OWNED_GCP_LINUX)")
            elif owned_freestyle(member):
                at = listed.index(member)
                if not all(owned_gcp(other) for other in listed[:at]) \
                        or not any(X64_SIZE.match(other) for other in listed[at + 1:]):
                    found.append(f"{where}: {member} is the Freestyle Linux label; it may only lead an x64 pool or "
                                 "follow its owned GCP lead, with a Blacksmith x64 member after it to overflow to "
                                 "(OWNED_FREESTYLE_LINUX)")
                if spec.get("ephemeral_only"):
                    found.append(f"{where}: {member} is the Freestyle Linux label, whose VMs keep their disk between "
                                 "jobs; an ephemeral_only pool's jobs need a fresh machine (OWNED_FREESTYLE_LINUX)")
            elif not EPHEMERAL.match(member):
                found.append(f"{where}: {member} is not an ephemeral Blacksmith label; owned Macs come only "
                             "through a picker, never a pool")
        least = memory_floor(spec)
        if "min_vcpu" in spec and not least:
            found.append(f"{where}: min_vcpu is a positive whole number of vCPU")
        first = X64_SIZE.match(listed[0])
        if first and int(first.group(1)) >= MEMORY_FLOOR_REQUIRED_FROM and not least:
            found.append(f"{where}: a pool led by {first.group(1)} vCPU declares min_vcpu, the smallest size its jobs fit "
                         "in, so nothing sends them below it (memory_floor())")
        for member in listed:
            size = X64_SIZE.match(member)
            if least and size and int(size.group(1)) < least:
                found.append(f"{where}: {member} is below its min_vcpu ({least}); the pool's jobs do not fit there")
        if "ephemeral_only" in spec and not isinstance(spec["ephemeral_only"], bool):
            found.append(f"{where}: ephemeral_only is true or false")
        if spec.get("hosted") and not str(spec.get("hosted_why", "")).strip():
            found.append(f"{where}: a hosted pool names why it cannot run on the set (hosted_why)")
        grows = grows_before_shrinking([member for member in listed if not owned_lead(member)])
        if grows:
            found.append(f"{where}: lists {grows} after a larger failover or out of size order; Blacksmith caps the org on vCPUs at "
                         "once, so a stalled size moves down first (list smaller sizes, largest first, before larger)")
    return found


def grows_before_shrinking(listed: Sequence[str]) -> str | None:
    """The member out of order in a Blacksmith Linux pool's failovers, else None.

    Blacksmith caps the org on vCPUs running at once, not per size, so when one size queues while the others start
    the cap is what binds, and moving its jobs to a bigger size fills the cap faster: on 2026-11-17 (00:00-00:48Z)
    32 vCPU started 1 of 282 jobs, 16 vCPU 5 of 63 and 4 vCPU 47 of 209, while linux_16 failed over to 32 vCPU. So a
    pool's failovers go down in size first (the largest smaller size first), and only then up."""
    sizes = [LINUX_SIZE.match(label) for label in listed]
    if len(listed) < 2 or not all(sizes) or len({match.group(2) for match in sizes}) != 1:
        return None
    first = int(sizes[0].group(1))
    larger_seen: str | None = None
    previous = first
    for label, match in zip(listed[1:], sizes[1:]):
        size = int(match.group(1))
        if size > first:
            larger_seen = larger_seen or label
        elif larger_seen is not None or size > previous:
            return label
        else:
            previous = size
    return None


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
        if isinstance(value[name], str) and value[name] in allowed(spec, pools):
            clean[name] = value[name]
        else:
            dropped.append(f"{VARIABLE}.{name}={value[name]!r} is not a member of "
                           f"pools.{name}; reset")
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
    served = value.get(SERVED_KEY)
    if served is not None:
        good = {label: since for label, since in (served.items() if isinstance(served, dict) else ())
                if owned_ephemeral(label) and parse_time(since) is not None}
        if not isinstance(served, dict) or len(good) != len(served):
            dropped.append(f"{VARIABLE}.{SERVED_KEY} holds entries that are not owned Linux VM label -> zoned time; "
                           "dropped")
        if good:
            clean[SERVED_KEY] = dict(sorted(good.items()))
    homes = value.get(RAW_HOME_KEY)
    if homes is not None:
        good = {name: {"home": entry["home"], "to": entry["to"]}
                for name, entry in (homes.items() if isinstance(homes, dict) else ())
                if name in RAW_LABEL_VARS and isinstance(entry, dict)
                and all(isinstance(entry.get(key), str) and BLACKSMITH_LINUX.match(entry[key])
                        for key in ("home", "to"))}
        if not isinstance(homes, dict) or len(good) != len(homes):
            dropped.append(f"{VARIABLE}.{RAW_HOME_KEY} holds entries that are not VARIABLE -> "
                           "{home, to} Blacksmith Linux labels; dropped")
        if good:
            clean[RAW_HOME_KEY] = dict(sorted(good.items()))
    return clean, dropped


def value_problems(value: Mapping[str, Any], pools: Mapping[str, Mapping[str, Any]]) -> list[str]:
    """Why a RUNNER_POOLS value would misroute a job: a missing pool, or a label that is not one of its declared
    members (allowed())."""
    found = []
    for name, spec in sorted(pools.items()):
        label = value.get(name)
        if not isinstance(label, str) or not label:
            found.append(f"{VARIABLE} has no {name}: every job reading fromJSON(vars.{VARIABLE}).{name} fails")
        elif label not in allowed(spec, pools):
            found.append(f"{VARIABLE}.{name}={label!r} is not a member of pools.{name} "
                         f"({', '.join(allowed(spec, pools))})")
    return found


def switch_owned(record: str | None) -> frozenset[str] | None:
    """The MIRRORS variables the overflow switch's record says it changed (and so puts back), or None for all.

    No record: none. A record whose `changed` cannot be read: all of them, as before, so an unreadable
    record never lets this script race the switch. Otherwise only the variables `changed` names. On
    2026-11-01 the record (set 04:23Z) changed only macOS variables, yet any record stopped the mirror,
    so LINUX_RUNNER stayed on blacksmith-32vcpu-ubuntu-2404 after RUNNER_POOLS marked it dead at 05:30Z
    and moved the linux pool to 16 vCPU; about 1,900 jobs sat queued on the dead size.
    """
    if not (record or "").strip():
        return frozenset()
    try:
        changed = json.loads(str(record)).get("changed")
    except (ValueError, AttributeError):
        return None
    if not isinstance(changed, dict):
        return None
    return frozenset(name for name in (*MIRRORS, *RAW_LABEL_VARS) if name in changed)


def mirror_target(value: Mapping[str, Any], pools: Mapping[str, Mapping[str, Any]] | None, pool: str) -> str | None:
    """The label a MIRRORS variable takes for `pool`: its live member, or while that is an owned lead (owned_lead()),
    its first Blacksmith member with no dead mark (else its first Blacksmith member).

    About 250 runs-on read `vars.LINUX_RUNNER || ...` with no fork or fresh-machine check of their own (release and
    write-token jobs among them), so the variable stays on a Blacksmith label while the pool itself leads with ours."""
    want = value.get(pool)
    if not owned_lead(want):
        return want if isinstance(want, str) else None
    if not pools or pool not in pools:
        return None
    dead = set(value.get(DEAD_KEY) or {})
    paid = [label for label in members(pools[pool]) if not owned_lead(label)]
    return next((label for label in paid if label not in dead), next(iter(paid), None))


def mirror_writes(value: Mapping[str, Any], live: Mapping[str, str | None], *,
                  record: str | None, pools: Mapping[str, Mapping[str, Any]] | None = None) -> list[tuple[str, str]]:
    """(variable, label) for each MIRRORS variable that does not hold its pool's live member.

    Not a variable the overflow switch's record changed (switch_owned()): the switch moved it and puts
    it back. A variable is moved only when it is unset or holds a Blacksmith or GitHub-hosted label; any other value is
    a deliberate choice, left alone here and named by --check (mirror_problems()).
    """
    owned = switch_owned(record)
    if owned is None:
        return []
    writes = []
    for name, pool in MIRRORS.items():
        if name in owned:
            continue
        want = mirror_target(value, pools, pool)
        current = (live.get(name) or "").strip()
        if not isinstance(want, str) or not want or current == want:
            continue
        # A GitHub-hosted label (the retired outage override's footprint, HOSTED_OVERRIDE) follows the pool back to
        # Blacksmith; an owned runner someone set by hand stays.
        if current and not EPHEMERAL.match(current) and not HOSTED.match(current):
            continue
        writes.append((name, want))
    writes += [(name, target) for name, target, _current, _why in raw_writes(value, live, owned=owned)]
    return writes


def raw_substitute(label: str, dead: Iterable[str], pools: Mapping[str, Mapping[str, Any]], least: int = 0) -> str | None:
    """The live Blacksmith Linux pool label a RAW_LABEL_VARS variable takes while `label` is dead: a member of a pool
    that declares `label` (so the same arch, and a size that pool's jobs were declared to fit), the largest size at
    most `label`'s, else the smallest larger one, never below `least` vCPU (RAW_LABEL_MIN_VCPU). None when no such
    member is live: the variable stays, as a pool with every member dead keeps its first member, rather than move a
    32 vCPU build onto 2 vCPU (2026-11-18)."""
    match = BLACKSMITH_LINUX.match(label)
    if not match:
        return None
    size, image, dead = int(match.group(1)), match.group(2), set(dead)
    sizes: dict[str, int] = {}
    for spec in pools.values():
        if label not in members(spec):
            continue
        for member in members(spec):
            other = BLACKSMITH_LINUX.match(member)
            if other and other.group(2) == image and member != label and member not in dead \
                    and int(other.group(1)) >= least:
                sizes[member] = int(other.group(1))
    down = sorted((name for name, n in sizes.items() if n <= size), key=lambda name: -sizes[name])
    up = sorted((name for name, n in sizes.items() if n > size), key=lambda name: sizes[name])
    return next(iter([*down, *up]), None)


def raw_homes(previous: Mapping[str, Mapping[str, str]], live: Mapping[str, str | None], dead: Iterable[str],
              pools: Mapping[str, Mapping[str, Any]], *, owned: frozenset[str]) -> tuple[dict[str, dict[str, str]],
                                                                                         list[str]]:
    """The next RUNNER_POOLS `_raw_home` (VARIABLE -> {home, to}) and a line per change.

    A RAW_LABEL_VARS variable on a Blacksmith Linux pool label `_dead` names gets an entry: `home`, the label it
    held, and `to`, the live size it moves to (raw_substitute()). The entry stays while the variable holds `home`,
    `to` or another dead label; raw_writes() points it at `to` while `home` is dead and back at `home` after. Once
    it holds `home` again with `home` live, the entry goes. A variable set by hand to anything else loses its entry
    and is left alone, as is one this pass could not read or the overflow switch's record names (`owned`)."""
    dead = set(dead)
    known = {label for spec in pools.values() for label in members(spec) if BLACKSMITH_LINUX.match(label)}
    homes: dict[str, dict[str, str]] = {}
    lines: list[str] = []
    for name in RAW_LABEL_VARS:
        entry = previous.get(name)
        if name not in live or name in owned:
            if entry:
                homes[name] = dict(entry)
            continue
        current = (live.get(name) or "").strip()
        size = BLACKSMITH_LINUX.match(current)
        below_floor = bool(size) and int(size.group(1)) < RAW_LABEL_MIN_VCPU.get(name, 0)
        if entry and current not in (entry["home"], entry["to"]) and current not in dead and not below_floor:
            lines.append(f"{name}={current or 'unset'} was set by hand after it moved off {entry['home']}; "
                         "it stays as set")
            entry = None
        if entry is None:
            if current not in known or current not in dead:
                continue
            to = raw_substitute(current, dead, pools, RAW_LABEL_MIN_VCPU.get(name, 0))
            if to is None:
                lines.append(f"{name}={current} is dead and no other size of its image is live; it stays")
                continue
            homes[name] = {"home": current, "to": to}
            continue
        home = entry["home"]
        if home not in dead and current == home:
            lines.append(f"{name} is back on {home}")
            continue
        to = entry["to"]
        least = RAW_LABEL_MIN_VCPU.get(name, 0)
        size = BLACKSMITH_LINUX.match(to)
        if size and int(size.group(1)) < least:
            # Moved below its floor (before RAW_LABEL_MIN_VCPU): an allowed live size, else back home to wait.
            to = raw_substitute(home, dead, pools, least) or home
            lines.append(f"{name}: {entry['to']} is below its {least} vCPU floor; it moves to {to}")
        elif home in dead and to in dead:
            to = raw_substitute(home, dead, pools, least) or to
        homes[name] = {"home": home, "to": to}
    return dict(sorted(homes.items())), lines


def raw_writes(value: Mapping[str, Any], live: Mapping[str, str | None], *,
               owned: frozenset[str]) -> list[tuple[str, str, str, str]]:
    """(variable, label, current, why) for each `_raw_home` entry (raw_homes()) whose variable does not hold its
    target: `to` while `home` is dead, `home` once it is not. Only a variable this pass read, the switch's record
    does not name, and that still holds `home`, `to` or a dead label (else it was set by hand) moves."""
    dead = set(value.get(DEAD_KEY) or {})
    found = []
    for name, entry in sorted((value.get(RAW_HOME_KEY) or {}).items()):
        if name in owned or name not in live:
            continue
        current = (live.get(name) or "").strip()
        size = BLACKSMITH_LINUX.match(current)
        below_floor = bool(size) and int(size.group(1)) < RAW_LABEL_MIN_VCPU.get(name, 0)
        if current not in (entry["home"], entry["to"]) and current not in dead and not below_floor:
            continue
        if entry["home"] in dead:
            target, why = entry["to"], f"{entry['home']} is dead"
        else:
            target, why = entry["home"], f"{entry['home']} takes jobs again"
        # `to` is `home` when no size at or above the variable's floor is live: it waits there, dead or not.
        if current != target and (target not in dead or target == entry["home"]):
            found.append((name, target, current, why))
    return found


def mirror_problems(live: Mapping[str, str | None], pools: Mapping[str, Mapping[str, Any]], *,
                    record: str | None) -> list[str]:
    """Why a MIRRORS variable misroutes its jobs: it names no member of its pool (and the switch did not move it)."""
    owned = switch_owned(record)
    if owned is None:
        return []
    found = []
    for name, pool in MIRRORS.items():
        if name in owned:
            continue
        current = (live.get(name) or "").strip()
        allowed_labels = allowed(pools[pool], pools) if pool in pools else []
        # The persistent pool, set by hand on purpose (Leo, 2026-11-21 00:38Z: "just... accept all labels"): it
        # serves every x64 Linux label, so nothing waits on it; not a pools.linux member, so the writer never
        # routes the pool's own readers there.
        if current not in allowed_labels and current not in PERSISTENT_LINUX_POOL_LABELS:
            found.append(f"{name}={current or 'unset'} is not a member of pools.{pool} "
                         f"({', '.join(allowed_labels)}): "
                         f"every `vars.{name} || ...` runs-on waits on it; runner_pools.py writes the live member")
    return found


def _labels(joined: object) -> set[str]:
    """A label set as the janitor writes it: joined with "," (dead_labels) or "+" (fleet keys)."""
    if not isinstance(joined, str):
        return set()
    return {part.strip() for part in re.split(r"[,+]", joined) if part.strip()}


def started_nothing_while_queued(snapshot: Mapping[str, Any], label: str, load: Mapping[str, Any],
                                 oldest_minutes: float, generated: dt.datetime) -> bool:
    """Whether a stalled label (its oldest queued job waited BLACKSMITH_STALL_MINUTES) is dead, not busy:
    nothing runs on it, and the janitor's `label_started` map shows no start since that job began to wait.

    A Blacksmith queue is not first in, first out, so a long wait alone proves nothing: on 2026-11-08
    blacksmith-6vcpu-macos-15 started four jobs of run 42503576472 at 17:28-17:31Z (one still running) and
    was marked dead at 17:34:13Z, because other jobs had queued there for more than 10 minutes. A snapshot
    without `label_started` (an older janitor) proves nothing either: no mark."""
    starts = snapshot.get(LABEL_STARTED_KEY)
    if not isinstance(starts, Mapping):
        return False
    try:
        if int(load.get("running") or 0) > 0:
            return False
    except (TypeError, ValueError):
        return False
    started = parse_time(starts.get(label))
    return started is None or (generated - started).total_seconds() / 60 >= oldest_minutes


# The idle runners an owned label keeps as headroom: more than this many idle beside a stalled queue and the label is
# not full (label_evidence()). A few idle runners are a reading's noise (one finishing its job, one about to take the
# next); hundreds are room the queue is not using. Leo, 2026-11-19, on Blacksmith: "stop ... relying on it".
OWNED_IDLE_HEADROOM = 4


def owned_idle(load: Mapping[str, Any]) -> int | None:
    """The idle runners the janitor's roster read (queue_janitor.attach_owned_idle()) shows on an owned label's
    pool entry, or None without a usable reading (an older janitor, no token, a failed read)."""
    idle = load.get("idle")
    return idle if isinstance(idle, int) and not isinstance(idle, bool) and idle >= 0 else None


def label_evidence(health: Mapping[str, Any] | None, snapshot: Mapping[str, Any] | None, *,
                   now: dt.datetime) -> tuple[set[str], set[str], list[str]]:
    """(dead, started, notes): the labels seen starting nothing, the labels seen starting a job.

    A probe's stall counts only beside a fresh, complete janitor snapshot, whose `label_started` tells a dead size
    from one the org's vCPU cap keeps full (recently_started()). Without one a stall decides nothing and the marks
    keep their state: in run 44296348389 (2026-11-18 11:37Z) the snapshot read returned 403 with the cmux-bot App's
    budget spent, the 4, 8, 16 and 32 vCPU probes waited behind the cap while 2,618 jobs were queued, and all four
    were marked dead, which squeezed every Linux pool onto 2 vCPU. A probe's start always counts."""
    dead: set[str] = set()
    started: set[str] = set()
    # Owned Linux VM labels whose queue waited the stall cutoff: full, whatever they started (below).
    full: set[str] = set()
    stalls: set[str] = set()
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
                    stalls.add(str(label))
                elif state == "started":
                    started.add(str(label))
    generated = parse_time(snapshot.get("generated_at")) if isinstance(snapshot, Mapping) else None
    if isinstance(snapshot, Mapping) and generated is None:
        notes.append("the janitor snapshot has no readable generated_at; no snapshot evidence")
    elif generated is not None and not (dt.timedelta(minutes=-1) <= now - generated <= SNAPSHOT_MAX_AGE):
        notes.append(f"the janitor snapshot is from {iso(generated)}, outside the last {SNAPSHOT_MAX_AGE}; "
                     "no snapshot evidence")
    elif generated is not None and pr_runner_pool.snapshot_truncated(snapshot):
        # Its queue counts are partial, so they decide nothing; its starts are still starts. On 2026-11-18 at 14:14Z
        # dropping them sent every Linux pool to the 2 vCPU release valve while 4 and 8 vCPU kept starting jobs.
        started |= recently_started(snapshot, now=now)
        notes.append(f"{pr_runner_pool.snapshot_truncated(snapshot)}; only its recent starts count")
    elif generated is not None:
        dead |= stalls
        stalls = set()
        age = max(0.0, (now - generated).total_seconds() / 60)
        started |= recently_started(snapshot, now=now)
        for label, load in (snapshot.get("pools") or {}).items():
            if not (isinstance(label, str) and (EPHEMERAL.match(label) or owned_lead(label))
                    and isinstance(load, Mapping)):
                continue
            try:
                queued = int(load.get("queued") or 0)
                oldest = float(load.get("oldest_queued_minutes") or 0)
            except (TypeError, ValueError):
                continue
            if owned_lead(label):
                # Our own machines, not a cloud: a job that waited the cutoff there and no idle runner past
                # OWNED_IDLE_HEADROOM means every VM is taken, so the pool overflows to its Blacksmith members until
                # the queue drains, even while the VMs start jobs. Idle runners beside the wait mean the waiting
                # jobs are ones these runners do not take, so the pool stays (owned_idle()). With no idle reading
                # the wait alone decides, as before.
                # The wait is the one the snapshot measured, never that plus the snapshot's age. Adding the age
                # assumes nothing took the job since, which for our pool (hundreds of idle runners, a start in
                # seconds) is a guess that sends every x64 pool to Blacksmith. 2026-11-22 09:37Z: the 09:02Z snapshot
                # read cmux-fleet-linux-x64 1 queued, oldest 0 min, 884 running, a start at 09:03Z; at 35 min old,
                # 0 + 35 crossed the cutoff, the label was marked full, and linux, linux_2, linux_8, linux_16 and
                # linux_32 ran on Blacksmith until 10:25Z. Leo, 2026-11-19, on Blacksmith: "stop ... relying on it".
                if not simple_pool_picker.blacksmith_stalled(queued, oldest):
                    continue
                idle = owned_idle(load)
                if idle is not None and idle > OWNED_IDLE_HEADROOM:
                    started.add(label)
                    notes.append(f"{label}: {queued} queued, oldest {oldest:g} min, but {idle} runners idle; "
                                 "not full")
                    continue
                full.add(label)
                continue
            if not simple_pool_picker.blacksmith_stalled(queued, oldest + age):
                continue
            if started_nothing_while_queued(snapshot, label, load, oldest, generated):
                dead.add(label)
            elif isinstance(snapshot.get(LABEL_STARTED_KEY), Mapping):
                # Positive evidence: it runs a job or started one while its oldest job waited, so a
                # dead mark an older rule wrote from the wait alone is cleared now, not at DEAD_TTL.
                started.add(label)
        for entry in snapshot.get("dead_labels") or ():
            if isinstance(entry, Mapping):
                dead |= _labels(entry.get("label"))
                live = entry.get("live")
                if isinstance(live, list):
                    started |= {str(label) for label in live if isinstance(label, str)}
    if stalls - started:
        notes.append(f"probe stalled on {', '.join(sorted(stalls - started))} with no fresh janitor snapshot to tell a "
                     "dead size from a full vCPU cap; no new dead mark")
    # A label both started and stalled in one pass (two probes, or a probe and a stale queue) started. A full owned
    # Linux label is dead though it starts jobs: its starts clear the mark only once its queue no longer waits.
    return (dead - started) | full, started - full, notes


def evidence_covers(health: Mapping[str, Any] | None, snapshot: Mapping[str, Any] | None,
                    pools: Mapping[str, Mapping[str, Any]], *, now: dt.datetime) -> set[str]:
    """The labels this pass has fresh evidence about, so a dead mark on one may expire.

    The probe's health (fresh, as label_evidence() reads it) covers the labels it lists. The janitor's
    snapshot (fresh and complete) covers every other pool member: it lists the Blacksmith macOS labels'
    queues, but no Linux label, so the linux pool's sizes are covered only by the probe."""
    covered: set[str] = set()
    # An owned lead (owned_lead()) is never probed: the snapshot covers it, so its full mark can expire.
    probed = {label for label in members(pools["linux"]) if not owned_lead(label)} if "linux" in pools else set()
    if isinstance(health, Mapping):
        checked, labels = parse_time(health.get("checked")), health.get("labels")
        if checked is not None and isinstance(labels, Mapping) and \
                dt.timedelta(minutes=-1) <= now - checked <= HEALTH_MAX_AGE:
            covered |= {str(label) for label in labels}
    generated = parse_time(snapshot.get("generated_at")) if isinstance(snapshot, Mapping) else None
    fresh = generated is not None and dt.timedelta(minutes=-1) <= now - generated <= SNAPSHOT_MAX_AGE
    if fresh and not pr_runner_pool.snapshot_truncated(snapshot):
        covered |= {label for spec in pools.values() for label in members(spec)} - probed
    if fresh:
        # A size the janitor saw start a job recently is covered too, truncated or not: label_evidence() calls it
        # started.
        covered |= recently_started(snapshot, now=now)
    return covered


def recently_started(snapshot: Mapping[str, Any], *, now: dt.datetime) -> set[str]:
    """The Blacksmith labels the janitor's `label_started` shows starting a job within RECENT_START of `now`.

    Such a label is serving, so it is never dead, whatever the probe saw: a probe that waits out its minutes on a
    size that keeps starting jobs is queued behind the org's vCPU cap, not on a dead size."""
    starts = snapshot.get(LABEL_STARTED_KEY)
    if not isinstance(starts, Mapping):
        return set()
    found = set()
    for label, when in starts.items():
        moment = parse_time(when)
        if isinstance(label, str) and (EPHEMERAL.match(label) or owned_lead(label)) and moment is not None \
                and dt.timedelta(minutes=-1) <= now - moment <= RECENT_START:
            found.add(label)
    return found


def unproven(label: str, served: Mapping[str, Any]) -> bool:
    """An owned Mac fleet Linux VM label (OWNED_EPHEMERAL_LINUX) no runner has been seen taking a job on.

    Its runners are scale-set clones that register only when a job is handed to them, so an idle label lists no
    runner, and a label whose scale sets never came up lists none either. Only a start tells them apart. The stall
    rule (label_evidence()) needs a job queued there, so a pool nothing reads yet was never judged: at about 07:26Z on
    2026-11-22 the writer put linux_owned_small back on glaeda-linux-arm64, which no runner had ever served, and the
    coordinator's FIRE read "No runner registered for manaflow-ai/cmux carries that label, so every job routed through
    it sits queued". Until a start is seen (a job pinned to the label, whose start the janitor's `label_started`
    records) the pool takes its Blacksmith members. The owned GCP label is not judged this way: its runners stand
    registered and its pools' readers queue there, so the stall rule marks it within the cutoff."""
    return owned_ephemeral(label) and label not in served


def reconcile(current: Mapping[str, Any], pools: Mapping[str, Mapping[str, Any]], *,
              dead_now: Iterable[str], served_now: Iterable[str], now: dt.datetime,
              covered: Iterable[str] | None = None) -> tuple[dict[str, Any], list[str]]:
    """The next RUNNER_POOLS value and a line per change. `current` is parse_value()'s output.

    `covered` (evidence_covers()) names the labels whose marks may expire; None lets every mark expire."""
    lines: list[str] = []
    marks: dict[str, str] = {}
    known_now = None if covered is None else set(covered)
    for label, since in (current.get(DEAD_KEY) or {}).items():
        seen = parse_time(since)
        if seen is not None and now - seen < DEAD_TTL:
            marks[label] = since
        elif seen is not None and known_now is not None and label not in known_now:
            # No fresh evidence about this label: it stays dead rather than taking jobs again on a guess.
            marks[label] = since
            lines.append(f"{label}: dead mark past {DEAD_TTL} kept; no fresh evidence about it this pass")
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
    served = {label: since for label, since in (current.get(SERVED_KEY) or {}).items() if label in known}
    for label in sorted(set(served_now)):
        if owned_ephemeral(label) and label in known and label not in served:
            served[label] = iso(now)
            lines.append(f"{label}: an owned Linux VM runner took a job; the pools may lead with it")
    skipped = set(marks) | {label for label in known if unproven(label, served)}
    value: dict[str, Any] = {}
    for name, spec in sorted(pools.items()):
        candidates = members(spec)
        chosen = next((label for label in candidates if label not in skipped), None)
        if candidates and unproven(candidates[0], served) and current.get(name) == candidates[0]:
            lines.append(f"pools.{name}: no runner has ever taken a job on {candidates[0]}; passed over")
        if chosen is None:
            # Every member is dead: the first member, never a size outside the declared members (allowed()).
            chosen = candidates[0]
            if current.get(name) != chosen:
                lines.append(f"pools.{name}: every member is dead ({', '.join(candidates)}); keeping the first member")
        if current.get(name) != chosen:
            lines.append(f"pools.{name}: {current.get(name) or 'unset'} -> {chosen}")
        value[name] = chosen
    value[DEAD_KEY] = dict(sorted(marks.items()))
    if served:
        value[SERVED_KEY] = dict(sorted(served.items()))
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
            if getattr(error, "status", None) == 404:
                return None
            raise

    def set_variable(self, name: str, value: str) -> None:
        self.client.set_variable(name, value)


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, *,
         api: Any = None, switch: Any = None, now: dt.datetime | None = None, fallback: Any = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="validate the live RUNNER_POOLS and exit")
    parser.add_argument("--dry-run", action="store_true",
                        default=(env.get("DRY_RUN", "").strip().lower() in {"1", "true", "yes"}))
    args = parser.parse_args(argv)
    now = now or dt.datetime.now(UTC)
    pools = load_pools(env=env)
    stale_override = (env.get(HOSTED_OVERRIDE) or "").strip()
    if stale_override:
        print(f"::error title=Runner pools::{HOSTED_OVERRIDE}={stale_override!r} is set, and no pool runs on GitHub-hosted "
              "runners (Leo, 2026-11-19: \"F*** GitHub.\"); it is ignored. Delete it: gh variable delete "
              f"{HOSTED_OVERRIDE} -R manaflow-ai/cmux")
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
        return 1 if found or stale_override else 0
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
            fallback_token = (env.get("GH_FALLBACK_TOKEN") or "").strip()
            if fallback is None and fallback_token and fallback_token != (env.get("GH_TOKEN") or "").strip() \
                    and repo:
                fallback = pr_runner_pool.GitHub(fallback_token, repo)
            if fallback is None:
                print(f"::warning title=Runner pools::no janitor snapshot ({error}); judging on the probe alone")
            else:
                # The cmux-bot read budget is org-wide and runs out: on 2026-11-18 from 11:18Z every read was
                # refused (403), every probe but 2 vCPU waited out its minutes under the vCPU cap, and with no
                # snapshot every Linux pool went to the 2 vCPU release valve. Ask once more with the workflow
                # token (a run read, which that token can do; it can never read a variable).
                try:
                    snapshot = fallback.snapshot(now=now)
                    if snapshot is None:
                        print(f"::warning title=Runner pools::no janitor snapshot ({error}; fallback: no trusted "
                              "snapshot); judging on the probe alone")
                    else:
                        print(f"::notice title=Runner pools::janitor snapshot read with the fallback token ({error})")
                except Exception as second:  # noqa: BLE001 - as above
                    print(f"::warning title=Runner pools::no janitor snapshot ({error}; fallback: {second}); "
                          "judging on the probe alone")
    health = _health(switch, env)
    dead, started, notes = label_evidence(health, snapshot, now=now)
    for note in notes:
        print(note)
    value, lines = reconcile(current, pools, dead_now=dead, served_now=started, now=now,
                             covered=evidence_covers(health, snapshot, pools, now=now))
    # The mirrored and raw-label variables and the switch's record, read live: the switch step just before this
    # one may have moved them, so the job-start values could undo its failover.
    live, record, readable = _live(switch, env)
    owned = switch_owned(record) if readable else None
    previous_homes = current.get(RAW_HOME_KEY) or {}
    if owned is not None:
        homes, said = raw_homes(previous_homes, live, value[DEAD_KEY], pools, owned=owned)
        lines += said
    else:
        homes = dict(previous_homes)
    if homes:
        value[RAW_HOME_KEY] = homes
    if homes != previous_homes:
        value[UPDATED_KEY] = iso(now)
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
    if readable:
        writes += mirror_writes(value, live, record=record, pools=pools)
    if owned is not None:
        # Every raw-label move is a warning, so the run's annotations say which variables left which label.
        for name, target, was, why in raw_writes(value, live, owned=owned):
            print(f"::warning title=Runner pools::{name}: {was or 'unset'} -> {target} ({why}; "
                  f"{VARIABLE}.{RAW_HOME_KEY} keeps its home)")
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
    """(MIRRORS values, the overflow record, whether they were read) through the API, else the job's env.

    The RAW_LABEL_VARS values this pass could read are in the same map; one it could not read is absent, so it is
    never moved on a guess (raw_homes(), raw_writes())."""
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
    for name in RAW_LABEL_VARS:
        if switch is not None and hasattr(switch, "get_variable"):
            try:
                got[name] = switch.get_variable(name)
            except Exception as error:  # noqa: BLE001 - an unread variable is never moved
                print(f"::warning title=Runner pools::could not read {name} ({error}); not moving it")
        elif name in env:
            got[name] = env.get(name)
    return got, record, True


if __name__ == "__main__":
    sys.exit(main())
