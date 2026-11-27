#!/usr/bin/env python3
"""The CAS replay rows share one default-source release executable.

W1 still compiles and tests the Rust crate in debug mode. B1 and U2 only need the
release executable, so they consume the producer artifact instead of rebuilding it.
A1 deliberately checks out feat-cmux-next and keeps its own build because it replays
published acpmux trees rather than the workflow checkout.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cas-replay.yml"
RELEASE_BUILD = "cargo build --release --locked -p cmux-cas --bin cas-replay"
DOWNLOAD = "actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131"
R2_UPLOAD = "./.github/actions/r2-artifact/upload"
R2_DOWNLOAD = "./.github/actions/r2-artifact/download"
CAS_PATHS = [
    "cmux-tui/crates/cmux-cas/**",
    "scripts/cas/**",
    "scripts/cmux-next/web-bundle-archive.py",
    ".github/workflows/cas-replay.yml",
    "tests/test_cas_web_ota_replay.py",
    "tests/test_cas_derived_data_replay.py",
    "tests/test_cas_mac_update_replay.py",
    "tests/test_cas_acpmux_update_replay.py",
    "scripts/ci/verify_cas_replay_artifact.py",
    "tests/test_cas_replay_workflow.py",
    "tests/test_verify_cas_replay_artifact.py",
]


def load_workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def run_steps(job: dict) -> list[str]:
    return [str(step.get("run", "")) for step in job.get("steps", [])]


def named_step(job: dict, name: str) -> dict:
    return next(step for step in job["steps"] if step.get("name") == name)


class CasReplayWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = load_workflow()
        cls.jobs = cls.workflow["jobs"]

    def test_triggers_and_path_routing_are_unchanged(self) -> None:
        trigger = self.workflow.get("on", self.workflow.get(True))
        self.assertEqual(trigger["push"]["branches"], ["feat-cmux-next"])
        self.assertEqual(trigger["push"]["paths"], [
            "cmux-tui/crates/cmux-cas/**",
            "cmux-tui/crates/cmux-signed-envelope/**",
            "scripts/cas/**",
            "scripts/cmux-next/web-bundle-archive.py",
            "webviews/**",
            ".github/workflows/cas-replay.yml",
            "tests/test_cas_web_ota_replay.py",
            "tests/test_cas_derived_data_replay.py",
            "tests/test_cas_mac_update_replay.py",
            "tests/test_cas_acpmux_update_replay.py",
        ])
        self.assertEqual(trigger["pull_request"]["paths"], CAS_PATHS)
        self.assertIn("workflow_dispatch", trigger)

    def test_default_source_release_build_has_one_producer(self) -> None:
        builders = [
            name for name, job in self.jobs.items()
            if RELEASE_BUILD in "\n".join(run_steps(job))
        ]
        self.assertEqual(builders, ["cas_replay_build", "a1"])
        producer = self.jobs["cas_replay_build"]
        self.assertEqual(producer["outputs"]["artifact_name"], "${{ steps.artifact_name.outputs.name }}")
        self.assertEqual(producer["outputs"]["artifact_transport"], "${{ steps.artifact-transport.outputs.transport }}")
        self.assertEqual(producer["permissions"], {"contents": "read", "id-token": "write"})
        name_step = named_step(producer, "Name run-scoped cas-replay artifact")
        self.assertIn("GITHUB_RUN_ID", name_step["run"])
        self.assertIn("GITHUB_RUN_ATTEMPT", name_step["run"])

        transport = named_step(producer, "Select the run artifact transport")
        self.assertIn("ACTIONS_ID_TOKEN_REQUEST_URL", transport["run"])
        self.assertIn("HEAD_REPOSITORY", transport["run"])
        self.assertIn("only fork pull requests may use GitHub artifacts", transport["run"])
        r2_upload = named_step(producer, "Upload cas-replay executable to R2")
        self.assertEqual(r2_upload["uses"], R2_UPLOAD)
        self.assertEqual(r2_upload["if"], "steps.artifact-transport.outputs.transport == 'r2'")
        upload = named_step(producer, "Upload cas-replay executable without OIDC")
        self.assertEqual(upload["uses"], "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02")
        self.assertEqual(upload["if"], "steps.artifact-transport.outputs.transport == 'github'")
        self.assertEqual(upload["with"]["name"], "${{ steps.artifact_name.outputs.name }}")
        self.assertEqual(upload["with"]["path"], "${{ runner.temp }}/cas-replay-artifact")
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        stage = named_step(producer, "Stage cas-replay and provenance manifest")
        self.assertIn("source_sha", stage["run"])
        self.assertIn("rust_toolchain_sha256", stage["run"])
        self.assertIn("binary_sha256", stage["run"])
        self.assertIn("RUNNER_ARCH", stage["run"])

    def test_rows_consume_the_producer_artifact(self) -> None:
        for name in ("w1", "b1", "u2"):
            with self.subTest(job=name):
                job = self.jobs[name]
                needs = job["needs"] if isinstance(job["needs"], list) else [job["needs"]]
                self.assertIn("cas_replay_build", needs)
                self.assertEqual(job["permissions"]["id-token"], "write")
                r2_download = named_step(job, "Download cas-replay executable from R2")
                self.assertEqual(r2_download["uses"], R2_DOWNLOAD)
                self.assertIn("artifact_transport == 'r2'", r2_download["if"])
                github_download = named_step(job, "Download cas-replay executable without OIDC")
                self.assertEqual(github_download["uses"], DOWNLOAD)
                self.assertIn("artifact_transport == 'github'", github_download["if"])
                for download in (r2_download, github_download):
                    self.assertEqual(download["with"]["name"], "${{ needs.cas_replay_build.outputs.artifact_name }}")
                    self.assertEqual(download["with"]["path"], "${{ runner.temp }}/cas-replay-artifact")
                verify = named_step(job, "Verify cas-replay provenance and install it")
                self.assertIn("verify_cas_replay_artifact.py", verify["run"])
                self.assertIn("--source-sha", verify["run"])
                self.assertIn("--toolchain", verify["run"])
                self.assertIn("--install-to", verify["run"])
                self.assertNotIn(RELEASE_BUILD, "\n".join(run_steps(job)))

        # A push with an already-seen NIGHTLY still skips every U2 consumer step.
        for step in self.jobs["u2"]["steps"]:
            if step.get("name") in {
                "Test the replay driver",
                "Install 7-Zip",
                "Download cas-replay executable from R2",
                "Download cas-replay executable without OIDC",
                "Verify cas-replay provenance and install it",
                "Replay N-20, N-1 and N (U2)",
            }:
                self.assertTrue(step.get("if", "").startswith("steps.seen.outputs.cache-hit != 'true'"))

    def test_w1_keeps_debug_test_and_a1_keeps_distinct_checkout(self) -> None:
        self.assertIn("cargo test -p cmux-cas --locked", "\n".join(run_steps(self.jobs["w1"])))
        a1_checkout = next(step for step in self.jobs["a1"]["steps"] if step.get("uses", "").startswith("actions/checkout@"))
        self.assertEqual(a1_checkout["with"]["ref"], "feat-cmux-next")
        self.assertIn(RELEASE_BUILD, "\n".join(run_steps(self.jobs["a1"])))
        self.assertNotIn("cas_replay_build", self.jobs["a1"].get("needs", []))

    def test_verifier_is_called_only_after_transport_download(self) -> None:
        for name in ("w1", "b1", "u2"):
            steps = self.jobs[name]["steps"]
            download_indexes = [i for i, step in enumerate(steps) if "Download cas-replay executable" in step.get("name", "")]
            verify_index = next(i for i, step in enumerate(steps) if step.get("name") == "Verify cas-replay provenance and install it")
            self.assertTrue(all(index < verify_index for index in download_indexes))


if __name__ == "__main__":
    sys.exit(unittest.main())
