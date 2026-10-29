#!/usr/bin/env python3
"""Move jobs off a runner label that has stopped starting jobs: the dead-label re-dispatch.

GitHub binds a job's runner label when it creates the job. When a label stops
starting jobs, every job already queued on it waits there, and pointing the
runner variables elsewhere (cloud_overflow_switch.py) only moves jobs created
after the switch. On 2026-10-28 the Blacksmith 16 vCPU Linux label started
nothing from about 22:12Z and about 1,300 runs sat queued while the 32 vCPU
label beside it served. Leo: "Bro, I thought we already had logic to
automatically route shit. How can we still have pins like this? I hate pins.
Like, just pin the set of the shit that isn't hilariously slow."

A label is dead (dead_labels()) when, in the queue janitor's inventory (plus
up to LINUX_ONLY_READS queued runs of Linux-only workflows, which the
janitor's own inventory leaves out):
  - a job on it has been queued with no runner for DEAD_AFTER (3 min) since it
    could first run (starved_labels.wait_start(): a running sibling, which may
    be its `needs`, means its wait has not begun), and
  - no job asking for a subset of its labels started within DEAD_AFTER. An owned
    pool label also counts a running job as service: a busy pool of minis is
    not dead. A Blacksmith label does not: its VMs keep running jobs they took
    before the stall, so only a start shows it serves;
  - some other label of the same family (Blacksmith Linux; or Blacksmith macOS,
    owned pools and capability labels, never a single-host label) did start a
    job within DEAD_AFTER. That is the live member a re-run can land on, and
    the proof that the inventory sees starts at all. When nothing in the family
    started (an org-wide stall, or every pool backed up), nothing moves.

A run holding such a job, or a job queued on a member its RUNNER_POOLS pool moved off
(PoolsState.retired()), is re-dispatched (plan()) only when its own runs-on, read
from the workflow file at the run's head, takes its label from
fromJSON(vars.RUNNER_POOLS).<pool> and that pool now points at another live
member (rerun_route()). Any other runs-on (a literal, a runner variable, a
picker's output) is flagged in the summary and left. Right before the cancel
the run and its jobs are read again and every check below is made again
(recheck()). The run's re-run is written as an obligation into the janitor's
one obligation store before the cancel; only a confirmed outcome clears it, and
every later sweep reads the run again (resume()). It is never moved when:
  - a job of it is running (cancelling would throw that work away; a later
    sweep takes the run once the job ends);
  - it is a nightly, DEV or promote run whose build has started
    (delivery_workflows.build_started(), the check the agents' cancel guard and
    the janitor's superseded pass use): "Never cancel a NEXT nightly, dev or
    promote build or its Release compile once it has started";
  - it is a release, merge-queue or tag event, or a release, publish,
    notarization, TestFlight or App Store workflow;
  - it is past its first attempt: a run is moved at most once.
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import json
import re
import time
from collections.abc import Callable, Iterable, Mapping, Sequence
from typing import Any

import runs_on_values
import starved_labels
import yaml
from delivery_workflows import attempt_jobs, build_started, is_delivery_run
from pr_runner_pool import CAPABILITY_LABELS, persistent as owned_pool

DEAD_AFTER = dt.timedelta(minutes=3)
# Only a run's first attempt is moved: when a re-run lands on the same dead label (a hard-coded label, or a route
# this sweep could not see), it is left there instead of being cancelled again.
MAX_ATTEMPT = 2
DEFAULT_MAX_REDISPATCH = 20
MAX_WORKFLOW_READS = 20  # workflow files read at a run's head per sweep (one request each)
# Linux-only workflows' runs are not in the janitor's job inventory (needs_jobs()); this many of the oldest queued
# ones are listed for this pass alone each sweep, so their jobs can be moved too.
LINUX_ONLY_READS = 12
MAX_REDISPATCH_LIMIT = 50
SETTLE_SECONDS = 90
POLL_SECONDS = 5

# The labels a job may be routed to, by family. "Live member" means a label of
# the job's family that started a job within DEAD_AFTER. GitHub-hosted labels
# are no member: no job runs there (Leo, 2026-10-27).
# Owned macOS labels count only as pools (pr_runner_pool.persistent(): glaeda-<class>-xcode-<version>) or capability
# labels (glaeda-ios-sim): a single-host label (glaeda-runner-<host>-...) is one machine a picker chose, and another
# machine serving says nothing about it.
DECLARED_SETS: dict[str, re.Pattern[str]] = {
    "linux": re.compile(r"^blacksmith-\d+vcpu-ubuntu-\d+(-arm)?$"),
    "macos": re.compile(r"^blacksmith-\d+vcpu-macos-\d+$"),
}
FLEET_PREFIX = starved_labels.FLEET_PREFIX
PROTECTED_EVENTS = frozenset({"release", "merge_group", "create", "delete", "deployment", "deployment_status"})
PROTECTED_WORKFLOW = re.compile(r"release|publish|notar|testflight|app[-_ ]?store", re.IGNORECASE)
TAG_LIKE_REF = re.compile(r"^(v\d|cmux-tui-v\d|.*-v\d+\.\d+)")


def parse_time(value: Any) -> dt.datetime | None:
    return starved_labels.parse_time(value if isinstance(value, str) else None)


def label_key(job: Mapping[str, Any]) -> frozenset[str]:
    return frozenset(str(label).lower() for label in job.get("labels") or ())


def label_family(label: str) -> str | None:
    if label in CAPABILITY_LABELS or owned_pool(label):
        return "macos"
    return next((name for name, pattern in DECLARED_SETS.items() if pattern.match(label)), None)


def family(labels: Iterable[str]) -> str | None:
    """The declared family every label of a job belongs to, or None (a hosted or single-host label, or a mix)."""
    found = {label_family(label) for label in labels}
    return next(iter(found)) if len(found) == 1 and None not in found else None


def _fleet(labels: frozenset[str]) -> bool:
    return any(label.startswith(FLEET_PREFIX) for label in labels)


def started_within(job: Mapping[str, Any], now: dt.datetime, window: dt.timedelta) -> bool:
    """A runner took the job within `window`. A queued job's started_at is set when it is queued, so the
    runner decides."""
    if not job.get("runner_name"):
        return False
    started = parse_time(job.get("started_at"))
    return started is not None and dt.timedelta(0) <= now - started <= window


def _serves(job: Mapping[str, Any], now: dt.datetime, window: dt.timedelta) -> bool:
    if started_within(job, now, window):
        return True
    # A running job on an owned label proves a listener is online (starved_labels).
    return job.get("status") == "in_progress" and _fleet(label_key(job))


@dataclasses.dataclass(frozen=True)
class DeadLabel:
    labels: frozenset[str]
    family: str
    oldest: dt.timedelta
    queued: int
    live: tuple[str, ...]  # labels of the family that started a job within the window

    def name(self) -> str:
        return ",".join(sorted(self.labels))

    def as_json(self) -> dict[str, Any]:
        return {"label": self.name(), "family": self.family, "queued": self.queued,
                "oldest_queued_minutes": int(self.oldest.total_seconds() // 60), "live": list(self.live)}


def dead_labels(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], *,
                now: dt.datetime, evidence: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
                after: dt.timedelta = DEAD_AFTER) -> list[DeadLabel]:
    """The label sets with a job stuck past `after` and no start within it, while their family has a live member."""
    all_jobs = [job for run in runs for job in jobs_by_run.get(run.get("id"), ())]
    all_jobs += [job for jobs in (evidence or {}).values() for job in jobs]
    served = [label_key(job) for job in all_jobs if _serves(job, now, after)]
    started = {label for job in all_jobs if started_within(job, now, after) for label in label_key(job)}
    waits: dict[frozenset[str], list[dt.timedelta]] = {}
    for run in runs:
        run_jobs = list(jobs_by_run.get(run.get("id"), ()))
        for job in run_jobs:
            labels = label_key(job)
            if not starved_labels.stuck(job) or not labels or family(labels) is None:
                continue
            if any(labels <= other for other in served):
                continue
            # Siblings stuck on another unserved label are no gate (starved_labels.wait_start()).
            suspects = frozenset(id(other) for other in run_jobs if starved_labels.stuck(other)
                                 and not any(label_key(other) <= s for s in served))
            wait = starved_labels.wait_start(job, run_jobs, suspects)
            if wait is None or wait[1]:
                continue  # a running or queued sibling may be its gate
            if now - wait[0] >= after:
                waits.setdefault(labels, []).append(now - wait[0])
    found = []
    for labels, ages in sorted(waits.items(), key=lambda item: sorted(item[0])):
        kind = family(labels)
        live = tuple(sorted(label for label in started - labels if kind and label_family(label) == kind))
        if kind and live:
            found.append(DeadLabel(labels, kind, max(ages), len(ages), live))
    return found


def run_reason(run: Mapping[str, Any]) -> str | None:
    """Why a run is left alone whatever its jobs show (its event, workflow and attempt), or None."""
    event, branch = str(run.get("event") or ""), str(run.get("head_branch") or "")
    if not event:
        return "its event could not be read"
    if event in PROTECTED_EVENTS:
        return f"a {event} run"
    if branch and TAG_LIKE_REF.match(branch):
        return f"tag-like ref {branch}"
    if PROTECTED_WORKFLOW.search(f"{run.get('name') or ''} {run.get('path') or ''}"):
        return "a release, publish, notarization, TestFlight or App Store workflow"
    attempt = run.get("run_attempt")
    if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
        return "its attempt could not be read"
    if attempt >= MAX_ATTEMPT:
        return f"already on attempt {attempt}; a re-run is moved at most once"
    return None


# --- RUNNER_POOLS ---------------------------------------------------------------------------------------------
# scripts/ci/runner_pools.py (cmux#27129) keeps RUNNER_POOLS pointed at each pool's live member, with `_dead`
# (label -> when last seen dead), and declares the pools in .github/runners.json `pools`. A job is re-dispatched
# only when its own runs-on takes its label from fromJSON(vars.RUNNER_POOLS).<pool> (rerun_route()): a re-run reads
# the pool's current member, so it lands on another label exactly when the pool moved. Every other runs-on (a
# literal, a runner variable, a picker's output) is flagged and left. The value is validated by runner_pools.py's
# own parse_value() and value_problems() (imported, never copied): any dropped part or problem, an unset variable, or
# no runner_pools.py on this tree means no RUNNER_POOLS state, and so no move.
POOLS_DEAD_KEY = "_dead"


@dataclasses.dataclass(frozen=True)
class PoolsState:
    current: Mapping[str, str]  # pool -> its current member
    members: Mapping[str, tuple[str, ...]]  # pool -> its declared members
    dead: frozenset[str]  # labels RUNNER_POOLS marks dead

    def retired(self) -> dict[str, str]:
        """{label: the member its pool points at now} for every declared member that is not its pool's current
        member, and every member marked dead."""
        found: dict[str, str] = {}
        for pool, listed in self.members.items():
            for member in listed:
                if member != self.current[pool] or member in self.dead:
                    found[member.lower()] = self.current[pool].lower()
        return found


def pools_state(raw: str | None, *, module: Any = None) -> tuple[PoolsState | None, str]:
    """(the validated RUNNER_POOLS state, or None; why not). `module` is runner_pools (imported when None)."""
    if not (raw or "").strip():
        return None, "RUNNER_POOLS is unset"
    if module is None:
        try:
            import runner_pools as module  # noqa: PLC0415 (cmux#27129; absent before it lands)
        except ImportError:
            return None, "scripts/ci/runner_pools.py is not on this tree"
    try:
        pools = module.load_pools()
        value, dropped = module.parse_value(raw, pools)
        problems = [*dropped, *module.value_problems(value, pools)]
        marks = value.get(module.DEAD_KEY)
    except Exception as error:  # noqa: BLE001 any failure to validate is no state, so no move
        return None, f"RUNNER_POOLS could not be validated ({type(error).__name__}: {error})"
    if problems:
        return None, f"RUNNER_POOLS fails runner_pools.py's validation: {'; '.join(problems)[:300]}"
    if not isinstance(marks, dict):
        return None, "RUNNER_POOLS has no valid _dead"
    members = {name: tuple(module.members(spec)) for name, spec in pools.items()}
    return PoolsState({name: str(value[name]) for name in pools}, members,
                      frozenset(str(label).lower() for label in marks)), ""


def retired_labels(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], *,
                   now: dt.datetime, retired: Mapping[str, str], after: dt.timedelta = DEAD_AFTER) -> list[DeadLabel]:
    """Retired labels (PoolsState.retired()) with a job queued on them past `after`, as DeadLabels whose live member
    is their pool's current one."""
    waits: dict[str, list[dt.timedelta]] = {}
    for run in runs:
        run_jobs = list(jobs_by_run.get(run.get("id"), ()))
        for job in run_jobs:
            labels = label_key(job)
            if len(labels) != 1 or not starved_labels.stuck(job) or next(iter(labels)) not in retired:
                continue
            wait = starved_labels.wait_start(job, run_jobs)
            if wait is not None and not wait[1] and now - wait[0] >= after:
                waits.setdefault(next(iter(labels)), []).append(now - wait[0])
    return [DeadLabel(frozenset({label}), label_family(label) or "pool", max(ages), len(ages),
                      tuple(x for x in (retired[label],) if x))
            for label, ages in sorted(waits.items())]


