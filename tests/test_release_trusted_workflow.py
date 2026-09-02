#!/usr/bin/env python3
"""Contract tests for the protected-main release dispatcher.

The tag workflow is deliberately only an event source.  All privileged work
must live in the ``workflow_run`` workflow that GitHub resolves from the
protected default branch.
"""

from __future__ import annotations

import base64
import pathlib
import re
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "release-trusted.yml"
WORKFLOW_PATH = ".github/workflows/release-trusted.yml"
TRIGGER_PATH = ".github/workflows/release.yml"
SHA = re.compile(r"^[0-9a-f]{40}$")
ACTION_SHA = re.compile(r"@[0-9a-f]{40}(?:\s+#.*)?$")


def load() -> dict:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return document


def triggers(document: dict) -> dict:
    # PyYAML 1.1 treats the YAML 1.2 ``on`` key as a boolean.
    return document.get("on", document.get(True, {}))


def script_for(job: dict) -> str:
    return "\n".join(
        str(step.get("with", {}).get("script", ""))
        for step in job.get("steps", [])
    )


def checkout_steps(job: dict) -> list[dict]:
    return [
        step
        for step in job.get("steps", [])
        if "actions/checkout@" in str(step.get("uses", ""))
    ]


def run_guard_fixture(script: str, *, wrapper_blob: str, main_blob: str) -> subprocess.CompletedProcess[str]:
    """Exercise the real guard with a tag-controlled workflow mutation.

    The event payload claims a successful observer run, while the observer
    definition at that source SHA contains a different blob from protected
    ``main``.  The guard must fail before any privileged job can run.
    """

    source_sha = "a" * 40
    main_sha = "b" * 40
    observer_run_id = 123456
    wrapper_content = base64.b64encode(
        b"name: Release macOS app trigger\n"
        b"permissions: { contents: write }\n"
        b"jobs:\n  attacker:\n    run: exfiltrate\n"
    ).decode()
    main_content = base64.b64encode(
        b"name: Release macOS app trigger\npermissions: {}\njobs: {}\n"
    ).decode()
    harness = f"""
const core = {{
  setFailed(message) {{ throw new Error(message); }},
  setOutput() {{}},
  notice() {{}},
}};
const context = {{
  repo: {{ owner: 'manaflow-ai', repo: 'cmux' }},
  eventName: 'workflow_run',
  ref: 'refs/heads/main',
  ref_type: 'branch',
  payload: {{ workflow_run: {{
    id: {observer_run_id},
    name: 'Release macOS app trigger',
    path: '{TRIGGER_PATH}',
    event: 'push',
    status: 'completed',
    conclusion: 'success',
    head_branch: 'v1.2.3',
    head_sha: '{source_sha}',
    head_repository: {{ full_name: 'manaflow-ai/cmux' }},
  }} }},
}};
const github = {{ rest: {{
  actions: {{
    getWorkflowRun: async () => ({{ data: {{ ...context.payload.workflow_run, workflow_id: 77, repository: {{ full_name: 'manaflow-ai/cmux' }} }} }}),
    getWorkflow: async () => ({{ data: {{ name: 'Release macOS app trigger', path: '{TRIGGER_PATH}' }} }}),
  }},
  repos: {{
    getBranch: async () => ({{ data: {{ protected: true, commit: {{ sha: '{main_sha}' }} }} }}),
    compareCommits: async () => ({{ data: {{ status: 'ahead' }} }}),
    getContent: async ({{ path, ref }}) => {{
      if (path === '{TRIGGER_PATH}') return {{ data: {{ type: 'file', sha: ref === '{main_sha}' ? '{main_blob}' : '{wrapper_blob}', encoding: 'base64', content: ref === '{main_sha}' ? '{main_content}' : '{wrapper_content}' }} }};
      return {{ data: {{ type: 'file', sha: 'trusted-workflow-blob', encoding: 'base64', content: '' }} }};
    }},
  }},
  git: {{
    getRef: async () => ({{ data: {{ object: {{ type: 'commit', sha: '{source_sha}' }} }} }}),
  }},
}} }};
process.env.REPOSITORY = 'manaflow-ai/cmux';
process.env.EVENT_NAME = 'workflow_run';
process.env.EVENT_REF = 'refs/heads/main';
process.env.EVENT_REF_TYPE = 'branch';
process.env.EVENT_SHA = '{main_sha}';
process.env.WORKFLOW_SHA = '{main_sha}';
process.env.WORKFLOW_REF = 'manaflow-ai/cmux/{WORKFLOW_PATH}@refs/heads/main';
process.env.REF_PROTECTED = 'true';
process.env.WORKFLOW_REPOSITORY = 'manaflow-ai/cmux';
process.env.WORKFLOW_RUN_JSON = JSON.stringify(context.payload.workflow_run);
(async () => {{
  try {{
{script}
  }} catch (error) {{
    console.error(error.message);
    process.exitCode = 1;
  }}
}})();
"""
    return subprocess.run(
        ["node", "--input-type=module"],
        input=harness,
        text=True,
        capture_output=True,
        check=False,
    )


