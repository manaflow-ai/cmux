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
# Statuses GitHub reports before a run has a conclusion. Anything else,
# including a missing status, is not treated as occupying a runner.
UNFINISHED = frozenset({"queued", "in_progress", "waiting", "requested", "pending"})
RUNNERS = (
    "auto",
    "blacksmith-6vcpu-macos-15",
    "blacksmith-6vcpu-macos-26",
    "blacksmith-12vcpu-macos-26",
    "blacksmith-6vcpu-macos-latest",
)
# Half of all commits compile on the large macOS 26 SKU, so the two sizes are
# compared on real focused-run traffic rather than one benchmark. The split is
# keyed on the commit, not drawn at random: every dispatch at one commit lands
# on one pool, which is what in-flight reuse, the failed-selector refusal and
# the product contract all match on.
SMALL_RUNNER = "blacksmith-6vcpu-macos-26"
LARGE_RUNNER = "blacksmith-12vcpu-macos-26"
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


def recent_dispatches() -> list[dict]:
    """Recent dispatches of this workflow, or nothing when history is unreadable.

    One listing answers every pre-dispatch question, for every selector in a
    batch. Asking per selector repeated the same request once per entry and
    spent shared GitHub API budget to receive the same page back.
    """
    try:
        payload = output(
            "gh", "run", "list", "--repo", REPO, "--workflow", WORKFLOW,
            "--event", "workflow_dispatch", "--limit", str(PRIOR_ATTEMPT_LIMIT),
            "--json", "databaseId,displayTitle,conclusion,status,url",
            timeout=PRIOR_ATTEMPT_TIMEOUT_SECONDS,
        )
    except (subprocess.SubprocessError, OSError, ValueError):
        # These guards are economy measures, never gates. If the history
        # cannot be read, dispatch as before.
        return []
    try:
        runs = json.loads(payload)
    except json.JSONDecodeError:
        return []
    if not isinstance(runs, list):
        return []
    return [run for run in runs if isinstance(run, dict)]


def parse_run_name(title: str) -> tuple[list[str], str, str] | None:
    """Split "<selectors> on <runner> @ <ref> [<dispatch id>]" into its parts.

    The dispatch id is optional: a run started from the GitHub UI, or by any
    tool that does not pass one, still names its selectors, runner and ref.
    Requiring the trailing "[" hid exactly the runs whose compile these guards
    exist to protect, because a run with the same ref and filter shares this
    workflow's concurrency group whether or not a dispatcher labelled it.
    """
    head, separator, remainder = title.partition(" on ")
    if not separator:
        return None
    runner, separator, remainder = remainder.partition(" @ ")
    if not separator:
        return None
    ref = remainder.split(" [", 1)[0].strip()
    return [part.strip() for part in head.split(",")], runner.strip(), ref