def dead_labels_if_complete(runs: Sequence[Mapping[str, Any]],
                            jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], *, now: dt.datetime,
                            evidence: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
                            unread: Sequence[str] = (), retired: Mapping[str, str] | None = None) -> list[DeadLabel]:
    """dead_labels() plus retired_labels(), or none at all when any listing of the sweep failed (`unread` names
    them): a run left unread may hold the only recent start on a label, so a partial inventory never calls a label
    dead."""
    if unread:
        print(f"dead-labels: {len(unread)} listing(s) failed this sweep ({'; '.join(unread)[:300]}); no label is "
              "judged dead and nothing is moved")
        return []
    found = dead_labels(runs, jobs_by_run, now=now, evidence=evidence)
    seen = {item.labels for item in found}
    return found + [item for item in retired_labels(runs, jobs_by_run, now=now, retired=retired or {})
                    if item.labels not in seen]


def protected_reason(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]]) -> str | None:
    """Why a run holding a job on a dead label is left alone, or None."""
    why = run_reason(run)
    if why:
        return why
    if is_delivery_run(run.get("path"), run.get("name"), run.get("display_title")):
        mine = attempt_jobs(run, jobs)
        if mine is None:
            return "a nightly, DEV or promote run whose attempt's jobs could not be read"
        started = build_started(mine)
        if started:
            return f"a nightly, DEV or promote run that has started ({started})"
    running = next((job for job in jobs if job.get("status") == "in_progress"), None)
    if running is not None:
        return f"its job {running.get('name')!r} is running; a later sweep takes it once that ends"
    return None


