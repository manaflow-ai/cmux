#!/usr/bin/env python3
"""Cancel macOS runner demand that no longer buys anything.

Pull request macOS jobs share one small runner pool. When that pool is
saturated, every queued job that nobody will read delays one that somebody
will. This janitor looks at in-flight Actions runs, and only when the number of
queued macOS jobs exceeds a threshold does it cancel runs that are waste, in
this priority order:

  a. push-triggered experiment workflows on ``exp/*`` branches;
  b. pull request runs whose PR is closed or merged, or whose head SHA is no
     longer the PR head (superseded);
  c. full-suite CI runs whose PR no longer carries the ``full-ci`` label, once
     a newer CI run for that PR is already waiting to replace them and the old
     run's compile admission is not mid-flight (ci.yml deliberately lets that
     compile finish so the queued run can reuse its product).
  d. CI runs whose required ``ci-status`` is already decided against them: an
     ``app-host unit tests`` shard has concluded ``failure``, so the ``macos``
     reusable-workflow call cannot report ``success`` or ``skipped`` and no
     later job can take that back, while sibling macOS jobs still hold the
     pool. Unlike (a)-(c) the run is current and its remaining output is still
     readable, so this category is ordered last and never touches a run whose
     diff changes what the failing shard does.

Draft pull requests are deliberately not a category: a draft can be an active
integration branch other work depends on, and ci.yml has no ready_for_review
trigger to replace a cancelled ci-status.

It stops as soon as the projected queue is back under the threshold, or when
it reaches the per-sweep cancel cap. Main pushes, merge groups, scheduled and
dispatched runs on main, release/tag runs, nightly, and TestFlight/App Store
workflows are never candidates, whatever their state.

Everything that decides is a pure function over already-fetched JSON; the
GitHub client at the bottom only fetches and cancels.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any


API = "https://api.github.com"
DEFAULT_THRESHOLD = 6
DEFAULT_MAX_CANCELS = 10
MAX_RUN_PAGES = 3
MAX_JOB_PAGES = 3
GRAPHQL_BATCH = 25

# Statuses a run can hold runner demand in. `pending` is a run parked behind a
# concurrency group, which is how a label-triggered CI rerun waits.
IN_FLIGHT_RUN_STATUSES = ("queued", "in_progress", "pending")
QUEUED_JOB_STATUSES = frozenset({"queued", "waiting", "pending", "requested"})
RUNNING_JOB_STATUSES = frozenset({"in_progress"})

# A queued run this old is a ghost the Actions backend never scheduled, not
# demand. Skip fetching its jobs every sweep.
GHOST_QUEUED_RUN_AGE = dt.timedelta(hours=24)

EXPERIMENT_BRANCH_PREFIXES = ("exp/",)
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
FULL_SUITE_LABEL = "full-ci"
COMPILE_ONLY_POLICY = "compile-only"
COMPILE_ADMISSION_JOB = re.compile(r"(^|/ )macOS compile admission$")

CATEGORY_ORDER = ("experiment", "stale-pr", "label-dropped", "doomed")

# The shards whose failure decides ci-status. ci-macos.yml shards this six ways
# and the reusable-call prefix makes the API name "macos / app-host unit tests
# (3/6)", so match on the substring.
DOOMED_JOB_NAME = "app-host unit tests"

# How long a shard failure must have stood before the run is a candidate, so a
# run that just turned red keeps its siblings while someone looks at it.
DOOMED_GRACE = dt.timedelta(minutes=10)

# The shards' own inputs, read off the app-host-unit-tests job block in
# ci-macos.yml: the XCTest sources it runs, the scripts that shard, compile,
# isolate and grade them, the known-failure quarantine list and the workflow
# that defines the job. A run that changes any of these is an attempt to change
# what the shard does, and its remaining shards are the result someone is
# waiting for. Sources/ is deliberately absent: the suite exercises it, but
# nearly every pull request changes it, and a set matching every pull request
# is not a rule. JANITOR_OPT_OUT_LABEL covers a fix that lives only there.
DOOMED_INPUT_PREFIXES = ("cmuxTests/", "scripts/ci/workloads/")
DOOMED_INPUT_MARKERS = ("app-host", "app_host")
DOOMED_INPUT_FILES = (".github/workflows/ci-macos.yml", "scripts/ci/cmux_unit_test_shard.py")
JANITOR_OPT_OUT_LABEL = "no-janitor"

PROTECTED_EVENTS = frozenset({"merge_group", "release", "create", "delete", "deployment", "deployment_status"})
MAIN_ONLY_EVENTS = frozenset({"schedule", "workflow_dispatch", "repository_dispatch"})
PROTECTED_WORKFLOW = re.compile(r"release|nightly|testflight|app[-_ ]?store|appstore|publish|notar", re.IGNORECASE)
TAG_LIKE_REF = re.compile(r"^(v\d|cmux-tui-v\d|.*-v\d+\.\d+)")

UTC = dt.timezone.utc


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def format_age(delta: dt.timedelta | None) -> str:
    if delta is None:
        return "-"
    minutes = max(0, int(delta.total_seconds() // 60))
    if minutes < 60:
        return f"{minutes}m"
    return f"{minutes // 60}h{minutes % 60:02d}m"


def protected_reason(run: Mapping[str, Any]) -> str | None:
    """Why a run must never be cancelled, or None when policy may look at it."""
    event = run.get("event") or ""
    branch = run.get("head_branch") or ""
    haystack = " ".join(str(run.get(key) or "") for key in ("name", "path"))
    if not event or not branch:
        return "missing event or branch"
    if event in PROTECTED_EVENTS:
        return f"{event} event"
    if event == "push" and (branch == "main" or branch.startswith("rc/")):
        return f"push to {branch}"
    if event in MAIN_ONLY_EVENTS and branch == "main":
        return f"{event} on main"
    if TAG_LIKE_REF.match(branch):
        return f"tag-like ref {branch}"
    if PROTECTED_WORKFLOW.search(haystack):
        return "release/nightly/TestFlight/App Store workflow"
    return None


def workflow_may_use_macos(text: str) -> bool:
    """False only when a workflow file cannot schedule a macOS job.

    Reusable workflows are followed by the text check on the caller: any
    workflow that calls a local reusable workflow is treated as macOS-capable.
    """
    lowered = text.lower()
    return "macos" in lowered or "uses: ./.github/workflows/" in lowered


def linux_only_workflow_paths(workflows_dir: Path) -> frozenset[str]:
    """Workflow paths on the default branch that never run macOS jobs."""
    paths = set()
    if not workflows_dir.is_dir():
        return frozenset()
    for path in sorted(workflows_dir.glob("*.y*ml")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if not workflow_may_use_macos(text):
            paths.add(f".github/workflows/{path.name}")
    return frozenset(paths)


def needs_jobs(run: Mapping[str, Any], linux_only_paths: frozenset[str], now: dt.datetime) -> bool:
    """Whether a run's jobs are worth one API call this sweep."""
    if run.get("path") in linux_only_paths:
        return False
    if run.get("event") in PROTECTED_EVENTS - {"merge_group"}:
        # Deployment/tag bookkeeping never holds pool capacity worth counting.
        return False
    created = parse_time(run.get("created_at"))
    if run.get("status") == "queued" and created and now - created > GHOST_QUEUED_RUN_AGE:
        return False
    return True


