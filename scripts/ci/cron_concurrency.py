"""One queued run per cron or maintenance workflow, and no delivery workflow ever deduped.

After the 2026-11-11 20:17Z-21:38Z Actions stall, manaflow-ai/cmux held 683 queued runs over about
40 workflows; the janitor and owned-pool rescue showed 18 and 21. GitHub's own concurrency is the
dedupe: within one group at most one run is pending, and a newer pending run replaces the older one.
So a workflow fired by a schedule (or by another workflow finishing, workflow_run) needs, for every
job that can run on that event, a group that is the same string on every such run, with
cancel-in-progress false so a running sweep is never cut short. A workflow_dispatch carrying its own
inputs keeps whatever key it has today: this only reads the group on the schedule and workflow_run
events.

A workflow_run maintenance workflow whose run handles one specific source run (it rescues, retries or
guards that run) cannot share a group: a replaced pending run would drop that run's work. Those are
PER_SOURCE_RUN, each with its reason.

The never-cancel rule (Leo): never cancel a nightly, dev or promote build. Workflows matching
EXCLUDED_GLOBS (the delivery globs of delivery_workflows.py plus release, publish, stable-next,
dev-build, TestFlight / App Store, signing, notarization, appcast, deploy and Homebrew) are never
regrouped by this rule. Their cancel-in-progress must stay false (or true only for a pull_request
test run), and a group shared on a schedule or workflow_run event must be one of EXCLUDED_SHARED,
the groups they have today, each with its reason; tests/test_nightly_delivery_concurrency.py holds
the stricter per-run rule for the delivery set.

TRIVIAL_CHECKS is the derived set of seconds-long pull request checks (Linux only, every job's
timeout at most TRIVIAL_TIMEOUT_MINUTES, no macOS, no reusable call). Each must cancel its own
superseded run when the pull request head moves (a group keyed by the PR and cancel-in-progress true
on pull request events), unless TRIVIAL_NO_SUPERSEDE names why not.

tests/test_ci_cron_concurrency.py is the detector; docs/ci/cron-concurrency.md explains the class.
load() needs PyYAML; is_excluded() and collapsible_run() do not (the queue janitor imports them).
"""

from __future__ import annotations

import re
from collections.abc import Iterable
from dataclasses import dataclass
from fnmatch import fnmatch
from pathlib import Path

import delivery_concurrency as dc
from delivery_workflows import DELIVERY_GLOBS

CRON_EVENTS = ("schedule", "workflow_run")
PR_EVENTS = ("pull_request", "pull_request_target")
TRIVIAL_TIMEOUT_MINUTES = 10

# Never deduped, never cancelled: nightly, DEV, promote, release, publish and app/feed builds.
EXCLUDED_GLOBS = (
    *DELIVERY_GLOBS,
    "release*.yml",
    "*-release*.yml",
    "*publish*.yml",
    "stable-next*.yml",
    "*dev-build*.yml",
    "*dev-sign*.yml",
    "*-sign.yml",
    "*notariz*.yml",
    "*appcast*.yml",
    "ios-testflight*.yml",
    "ios-app-store*.yml",
    "ios-appstore*.yml",
    "update-homebrew*.yml",
    "*deploy*.yml",
)

# Groups an excluded workflow already shares on a schedule or workflow_run event, and why each may.
# (file, job or "" for top-level) -> reason. A new entry needs the same scrutiny as
# tests/test_nightly_delivery_concurrency.py's ALLOWED_SHARED.
EXCLUDED_SHARED: dict[tuple[str, str], str] = {
    ("cmux-next-dev-daily-dispatch.yml", ""): "the dispatcher reads the branch tip when it starts and builds nothing",
    ("cmux-tui-release-delivery.yml", ""): (
        "one registry delivery at a time; each run reads the newest release when it starts"),
    ("nightly-next-canary.yml", ""): "the scheduled 'feed' tick canaries the newest feed build when it starts",
    ("nightly-next-feed-watch.yml", ""): "a schedule-only watch that reads the feed when it starts",
    ("nightly-next-tick.yml", "request"): "the tick dispatches no build itself; a sha request has its own group",
    ("nightly-next-tick.yml", "unstick"): "reads every run's state when it starts; builds nothing",
    ("nightly.yml", ""): "the scheduled cache seed builds the branch tip when it starts; pushes are per run",
    ("nightly.yml", "promote-nightly-next"): "a promotion request builds nothing; decideNewest() covers an evicted one",
    ("nightly.yml", "await-release-surface-ack"): "retired (if: false); it never runs",
    ("nightly.yml", "publish-nightly"): (
        "known gap tracked by tests/test_nightly_delivery_concurrency.py: runs only for branch builds that "
        "publish no main or rc channel"),
    ("published-in.yml", ""): "labels merged pull requests from the stable feed; reads the feed when it starts",
}

