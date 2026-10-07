#!/usr/bin/env python3
"""app-ffi-release.yml's publish job never reports success without a release.

Run 37556534995 (C3, 45845b2d13d7) built the FFI, skipped the create step
because workflow files had changed since the last FFI tag, printed a notice and
went green with no release. The pin check then failed on every Swift run until
a person noticed. Whenever the job cannot create the release (workflow files
changed, an HTTP 403, or a create that silently publishes nothing), it now
fails and names the hand-publish command.

Workflow-file changes no longer need a hand publish: GITHUB_TOKEN may not
create a tag over them, and FFI tags sit under the admin-create ruleset
24624526, so the publish job creates the release with a token of the FFI
release GitHub App (contents and workflows write, in ruleset 24624526's bypass
list), minted in the app-ffi-release environment. The fake `gh` refuses a
create with any other token.

The test runs the publish job's own shell steps in order, as the runner would,
against a fake `gh` and `curl` that play each outcome.
"""
from __future__ import annotations

import hashlib
import os
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/app-ffi-release.yml"
sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate  # noqa: E402

SHA = "45845b2d13d794c435d31f72ea74dc0f4a5739d0"
TAG = f"cmux-app-ffi-{SHA}"
REPO = "manaflow-ai/cmux"
RUN_ID = "37556534995"
APP_TOKEN = "fake-ffi-release-app-token"
APP_SECRETS = ("CMUX_APP_FFI_RELEASE_APP_ID", "CMUX_APP_FFI_RELEASE_APP_KEY")

FAKE_GH = r"""#!/usr/bin/env bash
# Fake gh: FAKE_CREATE is ok, 403 or noop. A created release is the directory $STATE/release.
set -u
rel="$STATE/release"
case "$1 $2" in
  "release view") [[ -d "$rel" ]] && exit 0; echo "release not found" >&2; exit 1 ;;
  "release create")
    # GITHUB_TOKEN may not tag over workflow-file changes or past ruleset
    # 24624526; only the FFI release App's token creates the release.
    [[ "${GH_TOKEN:-}" == "$APP_TOKEN" ]] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
    case "$FAKE_CREATE" in
      403) echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;;
      noop) exit 0 ;;
    esac
    mkdir -p "$rel"
    shift 3
    for arg in "$@"; do [[ -f "$arg" ]] && cp "$arg" "$rel/"; done
    exit 0 ;;
  "release download")
    [[ -d "$rel" ]] || { echo "release not found" >&2; exit 1; }
    dir=.
    while [[ $# -gt 0 ]]; do [[ "$1" == --dir ]] && dir="$2"; shift; done
    mkdir -p "$dir"; cp "$rel/CCmuxAppFFI.xcframework.zip" "$dir/"; exit 0 ;;
  "api repos/manaflow-ai/cmux/releases/latest") echo "v0.99.0"; exit 0 ;;
esac
echo "fake gh: unexpected: $*" >&2
exit 2
"""

FAKE_CURL = r"""#!/usr/bin/env bash
set -u
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
[[ -f "$STATE/release/CCmuxAppFFI.xcframework.zip" ]] || { echo "curl: (22) 404" >&2; exit 22; }
cp "$STATE/release/CCmuxAppFFI.xcframework.zip" "$out"
"""


def executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def render(text: str, context: dict) -> str:
    return re.sub(r"\$\{\{(.*?)\}\}", lambda match: str(evaluate(match.group(1), context) or ""), str(text))


def condition(expression: str | None, context: dict, failed: bool) -> bool:
    """A step's `if:` with the status functions GitHub adds (success() when none is named)."""
    if expression is None:
        return not failed
    text = str(expression).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    named = re.search(r"\b(always|failure|success|cancelled)\(\)", text)
    text = (text.replace("always()", "true").replace("cancelled()", "false")
            .replace("failure()", "true" if failed else "false")
            .replace("success()", "false" if failed else "true"))
    return bool(evaluate(text, context)) and (bool(named) or not failed)


