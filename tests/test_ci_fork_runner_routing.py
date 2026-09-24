#!/usr/bin/env python3
"""Fork pull-request workflows must use GitHub-hosted runners with zero setup."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

FORK_LINUX_BRANCH = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
FORK_MACOS_BRANCH = "github.repository_owner != 'manaflow-ai' && 'macos-15'"
# A matrix job may instead pick a hosted label per row, e.g. to spread
# app-host shards over macos-15 and macos-26. Accepted only when every
# `hosted_runner:` value in the workflow is a GitHub-hosted macOS label.
FORK_MACOS_MATRIX_BRANCH = "github.repository_owner != 'manaflow-ai' && matrix.hosted_runner"
HOSTED_MACOS_LABELS = {"macos-15", "macos-26"}
LOCAL_WORKFLOW_CALL = re.compile(
    r"uses:\s+\./\.github/workflows/([A-Za-z0-9_.-]+\.ya?ml)"
)


def pull_request_workflows() -> list[Path]:
    result: list[Path] = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        if re.search(r"(?m)^  pull_request:\s*(?:$|\[|\{)", text):
            result.append(path)
    return result


def fork_exercised_workflows() -> list[Path]:
    """PR workflows plus every local reusable workflow reachable from them."""
    pending = list(pull_request_workflows())
    seen: set[Path] = set()
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        text = path.read_text(encoding="utf-8")
        for name in LOCAL_WORKFLOW_CALL.findall(text):
            called = WORKFLOWS / name
            if called.is_file() and called not in seen:
                pending.append(called)
    return sorted(seen)


def pull_request_selects(line: str, family: str) -> bool:
    """True when `github.event_name == 'pull_request'` selects a hosted label."""
    return bool(
        re.search(
            r"github\.event_name == 'pull_request' && '" + family + r"-[^']+'",
            line,
        )
    )


class ForkRunnerRoutingTests(unittest.TestCase):
    def test_pull_request_branch_must_select_the_hosted_label(self) -> None:
        selected = (
            "runs-on: ${{ github.event_name == 'pull_request' && 'ubuntu-latest'"
            " || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
        )
        inverted = (
            "runs-on: ${{ github.event_name == 'pull_request'"
            " && 'blacksmith-6vcpu-macos-15' || 'macos-15' }}"
        )
        inverted_linux = (
            "runs-on: ${{ github.event_name == 'pull_request'"
            " && 'blacksmith-4vcpu-ubuntu-2404' || 'ubuntu-24.04' }}"
        )
        self.assertTrue(pull_request_selects(selected, "ubuntu"))
        self.assertFalse(pull_request_selects(inverted, "macos"))
        self.assertFalse(pull_request_selects(inverted_linux, "ubuntu"))

    def test_pull_request_graph_is_nonempty_and_includes_reusable_workflows(self) -> None:
        roots = pull_request_workflows()
        graph = fork_exercised_workflows()
        self.assertTrue(roots)
        self.assertGreater(len(graph), len(roots))

    def test_every_fork_exercised_runner_has_a_hosted_path(self) -> None:
        """No fork PR may queue forever on organization-only capacity."""
        saw_linux = 0
        saw_macos = 0

        for path in fork_exercised_workflows():
            text = path.read_text(encoding="utf-8")
            hosted_rows = re.findall(r"(?m)^\s+hosted_runner:\s*(\S+)\s*$", text)
            matrix_hosted = bool(hosted_rows) and set(hosted_rows) <= HOSTED_MACOS_LABELS
            for number, line in enumerate(text.splitlines(), start=1):
                if "runs-on:" not in line:
                    continue

                # A few trust-boundary workflows already choose GitHub-hosted
                # capacity specifically for pull_request and use the repository
                # pool for push/main. That is equivalent to the owner branch,
                # but only when the hosted label is the value the pull_request
                # condition selects, not a label appearing later on the line.
                pull_request_linux = pull_request_selects(line, "ubuntu")
                pull_request_macos = pull_request_selects(line, "macos")
                hosted_linux = FORK_LINUX_BRANCH in line or pull_request_linux
                hosted_macos = (
                    FORK_MACOS_BRANCH in line
                    or pull_request_macos
                    or (matrix_hosted and FORK_MACOS_MATRIX_BRANCH in line)
                )

                with self.subTest(workflow=path.name, line=number):
                    if "vars.LINUX_RUNNER" in line:
                        saw_linux += 1
                        self.assertTrue(
                            hosted_linux,
                            f"{path.name}:{number} has no GitHub-hosted Linux fork branch",
                        )
                    if "vars.MACOS_RUNNER" in line:
                        saw_macos += 1
                        self.assertTrue(
                            hosted_macos,
                            f"{path.name}:{number} has no GitHub-hosted macOS fork branch",
                        )
                    if "blacksmith-" in line:
                        self.assertTrue(
                            hosted_linux or hosted_macos,
                            f"{path.name}:{number} can queue forever in a fork: {line.strip()}",
                        )
                    if re.search(r"\b(?:warp|depot|tart)-", line):
                        self.assertTrue(
                            hosted_linux or hosted_macos,
                            f"{path.name}:{number} can route a fork onto non-GitHub capacity",
                        )

        self.assertGreater(saw_linux, 0)
        self.assertGreater(saw_macos, 0)


if __name__ == "__main__":
    unittest.main()
