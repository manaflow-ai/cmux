#!/usr/bin/env python3
"""Dispatch the existing E2E workflow for an exact revision and selected test."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from typing import Callable
from urllib.parse import quote
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import app_host_test_rerun as rerun  # noqa: E402
import e2e_runner_pool as pool  # noqa: E402
from e2e_runner_pool import SMALL_RUNNER  # noqa: E402

REPO = "manaflow-ai/cmux"
WORKFLOW = "test-e2e.yml"
# Runs cmuxTests against app-host products a CI run already compiled; see
# reuse_ci_products().
RERUN_WORKFLOW = "app-host-test-rerun.yml"
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
PRODUCTS_WAIT_SECONDS = 50 * 60
PRODUCTS_POLL_SECONDS = 60.0
# The branch `gh workflow run` takes the workflow definition from when no
# --workflow-ref is given: the repository default branch.
DEFAULT_WORKFLOW_REF = "main"
# `vars.MACOS_RUNNER_TESTS`, as passed by a workflow job; see default_runner().
VARIABLE_ENV = "CMUX_MACOS_RUNNER_TESTS"
# The pool-choice variables, passed the same way; see repository_variable().
OVERFLOW_ENV = "CMUX_" + pool.OVERFLOW_VARIABLE
ORDER_ENV = "CMUX_" + pool.ORDER_VARIABLE
MAX_QUEUED_ENV = "CMUX_" + pool.MAX_QUEUED_VARIABLE
QUEUE_ROUNDS_ENV = "CMUX_" + pool.QUEUE_ROUNDS_VARIABLE
OWNED_ENV = "CMUX_" + pool.OWNED_VARIABLE
SLOTS_ENV = "CMUX_" + pool.SLOTS_VARIABLE
PR_XCODE_ENV = "CMUX_" + pool.PR_XCODE_VARIABLE
OWNED_UI_ENV = "CMUX_" + pool.OWNED_UI_VARIABLE
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
    "glaeda-std-xcode-26.6",
)
# An unpinned run takes whichever macOS 26 pool pull request CI would, by
# preference and queue depth. The rule lives in e2e_runner_pool.py, which
# test-e2e.yml runs too. Because the choice depends on the queue at dispatch
# time, not on the commit, the in-flight guards below look on both pools.
OVERFLOW_POOLS = pool.E2E_POOLS + tuple(
    label for label in RUNNERS if pool.pr_runner_pool.persistent(label))
# GitHub rejects a concurrency group longer than this as a workflow file
# issue: the run is created with no jobs and no message saying why.
MAX_CONCURRENCY_GROUP = 400

SELECTOR = re.compile(
    r"(?:(?:cmuxTests|cmuxUITests)/)?"
    r"[A-Za-z_][A-Za-z0-9_]*(?:/[A-Za-z_][A-Za-z0-9_]*"
    # Swift Testing names a method with its call suffix, and a parameterized
    # one with its argument labels: method(), method(label:), method(_:_:).
    r"(?:\((?:[A-Za-z_][A-Za-z0-9_]*:)*\))?)?"
)


def _load_selectors():
    spec = importlib.util.spec_from_file_location(
        "focused_test_selectors", Path(__file__).resolve().parent / "focused_test_selectors.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


selectors = _load_selectors()


def normalize_entry(entry: str, root: Path = ROOT) -> tuple[str, str | None]:
    """Give a cmuxTests method selector the call suffix its declaration needs.

    `Suite/method` matches no Swift Testing test: xcodebuild runs nothing and
    reports success. The workflow resolves selectors against the built test
    inventory before running and fails a selector that executed nothing, but
    both happen after a full compile. Reading the suite's source here catches
    the common case before spending one.

    Only a declaration found in the local checkout changes the entry. A name
    this checkout does not declare passes through unchanged, because --ref may
    name a revision where it exists; the workflow remains the authority.
    """
    if not entry.startswith("cmuxTests/"):
        return entry, None
    parts = entry.split("/")
    if len(parts) != 3:
        return entry, None
    declared = selectors.source_inventory(root, parts[1])
    if not declared:
        return entry, None
    try:
        return selectors.resolve_selector(declared, entry)
    except selectors.UnknownSelector:
        return entry, (
            f"{entry} is not declared in this checkout's {parts[1]}; dispatching "
            "it unchanged. The workflow fails it if it matches no built test."
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


def recent_dispatches(workflow_ref: str) -> list[dict]:
    """Recent dispatches of this workflow from the definition on `workflow_ref`,
    or nothing when history is unreadable.

    Filtering on the server keeps the page to this definition's runs, so
    dispatches from other refs cannot push them past the listing limit.

    One listing answers every pre-dispatch question, for every selector in a
    batch. Asking per selector repeated the same request once per entry and
    spent shared GitHub API budget to receive the same page back.
    """
    try:
        payload = output(
            "gh", "run", "list", "--repo", REPO, "--workflow", WORKFLOW,
            "--event", "workflow_dispatch", "--branch", workflow_ref,
            "--limit", str(PRIOR_ATTEMPT_LIMIT),
            "--json", "databaseId,displayTitle,conclusion,status,url,headBranch",
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


_UNLISTED = object()
_listed: object = _UNLISTED


def listed_variables() -> dict[str, str] | None:
    """Repository variables by name, read once, or None when unreadable."""
    global _listed
    if _listed is _UNLISTED:
        try:
            payload = output(
                "gh", "variable", "list", "--repo", REPO, "--json", "name,value",
                timeout=PRIOR_ATTEMPT_TIMEOUT_SECONDS,
            )
            variables = json.loads(payload)
        except (subprocess.SubprocessError, OSError, ValueError, json.JSONDecodeError):
            variables = None
        if isinstance(variables, list):
            _listed = {
                str(entry["name"]): str(entry.get("value", ""))
                for entry in variables
                if isinstance(entry, dict) and "name" in entry
            }
        else:
            _listed = None
    return _listed  # type: ignore[return-value]


def repository_variable(name: str, env_name: str) -> str | None:
    """An overflow variable's value; None or empty means unset (the default).

    A workflow job cannot list variables and passes them in CMUX_* instead.
    A job that passed MACOS_RUNNER_TESTS but not this one predates it, so it
    gets the default. Elsewhere an unreadable listing also means the default:
    overflow is still bounded by the queue it reads, and fails to 6vcpu.
    """
    if env_name in os.environ:
        return os.environ[env_name]
    if VARIABLE_ENV in os.environ:
        return None
    return (listed_variables() or {}).get(name)


class GhApi(pool.pr_runner_pool.GitHub):
    """Pull request CI's pool-queue client, speaking through `gh api`.

    `gh` carries the caller's own credentials, locally or in a workflow job,
    so this needs no token handling of its own.
    """

    def __init__(self) -> None:
        super().__init__("", REPO)

    def get(self, path: str):
        endpoint = f"repos/{REPO}{path}"
        try:
            payload = output(
                "gh", "api", "--method", "GET", endpoint,
                timeout=PRIOR_ATTEMPT_TIMEOUT_SECONDS,
            )
            return json.loads(payload) if payload else {}
        except (subprocess.SubprocessError, OSError, ValueError) as error:
            raise RuntimeError(f"GET {path.split('?')[0]} failed") from error

    def download(self, artifact) -> bytes:
        # `gh api` follows the redirect to blob storage without the token.
        endpoint = f"repos/{REPO}/actions/artifacts/{int(artifact['id'])}/zip"
        try:
            return subprocess.check_output(
                ("gh", "api", "--method", "GET", endpoint),
                cwd=ROOT, timeout=PRIOR_ATTEMPT_TIMEOUT_SECONDS,
            )
        except (subprocess.SubprocessError, OSError, KeyError, TypeError, ValueError) as error:
            raise RuntimeError("GET /actions/artifacts/{id}/zip failed") from error


def default_runner() -> str | None:
    """The label `runner: auto` resolves to, or None when it cannot be known.

    The workflow reads `vars.MACOS_RUNNER_TESTS` and falls back to a literal
    written beside it, so the answer lives half in the repository's variables
    and half in the workflow definition. Read both rather than hard-coding
    either: the literal moves when the default pool moves, and the variable
    overrides it without touching the workflow.

    Returning None means "cannot tell", and every caller treats that as a
    reason to dispatch normally rather than to act on a runner it guessed.

    A workflow job's token cannot list variables, so a job that calls this
    passes `vars.MACOS_RUNNER_TESTS` in CMUX_MACOS_RUNNER_TESTS instead. Set
    and empty means the variable is unset, and the literal decides.
    """
    if VARIABLE_ENV in os.environ:
        value = os.environ[VARIABLE_ENV].strip()
        if value:
            return value
    else:
        variables = listed_variables()
        if variables is None:
            return None
        value = variables.get("MACOS_RUNNER_TESTS", "").strip()
        if value:
            return value
    try:
        workflow = (ROOT / ".github/workflows" / WORKFLOW).read_text()
    except OSError:
        return None
    literal = re.search(
        r"vars\.MACOS_RUNNER_TESTS \|\| '([^']+)'", workflow
    )
    return literal.group(1) if literal else None


def routed_runner(default: str | None, test_target: str | None = None) -> str | None:
    """The pool an unpinned dispatch runs on now; see e2e_runner_pool.

    Only called when a dispatch is about to happen, so a run reused from the
    history spends no API calls on the queue.
    """
    now = dt.datetime.now(dt.timezone.utc)
    return pool.auto_runner(
        default,
        enabled=pool.enabled(
            repository_variable(pool.OVERFLOW_VARIABLE, OVERFLOW_ENV)),
        limits=pool.settings(
            repository_variable(pool.ORDER_VARIABLE, ORDER_ENV),
            repository_variable(pool.MAX_QUEUED_VARIABLE, MAX_QUEUED_ENV),
            repository_variable(pool.OWNED_VARIABLE, OWNED_ENV)
            if test_target in (None, "cmuxTests")
            or (repository_variable(pool.OWNED_UI_VARIABLE, OWNED_UI_ENV) or "").strip() == "1" else "",
            repository_variable(pool.PR_XCODE_VARIABLE, PR_XCODE_ENV),
            # Unset is pull request CI's default rounds, as test-e2e.yml passes it.
            repository_variable(pool.QUEUE_ROUNDS_VARIABLE, QUEUE_ROUNDS_ENV) or "",
        ),
        measure=lambda: pool.measure_load(GhApi(), now=now),
        now=now,
        log=lambda message: print(f"Runner pool: {message}", file=sys.stderr, flush=True),
        owned_slots=pool.pr_runner_pool.slots(repository_variable(pool.SLOTS_VARIABLE, SLOTS_ENV),
                                              repository_variable(pool.PR_XCODE_VARIABLE, PR_XCODE_ENV)),
    )


def candidate_runners(runner: str | None, pinned: bool) -> tuple[str, ...]:
    """Every pool a dispatch with this runner could land on.

    A pinned runner is exact. An unpinned dispatch on the 6vcpu default may
    overflow to the 12vcpu pool or an owned Mac, so a run on any of them
    already answers it.
    Empty means the default could not be established.
    """
    if runner is None:
        return ()
    if not pinned and runner == SMALL_RUNNER:
        return OVERFLOW_POOLS
    return (runner,)


def attempts(
    runs: list[dict], commit: str, selector: str,
    runner: str | tuple[str, ...] | None = None,
) -> list[dict]:
    """Runs of this selector at this exact commit, newest first.

    `runner` narrows to one pool, or to any of several. None means every
    pool, which is what the repeat guard wants: a red result is usually a
    property of the commit.
    """
    runners = (runner,) if isinstance(runner, str) else runner
    found = []
    for run in runs:
        parsed = parse_run_name(str(run.get("displayTitle", "")))
        if parsed is None:
            continue
        selectors, run_runner, ref = parsed
        if ref != commit or selector not in selectors:
            continue
        if runners is not None and run_runner not in runners:
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
    runs: list[dict], commit: str, selector: str, runner: str | tuple[str, ...]
) -> list[dict]:
    """Attempts GitHub has accepted that have not reported a conclusion yet.

    Dispatching over one of these is worse than wasteful. The workflow's
    concurrency group is keyed on runner, ref and the whole test_filter string
    with `cancel-in-progress: true`, so an identical dispatch cancels the run
    already compiling and starts that compile again from cold. A dispatch that
    only overlaps -- a different batch naming one of the same selectors -- does
    not collide, and instead pays a second full compile of identical source to
    answer a question already in flight.

    `runner` is required and exact: one pool, or the pools an unpinned
    dispatch could overflow between. A run on another pool shares neither the
    concurrency group nor the question: reusing its result would report macOS
    15's answer to someone who asked about macOS 26.
    """
    return [
        run for run in attempts(runs, commit, selector, runner)
        if str(run.get("status", "")) in UNFINISHED
    ]


def parsed_runner(run: dict) -> str:
    parsed = parse_run_name(str(run.get("displayTitle", "")))
    return parsed[1] if parsed else "an unknown runner"


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
    workflow: str = WORKFLOW,
) -> dict:
    """Correlate this dispatch, never assume the newest run belongs to us."""
    cancel_event = cancel_event or threading.Event()
    suffix = f" @ {commit} [{dispatch_id}]"
    if workflow == WORKFLOW:
        def ours(title: str) -> bool:
            return title.startswith(f"{selector} on ") and title.endswith(suffix)
    else:
        def ours(title: str) -> bool:
            return title.endswith(f" [{dispatch_id}]")
    deadline = time.monotonic() + RUN_DISCOVERY_TIMEOUT_SECONDS
    for attempt in range(RUN_DISCOVERY_ATTEMPTS):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        runs = json.loads(output(
            "gh", "run", "list", "--repo", REPO, "--workflow", workflow,
            "--event", "workflow_dispatch", "--limit", "100",
            "--json", "databaseId,displayTitle,url",
            timeout=remaining,
            cancel_event=cancel_event,
        ))
        if cancel_event.is_set():
            raise ValueError("focused-run discovery cancelled")
        matches = [run for run in runs if ours(run["displayTitle"])]
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
        f"Check https://github.com/{REPO}/actions/workflows/{workflow} "
        "before dispatching again."
    )


@contextmanager
def chdir(path: Path):
    """contextlib.chdir, which needs Python 3.11; run-e2e.sh may get macOS's 3.9."""
    previous = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


