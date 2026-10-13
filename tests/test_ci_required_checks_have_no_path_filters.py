#!/usr/bin/env python3
"""A workflow that produces a required check must run on every pull request.

GitHub waits for each required context on every pull request. A workflow with
`paths` or `paths-ignore` on its pull_request, pull_request_target or
merge_group trigger does not start at all when the filter misses, so its check
never reports and the pull request sits on "Expected - Waiting for status to be
reported" with nothing red to say why.

#17415 did exactly that: it scoped backend-migrations.yml to backend paths, and
that workflow produces the required `backend migrations applied`. Every pull
request that did not touch the backend became unmergeable until #17432 reverted
it. A required workflow that only needs to act on some changes has to start
anyway and pass early, the way backend-migrations.yml's gate does.

The required contexts come from scripts/ci/required_status_checks.py, the
in-tree mirror of the ruleset, and are matched to jobs by name through the same
context_of() the timeout guard uses. A context that matches no job fails here
rather than quietly guarding nothing.

Run with workflow files as arguments to check them in place of the same-named
files under .github/workflows/, for example a version from history.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

from test_ci_required_checks_are_bounded import context_of, load

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

_SPEC = importlib.util.spec_from_file_location(
    "required_status_checks", ROOT / "scripts/ci/required_status_checks.py"
)
_required_status_checks = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
# Registered before execution: the module defines a dataclass.
sys.modules["required_status_checks"] = _required_status_checks
_SPEC.loader.exec_module(_required_status_checks)
REQUIRED_CHECKS = _required_status_checks.REQUIRED_CHECKS

# The events a required check has to report on before a pull request can merge.
GATING_EVENTS = ("pull_request", "pull_request_target", "merge_group")
FILTERS = ("paths", "paths-ignore")


def events(workflow: dict) -> dict:
    # PyYAML resolves a bare `on:` key to the boolean True.
    on = workflow.get("on", workflow.get(True))
    if isinstance(on, dict):
        return on
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return dict.fromkeys(on)
    return {}


def violations(workflows: dict[Path, dict], required: tuple[str, ...] = REQUIRED_CHECKS) -> list[str]:
    owners: dict[str, set[Path]] = {}
    for path, workflow in workflows.items():
        for job_id, job in (workflow.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            try:
                context = context_of(job_id, job, path, workflow)
            except ValueError:
                # The timeout guard reports a malformed CLA route; here it is
                # enough that the job cannot be matched by name.
                continue
            if context in required:
                owners.setdefault(context, set()).add(path)

    failures = [
        f"required check {context!r} matches no job, so nothing here can guard it"
        for context in required
        if context not in owners
    ]
    for context in required:
        for path in sorted(owners.get(context, ())):
            triggers = events(workflows[path])
            for event in GATING_EVENTS:
                config = triggers.get(event)
                if not isinstance(config, dict):
                    continue
                for key in FILTERS:
                    if key in config:
                        failures.append(
                            f"{path.name} produces the required check {context!r} but "
                            f"filters `{event}` with `{key}`; pull requests outside "
                            "those paths never get the check and cannot merge"
                        )
    return failures


def workflow_set(overrides: list[Path]) -> dict[Path, dict]:
    paths = {p.name: p for p in sorted(WORKFLOWS.glob("*.y*ml"))}
    for override in overrides:
        paths[override.name] = override
    return {WORKFLOWS / name: load(path) for name, path in paths.items()}


def main(argv: list[str]) -> int:
    failures = violations(workflow_set([Path(arg) for arg in argv]))
    if failures:
        print("required checks behind a paths filter:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"{len(REQUIRED_CHECKS)} required checks report on every pull request (no paths filters)")
    return 0


class PathFilterTests(unittest.TestCase):
    def check(self, document: dict) -> list[str]:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "backend-migrations.yml"
            path.write_text(yaml.safe_dump(document), encoding="utf-8")
            return violations(workflow_set([path]))

    def backend_migrations(self) -> dict:
        return load(WORKFLOWS / "backend-migrations.yml")

    def test_current_tree_passes(self) -> None:
        self.assertEqual(violations(workflow_set([])), [])

    def test_paths_on_pull_request_target_is_rejected(self) -> None:
        document = self.backend_migrations()
        events(document)["pull_request_target"]["paths"] = ["backend/**"]
        self.assertTrue(any("backend migrations applied" in f for f in self.check(document)))

    def test_paths_ignore_on_merge_group_is_rejected(self) -> None:
        document = self.backend_migrations()
        events(document)["merge_group"]["paths-ignore"] = ["docs/**"]
        self.assertTrue(any("`merge_group` with `paths-ignore`" in f for f in self.check(document)))

    def test_paths_on_push_is_allowed(self) -> None:
        # push never gates a pull request, so web-complexity-trusted.yml's
        # push filter is fine.
        document = self.backend_migrations()
        events(document)["push"] = {"branches": ["main"], "paths": ["backend/**"]}
        self.assertEqual(self.check(document), [])

    def test_renamed_required_job_is_reported(self) -> None:
        document = self.backend_migrations()
        document["jobs"]["gate"]["name"] = "renamed"
        self.assertTrue(any("matches no job" in f for f in self.check(document)))


if __name__ == "__main__":
    if len(sys.argv) == 1:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(PathFilterTests)
        if not unittest.TextTestRunner().run(suite).wasSuccessful():
            sys.exit(1)
    sys.exit(main(sys.argv[1:]))
