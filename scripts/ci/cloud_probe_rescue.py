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
import argparse
import base64
import importlib
import json
import os
from pathlib import Path
import re
import sys
import time
from collections.abc import Callable, Mapping

WORKFLOW_PATH = ".github/workflows/ci-cloud-overflow-probe.yml"
TRUSTED_REPOSITORY = "manaflow-ai/cmux"
TRUSTED_HEAD_BRANCH = "main"
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


def _trusted_source(run: Mapping[str, object], repository: str = TRUSTED_REPOSITORY) -> bool:
    source = run.get("head_repository")
    return (isinstance(source, Mapping) and source.get("full_name") == repository
            and run.get("head_branch") == TRUSTED_HEAD_BRANCH)


def workflow_supports_reroute(api: object, run: Mapping[str, object]) -> bool:
    """Reject pre-change queued runs whose rerun would keep the old label."""
    sha = str(run.get("head_sha") or "")
    if not sha or not hasattr(api, "request"):
        return False
    try:
        data = api.request("GET", f"/contents/{WORKFLOW_PATH}?ref={sha}")
        content = base64.b64decode(str((data or {}).get("content") or "").replace("\n", "")).decode()
        import yaml
        document = yaml.safe_load(content)
    except Exception:
        return False
    jobs = document.get("jobs") if isinstance(document, Mapping) else None
    watch = jobs.get("watch") if isinstance(jobs, Mapping) else None
    runs_on = watch.get("runs-on") if isinstance(watch, Mapping) else None
    if not isinstance(runs_on, str):
        return False
    normalized = re.sub(r"[\s'\"]", "", runs_on)
    expected = (f"github.run_attempt==1&&{WATCH_LABELS[0]}||"
                f"github.run_attempt==2&&{WATCH_LABELS[1]}||{WATCH_LABELS[2]}")
    return normalized == "${{" + expected + "}}"


def decide(run: Mapping[str, object], jobs: list[Mapping[str, object]],
           *, now: dt.datetime, no_start_seconds: int = NO_START_SECONDS) -> Decision:
    """Return a retry decision only for an exact queued, unassigned watcher."""
    if run.get("path") != WORKFLOW_PATH:
        return Decision("noop", "different workflow")
    if not _trusted_source(run):
        return Decision("noop", "run is not a trusted main-repository run")
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
    created = _time(job.get("created_at"))
    if created is None:
        # A rerun has a new queue budget.  Its run.created_at is the original
        # attempt's timestamp, so using it for attempt 2/3 would rescue a new
        # watcher immediately.  Fail closed when the new start timestamp is
        # absent instead of borrowing stale timing data.
        created = (_time(run.get("created_at")) if attempt == 1
                   else _time(run.get("run_started_at")))
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
    if current.get("path") != WORKFLOW_PATH or current_attempt != attempt or not _trusted_source(current):
        return Decision("noop", "run attempt changed before rescue")
    if not workflow_supports_reroute(api, current):
        return Decision("noop", "workflow revision predates the attempt-aware watcher route")
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


def candidate_runs(api: object, repository: str = TRUSTED_REPOSITORY) -> list[Mapping[str, object]]:
    """Read in-flight probe runs; the caller filters and rescues each once."""
    data = api.request("GET", f"/actions/workflows/{WORKFLOW_PATH.rsplit('/', 1)[-1]}/runs?per_page=100")
    return [run for run in (data or {}).get("workflow_runs", [])
            if isinstance(run, Mapping) and run.get("path") == WORKFLOW_PATH
            and run.get("status") in {"queued", "in_progress", "pending"}
            and _trusted_source(run, repository)]


def run_once(api: object, run: Mapping[str, object]) -> Decision:
    return rescue_control(api, run)


def rescue_sequence(api: object, run: Mapping[str, object], *, wait_seconds: int = 0,
                    follow_retries: bool = False,
                    sleep: Callable[[float], None] = time.sleep) -> list[Decision]:
    """Rescue one event and, for a targeted event, one fresh rerun attempt.

    A rerun made with the Actions token does not emit another ``workflow_run``
    event.  The requested-event path therefore gets one fixed queue budget and
    one fresh run read for attempt 2.  Scheduled sweeps stay a single pass so
    they never hold the long owned-pool sweeper open with polling.
    """
    if wait_seconds:
        sleep(max(0, min(wait_seconds, 300)))
    decision = run_once(api, run)
    decisions = [decision]
    if not follow_retries or decision.action != "rescue":
        return decisions
    attempt = int(run.get("run_attempt") or 0)
    if attempt + 1 >= MAX_ATTEMPT:
        return decisions
    sleep(NO_START_SECONDS)
    refreshed = api.run(_run_id(run))
    decisions.append(run_once(api, refreshed))
    return decisions


def _client(source_root: Path, token: str, repo: str, read_token: str) -> object:
    source_root = source_root.resolve()
    ci_root = source_root / "scripts" / "ci"
    if not (ci_root / "owned_pool_rescue.py").is_file():
        raise SystemExit(f"trusted source root is missing scripts/ci/owned_pool_rescue.py: {source_root}")
    sys.path.insert(0, str(ci_root))
    client = importlib.import_module("owned_pool_rescue")
    if Path(client.__file__).resolve().parent != ci_root:
        raise SystemExit("owned-pool rescue client was imported from a different checkout")
    return client.GitHub(token=token, repo=repo, read_token=read_token)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="rescue queued cloud-overflow probe watchers")
    parser.add_argument("--run-id", type=int, help="inspect one workflow run")
    parser.add_argument("--source-root", type=Path,
                        default=Path(os.environ.get("GITHUB_WORKSPACE", Path(__file__).resolve().parents[2])),
                        help="trusted checkout containing the rescue client (normally GITHUB_WORKSPACE)")
    parser.add_argument("--wait-seconds", "--sweep-seconds", dest="wait_seconds", type=int, default=0,
                        help="wait once before the API read (bounded to five minutes; no polling loop)")
    args = parser.parse_args(argv)
    repo = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    if repo != "manaflow-ai/cmux":
        raise SystemExit("cloud probe rescue only runs for manaflow-ai/cmux")
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        raise SystemExit("GH_TOKEN is required")
    api = _client(args.source_root, token, repo, os.environ.get("READ_TOKEN", ""))
    if args.wait_seconds:
        time.sleep(max(0, min(args.wait_seconds, 300)))
    runs = [api.run(args.run_id)] if args.run_id else candidate_runs(api, repo)
    for run in runs:
        for decision in rescue_sequence(api, run, follow_retries=args.run_id is not None, sleep=time.sleep):
            print(json.dumps({"run_id": run.get("id"), "action": decision.action,
                              "reason": decision.reason, "next_label": decision.next_label}, sort_keys=True), flush=True)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