def planned_products(commit: str, only_testing: str, source_run_id: str = "") -> dict | None:
    """app_host_test_rerun.py's plan for this commit, or None when it finds no products."""
    args = argparse.Namespace(
        ref=commit, repository=REPO, only_testing=only_testing,
        source_run_id=source_run_id, max_commits=200,
    )
    try:
        with chdir(ROOT):
            return rerun.plan(args)
    except SystemExit as error:
        print(f"note: no reusable CI products: {str(error).splitlines()[0]}", file=sys.stderr, flush=True)
    except (KeyError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError):
        pass
    return None


def building_producer(commit: str) -> dict | None:
    """A CI run of this commit still compiling products the commit can use.

    A pull_request run builds the merge with its base, so it qualifies only
    while that merge differs from the commit under cmuxTests/ alone. Main's
    ci.yml runs are dispatched by ci-main-full-suite.yml. The
    guards in main() already refuse a second test-e2e.yml compile of a commit.
    """
    try:
        listing = rerun.gh_api(f"repos/{REPO}/actions/runs?head_sha={commit}&per_page=50")
        runs = sorted(listing.get("workflow_runs", []), key=lambda run: run.get("created_at", ""), reverse=True)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        runs = []
    for run in runs:
        if (run.get("path") != CI_WORKFLOW_PATH or run.get("status") not in UNFINISHED
                or run.get("event") not in ("push", "pull_request", "workflow_dispatch")):
            continue
        try:
            with chdir(ROOT):
                if rerun.non_test_changes(rerun.built_revision(run), commit):
                    continue
        except (KeyError, ValueError, subprocess.CalledProcessError):
            continue
        return {"id": run["id"], "url": run.get("html_url", "")}
    return None


