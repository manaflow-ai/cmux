#!/usr/bin/env python3
"""No guard under tests/ reads a job's runs-on, environment, env or secrets raw: it reads them through
tests/workflow_jobs.py (resolve, runs_on_cells, environment_values, effective_env, effective_secrets). A guard
that holds self-hosted jobs to a rule picks them with workflow_jobs.may_run_self_hosted; raw runs-on reads
remain confined to workflow_jobs, with its written-text accessor reserved for callers that need that form.

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

Every name a file under tests/ or scripts/ takes from workflow_jobs (`from workflow_jobs import X`, `workflow_jobs.X`,
a `patch("workflow_jobs.X")` target) must exist in it: a public attribute is removed only with all its callers
(#41133 BLOCK at aa1c6f09: `runs_on` went while two suites still called it).

ALLOWED is for a read that is not a guard's; each entry gives its reason, and an entry that no longer matches a
read fails. It also checks workflow_jobs.UNRESOLVED_MATRICES: an entry whose job is gone, or whose matrix now
resolves, fails.

runs-on has a stricter lint (RawRunsOnReads), because the job heuristic above misses a job reached through a name
it does not know (`build = JOBS.get("build-nightly-deltas")`; #40846 review F1): no Python file under tests/ or
scripts/ci/ reads the key `runs-on` from anything (`X["runs-on"]`, `X.get("runs-on")`, `.pop` / `.setdefault`,
`"runs-on" in X`) outside RUNS_ON_READERS, which is tests/workflow_jobs.py and may only shrink. scripts/ci/ is in
scope because it is CI-run code: a hand parse there misroutes jobs the same way. Read runs_on_cells, runs_on_values or
single_runs_on instead; a fixture keeps the route it writes in a local. Writes and dict-literal keys are not reads.
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
    ("test_ci_job_list_fixture_mutations.py", "job.get('environment')"):
        "PreFixReader models the pre-fix literal environment read",
    ("test_ci_job_list_fixture_mutations.py", "{**job}"):
        "_plain_copy models the pre-fix job copy, which drops the workflow env, to show copy_job is needed",
    # Not workflow jobs: GitHub API job records and other dicts a test happens to name `job` or iterate as jobs.
    ("test_base_red_excuse.py", "dict(job, run_attempt=number)"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job",
    ("test_base_red_excuse.py", "{k: v for k, v in job.items() if k != 'run_id'}"): "a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job",
    ('test_base_red_excuse.py', 'dict(base_job, id=2, run_id=20, head_sha=BASE_SHA)'):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', "dict(github.jobs[2], conclusion='success', steps=[dict(step, conclusion='success' if step['name'] == PrOnlyStepGitHub.LIVE else step['conclusion']) for step in github.jobs[2]['steps']])"):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', "dict(job, conclusion='success')"):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', 'dict(job, id=1, run_id=10, head_sha=HEAD)'):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', "dict(job, id=2, run_id=20, head_sha=BASE_SHA, conclusion='success', steps=green)"):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', "dict(self.gh.jobs[2], conclusion='success', steps=[dict(step, conclusion='success') for step in self.gh.jobs[2]['steps']])"):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', 'dict(self.gh.jobs[1], steps=framed_steps(steps))'):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', 'dict(job)'):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job' + " (the fake GitHub's jobs listing)",
    ('test_base_red_excuse.py', 'dict(job, name=name)'):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', "dict(self.gh.jobs[2], steps=[{'number': 1, 'name': 'Set up job', 'status': 'completed', 'conclusion': 'success', 'started_at': '2026-10-30T23:15:20Z', 'completed_at': '2026-10-30T23:15:30Z'}, {'number': 2, 'name': 'swift test (macOS)', 'status': 'completed', 'conclusion': 'success', 'started_at': '2026-10-30T23:15:31Z', 'completed_at': '2026-10-30T23:16:37Z'}, {'number': 3, 'name': self.STEP, 'status': 'completed', 'conclusion': 'failure', 'started_at': '2026-10-30T23:16:38Z', 'completed_at': '2026-10-30T23:29:27Z'}, {'number': 4, 'name': 'Complete job', 'status': 'completed', 'conclusion': 'success', 'started_at': '2026-10-30T23:29:27Z', 'completed_at': '2026-10-30T23:29:27Z'}])"):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
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
    ('test_base_red_excuse.py', "dict(self.gh.jobs[2], steps=[{'number': 1, 'name': 'Set up job', 'status': 'completed', 'conclusion': 'success', 'started_at': '2026-10-30T23:15:20Z', 'completed_at': '2026-10-30T23:15:30Z'}, {'number': 2, 'name': 'swift test (macOS)', 'status': 'completed', 'conclusion': 'success', 'started_at': '2026-10-30T23:15:31Z', 'completed_at': '2026-10-30T23:16:37Z'}, {'number': 3, 'name': self.STEP, 'status': 'completed', 'conclusion': 'failure', 'started_at': '2026-10-30T23:16:38Z', 'completed_at': '2026-10-30T23:29:27Z'}, {'number': 4, 'name': 'Complete job', 'status': 'completed', 'conclusion': 'success', 'started_at': '2026-10-30T23:29:27Z', 'completed_at': '2026-10-30T23:29:27Z'}])"):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', "dict(github.jobs[2], conclusion='success', steps=[dict(step, conclusion='success' if step['name'] == PrOnlyStepGitHub.LIVE else step['conclusion']) for step in github.jobs[2]['steps']])"):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', "dict(job, conclusion='success')"):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', 'dict(base_job, id=2, run_id=20, head_sha=BASE_SHA)'):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', 'dict(job, id=1, run_id=10, head_sha=HEAD)'):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', "dict(job, id=2, run_id=20, head_sha=BASE_SHA, conclusion='success', steps=green)"):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
    ('test_base_red_excuse.py', 'dict(job, name=name)'):
        'a GitHub REST API job record (name, conclusion, run_attempt), not a workflow job',
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


# The files (relative to the repository root) allowed to read runs-on raw. It may only shrink: RUNS_ON_READERS_CEILING
# is the set it started as.
RUNS_ON_READERS = frozenset({"tests/workflow_jobs.py"})
RUNS_ON_READERS_CEILING = frozenset({"tests/workflow_jobs.py"})
RUNS_ON = "runs-on"
_KEY_METHODS = frozenset({"get", "pop", "setdefault"})


def raw_runs_on_reads(source: str) -> list[tuple[int, str]]:
    """(line, the read as written) for every read of the key runs-on, from any object, in one file's source."""
    found: list[tuple[int, str]] = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Load) \
                and isinstance(node.slice, ast.Constant) and node.slice.value == RUNS_ON:
            found.append((node.lineno, _text(node)))
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in _KEY_METHODS \
                and node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value == RUNS_ON:
            found.append((node.lineno, _text(node)))
        elif isinstance(node, ast.Compare) and isinstance(node.left, ast.Constant) and node.left.value == RUNS_ON \
                and isinstance(node.ops[0], (ast.In, ast.NotIn)):
            found.append((node.lineno, _text(node)))
    return sorted(set(found))


