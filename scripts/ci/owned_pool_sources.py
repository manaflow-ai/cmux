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

A runs-on that reads `matrix.*`, `needs.<job>.outputs.*` or `inputs.*` is
followed into the job's strategy.matrix, that job's steps, env and outputs, and
the input's workflow_dispatch/workflow_call default; a caller that passes such
an input a marked value through `with:` is owned too (Workflow.why()).

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
# on feat-cmux-next: the trusted promote mini, the daemon tests' slot and the
# cmux-tui-pin-* pushes' daemon pool).
EXTRA_OWNED_VARIABLES = frozenset({"CI_NEXT_PROMOTE_POOL", "CI_NEXT_DAEMON_POOL", "CI_PIN_DAEMON_POOL"})
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
        if isinstance(node, ast.Dict):
            return tuple(key.value for key in node.keys if isinstance(key, ast.Constant) and isinstance(key.value, str))
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            left, right = value(node.left), value(node.right)
            return left + right if isinstance(left, str) and isinstance(right, str) else None
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
            target = node.targets[0]
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value is not None:
            target = node.target
        else:
            continue
        resolved = value(node.value)
        if resolved is not None:
            found[target.id] = resolved
    return found


RESCUE_SCRIPT = "scripts/ci/owned_pool_rescue.py"
WATCHED_NAME = "WATCHED_WORKFLOW_PATHS"
UNRESCUED_NAME = "UNRESCUED_WORKFLOW_PATHS"
NIGHTLY_WORKFLOW = f"{WORKFLOWS_DIR}/nightly.yml"
# owned_pool_rescue.py's table of the nightly jobs its signing-stall rescue moves off a stalled Blacksmith macOS
# label: {job id: (jobs-API name, (runs-on expressions that give a re-run the alternate label, ...))}.
SIGN_TABLE_NAME = "NIGHTLY_SIGN_ALTERNATES"
# The nightly.yml jobs that table must hold: a sign, verify or DMG job (by its id) whose runs-on can name a
# Blacksmith macOS label (a literal, or vars.MACOS_RUNNER_26, which holds one) other than the outage switch's.
SIGN_STALL_JOB_ID = re.compile(r"sign|verify|dmg")
BLACKSMITH_MACOS = re.compile(r"blacksmith-[0-9]+vcpu-macos-[0-9]+(?:-[a-z0-9]+)*")
# vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-...-macos-...' ||: the outage switch a person turns on when Linux
# capacity is gone. The Linux jobs that carry it are not sign stalls.
OUTAGE_MACOS_FALLBACK = re.compile(r"vars\.CI_CLOUD_OVERFLOW_SAVED\s*&&\s*'[^']*'\s*\|\|")


def watched_paths(source: str) -> frozenset[str]:
    """owned_pool_rescue.WATCHED_WORKFLOW_PATHS read from a copy of the script, without running it."""
    watched = _constants(source).get(WATCHED_NAME)
    if not isinstance(watched, tuple) or not watched:
        raise ValueError(f"{RESCUE_SCRIPT} defines no {WATCHED_NAME}")
    return frozenset(watched)


def unrescued_paths(source: str) -> frozenset[str]:
    """owned_pool_rescue.UNRESCUED_WORKFLOW_PATHS' keys: owned workflows the rescue leaves to a person."""
    unrescued = _constants(source).get(UNRESCUED_NAME)
    if not isinstance(unrescued, tuple):
        raise ValueError(f"{RESCUE_SCRIPT} defines no {UNRESCUED_NAME}")
    return frozenset(unrescued)