def skips_macos(run_id: int) -> bool:
    """Whether a CI run decided not to compile for macOS, so it will leave no products."""
    listing = rerun.gh_api(f"repos/{REPO}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    return any(
        job.get("name", "").endswith(rerun.ADMISSION_JOB) and job.get("conclusion") == "skipped"
        for job in listing.get("jobs", [])
    )


def wait_for_products(producer: dict, still_wanted: Callable[[], bool] = lambda: True) -> bool:
    """Wait for a building CI run to upload its app-host products.

    True once they exist; False when the run ends without them, skips its
    macOS compile, has not produced them within PRODUCTS_WAIT_SECONDS, or
    `still_wanted` says the products it will make cannot be used.
    """
    print(
        f"{producer['url']} is already compiling this revision; waiting for its app-host "
        "products instead of compiling them a second time.",
        flush=True,
    )
    deadline = time.monotonic() + PRODUCTS_WAIT_SECONDS
    with cancellation_scope() as cancel_event:
        while True:
            if rerun.products_artifact(REPO, str(producer["id"]), rerun.gh_api):
                return True
            state = rerun.gh_api(f"repos/{REPO}/actions/runs/{producer['id']}")
            if state.get("status") not in UNFINISHED:
                print(f"note: {producer['url']} finished without app-host products", file=sys.stderr, flush=True)
                return False
            if skips_macos(producer["id"]):
                print(f"note: {producer['url']} skipped its macOS compile", file=sys.stderr, flush=True)
                return False
            if not still_wanted():
                print(f"note: {producer['url']} compiles products this run cannot use", file=sys.stderr, flush=True)
                return False
            if time.monotonic() > deadline:
                print(f"note: {producer['url']} has not produced app-host products yet", file=sys.stderr, flush=True)
                return False
            if wait_for_retry(cancel_event, PRODUCTS_POLL_SECONDS):
                raise ValueError("waiting for CI products cancelled")


