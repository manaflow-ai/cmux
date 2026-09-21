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
from collections.abc import Callable
from pathlib import Path


WORKFLOW = "persistent-macos-compile.yml"
JOB_NAME = "Persistent Apple compile"
TERMINAL = {"completed"}


def now() -> float:
    return time.monotonic()


def parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


class RoutingCanceled(RuntimeError):
    """Raised when GitHub cancels an in-progress routing observation."""


def install_cancel_event() -> threading.Event:
    """Translate process cancellation signals into one shared observation event."""
    event = threading.Event()

    def cancel_observation(_signum: int, _frame: object) -> None:
        event.set()

    signal.signal(signal.SIGINT, cancel_observation)
    signal.signal(signal.SIGTERM, cancel_observation)
    return event


def observe_until(
    deadline: float,
    interval_seconds: float,
    observe: Callable[[], object | None],
    *,
    cancel_event: threading.Event,
    monotonic: Callable[[], float] = now,
) -> object | None:
    """Observe bounded external state until ready, canceled, or the deadline passes."""
    while True:
        value = observe()
        if value is not None:
            return value
        remaining = deadline - monotonic()
        if remaining <= 0:
            return None
        if cancel_event.wait(min(interval_seconds, remaining)):
            raise RoutingCanceled("routing observation canceled")


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
    if args.author_association not in {"MEMBER", "OWNER"}:
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


def valid_observe_budget(observe_seconds: int) -> bool:
    """Bound how long a hosted admission runner may wait for persistent output."""
    return 5 <= observe_seconds <= 60


