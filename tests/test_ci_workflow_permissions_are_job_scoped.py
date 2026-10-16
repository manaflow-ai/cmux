#!/usr/bin/env python3
"""A workflow's top-level `permissions` may not grant a write scope.

The workflow-level block is the token every job gets unless it declares its
own. A write scope there reaches every job in the file, including ones added
later that never needed it. #17447 shipped ci-hosted-queue-rescue.yml with a
workflow-level `actions: write`; #17449 moved it to the one job that cancels
runs and left `permissions: {}` at the top.

So the top level may be absent (the repository default, read), `{}`, read
scopes, or `read-all`. Write scopes, and `write-all`, belong on the jobs that
use them.

Run with workflow files as arguments to check only those files, for example a
version from history.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

# Workflows that knowingly keep a workflow-level write scope, by file name, each
# with a one-line reason. Empty: every workflow that had one was moved to
# job-level blocks with the same grants when this guard landed.
ALLOWLIST: dict[str, str] = {}


def write_scopes(permissions: object) -> list[str]:
    if permissions == "write-all":
        return ["write-all"]
    if isinstance(permissions, dict):
        return sorted(f"{scope}: write" for scope, level in permissions.items() if level == "write")
    return []


def violations(paths: list[Path], allowlist: dict[str, str] = ALLOWLIST) -> list[str]:
    failures: list[str] = []
    seen: set[str] = set()
    for path in paths:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            continue
        seen.add(path.name)
        scopes = write_scopes(document.get("permissions"))
        if scopes and path.name not in allowlist:
            failures.append(
                f"{path.name} grants {', '.join(scopes)} at workflow level; set the top "
                "level to `{}` or read scopes and declare writes on the jobs that need them"
            )
        if not scopes and path.name in allowlist:
            failures.append(f"{path.name} is allowlisted but grants no workflow-level write; remove the entry")
    return failures


def main(argv: list[str]) -> int:
    paths = [Path(arg) for arg in argv] or sorted(WORKFLOWS.glob("*.y*ml"))
    failures = violations(paths)
    if not argv:
        failures += [f"allowlisted {name} does not exist" for name in ALLOWLIST if not (WORKFLOWS / name).exists()]
    if failures:
        print("workflow-wide write tokens:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"{len(paths)} workflows keep write scopes at job level")
    return 0


class WorkflowPermissionTests(unittest.TestCase):
    def check(self, permissions: object, allowlist: dict[str, str] | None = None) -> list[str]:
        document = {"name": "x", "on": "push", "jobs": {"a": {"runs-on": "ubuntu-24.04", "steps": []}}}
        if permissions is not None:
            document["permissions"] = permissions
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "x.yml"
            path.write_text(yaml.safe_dump(document), encoding="utf-8")
            return violations([path], allowlist if allowlist is not None else {})

    def test_current_tree_passes(self) -> None:
        self.assertEqual(violations(sorted(WORKFLOWS.glob("*.y*ml"))), [])

    def test_read_only_and_empty_blocks_pass(self) -> None:
        for permissions in (None, {}, {"contents": "read"}, "read-all"):
            self.assertEqual(self.check(permissions), [], permissions)

    def test_workflow_level_write_is_rejected(self) -> None:
        self.assertEqual(len(self.check({"contents": "read", "actions": "write"})), 1)

    def test_write_all_is_rejected(self) -> None:
        self.assertEqual(len(self.check("write-all")), 1)

    def test_allowlist_entry_must_still_be_needed(self) -> None:
        self.assertEqual(self.check({"actions": "write"}, {"x.yml": "reason"}), [])
        self.assertEqual(len(self.check({"actions": "read"}, {"x.yml": "reason"})), 1)


if __name__ == "__main__":
    if len(sys.argv) == 1:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(WorkflowPermissionTests)
        if not unittest.TextTestRunner().run(suite).wasSuccessful():
            sys.exit(1)
    sys.exit(main(sys.argv[1:]))
