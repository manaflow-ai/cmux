#!/usr/bin/env python3
"""The Billing lane runs on every billing change and runs every billing test.

.github/workflows/billing.yml filters pull requests by path, and
scripts/ci/billing_lane.py routes jobs and selects test files. A path the
workflow's filter misses never starts the lane at all, and a test the selector
misses never runs, so both are pinned here against real billing paths,
including the files of the open double-billing (#42777) and Apple renewal
recheck (#42784) pull requests.

Runs with plain python3 (no PyYAML) because billing.yml's first job runs it.
"""

from __future__ import annotations

import importlib.util
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/billing.yml"
SCRIPT = ROOT / "scripts/ci/billing_lane.py"

spec = importlib.util.spec_from_file_location("billing_lane", SCRIPT)
assert spec and spec.loader
lane = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = lane
spec.loader.exec_module(lane)

# Paths changed by #42777 and #42784, plus the lane's own files.
BILLING_PATHS = (
    "docs/billing/ios-in-app-purchases.md",
    "web/app/api/admin/subscriptions/double-billing/route.ts",
    "web/app/api/billing/checkout/route.ts",
    "web/app/api/billing/apple/transactions/route.ts",
    "web/app/api/cron/billing-double-subscriptions/route.ts",
    "web/app/api/cron/billing-reconcile/route.ts",
    "web/app/api/cron/apple-notifications/route.ts",
    "web/app/api/stripe/webhook/route.ts",
    "web/app/app-pricing/pricing-content.tsx",
    "web/dashboard-app/screens/billing/billing-screen.tsx",
    "web/orpc/server/dashboard/schemas/billing.ts",
    "web/db/migrations/20261113120000_apple_iap_recheck_backfill/migration.sql",
    "web/db/schema.ts",
    "web/services/billing/doubleBilling.ts",
    "web/services/billing/apple/recheck.ts",
    "web/services/vms/entitlements.ts",
    "web/services/vms/planUsage.ts",
    "web/tests/admin-double-billing-route.test.ts",
    "web/tests/billing-double-subscription-db-behavior.test.ts",
    "web/tests/apple-iap-renewal-recheck.test.ts",
    "web/tests/stripe-webhook-route.test.ts",
    "web/tests/dashboard-billing-screen.test.tsx",
    "web/tests/app-pricing-resume.test.tsx",
    "web/tests/plan-tier-entitlements.test.ts",
    "web/tests/helpers/apple-memory-store.ts",
    "web/tests/helpers/billing-team-fixtures.ts",
)
NOT_BILLING = (
    "web/app/api/vm/route.ts",
    "web/services/vms/limits.ts",
    "web/db/client.ts",
    "web/tests/vm-route-auth.test.ts",
    "web/app/api/cron/team-seats/route.ts",
    "Sources/AppDelegate.swift",
    "docs/billing.md",
)

# Test files that must be selected by name alone (no billing import needed).
BILLING_TEST_NAMES = (
    "billing-double-subscription.test.ts",
    "billing-double-subscription-db-behavior.test.ts",
    "admin-double-billing-route.test.ts",
    "admin-subscription-analytics-route.test.ts",
    "apple-iap-renewal-recheck.test.ts",
    "apple-iap-notification-history.test.ts",
    "apple-iap-retry-backoff.test.ts",
    "apple-iap-family-sharing.test.ts",
    "apple-iap-server-api-config.test.ts",
    "stripe-webhook-route.test.ts",
    "dashboard-billing-screen.test.tsx",
    "app-pricing-page.test.tsx",
    "team-entitlement-override.test.ts",
    "vm-billing-gateway.test.ts",
)


def workflow_pull_request_paths() -> list[str]:
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    start = lines.index("  pull_request:")
    assert lines[start + 1] == "    paths:", "billing.yml pull_request must start with a paths list"
    paths = []
    for line in lines[start + 2:]:
        match = re.fullmatch(r'      - "([^"]+)"', line)
        if not match:
            break
        paths.append(match.group(1))
    return paths


