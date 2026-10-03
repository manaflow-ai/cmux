#!/usr/bin/env python3
"""Tests for deterministic canonical-root ownership on self-hosted runners."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/ci/resolve-canonical-root.py"
SPEC = importlib.util.spec_from_file_location("resolve_canonical_root", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CanonicalRootTests(unittest.TestCase):
    def test_controller_root_wins(self) -> None:
        root, source = MODULE.resolve(
            {
                "CMUX_CI_CANONICAL_ROOT": "/private/tmp/cmux-ci-12",
                "CMUX_PRODUCT_RUNNER": "glaeda-std-xcode-26.3",
                "RUNNER_NAME": "aws-m4pro-8-glaeda-3",
            }
        )
        self.assertEqual(root, "/private/tmp/cmux-ci-12")
        self.assertEqual(source, "controller")

    def test_owned_primary_runner_uses_base_root(self) -> None:
        self.assertEqual(
            MODULE.resolve(
                {
                    "CMUX_PRODUCT_RUNNER": "glaeda-std-xcode-26.3",
                    "RUNNER_NAME": "aws-m4pro-9-glaeda",
                }
            ),
            ("/private/tmp/cmux-ci", "runner-name"),
        )

    def test_owned_slot_runner_gets_its_own_root(self) -> None:
        self.assertEqual(
            MODULE.resolve(
                {
                    "CMUX_PRODUCT_RUNNER": "glaeda-std-xcode-26.3",
                    "RUNNER_NAME": "aws-m4pro-8-glaeda-3",
                }
            ),
            ("/private/tmp/cmux-ci-3", "runner-name"),
        )
        self.assertEqual(
            MODULE.resolve(
                {
                    "CMUX_PRODUCT_RUNNER": "glaeda-std-xcode-26.3",
                    "RUNNER_NAME": "aws-m4pro-8-glaeda-12",
                }
            )[0],
            "/private/tmp/cmux-ci-12",
        )

    def test_non_owned_runner_keeps_ephemeral_default(self) -> None:
        self.assertEqual(
            MODULE.resolve({"CMUX_PRODUCT_RUNNER": "blacksmith-12vcpu-macos-26"}),
            ("/private/tmp/cmux-ci", "default"),
        )

    def test_unrecognized_owned_runner_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "slot identity"):
            MODULE.resolve(
                {
                    "CMUX_PRODUCT_RUNNER": "glaeda-std-xcode-26.3",
                    "RUNNER_NAME": "aws-m4pro-8-glaeda-side",
                }
            )

    def test_invalid_controller_root_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "unexpected CMUX_CI_CANONICAL_ROOT"):
            MODULE.resolve({"CMUX_CI_CANONICAL_ROOT": "/tmp/shared"})

    def test_admission_exports_the_resolved_root_before_cleanup(self) -> None:
        workflow = (ROOT / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8")
        resolver = workflow.index("python3 scripts/ci/resolve-canonical-root.py")
        export = workflow.index('echo "CMUX_CI_CANONICAL_ROOT=$root" >> "$GITHUB_ENV"', resolver)
        cleanup = workflow.index("Prepare isolated admission DerivedData", resolver)
        self.assertLess(resolver, export)
        self.assertLess(export, cleanup)


if __name__ == "__main__":
    unittest.main()
