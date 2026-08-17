#!/usr/bin/env python3
"""Regression tests for explicit skipped Windows startup claims."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("startup_benchmark_claim.py")
VERIFIER = Path(__file__).with_name("verify-startup-benchmark.py")
SPEC = importlib.util.spec_from_file_location("startup_benchmark_claim", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CLAIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLAIM)


class SkippedClaimTests(unittest.TestCase):
    @staticmethod
    def _write_preflight(output_dir: Path, *, unsupported_value=None) -> str:
        preflight = {
            "schema_version": 8,
            "backend": "windows-restricted-token-job",
            "policy": "fixture-root-only-write",
            "handshake": "nonce-bound-ready-arm-with-pre-exec-t0",
            "cleanup": "descendant-channel-eof-after-process-tree-empty",
            "windows_grandchild_in_job": True,
            "windows_active_process_zero": unsupported_value,
            "windows_caller_se_impersonate_enabled": None,
            "windows_standard_handles_valid": None,
            "windows_explicit_handle_list": None,
        }
        path = output_dir / "sandbox-preflight.json"
        path.write_text(json.dumps(preflight, sort_keys=True) + "\n", encoding="utf-8")
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def _run_verifier(
        self, *, runner_os: str, unsupported_value=None
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            preflight_sha256 = self._write_preflight(
                output_dir, unsupported_value=unsupported_value
            )
            trusted_sha = "a" * 40
            candidate_sha = "b" * 40
            supervisor_sha256 = "c" * 64
            report = CLAIM.build_skipped_report(
                platform_label="windows-azure",
                backend="windows-restricted-token-job",
                trusted_sha=trusted_sha,
                baseline_sha=trusted_sha,
                candidate_sha=candidate_sha,
                supervisor_sha256=supervisor_sha256,
                preflight_sha256=preflight_sha256,
                reason="required native Windows observations were unavailable",
            )
            CLAIM.write_skipped_artifacts(
                output_dir=output_dir,
                fixture_parent_name="cbp-test",
                report=report,
            )
            environment = os.environ.copy()
            environment.update(
                {
                    "RUNNER_OS": runner_os,
                    "PLATFORM_LABEL": "windows-azure",
                    "TRUSTED_SHA": trusted_sha,
                    "BASELINE_SHA": trusted_sha,
                    "CANDIDATE_SHA": candidate_sha,
                    "SUPERVISOR_BINARY_SHA256": supervisor_sha256,
                    "SANDBOX_PREFLIGHT_SHA256": preflight_sha256,
                }
            )
            return subprocess.run(
                [sys.executable, str(VERIFIER), str(output_dir / "startup-benchmark.json")],
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_skipped_report_has_explicit_unverified_status_and_reason(self) -> None:
        report = CLAIM.build_skipped_report(
            platform_label="windows-azure",
            backend="windows-restricted-token-job",
            trusted_sha="a" * 40,
            baseline_sha="a" * 40,
            candidate_sha="b" * 40,
            supervisor_sha256="c" * 64,
            preflight_sha256="d" * 64,
            reason="required native Windows observations were unavailable",
        )

        self.assertEqual(report["status"], "skipped")
        self.assertEqual(report["infrastructure"]["sandbox_claim_status"], "unverified")
        self.assertIn("unavailable", report["skip_reason"])

    def test_verified_status_or_empty_reason_cannot_be_encoded_as_a_skip(self) -> None:
        with self.assertRaises(ValueError):
            CLAIM.build_skipped_report(
                platform_label="windows-azure",
                backend="windows-restricted-token-job",
                trusted_sha="a" * 40,
                baseline_sha="a" * 40,
                candidate_sha="b" * 40,
                supervisor_sha256="c" * 64,
                preflight_sha256="d" * 64,
                reason="",
            )

    def test_unavailable_only_windows_claim_is_accepted_as_skipped(self) -> None:
        result = self._run_verifier(runner_os="Windows")

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_false_windows_observation_is_rejected(self) -> None:
        result = self._run_verifier(runner_os="Windows", unsupported_value=False)

        self.assertNotEqual(result.returncode, 0)

    def test_skipped_claim_is_rejected_on_linux_and_macos(self) -> None:
        for runner_os in ("Linux", "macOS"):
            with self.subTest(runner_os=runner_os):
                result = self._run_verifier(runner_os=runner_os)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
