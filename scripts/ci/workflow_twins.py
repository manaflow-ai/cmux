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

Runner labels, not the expression: each branch writes its own clauses around them (feat-cmux-next's fork-PR
fallback, main's vars.CI_OVERFLOW_LINUX), and those are each branch's own; the labels a job lands on are not.
workflow_twins_known_drift.tsv holds the jobs that already differed when this came in; a new one fails.
tests/test_ci_owned_pool_sources.py runs drift() on ci-guards.yml's runs of both branches, against the other
branch's freshly fetched tip; a feat-cmux-next pull request skips that group, so ci/steps.toml's
workflow-twins step runs this file against a scratch checkout of main's workflows.

    workflow_twins.py [--ref REF] --other REF       print each drifted job; exit 1 when there is one
    workflow_twins.py --other-dir DIR --write-known write what differs now to workflow_twins_known_drift.tsv
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
# The twin jobs that already differed when this guard came in (2026-11-28: 74 jobs of 51 workflows), one
# "PATH<TAB>JOB" per line. The guard fails on a job that newly differs; an entry whose copies agree again is printed
# for removal but fails nothing, so a twin PR on the other branch never turns this one red.
KNOWN_DRIFT = Path(__file__).resolve().parent / "workflow_twins_known_drift.tsv"


def known_drift(path: Path = KNOWN_DRIFT) -> set[tuple[str, str]]:
    if not path.is_file():
        return set()
    rows = (line.split("\t") for line in path.read_text(encoding="utf-8").splitlines())
    return {(row[0], row[1]) for row in rows if len(row) >= 2 and not row[0].startswith("#")}


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


# A quoted literal in a runs-on expression; the ones that are no runner label are dropped below.
LITERAL = re.compile(r"'((?:[^'\\]|\\.)*)'")
LABEL = re.compile(r"[a-z0-9][a-z0-9.-]*")
NOT_A_LABEL = {"manaflow-ai", "1", "0", "on", "off", "true", "false"}


def runs_on(job: dict) -> str:
    """The runner labels a job can take, sorted: each quoted literal of its runs-on expression that is a label.

    Each branch writes its own guard clauses around the labels (feat-cmux-next's fork-PR clause, main's
    vars.CI_OVERFLOW_LINUX, a RUNNER_POOLS allowlist): those are each branch's own. What one workflow must agree on is
    the labels it lands on: cmux#63743 is 'cmux-linux' against 'cmux-gcp-secret-jit-x64'."""
    value = job.get("runs-on", "")
    if not isinstance(value, str):
        import yaml  # noqa: PLC0415 - as tests/workflow_jobs.py runs_on

        value = yaml.safe_dump(value, default_flow_style=True)
    value = " ".join(value.split())
    if "${{" not in value:
        return value
    labels = {text for text in LITERAL.findall(value) if LABEL.fullmatch(text) and text not in NOT_A_LABEL}
    return " ".join(sorted(labels))


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


def differing(here: sources.Tree, other: sources.Tree) -> dict[tuple[str, str], str]:
    """{(path, job): what differs} for each twin job whose runner labels or token floor differ between the copies."""
    found = {}
    for path, (mine, theirs) in twins(here, other).items():
        jobs, others = _jobs(mine), _jobs(theirs)
        for key in sorted(jobs):
            a, b = shape(jobs[key]), shape(others[key])
            fields = [field for field in a if a[field] != b[field]]
            if fields:
                found[(path, key)] = "; ".join(f"{field}: {a[field]!r} in {here}, {b[field]!r} in {other}"
                                              for field in fields)
    return found


def drift(here: sources.Tree, other: sources.Tree, known: set[tuple[str, str]] | None = None) -> list[str]:
    """One line for each twin job that differs between the copies and is not in KNOWN_DRIFT."""
    known = known_drift() if known is None else known
    return [f"{path} job {key}: {said}" for (path, key), said in differing(here, other).items()
            if (path, key) not in known]


def agreed(here: sources.Tree, other: sources.Tree, known: set[tuple[str, str]] | None = None) -> list[str]:
    """KNOWN_DRIFT entries whose copies agree again (or are no twin): each a row to delete."""
    known = known_drift() if known is None else known
    now = differing(here, other)
    return [f"{path}\t{key}" for path, key in sorted(known) if (path, key) not in now]


HINT = ("A workflow on both main and feat-cmux-next is one workflow: make the other branch's copy take the same runner "
        "labels and token floor in a pull request to it (a twin PR). A job's runner is each branch's own only in the "
        "clauses around the labels (a fork-PR fallback, an overflow variable), never in the labels it lands on.")


KNOWN_HEADER = ("# Twin jobs whose runner labels or GITHUB_TOKEN floor differ between main and feat-cmux-next,\n"
                "# written by scripts/ci/workflow_twins.py --write-known. Each is drift to fix with a twin PR; a row\n"
                "# leaves when its copies agree. A new difference fails the guard and never comes here.\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ref", help="this side's git ref (default: the working tree)")
    other = parser.add_mutually_exclusive_group(required=True)
    other.add_argument("--other", help="the other branch's git ref, e.g. origin/main")
    other.add_argument("--other-dir", type=Path, help="a checkout of the other branch (its .github/workflows)")
    parser.add_argument("--write-known", action="store_true",
                        help=f"write every job that differs now to {KNOWN_DRIFT.name} (shrink it, never grow it)")
    args = parser.parse_args(argv)
    theirs = sources.Tree(args.other_dir) if args.other_dir else sources.Tree(ROOT, args.other)
    if not theirs.workflows():
        print(f"workflow twins: {theirs} holds no workflows, so nothing was compared", file=sys.stderr)
        return 2
    ours = sources.Tree(ROOT, args.ref)
    if args.write_known:
        rows = sorted(differing(ours, theirs))
        KNOWN_DRIFT.write_text(KNOWN_HEADER + "".join(f"{path}\t{key}\n" for path, key in rows), encoding="utf-8")
        print(f"workflow twins: wrote {len(rows)} known drifted jobs to {KNOWN_DRIFT.relative_to(ROOT)}")
        return 0
    for row in agreed(ours, theirs):
        print(f"::notice::workflow twins: {row.replace(chr(9), ' job ')} agrees again; delete its row in "
              f"{KNOWN_DRIFT.relative_to(ROOT)}")
    lines = drift(ours, theirs)
    for line in lines:
        print(line)
    if lines:
        print(HINT, file=sys.stderr)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main())