def awaited_products(producer: dict, commit: str, only_testing: str) -> dict | None:
    """Wait for a building run's products, then plan against them."""
    if not wait_for_products(producer):
        return None
    return planned_products(commit, only_testing, str(producer["id"]))


def ui_product_source(commit: str) -> dict | None:
    """The CI run whose app-host products a UI run of this commit can adopt.

    Compile admission builds the `cmux` scheme for testing, so its product
    already holds cmuxUITests-Runner.app and the UI xctestrun next to the app.
    test-e2e.yml adopts it whenever the tested tree has the same product
    inputs. A pull request run compiles `refs/pull/N/merge`, never the head, so
    a UI dispatch of the head missed it and compiled the whole app again
    (75 UI runs on 2026-09-25: 32 had such a product, 36 a CI run cancelled
    before one). Testing that merge instead is what pull request CI tests.

    Returns {"revision", "id", "url", "ready"}: the revision to dispatch, which
    is the merge for a pull request run, and whether its products exist yet.
    None when no in-repository CI run of this commit has or will have them.
    Only a macOS 26 product is taken, the pools an unpinned E2E run lands on.
    """
    try:
        listing = rerun.gh_api(f"repos/{REPO}/actions/runs?head_sha={commit}&per_page=50")
        runs = sorted(listing.get("workflow_runs", []), key=lambda run: run.get("created_at", ""), reverse=True)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None
    pending = None
    for run in runs:
        # Only a pull request run: test-e2e.yml trusts no other ci.yml
        # product (reuse_app_host_products.TRUSTED_WORKFLOWS). Main's ci.yml
        # runs are dispatches, and main's own product comes from
        # seed-derived-data.yml, which test-e2e.yml finds by itself.
        if (run.get("path") != CI_WORKFLOW_PATH or run.get("event") != "pull_request"
                or not run.get("id")
                or str((run.get("head_repository") or {}).get("full_name", "")).casefold() != REPO.casefold()):
            continue
        try:
            with chdir(ROOT):
                built = rerun.built_revision(run)
        except (KeyError, ValueError, subprocess.CalledProcessError):
            continue
        source = {"revision": built, "id": run["id"], "url": run.get("html_url", ""), "ready": False}
        try:
            if rerun.products_artifact(REPO, str(run["id"]), rerun.gh_api):
                if usable_product(source):
                    return {**source, "ready": True}
                continue
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            continue
        if pending is None and run.get("status") in UNFINISHED:
            pending = source
    return pending


