#!/usr/bin/env python3
"""A `workflow_run` trigger spells a display name; pin it to the file behind it.

`on.workflow_run.workflows:` matches the triggering workflow's `name:`. That
name is presentation text. Renaming a workflow for clarity stops every consumer
of it from triggering, and nothing turns red: the consumer simply never runs
again. `merge-group-fail-fast.yml` is the expensive version of that failure --
it cancels a merge group's CI run at the first failed job, so when it stops
firing every queue entry behind a doomed one burns full runner time instead.

The Actions API does carry stable identity. A workflow run object has `path`
(`.github/workflows/ci.yml`) and `workflow_id` next to the presentation `name`,
and a run can be located by file path through
`repos/:owner/:repo/actions/workflows/<file>/runs`. The trigger filter accepts
neither, so the name has to stay in the trigger. What changes is that the name
stops being the only copy: each consumer declares the file it means in
`env.SOURCE_WORKFLOW_PATHS`, and this test derives the expected names from
those files. Renaming a producer now fails this test on the pull request that
renames it.

Matching a *job* by display name has no stable alternative at all: the jobs API
reports `name` and never the YAML job id. Those matches are listed below so the
same derivation applies to them. The one in `update-homebrew.yml` is already
pinned by `tests/test_release_homebrew_gate.py` and is not repeated here.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# The declaration a `workflow_run` consumer carries: the workflow files whose
# `name:` its `workflows:` filter spells out, space separated.
DECLARATION = "SOURCE_WORKFLOW_PATHS"

# Consumers that match a job by display name. Each entry is
# (consumer, producer, job id); the expected display name is derived from the
# producer's job rather than written out a second time here.
PINNED_JOB_NAMES = (
    (
        ".github/workflows/ios-testflight.yml",
        ".github/workflows/ios-testflight.yml",
        "upload",
    ),
    # The persistent-pool rescue waits for the job that runs the pool picker.
    (
        "scripts/ci/owned_pool_rescue.py",
        ".github/workflows/ci.yml",
        "changes",
    ),
    # ... and, for an E2E run, the job that runs e2e_runner_pool.py.
    (
        "scripts/ci/owned_pool_rescue.py",
        ".github/workflows/test-e2e.yml",
        "runner",
    ),
    # ... and, for an iOS dispatch, the job that runs ios_runner_pool.py.
    (
        "scripts/ci/owned_pool_rescue.py",
        ".github/workflows/test-ios.yml",
        "runner",
    ),
    (
        "scripts/ci/owned_pool_rescue.py",
        ".github/workflows/ios-screenshots.yml",
        "runner",
    ),
)

# The fail-fast watcher is started by a display name but must not act on one.
# Display names are not unique, and the run object that arrives here carries
# the stable path, so it can confirm what woke it before it cancels anything.
IDENTITY_CHECKED = ".github/workflows/merge-group-fail-fast.yml"

# `repos/:owner/:repo/actions/workflows/<file>/runs` is the identity-based way
# to find another workflow's runs. The file still has to exist.
RUNS_BY_PATH = re.compile(r"actions/workflows/([A-Za-z0-9._-]+\.ya?ml)/runs")


def load(path: Path) -> dict:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    return document if isinstance(document, dict) else {}


def triggers(document: dict) -> dict:
    # PyYAML reads the bare key `on` as boolean True.
    on = document.get("on", document.get(True))
    return on if isinstance(on, dict) else {}


def display_name(path: Path, document: dict) -> str:
    name = document.get("name")
    # A workflow without `name:` is listed, and matched, by its path.
    return str(name) if name is not None else path.relative_to(ROOT).as_posix()


def as_list(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def check_workflow_run_sources(documents: dict[Path, dict], failures: list[str]) -> None:
    for path, document in documents.items():
        workflow_run = triggers(document).get("workflow_run")
        if not isinstance(workflow_run, dict):
            continue
        relative = path.relative_to(ROOT).as_posix()
        named = as_list(workflow_run.get("workflows"))
        environment = document.get("env")
        declared = str((environment or {}).get(DECLARATION, "")).split()

        if not declared:
            failures.append(
                f"{relative}: triggers on the display names {sorted(named)} and "
                f"declares no {DECLARATION}, so renaming any of those workflows "
                "stops this one from ever triggering and nothing reports it"
            )
            continue

        produced: list[str] = []
        for source in declared:
            source_path = ROOT / source
            if source_path not in documents:
                failures.append(
                    f"{relative}: {DECLARATION} names {source}, which is not a "
                    "workflow in .github/workflows"
                )
                continue
            produced.append(display_name(source_path, documents[source_path]))

        if sorted(produced) != sorted(named):
            failures.append(
                f"{relative}: the trigger matches {sorted(named)} but "
                f"{DECLARATION} resolves to {sorted(produced)}; the workflows "
                "this one means no longer carry the names it waits for"
            )


def check_pinned_job_names(documents: dict[Path, dict], failures: list[str]) -> None:
    for consumer, producer, job_id in PINNED_JOB_NAMES:
        producer_jobs = documents.get(ROOT / producer, {}).get("jobs") or {}
        job = producer_jobs.get(job_id)
        if not isinstance(job, dict):
            failures.append(
                f"{consumer}: matches a job of {producer} that no longer exists: {job_id}"
            )
            continue
        # The API name is the mapping key unless `name:` overrides it.
        name = str(job.get("name", job_id))
        text = (ROOT / consumer).read_text(encoding="utf-8")
        if f'"{name}"' not in text and f"'{name}'" not in text:
            failures.append(
                f"{consumer}: no longer matches {producer}'s {job_id} job, whose "
                f"display name is now {name!r}"
            )


def check_runs_lookups_by_path(documents: dict[Path, dict], failures: list[str]) -> None:
    known = {path.name for path in documents}
    for path in documents:
        text = path.read_text(encoding="utf-8")
        for filename in sorted(set(RUNS_BY_PATH.findall(text))):
            if filename not in known:
                failures.append(
                    f"{path.relative_to(ROOT).as_posix()}: looks up runs of "
                    f"{filename}, which is not a workflow in .github/workflows"
                )


def check_identity_before_acting(failures: list[str]) -> None:
    watcher = (ROOT / IDENTITY_CHECKED).read_text(encoding="utf-8")
    if "github.event.workflow_run.path" not in watcher or f"${DECLARATION}" not in watcher:
        failures.append(
            f"{IDENTITY_CHECKED}: must compare github.event.workflow_run.path "
            f"against {DECLARATION} before it cancels anything, so a workflow "
            "that merely shares a display name cannot drive it"
        )


def main() -> int:
    paths = sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")])
    documents = {path: load(path) for path in paths}

    failures: list[str] = []
    check_workflow_run_sources(documents, failures)
    check_pinned_job_names(documents, failures)
    check_runs_lookups_by_path(documents, failures)
    check_identity_before_acting(failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print(f"PASS: {len(documents)} workflows match the workflows they name by file, not by display text")
    return 0


if __name__ == "__main__":
    sys.exit(main())
