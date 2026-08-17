#!/usr/bin/env python3
"""Behavior tests for the shared startup preflight evidence contract."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("startup_benchmark_contract.py")
SPEC = importlib.util.spec_from_file_location("startup_benchmark_contract", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CONTRACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTRACT)


EXPECTED_FIELDS = {
    "schema_version",
    "backend",
    "policy",
    "handshake",
    "cleanup",
    "inside_write",
    "adjacent_write_denied",
    "descendant_adjacent_write_denied",
    "descendant_contained",
    "network_denied",
    "inbound_network_denied",
    "linux_no_new_privs",
    "linux_effective_capabilities_zero",
    "linux_sudo_bwrap",
    "linux_bwrap_version",
    "linux_unprivileged_userns_clone",
    "linux_max_user_namespaces",
    "windows_low_integrity",
    "windows_no_enabled_privileges",
    "windows_registry_write_denied",
    "windows_grandchild_in_job",
    "windows_breakaway_denied",
    "windows_active_process_zero",
    "windows_caller_se_impersonate_enabled",
    "windows_standard_handles_valid",
    "windows_explicit_handle_list",
    "windows_bootstrap_sha256",
    "windows_bootstrap_config_nonce",
    "windows_bootstrap_config_consumed",
    "windows_bootstrap_resume_previous_count",
    "windows_bootstrap_ready_elapsed_ms",
    "windows_bootstrap_exact_job",
    "windows_bootstrap_trusted_path_write_denied",
    "windows_bootstrap_self_write_denied",
    "windows_restricting_sid",
    "windows_broker_authentication_id",
    "windows_restricted_authentication_id",
    "windows_product_authentication_id",
    "windows_restricted_authentication_matches_broker",
    "windows_product_authentication_matches_broker",
    "windows_se_increase_quota_present",
    "windows_se_increase_quota_enabled",
    "windows_create_process_as_user_succeeded",
    "windows_restricted_token_write_restricted",
    "windows_restricted_token_restricting_sid_match",
    "windows_restricted_token_low_integrity",
    "windows_restricted_token_no_enabled_privileges",
    "windows_product_write_restricted",
    "windows_product_restricting_sid_match",
    "windows_product_low_integrity",
    "windows_product_no_enabled_privileges",
    "windows_product_exact_job",
    "windows_product_resume_previous_count",
    "windows_product_process_id",
    "windows_product_primary_thread_id",
    "windows_private_desktop",
    "windows_private_window_station_created",
    "windows_private_desktop_created",
    "windows_private_desktop_broker_assigned",
    "windows_private_desktop_product_assigned",
    "windows_private_desktop_closed_after_job_empty",
    "supervisor_ready",
    "timing_records",
    "supervisor_sha256",
}

CORE_FIELDS = (
    "inside_write",
    "adjacent_write_denied",
    "descendant_adjacent_write_denied",
    "descendant_contained",
    "network_denied",
    "inbound_network_denied",
    "supervisor_ready",
    "windows_low_integrity",
    "windows_no_enabled_privileges",
    "windows_registry_write_denied",
    "windows_breakaway_denied",
)
UNAVAILABLE_FIELDS = (
    "windows_active_process_zero",
    "windows_caller_se_impersonate_enabled",
    "windows_standard_handles_valid",
    "windows_explicit_handle_list",
)


def windows_evidence() -> dict:
    nonce = "b" * 64
    authentication_id = "0123456789abcdef"
    evidence = {field: None for field in EXPECTED_FIELDS}
    evidence.update(
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
            "linux_unprivileged_userns_clone": None,
            "linux_max_user_namespaces": None,
            "windows_low_integrity": True,
            "windows_no_enabled_privileges": True,
            "windows_registry_write_denied": True,
            "windows_grandchild_in_job": True,
            "windows_breakaway_denied": True,
            "windows_bootstrap_sha256": "a" * 64,
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
    return evidence


class StartupBenchmarkContractTests(unittest.TestCase):
    def test_contract_field_set_matches_serialized_preflight_schema(self) -> None:
        self.assertEqual(set(CONTRACT.EXPECTED_PREFLIGHT_FIELDS), EXPECTED_FIELDS)

    def test_unavailable_only_windows_fields_are_skippable_but_not_verified(self) -> None:
        evidence = windows_evidence()
        evidence["windows_grandchild_in_job"] = None
        for field in UNAVAILABLE_FIELDS:
            evidence[field] = None

        self.assertEqual(
            CONTRACT.validate_preflight_evidence(
                evidence,
                expected_supervisor_sha256="c" * 64,
                allow_unverified_windows=True,
            ),
            "unverified",
        )
        with self.assertRaises(ValueError):
            CONTRACT.validate_preflight_evidence(
                evidence,
                expected_supervisor_sha256="c" * 64,
                allow_unverified_windows=False,
            )

    def test_common_or_observed_false_proofs_reject_skipped_and_normal_paths(self) -> None:
        for field in (
            *CORE_FIELDS,
            *UNAVAILABLE_FIELDS,
            "windows_grandchild_in_job",
        ):
            with self.subTest(field=field):
                evidence = windows_evidence()
                evidence[field] = False
                for allow_unverified_windows in (True, False):
                    with self.subTest(allow_unverified_windows=allow_unverified_windows):
                        with self.assertRaises(ValueError):
                            CONTRACT.validate_preflight_evidence(
                                evidence,
                                expected_supervisor_sha256="c" * 64,
                                allow_unverified_windows=allow_unverified_windows,
                            )

    def test_missing_common_field_rejects_both_validator_modes(self) -> None:
        evidence = windows_evidence()
        del evidence["inside_write"]

        for allow_unverified_windows in (True, False):
            with self.subTest(allow_unverified_windows=allow_unverified_windows):
                    with self.assertRaises(ValueError):
                        CONTRACT.validate_preflight_evidence(
                            evidence,
                            expected_supervisor_sha256="c" * 64,
                            allow_unverified_windows=allow_unverified_windows,
                        )

    def test_unknown_field_rejects_both_validator_modes(self) -> None:
        evidence = windows_evidence()
        evidence["windows_inferred_claim"] = True
        for allow_unverified_windows in (True, False):
            with self.subTest(allow_unverified_windows=allow_unverified_windows):
                with self.assertRaises(ValueError):
                    CONTRACT.validate_preflight_evidence(
                        evidence,
                        expected_supervisor_sha256="c" * 64,
                        allow_unverified_windows=allow_unverified_windows,
                    )

    def test_resume_counts_reject_bool_and_wrong_numeric_values(self) -> None:
        for field in (
            "windows_bootstrap_resume_previous_count",
            "windows_product_resume_previous_count",
        ):
            for value in (True, 0, 2):
                with self.subTest(field=field, value=value):
                    evidence = windows_evidence()
                    evidence[field] = value
                    with self.assertRaises(ValueError):
                        CONTRACT.validate_preflight_evidence(
                            evidence,
                            expected_supervisor_sha256="c" * 64,
                            allow_unverified_windows=True,
                        )

    def test_status_contract_constants_are_explicit(self) -> None:
        self.assertEqual(CONTRACT.PREFLIGHT_STATUS_VERIFIED, "verified")
        self.assertEqual(CONTRACT.PREFLIGHT_STATUS_UNVERIFIED, "unverified")

    def test_linux_and_macos_contracts_remain_strict(self) -> None:
        for backend in ("linux-bwrap", "macos-seatbelt"):
            with self.subTest(backend=backend):
                evidence = windows_evidence()
                evidence["backend"] = backend
                for field in (
                    "windows_low_integrity",
                    "windows_no_enabled_privileges",
                    "windows_registry_write_denied",
                    "windows_grandchild_in_job",
                    "windows_breakaway_denied",
                ):
                    evidence[field] = None
                for field in UNAVAILABLE_FIELDS:
                    evidence[field] = None
                for field in EXPECTED_FIELDS:
                    if field.startswith("windows_"):
                        evidence[field] = None
                if backend == "linux-bwrap":
                    evidence.update(
                        {
                            "linux_no_new_privs": True,
                            "linux_effective_capabilities_zero": True,
                            "linux_sudo_bwrap": True,
                            "linux_bwrap_version": "0.9.0",
                        }
                    )
                self.assertEqual(
                    CONTRACT.validate_preflight_evidence(
                        evidence,
                        expected_supervisor_sha256="c" * 64,
                        allow_unverified_windows=False,
                    ),
                    "verified",
                )
                if backend == "linux-bwrap":
                    evidence["linux_sudo_bwrap"] = False
                    self.assertEqual(
                        CONTRACT.validate_preflight_evidence(
                            evidence,
                            expected_supervisor_sha256="c" * 64,
                            allow_unverified_windows=False,
                        ),
                        "verified",
                    )


if __name__ == "__main__":
    unittest.main()
