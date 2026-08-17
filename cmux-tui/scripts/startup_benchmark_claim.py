#!/usr/bin/env python3
"""Create a closed report when the Windows startup claim is unverified."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from startup_benchmark_contract import (
    PREFLIGHT_STATUS_UNVERIFIED,
    SANDBOX_CLEANUP,
    SANDBOX_HANDSHAKE,
    SANDBOX_POLICY,
    WINDOWS_BACKEND as CONTRACT_WINDOWS_BACKEND,
)


SKIPPED_SCHEMA_VERSION = 4
PAIR_ORDER = "serial alternating baseline-first and candidate-first pairs"
WINDOWS_PLATFORM = "windows-azure"
WINDOWS_BACKEND = CONTRACT_WINDOWS_BACKEND
PROFILE_PURPOSE = "offline attribution of native cmux-tui startup profiles"


def _require_sha(value: str, label: str, length: int) -> str:
    if len(value) != length or any(character not in "0123456789abcdef" for character in value):
        raise ValueError(f"{label} must be a lowercase {length}-character hexadecimal value")
    return value


def _require_reason(reason: str) -> str:
    if not isinstance(reason, str) or not reason.strip():
        raise ValueError("skip reason must be non-empty")
    if len(reason.encode("utf-8")) > 4096:
        raise ValueError("skip reason is too long")
    return reason.strip()


def build_skipped_report(
    *,
    platform_label: str,
    backend: str,
    trusted_sha: str,
    baseline_sha: str,
    candidate_sha: str,
    supervisor_sha256: str,
    preflight_sha256: str,
    reason: str,
) -> dict:
    if platform_label != WINDOWS_PLATFORM:
        raise ValueError("only the Windows benchmark can be skipped")
    if backend != WINDOWS_BACKEND:
        raise ValueError("Windows skip report has the wrong sandbox backend")
    trusted_sha = _require_sha(trusted_sha, "trusted SHA", 40)
    baseline_sha = _require_sha(baseline_sha, "baseline SHA", 40)
    candidate_sha = _require_sha(candidate_sha, "candidate SHA", 40)
    if trusted_sha != baseline_sha:
        raise ValueError("trusted and baseline SHAs must match")
    if candidate_sha == baseline_sha:
        raise ValueError("baseline and candidate SHAs must differ")
    supervisor_sha256 = _require_sha(supervisor_sha256, "supervisor SHA-256", 64)
    preflight_sha256 = _require_sha(preflight_sha256, "preflight SHA-256", 64)
    reason = _require_reason(reason)
    infrastructure = {
        "trusted_sha": trusted_sha,
        "sandbox_backend": backend,
        "sandbox_policy": SANDBOX_POLICY,
        "sandbox_handshake": SANDBOX_HANDSHAKE,
        "sandbox_cleanup": SANDBOX_CLEANUP,
        "sandbox_claim_status": PREFLIGHT_STATUS_UNVERIFIED,
        "sandbox_claim_reason": reason,
        "expected_supervisor_sha256": supervisor_sha256,
        "supervisor_sha256": supervisor_sha256,
        "expected_preflight_sha256": preflight_sha256,
        "preflight_sha256": preflight_sha256,
    }
    return {
        "schema_version": SKIPPED_SCHEMA_VERSION,
        "status": "skipped",
        "skip_reason": reason,
        "platform_label": platform_label,
        "warmups": 10,
        "paired_samples": 50,
        "order": PAIR_ORDER,
        "trusted_sha": trusted_sha,
        "baseline_sha": baseline_sha,
        "candidate_sha": candidate_sha,
        "infrastructure": infrastructure,
        "scenarios": [],
    }


def _write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as destination:
        json.dump(value, destination, indent=2, sort_keys=True)
        destination.write("\n")
        destination.flush()
        os.fsync(destination.fileno())


def _write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as destination:
        destination.write(value)
        destination.flush()
        os.fsync(destination.fileno())


def write_skipped_artifacts(
    *,
    output_dir: Path,
    fixture_parent_name: str,
    report: dict,
) -> None:
    reason = report["skip_reason"]
    output_dir.mkdir(parents=True, exist_ok=True)
    _write_json(output_dir / "startup-benchmark.json", report)
    _write_text(
        output_dir / "startup-benchmark.md",
        "# cmux-tui startup benchmark\n\n"
        f"Platform: {report['platform_label']}  \n"
        "Status: skipped (unverified)  \n"
        f"Reason: {reason}\n\n"
        "No Windows startup timing claim was published because the trusted preflight "
        "did not observe every required native security signal.\n"
    )
    _write_json(
        output_dir / "startup-lifecycle.json",
        {
            "schema_version": 1,
            "status": "skipped",
            "reason": reason,
            "fixture_parent_name": fixture_parent_name,
            "report_written_before_reclamation": True,
            "deferred_roots": [],
            "pairs": [],
            "fixtures": [],
            "profiles": [],
        },
    )
    _write_json(
        output_dir / "profile-attribution.json",
        {
            "schema_version": 1,
            "purpose": PROFILE_PURPOSE,
            "status": "skipped",
            "reason": reason,
            "targets": {},
        },
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--fixture-parent-name", required=True)
    parser.add_argument("--platform-label", required=True)
    parser.add_argument("--backend", required=True)
    parser.add_argument("--trusted-sha", required=True)
    parser.add_argument("--baseline-sha", required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--supervisor-sha256", required=True)
    parser.add_argument("--preflight-sha256", required=True)
    parser.add_argument("--reason", required=True)
    return parser


def main() -> int:
    args = _parser().parse_args()
    report = build_skipped_report(
        platform_label=args.platform_label,
        backend=args.backend,
        trusted_sha=args.trusted_sha,
        baseline_sha=args.baseline_sha,
        candidate_sha=args.candidate_sha,
        supervisor_sha256=args.supervisor_sha256,
        preflight_sha256=args.preflight_sha256,
        reason=args.reason,
    )
    write_skipped_artifacts(
        output_dir=args.output_dir,
        fixture_parent_name=args.fixture_parent_name,
        report=report,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
