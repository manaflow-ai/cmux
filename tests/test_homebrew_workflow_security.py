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
        f"repos/{repository}/releases/tags/{tag}": release,
        f"repos/{repository}/releases/assets/{asset['id']}": asset,
        f"repos/{repository}/releases/latest": {"tag_name": tag, "draft": False, "prerelease": False},
    }
    event = {
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
            "repository": {"full_name": repository},
            "head_repository": {"full_name": repository},
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
        self.assertEqual(
            triggers["workflow_dispatch"]["inputs"]["version"]["required"], "true"
        )
        self.assertEqual(
            triggers["workflow_dispatch"]["inputs"]["source_run_id"]["required"],
            "true",
        )
        jobs = document["jobs"]
        self.assertEqual(jobs["validate-source"]["runs-on"], "ubuntu-24.04")
        self.assertEqual(jobs["publish-cask"]["runs-on"], "ubuntu-24.04")
        self.assertEqual(
            jobs["validate-source"]["permissions"], {"actions": "read", "contents": "read"}
        )
        self.assertEqual(
            jobs["publish-cask"]["permissions"], {"actions": "read", "contents": "read"}
        )
        self.assertNotIn("vars.LINUX_RUNNER", text)
        for job in jobs.values():
            for step in job.get("steps", []):
                self.assertNotIn("${{", step.get("run", ""))
                if step.get("uses", "").startswith("actions/checkout@"):
                    self.assertEqual(step.get("with", {}).get("persist-credentials"), "false")

    def test_valid_workflow_run_is_accepted(self) -> None:
        event, api = _base_fixture()
        result = self.run_validator(event, api)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skip=false", result.stdout)
        self.assertIn("tag=v1.2.3", result.stdout)
        self.assertIn("release_sha=" + "a" * 40, result.stdout)

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

    def test_asset_digest_mismatch_is_rejected(self) -> None:
        event, api = _base_fixture()
        api["repos/manaflow-ai/cmux/releases/assets/987654321"]["digest"] = "sha256:" + "d" * 64
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

    def test_manual_dispatch_requires_main_and_matching_source_run(self) -> None:
        event, api = _base_fixture()
        event = {"inputs": {"version": "1.2.3", "source_run_id": "123456789"}}
        result = self.run_validator(event, api, event_name="workflow_dispatch")
        self.assertEqual(result.returncode, 0, result.stderr)

        result = self.run_validator(
            event,
            api,
            event_name="workflow_dispatch",
            ref="refs/heads/feature",
        )
        self.assertNotEqual(result.returncode, 0)

    def test_revalidation_cannot_accept_changed_digest(self) -> None:
        event, api = _base_fixture()
        expected = {"EXPECTED_ASSET_DIGEST": "sha256:" + "d" * 64}
        result = self.run_validator(event, api, expected=expected)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