def default_runner() -> str | None:
    """The label `runner: auto` resolves to, or None when it cannot be known.

    The workflow reads `vars.MACOS_RUNNER_TESTS` and falls back to a literal
    written beside it, so the answer lives half in the repository's variables
    and half in the workflow definition. Read both rather than hard-coding
    either: the literal moves when the default pool moves, and the variable
    overrides it without touching the workflow.

    Returning None means "cannot tell", and every caller treats that as a
    reason to dispatch normally rather than to act on a runner it guessed.
    """
    try:
        payload = output(
            "gh", "variable", "list", "--repo", REPO, "--json", "name,value",
            timeout=PRIOR_ATTEMPT_TIMEOUT_SECONDS,
        )
        variables = json.loads(payload)
    except (subprocess.SubprocessError, OSError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(variables, list):
        return None
    for entry in variables:
        if isinstance(entry, dict) and entry.get("name") == "MACOS_RUNNER_TESTS":
            value = str(entry.get("value", "")).strip()
            if value:
                return value
            break
    try:
        workflow = (ROOT / ".github/workflows" / WORKFLOW).read_text()
    except OSError:
        return None
    literal = re.search(
        r"vars\.MACOS_RUNNER_TESTS \|\| '([^']+)'", workflow
    )
    return literal.group(1) if literal else None


def routed_runner(commit: str, default: str | None) -> str | None:
    """The pool an unpinned dispatch at `commit` runs on.

    Only the free default is split. A repository variable naming any other
    pool is an admin decision, and it wins unchanged.
    """
    if default == SMALL_RUNNER and int(commit[-1], 16) % 2:
        return LARGE_RUNNER
    return default


def attempts(
    runs: list[dict], commit: str, selector: str, runner: str | None = None
) -> list[dict]:
    """Runs of this selector at this exact commit, newest first.

    `runner` narrows to one pool. None means every pool, which is what the
    repeat guard wants: a red result is usually a property of the commit.
    """
    found = []
    for run in runs:
        parsed = parse_run_name(str(run.get("displayTitle", "")))
        if parsed is None:
            continue
        selectors, run_runner, ref = parsed
        if ref != commit or selector not in selectors:
            continue
        if runner is not None and run_runner != runner:
            continue
        found.append(run)
    return found


def prior_attempts(
    runs: list[dict], commit: str, selector: str, runner: str | None = None
) -> list[dict]:
    """Completed attempts, whose conclusion is already knowable.

    A focused run compiles the tree before it runs anything, so a red result is
    often a property of the commit and runner, not of the attempt. Preserve
    the existing broad guard for the default/auto runner, but a failure on one
    macOS generation must not block a verification explicitly asked of another
    -- in either direction, since which generation `auto` means is a
    repository variable and has moved before.
    Re-dispatching the same selector/SHA/runner can reprint the same failure.
    """
    return [
        run for run in attempts(runs, commit, selector, runner)
        if run.get("status") == "completed"
    ]


def live_attempts(
    runs: list[dict], commit: str, selector: str, runner: str
) -> list[dict]:
    """Attempts GitHub has accepted that have not reported a conclusion yet.

    Dispatching over one of these is worse than wasteful. The workflow's
    concurrency group is keyed on runner, ref and the whole test_filter string
    with `cancel-in-progress: true`, so an identical dispatch cancels the run
    already compiling and starts that compile again from cold. A dispatch that
    only overlaps -- a different batch naming one of the same selectors -- does
    not collide, and instead pays a second full compile of identical source to
    answer a question already in flight.

    `runner` is required and exact. A run on another pool shares neither the
    concurrency group nor the question: reusing its result would report macOS
    15's answer to someone who asked about macOS 26.
    """
    return [
        run for run in attempts(runs, commit, selector, runner)
        if str(run.get("status", "")) in UNFINISHED
    ]


def watchable(run: dict) -> bool:
    """Whether this history entry carries enough to point a caller at the run.

    An entry without an id or a URL cannot be attached to or named, and these
    guards never become a gate: a caller that cannot be redirected is dispatched.
    """
    return (isinstance(run.get("databaseId"), int)
            and bool(str(run.get("url", "")).strip()))


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
        help="dispatch even if this selector already failed at this commit, "
        "or is already running there",
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

    # Which pool this dispatch will actually land on. None means the answer
    # could not be established, and the in-flight guards below stay silent
    # rather than compare against a runner they guessed.
    pinned = args.runner not in (None, "auto")
    runner = args.runner if pinned else routed_runner(commit, default_runner())

    if not args.force:
        history = recent_dispatches()

        if runner is not None:
            # An identical dispatch is already answering this exact question on
            # this exact pool. Attach to it instead of cancelling it: the
            # concurrency group keyed on runner/ref/test_filter would kill the
            # run mid-compile and start the same compile again from cold.
            requested = set(args.test_filter)
            running = [
                run for run in history
                if str(run.get("status", "")) in UNFINISHED
                and watchable(run)
                and (parsed := parse_run_name(str(run.get("displayTitle", "")))) is not None
                and parsed[2] == commit
                and parsed[1] == runner
                and set(parsed[0]) == requested
            ]
            if running:
                live = running[0]
                print(
                    f"{test_filter} is already {live['status']} at {commit} "
                    f"on {runner}; reusing that run instead of dispatching.",
                    flush=True,
                )
                print(f"Run: {live['url']}", flush=True)
                if args.wait:
                    return subprocess.run([
                        "gh", "run", "watch", "--repo", REPO, str(live["databaseId"]),
                        "--exit-status",
                    ], cwd=ROOT).returncode
                return 0

        # Refuse per entry: one already-red selector makes the whole batch a
        # reprint of a known failure, and the compile it would pay for is shared.
        for entry in args.test_filter:
            live = [run for run in live_attempts(history, commit, entry, runner)
                    if watchable(run)] if runner is not None else []
            if live:
                raise ValueError(
                    f"{entry} is already {live[0]['status']} at {commit} on "
                    f"{runner}, in {live[0]['url']}, under a different set of "
                    "selectors. Dispatching now would compile identical source "
                    "a second time to answer a question already in flight. Wait "
                    "for that run, dispatch the remaining selectors on their "
                    "own, or pass --force."
                )
            earlier = prior_attempts(
                history, commit, entry,
                args.runner if args.runner not in (None, "auto") else None,
            )
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
    if not pinned and runner == LARGE_RUNNER:
        fields["runner"] = runner
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
