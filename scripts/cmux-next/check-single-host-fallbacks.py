#!/usr/bin/env python3
"""Every repository variable a runs-on reads declares its fallback in .github/single-host-fallbacks.json.

Leo's rule (2026-10-24): no job waits on one reserved machine; each single-host label, and each repository
variable a runs-on reads, says what takes the job instead and after how many minutes. The declaration used to
live only in the build-fleet repository, whose runner label policy test reads this repository's workflows live,
so cmux#40221 merged two undeclared runs-on variables green here and turned that repository red afterwards.
The declaration now lives here; the build-fleet test reads this file.

Read, for every job of every workflow under <root>/.github/workflows, through the one resolve step every
workflow guard shares (tests/workflow_jobs.py: resolve): its runs-on per matrix cell, literal indexes read as dot
form (`matrix['runner']`, `vars['X']`), an expression's literal branches, and a reusable workflow's `inputs.X`
traced to every value its callers pass (each caller's own matrix expanded, at any call depth). Then:
- every repository variable any of those values or unresolved parts reads, wherever it sits (`fromJSON(vars.X)`,
  `needs.a.outputs.b && vars.X || 'y'`), must be declared; one whose name is itself an expression cannot be, and
  is a finding;
- every resolved label that is single-host (a controller label or one starting with a `single_host_prefixes`
  entry) must be declared under `labels`.
A part that reads no variable (a needs output, an input with no caller) is not this policy's business.
The declaration must also promise a bounded fallback, by the build-fleet test's own schema rules.

The hook runs only installed code, so the installer puts tests/workflow_jobs.py beside this checker; it loads that
copy first, else the repository's.

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

# `vars.NAME` and `vars['NAME']`; GitHub matches variable names case-insensitively, so `vars.name` reads NAME.
VAR = re.compile(r"\bvars\s*(?:\.\s*(?P<dot>[A-Za-z_][A-Za-z0-9_]*)|\[\s*'(?P<key>[^']*)'\s*\])")
# The build-fleet test's label token, so both read the same labels off a line.
LABEL = re.compile(r"(?<![A-Za-z0-9_.-])([A-Za-z][A-Za-z0-9_.-]*)(?![A-Za-z0-9_.-])")
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


def load_workflow_jobs():
    """tests/workflow_jobs.py: the copy beside this file (the hook's installed checks), else this repository's."""
    import importlib.util

    here = Path(__file__).resolve().parent
    for path in (here / "workflow_jobs.py", here.parents[1] / "tests" / "workflow_jobs.py"):
        if path.is_file():
            spec = importlib.util.spec_from_file_location("single_host_workflow_jobs", path)
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            return module
    raise FileNotFoundError("tests/workflow_jobs.py is not beside the checker nor in its repository")


def variable_names(text: str) -> Iterator[str]:
    for match in VAR.finditer(text):
        yield (match.group("dot") or match.group("key")).upper()


def first_line(paths: list[Path], pattern: re.Pattern) -> tuple[Path, int]:
    """The first of PATHS with a line PATTERN matches, and that line; the first path and line 1 when none has one."""
    for path in paths:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if pattern.search(line):
                return path, number
    return paths[0], 1


# A repository variable read at all: `vars.` or `vars[`, whatever the name is.
ANY_VAR = re.compile(r"\bvars\s*[.\[]", re.IGNORECASE)
INPUT_READ = re.compile(r"\binputs\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)", re.IGNORECASE)


def written(wj, workflows, workflow: str, texts: list[str], seen: set) -> list[str]:
    """TEXTS as written (literal indexes in dot form), plus every caller's `with:` value for each `inputs.X` they
    read, followed through the callers' own inputs. The resolve step keeps only the values an expression can take,
    so a variable read in a condition (`vars.X == 'a' && 'a' || 'b'`) is in these, not in its values."""
    out = []
    for text in texts:
        text = wj.dotted(text)
        out.append(text)
        for name in INPUT_READ.findall(text):
            key = (workflow, name.lower())
            if key in seen:
                continue
            seen.add(key)
            for caller, _, job in workflows.callers(workflow):
                passed = [v for k, v in (job.get("with") or {}).items() if str(k).lower() == name.lower()]
                out += written(wj, workflows, caller, list(wj.strings(passed)), seen)
    return out


class Reads:
    """What a scan of some workflow directories read."""

    def __init__(self) -> None:
        # name -> [(where, file path relative to the repository root, line)]
        self.variables: dict[str, list[tuple[str, str, int]]] = {}
        self.lines: list[tuple[str, int, str]] = []  # (file, line, a resolved runs-on label)
        self.dynamic: list[tuple[str, str, int]] = []  # (where, file, line) of a variable read with no literal name
        self.unreadable: list[str] = []


def references(workflow_dirs: Iterable[Path]) -> Reads:
    import yaml  # here, so --advisory can report a missing PyYAML instead of failing

    wj = load_workflow_jobs()
    reads = Reads()
    for directory in workflow_dirs:
        if not directory.is_dir():
            reads.unreadable.append(f"{directory}: workflow directory is missing")
            continue
        paths = {p.name: p for p in sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")])}
        documents = {}
        for name, path in paths.items():
            try:
                documents[name] = wj.document(path)
            except (yaml.YAMLError, ValueError) as error:
                reads.unreadable.append(f"{name}: unreadable YAML: {error.__class__.__name__}")
        workflows = wj.Workflows(documents)
        everything = list(paths.values())
        for name, document in documents.items():
            rel = f"{WORKFLOWS}/{name}"
            for job_id, job in wj.jobs(document).items():
                if not isinstance(job, dict) or "runs-on" not in job:
                    continue
                where = f"{name}: job {job_id}"
                resolved = wj.resolve(job, job_id, name, workflows)
                # The job's file first, then the callers a traced input came from, for the annotation's line.
                search = [paths[name], *(p for p in everything if p != paths[name])]
                parts = set(resolved.runs_on | resolved.runs_on_unresolved)
                parts |= set(written(wj, workflows, name, list(wj.strings(job.get("runs-on"))), set()))
                if any(re.search(r"\bmatrix\b", part) for part in resolved.runs_on_unresolved):
                    # A matrix nothing could expand (an expression, a key it lacks): what it is built from may be a
                    # variable, so every string in it counts (fail closed).
                    strategy = job.get("strategy")
                    parts |= set(wj.strings(strategy.get("matrix") if isinstance(strategy, dict) else None))
                for value in sorted(parts):
                    text = wj.dotted(value if "${{" in value else f"${{{{ {value} }}}}")
                    names = list(variable_names(text))
                    for variable in names:
                        places = reads.variables.setdefault(variable, [])
                        if all(not seen.endswith(f": {where}") for seen, _, _ in places):
                            path, line = first_line(search, re.compile(
                                rf"\bvars\s*(?:\.\s*{re.escape(variable)}\b|\[\s*['\"]{re.escape(variable)}['\"]\s*\])",
                                re.IGNORECASE))
                            places.append((f"{path.name}:{line}: {where}", f"{WORKFLOWS}/{path.name}", line))
                    if len(ANY_VAR.findall(text)) > len(names) and all(not w.startswith(f"{where}: ")
                                                                        for w, _, _ in reads.dynamic):
                        path, line = first_line(search, ANY_VAR)
                        reads.dynamic.append((f"{where}: {value[:120]}", f"{WORKFLOWS}/{path.name}", line))
                for value in sorted(resolved.runs_on):
                    for label in LABEL.findall(value):
                        _, line = first_line([paths[name]], re.compile(rf"(?<![A-Za-z0-9_.-]){re.escape(label)}(?![A-Za-z0-9_.-])"))
                        reads.lines.append((rel, line, label))
    return reads


def findings(workflow_dirs: Iterable[Path], policy: dict) -> list[dict]:
    """Each runs-on variable or single-host label with no declared fallback, and what could not be read.

    A finding is {"key", "message", "file", "line"}; `key` names the undeclared thing (`vars.NAME`, a label),
    which is what the pre-push gate compares between the base and the head."""
    reads = references(workflow_dirs)
    found = [{"key": f"unreadable:{note}", "message": note, "file": WORKFLOWS, "line": 1, "status": INCOMPLETE}
             for note in reads.unreadable]
    for where, rel, line in reads.dynamic:
        found.append({"key": f"vars:dynamic:{where.split(': ', 2)[0]}:{where.split(': ', 2)[1]}", "file": rel,
                      "line": line, "status": FOUND,
                      "message": f"{where}: a runs-on reads a repository variable whose name is an expression, so "
                                 f"{DECLARATION} cannot declare its fallback; name the variable"})
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