def runs_on_files() -> list[Path]:
    """Every Python file the runs-on lint reads: tests/ and scripts/ci/, the CI-run code that routes jobs."""
    ci = ROOT / "scripts" / "ci"
    return [*python_files(), *sorted(path for path in ci.rglob("*.py") if "__pycache__" not in path.parts)]


def runs_on_failures(files: Iterable[Path]) -> list[str]:
    out = []
    reading = set()
    for path in files:
        name = path.relative_to(ROOT).as_posix()
        reads = raw_runs_on_reads(path.read_text(encoding="utf-8"))
        if reads:
            reading.add(name)
        if name in RUNS_ON_READERS:
            continue
        out += [f"{name}:{line}: reads runs-on raw: {read} (read workflow_jobs.runs_on_cells, runs_on_values "
                f"or single_runs_on, which expand the matrix and refuse what they cannot resolve)"
                for line, read in reads]
    out += [f"RUNS_ON_READERS entry reads no runs-on any more; drop it: {name}"
            for name in sorted(RUNS_ON_READERS - reading)]
    out += [f"RUNS_ON_READERS may only shrink; {name} is new" for name in sorted(RUNS_ON_READERS - RUNS_ON_READERS_CEILING)]
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


PATCH_TARGET = re.compile(r"^workflow_jobs\.([A-Za-z_][A-Za-z0-9_]*)$")