class PublishJob(unittest.TestCase):
    def run_publish(self, *, workflow_changed: bool, create: str = "ok", existing: bool = False) -> tuple[bool, str]:
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["publish"]
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            bin_dir, state, work = temp_path / "bin", temp_path / "state", temp_path / "work"
            for path in (bin_dir, state, work / "assets"):
                path.mkdir(parents=True)
            executable(bin_dir / "gh", FAKE_GH)
            executable(bin_dir / "curl", FAKE_CURL)
            executable(bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
            archive = work / "assets/CCmuxAppFFI.xcframework.zip"
            archive.write_bytes(b"xcframework bytes")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            (work / "assets/CCmuxAppFFI.xcframework.zip.sha256").write_text(checksum + "\n")
            (work / "assets/SHA256SUMS").write_text(f"{checksum}  CCmuxAppFFI.xcframework.zip\n")
            (work / "assets/SOURCE_SHA").write_text(SHA + "\n")
            if existing:
                (state / "release").mkdir()
                (state / "release/CCmuxAppFFI.xcframework.zip").write_bytes(archive.read_bytes())
            context = {
                "github": {"token": "fake-token", "repository": REPO, "sha": SHA, "run_id": RUN_ID,
                           "ref": "refs/heads/feat-cmux-next", "event_name": "push",
                           "server_url": "https://github.com", "repository_owner": "manaflow-ai"},
                "needs": {"build": {"outputs": {"tag": TAG, "checksum": checksum,
                                                "workflow_changed": "true" if workflow_changed else "false"}}},
                "vars": {}, "runner": {"temp": str(temp_path)},
                "steps": {"app-token": {"outputs": {"token": APP_TOKEN}}},
            }
            base_env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": temp, "STATE": str(state),
                        "FAKE_CREATE": create, "APP_TOKEN": APP_TOKEN, "GITHUB_SHA": SHA, "GITHUB_REPOSITORY": REPO,
                        "GITHUB_RUN_ID": RUN_ID, "GITHUB_SERVER_URL": "https://github.com",
                        "RUNNER_TEMP": temp, "GITHUB_OUTPUT": str(temp_path / "output"),
                        "GITHUB_STEP_SUMMARY": str(temp_path / "summary")}
            base_env.update({key: render(value, context) for key, value in (job.get("env") or {}).items()})
            failed, log = False, []
            for step in job["steps"]:
                if "run" not in step or not condition(step.get("if"), context, failed):
                    continue
                env = dict(base_env)
                env.update({key: render(value, context) for key, value in (step.get("env") or {}).items()})
                script = render(step["run"], context)
                result = subprocess.run(["bash", "-e", "-c", script], cwd=work, env=env,
                                        capture_output=True, text=True, timeout=60)
                log.append(f"--- {step.get('name')} (exit {result.returncode})\n{result.stdout}{result.stderr}")
                if result.returncode != 0 and not step.get("continue-on-error"):
                    failed = True
            return not failed, "\n".join(log)

    def assert_fails_loud(self, passed: bool, log: str) -> None:
        self.assertFalse(passed, "the publish job reported success without a release:\n" + log)
        self.assertIn("publish by hand", log.lower(), log)
        # The exact command a person runs: the release create for this tag and commit.
        self.assertRegex(log, rf"gh release create {TAG}\b.*--target {SHA}", log)
        self.assertIn(f"gh run download {RUN_ID}", log, log)

    def test_workflow_files_changed_still_publishes_with_the_app_token(self):
        # Runs 37595723068 and 37613480750 needed a hand publish for this.
        passed, log = self.run_publish(workflow_changed=True)
        self.assertTrue(passed, log)
        self.assertNotIn("publish by hand", log.lower(), log)

    def test_a_refused_create_fails_with_the_hand_publish_command(self):
        # Run 37272232472: GITHUB_TOKEN got HTTP 403 creating the tag.
        self.assert_fails_loud(*self.run_publish(workflow_changed=False, create="403"))

    def test_a_create_that_publishes_nothing_fails_with_the_hand_publish_command(self):
        self.assert_fails_loud(*self.run_publish(workflow_changed=False, create="noop"))

    def test_a_created_release_passes(self):
        passed, log = self.run_publish(workflow_changed=False)
        self.assertTrue(passed, log)
        self.assertNotIn("publish by hand", log.lower(), log)

    def test_a_rerun_over_the_same_release_passes(self):
        passed, log = self.run_publish(workflow_changed=False, existing=True)
        self.assertTrue(passed, log)


class ReleaseAppToken(unittest.TestCase):
    """Only the publish job, in its protected environment, can mint the App token."""

    def test_the_publish_job_mints_a_contents_and_workflows_token(self):
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["publish"]
        self.assertEqual(job.get("environment"), "app-ffi-release")
        self.assertEqual(job.get("permissions"), {"contents": "read"})
        mint = [step for step in job["steps"] if str(step.get("uses", "")).startswith("actions/create-github-app-token@")]
        self.assertEqual(len(mint), 1, "exactly one App token step")
        self.assertEqual(mint[0].get("id"), "app-token")
        with_ = mint[0]["with"]
        self.assertEqual(with_["app-id"], "${{ secrets.CMUX_APP_FFI_RELEASE_APP_ID }}")
        self.assertEqual(with_["private-key"], "${{ secrets.CMUX_APP_FFI_RELEASE_APP_KEY }}")
        self.assertEqual(with_["repositories"], "${{ github.event.repository.name }}")
        self.assertEqual(sorted(k for k in with_ if k.startswith("permission-")),
                         ["permission-contents", "permission-workflows"])
        self.assertEqual((with_["permission-contents"], with_["permission-workflows"]), ("write", "write"))

    def test_no_other_job_reads_the_app_secrets(self):
        for workflow in sorted(WORKFLOW.parent.glob("*.yml")):
            jobs = (yaml.safe_load(workflow.read_text(encoding="utf-8")) or {}).get("jobs") or {}
            for name, job in jobs.items():
                if (workflow, name) == (WORKFLOW, "publish"):
                    continue
                text = yaml.safe_dump(job)
                for secret in APP_SECRETS:
                    self.assertNotIn(secret, text, f"{workflow.name}:{name} reads {secret}")


if __name__ == "__main__":
    unittest.main()