class WorkflowFilter(unittest.TestCase):
    def test_workflow_filter_equals_lane_patterns(self) -> None:
        self.assertEqual(workflow_pull_request_paths(), lane.workflow_paths())

    def test_billing_paths_start_the_lane(self) -> None:
        missed = [path for path in BILLING_PATHS if not lane.matches(path, lane.workflow_paths())]
        self.assertEqual(missed, [])

    def test_unrelated_paths_do_not(self) -> None:
        hit = [path for path in NOT_BILLING if lane.matches(path, lane.workflow_paths())]
        self.assertEqual(hit, [])

    def test_glob_semantics_follow_github(self) -> None:
        self.assertTrue(lane.matches("web/tests/billing-x.test.ts", ["web/tests/billing-*"]))
        self.assertFalse(lane.matches("web/tests/sub/billing-x.test.ts", ["web/tests/billing-*"]))
        self.assertTrue(lane.matches("a/b/c/d.swift", ["a/**"]))
        self.assertTrue(lane.matches("x/y/Billing/z.swift", ["**/Billing/**"]))
        self.assertTrue(lane.matches("Billing/z.swift", ["**/Billing/**"]))


class Routing(unittest.TestCase):
    def test_web_change_runs_web_only(self) -> None:
        self.assertEqual(lane.classify(["web/services/billing/stripe.ts"]),
                         {"web": True, "ios": False, "storekit": False})

    def test_ios_change_runs_ios_only(self) -> None:
        areas = lane.classify(["Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBilling/BillingModel.swift"])
        self.assertEqual(areas, {"web": False, "ios": True, "storekit": True})

    def test_lane_change_runs_everything(self) -> None:
        for path in lane.LANE_PATTERNS:
            with self.subTest(path=path):
                self.assertEqual(set(lane.classify([path]).values()), {True})

    def test_unrelated_change_runs_nothing(self) -> None:
        self.assertEqual(set(lane.classify(list(NOT_BILLING)).values()), {False})


class Selection(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.web = Path(self.dir.name)
        (self.web / "tests").mkdir()
        (self.web / "node_modules/pkg").mkdir(parents=True)

    def tearDown(self) -> None:
        self.dir.cleanup()

    def write(self, relative: str, text: str = "") -> None:
        path = self.web / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_names_imports_and_db_gate(self) -> None:
        for name in BILLING_TEST_NAMES:
            self.write(f"tests/{name}")
        self.write("tests/vm-pro-gate.test.ts", 'import { x } from "../services/billing/pro";\n')
        self.write("tests/teams-routes.test.ts", 'mock.module("@/services/vms/entitlements", () => ({}));\n')
        self.write("tests/cron.test.ts", 'await import("../app/api/cron/apple-notifications/route");\n')
        self.write("tests/plan-db.test.ts",
                   'import "../services/vms/planUsage";\nconst run = process.env.CMUX_DB_TEST === "1";\n')
        self.write("services/billing/apple/state.test.ts")
        # Not billing: unrelated, a helper (not a test file), node_modules.
        self.write("tests/vm-slug.test.ts", 'import "../services/vms/slug";\n')
        self.write("tests/billing-helpers.ts", "")
        self.write("node_modules/pkg/billing-x.test.ts", "")

        selected = lane.web_tests(web=self.web)
        expected = {f"./tests/{name}" for name in BILLING_TEST_NAMES} | {
            "./tests/vm-pro-gate.test.ts",
            "./tests/teams-routes.test.ts",
            "./tests/cron.test.ts",
            "./tests/plan-db.test.ts",
            "./services/billing/apple/state.test.ts",
        }
        self.assertEqual(set(selected), expected)
        self.assertEqual(selected, sorted(selected))
        self.assertEqual(lane.web_tests(db_only=True, web=self.web), ["./tests/plan-db.test.ts"])

    def test_real_tree_selects_known_billing_tests(self) -> None:
        selected = set(lane.web_tests())
        for name in ("apple-iap-db-behavior.test.ts", "billing-checkout-route.test.ts",
                     "stripe-webhook-route.test.ts", "plan-tier-entitlements.test.ts"):
            self.assertIn(f"./tests/{name}", selected)
        db = lane.web_tests(db_only=True)
        self.assertIn("./tests/apple-iap-db-behavior.test.ts", db)
        self.assertTrue(set(db) <= selected)


if __name__ == "__main__":
    unittest.main(verbosity=1)
