#!/usr/bin/env python3
"""Routing of .github/workflows/cmux-next-ios.yml on the committed tree."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import cmux_next_ios_route as route  # noqa: E402


def run(*changed: str) -> dict[str, object]:
    return route.route(ROOT, list(changed))


class CmuxNextIOSRouteTests(unittest.TestCase):
    def test_every_listed_package_exists(self) -> None:
        packages = route.mobile_packages(ROOT)
        self.assertIn("CmuxLink", packages)
        self.assertIn("CmuxMobileSSH", packages)
        self.assertNotIn("CmuxiOS", packages)  # iOS-only; built by test-ios.yml
        self.assertEqual(route.select_packages(ROOT, None), packages)

    def test_a_package_change_selects_it_and_its_dependents_only(self) -> None:
        selected = run("Packages/Shared/CmuxLink/Sources/CmuxLink/Link.swift")["packages"]
        self.assertIn("CmuxLink", selected)
        self.assertIn("CmuxLinkDirect", selected)  # depends on CmuxLink by path
        self.assertNotIn("CmuxMobileWire", selected)
        self.assertNotIn("CmuxFeedPushCore", selected)

    def test_a_shared_dependency_outside_the_list_selects_its_users(self) -> None:
        selected = run("Packages/Shared/CmuxTerminalStream/Sources/X.swift")["packages"]
        self.assertIn("CmuxMobileWire", selected)
        self.assertIn("CmuxTerminalRenderCore", selected)
        self.assertNotIn("CmuxLink", selected)

    def test_a_fixture_selects_the_packages_that_read_it(self) -> None:
        result = run("schemas/mobile-rpc/fixtures/rd.json")
        self.assertEqual(sorted(result["packages"]), ["CmuxLinkWebRTC", "CmuxMobileWire", "CmuxRemoteDesktop"])
        self.assertTrue(result["protocol"])
        self.assertTrue(result["api"])
        self.assertEqual(run("schemas/terminal-corpus/x.bin")["packages"], ["CmuxTerminalRenderCore"])

    def test_backend_runs_the_protocol_tests_only(self) -> None:
        result = run("backend/packages/protocol/src/mobile-wire.ts")
        self.assertEqual(result["packages"], [])
        self.assertTrue(result["protocol"])
        self.assertFalse(result["api"])  # backend.yml runs the API tests for backend/

    def test_app_and_unrelated_changes_select_no_package(self) -> None:
        result = run("ios/CmuxiOS/Sources/CmuxiOSShell/Shell.swift", "web/app/page.tsx", "docs/x.md")
        self.assertEqual(result, {"packages": [], "protocol": False, "api": False})

    def test_the_job_inputs_select_everything(self) -> None:
        for path in (".github/workflows/cmux-next-ios.yml", "scripts/cmux-next/mobile-scan-roots.txt",
                     "scripts/ci/hung_test_watchdog.py"):
            self.assertEqual(run(path)["packages"], route.mobile_packages(ROOT), path)


if __name__ == "__main__":
    unittest.main()