def sign_table(source: str) -> dict[str, tuple[str, ...]]:
    """owned_pool_rescue.NIGHTLY_SIGN_ALTERNATES read from a copy of the script, without running it: each job id
    and the runs-on expressions that move its re-run to an alternate label."""
    constants = _constants(source)
    for node in ast.parse(source).body:
        target = node.targets[0] if isinstance(node, ast.Assign) and len(node.targets) == 1 else \
            node.target if isinstance(node, ast.AnnAssign) else None
        if not (isinstance(target, ast.Name) and target.id == SIGN_TABLE_NAME and isinstance(node.value, ast.Dict)):
            continue
        table: dict[str, tuple[str, ...]] = {}
        for key, entry in zip(node.value.keys, node.value.values):
            if not (isinstance(key, ast.Constant) and isinstance(key.value, str)):
                continue
            expressions = entry.elts[1] if isinstance(entry, ast.Tuple) and len(entry.elts) == 2 else None
            items = expressions.elts if isinstance(expressions, (ast.Tuple, ast.List)) else \
                [expressions] if expressions is not None else []
            resolved = [item.value if isinstance(item, ast.Constant) else
                        constants.get(item.id) if isinstance(item, ast.Name) else None for item in items]
            table[key.value] = tuple(text for text in resolved if isinstance(text, str))
        return table
    raise ValueError(f"{RESCUE_SCRIPT} defines no {SIGN_TABLE_NAME}")


def sign_stall_candidates(workflow_text: str) -> dict[str, str]:
    """The jobs of a nightly.yml (either branch's) the signing-stall rescue must cover, with their runs-on."""
    spec = _load(workflow_text).get("jobs") or {}
    found: dict[str, str] = {}
    for key, job in spec.items():
        if not isinstance(job, dict) or not SIGN_STALL_JOB_ID.search(str(key)):
            continue
        runs_on = str(job.get("runs-on") or "")
        bare = OUTAGE_MACOS_FALLBACK.sub("", runs_on)
        if BLACKSMITH_MACOS.search(bare) or "MACOS_RUNNER_26" in bare:
            found[str(key)] = runs_on
    return found


def uncovered_sign_jobs(workflow_text: str, table: dict[str, tuple[str, ...]]) -> dict[str, str]:
    """nightly.yml's sign, verify and DMG jobs on a Blacksmith macOS label that the rescue's table leaves stuck:
    {job: why}. A job outside the table is never moved, and while it waits it counts as unfinished work, which
    keeps every other stalled job of its run where it is; a job whose runs-on has none of its table's
    expressions would be re-run onto the label that stalled."""
    missing: dict[str, str] = {}
    for key, runs_on in sign_stall_candidates(workflow_text).items():
        if key not in table:
            missing[key] = f"not in {SIGN_TABLE_NAME}"
        elif not any(expression in runs_on for expression in table[key]):
            missing[key] = "its runs-on takes none of its alternate-label expressions on a re-run"
    return missing


def policy_variables(source: str) -> frozenset[str]:
    """Variables drifted_runner_variables() checks against an owned label shape (not forbidden_reason())."""
    constants = _constants(source)
    tree = ast.parse(source)
    function = next((node for node in tree.body if isinstance(node, ast.FunctionDef)
                     and node.name == "drifted_runner_variables"), None)
    if function is None:
        raise ValueError(f"{POLICY_SCRIPT} has no drifted_runner_variables()")
    names: set[str] = set()
    # Only an if/elif whose whole test is `name == X` or `name in X` picks a label-shape check. A
    # compare inside a larger test (`name in NO_HOSTED_MAC_VARIABLES and HOSTED_MAC_LABEL...`, which
    # names LINUX_RUNNER and the hosted-Mac fallbacks) only guards a value and makes no variable owned.
    for branch in ast.walk(function):
        node = branch.test if isinstance(branch, ast.If) else None
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


NEEDS_OUTPUT = re.compile(r"\bneeds\.([A-Za-z0-9_-]+)\.outputs\.")
INPUT_REF = re.compile(r"\binputs\.([A-Za-z0-9_-]+)")