# --- where a re-run goes --------------------------------------------------------------------------------------
# A re-run evaluates the job's runs-on again. The runs-on comes from the workflow file at the run's head; the
# variables' live values come in the same NAME=value block ci-repo-variables.yml passes runs_on_values.py
# (CMUX_CI_RUNS_ON_VARIABLES; tests/test_ci_dead_labels.py keeps the janitor's block equal to that one), so the
# branch of the expression a re-run takes is known. rerun_route() moves the job only when that branch is
# fromJSON(vars.RUNNER_POOLS).<pool>.
UNKNOWN = object()
_LITERAL = re.compile(r"'((?:[^']|'')*)'")
_CALL = re.compile(r"^(startsWith|endsWith|contains)\((.*)\)$", re.IGNORECASE | re.DOTALL)
REUSABLE = re.compile(r"^\./\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$")


def _truthy(value: Any) -> bool:
    return value is not None and value is not False and value != ""


def evaluate(expression: str, values: Mapping[str, str], context: Mapping[str, str]) -> Any:
    """A GitHub expression's value with these variable values and this run's context, or UNKNOWN when it reads
    anything else (a picker's output, an input, a matrix value, a variable not passed in)."""
    text = runs_on_values.unwrap(expression)
    for operator in ("||", "&&"):
        parts = runs_on_values.split_top(text, operator)
        if len(parts) > 1:
            value: Any = None
            for part in parts:
                value = evaluate(part, values, context)
                if value is UNKNOWN:
                    return UNKNOWN
                if _truthy(value) == (operator == "||"):
                    return value
            return value
    for operator in ("!=", "=="):
        parts = runs_on_values.split_top(text, operator)
        if len(parts) == 2:
            left, right = (evaluate(part, values, context) for part in parts)
            if left is UNKNOWN or right is UNKNOWN:
                return UNKNOWN
            same = str("" if left is None else left).lower() == str("" if right is None else right).lower()
            return same == (operator == "==")
    if text.startswith("!"):
        value = evaluate(text[1:], values, context)
        return UNKNOWN if value is UNKNOWN else not _truthy(value)
    literal = _LITERAL.fullmatch(text)
    if literal:
        return literal.group(1).replace("''", "'")
    if text in ("true", "false"):
        return text == "true"
    pooled = re.fullmatch(r"fromJSON\(\s*vars\.([A-Za-z0-9_]+)\s*\)\.([A-Za-z0-9_]+)", text)
    if pooled:
        raw = values.get(pooled.group(1))
        try:
            doc = json.loads(raw) if isinstance(raw, str) and raw.strip() else None
        except ValueError:
            doc = None
        value = doc.get(pooled.group(2)) if isinstance(doc, dict) else None
        # Unset or off-schema fails the workflow on GitHub; here it is unknown, so nothing moves.
        return value if isinstance(value, str) else UNKNOWN
    variable = re.fullmatch(r"vars\.([A-Za-z0-9_]+)", text)
    if variable:
        return values[variable.group(1)] if variable.group(1) in values else UNKNOWN
    if text in context:
        return context[text]
    call = _CALL.fullmatch(text)
    if call:
        args = runs_on_values.split_top(call.group(2), ",")
        if len(args) == 2:
            left, right = (evaluate(arg, values, context) for arg in args)
            if not isinstance(left, str) or not isinstance(right, str):
                return UNKNOWN
            left, right, name = left.lower(), right.lower(), call.group(1).lower()
            return left.startswith(right) if name == "startswith" else (
                left.endswith(right) if name == "endswith" else right in left)
    return UNKNOWN


