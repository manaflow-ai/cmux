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
macOS, waits for them:

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
- Some start and some do not: nothing changes. One stalled size never flips
  the fleet, and a record is not cleared while a size is still stalled. A
  size stalling alone is for that size's own failover, not this switch.

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
# Where Linux overflow goes while the probed label stalls: another Blacksmith
# Linux size, never GitHub-hosted Ubuntu. CI_TRUSTED_RUNNER's readers accept
# only ubuntu-24.04 and the 2 and 4 vCPU labels (docs/ci-runners.md), so it
# takes 2 vCPU.
LINUX_FAILOVER = "blacksmith-16vcpu-ubuntu-2404"
TRUSTED_FAILOVER = "blacksmith-2vcpu-ubuntu-2404"
# When the probed label is that failover itself, the other size: a probed one, so
# toward_started() can pick it, and one the bounded LINUX_RUNNER selectors accept.
ALTERNATE_FAILOVERS = {LINUX_FAILOVER: "blacksmith-4vcpu-ubuntu-2404",
                       TRUSTED_FAILOVER: "blacksmith-4vcpu-ubuntu-2404"}
# The only Blacksmith labels CI_TRUSTED_RUNNER's readers accept.
TRUSTED_BLACKSMITH_LABELS = frozenset({"blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"})
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
STD_VARIABLES = ("MACOS_RUNNER_15", "MACOS_RUNNER_26", "MACOS_RUNNER_26_LARGE", "MACOS_RUNNER_PR",
                 "MACOS_RUNNER_DUAL_XCODE")
GUI_VARIABLE = "MACOS_RUNNER_DISPLAY"
IOS_VARIABLE = "MACOS_RUNNER_IOS"
SWITCHED_VARIABLES = (*LINUX_VARIABLES, *STD_VARIABLES, GUI_VARIABLE, IOS_VARIABLE, PAID_OVERFLOW_VARIABLE)
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
                elif name == TRUSTED_VARIABLE and value.strip() not in TRUSTED_BLACKSMITH_LABELS:
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
        if healthy is not None and name in LINUX_VARIABLES and (before or "") not in healthy:
            restores.append(Restore(name, before, f"stays {now or 'unset'}; its value before, {before or 'unset'}, "
                                                  "is not a size whose probe started"))
            continue
        restores.append(Restore(name, before))
    return restores


def plan_resume(record: Mapping[str, Any], current: Mapping[str, str | None],
                started: Iterable[str] | None = None) -> list[Resume]:
    """What a stalled probe should retry after a partial failover write.

    A value still at the recorded ``before`` value was never switched, so it
    is safe to apply its recorded failover. Any other value is either already
    at ``after`` or was edited by someone else and is left alone. A record
    written before signing variables were kept ephemeral may name one with an
    owned ``after``; that is never applied (on 2026-10-28 a retry re-applied
    MACOS_RUNNER_26 eight minutes after it was put back by hand).
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
        if name in LINUX_VARIABLES and started is not None and after not in set(started):
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
        if name not in values or values[name] in healthy:
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


def protected_reason(run: Mapping[str, Any]) -> str:
    if run.get("event") in PROTECTED_EVENTS:
        return f"{run.get('event')} run"
    if PROTECTED_WORKFLOW.search(f"{run.get('name') or ''} {run.get('path') or ''}"):
        return "release/publish/TestFlight/App Store workflow"
    if int(run.get("run_attempt") or 1) >= MAX_ATTEMPT:
        return f"already on attempt {run.get('run_attempt')}"
    return ""


def stuck_job(jobs: Iterable[Mapping[str, Any]], now: dt.datetime, minutes: int,
              failovers: Iterable[str] = (), linux_moves: bool = True) -> Mapping[str, Any] | None:
    """The oldest job queued with no runner on a Blacksmith label for `minutes` or more.

    A job queued on a failover label (another Blacksmith size) already went
    where the switch sends overflow, so re-running it moves nothing. Without
    `linux_moves` (no Linux size started, so no Linux variable has anywhere to
    go), a job on a Blacksmith Linux label would come back on the same label,
    so it is not one either.
    """
    skip = {str(label) for label in failovers}

    def movable(label: str) -> bool:
        return cloud_label(label) and label not in skip and (linux_moves or not linux_cloud_label(label))

    stuck = []
    for job in jobs:
        if job.get("status") != "queued" or job.get("runner_name"):
            continue
        if not any(movable(str(label)) for label in job.get("labels") or ()):
            continue
        created = parse_time(job.get("created_at"))
        if created is not None and (now - created).total_seconds() >= minutes * 60:
            stuck.append((created, job))
    return min(stuck, key=lambda item: item[0])[1] if stuck else None


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-cloud-overflow-switch",
        }

    def request(self, method: str, path: str, body: Any | None = None) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        headers = dict(self.headers)
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(f"{API}/repos/{self.repo}{path}", data=data, headers=headers,
                                         method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.code})") from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.reason})") from error

    def jobs(self, run_id: int, attempt: int | None = None) -> list[dict[str, Any]]:
        where = f"/actions/runs/{run_id}/attempts/{attempt}/jobs" if attempt else f"/actions/runs/{run_id}/jobs"
        return list(self.request("GET", f"{where}?per_page=100").get("jobs") or [])

    def runs(self, status: str) -> list[dict[str, Any]]:
        query = urllib.parse.urlencode({"status": status, "per_page": 100})
        return list(self.request("GET", f"/actions/runs?{query}").get("workflow_runs") or [])

    def run(self, run_id: int) -> dict[str, Any]:
        return self.request("GET", f"/actions/runs/{run_id}")

    def force_cancel(self, run_id: int) -> None:
        # A plain cancel of a run queued on a pool that starts nothing did nothing on 2026-09-29.
        self.request("POST", f"/actions/runs/{run_id}/force-cancel")

    def rerun(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/rerun")

    def set_variable(self, name: str, value: str) -> None:
        try:
            self.request("PATCH", f"/actions/variables/{name}", {"name": name, "value": value})
        except RuntimeError as error:
            if "(404)" not in str(error):
                raise
            self.request("POST", "/actions/variables", {"name": name, "value": value})

    def delete_variable(self, name: str) -> None:
        try:
            self.request("DELETE", f"/actions/variables/{name}")
        except RuntimeError as error:
            if "(404)" not in str(error):
                raise


def probe_set_outcome(jobs: Iterable[Mapping[str, Any]], labels: Sequence[str], now: dt.datetime,
                      minutes: int) -> tuple[str, list[str]]:
    """The set's outcome once every probe has decided, and the labels that stalled.

    "started": every probe started, so Blacksmith serves every size and an
    existing record is put back. "stalled": none started, so Blacksmith serves
    no size and overflow goes off. "partial": some started and some stalled;
    nothing changes either way, so one stalled size never flips the fleet and
    a record is not cleared while a size jobs fall back from is still stalled.
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


