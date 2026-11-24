#!/usr/bin/env python3
"""A sparse checkout of scripts/ci helpers carries every helper they import.

Several workflows check out a few scripts/ci/*.py files with
`sparse-checkout` (often at a pinned ref) and run one of them. When a listed
script imports a sibling module the list leaves out, the step dies with
ModuleNotFoundError before it does anything: #34428 pinned fast-checks'
admission helper at 159a7019 without github_spend.py, and every fleet test
dispatch failed in `admit` until #34673 added it.

This test reads each such list, follows the imports of every listed script
(module-level and lazy ones inside functions, through the import graph) and
fails on a sibling module the list does not carry. It checks the working tree
and, when the step pins a full commit, that commit too (fetched at depth 1 in
a shallow clone).
"""

from __future__ import annotations

import ast
import re
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
CI_DIR = "scripts/ci"
SCRIPT = re.compile(r"scripts/ci/(\w+)\.py")
FULL_SHA = re.compile(r"[0-9a-f]{40}")

# Steps whose script imports its siblings from another tree on purpose, never
# from its own sparse checkout: (workflow, pinned ref) -> why.
LOADS_SIBLINGS_ELSEWHERE = {
    ("ci-cloud-overflow-probe.yml", "c736d2e6c1db29305963040992f89f9466630f79"):
        "linux_pool_spill.py runs with --policy-root $GITHUB_WORKSPACE and imports main's modules from there",
}


def sibling_imports(source: str, siblings: set[str]) -> set[str]:
    found: set[str] = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            names = [node.module]
        else:
            continue
        found.update(name.split(".")[0] for name in names if name.split(".")[0] in siblings)
    return found


def working_tree_reader(module: str) -> str | None:
    path = ROOT / CI_DIR / f"{module}.py"
    return path.read_text(encoding="utf-8") if path.exists() else None


def git_reader(ref: str):
    def read(module: str) -> str | None:
        result = subprocess.run(
            ["git", "-C", str(ROOT), "show", f"{ref}:{CI_DIR}/{module}.py"],
            capture_output=True, text=True, check=False,
        )
        return result.stdout if result.returncode == 0 else None
    return read


def git_has_commit(ref: str) -> bool:
    def present() -> bool:
        return subprocess.run(
            ["git", "-C", str(ROOT), "cat-file", "-e", f"{ref}^{{commit}}"],
            capture_output=True, check=False,
        ).returncode == 0
    if present():
        return True
    # CI checkouts are shallow: fetch just the pinned commit (one object set, no tags).
    try:
        subprocess.run(
            ["git", "-C", str(ROOT), "fetch", "--quiet", "--depth=1", "--no-tags", "origin", ref],
            capture_output=True, check=False, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if present():
        return True
    print(f"notice: pinned {ref[:12]} is not fetchable here; checked the working tree only")
    return False


def git_siblings(ref: str) -> set[str]:
    result = subprocess.run(
        ["git", "-C", str(ROOT), "ls-tree", "--name-only", f"{ref}:{CI_DIR}"],
        capture_output=True, text=True, check=False,
    )
    return {Path(name).stem for name in result.stdout.split() if name.endswith(".py")}


def missing_imports(listed: set[str], read, siblings: set[str]) -> set[str]:
    """Sibling modules reachable from the listed scripts that the list leaves out."""
    seen: set[str] = set()
    todo = list(listed)
    while todo:
        module = todo.pop()
        if module in seen:
            continue
        seen.add(module)
        source = read(module)
        if source is None:
            continue
        todo.extend(sibling_imports(source, siblings) - seen)
    return seen - listed


def sparse_ci_steps():
    """(workflow, job, step index, ref, listed modules) for each narrow scripts/ci sparse checkout."""
    for workflow in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(workflow.read_text(encoding="utf-8")) or {}
        for job_name, job in (doc.get("jobs") or {}).items():
            for index, step in enumerate((job or {}).get("steps") or []):
                inputs = step.get("with") or {}
                sparse = inputs.get("sparse-checkout")
                if not isinstance(sparse, str):
                    continue
                paths = [line.strip().lstrip("/") for line in sparse.splitlines() if line.strip()]
                # A directory or glob already brings its siblings along.
                if any("*" in path or path.rstrip("/") in ("scripts", CI_DIR) for path in paths):
                    continue
                listed = {match.group(1) for path in paths if (match := SCRIPT.fullmatch(path))}
                if listed:
                    yield workflow.name, job_name, index, str(inputs.get("ref") or ""), listed


class SparseCheckoutImportTests(unittest.TestCase):
    def test_sparse_lists_carry_every_imported_helper(self) -> None:
        tree_siblings = {path.stem for path in (ROOT / CI_DIR).glob("*.py")}
        failures = []
        steps = list(sparse_ci_steps())
        self.assertTrue(steps, "expected at least one scripts/ci sparse checkout")
        for workflow, job, index, ref, listed in steps:
            where = f"{workflow} job {job} step {index}"
            if (workflow, ref) in LOADS_SIBLINGS_ELSEWHERE:
                continue
            missing = missing_imports(listed, working_tree_reader, tree_siblings)
            if missing:
                failures.append(f"{where}: add {sorted(missing)} (imported at this tree)")
            if FULL_SHA.fullmatch(ref) and git_has_commit(ref):
                pinned = missing_imports(listed, git_reader(ref), git_siblings(ref))
                if pinned:
                    failures.append(f"{where}: add {sorted(pinned)} (imported at pinned {ref[:12]})")
        self.assertFalse(failures, "\n".join(failures))

    def test_the_check_catches_the_admit_outage(self) -> None:
        # pr_runner_pool imports github_spend: a list without it is caught, lazily imported helpers too.
        sources = {
            "fast_checks_runner": "import pr_runner_pool\n",
            "pr_runner_pool": "import github_spend\n\ndef route():\n    import warm_distance\n",
            "github_spend": "import os\n",
            "warm_distance": "",
        }
        siblings = set(sources)
        self.assertEqual(
            missing_imports({"fast_checks_runner", "pr_runner_pool"}, sources.get, siblings),
            {"github_spend", "warm_distance"},
        )
        self.assertEqual(missing_imports(siblings, sources.get, siblings), set())


if __name__ == "__main__":
    unittest.main()
