#!/usr/bin/env python3
"""Guard privileged CI source refs against mutable or untrusted revisions.

The four workflows covered here can access signing, release, or self-hosted
runner capabilities. Release, nightly, and GhosttyKit jobs use only protected
push or schedule events. Read-only E2E keeps a manual entry point, but it must
start from protected ``main`` and every build checkout must use an immutable
SHA. GhosttyKit additionally verifies the submodule object and trusted fork
lineage before the release environment is entered.
"""

from __future__ import annotations

import pathlib
import re
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
WORKFLOWS = {
    "release": WORKFLOW_DIR / "release.yml",
    "nightly": WORKFLOW_DIR / "nightly.yml",
    "e2e": WORKFLOW_DIR / "test-e2e.yml",
    "ghosttykit": WORKFLOW_DIR / "build-ghosttykit.yml",
}
SCRIPT_SHA = re.compile(r"@[0-9a-f]{40}(?:\s+#.*)?$")


def load(path: pathlib.Path) -> dict:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    # PyYAML 1.1 parses the YAML 1.2 ``on`` key as ``True``.
    return document


def triggers(document: dict) -> dict:
    return document.get("on", document.get(True, {}))


def all_steps(job: dict) -> list[dict]:
    return list(job.get("steps", []))


def checkout_steps(job: dict) -> list[dict]:
    return [
        step
        for step in all_steps(job)
        if "actions/checkout@" in str(step.get("uses", ""))
    ]


def dependency_names(job: dict) -> set[str]:
    needs = job.get("needs", [])
    if isinstance(needs, str):
        return {needs}
    return set(needs)


def assert_immutable_checkouts(test: unittest.TestCase, job: dict, expected_ref: str) -> None:
    steps = all_steps(job)
    checkouts = checkout_steps(job)
    test.assertTrue(checkouts)
    for index, checkout in enumerate(steps):
        if "actions/checkout@" not in str(checkout.get("uses", "")):
            continue
        with test.subTest(checkout=checkout.get("name")):
            test.assertEqual(checkout.get("with", {}).get("ref"), expected_ref)
            test.assertIs(checkout.get("with", {}).get("persist-credentials"), False)
            verification = next(
                (
                    step
                    for step in steps[index + 1 :]
                    if str(step.get("name", "")).startswith("Verify immutable checkout")
                ),
                None,
            )
            test.assertIsNotNone(verification)
            test.assertIn("EXPECTED_SHA", str(verification.get("env", {})))


