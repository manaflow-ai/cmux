#!/usr/bin/env python3
"""Every step only the nightly runs has a pull-request-time counterpart, or a reviewed reason.

`.github/nightly-step-coverage.json` keys every step of nightly.yml and the local
reusable workflows it calls by job id and step name ("uses: <action>" if unnamed):
{"pr": "<workflow>:<job>:<step>"} (that step runs the same check for a
feat-cmux-next pull request), {"plumbing": true}, or {"nightly_only": "<reason>"},
plus an optional "note". External PLUMBING_ACTIONS steps need no entry; local
actions do, and external reusable workflows are refused. A "pr" step must be
reachable: trigger filters, caller, job, needed-job and step `if:`s, matrix rows.
Conditions the evaluator cannot decide count as possibly true.
"""

from __future__ import annotations

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
    return on if isinstance(on, dict) else {event: None for event in ([on] if isinstance(on, str) else on or [])}


def jobs(workflow: dict) -> dict:
    return {job_id: job for job_id, job in (workflow.get("jobs") or {}).items() if isinstance(job, dict)}


def local_callee(job: dict):
    uses = str(job.get("uses") or "")
    return uses[len(LOCAL_WORKFLOW):].split("@", 1)[0] if uses.startswith(LOCAL_WORKFLOW) else None


def step_key(step: dict) -> str:
    if step.get("name") or step.get("uses"):
        return str(step.get("name") or "uses: " + str(step["uses"]).split("@", 1)[0])
    raise AssertionError(f"a run step has no name: {str(step.get('run', ''))[:60]!r}; name it")


def label(key: tuple) -> str:
    return f"{key[0]} job {key[1]!r} step {key[2]!r}"


def nightly_steps(workflows: dict, roots: list, problems: list) -> dict:
    """{(workflow, job, step key): step} for every nightly step that is not derived plumbing."""
    steps, seen, queue = {}, set(), list(roots)
    while queue:
        name = queue.pop(0)
        seen.add(name)
        for job_id, job in jobs(workflows[name]).items():
            callee = local_callee(job)
            if callee in workflows:
                queue += [] if callee in seen or callee in queue else [callee]
            elif "uses" in job:
                problems.append(f"{name} job {job_id!r}: {job['uses']!r} is not a local reusable workflow in "
                                ".github/workflows; the nightly may call only those, so their steps are covered")
            for step in [step for step in job.get("steps") or []
                         if str(step.get("uses") or "").split("@", 1)[0] not in PLUMBING_ACTIONS]:
                key = (name, job_id, step_key(step))
                if key in steps:
                    problems.append(f"{label(key)}: two steps share this name; name each")
                steps[key] = step
    return steps


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
        return {"true": True, "false": False}.get(atom)
    name, op, literal = match.group(1, 2, 3) if match.group(1) else match.group(6, 5, 4)
    row, skipped = context.get("matrix") or {}, context.get("skipped") or {}
    if name == "github.event_name":
        actual = EVENT
    elif name == "github.event.pull_request.base.ref":
        actual = BASE
    elif name.startswith("matrix.") and name[7:] in row:
        actual = row[name[7:]]
    elif name.startswith("inputs.") and name[7:] in context.get("inputs", {}):
        actual = context["inputs"][name[7:]]
    elif name.startswith("needs.") and name.endswith(".result") and name[6:-7] in skipped:
        actual = "skipped"
    else:
        return None
    return (actual.lower() == literal.lower()) == (op == "==")


def value(text: str, context: dict):
    """Three-valued: `||` binds loosest, then `&&`, then `!`; what it cannot read is None."""
    text = unwrap(text)
    for separator, absorbing in (("||", True), ("&&", False)):
        parts = split_top(text, separator)
        if len(parts) > 1:
            values = [value(part, context) for part in parts]
            if absorbing in values:
                return absorbing
            return (not absorbing) if all(v is (not absorbing) for v in values) else None
    if text.startswith("!") and not text.startswith("!="):
        inner = value(text[1:], context)
        return None if inner is None else not inner
    return atom_value(text, context)


