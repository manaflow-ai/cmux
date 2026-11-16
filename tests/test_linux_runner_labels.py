#!/usr/bin/env python3
"""scripts/ci/linux_runner_labels.py: Linux runner labels come from .github/runners.json pools, and new hand-typed ones fail."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import linux_runner_labels as lrl  # noqa: E402

OWNER = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
FORK = "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository"
POOLS = {
    "pools": {
        "$comment": ["test"],
        "linux_2": {"members": ["blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"]},
        "linux_8": {"members": ["blacksmith-8vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
        "macos_26": {"members": ["blacksmith-6vcpu-macos-26"]},
    }
}


class Tree:
    def __init__(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        (self.dir / ".github" / "workflows").mkdir(parents=True)
        (self.dir / "scripts" / "ci").mkdir(parents=True)
        (self.dir / ".github" / "runners.json").write_text(json.dumps(POOLS))

    def workflow(self, runs_on: str, name: str = "w.yml") -> Path:
        path = self.dir / ".github" / "workflows" / name
        path.write_text(f"on: push\njobs:\n  a:\n    runs-on: {runs_on}\n    steps:\n      - run: true\n")
        return path

    def baseline(self, text: str) -> None:
        (self.dir / "scripts" / "ci" / "linux-runner-labels-baseline.txt").write_text(text)

    def close(self) -> None:
        shutil.rmtree(self.dir)


class LinuxRunnerLabelsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = Tree()
        self.addCleanup(self.tree.close)

    def check(self) -> list[str]:
        return lrl.check(self.tree.dir)

    def test_pool_route_with_owner_and_matching_fork_branch_passes(self) -> None:
        self.tree.workflow(f"${{{{ {OWNER} || {FORK} && 'blacksmith-8vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_8 }}}}")
        self.assertEqual(self.check(), [])

    def test_new_hand_typed_label_fails_and_names_the_pool(self) -> None:
        self.tree.workflow(f"${{{{ {OWNER} || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}}}")
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("fromJSON(vars.RUNNER_POOLS).<pool>", problems[0])

    def test_bare_hosted_label_fails(self) -> None:
        self.tree.workflow("ubuntu-latest")
        self.assertEqual(len(self.check()), 1)

    def test_fork_branch_must_be_the_pool_first_member_and_fix_rewrites_it(self) -> None:
        path = self.tree.workflow(
            f"${{{{ {OWNER} || {FORK} && 'blacksmith-4vcpu-ubuntu-2404' || vars.CI_CLOUD_OVERFLOW_SAVED && "
            "fromJSON(vars.RUNNER_POOLS).linux_8 || fromJSON(vars.RUNNER_POOLS).linux_2 }}")
        problems = self.check()
        self.assertTrue(any("starts with 'blacksmith-2vcpu-ubuntu-2404'" in p for p in problems), problems)
        self.assertEqual(lrl.fix(self.tree.dir), 1)
        self.assertIn("&& 'blacksmith-2vcpu-ubuntu-2404' ||", path.read_text())
        self.assertEqual(self.check(), [])

    def test_each_fork_branch_takes_the_pool_read_right_after_it(self) -> None:
        path = self.tree.workflow(
            f"${{{{ {OWNER} || vars.CI_CLOUD_OVERFLOW_SAVED && ({FORK} && 'blacksmith-2vcpu-ubuntu-2404' || "
            f"fromJSON(vars.RUNNER_POOLS).linux_8) || ({FORK} && 'blacksmith-2vcpu-ubuntu-2404' || "
            "fromJSON(vars.RUNNER_POOLS).linux_2) }}")
        self.assertEqual(len(self.check()), 1)
        lrl.fix(self.tree.dir)
        text = path.read_text()
        self.assertIn("'blacksmith-8vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_8", text)
        self.assertIn("'blacksmith-2vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_2", text)
        self.assertEqual(self.check(), [])

    def test_fork_branch_reads_the_last_linux_pool_not_a_macos_one(self) -> None:
        self.tree.workflow(
            f"${{{{ {OWNER} || {FORK} && 'blacksmith-8vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_8 && "
            "fromJSON(vars.RUNNER_POOLS).macos_26 }}")
        self.assertEqual(self.check(), [])

    def test_baseline_allows_its_count_and_no_more(self) -> None:
        listed = "contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-2vcpu-ubuntu-2404\"]'), vars.CI_TRUSTED_RUNNER)"
        self.tree.workflow(f"${{{{ {OWNER} || {listed} && vars.CI_TRUSTED_RUNNER || fromJSON(vars.RUNNER_POOLS).linux_2 }}}}")
        self.tree.baseline("2 .github/workflows/w.yml\n")
        self.assertEqual(self.check(), [])
        self.tree.baseline("1 .github/workflows/w.yml\n")
        self.assertEqual(len(self.check()), 1)

    def test_comments_and_runner_name_checks_are_not_routes(self) -> None:
        path = self.tree.workflow("${{ fromJSON(vars.RUNNER_POOLS).linux_2 }} # was blacksmith-2vcpu-ubuntu-2404")
        path.write_text(path.read_text() + "    # ubuntu-latest used to run this\n"
                        "    if: ${{ !startsWith(runner.name, 'blacksmith-2vcpu-ubuntu-2404-') }}\n")
        self.assertEqual(self.check(), [])

    def test_repository_has_no_label_beyond_its_baseline(self) -> None:
        self.assertEqual(lrl.check(), [])


if __name__ == "__main__":
    unittest.main()
