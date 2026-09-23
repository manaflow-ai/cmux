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
PRIOR_ATTEMPT_LIMIT = 100
PRIOR_ATTEMPT_TIMEOUT_SECONDS = 30.0
RUNNERS = (
    "auto",
    "blacksmith-6vcpu-macos-15",
    "blacksmith-6vcpu-macos-26",
    "blacksmith-6vcpu-macos-latest",
    "tart-canary",
    "tart-dual",
    "tart-small",
)
SELECTOR = re.compile(
    r"(?:(?:cmuxTests|cmuxUITests)/)?"
    r"[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?)?"
)


def positive_integer(value: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise argparse.ArgumentTypeError("must be a positive integer")
    return int(value)


def output(
    *command: str,
    timeout: float | None = None,
    cancel_event: threading.Event | None = None,
) -> str:
    if cancel_event is None:
        try:
            return subprocess.check_output(
                command, cwd=ROOT, text=True, timeout=timeout
            ).strip()
        except subprocess.TimeoutExpired as error:
            raise ValueError("GitHub command timed out during focused-run discovery") from error

    process = subprocess.Popen(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
    )
    try:
        while True:
            if cancel_event.is_set():
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                raise ValueError("focused-run discovery cancelled")
            try:
                stdout, _ = process.communicate(
                    timeout=min(0.25, timeout) if timeout is not None else 0.25
                )
            except subprocess.TimeoutExpired:
                if timeout is not None:
                    timeout -= 0.25
                    if timeout <= 0:
                        process.kill()
                        process.wait()
                        raise ValueError(
                            "GitHub command timed out during focused-run discovery"
                        )
                continue
            if process.returncode:
                raise subprocess.CalledProcessError(
                    process.returncode, command, output=stdout
                )
            return stdout.strip()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if process.stdout is not None:
            process.stdout.close()


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


def prior_attempts(commit: str, selector: str, runner: str | None = None) -> list[dict]:
    """Completed runs of this selector/commit, scoped to an explicit runner.

    A focused run compiles the tree before it runs anything, so a red result is
    often a property of the commit and runner, not of the attempt. Preserve
    the existing broad guard for the default/auto runner, but a failure on
    macOS 15 must not block an explicitly requested macOS 26 verification.
    Re-dispatching the same selector/SHA/runner can reprint the same failure.
    The run name carries the dispatch identity --
    "<selector> on <runner> @ <commit> [<dispatch id>]" -- so earlier attempts
    are findable without recording any local state.
    """
    try:
        payload = output(
            "gh", "run", "list", "--repo", REPO, "--workflow", WORKFLOW,
            "--event", "workflow_dispatch", "--limit", str(PRIOR_ATTEMPT_LIMIT),
            "--json", "displayTitle,conclusion,status,url",
            timeout=PRIOR_ATTEMPT_TIMEOUT_SECONDS,
        )
    except (subprocess.SubprocessError, OSError, ValueError):
        # The guard is an economy measure, never a gate. If the history cannot
        # be read, dispatch as before.
        return []
    try:
        runs = json.loads(payload)
    except json.JSONDecodeError:
        return []
    marker = f" @ {commit} ["

    def ran_selector(title: str) -> bool:
        # A batched dispatch names several selectors before " on ", so match
        # membership rather than a prefix. Otherwise batching would silently
        # bypass this guard for every selector it carried.
        head, separator, remainder = title.partition(" on ")
        if not separator:
            return False
        if runner not in (None, "auto") and not remainder.startswith(f"{runner} @ "):
            return False
        return selector in [part.strip() for part in head.split(",")]

    return [
        run for run in runs
        if isinstance(run, dict)
        and ran_selector(str(run.get("displayTitle", "")))
        and marker in str(run.get("displayTitle", ""))
        and run.get("status") == "completed"
    ]


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
            cancel_event=cancel_event,
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
    parser.add_argument(
        "test_filter",
        nargs="+",
        help="cmuxTests/Suite[/method] or cmuxUITests/Class[/method]; bare names target UI tests. "
        "Pass several to run them against one compile; they must share a target.",
    )
    parser.add_argument("--ref", help="remote branch, tag, or SHA; default: clean local HEAD, already pushed")
    parser.add_argument("--wait", action="store_true", help="wait and return a nonzero status if the run fails")
    parser.add_argument("--no-video", action="store_true")
    parser.add_argument("--timeout", type=positive_integer, default=120, help="per-test timeout in seconds (default: 120)")
    parser.add_argument("--job-timeout", type=positive_integer, default=45, help="job timeout in minutes, including compilation (default: 45)")
    parser.add_argument("--workflow-ref", help="workflow-definition branch/tag (default: repository default branch)")
    parser.add_argument("--runner", choices=RUNNERS, help="runner override (default: workflow's configured runner)")
    parser.add_argument(
        "--force",
        action="store_true",
        help="dispatch even if this selector already failed at this commit",
    )
    args = parser.parse_args()
    for entry in args.test_filter:
        if not SELECTOR.fullmatch(entry):
            parser.error("test_filter must name one suite or method, optionally prefixed with cmuxTests/ or cmuxUITests/")
    if len(set(args.test_filter)) != len(args.test_filter):
        parser.error("test_filter entries must be unique")
    # One dispatch compiles once and runs one scheme, so a batch cannot span
    # both targets. Bare names keep targeting UI tests.
    targets = {"cmuxTests" if e.startswith("cmuxTests/") else "cmuxUITests" for e in args.test_filter}
    if len(targets) != 1:
        parser.error("test_filter entries must all target cmuxTests or all target cmuxUITests")
    test_target = targets.pop()
    test_filter = ",".join(args.test_filter)
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

    if not args.force:
        # Refuse per entry: one already-red selector makes the whole batch a
        # reprint of a known failure, and the compile it would pay for is shared.
        for entry in args.test_filter:
            earlier = prior_attempts(commit, entry, args.runner)
            failures = [run for run in earlier if run.get("conclusion") == "failure"]
            if failures and not any(run.get("conclusion") == "success" for run in earlier):
                latest = failures[0]
                raise ValueError(
                    f"{entry} already failed at {commit} "
                    f"({len(failures)} time(s)); the newest is {latest['url']}. "
                    "A focused run compiles the tree first, so the most common red "
                    "result is a compile error in the branch, not a flaky test -- "
                    "and re-running the same selector at the same commit returns the "
                    "same answer. Read that run, fix the branch, push, and dispatch "
                    "the new commit. Pass --force to dispatch anyway."
                )

    dispatch_id = uuid.uuid4().hex
    video = not args.no_video and test_target != "cmuxTests"
    fields = {
        "ref": commit,
        "test_filter": test_filter,
        "record_video": str(video).lower(),
        "test_timeout": str(args.timeout),
        "job_timeout": str(args.job_timeout),
        "dispatch_id": dispatch_id,
    }
    if args.runner is not None:
        fields["runner"] = args.runner
    command = ["gh", "workflow", "run", WORKFLOW, "--repo", REPO]
    if args.workflow_ref:
        command.extend(["--ref", args.workflow_ref])
    for key, value in fields.items():
        command.extend(["-f", f"{key}={value}"])
    print(f"Testing {test_filter} at {commit} (request {dispatch_id})", flush=True)
    subprocess.run(command, cwd=ROOT, check=True)
    with cancellation_scope() as cancel_event:
        run = find_run(
            commit, test_filter, dispatch_id, cancel_event=cancel_event
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
