#!/usr/bin/env python3
"""Every repository variable a runs-on reads declares its fallback in .github/single-host-fallbacks.json.

Leo's rule (2026-10-24): no job waits on one reserved machine; each single-host label, and each
repository variable a runs-on reads, says what takes the job instead and after how many minutes.
The declaration used to live only in the build-fleet repository, whose runner label policy test
reads this repository's workflows live. So a pull request here that added a runs-on variable
merged green and turned that repository red afterwards: cmux#40221 added vars.CI_NIGHTLY_MINI_SIGNER
and vars.CI_NIGHTLY_MINI_PUBLISHER to nightly.yml, and only the policy test there caught it, after
the merge. The declaration now lives here, the build-fleet test reads this file, and this test fails
the pull request that adds an undeclared name, before it merges.

What is read, for every workflow under .github/workflows:
- each `runs-on:` line, as the build-fleet test reads it (every `vars.NAME` on the line, and every
  single-host label: a controller label or one starting with a `single_host_prefixes` entry, which
  `labels` must declare);
- each job's parsed runs-on (a block list, a `group`/`labels` mapping), `vars.NAME`, `vars['NAME']`
  and `fromJSON(vars.NAME)` forms alike;
- the matrix values a runs-on reads through `matrix.KEY` (axes and `include` entries; a matrix that is
  itself an expression is read whole);
- the `with:` values a caller passes to a local reusable workflow's input that reaches a runs-on there.

The declaration itself must promise a bounded fallback: the same schema checks as the build-fleet
test (fallback_policy in its tests/test_runner_label_policy.py), so a declaration it would refuse
fails here first. Its nightly scan (nightly_terminal_labels, nightly_job_outputs) stays there.
"""

from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from collections.abc import Iterable, Iterator
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
DECLARATION = ROOT / ".github" / "single-host-fallbacks.json"

RUNS_ON_LINE = re.compile(r"^\s*runs-on:\s*(?P<value>.*)$")
# `vars.NAME` and `vars['NAME']`; GitHub matches variable names case-insensitively, so `vars.name` reads NAME.
VAR = re.compile(r"\bvars\s*(?:\.\s*(?P<dot>[A-Za-z_][A-Za-z0-9_]*)|\[\s*'(?P<key>[^']*)'\s*\])")
# The build-fleet test's label token, so both read the same labels off a line.
LABEL = re.compile(r"(?<![A-Za-z0-9_.-])([A-Za-z][A-Za-z0-9_.-]*)(?![A-Za-z0-9_.-])")
MATRIX = re.compile(r"\bmatrix\.([A-Za-z_][A-Za-z0-9_-]*)")
INPUT = re.compile(r"\binputs\.([A-Za-z_][A-Za-z0-9_-]*)")
LOCAL_CALL = re.compile(r"^\./(\.github/workflows/[^@]+\.ya?ml)$")
# The build-fleet repository's GitHub-hosted label pattern (scripts/ci/check-runner-labels.py HOSTED).
HOSTED = re.compile(
    r"(?<![A-Za-z0-9_-])("
    r"ubuntu-(?:latest|slim|\d{2}\.\d{2}(?:-arm)?)"
    r"|macos-(?:latest|\d+(?:-intel|-large|-xlarge|-arm64)?)"
    r"|windows-(?:latest|\d{4}(?:-arm)?|11-arm)"
    r")(?![A-Za-z0-9_.-])"
)
ARRAY_PIN = "glaeda-runner-"
BLACKSMITH_POOL = re.compile(r"blacksmith-[0-9]+vcpu-[a-z0-9][a-z0-9.-]*")


