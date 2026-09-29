#!/usr/bin/env python3
"""Turn Blacksmith overflow off while Blacksmith starts no job, and back on once it does.

Blacksmith is overflow: the owned minis come first (docs/ci-runners.md,
"minis first"), and the runner variables (LINUX_RUNNER, MACOS_RUNNER_*,
gated by CI_PAID_MACOS_OVERFLOW) name what every job the minis do not take
lands on. On 2026-09-29 Blacksmith stopped starting jobs org-wide from about
10:15Z; about 150 runs sat queued for two hours until someone pointed those
variables at the owned pools and GitHub-hosted Linux by hand.

ci-cloud-overflow-probe.yml runs this every 10 minutes. Its `probe` job asks
for one Blacksmith label (the record's `probe`, else LINUX_RUNNER when it is
a Blacksmith label, else the Blacksmith Linux fallback every workflow bakes
in) and only prints a line. This script, in the `watch` job on a
GitHub-hosted runner, waits for it:

- The probe starts within PROBE_MINUTES of being queued: Blacksmith serves.
  If this switch turned overflow off (the CI_CLOUD_OVERFLOW_SAVED record
  exists), every variable it changed is put back, unless someone changed that
  variable since, and the record is deleted.
- It does not: Blacksmith is not serving. Unless overflow is already off,
  the record is written first (what each variable held, what it gets, when
  and why), then each variable is pointed at its failover. Then, if it is
  cheap, runs already stuck on a Blacksmith label are force-cancelled and
  re-run so they pick their runners again. The workflow then force-cancels
  its own run, whose probe would otherwise stay queued.

One probe, one switch: the only state is the variables and the record. The
failover of each variable (failover_values()) is derived from the lane's
Xcode pin, the same way pr_runner_pool.py names owned pools: the macOS
capability variables take the std owned pool (the GUI one for
MACOS_RUNNER_DISPLAY, the simulator capability label for MACOS_RUNNER_IOS),
and LINUX_RUNNER takes GitHub-hosted ubuntu-24.04. CI_CLOUD_FAILOVER (JSON,
variable name to value, "" to leave one alone) overrides any of them. Only a
variable that is unset (its readers then fall back to Blacksmith) or holds a
blacksmith-* label is changed, so a lane someone deliberately pointed
elsewhere is left alone. Nothing here touches the lane switches
(CI_PR_POOL_OWNED, CI_E2E_OWNED_UI, CI_IOS_OWNED, ...): minis-first routing
never changes, only where overflow goes.
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

API = "https://api.github.com"
UTC = dt.timezone.utc

RECORD_VARIABLE = "CI_CLOUD_OVERFLOW_SAVED"
OVERRIDES_VARIABLE = "CI_CLOUD_FAILOVER"
PAID_OVERFLOW_VARIABLE = "CI_PAID_MACOS_OVERFLOW"
CLOUD_PREFIX = pr_runner_pool.EPHEMERAL_PREFIX  # "blacksmith-"
# Every workflow's fallback when LINUX_RUNNER is unset (docs/ci-runners.md).
DEFAULT_PROBE_LABEL = "blacksmith-4vcpu-ubuntu-2404"
HOSTED_LINUX = "ubuntu-24.04"
LINUX_VARIABLE = "LINUX_RUNNER"
# The runner variables whose unset fallback is a Blacksmith label, and so the
# ones that carry overflow. MACOS_RUNNER_TESTS falls back per lane (the E2E
# lane goes through e2e_runner_pool.py, the iOS lane through
# MACOS_RUNNER_IOS) and MACOS_RUNNER_BACKGROUND is GitHub-hosted, so neither
# is here; CI_CLOUD_FAILOVER can add one.
STD_VARIABLES = ("MACOS_RUNNER_15", "MACOS_RUNNER_26", "MACOS_RUNNER_26_LARGE", "MACOS_RUNNER_PR",
                 "MACOS_RUNNER_DUAL_XCODE")
GUI_VARIABLE = "MACOS_RUNNER_DISPLAY"
IOS_VARIABLE = "MACOS_RUNNER_IOS"
SWITCHED_VARIABLES = (LINUX_VARIABLE, *STD_VARIABLES, GUI_VARIABLE, IOS_VARIABLE, PAID_OVERFLOW_VARIABLE)
# What CI_CLOUD_FAILOVER may name: the workflow passes each one's live value,
# so a restore never guesses what a variable held.
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


def probe_label(record: Mapping[str, Any] | None, linux_runner: str | None) -> str:
    """The Blacksmith label a probe asks for; the workflow's runs-on restates this."""
    saved = (record or {}).get("probe")
    if cloud_label(saved):
        return str(saved)
    if cloud_label(linux_runner):
        return str(linux_runner)
    return DEFAULT_PROBE_LABEL


def parse_record(raw: str | None) -> dict[str, Any] | None:
    """The switch's record, or None when overflow is on. An unreadable record raises."""
    if not (raw or "").strip():
        return None
    record = json.loads(str(raw))
    if not isinstance(record, dict) or not isinstance(record.get("changed"), dict):
        raise ValueError(f"{RECORD_VARIABLE} is not a switch record")
    return record


