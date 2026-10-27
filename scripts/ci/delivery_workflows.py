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
from collections.abc import Callable, Iterable, Mapping, Sequence
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
#     which builds the tip in its place: a delivery run itself (not an
#     ordinary run of a shared workflow), from the same event and the same
#     head repository (never a fork's branch of the same name), not finished
#     other than in success, and whose own jobs show the same build: every job
#     the old run waits on is listed there and not skipped or failed (a
#     cache-only or throttled run skips them).
# Anything unread (no jobs list, no branch, head or head repository) is not a
# skip, and neither is a re-run (run_attempt > 1): only the latest attempt's
# jobs are read, and an earlier attempt may have built.
WAITING_JOB_STATUSES = frozenset({"queued", "waiting", "pending", "requested"})
BUILD_JOB_NAME = re.compile(
    r"publish|promot|sign|notari[sz]|release|upload|deploy|verif|delta|dmg|archive|compile|\bapp\b",
    re.IGNORECASE)
GATE_JOB_MAX = _dt.timedelta(minutes=10)
KNOWN_CONCLUSIONS = frozenset({"success", "failure", "cancelled", "neutral", "timed_out", "action_required",
                               "stale", "startup_failure"})


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
        if job.get("conclusion") not in KNOWN_CONCLUSIONS:
            return f"its job {name!r} finished with an unknown conclusion ({job.get('conclusion')!r})"
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


def _head_repo(run: Mapping[str, Any]) -> str:
    return str(((run.get("head_repository") or {}).get("full_name")) or "").lower()


def newer_head_runs(run: Mapping[str, Any], runs: Iterable[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    """Delivery runs of the same workflow, event, head repository and branch, created after `run` at another head,
    and not finished other than in success; newest first."""
    branch, sha, repo = run.get("head_branch"), run.get("head_sha"), _head_repo(run)
    created = _time(run.get("created_at"))
    if not branch or not sha or not repo or not run.get("event") or created is None:
        return []
    found: dict[Any, tuple[_dt.datetime, Mapping[str, Any]]] = {}
    for other in runs:
        if _workflow_key(other) != _workflow_key(run) or other.get("head_branch") != branch:
            continue
        if not other.get("head_sha") or other.get("head_sha") == sha:
            continue
        if _head_repo(other) != repo or other.get("event") != run.get("event"):
            continue
        if other.get("run_attempt") != 1:  # a re-run's jobs are only its latest attempt's; missing is unread
            continue
        if not is_delivery_run(other.get("path"), other.get("name"), other.get("display_title")):
            continue
        status = other.get("status")
        if status == "completed" and other.get("conclusion") != "success":
            continue
        if status != "completed" and status not in WAITING_JOB_STATUSES and status != "in_progress":
            continue  # unknown or missing: unread
        when = _time(other.get("created_at"))
        if when is not None and when > created:
            found[other.get("id")] = (when, other)
    return [other for _, other in sorted(found.values(), key=lambda pair: pair[0], reverse=True)]


def is_build_job(job: Mapping[str, Any]) -> bool:
    """A job that does build work: it asks for a Mac, or its name says it builds, signs or publishes."""
    return (any("macos" in str(label).lower() for label in job.get("labels") or ())
            or bool(BUILD_JOB_NAME.search(str(job.get("name") or ""))))


def builds_the_same(waiting: Sequence[str], other_jobs: Sequence[Mapping[str, Any]] | None) -> str | None:
    """Why `other_jobs` (a newer run's) do not show that run doing the same work, or None when they do: each job
    of the old run that is not skipped (`waiting`: those waiting and the gates that ran) is listed in the newer one
    and has not been skipped or failed. A cache-only or throttled run skips its build jobs, and one still deciding
    has not listed them yet."""
    if other_jobs is None:
        return "its jobs could not be read"
    listed: dict[str, list[Mapping[str, Any]]] = {}
    for job in other_jobs:
        listed.setdefault(str(job.get("name") or ""), []).append(job)
    for name in sorted(set(waiting)):
        legs = listed.get(name) or []
        want = list(waiting).count(name)
        if len(legs) < want:
            return f"it lists {len(legs)} job(s) {name!r} where the old run has {want}"
        for leg in legs:
            live = leg.get("status") in WAITING_JOB_STATUSES or leg.get("status") == "in_progress"
            if not live and not (leg.get("status") == "completed" and leg.get("conclusion") == "success"):
                return f"its job {name!r} was skipped, did not succeed, or is {leg.get('status') or 'unknown'}"
    return None


REPLACEMENT_JOB_READS = 3


def superseded_unstarted(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]] | None,
                         runs: Iterable[Mapping[str, Any]],
                         jobs_of: Callable[[Mapping[str, Any]], Sequence[Mapping[str, Any]] | None] | None = None,
                         ) -> tuple[bool, str]:
    """(True, why) when a delivery run may be skipped for the tip; (False, why not) otherwise.

    `jobs` is the run's complete latest-attempt job list (None when unread); `runs` are runs to find the newer
    head's run among (the same workflow's runs on the branch, or every in-flight run); `jobs_of(newer)` reads a
    newer run's jobs (None when unread), at most REPLACEMENT_JOB_READS of them. The newer run must show the same
    build: each job the old run waits on is listed there and not skipped or failed."""
    if run.get("status") not in WAITING_JOB_STATUSES and run.get("status") != "in_progress":
        return False, f"it is {run.get('status') or 'in an unknown state'}"
    if jobs is None:
        return False, "its jobs could not be read"
    if run.get("run_attempt") != 1:
        return False, (f"it is attempt {run.get('run_attempt')}, and an earlier attempt's jobs are not read"
                       if run.get("run_attempt") else "its attempt could not be read")
    started = build_started(jobs)
    if started:
        return False, f"its build has started: {started}"
    pending = [job for job in jobs if job.get("status") in WAITING_JOB_STATUSES]
    if not any(is_build_job(job) for job in pending):
        # Still at its gates (decide, inputs): whether it would build at all is not known yet, so nothing can show
        # that a newer run does the same.
        return False, "it waits on no build job yet, so what it would deliver cannot be matched"
    # Every leg, with multiplicity: matrix legs may share a name, and each needs its own leg in the newer run.
    waiting = sorted(str(job.get("name") or "") for job in jobs if job.get("conclusion") != "skipped")
    newer = newer_head_runs(run, runs)
    if not newer:
        return False, f"no newer head of {run.get('head_branch') or 'its branch'} has its own run of this workflow"
    if jobs_of is None:
        return False, "the newer runs' jobs were not read"
    why_not = ""
    for other in newer[:REPLACEMENT_JOB_READS]:
        problem = builds_the_same(waiting, jobs_of(other))
        if problem is None:
            return True, (f"its build has not started ({len(pending)} job(s) waiting, only gate jobs done) and run "
                          f"{other.get('id')} builds the newer head {str(other.get('head_sha'))[:12]} of "
                          f"{run.get('head_branch')} with the same job(s)")
        why_not = why_not or f"run {other.get('id')}: {problem}"
    return False, f"no newer run of {run.get('head_branch')} shows the same build ({why_not})"
