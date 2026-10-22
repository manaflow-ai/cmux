#!/usr/bin/env python3
"""Every step only the nightly runs has a pull-request-time counterpart, or a reviewed reason.

`.github/nightly-step-coverage.json` lists every step of nightly.yml and the
local reusable workflows it calls (an external one is refused), keyed by job id
and step name ("uses: <action>" for an unnamed step), as one of:

  {"pr": "<workflow>:<job>:<step>"}  that step runs the same check for a
                                     feat-cmux-next pull request
  {"plumbing": true}                 checkout, setup, cache, artifact transfer
  {"nightly_only": "<reason>"}       needs secrets, the Release app or a Mac

plus an optional "note". Steps using an external PLUMBING_ACTIONS action need no
entry; local actions always do. A "pr" counterpart's workflow must admit a
feat-cmux-next pull request (pull_request trigger branches and paths, or a
caller that runs), and no caller job, job, needed job or step `if:` may be false
for it. Only comparisons of github.event_name, the base ref, needs.<job>.result,
a matrix value or a literal caller input decide; anything else may be true.
"""

from __future__ import annotations

import fnmatch
import json
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import detect_linux_guard_changes  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
REGISTRY = ROOT / ".github" / "nightly-step-coverage.json"
LOCAL_WORKFLOW = "./.github/workflows/"
KINDS = ("pr", "plumbing", "nightly_only")
MIN_REASON = 20
# Checkout, artifact transfer, caches and toolchain setup: no check of their own.
PLUMBING_ACTIONS = {
    "actions/checkout", "actions/upload-artifact", "actions/download-artifact", "actions/cache",
    "actions/setup-node", "actions/setup-go", "actions/setup-python", "oven-sh/setup-bun",
    "Swatinem/rust-cache",
}
EVENT, BASE = "pull_request", "feat-cmux-next"
# This job runs ci-guards.yml's groups through guards-local.sh --feat-routes, not `uses:`.
GUARDS_SCRIPT_ROUTE = ("cmux-next-guards.yml", "ci-guard-group", "ci-guards.yml")


def load_workflows(directory: Path = WORKFLOWS) -> dict:
    return {path.name: yaml.safe_load(path.read_text(encoding="utf-8"))
            for path in sorted(directory.glob("*.y*ml"))}