# cancel-in-progress true in an excluded workflow, outside pull request test runs, as it is today.
EXCLUDED_CANCEL: dict[tuple[str, str], str] = {
    ("coderouter-release.yml", ""): "keyed by the tag ref; only a re-push of the same tag cancels its own run",
}

# workflow_run maintenance workflows whose run handles one source run, so no group may be shared.
PER_SOURCE_RUN: dict[str, str] = {
    "ci-hosted-queue-rescue.yml": "each run re-runs the one source run that failed or was cancelled",
    "ci-manual-dispatch-guard.yml": "each run guards the one dispatched CI run that fired it; seconds long",
    "ci-owned-pool-rescue.yml": (
        "a workflow_run rescue handles its one source run; the schedule sweep shares owned-pool-sweeper"),
    "cmux-tui-artifacts-retry.yml": "each run retries the one failed artifacts run that fired it",
    "merge-group-fail-fast.yml": "each run watches the one merge-group run that fired it",
    "pr-media.yml": "each run renders media for the one pull request run that fired it; tours are per PR",
}

# workflow_run workflows whose shared group is keyed by the source run's workflow, repository or pull request:
# runs on one branch are not all interchangeable, so the queue janitor never collapses their stuck runs.
SOURCE_KEYED: dict[str, str] = {
    "ci-failure-attribution.yml": "one group per source head repository and branch",
    "ci-guard-attribution.yml": "one group per pull request branch, or per source workflow on main",
}

# cancel-in-progress expressions that are false on the schedule event, which the shared reader
# (delivery_concurrency) cannot prove through a `!`.
CANCEL_FALSE_ON_SCHEDULE: dict[str, str] = {
    "ci-owned-pool-rescue.yml": "!(schedule || dispatch without run_id): false for every schedule run",
}

# Trivial pull request checks that keep superseded runs, and why.
TRIVIAL_NO_SUPERSEDE: dict[str, str] = {
    "cla.yml": "a CLA signature comment must never cancel the check another comment started",
    "cla-policy-guard.yml": (
        "required context; ci-hosted-queue-rescue and ci-cla-quota-rerun re-run its cancelled runs"),
    "contributor-welcome.yml": "opened only: one run per pull request",
    "merge-receipt.yml": "closed only: one run per pull request",
    "labels-sync.yml": "one shared group: a sync writes repository labels and must not be cut short",
    "fleet-artifact-cdn.yml": "a push deploys the worker; a cut-short deploy is worse than a queued test",
    "ci-cache-receipts.yml": "receipt bookkeeping keyed per ref; each run writes its own receipt",
    "ci-artifact-transport.yml": "transport probe keyed per ref; each run measures its own head",
}


def is_excluded(name: str) -> bool:
    """A nightly, DEV, promote, release, publish or app/feed workflow: never deduped or cancelled."""
    return any(fnmatch(name.lower(), pattern) for pattern in EXCLUDED_GLOBS)


def collapsible_run(path: str | None, event: str | None) -> bool:
    """A run this rule lets share a group with its workflow's other runs: a schedule or workflow_run run of a
    workflow that is neither excluded nor handles one source run (PER_SOURCE_RUN). The queue janitor reads it
    to cancel all but the newest such run GitHub left queued with nothing started."""
    name = str(path or "").rsplit("/", 1)[-1].split("@", 1)[0]
    if not name or is_excluded(name) or event not in CRON_EVENTS:
        return False
    return not (event == "workflow_run" and (name in PER_SOURCE_RUN or name in SOURCE_KEYED))


