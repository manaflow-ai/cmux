#!/usr/bin/env python3
"""A job whose `name:` is an expression must never be skipped on a PR into main when it answers a required check.

GitHub evaluates a job's `name:` expression only when the job runs. A job skipped by its `if:` publishes the raw
`${{ ... }}` text as its check name, so a required check such as `backend migrations applied` never reports and
GitHub refuses the merge. cmux#55305 (into main) sat blocked at a SHIP head this way: backend-migrations.yml's gate
skipped itself when the plan found no migration change.

Detector: every top-level `!(...)` skip clause in such a job's `if:` must be one that cannot hold on an open PR into
main: one scoped to `base.ref == 'feat-cmux-next'` or to a closed PR.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
# Checks main's ruleset requires that a workflow job publishes (CLA checks come from an app).
MAIN_REQUIRED = {"backend migrations applied"}
SAFE_SCOPES = ("base.ref == 'feat-cmux-next'", "pull_request.state == 'closed'")


def split_top(expression: str, op: str) -> list[str]:
    """Split an Actions expression at `op` outside parentheses and quotes."""
    parts, depth, quoted, start, i = [], 0, False, 0, 0
    while i < len(expression):
        c = expression[i]
        if c == "'":
            quoted = not quoted
        elif not quoted and c == "(":
            depth += 1
        elif not quoted and c == ")":
            depth -= 1
        elif not quoted and depth == 0 and expression.startswith(op, i):
            parts.append(expression[start:i].strip())
            i += len(op)
            start = i
            continue
        i += 1
    parts.append(expression[start:].strip())
    return parts


def clauses(condition: str) -> list[str]:
    text = condition.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    return split_top(text, "&&")


def unsafe_skips(condition: str, handed_off: set[str] = frozenset()) -> list[str]:
    """Return the `!(...)` clauses of `condition` that can skip the job on an open PR into main. A clause in
    handed_off is safe: a sibling job with the same name runs on exactly that condition (handoffs)."""
    return [
        clause
        for clause in clauses(condition)
        if clause.startswith("!(") and not any(scope in clause for scope in SAFE_SCOPES)
        and clause[2:-1].strip() not in handed_off
    ]


def offenders(seen: list[str] | None = None) -> list[str]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            continue
        for job_id, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            name = str(job.get("name") or "")
            if "${{" not in name or not any(f"'{check}'" in name for check in MAIN_REQUIRED):
                continue
            if seen is not None:
                seen.append(f"{path.name}:{job_id}")
            jobs = document.get("jobs") or {}
            # A skip clause is covered when another job with the same expression name runs on exactly it (its
            # non-skip clauses, in order): backend-migrations.yml's gate skips when the plan found no migration
            # change and gate-no-change, on the persistent pool, runs on exactly that, so one of them reports.
            handed: set[str] = set()
            for other_id, other in jobs.items():
                if other_id != job_id and isinstance(other, dict) and other.get("name") == job.get("name"):
                    positives = [c for c in clauses(str(other.get("if") or ""))
                                 if not c.startswith("!") and c not in ("always()", "!cancelled()", "success()")]
                    handed.add(" && ".join(positives))
            for clause in unsafe_skips(str(job.get("if") or ""), handed):
                found.append(f"{path.name}:{job_id}: {clause}")
    return found


class RequiredGateNeverSkipsIntoMainTests(unittest.TestCase):
    def test_workflows_have_no_main_skip_on_expression_named_required_jobs(self) -> None:
        seen: list[str] = []
        self.assertEqual(offenders(seen), [])
        # A renamed gate must not turn this into a test of nothing.
        self.assertIn("backend-migrations.yml:gate", seen)

    def test_unscoped_no_change_skip_is_caught(self) -> None:
        condition = "always() && !(needs.plan.result == 'success' && needs.plan.outputs.migrations != 'true')"
        self.assertEqual(len(unsafe_skips(condition)), 1)

    def test_a_skip_handed_to_a_same_named_sibling_passes(self) -> None:
        no_change = "needs.plan.result == 'success' && needs.plan.outputs.migrations == 'false'"
        jobs = {
            "gate": {"name": "${{ 'backend migrations applied' }}", "if": f"always() && !({no_change})"},
            "gate-no-change": {"name": "${{ 'backend migrations applied' }}", "if": f"${{{{ !cancelled() && {no_change} }}}}"},
        }
        handed = {" && ".join(c for c in clauses(jobs["gate-no-change"]["if"]) if not c.startswith("!"))}
        self.assertEqual(unsafe_skips(jobs["gate"]["if"], handed), [])
        # A sibling that runs on something narrower does not cover the skip.
        narrower = "needs.plan.result == 'success' && needs.plan.outputs.migrations == 'false' && github.actor == 'x'"
        handed = {" && ".join(c for c in clauses(f"!cancelled() && {narrower}") if not c.startswith("!"))}
        self.assertEqual(len(unsafe_skips(jobs["gate"]["if"], handed)), 1)

    def test_feat_cmux_next_and_closed_scopes_pass(self) -> None:
        condition = (
            "always() && !(github.event.pull_request.state == 'closed' && github.event.action == 'labeled')"
            " && !(needs.plan.outputs.migrations != 'true' && github.event.pull_request.base.ref == 'feat-cmux-next')"
        )
        self.assertEqual(unsafe_skips(condition), [])


if __name__ == "__main__":
    sys.exit(unittest.main())