def can_hold(condition, context: dict) -> bool:
    """False only when the condition is false for every feat-cmux-next pull request."""
    if condition is None or isinstance(condition, bool):
        return condition is not False
    text = str(condition).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    if text.count("(") != text.count(")"):
        return True
    return value(text, context) is not False


def literal_input(value):
    """A caller's `with:` value as a string: plain, or a quoted literal in ${{ }}; else None."""
    quoted = re.fullmatch(r"\$\{\{\s*'([^']*)'\s*\}\}", str(value).strip())
    return quoted.group(1) if quoted else (None if "${{" in str(value) else str(value).strip())


def glob_regex(pattern: str) -> str:
    """GitHub's filter glob: ** any, * no slash, ? and + quantify the previous character, [] a class."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out, i = out + ".*", i + 2
            continue
        char = pattern[i]
        if char == "[" and "]" in pattern[i:]:
            end = pattern.index("]", i)
            out, i = out + pattern[i:end + 1], end + 1
            continue
        out += {"*": "[^/]*", "?": "?", "+": "+"}.get(char, re.escape(char))
        i += 1
    return out


def last_match(value: str, patterns: list):
    """True or False for the last pattern (in order, `!` negates) that matches value; None if none does."""
    result = None
    for pattern in patterns:
        negated = str(pattern).startswith("!")
        if re.fullmatch(glob_regex(str(pattern)[1:] if negated else str(pattern)), value):
            result = not negated
    return result


def trigger_problem(workflow: dict):
    """Why the pull_request trigger never admits a feat-cmux-next pull request, or None."""
    config = triggers(workflow).get(EVENT) or {}
    try:
        if "branches" in config and last_match(BASE, config["branches"] or []) is not True:
            return f"pull_request trigger branches {config['branches']} do not admit {BASE}"
        if last_match(BASE, config.get("branches-ignore") or []) is True:
            return f"pull_request trigger branches-ignore {config['branches-ignore']} excludes {BASE}"
        # The last matching pattern decides: refuse only a list after whose last match-all
        # closing pattern nothing reopens (a positive in paths, a negation in paths-ignore).
        for key, closing in (("paths", "!"), ("paths-ignore", "")):
            patterns = [str(p) for p in config.get(key) or []]
            ends = [i for i, p in enumerate(patterns) if p in (closing + "**", closing + "**/*")]
            tail = patterns[ends[-1] + 1:] if ends else (None if key == "paths-ignore" else patterns)
            if key in config and tail is not None and not [p for p in tail if p.startswith("!") != (key == "paths")]:
                return f"pull_request trigger {key} {patterns} admit no path"
    except re.error as error:
        return f"pull_request trigger pattern cannot be checked ({error}); simplify it"
    return None


def skipped_jobs(workflow: dict, inputs: dict) -> dict:
    """{job id: why} for the jobs that cannot run for a feat-cmux-next pull request."""
    skipped, size = {}, -1
    while size != len(skipped):
        size = len(skipped)
        for job_id, job in jobs(workflow).items():
            needs = job.get("needs") or []
            needs, condition = [needs] if isinstance(needs, str) else needs, str(job.get("if") or "")
            if job_id not in skipped and not can_hold(job.get("if"), {"inputs": inputs, "skipped": skipped}):
                skipped[job_id] = f"job {job_id!r} if: {condition}"
            elif job_id not in skipped and any(need in skipped for need in needs) and not re.search(
                    r"always\(\)|cancelled\(\)|failure\(\)", condition):
                skipped[job_id] = f"job {job_id!r} needs a skipped job ({', '.join(n for n in needs if n in skipped)})"
    return skipped


def pr_routes(workflows: dict) -> dict:
    """{workflow: [caller inputs]} for each workflow that can run for a feat-cmux-next pull request."""
    routes = {name: [{}] for name, workflow in workflows.items()
              if EVENT in triggers(workflow) and trigger_problem(workflow) is None}
    caller, job_id, guards = GUARDS_SCRIPT_ROUTE
    skipped = skipped_jobs(workflows[caller], {}) if caller in routes else {job_id: "no route"}
    job = jobs(workflows.get(caller) or {}).get(job_id) or {}
    rows = matrix_rows(job, {})
    if job_id not in skipped and guards in workflows and any(
            "guards-local.sh" in str(step.get("run")) and "--feat-routes" in str(step.get("run"))
            and can_hold(step.get("if"), {"skipped": skipped, "matrix": row}) for step in job.get("steps") or []
            for row in (rows if rows is not None else [None])):
        groups = detect_linux_guard_changes.FEAT_ALWAYS + detect_linux_guard_changes.FEAT_ROUTED
        routes[guards] = [{"linux_guard_tests": "true", "linux_guard_test_groups": json.dumps(list(groups))}]
    queue = [(name, inputs) for name in sorted(routes) for inputs in routes[name]]
    while queue:
        name, inputs = queue.pop(0)
        skipped = skipped_jobs(workflows[name], inputs)
        for job_id, job in jobs(workflows[name]).items():
            callee = local_callee(job)
            if callee not in workflows or job_id in skipped or matrix_rows(job, inputs) == []:
                continue
            passed = {key: literal_input(value) for key, value in (job.get("with") or {}).items()}
            passed = {key: value for key, value in passed.items() if value is not None}
            if passed not in routes.setdefault(callee, []):
                routes[callee].append(passed)
                queue.append((callee, passed))
    return routes


def matrix_rows(job: dict, inputs: dict):
    """The job's matrix rows after exclude and include, [{}] without a matrix, None when unknown."""
    matrix = (job.get("strategy") or {}).get("matrix")
    if matrix is None:
        return [{}]
    if not isinstance(matrix, dict):
        return None
    keys = [key for key in matrix if key not in ("include", "exclude")]
    rows = [{}] if keys else []
    for key in keys:
        raw = matrix[key]
        source = re.fullmatch(r"\$\{\{\s*fromJSON\(inputs\.([\w-]+)\)\s*\}\}", raw) if isinstance(raw, str) else None
        if source and source.group(1) in inputs:
            try:
                raw = json.loads(inputs[source.group(1)])
            except ValueError:
                return None
        if not isinstance(raw, list):
            return None
        rows = [dict(row, **{key: str(item)}) for row in rows for item in raw]
    excludes, includes = matrix.get("exclude") or [], matrix.get("include") or []
    if not all(isinstance(item, dict) for item in list(excludes) + list(includes)):
        return None
    rows = [row for row in rows if not any(all(row.get(k) == str(v) for k, v in item.items()) for item in excludes)]
    # An include extends each original combination it does not contradict, else adds its own row.
    originals, added = [dict(row) for row in rows], []
    for item in includes:
        item = {k: str(v) for k, v in item.items()}
        fits = [row for row, original in zip(rows, originals) if all(original.get(k, v) == v for k, v in item.items())]
        for row in fits:
            row.update(item)
        added += [] if fits else [item]
    return rows + added


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
        skipped, rows = skipped_jobs(workflows[workflow], inputs), matrix_rows(job, inputs)
        if job_id in skipped:
            reasons.append(skipped[job_id])
        elif any(can_hold(matches[0].get("if"), {"inputs": inputs, "matrix": row, "skipped": skipped})
                 for row in (rows if rows is not None else [None])):
            return None
        else:
            reasons.append(f"step {name!r} if: {matches[0].get('if')} (matrix rows {rows}, inputs {inputs})")
    return f"{workflow} job {job_id!r} step {name!r} does not run for a {BASE} pull request: {reasons[0]}"


