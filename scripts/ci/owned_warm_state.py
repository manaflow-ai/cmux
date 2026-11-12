#!/usr/bin/env python3
"""Which owned root runner kept a build of which main commits (warm affinity).

An owned Mac keeps compile admission's DerivedData between jobs
(owned_build_state.py `keep`), so a later admission merging onto the main
commit that build sat on recompiles only its own diff. GitHub hands a
root-label job to any free root runner, though, so that admission usually
lands on another Mac and compiles from a seed instead. ci-macos.yml compile
admission uploads the `owned-warm-keys` artifact on an owned Mac: the output
of `owned_build_state.py warm-keys`,

    {"runner": "<runner name>", "pool": "glaeda-root-std-xcode-26.6",
     "keys": ["<sha12>", "pr-<n>", ...],
     "roots": [{"root": 1, "merged_onto": "<sha40>", "pr": <n>,
                "pr_app_swift_files": [...], "pr_app_swift_total": <n>,
                "pr_package_interface": false}, {"root": 2}]}

with the kept build's merge base and pull request first, then the mini's
other roots', then the local seeds' on a mini with one root
(owned_build_state.py `warm-keys`).

The queue janitor folds those artifacts into its `macos-pool-load` snapshot
as `warm` (sweep()), and pr_runner_pool.py reads it: when an idle root runner
is warm for a run's merge base, admission's runs-on names that runner's own
static label, `glaeda-runner-<runner name>` (glaeda-cmux-runner gives every
root runner one at install time). Nothing writes a runner label at job time,
so the routing App needs only "Self-hosted runners: Read-only".

    "warm": {"through": <newest artifact id folded>,
             "runners": {"<runner name>": {"keys": ["<sha12>", ...],
                                           "at": "<artifact created_at>",
                                           "roots": [...]}}}

`roots` is every canonical root of the runner's mini with what glaeda's
job-started hook reads from its stamp (roots()), which warm_distance.py
distance_route() scores with the hook's near/far/rebuild tiers across minis.

Each sweep starts from the previous snapshot's `warm` and folds only the
artifacts newer than `through`, oldest first, so a runner's newest admission
replaces what it kept before. Every artifact costs two requests (its run's
jobs, unless the janitor listed them already, and its download), and a sweep
folds at most MAX_NEW. An entry older than MAX_AGE_HOURS is dropped.

The janitor sweeps every 10 to 45 minutes, so pr_runner_pool.py also folds
the artifacts uploaded since its snapshot live (live_warm()): one listing
plus two requests each for at most LIVE_MAX_NEW, the newest, under the same
checks.

The runner is the one the jobs API says ran admission, never the name in the
artifact, which the pull request's own code wrote: an artifact naming another
runner changes nothing, and so does one from a fork's run. A key that is not
12 hex digits or `pr-<n>` is dropped. A wrong key only sends an admission to a Mac whose
build is further away, which compiles as it would elsewhere.

The artifact name is fixed because this repository's unfiltered artifact
listing answers 500; the listing by name works, and admission uploads with
`overwrite: true` so a re-run attempt replaces its run's copy.
"""
from __future__ import annotations

import datetime as dt
import io
import json
import sys
import urllib.error
import zipfile
import zlib
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pr_runner_pool import ARTIFACT_NAME as SNAPSHOT_ARTIFACT  # noqa: E402
from pr_runner_pool import SNAPSHOT_BRANCH, SNAPSHOT_FILE, trusted_snapshot_artifact, warm_key  # noqa: E402

ARTIFACT_NAME = "owned-warm-keys"
KEYS_FILE = "warm-keys.json"
# ci-macos.yml's compile admission job; the jobs API prefixes the caller's job name.
ADMISSION_JOB = "macOS compile admission"
# Keys one runner keeps at most (owned_build_state.MAX_WARM_KEYS): each of
# its mini's roots' kept merge base and `pr-<n>`, then its local seeds (one-root minis).
MAX_KEYS = 8
# ci.yml's display name: admission of any other workflow proves nothing.
CI_WORKFLOW = "CI"
# Artifacts folded per sweep, oldest first; the rest wait for the next one.
MAX_NEW = 30
# Artifacts the picker folds itself past its snapshot's `through` (live_warm()), the newest first: at most
# 1 + 2 * LIVE_MAX_NEW requests of the GITHUB_TOKEN's shared hourly budget per pull request run.
LIVE_MAX_NEW = 4
# A snapshot younger than this is fresh enough: the picker lists nothing.
LIVE_MIN_AGE_SECONDS = 120
# Roots per mini and files per root kept (owned_build_state.py MAX_PATHS caps the stamp's list).
MAX_ROOTS = 4
MAX_ROOT_FILES = 400
MAX_PARKED = 2  # parked pull request builds per root (owned_build_state.py PR_SLOTS)
MAX_AGE_HOURS = 24
MAX_JOB_PAGES = 3
# Previous snapshots read, newest first, for the last one that has `warm`.
MAX_PREVIOUS = 3
# What a corrupt artifact raises: read, it proves nothing, never a retry.
UNREADABLE = (ValueError, KeyError, EOFError, NotImplementedError, zipfile.BadZipFile, zlib.error)


