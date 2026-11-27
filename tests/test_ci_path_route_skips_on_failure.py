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
A condition that requires a positive router output also blocks execution when the outputs are empty.
Coalesce jobs and self-edit-sweep.yml's advisory optimization gate are not routers: they fail open by design;
test_ci_self_edit_sweep.py checks the sweep's intended failure behavior.
"""
from __future__ import annotations

import os
import re
import sys
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
WORKFLOW = os.path.join(WORKFLOWS, "cmux-next.yml")
FAIL_OPEN_READ = re.compile(r"needs\.([A-Za-z0-9_-]+)\.outputs\.(\w+) != 'false'")
NOT_ROUTERS = {"coalesce", "pure-checks-coalesce"}
# This optimization gate intentionally runs the journey when its decision is unavailable.
# Match the reusable workflow, not the caller's job name: a router named self-edit is still checked.
ADVISORY_GATE = "./.github/workflows/self-edit-sweep.yml"
sys.path.insert(0, os.path.join(ROOT, "scripts", "ci"))
from pr_test_lanes import Expression, UNKNOWN, truthy  # noqa: E402


# This crate-graph WASM check deliberately runs when routing fails. Pin both the
# site and complete condition so another job or a widened condition is still checked.
INTENTIONAL_FAIL_OPEN = {
    ("cmux-tui-spec.yml", "remote-web-wasm", "changes"):
        "${{ (inputs.only == '' || inputs.only == 'remote-web-wasm') && "
        "(!cancelled() && (needs.changes.result != 'success' || "
        "needs.changes.outputs.run == 'true' && needs.changes.outputs.remote_web_wasm != 'false')) }}",
}


def intentional_fail_open(workflow, job, router, condition):
    return INTENTIONAL_FAIL_OPEN.get((workflow, job, router)) == condition


def non_routers(text: str) -> set[str]:
    doc = yaml.load(text, Loader=yaml.BaseLoader)
    return NOT_ROUTERS | {name for name, job in doc.get("jobs", {}).items()
                          if job.get("uses") == ADVISORY_GATE}


class FailedRouterExpression(Expression):
    @staticmethod
    def call(name, args):
        # Do not borrow pr_test_lanes' assumption that earlier jobs passed.
        if name.lower() in ("success", "failure", "cancelled"):
            return UNKNOWN
        return Expression.call(name, args)


def blocked_without_router_outputs(cond: str, router: str) -> bool:
    """Prove the condition false with the failed router's outputs empty; other inputs stay unknown."""
    context = {"github.event_name": "pull_request", f"needs.{router}.result": "failure",
               "github.event.pull_request.labels.*.name": UNKNOWN}
    for output in re.findall(rf"needs\.{re.escape(router)}\.outputs\.\w+", cond):
        context[output] = ""
    expr = cond.strip()
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2]
    try:
        return truthy(FailedRouterExpression(expr, context).evaluate()) is False
    except (ValueError, IndexError):
        return False



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
    if blocked_without_router_outputs(cond, router):
        return True
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
        excluded = non_routers(text)
        for job, block in jobs(text).items():
            cond = re.search(r"^    if: (.*)$", block, re.M)
            if not cond:
                continue
            for router in sorted({r for r, _ in FAIL_OPEN_READ.findall(cond.group(1))} - excluded):
                found.append((name, job, router, cond.group(1)))
    return found