def declaration_faults(policy: object) -> list[str]:
    """What the build-fleet test's fallback_policy would refuse in this declaration, or nothing."""
    if not isinstance(policy, dict):
        return ["the declaration must be a JSON object"]
    bad: list[str] = []
    if policy.get("schema") != 1:
        bad.append("schema must be 1")
    labels = policy.get("labels")
    if not isinstance(labels, dict) or not labels:
        bad.append("labels must declare at least one label")
        labels = {}
    for label, entry in labels.items():
        bad.extend(bounded(label, entry))
    controller = policy.get("controller_labels", [])
    if not isinstance(controller, list) or not set(controller) <= set(labels):
        bad.append("every controller_labels entry must be declared in labels")
    prefixes = policy.get("single_host_prefixes", [])
    if not isinstance(prefixes, list) or not all(isinstance(p, str) and p for p in prefixes):
        bad.append("single_host_prefixes must be non-empty strings")
    variables = policy.get("variables", {})
    if not isinstance(variables, dict):
        bad.append("variables must be an object")
        variables = {}
    for name, entry in variables.items():
        bad.extend(bounded(f"vars.{name}", entry))
    if not policy.get("nightly_workflow_marker"):
        bad.append("nightly_workflow_marker must say which workflows are nightly workflows")
    terminals = policy.get("nightly_terminal_labels")
    if not isinstance(terminals, dict) or not terminals:
        bad.append("nightly_terminal_labels must declare the nightly terminal labels")
        terminals = {}
    for label, entry in terminals.items():
        if not isinstance(entry, dict):
            bad.append(f"{label}: nightly declaration must be an object")
            continue
        for field in ("fallback", "served_by"):
            value = entry.get(field)
            if not isinstance(value, str) or not value.strip():
                bad.append(f"{label}: {field} must be a non-empty string, not {value!r}")
        if isinstance(entry.get("fallback"), str) and label in entry["fallback"]:
            bad.append(f"{label}: a label cannot be its own fallback")
        minutes = entry.get("after_minutes")
        if type(minutes) is not int or not 0 < minutes <= 30:
            bad.append(f"{label}: after_minutes must be a whole number of minutes in 1..30 "
                       f"(Leo's freshness budget), not {minutes!r}")
    declarable = set(terminals) | {f"vars.{name}" for name in variables}
    outputs = policy.get("nightly_job_outputs", {})
    for key, entry in (outputs.items() if isinstance(outputs, dict) else ()):
        if not isinstance(entry, dict):
            bad.append(f"{key}: job-output declaration must be an object")
            continue
        if ":" not in key or "." not in key.split(":", 1)[1]:
            bad.append(f"{key}: job-output key must be <workflow>:<job>.<output>")
        emitted = entry.get("labels")
        if not isinstance(emitted, list) or not emitted:
            bad.append(f"{key}: labels must be a non-empty list of the labels it can emit")
            emitted = []
        for label in emitted:
            if not isinstance(label, str) or not label.strip():
                bad.append(f"{key}: every label must be a non-empty string, not {label!r}")
            elif HOSTED.fullmatch(label.strip()):
                bad.append(f"{key}: {label} is a GitHub-hosted label; a run-time pick may not emit one")
            elif label not in declarable and not BLACKSMITH_POOL.fullmatch(label):
                bad.append(f"{key}: {label} is declared neither in nightly_terminal_labels nor as a variable")
        for field in ("constrained_by", "empty_falls_back_to"):
            value = entry.get(field)
            if not isinstance(value, str) or not value.strip():
                bad.append(f"{key}: {field} must be a non-empty string, not {value!r}")
        if "array_pin" in entry and entry["array_pin"] != ARRAY_PIN:
            bad.append(f"{key}: array_pin must be {ARRAY_PIN!r}, not {entry['array_pin']!r}")
    return bad


def bounded(name: str, entry: object) -> list[str]:
    """A label or variable entry: a named fallback, taken after a positive whole number of minutes."""
    if not isinstance(entry, dict) or not isinstance(entry.get("fallback"), str) or not entry["fallback"].strip():
        return [f"{name}: missing fallback declaration"]
    minutes = entry.get("after_minutes")
    if type(minutes) is not int or minutes <= 0:
        return [f"{name}: fallback must have a positive after_minutes, not {minutes!r}"]
    return []


