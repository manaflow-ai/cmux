"""Adversarial policy tests for the trusted Blacksmith Testbox broker.

The Testbox action writes a bearer token into the runner state.  A workflow
which runs from a candidate revision must therefore never decide its own
preflight, checkout, or post-token helper path.  These tests inspect the
workflow and the trusted helper boundary.  They do not provision a Testbox.
"""

from __future__ import annotations

import re
import stat
import unittest
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/ci-workflow-guard-tests-testbox-broker.yml"
HELPER_DIR = ROOT / "scripts/blacksmith-testbox-broker"
VALIDATE_HELPER = HELPER_DIR / "validate-identity.sh"
KEEPALIVE_HELPER = HELPER_DIR / "keepalive.sh"
BEGIN_ACTION = "useblacksmith/begin-testbox"
CHECKOUT_ACTION = "actions/checkout"
BROKER_SHA_VAR = "BLACKSMITH_TESTBOX_BROKER_SHA"
REVIEWED_REF_VAR = "BLACKSMITH_TESTBOX_REVIEWED_REF"
REVIEWED_SHA_VAR = "BLACKSMITH_TESTBOX_REVIEWED_SHA"
BROKER_HELPER_PREFIX = "scripts/blacksmith-testbox-broker/"


def _without_comments(text: str) -> str:
    return "\n".join(line.split(" #", 1)[0] for line in text.splitlines())