class DispatchSourceGuardTests(unittest.TestCase):
    def test_actions_are_pinned_in_the_guard_workflows(self) -> None:
        for name, path in WORKFLOWS.items():
            document = load(path)
            self.assertEqual(document.get("permissions"), {}, f"{name} must default to no token permissions")
            for job_name, job in document.get("jobs", {}).items():
                self.assertIn("permissions", job, f"{name}/{job_name} must declare job permissions")
                for step in all_steps(job):
                    uses = str(step.get("uses", ""))
                    if uses and not uses.startswith("./"):
                        self.assertRegex(
                            uses,
                            SCRIPT_SHA,
                            f"{name}/{job_name}: {uses!r} must use a full SHA",
                        )

    def test_release_is_an_unprivileged_observer_only(self) -> None:
        document = load(WORKFLOWS["release"])
        self.assertEqual(document.get("permissions"), {})
        self.assertIn("push", triggers(document))
        self.assertEqual(triggers(document)["push"]["tags"], ["v*"])
        self.assertNotIn("workflow_dispatch", triggers(document))
        self.assertEqual(set(document["jobs"]), {"announce"})
        job = document["jobs"]["announce"]
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertEqual(job["permissions"], {})
        self.assertEqual(len(all_steps(job)), 1)
        step = all_steps(job)[0]
        self.assertNotIn("uses", step)
        self.assertIn("Emit queued release event", step["name"])
        self.assertIn("Tag event queued for trusted protected-main release dispatcher", step["run"])
        text = WORKFLOWS["release"].read_text(encoding="utf-8")
        for forbidden in (
            "secrets.",
            "GITHUB_TOKEN",
            "github.token",
            "contents: write",
            "actions/github-script",
            "actions/checkout",
            "workflow_dispatch",
            "workflow_call",
            "repository_dispatch",
        ):
            self.assertNotIn(forbidden, text)

    def test_nightly_uses_protected_sources_and_propagates_sha(self) -> None:
        document = load(WORKFLOWS["nightly"])
        self.assertEqual(document.get("permissions"), {})
        self.assertNotIn("workflow_dispatch", triggers(document))
        self.assertIn("push", triggers(document))
        self.assertIn("schedule", triggers(document))
        self.assertNotIn("workflow_dispatch", WORKFLOWS["nightly"].read_text(encoding="utf-8"))
        guard = document["jobs"]["validate-source"]
        self.assertEqual(guard["runs-on"], "ubuntu-24.04")
        script = "\n".join(str(step.get("with", {}).get("script", "")) for step in all_steps(guard))
        self.assertIn("refs/heads/main", script)
        guard_env = "\n".join(str(step.get("env", {})) for step in all_steps(guard))
        self.assertIn("REF_PROTECTED", guard_env)
        self.assertIn("github.ref_type", guard_env)
        self.assertIn("github.workflow_sha", guard_env)
        self.assertIn("github.workflow_ref", guard_env)
        self.assertIn("compareCommits", script)
        self.assertIn("expectedWorkflowRef", script)
        self.assertIn("workflowComparison", script)
        self.assertIn("workflowAtSource", script)
        self.assertIn("workflowAtDefinition", script)
        self.assertIn("source_sha", script)
        self.assertIn("validate-source", dependency_names(document["jobs"]["decide"]))
        self.assertIn("github.ref_protected == true", document["jobs"]["decide"]["if"])
        self.assertIn("VALIDATED_SHA", "\n".join(str(step.get("env", {})) for step in all_steps(document["jobs"]["decide"])))
        self.assertEqual(
            document["jobs"]["build-sign-notarize-nightly"]["permissions"],
            {"contents": "write", "attestations": "write", "id-token": "write"},
        )
        for job_name in (
            "refresh-compilation-cache",
            "build-nightly-ghostty-cli-helper",
            "build-nightly-app",
            "build-sign-notarize-nightly",
        ):
            self.assertIn("github.ref_protected == true", document["jobs"][job_name]["if"])
            assert_immutable_checkouts(
                self,
                document["jobs"][job_name],
                "${{ needs.decide.outputs.head_sha }}",
            )

    def test_e2e_accepts_only_main_or_an_immutable_main_ancestor(self) -> None:
        document = load(WORKFLOWS["e2e"])
        self.assertEqual(document.get("permissions"), {})
        workflow_inputs = triggers(document)["workflow_dispatch"]["inputs"]
        self.assertIn("ref", workflow_inputs)
        guard = document["jobs"]["validate-source"]
        self.assertEqual(guard["runs-on"], "ubuntu-24.04")
        script = "\n".join(str(step.get("with", {}).get("script", "")) for step in all_steps(guard))
        self.assertIn("refs/heads/main", script)
        self.assertIn("getCommit", script)
        self.assertIn("compareCommits", script)
        self.assertIn("workflowComparison", script)
        self.assertIn("workflowAtSource", script)
        self.assertIn("workflowAtDefinition", script)
        self.assertRegex(script, r"\[0-9a-f\]\{40\}")
        guard_env = "\n".join(str(step.get("env", {})) for step in all_steps(guard))
        self.assertIn("github.event_name", guard_env)
        self.assertIn("github.ref_type", guard_env)
        self.assertIn("github.workflow_sha", guard_env)
        self.assertIn("github.workflow_ref", guard_env)
        self.assertIn("expectedWorkflowIdentity", script)
        self.assertIn("validate-source", dependency_names(document["jobs"]["e2e"]))
        self.assertEqual(document["jobs"]["e2e"]["permissions"], {"contents": "read"})
        self.assertIn("github.ref_protected == true", document["jobs"]["e2e"]["if"])
        self.assertEqual(document["jobs"]["e2e"]["runs-on"], "macos-15")
        assert_immutable_checkouts(
            self,
            document["jobs"]["e2e"],
            "${{ needs.validate-source.outputs.source_sha }}",
        )

    def test_ghosttykit_uses_protected_main_push_and_reviewed_environment(self) -> None:
        document = load(WORKFLOWS["ghosttykit"])
        self.assertEqual(document.get("permissions"), {})
        self.assertNotIn("workflow_dispatch", triggers(document))
        self.assertEqual(triggers(document)["push"]["branches"], ["main"])
        self.assertEqual(triggers(document)["push"]["paths"], ["ghostty"])
        self.assertNotIn("workflow_dispatch", WORKFLOWS["ghosttykit"].read_text(encoding="utf-8"))
        guard = document["jobs"]["validate-source"]
        self.assertEqual(guard["runs-on"], "ubuntu-24.04")
        script = "\n".join(str(step.get("with", {}).get("script", "")) for step in all_steps(guard))
        self.assertIn("refs/heads/main", script)
        self.assertIn("getBranch", script)
        self.assertIn("compareCommits", script)
        self.assertIn("workflowSha", script)
        self.assertIn("workflowComparison", script)
        self.assertIn("workflowAtSource", script)
        self.assertIn("workflowAtDefinition", script)
        guard_env = "\n".join(str(step.get("env", {})) for step in all_steps(guard))
        self.assertIn("REF_PROTECTED", guard_env)
        self.assertIn("github.ref_type", guard_env)
        self.assertIn("github.workflow_sha", guard_env)
        self.assertIn("github.workflow_ref", guard_env)
        job = document["jobs"]["build-ghosttykit"]
        self.assertIn("validate-source", dependency_names(job))
        self.assertIn("github.ref_protected == true", job["if"])
        self.assertEqual(job["environment"], {"name": "sdk-release"})
        self.assertEqual(job["permissions"], {"contents": "read"})
        self.assertIn("getContent", script)
        self.assertIn("submodule_git_url", script)
        self.assertIn("manaflow-ai/ghostty", script)
        self.assertIn("ghostty_sha", script)
        self.assertIn("ghosttyComparison", script)
        assert_immutable_checkouts(
            self,
            job,
            "${{ needs.validate-source.outputs.source_sha }}",
        )
        verification = next(
            step for step in all_steps(job) if str(step.get("name", "")).startswith("Verify immutable checkout")
        )
        self.assertIn("EXPECTED_GHOSTTY_SHA", str(verification.get("env", {})))
        self.assertIn("git -C ghostty rev-parse HEAD", str(verification.get("run", "")))
        self.assertIn("remote.origin.url", str(verification.get("run", "")))

    def test_manual_e2e_has_no_secret_or_write_token_path(self) -> None:
        document = load(WORKFLOWS["e2e"])
        text = WORKFLOWS["e2e"].read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch", triggers(document))
        self.assertNotIn("inputs.runner", text)
        self.assertNotIn("tart-", text)
        self.assertNotIn("depot-macos", text)
        self.assertNotIn("contents: write", text)
        for secret_name in (
            "APPLE_",
            "SPARKLE_",
            "CF_R2_",
            "GHOSTTY_RELEASE_TOKEN",
        ):
            self.assertNotIn(secret_name, text)
        self.assertEqual(document["jobs"]["e2e"]["permissions"], {"contents": "read"})


if __name__ == "__main__":
    unittest.main()