def strings(node: object) -> Iterator[str]:
    """Every string in a parsed YAML value, keys of a mapping included (a runs-on group or labels)."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for key, value in node.items():
            yield from strings(key)
            yield from strings(value)
    elif isinstance(node, list):
        for item in node:
            yield from strings(item)


def matrix_values(job: dict, keys: set[str]) -> Iterator[str]:
    """The strings `matrix.KEY` can take for each KEY a runs-on reads; a dynamic matrix whole."""
    matrix = (job.get("strategy") or {}).get("matrix") if isinstance(job.get("strategy"), dict) else None
    if matrix is None:
        return
    if not isinstance(matrix, dict):
        yield from strings(matrix)
        return
    for key, value in matrix.items():
        if key in keys:
            yield from strings(value)
        elif key == "include":
            if not isinstance(value, list):
                yield from strings(value)
                continue
            for entry in value:
                if isinstance(entry, dict):
                    for name, item in entry.items():
                        if name in keys:
                            yield from strings(item)
                else:
                    yield from strings(entry)


def load_workflow(path: Path) -> dict:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    return document if isinstance(document, dict) else {}


def jobs_of(document: dict) -> Iterator[tuple[str, dict]]:
    jobs = document.get("jobs")
    for name, job in (jobs.items() if isinstance(jobs, dict) else ()):
        if isinstance(job, dict):
            yield str(name), job


def job_selector_texts(job: dict) -> list[str]:
    """The runs-on strings of a job, with the matrix values its runs-on reads."""
    if "runs-on" not in job:
        return []
    texts = list(strings(job["runs-on"]))
    keys = {key for text in texts for key in MATRIX.findall(text)}
    if keys:
        texts.extend(matrix_values(job, keys))
    return texts


def local_callee(job: dict, root: Path) -> Path | None:
    uses = job.get("uses")
    match = LOCAL_CALL.match(uses) if isinstance(uses, str) else None
    return root / match.group(1) if match else None


def runner_inputs(path: Path, root: Path, memo: dict[Path, set[str]]) -> set[str]:
    """The workflow_call inputs of `path` that reach a runs-on, directly or through a local call."""
    if path in memo:
        return memo[path]
    memo[path] = set()  # a cycle reaches nothing new
    if not path.is_file():
        return memo[path]
    reached: set[str] = set()
    for _, job in jobs_of(load_workflow(path)):
        for text in job_selector_texts(job):
            reached.update(INPUT.findall(text))
        callee = local_callee(job, root)
        if callee is not None and isinstance(job.get("with"), dict):
            passed = runner_inputs(callee, root, memo)
            for key, value in job["with"].items():
                if key in passed:
                    for text in strings(value):
                        reached.update(INPUT.findall(text))
    memo[path] = reached
    return reached


def variable_names(text: str) -> Iterator[str]:
    for match in VAR.finditer(text):
        yield (match.group("dot") or match.group("key")).upper()


def references(workflow_dirs: Iterable[Path]) -> tuple[dict[str, list[str]], list[tuple[str, str]], list[str]]:
    """(variable -> where it is read, [(where, runs-on line)], unreadable notes) for the workflows."""
    found: dict[str, list[str]] = {}
    lines: list[tuple[str, str]] = []
    bad: list[str] = []

    def note(text: str, where: str) -> None:
        for name in variable_names(text):
            if where not in found.setdefault(name, []):
                found[name].append(where)

    for directory in workflow_dirs:
        if not directory.is_dir():
            bad.append(f"{directory}: workflow directory is missing")
            continue
        root = directory.parents[1]
        memo: dict[Path, set[str]] = {}
        for workflow in sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")]):
            for number, line in enumerate(workflow.read_text(encoding="utf-8").splitlines(), 1):
                match = RUNS_ON_LINE.match(line)
                if match:
                    lines.append((f"{workflow.name}:{number}", match.group("value")))
                    note(match.group("value"), f"{workflow.name}:{number}")
            try:
                document = load_workflow(workflow)
            except yaml.YAMLError as error:
                bad.append(f"{workflow.name}: unreadable YAML: {error.__class__.__name__}")
                continue
            for name, job in jobs_of(document):
                for text in job_selector_texts(job):
                    note(text, f"{workflow.name}: job {name}")
                callee = local_callee(job, root)
                if callee is not None and isinstance(job.get("with"), dict):
                    passed = runner_inputs(callee, root, memo)
                    for key, value in job["with"].items():
                        if key in passed:
                            for text in strings(value):
                                note(text, f"{workflow.name}: job {name}: with.{key} "
                                           f"(a runs-on input of {callee.name})")
    return found, lines, bad


def undeclared(workflow_dirs: Iterable[Path], policy: dict) -> list[str]:
    """Every runs-on variable or single-host label with no declared fallback, and what could not be read."""
    found, lines, bad = references(workflow_dirs)
    declared = {name.upper() for name in policy.get("variables", {})}
    for name in sorted(found):
        if name not in declared:
            bad.append(f"vars.{name} is read by a runs-on but {DECLARATION.relative_to(ROOT)} does not declare "
                       f"its fallback (variables.{name}): {', '.join(found[name])}")
    labels = set(policy.get("labels", {}))
    controller = set(policy.get("controller_labels", []))
    prefixes = tuple(policy.get("single_host_prefixes", ()))
    for where, value in lines:
        for label in LABEL.findall(value):
            if label in labels or (label not in controller and not label.startswith(prefixes)):
                continue
            bad.append(f"{where}: {label} is a single-host label with no declared fallback (labels.{label})")
    return bad


def load_declaration() -> dict:
    return json.loads(DECLARATION.read_text(encoding="utf-8"))


class SingleHostFallbacks(unittest.TestCase):
    def scan(self, files: dict[str, str], policy: dict | None = None) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / ".github" / "workflows"
            directory.mkdir(parents=True)
            for name, text in files.items():
                (directory / name).write_text(text, encoding="utf-8")
            return undeclared([directory], policy or load_declaration())

    def assert_names(self, findings: list[str], name: str) -> None:
        self.assertTrue([f for f in findings if f.startswith(f"vars.{name} ")],
                        f"vars.{name} was not reported: {findings}")

    def test_the_declaration_promises_a_bounded_fallback(self) -> None:
        self.assertEqual(declaration_faults(load_declaration()), [])

    def test_every_runs_on_variable_and_single_host_label_is_declared(self) -> None:
        bad = undeclared([WORKFLOWS], load_declaration())
        self.assertEqual(bad, [], "runs-on with no declared single-host fallback:\n" + "\n".join(bad))

    def test_the_real_scan_is_not_vacuous(self) -> None:
        found, lines, bad = references([WORKFLOWS])
        self.assertEqual(bad, [])
        self.assertGreater(len(lines), 100, "the scan read almost no runs-on lines")
        self.assertTrue({"RUNNER_POOLS", "LINUX_RUNNER", "CI_NIGHTLY_MINI"} <= set(found), sorted(found))

    def test_a_new_runs_on_variable_fails_naming_it(self) -> None:
        findings = self.scan({"x.yml": "jobs:\n  a:\n    runs-on: ${{ vars.NEW_X }}\n"})
        self.assert_names(findings, "NEW_X")
        self.assertIn("x.yml:3", findings[0])

    def test_a_declared_variable_passes(self) -> None:
        policy = load_declaration()
        policy["variables"]["NEW_X"] = {"fallback": "Blacksmith macOS after the owned-pool grace", "after_minutes": 5}
        self.assertEqual(self.scan({"x.yml": "jobs:\n  a:\n    runs-on: ${{ vars.NEW_X }}\n"}, policy), [])

    def test_a_comparison_or_fromjson_read_counts_as_a_read(self) -> None:
        for runs_on in ("${{ vars.NEW_X == 'macos-26' && 'macos-26' || fromJSON(vars.RUNNER_POOLS).macos_26 }}",
                        "${{ fromJSON(vars.NEW_X || '{}').macos || 'blacksmith-6vcpu-macos-26' }}",
                        "${{ vars['NEW_X'] || 'blacksmith-6vcpu-macos-26' }}",
                        "${{ vars.new_x || 'blacksmith-6vcpu-macos-26' }}"):
            with self.subTest(runs_on=runs_on):
                self.assert_names(self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: {runs_on}\n"}), "NEW_X")

    def test_a_block_or_group_runs_on_is_read(self) -> None:
        for runs_on in ("\n      - self-hosted\n      - ${{ vars.NEW_X }}",
                        "\n      group: ${{ vars.NEW_X }}\n      labels: [x]",
                        " [\"${{ vars.NEW_X }}\"]"):
            with self.subTest(runs_on=runs_on):
                self.assert_names(self.scan({"x.yml": f"jobs:\n  a:\n    runs-on:{runs_on}\n"}), "NEW_X")

    def test_a_matrix_expanded_runner_is_read(self) -> None:
        axis = ("jobs:\n  a:\n    strategy:\n      matrix:\n        runner: ['${{ vars.NEW_X }}', "
                "blacksmith-4vcpu-ubuntu-2404]\n    runs-on: ${{ matrix.runner }}\n")
        include = ("jobs:\n  a:\n    strategy:\n      matrix:\n        include:\n"
                   "          - os: mac\n            runner: ${{ vars.NEW_X }}\n"
                   "            label: ${{ vars.NOT_A_RUNNER }}\n    runs-on: ${{ matrix.runner }}\n")
        dynamic = ("jobs:\n  a:\n    strategy:\n      matrix: ${{ fromJSON(vars.NEW_X) }}\n"
                   "    runs-on: ${{ matrix.runner }}\n")
        for text in (axis, include, dynamic):
            with self.subTest(text=text):
                self.assert_names(self.scan({"x.yml": text}), "NEW_X")
        # A matrix key the runs-on never reads is not a runner.
        self.assertFalse([f for f in self.scan({"x.yml": include}) if "NOT_A_RUNNER" in f])

    def test_a_reusable_workflow_input_that_reaches_runs_on_is_read(self) -> None:
        callee = ("on:\n  workflow_call:\n    inputs:\n      runner: {type: string}\n      note: {type: string}\n"
                  "jobs:\n  a:\n    runs-on: ${{ inputs.runner || 'blacksmith-4vcpu-ubuntu-2404' }}\n")
        middle = ("on:\n  workflow_call:\n    inputs:\n      box: {type: string}\n"
                  "jobs:\n  b:\n    uses: ./.github/workflows/callee.yml\n    with:\n      runner: ${{ inputs.box }}\n")
        caller = ("jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n    with:\n"
                  "      runner: ${{ vars.NEW_X }}\n      note: ${{ vars.NOT_A_RUNNER }}\n"
                  "  d:\n    uses: ./.github/workflows/middle.yml\n    with:\n      box: ${{ vars.NEW_Y }}\n")
        findings = self.scan({"callee.yml": callee, "middle.yml": middle, "caller.yml": caller})
        self.assert_names(findings, "NEW_X")
        self.assert_names(findings, "NEW_Y")
        self.assertFalse([f for f in findings if "NOT_A_RUNNER" in f], findings)

    def test_a_variable_outside_runs_on_is_not_this_policys_business(self) -> None:
        text = "jobs:\n  a:\n    runs-on: blacksmith-4vcpu-ubuntu-2404\n    env:\n      X: ${{ vars.NEW_X }}\n"
        self.assertEqual(self.scan({"x.yml": text}), [])

    def test_an_undeclared_single_host_label_fails(self) -> None:
        policy = load_declaration()
        prefix = policy["single_host_prefixes"][0]
        findings = self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: {prefix}made-up\n"}, policy)
        self.assertTrue([f for f in findings if f"{prefix}made-up" in f], findings)
        policy["labels"][f"{prefix}made-up"] = {"fallback": "Blacksmith macOS", "after_minutes": 5}
        self.assertEqual(self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: {prefix}made-up\n"}, policy), [])

    def test_a_declaration_that_promises_nothing_is_refused(self) -> None:
        for entry in ({"fallback": "", "after_minutes": 5}, {"fallback": "x"}, {"fallback": "x", "after_minutes": 0},
                      {"fallback": "x", "after_minutes": True}, {"fallback": "x", "after_minutes": "5"}, "x"):
            with self.subTest(entry=entry):
                policy = load_declaration()
                policy["variables"]["NEW_X"] = entry
                self.assertTrue([f for f in declaration_faults(policy) if f.startswith("vars.NEW_X:")])
        policy = load_declaration()
        terminal = next(iter(policy["nightly_terminal_labels"]))
        policy["nightly_terminal_labels"][terminal]["after_minutes"] = 31
        self.assertTrue([f for f in declaration_faults(policy) if f.startswith(f"{terminal}:")])

    def test_a_missing_workflow_directory_is_reported(self) -> None:
        self.assertTrue(undeclared([ROOT / "no-such-dir" / "workflows"], load_declaration()))


if __name__ == "__main__":
    sys.exit(unittest.main())
