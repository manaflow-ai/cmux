"""The delivery workflows: nightly, DEV and promote builds of classic and NEXT.

One declared list. tests/test_nightly_delivery_concurrency.py reads it to
forbid cancel-in-progress and evicting groups in these files, and
scripts/ci/queue_janitor.py reads it to never cancel one of their runs as an
orphan. Standing rule: "Never cancel a nightly, dev or promote build or its
Release compile once it has started, for classic and NEXT alike, unless it is
stuck past its timeout or certain to fail." A job waiting for a runner is not
stuck past its timeout; the answer to that is capacity, not a cancel (run
40428578701, a DEV publish, was cancelled as an orphan on 2026-10-27).

The one exception is a run that never got going: "When nightly runs for older
commits are stuck waiting (queued for a runner or a gate), skip them and build
from the tip: cancel the stale runs and move the nightly branch to the tip"
(Leo, 2026-10-26). superseded_unstarted() below is that rule, read by the
queue janitor (which skips such runs) and by the agents' cancel guard, which
reads this file from origin/main.

Nightly promotion runs inside nightly.yml (promote-nightly-next), so the
nightly glob covers it. A glob picks up a new workflow on its own; REQUIRED
names make a rename or deletion fail the test instead of quietly dropping out.
"""

from __future__ import annotations

import datetime as _dt
import re
from collections.abc import Iterable, Mapping, Sequence
from fnmatch import fnmatch
from pathlib import PurePosixPath
from typing import Any

DELIVERY_GLOBS = (
    "nightly*.yml",          # nightly.yml, nightly-sign.yml, nightly-next-*.yml
    "*-nightly*.yml",        # cmux-tui-nightly.yml, ios-internal-nightly*.yml, resume-nightly-notarization.yml
    "cmux-next-dev-*.yml",   # cmux-next-dev-daily.yml (DEV build/sign/publish), its dispatcher and kick
    "*promote*.yml",         # cloud-vm-image-promote.yml (a VM image to the dev channel)
)
REQUIRED_DELIVERY_WORKFLOWS = ("nightly.yml", "cmux-next-dev-daily.yml")

# Delivery runs of a shared workflow, told apart by run name: the DEV source
# build is cmux-next.yml dispatched with dev_daily=true, which
# cmux-next-dev-daily-dispatch.yml names `cmux NEXT DEV daily · <sha>`.
DELIVERY_RUN_NAME_PREFIXES: dict[str, tuple[str, ...]] = {
    "cmux-next.yml": ("cmux NEXT DEV daily · ",),
}


def _file_name(path: str | None) -> str:
    # A reusable call's path can carry `@ref`; the file name is what counts.
    return PurePosixPath(str(path or "").split("@", 1)[0]).name.lower()


def is_delivery_workflow(path: str | None) -> bool:
    """Whether a workflow path (`.github/workflows/x.yml`, or a bare file name) is a delivery workflow."""
    name = _file_name(path)
    return bool(name) and any(fnmatch(name, pattern) for pattern in DELIVERY_GLOBS)


def is_delivery_run(path: str | None, *names: str | None) -> bool:
    """Whether a run is a nightly, DEV or promote build: a delivery workflow, or a named delivery run of a shared one.

    Pass every title the run carries (the API's `name` and `display_title`); any one matching counts,
    as the dispatcher itself checks both.
    """
    if is_delivery_workflow(path):
        return True
    prefixes = DELIVERY_RUN_NAME_PREFIXES.get(_file_name(path), ())
    return any(str(name or "").startswith(prefix) for name in names for prefix in prefixes)


