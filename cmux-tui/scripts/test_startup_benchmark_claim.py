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
CONTRACT_SCRIPT = Path(__file__).with_name("startup_benchmark_contract.py")
VERIFIER = Path(__file__).with_name("verify-startup-benchmark.py")
CONTRACT_SPEC = importlib.util.spec_from_file_location(
    "startup_benchmark_contract", CONTRACT_SCRIPT
)
if CONTRACT_SPEC is None or CONTRACT_SPEC.loader is None:
    raise RuntimeError(f"cannot load {CONTRACT_SCRIPT}")
CONTRACT = importlib.util.module_from_spec(CONTRACT_SPEC)
CONTRACT_SPEC.loader.exec_module(CONTRACT)
sys.modules["startup_benchmark_contract"] = CONTRACT
SPEC = importlib.util.spec_from_file_location("startup_benchmark_claim", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CLAIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLAIM)


class SkippedClaimTests(unittest.TestCase):
    @staticmethod
    def _write_appcontainer_evidence(
        output_dir: Path,
        *,
        runner_readable=True,
        runner_hash="d" * 64,
        expected_hash="d" * 64,
        staging_acl_attested=True,
        fixture_acl_attested=True,
        account_readable=False,
        account_error_code=5,
        restricted_token_run_started=False,
    ) -> None:
        (output_dir / "windows-appcontainer-feasibility.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "status": "unavailable",
                    "backend": "windows-appcontainer-feasibility",
                    "nonce": "e" * 64,
                    "stage": "staging-readability",
                    "reason": (
                        "dedicated Windows account could not read the nonce-bound staged "
                        "target before the restricted-token broker started"
                    ),
                    "runner_staged_target_readable": runner_readable,
                    "runner_staged_target_sha256": runner_hash,
                    "expected_staged_target_sha256": expected_hash,
                    "staging_creation_acl_applied": staging_acl_attested,
                    "fixture_creation_acl_applied": fixture_acl_attested,
                    "staged_target_regular_file": True,
                    "account_staged_target_readable": account_readable,
                    "account_staged_target_error_code": account_error_code,
                    "restricted_token_run_started": restricted_token_run_started,
                    "profile_deleted": True,
                    "account_profile_unloaded": True,
                    "adjacent_sentinel_deleted": True,
                    "staging_directory_deleted": True,
                    "fixture_directory_deleted": True,
                    "preexisting_parent_before_sha256": "f" * 64,
                    "preexisting_parent_after_sha256": "f" * 64,
                    "preexisting_parent_unchanged": True,
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    @staticmethod
    def _write_preflight(
        output_dir: Path,
        *,
        unsupported_value=None,
        false_field=None,
        missing_field=None,
        bootstrap_value=b"trusted Windows bootstrap",
        grandchild_value=True,
    ) -> str:
        nonce = "b" * 64
        authentication_id = "0123456789abcdef"
        bootstrap_path = output_dir / "trusted-bootstrap.exe"
        bootstrap_path.write_bytes(bootstrap_value)
        bootstrap_sha256 = hashlib.sha256(bootstrap_value).hexdigest()
        preflight = {field: None for field in CONTRACT.EXPECTED_PREFLIGHT_FIELDS}
        preflight.update(
            {
                "schema_version": 8,
                "backend": "windows-restricted-token-job",
                "policy": "fixture-root-only-write",
                "handshake": "nonce-bound-ready-arm-with-pre-exec-t0",
                "cleanup": "descendant-channel-eof-after-process-tree-empty",
                "inside_write": True,
                "adjacent_write_denied": True,
                "descendant_adjacent_write_denied": True,
                "descendant_contained": True,
                "network_denied": True,
                "inbound_network_denied": True,
                "windows_low_integrity": True,
                "windows_no_enabled_privileges": True,
                "windows_registry_write_denied": True,
                "windows_grandchild_in_job": grandchild_value,
                "windows_breakaway_denied": True,
                "windows_active_process_zero": unsupported_value,
                "windows_bootstrap_sha256": bootstrap_sha256,
                "windows_bootstrap_config_nonce": nonce,
                "windows_bootstrap_config_consumed": True,
                "windows_bootstrap_resume_previous_count": 1,
                "windows_bootstrap_ready_elapsed_ms": 1,
                "windows_bootstrap_exact_job": True,
                "windows_bootstrap_trusted_path_write_denied": True,
                "windows_bootstrap_self_write_denied": True,
                "windows_restricting_sid": "S-1-5-21",
                "windows_broker_authentication_id": authentication_id,
                "windows_restricted_authentication_id": authentication_id,
                "windows_product_authentication_id": authentication_id,
                "windows_restricted_authentication_matches_broker": True,
                "windows_product_authentication_matches_broker": True,
                "windows_se_increase_quota_present": True,
                "windows_se_increase_quota_enabled": True,
                "windows_create_process_as_user_succeeded": True,
                "windows_restricted_token_write_restricted": True,
                "windows_restricted_token_restricting_sid_match": True,
                "windows_restricted_token_low_integrity": True,
                "windows_restricted_token_no_enabled_privileges": True,
                "windows_product_write_restricted": True,
                "windows_product_restricting_sid_match": True,
                "windows_product_low_integrity": True,
                "windows_product_no_enabled_privileges": True,
                "windows_product_exact_job": True,
                "windows_product_resume_previous_count": 1,
                "windows_product_process_id": 1,
                "windows_product_primary_thread_id": 1,
                "windows_private_desktop": f"cmuxb-{nonce[:24]}\\desk-{nonce[24:48]}",
                "windows_private_window_station_created": True,
                "windows_private_desktop_created": True,
                "windows_private_desktop_broker_assigned": True,
                "windows_private_desktop_product_assigned": True,
                "windows_private_desktop_closed_after_job_empty": True,
                "supervisor_ready": True,
                "timing_records": 1,
                "supervisor_sha256": "c" * 64,
            }
        )
        if false_field is not None:
            preflight[false_field] = False
        if missing_field is not None:
            del preflight[missing_field]
        path = output_dir / "sandbox-preflight.json"
        path.write_text(json.dumps(preflight, sort_keys=True) + "\n", encoding="utf-8")
        imports_path = output_dir / "windows-bootstrap-imports.json"
        imports_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "bootstrap_sha256": bootstrap_sha256,
                    "dependencies": ["advapi32.dll", "bcrypt.dll", "kernel32.dll"],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        imports_sha256 = hashlib.sha256(imports_path.read_bytes()).hexdigest()
        (output_dir / "startup-integrity-before.json").write_text(
            json.dumps(
                {
                    "trusted_sha": "a" * 40,
                    "files": {
                        "trusted_windows_bootstrap": {
                            "path": str(bootstrap_path.resolve()),
                            "sha256": bootstrap_sha256,
                            "size_bytes": len(bootstrap_value),
                        },
                        "trusted_windows_bootstrap_imports": {
                            "path": str(imports_path.resolve()),
                            "sha256": imports_sha256,
                            "size_bytes": imports_path.stat().st_size,
                        },
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def _run_verifier(
        self,
        *,
        runner_os: str,
        unsupported_value=None,
        false_field=None,
        missing_field=None,
        bootstrap_value=b"trusted Windows bootstrap",
        grandchild_value=True,
        tamper_bootstrap=False,
        tamper_imports=False,
        appcontainer_evidence=None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            output_dir = Path(temporary)
            preflight_sha256 = self._write_preflight(
                output_dir,
                unsupported_value=unsupported_value,
                false_field=false_field,
                missing_field=missing_field,
                bootstrap_value=bootstrap_value,
                grandchild_value=grandchild_value,
            )
            if tamper_bootstrap:
                (output_dir / "trusted-bootstrap.exe").write_bytes(b"tampered")
            if tamper_imports:
                (output_dir / "windows-bootstrap-imports.json").write_text(
                    json.dumps(
                        {
                            "schema_version": 1,
                            "bootstrap_sha256": "0" * 64,
                            "dependencies": ["evil.dll"],
                        }
                    )
                    + "\n",
                    encoding="utf-8",
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
            if appcontainer_evidence is None:
                self._write_appcontainer_evidence(output_dir)
            else:
                (output_dir / "windows-appcontainer-feasibility.json").write_text(
                    json.dumps(appcontainer_evidence, sort_keys=True) + "\n",
                    encoding="utf-8",
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

        optional_result = self._run_verifier(
            runner_os="Windows", grandchild_value=None
        )
        self.assertEqual(optional_result.returncode, 0, optional_result.stderr)

        grandchild_only_result = self._run_verifier(
            runner_os="Windows", grandchild_value=None, unsupported_value=True
        )
        self.assertEqual(
            grandchild_only_result.returncode, 0, grandchild_only_result.stderr
        )

    def test_false_windows_observation_is_rejected(self) -> None:
        result = self._run_verifier(runner_os="Windows", unsupported_value=False)

        self.assertNotEqual(result.returncode, 0)

    def test_false_common_or_observed_proof_is_rejected(self) -> None:
        for field in (
            "inside_write",
            "adjacent_write_denied",
            "descendant_adjacent_write_denied",
            "descendant_contained",
            "network_denied",
            "inbound_network_denied",
            "windows_low_integrity",
            "windows_no_enabled_privileges",
            "windows_registry_write_denied",
            "windows_breakaway_denied",
            "windows_grandchild_in_job",
            "windows_active_process_zero",
            "windows_caller_se_impersonate_enabled",
            "windows_standard_handles_valid",
            "windows_explicit_handle_list",
        ):
            with self.subTest(field=field):
                result = self._run_verifier(runner_os="Windows", false_field=field)
                self.assertNotEqual(result.returncode, 0)

    def test_missing_common_proof_is_rejected(self) -> None:
        result = self._run_verifier(runner_os="Windows", missing_field="inside_write")
        self.assertNotEqual(result.returncode, 0)

    def test_missing_available_proof_is_rejected(self) -> None:
        result = self._run_verifier(
            runner_os="Windows", missing_field="windows_bootstrap_sha256"
        )
        self.assertNotEqual(result.returncode, 0)

    def test_bootstrap_hash_or_imports_are_required_for_skips(self) -> None:
        for option in ("tamper_bootstrap", "tamper_imports"):
            with self.subTest(option=option):
                result = self._run_verifier(runner_os="Windows", **{option: True})
                self.assertNotEqual(result.returncode, 0)

    def test_generic_appcontainer_access_denied_is_not_an_unavailable_claim(self) -> None:
        result = self._run_verifier(
            runner_os="Windows",
            appcontainer_evidence={
                "schema_version": 4,
                "nonce": "e" * 64,
                "stage": "config-validate",
                "error": "Access is denied. (os error 5)",
            },
        )
        self.assertNotEqual(result.returncode, 0)

    def test_unavailable_appcontainer_claim_requires_runner_and_cleanup_attestation(self) -> None:
        for changes in (
            {"runner_staged_target_readable": False},
            {"runner_staged_target_sha256": "0" * 64},
            {"staging_creation_acl_applied": False},
            {"fixture_creation_acl_applied": False},
            {"account_staged_target_error_code": None},
            {"account_staged_target_error_code": 5, "restricted_token_run_started": True},
            {"preexisting_parent_unchanged": False},
        ):
            with self.subTest(changes=changes):
                evidence = {
                    "schema_version": 1,
                    "status": "unavailable",
                    "backend": "windows-appcontainer-feasibility",
                    "nonce": "e" * 64,
                    "stage": "staging-readability",
                    "reason": "staged target was unavailable to the dedicated account",
                    "runner_staged_target_readable": True,
                    "runner_staged_target_sha256": "d" * 64,
                    "expected_staged_target_sha256": "d" * 64,
                    "staging_creation_acl_applied": True,
                    "fixture_creation_acl_applied": True,
                    "staged_target_regular_file": True,
                    "account_staged_target_readable": False,
                    "account_staged_target_error_code": 5,
                    "restricted_token_run_started": False,
                    "profile_deleted": True,
                    "account_profile_unloaded": True,
                    "adjacent_sentinel_deleted": True,
                    "staging_directory_deleted": True,
                    "fixture_directory_deleted": True,
                    "preexisting_parent_before_sha256": "f" * 64,
                    "preexisting_parent_after_sha256": "f" * 64,
                    "preexisting_parent_unchanged": True,
                }
                evidence.update(changes)
                result = self._run_verifier(
                    runner_os="Windows", appcontainer_evidence=evidence
                )
                self.assertNotEqual(result.returncode, 0)

    def test_skipped_claim_is_rejected_on_linux_and_macos(self) -> None:
        for runner_os in ("Linux", "macOS"):
            with self.subTest(runner_os=runner_os):
                result = self._run_verifier(runner_os=runner_os)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