def run_context(run: Mapping[str, Any], repo: str) -> dict[str, str]:
    """What a runs-on may read about the run that a re-run keeps."""
    return {"github.repository_owner": repo.split("/", 1)[0], "github.repository": repo,
            "github.event_name": str(run.get("event") or ""),
            "github.event.pull_request.head.repo.full_name": str(
                ((run.get("head_repository") or {}).get("full_name")) or "")}


def _name_pattern(template: str) -> re.Pattern[str]:
    parts = re.split(r"\$\{\{.*?\}\}", template, flags=re.DOTALL)
    return re.compile(".*?".join(re.escape(part) for part in parts) + r"(?: \(.*\))?", re.DOTALL)


def find_job(text: str, name: str) -> tuple[Mapping[str, Any], str] | None:
    """(the workflow job, what is left of the API's job name) for a job the API names NAME: the job itself (rest
    ""), or a reusable workflow's caller (rest: the callee's part after " / "). None when no job, or more than one,
    matches."""
    try:
        doc = yaml.load(text, Loader=yaml.BaseLoader) or {}
    except yaml.YAMLError:
        return None
    jobs = (doc.get("jobs") or {}) if isinstance(doc, dict) else {}
    exact, templated = [], []
    for job_id, job in jobs.items() if isinstance(jobs, dict) else ():
        if not isinstance(job, dict):
            continue
        template = str(job.get("name") or job_id)
        pattern = _name_pattern(template)
        reusable = isinstance(job.get("uses"), str)
        head, sep, rest = name.partition(" / ") if reusable else (name, "", "")
        if reusable and not sep:
            continue
        if re.sub(r"\s*\(.*\)\s*$", "", head) == re.sub(r"\s*\(.*\)\s*$", "", template) or head == template:
            exact.append((job, rest))
        elif "${{" in template and pattern.fullmatch(head):
            templated.append((job, rest))
    # A name spelled out wins over a templated one (`${{ matrix.root }}` matches any name).
    found = exact or templated
    return found[0] if len(found) == 1 else None