@dataclass(frozen=True)
class Workflow:
    path: Path
    text: str
    doc: dict
    events: frozenset[str]
    blocks: dict[str, dict[str, str]]
    inputs: dict[str, dict[str, tuple[bool, bool]]]

    @property
    def name(self) -> str:
        return self.path.name

    def jobs(self) -> dict[str, dict]:
        jobs = self.doc.get("jobs") or {}
        return {str(k): v for k, v in jobs.items() if isinstance(v, dict)}

    def block_for(self, job: str) -> dict[str, str] | None:
        return self.blocks.get(job) or self.blocks.get("")

    def runs_on_event(self, job: str, event: str) -> bool:
        """False only when the job's `if:` is provably false on `event` (it names other events)."""
        condition = self.jobs()[job].get("if")
        if condition is None or isinstance(condition, bool):
            return condition is not False
        text = str(condition).strip()
        match = re.fullmatch(r"\$\{\{(.*)\}\}", text, flags=re.S)
        try:
            kinds = dc._Parser(match.group(1) if match else text, self.inputs.get(event, {}), event).parse()
        except dc._Unreadable:
            return True
        return kinds != {dc.FALSY}


def _scalar(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return " ".join(str(value).split())


def _block(concurrency: object) -> dict[str, str] | None:
    if concurrency is None:
        return None
    if isinstance(concurrency, dict):
        block = {key: _scalar(concurrency[key]) for key in ("group", "cancel-in-progress") if key in concurrency}
        return block or {"unreadable": str(concurrency)}
    return {"group": _scalar(concurrency), "cancel-in-progress": "false"}


def _events(doc: dict) -> frozenset[str]:
    on = doc.get("on", doc.get(True))  # PyYAML reads a bare `on:` key as True
    if isinstance(on, str):
        return frozenset({on})
    if isinstance(on, (list, dict)):
        return frozenset(str(event) for event in on)
    return frozenset()


def load(path: Path) -> Workflow:
    import yaml  # here, so the queue janitor can import is_excluded() without PyYAML

    text = path.read_text(encoding="utf-8")
    doc = yaml.safe_load(text)
    if not isinstance(doc, dict):
        raise ValueError(f"{path.name}: not a workflow mapping")
    blocks: dict[str, dict[str, str]] = {}
    top = _block(doc.get("concurrency"))
    if top is not None:
        blocks[""] = top
    for name, job in (doc.get("jobs") or {}).items():
        own = _block(job.get("concurrency")) if isinstance(job, dict) else None
        if own is not None:
            blocks[str(name)] = own
    return Workflow(path, text, doc, _events(doc), blocks, dc.declared_inputs(text))


def workflows(root: Path) -> list[Workflow]:
    folder = root / ".github" / "workflows"
    return [load(path) for path in sorted([*folder.glob("*.yml"), *folder.glob("*.yaml")])]


def shared_on(block: dict[str, str], workflow: Workflow, event: str) -> bool:
    return "group" in block and dc.can_be_shared(block["group"], workflow.inputs, frozenset({event}))


def _cancel_kinds(block: dict[str, str], workflow: Workflow, event: str) -> set[str]:
    value = block.get("cancel-in-progress", "false").strip()
    if value in ("false", ""):
        return {dc.FALSY}
    if value == "true":
        return {dc.CONST}
    parts = re.findall(r"^\$\{\{(.*)\}\}$", value, flags=re.S)
    if not parts:
        return {dc.CONST, dc.FALSY}
    try:
        return dc._Parser(parts[0], workflow.inputs.get(event, {}), event).parse()
    except dc._Unreadable:
        return {dc.CONST, dc.FALSY}


def cron_findings(workflow: Workflow) -> list[str]:
    """Why a non-excluded schedule or workflow_run workflow can queue more than one run of itself."""
    if is_excluded(workflow.name):
        return []
    problems = []
    for event in CRON_EVENTS:
        if event not in workflow.events:
            continue
        if event == "workflow_run" and workflow.name in PER_SOURCE_RUN:
            continue
        for job in workflow.jobs():
            if not workflow.runs_on_event(job, event):
                continue
            block = workflow.block_for(job)
            where = f"{workflow.name} job {job} (on {event})"
            if block is None or "unreadable" in block or "group" not in block:
                problems.append(f"{where}: no concurrency group, so every {event} run queues its own run. Add "
                                f"`concurrency: {{group: {workflow.path.stem}, cancel-in-progress: false}}`.")
                continue
            if not shared_on(block, workflow, event):
                problems.append(f"{where}: group {block['group']!r} is unique per run on {event}, so runs pile up. "
                                "Key it so every scheduled run shares it (dispatches may keep their own key).")
            kinds = _cancel_kinds(block, workflow, event)
            if event == "schedule" and kinds != {dc.FALSY} and workflow.name not in CANCEL_FALSE_ON_SCHEDULE:
                problems.append(f"{where}: cancel-in-progress {block.get('cancel-in-progress')!r} can cut a running "
                                "scheduled run short; use false (or true only for pull request events).")
            if event == "workflow_run" and kinds == {dc.CONST}:
                problems.append(f"{where}: cancel-in-progress is always true; a running maintenance run is never "
                                "cut short.")
    return problems


def excluded_findings(workflow: Workflow) -> list[str]:
    """Why an excluded (delivery, release, publish) workflow now cancels or dedupes runs it did not before."""
    if not is_excluded(workflow.name):
        return []
    problems = []
    for owner, block in workflow.blocks.items():
        where = f"{workflow.name} {'job ' + owner if owner else 'top-level'}"
        if "unreadable" in block or "group" not in block:
            problems.append(f"{where}: concurrency this check cannot read ({block})")
            continue
        cancel = block.get("cancel-in-progress", "false")
        non_pr = [e for e in workflow.events if e not in PR_EVENTS]
        if any(_cancel_kinds(block, workflow, e) != {dc.FALSY} for e in non_pr or ["(any)"]) \
                and (workflow.name, owner) not in EXCLUDED_CANCEL:
            problems.append(f"{where}: cancel-in-progress {cancel!r}; a nightly, dev, promote, release or publish "
                            "run is never cancelled (only a pull request test run may be).")
        for event in CRON_EVENTS:
            if event in workflow.events and shared_on(block, workflow, event) \
                    and (workflow.name, owner) not in EXCLUDED_SHARED:
                problems.append(f"{where}: group {block['group']!r} is shared on {event}, so a newer run replaces "
                                "a waiting build. Key it per run or SHA; never dedupe a delivery run.")
    return problems


def _runs_on_text(job: dict) -> str:
    runs_on = job.get("runs-on")
    if isinstance(runs_on, dict):
        runs_on = [runs_on.get("group", ""), *(runs_on.get("labels") or [])]
    return " ".join(map(str, runs_on)) if isinstance(runs_on, list) else str(runs_on or "")


def is_trivial(workflow: Workflow) -> bool:
    """A seconds-long pull request check: PR-triggered, every job Linux with a short timeout."""
    if not set(PR_EVENTS) & workflow.events or is_excluded(workflow.name):
        return False
    jobs = workflow.jobs()
    if not jobs:
        return False
    for job in jobs.values():
        if "uses" in job:
            return False
        timeout = job.get("timeout-minutes")
        if not isinstance(timeout, int) or timeout > TRIVIAL_TIMEOUT_MINUTES:
            return False
        runs_on = _runs_on_text(job)
        if re.search(r"mac|xcode|glaeda|windows", runs_on, re.IGNORECASE) or "matrix." in runs_on:
            return False
    return True


def trivial_checks(items: Iterable[Workflow]) -> list[str]:
    return sorted(w.name for w in items if is_trivial(w))


PR_KEY = re.compile(r"github\.event\.pull_request\.number|github\.event\.number|github\.head_ref|github\.ref\b")


def supersede_findings(workflow: Workflow) -> list[str]:
    """Why a trivial check keeps a run for a pull request head that has moved on."""
    if not is_trivial(workflow) or workflow.name in TRIVIAL_NO_SUPERSEDE:
        return []
    events = sorted(set(PR_EVENTS) & workflow.events)
    problems = []
    for job in workflow.jobs():
        if not any(workflow.runs_on_event(job, e) for e in events):
            continue
        block = workflow.block_for(job)
        if block is None or "group" not in block:
            problems.append(f"{workflow.name} job {job}: no concurrency group; a moved pull request head leaves the "
                            "old run queued. Add `group: <workflow>-${{ github.event.pull_request.number || "
                            "github.ref }}` with cancel-in-progress true.")
            continue
        if not PR_KEY.search(block["group"]):
            problems.append(f"{workflow.name} job {job}: group {block['group']!r} is not keyed by the pull request")
        if not any(dc.CONST in _cancel_kinds(block, workflow, e) for e in events):
            problems.append(f"{workflow.name} job {job}: cancel-in-progress is never true on {', '.join(events)}, so "
                            "a superseded head's run stays queued")
    return problems
