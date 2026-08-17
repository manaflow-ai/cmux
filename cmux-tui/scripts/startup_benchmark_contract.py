#!/usr/bin/env python3
"""Shared schema and validation for startup sandbox preflight evidence.

The validator returns ``verified`` for a complete platform claim. Windows also
has an explicit ``unverified`` state, which is allowed only when every common
and observed proof passes and each unsupported native observation is either
true or unavailable. Any false, missing, malformed, or foreign-platform field
is a hard failure. ``windows_grandchild_in_job`` is the one optional native
observation, so ``None`` is accepted only for the unverified Windows state.
Linux and macOS never return ``unverified``.
"""

from __future__ import annotations

import re


PREFLIGHT_SCHEMA_VERSION = 8
PREFLIGHT_STATUS_VERIFIED = "verified"
PREFLIGHT_STATUS_UNVERIFIED = "unverified"
WINDOWS_BACKEND = "windows-restricted-token-job"
LINUX_BACKEND = "linux-bwrap"
MACOS_BACKEND = "macos-seatbelt"
SANDBOX_POLICY = "fixture-root-only-write"
SANDBOX_HANDSHAKE = "nonce-bound-ready-arm-with-pre-exec-t0"
SANDBOX_CLEANUP = "descendant-channel-eof-after-process-tree-empty"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
HEX64_PATTERN = re.compile(r"[0-9a-fA-F]{64}")
SID_PATTERN = re.compile(r"S-1(?:-\d+)+")
AUTHENTICATION_ID_PATTERN = re.compile(r"[0-9a-fA-F]{16}")

COMMON_BOOLEAN_FIELDS = (
    "inside_write",
    "adjacent_write_denied",
    "descendant_adjacent_write_denied",
    "descendant_contained",
    "network_denied",
    "inbound_network_denied",
    "supervisor_ready",
)
LINUX_FIELDS = (
    "linux_no_new_privs",
    "linux_effective_capabilities_zero",
    "linux_sudo_bwrap",
    "linux_bwrap_version",
    "linux_unprivileged_userns_clone",
    "linux_max_user_namespaces",
)
WINDOWS_CORE_BOOLEAN_FIELDS = (
    "windows_low_integrity",
    "windows_no_enabled_privileges",
    "windows_registry_write_denied",
    "windows_breakaway_denied",
)
WINDOWS_OPTIONAL_FIELDS = ("windows_grandchild_in_job",)
WINDOWS_UNAVAILABLE_FIELDS = (
    "windows_active_process_zero",
    "windows_caller_se_impersonate_enabled",
    "windows_standard_handles_valid",
    "windows_explicit_handle_list",
)
WINDOWS_REQUIRED_FIELDS = (
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
)
WINDOWS_REQUIRED_BOOLEAN_FIELDS = (
    "windows_bootstrap_config_consumed",
    "windows_bootstrap_exact_job",
    "windows_bootstrap_trusted_path_write_denied",
    "windows_bootstrap_self_write_denied",
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
    "windows_private_window_station_created",
    "windows_private_desktop_created",
    "windows_private_desktop_broker_assigned",
    "windows_private_desktop_product_assigned",
    "windows_private_desktop_closed_after_job_empty",
)
WINDOWS_FIELDS = (
    *WINDOWS_CORE_BOOLEAN_FIELDS,
    *WINDOWS_OPTIONAL_FIELDS,
    *WINDOWS_UNAVAILABLE_FIELDS,
    *WINDOWS_REQUIRED_FIELDS,
)
EXPECTED_PREFLIGHT_FIELDS = (
    "schema_version",
    "backend",
    "policy",
    "handshake",
    "cleanup",
    *COMMON_BOOLEAN_FIELDS,
    *LINUX_FIELDS,
    *WINDOWS_FIELDS,
    "timing_records",
    "supervisor_sha256",
)


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _require_true_fields(evidence: dict, fields: tuple[str, ...], label: str) -> None:
    _require(
        all(evidence[field] is True for field in fields),
        f"{label} must be true",
    )


def _require_optional_boolean_fields(
    evidence: dict, fields: tuple[str, ...], label: str
) -> None:
    _require(
        all(
            evidence[field] is None or isinstance(evidence[field], bool)
            for field in fields
        ),
        f"{label} must be boolean or unavailable",
    )


