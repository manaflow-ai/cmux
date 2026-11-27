"""The delivery workflows: nightly, DEV and promote builds of classic and NEXT.

One declared list. tests/test_nightly_delivery_concurrency.py reads it to
forbid cancel-in-progress and evicting groups in these files, and
scripts/ci/queue_janitor.py reads it to never cancel one of their runs as an
orphan. Standing rule: "Never cancel a nightly, dev or promote build or its
Release compile once it has started, for classic and NEXT alike, unless it is
stuck past its timeout or certain to fail." A job waiting for a runner is not
stuck past its timeout; the answer to that is capacity, not a cancel (run
40428578701, a DEV publish, was cancelled as an orphan on 2026-10-27).

The one exception is a stale run: "When nightly runs for older commits are
stuck waiting (queued for a runner or a gate), skip them and build from the
tip: cancel the stale runs and move the nightly branch to the tip" (Leo,
2026-10-26). A run is stale only when every job but the light control and
decide ones (LIGHT_JOBS) is still queued for a runner, it has waited at least
STALE_WAIT (20 min), and a newer tip run is already building (sr2,
2026-10-28). superseded_unstarted() below is that rule, read by the queue
janitor (which skips such runs) and by the agents' cancel guard, which reads
this file from origin/main.

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


# A delivery workflow's run from one of these events only tests a change to it: nightly-next-canary.yml and
# nightly-next-launch-smoke.yml run for the pull requests that edit them, and that run publishes, signs, rolls back
# and files nothing. dep-fleet's ruling (#27521) protects started nightly, DEV and promote builds, never these, so a
# pull request run of a delivery workflow is an ordinary pull request run to the rescue's open-head failover and the
# queue janitor.
TEST_ONLY_EVENTS = frozenset({"pull_request", "pull_request_target", "merge_group"})


def is_delivery_event(event: str | None) -> bool:
    """Whether a run's event can deliver: any event but a pull request's (TEST_ONLY_EVENTS). An unread event counts,
    so a run whose event is unknown keeps its protection."""
    return str(event or "") not in TEST_ONLY_EVENTS


def delivers(path: str | None, event: str | None, *names: str | None) -> bool:
    """Whether a run is a delivery run: a delivery workflow's (is_delivery_run(), the same titles) from an event that
    can deliver (is_delivery_event()): a schedule, a dispatch, a push, a workflow_run. A pull request run of
    nightly-next-canary.yml is not one; its scheduled run, or a dispatch on the nightly branch, is."""
    return is_delivery_event(event) and is_delivery_run(path, *names)


# --- skipping a stale run for the tip ----------------------------------------
# The rule (sr2, 2026-10-28): "count a nightly, dev or promote run as stale,
# and so cancellable, only when all of these hold: 1. every job except light
# control jobs and decide jobs is still queued for a runner; 2. it has waited
# at least 20 min; 3. a newer tip run is already building. A run with any
# build, sign or publish job started stays protected. So does the 25-min
# freshness rule (if nothing has published for about 25 min, the newest tip
# must be building; never cancel that one)." It carries out Leo's "When
# nightly runs for older commits are stuck waiting (queued for a runner or a
# gate), skip them and build from the tip: cancel the stale runs and move the
# nightly branch to the tip" (2026-10-26).
#
# superseded_unstarted() below is that rule, read by the queue janitor (which
# skips such runs) and by the agents' cancel guard, which reads this file from
# origin/main. In detail:
#   1. Light control and decide jobs are LIGHT_JOBS, the one declared list of
#      exact job names (as GitHub lists them; a matrix leg's " (...)" suffix is
#      dropped). They may be in any state, on any runner (decide may route to
#      a Mac).
#      Every other job of the run's current attempt is queued for a runner
#      (no runner_name) or skipped. A queued job's started_at is set when it is
#      queued, so it is never read as a start.
#   2. Nothing in the run has moved for STALE_WAIT (20 min): its creation and
#      every job's started_at and completed_at are at least that old. A job
#      without a readable started_at is unread (GitHub sets it at queueing).
#   3. The branch tip (tip_sha, which the caller must read) is a newer head
#      with its own run of the same workflow (a delivery run itself, from the
#      same event and head repository, never a fork's branch of the same
#      name, not finished other than in success) that is building: a build
#      job of it (named for the build, not light) is running or has
#      succeeded, none of its jobs past the light ones failed, and every job
#      the old run lists unskipped is listed there too, live or succeeded (a
#      cache-only or throttled run skips them).
#   Freshness: a run at the branch tip is never stale, and condition 3 asks
#   for the tip itself to be building, so the newest tip always builds.
# Anything unread (no jobs list, no branch, head or head repository) is not a
# skip. A re-run (run_attempt > 1) is judged on its own attempt's jobs: a
# re-run of a build that ran is a new build, and until a job of this attempt
# starts it has not started. A job whose attempt cannot be read is unread.
WAITING_JOB_STATUSES = frozenset({"queued", "waiting", "pending", "requested"})
BUILD_JOB_NAME = re.compile(
    r"build|publish|promot|sign|notari[sz]|release|upload|deploy|verif|delta|dmg|archive|compile|\bapp\b",
    re.IGNORECASE)
# Light control and decide jobs: they only decide, pick a runner label, resolve inputs or look something up, and
# do no build, sign or publish work. Exact job ids of nightly.yml (some only on the nightly-next branch's revision);
# a new job is never light until it is named here. tests/test_delivery_workflows_cancel.py checks that every one of
# them found in a delivery workflow runs no build, sign or publish command.
LIGHT_JOBS = frozenset({
    "decide",                              # whether this head builds, and on which track
    "pick-nightly-app-runner",             # choose a runner label
    "pick-nightly-build-runner",
    "pick-nightly-sign-runner",
    "pick-classic-sign-runner",
    "pick-classic-prepare-runner",
    "resolve-nightly-cmux-tui-client",     # resolve the cmux-tui client commit
    "resolve-nightly-ghostty-cli-helper",  # find a reusable Ghostty CLI helper
    "find-nightly-next-recovery",          # list newer pending notarizations to recover
    "probe-nightly-tag-permission",        # the tag permission probe
})
STALE_WAIT = _dt.timedelta(minutes=20)
KNOWN_CONCLUSIONS = frozenset({"success", "failure", "cancelled", "neutral", "timed_out", "action_required",
                               "stale", "startup_failure"})
FAILED_CONCLUSIONS = frozenset({"failure", "cancelled", "timed_out", "action_required", "startup_failure"})


def _time(value: Any) -> _dt.datetime | None:
    try:
        return _dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


def _base_name(name: str) -> str:
    # A matrix leg is listed as `job (value, ...)`.
    return re.sub(r"\s*\(.*\)\s*$", "", name.strip())


def is_light_job(job: Mapping[str, Any] | str) -> bool:
    """A light control or decide job (LIGHT_JOBS): never the build, wherever it ran."""
    return _base_name(str(job if isinstance(job, str) else job.get("name") or "")) in LIGHT_JOBS


def _named_for_build(name: str) -> bool:
    return bool(BUILD_JOB_NAME.search(name)) and not is_light_job(name)


def attempt_jobs(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]] | None:
    """The jobs of the run's current attempt, or None when that cannot be told. Attempt 1 is every job listed; a
    re-run's listing may carry jobs an earlier attempt finished, which are not this attempt's build."""
    attempt = run.get("run_attempt")
    if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
        return None
    if attempt == 1:
        return list(jobs)
    mine = []
    for job in jobs:
        own = job.get("run_attempt")
        if not isinstance(own, int) or isinstance(own, bool) or own < 1 or own > attempt:
            return None
        if own == attempt:
            mine.append(job)
    return mine


def build_started(jobs: Iterable[Mapping[str, Any]]) -> str | None:
    """Why the run counts as started (condition 1 fails), or None when every job but the light ones (LIGHT_JOBS)
    is still queued for a runner or skipped."""
    for job in jobs:
        name = str(job.get("name") or "")
        status = job.get("status")
        if status == "completed" and job.get("conclusion") not in KNOWN_CONCLUSIONS | {"skipped"}:
            return f"its job {name!r} finished with an unknown conclusion ({job.get('conclusion')!r})"
        if is_light_job(job):
            continue
        if status in WAITING_JOB_STATUSES:
            if job.get("runner_name"):
                return f"its job {name!r} has a runner"
            continue
        if status == "completed" and job.get("conclusion") == "skipped":
            continue
        kind = "build" if _named_for_build(name) else "non-control"
        if status == "completed":
            return f"its {kind} job {name!r} has run ({job.get('conclusion')})"
        return f"its {kind} job {name!r} is {status or 'in an unknown state'}"
    return None


def waited_since(run: Mapping[str, Any], jobs: Iterable[Mapping[str, Any]]) -> _dt.datetime | None:
    """When the run last moved: the newest of its creation and its jobs' started_at and completed_at. None (unread)
    when its creation or any job's started_at, or a finished job's completed_at, cannot be read."""
    newest = _time(run.get("created_at"))
    if newest is None:
        return None
    for job in jobs:
        keys = ("started_at", "completed_at") if job.get("status") == "completed" else ("started_at",)
        for key in keys:
            when = _time(job.get(key))
            if when is None:
                return None
            newest = max(newest, when)
    return newest


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
    """A job that does build work: not a light control job (LIGHT_JOBS), and it asks for a Mac or its name says it
    builds, signs or publishes."""
    if is_light_job(job):
        return False
    return (any("macos" in str(label).lower() for label in job.get("labels") or ())
            or _named_for_build(str(job.get("name") or "")))


def building(jobs: Sequence[Mapping[str, Any]] | None) -> str | None:
    """Why a newer run is not building (condition 3), or None when it is: a job of it named for the build, sign or
    publish work (BUILD_JOB_NAME, never a light job) is running or has succeeded, and no job past the light ones
    failed. A Mac job alone (a compilation cache refresh) is not the build."""
    if jobs is None:
        return "its jobs could not be read"
    live = ""
    for job in jobs:
        name = str(job.get("name") or "")
        if job.get("status") == "completed" and job.get("conclusion") in FAILED_CONCLUSIONS and not is_light_job(job):
            return f"its job {name!r} concluded {job.get('conclusion')}"
        if _named_for_build(name) and (job.get("status") == "in_progress" or (
                job.get("status") == "completed" and job.get("conclusion") == "success")):
            live = live or name
    return None if live else "no build job of it is running or has run"


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
                         *, now: _dt.datetime | None = None, tip_sha: str | None = None,
                         stale_wait: _dt.timedelta = STALE_WAIT) -> tuple[bool, str]:
    """(True, why) when a delivery run is stale and may be skipped for the tip; (False, why not) otherwise. Both
    name the condition that held or failed.

    The rule (sr2, 2026-10-28): "count a nightly, dev or promote run as stale, and so cancellable, only when all
    of these hold: 1. every job except light control jobs and decide jobs is still queued for a runner; 2. it has
    waited at least 20 min; 3. a newer tip run is already building. A run with any build, sign or publish job
    started stays protected. So does the 25-min freshness rule (if nothing has published for about 25 min, the
    newest tip must be building; never cancel that one)."

    `jobs` is the run's complete latest-attempt job list (None when unread); `runs` are runs to find the newer
    head's run among (the same workflow's runs on the branch, or every in-flight run); `jobs_of(newer)` reads a
    newer run's jobs (None when unread), at most REPLACEMENT_JOB_READS of them. `now` defaults to the clock.
    `tip_sha` is the branch tip the caller read: unread (None or empty) is never stale."""
    if run.get("status") not in WAITING_JOB_STATUSES and run.get("status") != "in_progress":
        return False, f"it is {run.get('status') or 'in an unknown state'}"
    if jobs is None:
        return False, "its jobs could not be read"
    jobs = attempt_jobs(run, jobs)
    if jobs is None:
        return False, (f"it is attempt {run.get('run_attempt')}, and which attempt its jobs belong to could not be read"
                       if run.get("run_attempt") else "its attempt could not be read")
    started = build_started(jobs)
    if started:
        return False, f"condition 1 fails, it has started: {started}"
    head, tip = str(run.get("head_sha") or "").lower(), str(tip_sha or "").lower()
    if not tip:
        return False, f"condition 3 cannot be checked: the tip of {run.get('head_branch')} could not be read"
    if head == tip:
        return False, (f"freshness rule: it builds the tip of {run.get('head_branch')}, and the newest tip must be "
                       "building")
    since = waited_since(run, jobs)
    if since is None:
        return False, "how long it has waited could not be read"
    now = now or _dt.datetime.now(_dt.timezone.utc)
    waited = now - since
    minutes = int(stale_wait.total_seconds() // 60)
    if waited < stale_wait:
        return False, (f"condition 2 fails: it has waited {int(waited.total_seconds() // 60)} min since it last "
                       f"moved, under {minutes} min")
    # Every leg, with multiplicity: matrix legs may share a name, and each needs its own leg in the newer run.
    listed = sorted(str(job.get("name") or "") for job in jobs if job.get("conclusion") != "skipped")
    newer = [other for other in newer_head_runs(run, runs) if str(other.get("head_sha") or "").lower() == tip]
    if not newer:
        return False, (f"condition 3 fails: no newer head of {run.get('head_branch') or 'its branch'} at its tip "
                       f"{tip[:12]} has its own run of this workflow")
    if jobs_of is None:
        return False, "condition 3 fails: the newer runs' jobs were not read"
    why_not = ""
    pending = sum(1 for job in jobs if job.get("status") in WAITING_JOB_STATUSES)
    for other in newer[:REPLACEMENT_JOB_READS]:
        theirs = jobs_of(other)
        problem = building(theirs) or builds_the_same(listed, theirs)
        if problem is None:
            return True, (f"stale: (1) every job but the light control and decide ones is queued for a runner or "
                          f"skipped ({pending} job(s) waiting); (2) it has waited {int(waited.total_seconds() // 60)}"
                          f" min since it last moved (at least {minutes}); (3) run {other.get('id')} is building the "
                          f"tip {str(other.get('head_sha'))[:12]} of {run.get('head_branch')}")
        why_not = why_not or f"run {other.get('id')}: {problem}"
    return False, (f"condition 3 fails: no newer run of {run.get('head_branch')} at its tip is building in its place "
                   f"({why_not})")


# --- DEV publish runs a newer publish already covered ---------------------------
# cmux-next-dev-daily.yml's publish runs ("cmux NEXT DEV daily · publish <source run>") all run on main, at
# whatever main's head was when the dispatcher asked, so superseded_unstarted() can never tell them apart by head;
# and their Linux sign jobs run within minutes, so build_started() counts every one as started. On 2026-10-31 that
# left 115 of them queued (the oldest 37 hours), each holding a Verify and a tip DMG job on a Mac label (106 on
# blacksmith-12vcpu-macos-26, dead since 10-30, the rest on glaeda-std-xcode-26.6).
#
# Such a run can never publish once a newer publish run has published: its Publish job's not_newer() skips a
# source commit the publish record already contains, and the tip feed refuses a build that is not newer than the
# one it has. So it is certain not to deliver, the "certain to fail" exception of the standing rule, when:
#   1. it is a DEV publish run, in flight, no job of its current attempt is running (in progress, or queued with a
#      runner assigned), and its Publish job has not run: what is left only waits for a runner. A tip DMG or tip
#      feed job that already finished changes nothing, since the tip feed refuses a build that is not newer;
#   2. nothing in it has moved for STALE_WAIT;
#   3. a newer DEV publish run (a later source run id) completed in success with its Publish job succeeding; and
#   4. that run's source commit contains this run's source commit (`contains(old, new)` is True).
# Anything unread is a keep.
DEV_PUBLISH_WORKFLOW = "cmux-next-dev-daily.yml"
DEV_PUBLISH_TITLE = re.compile(r"^cmux NEXT DEV daily · publish ([0-9]+)$")
DEV_PUBLISH_JOB = "Publish cmux NEXT DEV"


def dev_publish_source(run: Mapping[str, Any]) -> int | None:
    """The source run id a DEV publish run publishes (from its title), or None when it is not one."""
    if _file_name(run.get("path")) != DEV_PUBLISH_WORKFLOW:
        return None
    for title in (run.get("name"), run.get("display_title")):
        match = DEV_PUBLISH_TITLE.match(str(title or ""))
        if match:
            return int(match.group(1))
    return None


def dev_publish_published(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]] | None) -> bool:
    """Whether a DEV publish run finished in success with its Publish job succeeding (its source, or a newer one,
    is then in the publish record)."""
    if dev_publish_source(run) is None or run.get("status") != "completed" or run.get("conclusion") != "success":
        return False
    mine = attempt_jobs(run, jobs) if jobs is not None else None
    return bool(mine) and any(_base_name(str(job.get("name") or "")) == DEV_PUBLISH_JOB
                              and job.get("status") == "completed" and job.get("conclusion") == "success"
                              for job in mine)


def dev_publish_superseded(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]] | None, *,
                           source_sha: str | None, newer: Mapping[str, Any] | None,
                           newer_jobs: Sequence[Mapping[str, Any]] | None, newer_source_sha: str | None,
                           contains: Contains, now: _dt.datetime | None = None,
                           stale_wait: _dt.timedelta = STALE_WAIT) -> tuple[bool, str]:
    """(True, why) when a DEV publish run can never publish because `newer` (a later DEV publish run) already
    published a source commit that contains this run's; (False, why not) otherwise or when anything is unread."""
    source = dev_publish_source(run)
    if source is None:
        return False, "it is not a DEV publish run"
    if run.get("status") not in WAITING_JOB_STATUSES and run.get("status") != "in_progress":
        return False, f"it is {run.get('status') or 'in an unknown state'}"
    mine = attempt_jobs(run, jobs) if jobs is not None else None
    if mine is None:
        return False, "its jobs, or which attempt they belong to, could not be read"
    for job in mine:
        name, status = str(job.get("name") or ""), job.get("status")
        if status == "completed" and job.get("conclusion") not in KNOWN_CONCLUSIONS | {"skipped"}:
            return False, f"its job {name!r} finished with an unknown conclusion ({job.get('conclusion')!r})"
        waiting = status in WAITING_JOB_STATUSES and not job.get("runner_name")
        if status != "completed" and not waiting:
            return False, f"condition 1 fails: its job {name!r} is running ({status}, runner {job.get('runner_name')!r})"
        if (_base_name(name) == DEV_PUBLISH_JOB and not waiting
                and not (status == "completed" and job.get("conclusion") == "skipped")):
            return False, f"condition 1 fails: its Publish job has run ({job.get('conclusion')})"
    since = waited_since(run, mine)
    if since is None:
        return False, "how long it has waited could not be read"
    waited = (now or _dt.datetime.now(_dt.timezone.utc)) - since
    if waited < stale_wait:
        return False, (f"condition 2 fails: it has waited {int(waited.total_seconds() // 60)} min since it last "
                       f"moved, under {int(stale_wait.total_seconds() // 60)} min")
    if newer is None:
        return False, "condition 3 fails: no newer DEV publish run has published"
    newer_source = dev_publish_source(newer)
    if newer_source is None or newer_source <= source:
        return False, f"condition 3 fails: run {newer.get('id')} does not publish a later source run than {source}"
    if not dev_publish_published(newer, newer_jobs):
        return False, f"condition 3 fails: run {newer.get('id')} has not published (Publish job not a success)"
    old, new = str(source_sha or "").lower(), str(newer_source_sha or "").lower()
    if not _SHA.fullmatch(old) or not _SHA.fullmatch(new):
        return False, "condition 4 fails: a source commit could not be read"
    if old != new and contains(old, new) is not True:
        return False, f"condition 4 fails: {new[:12]} could not be shown to contain {old[:12]}"
    return True, (f"certain not to publish: run {newer.get('id')} published source run {newer_source} "
                  f"({new[:12]}), which contains this run's source {old[:12]}; the publisher and the tip feed refuse "
                  f"a commit that is not newer (it waited {int(waited.total_seconds() // 60)} min with no job "
                  "running)")


