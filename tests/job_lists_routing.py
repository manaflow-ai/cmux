"""Job sets the routing guards read from the workflows instead of keeping by hand.

Used by tests/test_ci_fork_runner_routing.py and tests/test_publish_app_token_workflow.py.
A hand-kept job list misses the job someone splits out or adds later, and that job then
escapes the check (#36559's deploy-dashboard-staging escaped BACKEND_SECRET_JOBS that way).
These readers give each guard the set of jobs that has the trait its list is about, so a
job with the trait is either derived into the list or must be classified by name.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
NIGHTLY = WORKFLOWS / "nightly.yml"

# The environments that hold the release credentials (CMUX_RELEASE_APP_ID/_KEY, signing).
RELEASE_ENVIRONMENT_NAMES = frozenset({"release", "release-next"})
# nightly.yml's decide job sets this output to 'release' or 'release-next'.
RELEASE_ENVIRONMENT_OUTPUT = re.compile(r"\bneeds\.decide\.outputs\.environment\b")
QUOTED = re.compile(r"'([^']*)'")


def load_jobs(text: str) -> dict[str, dict[str, Any]]:
    """A workflow's jobs, with YAML aliases resolved (nightly.yml shares steps by alias)."""
    return (yaml.safe_load(text) or {}).get("jobs") or {}


def environment_values(job: Mapping[str, Any]) -> set[str]:
    """Every environment name a job's `environment:` can resolve to."""
    env = job.get("environment")
    if isinstance(env, Mapping):
        env = env.get("name")
    if not env:
        return set()
    env = str(env).strip()
    if "${{" not in env:
        return {env}
    values = set(QUOTED.findall(env))
    if RELEASE_ENVIRONMENT_OUTPUT.search(env):
        values |= RELEASE_ENVIRONMENT_NAMES
    return values


def release_environment_jobs(jobs: Mapping[str, Mapping[str, Any]]) -> set[str]:
    """Jobs that can run under a release environment, so they can read its secrets."""
    return {name for name, job in jobs.items() if environment_values(job) & RELEASE_ENVIRONMENT_NAMES}


def required_checks() -> tuple[str, ...]:
    """The required status contexts on main, from the mirror required-checks-drift.yml keeps honest."""
    path = ROOT / "scripts/ci/required_status_checks.py"
    spec = importlib.util.spec_from_file_location("required_status_checks", path)
    assert spec is not None and spec.loader is not None
    module = sys.modules.get("required_status_checks")
    if module is None:
        module = importlib.util.module_from_spec(spec)
        # Registered before execution: its dataclasses resolve types through sys.modules.
        sys.modules["required_status_checks"] = module
        spec.loader.exec_module(module)
    return tuple(module.REQUIRED_CHECKS)


def _needs(job: Mapping[str, Any]) -> list[str]:
    needs = job.get("needs") or []
    return [needs] if isinstance(needs, str) else [str(n) for n in needs]


def merge_gating_jobs(workflow_texts: Mapping[str, str], contexts: Iterable[str]) -> set[tuple[str, str]]:
    """(workflow, job) for every job that reports a required context, plus every job it needs:
    a needed job that cannot start leaves the required context unreported."""
    contexts = set(contexts)
    found: set[tuple[str, str]] = set()
    for workflow, text in workflow_texts.items():
        jobs = load_jobs(text)
        pending = [name for name, job in jobs.items() if str(job.get("name", name)) in contexts]
        while pending:
            name = pending.pop()
            if (workflow, name) in found or name not in jobs:
                continue
            found.add((workflow, name))
            pending.extend(_needs(jobs[name]))
    return found


def workflow_texts() -> dict[str, str]:
    return {path.name: path.read_text(encoding="utf-8") for path in sorted(WORKFLOWS.glob("*.y*ml"))}