class ReleaseTrustedWorkflowTests(unittest.TestCase):
    def test_workflow_run_is_resolved_from_protected_main(self) -> None:
        document = load()
        event = triggers(document)
        self.assertEqual(event["workflow_run"]["types"], ["completed"])
        self.assertEqual(event["workflow_run"]["workflows"], ["Release macOS app trigger"])
        self.assertNotIn("push", event)
        self.assertNotIn("workflow_dispatch", event)
        self.assertEqual(document["permissions"], {})
        guard = document["jobs"]["validate-source"]
        self.assertEqual(guard["runs-on"], "ubuntu-24.04")
        self.assertEqual(guard["permissions"], {"actions": "read", "contents": "read"})
        script = script_for(guard)
        for required in (
            "workflow_run",
            "getWorkflowRun",
            "head_repository",
            "head_branch",
            "head_sha",
            "conclusion",
            "completed",
            "getBranch",
            "compareCommits",
            "getRef",
            "getTag",
            "trustedAtWorkflow",
            "trustedAtMain",
            "protected",
            "source_sha",
            "tag_name",
            "minimal unprivileged observer",
        ):
            self.assertIn(required, script)
        env = "\n".join(str(step.get("env", {})) for step in guard.get("steps", []))
        self.assertIn("github.event.workflow_run", env)
        self.assertIn("github.workflow_ref", env)
        self.assertIn("github.workflow_sha", env)
        self.assertIn("github.ref_protected", env)

    def test_privileged_jobs_require_guard_and_immutable_source(self) -> None:
        document = load()
        for job_name, job in document["jobs"].items():
            self.assertIn("permissions", job, job_name)
            for step in job.get("steps", []):
                uses = str(step.get("uses", ""))
                if uses and not uses.startswith("./"):
                    self.assertRegex(uses, ACTION_SHA)
        for job_name in ("build-ghostty-cli-helper", "build-sign-notarize"):
            job = document["jobs"][job_name]
            needs = job.get("needs", [])
            needs = {needs} if isinstance(needs, str) else set(needs)
            self.assertIn("validate-source", needs)
            self.assertIn("needs.validate-source.result", job["if"])
            checkouts = checkout_steps(job)
            self.assertTrue(checkouts)
            for checkout in checkouts:
                self.assertEqual(
                    checkout.get("with", {}).get("ref"),
                    "${{ needs.validate-source.outputs.source_sha }}",
                )
                self.assertIs(checkout.get("with", {}).get("persist-credentials"), False)

    def test_adversarial_tag_workflow_is_rejected_before_release(self) -> None:
        document = load()
        script = script_for(document["jobs"]["validate-source"])
        result = run_guard_fixture(
            script,
            wrapper_blob="tag-controlled-wrapper",
            main_blob="protected-main-wrapper",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(
            result.stderr,
            r"(?i)(?:minimal unprivileged observer|dispatcher source workflow changed|workflow definition)",
        )


if __name__ == "__main__":
    unittest.main()