# A product's contract hashes the exact toolchain (Xcode build, SDK, rustc,
# node, go...), which the owned Macs and the Blacksmith macOS 26 image do not
# share, so a product only ever moves within one of these families: on
# 2026-09-25 every adoption of a ci.yml product went Blacksmith to Blacksmith
# (either size) or owned Mac to owned Mac, and a 12vcpu dispatch of an owned
# Mac's product missed (run 36209020703). The UI run is pinned to the family.
FAMILY_RUNNERS = {"owned": "glaeda-std-xcode-26.6", "blacksmith": "blacksmith-6vcpu-macos-26"}


def product_family(source: dict) -> str | None:
    """"owned" or "blacksmith" for where a CI run's compile admission ran on
    macOS 26; "" before it has a runner; None for anything else (macOS 15)."""
    listing = rerun.gh_api(f"repos/{REPO}/actions/runs/{source['id']}/jobs?filter=latest&per_page=100")
    for job in listing.get("jobs", []):
        if not job.get("name", "").endswith(rerun.ADMISSION_JOB):
            continue
        labels = job.get("labels") or []
        if any(re.fullmatch(r"glaeda-(?:root-)?(?:xl|std|light)-xcode-[0-9.]+", label) for label in labels):
            return "owned"
        if any(re.fullmatch(r"blacksmith-[0-9]+vcpu-macos-26", label) for label in labels):
            return "blacksmith"
        return None if labels else ""
    return ""


