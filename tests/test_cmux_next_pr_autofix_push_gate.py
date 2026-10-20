#!/usr/bin/env python3
"""The PR autofix pushes its repair commit only after the export areas were read.

A pushed autofix head carries an Autofix-Run trailer, and action-areas skips the
Mac exports for such a head. So a push made while action-areas was cancelled
(its full fetch hit the 5-minute timeout) or the Mac exports failed leaves the
pull request with stale exports that no later autofix run regenerates (seen on
#21814: run 39315375602).

The test loads the workflow and evaluates the push job's `if:` against each
combination of upstream results, so a regrouped or negated term fails it.

The workflow runs only on pull_request, and since 1aa405bc167d the push job's
`if:` starts with `github.event_name != 'pull_request'`: the job waits on the
protected cmux-pr-autofix environment, so it is switched off and the repairs
stay in the artifact. The test asserts that it stays off for a pull request,
and checks the rest of the gate with that one term set aside (another event),
so the gate is still right when the job is switched back on.
"""

import itertools
import re
import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next-pr-autofix.yml"
RESULTS = ("success", "failure", "cancelled", "skipped")
SAME_REPO = "github.event.pull_request.head.repo.full_name == github.repository"


def evaluate(expression: str, values: dict[str, str], same_repo: bool = True,
             event_name: str = "workflow_dispatch") -> bool:
    """Evaluates the push job's `if:` with GitHub's operators, for the terms it uses."""
    body = expression.strip()
    if body.startswith("${{") and body.endswith("}}"):
        body = body[3:-2]
    body = body.replace("github.event_name", repr(event_name))
    body = body.replace(SAME_REPO, "True" if same_repo else "False")
    body = body.replace("!cancelled()", "True")

    def value(match: re.Match[str]) -> str:
        key = match.group(0)
        if key not in values:
            raise AssertionError(f"push's if: reads {key}, which the test does not model")
        return repr(values[key])

    body = re.sub(r"needs\.[a-z-]+\.(?:result|outputs\.[a-z_]+)", value, body)
    body = body.replace("&&", " and ").replace("||", " or ")
    leftover = re.sub(r"'[^']*'|\b(?:and|or|not|True|False)\b|==|!=|[()\s]", "", body)
    if leftover:
        raise AssertionError(f"push's if: has a term the test does not model: {leftover!r}")
    return bool(eval(body, {"__builtins__": {}}, {}))  # noqa: S307 - only literals and operators remain


class PushGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.push = yaml.safe_load(WORKFLOW.read_text())["jobs"]["push"]

    def test_push_waits_for_the_export_areas_and_exports(self) -> None:
        needs = self.push["needs"]
        self.assertLessEqual({"action-areas", "action-exports", "repair"}, set(needs if isinstance(needs, list) else [needs]))

    def test_push_runs_only_after_the_areas_were_read_and_the_exports_made_or_not_needed(self) -> None:
        for areas, exports, repair in itertools.product(RESULTS, RESULTS, RESULTS):
            values = {
                "needs.action-areas.result": areas,
                "needs.action-exports.result": exports,
                "needs.repair.result": repair,
                "needs.repair.outputs.patch": "true",
            }
            expected = areas == "success" and exports in ("success", "skipped") and repair == "success"
            with self.subTest(areas=areas, exports=exports, repair=repair):
                self.assertEqual(evaluate(self.push["if"], values), expected)

    def test_push_needs_a_patch_and_a_same_repository_head(self) -> None:
        values = {
            "needs.action-areas.result": "success",
            "needs.action-exports.result": "skipped",
            "needs.repair.result": "success",
            "needs.repair.outputs.patch": "true",
        }
        self.assertTrue(evaluate(self.push["if"], values))
        self.assertFalse(evaluate(self.push["if"], {**values, "needs.repair.outputs.patch": "false"}))
        self.assertFalse(evaluate(self.push["if"], values, same_repo=False))

    def test_push_stays_off_for_the_pull_request_event(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text())
        self.assertEqual(set(workflow[True]), {"pull_request"})  # PyYAML reads `on:` as True
        for areas, exports, repair in itertools.product(RESULTS, RESULTS, RESULTS):
            values = {
                "needs.action-areas.result": areas,
                "needs.action-exports.result": exports,
                "needs.repair.result": repair,
                "needs.repair.outputs.patch": "true",
            }
            with self.subTest(areas=areas, exports=exports, repair=repair):
                self.assertFalse(evaluate(self.push["if"], values, event_name="pull_request"))


if __name__ == "__main__":
    unittest.main()
