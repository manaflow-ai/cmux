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


def load_workflow(name: str) -> dict:
    data = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise AssertionError(f"{name} is not a workflow mapping")
    return data


def triggers(workflow: dict) -> set:
    # PyYAML reads the bare key `on` as the boolean True.
    on = workflow.get("on", workflow.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, (list, dict)):
        return set(on)
    return set()


def called_workflows(workflow: dict) -> list:
    called = []
    for job in (workflow.get("jobs") or {}).values():
        uses = job.get("uses") if isinstance(job, dict) else None
        if isinstance(uses, str) and uses.startswith(LOCAL_WORKFLOW):
            called.append(uses[len(LOCAL_WORKFLOW):].split("@", 1)[0])
    return called


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


def job_steps(workflow: dict, job_id: str, skip_plumbing: bool = False) -> list:
    steps = workflow["jobs"][job_id].get("steps") or []
    return [step_key(step) for step in steps if not (skip_plumbing and is_plumbing(step))]


def nightly_workflows(roots: list) -> list:
    """The roots and every local reusable workflow they call, transitively."""
    seen, queue = [], list(roots)
    while queue:
        name = queue.pop(0)
        if name in seen:
            continue
        seen.append(name)
        queue.extend(called_workflows(load_workflow(name)))
    return seen


def nightly_steps(roots: list) -> dict:
    """{(workflow, job, step key): count} for every nightly step that is not derived plumbing."""
    counts = {}
    for name in nightly_workflows(roots):
        workflow = load_workflow(name)
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict) or "steps" not in job:
                continue
            for key in job_steps(workflow, job_id, skip_plumbing=True):
                counts[(name, job_id, key)] = counts.get((name, job_id, key), 0) + 1
    return counts


def pull_request_workflows() -> set:
    """Workflows that run for a pull request: triggered by one, or called by one that is."""
    names = sorted(path.name for path in WORKFLOWS.glob("*.yml"))
    loaded = {name: load_workflow(name) for name in names}
    reached = {name for name, workflow in loaded.items() if "pull_request" in triggers(workflow)}
    queue = sorted(reached)
    while queue:
        for callee in called_workflows(loaded[queue.pop(0)]):
            if callee in loaded and callee not in reached:
                reached.add(callee)
                queue.append(callee)
    return reached


def load_registry() -> dict:
    if not REGISTRY.exists():
        raise AssertionError(f"{REGISTRY.relative_to(ROOT)} is missing")
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def registry_entries(registry: dict) -> dict:
    entries = {}
    for workflow, jobs in registry["workflows"].items():
        for job_id, steps in jobs.items():
            for key, entry in steps.items():
                entries[(workflow, job_id, key)] = entry
    return entries


def label(key: tuple) -> str:
    return f"{key[0]} job {key[1]!r} step {key[2]!r}"


class NightlyStepCoverageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry = load_registry()
        cls.roots = cls.registry["roots"]
        cls.steps = nightly_steps(cls.roots)
        cls.entries = registry_entries(cls.registry)

    def test_roots_are_the_nightly(self) -> None:
        self.assertIn("nightly.yml", self.roots)
        self.assertTrue(set(self.registry["workflows"]) <= set(nightly_workflows(self.roots)),
                        "the registry names a workflow the nightly does not run")

    def test_step_keys_are_unique(self) -> None:
        duplicates = [label(key) for key, count in self.steps.items() if count > 1]
        self.assertEqual(duplicates, [], "name these steps so each has its own entry")

    def test_every_nightly_step_has_an_entry(self) -> None:
        missing = [label(key) for key in self.steps if key not in self.entries]
        self.assertEqual(
            missing, [],
            f"add each to {REGISTRY.relative_to(ROOT)}: {{\"pr\": \"<workflow>:<job>:<step>\"}} naming the "
            "pull-request step that runs the same check, {\"plumbing\": true}, or "
            "{\"nightly_only\": \"<why a pull request cannot run it>\"}",
        )

    def test_no_stale_entries(self) -> None:
        stale = [label(key) for key in self.entries if key not in self.steps]
        self.assertEqual(stale, [], "these steps are gone, renamed or derived plumbing (PLUMBING_ACTIONS); update their entries")

    def test_entries_have_one_kind(self) -> None:
        bad = []
        for key, entry in self.entries.items():
            if not isinstance(entry, dict):
                bad.append(f"{label(key)}: not an object")
                continue
            kinds = [kind for kind in KINDS if kind in entry]
            extra = set(entry) - set(KINDS) - {"note"}
            if len(kinds) != 1 or extra:
                bad.append(f"{label(key)}: needs exactly one of {KINDS} (and optionally a note)")
            elif "plumbing" in entry and entry["plumbing"] is not True:
                bad.append(f"{label(key)}: plumbing must be true")
            elif "nightly_only" in entry and (
                not isinstance(entry["nightly_only"], str) or len(entry["nightly_only"].strip()) < MIN_REASON
            ):
                bad.append(f"{label(key)}: nightly_only needs a reason a reviewer can check")
        self.assertEqual(bad, [])

    def test_pr_counterparts_exist_and_run_on_pull_requests(self) -> None:
        reachable = pull_request_workflows()
        bad = []
        for key, entry in self.entries.items():
            target = entry.get("pr") if isinstance(entry, dict) else None
            if target is None:
                continue
            parts = target.split(":", 2) if isinstance(target, str) else []
            if len(parts) != 3:
                bad.append(f"{label(key)}: pr must be <workflow>:<job>:<step>, got {target!r}")
                continue
            workflow, job_id, step = parts
            if not (WORKFLOWS / workflow).is_file():
                bad.append(f"{label(key)}: no workflow {workflow}")
                continue
            if workflow not in reachable:
                bad.append(f"{label(key)}: {workflow} does not run on pull_request")
                continue
            loaded = load_workflow(workflow)
            if job_id not in (loaded.get("jobs") or {}):
                bad.append(f"{label(key)}: {workflow} has no job {job_id!r}")
            elif step not in job_steps(loaded, job_id):
                bad.append(f"{label(key)}: {workflow} job {job_id!r} has no step {step!r}")
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
