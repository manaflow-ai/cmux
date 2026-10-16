#!/usr/bin/env python3
"""The mirror of GitHub's required status checks has to be checked against GitHub.

`REQUIRED_CHECKS` is a copy of a list that lives in a repository ruleset, where
nobody editing this tree can watch it change. Two drifts follow from that, and
neither one turns anything red by itself:

  settings -> tree   an admin adds a required check and no pull request updates
                     the tuple. Every pull request afterwards waits on a
                     context that no workflow produces.
  tree -> reality    a pull request renames the job behind a required check.
                     The tuple and the ruleset still agree with each other, and
                     both now name something nothing reports.

`tests/test_ci_merge_queue_required_checks.py` can see neither: it reads the
tuple and the workflows, which is the copy, never the source. These cases cover
`scripts/ci/required_status_checks.py`, which asks GitHub. They run over fixture
payloads so the guard lane stays offline; the live call belongs to
`.github/workflows/required-checks-drift.yml`.

What the fixtures mostly encode is the fail-closed rule. A reconciliation that
cannot read its source and reports success is the exact bug being fixed here,
so every unreadable, empty or unrecognised payload has to raise instead.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/required_status_checks.py"
WORKFLOW = ROOT / ".github/workflows/required-checks-drift.yml"
MERGE_QUEUE_GUARD = ROOT / "tests/test_ci_merge_queue_required_checks.py"

SPEC = importlib.util.spec_from_file_location("required_status_checks", SCRIPT)
checks = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["required_status_checks"] = checks
SPEC.loader.exec_module(checks)


def rules(*contexts: str, other_rules: bool = True) -> list[dict]:
    """The shape of GET /repos/{owner}/{repo}/rules/branches/{branch}."""
    payload: list[dict] = []
    if other_rules:
        payload += [{"type": "deletion"}, {"type": "non_fast_forward"}]
    payload.append(
        {
            "type": "required_status_checks",
            "parameters": {
                "strict_required_status_checks_policy": False,
                "required_status_checks": [
                    {"context": context, "integration_id": 15368} for context in contexts
                ],
            },
            "ruleset_id": 15917555,
        }
    )
    return payload


def check_runs(*names: str) -> dict:
    return {"total_count": len(names), "check_runs": [{"name": name} for name in names]}


def statuses(*contexts: str) -> dict:
    return {"state": "success", "statuses": [{"context": context} for context in contexts]}


class ContextsFromRules(unittest.TestCase):
    def test_reads_the_live_contexts(self) -> None:
        self.assertEqual(
            checks.contexts_from_rules(rules("ci-status", "web-validation")),
            frozenset({"ci-status", "web-validation"}),
        )

    def test_unions_every_ruleset_that_requires_checks(self) -> None:
        # Several rulesets can apply to one branch; each contributes contexts.
        payload = rules("ci-status") + rules("Web complexity", other_rules=False)
        self.assertEqual(
            checks.contexts_from_rules(payload),
            frozenset({"ci-status", "Web complexity"}),
        )

    def test_no_required_status_checks_rule_is_an_error(self) -> None:
        # Protection removed, or the endpoint answered about the wrong branch.
        # Either way the tuple cannot be reconciled, so this must not pass.
        with self.assertRaises(checks.DriftCheckError):
            checks.contexts_from_rules([{"type": "deletion"}])

    def test_a_rule_requiring_nothing_is_an_error(self) -> None:
        with self.assertRaises(checks.DriftCheckError):
            checks.contexts_from_rules(rules())

    def test_an_error_body_is_an_error(self) -> None:
        # A 404 body is a dict, not a list. Reading `.get` off it and finding
        # no rules is how a silent pass would happen.
        with self.assertRaises(checks.DriftCheckError):
            checks.contexts_from_rules({"message": "Not Found", "status": "404"})

    def test_an_unrecognised_rule_shape_is_an_error(self) -> None:
        with self.assertRaises(checks.DriftCheckError):
            checks.contexts_from_rules(
                [{"type": "required_status_checks", "parameters": {"required_status_checks": "all"}}]
            )


class ReportedContexts(unittest.TestCase):
    def test_unions_check_runs_and_commit_statuses(self) -> None:
        # A required context can be an Actions check run or a legacy commit
        # status. Reading only one endpoint would report the other as phantom.
        self.assertEqual(
            checks.reported_contexts(check_runs("ci-status"), statuses("web-validation")),
            frozenset({"ci-status", "web-validation"}),
        )

    def test_a_commit_with_no_checks_is_empty_not_an_error(self) -> None:
        self.assertEqual(checks.reported_contexts(check_runs(), statuses()), frozenset())

    def test_an_error_body_is_an_error(self) -> None:
        with self.assertRaises(checks.DriftCheckError):
            checks.reported_contexts({"message": "Not Found"}, statuses("ci-status"))


class Findings(unittest.TestCase):
    sample = {"aaa": frozenset({"ci-status", "web-validation"})}

    def test_agreement_is_clean(self) -> None:
        found = checks.findings(
            live=frozenset({"ci-status", "web-validation"}),
            committed=("ci-status", "web-validation"),
            reported_by_commit=self.sample,
        )
        self.assertTrue(found.ok())
        self.assertEqual((found.unmirrored, found.stale, found.unproduced), ((), (), ()))

    def test_a_required_check_missing_from_the_tuple(self) -> None:
        # The headline bug: an admin added "Nightly smoke", nobody edited the
        # tuple, and the merge queue guard stayed green.
        found = checks.findings(
            live=frozenset({"ci-status", "Nightly smoke"}),
            committed=("ci-status",),
            reported_by_commit={"aaa": frozenset({"ci-status", "Nightly smoke"})},
        )
        self.assertFalse(found.ok())
        self.assertEqual(found.unmirrored, ("Nightly smoke",))

    def test_a_tuple_entry_github_no_longer_requires(self) -> None:
        # The opposite direction. Harmless to the queue, but the merge queue
        # guard is spending its assertion on a check nothing gates on.
        found = checks.findings(
            live=frozenset({"ci-status"}),
            committed=("ci-status", "web-validation"),
            reported_by_commit=self.sample,
        )
        self.assertFalse(found.ok())
        self.assertEqual(found.stale, ("web-validation",))

    def test_a_required_check_nothing_produces(self) -> None:
        # Settings and tree agree; the producing job was renamed. Pull requests
        # hang on "Expected - Waiting for status to be reported".
        found = checks.findings(
            live=frozenset({"ci-status", "web-validation"}),
            committed=("ci-status", "web-validation"),
            reported_by_commit={"aaa": frozenset({"ci-status"}), "bbb": frozenset({"ci-status"})},
        )
        self.assertFalse(found.ok())
        self.assertEqual(found.unproduced, ("web-validation",))

    def test_reporting_on_one_sampled_commit_is_enough(self) -> None:
        # A path-filtered check does not report on every merge. Only a context
        # that reported on nothing at all is evidence of a phantom.
        found = checks.findings(
            live=frozenset({"ci-status", "web-validation"}),
            committed=("ci-status", "web-validation"),
            reported_by_commit={"aaa": frozenset({"ci-status"}), "bbb": frozenset({"web-validation"})},
        )
        self.assertTrue(found.ok())

    def test_an_empty_sample_is_an_error(self) -> None:
        # No merged pull requests read means no verdict on production. Saying
        # "nothing to check, pass" is how this class of guard fails silently.
        with self.assertRaises(checks.DriftCheckError):
            checks.findings(
                live=frozenset({"ci-status"}),
                committed=("ci-status",),
                reported_by_commit={},
            )

    def test_the_report_names_every_finding(self) -> None:
        found = checks.findings(
            live=frozenset({"Nightly smoke"}),
            committed=("ci-status",),
            reported_by_commit={"aaa": frozenset()},
        )
        report = found.report()
        for expected in ("Nightly smoke", "ci-status", SCRIPT.name):
            self.assertIn(expected, report)


class Wiring(unittest.TestCase):
    def test_the_merge_queue_guard_reads_this_tuple(self) -> None:
        # One copy. If the guard declares REQUIRED_CHECKS itself again, the
        # reconciliation above verifies a tuple nothing else consumes.
        source = MERGE_QUEUE_GUARD.read_text(encoding="utf-8")
        self.assertNotIn("REQUIRED_CHECKS = (", source)
        self.assertIn("required_status_checks", source)

    def test_the_committed_tuple_is_non_empty_and_sorted_by_nothing_but_itself(self) -> None:
        self.assertTrue(checks.REQUIRED_CHECKS)
        self.assertEqual(len(set(checks.REQUIRED_CHECKS)), len(checks.REQUIRED_CHECKS))

    def test_a_workflow_makes_the_live_call_on_a_schedule(self) -> None:
        # Nothing in the tree changes when an admin edits protection, so a
        # trigger that waits for a relevant push would wait forever.
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("schedule:", source)
        self.assertIn("cron:", source)
        self.assertIn(f"python3 {SCRIPT.relative_to(ROOT)}", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
