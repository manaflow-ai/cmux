#!/usr/bin/env python3
"""Regression tests for explicit skipped Windows startup claims."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("startup_benchmark_claim.py")
SPEC = importlib.util.spec_from_file_location("startup_benchmark_claim", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CLAIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLAIM)


class SkippedClaimTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
