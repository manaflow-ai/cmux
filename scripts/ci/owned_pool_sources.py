#!/usr/bin/env python3
"""Which workflows can put a job on an owned (persistent) runner pool.

A job on an owned pool can wait for good or be refused at job start, and only
ci-owned-pool-rescue.yml moves it (scripts/ci/owned_pool_rescue.py). That rescue
acts only on the workflow files it knows (owned_pool_rescue.WATCHED_WORKFLOW_PATHS),
so a workflow that takes an owned label without being listed there is never
rescued: run 39638669325 (cmux-next-base-autofix.yml, 2026-10-21) had its Mac
job refused by a mini and nothing re-ran it.

This module decides it from the workflow files themselves, so the rescue's list
can be checked against it (tests/test_ci_owned_pool_sources.py). A workflow is
owned when one of its jobs' `runs-on`, or a job of a reusable workflow it calls,
names:

- an owned label literal: the prefix every glaeda label shares, read from
  pr_runner_pool.py's label prefixes;
- an owned-pool variable: pr_runner_pool.OWNED_VARIABLE (the switch an owned
  route is gated on), every variable runner_label_policy.drifted_runner_variables()
  holds to an owned label's shape, and EXTRA_OWNED_VARIABLES;
- an output of a job that runs a pool picker: a scripts/ci script that is
  pr_runner_pool.py or imports it (ios_runner_pool.py, e2e_runner_pool.py,
  side_lane_placement.py, ...).

The markers are read from the scanned tree's own pr_runner_pool.py and
runner_label_policy.py, so a branch that adds a pool variable is judged by its
own policy. A tree is the working tree or a git ref (`git show REF:PATH`), which
is how main's guard also checks feat-cmux-next's workflows and the reverse.

Running this file prints the owned workflows of the working tree, or of
`--ref REF`.
"""

from __future__ import annotations

import argparse
import ast
import functools
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS_DIR = ".github/workflows"
POOL_SCRIPT = "scripts/ci/pr_runner_pool.py"
POLICY_SCRIPT = "scripts/ci/runner_label_policy.py"
# pr_runner_pool.py's label prefixes; their common prefix is the owned literal.
LABEL_PREFIX_NAMES = ("ROOT_PREFIX", "SIDE_PREFIX", "GUI_PREFIX", "RUNNER_LABEL_PREFIX")
# Pool variables no policy check holds to a label shape yet (docs/ci-runners.md
# on feat-cmux-next: the trusted promote mini and the daemon tests' slot).
EXTRA_OWNED_VARIABLES = frozenset({"CI_NEXT_PROMOTE_POOL", "CI_NEXT_DAEMON_POOL"})
# (caller, reusable workflow) calls whose picker never places the call on an
# owned pool, so the caller does not inherit the reusable workflow's owned job.
OFF_POOL_CALLS = {
    (".github/workflows/release.yml", ".github/workflows/ios-screenshots.yml"):
        "ios_runner_pool.owned_blocker(): a release call stays on Blacksmith",
}
PICKER_IMPORT = re.compile(r"^\s*(?:from\s+pr_runner_pool\s+import|import\s+pr_runner_pool\b)", re.M)
SCRIPT_PATH = re.compile(r"scripts/ci/[A-Za-z0-9_]+\.py")
LOCAL_USES = re.compile(r"^\./(\.github/workflows/[A-Za-z0-9._-]+\.ya?ml)$")


class Tree:
    """Files of the working tree (ref None) or of a git ref."""

    def __init__(self, root: Path = ROOT, ref: str | None = None):
        self.root, self.ref = root, ref

    def __repr__(self) -> str:
        return self.ref or str(self.root)

    @functools.cache
    def read(self, path: str) -> str | None:
        if self.ref is None:
            file = self.root / path
            return file.read_text(encoding="utf-8") if file.is_file() else None
        result = subprocess.run(["git", "-C", str(self.root), "show", f"{self.ref}:{path}"],
                                capture_output=True, text=True)
        return result.stdout if result.returncode == 0 else None

    def workflows(self) -> list[str]:
        if self.ref is None:
            folder = self.root / WORKFLOWS_DIR
            names = [path.name for path in folder.iterdir()] if folder.is_dir() else []
        else:
            result = subprocess.run(["git", "-C", str(self.root), "ls-tree", "--name-only", self.ref,
                                     f"{WORKFLOWS_DIR}/"], capture_output=True, text=True, check=True)
            names = [line.rsplit("/", 1)[-1] for line in result.stdout.split()]
        return sorted(f"{WORKFLOWS_DIR}/{name}" for name in names if name.endswith((".yml", ".yaml")))


