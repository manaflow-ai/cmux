#!/usr/bin/env python3
"""Behavior of the cmux-next INTERNAL iOS TestFlight builder's decision logic.

scripts/ci/ios_internal_builder.py decides when a feat-cmux-next head ships to
cmux INTERNAL, stamps the build number, and admits jobs on the dedicated
runner. Design: plans/cmux-next/ios-testflight-builder-DESIGN.md.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_internal_builder", ROOT / "scripts/ci/ios_internal_builder.py")
ib = importlib.util.module_from_spec(SPEC)
sys.modules["ios_internal_builder"] = ib
SPEC.loader.exec_module(ib)

UTC = dt.timezone.utc
NOW = dt.datetime(2026, 10, 20, 9, 30, 15, tzinfo=UTC)
A = "a" * 40
B = "b" * 40
C = "c" * 40

PACKAGE_SWIFT = """
let package = Package(
    dependencies: [
        .package(path: "../../Packages/Shared/CmuxGhosttyKit"),
        .package(path: "../../Packages/iOS/CmuxTabsKit"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [.binaryTarget(name: "CnxFFIFFI", path: "Frameworks/CnxFFI.xcframework")]
)
"""


def run(sha, conclusion="success", status="completed", minutes_ago=60, run_id=1):
    created = (NOW - dt.timedelta(minutes=minutes_ago)).isoformat().replace("+00:00", "Z")
    return {"id": run_id, "sha": sha, "status": status, "conclusion": conclusion, "created_at": created}


class BuildNumberTests(unittest.TestCase):
    def test_is_the_utc_timestamp(self):
        self.assertEqual(ib.next_build_number(NOW, None), "20261020093015")

    def test_steps_past_a_newer_or_equal_last_build(self):
        self.assertEqual(ib.next_build_number(NOW, "20261020093015"), "20261020093016")
        self.assertEqual(ib.next_build_number(NOW, "20991231235959"), "20991231235960")

    def test_ignores_an_older_last_build(self):
        self.assertEqual(ib.next_build_number(NOW, "20261019000000"), "20261020093015")

    def test_rejects_a_non_numeric_last_build(self):
        with self.assertRaises(ValueError):
            ib.next_build_number(NOW, "1.2.3")


class MarketingVersionTests(unittest.TestCase):
    def test_reads_project_yml(self):
        text = "settings:\n  base:\n    MARKETING_VERSION: 1.2.0\n    CURRENT_PROJECT_VERSION: 1\n"
        self.assertEqual(ib.marketing_version(text), "1.2.0")

    def test_missing_or_malformed_is_an_error(self):
        with self.assertRaises(ValueError):
            ib.marketing_version("settings: {}\n")
        with self.assertRaises(ValueError):
            ib.marketing_version("    MARKETING_VERSION: $(VERSION)\n")


class RelevantPathTests(unittest.TestCase):
    def test_package_paths_come_from_cnxkit(self):
        self.assertEqual(
            ib.package_paths(PACKAGE_SWIFT),
            ["Packages/Shared/CmuxGhosttyKit/", "Packages/iOS/CmuxTabsKit/", "vendor/stack-auth-swift-sdk-prerelease/"],
        )

    def test_ios_changes_are_relevant(self):
        prefixes = ib.relevant_prefixes(PACKAGE_SWIFT)
        for path in ("cnx-ios/App/RootView.swift", "Packages/iOS/CmuxTabsKit/Sources/X.swift",
                     "cmux-tui/crates/cmux-wg/src/lib.rs", ".github/workflows/ios-internal-nightly.yml",
                     "scripts/ci/ios_internal_builder.py", "Packages/Shared/CmuxGhosttyKit/Package.swift"):
            self.assertTrue(ib.touches_ios([path], prefixes), path)

    def test_mac_only_changes_are_not(self):
        prefixes = ib.relevant_prefixes(PACKAGE_SWIFT)
        self.assertFalse(ib.touches_ios(["Sources/App/AppDelegate.swift", "cmux-tui/src/cli.rs",
                                         "Packages/macOS/CmuxSettings/x.swift", "ios/cmux/Old.swift"], prefixes))


class PlanTests(unittest.TestCase):
    def plan(self, **kw):
        args = dict(head=C, runs=[run(A)], changed=["cnx-ios/App/A.swift"], has_cnx_ios=True, now=NOW,
                    prefixes=ib.relevant_prefixes(PACKAGE_SWIFT))
        args.update(kw)
        return ib.plan(**args)

    def test_builds_an_ios_change_since_the_last_upload(self):
        decision = self.plan()
        self.assertTrue(decision.build, decision.reason)
        self.assertEqual(decision.base, A)

    def test_first_build_when_nothing_was_uploaded(self):
        decision = self.plan(runs=[], changed=None)
        self.assertTrue(decision.build, decision.reason)
        self.assertIsNone(decision.base)

    def test_skips_until_cnx_ios_is_on_the_branch(self):
        decision = self.plan(has_cnx_ios=False)
        self.assertFalse(decision.build)
        self.assertIn("cnx-ios", decision.reason)

    def test_skips_the_head_already_uploaded(self):
        decision = self.plan(runs=[run(C)])
        self.assertFalse(decision.build)

    def test_skips_mac_only_changes_while_the_last_upload_is_fresh(self):
        decision = self.plan(changed=["Sources/App/AppDelegate.swift"], runs=[run(A, minutes_ago=60)])
        self.assertFalse(decision.build)

    def test_periodic_fallback_ships_any_change_after_twelve_hours(self):
        decision = self.plan(changed=["Sources/App/AppDelegate.swift"], runs=[run(A, minutes_ago=12 * 60 + 1)])
        self.assertTrue(decision.build, decision.reason)
        self.assertIn("fallback", decision.reason)

    def test_unknown_diff_fails_open(self):
        decision = self.plan(changed=None)
        self.assertTrue(decision.build, decision.reason)

    def test_does_not_queue_behind_the_same_head(self):
        decision = self.plan(runs=[run(C, status="queued", conclusion=None, minutes_ago=2, run_id=3), run(A, run_id=2)])
        self.assertFalse(decision.build)

    def test_a_newer_head_replaces_the_pending_one(self):
        decision = self.plan(runs=[run(B, status="in_progress", conclusion=None, minutes_ago=5, run_id=3), run(A, run_id=2)])
        self.assertTrue(decision.build, decision.reason)

    def test_does_not_retry_a_failed_head(self):
        decision = self.plan(runs=[run(C, conclusion="failure", minutes_ago=30, run_id=3), run(A, run_id=2)])
        self.assertFalse(decision.build)

    def test_retries_a_failed_head_after_the_fallback_interval(self):
        decision = self.plan(runs=[run(C, conclusion="failure", minutes_ago=12 * 60 + 1, run_id=3),
                                   run(A, minutes_ago=13 * 60, run_id=2)])
        self.assertTrue(decision.build, decision.reason)

    def test_cancelled_runs_do_not_count(self):
        decision = self.plan(runs=[run(C, conclusion="cancelled", minutes_ago=30, run_id=3), run(A, run_id=2)])
        self.assertTrue(decision.build, decision.reason)

    def test_base_is_the_newest_success(self):
        decision = self.plan(runs=[run(B, conclusion="failure", run_id=3), run(A, minutes_ago=120, run_id=2)])
        self.assertEqual(decision.base, A)


class AdmitTests(unittest.TestCase):
    def env(self, **kw):
        env = {
            "GITHUB_REPOSITORY": "manaflow-ai/cmux",
            "GITHUB_WORKFLOW_REF": "manaflow-ai/cmux/.github/workflows/ios-internal-nightly.yml@refs/heads/rc/cnx-ios-builder",
            "GITHUB_JOB": "archive",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REF": "refs/heads/rc/cnx-ios-builder",
        }
        env.update(kw)
        return env

    def test_admits_the_archive_job(self):
        ok, reason = ib.admit(self.env(), 100 * 1024 ** 3)
        self.assertTrue(ok, reason)

    def test_refuses_everything_else(self):
        for change in ({"GITHUB_REPOSITORY": "someone/fork"},
                       {"GITHUB_WORKFLOW_REF": "manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/nightly-next"},
                       {"GITHUB_JOB": "upload"},
                       {"GITHUB_EVENT_NAME": "pull_request"},
                       {"GITHUB_REF": "refs/heads/feat-cmux-next"}):
            ok, _ = ib.admit(self.env(**change), 100 * 1024 ** 3)
            self.assertFalse(ok, change)

    def test_refuses_on_low_disk(self):
        ok, reason = ib.admit(self.env(), 10 * 1024 ** 3)
        self.assertFalse(ok)
        self.assertIn("GiB", reason)


if __name__ == "__main__":
    unittest.main()
