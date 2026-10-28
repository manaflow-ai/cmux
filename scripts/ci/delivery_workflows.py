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
# skip. A re-run (run_attempt > 1) is judged on its own attempt's jobs: a
# re-run of a build that ran is a new build, and until a job of this attempt
# starts it has not started. A job whose attempt cannot be read is unread.
# Picker jobs (pick-nightly-app-runner, pick-nightly-sign-runner) only choose a
# runner label; their names are not read as the build.
WAITING_JOB_STATUSES = frozenset({"queued", "waiting", "pending", "requested"})
BUILD_JOB_NAME = re.compile(
    r"publish|promot|sign|notari[sz]|release|upload|deploy|verif|delta|dmg|archive|compile|\bapp\b",
    re.IGNORECASE)
PICKER_JOB_NAME = re.compile(r"pick-[\w-]*-runner", re.IGNORECASE)
GATE_JOB_MAX = _dt.timedelta(minutes=10)
KNOWN_CONCLUSIONS = frozenset({"success", "failure", "cancelled", "neutral", "timed_out", "action_required",
                               "stale", "startup_failure"})


def _time(value: Any) -> _dt.datetime | None:
    try:
        return _dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


def _named_for_build(name: str) -> bool:
    return bool(BUILD_JOB_NAME.search(name)) and not PICKER_JOB_NAME.fullmatch(name.strip())


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
        if _named_for_build(name):
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
            or _named_for_build(str(job.get("name") or "")))


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
    jobs = attempt_jobs(run, jobs)
    if jobs is None:
        return False, (f"it is attempt {run.get('run_attempt')}, and which attempt its jobs belong to could not be read"
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