def _constants(source: str) -> dict[str, object]:
    """A module's top-level string and tuple-of-string constants, names resolved."""
    found: dict[str, object] = {}

    def value(node: ast.AST) -> object:
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return node.value
        if isinstance(node, ast.Name):
            return found.get(node.id)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in (
                "frozenset", "set", "tuple") and len(node.args) == 1 and not node.keywords:
            return value(node.args[0])
        if isinstance(node, ast.Starred):
            return value(node.value)
        if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
            items = [value(item) for item in node.elts]
            flat: list[str] = []
            for item in items:
                if isinstance(item, str):
                    flat.append(item)
                elif isinstance(item, tuple):
                    flat.extend(item)
            return tuple(flat)
        return None

    for node in ast.parse(source).body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            resolved = value(node.value)
            if resolved is not None:
                found[node.targets[0].id] = resolved
    return found


RESCUE_SCRIPT = "scripts/ci/owned_pool_rescue.py"
WATCHED_NAME = "WATCHED_WORKFLOW_PATHS"


def watched_paths(source: str) -> frozenset[str]:
    """owned_pool_rescue.WATCHED_WORKFLOW_PATHS read from a copy of the script, without running it."""
    watched = _constants(source).get(WATCHED_NAME)
    if not isinstance(watched, tuple) or not watched:
        raise ValueError(f"{RESCUE_SCRIPT} defines no {WATCHED_NAME}")
    return frozenset(watched)


def policy_variables(source: str) -> frozenset[str]:
    """Variables drifted_runner_variables() checks against an owned label shape (not forbidden_reason())."""
    constants = _constants(source)
    tree = ast.parse(source)
    function = next((node for node in tree.body if isinstance(node, ast.FunctionDef)
                     and node.name == "drifted_runner_variables"), None)
    if function is None:
        raise ValueError(f"{POLICY_SCRIPT} has no drifted_runner_variables()")
    names: set[str] = set()
    for node in ast.walk(function):
        if not (isinstance(node, ast.Compare) and isinstance(node.left, ast.Name) and node.left.id == "name"):
            continue
        for operator, right in zip(node.ops, node.comparators):
            if not isinstance(operator, (ast.Eq, ast.In)):
                continue
            items = right.elts if isinstance(right, (ast.Tuple, ast.List, ast.Set)) else [right]
            for item in items:
                resolved = (item.value if isinstance(item, ast.Constant) else
                            constants.get(item.id) if isinstance(item, ast.Name) else None)
                if isinstance(resolved, str):
                    names.add(resolved)
                elif isinstance(resolved, tuple):
                    names.update(resolved)
    if not names:
        raise ValueError(f"{POLICY_SCRIPT}'s drifted_runner_variables() names no variable")
    return frozenset(names)


def common_prefix(texts: list[str]) -> str:
    shared = ""
    for chars in zip(*texts):
        if len(set(chars)) != 1:
            break
        shared += chars[0]
    return shared


