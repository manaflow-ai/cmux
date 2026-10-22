#!/usr/bin/env python3
"""Every step only the nightly runs has a pull-request-time counterpart, or a reviewed reason.

A direct push broke every nightly-next at a step only the nightly ran, so no
pull request could have seen it. `.github/nightly-step-coverage.json` lists
every step of the nightly workflow (nightly.yml and each reusable workflow it
calls, followed transitively) and says how a pull request exercises it:

  {"pr": "<workflow>:<job>:<step>"}  a step of a workflow that runs on
                                     pull_request (directly, or as a reusable
                                     workflow such a workflow calls) runs the
                                     same script, against fixtures or a dry run
  {"plumbing": true}                 checkout, setup, cache, artifact transfer
  {"nightly_only": "<reason>"}       needs the signing or publishing secrets,
                                     the Release app or a Mac, said precisely

An entry may add a "note". A step is keyed by its name; a step without one by
"uses: <action>" (the action without its pinned ref). A step that only uses a
PLUMBING_ACTIONS action is plumbing by derivation and has no entry. A new
nightly step fails this test until it has an entry, a renamed or removed one
until its entry goes, and a "pr" entry until the step it names exists.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
REGISTRY = ROOT / ".github" / "nightly-step-coverage.json"
LOCAL_WORKFLOW = "./.github/workflows/"
KINDS = ("pr", "plumbing", "nightly_only")
MIN_REASON = 20
# Checkout, artifact transfer, caches and toolchain setup: no check of their own.
PLUMBING_ACTIONS = {
    "actions/checkout", "actions/upload-artifact", "actions/download-artifact", "actions/cache",
    "actions/setup-node", "actions/setup-go", "actions/setup-python", "oven-sh/setup-bun",
    "Swatinem/rust-cache", "./.github/actions/cache-restore", "./.github/actions/cache-save",
}


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
            if callee:
                queue.append(callee)
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
    if "nightly_only" in entry and (not isinstance(entry["nightly_only"], str)
                                    or len(entry["nightly_only"].strip()) < MIN_REASON):
        return "nightly_only needs a reason a reviewer can check"
    return None


def pr_routes(workflows: dict) -> dict:
    """{workflow: [caller inputs]} for each workflow that runs for a feat-cmux-next pull request."""
    routes = {name: [{}] for name, workflow in workflows.items() if "pull_request" in triggers(workflow)}
    queue = sorted(routes)
    while queue:
        for job in jobs(workflows[queue.pop(0)]).values():
            callee = local_callee(job)
            if callee in workflows and callee not in routes:
                routes[callee] = [job.get("with") or {}]
                queue.append(callee)
    return routes


def counterpart_problem(workflows: dict, routes: dict, target):
    if target is None:
        return None
    parts = target.split(":", 2) if isinstance(target, str) else []
    if len(parts) != 3:
        return f"pr must be <workflow>:<job>:<step>, got {target!r}"
    workflow, job_id, name = parts
    if workflow not in workflows:
        return f"no workflow {workflow}"
    if workflow not in routes:
        return f"{workflow} does not run on pull_request"
    job = jobs(workflows[workflow]).get(job_id)
    if job is None:
        return f"{workflow} has no job {job_id!r}"
    if not [step for step in job.get("steps") or [] if step_key(step) == name]:
        return f"{workflow} job {job_id!r} has no step {name!r}"
    return None


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
        why = entry_problem(entry) or counterpart_problem(workflows, routes, entry.get("pr"))
        if why:
            problems.append(f"{label(key)}: {why}")
    return problems


def load_registry() -> dict:
    if not REGISTRY.exists():
        raise AssertionError(f"{REGISTRY.relative_to(ROOT)} is missing")
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


class NightlyStepCoverageTests(unittest.TestCase):
    def test_the_nightly_is_covered(self) -> None:
        problems = coverage_problems(load_workflows(), load_registry())
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

    def test_missing_and_stale_entries(self) -> None:
        problems = self.problems({"pr.yml": counterpart()}, nightly_steps_=[{"name": "Renamed", "run": "true"}])
        self.assert_rejected("'Renamed': no entry", problems)
        self.assert_rejected("'Gate': stale entry", problems)

    def test_pr_must_name_a_step(self) -> None:
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

    def test_job_and_step_conditions_that_skip_pull_requests(self) -> None:
        self.assert_rejected("job 'check'", self.problems(
            {"pr.yml": counterpart(job={"if": "github.event_name == 'workflow_dispatch'"})}))
        self.assert_rejected("step 'Dry run'", self.problems(
            {"pr.yml": counterpart(step_if="github.event_name == 'schedule'")}))

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


if __name__ == "__main__":
    unittest.main()