def _validate_identity(evidence: dict, expected_supervisor_sha256: str) -> None:
    _require(
        isinstance(evidence, dict),
        "preflight evidence must be an object",
    )
    actual_fields = set(evidence)
    expected_fields = set(EXPECTED_PREFLIGHT_FIELDS)
    _require(
        actual_fields == expected_fields,
        "preflight evidence has unknown or missing fields",
    )
    _require(
        evidence["schema_version"] == PREFLIGHT_SCHEMA_VERSION,
        "preflight evidence has the wrong schema version",
    )
    _require(
        evidence["policy"] == SANDBOX_POLICY
        and evidence["handshake"] == SANDBOX_HANDSHAKE
        and evidence["cleanup"] == SANDBOX_CLEANUP,
        "preflight evidence has the wrong sandbox contract",
    )
    _require(
        isinstance(expected_supervisor_sha256, str)
        and SHA256_PATTERN.fullmatch(expected_supervisor_sha256) is not None,
        "expected supervisor SHA-256 is invalid",
    )
    _require(
        evidence["supervisor_sha256"] == expected_supervisor_sha256,
        "preflight evidence has the wrong supervisor SHA-256",
    )
    _require(
        isinstance(evidence["timing_records"], int)
        and not isinstance(evidence["timing_records"], bool)
        and evidence["timing_records"] == 1,
        "preflight evidence has incomplete timing records",
    )
    _require_true_fields(evidence, COMMON_BOOLEAN_FIELDS, "common preflight proofs")


def _validate_linux(evidence: dict) -> str:
    _require(evidence["backend"] == LINUX_BACKEND, "Linux preflight backend is invalid")
    _require_true_fields(
        evidence,
        ("linux_no_new_privs", "linux_effective_capabilities_zero"),
        "Linux preflight proofs",
    )
    _require(
        isinstance(evidence["linux_sudo_bwrap"], bool),
        "Linux sudo bubblewrap mode is unavailable",
    )
    _require(
        isinstance(evidence["linux_bwrap_version"], str)
        and bool(evidence["linux_bwrap_version"]),
        "Linux bubblewrap version is unavailable",
    )
    for field in ("linux_unprivileged_userns_clone", "linux_max_user_namespaces"):
        value = evidence[field]
        _require(
            value is None
            or (
                isinstance(value, int)
                and not isinstance(value, bool)
                and value >= 0
            ),
            f"{field} is invalid",
        )
    _require_optional_boolean_fields(
        evidence,
        ("linux_no_new_privs", "linux_effective_capabilities_zero", "linux_sudo_bwrap"),
        "Linux boolean fields",
    )
    _require(
        all(evidence[field] is None for field in WINDOWS_FIELDS),
        "Linux preflight contains Windows proof fields",
    )
    return PREFLIGHT_STATUS_VERIFIED


def _validate_macos(evidence: dict) -> str:
    _require(evidence["backend"] == MACOS_BACKEND, "macOS preflight backend is invalid")
    _require(
        all(evidence[field] is None for field in (*LINUX_FIELDS, *WINDOWS_FIELDS)),
        "macOS preflight contains foreign-platform proof fields",
    )
    return PREFLIGHT_STATUS_VERIFIED


