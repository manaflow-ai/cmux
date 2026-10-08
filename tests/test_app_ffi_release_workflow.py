#!/usr/bin/env python3
"""app-ffi-release.yml's publish job never reports success without a release.

Run 37556534995 (C3, 45845b2d13d7) built the FFI, skipped the create step
because workflow files had changed since the last FFI tag, printed a notice and
went green with no release. The pin check then failed on every Swift run until
a person noticed. Whenever the job cannot create the release (workflow files
changed, an HTTP 403, or a create that silently publishes nothing), it now
fails and names the hand-publish command.

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

FAKE_GH = r"""#!/usr/bin/env bash
# Fake gh: FAKE_CREATE is ok, 403 or noop. A created release is the directory $STATE/release.
set -u
rel="$STATE/release"
case "$1 $2" in
  "release view") [[ -d "$rel" ]] && exit 0; echo "release not found" >&2; exit 1 ;;
  "release create")
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
    def run_publish(self, *, workflow_changed: bool, create: str = "ok", existing: bool = False,
                    app_token: str = "") -> tuple[bool, str]:
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
                # The release App token step is a `uses:` step: an empty token is a failed mint.
                "steps": {"app-token": {"outputs": {"token": app_token}}},
            }
            base_env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": temp, "STATE": str(state),
                        "FAKE_CREATE": create, "GITHUB_SHA": SHA, "GITHUB_REPOSITORY": REPO,
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

    def test_workflow_files_changed_fails_with_the_hand_publish_command(self):
        # Run 37556534995: the create step skipped and the job went green.
        self.assert_fails_loud(*self.run_publish(workflow_changed=True))

    def test_the_release_app_token_publishes_over_workflow_changes(self):
        # Run 37562535914: GITHUB_TOKEN cannot create a tag over workflow-file
        # changes, so every FFI change pushed with one went unpublished and
        # left the pin stale. The release App (contents and workflows write) can.
        passed, log = self.run_publish(workflow_changed=True, app_token="app-token")
        self.assertTrue(passed, log)
        self.assertNotIn("publish by hand", log.lower(), log)

    def test_the_release_is_created_with_the_app_token_when_there_is_one(self):
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["publish"]
        mint = next(step for step in job["steps"] if step.get("id") == "app-token")
        self.assertIn("create-github-app-token", mint["uses"])
        self.assertEqual(mint["with"]["app-id"], "${{ secrets.CMUX_RELEASE_APP_ID }}")
        self.assertEqual(mint["with"]["permission-contents"], "write")
        self.assertEqual(mint["with"]["permission-workflows"], "write")
        self.assertTrue(mint.get("continue-on-error"))
        create = next(step for step in job["steps"] if step.get("name") == "Create the release (never overwrite)")
        self.assertIn("steps.app-token.outputs.token", create["env"]["GH_TOKEN"])

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


REPIN = ROOT / "scripts/cmux-next/repin-app-ffi.sh"
CHECK = ROOT / "scripts/cmux-next/check-app-ffi-pin.sh"
NEW_SHA = "d" * 40
NEW_SUM = "e" * 64


class RePin(unittest.TestCase):
    def test_repin_rewrites_the_url_and_checksum_the_check_reads(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = Path(temp) / "Package.swift"
            manifest.write_text(textwrap.dedent(f"""\
                .binaryTarget(
                    name: "CCmuxAppFFI",
                    url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-{SHA}/CCmuxAppFFI.xcframework.zip",
                    checksum: "{"a" * 64}"
                ),
                .binaryTarget(name: "Other", url: "https://example.com/x.zip", checksum: "{"b" * 64}"),
                """))
            subprocess.run(["bash", str(REPIN), NEW_SHA, NEW_SUM, str(manifest)], check=True, capture_output=True)
            text = manifest.read_text()
            self.assertIn(f"cmux-app-ffi-{NEW_SHA}/CCmuxAppFFI.xcframework.zip", text)
            self.assertIn(f'checksum: "{NEW_SUM}"', text)
            self.assertNotIn(SHA, text)
            self.assertIn(f'checksum: "{"b" * 64}"', text)  # other targets are untouched
            for bad in (("x", NEW_SUM), (NEW_SHA, "y")):
                result = subprocess.run(["bash", str(REPIN), *bad, str(manifest)], capture_output=True)
                self.assertNotEqual(result.returncode, 0, bad)

    def test_a_published_release_opens_or_updates_the_repin_pull_request(self):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        job = workflow["jobs"]["repin"]
        self.assertEqual(job["needs"], ["build", "publish"])
        self.assertIn("needs.publish.result == 'success'", job["if"])
        self.assertIn("refs/heads/feat-cmux-next", job["if"])
        mint = next(step for step in job["steps"] if step.get("id") == "app-token")
        self.assertEqual(mint["with"]["permission-contents"], "write")
        # A mint asking for a permission the App lacks fails whole, so the
        # pull-request token is separate and optional; the push never depends on it.
        self.assertNotIn("permission-pull-requests", mint["with"])
        pr_mint = next(step for step in job["steps"] if step.get("id") == "pr-token")
        self.assertEqual(pr_mint["with"]["permission-pull-requests"], "write")
        self.assertTrue(pr_mint.get("continue-on-error"))
        script = "\n".join(str(step.get("run", "")) for step in job["steps"])
        self.assertIn("scripts/cmux-next/repin-app-ffi.sh", script)
        # An App token's push runs CI on the re-pin, unlike GITHUB_TOKEN's.
        self.assertIn("app-ffi-repin", script)
        self.assertIn("gh pr create", script)
        self.assertIn("gh pr edit", script)
        self.assertIn('--title "cmux-next: pin CCmuxAppFFI to $TAG"', script)
        self.assertIn('--body "$body"', script)
        self.assertIn("--base feat-cmux-next", script)
        self.assertIn("compare/feat-cmux-next...$branch", script)


if __name__ == "__main__":
    unittest.main()