# --- runs that can never deliver ----------------------------------------------
# Two more ways a started nightly run may be cancelled, both read by the
# agents' cancel guard (never by the queue janitor, which only skips runs that
# never started):
#   - latest wins: "SKIP THE OLD NIGHTLY BUILDS THEN WE'RE JUST BUILDING FROM
#     THE TIP" (Leo, 2026-10-26). A nightly-next run never publishes once the
#     feed holds a newer build, and is replaced once a newer commit is promoted
#     to the branch tip with its own run building (or built). Either makes the
#     old run skippable even though its publish job has not run.
#   - known bad: a run whose head contains a commit filed in
#     nightly_known_bad.json (bad_since) and lacks its fix (fixed_by) is
#     certain to fail. The file is the one declared list; no SHA lives here.
# `contains(ancestor, descendant)` answers whether descendant's history has
# ancestor (None when unread); anything unread is never a cancel.

# Workflow file -> {branch: the release tag whose body records the published commit}.
LATEST_WINS_FEEDS: dict[str, dict[str, str]] = {"nightly.yml": {"nightly-next": "nightly-next"}}
KNOWN_BAD_PATH = "scripts/ci/nightly_known_bad.json"
KNOWN_BAD_WORKFLOWS = ("nightly.yml",)
KNOWN_BAD_KEYS = frozenset({"bad_since", "fixed_by", "reason", "filed_by"})
PUBLISHED_MARKER = re.compile(r"<!--\s*cmux-published-sha:\s*([0-9a-f]{40})\s*-->", re.IGNORECASE)
_SHA = re.compile(r"[0-9a-f]{40}")
Contains = Callable[[str, str], "bool | None"]


