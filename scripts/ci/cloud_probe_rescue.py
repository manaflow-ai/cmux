#!/usr/bin/env python3
"""Bounded rescue for the credentialed cloud-overflow probe watcher.

This is deliberately separate from the owned-pool/nightly rescue policy.  It
touches one workflow and one unstarted control job only.  A queued watcher is
safe to retry because it has not received the App key; started watchers are
left alone and execute their normal probe/switch path.
"""
from __future__ import annotations

import dataclasses
import datetime as dt
import time
from collections.abc import Callable, Mapping

WORKFLOW_PATH = ".github/workflows/ci-cloud-overflow-probe.yml"
WATCH_JOB = "Watch the probe and switch overflow"
QUEUED = frozenset({"queued", "waiting", "pending", "requested"})
NO_START_SECONDS = 180
MAX_ATTEMPT = 3
CANCEL_WAIT_SECONDS = 20 * 60
FORCE_CANCEL_AFTER_SECONDS = 5 * 60

# The probe matrix occupies the measured Linux labels. Keep its first rescue on
# the measured 8-vCPU Linux size, then use the existing Mac and 16-vCPU sizes.
WATCH_LABELS = (
    "blacksmith-8vcpu-ubuntu-2404",
    "blacksmith-6vcpu-macos-26",
    "blacksmith-16vcpu-ubuntu-2404",
)


@dataclasses.dataclass(frozen=True)
class Decision:
    action: str  # "rescue" or "noop"
    reason: str
    next_label: str = ""


def _time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(dt.timezone.utc)


def _run_id(run: Mapping[str, object]) -> int:
    try:
        value = int(run.get("id") or 0)
    except (TypeError, ValueError):
        return 0
    return value


def decide(run: Mapping[str, object], jobs: list[Mapping[str, object]],
           *, now: dt.datetime, no_start_seconds: int = NO_START_SECONDS) -> Decision:
    """Return a retry decision only for an exact queued, unassigned watcher."""
    if run.get("path") != WORKFLOW_PATH:
        return Decision("noop", "different workflow")
    try:
        attempt = int(run.get("run_attempt") or 0)
    except (TypeError, ValueError):
        return Decision("noop", "invalid run attempt")
    if attempt < 1 or attempt >= MAX_ATTEMPT:
        return Decision("noop", "attempt is at rescue limit")
    watch = [job for job in jobs if job.get("name") == WATCH_JOB]
    if len(watch) != 1:
        return Decision("noop", "watch job is absent or ambiguous")
    job = watch[0]
    if job.get("status") not in QUEUED or job.get("runner_name") or job.get("runner_id"):
        return Decision("noop", "watch job has started or is not queued")
    created = _time(job.get("created_at")) or _time(run.get("created_at"))
    if created is None or (now.astimezone(dt.timezone.utc) - created).total_seconds() < no_start_seconds:
        return Decision("noop", "watch job has not reached the no-start budget")
    return Decision("rescue", f"watch job queued without a runner for at least {no_start_seconds}s",
                    WATCH_LABELS[attempt])


def rescue_control(api: object, run: Mapping[str, object], *, now: Callable[[], dt.datetime] = lambda: dt.datetime.now(dt.timezone.utc),
                   sleep: Callable[[float], None] = time.sleep) -> Decision:
    """Cancel-settle-rerun one stalled probe run; return the next label.

    ``api`` is the existing rescue client: ``jobs(id, attempt)``,
    ``run(id)``, ``cancel(id)``, ``force_cancel(id)`` and ``rerun(id, next)``.
    No caller should invoke this for a nightly run; ``decide`` rejects every
    other workflow path before a mutation.
    """
    run_id = _run_id(run)
    if not run_id:
        return Decision("noop", "invalid run id")
    try:
        attempt = int(run.get("run_attempt") or 0)
    except (TypeError, ValueError):
        return Decision("noop", "invalid run attempt")
    # A workflow_run event can be delayed until a later attempt exists. Read
    # the run and its current-attempt jobs immediately before mutating it.
    current = api.run(run_id)
    try:
        current_attempt = int(current.get("run_attempt") or 0)
    except (TypeError, ValueError):
        return Decision("noop", "current run attempt is invalid")
    if current.get("path") != WORKFLOW_PATH or current_attempt != attempt:
        return Decision("noop", "run attempt changed before rescue")
    jobs = list(api.jobs(run_id, current_attempt))
    decision = decide(current, jobs, now=now())
    if decision.action != "rescue":
        return decision
    # Close the last read-to-cancel gap: a runner may be assigned while the
    # first job listing is in flight.
    confirm = api.run(run_id)
    try:
        confirmed_attempt = int(confirm.get("run_attempt") or 0)
    except (TypeError, ValueError):
        return Decision("noop", "current run attempt is invalid")
    if confirm.get("path") != WORKFLOW_PATH or confirmed_attempt != attempt:
        return Decision("noop", "run attempt changed before cancel")
    confirmed = decide(confirm, list(api.jobs(run_id, attempt)), now=now())
    if confirmed.action != "rescue":
        return confirmed
    api.cancel(run_id)
    started = now()
    forced = False
    while True:
        current = api.run(run_id)
        try:
            settling_attempt = int(current.get("run_attempt") or 0)
        except (TypeError, ValueError):
            return Decision("noop", "current run attempt became invalid while cancelling")
        if current.get("path") != WORKFLOW_PATH or settling_attempt != attempt:
            return Decision("noop", "run attempt changed while cancelling")
        if current.get("status") in {"completed", "cancelled"}:
            break
        elapsed = (now() - started).total_seconds()
        if not forced and elapsed >= FORCE_CANCEL_AFTER_SECONDS:
            api.force_cancel(run_id)
            forced = True
        if elapsed >= CANCEL_WAIT_SECONDS:
            return Decision("noop", "cancel did not settle before rescue deadline")
        sleep(min(10, max(1, CANCEL_WAIT_SECONDS - elapsed)))
    api.rerun(run_id, attempt + 1)
    return decision