def triggers(workflow: dict) -> dict:
    # PyYAML reads the bare key `on` as the boolean True.
    on = workflow.get("on", workflow.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {event: None for event in on}
    return on if isinstance(on, dict) else {}


def jobs(workflow: dict) -> dict:
    return {job_id: job for job_id, job in (workflow.get("jobs") or {}).items() if isinstance(job, dict)}


def local_callee(job: dict):
    uses = job.get("uses")
    if isinstance(uses, str) and uses.startswith(LOCAL_WORKFLOW):
        return uses[len(LOCAL_WORKFLOW):].split("@", 1)[0]
    return None


def step_key(step: dict) -> str:
    name = step.get("name")
    if isinstance(name, str) and name:
        return name
    uses = step.get("uses")
    if isinstance(uses, str) and uses:
        return "uses: " + uses.split("@", 1)[0]
    raise AssertionError(f"a run step has no name: {str(step.get('run', ''))[:60]!r}; name it")


def is_plumbing(step: dict) -> bool:
    uses = step.get("uses")
    return isinstance(uses, str) and uses.split("@", 1)[0] in PLUMBING_ACTIONS


def label(key: tuple) -> str:
    return f"{key[0]} job {key[1]!r} step {key[2]!r}"


def nightly_steps(workflows: dict, roots: list, problems: list) -> dict:
    """{(workflow, job, step key): step} for every nightly step that is not derived plumbing."""
    steps, seen, queue = {}, [], list(roots)
    while queue:
        name = queue.pop(0)
        if name in seen:
            continue
        seen.append(name)
        for job_id, job in jobs(workflows[name]).items():
            callee = local_callee(job)
            if callee in workflows:
                queue.append(callee)
            elif "uses" in job:
                problems.append(f"{name} job {job_id!r}: {job['uses']!r} is not a local reusable workflow in "
                                ".github/workflows; the nightly may call only those, so their steps are covered")
            for step in job.get("steps") or []:
                if is_plumbing(step):
                    continue
                key = (name, job_id, step_key(step))
                if key in steps:
                    problems.append(f"{label(key)}: two steps share this name; name each")
                steps[key] = step
    return steps


def registry_entries(registry: dict) -> dict:
    entries = {}
    for workflow, job_map in registry["workflows"].items():
        for job_id, step_map in job_map.items():
            for key, entry in step_map.items():
                entries[(workflow, job_id, key)] = entry
    return entries


def entry_problem(entry):
    if not isinstance(entry, dict):
        return "not an object"
    kinds = [kind for kind in KINDS if kind in entry]
    if len(kinds) != 1 or set(entry) - set(KINDS) - {"note"}:
        return f"needs exactly one of {KINDS} (and optionally a note)"
    if "plumbing" in entry and entry["plumbing"] is not True:
        return "plumbing must be true"
    if "pr" in entry and not re.fullmatch(r"[^:]+:[^:]+:.+", str(entry["pr"] or "")):
        return f"pr must be <workflow>:<job>:<step>, got {entry['pr']!r}"
    if "nightly_only" in entry and (not isinstance(entry["nightly_only"], str)
                                    or len(entry["nightly_only"].strip()) < MIN_REASON):
        return "nightly_only needs a reason a reviewer can check"
    return None


def split_top(text: str, separator: str) -> list:
    """`text` split at each `separator` outside parentheses and quotes."""
    parts, depth, quote, start, i = [], 0, False, 0, 0
    while i < len(text):
        char = text[i]
        if char == "'":
            quote = not quote
        elif not quote and char in "()":
            depth += 1 if char == "(" else -1
        elif not quote and depth == 0 and text.startswith(separator, i):
            parts.append(text[start:i])
            start = i = i + len(separator)
            continue
        i += 1
    return parts + [text[start:]]


def unwrap(text: str) -> str:
    """`text` without parentheses that enclose all of it."""
    text = text.strip()
    while text.startswith("(") and text.endswith(")"):
        depth, quote = 0, False
        for i, char in enumerate(text):
            quote = not quote if char == "'" else quote
            depth += 0 if quote else {"(": 1, ")": -1}.get(char, 0)
            if depth == 0 and i < len(text) - 1:
                return text
        text = text[1:-1].strip()
    return text


COMPARISON = re.compile(r"^([\w.-]+)\s*(==|!=)\s*'([^']*)'$|^'([^']*)'\s*(==|!=)\s*([\w.-]+)$")


def atom_value(atom: str, context: dict):
    """True, False, or None (unknown) for one comparison under a feat-cmux-next pull request."""
    match = COMPARISON.match(atom)
    if not match:
        return None
    name, op, literal = (match.group(1), match.group(2), match.group(3)) if match.group(1) else (
        match.group(6), match.group(5), match.group(4))
    if name == "github.event_name":
        actual = {EVENT}
    elif name == "github.event.pull_request.base.ref":
        actual = {BASE}
    elif name.startswith("matrix.") and name[7:] in context.get("matrix", {}):
        actual = set(context["matrix"][name[7:]])
    elif name.startswith("inputs.") and name[7:] in context.get("inputs", {}):
        actual = {context["inputs"][name[7:]]}
    elif name.startswith("needs.") and name.endswith(".result") and name[6:-7] in context.get("skipped", ()):
        actual = {"skipped"}
    else:
        return None
    if op == "==":
        return literal in actual if len(actual) == 1 or literal not in actual else None
    return literal not in actual if len(actual) == 1 or literal not in actual else None


def can_hold(condition, context: dict) -> bool:
    """False only when a top-level `&&` term is false for a feat-cmux-next pull request.

    A term is false when every one of its `||` alternatives is a comparison that
    atom_value decides false; anything it cannot decide counts as possibly true.
    """
    if condition is None or isinstance(condition, bool):
        return condition is not False
    text = str(condition).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    for term in split_top(text, "&&"):
        alternatives = [unwrap(part) for part in split_top(unwrap(term), "||")]
        if all(atom_value(part, context) is False for part in alternatives):
            return False
    return True


def literal_input(value):
    """A caller's `with:` value as a string: plain, or a quoted literal in ${{ }}; else None."""
    quoted = re.fullmatch(r"\$\{\{\s*'([^']*)'\s*\}\}", str(value).strip())
    return quoted.group(1) if quoted else (None if "${{" in str(value) else str(value).strip())


def trigger_problem(workflow: dict):
    """Why the pull_request trigger never admits a feat-cmux-next pull request, or None."""
    config = triggers(workflow).get(EVENT) or {}
    branches, ignored = config.get("branches"), config.get("branches-ignore") or []
    if branches is not None and not any(fnmatch.fnmatchcase(BASE, glob) for glob in branches):
        return f"pull_request trigger branches {branches} do not admit {BASE}"
    if any(fnmatch.fnmatchcase(BASE, glob) for glob in ignored):
        return f"pull_request trigger branches-ignore {ignored} excludes {BASE}"
    if "paths" in config and not config["paths"]:
        return "pull_request trigger has empty paths"
    if set(config.get("paths-ignore") or []) & {"**", "**/*", "*"}:
        return "pull_request trigger paths-ignore ignores every path"
    return None


def skipped_jobs(workflow: dict, inputs: dict) -> dict:
    """{job id: why} for the jobs that cannot run for a feat-cmux-next pull request."""
    skipped, changed = {}, True
    while changed:
        changed = False
        for job_id, job in jobs(workflow).items():
            if job_id in skipped:
                continue
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else needs
            condition = str(job.get("if") or "")
            if not can_hold(job.get("if"), {"inputs": inputs, "skipped": skipped}):
                skipped[job_id] = f"job {job_id!r} if: {condition}"
            elif any(need in skipped for need in needs) and not re.search(r"always\(\)|cancelled\(\)|failure\(\)", condition):
                skipped[job_id] = f"job {job_id!r} needs a skipped job ({', '.join(n for n in needs if n in skipped)})"
            else:
                continue
            changed = True
    return skipped


def pr_routes(workflows: dict) -> dict:
    """{workflow: [caller inputs]} for each workflow that can run for a feat-cmux-next pull request."""
    routes = {name: [{}] for name, workflow in workflows.items()
              if EVENT in triggers(workflow) and trigger_problem(workflow) is None}
    caller, job_id, guards = GUARDS_SCRIPT_ROUTE
    runs = [str(step.get("run", "")) for step in (jobs(workflows.get(caller) or {}).get(job_id) or {}).get("steps", [])]
    if caller in routes and guards in workflows and any("guards-local.sh" in r and "--feat-routes" in r for r in runs):
        groups = detect_linux_guard_changes.FEAT_ALWAYS + detect_linux_guard_changes.FEAT_ROUTED
        routes[guards] = [{"linux_guard_tests": "true", "linux_guard_test_groups": json.dumps(list(groups))}]
    queue = [(name, inputs) for name in sorted(routes) for inputs in routes[name]]
    while queue:
        name, inputs = queue.pop(0)
        skipped = skipped_jobs(workflows[name], inputs)
        for job_id, job in jobs(workflows[name]).items():
            callee = local_callee(job)
            if callee not in workflows or job_id in skipped:
                continue
            passed = {key: literal_input(value) for key, value in (job.get("with") or {}).items()}
            passed = {key: value for key, value in passed.items() if value is not None}
            if passed not in routes.setdefault(callee, []):
                routes[callee].append(passed)
                queue.append((callee, passed))
    return routes


def matrix_values(job: dict, inputs: dict) -> dict:
    """{key: values} for each matrix key whose values are known, after include and exclude."""
    matrix = (job.get("strategy") or {}).get("matrix")
    if not isinstance(matrix, dict):
        return {}
    values = {}
    for key, raw in matrix.items():
        if key in ("include", "exclude"):
            continue
        source = re.fullmatch(r"\$\{\{\s*fromJSON\(inputs\.([\w-]+)\)\s*\}\}", raw) if isinstance(raw, str) else None
        if isinstance(raw, list):
            values[key] = [str(item) for item in raw]
        elif source and source.group(1) in inputs:
            try:
                values[key] = [str(item) for item in json.loads(inputs[source.group(1)])]
            except ValueError:
                pass
    for item in matrix.get("include") or []:
        for key, value in (item if isinstance(item, dict) else {}).items():
            if key in values and str(value) not in values[key]:
                values[key].append(str(value))
    for item in matrix.get("exclude") or []:
        if isinstance(item, dict) and len(item) == 1:
            ((key, value),) = item.items()
            if key in values:
                values[key] = [v for v in values[key] if v != str(value)]
    return values


def counterpart_problem(workflows: dict, routes: dict, target: str):
    workflow, job_id, name = target.split(":", 2)
    if workflow not in workflows:
        return f"no workflow {workflow}"
    if workflow not in routes:
        why = trigger_problem(workflows[workflow]) if EVENT in triggers(workflows[workflow]) else None
        return f"{workflow} does not run for a {BASE} pull request" + (f": {why}" if why else "")
    job = jobs(workflows[workflow]).get(job_id)
    if job is None:
        return f"{workflow} has no job {job_id!r}"
    matches = [step for step in job.get("steps") or [] if step_key(step) == name]
    if not matches:
        return f"{workflow} job {job_id!r} has no step {name!r}"
    reasons = []
    for inputs in routes[workflow]:
        context = {"inputs": inputs, "matrix": matrix_values(job, inputs)}
        skipped = skipped_jobs(workflows[workflow], inputs)
        if job_id in skipped:
            reasons.append(skipped[job_id])
        elif not can_hold(matches[0].get("if"), context):
            reasons.append(f"step {name!r} if: {matches[0]['if']} (matrix {context['matrix']}, inputs {inputs})")
        else:
            return None
    return f"{workflow} job {job_id!r} step {name!r} does not run for a {BASE} pull request: {reasons[0]}"


def coverage_problems(workflows: dict, registry: dict) -> list:
    problems = []
    roots = registry.get("roots") or []
    if "nightly.yml" not in roots:
        problems.append("roots must name nightly.yml")
    steps = nightly_steps(workflows, roots, problems)
    entries = registry_entries(registry)
    routes = pr_routes(workflows)
    for key in steps:
        if key not in entries:
            problems.append(
                f"{label(key)}: no entry. Add {{\"pr\": \"<workflow>:<job>:<step>\"}} naming the pull-request "
                "step that runs the same check, plumbing, or {\"nightly_only\": \"<why a pull request cannot>\"}")
    for key, entry in entries.items():
        if key not in steps:
            problems.append(f"{label(key)}: stale entry; the step is gone, renamed or derived plumbing")
            continue
        why = entry_problem(entry)
        if why is None and "pr" in entry:
            why = counterpart_problem(workflows, routes, entry["pr"])
        if why:
            problems.append(f"{label(key)}: {why}")
    return problems


class NightlyStepCoverageTests(unittest.TestCase):
    def test_the_nightly_is_covered(self) -> None:
        problems = coverage_problems(load_workflows(), json.loads(REGISTRY.read_text(encoding="utf-8")))
        self.assertEqual(problems, [], f"fix {REGISTRY.relative_to(ROOT)}:\n" + "\n".join(problems))


def counterpart(on=None, job=None, step_if=None) -> dict:
    """A pull-request workflow whose job `check` has the step `Dry run`."""
    step = {"name": "Dry run", "run": "true"}
    if step_if:
        step["if"] = step_if
    return {"on": on or {"pull_request": None}, "jobs": {"check": dict(job or {}, steps=[step])}}


class CoverageFixtureTests(unittest.TestCase):
    """The validator on fixtures: each rejection the live registry cannot show."""

    def problems(self, workflows: dict, entry=None, nightly_steps_=None) -> list:
        nightly = {"on": {"push": None}, "jobs": {"build": {"steps": nightly_steps_ or [
            {"name": "Gate", "run": "./gate.sh"}]}}}
        registry = {"roots": ["nightly.yml"], "workflows": {"nightly.yml": {"build": {
            "Gate": entry if entry is not None else {"pr": "pr.yml:check:Dry run"}}}}}
        return coverage_problems(dict(workflows, **{"nightly.yml": nightly}), registry)

    def assert_rejected(self, needle: str, problems: list) -> None:
        self.assertTrue([p for p in problems if needle in p], f"expected {needle!r} in {problems}")

    def test_a_reachable_counterpart_passes(self) -> None:
        self.assertEqual(self.problems({"pr.yml": counterpart()}), [])

    def test_missing_stale_and_malformed_entries(self) -> None:
        problems = self.problems({"pr.yml": counterpart()}, nightly_steps_=[{"name": "Renamed", "run": "true"}])
        self.assert_rejected("'Renamed': no entry", problems)
        self.assert_rejected("'Gate': stale entry", problems)
        for value in (None, "", "pr.yml:check", 3):
            self.assert_rejected("pr must be", self.problems({"pr.yml": counterpart()}, {"pr": value}))

    def test_pull_request_filters_must_admit_feat_cmux_next(self) -> None:
        for trigger in ({"branches": ["main"]}, {"branches-ignore": ["feat-*"]},
                        {"paths-ignore": ["**"]}, {"paths": []}):
            self.assert_rejected("pull_request trigger",
                                 self.problems({"pr.yml": counterpart(on={"pull_request": trigger})}))
        admitted = {"branches": ["feat-cmux-next"], "paths": ["scripts/**"]}
        self.assertEqual(self.problems({"pr.yml": counterpart(on={"pull_request": admitted})}), [])

    def test_caller_conditions_that_skip_pull_requests(self) -> None:
        callee = counterpart(on={"workflow_call": None})
        for condition in ("github.event_name == 'schedule'",
                          "github.event.pull_request.base.ref != 'feat-cmux-next'"):
            caller = {"on": {"pull_request": None}, "jobs": {"call": {
                "if": condition, "uses": "./.github/workflows/pr.yml"}}}
            self.assert_rejected("does not run for a feat-cmux-next pull request",
                                 self.problems({"pr.yml": callee, "caller.yml": caller}))

    def test_job_step_and_needed_job_conditions_that_skip_pull_requests(self) -> None:
        self.assert_rejected("job 'check'", self.problems(
            {"pr.yml": counterpart(job={"if": "github.event_name == 'workflow_dispatch'"})}))
        self.assert_rejected("step 'Dry run'", self.problems(
            {"pr.yml": counterpart(step_if="github.event_name == 'schedule'")}))
        workflow = counterpart(job={"needs": ["preflight"]})
        workflow["jobs"]["preflight"] = {"if": "github.event.pull_request.base.ref != 'feat-cmux-next'",
                                         "steps": [{"name": "Plan", "run": "true"}]}
        self.assert_rejected("needs a skipped job (preflight)", self.problems({"pr.yml": workflow}))
        workflow["jobs"]["check"]["if"] = "!cancelled() && needs.preflight.result == 'success'"
        self.assert_rejected("job 'check' if:", self.problems({"pr.yml": workflow}))

    def test_step_matrix_value_the_job_never_runs(self) -> None:
        absent = {"strategy": {"matrix": {"group": ["ci"]}}}
        excluded = {"strategy": {"matrix": {"group": ["ci", "release"], "exclude": [{"group": "release"}]}}}
        for job in (absent, excluded):
            self.assert_rejected("matrix", self.problems(
                {"pr.yml": counterpart(job=job, step_if="matrix.group == 'release'")}))

    def test_matrix_from_caller_input(self) -> None:
        callee = counterpart(on={"workflow_call": None},
                             job={"strategy": {"matrix": {"group": "${{ fromJSON(inputs.groups) }}"}}},
                             step_if="!cancelled() && matrix.group == 'release'")
        for groups, ok in (('["release"]', True), ('["ci"]', False)):
            caller = {"on": {"pull_request": None}, "jobs": {"call": {
                "uses": "./.github/workflows/pr.yml", "with": {"groups": groups}}}}
            problems = self.problems({"pr.yml": callee, "caller.yml": caller})
            self.assertEqual(problems == [], ok, problems)

    def test_external_reusable_workflow_in_the_nightly(self) -> None:
        nightly = {"jobs": {"x": {"uses": "owner/repo/.github/workflows/check.yml@abc"}}}
        self.assert_rejected("not a local reusable workflow", coverage_problems(
            {"nightly.yml": nightly}, {"roots": ["nightly.yml"], "workflows": {}}))

    def test_local_actions_are_never_derived_plumbing(self) -> None:
        self.assertEqual([action for action in PLUMBING_ACTIONS if action.startswith(".")], [])
        problems = self.problems({"pr.yml": counterpart()}, nightly_steps_=[
            {"name": "Gate", "run": "./gate.sh"}, {"uses": "./.github/actions/cache-restore"}])
        self.assert_rejected("'uses: ./.github/actions/cache-restore': no entry", problems)

    def test_ordered_negative_trigger_patterns(self) -> None:
        for trigger in ({"branches": ["**", "!" + BASE]}, {"paths": ["**", "!**"]},
                        {"paths-ignore": ["docs/**", "!docs/**", "**"]}):
            self.assert_rejected("pull_request trigger",
                                 self.problems({"pr.yml": counterpart(on={"pull_request": trigger})}))
        admitted = {"branches": ["feat-*", "!feat-x"], "paths": ["scripts/**", "!scripts/docs/**"]}
        self.assertEqual(self.problems({"pr.yml": counterpart(on={"pull_request": admitted})}), [])

    def test_guards_script_route_keeps_its_conditions(self) -> None:
        def route(job_if=None, step_if=None) -> dict:
            step = {"name": "Run guards", "run": "scripts/ci/guards-local.sh --feat-routes changed.txt"}
            if step_if is not None:
                step["if"] = step_if
            job = {"steps": [step]} if job_if is None else {"if": job_if, "steps": [step]}
            return {"on": {"pull_request": None}, "jobs": {"ci-guard-group": job}}
        guards = counterpart(on={"workflow_call": None}, step_if="matrix.group == 'release-notary'",
                             job={"strategy": {"matrix": {"group": "${{ fromJSON(inputs.linux_guard_test_groups) }}"}}})
        entry = {"pr": "ci-guards.yml:check:Dry run"}
        self.assertEqual(self.problems({"ci-guards.yml": guards, "cmux-next-guards.yml": route()}, entry), [])
        for workflow in (route(job_if=False), route(step_if="github.event_name == 'push'")):
            self.assert_rejected("does not run for a " + BASE + " pull request", self.problems(
                {"ci-guards.yml": guards, "cmux-next-guards.yml": workflow}, entry))

    def test_matrix_rows_follow_exclude_and_include(self) -> None:
        multi = {"group": ["ci", "release"], "os": ["ubuntu"], "exclude": [{"group": "release", "os": "ubuntu"}]}
        include_only = {"include": [{"group": "ci"}]}
        for matrix in (multi, include_only):
            self.assert_rejected("matrix", self.problems({"pr.yml": counterpart(
                job={"strategy": {"matrix": matrix}}, step_if="matrix.group == 'release'")}))
        self.assertEqual(self.problems({"pr.yml": counterpart(
            job={"strategy": {"matrix": include_only}}, step_if="matrix.group == 'ci'")}), [])

    def test_step_conditions_see_skipped_dependencies(self) -> None:
        workflow = counterpart(job={"needs": ["preflight"], "if": "always()"},
                               step_if="needs.preflight.result == 'success'")
        workflow["jobs"]["preflight"] = {"if": "github.event_name == 'push'", "steps": [{"name": "Plan", "run": "true"}]}
        self.assert_rejected("step 'Dry run'", self.problems({"pr.yml": workflow}))

    def test_and_binds_tighter_than_or(self) -> None:
        runs = "github.event_name == 'pull_request' || github.event_name == 'push' && github.event_name == 'schedule'"
        self.assertEqual(self.problems({"pr.yml": counterpart(step_if=runs)}), [])
        for never in ("(github.event_name == 'push' || github.event_name == 'schedule') && "
                      "github.event_name == 'pull_request'", "!(github.event_name == 'pull_request')"):
            self.assert_rejected("step 'Dry run'", self.problems({"pr.yml": counterpart(step_if=never)}))


if __name__ == "__main__":
    unittest.main()