def runs_on_of(read: Callable[[str], str | None], path: str, name: str, depth: int = 0) -> str | None:
    """The runs-on text of the job the API names NAME in the workflow at PATH (read(path) gives the file at the
    run's head), following one reusable-workflow call; None when it cannot be found."""
    text = read(path)
    found = find_job(text, name) if text is not None else None
    if found is None:
        return None
    job, rest = found
    if not rest:
        return runs_on_values.runs_on_text(job)
    uses = str(job.get("uses") or "")
    if depth or not REUSABLE.match(uses):
        return None
    return runs_on_of(read, uses[2:], rest, depth + 1)


POOL_MARK = "\x00runner-pool:"


def rerun_route(runs_on: str | None, label: str, values: Mapping[str, str], context: Mapping[str, str],
                pools: PoolsState | None, dead: Iterable[str] = ()) -> tuple[str | None, str]:
    """(the label a re-run lands on, why), or (None, why not). Only a runs-on whose taken branch is
    fromJSON(vars.RUNNER_POOLS).<pool> qualifies: the expression is evaluated with each pool standing for a marker,
    so a value from any other source never counts, and the target is the pool's current member."""
    if pools is None:
        return None, "no validated RUNNER_POOLS"
    if runs_on is None:
        return None, "its job's runs-on could not be read at the run's head"
    expressions = runs_on_values.runs_on_expressions(runs_on)
    if len(expressions) != 1 or runs_on_values.EXPRESSION.sub("", runs_on).strip():
        return None, "its runs-on is a literal label, so a re-run waits on it again"
    marked = {**values, "RUNNER_POOLS": json.dumps({pool: POOL_MARK + pool for pool in pools.current})}
    value = evaluate(expressions[0], marked, context)
    if not isinstance(value, str) or not value.startswith(POOL_MARK):
        return None, "its runs-on does not take its label from fromJSON(vars.RUNNER_POOLS); flagged, not moved"
    pool = value[len(POOL_MARK):]
    target = pools.current.get(pool, "").lower()
    if not target:
        return None, f"RUNNER_POOLS has no pool {pool!r}"
    if target == label:
        return None, f"pool {pool} still points at `{label}`; a re-run lands there again"
    if target in pools.dead or target in set(dead):
        return None, f"pool {pool} points at `{target}`, which is dead too"
    return target, f"pool {pool} now points at `{target}`; a re-run lands there"


