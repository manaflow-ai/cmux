#!/usr/bin/env python3
"""No guard under tests/ reads a job's runs-on, environment, env or secrets raw: it reads them through
tests/workflow_jobs.py (resolve, runs_on_cells, environment_values, effective_env, effective_secrets).

A raw read fails open. `job["runs-on"]` is one string, so `${{ matrix.runner }}` hides every cell from a
route guard; `job["environment"]` is compared as written, so `Release` is not `release`; `job["env"]` misses
the workflow-level env every job inherits; `job.get("secrets")` stops at a `secrets: inherit` call. The resolve
step expands, normalizes and follows each of these, and names what it cannot read so the guard fails closed.

The detector parses every Python file under tests/ and names, by file and line:
- a read (`X["key"]`, `X.get("key")`, `"key" in X`) of runs-on, environment, env or secrets where X is a job: a
  loop or comprehension variable over a jobs mapping, a function parameter named `job`, `*_job` or `job_*`, a
  local or attribute named that way, a name bound to a jobs lookup (`build = doc["jobs"]["build"]`), or the
  lookup itself (`doc["jobs"]["build"]["runs-on"]`);
- a copy of a job by `{**job}` or `dict(job)`, which drops the workflow env and document a workflow_jobs.Job
  carries (copy with workflow_jobs.copy_job).
Writes (`job["runs-on"] = ...` in a fixture) are not reads. workflow_jobs.py itself is where the reads live.

ALLOWED is for a read that is not a guard's; each entry gives its reason, and an entry that no longer matches a
read fails. It also checks workflow_jobs.UNRESOLVED_MATRICES: an entry whose job is gone, or whose matrix now
resolves, fails.
"""

from __future__ import annotations

import ast
import re
import sys
import unittest
from collections.abc import Iterable, Iterator
from pathlib import Path

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
sys.path.insert(0, str(TESTS))

import workflow_jobs  # noqa: E402

KEYS = frozenset({"runs-on", "environment", "env", "secrets"})
JOB_NAME = re.compile(r"(?:job|[A-Za-z0-9_]+_job|job_[A-Za-z0-9_]+)")
# A jobs mapping or a lookup in one: `jobs`, `self.jobs`, `doc["jobs"]`, `workflow_jobs.jobs(path)`.
JOBS_SOURCE = re.compile(r"(?:\bjobs\b|\[\s*['\"]jobs['\"]\s*\])")
JOBS_LOOKUP = re.compile(r"(?:\bjobs\b|\[\s*['\"]jobs['\"]\s*\]|\.get\(\s*['\"]jobs['\"][^()]*\)|\bjobs\([^)]*\))"
                         r"\s*(?:\[[^\[\]]+\]|\.get\([^()]*\))$")
# A value read from a job's steps is a step (`place = next(s for s in job["steps"] if ...)`): its env is the step's.
STEPS = re.compile(r"\bsteps\b")

