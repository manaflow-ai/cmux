#!/usr/bin/env python3
"""Contract tests for the protected-main release dispatcher.

The tag workflow is deliberately only an event source.  All privileged work
must live in the ``workflow_run`` workflow that GitHub resolves from the
protected default branch.
"""

from __future__ import annotations

import base64
import json
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
OBSERVER_CONTENT = "\n".join(
    (
        "name: Release macOS app trigger",
        "",
        "on:",
        "  push:",
        "    tags:",
        '      - "v*"',
        "",
        "permissions: {}",
        "",
        "jobs:",
        "  announce:",
        "    runs-on: ubuntu-24.04 # github-hosted-required: unprivileged tag observer",
        "    permissions: {}",
        "    timeout-minutes: 2",
        "    steps:",
        "      - name: Emit queued release event",
        "        run: |",
        "          set -euo pipefail",
        '          echo "Tag event queued for trusted protected-main release dispatcher: ${GITHUB_REF_NAME}"',
        "",
    )
)


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


def run_guard_fixture(
    script: str,
    *,
    wrapper_blob: str,
    main_blob: str,
    source_content: str | None = None,
    main_content: str | None = None,
    tag_target_sha: str | None = None,
    tag_name: str = "v1.2.3",
) -> subprocess.CompletedProcess[str]:
    """Exercise the real guard with a tag-controlled workflow mutation.

    The event payload claims a successful observer run, while the observer
    definition at that source SHA contains a different blob from protected
    ``main``.  The guard must fail before any privileged job can run.
    """

    source_sha = "a" * 40
    main_sha = "b" * 40
    observer_run_id = 123456
    source_content = source_content or (
        "name: Release macOS app trigger\n"
        "permissions: { contents: write }\n"
        "jobs:\n  attacker:\n    run: exfiltrate\n"
    )
    main_content = main_content or (
        "name: Release macOS app trigger\npermissions: {}\njobs: {}\n"
    )
    source_content_b64 = base64.b64encode(source_content.encode()).decode()
    main_content_b64 = base64.b64encode(main_content.encode()).decode()
    tag_target_sha = tag_target_sha or source_sha
    tag_name_literal = json.dumps(tag_name)
    harness = f"""
const outputs = {{}};
const core = {{
  setFailed(message) {{ throw new Error(message); }},
  setOutput(name, value) {{ outputs[name] = value; }},
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
    head_branch: {tag_name_literal},
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
      if (path === '{TRIGGER_PATH}') return {{ data: {{ type: 'file', sha: ref === '{main_sha}' ? '{main_blob}' : '{wrapper_blob}', encoding: 'base64', content: ref === '{main_sha}' ? '{main_content_b64}' : '{source_content_b64}' }} }};
      return {{ data: {{ type: 'file', sha: 'trusted-workflow-blob', encoding: 'base64', content: '' }} }};
    }},
  }},
  git: {{
    getRef: async () => ({{ data: {{ object: {{ type: 'commit', sha: '{tag_target_sha}' }} }} }}),
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
    process.stdout.write(JSON.stringify(outputs));
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
    def test_release_tag_policy_is_documented_as_a_deployment_prerequisite(self) -> None:
        policy = (ROOT / "docs" / "ci-runners.md").read_text(encoding="utf-8")
        for required in (
            "Protected release tags",
            "refs/tags/v*",
            "create, update, and delete",
            "only to the release authority",
            "rejects force-updates",
            "deployment prerequisite",
        ):
            self.assertIn(required, policy)

    def test_sparkle_private_key_is_streamed_to_the_derivation_helper(self) -> None:
        workflow_text = WORKFLOW.read_text(encoding="utf-8")
        helper_text = (ROOT / "scripts" / "derive_sparkle_public_key.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'swift scripts/derive_sparkle_public_key.swift --stdin <<<"$SPARKLE_PRIVATE_KEY"',
            workflow_text,
        )
        self.assertNotIn(
            'swift scripts/derive_sparkle_public_key.swift "$SPARKLE_PRIVATE_KEY"',
            workflow_text,
        )
        self.assertIn("FileHandle.standardInput", helper_text)
        self.assertIn("--stdin", helper_text)

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
            "is_prerelease",
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

        sign_steps = document["jobs"]["build-sign-notarize"]["steps"]
        self.assertEqual(
            document["jobs"]["build-sign-notarize"]["concurrency"],
            {"group": "cmux-release-stable-r2", "cancel-in-progress": False},
        )
        sign_text = "\n".join(str(step) for step in sign_steps)
        for required in (
            "skip_r2_upload",
            "Refusing to download or sign release assets",
            "Refusing to trust mutable release assets on a retry",
            "Revalidate release tag before GitHub publication",
            "Revalidate release tag before R2 publication",
        ):
            self.assertIn(required, sign_text)
        r2_recheck = next(step for step in sign_steps if step.get("name") == "Revalidate release tag before R2 publication")
        self.assertIn("gh api", r2_recheck["run"])
        self.assertIn("skip_r2_upload", r2_recheck["if"])
        r2_upload = next(step for step in sign_steps if step.get("name") == "Upload release appcast to R2")
        self.assertIn('[[ "$IS_PRERELEASE" == true ]]', r2_upload["run"])
        self.assertNotIn('RELEASE_TAG" == *-*', r2_upload["run"])

        release_upload = next(step for step in sign_steps if step.get("name") == "Upload release asset")
        self.assertEqual(
            release_upload["with"]["prerelease"],
            "${{ needs.validate-source.outputs.is_prerelease == 'true' }}",
        )
        self.assertEqual(
            release_upload["with"]["make_latest"],
            "${{ needs.validate-source.outputs.is_prerelease != 'true' }}",
        )
        self.assertNotIn("gh release download", sign_text)
        self.assertNotIn("sort -V", r2_upload["run"])
        self.assertIn("python3 -c", r2_upload["run"])
        self.assertIn("gh release list --limit 1000", r2_upload["run"])
        self.assertIn("latest_sha", r2_upload["run"])
        self.assertIn("EXPECTED_SHA", r2_upload["run"])

        self.assertEqual(
            document["jobs"]["build-sign-notarize"]["env"]["IS_PRERELEASE"],
            "${{ needs.validate-source.outputs.is_prerelease }}",
        )

    def test_signing_certificate_tempfile_is_private_and_symlink_safe(self) -> None:
        document = load()
        sign_steps = document["jobs"]["build-sign-notarize"]["steps"]
        import_step = next(step for step in sign_steps if step.get("name") == "Import signing cert")
        import_run = import_step["run"]
        for required in (
            "umask 077",
            'runner_temp="${RUNNER_TEMP:?RUNNER_TEMP is required}"',
            '[[ -d "$runner_temp" && ! -L "$runner_temp" ]]',
            'cert_path="$(mktemp "$runner_temp/cmux-signing-cert.',
            '[[ -f "$cert_path" && ! -L "$cert_path" ]]',
            "trap 'rm -f -- \"$cert_path\"' EXIT",
            'chmod 600 "$cert_path"',
        ):
            self.assertIn(required, import_run)
        self.assertNotIn("/tmp/cert.p12", import_run)

    def test_keychain_search_list_is_restored_and_cleanup_is_fail_closed(self) -> None:
        document = load()
        sign_steps = document["jobs"]["build-sign-notarize"]["steps"]
        import_step = next(step for step in sign_steps if step.get("name") == "Import signing cert")
        cleanup_step = next(step for step in sign_steps if step.get("name") == "Cleanup keychain")
        import_run = import_step["run"]
        cleanup_run = cleanup_step["run"]
        self.assertIn('keychain_list_backup="$(mktemp "$runner_temp/cmux-keychain-list.', import_run)
        self.assertIn('[[ -f "$keychain_list_backup" && ! -L "$keychain_list_backup" ]]', import_run)
        self.assertIn('security list-keychains -d user > "$keychain_list_backup"', import_run)
        self.assertIn("CMUX_KEYCHAIN_LIST_BACKUP", import_run)
        self.assertEqual(cleanup_step["if"], "always()")
        for required in (
            'backup="${CMUX_KEYCHAIN_LIST_BACKUP:-}"',
            '[[ -n "$backup" && -f "$backup" && ! -L "$backup" ]]',
            "security list-keychains -d user -s",
            'rm -f -- "$backup"',
            "Failed to restore the keychain search list",
        ):
            self.assertIn(required, cleanup_run)
        self.assertIn("CMUX_KEYCHAIN_CREATED", cleanup_run)

        # A reused self-hosted workspace must never delete another process's
        # lock. The pre-checkout cleanup is intentionally duplicated in each
        # privileged job so source-controlled code cannot weaken the guard.
        for job_name in ("build-ghostty-cli-helper", "build-sign-notarize"):
            cleanup = next(
                step for step in document["jobs"][job_name]["steps"]
                if step.get("name") == "Clear stale git locks (self-hosted reused workspace)"
            )
            cleanup_run = cleanup["run"]
            self.assertIn("stat -c '%u'", cleanup_run)
            self.assertIn("stat -f '%u'", cleanup_run)
            self.assertIn("lsof -n -t", cleanup_run)
            self.assertIn("find -P", cleanup_run)
            self.assertNotIn('find "$git_dir/modules" -type f -name "*.lock" -delete', cleanup_run)

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

    def test_observer_rejects_alternate_yaml_run_syntax(self) -> None:
        document = load()
        script = script_for(document["jobs"]["validate-source"])
        alternate = OBSERVER_CONTENT.replace("        run: |", "        run: >")
        result = run_guard_fixture(
            script,
            wrapper_blob="same-protected-blob",
            main_blob="same-protected-blob",
            source_content=alternate,
            main_content=OBSERVER_CONTENT,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("minimal unprivileged observer", result.stderr)

    def test_canonical_observer_passes_full_provenance_guard(self) -> None:
        document = load()
        script = script_for(document["jobs"]["validate-source"])
        result = run_guard_fixture(
            script,
            wrapper_blob="same-protected-blob",
            main_blob="same-protected-blob",
            source_content=OBSERVER_CONTENT,
            main_content=OBSERVER_CONTENT,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_moved_tag_is_rejected_before_release(self) -> None:
        document = load()
        script = script_for(document["jobs"]["validate-source"])
        result = run_guard_fixture(
            script,
            wrapper_blob="same-protected-blob",
            main_blob="same-protected-blob",
            source_content=OBSERVER_CONTENT,
            main_content=OBSERVER_CONTENT,
            tag_target_sha="c" * 40,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("moved", result.stderr.lower())

    def test_build_metadata_hyphen_is_not_a_prerelease(self) -> None:
        document = load()
        script = script_for(document["jobs"]["validate-source"])
        result = run_guard_fixture(
            script,
            wrapper_blob="same-protected-blob",
            main_blob="same-protected-blob",
            source_content=OBSERVER_CONTENT,
            main_content=OBSERVER_CONTENT,
            tag_name="v1.2.3+build-1",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"is_prerelease":"false"', result.stdout)

    def test_leading_zero_semver_core_is_rejected(self) -> None:
        document = load()
        script = script_for(document["jobs"]["validate-source"])
        result = run_guard_fixture(
            script,
            wrapper_blob="same-protected-blob",
            main_blob="same-protected-blob",
            source_content=OBSERVER_CONTENT,
            main_content=OBSERVER_CONTENT,
            tag_name="v01.2.3",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("semantic version", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