def rescue_stuck_runs(api: GitHub, *, own_run_id: int, minutes: int, now: Callable[[], dt.datetime],
                      sleep: Callable[[float], None], log: Callable[[str], None], dry_run: bool,
                      failovers: Iterable[str] = (), linux_moves: bool = True) -> list[str]:
    """Force-cancel and re-run runs holding a job queued on Blacksmith; one line per run touched."""
    lines: list[str] = []
    seen: dict[int, dict[str, Any]] = {}
    for status in ("queued", "in_progress"):
        try:
            for run in api.runs(status):
                seen.setdefault(int(run["id"]), run)
        except RuntimeError as error:
            lines.append(f"could not list {status} runs ({error})")
    candidates = sorted((run for run_id, run in seen.items() if run_id != own_run_id),
                        key=lambda run: str(run.get("created_at") or ""))[:MAX_RUN_LISTINGS]
    chosen: list[tuple[dict[str, Any], Mapping[str, Any]]] = []
    for run in candidates:
        if len(chosen) >= MAX_RESCUES:
            break
        try:
            job = stuck_job(api.jobs(int(run["id"])), now(), minutes, failovers, linux_moves)
        except RuntimeError as error:
            lines.append(f"run {run['id']}: could not list jobs ({error})")
            continue
        if job is None:
            continue
        why = protected_reason(run)
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
        api = GitHub(token, repo)
    if switch is None and (env.get("SWITCH_TOKEN") or "").strip():
        switch = GitHub(str(env["SWITCH_TOKEN"]).strip(), repo)
    minutes = probe_minutes(env.get("PROBE_MINUTES"))
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

    outcome, stalled = wait_for_probe(api, run_id, attempt, minutes, labels, now=now, sleep=sleep, log=log)
    stamp = iso(now())
    code = 0
    started = [item for item in labels if item not in stalled] if outcome != "unknown" else []
    failover = toward_started(failover, started)
    if outcome != "unknown" and not args.dry_run and switch is not None:
        health = label_health(labels, stalled, checked=stamp, run=f"https://github.com/{repo}/actions/runs/{run_id}",
                              minutes=minutes)
        try:
            switch.set_variable(HEALTH_VARIABLE, json.dumps(health, sort_keys=True))
        except RuntimeError as error:
            # Reporting only: the switch decides from this run's probes, never from this variable.
            log(f"::warning title=Cloud overflow switch::could not write {HEALTH_VARIABLE} ({error})")
    if outcome == "unknown":
        log("::warning title=Cloud overflow switch::never saw every probe job decide; nothing decided")
    elif outcome == "partial":
        log(f"{stamp}: {', '.join(stalled)} waited {minutes} min with no runner while the other sizes started; "
            f"overflow stays {'off' if record else 'on'}; nothing changes (per-size routing reads "
            f"{HEALTH_VARIABLE})")
    elif outcome == "started":
        log(f"{stamp}: every probe started ({label}); Blacksmith is serving")
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
            resumes = plan_resume(migrated if args.dry_run else record, current, started)
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