def failover_values(xcode_app_pr: str | None, overrides: str | None) -> tuple[dict[str, str], list[str]]:
    """What each overflow variable points at while Blacksmith is down, and any problems.

    The owned labels come from the lane's Xcode pin exactly as the picker
    names its pools, so moving the pin moves the failover. Without a pin the
    macOS variables are left alone (named in the problems).
    """
    problems: list[str] = []
    values: dict[str, str] = {LINUX_VARIABLE: HOSTED_LINUX}
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
                elif cloud_label(value.strip()):
                    problems.append(f"{OVERRIDES_VARIABLE} points {name} at {value.strip()}, a Blacksmith label; "
                                    "ignored")
                else:
                    values[name] = value.strip()
    if any(name != LINUX_VARIABLE for name in values):
        # MACOS_RUNNER_15, _26 and friends are read only when this is 1.
        values[PAID_OVERFLOW_VARIABLE] = "1"
    return values, problems


def plan_off(current: Mapping[str, str | None], failover: Mapping[str, str]) -> dict[str, dict[str, str | None]]:
    """{name: {"before", "after"}} for every variable the switch changes.

    A runner variable changes only while it sends overflow to Blacksmith:
    unset (its readers fall back to Blacksmith) or a blacksmith-* label.
    CI_PAID_MACOS_OVERFLOW changes when it is not already 1. A variable
    already at its failover is not recorded, so turning overflow back on
    never "restores" a value this switch did not set.
    """
    changed: dict[str, dict[str, str | None]] = {}
    for name, after in failover.items():
        before = (current.get(name) or "").strip() or None
        if before == after:
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


def plan_on(record: Mapping[str, Any], current: Mapping[str, str | None]) -> list[Restore]:
    """What turning overflow back on writes: each recorded variable's value before, unless it moved since."""
    restores: list[Restore] = []
    for name, change in sorted((record.get("changed") or {}).items()):
        if not isinstance(change, Mapping):
            continue
        before, after = change.get("before"), change.get("after")
        now = (current.get(name) or "").strip() or None
        if now != after:
            restores.append(Restore(name, before, f"now {now or 'unset'}, not the failover {after}; "
                                                  "someone changed it, so it is left alone"))
            continue
        restores.append(Restore(name, before))
    return restores


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


def stuck_job(jobs: Iterable[Mapping[str, Any]], now: dt.datetime, minutes: int) -> Mapping[str, Any] | None:
    """The oldest job queued with no runner on a Blacksmith label for `minutes` or more."""
    stuck = []
    for job in jobs:
        if job.get("status") != "queued" or job.get("runner_name"):
            continue
        if not any(cloud_label(str(label)) for label in job.get("labels") or ()):
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


def wait_for_probe(api: GitHub, run_id: int, attempt: int, minutes: int, *,
                   now: Callable[[], dt.datetime], sleep: Callable[[float], None],
                   log: Callable[[str], None]) -> str:
    """Watch this run's probe job until it starts or has waited `minutes`."""
    deadline = now() + dt.timedelta(minutes=minutes + 5)
    while True:
        try:
            probe = next((job for job in api.jobs(run_id, attempt) if job.get("name") == PROBE_JOB), None)
        except RuntimeError as error:
            log(f"could not list this run's jobs ({error}); trying again")
            probe = None
        outcome = probe_outcome(probe, now(), minutes)
        if outcome != "waiting":
            return outcome
        if now() >= deadline:
            # Never saw the probe: nothing measured, so nothing is decided.
            return "unknown"
        sleep(POLL_SECONDS)


def rescue_stuck_runs(api: GitHub, *, own_run_id: int, minutes: int, now: Callable[[], dt.datetime],
                      sleep: Callable[[float], None], log: Callable[[str], None], dry_run: bool) -> list[str]:
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
            job = stuck_job(api.jobs(int(run["id"])), now(), minutes)
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
    label = probe_label(record, current.get(LINUX_VARIABLE))
    drill = (env.get("PROBE_LABEL_DRILL") or "").strip()
    if drill:
        # A drill (workflow_dispatch probe_label) probes another label and never writes.
        label, args.dry_run = drill, True
        log(f"drill: probing {drill} instead; a dry run whatever it finds")
    state = f"off since {record.get('since')}" if record else "on"
    log(f"Blacksmith overflow is {state}; probing {label} (a probe queued {minutes} min with no runner is a stall)")

    outcome = wait_for_probe(api, run_id, attempt, minutes, now=now, sleep=sleep, log=log)
    stamp = iso(now())
    code = 0
    if outcome == "unknown":
        log("::warning title=Cloud overflow switch::never saw the probe job; nothing decided")
    elif outcome == "started":
        log(f"{stamp}: the probe started on {label}; Blacksmith is serving")
        if record:
            restores = plan_on(record, current)
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
        log(f"{stamp}: the probe waited {minutes} min on {label} with no runner; Blacksmith is not serving")
        if not record:
            changed = plan_off(current, failover)
            new_record = {"since": stamp, "probe": label, "reason": f"probe on {label} queued {minutes} min "
                          "with no runner", "run": f"https://github.com/{repo}/actions/runs/{run_id}",
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
        if record or args.dry_run:
            for line in rescue_stuck_runs(api, own_run_id=run_id, minutes=minutes, now=now, sleep=sleep,
                                          log=log, dry_run=args.dry_run):
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