def coverage_problems(workflows: dict, registry: dict) -> list:
    problems = []
    roots = registry.get("roots") or []
    if "nightly.yml" not in roots:
        problems.append("roots must name nightly.yml")
    steps = nightly_steps(workflows, roots, problems)
    entries = {(workflow, job_id, key): entry for workflow, job_map in registry["workflows"].items()
               for job_id, step_map in job_map.items() for key, entry in step_map.items()}
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


def counterpart(on=None, job=None, step_if=None, pr="pull_request") -> dict:
    """A workflow whose job `check` has the step `Dry run`."""
    step = {"name": "Dry run", "run": "true"}
    if step_if is not None:
        step["if"] = step_if
    return {"on": on or {pr: None}, "jobs": {"check": dict(job or {}, steps=[step])}}


def caller(job: dict) -> dict:
    return {"on": {"pull_request": None}, "jobs": {"call": dict(job, uses="./.github/workflows/pr.yml")}}


def needing_preflight(job: dict, step_if=None) -> dict:
    workflow = counterpart(job=dict(job, needs=["preflight"]), step_if=step_if)
    workflow["jobs"]["preflight"] = {"if": "github.event_name == 'push'", "steps": [{"name": "Plan", "run": "true"}]}
    return workflow


def guards_route(job_if=None, step_if=None, matrix=None) -> dict:
    job = dict({} if job_if is None else {"if": job_if}, **(matrix_job(matrix) if matrix else {}))
    workflow = counterpart(job=job, step_if=step_if)
    workflow["jobs"]["check"]["steps"][0]["run"] = "scripts/ci/guards-local.sh --feat-routes changed.txt"
    return {"on": workflow["on"], "jobs": {"ci-guard-group": workflow["jobs"]["check"]}}


