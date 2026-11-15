"""Job sets the routing guards read from the workflows instead of keeping by hand.

Used by tests/test_ci_fork_runner_routing.py and tests/test_publish_app_token_workflow.py.
A hand-kept job list misses the job someone splits out or adds later, and that job then
escapes the check (#36559's deploy-dashboard-staging escaped BACKEND_SECRET_JOBS that way).
These readers give each guard the set of jobs that has the trait its list is about, so a
job with the trait is either derived into the list or must be classified by name.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

import workflow_jobs
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import gh_expressions  # noqa: E402  (finds each ${{ }}: a regex cuts at a }} in a string)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
NIGHTLY = WORKFLOWS / "nightly.yml"

# The environments that hold the release credentials (CMUX_RELEASE_APP_ID/_KEY, signing).
RELEASE_ENVIRONMENT_NAMES = frozenset({"release", "release-next"})
# nightly.yml's decide job sets this output to 'release' or 'release-next'.
RELEASE_ENVIRONMENT_OUTPUT = re.compile(r"\bneeds\.decide\.outputs\.environment\b")


def environment_values(job: Mapping[str, Any]) -> tuple[set[str], set[str]]:
    """Every environment name a job's `environment:` can resolve to, and the parts that cannot be
    resolved. workflow_jobs expands matrix values and reads an expression's literal branches; the
    one extra resolution here is nightly.yml's decide output, which is 'release' or 'release-next'."""
    values, unresolved = workflow_jobs.environment_values(job)
    remaining = set()
    for term in unresolved:
        if RELEASE_ENVIRONMENT_OUTPUT.fullmatch(term.strip()):
            values |= RELEASE_ENVIRONMENT_NAMES
        else:
            remaining.add(term)
    return values, remaining


def release_environment_jobs(jobs: Mapping[str, Mapping[str, Any]]) -> set[str]:
    """Jobs that can run under a release environment, so they can read its secrets."""
    return {name for name, job in jobs.items() if environment_values(job)[0] & RELEASE_ENVIRONMENT_NAMES}


def unresolved_environment_jobs(jobs: Mapping[str, Mapping[str, Any]]) -> set[str]:
    """Jobs whose environment has a part nothing here can resolve (`${{ inputs.env }}`, a matrix
    from fromJSON). They may be release jobs, so a guard counts them unclassified."""
    return {name for name, job in jobs.items() if environment_values(job)[1]}


def required_checks() -> tuple[str, ...]:
    """The required status contexts on main, from the mirror required-checks-drift.yml keeps honest."""
    # By name (scripts/ci is on sys.path above), as the other tests import it: one module object per file
    # (tests/test_script_module_loads.py).
    import required_status_checks  # noqa: PLC0415
    return tuple(required_status_checks.REQUIRED_CHECKS)


def _needs(job: Mapping[str, Any]) -> list[str]:
    needs = job.get("needs") or []
    return [needs] if isinstance(needs, str) else [str(n) for n in needs]


def _name_patterns(job: Mapping[str, Any], job_id: str) -> tuple[set[str], list[re.Pattern]]:
    """The names a job can report (workflow_jobs.name_values) and, for each part nothing resolves, a pattern of
    the names it could still report (each `${{ }}` it holds is any text; a whole unresolved expression is any
    name)."""
    values, unresolved = workflow_jobs.name_values(job, job_id)
    patterns = []
    for part in unresolved:
        if "${{" not in part:
            patterns.append(re.compile(r".*", re.DOTALL))
            continue
        pieces = gh_expressions.EXPRESSION.split(part)[::2]
        patterns.append(re.compile(".*".join(re.escape(piece) for piece in pieces), re.DOTALL))
    return values, patterns


def unresolved_name_jobs(workflow_texts: Mapping[str, str], contexts: Iterable[str]) -> set[tuple[str, str]]:
    """(workflow, job) for every job that reports a required context only if a name part nothing resolves takes
    a certain value (`name: ${{ inputs.check }}`, `name: ${{ needs.x.outputs.y || 'report' }}`)."""
    contexts = set(contexts)
    found = set()
    for workflow, text in workflow_texts.items():
        for name, job in workflow_jobs.jobs(text).items():
            values, patterns = _name_patterns(job, name)
            if not values & contexts and any(p.fullmatch(c) for p in patterns for c in contexts):
                found.add((workflow, name))
    return found


def merge_gating_jobs(workflow_texts: Mapping[str, str], contexts: Iterable[str],
                      unresolved_exempt: Iterable[tuple[str, str]] = ()) -> set[tuple[str, str]]:
    """(workflow, job) for every job that reports a required context, plus every job it needs:
    a needed job that cannot start leaves the required context unreported. The name is read as GitHub reports
    it (workflow_jobs.name_values: literal expressions read); a job that could report a required context through
    a name part nothing resolves counts too (unresolved_name_jobs), unless `unresolved_exempt` names it."""
    contexts = set(contexts)
    exempt = set(unresolved_exempt)
    found: set[tuple[str, str]] = set()
    for workflow, text in workflow_texts.items():
        jobs = workflow_jobs.jobs(text)
        pending = []
        for name, job in jobs.items():
            values, patterns = _name_patterns(job, name)
            if values & contexts or ((workflow, name) not in exempt
                                     and any(p.fullmatch(c) for p in patterns for c in contexts)):
                pending.append(name)
        while pending:
            name = pending.pop()
            if (workflow, name) in found or name not in jobs:
                continue
            found.add((workflow, name))
            pending.extend(_needs(jobs[name]))
    return found


def workflow_texts() -> dict[str, str]:
    return {path.name: path.read_text(encoding="utf-8") for path in sorted(WORKFLOWS.glob("*.y*ml"))}
