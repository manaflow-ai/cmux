#!/usr/bin/env python3
"""Tests for the explicit PR test-suite policy."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/ci/ci_test_policy.py"
SPEC = importlib.util.spec_from_file_location("ci_test_policy", HELPER)
assert SPEC and SPEC.loader
policy = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = policy
SPEC.loader.exec_module(policy)


class CITestPolicyTests(unittest.TestCase):
    def test_repository_manifest_is_valid(self) -> None:
        suites = policy.load_policy()
        self.assertGreaterEqual(len(suites), 5)

    def test_source_change_selects_only_its_platforms(self) -> None:
        selected = policy.matching_suites(["ios/cmuxPackage/Sources/cmuxFeature/Screen.swift"])
        self.assertEqual(set(selected), {"ios"})

    def test_ios_mobile_source_does_not_select_macos(self) -> None:
        selected = policy.matching_suites(["Sources/Mobile/Pairing/PairingStore.swift"])
        self.assertEqual(set(selected), {"ios"})

    def test_ios_ui_and_macos_cli_tests_have_explicit_owners(self) -> None:
        selected = policy.matching_suites([
            "ios/cmuxUITests/PairingUITests.swift",
            "cmuxCLITests/CLIContractTests.swift",
        ])
        self.assertEqual(set(selected), {"ios", "ios-ui", "macos-cli"})

    def test_shared_source_can_select_shared_and_platform_suites(self) -> None:
        selected = policy.matching_suites(["Packages/Shared/CmuxSync/Sources/Store.swift"])
        self.assertEqual(set(selected), {"macos-unit", "ios", "shared-package"})

    def test_new_test_under_known_root_is_selective_not_always(self) -> None:
        selected = policy.matching_suites(["web/tests/new-route.test.ts"])
        self.assertEqual(set(selected), {"web"})
        self.assertEqual(next(item for item in policy.load_policy() if item.id == "web").pr_mode, "selective")

    def test_always_suite_is_selected_without_a_matching_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "policy.json"
            manifest.write_text(json.dumps({"version": 1, "suite": [{
                "id": "always", "platform": "shared", "aggregate": "Shared",
                "pr_mode": "always", "test_paths": ["guard/"],
                "source_paths": ["Sources/"], "budget_seconds": 1,
            }]}), encoding="utf-8")
            self.assertEqual(policy.matching_suites([], manifest=manifest), {"always": ("<always>",)})

    def test_unowned_test_path_is_rejected(self) -> None:
        self.assertEqual(
            policy.unmatched_test_paths(["Packages/Unknown/Tests/NewTests/NewTests.swift"]),
            ("Packages/Unknown/Tests/NewTests/NewTests.swift",),
        )

    def test_unowned_product_source_is_rejected(self) -> None:
        self.assertEqual(
            policy.unmatched_product_paths(["Packages/Unknown/Sources/Feature.swift"]),
            ("Packages/Unknown/Sources/Feature.swift",),
        )

    def test_webview_tests_belong_to_web(self) -> None:
        self.assertEqual(
            set(policy.matching_suites(["webviews/test/renderer.test.ts"])),
            {"web"},
        )

    def test_off_suites_do_not_route_in_normal_pr_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "policy.json"
            manifest.write_text(json.dumps({"version": 1, "suite": [{
                "id": "manual", "platform": "macos", "aggregate": "macOS",
                "pr_mode": "off", "test_paths": ["manual-tests/"],
                "source_paths": ["Sources/Manual/"], "budget_seconds": 0,
            }]}), encoding="utf-8")
            self.assertEqual(policy.matching_suites(["manual-tests/Only.swift"], manifest=manifest), {})
            self.assertEqual(policy.unmatched_test_paths(["manual-tests/Only.swift"], manifest=manifest), ())

    def test_invalid_mode_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "policy.json"
            manifest.write_text(json.dumps({"version": 1, "suite": [{
                "id": "bad", "platform": "macos", "aggregate": "macOS",
                "pr_mode": "everywhere", "test_paths": ["cmuxTests/"],
                "source_paths": ["Sources/"], "budget_seconds": 1,
            }]}), encoding="utf-8")
            with self.assertRaises(policy.PolicyError):
                policy.load_policy(manifest)


if __name__ == "__main__":
    unittest.main()