def is_macos_job(job: Mapping[str, Any]) -> bool:
    return any("macos" in str(label).lower() for label in job.get("labels") or ())


@dataclasses.dataclass(frozen=True)
class MacosUsage:
    queued: int = 0
    running: int = 0
    oldest_queued_at: dt.datetime | None = None
    compile_admission_running: bool = False
    # The app-host shard whose failure decided ci-status, and when it landed.
    # Read from the same pass over the run's jobs, at no extra API cost.
    decided_by: str | None = None
    decided_at: dt.datetime | None = None

    @property
    def held(self) -> int:
        return self.queued + self.running


def macos_usage(jobs: Iterable[Mapping[str, Any]]) -> MacosUsage:
    queued = running = 0
    oldest: dt.datetime | None = None
    compiling = False
    decided_by: str | None = None
    decided_at: dt.datetime | None = None
    undated_failure = False
    for job in jobs:
        if not is_macos_job(job):
            continue
        status = job.get("status")
        name = job.get("name") or ""
        if status in QUEUED_JOB_STATUSES:
            queued += 1
            created = parse_time(job.get("created_at"))
            if created and (oldest is None or created < oldest):
                oldest = created
        elif status in RUNNING_JOB_STATUSES:
            running += 1
            if COMPILE_ADMISSION_JOB.search(name):
                compiling = True
        elif status == "completed" and DOOMED_JOB_NAME in name:
            # Job conclusion, never step conclusion: a job whose only failed
            # steps carry continue-on-error concludes `success`, so reading the
            # job already excludes tolerated failures.
            if job.get("conclusion") != "failure":
                continue
            finished = parse_time(job.get("completed_at"))
            if finished is None:
                undated_failure = True
            elif decided_at is None or finished < decided_at:
                decided_by, decided_at = name, finished
    if undated_failure:
        # A failure we cannot time cannot clear the grace window; fail closed.
        decided_by = decided_at = None
    return MacosUsage(queued, running, oldest, compiling, decided_by, decided_at)


