#!/usr/bin/env python3
"""A job that runs past a skipped ancestor must not be skipped by its children's implicit success().

GitHub gives a job with no status function in its `if:` (always(), !cancelled(), failure(), success())
an implicit success(), and that looks at every ancestor, not only the jobs in `needs:`. So when job P
runs past a skipped ancestor A (P's `if:` has !cancelled() or always()), a child of P whose `if:` has no
status function is skipped too, though P succeeded.

That skipped cmux-tui-artifacts.yml's tree-owner-wait on every trunk push once #45997 put push-gate
(skipped on trunk refs) above tree-preflight: a run that did not own its tree key left no deferred
marker, adopt-commit-manifest wrote state=missing, and verify-cdn-publication went red (runs
44818589673 and 44834489171 on 2026-11-20). The same shape skipped rust-workspaces.yml's workspace
matrix whenever receipt was skipped, and cmux-vm.yml's smoke-staging on main pushes.

This scans every workflow: a job with a need P that has a status function and a skippable ancestor
(any job with an `if:`) must have a status function itself.
"""

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))
STATUS = re.compile(r"(?<![\w.-])(always|cancelled|failure|success)\s*\(")


def needs_of(job: dict) -> list[str]:
    needs = job.get("needs") or []
    return [needs] if isinstance(needs, str) else list(needs)


def has_status_function(job: dict) -> bool:
    return bool(STATUS.search(str(job.get("if") or "")))


def violations(jobs: dict) -> list[str]:
    ancestors: dict[str, set[str]] = {}

    def ancestors_of(name: str) -> set[str]:
        if name not in ancestors:
            ancestors[name] = set()
            found = set()
            for parent in needs_of(jobs.get(name) or {}):
                found |= {parent} | ancestors_of(parent)
            ancestors[name] = found
        return ancestors[name]

    found = []
    for name, job in jobs.items():
        if not isinstance(job, dict) or has_status_function(job):
            continue
        for parent in needs_of(job):
            parent_job = jobs.get(parent) or {}
            if not has_status_function(parent_job):
                continue  # A skipped ancestor skips the parent too; skipping this job with it is intended.
            skippable = sorted(a for a in ancestors_of(parent) if "if" in (jobs.get(a) or {}))
            if skippable:
                found.append(f"{name}: needs {parent}, which runs past skippable {', '.join(skippable)}; "
                             f"add !cancelled() (and needs.{parent}.result == 'success') to {name}'s if")
                break
    return found


class NeedsSkipPropagation(unittest.TestCase):
    def test_every_workflow(self) -> None:
        self.assertTrue(WORKFLOWS)
        problems = []
        for path in WORKFLOWS:
            workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader) or {}
            problems += [f"{path.name}: {v}" for v in violations(workflow.get("jobs") or {})]
        self.assertEqual(problems, [], "\n".join(problems))

    def test_detector_catches_the_tree_owner_wait_shape(self) -> None:
        jobs = {
            "push-gate": {"if": "github.ref != 'refs/heads/feat-cmux-next'"},
            "tree-preflight": {"needs": "push-gate", "if": "${{ !cancelled() }}"},
            "tree-owner-wait": {"needs": "tree-preflight", "if": "needs.tree-preflight.result == 'success'"},
            "plain-child": {"needs": "push-gate"},
        }
        self.assertEqual([v.split(":")[0] for v in violations(jobs)], ["tree-owner-wait"])
        jobs["tree-owner-wait"]["if"] = "${{ !cancelled() && needs.tree-preflight.result == 'success' }}"
        self.assertEqual(violations(jobs), [])


if __name__ == "__main__":
    unittest.main()