def _validate_windows(evidence: dict, allow_unverified_windows: bool) -> str:
    _require(
        evidence["backend"] == WINDOWS_BACKEND,
        "Windows preflight backend is invalid",
    )
    _require(
        all(evidence[field] is None for field in LINUX_FIELDS),
        "Windows preflight contains Linux proof fields",
    )
    _require_true_fields(evidence, WINDOWS_CORE_BOOLEAN_FIELDS, "Windows core proofs")
    _require_optional_boolean_fields(
        evidence,
        (*WINDOWS_CORE_BOOLEAN_FIELDS, *WINDOWS_OPTIONAL_FIELDS, *WINDOWS_UNAVAILABLE_FIELDS),
        "Windows observation fields",
    )

    grandchild = evidence["windows_grandchild_in_job"]
    _require(
        grandchild is None or grandchild is True,
        "Windows job-membership proof is false",
    )
    unavailable = [evidence[field] for field in WINDOWS_UNAVAILABLE_FIELDS]
    _require(
        all(value is None or value is True for value in unavailable),
        "Windows unavailable proof fields contain a failure",
    )

    _require(
        all(evidence[field] is not None for field in WINDOWS_REQUIRED_FIELDS),
        "Windows available proof fields are incomplete",
    )
    _require_true_fields(
        evidence,
        WINDOWS_REQUIRED_BOOLEAN_FIELDS,
        "Windows available boolean proofs",
    )

    bootstrap_sha256 = evidence["windows_bootstrap_sha256"]
    bootstrap_nonce = evidence["windows_bootstrap_config_nonce"]
    _require(
        isinstance(bootstrap_sha256, str)
        and SHA256_PATTERN.fullmatch(bootstrap_sha256) is not None,
        "Windows bootstrap SHA-256 is invalid",
    )
    _require(
        isinstance(bootstrap_nonce, str)
        and HEX64_PATTERN.fullmatch(bootstrap_nonce) is not None,
        "Windows bootstrap nonce is invalid",
    )
    _require(
        isinstance(evidence["windows_bootstrap_resume_previous_count"], int)
        and not isinstance(evidence["windows_bootstrap_resume_previous_count"], bool)
        and evidence["windows_bootstrap_resume_previous_count"] == 1
        and isinstance(evidence["windows_bootstrap_ready_elapsed_ms"], int)
        and not isinstance(evidence["windows_bootstrap_ready_elapsed_ms"], bool)
        and 0 <= evidence["windows_bootstrap_ready_elapsed_ms"] <= 30_000,
        "Windows bootstrap timing evidence is invalid",
    )
    restricting_sid = evidence["windows_restricting_sid"]
    authentication_id = evidence["windows_broker_authentication_id"]
    _require(
        isinstance(restricting_sid, str)
        and SID_PATTERN.fullmatch(restricting_sid) is not None
        and len(restricting_sid) <= 184,
        "Windows restricting SID is invalid",
    )
    _require(
        isinstance(authentication_id, str)
        and AUTHENTICATION_ID_PATTERN.fullmatch(authentication_id) is not None
        and evidence["windows_restricted_authentication_id"] == authentication_id
        and evidence["windows_product_authentication_id"] == authentication_id,
        "Windows authentication evidence is invalid",
    )
    _require(
        isinstance(evidence["windows_product_resume_previous_count"], int)
        and not isinstance(evidence["windows_product_resume_previous_count"], bool)
        and evidence["windows_product_resume_previous_count"] == 1,
        "Windows product resume evidence is invalid",
    )
    for field in ("windows_product_process_id", "windows_product_primary_thread_id"):
        _require(
            isinstance(evidence[field], int)
            and not isinstance(evidence[field], bool)
            and 0 < evidence[field] <= 0xFFFFFFFF,
            f"{field} is invalid",
        )
    expected_private_desktop = (
        f"cmuxb-{bootstrap_nonce[:24]}\\desk-{bootstrap_nonce[24:48]}"
    )
    _require(
        evidence["windows_private_desktop"] == expected_private_desktop,
        "Windows private desktop evidence is invalid",
    )

    if grandchild is True and all(value is True for value in unavailable):
        return PREFLIGHT_STATUS_VERIFIED
    if not allow_unverified_windows:
        raise ValueError("Windows native observations are unavailable")
    return PREFLIGHT_STATUS_UNVERIFIED


def validate_preflight_evidence(
    evidence: dict,
    *,
    expected_supervisor_sha256: str,
    allow_unverified_windows: bool,
) -> str:
    """Validate all preflight fields and return an explicit claim status."""

    _validate_identity(evidence, expected_supervisor_sha256)
    backend = evidence["backend"]
    if backend == LINUX_BACKEND:
        return _validate_linux(evidence)
    if backend == MACOS_BACKEND:
        return _validate_macos(evidence)
    if backend == WINDOWS_BACKEND:
        return _validate_windows(evidence, allow_unverified_windows)
    raise ValueError(f"unsupported preflight backend: {backend!r}")
