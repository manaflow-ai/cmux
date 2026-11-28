#!/usr/bin/env python3
"""A workflow file on both main and feat-cmux-next (a twin) runs each job on the same runner and reads the same
GITHUB_TOKEN floor in both copies.

A schedule, workflow_dispatch or workflow_run fires main's copy of a workflow, and most twins check out
feat-cmux-next's scripts, so the two copies are one workflow that two branches hold. When one copy's runner or token
floor moves and the other's does not, whichever branch's guards hold the old shape go red on it, and a dispatch from
the other branch runs a job that guard was written to prevent. 2026-11-28: cmux#63743 moved main's
ui-proof-stale-sweep.yml to the one-job secret JIT label and gave it the token floor (main's fast guards were red on
both), while feat-cmux-next's copy (from cmux#63625) kept `runs-on: cmux-linux` and no floor; nothing compared them.
scripts/cmux-next/prepush-gate.py's main-twin check compares jobs and crons but drops `runs-on:` lines, and it is a
local hook, so a change made on main or pushed without the hook never met it.

Twins: a path both trees hold whose copies have the same job ids and the same triggers (prepush-gate.py
_twin_identity's rule). main's nightly.yml is classic's build and feat-cmux-next's is NEXT's: other jobs, two
workflows, never compared. For each job of a twin:
- runs-on as written (tests/workflow_jobs.py runs_on), whitespace collapsed;
- the floor: every job_token_floor.py call in its steps' `run:`, by its arguments (the script's path differs by where
  a copy checks it out, so only what follows the script's name counts).

DIFFERENT_ON_PURPOSE names a job whose copies differ by design, with why; an entry that no longer differs fails too,
so the list never goes stale. tests/test_ci_owned_pool_sources.py runs drift() on ci-guards.yml's runs of both
branches, against the other branch's freshly fetched tip; a feat-cmux-next pull request skips that group, so
ci/steps.toml's workflow-twins step runs this file against a scratch checkout of main's workflows.

    workflow_twins.py [--ref REF] --other REF       print each drifted job; exit 1 when there is one
    workflow_twins.py [--ref REF] --other-dir DIR   the same, the other branch's files checked out in DIR
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import owned_pool_sources as sources  # noqa: E402  (Tree: a working tree or a git ref)

FLOOR_CALL = re.compile(r"job_token_floor\.py\b([^\n|;&>]*)")
# {(workflow path, job id): why its two copies differ in runner or floor on purpose}. Each entry must still differ.
DIFFERENT_ON_PURPOSE: dict[tuple[str, str], str] = {}


def _load(text: str | None) -> dict:
    if not text:
        return {}
    try:
        return sources._load(text)
    except Exception:  # noqa: BLE001 - an unparsable copy is actionlint's finding, not a twin
        return {}


def _jobs(document: dict) -> dict[str, dict]:
    jobs = document.get("jobs")
    return {str(key): job for key, job in jobs.items() if isinstance(job, dict)} if isinstance(jobs, dict) else {}


def identity(document: dict) -> tuple[frozenset[str], frozenset[str]]:
    """A workflow's job ids and trigger names: two copies that differ here are two workflows, not one twin."""
    return frozenset(_jobs(document)), frozenset(sources._triggers(document))


def runs_on(job: dict) -> str:
    value = job.get("runs-on", "")
    if not isinstance(value, str):
        import yaml  # noqa: PLC0415 - as tests/workflow_jobs.py runs_on

        value = yaml.safe_dump(value, default_flow_style=True)
    return " ".join(value.split())


def floor(job: dict) -> tuple[str, ...]:
    """The job's job_token_floor.py calls, by their arguments, in step order."""
    calls = []
    for step in job.get("steps") or []:
        if isinstance(step, dict):
            calls += [" ".join(("job_token_floor.py" + args).split()) for args in FLOOR_CALL.findall(
                str(step.get("run") or ""))]
    return tuple(calls)


def shape(job: dict) -> dict[str, object]:
    return {"runs-on": runs_on(job), "floor": floor(job)}


def twins(here: sources.Tree, other: sources.Tree) -> dict[str, tuple[dict, dict]]:
    """{path: (this copy, the other copy)} for every twin: same path, same job ids, same triggers."""
    found = {}
    for path in sorted(set(here.workflows()) & set(other.workflows())):
        mine, theirs = _load(here.read(path)), _load(other.read(path))
        if mine and theirs and identity(mine) == identity(theirs):
            found[path] = (mine, theirs)
    return found


def drift(here: sources.Tree, other: sources.Tree,
          on_purpose: dict[tuple[str, str], str] | None = None) -> list[str]:
    """One line for each twin job whose runner or floor differs between the copies and is not DIFFERENT_ON_PURPOSE,
    and for each DIFFERENT_ON_PURPOSE entry whose copies no longer differ (or are no twin any more)."""
    on_purpose = DIFFERENT_ON_PURPOSE if on_purpose is None else on_purpose
    lines, differing = [], set()
    for path, (mine, theirs) in twins(here, other).items():
        jobs, others = _jobs(mine), _jobs(theirs)
        for key in sorted(jobs):
            a, b = shape(jobs[key]), shape(others[key])
            fields = [field for field in a if a[field] != b[field]]
            if not fields:
                continue
            differing.add((path, key))
            if (path, key) in on_purpose:
                continue
            said = "; ".join(f"{field}: {a[field]!r} in {here}, {b[field]!r} in {other}" for field in fields)
            lines.append(f"{path} job {key}: {said}")
    for (path, key), why in sorted(on_purpose.items()):
        if (path, key) not in differing:
            lines.append(f"{path} job {key}: listed in DIFFERENT_ON_PURPOSE ({why}) but its copies no longer differ "
                         "(or it is no twin); remove the entry")
    return lines


HINT = ("A workflow on both main and feat-cmux-next is one workflow: make the other branch's copy take the same runs-on "
        "and token floor in a pull request to it (a twin PR), or, when the difference is by design, add the job to "
        "DIFFERENT_ON_PURPOSE in scripts/ci/workflow_twins.py with why.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ref", help="this side's git ref (default: the working tree)")
    other = parser.add_mutually_exclusive_group(required=True)
    other.add_argument("--other", help="the other branch's git ref, e.g. origin/main")
    other.add_argument("--other-dir", type=Path, help="a checkout of the other branch (its .github/workflows)")
    args = parser.parse_args(argv)
    theirs = sources.Tree(args.other_dir) if args.other_dir else sources.Tree(ROOT, args.other)
    if not theirs.workflows():
        print(f"workflow twins: {theirs} holds no workflows, so nothing was compared", file=sys.stderr)
        return 2
    lines = drift(sources.Tree(ROOT, args.ref), theirs)
    for line in lines:
        print(line)
    if lines:
        print(HINT, file=sys.stderr)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main())