def touches_doomed_job_inputs(paths: Iterable[str]) -> bool:
    for path in paths:
        if path in DOOMED_INPUT_FILES or path.startswith(DOOMED_INPUT_PREFIXES):
            return True
        if any(marker in path for marker in DOOMED_INPUT_MARKERS):
            return True
    return False


def pr_changed_paths(pr: Mapping[str, Any]) -> list[str] | None:
    """Changed paths, or None when the diff cannot be read in full."""
    files = pr.get("files") or {}
    if (files.get("pageInfo") or {}).get("hasNextPage"):
        return None
    nodes = files.get("nodes")
    if nodes is None:
        return None
    return [str(node.get("path")) for node in nodes]


def run_head_owner(run: Mapping[str, Any]) -> str:
    repo = run.get("head_repository") or {}
    owner = repo.get("owner") or {}
    return str(owner.get("login") or "").lower()


def resolve_pull_request(run: Mapping[str, Any], candidates: Sequence[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """Pick the pull request a pull_request-event run belongs to, or None if unsure."""
    owner = run_head_owner(run)
    prs = [pr for pr in candidates if str(((pr.get("headRepositoryOwner") or {}).get("login")) or "").lower() == owner]
    if not prs:
        return None
    numbers = {pr.get("number") for pr in run.get("pull_requests") or ()}
    by_number = [pr for pr in prs if pr.get("number") in numbers]
    if len(by_number) == 1:
        return by_number[0]
    same_head = [pr for pr in prs if pr.get("headRefOid") == run.get("head_sha")]
    open_same_head = [pr for pr in same_head if pr.get("state") == "OPEN"]
    if len(open_same_head) == 1:
        return open_same_head[0]
    if len(same_head) == 1:
        return same_head[0]
    open_prs = [pr for pr in prs if pr.get("state") == "OPEN"]
    if len(open_prs) == 1:
        return open_prs[0]
    if not open_prs and len(prs) == 1:
        return prs[0]
    return None


def had_label_at(pr: Mapping[str, Any], label: str, when: dt.datetime) -> bool | None:
    """Whether `label` was on the PR at `when`, from its label timeline.

    None means the timeline cannot say (no event for that label at all while
    the label is absent now is taken as "never had it"; a label present now
    with no events is unknowable).
    """
    events = []
    for node in ((pr.get("timelineItems") or {}).get("nodes") or ()):
        name = ((node.get("label") or {}).get("name"))
        created = parse_time(node.get("createdAt"))
        if name != label or created is None:
            continue
        events.append((created, node.get("__typename")))
    events.sort()
    before = [kind for created, kind in events if created <= when]
    if before:
        return before[-1] == "LabeledEvent"
    if events:
        # Every event is later: the label state before them is the opposite of
        # the first one.
        return events[0][1] == "UnlabeledEvent"
    has_now = label in {n.get("name") for n in ((pr.get("labels") or {}).get("nodes") or ())}
    return None if has_now else False


def pr_labels(pr: Mapping[str, Any]) -> set[str]:
    return {str(n.get("name")) for n in ((pr.get("labels") or {}).get("nodes") or ())}


@dataclasses.dataclass(frozen=True)
class Candidate:
    run: Mapping[str, Any]
    category: str
    reason: str
    usage: MacosUsage


def classify(
    run: Mapping[str, Any],
    usage: MacosUsage,
    pr: Mapping[str, Any] | None,
    *,
    newer_ci_run_waiting: bool,
    pull_request_policy: str,
    now: dt.datetime,
) -> tuple[str, str] | None:
    """Return (category, reason) for a wasteful run, or None to leave it alone."""
    if usage.held == 0 or protected_reason(run):
        return None
    event = run.get("event")
    branch = run.get("head_branch") or ""

    if event == "push":
        if branch.startswith(EXPERIMENT_BRANCH_PREFIXES):
            return "experiment", f"push-triggered experiment on {branch}"
        return None

    if event != "pull_request" or pr is None:
        return None

    number = pr.get("number")
    state = pr.get("state")
    if state == "MERGED":
        return "stale-pr", f"PR #{number} is merged"
    if state == "CLOSED":
        return "stale-pr", f"PR #{number} is closed"
    if state != "OPEN":
        return None
    if pr.get("headRefOid") and pr.get("headRefOid") != run.get("head_sha"):
        return "stale-pr", f"superseded: PR #{number} head is now {str(pr.get('headRefOid'))[:9]}"

    if (
        run.get("path") == CI_WORKFLOW_PATH
        and pull_request_policy.strip() == COMPILE_ONLY_POLICY
        and FULL_SUITE_LABEL not in pr_labels(pr)
        and newer_ci_run_waiting
        and not usage.compile_admission_running
    ):
        created = parse_time(run.get("created_at"))
        if created and had_label_at(pr, FULL_SUITE_LABEL, created) is True:
            return "label-dropped", f"full suite, but PR #{number} no longer has `{FULL_SUITE_LABEL}`"

    # Doomed: ci-status is already decided against this run. Reaching here means
    # the PR is open and this run is still its current head, so unlike the
    # categories above the run is live and its remaining shards are readable
    # output. Everything unknown therefore preserves the run.
    if (
        run.get("path") == CI_WORKFLOW_PATH
        and usage.decided_by
        and usage.decided_at is not None
        # A re-run replays a subset of jobs, so an older attempt's failure is
        # not evidence about this one.
        and run.get("run_attempt") == 1
        and now - usage.decided_at >= DOOMED_GRACE
        and JANITOR_OPT_OUT_LABEL not in pr_labels(pr)
    ):
        changed = pr_changed_paths(pr)
        # An unreadable diff is not evidence that this run is not the fix.
        if changed is not None and not touches_doomed_job_inputs(changed):
            return "doomed", (
                f"ci-status already decided for PR #{number} ({branch}): `{usage.decided_by}` "
                f"failed {format_age(now - usage.decided_at)} ago, "
                f"{usage.held} macOS job(s) still held"
            )
    return None


def newer_ci_run_waiting(run: Mapping[str, Any], runs: Iterable[Mapping[str, Any]]) -> bool:
    """A later CI run for the same PR branch is in flight to take over ci-status."""
    if run.get("path") != CI_WORKFLOW_PATH:
        return False
    created = parse_time(run.get("created_at"))
    for other in runs:
        if other.get("id") == run.get("id") or other.get("path") != CI_WORKFLOW_PATH:
            continue
        if other.get("event") != "pull_request" or other.get("head_branch") != run.get("head_branch"):
            continue
        if run_head_owner(other) != run_head_owner(run):
            continue
        other_created = parse_time(other.get("created_at"))
        if created and other_created and other_created > created and other.get("status") in IN_FLIGHT_RUN_STATUSES:
            return True
    return False


@dataclasses.dataclass
class Decision:
    candidate: Candidate
    action: str  # "cancel" or "skip"
    note: str = ""


@dataclasses.dataclass
class Plan:
    queued_macos_jobs: int
    running_macos_jobs: int
    threshold: int
    decisions: list[Decision]

    @property
    def over_threshold(self) -> bool:
        return self.queued_macos_jobs > self.threshold

    def to_cancel(self) -> list[Candidate]:
        return [d.candidate for d in self.decisions if d.action == "cancel"]


def pr_key(run: Mapping[str, Any]) -> tuple[str, str]:
    return (run_head_owner(run), str(run.get("head_branch") or ""))


def build_plan(
    runs: Sequence[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
    prs_by_branch: Mapping[str, Sequence[Mapping[str, Any]]],
    *,
    threshold: int,
    max_cancels: int,
    pull_request_policy: str,
    now: dt.datetime,
) -> Plan:
    usages = {run["id"]: macos_usage(jobs_by_run.get(run["id"], ())) for run in runs}
    queued = sum(u.queued for u in usages.values())
    running = sum(u.running for u in usages.values())

    candidates: list[Candidate] = []
    for run in runs:
        usage = usages[run["id"]]
        pr = None
        if run.get("event") == "pull_request":
            pr = resolve_pull_request(run, prs_by_branch.get(str(run.get("head_branch") or ""), ()))
        verdict = classify(
            run, usage, pr,
            newer_ci_run_waiting=newer_ci_run_waiting(run, runs),
            pull_request_policy=pull_request_policy,
            now=now,
        )
        if verdict:
            candidates.append(Candidate(run, verdict[0], verdict[1], usage))

    def order(candidate: Candidate) -> tuple[int, str, int]:
        return (CATEGORY_ORDER.index(candidate.category), str(candidate.run.get("created_at") or ""), candidate.run["id"])

    candidates.sort(key=order)
    decisions: list[Decision] = []
    projected = queued
    cancels = 0
    for candidate in candidates:
        if projected <= threshold:
            decisions.append(Decision(candidate, "skip", f"queue projected at {projected}, not over {threshold}"))
            continue
        if cancels >= max_cancels:
            decisions.append(Decision(candidate, "skip", f"per-sweep cap of {max_cancels} reached"))
            continue
        decisions.append(Decision(candidate, "cancel"))
        cancels += 1
        # Each cancelled queued job leaves the queue; each cancelled running
        # job frees a slot that the next queued job takes.
        projected = max(0, projected - candidate.usage.held)
    return Plan(queued, running, threshold, decisions)


def branches_to_resolve(
    runs: Iterable[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
) -> list[str]:
    """PR branches worth one GraphQL lookup: PR runs that hold macOS jobs."""
    branches = set()
    for run in runs:
        if run.get("event") != "pull_request" or protected_reason(run):
            continue
        if macos_usage(jobs_by_run.get(run["id"], ())).held and run.get("head_branch"):
            branches.add(str(run["head_branch"]))
    return sorted(branches)


PR_FIELDS = """
        number state headRefOid url
        headRepositoryOwner { login }
        labels(first: 50) { nodes { name } }
        files(first: 100) { pageInfo { hasNextPage } nodes { path } }
        timelineItems(last: 50, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
          nodes {
            __typename
            ... on LabeledEvent { createdAt label { name } }
            ... on UnlabeledEvent { createdAt label { name } }
          }
        }
"""


def graphql_query(owner: str, name: str, branches: Sequence[str]) -> tuple[str, dict[str, Any]]:
    """One query that resolves every branch to its recent pull requests."""
    variables: dict[str, Any] = {"owner": owner, "name": name}
    params = ["$owner: String!", "$name: String!"]
    fields = []
    for index, branch in enumerate(branches):
        variables[f"b{index}"] = branch
        params.append(f"$b{index}: String!")
        fields.append(
            f"    b{index}: pullRequests(headRefName: $b{index}, first: 5, "
            f"orderBy: {{field: CREATED_AT, direction: DESC}}) {{\n      nodes {{{PR_FIELDS}      }}\n    }}"
        )
    query = (
        f"query({', '.join(params)}) {{\n  repository(owner: $owner, name: $name) {{\n"
        + "\n".join(fields)
        + "\n  }\n}"
    )
    return query, variables


def parse_graphql_prs(response: Mapping[str, Any], branches: Sequence[str]) -> dict[str, list[dict[str, Any]]]:
    repository = ((response.get("data") or {}).get("repository")) or {}
    result: dict[str, list[dict[str, Any]]] = {}
    for index, branch in enumerate(branches):
        connection = repository.get(f"b{index}") or {}
        result[branch] = list(connection.get("nodes") or [])
    return result


def render_summary(plan: Plan, *, dry_run: bool, now: dt.datetime, results: Mapping[int, str] | None = None) -> str:
    results = results or {}
    mode = "dry run" if dry_run else "live"
    lines = [
        f"## CI queue janitor ({mode})",
        "",
        f"Queued macOS jobs: **{plan.queued_macos_jobs}** (threshold {plan.threshold}); "
        f"running macOS jobs: {plan.running_macos_jobs}.",
        "",
    ]
    if not plan.decisions:
        lines.append("No wasteful macOS demand found.")
        return "\n".join(lines) + "\n"
    if not plan.over_threshold:
        lines.append("Queue is not over the threshold, so nothing is cancelled. Candidates seen:")
        lines.append("")
    lines.append("| Decision | Run | Workflow | Reason | Queued age | macOS jobs (queued/running) |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for decision in plan.decisions:
        run = decision.candidate.run
        usage = decision.candidate.usage
        if decision.action == "cancel":
            verb = results.get(run["id"]) or ("would cancel" if dry_run else "cancel")
        else:
            verb = f"keep ({decision.note})"
        age = format_age(now - usage.oldest_queued_at) if usage.oldest_queued_at else "-"
        url = run.get("html_url") or f"run {run.get('id')}"
        name = str(run.get("name") or run.get("path") or "").replace("|", "\\|")
        reason = f"({decision.candidate.category}) {decision.candidate.reason}".replace("|", "\\|")
        lines.append(f"| {verb} | {url} | {name} | {reason} | {age} | {usage.queued}/{usage.running} |")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# GitHub I/O
# ---------------------------------------------------------------------------


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.calls = 0
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-queue-janitor",
        }

    def request(self, method: str, path: str, body: Any | None = None) -> Any:
        self.calls += 1
        data = json.dumps(body).encode() if body is not None else None
        headers = dict(self.headers)
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(API + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.code})") from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.reason})") from error

    def in_flight_runs(self) -> list[dict[str, Any]]:
        runs: dict[int, dict[str, Any]] = {}
        for status in IN_FLIGHT_RUN_STATUSES:
            for page in range(1, MAX_RUN_PAGES + 1):
                query = urllib.parse.urlencode({"status": status, "per_page": 100, "page": page})
                payload = self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")
                batch = payload.get("workflow_runs") or []
                for run in batch:
                    runs[run["id"]] = run
                if len(batch) < 100:
                    break
        return list(runs.values())

    def jobs(self, run_id: int) -> list[dict[str, Any]]:
        jobs: list[dict[str, Any]] = []
        for page in range(1, MAX_JOB_PAGES + 1):
            query = urllib.parse.urlencode({"filter": "latest", "per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/actions/runs/{run_id}/jobs?{query}")
            batch = payload.get("jobs") or []
            jobs.extend(batch)
            if len(batch) < 100:
                break
        return jobs

    def pull_requests(self, branches: Sequence[str]) -> dict[str, list[dict[str, Any]]]:
        owner, name = self.repo.split("/", 1)
        result: dict[str, list[dict[str, Any]]] = {}
        for start in range(0, len(branches), GRAPHQL_BATCH):
            chunk = list(branches[start:start + GRAPHQL_BATCH])
            query, variables = graphql_query(owner, name, chunk)
            response = self.request("POST", "/graphql", {"query": query, "variables": variables})
            if response.get("errors"):
                raise RuntimeError(f"GraphQL errors: {response['errors'][:1]}")
            result.update(parse_graphql_prs(response, chunk))
        return result

    def run(self, run_id: int) -> dict[str, Any]:
        return self.request("GET", f"/repos/{self.repo}/actions/runs/{run_id}")

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/cancel")


def env_int(name: str, default: int) -> int:
    raw = (os.environ.get(name) or "").strip()
    return int(raw) if raw else default


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--dry-run", action="store_true",
                        default=(os.environ.get("DRY_RUN", "").lower() in {"1", "true", "yes"}))
    parser.add_argument("--threshold", type=int, default=None)
    parser.add_argument("--max-cancels", type=int, default=None)
    parser.add_argument("--pull-request-policy", default=os.environ.get("CI_PULL_REQUEST_SUITE", ""))
    parser.add_argument("--workflows-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / ".github" / "workflows")
    parser.add_argument("--summary", type=Path, default=(
        Path(os.environ["GITHUB_STEP_SUMMARY"]) if os.environ.get("GITHUB_STEP_SUMMARY") else None))
    args = parser.parse_args(argv)

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token or not args.repo:
        print("queue-janitor: GH_TOKEN and GH_REPO are required", file=sys.stderr)
        return 2
    try:
        threshold = args.threshold if args.threshold is not None else env_int("QUEUE_THRESHOLD", DEFAULT_THRESHOLD)
        max_cancels = args.max_cancels if args.max_cancels is not None else env_int("MAX_CANCELS", DEFAULT_MAX_CANCELS)
    except ValueError:
        print("queue-janitor: QUEUE_THRESHOLD and MAX_CANCELS must be integers", file=sys.stderr)
        return 2
    if threshold < 0 or not 0 <= max_cancels <= 25:
        print("queue-janitor: threshold must be >= 0 and max cancels within 0..25", file=sys.stderr)
        return 2

    github = GitHub(token, args.repo)
    now = dt.datetime.now(UTC)
    linux_only = linux_only_workflow_paths(args.workflows_dir)
    try:
        runs = github.in_flight_runs()
        jobs_by_run = {run["id"]: github.jobs(run["id"]) for run in runs if needs_jobs(run, linux_only, now)}
        branches = branches_to_resolve(runs, jobs_by_run)
        prs_by_branch = github.pull_requests(branches) if branches else {}
    except RuntimeError as error:
        print(f"queue-janitor: {error}", file=sys.stderr)
        return 1

    plan = build_plan(
        runs, jobs_by_run, prs_by_branch,
        threshold=threshold, max_cancels=max_cancels, pull_request_policy=args.pull_request_policy,
        now=now,
    )

    results: dict[int, str] = {}
    failures = 0
    if not args.dry_run:
        for candidate in plan.to_cancel():
            run_id = candidate.run["id"]
            try:
                # The inventory is seconds old; drop anything that finished or
                # moved to a new head in between.
                current = github.run(run_id)
                if current.get("status") not in IN_FLIGHT_RUN_STATUSES:
                    results[run_id] = f"skipped (now {current.get('status')})"
                    continue
                if current.get("head_sha") != candidate.run.get("head_sha"):
                    results[run_id] = "skipped (head changed)"
                    continue
                github.cancel(run_id)
                results[run_id] = "cancelled"
            except RuntimeError as error:
                failures += 1
                results[run_id] = f"failed: {error}"

    summary = render_summary(plan, dry_run=args.dry_run, now=now, results=results)
    summary += f"\n_{len(runs)} in-flight runs, {len(jobs_by_run)} job listings, {len(branches)} PR branches, " \
               f"{github.calls} API calls._\n"
    print(summary)
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as handle:
            handle.write(summary)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
