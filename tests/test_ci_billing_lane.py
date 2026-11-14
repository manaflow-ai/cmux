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
    # Billing code outside the billing directories (review of #42863).
    "web/app/api/cron/team-seats/route.ts",
    "web/orpc/server/dashboard/billing.ts",
    "web/orpc/server/dashboard/team-billing.ts",
    "web/services/teams/seats.ts",
    "web/services/vms/billingGateway.ts",
    "web/services/vms/teamEntitlementOverride.ts",
    "web/services/admin/teamEntitlements.ts",
    "web/app/lib/billing.ts",
    "web/app/billing/success/page.tsx",
    "web/app/[locale]/dashboard/billing/page.tsx",
    "web/app/components/pricing-checkout.tsx",
    "web/app/components/pro-plan-card.tsx",
    "web/dashboard-app/queries/billing.ts",
    "web/dashboard-app/screens/teams/team-billing.tsx",
    "web/services/analytics/stripeBilling.ts",
    "web/services/analytics/checkoutAttribution.ts",
    "web/services/observability/billingAlerts.ts",
    "web/scripts/stripe/backfill-subscriptions-from-stripe.ts",
    "Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBilling/BillingModel.swift",
    "Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/Wire.swift",
    "ios/Config/cmux-dev.storekit",
    "ios/cmuxPackage/Sources/cmuxFeature/MobileBillingComposition.swift",
    "Packages/iOS/CmuxStoreBilling/Package.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/BillingDemo.swift",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileBilling/Purchase.swift",
    "cmux-next-ios/CmuxMobileKit/Tests/BillingStoreKitTests/PurchaseTests.swift",
    "cmux-next-ios/App/Billing.storekit",
)
NOT_BILLING = (
    "web/app/api/vm/route.ts",
    "web/services/vms/limits.ts",
    "web/db/client.ts",
    "web/tests/vm-route-auth.test.ts",
    "web/app/api/cron/vm-idle/route.ts",
    "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/ShellModel.swift",
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
    assert lines[start + 1] == "    branches: [feat-cmux-next]", "billing.yml must target feat-cmux-next"
    assert lines[start + 2] == "    paths:", "billing.yml pull_request must list paths after branches"
    paths = []
    for line in lines[start + 3:]:
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

    def test_billing_package_change_runs_ios_and_storekit(self) -> None:
        areas = lane.classify(["Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBilling/BillingModel.swift"])
        self.assertEqual(areas, {"web": False, "ios": True, "storekit": True})

    def test_app_billing_change_runs_storekit_only(self) -> None:
        for path in ("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/BillingDemo.swift",
                     "cmux-next-ios/App/Billing.storekit"):
            with self.subTest(path=path):
                self.assertEqual(lane.classify([path]), {"web": False, "ios": False, "storekit": True})

    def test_lane_change_runs_everything(self) -> None:
        for path in lane.LANE_PATTERNS:
            with self.subTest(path=path):
                self.assertEqual(set(lane.classify([path]).values()), {True})

    def route_outputs(self, event: str, paths: list[str] | None) -> dict[str, str]:
        import contextlib, io, os
        from unittest import mock
        with tempfile.NamedTemporaryFile("r", suffix=".out") as output, \
                mock.patch.dict(os.environ, {"EVENT_NAME": event, "GITHUB_OUTPUT": output.name}), \
                mock.patch.object(lane, "changed_paths", return_value=paths), \
                contextlib.redirect_stdout(io.StringIO()):
            lane.route()
            return dict(line.split("=", 1) for line in output.read().splitlines())

    def test_route_fails_open(self) -> None:
        # No diff, or a filter match these patterns disagree with, runs everything.
        for event, paths in (("pull_request", None), ("pull_request", ["web/unrelated.ts"]),
                             ("workflow_dispatch", ["web/unrelated.ts"])):
            with self.subTest(event=event, paths=paths):
                outputs = self.route_outputs(event, paths)
                self.assertEqual(outputs["web"], "true")
                self.assertEqual(outputs["ios"], "true")

    def test_route_narrows_a_billing_diff(self) -> None:
        outputs = self.route_outputs("pull_request", ["web/services/billing/stripe.ts"])
        self.assertEqual((outputs["web"], outputs["ios"]), ("true", "false"))

    def test_unsupported_glob_syntax_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            lane.matches("web/a.ts", ["web/[ab].ts"])

    def test_unrelated_change_runs_nothing(self) -> None:
        self.assertEqual(set(lane.classify(list(NOT_BILLING)).values()), {False})


class StoreKitSlot(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        (self.root / "cmux-next-ios/CmuxMobileKit/Tests/OtherTests").mkdir(parents=True)
        (self.root / "cmux-next-ios/CmuxMobileKit/Package.swift").write_text("", encoding="utf-8")
        (self.root / "cmux-next-ios/project.yml").write_text("targets:\n  CmuxMobileApp:\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.dir.cleanup()

    def test_real_tree_target_is_found_when_declared(self) -> None:
        # Holds before and after the rewrite lands BillingStoreKitTests: whatever
        # declares the target, the slot must see it rather than skip.
        app = ROOT / "cmux-next-ios"
        declared = any(path.is_dir() for path in app.rglob(lane.STOREKIT_TARGET)
                       if ".build" not in path.parts and "target" not in path.parts)
        project = app / "project.yml"
        declared = declared or (project.is_file() and lane.STOREKIT_TARGET in project.read_text(encoding="utf-8"))
        self.assertEqual(lane.storekit_target() != ("", ""), declared)

    def test_absent_target_skips(self) -> None:
        self.assertEqual(lane.storekit_target(self.root), ("", ""))

    def test_swiftpm_test_directory_runs_its_package(self) -> None:
        (self.root / "cmux-next-ios/CmuxMobileKit/Tests/BillingStoreKitTests").mkdir()
        self.assertEqual(lane.storekit_target(self.root), ("package", "cmux-next-ios/CmuxMobileKit"))

    def test_quoted_or_inline_project_target(self) -> None:
        for line in ('  "BillingStoreKitTests": {type: bundle.unit-test}', "  BillingStoreKitTests:  # StoreKit"):
            with self.subTest(line=line):
                (self.root / "cmux-next-ios/project.yml").write_text(f"targets:\n{line}\n", encoding="utf-8")
                self.assertEqual(lane.storekit_target(self.root), ("project", "cmux-next-ios"))

    def test_project_target_runs_the_app_project(self) -> None:
        (self.root / "cmux-next-ios/project.yml").write_text(
            "targets:\n  CmuxMobileApp:\n    type: application\n  BillingStoreKitTests:\n    type: bundle.unit-test\n",
            encoding="utf-8")
        self.assertEqual(lane.storekit_target(self.root), ("project", "cmux-next-ios"))


def jobs_text() -> dict[str, str]:
    """billing.yml's jobs by id, as raw text blocks."""
    text = WORKFLOW.read_text(encoding="utf-8")
    body = text[text.index("\njobs:\n") + len("\njobs:\n"):]
    blocks: dict[str, str] = {}
    current = None
    for line in body.splitlines():
        header = re.fullmatch(r"  ([a-z][a-z0-9-]*):", line)
        if header:
            current = header.group(1)
            blocks[current] = ""
        elif current:
            blocks[current] += line + "\n"
    return blocks


class Wiring(unittest.TestCase):
    """The two jobs, their routes and the script agree with each other."""

    def setUp(self) -> None:
        self.jobs = jobs_text()

    def test_two_jobs(self) -> None:
        # feat-cmux-next counts every job a pull request can start (ci/steps.toml [budget]).
        self.assertEqual(set(self.jobs), {"billing", "ios-billing"})

    def test_route_outputs_match_the_script(self) -> None:
        outputs = set(re.findall(r"^      ([a-z_]+): \$\{\{ steps\.route\.outputs\.\1 \}\}",
                                 self.jobs["billing"], re.MULTILINE))
        self.assertEqual(outputs, set(lane.classify([])) | {"storekit_kind", "storekit_path"})

    def test_web_steps_run_on_the_web_route(self) -> None:
        block = self.jobs["billing"]
        for step in ("Install dependencies", "Billing tests", "Apply migrations",
                     "Billing database tests", "Typecheck"):
            with self.subTest(step=step):
                body = block[block.index(f"- name: {step}"):]
                condition = body.splitlines()[1]
                self.assertIn("steps.route.outputs.web == 'true'", condition)
        self.assertIn("billing_lane.py web-tests >", block)
        self.assertIn("billing_lane.py web-tests --db >", block)

    def test_ios_job_runs_on_its_routes(self) -> None:
        block = self.jobs["ios-billing"]
        self.assertIn("needs.billing.outputs.ios == 'true' || needs.billing.outputs.storekit_kind != ''", block)
        self.assertIn("IOS: ${{ needs.billing.outputs.ios }}", block)
        self.assertIn("STOREKIT_KIND: ${{ needs.billing.outputs.storekit_kind }}", block)


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