@dataclasses.dataclass(frozen=True)
class Redispatch:
    run: Mapping[str, Any]
    job: str
    label: str
    why_not: str | None  # None: re-dispatch it
    note: str = ""

    def line(self) -> str:
        what = f"run {self.run.get('id')} ({self.run.get('name')}): `{self.job}` stuck on `{self.label}`"
        return f"{what}; left alone: {self.why_not}" if self.why_not else f"{what}; {self.note}"


def plan(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
         dead: Sequence[DeadLabel], *, values: Mapping[str, str] | None, repo: str, pools: PoolsState | None,
         workflow_text: Callable[[Mapping[str, Any], str], str | None], exclude: Iterable[int] = (),
         max_runs: int = DEFAULT_MAX_REDISPATCH, max_reads: int = MAX_WORKFLOW_READS) -> list[Redispatch]:
    """One decision per run holding a stuck job on a dead label, oldest run first; at most `max_runs` go.
    `workflow_text(run, path)` reads a workflow file at the run's head (None when it cannot), at most `max_reads`
    distinct files a sweep. With `values` None (not passed) nothing moves."""
    by_labels = {item.labels: item for item in dead}
    dead_names = {item.name() for item in dead}
    skip = set(exclude)
    decisions: list[Redispatch] = []
    texts: dict[tuple[str, str], str | None] = {}
    going = 0
    for run in sorted(runs, key=lambda r: (str(r.get("created_at") or ""), r.get("id") or 0)):
        if run.get("id") in skip or run.get("status") not in ("queued", "in_progress", "waiting", "pending"):
            continue
        jobs = list(jobs_by_run.get(run.get("id"), ()))
        stuck = next((job for job in jobs if starved_labels.stuck(job) and label_key(job) in by_labels), None)
        if stuck is None:
            continue
        labels = label_key(stuck)
        name = by_labels[labels].name()
        why = protected_reason(run, jobs)
        note = ""
        if why is None and values is None:
            why = f"the runner variables ({runs_on_values.RUNS_ON_VARIABLES_ENV}) were not passed"
        if why is None and len(labels) != 1:
            why = "it asks for several labels"
        if why is None and going >= max_runs:
            why = f"this sweep's cap of {max_runs} re-dispatches is used; the next sweep takes it"
        if why is None:
            def read(path: str, run: Mapping[str, Any] = run) -> str | None:
                key = (path, str(run.get("head_sha") or ""))
                if key not in texts:
                    if len(texts) >= max_reads:
                        return None
                    texts[key] = workflow_text(run, path)
                return texts[key]
            runs_on = runs_on_of(read, str(run.get("path") or "").split("@", 1)[0], str(stuck.get("name") or ""))
            target, note = rerun_route(runs_on, name, values or {}, run_context(run, repo), pools, dead_names)
            if target is None:
                why = note
        if why is None:
            going += 1
        decisions.append(Redispatch(run, str(stuck.get("name") or ""), name, why, note))
    return decisions


# --- moving a run --------------------------------------------------------------------------------------------
# An obligation is a run this pass force-cancelled (or tried to) and owes a re-run. It is written into the janitor's
# snapshot (OBLIGATIONS_KEY; the workflow uploads it whatever the sweep's outcome) before the cancel, and only a
# confirmed outcome clears it (settle()): the run is seen on a later attempt (re-run), or it completed with a
# conclusion other than cancelled (the cancel never took and the run finished). An error, a timeout or an unread run
# clears nothing: the entry stays, and every later sweep reads the run again and acts the same way (a re-run is
# asked only of a run that completed cancelled on the attempt the entry names, and a re-run that did take shows as a
# later attempt). The obligations share the janitor's one cap for carried re-runs (queue_janitor.LOST_PENDING_MAX,
# passed as `cap`): when it is full no new run is cancelled; nothing is ever evicted.
OBLIGATIONS_KEY = "dead_label_reruns"
# An obligation older than this is named in every summary as an error for a person; it is still never dropped.
OBLIGATION_ALARM_S = 6 * 3600


def _rate_limited(error: BaseException) -> bool:
    return type(error).__name__ == "RateLimited"