class Transient(Exception):
    """A request failed; the sweep stops before this artifact and retries it next time."""


def through_of(warm: Mapping[str, Any]) -> int:
    value = warm.get("through")
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def keys(document: Any) -> list[str]:
    """The artifact's valid keys, deduplicated in order, at most MAX_KEYS."""
    raw = document.get("keys") if isinstance(document, Mapping) else None
    found: list[str] = []
    for key in raw if isinstance(raw, list) else []:
        key = warm_key(str(key))
        if key and key not in found:
            found.append(key)
    return found[:MAX_KEYS]


def stamp_fields(entry: Mapping[str, Any]) -> dict[str, Any]:
    """A root's or parked build's stamp fields (owned_build_state.py ROOT_FIELDS), each checked."""
    clean: dict[str, Any] = {}
    onto = str(entry.get("merged_onto") or "").lower()
    if len(onto) == 40 and warm_key(onto):
        clean["merged_onto"] = onto
    pr = entry.get("pr")
    if isinstance(pr, int) and not isinstance(pr, bool) and 0 < pr < 10**9:
        clean["pr"] = pr
    files = entry.get("pr_app_swift_files")
    if isinstance(files, list):
        clean["pr_app_swift_files"] = [path for path in files[:MAX_ROOT_FILES]
                                       if isinstance(path, str) and 0 < len(path) <= 512 and "\0" not in path]
    total = entry.get("pr_app_swift_total")
    if isinstance(total, int) and not isinstance(total, bool) and 0 <= total < 10**6:
        clean["pr_app_swift_total"] = total
    if entry.get("pr_package_interface") in (True, False, None) and "pr_package_interface" in entry:
        clean["pr_package_interface"] = entry.get("pr_package_interface")
    return clean


def roots(document: Any) -> list[dict[str, Any]]:
    """The artifact's valid roots (owned_build_state.py `warm-keys`), at most MAX_ROOTS, fields checked.

    A root's `parked` pull request builds (at most MAX_PARKED, each with a pull request) are kept too."""
    raw = document.get("roots") if isinstance(document, Mapping) else None
    found: list[dict[str, Any]] = []
    seen: set[int] = set()
    for entry in raw if isinstance(raw, list) else []:
        number = entry.get("root") if isinstance(entry, Mapping) else None
        if not isinstance(number, int) or isinstance(number, bool) or not 0 < number < 100 or number in seen:
            continue
        seen.add(number)
        clean: dict[str, Any] = {"root": number, **stamp_fields(entry)}
        parked = entry.get("parked")
        parked = [stamp_fields(item) for item in parked[:MAX_PARKED] if isinstance(item, Mapping)] \
            if isinstance(parked, list) else []
        parked = [item for item in parked if "pr" in item]
        if parked:
            clean["parked"] = parked
        found.append(clean)
    return sorted(found, key=lambda item: item["root"])[:MAX_ROOTS]


