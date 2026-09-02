"""Security contract tests for the Homebrew release publisher."""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "update-homebrew.yml"
VALIDATOR = ROOT / ".github" / "scripts" / "validate-homebrew-release.sh"


def _base_fixture() -> tuple[dict[str, object], dict[str, object]]:
    repository = "manaflow-ai/cmux"
    tag = "v1.2.3"
    sha = "a" * 40
    workflow_id = 227907677
    run_id = 123456789
    digest = "sha256:" + "b" * 64
    asset_url = (
        f"https://github.com/{repository}/releases/download/{tag}/cmux-macos.dmg"
    )
    workflow = {
        "id": workflow_id,
        "name": "Release macOS app",
        "path": ".github/workflows/release.yml",
        "state": "active",
    }
    run = {
        "id": run_id,
        "name": "Release macOS app",
        "path": ".github/workflows/release.yml",
        "event": "push",
        "status": "completed",
        "conclusion": "success",
        "workflow_id": workflow_id,
        "run_attempt": 1,
        "head_branch": tag,
        "head_sha": sha,
        "repository": {"id": 1, "full_name": repository},
        "head_repository": {"id": 1, "full_name": repository},
        "pull_requests": [],
        "head_commit": {"id": sha},
    }
    asset = {
        "id": 987654321,
        "name": "cmux-macos.dmg",
        "state": "uploaded",
        "size": 2_000_000,
        "content_type": "application/x-apple-diskimage",
        "digest": digest,
        "browser_download_url": asset_url,
    }
    release = {
        "id": 42,
        "tag_name": tag,
        "draft": False,
        "prerelease": False,
        "published_at": "2026-09-01T12:00:00Z",
        "assets": [asset],
    }
    api = {
        f"repos/{repository}/actions/workflows/release.yml": workflow,
        f"repos/{repository}/actions/runs/{run_id}": run,
        f"repos/{repository}/git/ref/tags/{tag}": {
            "ref": f"refs/tags/{tag}",
            "object": {"type": "commit", "sha": sha},
        },
        f"repos/{repository}/compare/main...{sha}": {
            "status": "behind",
            "ahead_by": 0,
            "base_commit": {"sha": "c" * 40},
            "commits": [],
        },
        f"repos/{repository}/releases/tags/{tag}": release,
        f"repos/{repository}/releases/assets/{asset['id']}": dict(asset),
        f"repos/{repository}/releases/latest": {"tag_name": tag, "draft": False, "prerelease": False},
    }
    event = {
        "action": "completed",
        "repository": {"full_name": repository},
        "workflow_run": {
            "id": run_id,
            "name": run["name"],
            "path": run["path"],
            "event": run["event"],
            "status": run["status"],
            "conclusion": run["conclusion"],
            "workflow_id": workflow_id,
            "run_attempt": 1,
            "head_branch": tag,
            "head_sha": sha,
            "repository": {"id": 1, "full_name": repository},
            "head_repository": {"id": 1, "full_name": repository},
        }
    }
    return event, api


def _write_fake_gh(directory: Path, api: dict[str, object]) -> None:
    mapping = directory / "api.json"
    mapping.write_text(json.dumps(api), encoding="utf-8")
    fake_gh = directory / "gh"
    fake_gh.write_text(
        textwrap.dedent(
            """
            #!/usr/bin/env python3
            import json
            import pathlib
            import sys

            if len(sys.argv) < 3 or sys.argv[1] != "api":
                print("unexpected gh invocation", file=sys.stderr)
                raise SystemExit(2)
            endpoint = next(
                (arg for arg in sys.argv[2:] if arg.startswith("repos/")), None
            )
            if endpoint is None:
                print("missing API endpoint", file=sys.stderr)
                raise SystemExit(2)
            endpoint = endpoint.split("?", 1)[0]
            data = json.loads(
                (pathlib.Path(__file__).parent / "api.json").read_text()
            )
            if endpoint not in data:
                print(f"unexpected endpoint: {endpoint}", file=sys.stderr)
                raise SystemExit(3)
            print(json.dumps(data[endpoint]))
            """
        ).lstrip(),
        encoding="utf-8",
    )
    fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IXUSR)