def published_commit(release_body: str | None) -> str | None:
    """The commit a feed's release body records (scripts/ci/nightly-publication-marker.py), or None."""
    match = PUBLISHED_MARKER.search(release_body or "")
    return match.group(1).lower() if match else None


def latest_wins_feed(run: Mapping[str, Any]) -> str | None:
    """The release tag of the latest-wins feed this run publishes to, or None when it publishes to none."""
    return LATEST_WINS_FEEDS.get(_file_name(run.get("path")), {}).get(str(run.get("head_branch") or ""))


def never_publishes(run: Mapping[str, Any], runs: Iterable[Mapping[str, Any]], *, tip_sha: str | None,
                    published_sha: str | None, contains: Contains,
                    jobs: Sequence[Mapping[str, Any]] | None = None,
                    jobs_of: Callable[[Mapping[str, Any]], Sequence[Mapping[str, Any]] | None] | None = None,
                    ) -> tuple[bool, str]:
    """(True, why) when a latest-wins run can never publish: the feed already has a newer build, or a newer commit
    sits at the branch tip with its own run building or built. (False, why not) otherwise, or when anything is
    unread. For the tip, `jobs` (the run's own) and `jobs_of(tip run)` must show the tip run doing the same build:
    each build job of this run's current attempt that is not skipped is listed there, live or succeeded (a
    cache-only or throttled tip run skips them)."""
    if run.get("status") not in WAITING_JOB_STATUSES and run.get("status") != "in_progress":
        return False, f"it is {run.get('status') or 'in an unknown state'}"
    if not latest_wins_feed(run):
        return False, "it publishes to no latest-wins feed"
    if not _head_repo(run) or not run.get("head_branch"):
        return False, "its head repository or branch could not be read"
    head = str(run.get("head_sha") or "").lower()
    if not _SHA.fullmatch(head):
        return False, "its head could not be read"
    published = str(published_sha or "").lower()
    if _SHA.fullmatch(published) and published != head and contains(head, published) is True:
        return True, (f"the feed already has {published[:12]}, which contains its head {head[:12]}, so under "
                      "latest-wins it can never publish")
    tip = str(tip_sha or "").lower()
    if not _SHA.fullmatch(tip):
        return False, f"the tip of {run.get('head_branch')} could not be read"
    if tip == head:
        return False, f"it builds the tip of {run.get('head_branch')}"
    if contains(head, tip) is not True:
        return False, f"the tip {tip[:12]} could not be shown to contain its head {head[:12]}"
    mine = attempt_jobs(run, jobs) if jobs is not None else None
    if mine is None or jobs_of is None:
        return False, "its jobs, or which attempt they belong to, could not be read"
    builds = [str(job.get("name") or "") for job in mine if job.get("conclusion") != "skipped" and is_build_job(job)]
    if not builds:
        return False, "it lists no build job, so a tip run doing the same build cannot be shown"
    why_not = f"the tip {tip[:12]} has no run building it"
    for other in runs:
        if (str(other.get("head_sha") or "").lower() != tip or _workflow_key(other) != _workflow_key(run)
                or other.get("head_branch") != run.get("head_branch") or _head_repo(other) != _head_repo(run)
                or not is_delivery_run(other.get("path"), other.get("name"), other.get("display_title"))):
            continue
        status = other.get("status")
        if not (status in WAITING_JOB_STATUSES or status == "in_progress" or (
                status == "completed" and other.get("conclusion") == "success")):
            continue
        # A re-run at the tip is read on its own attempt only: an earlier attempt's build is not this one's.
        listed = jobs_of(other)
        problem = builds_the_same(builds, None if listed is None else attempt_jobs(other, listed))
        if problem:
            why_not = f"run {other.get('id')} at the tip {tip[:12]} does not show the same build: {problem}"
            continue
        return True, (f"the newer commit {tip[:12]} is promoted at the tip of {run.get('head_branch')} and run "
                      f"{other.get('id')} is {'building' if status != 'completed' else 'done building'} it, so "
                      "under latest-wins this run can never publish")
    return False, why_not


