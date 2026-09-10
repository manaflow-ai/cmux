#!/usr/bin/env python3
"""Guard the Blacksmith Testbox broker trust boundary.

`blacksmith testbox warmup` resolves the workflow definition and the hydrated
source from one `--ref`, so a lane that hydrates a candidate branch also *runs*
that branch's copy of this workflow, before `begin-testbox` writes the Testbox
auth token. The lane avoids that by hydrating `main` only.

These checks fail the moment an edit reintroduces the old shape: a ref other
than `refs/heads/main`, a candidate-selecting input, repository code executing
ahead of the token, or an unpinned action.
"""

import pathlib
import re
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-testbox-warmup.yml"
JOB = "cmux-tui-rust"
BEGIN_TESTBOX = "useblacksmith/begin-testbox"


def load_job() -> dict:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return document, document["jobs"][JOB]


class TestboxBrokerGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.document, self.job = load_job()
        self.steps = self.job["steps"]
        self.begin_index = next(
            index
            for index, step in enumerate(self.steps)
            if BEGIN_TESTBOX in str(step.get("uses", ""))
        )

    def test_only_manual_dispatch_with_no_candidate_selector(self) -> None:
        # yaml.safe_load turns a bare `on:` key into True.
        triggers = self.document[True]
        self.assertEqual(list(triggers), ["workflow_dispatch"])
        inputs = triggers["workflow_dispatch"]["inputs"]
        self.assertEqual(
            sorted(inputs),
            ["testbox_id"],
            "an input that names a source ref or SHA would let a caller hydrate "
            "a revision the reviewed environment never approved",
        )

    def test_a_ref_guard_runs_before_the_token_bearing_action(self) -> None:
        guard = self.steps[: self.begin_index]
        self.assertTrue(guard, "begin-testbox must not be the first step")
        scripts = "\n".join(str(step.get("run", "")) for step in guard)
        self.assertIn('"$DISPATCH_REF" == "refs/heads/main"', scripts)
        self.assertIn("exit 1", scripts)

    def test_no_repository_code_runs_before_the_token(self) -> None:
        for step in self.steps[: self.begin_index]:
            uses = str(step.get("uses", ""))
            self.assertFalse(
                uses.startswith("./"),
                f"local composite action {uses!r} runs before begin-testbox",
            )
            run = str(step.get("run", ""))
            self.assertNotRegex(
                run,
                r"(^|\s)\./",
                "a repository script must not execute before begin-testbox",
            )

    def test_every_checkout_pins_the_dispatched_commit(self) -> None:
        checkouts = [
            step for step in self.steps if "actions/checkout" in str(step.get("uses", ""))
        ]
        self.assertTrue(checkouts, "the job must check out the hydration commit")
        for step in checkouts:
            self.assertEqual(step["with"]["ref"], "${{ github.sha }}")
            self.assertIs(step["with"]["persist-credentials"], False)

    def test_actions_are_pinned_to_commit_shas(self) -> None:
        for step in self.steps:
            uses = str(step.get("uses", ""))
            if not uses or uses.startswith("./"):
                continue
            self.assertRegex(
                uses,
                r"@[0-9a-f]{40}$",
                f"{uses!r} must be pinned to a full commit SHA",
            )

    def test_the_job_keeps_its_reviewed_environment_and_least_privilege(self) -> None:
        self.assertEqual(self.job["environment"]["name"], "blacksmith-testbox-trusted")
        self.assertEqual(self.job["permissions"], {"contents": "read"})
        self.assertEqual(self.document["permissions"], {})

    def test_the_keepalive_reads_the_token_only_from_a_main_controlled_script(self) -> None:
        keepalive = self.steps[-1]
        self.assertIn("keepalive", keepalive["name"].lower())
        self.assertEqual(
            keepalive["run"].strip(),
            "./scripts/blacksmith-testbox-keepalive.sh",
        )
        script = ROOT / "scripts" / "blacksmith-testbox-keepalive.sh"
        self.assertTrue(script.is_file())
        self.assertIn("/tmp/.testbox", script.read_text(encoding="utf-8"))

    def test_the_runner_label_is_declared_for_actionlint(self) -> None:
        label = self.job["runs-on"]
        config = (ROOT / ".github" / "actionlint.yaml").read_text(encoding="utf-8")
        self.assertRegex(config, rf"(?m)^\s*-\s*{re.escape(label)}\s*$")


if __name__ == "__main__":
    unittest.main()