class HomebrewPublisherSecurityTests(unittest.TestCase):
    def run_validator(
        self,
        event: dict[str, object],
        api: dict[str, object],
        *,
        event_name: str = "workflow_run",
        ref: str = "refs/heads/main",
        expected: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="homebrew-validator-") as temp:
            directory = Path(temp)
            event_path = directory / "event.json"
            event_path.write_text(json.dumps(event), encoding="utf-8")
            _write_fake_gh(directory, api)
            output_path = directory / "output.txt"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{directory}:{env['PATH']}",
                    "GITHUB_EVENT_PATH": str(event_path),
                    "GITHUB_EVENT_NAME": event_name,
                    "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                    "GITHUB_REF": ref,
                    "GITHUB_WORKFLOW": "Update Homebrew Cask",
                    "GITHUB_WORKFLOW_SHA": "d" * 40,
                    "GITHUB_WORKFLOW_REF": (
                        "manaflow-ai/cmux/.github/workflows/update-homebrew.yml@refs/heads/main"
                    ),
                    "GITHUB_OUTPUT": str(output_path),
                    "GH_TOKEN": "fixture-token",
                }
            )
            if expected:
                env.update(expected)
            result = subprocess.run(
                ["bash", str(VALIDATOR)],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            if output_path.exists():
                result.stdout += "\n" + output_path.read_text(encoding="utf-8")
            return result

    def test_workflow_contract_is_secret_and_runner_safe(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        document = yaml.load(text, Loader=yaml.BaseLoader)
        self.assertEqual(document["permissions"], {})
        triggers = document["on"]
        self.assertEqual(triggers["workflow_run"]["workflows"], ["Release macOS app"])
        self.assertEqual(triggers["workflow_run"]["types"], ["completed"])
        self.assertNotIn("workflow_dispatch", triggers)
        jobs = document["jobs"]
        self.assertEqual(jobs["validate-source"]["runs-on"], "ubuntu-24.04")
        self.assertEqual(jobs["publish-cask"]["runs-on"], "ubuntu-24.04")
        self.assertEqual(
            jobs["validate-source"]["permissions"], {"actions": "read", "contents": "read"}
        )
        self.assertEqual(
            jobs["publish-cask"]["permissions"], {"actions": "read", "contents": "read"}
        )
        self.assertEqual(jobs["publish-cask"]["environment"]["name"], "homebrew-cask")
        self.assertIn("secrets.HOMEBREW_CASK_TAP_TOKEN", text)
        self.assertNotIn("secrets.HOMEBREW_TAP_TOKEN", text)
        self.assertNotIn("vars.LINUX_RUNNER", text)
        for job in jobs.values():
            for step in job.get("steps", []):
                self.assertNotIn("${{", step.get("run", ""))
                if step.get("uses", "").startswith("actions/checkout@"):
                    self.assertEqual(step.get("with", {}).get("persist-credentials"), "false")
                    expected_ref = (
                        "main"
                        if step.get("with", {}).get("path") == "homebrew-cmux"
                        else "${{ github.workflow_sha }}"
                    )
                    self.assertEqual(step.get("with", {}).get("ref"), expected_ref)

    def test_valid_workflow_run_is_accepted(self) -> None:
        event, api = _base_fixture()
        result = self.run_validator(event, api)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skip=false", result.stdout)
        self.assertIn("tag=v1.2.3", result.stdout)
        self.assertIn("release_sha=" + "a" * 40, result.stdout)

    def test_workflow_run_payload_must_bind_every_provenance_field(self) -> None:
        event, api = _base_fixture()
        del event["workflow_run"]["workflow_id"]
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_different_source_workflow_is_rejected(self) -> None:
        event, api = _base_fixture()
        event["workflow_run"]["workflow_id"] = 999
        api["repos/manaflow-ai/cmux/actions/runs/123456789"]["workflow_id"] = 999
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_workflow_run_must_execute_from_main(self) -> None:
        event, api = _base_fixture()
        result = self.run_validator(event, api, ref="refs/heads/attacker")
        self.assertNotEqual(result.returncode, 0)

    def test_source_run_repository_ids_are_required(self) -> None:
        event, api = _base_fixture()
        del api["repos/manaflow-ai/cmux/actions/runs/123456789"]["repository"]["id"]
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_failed_source_run_is_rejected(self) -> None:
        event, api = _base_fixture()
        api["repos/manaflow-ai/cmux/actions/runs/123456789"]["conclusion"] = "failure"
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_fork_source_run_is_rejected(self) -> None:
        event, api = _base_fixture()
        api["repos/manaflow-ai/cmux/actions/runs/123456789"]["head_repository"] = {
            "id": 2,
            "full_name": "attacker/cmux",
        }
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_tag_commit_mismatch_is_rejected(self) -> None:
        event, api = _base_fixture()
        api["repos/manaflow-ai/cmux/git/ref/tags/v1.2.3"]["object"]["sha"] = "c" * 40
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_unmerged_release_commit_is_rejected(self) -> None:
        event, api = _base_fixture()
        api["repos/manaflow-ai/cmux/compare/main..." + "a" * 40]["status"] = "ahead"
        api["repos/manaflow-ai/cmux/compare/main..." + "a" * 40]["ahead_by"] = 1
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_asset_digest_mismatch_is_rejected(self) -> None:
        event, api = _base_fixture()
        api["repos/manaflow-ai/cmux/releases/tags/v1.2.3"]["assets"][0]["digest"] = (
            "sha256:" + "d" * 64
        )
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_noncanonical_asset_url_is_rejected(self) -> None:
        event, api = _base_fixture()
        attacker_url = "https://attacker.invalid/cmux-macos.dmg"
        api["repos/manaflow-ai/cmux/releases/tags/v1.2.3"]["assets"][0][
            "browser_download_url"
        ] = attacker_url
        api["repos/manaflow-ai/cmux/releases/assets/987654321"][
            "browser_download_url"
        ] = attacker_url
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_duplicate_dmg_assets_are_rejected(self) -> None:
        event, api = _base_fixture()
        release = api["repos/manaflow-ai/cmux/releases/tags/v1.2.3"]
        release["assets"].append(dict(release["assets"][0]))
        result = self.run_validator(event, api)
        self.assertNotEqual(result.returncode, 0)

    def test_older_release_is_skipped_without_publishing(self) -> None:
        event, api = _base_fixture()
        api["repos/manaflow-ai/cmux/releases/latest"]["tag_name"] = "v1.2.4"
        result = self.run_validator(event, api)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skip=true", result.stdout)

    def test_manual_dispatch_is_rejected(self) -> None:
        event, api = _base_fixture()
        result = self.run_validator(event, api, event_name="workflow_dispatch")
        self.assertNotEqual(result.returncode, 0)

    def test_malformed_event_payload_is_rejected(self) -> None:
        _, api = _base_fixture()
        result = self.run_validator([], api)  # type: ignore[arg-type]
        self.assertNotEqual(result.returncode, 0)

    def test_revalidation_cannot_accept_changed_digest(self) -> None:
        event, api = _base_fixture()
        expected = {"EXPECTED_ASSET_DIGEST": "sha256:" + "d" * 64}
        result = self.run_validator(event, api, expected=expected)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
