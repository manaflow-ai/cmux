#!/usr/bin/env python3
"""Dispatch the existing E2E workflow for an exact revision and selected test."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import quote
import uuid

REPO = "manaflow-ai/cmux"
WORKFLOW = "test-e2e.yml"
ROOT = Path(__file__).resolve().parents[2]
RUN_DISCOVERY_ATTEMPTS = 12
RUN_DISCOVERY_TIMEOUT_SECONDS = 60.0
SELECTOR = re.compile(
    r"(?:(?:cmuxTests|cmuxUITests)/)?"
    r"[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?)?"
)


def positive_integer(value: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise argparse.ArgumentTypeError("must be a positive integer")
    return int(value)


def output(*command: str, timeout: float | None = None) -> str:
    try:
        return subprocess.check_output(
            command, cwd=ROOT, text=True, timeout=timeout
        ).strip()
    except subprocess.TimeoutExpired as error:
        raise ValueError("GitHub command timed out during focused-run discovery") from error


def wait_for_retry(cancel_event: threading.Event, delay_seconds: float) -> bool:
    """Wait for the next discovery attempt, allowing cancellation to interrupt it."""
    return cancel_event.wait(delay_seconds)


@contextmanager
def cancellation_scope():
    """Turn termination signals into a cancellable run-discovery wait."""
    cancel_event = threading.Event()
    previous = {}

    def cancel(_signum, _frame):
        cancel_event.set()

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, cancel)
        yield cancel_event
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def find_run(
    commit: str,
    selector: str,
    dispatch_id: str,
    *,
    cancel_event: threading.Event | None = None,
) -> dict:
    """Correlate this dispatch, never assume the newest run belongs to us."""
    cancel_event = cancel_event or threading.Event()
    suffix = f" @ {commit} [{dispatch_id}]"
    deadline = time.monotonic() + RUN_DISCOVERY_TIMEOUT_SECONDS
    for attempt in range(RUN_DISCOVERY_ATTEMPTS):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        runs = json.loads(output(
            "gh", "run", "list", "--repo", REPO, "--workflow", WORKFLOW,
            "--event", "workflow_dispatch", "--limit", "100",
            "--json", "databaseId,displayTitle,url",
            timeout=remaining,
        ))
        if cancel_event.is_set():
            raise ValueError("focused-run discovery cancelled")
        matches = [
            run for run in runs
            if run["displayTitle"].startswith(f"{selector} on ")
            and run["displayTitle"].endswith(suffix)
        ]
        if len(matches) == 1:
            return matches[0]
        if matches:
            raise ValueError("multiple runs matched this dispatch; refusing to guess")
        remaining = deadline - time.monotonic()
        if attempt + 1 >= RUN_DISCOVERY_ATTEMPTS or remaining <= 0:
            break
        # Back off while the Actions API registers the run. The monotonic
        # deadline bounds the total wait, and Event.wait lets cancellation
        # interrupt the delay instead of trapping the caller in a fixed sleep.
        delay = min(2 ** min(attempt, 3), 8, remaining)
        if wait_for_retry(cancel_event, delay):
            raise ValueError("focused-run discovery cancelled")
    raise ValueError(
        f"dispatch accepted but its run was not found; request {dispatch_id}. "
        f"Check https://github.com/{REPO}/actions/workflows/{WORKFLOW} "
        "before dispatching again."
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run one suite or method on an exact pushed commit. "
        "This focused result does not replace the full CI merge checks.",
        epilog="Examples: scripts/run-e2e.sh cmuxTests/RemoteTmuxMirrorPaneInputMappingTests --wait; "
        "scripts/run-e2e.sh UpdatePillUITests/testFoo --ref my-branch --no-video",
    )
    parser.add_argument("test_filter", help="cmuxTests/Suite[/method] or cmuxUITests/Class[/method]; bare names target UI tests")
    parser.add_argument("--ref", help="remote branch, tag, or SHA; default: clean local HEAD, already pushed")
    parser.add_argument("--wait", action="store_true", help="wait and return a nonzero status if the run fails")
    parser.add_argument("--no-video", action="store_true")
    parser.add_argument("--timeout", type=positive_integer, default=120, help="per-test timeout in seconds (default: 120)")
    parser.add_argument("--job-timeout", type=positive_integer, default=45, help="job timeout in minutes, including compilation (default: 45)")
    parser.add_argument("--workflow-ref", help="workflow-definition branch/tag (default: repository default branch)")
    args = parser.parse_args()
    if not SELECTOR.fullmatch(args.test_filter):
        parser.error("test_filter must name one suite or method, optionally prefixed with cmuxTests/ or cmuxUITests/")
    if args.ref is not None and not args.ref.strip():
        parser.error("--ref must not be empty")
    if args.workflow_ref is not None and not args.workflow_ref.strip():
        parser.error("--workflow-ref must not be empty")

    requested_ref = args.ref
    if requested_ref is None:
        if output("git", "status", "--porcelain", "--untracked-files=normal"):
            raise ValueError("commit and push local changes first, or use --ref to explicitly test a remote revision")
        requested_ref = output("git", "rev-parse", "HEAD")
    # Resolve once before spending a runner. A subsequent branch push cannot
    # change which source revision checkout receives.
    commit = json.loads(output(
        "gh", "api", f"repos/{REPO}/commits/{quote(requested_ref, safe='')}",
    ))["sha"]
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("GitHub did not resolve the requested revision to a full commit SHA")
    if args.ref is None and commit != requested_ref:
        raise ValueError("GitHub revision differs from local HEAD; push the intended commit first")

    dispatch_id = uuid.uuid4().hex
    video = not args.no_video and not args.test_filter.startswith("cmuxTests/")
    fields = {
        "ref": commit,
        "test_filter": args.test_filter,
        "record_video": str(video).lower(),
        "test_timeout": str(args.timeout),
        "job_timeout": str(args.job_timeout),
        "dispatch_id": dispatch_id,
    }
    command = ["gh", "workflow", "run", WORKFLOW, "--repo", REPO]
    if args.workflow_ref:
        command.extend(["--ref", args.workflow_ref])
    for key, value in fields.items():
        command.extend(["-f", f"{key}={value}"])
    print(f"Testing {args.test_filter} at {commit} (request {dispatch_id})", flush=True)
    subprocess.run(command, cwd=ROOT, check=True)
    with cancellation_scope() as cancel_event:
        run = find_run(
            commit, args.test_filter, dispatch_id, cancel_event=cancel_event
        )
    print(f"Run: {run['url']}", flush=True)
    if args.wait:
        return subprocess.run([
            "gh", "run", "watch", "--repo", REPO, str(run["databaseId"]),
            "--exit-status",
        ], cwd=ROOT).returncode
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