def recheck(github: Any, decision: Redispatch) -> str | None:
    """Why a run planned to move must not be cancelled now, read again right before the cancel: its attempt moved
    or it finished, a nightly, DEV or promote build of it started, a job of it is running, or its stuck job took a
    runner. None when it still may go. Anything unread is a reason."""
    run_id = int(decision.run["id"])
    try:
        fresh = github.run(run_id)
        jobs = github.jobs(run_id)
    except RuntimeError as error:
        if _rate_limited(error):
            raise
        return f"it could not be read again before the cancel ({error})"
    if fresh.get("run_attempt") != decision.run.get("run_attempt"):
        return "its attempt moved since the inventory"
    if fresh.get("status") not in ("queued", "in_progress", "waiting", "pending"):
        return f"it is {fresh.get('status') or 'in an unknown state'} now"
    why = protected_reason(fresh, jobs)
    if why:
        return why
    if not any(starved_labels.stuck(job) and str(job.get("name") or "") == decision.job for job in jobs):
        return f"its job `{decision.job}` is no longer queued without a runner"
    return None


def _rerun(github: Any, run_id: int) -> None:
    # The failed and cancelled jobs: each new job reads RUNNER_POOLS again, so it takes the pool's current member.
    github.rerun_failed(run_id)


def settle(github: Any, entry: Mapping[str, Any], *, now: float) -> tuple[bool, str, bool]:
    """Act on one obligation: (cleared, what happened, failed). Cleared only on a confirmed outcome; any error or
    unread state keeps it. A rate limit is raised (the caller has the entry saved)."""
    run_id, attempt = entry.get("run_id"), entry.get("attempt")
    if not isinstance(run_id, int) or isinstance(run_id, bool) or not isinstance(attempt, int):
        return False, "an unreadable entry; kept for a person", True
    try:
        run = github.run(run_id)
    except RuntimeError as error:
        if _rate_limited(error):
            raise
        return False, f"could not be read ({error}); kept", False
    seen = run.get("run_attempt")
    if isinstance(seen, int) and seen > attempt:
        return True, "re-run (a later attempt exists)", False
    if seen != attempt:
        return False, f"its attempt reads {seen!r}; kept", True
    if run.get("status") != "completed":
        old = now - float(entry.get("at") or 0) > OBLIGATION_ALARM_S
        return False, ("cancelled long ago and still not finished; look at it by hand" if old
                       else "its cancel is still finishing; the next sweep re-runs it"), old
    conclusion = run.get("conclusion")
    if not isinstance(conclusion, str) or not conclusion:
        return False, "completed with no conclusion read; kept", True
    if conclusion != "cancelled":
        return True, f"finished {conclusion} on its own; nothing to re-run", False
    try:
        _rerun(github, run_id)
    except RuntimeError as error:
        if _rate_limited(error):
            raise
        # The answer may have been lost after GitHub took it: the next sweep sees a later attempt, or asks again.
        return False, f"the re-run failed ({error}); the next sweep asks again", True
    return False, "re-run asked; cleared once the next attempt is seen", False


def resume(github: Any, obligations: Sequence[Mapping[str, Any]], *, now: float) -> tuple[list[dict[str, Any]],
                                                                                          dict[int, str], int]:
    """Carry out what earlier sweeps owe: (still owed, {run id: result}, failures)."""
    owed: list[dict[str, Any]] = []
    results: dict[int, str] = {}
    failures = 0
    for index, entry in enumerate(obligations):
        try:
            cleared, what, failed = settle(github, entry, now=now)
        except RuntimeError:
            owed.extend(dict(rest) for rest in obligations[index:])
            raise
        if not cleared:
            owed.append(dict(entry))
        if isinstance(entry.get("run_id"), int):
            results[int(entry["run_id"])] = f"an earlier sweep's cancel: {what}"
        failures += failed
    return owed, results, failures