def matrix_job(matrix) -> dict:
    return {"strategy": {"matrix": matrix}}


GUARDS = counterpart(on={"workflow_call": None}, step_if="matrix.group == 'release-notary'",
                     job=matrix_job({"group": "${{ fromJSON(inputs.linux_guard_test_groups) }}"}))
CALLEE = counterpart(on={"workflow_call": None}, job=matrix_job({"group": "${{ fromJSON(inputs.groups) }}"}),
                     step_if="!cancelled() && matrix.group == 'release'")
PR_EVENT, PUSH, SCHEDULE = (f"github.event_name == '{event}'" for event in ("pull_request", "push", "schedule"))
RELEASE = "matrix.group == 'release'"


def filtered(**filters) -> dict:
    return {"pr.yml": counterpart(on={"pull_request": {k.replace("_", "-"): v for k, v in filters.items()}})}


def stepped(step_if: str, matrix=None) -> dict:
    return {"pr.yml": counterpart(step_if=step_if, job=matrix_job(matrix) if matrix else None)}


# (case, workflows; the entry names ci-guards.yml when present, else pr.yml; refusal needle or None to pass)
COUNTERPART_CASES = [
    ("plain", {"pr.yml": counterpart()}, None),
    ("branches main", filtered(branches=["main"]), "trigger"),
    ("branches-ignore", filtered(branches_ignore=["feat-*"]), "trigger"),
    ("branches negated", filtered(branches=["**", "!" + BASE]), "trigger"),
    ("paths empty", filtered(paths=[]), "trigger"),
    ("paths negated", filtered(paths=["**", "!**"]), "trigger"),
    ("paths-ignore all", filtered(paths_ignore=["docs/**", "!docs/**", "**"]), "trigger"),
    ("filters admit", filtered(branches=["feat-*", "!feat-x"], paths=["scripts/**", "!scripts/docs/**"]), None),
    ("paths narrower negation", filtered(paths=["src/**", "!src/x/**"]), None),
    ("caller schedule", {"pr.yml": counterpart(pr="workflow_call"), "c.yml": caller({"if": SCHEDULE})}, "does not run"),
    ("caller base", {"pr.yml": counterpart(pr="workflow_call"), "c.yml": caller(
        {"if": f"github.event.pull_request.base.ref != '{BASE}'"})}, "does not run"),
    ("caller empty matrix", {"pr.yml": counterpart(pr="workflow_call"), "c.yml": caller(
        matrix_job({"shard": ["a"], "exclude": [{"shard": "a"}]}))}, "does not run"),
    ("caller input row", {"pr.yml": CALLEE, "c.yml": caller({"with": {"groups": '["release"]'}})}, None),
    ("caller input no row", {"pr.yml": CALLEE, "c.yml": caller({"with": {"groups": '["ci"]'}})}, "matrix"),
    ("job dispatch", {"pr.yml": counterpart(job={"if": "github.event_name == 'workflow_dispatch'"})}, "job 'check'"),
    ("step schedule", stepped(SCHEDULE), "step 'Dry run'"),
    ("needs skipped", {"pr.yml": needing_preflight({})}, "needs a skipped job (preflight)"),
    ("needs result", {"pr.yml": needing_preflight({"if": "!cancelled() && needs.preflight.result == 'success'"})},
     "job 'check' if:"),
    ("step sees skipped", {"pr.yml": needing_preflight({"if": "always()"}, "needs.preflight.result == 'success'")},
     "step 'Dry run'"),
    ("and before or", stepped(f"{PR_EVENT} || {PUSH} && {SCHEDULE}"), None),
    ("parenthesized or", stepped(f"({PUSH} || {SCHEDULE}) && {PR_EVENT}"), "step 'Dry run'"),
    ("negation", stepped(f"!({PR_EVENT})"), "step 'Dry run'"),
    ("case-insensitive", stepped("github.event_name != 'PULL_REQUEST'"), "step 'Dry run'"),
    ("matrix absent", stepped(RELEASE, {"group": ["ci"]}), "matrix"),
    ("matrix exclude", stepped(RELEASE, {"group": ["ci", "release"], "exclude": [{"group": "release"}]}), "matrix"),
    ("matrix multi-key exclude", stepped(RELEASE, {"group": ["ci", "release"], "os": ["ubuntu"],
                                                   "exclude": [{"group": "release", "os": "ubuntu"}]}), "matrix"),
    ("matrix include only", stepped(RELEASE, {"include": [{"group": "ci"}]}), "matrix"),
    ("matrix include rows", stepped("matrix.group == 'ci'", {"include": [{"group": "ci"}, {"group": "x"}]}), None),
    ("guards route", {"ci-guards.yml": GUARDS, "cmux-next-guards.yml": guards_route()}, None),
    ("guards route job off", {"ci-guards.yml": GUARDS, "cmux-next-guards.yml": guards_route(job_if=False)},
     "does not run"),
    ("guards route step off", {"ci-guards.yml": GUARDS, "cmux-next-guards.yml": guards_route(step_if=PUSH)},
     "does not run"),
    ("guards route matrix", {"ci-guards.yml": GUARDS, "cmux-next-guards.yml": guards_route(
        step_if="matrix.shard == 'b'", matrix={"shard": ["a"]})}, "does not run"),
    ("guards route empty matrix", {"ci-guards.yml": GUARDS, "cmux-next-guards.yml": guards_route(
        matrix={"shard": ["a"], "exclude": [{"shard": "a"}]})}, "does not run"),
]


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

    def test_counterpart_cases(self) -> None:
        for case, workflows, needle in COUNTERPART_CASES:
            with self.subTest(case):
                target = "ci-guards.yml" if "ci-guards.yml" in workflows else "pr.yml"
                problems = self.problems(workflows, {"pr": target + ":check:Dry run"})
                if needle is None:
                    self.assertEqual(problems, [])
                else:
                    self.assert_rejected(needle, problems)

    def test_missing_stale_and_malformed_entries(self) -> None:
        problems = self.problems({"pr.yml": counterpart()}, nightly_steps_=[{"name": "Renamed", "run": "true"}])
        self.assert_rejected("'Renamed': no entry", problems)
        self.assert_rejected("'Gate': stale entry", problems)
        for value in (None, "", "pr.yml:check", 3):
            self.assert_rejected("pr must be", self.problems({"pr.yml": counterpart()}, {"pr": value}))

    def test_external_reusable_workflow_in_the_nightly(self) -> None:
        nightly = {"jobs": {"x": {"uses": "owner/repo/.github/workflows/check.yml@abc"}}}
        self.assert_rejected("not a local reusable workflow", coverage_problems(
            {"nightly.yml": nightly}, {"roots": ["nightly.yml"], "workflows": {}}))

    def test_local_actions_are_never_derived_plumbing(self) -> None:
        problems = self.problems({"pr.yml": counterpart()}, nightly_steps_=[
            {"name": "Gate", "run": "./gate.sh"}, {"uses": "./.github/actions/cache-restore"}])
        self.assert_rejected("'uses: ./.github/actions/cache-restore': no entry", problems)

if __name__ == "__main__":
    unittest.main()