class RouterFailureSkipsOnPullRequests(unittest.TestCase):
    def test_every_fail_open_router_read_needs_the_routers_success_on_a_pull_request(self):
        readers = fail_open_readers()
        bad = [f"{wf} :: {job} reads needs.{router}.outputs.X != 'false' but runs on a PR whose {router} failed"
               for wf, job, router, cond in readers
               if not guarded(cond, router) and not intentional_fail_open(wf, job, router, cond)]
        self.assertEqual(bad, [], "\nadd (github.event_name != 'pull_request' || needs.R.result == 'success' || "
                                  "needs.R.result == 'skipped') to:\n" + "\n".join(bad))
        named = {(wf, job) for wf, job, _, _ in readers}
        # The sites cmux#58001 named, so a parser change that finds nothing cannot pass.
        for site in [("cmux-next.yml", "fast-tier-cargo"), ("ci.yml", "linux-preflight"),
                     ("cmux-next-guards.yml", "ci-guard-group"), ("cmux-next-guards.yml", "own-change-checks"),
                     ("cmux-tui-spec.yml", "acpmux-tests"), ("cmux-tui-sdks.yml", "conformance")]:
            self.assertIn(site, named)

    def test_intentional_exception_is_exact_and_still_present(self):
        readers = set(fail_open_readers())
        for site, condition in INTENTIONAL_FAIL_OPEN.items():
            self.assertIn((*site, condition), readers)
            self.assertTrue(intentional_fail_open(*site, condition))
            self.assertFalse(intentional_fail_open(site[0], "other-job", site[2], condition))
            self.assertFalse(intentional_fail_open("other.yml", site[1], site[2], condition))
            self.assertFalse(intentional_fail_open(site[0], site[1], "other-router", condition))
            self.assertFalse(intentional_fail_open(*site, condition + " || true"))

    def test_logical_operators_preserve_operands_and_unknown_values(self):
        cases = {
            "'' || 'fast'": "fast",
            "'slow' || 'fast'": "slow",
            "true && 'fast'": "fast",
            "'' && 'fast'": "",
            "false || 0": 0.0,
            "true && 'fast' || 'slow'": "fast",
            "('' || 'fast') == 'fast'": True,
            "('slow' && 'fast') == 'fast'": True,
        }
        for expression, expected in cases.items():
            with self.subTest(expression=expression):
                actual = Expression(expression, {}).evaluate()
                self.assertEqual(actual, expected)
                self.assertIs(type(actual), type(expected))
        for expression in ("(vars.x || 'fast') == 'fast'", "(vars.x && false) == ''"):
            self.assertIs(Expression(expression, {}).evaluate(), UNKNOWN)
        self.assertIs(truthy(Expression("vars.x && false", {}).evaluate()), False)
        self.assertIs(truthy(Expression("vars.x || 'fast'", {}).evaluate()), True)
        # Reusable-workflow inputs compare repr across matrix rows. Different
        # known truth values must not collapse to the first row's value.
        values = [Expression(expr, {}).evaluate() for expr in
                  ("vars.x", "vars.x && false", "vars.x || 'fast'")]
        self.assertEqual(len({repr(value) for value in values}), 3)
        self.assertFalse(guarded("(needs.changes.outputs.tier || 'fast') == 'fast' && "
                                 "needs.changes.outputs.run != 'false'", "changes"))

    def test_the_detector_tells_a_guarded_read_from_a_fail_open_one(self):
        read = "needs.changes.outputs.macos != 'false'"
        self.assertFalse(guarded(f"!cancelled() && {read}", "changes"))
        self.assertFalse(guarded(f"!cancelled() && (needs.changes.result != 'success' || {read})", "changes"))
        self.assertFalse(guarded(f"(!cancelled() && (needs.changes.result == 'success' && x || "
                                 f"needs.changes.result != 'success' || {read}))", "changes"))
        self.assertTrue(guarded(f"(!cancelled() && {read}) && (github.event_name != 'pull_request' || "
                                "needs.changes.result == 'success' || needs.changes.result == 'skipped')", "changes"))
        self.assertTrue(guarded(f"!cancelled() && needs.changes.result == 'success' && {read}", "changes"))

    def test_a_positive_output_requirement_blocks_a_failed_router(self):
        read = "needs.path_route.outputs.app_compile_pr != 'false'"
        native = "needs.path_route.outputs.native == 'true'"
        self.assertTrue(guarded(f"!cancelled() && ({native} && {read})", "path_route"))
        # An OR escape, a different router's output, or an unknown label must not prove safety.
        self.assertFalse(guarded(f"({native} && {read}) || vars.force == '1'", "path_route"))
        self.assertFalse(guarded(f"needs.other.outputs.native == 'true' && {read}", "path_route"))
        self.assertFalse(guarded(f"contains(github.event.pull_request.labels.*.name, 'full-ci') && {read}",
                                 "path_route"))
        self.assertFalse(guarded(f"failure() || ({native} && {read})", "path_route"))
        self.assertFalse(guarded(f"cancelled() || ({native} && {read})", "path_route"))

    def test_only_the_advisory_sweep_workflow_is_exempt(self):
        text = "jobs:\n  renamed-gate:\n    uses: " + ADVISORY_GATE + "\n  self-edit:\n    runs-on: ubuntu-latest\n"
        self.assertIn("renamed-gate", non_routers(text))
        self.assertNotIn("self-edit", non_routers(text))

    def test_tui_spec_router_retries_its_checkout_and_prefetches_what_it_widens_to(self):
        """cmux-tui-spec.yml `changes` widened with `git sparse-checkout set`: one lazy blob fetch that stalled whole."""
        with open(os.path.join(WORKFLOWS, "cmux-tui-spec.yml"), encoding="utf-8") as fh:
            block = jobs(fh.read())["changes"]
        self.assertIn("with: &tui-spec-route-checkout", block)
        self.assertEqual(block.count("with: *tui-spec-route-checkout"), 2)
        self.assertEqual(len(re.findall(r"if: steps\.checkout\.outcome == 'failure'$", block, re.M)), 2)
        self.assertNotIn("run: git sparse-checkout set", block)
        self.assertIn("/scripts/ci/prefetch-sparse-checkout.sh\n", block)
        self.assertIn("| bash scripts/ci/prefetch-sparse-checkout.sh", block)


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
                self.assertTrue(guarded(cond.group(1), router),
                                f"{name}: a failed path_route reads as '' != 'false' and runs it in full on a PR")
        self.assertIn("fast-tier-cargo", readers)

    def test_path_route_tries_its_checkout_again(self):
        block = self.jobs["path_route"]
        self.assertIn("with: &path-route-checkout", block)
        self.assertEqual(block.count("with: *path-route-checkout"), 2)
        self.assertEqual(len(re.findall(r"if: steps\.checkout\.outcome == 'failure'$", block, re.M)), 2)


if __name__ == "__main__":
    unittest.main()
