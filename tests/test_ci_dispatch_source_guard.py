#!/usr/bin/env python3
"""Guard manual CI dispatches against mutable or untrusted source refs.

The four workflows covered here can access signing, release, or self-hosted
runner capabilities. A workflow_dispatch caller must therefore start from the
protected current ``main`` revision (or, for read-only E2E, an immutable
ancestor of ``main``), and every build checkout must use the validated SHA.
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


class DispatchSourceGuardTests(unittest.TestCase):
    def test_actions_are_pinned_in_the_guard_workflows(self) -> None:
        for name, path in WORKFLOWS.items():
            document = load(path)
            for job_name, job in document.get("jobs", {}).items():
                for step in all_steps(job):
                    uses = str(step.get("uses", ""))
                    if uses and not uses.startswith("./"):
                        self.assertRegex(
                            uses,
                            SCRIPT_SHA,
                            f"{name}/{job_name}: {uses!r} must use a full SHA",
                        )

    def test_release_has_a_protected_immutable_source_gate(self) -> None:
        document = load(WORKFLOWS["release"])
        self.assertEqual(document.get("permissions"), {})
        self.assertIn("workflow_dispatch", triggers(document))
        guard = document["jobs"]["validate-source"]
        self.assertEqual(guard["runs-on"], "ubuntu-24.04")
        self.assertEqual(guard["permissions"], {"contents": "read"})
        script = "\n".join(str(step.get("with", {}).get("script", "")) for step in all_steps(guard))
        self.assertIn("refs/heads/main", script)
        self.assertIn("REF_PROTECTED", "\n".join(str(step.get("env", {})) for step in all_steps(guard)))
        self.assertIn("getBranch", script)
        self.assertIn("compareCommits", script)
        self.assertIn("source_sha", script)
        for job_name in ("build-ghostty-cli-helper", "build-sign-notarize"):
            job = document["jobs"][job_name]
            self.assertIn("validate-source", job.get("needs", []))
            for step in checkout_steps(job):
                self.assertEqual(
                    step.get("with", {}).get("ref"),
                    "${{ needs.validate-source.outputs.source_sha }}",
                )
                self.assertIs(step.get("with", {}).get("persist-credentials"), False)

    def test_nightly_validates_manual_main_and_propagates_sha(self) -> None:
        document = load(WORKFLOWS["nightly"])
        self.assertEqual(document.get("permissions"), {})
        guard = document["jobs"]["validate-source"]
        self.assertEqual(guard["runs-on"], "ubuntu-24.04")
        script = "\n".join(str(step.get("with", {}).get("script", "")) for step in all_steps(guard))
        self.assertIn("workflow_dispatch", script)
        self.assertIn("refs/heads/main", script)
        self.assertIn("REF_PROTECTED", "\n".join(str(step.get("env", {})) for step in all_steps(guard)))
        self.assertIn("compareCommits", script)
        self.assertIn("source_sha", script)
        self.assertIn("validate-source", document["jobs"]["decide"].get("needs", []))
        self.assertIn("VALIDATED_SHA", "\n".join(str(step.get("env", {})) for step in all_steps(document["jobs"]["decide"])))
        for job in document["jobs"].values():
            for step in checkout_steps(job):
                self.assertIs(step.get("with", {}).get("persist-credentials"), False)

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
        self.assertRegex(script, r"[0-9a-f]\{40\}")
        self.assertIn("validate-source", document["jobs"]["e2e"].get("needs", []))
        self.assertEqual(document["jobs"]["e2e"]["permissions"], {"contents": "read"})
        for step in checkout_steps(document["jobs"]["e2e"]):
            self.assertEqual(
                step.get("with", {}).get("ref"),
                "${{ needs.validate-source.outputs.source_sha }}",
            )
            self.assertIs(step.get("with", {}).get("persist-credentials"), False)

    def test_ghosttykit_dispatch_is_main_only_and_read_only_by_default(self) -> None:
        document = load(WORKFLOWS["ghosttykit"])
        self.assertEqual(document.get("permissions"), {})
        guard = document["jobs"]["validate-source"]
        self.assertEqual(guard["runs-on"], "ubuntu-24.04")
        script = "\n".join(str(step.get("with", {}).get("script", "")) for step in all_steps(guard))
        self.assertIn("workflow_dispatch", script)
        self.assertIn("refs/heads/main", script)
        self.assertIn("getBranch", script)
        self.assertIn("REF_PROTECTED", "\n".join(str(step.get("env", {})) for step in all_steps(guard)))
        job = document["jobs"]["build-ghosttykit"]
        self.assertIn("validate-source", job.get("needs", []))
        self.assertEqual(job["permissions"], {"contents": "read"})
        for step in checkout_steps(job):
            self.assertEqual(
                step.get("with", {}).get("ref"),
                "${{ needs.validate-source.outputs.source_sha }}",
            )
            self.assertIs(step.get("with", {}).get("persist-credentials"), False)


if __name__ == "__main__":
    unittest.main()
