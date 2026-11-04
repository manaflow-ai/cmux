#!/usr/bin/env python3
"""A fast-checks dispatch names the commit it tests, in a form a receipt reader can match.

A workflow_dispatch run's head_sha is the dispatch ref's tip (main), never the
commit it tests, so `glaeda-gh wait run|pr --sha <PR head>` refused every
fast-checks receipt as another commit's and lanes re-dispatched or hand-rolled
validation. The client now passes tested_sha (the snapshot's parent, when the
snapshot's tree is that commit's), the run-name names it as
`<owner>/<repo>@<full sha>`, and a step proves the claim before anything runs.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "fast-checks.yml"
RUN_NAME = ("run-name: Fast checks ${{ inputs.source_sha }}${{ inputs.tested_sha && "
            "format(' tests {0}@{1}', github.repository, inputs.tested_sha) || '' }}")


def text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def step(name: str) -> str:
    """The body of the step called NAME, up to the next step."""
    match = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)", text(), re.S | re.M)
    if not match:
        raise AssertionError(f"no step named {name!r}")
    return match.group(1)


class FastChecksReceiptTests(unittest.TestCase):
    def test_run_name_names_the_tested_commit_with_its_repo(self) -> None:
        names = [line for line in text().splitlines() if line.startswith("run-name:")]
        self.assertEqual(names, [RUN_NAME])

    def test_tested_sha_is_an_optional_input(self) -> None:
        inputs = re.search(r"^      tested_sha:\n((?:        .*\n)+)", text(), re.M)
        self.assertIsNotNone(inputs)
        self.assertIn("default: ''", inputs.group(1))
        self.assertNotIn("required: true", inputs.group(1))

    def test_tested_sha_must_be_a_full_commit_id(self) -> None:
        body = step("Validate request")
        self.assertIn("TESTED_SHA: ${{ inputs.tested_sha }}", body)
        self.assertIn('[[ -z "$TESTED_SHA" || "$TESTED_SHA" =~ ^[0-9a-f]{40}$ ]]', body)

    def test_the_claim_is_proved_before_the_command_runs(self) -> None:
        order = [m.group(1) for m in re.finditer(r"^      - (?:name: (.*)|uses: .*)$", text(), re.M)]
        self.assertIn("Confirm the tested commit", order)
        self.assertLess(order.index("Confirm the tested commit"), order.index("Run fast checks"))
        body = step("Confirm the tested commit")
        self.assertIn("if: inputs.tested_sha != ''", body)
        # the snapshot's only parent, and the very same tree: no uncommitted edits ride along
        self.assertIn("git rev-list --parents -n 1 HEAD", body)
        self.assertIn('"$parents" != "$TESTED_SHA"', body)
        self.assertIn("git rev-parse 'HEAD^{tree}'", body)
        self.assertIn('git rev-parse "$TESTED_SHA^{tree}"', body)
        self.assertEqual(body.count("exit 2"), 2)

    def test_checkout_brings_the_parent_only_when_asked(self) -> None:
        self.assertIn("fetch-depth: ${{ inputs.tested_sha && 2 || 1 }}", text())

    def test_the_name_form_is_what_a_reader_parses(self) -> None:
        # what glaeda-gh matches: owner/repo@40 hex, the snapshot sha alone never matching
        name = "Fast checks " + "a" * 40 + " tests manaflow-ai/cmux@" + "b" * 40
        token = re.compile(r"(?<![\w./-])([\w.-]+/[\w.-]+)@([0-9a-f]{40})(?![0-9a-fA-F])")
        self.assertEqual(token.findall(name), [("manaflow-ai/cmux", "b" * 40)])


if __name__ == "__main__":
    unittest.main()
