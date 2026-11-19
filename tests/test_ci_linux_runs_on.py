#!/usr/bin/env python3
"""Every own-branch Linux job runs on the literal cmux-linux (scripts/ci/check_linux_runs_on.py).

cmuxterm-hq#14156, "capacity comes to the job": one Linux label, one provider that brings a runner to it, and
overflow as more runners on that label. These tests pin what the checker accepts and refuses, then run it on this
repository's workflows.
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_linux_runs_on", ROOT / "scripts" / "ci" / "check_linux_runs_on.py")
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

FORK = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
FORK_PR = ("github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository"
           " && 'blacksmith-4vcpu-ubuntu-2404'")
POOLS = {"pools": {"linux_4": {"members": ["blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
                   "linux_arm64": {"members": ["blacksmith-4vcpu-ubuntu-2404-arm"]},
                   "macos_26": {"members": ["blacksmith-6vcpu-macos-26"]},
                   "provenance": {"hosted": True, "members": ["ubuntu-24.04"]}}}


class LinuxRunsOn(unittest.TestCase):
    def found(self, runs_on: str, extra: str = "") -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github" / "workflows").mkdir(parents=True)
            (root / ".github" / "runners.json").write_text(json.dumps(POOLS))
            (root / ".github" / "workflows" / "w.yml").write_text(
                f"on: push\njobs:\n  a:\n{extra}    runs-on: {runs_on}\n    steps:\n      - run: true\n")
            return check.problems(root / ".github" / "workflows", root)

    def test_accepts_the_one_label_and_its_fork_branches(self):
        for good in ("cmux-linux",
                     f"${{{{ {FORK} || 'cmux-linux' }}}}",
                     f"${{{{ {FORK} || {FORK_PR} || 'cmux-linux' }}}}",
                     "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request'"
                     " && github.event.pull_request.head.repo.full_name != github.repository && !contains(fromJSON("
                     "inputs.owned_head_repos), github.event.pull_request.head.repo.full_name) && "
                     "'blacksmith-4vcpu-ubuntu-2404' || 'cmux-linux' }}",
                     "ubuntu-latest # github-hosted-required: npm provenance needs GitHub's OIDC",
                     "${{ fromJSON(vars.RUNNER_POOLS).macos_26 }}",
                     "${{ vars.CI_COMPILE_CHECK_GATEWAY || 'cmux-linux' }}",
                     "${{ fromJSON(vars.RUNNER_POOLS).linux_arm64 }}",
                     "blacksmith-6vcpu-macos-26",
                     "${{ needs.pick.outputs.mac_runner || 'cmux-linux' }}"):
            with self.subTest(runs_on=good):
                self.assertEqual(self.found(good), [])

    def test_refuses_every_other_linux_route(self):
        for bad in ("blacksmith-4vcpu-ubuntu-2404",
                    "ubuntu-24.04",
                    "cmux-gcp-lane-x64",
                    "[cmux-fleet-linux-x64]",
                    f"${{{{ {FORK} || fromJSON(vars.RUNNER_POOLS).linux_4 }}}}",
                    f"${{{{ {FORK} || vars.LINUX_RUNNER || 'cmux-linux' }}}}",
                    f"${{{{ {FORK} || !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && 'cmux-linux' || 'cmux-linux' }}}}",
                    f"${{{{ {FORK} || needs.placement.outputs.linux_runner || 'cmux-linux' }}}}",
                    f"${{{{ {FORK} || github.run_attempt == 1 && 'cmux-gcp-lane-build-x64' || 'cmux-linux' }}}}",
                    f"${{{{ {FORK} || vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}}}",
                    "${{ github.repository_owner == 'manaflow-ai' && 'blacksmith-2vcpu-ubuntu-2404' || 'cmux-linux' }}"):
            with self.subTest(runs_on=bad):
                self.assertTrue(self.found(bad), bad)

    def test_reads_matrix_rows(self):
        matrix = ("    strategy:\n      matrix:\n        include:\n"
                  "          - runner: blacksmith-8vcpu-ubuntu-2404\n")
        self.assertTrue(self.found("${{ matrix.runner }}", matrix))
        self.assertEqual(self.found("${{ matrix.runner }}", matrix.replace("blacksmith-8vcpu-ubuntu-2404", "cmux-linux")),
                         [])

    def test_an_unreadable_expression_is_refused(self):
        self.assertTrue(self.found("${{ vars.X || ( }}"))

    def test_every_allowed_file_says_why(self):
        for name, why in check.ALLOWED.items():
            with self.subTest(name=name):
                self.assertTrue((ROOT / ".github" / "workflows" / name).is_file())
                self.assertGreater(len(why), 40)

    def test_this_repository(self):
        self.assertEqual(check.problems(ROOT / ".github" / "workflows"), [])


if __name__ == "__main__":
    unittest.main()
