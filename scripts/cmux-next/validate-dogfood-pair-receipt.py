#!/usr/bin/env python3
"""Fail-closed validator for an exact-head cmux-next iOS/Mac dogfood receipt.

The launcher receipt proves that the installed iOS app reached a usable RPC
session. This offline validator adds the provenance gate that a runtime run
cannot establish by itself: the receipt, installed iOS bundle metadata, and
tagged Mac bundle must all name the expected commit and tag. It intentionally
prints only non-sensitive summary fields so it is safe to attach to a handoff.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path
from typing import Any


RECEIPT_SCHEMA = "cmux-ios-dogfood-readiness-v1"
SHA40 = re.compile(r"^[0-9a-fA-F]{40}$")
SHA64 = re.compile(r"^[0-9a-fA-F]{64}$")
SECRET_KEY = re.compile(r"(?:token|password|secret|cookie)", re.IGNORECASE)


class ValidationError(ValueError):
    """A receipt or bundle failed the exact-head contract."""


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{field} must be a non-empty string")
    return value


def _integer(value: Any, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValidationError(f"{field} must be an integer >= {minimum}")
    return value


def _commit_matches(value: Any, expected: str, field: str) -> str:
    """Accept the full expected SHA or its clean short git prefix."""
    actual = _string(value, field)
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", actual):
        raise ValidationError(f"{field} must be a clean 7-40 character hexadecimal SHA")
    if not expected.lower().startswith(actual.lower()):
        raise ValidationError(f"{field} does not match expected head")
    return actual


def _walk_for_secret_keys(value: Any, path: str = "receipt") -> None:
    if isinstance(value, dict):
        for key, nested in value.items():
            key_text = str(key)
            if SECRET_KEY.search(key_text):
                raise ValidationError(f"{path}.{key_text} is a forbidden secret-like field")
            _walk_for_secret_keys(nested, f"{path}.{key_text}")
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            _walk_for_secret_keys(nested, f"{path}[{index}]")


def _load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"could not read {label}: {error}") from error
    if not isinstance(value, dict):
        raise ValidationError(f"{label} must be a JSON object")
    return value


def _load_mac_info(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise ValidationError(f"could not read Mac Info.plist: {error}") from error
    if not isinstance(value, dict):
        raise ValidationError("Mac Info.plist must contain a dictionary")
    return value


def validate(
    receipt: dict[str, Any],
    mac_info: dict[str, Any],
    *,
    expected_sha: str,
    expected_tag: str,
    expected_bundle_id: str,
) -> dict[str, Any]:
    """Validate and return a secret-free summary."""
    if not SHA40.fullmatch(expected_sha):
        raise ValidationError("expected SHA must be a 40-character hexadecimal commit")
    if not expected_tag.strip():
        raise ValidationError("expected tag must be non-empty")
    if not expected_bundle_id.strip():
        raise ValidationError("expected bundle id must be non-empty")

    _walk_for_secret_keys(receipt)
    if receipt.get("schema") != RECEIPT_SCHEMA:
        raise ValidationError(f"receipt schema must be {RECEIPT_SCHEMA}")
    if receipt.get("readiness") not in (None, "mac-rpc"):
        raise ValidationError("receipt is not a paired mac-rpc readiness receipt")

    _commit_matches(receipt.get("git_sha"), expected_sha, "receipt.git_sha")
    tooling_sha = _string(receipt.get("tooling_checkout_sha"), "receipt.tooling_checkout_sha")
    if tooling_sha.lower() != expected_sha.lower():
        raise ValidationError("launcher checkout SHA does not match expected head")
    if receipt.get("tag") != expected_tag:
        raise ValidationError("iOS receipt tag does not match expected tag")
    if receipt.get("mac_tag") != expected_tag:
        raise ValidationError("paired Mac tag does not match expected tag")
    if receipt.get("bundle_id") != expected_bundle_id:
        raise ValidationError("iOS receipt bundle id does not match expected bundle id")

    target = _string(receipt.get("target"), "receipt.target")
    if target not in {"physical_device", "simulator_injection"}:
        raise ValidationError("receipt.target must be physical_device or simulator_injection")
    _string(receipt.get("target_id"), "receipt.target_id")
    _string(receipt.get("mac_tag"), "receipt.mac_tag")
    _string(receipt.get("connection_id"), "receipt.connection_id")
    _string(receipt.get("client_id"), "receipt.client_id")
    _string(receipt.get("stream_id"), "receipt.stream_id")
    _string(receipt.get("transport"), "receipt.transport")
    _integer(receipt.get("readiness_latency_ms"), "receipt.readiness_latency_ms")
    _integer(receipt.get("attempt_count"), "receipt.attempt_count", minimum=1)
    workspace_count = _integer(receipt.get("workspace_count"), "receipt.workspace_count", minimum=1)
    if receipt.get("auth_proof") != "stack_same_account_rpc":
        raise ValidationError("receipt lacks the same-account paired RPC proof")

    installed = receipt.get("installed_bundle")
    if not isinstance(installed, dict):
        raise ValidationError("receipt.installed_bundle must be an object")
    if installed.get("bundle_id") != expected_bundle_id:
        raise ValidationError("installed iOS bundle id does not match expected bundle id")
    if installed.get("target") != target or installed.get("target_id") != receipt.get("target_id"):
        raise ValidationError("installed iOS bundle target does not match the readiness receipt")
    _commit_matches(
        installed.get("source_git_sha"), expected_sha, "installed_bundle.source_git_sha"
    )
    if installed.get("dev_tag") != expected_tag:
        raise ValidationError("installed bundle dev tag does not match expected tag")
    executable_sha = _string(installed.get("executable_sha256"), "installed_bundle.executable_sha256")
    if not SHA64.fullmatch(executable_sha):
        raise ValidationError("installed bundle executable SHA must be 64 hexadecimal characters")
    if installed.get("metadata_source") not in {"signed_app_bundle", "simulator_container"}:
        raise ValidationError("installed bundle metadata is not from an inspected app bundle")

    _commit_matches(mac_info.get("CMUXGitSHA"), expected_sha, "Mac CMUXGitSHA")
    if mac_info.get("CMUXDevTag") != expected_tag:
        raise ValidationError("tagged Mac dev tag does not match expected tag")
    _string(mac_info.get("CFBundleIdentifier"), "Mac CFBundleIdentifier")
    _string(mac_info.get("CFBundleExecutable"), "Mac CFBundleExecutable")

    return {
        "status": "pass",
        "schema": RECEIPT_SCHEMA,
        "source_sha": expected_sha.lower(),
        "tag": expected_tag,
        "bundle_id": expected_bundle_id,
        "target": target,
        "transport": receipt["transport"],
        "workspace_count": workspace_count,
        "mac_provenance": "Info.plist",
        "ios_executable_sha256": executable_sha.lower(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--mac-info-plist", type=Path, required=True)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--expected-tag", required=True)
    parser.add_argument("--expected-bundle-id", required=True)
    args = parser.parse_args(argv)
    try:
        summary = validate(
            _load_json(args.receipt, "readiness receipt"),
            _load_mac_info(args.mac_info_plist),
            expected_sha=args.expected_sha,
            expected_tag=args.expected_tag,
            expected_bundle_id=args.expected_bundle_id,
        )
    except ValidationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