# (file relative to tests/, the read as ast.unparse writes it): reason.
ALLOWED: dict[tuple[str, str], str] = {
    # The pre-fix reader the mutation test patches in: it reads the raw field on purpose, to show a fixture fails
    # without workflow_jobs.
    ("test_ci_job_list_fixture_mutations.py", "job.get('runs-on')"): "PreFixReader models the pre-fix raw runs-on read",
    ("test_ci_job_list_fixture_mutations.py", "job.get('environment')"):
        "PreFixReader models the pre-fix literal environment read",
    ("test_ci_job_list_fixture_mutations.py", "{**job}"):
        "_plain_copy models the pre-fix job copy, which drops the workflow env, to show copy_job is needed",
    # Not workflow jobs: GitHub API job records and other dicts a test happens to name `job` or iterate as jobs.
    ("test_base_red_excuse.py", "dict(job, run_attempt=number)"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job",
    ("test_base_red_excuse.py", "{k: v for k, v in job.items() if k != 'run_id'}"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job",
    ("test_ci_r2_artifact.py", "{**job, 'name': 'macos / ' + job['name']}"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job",
    ("test_ci_timing_readout.py", "dict(j)"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job",
    ("test_nightly_next_pipeline.py", "dict(jobs[0], conclusion=None)"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job",
    ("test_nightly_next_recovery.py", "dict(job)"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job (the republish receipt fixture)",
    ("test_publish_nightly_next_r2.py", "{**self.jobs['jobs'][0], 'conclusion': 'failure'}"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job",
    ("test_publish_nightly_next_r2.py", "{**self.jobs['jobs'][0], 'run_attempt': 2}"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job",
    ("test_test_reds.py", "dict(self.job, steps=[dict(s, status='completed') for s in self.job['steps'][:14]])"):
        "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job (LOST_JOB)",
    ("test_test_reds.py", "dict(self.job, steps=[dict(s, status='completed', conclusion='success') for s in self.job['steps']])"):
        "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job (LOST_JOB)",
    ("test_test_reds.py", "dict(self.job, conclusion='cancelled')"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job (LOST_JOB)",
    ("test_nightly_linux_admission.py", "{**receipt('fleet'), **mutation}"):
        "an admission receipt merged with a mutation; the loop that binds `mutation` builds a runner map per job",
}


def _text(node: ast.AST) -> str:
    try:
        return ast.unparse(node)
    except Exception:  # noqa: BLE001 - an unparseable fragment is no job expression
        return ""


def _target_name(target: ast.AST) -> str | None:
    if isinstance(target, ast.Tuple) and target.elts:
        target = target.elts[-1]
    return target.id if isinstance(target, ast.Name) else None


_SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)


def _scope_nodes(scope: ast.AST) -> Iterator[ast.AST]:
    """Every node of one scope (a module, function, lambda or class body), not those of the scopes inside it, where
    a name of the same spelling is another variable."""
    stack = list(ast.iter_child_nodes(scope))
    while stack:
        node = stack.pop()
        yield node
        if isinstance(node, _SCOPES):
            # The defaults and decorators belong to this scope; the body is its own.
            stack.extend(getattr(node.args, "defaults", []) if hasattr(node, "args") else [])
            continue
        stack.extend(ast.iter_child_nodes(node))


def _job_names(nodes: list[ast.AST]) -> set[str]:
    names: set[str] = set()
    for node in nodes:
        if isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
            source = _text(node.iter)
            if JOBS_SOURCE.search(source) and not STEPS.search(source):
                name = _target_name(node.target)
                if name:
                    names.add(name)
        elif (isinstance(node, ast.Assign) and JOBS_LOOKUP.search(_text(node.value))
              and not STEPS.search(_text(node.value))):
            names.update(t.id for t in node.targets if isinstance(t, ast.Name))
    return names


def _is_job(node: ast.AST, names: set[str]) -> bool:
    if isinstance(node, ast.Name):
        return node.id in names or bool(JOB_NAME.fullmatch(node.id))
    if isinstance(node, ast.Attribute) and JOB_NAME.fullmatch(node.attr):
        return True
    return bool(JOBS_LOOKUP.search(_text(node)))


def _is_one_job(node: ast.AST, names: set[str]) -> bool:
    """_is_job without the `job_*` spelling, which names a mapping of jobs (`job_results`) as often as one job."""
    if isinstance(node, ast.Name) and node.id.startswith("job_") and node.id not in names:
        return False
    return _is_job(node, names)


def _key(node: ast.AST) -> str | None:
    return node.value if isinstance(node, ast.Constant) and node.value in KEYS else None


def raw_reads(source: str) -> list[tuple[int, str]]:
    """(line, the read as written) for every raw job-field read and job copy in one file's source."""
    tree = ast.parse(source)
    found: list[tuple[int, str]] = []
    for scope in [tree, *(node for node in ast.walk(tree) if isinstance(node, _SCOPES))]:
        nodes = list(_scope_nodes(scope))
        found.extend(_scope_reads(nodes, _job_names(nodes)))
    return sorted(set(found))


def _scope_reads(nodes: list[ast.AST], names: set[str]) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []
    for node in nodes:
        if isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Load) and _key(node.slice):
            if _is_job(node.value, names):
                found.append((node.lineno, _text(node)))
        elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "get"
              and node.args and _key(node.args[0]) and _is_job(node.func.value, names)):
            found.append((node.lineno, _text(node)))
        elif (isinstance(node, ast.Compare) and _key(node.left)
              and isinstance(node.ops[0], (ast.In, ast.NotIn)) and _is_job(node.comparators[0], names)):
            found.append((node.lineno, _text(node)))
        elif isinstance(node, ast.Dict) and any(
                key is None and _is_job(value, names) for key, value in zip(node.keys, node.values)):
            found.append((node.lineno, _text(node)))
        elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "dict"
              and len(node.args) == 1 and _is_job(node.args[0], names)):
            found.append((node.lineno, _text(node)))
        elif isinstance(node, ast.DictComp) and any(
                isinstance(gen.iter, ast.Call) and isinstance(gen.iter.func, ast.Attribute)
                and gen.iter.func.attr == "items" and _is_one_job(gen.iter.func.value, names) for gen in node.generators):
            found.append((node.lineno, _text(node)))
    return found


def tree_reads(files: Iterable[Path]) -> list[tuple[str, int, str]]:
    out = []
    for path in files:
        if path.name == "workflow_jobs.py":
            continue
        for line, read in raw_reads(path.read_text(encoding="utf-8")):
            out.append((path.relative_to(TESTS).as_posix(), line, read))
    return out


def python_files() -> list[Path]:
    return sorted(path for path in TESTS.rglob("*.py") if "__pycache__" not in path.parts)


def failures(reads: list[tuple[str, int, str]]) -> list[str]:
    found = {(name, read) for name, _, read in reads}
    out = [f"tests/{name}:{line}: reads a job field raw: {read} (read it through workflow_jobs.resolve)"
           for name, line, read in reads if (name, read) not in ALLOWED]
    out += [f"ALLOWED entry matches no read any more: {entry}" for entry in sorted(set(ALLOWED) - found)]
    return out


def matrix_audit_failures() -> list[str]:
    out = []
    for (workflow, job_id), reason in sorted(workflow_jobs.UNRESOLVED_MATRICES.items()):
        path = ROOT / ".github" / "workflows" / workflow
        if not reason.strip():
            out.append(f"{workflow}#{job_id}: an audited matrix needs its reason")
        if not path.is_file():
            out.append(f"{workflow}#{job_id}: the workflow is gone; drop the entry")
            continue
        job = workflow_jobs.jobs(workflow_jobs.document(path)).get(job_id)
        if job is None:
            out.append(f"{workflow}#{job_id}: the job is gone; drop the entry")
        elif workflow_jobs.runs_on_cells(job) is not None:
            out.append(f"{workflow}#{job_id}: its matrix resolves now; drop the entry")
    return out


class GuardsReadThroughWorkflowJobs(unittest.TestCase):
    def test_no_guard_reads_a_job_field_raw(self) -> None:
        self.assertEqual(failures(tree_reads(python_files())), [])

    def test_every_audited_matrix_is_still_unresolved(self) -> None:
        self.assertEqual(matrix_audit_failures(), [])

    def test_a_raw_read_in_a_guard_is_named(self) -> None:
        source = (
            "def route(job):\n    return job['runs-on']\n"
            "for name, body in doc['jobs'].items():\n    body.get('environment')\n"
            "build = doc['jobs']['build']\nok = 'secrets' in build\n"
            "x = workflow_jobs.jobs(p)['a']['env']\n"
            "copy = {**job, 'steps': []}\nother = dict(job)\n"
            "kept = {k: v for k, v in job.items() if k != 'environment'}\n"
        )
        self.assertEqual([line for line, _ in raw_reads(source)], [2, 4, 6, 7, 8, 9, 10])

    def test_writes_steps_and_resolved_reads_are_not_named(self) -> None:
        source = (
            "job['runs-on'] = 'x'\n"
            "for step in job['steps']:\n    step.get('env')\n"
            "workflow_jobs.resolve(job).env['A']\n"
            "workflow_jobs.copy_job(job, {'steps': []})\n"
            "def other():\n    build = doc['jobs']['build']\n"
            "def step_env():\n    build = next(s for s in steps if s['id'] == 'b')\n    return build['env']\n"
        )
        self.assertEqual(raw_reads(source), [])


if __name__ == "__main__":
    unittest.main()