def usable_product(source: dict, pending: bool = False) -> bool:
    """Whether a CI run compiles its products where a UI run can be sent to
    load them, recording the family in `source`. With `pending`, a run whose
    compile admission has no runner yet may still qualify."""
    try:
        family = product_family(source)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return pending
    if family:
        source["family"] = family
        return True
    return pending and family == ""


def reuse_ci_products(commit: str, entries: list[str], workflow_ref: str | None, wait: bool) -> int | None:
    """Run cmuxTests selectors against app-host products CI compiled, if any.

    A test-e2e.yml run compiles the whole app, 12 to 27 minutes, to run a few
    minutes of tests. When CI already compiled this commit's app, or is
    compiling it now, app-host-test-rerun.yml recompiles only cmuxTests
    against those products. Returns the exit status, or None to fall back to
    a full build.
    """
    try:
        only_testing = " ".join(rerun.parse_selectors(" ".join(entries)))
    except ValueError:
        return None
    try:
        with chdir(ROOT):
            rerun.fetch_commit(commit)
    except subprocess.CalledProcessError:
        return None
    try:
        found = planned_products(commit, only_testing)
        if found is None:
            producer = building_producer(commit)
            if producer is None:
                return None
            found = awaited_products(producer, commit, only_testing)
    except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError):
        return None
    if found is None:
        return None
    dispatch_id = uuid.uuid4().hex
    command = ["gh", "workflow", "run", RERUN_WORKFLOW, "--repo", REPO]
    if workflow_ref:
        command.extend(["--ref", workflow_ref])
    for key, value in {
        "ref": commit,
        "only_testing": only_testing,
        "source_run_id": found["source_run_id"],
        "dispatch_id": dispatch_id,
    }.items():
        command.extend(["-f", f"{key}={value}"])
    print(
        f"Testing {only_testing} at {commit} against the products run {found['source_run_id']} "
        f"compiled from {found['source_sha']}; only cmuxTests recompiles (request {dispatch_id})",
        flush=True,
    )
    try:
        subprocess.run(command, cwd=ROOT, check=True)
    except subprocess.CalledProcessError:
        # A --workflow-ref whose rerun workflow predates dispatch_id rejects it.
        print("note: the rerun dispatch was refused; compiling in full instead", file=sys.stderr, flush=True)
        return None
    with cancellation_scope() as cancel_event:
        run = find_run(commit, only_testing, dispatch_id, cancel_event=cancel_event, workflow=RERUN_WORKFLOW)
    print(f"Run: {run['url']}", flush=True)
    if wait:
        return watch_run(run["databaseId"])
    return 0


