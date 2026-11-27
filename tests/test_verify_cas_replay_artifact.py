#!/usr/bin/env python3
"""Behavioral tests for the CAS replay artifact verifier."""
from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Callable, Optional


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts/ci/verify_cas_replay_artifact.py"


class CasReplayArtifactVerifier(unittest.TestCase):
    source_sha = "a" * 40

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.artifact = self.root / "artifact"
        self.artifact.mkdir()
        self.toolchain = self.root / "rust-toolchain.toml"
        self.toolchain.write_text("[toolchain]\nchannel = '1.84.1'\n", encoding="utf-8")
        self.binary = self.artifact / "cas-replay"
        self.binary.write_bytes(b"cas-replay fixture\n")
        self.manifest = {
            "schema_version": 1,
            "source_sha": self.source_sha,
            "runner_os": "Linux",
            "runner_arch": "X64",
            "build_profile": "release",
            "cargo_package": "cmux-cas",
            "cargo_bin": "cas-replay",
            "rust_toolchain_sha256": self.digest(self.toolchain),
            "binary_sha256": self.digest(self.binary),
        }
        self.write_manifest()

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def reset_fixture(self) -> None:
        self.tempdir.cleanup()
        self.setUp()

    @staticmethod
    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def write_manifest(self, value: object = None) -> None:
        value = self.manifest if value is None else value
        self.artifact.joinpath("manifest.json").write_text(
            json.dumps(value), encoding="utf-8"
        )

    def run_verifier(self, install_to: Optional[Path] = None) -> subprocess.CompletedProcess:
        target = install_to or self.root / "installed" / "cas-replay"
        env = os.environ.copy()
        env.update({"RUNNER_OS": "Linux", "RUNNER_ARCH": "X64"})
        return subprocess.run(
            [
                sys.executable,
                str(VERIFIER),
                str(self.artifact),
                "--source-sha",
                self.source_sha,
                "--toolchain",
                str(self.toolchain),
                "--install-to",
                str(target),
            ],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_rejected_without_install(self, mutate: Callable[[], None], message: str) -> None:
        install_to = self.root / "installed" / "cas-replay"
        install_to.parent.mkdir()
        install_to.write_bytes(b"sentinel")
        mutate()
        result = self.run_verifier(install_to)
        self.assertNotEqual(result.returncode, 0, message)
        self.assertEqual(install_to.read_bytes(), b"sentinel", message)

    def test_rejects_missing_manifest_without_install(self) -> None:
        self.assert_rejected_without_install(
            lambda: self.artifact.joinpath("manifest.json").unlink(), "missing manifest"
        )

    def test_rejects_malformed_and_non_object_manifests_without_install(self) -> None:
        for value, label in (("{", "malformed"), (["not", "an", "object"], "non-object")):
            with self.subTest(manifest=label):
                self.reset_fixture()
                if label == "malformed":
                    mutate = lambda: self.artifact.joinpath("manifest.json").write_text(
                        "{", encoding="utf-8"
                    )
                else:
                    mutate = lambda value=value: self.write_manifest(value)
                self.assert_rejected_without_install(
                    mutate, label
                )

    def test_rejects_wrong_source_toolchain_os_and_arch_without_install(self) -> None:
        mutations = (
            ("source", lambda: self.manifest.__setitem__("source_sha", "b" * 40)),
            ("toolchain", lambda: self.toolchain.write_text("changed\n", encoding="utf-8")),
            ("os", lambda: self.manifest.__setitem__("runner_os", "Windows")),
            ("arch", lambda: self.manifest.__setitem__("runner_arch", "ARM64")),
            ("profile", lambda: self.manifest.__setitem__("build_profile", "debug")),
            ("package", lambda: self.manifest.__setitem__("cargo_package", "other")),
            ("binary target", lambda: self.manifest.__setitem__("cargo_bin", "other")),
        )
        for label, mutate in mutations:
            with self.subTest(provenance=label):
                self.reset_fixture()
                self.assert_rejected_without_install(
                    lambda mutate=mutate: (mutate(), self.write_manifest()), label
                )

    def test_rejects_missing_or_changed_binary_without_install(self) -> None:
        self.assert_rejected_without_install(
            lambda: self.binary.unlink(), "missing binary"
        )
        self.reset_fixture()
        self.assert_rejected_without_install(
            lambda: (self.binary.write_bytes(b"changed"), self.write_manifest()),
            "changed binary",
        )

    def test_success_installs_and_makes_binary_executable(self) -> None:
        install_to = self.root / "nested" / "installed" / "cas-replay"
        result = self.run_verifier(install_to)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(install_to.read_bytes(), self.binary.read_bytes())
        self.assertTrue(install_to.stat().st_mode & stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