def verify_live_request(api: GitHub, args: argparse.Namespace) -> tuple[bool, str]:
    source_run = api.api(f"actions/runs/{args.run_id}")
    if not isinstance(source_run, dict):
        return False, "source_run_observation_invalid"
    try:
        observed_attempt = int(source_run.get("run_attempt"))
        expected_attempt = int(args.run_attempt)
        expected_pr = int(args.pr_number)
    except (TypeError, ValueError):
        return False, "source_run_identity_invalid"
    source_pull_requests = source_run.get("pull_requests")
    if not isinstance(source_pull_requests, list):
        return False, "source_run_pr_observation_invalid"
    matching_prs = [
        item for item in source_pull_requests
        if isinstance(item, dict) and item.get("number") == expected_pr
    ]
    run_repository = (source_run.get("head_repository") or {}).get("full_name", "")
    source_checks = {
        "source_run_event_mismatch": source_run.get("event") == "pull_request",
        "source_run_attempt_mismatch": observed_attempt == expected_attempt,
        "source_run_workflow_mismatch": source_run.get("path") == ".github/workflows/ci.yml",
        "source_run_source_mismatch": source_run.get("head_sha") == args.source_sha,
        "source_run_repository_mismatch": str(run_repository).casefold() == args.repository.casefold(),
        "source_run_pr_mismatch": len(matching_prs) == 1,
        "source_run_pr_head_mismatch": (
            len(matching_prs) == 1
            and (matching_prs[0].get("head") or {}).get("sha") == args.head_sha
        ),
        "source_run_pr_base_mismatch": (
            len(matching_prs) == 1
            and (matching_prs[0].get("base") or {}).get("sha") == args.source_parent1
        ),
    }
    for reason, passed in source_checks.items():
        if not passed:
            return False, reason

    pr = api.api(f"pulls/{args.pr_number}")
    if not isinstance(pr, dict):
        return False, "pr_observation_invalid"
    head = pr.get("head") or {}
    base = pr.get("base") or {}
    head_repo = (head.get("repo") or {}).get("full_name", "")
    checks = {
        "pr_closed": pr.get("state") == "open",
        "untrusted_repository": str(head_repo).casefold() == args.repository.casefold(),
        "untrusted_author": pr.get("author_association") in {"MEMBER", "OWNER"},
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


def find_run(
    api: GitHub,
    request_id: str,
    deadline: float,
    cancel_event: threading.Event,
) -> dict[str, object]:
    """Find the exact dispatched producer run within a bounded observation window."""
    title = f"persistent-mac-compile-{request_id}"

    def observe() -> dict[str, object] | None:
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

    found = observe_until(
        deadline,
        1.0,
        observe,
        cancel_event=cancel_event,
    )
    if not isinstance(found, dict):
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
    parser.add_argument("--observe-seconds", type=int, default=60)
    parser.add_argument("--github-output", type=Path, required=True)
    parser.add_argument("--observe-only", action="store_true")
    args = parser.parse_args()

    eligible, reason = eligibility(args)
    if not eligible:
        return fallback(args.github_output, reason)
    if not valid_budget(args.queue_seconds, args.execution_seconds):
        return fallback(args.github_output, "invalid_budget")
    if args.observe_only and not valid_observe_budget(args.observe_seconds):
        return fallback(args.github_output, "invalid_observe_budget")

    request_id = f"{args.run_id}-{args.run_attempt}"
    api = GitHub(args.repository)
    cancel_event = install_cancel_event()
    try:
        verified, live_reason = verify_live_request(api, args)
        if not verified:
            return fallback(args.github_output, live_reason)

        discovery_started = now()
        observation_deadline = (
            discovery_started + args.observe_seconds if args.observe_only else None
        )
        if args.observe_only:
            try:
                run = find_run(api, request_id, observation_deadline, cancel_event)
            except RuntimeError as error:
                if "did not become observable" in str(error):
                    return fallback(args.github_output, "observe_timeout")
                raise
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
            run = find_run(api, request_id, discovery_started + 30, cancel_event)
        run_id = int(run["id"])
        queue_deadline = now() + args.queue_seconds
        if observation_deadline is not None:
            queue_deadline = min(queue_deadline, observation_deadline)

        def observe_queue() -> dict[str, object] | None:
            selected = compile_job(api, run_id)
            if selected and (
                selected.get("started_at")
                or selected.get("status") in TERMINAL
            ):
                return selected
            return None

        selected = observe_until(
            queue_deadline,
            2.0,
            observe_queue,
            cancel_event=cancel_event,
        )
        if isinstance(selected, dict) and selected.get("status") in TERMINAL and not selected.get("started_at"):
            conclusion = str(selected.get("conclusion") or "unknown")
            return fallback(args.github_output, f"producer_{conclusion}", producer_run_id=run_id)
        if not isinstance(selected, dict) or not selected.get("started_at"):
            if not args.observe_only:
                cancel(api, run_id)
            return fallback(
                args.github_output,
                "observe_timeout" if args.observe_only else "queue_timeout",
                producer_run_id=run_id,
            )

        created = parse_time(str(selected.get("created_at") or ""))
        started = parse_time(str(selected.get("started_at") or ""))
        if created is None or started is None:
            if not args.observe_only:
                cancel(api, run_id)
            return fallback(args.github_output, "producer_timing_unavailable", producer_run_id=run_id)
        queue_seconds = max(0.0, (started - created).total_seconds())

        execution_deadline = now() + args.execution_seconds
        if observation_deadline is not None:
            execution_deadline = min(execution_deadline, observation_deadline)

        def observe_completion() -> dict[str, object] | None:
            current = compile_job(api, run_id)
            if current and current.get("status") == "completed":
                return current
            return None

        completed = observe_until(
            execution_deadline,
            3.0,
            observe_completion,
            cancel_event=cancel_event,
        )
        if not isinstance(completed, dict):
            if not args.observe_only:
                cancel(api, run_id)
            return fallback(
                args.github_output,
                "observe_timeout" if args.observe_only else "execution_budget_exceeded",
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
    except (RuntimeError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
        print(f"persistent Mac routing fell back to hosted: {error}", file=sys.stderr)
        return fallback(args.github_output, "routing_error")


if __name__ == "__main__":
    raise SystemExit(main())
