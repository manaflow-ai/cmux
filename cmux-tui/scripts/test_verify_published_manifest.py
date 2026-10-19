from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
import re
import tempfile
from unittest import TestCase, main
from unittest.mock import patch

import yaml


SCRIPT = Path(__file__).with_name("verify_published_manifest.py")
ROOT = SCRIPT.parents[2]
ARTIFACT_WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
WINDOWS_INSTALLER = ROOT / "web" / "public" / "tui" / "install-static.ps1"
SPEC = importlib.util.spec_from_file_location("verify_published_manifest", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class FakeResponse:
    def __init__(self, body: dict[str, object]) -> None:
        self.body = json.dumps(body).encode("utf-8")
        self.headers: dict[str, str] = {}
        self._read = False

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def read(self, size: int = -1) -> bytes:
        if self._read:
            return b""
        self._read = True
        return self.body


class VerifyPublishedManifestTests(TestCase):
    COMMIT = "a" * 40
    WINDOWS = "cmux-tui-x86_64-pc-windows-gnu.exe"
    CURRENT_UNIX_ONLY_MANIFEST = {
        "commit": "2dc5237c59e06b8f1007533cd4d14b13e702e553",
        "builtAt": "2026-07-15T06:35:13.005735+00:00",
        "binaries": {
            "cmux-tui-aarch64-apple-darwin":
                "21311bd5af176f5196937240b4f38c4810f01ed2e219731e8ba122256512b58d",
            "cmux-tui-aarch64-unknown-linux-gnu":
                "cc50a9cf5040f3d3a7d02d5d9faae6a479967adf3c3f5abb4c4c34796dee3046",
            "cmux-tui-x86_64-apple-darwin":
                "66ac1ee6d31fbb8de1004668de6517f59c075899a359c3946fce92f9273d3741",
            "cmux-tui-x86_64-unknown-linux-gnu":
                "8455dcebdb91d47a3988d64679f1d1ac0919ab558286e3a016ec88c24dce463a",
        },
    }

    def manifest(self, *, windows: bool = True) -> dict[str, object]:
        binaries: dict[str, str] = {}
        if windows:
            binaries[self.WINDOWS] = "b" * 64
        return {"commit": self.COMMIT, "binaries": binaries}

    def provenance(self, manifest: dict[str, object]) -> dict[str, object]:
        manifest.update(
            {
                "sourceRepository": "https://github.com/manaflow-ai/cmux",
                "sourceCommit": self.COMMIT,
                "attestationUrl": "https://github.com/manaflow-ai/cmux/actions/runs/123456789",
                "releaseUrl": None,
            }
        )
        return manifest

    def machine_manifest(self, payloads: dict[str, bytes]) -> dict[str, object]:
        targets = (
            "aarch64-apple-darwin",
            "x86_64-apple-darwin",
            "x86_64-unknown-linux-musl",
            "aarch64-unknown-linux-musl",
        )
        artifacts: dict[str, dict[str, dict[str, object]]] = {}
        for target in targets:
            target_artifacts: dict[str, dict[str, object]] = {}
            for kind in ("chatmux-relay", "cmux-tui"):
                name = f"{kind}-{target}"
                payload = payloads[name]
                target_artifacts[kind] = {
                    "name": name,
                    "url": f"https://files.cmux.com/chatmux-relay/{self.COMMIT}/{name}",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "size": len(payload),
                }
            artifacts[target] = target_artifacts
        return {
            "schemaVersion": 1,
            "sourceRepository": "https://github.com/manaflow-ai/cmux",
            "sourceCommit": self.COMMIT,
            "version": f"0.0.0-r2.sha-{self.COMMIT}",
            "workflowRunUrl": "https://github.com/manaflow-ai/cmux/actions/runs/123456789",
            "releaseUrl": f"https://github.com/manaflow-ai/cmux/releases/tag/chatmux-relay-r2-{self.COMMIT}",
            "artifacts": artifacts,
        }

    def machine_payloads(self) -> dict[str, bytes]:
        payloads: dict[str, bytes] = {}
        for target in (
            "aarch64-apple-darwin",
            "x86_64-apple-darwin",
            "x86_64-unknown-linux-musl",
            "aarch64-unknown-linux-musl",
        ):
            for kind in ("chatmux-relay", "cmux-tui"):
                name = f"{kind}-{target}"
                payloads[name] = name.encode("utf-8")
        return payloads

    def verify(self, manifest: dict[str, object]) -> None:
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            VERIFY.verify_manifest(
                "https://files.example/cmux-tui/latest/manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
            )

    def test_accepts_required_windows_artifact_and_digest(self) -> None:
        self.verify(self.manifest())

    def test_rejects_manifest_without_windows_artifact(self) -> None:
        with self.assertRaisesRegex(VERIFY.ManifestError, "missing required artifact"):
            self.verify(self.manifest(windows=False))

    def test_rejects_current_unix_only_latest_manifest(self) -> None:
        manifest = self.CURRENT_UNIX_ONLY_MANIFEST
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(
                VERIFY.ManifestError,
                "missing required artifact",
            ):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=manifest["commit"],
                    required_artifacts=(self.WINDOWS,),
                )

    def test_artifact_workflow_verifies_unix_machine_manifest_before_latest(self) -> None:
        document = yaml.safe_load(ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        build = document["jobs"]["build"]["with"]
        self.assertIs(build["include_windows"], False)
        self.assertIs(build["package_npm"], False)
        self.assertIs(build["package_pypi"], False)

        installer = WINDOWS_INSTALLER.read_text(encoding="utf-8")
        advertised = re.search(r'^\$Artifact = "([^"]+)"$', installer, re.MULTILINE)
        self.assertIsNotNone(advertised)
        self.assertEqual(advertised.group(1), self.WINDOWS)

        steps = document["jobs"]["publish"]["steps"]
        names = [step.get("name", "") for step in steps]
        before_upload = names.index("Verify Unix manifests before upload")
        upload = names.index("Upload to R2")
        before_latest = names.index("Verify immutable Unix manifests before latest publish")
        rolling = names.index("Publish rolling latest artifacts")
        after_publish = names.index("Verify published Unix manifests")
        self.assertLess(before_upload, upload)
        self.assertLess(upload, before_latest)
        self.assertLess(before_latest, rolling)
        self.assertLess(rolling, after_publish)

        upload_run = steps[upload]["run"]
        self.assertNotIn("cmux-tui/latest", upload_run)
        before_upload_run = steps[before_upload]["run"]
        before_latest_run = steps[before_latest]["run"]
        after_publish_run = steps[after_publish]["run"]
        self.assertIn(f"cmux-tui/$GITHUB_SHA/manifest.json", after_publish_run)
        self.assertIn("cmux-tui/latest/manifest.json?verify=$GITHUB_SHA", after_publish_run)
        self.assertIn("--artifact-directory assets/cmux-tui", before_upload_run)
        self.assertIn("--artifact-base-url", before_latest_run)
        self.assertIn("--artifact-base-url", after_publish_run)
        self.assertIn("chatmux-relay/$GITHUB_SHA/manifest.json", after_publish_run)
        self.assertIn("--machine-manifest", before_upload_run)
        self.assertNotIn("chatmux-relay-x86_64-pc-windows-gnu.exe", before_upload_run)
        self.assertIn("--forbid-artifact cmux-tui-x86_64-pc-windows-gnu.exe", before_upload_run)
        self.assertIn("--forbid-artifact cmux-relay-x86_64-pc-windows-gnu.exe", before_upload_run)
        self.assertNotIn("--require-dependency-artifact", before_upload_run)
        self.assertNotIn("--dependency-artifact-directory assets/cmux-tui", before_upload_run)
        self.assertIn("--require-provenance", before_upload_run)
        self.assertIn("--require-provenance", before_latest_run)
        self.assertIn("--require-provenance", after_publish_run)
        self.assertIn("pattern: chatmux-relay-*", ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn("assets/chatmux-relay/cmux-tui-*", ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        self.assertNotIn("chatmux-relay-x86_64-pc-windows-gnu.exe", ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))
        self.assertIn("chatmux-relay/$GITHUB_SHA", upload_run)
        self.assertIn("--machine-manifest", before_upload_run)
        self.assertIn("--machine-manifest", before_latest_run)
        self.assertIn("--machine-manifest", after_publish_run)
        self.assertIn("0.0.0-r2.sha-${GITHUB_SHA}", ARTIFACT_WORKFLOW.read_text(encoding="utf-8"))

        attestation = steps[names.index("Attest raw binary subjects")]
        self.assertEqual(attestation["with"]["push-to-registry"], False)

    def test_machine_manifest_builder_copies_dependency_before_directory_change(self) -> None:
        workflow = ARTIFACT_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            'cp "assets/cmux-tui/cmux-tui-${target}" "assets/chatmux-relay/cmux-tui-${target}"',
            workflow,
        )
        self.assertIn('directory="$(cd "$directory" && pwd)"', workflow)
        self.assertIn('dependency_directory="$(cd "$dependency_directory" && pwd)"', workflow)
        self.assertIn("build_machine_manifest assets/chatmux-relay assets/cmux-tui", workflow)

    def test_machine_manifest_requires_dual_unix_binaries_and_full_digests(self) -> None:
        payloads = self.machine_payloads()
        manifest = self.machine_manifest(payloads)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            for name, payload in payloads.items():
                (root / name).write_bytes(payload)
            VERIFY.verify_manifest_file(
                root / "manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(),
                artifact_directory=root,
                machine_manifest=True,
            )

    def test_machine_manifest_rejects_compatibility_fields_and_windows(self) -> None:
        payloads = self.machine_payloads()
        manifest = self.machine_manifest(payloads)
        manifest["binaries"] = {}
        manifest["artifacts"]["x86_64-pc-windows-gnu"] = {}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(VERIFY.ManifestError, "shape mismatch"):
                VERIFY.verify_manifest_file(
                path,
                expected_commit=self.COMMIT,
                required_artifacts=(),
                artifact_directory=Path(directory),
                machine_manifest=True,
                )

    def test_machine_manifest_rejects_size_or_digest_drift(self) -> None:
        payloads = self.machine_payloads()
        manifest = self.machine_manifest(payloads)
        target = manifest["artifacts"]["x86_64-unknown-linux-musl"]["chatmux-relay"]
        target["size"] += 1
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            for name, payload in payloads.items():
                (root / name).write_bytes(payload)
            with self.assertRaisesRegex(VERIFY.ManifestError, "size mismatch"):
                VERIFY.verify_manifest_file(
                    root / "manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(),
                    artifact_directory=root,
                    machine_manifest=True,
                )

    def test_rejects_manifest_with_invalid_digest(self) -> None:
        manifest = self.manifest()
        manifest["binaries"] = {self.WINDOWS: "not-a-sha256"}
        with self.assertRaisesRegex(VERIFY.ManifestError, "invalid SHA-256"):
            self.verify(manifest)

    def test_requires_source_build_provenance_when_requested(self) -> None:
        manifest = self.provenance(self.manifest())
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            VERIFY.verify_manifest(
                "https://files.example/cmux-tui/latest/manifest.json",
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
                require_provenance=True,
            )

    def test_rejects_provenance_for_a_different_source_commit(self) -> None:
        manifest = self.provenance(self.manifest())
        manifest["sourceCommit"] = "b" * 40
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(VERIFY.ManifestError, "sourceCommit"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                    require_provenance=True,
                )

    def test_rejects_provenance_attestation_outside_source_repository(self) -> None:
        manifest = self.provenance(self.manifest())
        manifest["attestationUrl"] = "https://example.com/actions/runs/1"
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(VERIFY.ManifestError, "attestationUrl"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                    require_provenance=True,
                )

    def test_validates_local_manifest_before_upload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(self.manifest()), encoding="utf-8")
            VERIFY.verify_manifest_file(
                path,
                expected_commit=self.COMMIT,
                required_artifacts=(self.WINDOWS,),
            )

    def test_verifies_every_local_binary_digest_and_exact_set(self) -> None:
        payload = b"verified binary"
        manifest = {
            "commit": self.COMMIT,
            "binaries": {"relay-linux": hashlib.sha256(payload).hexdigest()},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            (root / "relay-linux").write_bytes(payload)
            VERIFY.verify_manifest_file(
                manifest_path,
                expected_commit=self.COMMIT,
                required_artifacts=(),
                exact_artifacts=("relay-linux",),
                artifact_directory=root,
            )

    def test_rejects_local_binary_digest_mismatch(self) -> None:
        manifest = {
            "commit": self.COMMIT,
            "binaries": {"relay-linux": "a" * 64},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            (root / "relay-linux").write_bytes(b"tampered")
            with self.assertRaisesRegex(VERIFY.ManifestError, "digest mismatch"):
                VERIFY.verify_manifest_file(
                    manifest_path,
                    expected_commit=self.COMMIT,
                    required_artifacts=(),
                    artifact_directory=root,
                )

    def test_rejects_unexpected_artifact_in_exact_set(self) -> None:
        manifest = self.manifest()
        manifest["binaries"] = {
            self.WINDOWS: "b" * 64,
            "unexpected": "c" * 64,
        }
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(VERIFY.ManifestError, "artifact set mismatch"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(),
                    exact_artifacts=(self.WINDOWS,),
                )

    def test_rejects_forbidden_windows_artifact(self) -> None:
        manifest = self.manifest()
        with patch.object(VERIFY, "urlopen", return_value=FakeResponse(manifest)):
            with self.assertRaisesRegex(VERIFY.ManifestError, "forbidden artifact"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(),
                    forbidden_artifacts=(self.WINDOWS,),
                )

    def test_rejects_manifest_for_a_different_commit(self) -> None:
        manifest = self.manifest()
        manifest["commit"] = "c" * 40
        with self.assertRaisesRegex(VERIFY.ManifestError, "commit mismatch"):
            self.verify(manifest)

    def test_rejects_oversized_published_manifest(self) -> None:
        class OversizedResponse(FakeResponse):
            def __init__(self) -> None:
                self.headers = {}
                self.remaining = VERIFY.MAX_MANIFEST_BYTES + 1

            def read(self, size: int = -1) -> bytes:
                if self.remaining <= 0:
                    return b""
                count = min(size, self.remaining)
                self.remaining -= count
                return b"x" * count

        with patch.object(VERIFY, "urlopen", return_value=OversizedResponse()):
            with self.assertRaisesRegex(VERIFY.ManifestError, "size limit"):
                VERIFY.verify_manifest(
                    "https://files.example/cmux-tui/latest/manifest.json",
                    expected_commit=self.COMMIT,
                    required_artifacts=(self.WINDOWS,),
                )


if __name__ == "__main__":
    main()