def module_names(source: str) -> list[tuple[int, str]]:
    """Every name SOURCE takes from workflow_jobs, by line: `from workflow_jobs import X`, a load of `M.X` where
    `import workflow_jobs [as M]` binds M, and a `patch("workflow_jobs.X")` target. A name bound otherwise (a local
    `workflow_jobs = jobs(...)` dict) is not the module and is not read."""
    tree = ast.parse(source)
    aliases: set[str] = set()
    found: list[tuple[int, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            aliases |= {alias.asname or alias.name for alias in node.names if alias.name == "workflow_jobs"}
        elif isinstance(node, ast.ImportFrom) and node.module == "workflow_jobs" and not node.level:
            found += [(node.lineno, alias.name) for alias in node.names if alias.name != "*"]
    def shadowed(scope: ast.AST) -> set[str]:
        """The aliases a function or lambda binds itself (an argument or an assignment), where they are not the module."""
        names = {arg.arg for arg in ast.walk(scope.args) if isinstance(arg, ast.arg)}
        names |= {node.id for node in ast.walk(scope) if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store)}
        return names & aliases

    def visit(node: ast.AST, live: set[str]) -> None:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            live = live - shadowed(node)
        if (isinstance(node, ast.Attribute) and isinstance(node.ctx, ast.Load) and isinstance(node.value, ast.Name)
                and node.value.id in live):
            found.append((node.lineno, node.attr))
        for child in ast.iter_child_nodes(node):
            visit(child, live)

    visit(tree, aliases)
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and _text(node.func).split(".")[-1].startswith("patch"):
            for arg in node.args[:1]:
                match = PATCH_TARGET.match(arg.value) if isinstance(arg, ast.Constant) and isinstance(arg.value, str) else None
                if match:
                    found.append((node.lineno, match.group(1)))
    return sorted(set(found))


def caller_files() -> list[Path]:
    """Every Python file under tests/ and scripts/ but workflow_jobs.py itself."""
    return sorted(path for base in (TESTS, ROOT / "scripts") for path in base.rglob("*.py")
                  if "__pycache__" not in path.parts and path != TESTS / "workflow_jobs.py")


def missing_names(files: Iterable[Path], module: object = workflow_jobs) -> list[str]:
    """A name a file takes from workflow_jobs that the module lacks: removing a public attribute without migrating
    every caller (#41133 BLOCK at aa1c6f09: `runs_on` went, two suites still called it)."""
    out = []
    for path in files:
        source = path.read_text(encoding="utf-8")
        if "workflow_jobs" not in source:
            continue
        for line, name in module_names(source):
            if not hasattr(module, name):
                out.append(f"{path.relative_to(ROOT).as_posix()}:{line}: workflow_jobs has no {name!r}")
    return out


class GuardsReadThroughWorkflowJobs(unittest.TestCase):
    def test_no_guard_reads_a_job_field_raw(self) -> None:
        self.assertEqual(failures(tree_reads(python_files())), [])

    def test_every_name_a_caller_takes_from_workflow_jobs_exists(self) -> None:
        files = caller_files()
        self.assertGreater(sum("workflow_jobs" in path.read_text(encoding="utf-8") for path in files), 50)
        self.assertEqual(missing_names(files), [])

    def test_a_missing_workflow_jobs_name_is_named(self) -> None:
        source = (
            "import workflow_jobs\nimport workflow_jobs as wj\nfrom workflow_jobs import holds_secret, gone_a\n"
            "workflow_jobs.runs_on_cells(job)\nworkflow_jobs.gone_b(job)\nwj.gone_c\n"
            "patch('workflow_jobs.gone_d')\npatch.object(workflow_jobs, 'x')\n"
            "def f():\n    workflow_jobs = jobs(p)\n    return workflow_jobs.items()\n"
        )
        self.assertEqual([(line, name) for line, name in module_names(source) if not hasattr(workflow_jobs, name)],
                         [(3, "gone_a"), (5, "gone_b"), (6, "gone_c"), (7, "gone_d")])

    def test_runs_on_is_named_against_a_module_without_it(self) -> None:
        # The #41133 BLOCK at aa1c6f09: workflow_jobs.runs_on was removed while two suites still called it.
        source = "import workflow_jobs\nworkflow_jobs.runs_on(job)\nworkflow_jobs.runs_on_cells(job)\n"
        without_runs_on = type("WithoutRunsOn", (), {"runs_on_cells": object()})
        self.assertEqual([name for _, name in module_names(source) if not hasattr(without_runs_on, name)], ["runs_on"])

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

    def test_no_file_but_workflow_jobs_reads_runs_on_raw(self) -> None:
        found = runs_on_failures(runs_on_files())
        self.assertEqual(found, [], "\n" + "\n".join(found))

    def test_a_raw_runs_on_read_from_any_name_is_named(self) -> None:
        # #40846 F1: `build` came from `JOBS.get(...)`, a name the job heuristic does not know.
        source = (
            "build = JOBS.get('build-nightly-deltas')\nok = 'x' in str(build.get('runs-on'))\n"
            "route = DOC['jobs']['a']['runs-on']\n"
            "merged = {**base, **change}['runs-on']\n"
            "gone = fixture.pop('runs-on')\nhas = 'runs-on' in thing\nkept = row.setdefault('runs-on', '')\n"
        )
        self.assertEqual([line for line, _ in raw_runs_on_reads(source)], [2, 3, 4, 5, 6, 7])

    def test_runs_on_writes_and_fixture_keys_are_not_reads(self) -> None:
        source = (
            "job['runs-on'] = 'x'\n[twin['runs-on']] = cells\nfixture = {'runs-on': route}\n"
            "del job['runs-on']\nworkflow_jobs.single_runs_on(job)\n"
        )
        self.assertEqual(raw_runs_on_reads(source), [])

    def test_the_runs_on_reader_list_only_shrinks(self) -> None:
        self.assertLessEqual(RUNS_ON_READERS, RUNS_ON_READERS_CEILING)
        self.assertEqual(RUNS_ON_READERS_CEILING, frozenset({"tests/workflow_jobs.py"}))

    def test_the_runs_on_lint_reads_scripts_ci(self) -> None:
        names = {path.relative_to(ROOT).as_posix() for path in runs_on_files()}
        self.assertIn("tests/workflow_jobs.py", names)
        self.assertIn("scripts/ci/runner_routing_table.py", names)

    def test_single_runs_on_refuses_what_it_cannot_read_as_one_route(self) -> None:
        self.assertEqual(workflow_jobs.single_runs_on({"runs-on": "ubuntu-24.04"}), "ubuntu-24.04")
        matrix = {"runs-on": "${{ matrix.runner }}", "strategy": {"matrix": {"runner": ["a", "b"]}}}
        unresolved = {"runs-on": "${{ matrix.runner }}", "strategy": {"matrix": "${{ fromJSON(needs.x.outputs.m) }}"}}
        for job in (matrix, unresolved, {}, {"uses": "./.github/workflows/x.yml"}):
            with self.subTest(job=job):
                with self.assertRaises(workflow_jobs.UnresolvedRunsOn):
                    workflow_jobs.single_runs_on(job)

    def test_deciding_mac_jobs_reads_a_matrix_route_per_cell(self) -> None:
        # scripts/ci/deciding_mac_jobs.py has no suite of its own; its runs-on reads moved with this lint. Read as one
        # string, `${{ matrix.os }}` is one unknown label, so a matrix with a Mac cell was "other" and its checks were
        # not counted as Mac checks (coderouter-release.yml's build, relay-publish-npm.yml's smoke).
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import deciding_mac_jobs  # noqa: PLC0415

        def matrix(*values: str) -> dict:
            return {"runs-on": "${{ matrix.os }}", "strategy": {"matrix": {"os": list(values)}}}
        self.assertEqual(deciding_mac_jobs.job_runner_class(matrix("ubuntu-24.04", "macos-15")), "mac")
        self.assertEqual(deciding_mac_jobs.job_runner_class(matrix("blacksmith-4vcpu-ubuntu-2404")), "linux")
        self.assertEqual(deciding_mac_jobs.job_runner_class(
            {"runs-on": "${{ matrix.os }}", "strategy": {"matrix": "${{ fromJSON(needs.a.outputs.m) }}"}}), "other")
        self.assertEqual(deciding_mac_jobs.job_runner_class({"uses": "./.github/workflows/x.yml"}), "other")
        self.assertEqual(deciding_mac_jobs.job_runner_class({"runs-on": "macos-15"}), "mac")

    def test_runs_on_label_cells_keep_a_list_route_a_list(self) -> None:
        job = {"runs-on": ["self-hosted", "${{ matrix.arch }}"], "strategy": {"matrix": {"arch": ["x64", "arm64"]}}}
        self.assertEqual(workflow_jobs.runs_on_label_cells(job), [("self-hosted", "x64"), ("self-hosted", "arm64")])
        self.assertEqual(workflow_jobs.runs_on_cells(job), ["self-hosted, x64", "self-hosted, arm64"])
        self.assertEqual(workflow_jobs.runs_on_items({"runs-on": {"group": "g", "labels": "l"}}), ["l", "g"])

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
