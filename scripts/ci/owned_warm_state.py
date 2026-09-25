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
     "keys": ["<sha12>", ...]}

with the kept build's merge base first.

The queue janitor folds those artifacts into its `macos-pool-load` snapshot
as `warm` (sweep()), and pr_runner_pool.py reads it: when an idle root runner
is warm for a run's merge base, admission's runs-on names that runner's own
static label, `glaeda-runner-<runner name>` (glaeda-cmux-runner gives every
root runner one at install time). Nothing writes a runner label at job time,
so the routing App needs only "Self-hosted runners: Read-only".

    "warm": {"through": <newest artifact id folded>,
             "runners": {"<runner name>": {"keys": ["<sha12>", ...],
                                           "at": "<artifact created_at>"}}}

Each sweep starts from the previous snapshot's `warm` and folds only the
artifacts newer than `through`, oldest first, so a runner's newest admission
replaces what it kept before. Every artifact costs two requests (its run's
jobs, unless the janitor listed them already, and its download), and a sweep
folds at most MAX_NEW. An entry older than MAX_AGE_HOURS is dropped.

The runner is the one the jobs API says ran admission, never the name in the
artifact, which the pull request's own code wrote: an artifact naming another
runner changes nothing, and so does one from a fork's run. A key that is not
12 hex digits is dropped. A wrong key only sends an admission to a Mac whose
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
import zipfile
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
# Keys one runner keeps at most: its kept build's merge base and a few
# commits past it that still build cheaply from it.
MAX_KEYS = 4
# Artifacts folded per sweep; the rest wait for the next one.
MAX_NEW = 12
MAX_AGE_HOURS = 24
def keys(document: Any) -> list[str]:
    """The artifact's valid keys, deduplicated in order, at most MAX_KEYS."""
    raw = document.get("keys") if isinstance(document, Mapping) else None
    found: list[str] = []
    for key in raw if isinstance(raw, list) else []:
        key = warm_key(str(key))
        if key and key not in found:
            found.append(key)
    return found[:MAX_KEYS]


def admission_job(jobs: Sequence[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """The run's compile admission job that ran on a runner, or None."""
    for job in jobs:
        name = str(job.get("name") or "")
        if (name == ADMISSION_JOB or name.endswith(" / " + ADMISSION_JOB)) and job.get("runner_name"):
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
    """The artifacts to fold this sweep, oldest first: newer than `through`, at most the newest MAX_NEW."""
    through = int(previous.get("through") or 0)
    fresh = [artifact for artifact in artifacts
             if isinstance(artifact, Mapping) and not artifact.get("expired")
             and artifact.get("name") == ARTIFACT_NAME and isinstance(artifact.get("id"), int)
             and artifact["id"] > through and same_repository(artifact)]
    return sorted(fresh, key=lambda artifact: artifact["id"])[-MAX_NEW:]


def record(document: Any, jobs: Sequence[Mapping[str, Any]]) -> tuple[str, list[str]] | str:
    """(runner, keys) the artifact proves, or why it proves nothing."""
    if not isinstance(document, Mapping):
        return "the warm keys are not a JSON object"
    job = admission_job(jobs)
    if job is None:
        return "no compile admission job ran on a runner"
    runner = str(job.get("runner_name"))
    if str(document.get("runner") or "") != runner:
        return f"the keys name runner {document.get('runner')!r}, but admission ran on {runner!r}"
    return runner, keys(document)


def fold(previous: Mapping[str, Any], folded: Sequence[tuple[Mapping[str, Any], tuple[str, list[str]] | str]],
         now: dt.datetime) -> dict[str, Any]:
    """`previous` with each (artifact, record) applied in order, entries past MAX_AGE_HOURS dropped."""
    runners: dict[str, Any] = {}
    for name, entry in (previous.get("runners") or {}).items() if isinstance(previous.get("runners"), Mapping) else ():
        if isinstance(entry, Mapping) and isinstance(entry.get("keys"), list):
            runners[str(name)] = {"keys": [key for key in entry["keys"] if warm_key(str(key)) == key][:MAX_KEYS],
                                  "at": str(entry.get("at") or "")}
    through = int(previous.get("through") or 0)
    for artifact, proved in folded:
        through = max(through, int(artifact["id"]))
        if isinstance(proved, tuple):
            runner, found = proved
            runners[runner] = {"keys": found, "at": str(artifact.get("created_at") or "")}
    cutoff = now - dt.timedelta(hours=MAX_AGE_HOURS)
    runners = {name: entry for name, entry in runners.items()
               if entry["keys"] and (parse_time(entry["at"]) or cutoff) > cutoff}
    return {"through": through, "runners": dict(sorted(runners.items()))}


def sweep(client: Any, jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], now: dt.datetime,
          log: Callable[[str], None] = print) -> dict[str, Any]:
    """The snapshot's new `warm`: the previous one plus the artifacts uploaded since.

    `client` is a pr_runner_pool.GitHub (get() and download()). Raises what
    the listing raises; a single artifact that cannot be read is skipped.
    """
    previous = previous_warm(client)
    listed = client.get(f"/actions/artifacts?name={ARTIFACT_NAME}&per_page=100").get("artifacts") or []
    folded: list[tuple[Mapping[str, Any], tuple[str, list[str]] | str]] = []
    for artifact in new_artifacts(previous, listed):
        run_id = int((artifact.get("workflow_run") or {}).get("id") or 0)
        try:
            jobs = jobs_by_run.get(run_id)
            if jobs is None:
                jobs = client.get(f"/actions/runs/{run_id}/jobs?filter=latest&per_page=100").get("jobs") or []
            archive = zipfile.ZipFile(io.BytesIO(client.download(artifact)))
            proved = record(json.loads(archive.read(KEYS_FILE)), jobs)
        except (OSError, ValueError, KeyError, RuntimeError, zipfile.BadZipFile) as error:
            proved = f"unreadable ({type(error).__name__})"
        log(f"owned warm state: run {run_id} artifact {artifact['id']}: "
            + (f"{proved[0]} keeps {', '.join(proved[1]) or 'no keys'}" if isinstance(proved, tuple) else proved))
        folded.append((artifact, proved))
    return fold(previous, folded, now)


def previous_warm(client: Any) -> Mapping[str, Any]:
    """The newest trusted janitor snapshot's `warm`, or {} (then this sweep starts fresh)."""
    listed = client.get(f"/actions/artifacts?name={SNAPSHOT_ARTIFACT}&per_page=20").get("artifacts") or []
    trusted = [artifact for artifact in listed
               if isinstance(artifact, Mapping) and trusted_snapshot_artifact(artifact, SNAPSHOT_BRANCH)]
    if not trusted:
        return {}
    newest = max(trusted, key=lambda artifact: str(artifact.get("created_at") or ""))
    try:
        document = json.loads(zipfile.ZipFile(io.BytesIO(client.download(newest))).read(SNAPSHOT_FILE))
    except (OSError, ValueError, KeyError, RuntimeError, zipfile.BadZipFile):
        return {}
    warm = document.get("warm") if isinstance(document, Mapping) else None
    return warm if isinstance(warm, Mapping) else {}
