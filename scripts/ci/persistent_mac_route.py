#!/usr/bin/env python3
"""Dispatch the bounded persistent-Mac compile pilot, with hosted fallback."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


WORKFLOW = "persistent-macos-compile.yml"
JOB_NAME = "Persistent Apple compile"
TERMINAL = {"completed"}

# Must stay identical to the producer's `authorize` job in
# .github/workflows/persistent-macos-compile.yml, which admits only MEMBER/OWNER.
# Routing wider than the producer is not a security hole -- the producer still
# refuses -- but it dispatches a producer that is guaranteed to fail, burning an
# owned-Mac allocation and returning producer_failure instead of falling through
# to the hosted path immediately. Alignment is deliberately at the narrower set:
# the owned hardware keeps warm cmux DerivedData across runs, so its trust
# boundary stays at organization membership rather than per-repository
# collaborator grants.
TRUSTED_AUTHOR_ASSOCIATIONS = frozenset({"MEMBER", "OWNER"})


def now() -> float:
    return time.monotonic()


def parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


class RetryCancelled(RuntimeError):
    """Raised when CI cancellation interrupts a bounded GitHub observation."""


class RetryWait:
    """Cancellation-aware bounded retry owner for GitHub control-plane observation."""

    def __init__(self, *, clock=now, wait=None):
        self._clock = clock
        self._cancelled = threading.Event()
        self._wait = wait or self._cancelled.wait
        self.cancel_signal: int | None = None

    def cancel(self, signum: int | None = None) -> None:
        if signum is not None:
            self.cancel_signal = signum
        self._cancelled.set()

    def until(self, deadline: float, probe, *, initial_delay: float = 0.5, max_delay: float = 3.0):
        delay = initial_delay
        while True:
            complete, value = probe()
            if complete:
                return value
            remaining = deadline - self._clock()
            if remaining <= 0:
                return None
            if self._cancelled.is_set() or self._wait(min(delay, remaining)):
                raise RetryCancelled("persistent Mac route observation was cancelled")
            delay = min(max_delay, delay * 2)


def install_cancel_handlers(waiter: RetryWait) -> None:
    def cancel_wait(signum, _frame) -> None:
        waiter.cancel(signum)

    signal.signal(signal.SIGINT, cancel_wait)
    signal.signal(signal.SIGTERM, cancel_wait)


class GitHub:
    def __init__(self, repository: str):
        self.repository = repository

    def api(self, path: str, *, method: str = "GET") -> object:
        result = subprocess.run(
            ["gh", "api", "--method", method, f"repos/{self.repository}/{path}"],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or f"gh api exited {result.returncode}")
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def dispatch(self, fields: dict[str, str]) -> None:
        argv = [
            "gh",
            "workflow",
            "run",
            WORKFLOW,
            "--repo",
            self.repository,
            "--ref",
            "main",
        ]
        for key, value in fields.items():
            argv.extend(["--field", f"{key}={value}"])
        result = subprocess.run(argv, text=True, capture_output=True, check=False)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or f"workflow dispatch exited {result.returncode}")


def cohort_match(cohort: str, pr_number: str, head_ref: str) -> bool:
    values = {value.strip() for value in cohort.split(",") if value.strip()}
    return pr_number in values or head_ref in values


def eligibility(args: argparse.Namespace) -> tuple[bool, str]:
    selector = args.selector.strip().lower()
    if selector in {"", "0", "off", "false"}:
        return False, "selector_off"
    if args.event_name != "pull_request":
        return False, "event_not_pull_request"
    if args.head_repository.casefold() != args.repository.casefold():
        return False, "untrusted_repository"
    if args.author_association not in TRUSTED_AUTHOR_ASSOCIATIONS:
        return False, "untrusted_author"
    if selector == "pilot":
        if cohort_match(args.cohort, args.pr_number, args.head_ref):
            return True, "pilot"
        return False, "outside_pilot_cohort"
    if selector in {"1", "on", "true", "all"}:
        return True, "all"
    return False, "invalid_selector"


def valid_budget(queue_seconds: int, execution_seconds: int) -> bool:
    return (
        15 <= queue_seconds <= 120
        and 60 <= execution_seconds <= 480
        and queue_seconds + execution_seconds <= 600
    )


def verify_live_request(api: GitHub, args: argparse.Namespace) -> tuple[bool, str]:
    pr = api.api(f"pulls/{args.pr_number}")
    if not isinstance(pr, dict):
        return False, "pr_observation_invalid"
    head = pr.get("head") or {}
    base = pr.get("base") or {}
    head_repo = (head.get("repo") or {}).get("full_name", "")
    checks = {
        "pr_closed": pr.get("state") == "open",
        "untrusted_repository": str(head_repo).casefold() == args.repository.casefold(),
        "untrusted_author": pr.get("author_association") in TRUSTED_AUTHOR_ASSOCIATIONS,
        "head_changed": head.get("sha") == args.head_sha,
        "base_changed": base.get("sha") == args.source_parent1,
        "merge_changed": pr.get("merge_commit_sha") == args.source_sha,
    }
    for reason, passed in checks.items():
        if not passed:
            return False, reason
    commit = api.api(f"git/commits/{args.source_sha}")
    tree = (commit.get("tree") or {}).get("sha") if isinstance(commit, dict) else None
    if tree != args.source_tree:
        return False, "tree_changed"
    return True, "verified"


def matching_run(api: GitHub, request_id: str) -> dict[str, object] | None:
    title = f"persistent-mac-compile-{request_id}"
    payload = api.api(f"actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=50")
    runs = payload.get("workflow_runs", []) if isinstance(payload, dict) else []
    matches = [
        run for run in runs
        if isinstance(run, dict)
        and run.get("display_title") == title
        and run.get("head_branch") == "main"
    ]
    if not matches:
        return None
    matches.sort(key=lambda run: int(run.get("id", 0)), reverse=True)
    return matches[0]


def find_run(
    api: GitHub,
    request_id: str,
    deadline: float,
    waiter: RetryWait,
) -> dict[str, object]:
    def observe():
        run = matching_run(api, request_id)
        return (run is not None, run)

    found = waiter.until(deadline, observe)
    if found is None:
        raise RuntimeError("dispatched producer workflow did not become observable")
    return found


def jobs(api: GitHub, run_id: int) -> list[dict[str, object]]:
    payload = api.api(f"actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    if not isinstance(payload, dict) or not isinstance(payload.get("jobs"), list):
        raise RuntimeError("producer job list is malformed")
    return [job for job in payload["jobs"] if isinstance(job, dict)]


def compile_job(api: GitHub, run_id: int) -> dict[str, object] | None:
    matched = [job for job in jobs(api, run_id) if job.get("name") == JOB_NAME]
    if len(matched) > 1:
        raise RuntimeError("producer run has multiple compile jobs")
    return matched[0] if matched else None


def cancel(api: GitHub, run_id: int) -> None:
    try:
        api.api(f"actions/runs/{run_id}/cancel", method="POST")
    except RuntimeError as error:
        print(f"warning: producer cancellation failed: {error}", file=sys.stderr)


def cancel_owned_producer(
    api: GitHub,
    request_id: str,
    run_id: int | None,
    dispatched: bool,
    waiter: RetryWait,
    deadline: float,
) -> int | None:
    if run_id is None and dispatched:
        def observe():
            observed = matching_run(api, request_id)
            return (observed is not None, observed)

        try:
            observed = waiter.until(
                deadline,
                observe,
                initial_delay=0.25,
                max_delay=1.0,
            )
            if observed is not None:
                run_id = int(observed["id"])
        except (RuntimeError, KeyError, TypeError, ValueError) as error:
            print(
                f"warning: cancelled producer could not be rediscovered: {error}",
                file=sys.stderr,
            )
    if run_id is not None:
        cancel(api, run_id)
    return run_id


def write_outputs(path: Path, values: dict[str, object]) -> None:
    with path.open("a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def fallback(output: Path, reason: str, **extra: object) -> int:
    values = {
        "use_persistent": "false",
        "fallback_reason": reason,
        "producer_run_id": "",
        "artifact_id": "",
        "queue_to_start_seconds": "",
        "producer_allocated_seconds": "",
        **extra,
    }
    write_outputs(output, values)
    print(json.dumps(values, sort_keys=True))
    return 0


def success(
    output: Path,
    *,
    run_id: int,
    artifact_id: int,
    queue_seconds: float,
    allocated_seconds: float,
) -> int:
    values = {
        "use_persistent": "true",
        "fallback_reason": "",
        "producer_run_id": run_id,
        "artifact_id": artifact_id,
        "queue_to_start_seconds": round(queue_seconds, 3),
        "producer_allocated_seconds": round(allocated_seconds, 3),
    }
    write_outputs(output, values)
    print(json.dumps(values, sort_keys=True))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--selector", default="")
    parser.add_argument("--cohort", default="")
    parser.add_argument("--repository", required=True)
    parser.add_argument("--pr-number", default="")
    parser.add_argument("--head-repository", default="")
    parser.add_argument("--head-ref", default="")
    parser.add_argument("--author-association", default="")
    parser.add_argument("--head-sha", default="")
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--source-tree", required=True)
    parser.add_argument("--source-parent1", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--queue-seconds", type=int, default=90)
    parser.add_argument("--execution-seconds", type=int, default=480)
    parser.add_argument("--github-output", type=Path, required=True)
    parser.add_argument("--observe-only", action="store_true")
    parser.add_argument(
        "--ready-only",
        action="store_true",
        help="observe once and use the producer only when its compile is already complete",
    )
    args = parser.parse_args()
    if args.ready_only and not args.observe_only:
        parser.error("--ready-only requires --observe-only")

    eligible, reason = eligibility(args)
    if not eligible:
        return fallback(args.github_output, reason)
    if not valid_budget(args.queue_seconds, args.execution_seconds):
        return fallback(args.github_output, "invalid_budget")

    request_id = f"{args.run_id}-{args.run_attempt}"
    api = GitHub(args.repository)
    waiter = RetryWait()
    install_cancel_handlers(waiter)
    dispatched = False
    producer_run_id: int | None = None
    try:
        verified, live_reason = verify_live_request(api, args)
        if not verified:
            return fallback(args.github_output, live_reason)

        discovery_started = now()
        if args.ready_only:
            run = matching_run(api, request_id)
            if run is None:
                return fallback(args.github_output, "producer_not_ready")
        elif args.observe_only:
            run = find_run(api, request_id, discovery_started + 90, waiter)
        else:
            api.dispatch(
                {
                    "request_id": request_id,
                    "pr_number": args.pr_number,
                    "source_sha": args.source_sha,
                    "source_tree": args.source_tree,
                    "source_parent1": args.source_parent1,
                    "head_sha": args.head_sha,
                }
            )
            dispatched = True
            run = find_run(api, request_id, discovery_started + 30, waiter)
        run_id = int(run["id"])
        producer_run_id = run_id
        if args.ready_only:
            selected = compile_job(api, run_id)
            if selected is None or selected.get("status") != "completed":
                return fallback(
                    args.github_output,
                    "producer_not_ready",
                    producer_run_id=run_id,
                )
        else:
            queue_deadline = now() + args.queue_seconds

            def observe_queue():
                selected = compile_job(api, run_id)
                if selected and selected.get("started_at"):
                    return True, ("started", selected)
                if selected and selected.get("status") in TERMINAL:
                    return True, ("terminal", selected)
                return False, None

            queue_result = waiter.until(queue_deadline, observe_queue)
            if queue_result is not None and queue_result[0] == "terminal":
                selected = queue_result[1]
                conclusion = str(selected.get("conclusion") or "unknown")
                return fallback(args.github_output, f"producer_{conclusion}", producer_run_id=run_id)
            selected = queue_result[1] if queue_result is not None else None
            if not selected or not selected.get("started_at"):
                if not args.observe_only:
                    cancel(api, run_id)
                return fallback(args.github_output, "queue_timeout", producer_run_id=run_id)

        created = parse_time(str(selected.get("created_at") or ""))
        started = parse_time(str(selected.get("started_at") or ""))
        if created is None or started is None:
            if not args.observe_only:
                cancel(api, run_id)
            return fallback(args.github_output, "producer_timing_unavailable", producer_run_id=run_id)
        queue_seconds = max(0.0, (started - created).total_seconds())

        if args.ready_only:
            completed = selected
        else:
            execution_deadline = now() + args.execution_seconds

            def observe_execution():
                current = compile_job(api, run_id)
                if current and current.get("status") == "completed":
                    return True, current
                return False, None

            completed = waiter.until(execution_deadline, observe_execution)
            if completed is None:
                if not args.observe_only:
                    cancel(api, run_id)
                return fallback(
                    args.github_output,
                    "execution_budget_exceeded",
                    producer_run_id=run_id,
                    queue_to_start_seconds=round(queue_seconds, 3),
                )
        if completed.get("conclusion") != "success":
            return fallback(
                args.github_output,
                f"producer_{completed.get('conclusion') or 'failed'}",
                producer_run_id=run_id,
                queue_to_start_seconds=round(queue_seconds, 3),
            )

        completed_at = parse_time(str(completed.get("completed_at") or ""))
        started_at = parse_time(str(completed.get("started_at") or ""))
        allocated_seconds = (
            max(0.0, (completed_at - started_at).total_seconds())
            if completed_at is not None and started_at is not None
            else 0.0
        )
        artifacts = api.api(f"actions/runs/{run_id}/artifacts?per_page=100")
        candidates = artifacts.get("artifacts", []) if isinstance(artifacts, dict) else []
        name = f"persistent-mac-compile-{request_id}"
        matches = [
            artifact for artifact in candidates
            if isinstance(artifact, dict)
            and artifact.get("name") == name
            and artifact.get("expired") is False
        ]
        if len(matches) != 1:
            return fallback(
                args.github_output,
                "producer_artifact_missing",
                producer_run_id=run_id,
                queue_to_start_seconds=round(queue_seconds, 3),
                producer_allocated_seconds=round(allocated_seconds, 3),
            )
        return success(
            args.github_output,
            run_id=run_id,
            artifact_id=int(matches[0]["id"]),
            queue_seconds=queue_seconds,
            allocated_seconds=allocated_seconds,
        )
    except RetryCancelled:
        cancel_signal = waiter.cancel_signal or signal.SIGTERM
        if not args.observe_only:
            cleanup_waiter = RetryWait()
            install_cancel_handlers(cleanup_waiter)
            try:
                producer_run_id = cancel_owned_producer(
                    api,
                    request_id,
                    producer_run_id,
                    dispatched,
                    cleanup_waiter,
                    now() + 30,
                )
            except RetryCancelled:
                print(
                    "warning: producer rediscovery cancelled by a second signal",
                    file=sys.stderr,
                )
        fallback(
            args.github_output,
            "routing_cancelled",
            producer_run_id=producer_run_id or "",
        )
        return 128 + cancel_signal
    except (RuntimeError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
        print(f"persistent Mac routing fell back to hosted: {error}", file=sys.stderr)
        return fallback(args.github_output, "routing_error")


if __name__ == "__main__":
    raise SystemExit(main())