def admission_job(jobs: Sequence[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """The run's compile admission job that ran on a runner, or None."""
    for job in jobs:
        name = str(job.get("name") or "")
        if ((name == ADMISSION_JOB or name.endswith(" / " + ADMISSION_JOB)) and job.get("runner_name")
                and job.get("workflow_name") == CI_WORKFLOW):
            return job
    return None


def parse_time(value: Any) -> dt.datetime | None:
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def same_repository(artifact: Mapping[str, Any]) -> bool:
    run = artifact.get("workflow_run") or {}
    return run.get("repository_id") is not None and run.get("head_repository_id") == run.get("repository_id")


def new_artifacts(previous: Mapping[str, Any], artifacts: Sequence[Any]) -> list[Mapping[str, Any]]:
    """The artifacts to fold this sweep, oldest first: newer than `through`, at most MAX_NEW."""
    through = through_of(previous)
    fresh = [artifact for artifact in artifacts
             if isinstance(artifact, Mapping) and not artifact.get("expired")
             and artifact.get("name") == ARTIFACT_NAME and isinstance(artifact.get("id"), int)
             and artifact["id"] > through and same_repository(artifact)]
    return sorted(fresh, key=lambda artifact: artifact["id"])[:MAX_NEW]


def record(document: Any, jobs: Sequence[Mapping[str, Any]]) -> tuple[str, list[str], list[dict[str, Any]]] | str:
    """(runner, keys, roots) the artifact proves, or why it proves nothing."""
    if not isinstance(document, Mapping):
        return "the warm keys are not a JSON object"
    job = admission_job(jobs)
    if job is None:
        return "no compile admission job ran on a runner"
    runner = str(job.get("runner_name"))
    if str(document.get("runner") or "") != runner:
        return f"the keys name runner {document.get('runner')!r}, but admission ran on {runner!r}"
    return runner, keys(document), roots(document)


def fold(previous: Mapping[str, Any], folded: Sequence[tuple[Mapping[str, Any], tuple | str]],
         now: dt.datetime) -> dict[str, Any]:
    """`previous` with each (artifact, record) applied in order, entries past MAX_AGE_HOURS dropped."""
    runners: dict[str, Any] = {}
    for name, entry in (previous.get("runners") or {}).items() if isinstance(previous.get("runners"), Mapping) else ():
        if isinstance(entry, Mapping) and isinstance(entry.get("keys"), list):
            runners[str(name)] = {"keys": [key for key in entry["keys"] if warm_key(str(key)) == key][:MAX_KEYS],
                                  "at": str(entry.get("at") or "")}
            kept_roots = roots(entry)
            if kept_roots:
                runners[str(name)]["roots"] = kept_roots
    through = through_of(previous)
    for artifact, proved in folded:
        through = max(through, int(artifact["id"]))
        if isinstance(proved, tuple):
            runner, found = proved[0], proved[1]
            runners[runner] = {"keys": found, "at": str(artifact.get("created_at") or "")}
            if len(proved) > 2 and proved[2]:
                runners[runner]["roots"] = proved[2]
    cutoff = now - dt.timedelta(hours=MAX_AGE_HOURS)
    runners = {name: entry for name, entry in runners.items()
               if entry["keys"] and (parse_time(entry["at"]) or cutoff) > cutoff}
    return {"through": through, "runners": dict(sorted(runners.items()))}


def sweep(client: Any, jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], now: dt.datetime,
          log: Callable[[str], None] = print) -> dict[str, Any]:
    """The snapshot's new `warm`: the previous one plus the artifacts uploaded since.

    `client` is a pr_runner_pool.GitHub (get() and download()). Raises when
    no previous snapshot can be read (the janitor then leaves `warm` out, and
    the next sweep reads the older one). A request that fails stops the fold
    before that artifact, which the next sweep retries; an artifact that is
    read but proves nothing is passed over for good.
    """
    previous = previous_warm(client)
    try:
        listed = client.get(f"/actions/artifacts?name={ARTIFACT_NAME}&per_page=100").get("artifacts") or []
    except (OSError, ValueError, RuntimeError) as error:
        log(f"owned warm state: listing failed ({type(error).__name__}); keeping the previous state")
        return fold(previous, [], now)
    folded: list[tuple[Mapping[str, Any], tuple | str]] = []
    for artifact in new_artifacts(previous, listed):
        run_id = int((artifact.get("workflow_run") or {}).get("id") or 0)
        try:
            proved = read(client, artifact, jobs_by_run.get(run_id), run_id)
        except Transient as error:
            log(f"owned warm state: run {run_id} artifact {artifact['id']}: {error}; retried next sweep")
            break
        log(f"owned warm state: run {run_id} artifact {artifact['id']}: "
            + (f"{proved[0]} keeps {', '.join(proved[1]) or 'no keys'}" if isinstance(proved, tuple) else proved))
        folded.append((artifact, proved))
    return fold(previous, folded, now)


def read(client: Any, artifact: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]] | None,
         run_id: int) -> tuple | str:
    """record() for one artifact. Raises Transient when a request fails."""
    try:
        if jobs is None:
            jobs = []
            for page in range(1, MAX_JOB_PAGES + 1):
                batch = client.get(f"/actions/runs/{run_id}/jobs?filter=latest&per_page=100&page={page}"
                                   ).get("jobs") or []
                jobs.extend(job for job in batch if isinstance(job, Mapping))
                if len(batch) < 100:
                    break
        blob = client.download(artifact)
    except urllib.error.HTTPError as error:
        if error.code in (404, 410):  # gone for good: pass it over
            return f"gone ({error.code})"
        raise Transient(f"request failed ({error.code})") from error
    except (OSError, ValueError, RuntimeError) as error:
        raise Transient(f"request failed ({type(error).__name__})") from error
    try:
        document = json.loads(zipfile.ZipFile(io.BytesIO(blob)).read(KEYS_FILE))
    except UNREADABLE as error:
        return f"unreadable ({type(error).__name__})"
    return record(document, jobs)


