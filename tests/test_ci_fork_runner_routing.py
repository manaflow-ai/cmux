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


class ForkRunnerRoutingTests(unittest.TestCase):
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
            for number, line in enumerate(text.splitlines(), start=1):
                if "runs-on:" not in line:
                    continue

                # A few trust-boundary workflows already choose GitHub-hosted
                # capacity specifically for pull_request and use the repository
                # pool for push/main. That is equivalent to the owner branch.
                pull_request_linux = bool(
                    re.search(
                        r"github\.event_name == 'pull_request'.*'ubuntu-[^']+'",
                        line,
                    )
                )
                pull_request_macos = bool(
                    re.search(
                        r"github\.event_name == 'pull_request'.*'macos-[^']+'",
                        line,
                    )
                )
                hosted_linux = FORK_LINUX_BRANCH in line or pull_request_linux
                hosted_macos = FORK_MACOS_BRANCH in line or pull_request_macos

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
