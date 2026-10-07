#!/usr/bin/env python3
"""The tree-addressed cmux-tui publication carries the Linux daemon too.

Linux daemon mode (GPUI) fetches cmux-tui by the same tree key as the macOS
app (scripts/cmux-next/pin-cmux-tui.sh fetch picks the host's target). Both
tree publishers in cmux-tui-artifacts.yml must therefore download the Linux
musl build artifacts beside the macOS one, and take the list of companions
from the publisher (scripts/ci/publish-cmux-tui-tree.py --list-companions)
instead of a hand-written copy that can drift from it.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
TREE_JOBS = ("publish-tree", "publish-pr-tree")
ARTIFACTS = ("cmux-tui-aarch64-apple-darwin", "cmux-tui-x86_64-unknown-linux-musl",
             "cmux-tui-aarch64-unknown-linux-musl")
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$", re.M)


def jobs(text: str) -> dict[str, str]:
    body = text[text.index("\njobs:\n") + len("\njobs:\n"):]
    headers = list(JOB_HEADER.finditer(body))
    return {m.group(1): body[m.start():headers[i + 1].start() if i + 1 < len(headers) else len(body)]
            for i, m in enumerate(headers)}


class TreeTargets(unittest.TestCase):
    def test_tree_publishers_download_every_target(self) -> None:
        all_jobs = jobs(WORKFLOW.read_text(encoding="utf-8"))
        for job in TREE_JOBS:
            with self.subTest(job=job):
                block = all_jobs[job]
                for artifact in ARTIFACTS:
                    self.assertRegex(block, rf"(?m)^\s+name: {re.escape(artifact)}$",
                                     f"{job} does not download {artifact}")

    def test_tree_publishers_read_the_companion_list_from_the_publisher(self) -> None:
        all_jobs = jobs(WORKFLOW.read_text(encoding="utf-8"))
        for job in TREE_JOBS:
            with self.subTest(job=job):
                block = all_jobs[job]
                self.assertIn("--list-companions", block)
                self.assertNotIn('"cmux-tui-cloud-server-aarch64-apple-darwin")', block,
                                 f"{job} still hand-lists the companions")
                self.assertNotRegex(block, r"for asset in cmux-tui-aarch64-apple-darwin ",
                                    f"{job} still hand-lists the repair downloads")

    def test_the_tree_verification_checks_the_linux_daemon(self) -> None:
        block = jobs(WORKFLOW.read_text(encoding="utf-8"))["publish-tree"]
        verify = block[block.index("- name: Verify the tree publication"):]
        self.assertIn("x86_64-unknown-linux-musl", verify)
        self.assertIn("aarch64-unknown-linux-musl", verify)


if __name__ == "__main__":
    unittest.main()