def redispatch(github: Any, decisions: Sequence[Redispatch], *, dry_run: bool, store: Any,
               save: Callable[[list[dict[str, Any]]], None] | None,
               hold: Callable[[], str | None] = lambda: None, now: Callable[[], float] = time.time,
               sleep: Callable[[float], None] = time.sleep,
               settle_seconds: float = SETTLE_SECONDS) -> tuple[dict[int, str], int]:
    """Move every run that goes: read it again (recheck()), write its obligation into the janitor's one store
    (`store`, a janitor_guard.OwedStore; save() publishes this pass's list), force-cancel it, then settle() each until
    its cancel finished or `settle_seconds` passed. ({run id: result}, failures). Nothing is cancelled with `save`
    None, while hold() names a failed listing, for a run any list of the store owes, or with no room in the store.
    `github` is queue_janitor.GitHub: run(id), jobs(id), force_cancel(id), rerun_failed(id). A rate limit is
    raised; every obligation it leaves is saved first."""
    going = [d for d in decisions if d.why_not is None]
    results: dict[int, str] = {}
    failures = 0
    if dry_run:
        return {int(d.run["id"]): "would force-cancel and re-run (dry run)" for d in going}, 0
    if save is None:
        return {int(d.run["id"]): "not moved: no snapshot to carry its re-run" for d in going}, 0
    obligations = store.entries(OBLIGATIONS_KEY)
    mine: list[dict[str, Any]] = []
    for decision in going:
        run_id = int(decision.run["id"])
        why_held = hold()
        if why_held:
            results[run_id] = f"not moved: {why_held}"
            continue
        if run_id in store.ids():
            results[run_id] = "already owed a re-run; settled through that, never cancelled twice"
            continue
        if store.room() <= 0:
            results[run_id] = (f"not moved: the owed re-runs store is full ({store.count()} of {store.cap}) "
                               "or unread")
            continue
        why = recheck(github, decision)
        if why:
            results[run_id] = f"kept: {why}"
            continue
        entry = {"run_id": run_id, "attempt": int(decision.run.get("run_attempt") or 1), "at": now()}
        obligations.append(entry)
        save(list(obligations))
        try:
            github.force_cancel(run_id)
        except RuntimeError as error:
            if _rate_limited(error):
                raise
            # Ambiguous: GitHub may have taken it. The obligation stays; settle() reads what happened.
            results[run_id] = f"force-cancel answered an error ({error}); kept owed, the next sweeps settle it"
            continue
        mine.append(entry)
    deadline = now() + settle_seconds
    while mine:
        for entry in list(mine):
            cleared, what, failed = settle(github, entry, now=now())
            if "still finishing" in what and now() < deadline:
                continue
            mine.remove(entry)
            results[entry["run_id"]] = what
            failures += failed
            if cleared:
                obligations.remove(entry)
                save(list(obligations))
        if mine and now() >= deadline:
            for entry in mine:
                results[entry["run_id"]] = f"force-cancelled, still finishing after {int(settle_seconds)} s; owed"
            break
        if mine:
            sleep(POLL_SECONDS)
    return results, failures


# --- the Linux-only runs the janitor's inventory leaves out --------------------------------------------------
def linux_only_candidates(runs: Sequence[Mapping[str, Any]], *, now: dt.datetime,
                          limit: int = LINUX_ONLY_READS) -> list[Mapping[str, Any]]:
    """Which of these queued runs (Linux-only, unlisted) to read jobs for this sweep: only runs that could move
    (run_reason() is None: attempt 1, not a protected event or workflow) and have waited DEAD_AFTER, at most `limit`,
    taken in turn across sweeps (a window over the oldest-first list that moves each DEAD_AFTER) so runs that stay
    stuck never hide the ones behind them."""
    eligible = sorted((run for run in runs if run_reason(run) is None
                       and (created := parse_time(run.get("created_at"))) is not None and now - created >= DEAD_AFTER),
                      key=lambda run: (str(run.get("created_at") or ""), run.get("id") or 0))
    if len(eligible) <= limit:
        return eligible
    turn = int(now.timestamp() // DEAD_AFTER.total_seconds())
    start = (turn * limit) % len(eligible)
    return (eligible[start:] + eligible[:start])[:limit]


def render_summary(dead: Sequence[DeadLabel], decisions: Sequence[Redispatch], results: Mapping[int, str],
                   resumed: Mapping[int, str] | None = None) -> str:
    if not dead and not resumed:
        return ""
    lines = ["", "### Dead runner labels", ""]
    for run_id, result in sorted((resumed or {}).items()):
        lines.append(f"- run {run_id}: {result}")
        if "by hand" in result or "failed" in result:
            print(f"::error title=Dead-label re-dispatch::run {run_id}: {result}")
    for item in dead:
        lines.append(f"- `{item.name()}`: {item.queued} job(s) queued past {int(DEAD_AFTER.total_seconds() // 60)} "
                     f"min (oldest {int(item.oldest.total_seconds() // 60)} min) and none started; live in its "
                     f"family: {', '.join(f'`{label}`' for label in item.live)}")
    for decision in decisions:
        result = results.get(int(decision.run["id"]))
        lines.append(f"- {decision.line()}" + (f": {result}" if result else ""))
        if result and ("by hand" in result or "failed" in result):
            print(f"::error title=Dead-label re-dispatch::run {decision.run['id']}: {result}")
    return "\n".join(lines) + "\n"
