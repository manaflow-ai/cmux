#!/usr/bin/env python3
"""A pull request whose router job failed runs no job that the router would have skipped, in any workflow.

2026-11-25 from 12Z GitHub's slowness failed path routing's checkout 702 times (8 the day before). fast-tier-cargo
read `needs.path_route.outputs.fast_tier_cargo != 'false'` under `!cancelled()`: a failed path_route has no outputs,
'' != 'false', so cargo ran in full on every such PR (~2.2k PR minutes that day). The same read sat in other
workflows' routers (ci.yml `changes`, cmux-next-guards.yml / cmux-next-react-doctor.yml `fast-check-route`,
cmux-tui-spec.yml `changes`, cmux-tui-sdks.yml `contract`, ...; hq issue cmux#58001), some of them failing open on
purpose with `needs.<router>.result != 'success' || ...`.

The rule: a job that reads a router output as "run unless told not to" (`needs.R.outputs.X != 'false'`) must, on a
pull request, also require that R did not break: `(github.event_name != 'pull_request' || needs.R.result ==
'success' ...)`, or an unconditional `needs.R.result == 'success' &&`. A failed router is a red check on the PR
already, and re-running it re-runs what it gates. On push and dispatch the read stays fail open, since running in
full is right on the base. A skipped router (its own tier or label conditions) keeps today's behaviour.
Coalesce jobs (base-coalesce.yml's `run`) are not routers: they fail open by design and are not checked here.
"""
from __future__ import annotations

import os
import re
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
WORKFLOW = os.path.join(WORKFLOWS, "cmux-next.yml")
FAIL_OPEN_READ = re.compile(r"needs\.([A-Za-z0-9_-]+)\.outputs\.(\w+) != 'false'")
NOT_ROUTERS = {"coalesce", "pure-checks-coalesce"}


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


def runs_for_pull_requests(path: str) -> bool:
    """A workflow a pull request can start: its own trigger, or a caller's (workflow_call keeps the event name)."""
    with open(path, encoding="utf-8") as fh:
        on = yaml.load(fh, Loader=yaml.BaseLoader).get("on") or {}
    names = on if isinstance(on, (list, dict)) else [on]
    return any(name in names for name in ("pull_request", "pull_request_target", "workflow_call"))


def guarded(cond: str, router: str) -> bool:
    """Whether a job condition requires `router` to have succeeded (or been skipped) on a pull request."""
    r = re.escape(router)
    if re.search(rf"\(github\.event_name != 'pull_request' \|\| needs\.{r}\.result == 'success'", cond):
        return True
    # An unconditional success requirement, and no explicit fail-open on the router's failure.
    return (re.search(rf"needs\.{r}\.result == 'success' &&", cond) is not None
            and f"needs.{router}.result != 'success'" not in cond)


def fail_open_readers() -> list[tuple[str, str, str, str]]:
    """(workflow, job, router, condition) for every job condition that reads a router output as `!= 'false'`."""
    found = []
    for name in sorted(os.listdir(WORKFLOWS)):
        path = os.path.join(WORKFLOWS, name)
        if not name.endswith((".yml", ".yaml")) or not runs_for_pull_requests(path):
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        if "\njobs:\n" not in text:
            continue
        for job, block in jobs(text).items():
            cond = re.search(r"^    if: (.*)$", block, re.M)
            if not cond:
                continue
            for router in sorted({r for r, _ in FAIL_OPEN_READ.findall(cond.group(1))} - NOT_ROUTERS):
                found.append((name, job, router, cond.group(1)))
    return found


class RouterFailureSkipsOnPullRequests(unittest.TestCase):
    def test_every_fail_open_router_read_needs_the_routers_success_on_a_pull_request(self):
        readers = fail_open_readers()
        bad = [f"{wf} :: {job} reads needs.{router}.outputs.X != 'false' but runs on a PR whose {router} failed"
               for wf, job, router, cond in readers if not guarded(cond, router)]
        self.assertEqual(bad, [], "\nadd (github.event_name != 'pull_request' || needs.R.result == 'success' || "
                                  "needs.R.result == 'skipped') to:\n" + "\n".join(bad))
        named = {(wf, job) for wf, job, _, _ in readers}
        # The sites cmux#58001 named, so a parser change that finds nothing cannot pass.
        for site in [("cmux-next.yml", "fast-tier-cargo"), ("ci.yml", "linux-preflight"),
                     ("cmux-next-guards.yml", "ci-guard-group"), ("cmux-next-guards.yml", "own-change-checks"),
                     ("cmux-tui-spec.yml", "acpmux-tests"), ("cmux-tui-sdks.yml", "conformance")]:
            self.assertIn(site, named)

    def test_the_detector_tells_a_guarded_read_from_a_fail_open_one(self):
        read = "needs.changes.outputs.macos != 'false'"
        self.assertFalse(guarded(f"!cancelled() && {read}", "changes"))
        self.assertFalse(guarded(f"!cancelled() && (needs.changes.result != 'success' || {read})", "changes"))
        self.assertFalse(guarded(f"(!cancelled() && (needs.changes.result == 'success' && x || "
                                 f"needs.changes.result != 'success' || {read}))", "changes"))
        self.assertTrue(guarded(f"(!cancelled() && {read}) && (github.event_name != 'pull_request' || "
                                "needs.changes.result == 'success' || needs.changes.result == 'skipped')", "changes"))
        self.assertTrue(guarded(f"!cancelled() && needs.changes.result == 'success' && {read}", "changes"))


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
            for router, output in FAIL_OPEN_READ.findall(cond.group(1)):
                if router != "path_route":
                    continue
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
