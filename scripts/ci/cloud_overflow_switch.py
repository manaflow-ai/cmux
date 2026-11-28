#!/usr/bin/env python3
"""Turn Blacksmith overflow off while Blacksmith starts no job, and back on once it does.

Blacksmith is overflow: the owned minis come first (docs/ci-runners.md,
"minis first"), and the runner variables (LINUX_RUNNER, MACOS_RUNNER_*,
gated by CI_PAID_MACOS_OVERFLOW) name what every job the minis do not take
lands on. On 2026-09-29 Blacksmith stopped starting jobs org-wide from about
10:15Z; about 150 runs sat queued for two hours until someone pointed those
variables at the owned pools and GitHub-hosted Linux by hand.

ci-cloud-overflow-probe.yml runs this every 10 minutes. Its `probe` jobs ask
for each Blacksmith Linux size in PROBE_LABELS (4 and 16 vCPU), one job per
label, and only print a line. This script, in the `watch` job on Blacksmith
Linux (its own bounded CI_TRUSTED_RUNNER selector, 2 or 8 vCPU or the one-job GCP JIT label, never a probe
size), waits for them:

- Every probe starts within PROBE_MINUTES of being queued: Blacksmith serves.
  If this switch turned overflow off (the CI_CLOUD_OVERFLOW_SAVED record
  exists), every variable it changed is put back, unless someone changed that
  variable since, and the record is deleted.
- None does: Blacksmith is not serving. Unless overflow is already off,
  the record is written first (what each variable held, what it gets, when
  and why), then each variable is pointed at its failover. Then, if it is
  cheap, runs already stuck on a Blacksmith label are force-cancelled and
  re-run so they pick their runners again. The workflow then force-cancels
  its own run, whose probes would otherwise stay queued.
- Some start and some do not: nothing changes, with one exception. One
  stalled size never flips the fleet, and a size stalling alone is for that
  size's own failover (RUNNER_POOLS, from CI_CLOUD_LABEL_HEALTH), not this
  switch. The exception: a record exists and the smallest probed size
  (SERVING_PROBE, 4 vCPU) started. Blacksmith is serving then, so the record
  is put back as when every probe starts (plan_on() returns a Linux variable
  only onto a size that started). Keeping it would latch: while the record is
  set, about 216 feat-cmux-next runs-on read `vars.CI_CLOUD_OVERFLOW_SAVED &&`
  a larger size (8 to 16, 16 to 32), which fills exactly the large sizes under
  Blacksmith's vCPU cap, so the 16 vCPU probe keeps stalling and the record
  never clears. On 2026-11-17 a record written at 19:48Z (macOS variables
  only) was still set at 00:48Z; every pass from 21:07Z ended partial (the
  00:31Z one: 4 vCPU started in 7 s, 16 vCPU no runner), and of the Linux jobs
  created 00:00-00:48Z, 32 vCPU started 1 of 282 and 16 vCPU 5 of 63 while
  4 vCPU started 47 of 209. A required check (`clippy (changed cmux-tui
  packages)`, size 8, overflow route RUNNER_POOLS.linux_16, then 32 vCPU) sat
  in that queue.

One probe, one switch: the only state is the variables and the record. The
failover of each variable (failover_values()) is derived from the lane's
Xcode pin, the same way pr_runner_pool.py names owned pools: the macOS
capability variables take the std owned pool (the GUI one for
MACOS_RUNNER_DISPLAY, the simulator capability label for MACOS_RUNNER_IOS),
and LINUX_RUNNER and CI_TRUSTED_RUNNER take another Blacksmith Linux size
(LINUX_FAILOVER, TRUSTED_FAILOVER), never GitHub-hosted Ubuntu: hosted
Ubuntu sits behind the plan's concurrency limit, and on 2026-10-27 the
switch's own failover filled it so this workflow's watch waited 94 minutes
for a runner (Leo: "just put it on blacksmith / 16vcpu blacksmiths do
exist"). CI_CLOUD_FAILOVER (JSON,
variable name to value, "" to leave one alone) overrides any of them. Only a
variable that is unset (its readers then fall back to Blacksmith) or holds a
blacksmith-* label is changed, so a lane someone deliberately pointed
elsewhere is left alone. Nothing here touches the lane switches
(CI_PR_POOL_OWNED, CI_E2E_OWNED_UI, CI_IOS_OWNED, ...): minis-first routing
never changes, only where overflow goes.

Some variables are read by signing jobs' runs-on, and those must only ever
name an ephemeral runner (rule 7 of
tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py on
feat-cmux-next, checked live by cmux-next-guards.yml there). Which ones is
read from the workflows of main and of feat-cmux-next
(signing_runner_variables.signing_variables(); the variables are
repository-wide, and this scheduled switch runs from main). The switch never
writes anything else to one: such a variable has no owned failover (its jobs
wait for Blacksmith), an override that names a reused machine for one is
refused, and an older record that still names one as switched to an owned
pool is not re-applied. Turning overflow back on still puts back the value a
record names.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_runner_pool  # noqa: E402
from runner_label_policy import HOSTED_MACOS_LABEL  # noqa: E402
import signing_runner_variables  # noqa: E402

API = "https://api.github.com"
UTC = dt.timezone.utc

RECORD_VARIABLE = "CI_CLOUD_OVERFLOW_SAVED"
OVERRIDES_VARIABLE = "CI_CLOUD_FAILOVER"
PAID_OVERFLOW_VARIABLE = "CI_PAID_MACOS_OVERFLOW"
CLOUD_PREFIX = pr_runner_pool.EPHEMERAL_PREFIX  # "blacksmith-"
# What the probe asks for: every member of the linux pool in .github/runners.json
# (tests/test_ci_runner_pools.py; the workflow's probe matrix restates this). Overflow goes off
# only when none of them starts its probe; one that starts means Blacksmith
# serves. A single probed label is a pin: on 2026-10-28 the 4 vCPU label
# alone queued past 5 minutes at 21:59Z, 22:13Z, 22:53Z and 23:30Z while the
# other sizes started jobs, and each time the whole fleet failed over.
PROBE_LABELS = ("blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404")
# Every x64 Linux label a RUNNER_POOLS pool can point at (its declared members,
# runner_pools.allowed(); tests/test_ci_runner_pools.py), decision probes first. The others are probed for
# CI_CLOUD_LABEL_HEALTH only and never decide overflow: on 2026-11-18 linux_16 and linux_32 sat on
# blacksmith-32vcpu-ubuntu-2404 from about 23:12Z with nothing starting there, because no probe asked for it
# and the janitor's snapshot (truncated at 2,500 queued runs) said nothing either.
HEALTH_LABELS = (*PROBE_LABELS, "blacksmith-2vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404",
                 "blacksmith-32vcpu-ubuntu-2404")
# Where Linux overflow goes while the probed label stalls: another Blacksmith
# Linux size, never GitHub-hosted Ubuntu. Every CI_TRUSTED_RUNNER reader
# accepts ubuntu-24.04 and the 2 and 4 vCPU labels (docs/ci-runners.md), so it
# takes 2 vCPU.
LINUX_FAILOVER = "blacksmith-16vcpu-ubuntu-2404"
# The size whose probe starting means Blacksmith serves, whatever larger sizes do: most Linux jobs are
# measured at 4 vCPU or less (.github/runners.json linux_sizes on feat-cmux-next), and a larger size that
# stalls alone is per-size routing's to move (module docstring).
SERVING_PROBE = PROBE_LABELS[0]
TRUSTED_FAILOVER = "blacksmith-2vcpu-ubuntu-2404"
# When the probed label is that failover itself, the other size: a probed one, so
# toward_started() can pick it, and one the bounded LINUX_RUNNER selectors accept.
ALTERNATE_FAILOVERS = {LINUX_FAILOVER: "blacksmith-4vcpu-ubuntu-2404",
                       TRUSTED_FAILOVER: "blacksmith-4vcpu-ubuntu-2404"}
# The only Blacksmith labels every CI_TRUSTED_RUNNER reader accepts.
TRUSTED_BLACKSMITH_LABELS = frozenset({"blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"})
# The owned one-job GCP JIT label CI_TRUSTED_RUNNER's readers also accept (cmuxterm-hq runner_pool.py
# JIT_ONLY_LABELS: one VM per job, deleted after it). Leo, 2026-11-19, on Blacksmith: "stop ... relying on it".
# The CLA jobs (cla.yml, cla-policy-guard.yml) do not list it: their runner-name guard admits only GitHub-hosted
# and Blacksmith VMs, so for them it falls back to Blacksmith 4 vCPU. No probe asks for it and Blacksmith being
# down does not stall it, so the switch never moves CI_TRUSTED_RUNNER off it (plan_off: it is not a blacksmith-*
# label) and keeps it where an override or a recorded value puts it (toward_started, plan_on, plan_resume).
TRUSTED_JIT_LABELS = frozenset({"cmux-gcp-secret-jit-x64"})
TRUSTED_ACCEPTED_LABELS = TRUSTED_BLACKSMITH_LABELS | TRUSTED_JIT_LABELS
HOSTED_LINUX_LABEL = re.compile(r"^ubuntu-")
LINUX_VARIABLE = "LINUX_RUNNER"
# The merge-gating checks (CLA, backend migrations) read this; it falls back to
# Blacksmith, so it leaves with the rest of Linux and comes back with it.
TRUSTED_VARIABLE = "CI_TRUSTED_RUNNER"
LINUX_VARIABLES = (LINUX_VARIABLE, TRUSTED_VARIABLE)
# The runner variables whose unset fallback is a Blacksmith label, and so the
# ones that carry overflow. MACOS_RUNNER_TESTS falls back per lane (the E2E
# lane goes through e2e_runner_pool.py, the iOS lane through
# MACOS_RUNNER_IOS) and MACOS_RUNNER_BACKGROUND is GitHub-hosted, so neither
# is here; CI_CLOUD_FAILOVER can add one.
# Any of these a signing job reads (signing_runner_variables) keeps its value: on
# 2026-10-28 the failover pointed MACOS_RUNNER_26 at the std pool and turned
# cmux-next-guards.yml's signing-runner-variables red on every PR.
STD_VARIABLES = ("MACOS_RUNNER_15", "MACOS_RUNNER_26", "MACOS_RUNNER_26_LARGE", "MACOS_RUNNER_PR")
# swift-package-tests reads this one, and on a full suite that checks the
# Release build it first builds the Release helper against an SDK 15 Xcode.
# No owned pool carries one (the minis have the lane's Xcode alone), so the
# std pool is no failover for it: on 2026-11-16 the switch pointed it there
# and the job failed "No Xcode.app found under /Applications with macOS SDK
# major 15" on every main full suite. It has no default failover: its jobs
# wait for Blacksmith, and CI_CLOUD_FAILOVER can still name one.
SDK15_VARIABLE = "MACOS_RUNNER_DUAL_XCODE"
GUI_VARIABLE = "MACOS_RUNNER_DISPLAY"
IOS_VARIABLE = "MACOS_RUNNER_IOS"
SWITCHED_VARIABLES = (*LINUX_VARIABLES, *STD_VARIABLES, SDK15_VARIABLE, GUI_VARIABLE, IOS_VARIABLE,
                      PAID_OVERFLOW_VARIABLE)
# What CI_CLOUD_FAILOVER may name: the workflow passes each one's live value,
# so a restore never guesses what a variable held. MACOS_RUNNER_26 is not
# one: every value an override could give it is refused (GitHub-hosted, a
# Blacksmith label for a macOS variable, or a reused machine signing jobs
# would run on).
OVERRIDABLE_VARIABLES = (*SWITCHED_VARIABLES, "MACOS_RUNNER_TESTS")

# Blacksmith Linux started 35,454 jobs on 2026-09-27 with a queue p90 of 13 s;
# 18 waited more than a minute. A probe still queued after 5 minutes is far
# outside that, and the 10-minute schedule keeps a probe and its watch inside
# one period.
DEFAULT_PROBE_MINUTES = 5
MIN_PROBE_MINUTES = 2
MAX_PROBE_MINUTES = 20
PROBE_JOB = "Blacksmith probe"
POLL_SECONDS = 15

# Moving stuck runs: a bounded, best-effort pass.
MAX_RESCUES = 25
MAX_RUN_LISTINGS = 60
MAX_ATTEMPT = 3  # a run re-run this often already is left to a person
CANCEL_WAIT_SECONDS = 300
PROTECTED_EVENTS = frozenset({"merge_group", "release"})
PROTECTED_WORKFLOW = re.compile(r"release|publish|notar|testflight|app[-_ ]?store", re.IGNORECASE)
# --rescue-dead runs every pass while a dead mark lasts (hours on 2026-11-18), not only while
# overflow is off, so it also leaves alone signing, deploys, promotions, rollbacks and the
# nightly trains, whose half-done work a force-cancel would cut, and gives each run one try: a
# job whose runs-on names a literal label (or a variable no pool moves) comes back to the same
# dead label, and a second cancel would only repeat that.
DEAD_PROTECTED_WORKFLOW = re.compile(r"sign|deploy|promot|rollback|nightly|train", re.IGNORECASE)
DEAD_MAX_RESCUES = 10
# Of MAX_RUN_LISTINGS, the share kept for runs other than pushes, so pushes queued on live labels cannot
# push a stranded pull request run out of every pass.
DEAD_NON_PUSH_LISTINGS = 20
# A run with one of these jobs in progress is mid-publish or mid-sign: a force-cancel would cut it.
DEAD_BUSY_JOB = re.compile(r"publish|upload|sign|notar|deploy|promot|release", re.IGNORECASE)
# Pages of 100 GitHub.jobs() reads. A run with more jobs than these hold is an incomplete listing: it raises, so a
# rescue leaves the run alone rather than cancel it past a running job it never saw.
MAX_JOB_PAGES = 5
DEAD_CANCEL_WAIT_SECONDS = 120
# A label some pool named and none names now, with no dead mark: linux_pool_spill.py moved a pool off a backed-up
# size and back, or a pool was moved by hand. GitHub never re-routes a queued job, so a job bound there while a pool
# named it waits on it for good (2026-11-19: cmux#45502's `changes`, run 44476854382, queued on
# blacksmith-16vcpu-ubuntu-2404 from 07:04Z, past 13:00Z; cmux#46768 and #47130 the same day). The label may still
# start jobs, so a moved job waits this long first: a re-run loses its place, and most jobs bound to a size a pool
# just left still start there within it.
MOVED_MINUTES = 30
# Created at least this long ago: a listing of the oldest queued runs, besides the newest 100. With thousands queued
# (2026-11-19) a run stranded for hours is never in the newest page.
OLD_RUN_SLICES_MINUTES = (MOVED_MINUTES, 180)
# Variables that hold one raw Blacksmith Linux label runs-on reads ahead of a pool (runner_pools.RAW_LABEL_VARS),
# passed to the rescue step as NAME=value lines: a label one of them names is routed, and a re-run comes back to it.
RAW_RUNNER_VARIABLES_ENV = "RAW_RUNNER_VARIABLES"


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def probe_minutes(raw: str | None) -> int:
    """PROBE_MINUTES clamped to its range; unset or unreadable is the default."""
    try:
        value = int((raw or "").strip() or DEFAULT_PROBE_MINUTES)
    except ValueError:
        return DEFAULT_PROBE_MINUTES
    return max(MIN_PROBE_MINUTES, min(MAX_PROBE_MINUTES, value))


def cloud_label(label: str | None) -> bool:
    return bool(label) and str(label).startswith(CLOUD_PREFIX)


def linux_cloud_label(label: str | None) -> bool:
    """An x64 Blacksmith Linux label: a Linux failover may name another size of the pool it probes."""
    return bool(re.fullmatch(r"blacksmith-\d+vcpu-ubuntu-\d+", str(label or "")))


def unprobed_trusted(name: str, label: str | None) -> bool:
    """CI_TRUSTED_RUNNER on a one-job GCP JIT label: no probe decides it, so probe health never moves it."""
    return name == TRUSTED_VARIABLE and (label or "").strip() in TRUSTED_JIT_LABELS


def probe_job_name(label: str) -> str:
    """The name of the probe job for one label (the workflow's matrix job name)."""
    return f"{PROBE_JOB} ({label})"


def parse_record(raw: str | None) -> dict[str, Any] | None:
    """The switch's record, or None when overflow is on. An unreadable record raises."""
    if not (raw or "").strip():
        return None
    record = json.loads(str(raw))
    if not isinstance(record, dict) or not isinstance(record.get("changed"), dict):
        raise ValueError(f"{RECORD_VARIABLE} is not a switch record")
    return record


def signing_safe(name: str, value: str | None) -> bool:
    """Whether the switch may write `value` to `name`: anything, unless signing jobs read `name`."""
    return signing_runner_variables.allowed_value(name, value)


def failover_values(xcode_app_pr: str | None, overrides: str | None) -> tuple[dict[str, str], list[str]]:
    """What each overflow variable points at while Blacksmith is down, and any problems.

    The owned labels come from the lane's Xcode pin exactly as the picker
    names its pools, so moving the pin moves the failover. Without a pin the
    macOS variables are left alone (named in the problems).
    """
    problems: list[str] = []
    values: dict[str, str] = {LINUX_VARIABLE: LINUX_FAILOVER, TRUSTED_VARIABLE: TRUSTED_FAILOVER}
    owned = pr_runner_pool.owned_pools(xcode_app_pr)
    if owned:
        std = owned[0]
        values.update({name: std for name in STD_VARIABLES})
        values[GUI_VARIABLE] = pr_runner_pool.gui_label(std)
        values[IOS_VARIABLE] = pr_runner_pool.CAPABILITY_LABELS[0]
    else:
        problems.append(f"{pr_runner_pool.PR_XCODE_VARIABLE} names no owned pool; the macOS variables keep "
                        "their values")
    if (overrides or "").strip():
        try:
            extra = json.loads(str(overrides))
        except ValueError:
            extra = None
        if not isinstance(extra, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                                  for k, v in extra.items()):
            problems.append(f"{OVERRIDES_VARIABLE} is not a JSON object of variable names to strings; ignored")
        else:
            for name, value in extra.items():
                if name not in OVERRIDABLE_VARIABLES:
                    problems.append(f"{OVERRIDES_VARIABLE} names {name!r}, which the switch does not set; ignored")
                elif not value.strip():
                    values.pop(name, None)
                elif HOSTED_LINUX_LABEL.match(value.strip().lower()):
                    # No job runs on GitHub-hosted Ubuntu (Leo, 2026-10-27).
                    problems.append(f"{OVERRIDES_VARIABLE} points {name} at {value.strip()}, GitHub-hosted "
                                    "Ubuntu; ignored")
                elif name == TRUSTED_VARIABLE and value.strip() not in TRUSTED_ACCEPTED_LABELS:
                    problems.append(f"{OVERRIDES_VARIABLE} points {name} at {value.strip()}, which its readers do "
                                    "not accept; ignored")
                elif cloud_label(value.strip()) and not (name in LINUX_VARIABLES and linux_cloud_label(value.strip())):
                    problems.append(f"{OVERRIDES_VARIABLE} points {name} at {value.strip()}, a Blacksmith label; "
                                    "ignored")
                elif HOSTED_MACOS_LABEL.search(value.strip().lower()):
                    # No job runs on a GitHub-hosted Mac (tests/test_ci_no_github_hosted_macos.py).
                    problems.append(f"{OVERRIDES_VARIABLE} points {name} at {value.strip()}, a GitHub-hosted Mac; "
                                    "ignored")
                elif not signing_safe(name, value):
                    problems.append(f"{OVERRIDES_VARIABLE} points {name} at {value.strip()}; signing jobs run on "
                                    f"{name}, so it may only name blacksmith-* or ubuntu-*; ignored")
                else:
                    values[name] = value.strip()
    for name in [name for name, value in values.items() if not signing_safe(name, value)]:
        # A signing job reads it (read from the workflows), so it keeps its value. Not a problem:
        # this is the routine case for MACOS_RUNNER_26.
        values.pop(name)
    if any(name not in LINUX_VARIABLES for name in values):
        # MACOS_RUNNER_15, _26 and friends are read only when this is 1.
        values[PAID_OVERFLOW_VARIABLE] = "1"
    return values, problems


def plan_off(current: Mapping[str, str | None], failover: Mapping[str, str]) -> dict[str, dict[str, str | None]]:
    """{name: {"before", "after"}} for every variable the switch changes.

    A runner variable changes only while it sends overflow to Blacksmith:
    unset (its readers fall back to Blacksmith) or a blacksmith-* label.
    CI_PAID_MACOS_OVERFLOW changes when it is not already 1. A variable
    already at its failover is not recorded, so turning overflow back on
    never "restores" a value this switch did not set. A variable signing jobs
    read never gets a label other than blacksmith-* or ubuntu-*.
    """
    changed: dict[str, dict[str, str | None]] = {}
    for name, after in failover.items():
        before = (current.get(name) or "").strip() or None
        if before == after or not signing_safe(name, after):
            continue
        if name != PAID_OVERFLOW_VARIABLE and before is not None and not cloud_label(before):
            continue
        changed[name] = {"before": before, "after": after}
    return dict(sorted(changed.items()))


@dataclasses.dataclass(frozen=True)
class Restore:
    name: str
    value: str | None  # None: delete the variable
    skipped: str = ""  # why it is left alone


@dataclasses.dataclass(frozen=True)
class Resume:
    name: str
    value: str
    skipped: str = ""  # why it is left alone


def plan_on(record: Mapping[str, Any], current: Mapping[str, str | None],
            started: Iterable[str] | None = None) -> list[Restore]:
    """What turning overflow back on writes: each recorded variable's value before, unless it moved since.

    With `started` (the labels whose probes started in this run), a Linux
    variable goes back only onto a label whose probe started: an older
    record's before (a size no longer probed, such as blacksmith-32vcpu-ubuntu-2404
    before the linux pool went smallest first, or unset, whose readers fall back
    to an unprobed literal) may
    still be stalled, and once the record is deleted nothing would see it.
    Such a variable stays where it is. A GitHub-hosted label is never put back.
    """
    healthy = None if started is None else set(started)
    restores: list[Restore] = []
    for name, change in sorted((record.get("changed") or {}).items()):
        if not isinstance(change, Mapping):
            continue
        before, after = change.get("before"), change.get("after")
        now = (current.get(name) or "").strip() or None
        hosted_now = name in LINUX_VARIABLES and now is not None and bool(HOSTED_LINUX_LABEL.match(now.lower()))
        if hosted_now and healthy is not None and (before or "") not in healthy:
            # A record from when Linux failed over to GitHub-hosted Ubuntu, whose before is not a
            # size seen serving: the record is about to be deleted, so the hosted value must not
            # outlive it. LINUX_RUNNER takes a probed size that started; CI_TRUSTED_RUNNER, whose
            # readers accept no probed size, is unset (its readers fall back to Blacksmith).
            live = [label for label in PROBE_LABELS if label in healthy]
            target = live[0] if name == LINUX_VARIABLE and live else None
            restores.append(Restore(name, target))
            continue
        if now != after and not (now is not None and now == change.get("was")):
            restores.append(Restore(name, before, f"now {now or 'unset'}, not the failover {after}; "
                                                  "someone changed it, so it is left alone"))
            continue
        if before and (HOSTED_LINUX_LABEL.match(before.lower()) or HOSTED_MACOS_LABEL.search(before.lower())):
            restores.append(Restore(name, before, f"stays {now or 'unset'}; its value before, {before}, is "
                                                  "GitHub-hosted, which no job runs on"))
            continue
        if (healthy is not None and name in LINUX_VARIABLES and (before or "") not in healthy
                and not unprobed_trusted(name, before)):
            restores.append(Restore(name, before, f"stays {now or 'unset'}; its value before, {before or 'unset'}, "
                                                  "is not a size whose probe started"))
            continue
        restores.append(Restore(name, before))
    return restores


def plan_resume(record: Mapping[str, Any], current: Mapping[str, str | None],
                started: Iterable[str] | None = None,
                failover: Mapping[str, str] | None = None) -> list[Resume]:
    """What a stalled probe should retry after a partial failover write.

    A value still at the recorded ``before`` value was never switched, so it
    is safe to apply its recorded failover. Any other value is either already
    at ``after`` or was edited by someone else and is left alone. A record
    written before signing variables were kept ephemeral may name one with an
    owned ``after``; that is never applied (on 2026-10-28 a retry re-applied
    MACOS_RUNNER_26 eight minutes after it was put back by hand). Given
    ``failover`` (this run's), a non-Linux variable it no longer names is
    never applied either: on 2026-11-16 the record held
    MACOS_RUNNER_DUAL_XCODE on the std pool, which has no SDK 15 Xcode, after
    the failover stopped naming it. The Linux variables follow ``started``.
    """
    resumes: list[Resume] = []
    for name, change in sorted((record.get("changed") or {}).items()):
        if not isinstance(change, Mapping):
            continue
        before, after = change.get("before"), change.get("after")
        if (before is not None and not isinstance(before, str)) or not isinstance(after, str):
            resumes.append(Resume(name, "", "record has an invalid before/after value; left alone"))
            continue
        now = (current.get(name) or "").strip() or None
        if now == after:
            continue
        if not signing_safe(name, after):
            resumes.append(Resume(name, after, f"signing jobs run on {name}, and {after} is not an ephemeral "
                                  "runner; left alone"))
            continue
        if name in LINUX_VARIABLES and HOSTED_LINUX_LABEL.match(after.lower()):
            # No job runs on GitHub-hosted Ubuntu (Leo, 2026-10-27), whatever an older record says.
            resumes.append(Resume(name, after, "a GitHub-hosted Ubuntu failover from an older record; left alone"))
            continue
        if (failover is not None and name not in LINUX_VARIABLES and name != PAID_OVERFLOW_VARIABLE
                and name not in failover):
            resumes.append(Resume(name, after, "no failover now; left alone (the record still restores it)"))
            continue
        if (name in LINUX_VARIABLES and started is not None and after not in set(started)
                and not unprobed_trusted(name, after)):
            resumes.append(Resume(name, after, f"{after} did not start a probe in this run; left alone"))
            continue
        if now == before or (now is not None and now == change.get("was")):
            resumes.append(Resume(name, after))
        else:
            resumes.append(Resume(name, after, f"now {now or 'unset'}, not the recorded before {before or 'unset'}; "
                                  "someone changed it, so it is left alone"))
    return resumes


# Where each Linux variable may go, in order.
LINUX_FAILOVER_CHAIN = {LINUX_VARIABLE: (LINUX_FAILOVER, ALTERNATE_FAILOVERS[LINUX_FAILOVER]),
                        TRUSTED_VARIABLE: (TRUSTED_FAILOVER, ALTERNATE_FAILOVERS[TRUSTED_FAILOVER])}


def toward_started(failover: Mapping[str, str], started: Iterable[str]) -> dict[str, str]:
    """Linux failovers, overrides included, name only a Blacksmith label whose probe started.

    A Linux variable whose failover (and every other label in its chain) did
    not start in this run is left alone: moving it onto a size not seen
    serving moves nothing, and may move it onto one seen stalling. The macOS
    failovers are owned pools and are not probed here.
    """
    healthy = set(started)
    values = dict(failover)
    for name in LINUX_VARIABLES:
        if name not in values or values[name] in healthy or unprobed_trusted(name, values[name]):
            continue
        other = next((label for label in LINUX_FAILOVER_CHAIN[name] if label in healthy), None)
        if other is None:
            values.pop(name)
        else:
            values[name] = other
    return values


# Per-label probe health, rewritten by every deciding run: {"checked", "run", "minutes",
# "labels": {label: "started" | "stalled"}}. The switch reads none of it back; it is
# there for whatever routes on per-label health (the RUNNER_POOLS reconciler).
HEALTH_VARIABLE = "CI_CLOUD_LABEL_HEALTH"


def label_health(labels: Sequence[str], stalled: Iterable[str], *, checked: str, run: str,
                 minutes: int) -> dict[str, Any]:
    stalled_set = set(stalled)
    return {"checked": checked, "run": run, "minutes": minutes,
            "labels": {label: "stalled" if label in stalled_set else "started" for label in labels}}


def migrate_hosted_linux(record: Mapping[str, Any], current: Mapping[str, str | None],
                         failover: Mapping[str, str]) -> tuple[dict[str, Any], list[Resume]]:
    """Move a record written when Linux failed over to GitHub-hosted Ubuntu onto today's failover.

    The record keeps each variable's value before; only the destination
    changes. A variable still at the old hosted destination (or at its value
    before, which plan_resume then retries) moves to the new one; one someone
    changed since keeps its old entry and is left alone.
    """
    changed = dict(record.get("changed") or {})
    moves: list[Resume] = []
    for name, change in sorted(changed.items()):
        if name not in LINUX_VARIABLES or not isinstance(change, Mapping):
            continue
        old, new = change.get("after"), failover.get(name)
        if not isinstance(old, str) or not HOSTED_LINUX_LABEL.match(old.lower()) or not new or new == old \
                or "was" in change:
            continue
        now = (current.get(name) or "").strip() or None
        if now == old:
            moves.append(Resume(name, new))
        elif now != change.get("before"):
            continue
        # "was" keeps the hosted destination, so a move that fails after the record
        # is written is still recognised (plan_resume, plan_on) rather than read as a hand edit.
        changed[name] = {**change, "after": new, "was": old}
    return {**record, "changed": changed}, moves


def failover_destinations(record: Mapping[str, Any] | None, probes: Iterable[str]) -> set[str]:
    """Linux labels the switch moved overflow onto: a job queued there has nowhere better to go.

    A label that was also some variable's value before (or the probed one)
    still carries stalled overflow, so it is not one of them.
    """
    changes = [change for name, change in ((record or {}).get("changed") or {}).items()
               if name in LINUX_VARIABLES and isinstance(change, Mapping)]
    afters = {str(change.get("after")) for change in changes if change.get("after")}
    befores = {str(change.get("before")) for change in changes if change.get("before")}
    return afters - befores - set(probes)


def job_started(job: Mapping[str, Any]) -> bool:
    """Whether a runner took the job. A queued job can carry a started_at already, so the runner decides."""
    return bool(job.get("runner_name")) or job.get("status") == "in_progress"


def probe_outcome(job: Mapping[str, Any] | None, now: dt.datetime, minutes: int) -> str:
    """"started", "stalled" (queued past `minutes`), or "waiting"."""
    if job is None:
        return "waiting"
    if job_started(job):
        return "started"
    if job.get("status") == "completed":
        # Cancelled before any runner took it: counted as not served.
        return "stalled"
    created = parse_time(job.get("created_at"))
    if created is not None and (now - created).total_seconds() >= minutes * 60:
        return "stalled"
    return "waiting"


def protected_reason(run: Mapping[str, Any], dead: bool = False) -> str:
    if run.get("event") in PROTECTED_EVENTS:
        return f"{run.get('event')} run"
    if PROTECTED_WORKFLOW.search(f"{run.get('name') or ''} {run.get('path') or ''}"):
        return "release/publish/TestFlight/App Store workflow"
    if dead and DEAD_PROTECTED_WORKFLOW.search(f"{run.get('name') or ''} {run.get('path') or ''}"):
        return "signing/deploy/promotion/rollback/nightly workflow"
    if dead and int(run.get("run_attempt") or 1) >= 2:
        return f"already re-run (attempt {run.get('run_attempt')}); a dead-label rescue tries a run once"
    if int(run.get("run_attempt") or 1) >= MAX_ATTEMPT:
        return f"already on attempt {run.get('run_attempt')}"
    return ""


def stuck_job(jobs: Iterable[Mapping[str, Any]], now: dt.datetime, minutes: int,
              failovers: Iterable[str] = (), linux_moves: bool = True,
              only: Iterable[str] | Mapping[str, int] | None = None) -> Mapping[str, Any] | None:
    """The oldest job queued with no runner on a Blacksmith label for `minutes` or more.

    A job queued on a failover label (another Blacksmith size) already went
    where the switch sends overflow, so re-running it moves nothing. Without
    `linux_moves` (no Linux size started, so no Linux variable has anywhere to
    go), a job on a Blacksmith Linux label would come back on the same label,
    so it is not one either. With `only`, a job counts only on one of those
    labels (the dead labels no pool names any more, dead_labels()).
    """
    skip = {str(label) for label in failovers}
    wanted = None if only is None else {str(label) for label in only}
    # `only` as a mapping gives a label its own wait (stranded_labels(): a moved label waits MOVED_MINUTES).
    waits = {str(label): int(wait) for label, wait in only.items()} if isinstance(only, Mapping) else {}

    def movable(label: str) -> bool:
        return (cloud_label(label) and label not in skip and (linux_moves or not linux_cloud_label(label))
                and (wanted is None or label in wanted))

    stuck = []
    for job in jobs:
        if job.get("status") != "queued" or job.get("runner_name"):
            continue
        labels = [str(label) for label in job.get("labels") or () if movable(str(label))]
        if not labels:
            continue
        wait = max([minutes, *(waits.get(label, minutes) for label in labels)])
        created = parse_time(job.get("created_at"))
        if created is not None and (now - created).total_seconds() >= wait * 60:
            stuck.append((created, job))
    return min(stuck, key=lambda item: item[0])[1] if stuck else None


class GitHubError(RuntimeError):
    """A refused call, with GitHub's own words: `status` is the HTTP code (None for a network error)."""

    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def http_error_text(error: urllib.error.HTTPError) -> str:
    """`403: <GitHub's message>; rate limit 0 left (resource core), resets 03:12:00Z` from a refused call:
    a bare 403 says nothing of whether the token lacks a permission or its pool is spent."""
    parts = [str(error.code)]
    try:
        raw = error.read() or b""
    except (OSError, ValueError, http.client.HTTPException):
        raw = b""
    message = ""
    try:
        body = json.loads(raw) if raw else {}
        message = str(body.get("message") or "") if isinstance(body, dict) else ""
    except ValueError:
        message = raw.decode("utf-8", "replace")
    message = " ".join(message.split())[:300]
    if message:
        parts[0] += f": {message}"
    headers = error.headers
    get = headers.get if headers is not None else (lambda _name: None)
    remaining, resource, reset = get("x-ratelimit-remaining"), get("x-ratelimit-resource"), get("x-ratelimit-reset")
    if remaining is not None:
        limit = f"rate limit {remaining} left" + (f" (resource {resource})" if resource else "")
        if reset and str(reset).isdigit():
            limit += ", resets " + dt.datetime.fromtimestamp(int(reset), dt.timezone.utc).strftime(
                "%H:%M:%SZ")
        parts.append(limit)
    if get("retry-after"):
        parts.append(f"retry after {get('retry-after')} s")
    if get("x-accepted-github-permissions"):
        parts.append(f"needs {get('x-accepted-github-permissions')}")
    return "; ".join(parts)


class GitHub:
    """REST client. With `fallback_token`, reads go out on `token` (the watch's cmux-bot installation token,
    whose pool is its own) and writes on the fallback (the workflow token), so who cancels and re-runs a run
    is unchanged. A refused read is not asked again on the workflow token: that token can never read a
    variable, and its 403 hid the first refusal's cause. Without it, everything uses `token`."""

    def __init__(self, token: str, repo: str, fallback_token: str | None = None) -> None:
        self.repo = repo
        self.token = token
        self.fallback_token = (fallback_token or "").strip() or None
        # path -> (ETag, body) of the last answer to a GET. The watch lists its own run's jobs every POLL_SECONDS
        # for up to PROBE_MINUTES + 5; a conditional read of an unchanged listing answers 304, which GitHub does not
        # count against the token's hourly pool.
        self.etags: dict[str, tuple[str, Any]] = {}

    def _headers(self, token: str) -> dict[str, str]:
        return {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-cloud-overflow-switch",
        }

    def _send(self, method: str, path: str, data: bytes | None, token: str) -> Any:
        headers = self._headers(token)
        if data is not None:
            headers["Content-Type"] = "application/json"
        # An ETag is per URL, not per token: a 304 answers whichever token asked.
        cached = self.etags.get(path) if method == "GET" else None
        if cached:
            headers["If-None-Match"] = cached[0]
        request = urllib.request.Request(f"{API}/repos/{self.repo}{path}", data=data, headers=headers,
                                         method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                result = json.loads(raw) if raw else {}
                etag = response.headers.get("ETag") if method == "GET" else None
                if etag:
                    self.etags[path] = (etag, result)
                return result
        except urllib.error.HTTPError as error:
            if error.code == 304 and cached:
                return cached[1]
            raise

    def request(self, method: str, path: str, body: Any | None = None) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        read = method == "GET"
        token = self.token if read or self.fallback_token is None else self.fallback_token
        where = f"{method} {path.split('?')[0]}"
        try:
            return self._send(method, path, data, token)
        except urllib.error.HTTPError as error:
            raise GitHubError(f"{where} failed ({http_error_text(error)})", error.code) from error
        except urllib.error.URLError as error:
            raise GitHubError(f"{where} failed ({error.reason})") from error
        except (OSError, ValueError, http.client.HTTPException) as error:
            # A read timeout (TimeoutError) or a body that is not JSON: a failed call like any other, so a
            # rescue that already force-cancelled runs still re-runs the rest.
            raise GitHubError(f"{where} failed ({type(error).__name__})") from error

    def jobs(self, run_id: int, attempt: int | None = None) -> list[dict[str, Any]]:
        """Every job of the run (its latest attempt, or `attempt`), or GitHubError when the listing is not complete.

        One page of 100 hid the rest of a bigger run, so a rescue could force-cancel it while a job it never saw was
        running. Only a listing that ends on a short page, with no total_count above what it holds, is complete.
        """
        where = f"/actions/runs/{run_id}/attempts/{attempt}/jobs" if attempt else f"/actions/runs/{run_id}/jobs"
        found: list[dict[str, Any]] = []
        total = 0
        for page in range(1, MAX_JOB_PAGES + 1):
            payload = self.request("GET", f"{where}?per_page=100&page={page}") or {}
            batch = list(payload.get("jobs") or [])
            found.extend(batch)
            if isinstance(payload.get("total_count"), int):
                total = max(total, payload["total_count"])
            if len(batch) < 100:
                if total > len(found):
                    raise GitHubError(f"GET {where} incomplete ({len(found)} of {total} jobs)")
                return found
        raise GitHubError(f"GET {where} incomplete (more than {MAX_JOB_PAGES * 100} jobs)")

    def runs(self, status: str, event: str | None = None, *,
             created_before: dt.datetime | None = None) -> list[dict[str, Any]]:
        query = urllib.parse.urlencode({"status": status, "per_page": 100, **({"event": event} if event else {}),
                                        **({"created": f"<={iso(created_before)}"} if created_before else {})})
        return list(self.request("GET", f"/actions/runs?{query}").get("workflow_runs") or [])

    def run(self, run_id: int) -> dict[str, Any]:
        return self.request("GET", f"/actions/runs/{run_id}")

    def force_cancel(self, run_id: int) -> None:
        # A plain cancel of a run queued on a pool that starts nothing did nothing on 2026-09-29.
        self.request("POST", f"/actions/runs/{run_id}/force-cancel")

    def rerun(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/rerun")

    def get_variable(self, name: str) -> str | None:
        try:
            return self.request("GET", f"/actions/variables/{name}").get("value")
        except RuntimeError as error:
            if getattr(error, "status", None) == 404:
                return None
            raise

    def set_variable(self, name: str, value: str) -> None:
        try:
            self.request("PATCH", f"/actions/variables/{name}", {"name": name, "value": value})
        except RuntimeError as error:
            if getattr(error, "status", None) != 404:
                raise
            self.request("POST", "/actions/variables", {"name": name, "value": value})

    def delete_variable(self, name: str) -> None:
        try:
            self.request("DELETE", f"/actions/variables/{name}")
        except RuntimeError as error:
            if getattr(error, "status", None) != 404:
                raise


def probe_set_outcome(jobs: Iterable[Mapping[str, Any]], labels: Sequence[str], now: dt.datetime,
                      minutes: int) -> tuple[str, list[str]]:
    """The set's outcome once every probe has decided, and the labels that stalled.

    "started": every probe started, so Blacksmith serves every size and an
    existing record is put back. "stalled": none started, so Blacksmith serves
    no size and overflow goes off. "partial": some started and some stalled;
    one stalled size never flips the fleet, and main() clears a record on it
    only when SERVING_PROBE started (the upsize latch, module docstring).
    "waiting": a probe has not decided yet.
    """
    by_name = {str(job.get("name")): job for job in jobs}
    outcomes = {label: probe_outcome(by_name.get(probe_job_name(label)), now, minutes) for label in labels}
    stalled = [label for label, outcome in outcomes.items() if outcome == "stalled"]
    if not outcomes or "waiting" in outcomes.values():
        return "waiting", stalled
    if not stalled:
        return "started", stalled
    if len(stalled) == len(outcomes):
        return "stalled", stalled
    return "partial", stalled


def wait_for_probe(api: GitHub, run_id: int, attempt: int, minutes: int, labels: Sequence[str], *,
                   now: Callable[[], dt.datetime], sleep: Callable[[float], None],
                   log: Callable[[str], None]) -> tuple[str, list[str]]:
    """Watch this run's probe jobs until every one has started or waited `minutes`."""
    deadline = now() + dt.timedelta(minutes=minutes + 5)
    while True:
        try:
            jobs = api.jobs(run_id, attempt)
        except RuntimeError as error:
            log(f"could not list this run's jobs ({error}); trying again")
            jobs = []
        outcome, stalled = probe_set_outcome(jobs, labels, now(), minutes)
        if outcome != "waiting":
            return outcome, stalled
        if now() >= deadline:
            # Never saw every probe decide: nothing measured, so nothing is decided.
            return "unknown", stalled
        sleep(POLL_SECONDS)


def wait_for_health(api: GitHub, run_id: int, attempt: int, minutes: int, labels: Sequence[str], *,
                    deadline: dt.datetime, now: Callable[[], dt.datetime], sleep: Callable[[float], None],
                    log: Callable[[str], None]) -> tuple[list[str], list[str]]:
    """(decided, stalled) for the health-only probes (HEALTH_LABELS beyond PROBE_LABELS), never past `deadline`.

    They decide nothing about overflow; one that never decides is left out of the health."""
    if not labels:
        return [], []
    while True:
        try:
            jobs = api.jobs(run_id, attempt)
        except RuntimeError as error:
            log(f"could not list this run's jobs ({error}); trying again")
            jobs = []
        by_name = {str(job.get("name")): job for job in jobs}
        outcomes = {label: probe_outcome(by_name.get(probe_job_name(label)), now(), minutes) for label in labels}
        decided = [label for label in labels if outcomes[label] != "waiting"]
        if len(decided) == len(labels) or now() >= deadline:
            return decided, [label for label in decided if outcomes[label] == "stalled"]
        sleep(POLL_SECONDS)


def rescue_stuck_runs(api: GitHub, *, own_run_id: int, minutes: int, now: Callable[[], dt.datetime],
                      sleep: Callable[[float], None], log: Callable[[str], None], dry_run: bool,
                      failovers: Iterable[str] = (), linux_moves: bool = True,
                      only: Iterable[str] | Mapping[str, int] | None = None) -> list[str]:
    """Force-cancel and re-run runs holding a job queued on Blacksmith; one line per run touched.

    With `only` (--rescue-dead), push runs are listed and looked at first: one listing holds
    the newest 100 runs, and with thousands queued (2026-11-18) the branch pushes a nightly
    waits on (the cmux-tui tree owners) fell outside it. That mode also protects more
    (protected_reason(dead=True), busy_reason()), touches at most DEAD_MAX_RESCUES runs, and
    cancels and re-runs through _cancel_and_rerun_once().
    """
    lines: list[str] = []
    dead = only is not None
    if isinstance(only, Mapping):
        only = {str(label): int(wait) for label, wait in sorted(only.items())}
    elif only is not None:
        only = sorted({str(label) for label in only})
    seen: dict[int, dict[str, Any]] = {}
    listings = (("queued", "push"), ("in_progress", "push"), ("queued", None), ("in_progress", None)) if dead \
        else (("queued", None), ("in_progress", None))
    for status, event in listings:
        try:
            for run in api.runs(status, event) if event else api.runs(status):
                seen.setdefault(int(run["id"]), run)
        except RuntimeError as error:
            lines.append(f"could not list {status} {event or ''} runs ({error})".replace("  ", " "))
    if dead:
        # The newest page of each listing misses a run stranded for hours under a deep queue: list queued runs
        # created before each OLD_RUN_SLICES_MINUTES too (one call each).
        for age in OLD_RUN_SLICES_MINUTES:
            try:
                for run in api.runs("queued", None, created_before=now() - dt.timedelta(minutes=age)):
                    seen.setdefault(int(run["id"]), run)
            except RuntimeError as error:
                lines.append(f"could not list queued runs older than {age} min ({error})")
    if dead:
        # Protected and already re-run runs leave the window before it is cut, so they cannot fill it
        # pass after pass (a re-run keeps its created_at, so it stays oldest).
        seen = {run_id: run for run_id, run in seen.items() if not protected_reason(run, dead)}
    ordered = sorted((run for run_id, run in seen.items() if run_id != own_run_id),
                     key=lambda run: (dead and run.get("event") != "push", str(run.get("created_at") or "")))
    if dead:
        pushes = [run for run in ordered if run.get("event") == "push"]
        others = [run for run in ordered if run.get("event") != "push"]
        keep_others = others[:max(DEAD_NON_PUSH_LISTINGS, MAX_RUN_LISTINGS - len(pushes))]
        candidates = (pushes[:MAX_RUN_LISTINGS - len(keep_others)] + keep_others)[:MAX_RUN_LISTINGS]
    else:
        candidates = ordered[:MAX_RUN_LISTINGS]
    most = DEAD_MAX_RESCUES if dead else MAX_RESCUES
    chosen: list[tuple[dict[str, Any], Mapping[str, Any]]] = []
    for run in candidates:
        if len(chosen) >= most:
            break
        try:
            jobs = api.jobs(int(run["id"]))
        except RuntimeError as error:
            lines.append(f"run {run['id']}: could not list jobs ({error})")
            continue
        job = stuck_job(jobs, now(), minutes, failovers, linux_moves, only)
        if job is None:
            continue
        why = protected_reason(run, dead) or busy_reason(jobs)
        label = ",".join(str(label) for label in job.get("labels") or ())
        if why:
            lines.append(f"run {run['id']} ({run.get('name')}): `{job.get('name')}` stuck on {label}; left "
                         f"alone ({why})")
            continue
        chosen.append((run, job))
    for run, job in chosen:
        label = ",".join(str(label) for label in job.get("labels") or ())
        lines.append(f"run {run['id']} ({run.get('name')}, {run.get('event')}): `{job.get('name')}` stuck on "
                     f"{label}" + (" (dry run)" if dry_run else ""))
    if dry_run or not chosen:
        return lines
    if dead:
        return lines + _cancel_and_rerun_once(api, chosen, minutes=minutes, now=now, sleep=sleep, log=log,
                                              only=only if only is not None else ())
    cancelled: list[int] = []
    for run, _ in chosen:
        try:
            api.force_cancel(int(run["id"]))
            cancelled.append(int(run["id"]))
        except RuntimeError as error:
            lines.append(f"run {run['id']}: force-cancel failed ({error})")
    deadline = now() + dt.timedelta(seconds=CANCEL_WAIT_SECONDS)
    pending = list(cancelled)
    while pending:
        still: list[int] = []
        for run_id in pending:
            try:
                status = api.run(run_id).get("status")
            except RuntimeError:
                status = None
            if status == "completed":
                try:
                    api.rerun(run_id)
                    lines.append(f"run {run_id}: force-cancelled and re-run")
                except RuntimeError as error:
                    lines.append(f"run {run_id}: force-cancelled, re-run failed ({error}); re-run it by hand")
            else:
                still.append(run_id)
        pending = still
        if pending and now() >= deadline:
            for run_id in pending:
                lines.append(f"run {run_id}: force-cancelled but still finishing after {CANCEL_WAIT_SECONDS} s; "
                             "re-run it by hand")
            break
        if pending:
            sleep(10)
    return lines


def busy_reason(jobs: Iterable[Mapping[str, Any]]) -> str:
    """Why a run must not be cut now: a job of it is running (a runner took it and it has not finished).

    A force-cancel ends every job of the run, so a running one would lose its work and its re-run would start it
    over: the run waits for a later pass. A publish, upload, signing or deploy job is named first.
    """
    running = [job for job in jobs if job.get("status") == "in_progress"
               or (job.get("runner_name") and job.get("status") not in {"completed", "queued"})]
    for job in sorted(running, key=lambda job: not DEAD_BUSY_JOB.search(str(job.get("name") or ""))):
        return f"`{job.get('name')}` is running"
    return ""


def _http_code(error: RuntimeError) -> int | None:
    found = re.search(r"failed \((\d{3})\)", str(error))
    return int(found.group(1)) if found else None


def _cancel_and_rerun_once(api: GitHub, chosen: Sequence[tuple[Mapping[str, Any], Mapping[str, Any]]], *,
                           minutes: int, now: Callable[[], dt.datetime], sleep: Callable[[float], None],
                           log: Callable[[str], None], only: Iterable[str] | Mapping[str, int]) -> list[str]:
    """--rescue-dead's cancel and re-run.

    - Each run is read again first: one re-run or started since the listing is left alone.
    - The re-run is a whole one (`/rerun`), never rerun-failed-jobs: that keeps the outputs of jobs that
      passed, and a planner's output can name the dead label (cmux-tui-build-package.yml's plan-build
      writes LINUX_RUNNER into the build matrix), so the build would queue there again.
    - A force-cancel whose answer was lost (no HTTP status, or a 5xx) may have gone through: the run is
      watched like a cancelled one and re-run only if it ends cancelled. A 4xx refusal is final.
    """
    lines: list[str] = []
    pending: dict[int, bool] = {}  # run id -> whether the cancel is known to have gone through
    for run, _ in chosen:
        run_id = int(run["id"])
        try:
            current = api.run(run_id)
            jobs = api.jobs(run_id)
            still = (current.get("status") != "completed"
                     and int(current.get("run_attempt") or 1) == int(run.get("run_attempt") or 1)
                     and stuck_job(jobs, now(), minutes, only=only) is not None and not busy_reason(jobs))
        except RuntimeError as error:
            lines.append(f"run {run_id}: could not read it again ({error}); left alone")
            continue
        if not still:
            lines.append(f"run {run_id}: changed since it was listed; left alone")
            continue
        try:
            api.force_cancel(run_id)
            pending[run_id] = True
            # Logged now: if the step is killed before the re-run, its log still names the run.
            log(f"run {run_id}: force-cancelled; re-running it once it ends")
        except RuntimeError as error:
            code = _http_code(error)
            if code is not None and code < 500:
                lines.append(f"run {run_id}: force-cancel refused ({error})")
                continue
            pending[run_id] = False
            log(f"run {run_id}: force-cancel answer lost ({error}); re-running it only if it ends cancelled")
    deadline = now() + dt.timedelta(seconds=DEAD_CANCEL_WAIT_SECONDS)
    while pending:
        for run_id, known in list(pending.items()):
            try:
                current = api.run(run_id)
            except RuntimeError:
                continue
            if current.get("status") != "completed":
                continue
            del pending[run_id]
            if not known and current.get("conclusion") != "cancelled":
                lines.append(f"run {run_id}: ended {current.get('conclusion')}; the cancel did not take, no re-run")
                continue
            try:
                api.rerun(run_id)
                lines.append(f"run {run_id}: force-cancelled and re-run")
            except RuntimeError as error:
                lines.append(f"run {run_id}: force-cancelled, re-run failed ({error}); re-run it by hand")
        if pending and now() >= deadline:
            for run_id in pending:
                lines.append(f"run {run_id}: force-cancelled but still finishing after {DEAD_CANCEL_WAIT_SECONDS} s; "
                             "re-run it by hand")
            break
        if pending:
            sleep(10)
    return lines


POOLS_VARIABLE = "RUNNER_POOLS"
POOLS_DEAD_KEY = "_dead"


def dead_labels(pools_value: Mapping[str, Any]) -> set[str]:
    """Blacksmith labels RUNNER_POOLS marks dead and no pool points at any more.

    runner_pools.py moves each pool off a label it marks dead, so a run that picks its
    runner again lands on a live one; but a job already queued on that label keeps it
    and waits forever. On 2026-11-18 (09:32Z) 4, 8 and 16 vCPU were marked dead while
    2 and 32 vCPU served: an outcome this switch leaves to per-size routing, and the
    cmux-tui tree owners queued there held the NEXT nightly for hours until they were
    cancelled and re-run by hand. A dead label a pool still names is skipped: a re-run
    would come back to it, and so is any macOS label (below).
    """
    marks = pools_value.get(POOLS_DEAD_KEY)
    if not isinstance(marks, Mapping):
        return set()
    routed = {str(value) for key, value in pools_value.items() if not str(key).startswith("_")}
    # Linux only: a MACOS_RUNNER_* variable (which runner_pools.py never moves) can still name a dead
    # macOS label, and a re-run would go straight back to it.
    return {str(label) for label in marks if linux_cloud_label(str(label)) and str(label) not in routed}


def raw_named(env: Mapping[str, str]) -> set[str]:
    """The labels the raw runner variables name (RAW_RUNNER_VARIABLES_ENV, NAME=value lines)."""
    named = set()
    for line in str(env.get(RAW_RUNNER_VARIABLES_ENV) or "").splitlines():
        _, _, value = line.partition("=")
        if value.strip():
            named.add(value.strip())
    return named


# The Blacksmith macOS labels a pool or a picker may have sent jobs to. No probe marks one dead, so one is stranded only
# when a pool move left it (stranded_labels()) and no runner variable names it. 2026-11-27 23:4xZ:
# blacksmith-12vcpu-macos-26 held 18 queued jobs, oldest 238 min, 0 started in 1 h, while every pool and variable
# named another label, and this rescue looked only at Linux sizes.
MACOS_CLOUD_LABELS = ("blacksmith-6vcpu-macos-15", "blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26",
                      "blacksmith-6vcpu-macos-latest")
MACOS_RUNNER_VARIABLES_ENV = "MACOS_RUNNER_VARIABLES"


def stranded_labels(pools_value: Mapping[str, Any], named: Iterable[str] = (), *,
                    minutes: int = DEFAULT_PROBE_MINUTES) -> dict[str, int]:
    """Each Blacksmith label a job may be stranded on, with how long its jobs wait before a re-run.

    A label is stranded when no pool names it now (and no raw runner variable, `named`), so a re-run picks another:
    - marked dead (dead_labels()): after `minutes`, the probe's wait, as before;
    - otherwise a label a pool can point at (HEALTH_LABELS, a `_spill` record's `from`) that no pool names: a move
      left it, by runner_pools.py, linux_pool_spill.py or a hand edit of RUNNER_POOLS. It may still start jobs, so
      after MOVED_MINUTES.
    - a Blacksmith macOS label (MACOS_CLOUD_LABELS) no pool names, after MOVED_MINUTES: a macOS pool member a
      pool moved off, or one a picker names literally. `named` must then carry the MACOS_RUNNER_* values
      (rescue_dead() reads MACOS_RUNNER_VARIABLES_ENV), since a re-run would go back to a label one names.
    Reading the state after the move, not each writer's move, covers every writer, a hand edit included.
    """
    pooled = {str(value) for key, value in pools_value.items() if not str(key).startswith("_")}
    routed = pooled | set(named)
    out = {label: minutes for label in dead_labels(pools_value) if label not in routed}
    if not pooled:
        # An unset or empty value names no pool: every label would read as left. Its readers take their defaults.
        return out
    candidates = set(HEALTH_LABELS)
    spills = pools_value.get("_spill")
    if isinstance(spills, Mapping):
        candidates |= {str(spill.get("from")) for spill in spills.values() if isinstance(spill, Mapping)}
    for label in candidates:
        if linux_cloud_label(label) and label not in routed and label not in out:
            out[label] = max(minutes, MOVED_MINUTES)
    if any(str(value) in MACOS_CLOUD_LABELS for value in pooled):
        # Only once RUNNER_POOLS carries the macOS pools: a value written before them names no macOS label at all.
        for label in MACOS_CLOUD_LABELS:
            if label not in routed and label not in out:
                out[label] = max(minutes, MOVED_MINUTES)
    return dict(sorted(out.items()))


def rescue_dead(api: GitHub, switch: GitHub | None, env: Mapping[str, str], *, own_run_id: int, minutes: int,
                now: Callable[[], dt.datetime], sleep: Callable[[float], None], log: Callable[[str], None],
                dry_run: bool) -> int:
    """`--rescue-dead`: after the pools step, re-run runs stranded on a label no pool names (stranded_labels())."""
    raw = None
    fresh = False
    if switch is not None:
        try:
            raw = switch.get_variable(POOLS_VARIABLE) or ""  # None: the API says the variable is unset
            fresh = True
        except RuntimeError as error:
            log(f"::warning title=Dead label rescue::could not read {POOLS_VARIABLE} ({error})")
    if not fresh:
        # The job-start value predates the pools step, which may have cleared or added a mark since: it may
        # only describe what a live pass would do, never cancel anything.
        if not dry_run:
            log(f"no live {POOLS_VARIABLE} read (switch token missing or refused); nothing cancelled this pass")
            return 0
        raw = env.get(POOLS_VARIABLE) or ""
    try:
        value = json.loads(raw) if raw.strip() else {}
    except ValueError:
        log(f"::warning title=Dead label rescue::{POOLS_VARIABLE} is not JSON; nothing to rescue")
        return 0
    named = raw_named(env) | raw_named({RAW_RUNNER_VARIABLES_ENV: env.get(MACOS_RUNNER_VARIABLES_ENV) or ""})
    labels = stranded_labels(value if isinstance(value, Mapping) else {}, named, minutes=minutes)
    if not labels:
        log(f"no Blacksmith label off every pool in {POOLS_VARIABLE}; nothing to rescue")
        return 0
    log("labels no pool names: " + ", ".join(f"{label} ({wait}+ min)" for label, wait in labels.items())
        + "; re-running runs queued there that long")
    for line in rescue_stuck_runs(api, own_run_id=own_run_id, minutes=minutes, now=now, sleep=sleep, log=log,
                                  dry_run=dry_run, only=labels):
        log(f"- {line}")
    return 0


RUNNER_VARIABLES_ENV = "CMUX_CI_RUNNER_VARIABLES"


def current_values(env: Mapping[str, str], names: Iterable[str]) -> dict[str, str | None]:
    """The live values the workflow passed from its expression context; '' is unset.

    The runner variables come as NAME=value lines in CMUX_CI_RUNNER_VARIABLES
    (the format ci-repo-variables.yml uses); any other name as `VAR_<name>`.
    """
    block: dict[str, str] = {}
    for line in (env.get(RUNNER_VARIABLES_ENV) or "").splitlines():
        name, separator, value = line.strip().partition("=")
        if separator and name:
            block[name] = value
    return {name: (block.get(name, env.get(f"VAR_{name}")) or "").strip() or None for name in names}


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, *,
         api: GitHub | None = None, switch: GitHub | None = None,
         now: Callable[[], dt.datetime] = lambda: dt.datetime.now(UTC),
         sleep: Callable[[float], None] = time.sleep) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true",
                        default=(env.get("DRY_RUN", "").strip().lower() in {"1", "true", "yes"}))
    parser.add_argument("--rescue-dead", action="store_true",
                        help="only re-run runs stranded on a RUNNER_POOLS dead label no pool names (dead_labels())")
    args = parser.parse_args(argv)
    lines: list[str] = []

    def log(message: str) -> None:
        print(message, flush=True)
        lines.append(message)

    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    run_id = int(env.get("GITHUB_RUN_ID") or 0)
    attempt = int(env.get("GITHUB_RUN_ATTEMPT") or 1)
    token = env.get("GH_TOKEN") or ""
    if api is None:
        if not token or not repo or not run_id:
            print("cloud-overflow-switch: GH_TOKEN, GH_REPO and GITHUB_RUN_ID are required", file=sys.stderr)
            return 2
        api = GitHub(token, repo, env.get("GH_FALLBACK_TOKEN"))
    if switch is None and (env.get("SWITCH_TOKEN") or "").strip():
        switch = GitHub(str(env["SWITCH_TOKEN"]).strip(), repo)
    minutes = probe_minutes(env.get("PROBE_MINUTES"))
    if args.rescue_dead:
        code = rescue_dead(api, switch, env, own_run_id=run_id, minutes=minutes, now=now, sleep=sleep, log=log,
                           dry_run=args.dry_run)
        write_summary(env, lines)
        return code
    try:
        record = parse_record(env.get(f"VAR_{RECORD_VARIABLE}"))
    except ValueError as error:
        log(f"::error title=Cloud overflow switch::{error}; fix or delete {RECORD_VARIABLE} by hand")
        write_summary(env, lines)
        return 1
    failover, problems = failover_values(env.get(f"VAR_{pr_runner_pool.PR_XCODE_VARIABLE}"),
                                         env.get(f"VAR_{OVERRIDES_VARIABLE}"))
    for problem in problems:
        log(f"::warning title=Cloud overflow switch::{problem}")
    names = sorted(set(SWITCHED_VARIABLES) | set(failover) | set((record or {}).get("changed") or {}))
    current = current_values(env, names)
    labels: tuple[str, ...] = PROBE_LABELS
    drill = (env.get("PROBE_LABEL_DRILL") or "").strip()
    if drill:
        # A drill (workflow_dispatch probe_label) probes another label and never writes.
        labels, args.dry_run = (drill,), True
        log(f"drill: probing {drill} instead; a dry run whatever it finds")
    label = ", ".join(labels)
    state = f"off since {record.get('since')}" if record else "on"
    log(f"Blacksmith overflow is {state}; probing {label} (a stall is every probe queued {minutes} min with no "
        "runner)")

    health_deadline = now() + dt.timedelta(minutes=minutes + 5)
    outcome, stalled = wait_for_probe(api, run_id, attempt, minutes, labels, now=now, sleep=sleep, log=log)
    extra = () if drill else tuple(item for item in HEALTH_LABELS if item not in labels)
    extra_decided, extra_stalled = wait_for_health(api, run_id, attempt, minutes, extra, deadline=health_deadline,
                                                   now=now, sleep=sleep, log=log)
    stamp = iso(now())
    code = 0
    started = [item for item in labels if item not in stalled] if outcome != "unknown" else []
    failover = toward_started(failover, started)
    if outcome != "unknown" and not args.dry_run and switch is not None:
        health = label_health([*labels, *extra_decided], [*stalled, *extra_stalled], checked=stamp,
                              run=f"https://github.com/{repo}/actions/runs/{run_id}", minutes=minutes)
        try:
            switch.set_variable(HEALTH_VARIABLE, json.dumps(health, sort_keys=True))
        except RuntimeError as error:
            # Reporting only: the switch decides from this run's probes, never from this variable.
            log(f"::warning title=Cloud overflow switch::could not write {HEALTH_VARIABLE} ({error})")
    if outcome == "unknown":
        log("::warning title=Cloud overflow switch::never saw every probe job decide; nothing decided")
    elif outcome == "partial" and not (record and SERVING_PROBE in started):
        log(f"{stamp}: {', '.join(stalled)} waited {minutes} min with no runner while the other sizes started; "
            f"overflow stays {'off' if record else 'on'}; nothing changes (per-size routing reads "
            f"{HEALTH_VARIABLE})")
    elif outcome in ("started", "partial"):
        if outcome == "started":
            log(f"{stamp}: every probe started ({label}); Blacksmith is serving")
        else:
            log(f"{stamp}: {SERVING_PROBE} started while {', '.join(stalled)} waited {minutes} min with no runner; "
                f"Blacksmith is serving, so the record goes back (a stalled larger size is per-size routing's, "
                f"{HEALTH_VARIABLE}); keeping it would hold every overflow reader on the larger sizes")
        if record:
            restores = plan_on(record, current, started)
            if args.dry_run:
                for item in restores:
                    if item.skipped:
                        log(f"- {item.name}: {item.skipped}")
                    else:
                        log(f"- {item.name}: would restore {item.value or 'unset'} (dry run)")
            elif switch is None:
                log("::error title=Cloud overflow switch::no switch token (GLAEDA_ROUTE_APP_ID); overflow "
                    "stays off. Turn it back on by hand: " + "; ".join(
                        f"{r.name} -> {r.value or 'unset'}" for r in restores if not r.skipped))
                code = 1
            else:
                for item in restores:
                    if item.skipped:
                        log(f"- {item.name}: {item.skipped}")
                    else:
                        (switch.set_variable(item.name, item.value) if item.value
                         else switch.delete_variable(item.name))
                        log(f"- {item.name}: restored {item.value or 'unset'}")
                switch.delete_variable(RECORD_VARIABLE)
                log(f"overflow back on; {RECORD_VARIABLE} deleted (it was off since {record.get('since')})")
    else:
        log(f"{stamp}: every probe waited {minutes} min on {label} with no runner; Blacksmith is not serving")
        if not record:
            changed = plan_off(current, failover)
            new_record = {"since": stamp, "probe": label, "reason": f"every probe on {label} queued {minutes} "
                          "min with no runner", "run": f"https://github.com/{repo}/actions/runs/{run_id}",
                          "changed": changed}
            if args.dry_run:
                for name, change in changed.items():
                    log(f"- {name}: would set {change['after']} (was {change['before'] or 'unset'}; dry run)")
            elif switch is None:
                log("::error title=Cloud overflow switch::no switch token (GLAEDA_ROUTE_APP_ID); overflow "
                    "stays on. Turn it off by hand: " + "; ".join(
                        f"{name} -> {change['after']}" for name, change in changed.items()))
                code = 1
            else:
                # The record first: a failure halfway still leaves what to put back.
                switch.set_variable(RECORD_VARIABLE, json.dumps(new_record, sort_keys=True))
                for name, change in changed.items():
                    switch.set_variable(name, str(change["after"]))
                    log(f"- {name}: {change['before'] or 'unset'} -> {change['after']}")
                log(f"overflow off; {RECORD_VARIABLE} holds the values to put back")
                record = new_record
        else:
            migrated, moves = migrate_hosted_linux(record, current, failover)
            if migrated != record:
                if args.dry_run:
                    for item in moves:
                        log(f"- {item.name}: would move from GitHub-hosted Ubuntu to {item.value} (dry run)")
                elif switch is None:
                    log("::error title=Cloud overflow switch::no switch token (GLAEDA_ROUTE_APP_ID); Linux "
                        "overflow stays on GitHub-hosted Ubuntu. Move it by hand: " + "; ".join(
                            f"{item.name} -> {item.value}" for item in moves) + f", and update {RECORD_VARIABLE}")
                    code = 1
                else:
                    # The record first, as for a new switch: a failure halfway still knows the way back.
                    switch.set_variable(RECORD_VARIABLE, json.dumps(migrated, sort_keys=True))
                    for item in moves:
                        switch.set_variable(item.name, item.value)
                        log(f"- {item.name}: moved from GitHub-hosted Ubuntu to {item.value}")
                    record = migrated
                    current = {**current, **{item.name: item.value for item in moves}}
            resumes = plan_resume(migrated if args.dry_run else record, current, started, failover)
            if args.dry_run:
                for item in resumes:
                    if item.skipped:
                        log(f"- {item.name}: {item.skipped}")
                    else:
                        log(f"- {item.name}: would retry {item.value} (dry run)")
            elif switch is None and any(not item.skipped for item in resumes):
                log("::error title=Cloud overflow switch::no switch token (GLAEDA_ROUTE_APP_ID); the recorded "
                    "failover is incomplete and stays as-is")
                code = 1
            elif switch is not None:
                for item in resumes:
                    if item.skipped:
                        log(f"- {item.name}: {item.skipped}")
                    else:
                        switch.set_variable(item.name, item.value)
                        log(f"- {item.name}: retried {item.value}")
        if record or args.dry_run:
            for line in rescue_stuck_runs(api, own_run_id=run_id, minutes=minutes, now=now, sleep=sleep,
                                          log=log, dry_run=args.dry_run,
                                          linux_moves=bool(started),
                                          failovers=failover_destinations(
                                              record or {"changed": plan_off(current, failover)}, labels)):
                log(f"- {line}")
    out = env.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as handle:
            handle.write(f"outcome={outcome}\n")
            # Whether every probe job, health-only ones included, started: otherwise one may still be
            # queued, and the workflow's last step force-cancels this run so it frees the concurrency group.
            every = outcome == "started" and len(extra_decided) == len(extra) and not extra_stalled
            handle.write(f"all_started={'true' if every else 'false'}\n")
    write_summary(env, lines)
    return code


def write_summary(env: Mapping[str, str], lines: Sequence[str]) -> None:
    path = env.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("### Blacksmith overflow switch\n\n")
        handle.write("\n".join(line if line.startswith("- ") else f"{line}\n" for line in lines) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