class Markers:
    """What makes a runs-on owned in one tree."""

    def __init__(self, tree: Tree):
        self.tree = tree
        pool = tree.read(POOL_SCRIPT)
        policy = tree.read(POLICY_SCRIPT)
        if pool is None or policy is None:
            raise ValueError(f"{tree}: {POOL_SCRIPT} or {POLICY_SCRIPT} is missing")
        constants = _constants(pool)
        prefixes = [constants.get(name) for name in LABEL_PREFIX_NAMES]
        if not all(isinstance(prefix, str) for prefix in prefixes):
            raise ValueError(f"{tree}: {POOL_SCRIPT} no longer defines {', '.join(LABEL_PREFIX_NAMES)}")
        self.literal = common_prefix(prefixes)
        if not self.literal.endswith("-"):
            raise ValueError(f"{tree}: the owned label prefixes share no family prefix ({self.literal!r})")
        switch = constants.get("OWNED_VARIABLE")
        if not isinstance(switch, str):
            raise ValueError(f"{tree}: {POOL_SCRIPT} no longer defines OWNED_VARIABLE")
        self.variables = frozenset({switch, *policy_variables(policy), *EXTRA_OWNED_VARIABLES})
        self.variable = re.compile(r"\bvars\.(" + "|".join(sorted(map(re.escape, self.variables))) + r")\b")

    @functools.cache
    def picker_script(self, path: str) -> bool:
        if path == POOL_SCRIPT:
            return True
        text = self.tree.read(path)
        return bool(text and PICKER_IMPORT.search(text))

    def runs_picker(self, text: str) -> bool:
        return any(self.picker_script(path) for path in SCRIPT_PATH.findall(text))

    def owned_runs_on(self, runs_on: str, pickers: set[str]) -> str:
        """Why a runs-on can take an owned pool, or ""."""
        if self.literal in runs_on:
            return f"names a {self.literal}* label"
        match = self.variable.search(runs_on)
        if match:
            return f"reads vars.{match.group(1)}"
        for job in sorted(pickers):
            if re.search(rf"\bneeds\.{re.escape(job)}\.outputs\.", runs_on):
                return f"takes the pool picker job {job}'s output"
        return ""


def _load(text: str) -> dict:
    import yaml  # noqa: PLC0415 - only the guard and this CLI need it

    document = yaml.safe_load(text)
    return document if isinstance(document, dict) else {}


def _triggers(document: dict) -> set[str]:
    on = document.get("on", document.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {str(item) for item in on}
    return {str(key) for key in on} if isinstance(on, dict) else set()


def owned_workflows(tree: Tree) -> dict[str, str]:
    """{workflow path: why} for each workflow with its own runs (not only workflow_call) that can take an owned pool."""
    markers = Markers(tree)
    documents = {path: _load(tree.read(path) or "") for path in tree.workflows()}
    direct: dict[str, str] = {}
    calls: dict[str, set[str]] = {}
    for path, document in documents.items():
        jobs = {key: job for key, job in (document.get("jobs") or {}).items() if isinstance(job, dict)}
        pickers = set()
        for key, job in jobs.items():
            text = "\n".join(str(step.get("run") or "") for step in job.get("steps") or [] if isinstance(step, dict))
            uses = LOCAL_USES.match(str(job.get("uses") or ""))
            if markers.runs_picker(text) or uses and markers.runs_picker(tree.read(uses.group(1)) or ""):
                pickers.add(key)
        calls[path] = set()
        for key, job in jobs.items():
            uses = LOCAL_USES.match(str(job.get("uses") or ""))
            if uses:
                calls[path].add(uses.group(1))
            why = markers.owned_runs_on(str(job.get("runs-on") or ""), pickers)
            if why and path not in direct:
                direct[path] = f"job {key} {why}"
    owned = dict(direct)
    changed = True
    while changed:
        changed = False
        for path, called in calls.items():
            if path in owned:
                continue
            hit = next((callee for callee in sorted(called)
                        if callee in owned and (path, callee) not in OFF_POOL_CALLS), None)
            if hit:
                owned[path] = f"calls {hit.rsplit('/', 1)[-1]}, whose {owned[hit]}"
                changed = True
    return {path: why for path, why in sorted(owned.items())
            if _triggers(documents[path]) - {"workflow_call"}}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ref", help="a git ref to read the workflows from (default: the working tree)")
    args = parser.parse_args(argv)
    for path, why in owned_workflows(Tree(ROOT, args.ref)).items():
        print(f"{path}\t{why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