def known_bad_entries(text: str | None) -> list[dict[str, Any]] | None:
    """The entries of nightly_known_bad.json, or None when the file is missing or any entry is malformed."""
    import json
    try:
        doc = json.loads(text or "")
    except ValueError:
        return None
    entries = doc.get("entries") if isinstance(doc, dict) else None
    if not isinstance(entries, list):
        return None
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != KNOWN_BAD_KEYS:
            return None
        if not _SHA.fullmatch(str(entry["bad_since"])):
            return None
        if entry["fixed_by"] is not None and not _SHA.fullmatch(str(entry["fixed_by"])):
            return None
        if not (isinstance(entry["reason"], str) and entry["reason"].strip()
                and isinstance(entry["filed_by"], str) and entry["filed_by"].strip()):
            return None
    return entries


def known_bad(run: Mapping[str, Any], entries: Sequence[Mapping[str, Any]] | None,
              contains: Contains) -> tuple[Mapping[str, Any] | None, str]:
    """(the entry, why) when the run's head contains a known-bad commit and lacks its fix, so the run is certain
    to fail; (None, why not) otherwise, or when the list or an ancestry is unread."""
    if _file_name(run.get("path")) not in KNOWN_BAD_WORKFLOWS:
        return None, "its workflow has no known-bad list"
    if entries is None:
        return None, f"{KNOWN_BAD_PATH} could not be read"
    head = str(run.get("head_sha") or "").lower()
    if not _SHA.fullmatch(head):
        return None, "its head could not be read"
    unread = ""
    for entry in entries:
        bad, fix = str(entry["bad_since"]), entry.get("fixed_by")
        has_bad = contains(bad, head)
        has_fix = False if has_bad is not True or not fix else contains(str(fix), head)
        if has_bad is True and has_fix is False:
            return entry, (f"its head {head[:12]} contains {bad[:12]} ({entry['reason']}) and lacks its fix "
                           f"{str(fix or 'none yet')[:12]}, so it is certain to fail")
        if has_bad is None or has_fix is None:
            unread = unread or f"whether its head has {bad[:12]} or its fix could not be read"
    return None, unread or "its head contains no known-bad commit without its fix"
