#!/usr/bin/env python3
"""Every repository variable a runs-on reads declares its fallback in .github/single-host-fallbacks.json.

Leo's rule (2026-10-24): no job waits on one reserved machine; each single-host label, and each repository
variable a runs-on reads, says what takes the job instead and after how many minutes. The declaration used to
live only in the build-fleet repository, whose runner label policy test reads this repository's workflows live,
so cmux#40221 merged two undeclared runs-on variables green here and turned that repository red afterwards.
The declaration now lives here; the build-fleet test reads this file.

Read, for every workflow under <root>/.github/workflows:
- each `runs-on:` line, as the build-fleet test reads it (every `vars.NAME` on the line, and every single-host
  label: a controller label or one starting with a `single_host_prefixes` entry, which `labels` must declare);
- each job's parsed runs-on (a block list, a `group`/`labels` mapping), `vars.NAME`, `vars['NAME']` and
  `fromJSON(vars.NAME)` alike;
- the matrix values a runs-on reads through `matrix.KEY` (axes and `include`; a dynamic matrix whole);
- the `with:` values a caller passes to a local reusable workflow's input that reaches a runs-on there.
The declaration must also promise a bounded fallback, by the build-fleet test's own schema rules.

Where it runs. No CI gate (CLAUDE.md, Lawrence 2026-10-23: no new CI gates or tests). The mode is an explicit
flag, never read from the environment:
- strict (the default): print each finding and exit 1. scripts/cmux-next/prepush-gate.py runs it on the pre-push
  hook and a plain local run when a push changes .github/workflows/ or the declaration, and refuses only names
  the push adds; tests/test_ci_single_host_fallbacks.py runs it too.
- --advisory: what ci-guards.yml passes. One `::warning file=...,line=...::` per finding and a line in
  $GITHUB_STEP_SUMMARY, and exit 0 whatever it finds, even when it cannot run.
- --json: the findings as JSON (key, message, file, line, status), exit 0; the pre-push gate's input.

Every finding has a status. "found": the scan ran and found it. "incomplete": the scan (or a part of it) did not run,
so what it would have found is unknown: a declaration that is missing, unreadable or of the wrong shape, or a
workflow whose YAML does not load. The gate never subtracts an incomplete finding as old debt and refuses any push
whose head has one (Codex on #40840: a schema fault the base already had was subtracted, so a new vars.NAME at the
head passed with no scan at all).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Iterable, Iterator
from pathlib import Path

DECLARATION = ".github/single-host-fallbacks.json"
WORKFLOWS = ".github/workflows"
# A finding's status (see the module doc): the scan found it, or the scan did not run.
FOUND, INCOMPLETE = "found", "incomplete"

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
    if not isinstance(controller, list) or not all(isinstance(c, str) for c in controller):
        bad.append("controller_labels must be a list of label names")
    elif not set(controller) <= set(labels):
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
    if not isinstance(outputs, dict):
        bad.append("nightly_job_outputs must be an object")
        outputs = {}
    for key, entry in outputs.items():
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
            if not isinstance(label, str) or not label.strip():  # also a null or a list in the list
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


def scannable(policy: object) -> bool:
    """Whether the sections the workflow scan reads have the types it walks (Codex on #40799: `"variables": null`
    passed declaration_faults with a finding, then crashed findings(), so --json printed nothing)."""
    if not isinstance(policy, dict):
        return False
    labels, variables = policy.get("labels", {}), policy.get("variables", {})
    controller, prefixes = policy.get("controller_labels", []), policy.get("single_host_prefixes", [])
    return (isinstance(labels, dict) and isinstance(variables, dict)
            and isinstance(controller, list) and all(isinstance(c, str) for c in controller)
            and isinstance(prefixes, list) and all(isinstance(p, str) for p in prefixes))


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
    import yaml  # here, so --advisory can report a missing PyYAML instead of failing

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


def first_line(path: Path, name: str) -> int:
    """The first line of `path` that names the variable, for an annotation; 1 when none does."""
    pattern = re.compile(rf"\bvars\s*(?:\.\s*{re.escape(name)}\b|\[\s*'{re.escape(name)}'\s*\])", re.IGNORECASE)
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if pattern.search(line):
            return number
    return 1


class Reads:
    """What a scan of some workflow directories read."""

    def __init__(self) -> None:
        # name -> [(where, file path relative to the repository root, line)]
        self.variables: dict[str, list[tuple[str, str, int]]] = {}
        self.lines: list[tuple[str, int, str]] = []  # (file, line, runs-on value)
        self.unreadable: list[str] = []


def references(workflow_dirs: Iterable[Path]) -> Reads:
    import yaml

    reads = Reads()
    for directory in workflow_dirs:
        if not directory.is_dir():
            reads.unreadable.append(f"{directory}: workflow directory is missing")
            continue
        root = directory.parents[1]
        memo: dict[Path, set[str]] = {}
        for workflow in sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")]):
            rel = f"{WORKFLOWS}/{workflow.name}"

            def note(text: str, where: str, line: int | None = None) -> None:
                for name in variable_names(text):
                    places = reads.variables.setdefault(name, [])
                    if all(where != seen for seen, _, _ in places):
                        places.append((where, rel, line if line is not None else first_line(workflow, name)))

            for number, line in enumerate(workflow.read_text(encoding="utf-8").splitlines(), 1):
                match = RUNS_ON_LINE.match(line)
                if match:
                    reads.lines.append((rel, number, match.group("value")))
                    note(match.group("value"), f"{workflow.name}:{number}", number)
            try:
                document = load_workflow(workflow)
            except yaml.YAMLError as error:
                reads.unreadable.append(f"{workflow.name}: unreadable YAML: {error.__class__.__name__}")
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
                                note(text, f"{workflow.name}: job {name}: with.{key} (a runs-on input of {callee.name})")
    return reads


def findings(workflow_dirs: Iterable[Path], policy: dict) -> list[dict]:
    """Each runs-on variable or single-host label with no declared fallback, and what could not be read.

    A finding is {"key", "message", "file", "line"}; `key` names the undeclared thing (`vars.NAME`, a label),
    which is what the pre-push gate compares between the base and the head."""
    reads = references(workflow_dirs)
    found = [{"key": f"unreadable:{note}", "message": note, "file": WORKFLOWS, "line": 1, "status": INCOMPLETE}
             for note in reads.unreadable]
    declared = {name.upper() for name in policy.get("variables", {})}
    for name in sorted(reads.variables):
        if name in declared:
            continue
        places = reads.variables[name]
        found.append({"key": f"vars.{name}", "file": places[0][1], "line": places[0][2], "status": FOUND,
                      "message": f"vars.{name} is read by a runs-on but {DECLARATION} does not declare its fallback "
                                 f"(variables.{name}): {', '.join(where for where, _, _ in places)}"})
    labels = set(policy.get("labels", {}))
    controller = set(policy.get("controller_labels", []))
    prefixes = tuple(policy.get("single_host_prefixes", ()))
    for rel, number, value in reads.lines:
        for label in LABEL.findall(value):
            if label in labels or (label not in controller and not label.startswith(prefixes)):
                continue
            found.append({"key": f"label:{label}", "file": rel, "line": number, "status": FOUND,
                          "message": f"{Path(rel).name}:{number}: {label} is a single-host label with no declared "
                                     f"fallback (labels.{label})"})
    return found


def undeclared(workflow_dirs: Iterable[Path], policy: dict) -> list[str]:
    return [finding["message"] for finding in findings(workflow_dirs, policy)]


def check(root: Path) -> list[dict]:
    """Every finding for the repository at ROOT: the declaration's own faults, then the workflows'.

    A declaration the scan cannot walk (missing, not JSON, a section of the wrong type) gives INCOMPLETE findings
    only: no workflow was read, so none of them says anything about the runs-on lines."""
    path = root / DECLARATION
    if not path.is_file():
        return [{"key": "declaration:missing", "file": DECLARATION, "line": 1, "status": INCOMPLETE,
                 "message": f"{DECLARATION} is missing, so no runs-on variable has a declared fallback"}]
    try:
        policy = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        return [{"key": "declaration:unreadable", "file": DECLARATION, "line": 1, "status": INCOMPLETE,
                 "message": f"{DECLARATION} is not readable JSON, so no workflow was scanned: {error}"}]
    faults = declaration_faults(policy)
    if not scannable(policy):
        # A section of the wrong type (null, a list for an object) is never walked: the scan did not run.
        return [{"key": f"declaration:{fault}", "file": DECLARATION, "line": 1, "status": INCOMPLETE,
                 "message": f"{DECLARATION}: {fault} (no workflow was scanned)"}
                for fault in faults or ["a section the scan reads has the wrong type"]]
    found = [{"key": f"declaration:{fault}", "file": DECLARATION, "line": 1, "status": FOUND,
              "message": f"{DECLARATION}: {fault}"} for fault in faults]
    return found + findings([root / WORKFLOWS], policy)


def escape(text: str, properties: bool = False) -> str:
    """A workflow command value (GitHub's escaping: %, CR, LF; also : and , in a property)."""
    text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return text.replace(":", "%3A").replace(",", "%2C") if properties else text


def advisory(root: Path) -> int:
    """Warn on each finding, add a line to the step summary, and exit 0 whatever happens."""
    try:
        found = check(root)
    except Exception as error:  # advisory: a scan that cannot run warns, it never fails the step
        found = [{"key": "error", "file": DECLARATION, "line": 1, "status": INCOMPLETE,
                  "message": f"the single-host fallback scan could not run: {error.__class__.__name__}: {error}"}]
    for finding in found:
        print(f"::warning file={escape(finding['file'], True)},line={finding['line']},"
              f"title=Single-host fallback::{escape(finding['message'])}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            if found:
                handle.write(f"- Single-host fallbacks (advisory, not a gate): {len(found)} finding(s): "
                             + "; ".join(f"`{f['key']}`" for f in found) + f". Declare them in `{DECLARATION}`.\n")
            else:
                handle.write("- Single-host fallbacks (advisory, not a gate): every runs-on variable is declared.\n")
    print(f"single-host fallbacks (advisory): {len(found)} finding(s); this step's exit code is unchanged")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2],
                        help="the repository root holding .github/ (default: this checkout)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--advisory", action="store_true",
                      help="CI: one ::warning per finding and a step summary line, exit 0")
    mode.add_argument("--json", action="store_true", help="print the findings as JSON, exit 0 (the pre-push gate)")
    args = parser.parse_args(argv)
    if args.advisory:
        return advisory(args.root)
    found = check(args.root)
    if args.json:
        print(json.dumps(found))
        return 0
    for finding in found:
        print(finding["message"])
    if found:
        print(f"single-host fallbacks: {len(found)} finding(s); declare each in {DECLARATION}", file=sys.stderr)
        return 1
    print("single-host fallbacks: every runs-on variable and single-host label is declared")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