def watch_run(run_id: int) -> int:
    """Wait for a run's verdict: 0 success, nonzero otherwise.

    Every agent shares one GitHub account and its API quota, and parallel
    `gh run watch` loops (3 s default) emptied it on 2026-09-25. glaeda-gh, where
    installed, answers from one shared poller at no per-waiter cost; its 0 and 1
    are the verdict, anything else (timeout, daemon down) falls back to polling
    at a 300 s interval.
    """
    glaeda = shutil.which("glaeda-gh")
    if glaeda:
        code = subprocess.run([glaeda, "wait", "run", f"{REPO}/{run_id}", "--timeout", "14400"], cwd=ROOT).returncode
        if code in (0, 1, 130):  # a verdict, or an interrupt: never fall back to polling then
            return code
    return subprocess.run([
        "gh", "run", "watch", "--repo", REPO, str(run_id), "--exit-status", "--interval", "300",
    ], cwd=ROOT).returncode


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
        "A Swift Testing method takes its call suffix, Suite/method() or Suite/method(label:); "
        "one this checkout declares gets it added. "
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
        "--full-build",
        action="store_true",
        help="compile the whole app even when CI already compiled this commit's app-host products; "
        "without it, a run waits (up to 50 min) for a CI run still compiling this commit, and a UI "
        "run of a pull request head tests the merge its CI compiled",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="dispatch even if this selector already failed at this commit, "
        "or is already running there",
    )
    args = parser.parse_args()
    for entry in args.test_filter:
        if not SELECTOR.fullmatch(entry):
            parser.error(
                "test_filter must name one suite or method, optionally prefixed "
                "with cmuxTests/ or cmuxUITests/; a Swift Testing method takes "
                "its call suffix, Suite/method() or Suite/method(label:)"
            )
    normalized = []
    for entry in args.test_filter:
        try:
            value, note = normalize_entry(entry)
        except selectors.AmbiguousSelector as error:
            parser.error(str(error))
        if note:
            print(f"note: {note}", file=sys.stderr, flush=True)
        normalized.append(value)
    args.test_filter = normalized
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

    # A UI run adopts the app-host product a CI run of this commit compiled,
    # UI test bundle included; see ui_product_source(). For a pull request
    # that means dispatching the merge CI built, so every guard below reads
    # the revision actually dispatched.
    head = commit
    ui_source = None
    if test_target == "cmuxUITests" and args.runner in (None, "auto") and not args.full_build:
        ui_source = ui_product_source(commit)
        if ui_source is not None:
            commit = ui_source["revision"]
            if commit != head:
                print(
                    f"Testing {commit}, the merge of {head} into its base that {ui_source['url']} "
                    "compiled, so this run adopts CI's app and UI test bundle instead of compiling "
                    "them. Pass --full-build to test the head itself.",
                    flush=True,
                )

    def guards(commit: str) -> int | None:
        """Refuse or attach before dispatching `commit`; a status means return it."""
        nonlocal pinned, default, pools
        # Which pools this dispatch could land on. Empty means the answer could
        # not be established, and the in-flight guards below stay silent rather
        # than compare against a runner they guessed. The queue is read only once
        # the guards have decided to dispatch.
        pinned = args.runner not in (None, "auto")
        default = args.runner if pinned else default_runner()
        pools = candidate_runners(default, pinned)
        # test-e2e.yml groups on "e2e-<runner>-<ref>-<test_filter>". When the pool
        # is unknown, measure against the longest label in the runner dropdown.
        label = max(pools or RUNNERS, key=len)
        group_length = len(f"e2e-{label}-{commit}-{test_filter}")
        if group_length > MAX_CONCURRENCY_GROUP:
            parser.error(
                f"these selectors make a {group_length}-character concurrency group, over "
                f"GitHub's {MAX_CONCURRENCY_GROUP}; split them across dispatches or select the whole suite"
            )

        if not args.force:
            # A dispatch's headBranch is the branch its workflow definition came
            # from. A run of another definition answers a different question:
            # attaching to it, or refusing because it failed, would mean the
            # definition under --workflow-ref never runs. Every guard below reads
            # this filtered history.
            workflow_ref = args.workflow_ref or DEFAULT_WORKFLOW_REF
            history = [
                run for run in recent_dispatches(workflow_ref)
                if run.get("headBranch") == workflow_ref
            ]

            if pools:
                # An identical dispatch is already answering this exact question on
                # a pool this one could land on. Attach to it instead of cancelling
                # it or paying a second compile on the other macOS 26 pool: the
                # concurrency group keyed on runner/ref/test_filter would kill a
                # same-pool run mid-compile and start the compile again from cold.
                requested = set(args.test_filter)
                running = [
                    run for run in history
                    if str(run.get("status", "")) in UNFINISHED
                    and watchable(run)
                    and (parsed := parse_run_name(str(run.get("displayTitle", "")))) is not None
                    and parsed[2] == commit
                    and parsed[1] in pools
                    and set(parsed[0]) == requested
                ]
                if running:
                    live = running[0]
                    print(
                        f"{test_filter} is already {live['status']} at {commit} "
                        f"on {parsed_runner(live)}; reusing that run instead of dispatching.",
                        flush=True,
                    )
                    print(f"Run: {live['url']}", flush=True)
                    if args.wait:
                        return watch_run(live["databaseId"])
                    return 0

            # Refuse per entry: one already-red selector makes the whole batch a
            # reprint of a known failure, and the compile it would pay for is shared.
            for entry in args.test_filter:
                live = [run for run in live_attempts(history, commit, entry, pools)
                        if watchable(run)] if pools else []
                if live:
                    raise ValueError(
                        f"{entry} is already {live[0]['status']} at {commit} on "
                        f"{parsed_runner(live[0])}, in {live[0]['url']}, under a different set of "
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

        return None

    pinned = default = pools = None
    status = guards(commit)
    if status is not None:
        return status

    # A pinned runner asks about that pool; reused products run on the pool
    # that compiled them.
    if test_target == "cmuxTests" and not pinned and not args.full_build:
        status = reuse_ci_products(commit, args.test_filter, args.workflow_ref, args.wait)
        if status is not None:
            return status

    if ui_source is not None and not ui_source["ready"]:
        try:
            adopted = wait_for_products(ui_source, lambda: usable_product(ui_source, pending=True))
            adopted = adopted and usable_product(ui_source)
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            adopted = False
        if not adopted and commit != head:
            print(f"note: no CI products for {commit}; compiling {head} instead", file=sys.stderr, flush=True)
            commit = head
            # The guards above read the merge; the head needs its own.
            status = guards(commit)
            if status is not None:
                return status

    runner = args.runner if pinned else routed_runner(default, test_target)
    if ui_source is not None and ui_source.get("family") and commit == ui_source["revision"]:
        # Send the run where the product can be adopted; see FAMILY_RUNNERS.
        owned = bool(runner) and pool.pr_runner_pool.persistent(runner)
        if ui_source["family"] == "owned" and not owned:
            runner = FAMILY_RUNNERS["owned"]
        elif ui_source["family"] == "blacksmith" and (owned or not runner or "macos-26" not in runner):
            runner = FAMILY_RUNNERS["blacksmith"]
        print(f"Runner: {runner}, the pool family that compiled {commit}'s products", flush=True)
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
    # Name the pool chosen here, so the run title carries the pool the guards
    # above match on and test-e2e.yml does not read the queue a second time.
    if not pinned and runner in OVERFLOW_POOLS:
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
        return watch_run(run["databaseId"])
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
