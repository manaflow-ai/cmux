#!/usr/bin/env python3
"""cmux-next.yml: a pull request whose path routing failed runs no job that path routing would have skipped.

2026-11-25 from 12Z GitHub's slowness failed path routing's checkout 702 times (8 the day before). fast-tier-cargo
read `needs.path_route.outputs.fast_tier_cargo != 'false'` under `!cancelled()`: a failed path_route has no outputs,
'' != 'false', so cargo ran in full on every such PR (~2.2k PR minutes that day). A PR job that reads a path_route
output as "run unless told not to" must also require path_route's success on a pull request; on push it stays fail
open, since running in full is right on the base. Path routing retries its checkout so the failure itself is rare.
"""
from __future__ import annotations

import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-next.yml")
FAIL_OPEN_READ = re.compile(r"needs\.path_route\.outputs\.(\w+) != 'false'")


def jobs(text: str) -> dict[str, str]:
    """{job id: its block} of the workflow's top-level jobs."""
    body = text.split("\njobs:\n", 1)[1]
    found, name, lines = {}, None, []
    for line in body.splitlines():
        head = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if head:
            if name:
                found[name] = "\n".join(lines)
            name, lines = head.group(1), []
        elif name:
            lines.append(line)
    if name:
        found[name] = "\n".join(lines)
    return found


class PathRouteFailureSkipsOnPullRequests(unittest.TestCase):
    def setUp(self):
        with open(WORKFLOW, encoding="utf-8") as fh:
            self.text = fh.read()
        self.jobs = jobs(self.text)

    def test_a_fail_open_read_of_path_route_needs_its_success_on_a_pull_request(self):
        readers = []
        for name, block in self.jobs.items():
            cond = re.search(r"^    if: (.*)$", block, re.M)
            if not cond:
                continue
            for output in FAIL_OPEN_READ.findall(cond.group(1)):
                readers.append(name)
                self.assertIn(f"(github.event_name != 'pull_request' || needs.path_route.result == 'success' && "
                              f"needs.path_route.outputs.{output} != 'false')", cond.group(1),
                              f"{name}: a failed path_route reads as '' != 'false' and runs it in full on a PR")
        self.assertIn("fast-tier-cargo", readers)

    def test_path_route_tries_its_checkout_again(self):
        block = self.jobs["path_route"]
        self.assertIn("with: &path-route-checkout", block)
        self.assertEqual(block.count("with: *path-route-checkout"), 2)
        self.assertEqual(len(re.findall(r"if: steps\.checkout\.outcome == 'failure'$", block, re.M)), 2)


if __name__ == "__main__":
    unittest.main()