class Workflow:
    """One workflow file: why a runs-on of it can take an owned pool, following what the runs-on reads."""

    def __init__(self, markers: Markers, tree: Tree, path: str, document: dict):
        self.markers, self.path, self.document = markers, path, document
        self.jobs = {key: job for key, job in (document.get("jobs") or {}).items() if isinstance(job, dict)}
        self.pickers = set()
        for key, job in self.jobs.items():
            text = "\n".join(str(step.get("run") or "") for step in job.get("steps") or [] if isinstance(step, dict))
            uses = LOCAL_USES.match(str(job.get("uses") or ""))
            if markers.runs_picker(text) or uses and markers.runs_picker(tree.read(uses.group(1)) or ""):
                self.pickers.add(key)
        on = document.get("on", document.get(True))
        self.inputs: dict[str, object] = {}
        for trigger in ("workflow_dispatch", "workflow_call"):
            declared = ((on or {}).get(trigger) or {}).get("inputs") if isinstance(on, dict) else None
            for name, spec in (declared or {}).items():
                if isinstance(spec, dict) and spec.get("default") not in (None, ""):
                    self.inputs.setdefault(str(name), spec["default"])
        # Inputs a runs-on reads, directly or through a matrix or another job's outputs: a caller's
        # `with:` value for one of them is where that runs-on's label comes from.
        self.runner_inputs: set[str] = set()

    def why(self, text: str, job: str | None, seen: set[tuple[str, str]]) -> str:
        """Why `text` (a runs-on, or what it reads) can name an owned pool, or ""."""
        direct = self.markers.owned_runs_on(text, self.pickers)
        if direct:
            return direct
        if job is not None and "matrix." in text and ("matrix", job) not in seen:
            seen.add(("matrix", job))
            matrix = (self.jobs.get(job, {}).get("strategy") or {}).get("matrix")
            found = self.why(str(matrix), job, seen) if matrix is not None else ""
            if found:
                return f"takes matrix values that {found}"
        for producer in NEEDS_OUTPUT.findall(text):
            if producer not in self.jobs or ("needs", producer) in seen:
                continue
            seen.add(("needs", producer))
            body = {key: value for key, value in self.jobs[producer].items() if key not in ("runs-on", "name")}
            found = self.why(str(body), producer, seen)
            if found:
                return f"takes job {producer}'s output, which {found}"
        for name in INPUT_REF.findall(text):
            self.runner_inputs.add(name)
            if name in self.inputs and ("input", name) not in seen:
                seen.add(("input", name))
                found = self.why(str(self.inputs[name]), job, seen)
                if found:
                    return f"reads input {name}, whose default {found}"
        return ""

    def owned_jobs(self) -> dict[str, str]:
        found = {}
        for key, job in self.jobs.items():
            why = self.why(str(job.get("runs-on") or ""), key, set())
            if why:
                found[key] = why
        return found


def owned_workflows(tree: Tree) -> dict[str, str]:
    """{workflow path: why} for each workflow with its own runs (not only workflow_call) that can take an owned pool."""
    markers = Markers(tree)
    workflows = {path: Workflow(markers, tree, path, _load(tree.read(path) or "")) for path in tree.workflows()}
    owned: dict[str, str] = {}
    for path, workflow in workflows.items():
        jobs = workflow.owned_jobs()
        if jobs:
            key = sorted(jobs)[0]
            owned[path] = f"job {key} {jobs[key]}"
    calls: dict[str, set[str]] = {path: set() for path in workflows}
    for path, workflow in workflows.items():
        for key, job in workflow.jobs.items():
            uses = LOCAL_USES.match(str(job.get("uses") or ""))
            if not uses or (path, uses.group(1)) in OFF_POOL_CALLS:
                continue
            callee = uses.group(1)
            calls[path].add(callee)
            given = job.get("with") if isinstance(job.get("with"), dict) else {}
            for name in sorted(workflows[callee].runner_inputs if callee in workflows else ()):
                if name in given and path not in owned:
                    why = workflow.why(str(given[name]), key, set())
                    if why:
                        owned[path] = (f"job {key} passes {callee.rsplit('/', 1)[-1]} a runs-on input {name} "
                                       f"that {why}")
    changed = True
    while changed:
        changed = False
        for path, called in calls.items():
            if path in owned:
                continue
            hit = next((callee for callee in sorted(called) if callee in owned), None)
            if hit:
                owned[path] = f"calls {hit.rsplit('/', 1)[-1]}, whose {owned[hit]}"
                changed = True
    return {path: why for path, why in sorted(owned.items())
            if _triggers(workflows[path].document) - {"workflow_call"}}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ref", help="a git ref to read the workflows from (default: the working tree)")
    args = parser.parse_args(argv)
    for path, why in owned_workflows(Tree(ROOT, args.ref)).items():
        print(f"{path}\t{why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