# --- skipping a superseded run that never got going ---------------------------
# A delivery run may be skipped (cancelled) only when both hold:
#   - its build has not started: no job is running or holds a runner, and no
#     finished job did build work: one that ran on a Mac, ran longer than
#     GATE_JOB_MAX, or whose name says it builds the app, compiles, signs,
#     notarizes, verifies, publishes, promotes, uploads or makes deltas. Gate
#     and input jobs that finished in a few minutes on Linux (decide, resolve
#     inputs, pick a runner) are not the build. A queued job's started_at is
#     set when it is queued, so it is never read as a start.
#   - a newer head of the same branch has its own run of the same workflow,
#     not cancelled, which builds the tip in its place.
# Anything unread (no jobs list, no branch or head) is not a skip.
WAITING_JOB_STATUSES = frozenset({"queued", "waiting", "pending", "requested"})
BUILD_JOB_NAME = re.compile(
    r"publish|promot|sign|notari[sz]|release|upload|deploy|verif|delta|dmg|archive|compile|\bapp\b",
    re.IGNORECASE)
GATE_JOB_MAX = _dt.timedelta(minutes=10)


def _time(value: Any) -> _dt.datetime | None:
    try:
        return _dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


def build_started(jobs: Iterable[Mapping[str, Any]]) -> str | None:
    """Why the run's build counts as started, or None when only gate jobs have run and the rest waits."""
    for job in jobs:
        name = str(job.get("name") or "")
        status = job.get("status")
        if status in WAITING_JOB_STATUSES:
            if job.get("runner_name"):
                return f"its job {name!r} has a runner"
            continue
        if status != "completed":
            return f"its job {name!r} is {status or 'in an unknown state'}"
        if job.get("conclusion") == "skipped":
            continue
        if any("macos" in str(label).lower() for label in job.get("labels") or ()):
            return f"its job {name!r} ran on a Mac"
        if BUILD_JOB_NAME.search(name):
            return f"its job {name!r} has run"
        started, completed = _time(job.get("started_at")), _time(job.get("completed_at"))
        if started is None or completed is None:
            return f"its job {name!r} has run, and for how long cannot be read"
        if completed - started > GATE_JOB_MAX:
            return f"its job {name!r} ran {int((completed - started).total_seconds() // 60)} min"
    return None


def _workflow_key(run: Mapping[str, Any]) -> Any:
    return run.get("workflow_id") or _file_name(run.get("path"))


def newer_head_run(run: Mapping[str, Any], runs: Iterable[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """A run of the same workflow on the same branch, created after `run` at another head, and not cancelled."""
    branch, sha = run.get("head_branch"), run.get("head_sha")
    created = _time(run.get("created_at"))
    if not branch or not sha or created is None:
        return None
    for other in runs:
        if _workflow_key(other) != _workflow_key(run) or other.get("head_branch") != branch:
            continue
        if not other.get("head_sha") or other.get("head_sha") == sha:
            continue
        if other.get("status") == "completed" and other.get("conclusion") in ("cancelled", "skipped"):
            continue
        when = _time(other.get("created_at"))
        if when is not None and when > created:
            return other
    return None


def superseded_unstarted(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]] | None,
                         runs: Iterable[Mapping[str, Any]]) -> tuple[bool, str]:
    """(True, why) when a delivery run may be skipped for the tip; (False, why not) otherwise.

    `jobs` is the run's complete latest-attempt job list (None when unread), and `runs` are runs to find the
    newer head's run among (the same workflow's runs on the branch, or every in-flight run)."""
    if run.get("status") == "completed":
        return False, "it has completed"
    if jobs is None:
        return False, "its jobs could not be read"
    started = build_started(jobs)
    if started:
        return False, f"its build has started: {started}"
    newer = newer_head_run(run, runs)
    if newer is None:
        return False, f"no newer head of {run.get('head_branch') or 'its branch'} has its own run of this workflow"
    waiting = sum(1 for job in jobs if job.get("status") in WAITING_JOB_STATUSES)
    return True, (f"its build has not started ({waiting} job(s) waiting, only gate jobs done) and run "
                  f"{newer.get('id')} builds the newer head {str(newer.get('head_sha'))[:12]} of "
                  f"{run.get('head_branch')}")