def previous_warm(client: Any) -> Mapping[str, Any]:
    """The `warm` of the newest trusted janitor snapshot that has one, or {} when none does.

    A sweep that failed publishes a snapshot without `warm`, so the older
    ones are read too (at most MAX_PREVIOUS). Raises when a request fails,
    rather than start over from nothing.
    """
    listed = client.get(f"/actions/artifacts?name={SNAPSHOT_ARTIFACT}&per_page=20").get("artifacts") or []
    trusted = sorted((artifact for artifact in listed
                      if isinstance(artifact, Mapping) and trusted_snapshot_artifact(artifact, SNAPSHOT_BRANCH)),
                     key=lambda artifact: str(artifact.get("created_at") or ""), reverse=True)
    for artifact in trusted[:MAX_PREVIOUS]:
        blob = client.download(artifact)
        try:
            document = json.loads(zipfile.ZipFile(io.BytesIO(blob)).read(SNAPSHOT_FILE))
        except UNREADABLE:
            continue
        warm = document.get("warm") if isinstance(document, Mapping) else None
        if isinstance(warm, Mapping):
            return warm
    return {}


def live_warm(client: Any, warm: Mapping[str, Any], now: dt.datetime, *, generated_at: dt.datetime | None,
              log: Callable[[str], None] = print) -> dict[str, Any]:
    """WARM (a snapshot's) with the artifacts uploaded since folded in, for pr_runner_pool.py.

    The janitor folds at most MAX_NEW per sweep and sweeps every 10 to 45
    minutes, so a snapshot's `warm` misses the builds kept since. This reads
    the listing (one request) and folds the LIVE_MAX_NEW newest artifacts
    past `through`, each checked as the janitor checks it (its run's jobs and
    its download: two requests). An older one left out waits for the janitor,
    which advances `through` past it. Nothing is listed when the snapshot is
    under LIVE_MIN_AGE_SECONDS old. Any failure keeps WARM as it is.
    """
    if generated_at is not None and (now - generated_at).total_seconds() < LIVE_MIN_AGE_SECONDS:
        return dict(warm)
    try:
        listed = client.get(f"/actions/artifacts?name={ARTIFACT_NAME}&per_page=100").get("artifacts") or []
    except (OSError, ValueError, RuntimeError) as error:
        log(f"owned warm state: live listing failed ({type(error).__name__}); using the snapshot's")
        return dict(warm)
    fresh = new_artifacts({"through": through_of(warm)}, listed)
    newest = sorted(fresh, key=lambda artifact: artifact["id"], reverse=True)[:LIVE_MAX_NEW]
    folded: list[tuple[Mapping[str, Any], tuple | str]] = []
    for artifact in sorted(newest, key=lambda artifact: artifact["id"]):
        run_id = int((artifact.get("workflow_run") or {}).get("id") or 0)
        try:
            folded.append((artifact, read(client, artifact, None, run_id)))
        except Transient as error:
            log(f"owned warm state: live run {run_id} artifact {artifact['id']}: {error}")
            break
    # `through` stays the snapshot's: the janitor still folds the older ones this skipped.
    result = fold(warm, folded, now)
    result["through"] = through_of(warm)
    result["live"] = {"folded": len(folded), "pending": max(0, len(fresh) - len(folded))}
    return result