class TestboxBrokerSecurityTests(unittest.TestCase):
    def workflow_text(self) -> str:
        self.assertTrue(
            WORKFLOW_PATH.is_file(),
            "main-controlled Testbox broker workflow is missing: "
            f"{WORKFLOW_PATH.relative_to(ROOT)}",
        )
        return WORKFLOW_PATH.read_text(encoding="utf-8")

    def workflow_document(self) -> dict[str, Any]:
        document = yaml.load(self.workflow_text(), Loader=yaml.BaseLoader)
        self.assertIsInstance(document, dict)
        return document

    def broker_job(self) -> dict[str, Any]:
        document = self.workflow_document()
        jobs = document.get("jobs")
        self.assertIsInstance(jobs, dict)
        job = jobs.get("cmux-tui-testbox-broker")
        self.assertIsInstance(job, dict)
        return job

    def steps(self) -> list[dict[str, Any]]:
        steps = self.broker_job().get("steps")
        self.assertIsInstance(steps, list)
        self.assertTrue(all(isinstance(step, dict) for step in steps))
        return steps

    def step(self, name: str) -> dict[str, Any]:
        for step in self.steps():
            if step.get("name") == name:
                return step
        self.fail(f"broker step is missing: {name}")

    def helper_text(self, path: Path) -> str:
        self.assertTrue(
            path.is_file(),
            "trusted broker helper is missing: " + str(path.relative_to(ROOT)),
        )
        return path.read_text(encoding="utf-8")

    @staticmethod
    def run_text(step: dict[str, Any]) -> str:
        run = step.get("run", "")
        return run if isinstance(run, str) else ""

    @staticmethod
    def uses(step: dict[str, Any]) -> str:
        uses = step.get("uses", "")
        return uses if isinstance(uses, str) else ""

    def test_broker_workflow_is_dispatch_only_with_narrow_inputs(self) -> None:
        document = self.workflow_document()
        triggers = document.get("on")
        self.assertIsInstance(triggers, dict)
        self.assertIn("workflow_dispatch", triggers)
        self.assertFalse(
            set(triggers) & {"push", "pull_request", "pull_request_target", "workflow_run"},
            "an untrusted event must not be able to invoke the token-bearing broker",
        )

        dispatch = triggers["workflow_dispatch"]
        self.assertIsInstance(dispatch, dict)
        inputs = dispatch.get("inputs")
        self.assertIsInstance(inputs, dict)
        self.assertEqual(set(inputs), {"testbox_id", "source_sha"})
        self.assertEqual(inputs["testbox_id"].get("required"), "true")
        self.assertEqual(inputs["source_sha"].get("required"), "false")
        self.assertIn("assertion", inputs["source_sha"].get("description", "").lower())

    def test_broker_job_and_external_actions_are_pinned(self) -> None:
        job = self.broker_job()
        text = self.workflow_text()
        self.assertIn("blacksmith-testbox-trusted", text)

        permissions = job.get("permissions", {})
        self.assertIsInstance(permissions, dict)
        self.assertNotIn("write", {str(value).lower() for value in permissions.values()})

        external_actions: list[str] = []
        for step in self.steps():
            action = self.uses(step)
            if action and not action.startswith("./"):
                external_actions.append(action)
        self.assertTrue(external_actions)
        for action in external_actions:
            self.assertRegex(
                action,
                r"@[0-9a-f]{40}(?:\s|$)",
                f"external action is not pinned to a full commit: {action}",
            )
        begin = self.step("Begin Testbox")
        self.assertTrue(self.uses(begin).startswith(BEGIN_ACTION + "@"))
        self.assertNotIn("@v", self.uses(begin))

    def test_only_the_main_controlled_broker_can_begin_a_testbox(self) -> None:
        """A candidate workflow must not retain a second token-bearing entrypoint."""

        for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            if path == WORKFLOW_PATH:
                continue
            text = path.read_text(encoding="utf-8")
            self.assertNotIn(
                BEGIN_ACTION + "@",
                text,
                f"candidate-controlled workflow can invoke Begin Testbox: {path.name}",
            )

    def test_token_boundary_has_preflight_and_postflight_identity_checks(self) -> None:
        steps = self.steps()
        names = [str(step.get("name", "")) for step in steps]
        begin_index = names.index("Begin Testbox")
        pre_index = names.index("Validate broker and reviewed source before Testbox")
        post_index = names.index("Revalidate broker and reviewed source after Testbox")
        candidate_index = names.index("Checkout reviewed candidate (isolated)")
        self.assertLess(pre_index, begin_index)
        self.assertGreater(post_index, begin_index)
        self.assertGreater(candidate_index, post_index)
        self.assertEqual(steps[post_index].get("if"), "always()")

        pre_run = self.run_text(steps[pre_index])
        post_run = self.run_text(steps[post_index])
        self.assertIn("./" + BROKER_HELPER_PREFIX + "validate-identity.sh", pre_run)
        self.assertIn("./" + BROKER_HELPER_PREFIX + "validate-identity.sh", post_run)
        self.assertRegex(pre_run, r"(?:--phase\s+)?(?:pre|before)\b")
        self.assertRegex(post_run, r"(?:--phase\s+)?(?:post|after)\b")

        for source in (pre_run, post_run):
            for variable in (BROKER_SHA_VAR, REVIEWED_REF_VAR, REVIEWED_SHA_VAR):
                self.assertIn(variable, source)
            self.assertIn("testbox_id", source)
            self.assertRegex(source, r"(?:github\.sha|GITHUB_SHA)")
            self.assertRegex(source, r"(?:github\.ref|GITHUB_REF)")
            self.assertRegex(source, r"(?:github\.repository|GITHUB_REPOSITORY)")

    def test_validate_identity_rejects_forks_tags_raw_shas_and_moved_branches(self) -> None:
        workflow = _without_comments(self.workflow_text())
        helper = _without_comments(self.helper_text(VALIDATE_HELPER))
        combined = workflow + "\n" + helper

        self.assertRegex(combined, r"manaflow-ai/cmux")
        self.assertRegex(combined, r"(?:EVENT_NAME|GITHUB_EVENT_NAME|github\.event_name)")
        self.assertRegex(combined, r"workflow_dispatch")
        self.assertRegex(combined, r"refs/heads/")
        self.assertRegex(combined, r"git\s+ls-remote")
        self.assertRegex(combined, r"[Rr]emote[_ -]?[Ss][Hh][Aa]")
        self.assertRegex(combined, r"[0-9a-f]{40}")

        # A tag, fork, or raw SHA must not be accepted as the reviewed source.
        self.assertNotRegex(workflow, r"ref:\s*\$\{\{\s*inputs\.source_sha\s*\}\}")
        self.assertRegex(helper, r"(?:REVIEWED_REF|reviewed_ref)")
        self.assertIn("refs/heads/", helper)

        # The same trusted validator must run on both sides of token exposure.
        steps = self.steps()
        pre = self.run_text(self.step("Validate broker and reviewed source before Testbox"))
        post = self.run_text(self.step("Revalidate broker and reviewed source after Testbox"))
        self.assertIn("validate-identity.sh", pre)
        self.assertIn("validate-identity.sh", post)
        self.assertNotEqual(pre, post, "pre/post checks must carry distinct phases")
        self.assertGreaterEqual(sum("validate-identity.sh" in self.run_text(step) for step in steps), 2)

    def test_testbox_id_is_checked_before_and_after_begin(self) -> None:
        helper = _without_comments(self.helper_text(VALIDATE_HELPER))
        self.assertIn("=~ ^tbx_[A-Za-z0-9_-]+$", helper)
        self.assertRegex(helper, r"testbox_id")
        self.assertRegex(helper, r"(?i)(?:state|registration)")
        self.assertRegex(helper, r"(?i)testbox_id")

        begin = self.step("Begin Testbox")
        with_values = begin.get("with")
        self.assertIsInstance(with_values, dict)
        self.assertEqual(with_values.get("testbox_id"), "${{ inputs.testbox_id }}")
        pre = self.run_text(self.step("Validate broker and reviewed source before Testbox"))
        post = self.run_text(self.step("Revalidate broker and reviewed source after Testbox"))
        self.assertIn("inputs.testbox_id", pre)
        self.assertIn("inputs.testbox_id", post)

    def test_reviewed_candidate_checkout_isolated_and_without_credentials(self) -> None:
        candidate = self.step("Checkout reviewed candidate (isolated)")
        self.assertEqual(self.uses(candidate).split("@", 1)[0], CHECKOUT_ACTION)
        self.assertEqual(candidate.get("with", {}).get("path"), "candidate-source")
        self.assertEqual(candidate.get("with", {}).get("persist-credentials"), "false")
        self.assertEqual(candidate.get("with", {}).get("fetch-depth"), "0")
        self.assertNotEqual(
            str(candidate.get("with", {}).get("submodules", "false")).lower(),
            "true",
        )
        candidate_ref = str(candidate.get("with", {}).get("ref", ""))
        self.assertNotIn("inputs.source_sha", candidate_ref)
        self.assertRegex(candidate_ref, rf"{re.escape(REVIEWED_SHA_VAR)}|{re.escape(REVIEWED_REF_VAR)}")

        verify = self.step("Verify isolated candidate identity")
        verify_run = self.run_text(verify)
        self.assertIn("candidate-source", verify_run)
        self.assertRegex(verify_run, r"git\s+-C\s+candidate-source")
        self.assertRegex(verify_run, r"(?:github\.sha|REVIEWED_SHA|reviewed_sha)")
        self.assertIn("status", verify_run)

    def test_no_candidate_workflow_actions_or_helpers_run_after_token_exposure(self) -> None:
        steps = self.steps()
        names = [str(step.get("name", "")) for step in steps]
        begin_index = names.index("Begin Testbox")
        post_steps = steps[begin_index + 1 :]
        forbidden = (
            ".github/workflows/",
            ".github/actions/",
            "blacksmith-cmux-tui-testbox-stage.sh",
            "blacksmith-testbox-cleanup.sh",
            "blacksmith-testbox-keepalive.sh",
        )
        for step in post_steps:
            action = self.uses(step)
            run = self.run_text(step)
            self.assertFalse(
                action.startswith("./.github/") or "${{" in action,
                f"candidate-controlled action after token exposure: {action}",
            )
            for marker in forbidden:
                self.assertNotIn(marker, run, f"candidate-controlled path after Begin Testbox: {marker}")

            # Any repository script invoked after Begin must be a literal path
            # in the trusted broker directory.  Candidate source may be read,
            # but it must never supply executable helper code.
            for match in re.finditer(r"(?:^|\s)(?:\./)?scripts/[^\s'\"]+", run):
                path = match.group(0).strip()
                if path.startswith("./"):
                    path = path[2:]
                self.assertTrue(
                    path.startswith(BROKER_HELPER_PREFIX),
                    f"post-token script is outside the trusted broker directory: {path}",
                )

        keepalive = self.step("Run trusted broker keepalive")
        self.assertIn("./" + BROKER_HELPER_PREFIX + "keepalive.sh", self.run_text(keepalive))

    def test_trusted_helpers_are_executable_and_do_not_download_candidate_code(self) -> None:
        for helper_path in (VALIDATE_HELPER, KEEPALIVE_HELPER):
            text = self.helper_text(helper_path)
            mode = helper_path.stat().st_mode
            self.assertTrue(mode & stat.S_IXUSR, f"helper is not executable: {helper_path.name}")
            self.assertTrue(text.startswith("#!/usr/bin/env bash"))
            self.assertNotRegex(text, r"curl\s+[^\n|]*\|\s*(?:bash|sh)")
            self.assertNotIn("candidate-source/.github", text)
            self.assertNotIn("candidate-source/scripts", text)


if __name__ == "__main__":
    unittest.main()
