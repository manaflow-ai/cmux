"""cmux-next-ios/scripts/app_review_gate.py: each rejection class is caught on a fixture of the
NEXT iOS app (cmux-next-ios), and the real history names detectors that exist."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("app_review_gate", ROOT / "cmux-next-ios/scripts/app_review_gate.py")
gate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
# Registered before exec: dataclasses (and anything else that looks the module
# up by name while it runs) needs it in sys.modules on Python 3.12.
sys.modules[SPEC.name] = gate
SPEC.loader.exec_module(gate)


def write(root: Path, rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class AppReviewGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        write(self.root, "cmux-next-ios/AppStoreReview/metadata/app-info/en-US.json",
              json.dumps({"name": "cmux", "subtitle": "x", "privacyPolicyUrl": "https://cmux.com/privacy-policy"}))
        write(self.root, "cmux-next-ios/AppStoreReview/metadata/version/1.0.0/en-US.json",
              json.dumps({"description": "cmux for iPhone", "supportUrl": "https://cmux.com/support"}))
        for family in ("iphone", "ipad"):
            write(self.root, f"cmux-next-ios/AppStoreReview/screenshots/en-US/{family}/1.png", "png")
        write(self.root, "cmux-next-ios/project.yml",
              "configs:\n  TestFlight: release\n  AppStore: release\nsettings:\n  MARKETING_VERSION: 1.2.0\n  configs:\n"
              "    AppStore:\n      CMUX_MOBILE_APP_BUNDLE_ID: com.cmux.app\n      MARKETING_VERSION: 1.0.0\n"
              "targets:\n  CmuxMobileApp:\n    type: application\n"
              "    settings:\n      base:\n        CMUX_MOBILE_APPLE_SIGN_IN: \"NO\"\n      configs:\n"
              "        TestFlight:\n          CMUX_MOBILE_ENTITLEMENTS_NO: App/CmuxMobileApp-TestFlight.entitlements\n"
              "          CMUX_MOBILE_APPLE_SIGN_IN: \"YES\"\n"
              "        AppStore:\n          CMUX_MOBILE_ENTITLEMENTS_NO: App/CmuxMobileApp-TestFlight.entitlements\n"
              "          CMUX_MOBILE_APPLE_SIGN_IN: \"YES\"\n"
              "    info:\n      path: App/Info.plist\n      properties:\n        ITSAppUsesNonExemptEncryption: false\n")
        write(self.root, "cmux-next-ios/App/CmuxMobileApp-TestFlight.entitlements",
              plistlib.dumps({"aps-environment": "production", "com.apple.developer.applesignin": ["Default"]}).decode())
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileOnboarding/Welcome.swift",
              'let a = "Continue with Apple"; let g = "Continue with Google"; let h = "Continue with GitHub"\n')
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileSettings/SettingsPages.swift",
              'Text("Delete Account").accessibilityIdentifier("settings.deleteAccount")\n')
        write(self.root, "cmux-next-ios/UITests/AppReviewGateUITests.swift", "func testX() {}\n")
        write(self.root, "cmux-next-ios/AppStoreReview/rejection-history.json",
              json.dumps({"rejections": [{"date": "d", "guideline": "1.5", "summary": "s", "detectors": ["uitest:testX"]}]}))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_lint(self, lane: str = "appstore") -> list[str]:
        lint = gate.Lint(self.root, lane)
        lint.check_metadata()
        if lint.check_next_app_present():
            lint.check_sources()
        lint.check_history()
        return lint

    def rules(self, lint) -> set[str]:
        return {f.rule for f in lint.findings if f.severity == "blocker"}

    def test_clean_fixture_has_no_blockers(self) -> None:
        self.assertEqual(self.rules(self.run_lint()), set())

    def test_missing_support_url_blocks(self) -> None:
        write(self.root, "cmux-next-ios/AppStoreReview/metadata/version/1.0.0/en-US.json",
              json.dumps({"description": "cmux for iPhone"}))
        self.assertIn("metadata.support-url", self.rules(self.run_lint()))

    def screenshot_findings(self, families: str | None) -> set[str]:
        """The screenshot blockers with only an iphone folder, for an app
        target built for `families` (None: project.yml never sets it)."""
        shutil.rmtree(self.root / "cmux-next-ios/AppStoreReview/screenshots/en-US/ipad")
        project = self.root / "cmux-next-ios/project.yml"
        if families is not None:
            project.write_text(project.read_text().replace(
                "        CMUX_MOBILE_APPLE_SIGN_IN: \"NO\"\n",
                f"        CMUX_MOBILE_APPLE_SIGN_IN: \"NO\"\n        TARGETED_DEVICE_FAMILY: \"{families}\"\n"))
        return {f.message for f in self.run_lint().findings if f.rule == "metadata.screenshots"}

    def test_an_iphone_only_app_needs_no_ipad_screenshots(self) -> None:
        # App Store Connect: iPad screenshots are "Required if app runs on iPad".
        self.assertEqual(self.screenshot_findings("1"), set())

    def test_an_app_that_runs_on_ipad_needs_ipad_screenshots(self) -> None:
        self.assertEqual(self.screenshot_findings("1,2"), {"no ipad screenshots"})

    def test_an_app_with_no_device_family_runs_on_ipad_too(self) -> None:
        # xcodegen's and Xcode's iOS default is "1,2".
        self.assertEqual(self.screenshot_findings(None), {"no ipad screenshots"})

    def test_an_iphone_only_app_still_needs_iphone_screenshots(self) -> None:
        shutil.rmtree(self.root / "cmux-next-ios/AppStoreReview/screenshots/en-US/iphone")
        self.assertEqual(self.screenshot_findings("1"), {"no iphone screenshots"})

    def test_the_real_app_is_iphone_only(self) -> None:
        # Every shipping build in the real project.yml is TARGETED_DEVICE_FAMILY "1";
        # only Debug also runs on an iPad mini simulator.
        self.assertEqual(gate.app_device_families(ROOT), frozenset({"1"}))

    def test_a_debug_only_ipad_family_ships_iphone_only(self) -> None:
        project = self.root / "cmux-next-ios/project.yml"
        project.write_text(project.read_text().replace(
            "        CMUX_MOBILE_APPLE_SIGN_IN: \"NO\"\n",
            "        CMUX_MOBILE_APPLE_SIGN_IN: \"NO\"\n        TARGETED_DEVICE_FAMILY: \"1\"\n"
            "      configs:\n        Debug:\n          TARGETED_DEVICE_FAMILY: \"1,2\"\n"))
        self.assertEqual(gate.app_device_families(self.root), frozenset({"1"}))

    def test_families_prints_the_shipped_families(self) -> None:
        # ios-review-gate.yml skips a pull request's iPad leg when this prints exactly "1".
        out = subprocess.run([sys.executable, "-I", str(ROOT / "cmux-next-ios/scripts/app_review_gate.py"), "families",
                              "--source-root", str(ROOT)], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.strip(), "1")

    def test_missing_account_deletion_blocks(self) -> None:
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileSettings/SettingsPages.swift", 'Text("Account")\n')
        self.assertIn("account.deletion", self.rules(self.run_lint()))

    def test_external_purchase_link_blocks(self) -> None:
        write(self.root, "cmux-next-ios/App/Buy.swift", 'let u = URL(string: "https://checkout.stripe.com/x")\n')
        self.assertIn("iap.external-purchase", self.rules(self.run_lint()))

    # Classes mapped from the public rejection lists (hq docs/handbook/app-review-rejections.md).

    def write_chief(self, consent: str, report: str = "ChiefReport.open(conversationID: id)") -> None:
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileChief/Chief.swift",
              f"final class ChiefSession {{}}\n{consent}\n{report}\n")

    def test_ai_chat_without_consent_blocks(self) -> None:
        self.write_chief(consent="")
        self.assertIn("ai.consent", self.rules(self.run_lint()))

    def test_ai_consent_must_name_the_providers(self) -> None:
        self.write_chief(consent='let k = "cmuxMobile.chief.aiSharingConsent"; let p = String(localized: "p", defaultValue: "our AI")')
        self.assertIn("ai.consent", self.rules(self.run_lint()))

    NAMED = ('let k = "cmuxMobile.chief.aiSharingConsent"; '
             'let p = String(localized: "p", defaultValue: "Anthropic (Claude) and OpenAI")')
    GATED = "conversation.sendGate = { retry in guard !ChiefAIConsent.isGranted else { return true }; return false }"

    def test_ai_consent_naming_the_providers_passes(self) -> None:
        self.write_chief(consent=f"{self.NAMED}\n{self.GATED}")
        self.assertEqual(self.rules(self.run_lint()), set())

    def test_ai_consent_only_on_the_send_button_blocks(self) -> None:
        # Asked in the Send button's handler alone: Return and the effect picker skip it.
        self.write_chief(consent=f"{self.NAMED}\nfunc sendTapped() {{ if !ChiefAIConsent.isGranted {{ return }} }}")
        self.assertIn("ai.consent", self.rules(self.run_lint()))

    def test_ai_chat_without_a_report_control_blocks(self) -> None:
        self.write_chief(consent='let k = "aiSharingConsent"; let p = String(localized: "p", defaultValue: "Anthropic and OpenAI")',
                         report="")
        self.assertIn("ugc.report", self.rules(self.run_lint()))

    def test_unfinished_copy_blocks(self) -> None:
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileSettings/Labs.swift",
              'Text("Adds a toggle. Still in progress.")\n// Text("coming soon") in a comment is fine\n')
        lint = self.run_lint()
        self.assertEqual([f.where for f in lint.findings if f.rule == "copy.unfinished"],
                         ["cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileSettings/Labs.swift:1"])

    def test_an_ipv4_only_lookup_and_an_allow_pre_prompt_warn(self) -> None:
        write(self.root, "cmux-next-ios/App/Net.swift",
              'let h = gethostbyname(name)\nlet u = "http://10.0.0.1:8080/x"\nButton("Allow Camera") {}\n')
        found = {(f.rule, f.severity) for f in self.run_lint().findings}
        self.assertIn(("net.ipv4-only", "warning"), found)
        self.assertIn(("privacy.pre-prompt", "warning"), found)

    def test_a_decorated_name_or_a_competitor_keyword_blocks(self) -> None:
        write(self.root, "cmux-next-ios/AppStoreReview/metadata/app-info/en-US.json",
              json.dumps({"name": "cmux: Best Agent App", "subtitle": "x", "privacyPolicyUrl": "https://cmux.com/privacy-policy"}))
        write(self.root, "cmux-next-ios/AppStoreReview/metadata/version/1.0.0/en-US.json",
              json.dumps({"description": "cmux", "keywords": "agent,ChatGPT,terminal", "supportUrl": "https://cmux.com/support"}))
        rules = self.rules(self.run_lint())
        self.assertIn("metadata.decoration", rules)
        self.assertIn("metadata.competitor-terms", rules)

    def test_the_real_app_asks_before_sharing_with_ai_and_can_report(self) -> None:
        lint = gate.Lint(ROOT, "appstore")
        lint.check_sources()
        self.assertEqual({f.rule for f in lint.findings} & {"ai.consent", "ugc.report", "copy.unfinished"}, set())

    def test_a_source_without_the_next_app_is_never_a_pass(self) -> None:
        # main ships the classic ios/ app today; the gate judges NEXT only.
        (self.root / "cmux-next-ios/project.yml").unlink()
        self.assertIn("source.not-next", self.rules(self.run_lint()))

    def test_the_app_store_lane_needs_the_app_store_configuration(self) -> None:
        project = self.root / "cmux-next-ios/project.yml"
        lint = gate.Lint(self.root, "appstore")
        lint.check_appstore_config()
        self.assertEqual(self.rules(lint), set())
        project.write_text(project.read_text().replace("com.cmux.app", "dev.cmux.app.internal"))
        lint = gate.Lint(self.root, "appstore")
        lint.check_appstore_config()
        self.assertIn("appstore.bundle-id", self.rules(lint))
        project.write_text(project.read_text().replace("  AppStore: release\n", ""))
        lint = gate.Lint(self.root, "appstore")
        lint.check_appstore_config()
        self.assertIn("appstore.config-missing", self.rules(lint))

    def test_the_internal_submission_lane_needs_testflight_and_cmux_internals_bundle(self) -> None:
        project = self.root / "cmux-next-ios/project.yml"
        project.write_text(project.read_text().replace(
            "  configs:\n    AppStore:", "  configs:\n    TestFlight:\n      CMUX_MOBILE_APP_BUNDLE_ID: dev.cmux.app.internal\n    AppStore:"))
        lint = gate.Lint(self.root, "internal-submission")
        lint.check_appstore_config()
        self.assertEqual(self.rules(lint), set())
        project.write_text(project.read_text().replace(
            "CMUX_MOBILE_APP_BUNDLE_ID: dev.cmux.app.internal", "CMUX_MOBILE_APP_BUNDLE_ID: dev.cmux.app.other"))
        lint = gate.Lint(self.root, "internal-submission")
        lint.check_appstore_config()
        self.assertIn("appstore.bundle-id", self.rules(lint))
        project.write_text(project.read_text().replace("  TestFlight: release\n", ""))
        lint = gate.Lint(self.root, "internal-submission")
        lint.check_appstore_config()
        self.assertIn("appstore.config-missing", self.rules(lint))

    def test_only_the_submission_lanes_run_the_configuration_check_in_lint(self) -> None:
        checked = {}
        for lane in gate.LANES:
            out = self.root / f"lint-{lane}.json"
            gate.main(["lint", "--source-root", str(self.root), "--lane", lane, "--json", str(out)])
            checked[lane] = "appstore-config" in json.loads(out.read_text())["checked"]
        self.assertEqual(checked, {"appstore": True, "internal": False, "internal-submission": True})

    def test_the_internal_submission_lane_holds_entitlements_to_the_app_store_rules(self) -> None:
        ents = {"get-task-allow": True, "aps-environment": "development",
                "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]}
        submission = gate.Lint(self.root, "internal-submission")
        submission.check_entitlements(ents, "x")
        internal = gate.Lint(self.root, "internal")
        internal.check_entitlements(ents, "x")
        self.assertEqual(self.rules(submission), {"entitlement.debug", "entitlement.aps", "entitlement.vpn"})
        self.assertEqual(self.rules(internal), set(), "the ordinary internal lane is unchanged")

    def test_the_internal_submission_binary_must_be_cmux_internal_without_vpn(self) -> None:
        app = self.root / "Payload/CmuxMobileApp.app"
        app.mkdir(parents=True)
        (app / "PrivacyInfo.xcprivacy").write_text("x")
        (app / "CmuxMobileApp").write_bytes(b"\x00NEVPNManager\x00")
        for bundle_id, lane, want in (("dev.cmux.app.internal", "internal-submission", {"api.vpn"}),
                                      ("com.cmux.app", "internal-submission", {"api.vpn", "binary.bundle-id"}),
                                      ("dev.cmux.app.internal", "internal", set())):
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "CmuxMobileApp", "CFBundleIdentifier": bundle_id,
                "ITSAppUsesNonExemptEncryption": False, "CmuxMobileAppleSignIn": "YES"}))
            lint = gate.Lint(self.root, lane)
            lint.check_app_bundle(app)
            self.assertEqual(self.rules(lint) & {"api.vpn", "binary.bundle-id"}, want, (bundle_id, lane))

    def test_an_internal_submission_is_never_judged_without_asc_validate(self) -> None:
        out = self.root / "report.md"
        for lane, want in (("internal-submission", True), ("internal", False), ("appstore", False)):
            lint_json = self.root / f"lint-{lane}.json"
            lint_json.write_text(json.dumps({"lane": lane, "checked": [], "findings": []}))
            gate.main(["report", "--lint", str(lint_json), "--asc-skipped", "--out", str(out)])
            self.assertEqual("asc validate did not run" in out.read_text(), want, lane)

    def test_asc_validates_the_app_store_configurations_version(self) -> None:
        self.assertEqual(gate.marketing_version(self.root, "appstore"), "1.0.0")
        self.assertEqual(gate.marketing_version(self.root, "internal"), "1.2.0")
        # cmux INTERNAL as a submission: the TestFlight configuration sets no version of its own.
        self.assertEqual(gate.marketing_version(self.root, "internal-submission"), "1.2.0")

    def test_missing_store_metadata_is_a_clear_blocker(self) -> None:
        import shutil
        shutil.rmtree(self.root / "cmux-next-ios/AppStoreReview/metadata")
        lint = self.run_lint()
        self.assertIn("metadata.missing", self.rules(lint))
        self.assertTrue(any("cmux-next-ios/AppStoreReview/metadata" in f.message for f in lint.findings))

    def test_a_raw_error_dump_in_user_text_warns_but_a_log_line_does_not(self) -> None:
        rel = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/Failing.swift"
        write(self.root, rel,
              'log.error("failed: \\(String(describing: error), privacy: .public)")\n'
              'let shown = UserFacingError.message(error)\n'
              '// was: (error as? LocalizedError)?.errorDescription ?? String(describing: error)\n')
        lint = self.run_lint()
        self.assertEqual([f for f in lint.findings if f.rule == "ux.raw-error"], [])
        write(self.root, rel, 'failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)\n')
        write(self.root, "cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/FailingTests.swift",
              'let text = x ?? String(describing: error)\n')
        lint = self.run_lint()
        raw = [f for f in lint.findings if f.rule == "ux.raw-error"]
        self.assertEqual([(f.severity, f.where) for f in raw], [("warning", f"{rel}:1")])
        self.assertNotIn("ux.raw-error", self.rules(lint))

    def test_google_and_github_without_apple_block(self) -> None:
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileOnboarding/Welcome.swift",
              'let g = "Continue with Google"; let h = "Continue with GitHub"\n')
        self.assertIn("signin.apple", self.rules(self.run_lint()))

    def test_apple_sign_in_off_in_every_shipping_configuration_blocks(self) -> None:
        # Debug hides the Apple button; a shipping configuration must turn it on.
        project = self.root / "cmux-next-ios/project.yml"
        project.write_text(project.read_text().replace('"YES"', '"NO"'))
        self.assertIn("signin.apple-shipping", self.rules(self.run_lint()))

    def test_apple_sign_in_is_judged_in_this_lanes_configuration_only(self) -> None:
        # TestFlight turning it on proves nothing about the AppStore build.
        project = self.root / "cmux-next-ios/project.yml"
        text = project.read_text()
        head, tail = text.split("        AppStore:\n", 1)
        project.write_text(head + "        AppStore:\n" + tail.replace('"YES"', '"NO"', 1))
        self.assertIn("signin.apple-shipping", self.rules(self.run_lint("appstore")))
        self.assertNotIn("signin.apple-shipping", self.rules(self.run_lint("internal")))

    def test_a_missing_app_store_entitlements_file_blocks(self) -> None:
        (self.root / "cmux-next-ios/App/CmuxMobileApp-TestFlight.entitlements").unlink()
        self.assertIn("signin.apple-entitlement", self.rules(self.run_lint()))

    def test_a_configuration_with_no_entitlements_blocks(self) -> None:
        project = self.root / "cmux-next-ios/project.yml"
        text = project.read_text()
        head, tail = text.split("        AppStore:\n", 1)
        tail = tail.replace("          CMUX_MOBILE_ENTITLEMENTS_NO: App/CmuxMobileApp-TestFlight.entitlements\n", "", 1)
        project.write_text(head + "        AppStore:\n" + tail)
        self.assertIn("signin.apple-entitlement", self.rules(self.run_lint()))

    def bundle(self, **info) -> Path:
        app = self.root / "Payload/CmuxMobileApp.app"
        app.mkdir(parents=True, exist_ok=True)
        body = {"CFBundleExecutable": "CmuxMobileApp", "ITSAppUsesNonExemptEncryption": False,
                "CmuxMobileAppleSignIn": "YES", "CFBundleIdentifier": "com.cmux.app",
                "CmuxMobileSourceCommit": "a" * 40}
        body.update(info)
        (app / "Info.plist").write_bytes(plistlib.dumps(body))
        (app / "PrivacyInfo.xcprivacy").write_text("x")
        (app / "CmuxMobileApp").write_bytes(b"\x00")
        return app

    def test_the_binary_must_be_this_lanes_app_from_the_judged_commit(self) -> None:
        lint = gate.Lint(self.root, "appstore")
        lint.check_app_bundle(self.bundle(), "a" * 40)
        self.assertFalse({"binary.bundle-id", "binary.source-commit"} & self.rules(lint))
        lint = gate.Lint(self.root, "appstore")
        lint.check_app_bundle(self.bundle(CFBundleIdentifier="dev.cmux.app.internal"), "a" * 40)
        self.assertIn("binary.bundle-id", self.rules(lint))
        lint = gate.Lint(self.root, "appstore")
        lint.check_app_bundle(self.bundle(CmuxMobileSourceCommit="b" * 40), "a" * 40)
        self.assertIn("binary.source-commit", self.rules(lint))
        lint = gate.Lint(self.root, "appstore")
        lint.check_app_bundle(self.bundle(CmuxMobileSourceCommit=""), "a" * 40)
        self.assertIn("binary.source-commit", self.rules(lint))
        lint = gate.Lint(self.root, "internal")
        lint.check_app_bundle(self.bundle(), "a" * 40)
        self.assertIn("binary.bundle-id", self.rules(lint))

    def test_app_store_entitlements_without_sign_in_with_apple_block(self) -> None:
        write(self.root, "cmux-next-ios/App/CmuxMobileApp-TestFlight.entitlements",
              plistlib.dumps({"aps-environment": "production"}).decode())
        self.assertIn("signin.apple-entitlement", self.rules(self.run_lint()))

    def write_billing(self, notes: str | None = None, plans: str | None = None) -> None:
        """A selling app: StoreKit, the plans screen and review notes as the real tree has them."""
        write(self.root, "Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBilling/LiveStoreKitClient.swift",
              "import StoreKit\nfunc restore() async throws { try await AppStore.sync() }\n")
        write(self.root, "Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBillingUI/MobilePlansView.swift", plans if plans is not None else (
            'import StoreKit\nButton("Restore Purchases") { restorePurchases() }\n'
            'let v = x.manageSubscriptionsSheet(isPresented: $m)\n'
            'let terms = URL(string: "https://cmux.com/terms-of-service")!\n'
            'let privacy = URL(string: "https://cmux.com/privacy-policy")!\n'
            'let d = "Subscriptions renew automatically at the end of each month."\n'))
        write(self.root, "cmux-next-ios/AppStoreReview/review-notes-asc.txt", notes if notes is not None else (
            '## comment\nSettings > "Plan" opens "Plans". "Subscribe" buys in the Sandbox.\n'
            '"Restore Purchases" is there; "Manage Subscription" opens Apple\'s settings.\n'))
        write(self.root, "cmux-next-ios/AppStoreReview/metadata/version/1.0.0/en-US.json",
              json.dumps({"description": "cmux for iPhone. Terms of Use: https://cmux.com/terms-of-service",
                          "supportUrl": "https://cmux.com/support"}))

    def iap_rules(self) -> set[str]:
        return {f.rule for f in self.run_lint().findings if f.rule.startswith(("iap.", "metadata.subscription"))}

    def test_an_app_without_storekit_has_no_subscription_rules(self) -> None:
        self.assertEqual(self.iap_rules(), set())

    def test_a_selling_app_with_restore_terms_and_notes_passes(self) -> None:
        self.write_billing()
        self.assertEqual(self.iap_rules(), set())
        self.assertIn("subscriptions", self.run_lint().checked)

    def test_storekit_without_restore_or_renewal_terms_blocks(self) -> None:
        self.write_billing(plans="import StoreKit\nText(\"Plans\")\n")
        write(self.root, "Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBilling/LiveStoreKitClient.swift", "import StoreKit\n")
        rules = self.iap_rules()
        self.assertTrue({"iap.restore", "iap.disclosure"} <= rules, rules)
        self.assertIn("iap.manage", {f.rule for f in self.run_lint().findings if f.severity == "warning"})

    def test_review_notes_that_say_the_app_sells_nothing_block(self) -> None:
        self.write_billing(notes="Payments: the app sells no digital goods and has no purchase links.\n")
        self.assertIn("iap.review-notes", self.rules(self.run_lint()))

    def test_review_notes_must_name_the_plan_row_and_restore(self) -> None:
        self.write_billing(notes='Settings > "Plan" opens the plans. Buy in the Sandbox.\n')
        messages = [f.message for f in self.run_lint().findings if f.rule == "iap.review-notes"]
        self.assertEqual(len(messages), 1)
        self.assertIn('"Restore Purchases"', messages[0])

    def test_a_listing_without_a_terms_link_blocks_a_selling_app(self) -> None:
        self.write_billing()
        write(self.root, "cmux-next-ios/AppStoreReview/metadata/version/1.0.0/en-US.json",
              json.dumps({"description": "cmux for iPhone", "supportUrl": "https://cmux.com/support"}))
        self.assertIn("metadata.subscription-terms", self.rules(self.run_lint()))

    INTERNAL_NOTES = "cmux-next-ios/AppStoreReview/review-notes-asc-internal.txt"
    TRUTHFUL_INTERNAL_NOTES = ('## comment: "Subscribe" in a comment line is not sent\n'
                               'Settings > "Plan" shows the account\'s current plan.\n'
                               "This version offers no purchase, no subscription and no external purchase link.\n")

    def write_no_sale(self, internal_notes: str, bundles: str = '"dev.cmux.app.internal"') -> None:
        """A selling tree (write_billing) whose app lists cmux INTERNAL in
        appsWithoutSubscriptions (cmux#50453), with INTERNAL's own notes."""
        self.write_billing()
        write(self.root, "Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBilling/BillingPurchaseAvailability.swift",
              f"public struct BillingPurchaseAvailability {{\n"
              f"    public static let appsWithoutSubscriptions: Set<String> = [{bundles}]\n}}\n")
        write(self.root, self.INTERNAL_NOTES, internal_notes)

    def iap_findings(self, lane: str) -> dict[str, list[str]]:
        found: dict[str, list[str]] = {}
        for f in self.run_lint(lane).findings:
            if f.rule.startswith(("iap.", "metadata.subscription")):
                found.setdefault(f.rule, []).append(f"{f.severity}: {f.message}")
        return found

    def test_internal_notes_that_promise_a_purchase_block_a_build_that_sells_nothing(self) -> None:
        self.write_no_sale('Settings > "Plan" opens "Plans". "Subscribe" buys in the Sandbox.\n'
                           '"Restore Purchases" is there; "Manage Subscription" opens Apple\'s settings.\n')
        found = self.iap_findings("internal-submission")
        self.assertEqual(set(found), {"iap.review-notes"}, found)
        message = found["iap.review-notes"][0]
        self.assertTrue(message.startswith("blocker: "), message)
        for word in (self.INTERNAL_NOTES, '"Subscribe"', '"Restore Purchases"', '"Manage Subscription"', "Sandbox",
                     "dev.cmux.app.internal"):
            self.assertIn(word, message)

    def test_internal_notes_must_still_name_the_plan_row(self) -> None:
        self.write_no_sale("This version offers no purchase.\n")
        self.assertIn('never names "Plan"', self.iap_findings("internal-submission")["iap.review-notes"][0])

    def test_truthful_internal_notes_pass_and_the_selling_rules_do_not_apply(self) -> None:
        self.write_no_sale(self.TRUTHFUL_INTERNAL_NOTES)
        # No restore, renewal terms, manage sheet or listing Terms link: a build that sells nothing owes none.
        write(self.root, "Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBillingUI/MobilePlansView.swift",
              'import StoreKit\nText("Plans")\n')
        write(self.root, "Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBilling/LiveStoreKitClient.swift",
              "import StoreKit\n")
        write(self.root, "cmux-next-ios/AppStoreReview/metadata/version/1.0.0/en-US.json",
              json.dumps({"description": "cmux for iPhone", "supportUrl": "https://cmux.com/support"}))
        self.assertEqual(self.iap_findings("internal-submission"), {})
        self.assertIn("subscriptions", self.run_lint("internal-submission").checked)

    def test_the_internal_notes_in_the_repository_pass_the_inverted_rule(self) -> None:
        self.write_no_sale((ROOT / self.INTERNAL_NOTES).read_text())
        self.assertEqual(self.iap_findings("internal-submission"), {})

    def test_internal_notes_are_held_to_the_selling_rules_while_the_app_sells(self) -> None:
        # Before the app lists dev.cmux.app.internal (cmux#50453), or once INTERNAL gets
        # subscriptions and leaves the list, its build shows the purchase controls.
        for bundles in ("", '"some.other.app"'):
            with self.subTest(bundles=bundles):
                self.write_no_sale(self.TRUTHFUL_INTERNAL_NOTES, bundles=bundles)
                found = self.iap_findings("internal-submission")
                self.assertEqual(set(found), {"iap.review-notes"}, found)
                self.assertIn(self.INTERNAL_NOTES, found["iap.review-notes"][0])
                self.assertIn('never names "Restore Purchases"', found["iap.review-notes"][0])

    def test_the_appstore_lane_is_unchanged_by_the_internal_no_sale_list(self) -> None:
        # com.cmux.app sells: its lane reads review-notes-asc.txt with every selling rule,
        # whatever INTERNAL's notes or list say.
        self.write_no_sale(self.TRUTHFUL_INTERNAL_NOTES)
        self.assertEqual(self.iap_findings("appstore"), {})
        self.write_no_sale('"Subscribe" "Restore Purchases" "Manage Subscription" Sandbox\n',
                           bundles='"dev.cmux.app.internal", "com.cmux.app.not-this-one"')
        self.assertEqual(self.iap_findings("appstore"), {})
        write(self.root, "cmux-next-ios/AppStoreReview/review-notes-asc.txt", self.TRUTHFUL_INTERNAL_NOTES)
        found = self.iap_findings("appstore")
        self.assertEqual(set(found), {"iap.review-notes"}, found)
        self.assertIn("cmux-next-ios/AppStoreReview/review-notes-asc.txt", found["iap.review-notes"][0])
        write(self.root, "Packages/iOS/CmuxMobileBilling/Sources/CmuxMobileBillingUI/MobilePlansView.swift",
              'import StoreKit\nText("Plans")\n')
        self.assertTrue({"iap.restore", "iap.disclosure", "iap.manage"} <= set(self.iap_findings("appstore")))

    def test_the_ordinary_internal_lane_keeps_the_appstore_notes_rule(self) -> None:
        # The TestFlight nightly lane submits nothing: it judges as it did before.
        self.write_no_sale('Settings > "Plan" opens "Plans". "Subscribe" buys in the Sandbox.\n')
        self.assertEqual(self.iap_findings("internal"), {})

    def test_a_switched_entitlements_setting_judges_every_file_it_can_pick(self) -> None:
        # project.yml's AppStore configuration picks its entitlements by
        # CMUX_MOBILE_ASSOCIATED_DOMAINS; both files must carry Sign in with Apple.
        project = (self.root / "cmux-next-ios/project.yml").read_text()
        project = project.replace(
            "    settings:\n      base:\n        CMUX_MOBILE_APPLE_SIGN_IN: \"NO\"\n",
            "    settings:\n      base:\n        CMUX_MOBILE_APPLE_SIGN_IN: \"NO\"\n"
            "        CMUX_MOBILE_DISTRIBUTION_ENTITLEMENTS_NO: App/CmuxMobileApp-TestFlight.entitlements\n"
            "        CMUX_MOBILE_DISTRIBUTION_ENTITLEMENTS_YES: App/CmuxMobileApp-TestFlight-Links.entitlements\n", 1)
        project = project.replace(
            "        AppStore:\n          CMUX_MOBILE_ENTITLEMENTS_NO: App/CmuxMobileApp-TestFlight.entitlements\n",
            "        AppStore:\n          CMUX_MOBILE_ENTITLEMENTS_NO: "
            "$(CMUX_MOBILE_DISTRIBUTION_ENTITLEMENTS_$(CMUX_MOBILE_ASSOCIATED_DOMAINS))\n", 1)
        write(self.root, "cmux-next-ios/project.yml", project)
        lint = self.run_lint()
        self.assertIn("signin.apple-entitlement", self.rules(lint))
        self.assertTrue(any("TestFlight-Links.entitlements" in f.where for f in lint.findings))
        write(self.root, "cmux-next-ios/App/CmuxMobileApp-TestFlight-Links.entitlements",
              plistlib.dumps({"aps-environment": "production", "com.apple.developer.applesignin": ["Default"],
                              "com.apple.developer.associated-domains": ["applinks:cmux.com"]}).decode())
        self.assertEqual(self.rules(self.run_lint()), set())

    def test_history_detector_that_vanished_blocks(self) -> None:
        write(self.root, "cmux-next-ios/AppStoreReview/rejection-history.json",
              json.dumps({"rejections": [{"date": "d", "guideline": "2.1", "summary": "s", "detectors": ["uitest:testGone"]}]}))
        self.assertIn("history.detector-missing", self.rules(self.run_lint()))

    def test_face_id_without_purpose_string_blocks(self) -> None:
        write(self.root, "cmux-next-ios/App/Keys.swift", "import LocalAuthentication\nlet c = LAContext()\n")
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False}, "Info.plist")
        self.assertIn("privacy.purpose-string", self.rules(lint))

    def test_a_privacy_api_in_a_linked_package_needs_its_purpose_string(self) -> None:
        # The microphone lives in a shared package the kit links, not in the
        # app's own folders; the prompt is still the app's.
        write(self.root, "cmux-next-ios/CmuxMobileKit/Package.swift",
              'let p = Package(dependencies: [.package(path: "../../Packages/Shared/Voice")])\n')
        write(self.root, "Packages/Shared/Voice/Package.swift", "let p = Package()\n")
        write(self.root, "Packages/Shared/Voice/Sources/Voice/Rec.swift", "let e = AVAudioEngine()\n")
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False}, "Info.plist")
        self.assertIn("privacy.purpose-string", self.rules(lint))
        self.assertTrue(any("NSMicrophoneUsageDescription" in f.message for f in lint.findings))

    def test_a_package_the_app_does_not_link_is_not_judged(self) -> None:
        write(self.root, "cmux-next-ios/CmuxMobileKit/Package.swift", "let p = Package()\n")
        write(self.root, "Packages/iOS/Classic/Package.swift", "let p = Package()\n")
        write(self.root, "Packages/iOS/Classic/Sources/Classic/Rec.swift", "let e = AVAudioEngine()\n")
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False}, "Info.plist")
        self.assertNotIn("privacy.purpose-string", self.rules(lint))

    def test_a_biometry_locked_key_needs_the_face_id_purpose_string(self) -> None:
        # The classic app's SSH key lock (#40636): Secure Enclave keys with
        # biometry access control ask for Face ID with no LAContext call.
        write(self.root, "cmux-next-ios/App/Keys.swift", "var flags: SecAccessControlCreateFlags = [.privateKeyUsage, .biometryCurrentSet]\n")
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False}, "Info.plist")
        self.assertTrue(any("NSFaceIDUsageDescription" in f.message and f.severity == "blocker" for f in lint.findings))

    def test_a_generic_purpose_string_is_flagged(self) -> None:
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False,
                               "NSCameraUsageDescription": "This app uses the camera for features."}, "Info.plist")
        self.assertIn("privacy.purpose-string-vague", {f.rule for f in lint.findings})

    def test_bonjour_services_are_asked_for_only_when_bonjour_is_used(self) -> None:
        plist = {"ITSAppUsesNonExemptEncryption": False,
                 "NSLocalNetworkUsageDescription": "Connect directly to your Mac on this network for a faster link."}
        write(self.root, "cmux-next-ios/App/Dial.swift", "let l = try NWListener(using: .tcp, on: 0)\n")
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist(plist, "Info.plist")
        self.assertNotIn("privacy.bonjour", {f.rule for f in lint.findings})
        write(self.root, "cmux-next-ios/App/Browse.swift", 'let b = NWBrowser(for: .bonjour(type: "_cmux._tcp", domain: nil), using: .tcp)\n')
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist(plist, "Info.plist")
        self.assertIn("privacy.bonjour", self.rules(lint))

    # A valid reason code per category (the first one Apple lists that an app may use).
    REASONS = {"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"], "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
               "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"], "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
               "NSPrivacyAccessedAPICategoryActiveKeyboards": ["54BD.1"]}

    def manifests(self, app: list[str], reasons: dict[str, list[str]] | None = None, extra: dict | None = None,
                  **extensions: list[str]) -> None:
        def body(categories: list[str]) -> str:
            codes = dict(self.REASONS, **(reasons or {}))
            return plistlib.dumps(dict({"NSPrivacyTracking": False, "NSPrivacyAccessedAPITypes": [
                {"NSPrivacyAccessedAPIType": c, "NSPrivacyAccessedAPITypeReasons": codes.get(c, ["X.1"])}
                for c in categories]}, **(extra or {}))).decode()
        write(self.root, "cmux-next-ios/App/PrivacyInfo.xcprivacy", body(app))
        for name in ("NotificationContent", "NotificationService"):
            if name in extensions:
                write(self.root, f"cmux-next-ios/{name}/PrivacyInfo.xcprivacy", body(extensions[name]))

    def privacy_rules(self) -> set[str]:
        lint = gate.Lint(self.root, "appstore")
        lint.check_privacy_manifests()
        return self.rules(lint)

    def test_a_required_reason_api_the_manifest_omits_blocks(self) -> None:
        # ITMS-91053: PreviewStorage read free space with no DiskSpace entry (2026-11-12).
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileArtifacts/PreviewStorage.swift",
              "let v = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])\n")
        self.manifests([], NotificationContent=[], NotificationService=[])
        self.assertIn("privacy.required-reason", self.privacy_rules())
        self.manifests(["NSPrivacyAccessedAPICategoryDiskSpace"], NotificationContent=[], NotificationService=[])
        self.assertEqual(self.privacy_rules(), set())

    # ---- common-rejections.json: the public lists' rejections the gate now proves.

    def test_a_reason_code_outside_its_category_or_for_sdks_only_blocks(self) -> None:
        # ITMS-91056: a reason Apple does not list for the category invalidates the manifest.
        for codes in (["35F9.1"], ["C56D.1"]):
            self.manifests(["NSPrivacyAccessedAPICategoryUserDefaults"], reasons={"NSPrivacyAccessedAPICategoryUserDefaults": codes},
                           NotificationContent=[], NotificationService=[])
            self.assertIn("privacy.manifest-reason-code", self.privacy_rules(), codes)
        self.manifests(["NSPrivacyAccessedAPICategoryUserDefaults"], NotificationContent=[], NotificationService=[])
        self.assertNotIn("privacy.manifest-reason-code", self.privacy_rules())

    def test_app_group_defaults_need_1c8f_in_the_manifest_of_the_bundle_that_reads_them(self) -> None:
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileNotifications/PushActions.swift",
              'static func sharedDefaults() -> UserDefaults? { UserDefaults(suiteName: "group.x") }\n')
        write(self.root, "cmux-next-ios/NotificationContent/View.swift", "let p = PushSharedPreference.live(group: g)\n")
        ud = "NSPrivacyAccessedAPICategoryUserDefaults"
        self.manifests([ud], NotificationContent=[ud], NotificationService=[])
        lint = gate.Lint(self.root, "appstore")
        lint.check_privacy_manifests()
        where = {f.where.split(" -> ")[1] for f in lint.findings if f.rule == "privacy.reason-app-group"}
        self.assertEqual(where, {"cmux-next-ios/App/PrivacyInfo.xcprivacy", "cmux-next-ios/NotificationContent/PrivacyInfo.xcprivacy"})
        self.manifests([ud], reasons={ud: ["CA92.1", "1C8F.1"]}, NotificationContent=[ud], NotificationService=[])
        self.assertNotIn("privacy.reason-app-group", self.privacy_rules())

    def test_collected_data_must_use_apples_identifiers_and_tracking_needs_domains_and_att(self) -> None:
        good = {"NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeEmailAddress", "NSPrivacyCollectedDataTypeLinked": True,
                "NSPrivacyCollectedDataTypeTracking": False,
                "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]}
        self.manifests([], extra={"NSPrivacyCollectedDataTypes": [good]}, NotificationContent=[], NotificationService=[])
        self.assertEqual(self.privacy_rules(), set())
        bad = dict(good, NSPrivacyCollectedDataType="NSPrivacyCollectedDataTypeEmail",
                   NSPrivacyCollectedDataTypePurposes=["AppFunctionality"])
        self.manifests([], extra={"NSPrivacyCollectedDataTypes": [bad]}, NotificationContent=[], NotificationService=[])
        lint = gate.Lint(self.root, "appstore")
        lint.check_privacy_manifests()
        self.assertEqual(sum(f.rule == "privacy.collected-data" and f.where == "cmux-next-ios/App/PrivacyInfo.xcprivacy"
                             for f in lint.findings), 2)
        self.manifests([], extra={"NSPrivacyTracking": True}, NotificationContent=[], NotificationService=[])
        self.assertIn("privacy.tracking", self.privacy_rules())

    def lint_rules(self, plist: dict | None = None, lane: str = "appstore") -> set[str]:
        lint = gate.Lint(self.root, lane)
        lint.check_common_rejection_rules(plist or {})
        return {f.rule for f in lint.findings}

    def privacy_link(self) -> None:
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileSettings/Legal.swift",
              'let p = URL(string: "https://cmux.com/privacy-policy")!\n')

    def test_a_background_mode_the_app_never_uses_blocks(self) -> None:
        self.privacy_link()
        self.assertIn("background.unused-mode", self.lint_rules({"UIBackgroundModes": ["audio"]}))
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileVoice/Call.swift",
              "try session.setCategory(.playAndRecord, mode: .voiceChat)\n")
        self.assertNotIn("background.unused-mode", self.lint_rules({"UIBackgroundModes": ["audio"]}))
        self.assertIn("background.unused-mode", self.lint_rules({"UIBackgroundModes": ["audio", "location"]}))

    def test_uiwebview_in_source_or_binary_blocks(self) -> None:
        self.privacy_link()
        write(self.root, "cmux-next-ios/App/Old.swift", "// UIWebView was here\nlet w = WKWebView()\n")
        self.assertNotIn("api.uiwebview", self.lint_rules())
        write(self.root, "cmux-next-ios/App/Old.swift", "let w = UIWebView()\n")
        self.assertIn("api.uiwebview", self.lint_rules())
        app = self.root / "Payload/CmuxMobileApp.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "CmuxMobileApp", "ITSAppUsesNonExemptEncryption": False,
                                                         "CmuxMobileAppleSignIn": "YES"}))
        (app / "CmuxMobileApp").write_bytes(b"\x00_OBJC_CLASS_$_UIWebView\x00")
        lint = gate.Lint(self.root, "appstore")
        lint.check_app_bundle(app)
        self.assertIn("api.uiwebview", self.rules(lint))

    def test_the_privacy_policy_must_be_linked_inside_the_app(self) -> None:
        self.assertIn("privacy.policy-in-app", self.lint_rules())
        self.privacy_link()
        self.assertNotIn("privacy.policy-in-app", self.lint_rules())

    def test_keywords_that_name_another_company_block_but_generic_words_do_not(self) -> None:
        self.privacy_link()
        rel = "cmux-next-ios/AppStoreReview/metadata/version/1.0.0/en-US.json"
        write(self.root, rel, json.dumps({"description": "d", "keywords": "coding agent,cursor,warp,terminal"}))
        self.assertNotIn("metadata.keyword-trademark", self.lint_rules())
        write(self.root, rel, json.dumps({"description": "d", "keywords": "coding agent,Claude Code,chatgpt"}))
        lint = gate.Lint(self.root, "appstore")
        lint.check_common_rejection_rules({})
        self.assertEqual(sorted(f.message.split("'")[1] for f in lint.findings if f.rule == "metadata.keyword-trademark"),
                         ["Claude", "chatgpt"])

    def test_a_build_that_sells_nothing_warns_on_a_listing_that_says_it_sells_in_the_app(self) -> None:
        self.privacy_link()
        self.write_no_sale("Sign in with the demo account {{DEMO_ACCOUNT_EMAIL}}. Settings > \"Plan\" is read-only.")
        rel = "cmux-next-ios/AppStoreReview/metadata/version/1.0.0/en-US.json"
        write(self.root, rel, json.dumps({"description": "cmux Pro is a monthly subscription bought in the app."}))
        self.assertIn("metadata.iap-claim", self.lint_rules(lane="internal-submission"))
        self.assertNotIn("metadata.iap-claim", self.lint_rules(lane="appstore"))
        write(self.root, rel, json.dumps({"description": "Plans are managed on cmux.com."}))
        self.assertNotIn("metadata.iap-claim", self.lint_rules(lane="internal-submission"))

    def test_a_submission_without_sign_in_steps_in_the_notes_blocks(self) -> None:
        self.privacy_link()
        write(self.root, "cmux-next-ios/AppStoreReview/review-notes-asc.txt", "cmux runs agents on your Mac.\n")
        self.assertIn("review-notes.sign-in", self.lint_rules())
        self.assertNotIn("review-notes.sign-in", self.lint_rules(lane="internal"))
        write(self.root, "cmux-next-ios/AppStoreReview/review-notes-asc.txt", "Sign in: {{DEMO_ACCOUNT_EMAIL}}\n")
        self.assertNotIn("review-notes.sign-in", self.lint_rules())

    def test_an_entitlement_the_app_never_uses_blocks(self) -> None:
        ents = {"aps-environment": "production", "com.apple.developer.healthkit": True}
        write(self.root, "cmux-next-ios/App/Push.swift", "UIApplication.shared.registerForRemoteNotifications()\n")
        lint = gate.Lint(self.root, "appstore")
        lint.check_entitlements_used(ents, "x.entitlements")
        self.assertEqual([f.message.split()[0] for f in lint.findings if f.rule == "entitlement.unused"],
                         ["com.apple.developer.healthkit"])

    def test_a_weakened_ats_warns(self) -> None:
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False, "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}, "p")
        self.assertNotIn("ats.exception", {f.rule for f in lint.findings})
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False,
                               "NSAppTransportSecurity": {"NSExceptionDomains": {"x.com": {"NSExceptionAllowsInsecureHTTPLoads": True}}}}, "p")
        self.assertIn("ats.exception", {f.rule for f in lint.findings})

    def common(self, entries: list[dict]) -> list[str]:
        write(self.root, gate.COMMON_REJECTIONS_FILE, json.dumps({"rejections": entries}))
        lint = gate.Lint(self.root, "appstore")
        lint.check_common_rejections()
        return sorted(f.rule for f in lint.findings)

    def test_a_common_rejection_must_name_a_real_detector_a_source_and_a_known_status(self) -> None:
        src = ["https://github.com/x/y"]
        self.assertEqual(self.common([{"id": "a", "guideline": "2.1", "status": "gated", "sources": src,
                                       "detectors": ["lint:account.deletion", "uitest:testX"]}]), [])
        self.assertEqual(self.common([{"id": "a", "guideline": "2.1", "status": "gated", "sources": src,
                                       "detectors": ["lint:no.such-rule", "uitest:testGone"]}]),
                         ["common-rejections.detector-missing"] * 2)
        self.assertEqual(self.common([{"id": "a", "guideline": "2.1", "status": "gated", "sources": src}]),
                         ["common-rejections.no-detector"])
        self.assertEqual(self.common([{"id": "a", "guideline": "2.1", "status": "maybe", "sources": src}]),
                         ["common-rejections.status"])
        self.assertEqual(self.common([{"id": "a", "guideline": "2.1", "status": "follow-up"}]),
                         ["common-rejections.no-follow-up", "common-rejections.source"])


    def test_an_extension_without_its_own_manifest_blocks(self) -> None:
        self.manifests([], NotificationContent=[])
        self.assertIn("privacy.manifest", self.privacy_rules())

    def test_an_extensions_manifest_covers_its_own_sources(self) -> None:
        write(self.root, "cmux-next-ios/NotificationService/NotificationService.swift", "let d = UserDefaults.standard\n")
        self.manifests(["NSPrivacyAccessedAPICategoryUserDefaults"], NotificationContent=[], NotificationService=[])
        self.assertIn("privacy.required-reason", self.privacy_rules())

    def test_local_network_without_bonjour_browsing_needs_no_bonjour_services(self) -> None:
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False,
                               "NSLocalNetworkUsageDescription": "Connect directly to your Mac on this network."}, "Info.plist")
        self.assertNotIn("privacy.bonjour", {f.rule for f in lint.findings})
        write(self.root, "cmux-next-ios/App/Find.swift", "let b = NWBrowser(for: .bonjour(type: \"_x._tcp\", domain: nil), using: .tcp)\n")
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False,
                               "NSLocalNetworkUsageDescription": "Connect directly to your Mac on this network."}, "Info.plist")
        self.assertIn("privacy.bonjour", {f.rule for f in lint.findings})

    def test_vpn_entitlement_blocks_only_the_app_store_lane(self) -> None:
        ents = {"com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]}
        store = gate.Lint(self.root, "appstore")
        store.check_entitlements(ents, "x")
        beta = gate.Lint(self.root, "beta")
        beta.check_entitlements(ents, "x")
        self.assertIn("entitlement.vpn", self.rules(store))
        self.assertNotIn("entitlement.vpn", self.rules(beta))

    def test_vpn_extension_in_bundle_blocks(self) -> None:
        app = self.root / "Payload/CmuxMobileApp.app"
        (app / "PlugIns/CloudVPN.appex").mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "CmuxMobileApp", "ITSAppUsesNonExemptEncryption": False,
                                                         "CmuxMobileAppleSignIn": "YES"}))
        (app / "PrivacyInfo.xcprivacy").write_text("x")
        (app / "CmuxMobileApp").write_bytes(b"\x00NEPacketTunnelProvider\x00")
        (app / "PlugIns/CloudVPN.appex/Info.plist").write_bytes(plistlib.dumps(
            {"NSExtension": {"NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"}}))
        lint = gate.Lint(self.root, "appstore")
        lint.check_app_bundle(app)
        self.assertTrue({"binary.vpn-extension", "api.vpn"} <= self.rules(lint))

    def test_report_ranks_blockers_first_and_fails(self) -> None:
        lint_json = self.root / "lint.json"
        lint_json.write_text(json.dumps({"lane": "appstore", "checked": [], "findings": [
            {"rule": "a", "guideline": "2.1", "severity": "warning", "message": "w", "where": ""},
            {"rule": "b", "guideline": "1.5", "severity": "blocker", "message": "b", "where": ""},
        ], "urls": []}))
        out = self.root / "report.md"
        code = gate.main(["report", "--lint", str(lint_json), "--asc-skipped", "--out", str(out)])
        text = out.read_text()
        self.assertEqual(code, 1)
        self.assertLess(text.index("| 1 | blocker"), text.index("| 2 | warning"))

    def test_a_binary_that_hides_sign_in_with_apple_blocks(self) -> None:
        app = self.root / "Payload/CmuxMobileApp.app"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "CmuxMobileApp", "ITSAppUsesNonExemptEncryption": False,
                                                         "CmuxMobileAppleSignIn": "NO"}))
        (app / "PrivacyInfo.xcprivacy").write_text("x")
        (app / "CmuxMobileApp").write_bytes(b"\x00")
        lint = gate.Lint(self.root, "appstore")
        lint.check_app_bundle(app)
        self.assertIn("binary.apple-sign-in", self.rules(lint))

    def test_url_checks_never_reach_a_private_address(self) -> None:
        # A URL in the judged source is fetched only over https from a public host.
        for url in ("http://cmux.com/support", "https://127.0.0.1/x", "https://169.254.169.254/latest/meta-data/",
                    "https://10.0.0.1/", "https://[::1]/", "https://localhost/", "file:///etc/passwd"):
            result = gate.fetch(url)
            self.assertEqual(result["status"], 0, url)
            self.assertIn("not fetched", result["error"], url)

    def test_a_redirect_to_a_private_address_is_refused(self) -> None:
        import unittest.mock as mock
        hops = []

        class Resp:
            def __init__(self, status, location=None):
                self.status, self.location = status, location

            def getheader(self, name):
                return self.location if name == "Location" else None

            def read(self, n):
                return b"<title>ok</title>"

        class Conn:
            def __init__(self, host, address, port, timeout):
                hops.append(host)
                self.host = host

            def request(self, *a, **k):
                pass

            def getresponse(self):
                return Resp(302, "https://127.0.0.1/admin") if self.host == "cmux.com" else Resp(200)

            def close(self):
                pass

        with mock.patch.object(gate, "PinnedHTTPSConnection", Conn), \
                mock.patch.object(gate.socket, "getaddrinfo",
                                  lambda host, *a, **k: [(0, 0, 0, "", ("104.18.0.1" if host == "cmux.com" else "127.0.0.1", 443))]):
            result = gate.fetch("https://cmux.com/support")
        self.assertEqual(hops, ["cmux.com"])
        self.assertIn("not a public address", result["error"])

    def test_report_reads_asc_strict_warnings_as_blockers(self) -> None:
        asc = self.root / "asc-validate.json"
        asc.write_text(json.dumps({"issues": [
            {"severity": "warning", "blocking": True, "code": "screenshots.missing_required",
             "message": "No 6.9-inch iPhone screenshots"}]}))
        findings = gate.asc_findings(asc)
        self.assertEqual(findings[0]["severity"], "blocker")
        self.assertEqual(findings[0]["guideline"], "2.3")

    # INTERNAL build run 45090966438's asc validate --strict on cmux INTERNAL's 1.2.0,
    # the app's first App Store version: What's New empty, listed twice by asc.
    ASC_FIRST_VERSION_VALIDATE = {
        "appId": "6791408425", "versionString": "1.2.0", "strict": True,
        "remediation": {"steps": [{"order": 1, "blocking": True, "severity": "warning",
                                   "checkId": "metadata.required.whats_new", "message": "what's new is empty",
                                   "field": "whatsNew", "resourceId": "1fb582be"}]},
        "checks": [{"id": "metadata.required.whats_new", "severity": "warning", "message": "what's new is empty",
                    "field": "whatsNew", "resourceId": "1fb582be"}],
    }

    def asc_report(self, versions: object | None) -> tuple[int, str]:
        asc = self.root / "asc-validate.json"
        asc.write_text(json.dumps(self.ASC_FIRST_VERSION_VALIDATE))
        args = ["report", "--asc-validate", str(asc), "--out", str(self.root / "report.md")]
        if versions is not None:
            path = self.root / "app-store-versions.json"
            path.write_text(versions if isinstance(versions, str) else json.dumps(versions))
            args += ["--asc-versions", str(path)]
        code = gate.main(args)
        return code, (self.root / "report.md").read_text()

    def test_a_first_app_store_version_is_not_asked_for_whats_new(self) -> None:
        # Apple refuses What's New on an app's first App Store version: run
        # 45102744374 failed "STATE_ERROR: Attribute 'whatsNew' cannot be
        # edited at this time" on cmux INTERNAL 1.2.0, so the gate must not
        # block on a field nobody can fill.
        code, text = self.asc_report({"data": [
            {"id": "v1", "attributes": {"versionString": "1.2.0", "appStoreState": "PREPARE_FOR_SUBMISSION"}}]})
        self.assertEqual(code, 0, text)
        self.assertIn("**YES**", text)
        self.assertIn("first App Store version", text)
        self.assertIn("45102744374", text)

    def test_whats_new_still_blocks_once_a_version_has_been_on_sale(self) -> None:
        code, text = self.asc_report({"data": [
            {"id": "v1", "attributes": {"versionString": "1.2.0", "appStoreState": "PREPARE_FOR_SUBMISSION"}},
            {"id": "v0", "attributes": {"versionString": "1.1.0", "appStoreState": "READY_FOR_SALE"}}]})
        self.assertEqual(code, 1)
        self.assertIn("**NO**: 1 blocking", text)
        self.assertIn("what's new is empty", text)

    def test_whats_new_blocks_when_the_version_history_is_unknown(self) -> None:
        # No version list, or one that did not parse: fail closed.
        for versions in (None, "not json", {"errors": [{"status": "401"}]}):
            code, text = self.asc_report(versions)
            self.assertEqual(code, 1, versions)
            self.assertIn("**NO**: 1 blocking", text)

    def test_asc_lists_each_check_once(self) -> None:
        # asc prints a check under both remediation.steps and checks; run
        # 45090966438's report showed "what's new is empty" twice (2.1 and 2.3).
        asc = self.root / "asc-validate.json"
        asc.write_text(json.dumps(self.ASC_FIRST_VERSION_VALIDATE))
        findings = gate.asc_findings(asc)
        self.assertEqual(len(findings), 1, findings)
        self.assertEqual(findings[0]["rule"], "asc.metadata.required.whats_new")
        self.assertEqual(findings[0]["guideline"], "2.3")

    def test_a_retired_subscription_is_never_a_blocker(self) -> None:
        # Readiness run 45748224089 (2026-11-26) counted the unused trial App
        # Store Connect cannot delete as two blockers (no promotional image,
        # READY_TO_SUBMIT); Go Monthly's READY_TO_SUBMIT stays one.
        asc = self.root / "asc-validate.json"
        asc.write_text(json.dumps({"remediation": {"steps": [
            {"blocking": True, "severity": "warning", "checkId": "subscriptions.images.recommended",
             "message": "trial has no subscription promotional image", "resourceId": "6822947304"},
            {"blocking": True, "severity": "warning", "checkId": "subscriptions.review_readiness.needs_attention",
             "message": "trial is READY_TO_SUBMIT", "resourceId": "6822947304"},
            {"blocking": True, "severity": "warning", "checkId": "subscriptions.review_readiness.needs_attention",
             "message": "Go Monthly is READY_TO_SUBMIT", "resourceId": "6818445194"}]}}))
        findings = gate.asc_findings(asc)
        self.assertEqual([(f["where"], f["severity"]) for f in findings],
                         [("6822947304", "info"), ("6822947304", "info"), ("6818445194", "blocker")])

    def test_a_version_apple_already_has_is_not_blocked_on_its_state(self) -> None:
        # Readiness run 45615832158 (2026-11-25): asc validate on 1.0.0 in
        # WAITING_FOR_REVIEW gave "version is in non-editable state", and the
        # gate made it a blocker for the whole review.
        asc = self.root / "asc-validate.json"
        for state, severity in (("WAITING_FOR_REVIEW", "info"), ("IN_REVIEW", "info"),
                                ("PENDING_DEVELOPER_RELEASE", "info"), ("DEVELOPER_REJECTED", "blocker")):
            asc.write_text(json.dumps({"remediation": {"steps": [
                {"order": 1, "blocking": True, "severity": "error", "checkId": "version.state.editable",
                 "message": f'version is in non-editable state "{state}"', "field": "appVersionState"}]}}))
            findings = gate.asc_findings(asc)
            self.assertEqual([f["severity"] for f in findings], [severity], state)

    def test_asc_advice_and_a_locked_listing_do_not_block(self) -> None:
        # Readiness run 45874464871 (2026-11-26) on 1.0.0 WAITING_FOR_REVIEW
        # ranked 28 blockers: 3 missing promotional images and 7 keyword and
        # subtitle overlaps (asc's advice, no App Review requirement) and 11
        # locales' Terms of Use links on a listing App Store Connect locks
        # during review. The subscriptions' missing review screenshots and
        # metadata stay blockers: they are editable and App Review needs them.
        def check(code: str, resource: str, message: str, severity: str = "warning") -> dict:
            return {"id": code, "severity": severity, "resourceId": resource, "message": message}

        def body(state: str) -> dict:
            return {"versionString": "1.0.0", "checks": [
                check("version.state.editable", "", f'version is in non-editable state "{state}"', "error"),
                check("subscriptions.images.recommended", "6838160761", "no subscription promotional image"),
                check("metadata.keywords.overlap_subtitle", "219cf75d", "keyword field repeats a subtitle term"),
                check("legal.subscription.terms_of_use_link", "87553b21", "description is missing a Terms of Use link"),
                check("subscriptions.diagnostics.review_screenshot_missing", "6838160761", "no App Review screenshot"),
                check("subscriptions.review_readiness.needs_attention", "6838160761", "is MISSING_METADATA"),
            ]}

        asc = self.root / "asc-validate.json"
        asc.write_text(json.dumps(body("WAITING_FOR_REVIEW")))
        severities = {f["rule"]: f["severity"] for f in gate.asc_findings(asc)}
        self.assertEqual(severities, {
            "asc.version.state.editable": "info",
            "asc.subscriptions.images.recommended": "warning",
            "asc.metadata.keywords.overlap_subtitle": "warning",
            "asc.legal.subscription.terms_of_use_link": "warning",
            "asc.subscriptions.diagnostics.review_screenshot_missing": "blocker",
            "asc.subscriptions.review_readiness.needs_attention": "blocker",
        })
        # An editable version's listing can be fixed before the submit: it blocks.
        asc.write_text(json.dumps(body("DEVELOPER_REJECTED")))
        severities = {f["rule"]: f["severity"] for f in gate.asc_findings(asc)}
        self.assertEqual(severities["asc.legal.subscription.terms_of_use_link"], "blocker")
        self.assertEqual(severities["asc.version.state.editable"], "blocker")
        self.assertEqual(severities["asc.subscriptions.images.recommended"], "warning")

    def test_the_asc_job_saves_the_app_store_version_history(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-review-gate.yml").read_text()
        self.assertIn('asc versions list --app "$ASC_APP_ID" --platform IOS --paginate --output json > app-store-versions.json',
                      workflow)
        self.assertIn("--asc-versions", workflow)

    def test_report_fails_closed_when_inputs_never_arrive(self) -> None:
        # Run 42799920852 said YES with no lint and no suite result in hand.
        out = self.root / "report.md"
        code = gate.main(["report", "--asc-skipped", "--expect-lint", "--expect-device", "iphone",
                          "--expect-device", "ipad", "--out", str(out)])
        text = out.read_text()
        self.assertEqual(code, 1)
        self.assertIn("**NO**: 3 blocking", text)
        self.assertIn("guideline lint left no result", text)
        self.assertIn("no ipad suite result", text)

    def test_a_device_job_that_left_no_result_fails_the_report(self) -> None:
        # Each device walks in its own job: a Duo job that failed, was
        # cancelled or uploaded nothing must fail the report, and only Duo's
        # own skip marker (no Duo simulator on the image) stands in for it.
        passed = {"testNodes": [{"nodeType": "Test Case", "name": "testA()", "result": "Passed"}]}
        results = []
        for family in ("iphone", "ipad"):
            path = self.root / f"{family}.json"
            path.write_text(json.dumps(passed))
            results += ["--xcresult-json", str(path)]
        expect = ["--expect-device", "iphone", "--expect-device", "ipad", "--expect-device-or-skipped", "duo"]
        out = self.root / "report.md"
        self.assertEqual(gate.main(["report", "--asc-skipped", *results, *expect, "--out", str(out)]), 1)
        self.assertIn("no duo suite result", out.read_text())
        duo_skipped = self.root / "duo.skipped.json"
        duo_skipped.write_text(json.dumps({"family": "duo", "skipped": True}))
        self.assertEqual(gate.main(["report", "--asc-skipped", *results, *expect,
                                    "--skipped", str(duo_skipped), "--out", str(out)]), 0)
        # A skip marker never excuses a device that must be walked.
        ipad_skipped = self.root / "ipad.skipped.json"
        ipad_skipped.write_text(json.dumps({"family": "ipad", "skipped": True}))
        self.assertEqual(gate.main(["report", "--asc-skipped", results[0], results[1], *expect,
                                    "--skipped", str(duo_skipped), "--skipped", str(ipad_skipped),
                                    "--out", str(out)]), 1)
        self.assertIn("no ipad suite result", out.read_text())

    def test_the_report_waits_for_and_expects_every_device_job(self) -> None:
        # The devices walk side by side, one reviewer-path job each; the
        # report needs them all and fails closed on any family's missing
        # result, and each job's artifact has its own name.
        workflow = (ROOT / ".github/workflows/ios-review-gate.yml").read_text()
        reviewer = workflow.split("\n  reviewer-path:\n", 1)[1].split("\n  asc-validate:\n", 1)[0]
        report = workflow.split("\n  report:\n", 1)[1]
        self.assertIn("fail-fast: false", reviewer)
        self.assertIn("        family: ${{ fromJSON(needs.plan.outputs.families) }}\n", reviewer)
        self.assertIn("name: review-gate-path-${{ env.LANE }}-${{ matrix.family }}", reviewer)
        self.assertNotIn("for family in", reviewer)
        self.assertIn("needs: [plan, lint, reviewer-path, asc-validate]", report)
        self.assertIn("pattern: review-gate-*", report)
        self.assertIn("--expect-device iphone --expect-device-or-skipped duo", report)
        # iPad: required on every run but a pull request on the iPhone-only app (the plan's skip marker).
        self.assertIn('if [ "$EVENT" = pull_request ]; then args+=(--expect-device-or-skipped ipad); '
                      'else args+=(--expect-device ipad); fi', report)
        self.assertIn("find in -name '*.skipped.json'", report)

    def test_a_device_with_no_tests_is_never_a_pass(self) -> None:
        empty = self.root / "iphone.json"
        empty.write_text(json.dumps({"testNodes": []}))
        out = self.root / "report.md"
        code = gate.main(["report", "--asc-skipped", "--xcresult-json", str(empty), "--out", str(out)])
        self.assertEqual(code, 1)
        self.assertIn("ran no tests", out.read_text())

    def test_a_device_whose_every_test_skipped_is_never_a_pass(self) -> None:
        skipped = self.root / "iphone.json"
        skipped.write_text(json.dumps({"testNodes": [{"nodeType": "Test Plan", "name": "p", "children": [
            {"nodeType": "Test Case", "name": "testA()", "result": "Skipped"},
            {"nodeType": "Test Case", "name": "testB()", "result": "Skipped"}]}]}))
        out = self.root / "report.md"
        code = gate.main(["report", "--asc-skipped", "--xcresult-json", str(skipped), "--out", str(out)])
        self.assertEqual(code, 1)
        self.assertIn("uitest.none-ran", {f["rule"] for f in gate.xcresult_findings(skipped)})

    def test_a_suite_that_exited_nonzero_with_no_failed_test_blocks(self) -> None:
        # xcodebuild can crash or refuse the xctestrun after a passing test
        # lands in the result; the exit status is then the only signal.
        passed = self.root / "iphone.json"
        passed.write_text(json.dumps({"testNodes": [{"nodeType": "Test Case", "name": "testA()", "result": "Passed"}]}))
        status = self.root / "iphone.status.json"
        status.write_text(json.dumps({"family": "iphone", "exit": 65}))
        out = self.root / "report.md"
        code = gate.main(["report", "--asc-skipped", "--xcresult-json", str(passed),
                          "--suite-status", str(status), "--out", str(out)])
        self.assertEqual(code, 1)
        self.assertIn("xcodebuild exited 65 on iphone", out.read_text())
        status.write_text(json.dumps({"family": "iphone", "exit": 0}))
        self.assertEqual(gate.main(["report", "--asc-skipped", "--xcresult-json", str(passed),
                                    "--suite-status", str(status), "--out", str(out)]), 0)

    def test_an_unreadable_result_still_writes_the_report_and_blocks(self) -> None:
        # A failed xcresult export leaves an empty file; the report must be
        # written and say so instead of dying on JSONDecodeError.
        empty = self.root / "iphone.json"
        empty.write_text("")
        out = self.root / "report.md"
        code = gate.main(["report", "--asc-skipped", "--xcresult-json", str(empty), "--out", str(out)])
        self.assertEqual(code, 1)
        self.assertIn("iphone.json did not parse", out.read_text())

    def test_gate_notes_in_a_suite_log_become_warnings(self) -> None:
        passed = self.root / "duo.json"
        passed.write_text(json.dumps({"testNodes": [{"nodeType": "Test Case", "name": "testA()", "result": "Passed"}]}))
        log = self.root / "duo.log"
        log.write_text("Test Case started\nGATE-NOTE fold-unjudged: XCUITest cannot fold the simulator\n"
                       "GATE-NOTE fold-unjudged: XCUITest cannot fold the simulator\n")
        out = self.root / "report.md"
        code = gate.main(["report", "--asc-skipped", "--xcresult-json", str(passed),
                          "--suite-log", str(log), "--out", str(out)])
        text = out.read_text()
        self.assertEqual(code, 0)
        self.assertEqual(text.count("XCUITest cannot fold the simulator"), 1)

    def ratchet_inputs(self, failed: list[str]) -> tuple[Path, Path]:
        suite = self.root / "iphone.json"
        cases = [{"nodeType": "Test Case", "name": name, "result": "Failed",
                  "children": [{"nodeType": "Failure Message", "name": f"AppReviewGateUITests.swift:{i}: on screen: {i}"}]}
                 for i, name in enumerate(failed, 1)] or [{"nodeType": "Test Case", "name": "testA()", "result": "Passed"}]
        suite.write_text(json.dumps({"testNodes": [{"nodeType": "Unit test bundle", "name": "AppReviewGateUITests", "children": cases}]}))
        known = self.root / "known-blockers.json"
        known.write_text(json.dumps({"blockers": [{"key": "uitest.failed|iphone|AppReviewGateUITests/testOld()"}]}))
        return suite, known

    def test_a_known_blocker_alone_passes_a_change_and_still_shows(self) -> None:
        suite, known = self.ratchet_inputs(["testOld()"])
        out = self.root / "report.md"
        code = gate.main(["report", "--asc-skipped", "--xcresult-json", str(suite),
                          "--known-blockers", str(known), "--out", str(out)])
        text = out.read_text()
        self.assertEqual(code, 0)
        self.assertIn("**NO**: 1 blocking", text)
        self.assertIn("No new blocker", text)
        # A submission reads no baseline: the same result refuses it.
        self.assertEqual(gate.main(["report", "--asc-skipped", "--xcresult-json", str(suite), "--out", str(out)]), 1)

    def test_a_new_blocker_fails_the_change_that_brought_it(self) -> None:
        suite, known = self.ratchet_inputs(["testOld()", "testNew()"])
        out = self.root / "report.md"
        code = gate.main(["report", "--asc-skipped", "--xcresult-json", str(suite),
                          "--known-blockers", str(known), "--out", str(out)])
        text = out.read_text()
        self.assertEqual(code, 1)
        self.assertIn("**1 new blocking**", text)
        self.assertIn("uitest.failed|iphone|AppReviewGateUITests/testNew()", text)
        self.assertNotIn("`uitest.failed|iphone|AppReviewGateUITests/testOld()`: ", text)

    def test_a_fixed_blocker_is_named_for_removal(self) -> None:
        suite, known = self.ratchet_inputs([])
        out = self.root / "report.md"
        code = gate.main(["report", "--asc-skipped", "--xcresult-json", str(suite),
                          "--known-blockers", str(known), "--out", str(out)])
        self.assertEqual(code, 0)
        self.assertIn("remove from", out.read_text())

    def test_a_change_cannot_pin_its_own_regression(self) -> None:
        suite, known = self.ratchet_inputs(["testOld()", "testNew()"])
        proposed = self.root / "proposed.json"
        proposed.write_text(json.dumps({"blockers": [{"key": "uitest.failed|iphone|AppReviewGateUITests/testOld()"},
                                                     {"key": "uitest.failed|iphone|AppReviewGateUITests/testNew()"}]}))
        out = self.root / "report.md"
        # Its own list alone would pass it; judged on the base's, it fails twice over.
        self.assertEqual(gate.main(["report", "--asc-skipped", "--xcresult-json", str(suite),
                                    "--known-blockers", str(proposed), "--out", str(out)]), 0)
        self.assertEqual(gate.main(["report", "--asc-skipped", "--xcresult-json", str(suite), "--known-blockers",
                                    str(known), "--proposed-known-blockers", str(proposed), "--out", str(out)]), 1)
        self.assertIn("known-blockers.added", out.read_text())
        # Removing a fixed entry is fine.
        suite, known = self.ratchet_inputs([])
        proposed.write_text(json.dumps({"blockers": []}))
        self.assertEqual(gate.main(["report", "--asc-skipped", "--xcresult-json", str(suite), "--known-blockers",
                                    str(known), "--proposed-known-blockers", str(proposed), "--out", str(out)]), 0)

    def test_the_key_ignores_line_numbers_and_screen_dumps(self) -> None:
        a = {"rule": "uitest.failed", "where": "ipad", "message": "AppReviewGateUITests/testX(): T.swift:120: on screen: a"}
        b = {"rule": "uitest.failed", "where": "ipad", "message": "AppReviewGateUITests/testX(): T.swift:131: on screen: b"}
        self.assertEqual(gate.blocker_key(a), gate.blocker_key(b))
        self.assertEqual(gate.blocker_key({"rule": "r", "where": "a/B.swift:90"}),
                         gate.blocker_key({"rule": "r", "where": "a/B.swift:91"}))

    def test_missing_results_are_judged_apart_from_the_baseline(self) -> None:
        # Fail closed: a suite that never reported is new, whatever is known.
        _, known = self.ratchet_inputs([])
        out = self.root / "report.md"
        self.assertEqual(gate.main(["report", "--asc-skipped", "--known-blockers", str(known), "--out", str(out)]), 0)
        self.assertEqual(gate.main(["report", "--asc-skipped", "--expect-device", "ipad",
                                    "--known-blockers", str(known), "--out", str(out)]), 1)
        known.write_text("not json")
        self.assertEqual(gate.main(["report", "--asc-skipped", "--known-blockers", str(known), "--out", str(out)]), 1)


class RealTreeTests(unittest.TestCase):
    """The checked-in history, the NEXT app's UI tests and the gate agree."""

    def test_every_rejection_names_a_detector_that_exists_here(self) -> None:
        lint = gate.Lint(ROOT, "appstore")
        lint.check_history()
        self.assertEqual([f.message for f in lint.findings], [])

    def test_every_common_rejection_is_mapped_to_a_detector_that_exists_here(self) -> None:
        lint = gate.Lint(ROOT, "internal-submission")
        entries = lint.check_common_rejections()
        self.assertGreaterEqual(len(entries), 30)
        self.assertEqual([f.message for f in lint.findings], [])

    def test_the_real_app_passes_the_common_rejection_rules(self) -> None:
        # The App Group defaults reason, the background modes, UIWebView, the
        # in-app privacy link, keywords, notes and the shipping entitlements.
        for lane in gate.LANES:
            lint = gate.Lint(ROOT, lane)
            lint.check_privacy_manifests()
            lint.check_common_rejection_rules(lint.project_info())
            for rel in gate.APPSTORE_ENTITLEMENTS:
                lint.check_entitlements_used(plistlib.loads((ROOT / rel).read_bytes()), rel)
            self.assertEqual([f"{f.rule}: {f.message}" for f in lint.findings if f.severity == "blocker"], [], lane)

    def test_the_app_declares_a_specific_purpose_string_for_every_privacy_api_it_links(self) -> None:
        # Fails CI the moment the NEXT app (or a package it links) calls a
        # privacy API without its Info.plist purpose string, or a purpose
        # string reads as generic: iOS kills the app at the prompt, and App
        # Review rejects under 5.1.1 (first-user journey, permission audit).
        lint = gate.Lint(ROOT, "appstore")
        plist = lint.project_info()
        self.assertTrue(plist, "project.yml's CmuxMobileApp Info.plist properties could not be read")
        lint.check_info_plist(plist, gate.PROJECT_YML)
        privacy = [f"{f.rule}: {f.message}" for f in lint.findings if f.rule.startswith("privacy.")]
        self.assertEqual(privacy, [])

    def test_the_workflow_runs_every_gate_test_by_its_real_name(self) -> None:
        # -only-testing names resolve only when target, class and method match.
        workflow = (ROOT / ".github/workflows/ios-review-gate.yml").read_text()
        tests = (ROOT / "cmux-next-ios/UITests/AppReviewGateUITests.swift").read_text()
        project = (ROOT / "cmux-next-ios/project.yml").read_text()
        for needle, text in (("CmuxMobileAppUITests:", project),
                             ("final class AppReviewGateUITests: XCTestCase", tests),
                             ("-only-testing:CmuxMobileAppUITests/AppReviewGateUITests", workflow),
                             ("-scheme CmuxMobileApp ", workflow)):
            self.assertTrue(needle in text, needle)

    def test_every_known_blocker_names_something_that_still_exists(self) -> None:
        # A renamed or deleted test would leave a pin nothing can match.
        known = json.loads((ROOT / gate.KNOWN_BLOCKERS_FILE).read_text())
        tests = (ROOT / "cmux-next-ios/UITests/AppReviewGateUITests.swift").read_text()
        for entry in known["blockers"]:
            rule, where, *rest = entry["key"].split("|")
            if rule == "uitest.failed":
                self.assertIn(where, ("iphone", "ipad", "duo"), entry["key"])
                name = rest[0].split("/")[-1].removesuffix("()")
                self.assertIn(f"func {name}(", tests, entry["key"])
            self.assertNotIn("agent", rule, "no agent rule is pinned")

    def test_the_app_store_build_names_no_private_framework_path(self) -> None:
        # The binary scan's api.private-framework blocker (2.5.1) failed the
        # 1.0.0 upload's IPA check (run 44431574873): CmuxConversationUI named
        # ChatKit's PrivateFrameworks path. Packages compile into every
        # configuration, so the path lives only in the app target, compiled out
        # of every shipping build (CMUX_MOBILE_PRODUCTION: Production, TestFlight,
        # which builds the cmux INTERNAL record, TestFlightStaging and AppStore),
        # and the package is handed the bundle.
        packages = [p for p in (ROOT / "Packages/iOS").rglob("*.swift") if "PrivateFrameworks/" in p.read_text()]
        self.assertEqual(packages, [], "an iOS package names a PrivateFrameworks path")
        app = (ROOT / "cmux-next-ios/App/CmuxMobileApp.swift").read_text()
        self.assertIn("PrivateFrameworks/ChatKit.framework", app)
        depth = 0
        for line in app.splitlines():
            stripped = line.strip()
            if stripped == "#if !CMUX_MOBILE_PRODUCTION":
                depth += 1
            elif depth and stripped.startswith("#if"):
                depth += 1
            elif depth and stripped == "#endif":
                depth -= 1
            elif "PrivateFrameworks/" in line:
                self.assertGreater(depth, 0, f"outside #if !CMUX_MOBILE_PRODUCTION: {stripped}")
        project = (ROOT / gate.PROJECT_YML).read_text()
        for conditions in ("CMUX_MOBILE_PRODUCTION CMUX_MOBILE_TESTFLIGHT", "CMUX_MOBILE_PRODUCTION CMUX_MOBILE_APPSTORE"):
            self.assertIn(f"SWIFT_ACTIVE_COMPILATION_CONDITIONS: {conditions}", project)

    def test_pushes_and_pull_requests_fail_on_a_new_blocker(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-review-gate.yml").read_text()
        self.assertIn('--known-blockers "base/$known" --proposed-known-blockers "$known"', workflow)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", workflow)
        self.assertNotIn("ADVISORY", workflow)
        pull_request = workflow.split("  pull_request:", 1)[1].split("  workflow_dispatch:", 1)[0]
        self.assertIn('"cmux-next-ios/**"', pull_request)


class GateWorkflowTests(unittest.TestCase):
    """The report's inputs and the workflow's wiring."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_the_gate_runs_no_agent_reviewer_pass(self) -> None:
        # Every check is deterministic: no model judges the build, and the
        # report takes no agent verdict (removed 2026-11-17).
        workflow = (ROOT / ".github/workflows/ios-review-gate.yml").read_text()
        for gone in ("Agent reviewer pass", "CLAUDE_CODE_OAUTH_TOKEN", "app_review_agent_pass",
                     "--expect-agent", "--agent-skipped", "agent-findings.json", "@anthropic-ai/claude-code"):
            self.assertNotIn(gone, workflow)
        # `agent_pass` stays declared as an ignored input (main's readiness workflow still dispatches
        # with it, and GitHub refuses an undeclared input), but nothing may read its value.
        self.assertNotIn("inputs.agent_pass", workflow)
        self.assertFalse((ROOT / "cmux-next-ios/scripts/app_review_agent_pass.py").exists())
        self.assertEqual(self.report("--expect-agent")[0], 2, "the report no longer knows the agent's flags")

    def report(self, *extra: str) -> tuple[int, str]:
        out = self.root / "report.md"
        out.unlink(missing_ok=True)
        try:
            code = gate.main(["report", "--asc-skipped", *extra, "--out", str(out)])
        except SystemExit as exit:  # a flag the report does not know
            code = exit.code
        return code, out.read_text() if out.exists() else ""

    def pick(self, exit_code: int) -> tuple[int, str, list[str]]:
        picker = self.root / "picker.py"
        picker.write_text(f"import sys\nprint('SIM-UDID')\nsys.exit({exit_code})\n")
        results = self.root / f"results-{exit_code}"
        results.mkdir()
        github_env = self.root / f"env-{exit_code}"
        github_env.write_text("")
        proc = subprocess.run(
            ["bash", "-e", str(ROOT / "cmux-next-ios/scripts/app_review_pick_step.sh"), "duo"],
            env=dict(os.environ, RESULTS=str(results), GITHUB_ENV=str(github_env), PICKER=str(picker)),
            capture_output=True, text=True)
        return proc.returncode, github_env.read_text(), sorted(p.name for p in results.iterdir())

    def test_only_the_pickers_no_simulator_exit_skips_a_device(self) -> None:
        # Exit 3 is "no simulator for this family on the image": the leg
        # skips with a marker the report reads. Any other failure fails the
        # leg, so the report blocks on its missing result (#42997 review).
        self.assertEqual(self.pick(0), (0, "UDID=SIM-UDID\n", []))
        code, env, files = self.pick(3)
        self.assertEqual((code, env, files), (0, "", ["duo.skipped.json"]))
        code, env, files = self.pick(1)
        self.assertEqual((code, env, files), (1, "", []))

    def test_notes_and_verify_evidence_alone_never_start_the_gate(self) -> None:
        # cmux#43251 changed only cmux-next-ios/SECURITY.md and verify/parity-mac.md under the
        # app and still walked the reviewer path on every device.
        import yaml  # noqa: PLC0415

        doc = yaml.safe_load((ROOT / ".github/workflows/ios-review-gate.yml").read_text())
        on = doc.get("on", doc.get(True))
        for event in ("push", "pull_request"):
            patterns = on[event]["paths"]
            with self.subTest(event=event):
                for path in ("cmux-next-ios/SECURITY.md", "cmux-next-ios/verify/parity-mac.md",
                             "cmux-next-ios/verify/parity-mac/2026-11-25-find-in-terminal.md",
                             "cmux-next-ios/verify/alignment/alignscan.swift", "Packages/Shared/README.md"):
                    self.assertFalse(github_paths_match(patterns, path), path)
                for path in ("cmux-next-ios/CmuxMobileApp/App.swift", "cmux-next-ios/project.yml",
                             "cmux-next-ios/AppStoreReview/reviewer-setup.md",
                             "cmux-next-ios/AppStoreReview/known-blockers.json",
                             "Packages/Shared/CmuxTheme/Sources/X.swift", ".github/workflows/ios-review-gate.yml"):
                    self.assertTrue(github_paths_match(patterns, path), path)

    def test_a_refused_package_fetch_never_ends_a_device_leg(self) -> None:
        # Run 45746201444 lost both device legs to `swift-crypto.git: ... returned error: 403`
        # inside build-for-testing, though the kept DerivedData slot held every clone.
        import yaml  # noqa: PLC0415

        doc = yaml.safe_load((ROOT / ".github/workflows/ios-review-gate.yml").read_text())
        steps = doc["jobs"]["reviewer-path"]["steps"]
        names = [step.get("name") for step in steps]
        resolve = steps[names.index("Resolve packages")]["run"]
        build = steps[names.index("Build the app and the gate for testing")]["run"]
        self.assertLess(names.index("Resolve packages"), names.index("Build the app and the gate for testing"))
        self.assertIn("-resolvePackageDependencies", resolve)
        self.assertIn("for wait_s in 0 30 90", resolve)
        self.assertIn("resolve -skipPackageUpdates", resolve)
        self.assertIn("-skipPackageUpdates", build)
        self.assertNotIn("xcodegen generate", build)

    def test_notes_and_verify_evidence_alone_never_start_the_kit_tests(self) -> None:
        # cmux#43251 changed only cmux-next-ios/SECURITY.md and verify/parity-mac.md under the
        # app and still ran CmuxMobileKit's tests, then went red on kit tests it never touched.
        import yaml  # noqa: PLC0415

        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import ci_steps  # noqa: PLC0415

        doc = yaml.safe_load((ROOT / ".github/workflows/cmux-next-ios-kit.yml").read_text())
        on = doc.get("on", doc.get(True))
        # A push runs the workflow; a feat-cmux-next pull request runs its tests as the ios-kit table step.
        kit = ci_steps.load().steps["ios-kit"]
        matchers = {"push": lambda path: github_paths_match(on["push"]["paths"], path),
                    "pull_request": lambda path: ci_steps.routed(kit, [path])}
        for event, matches in matchers.items():
            with self.subTest(event=event):
                for path in ("cmux-next-ios/SECURITY.md", "cmux-next-ios/verify/parity-mac.md",
                             "cmux-next-ios/verify/parity-mac/2026-11-25-find-in-terminal.md",
                             "cmux-next-ios/verify/alignment/alignscan.swift",
                             "cmux-next-ios/CmuxMobileKit/README.md", "Packages/Shared/CmuxSpinner/README.md"):
                    self.assertFalse(matches(path), path)
                for path in ("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/X.swift",
                             "cmux-next-ios/CmuxMobileKit/Package.swift", "cmux-next-ios/rust/Cargo.toml",
                             "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileModel/Resources/notes.md",
                             "Packages/Shared/CmuxSpinner/Sources/CmuxSpinner/Resources/x.md",
                             "Packages/iOS/CmuxConversation/Sources/X.swift"):
                    self.assertTrue(matches(path), path)
        self.assertTrue(matchers["push"](".github/workflows/cmux-next-ios-kit.yml"))


def github_paths_match(patterns: list[str], path: str) -> bool:
    """GitHub's `paths` filter: the last pattern that matches PATH decides; a `!` one excludes it."""
    def regex(glob: str) -> str:
        out, i = [], 0
        while i < len(glob):
            if glob.startswith("**/", i):
                out.append("(?:.*/)?")
                i += 3
            elif glob.startswith("**", i):
                out.append(".*")
                i += 2
            elif glob[i] == "*":
                out.append("[^/]*")
                i += 1
            else:
                out.append(re.escape(glob[i]))
                i += 1
        return "".join(out)

    included = False
    for pattern in patterns:
        negated = pattern.startswith("!")
        if re.fullmatch(regex(pattern.removeprefix("!")), path):
            included = not negated
    return included


DEVICES_SCRIPT = ROOT / ".github/scripts/ios_review_gate_devices.py"
DEVICES_LIST = ROOT / ".github/ios-review-gate-devices.json"
PINS = ROOT / "scripts/ci/xcode-pins.txt"
PICKER = ROOT / "cmux-next-ios/scripts/app_review_pick_simulator.py"
PASSED = {"testNodes": [{"nodeType": "Test Case", "name": "testA()", "result": "Passed"}]}

# A stand-in `xcrun` for the macOS image's simctl: iPhone and iPad devices,
# and an iPhone Duo device type only with FAKE_SIM_DUO=1. A `simctl create` is
# logged to FAKE_SIM_CREATES, so a check that would create a simulator shows.
FAKE_XCRUN = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:2] == ["simctl", "create"]:
    open(os.environ["FAKE_SIM_CREATES"], "a").write(" ".join(args) + "\\n")
    print("CREATED-UDID")
    sys.exit(0)
if os.environ.get("FAKE_SIM_BROKEN") == "1":
    sys.exit(72)
types = [{"name": "iPhone 17 Pro Max", "identifier": "t.iphone"}, {"name": "iPad Pro 13-inch (M5)", "identifier": "t.ipad"}]
if os.environ.get("FAKE_SIM_DUO") == "1":
    types.append({"name": "iPhone Duo", "identifier": "t.duo"})
runtime = {"identifier": "r.ios26", "platform": "iOS", "version": "26.0", "isAvailable": True,
           "supportedDeviceTypes": [{"identifier": t["identifier"]} for t in types]}
what = args[2]
if what == "runtimes":
    print(json.dumps({"runtimes": [runtime]}))
elif what == "devices":
    print(json.dumps({"devices": {"r.ios26": [
        {"name": "iPhone 17 Pro Max", "udid": "U-IPHONE", "isAvailable": True},
        {"name": "iPad Pro 13-inch (M5)", "udid": "U-IPAD", "isAvailable": True}]}}))
elif what == "devicetypes":
    print(json.dumps({"devicetypes": types}))
else:
    sys.exit(2)
"""


class DevicePlanTests(unittest.TestCase):
    """The plan job (Linux) decides which device legs take a Mac: a family the
    image has no simulator for leaves its skip marker from the plan and never
    queues, and every leg that does run checks the plan against its image."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def script(self, *args: str, env: dict | None = None) -> subprocess.CompletedProcess:
        self.assertTrue(DEVICES_SCRIPT.is_file(), f"{DEVICES_SCRIPT.relative_to(ROOT)} decides the device legs")
        return subprocess.run([sys.executable, "-I", str(DEVICES_SCRIPT), *args], capture_output=True, text=True,
                              env=dict(os.environ, **(env or {})))

    def device_list(self) -> dict:
        self.assertTrue(DEVICES_LIST.is_file(), f"{DEVICES_LIST.relative_to(ROOT)} lists the image's simulators")
        return json.loads(DEVICES_LIST.read_text())

    def matching_pins(self, devices: dict) -> str:
        return f"# macOS  Xcode\n{devices['image']['macos']}       {devices['image']['xcode']}\n"

    def plan(self, devices: dict, pins: str, trust: str = "true") -> tuple[subprocess.CompletedProcess, dict, list]:
        devices_path = self.root / "devices.json"
        devices_path.write_text(json.dumps(devices))
        pins_path = self.root / "pins.txt"
        pins_path.write_text(pins)
        out = self.root / "planned"
        shutil.rmtree(out, ignore_errors=True)
        proc = self.script("plan", "--devices", str(devices_path), "--pins", str(pins_path), "--trust", trust,
                           "--out-dir", str(out))
        outputs = dict(line.split("=", 1) for line in proc.stdout.splitlines() if "=" in line)
        markers = sorted(p.name for p in out.iterdir()) if out.is_dir() else []
        return proc, outputs, markers

    def report(self, *args: str) -> tuple[int, str]:
        out = self.root / "report.md"
        out.unlink(missing_ok=True)
        code = gate.main(["report", "--asc-skipped", "--expect-device", "iphone", "--expect-device", "ipad",
                          "--expect-device-or-skipped", "duo", *args, "--out", str(out)])
        return code, out.read_text()

    def results(self, *families: str) -> list[str]:
        args = []
        for family in families:
            path = self.root / f"{family}.json"
            path.write_text(json.dumps(PASSED))
            args += ["--xcresult-json", str(path)]
        return args

    def test_the_plan_skips_duo_from_the_device_list_and_walks_the_rest(self) -> None:
        devices = self.device_list()
        proc, outputs, markers = self.plan(devices, self.matching_pins(devices))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(outputs["families"]), ["iphone", "ipad"])
        self.assertEqual(json.loads(outputs["skipped"]), ["duo"])
        self.assertTrue(json.loads(outputs["devices"])["decided"])
        self.assertEqual(markers, ["duo.skipped.json"])
        marker = json.loads((self.root / "planned/duo.skipped.json").read_text())
        self.assertEqual((marker["family"], marker["skipped"], marker["planned"]), ("duo", True, True))
        self.assertIn("iPhone Duo", marker["reason"])
        # A pin the list was not checked on, or another repository's image:
        # every family is walked and the legs' picker decides, as before.
        for pins, trust in ((f"{devices['image']['macos']}  99.9\n", "true"), (self.matching_pins(devices), "false")):
            proc, outputs, markers = self.plan(devices, pins, trust)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(outputs["families"]), ["iphone", "ipad", "duo"])
            self.assertFalse(json.loads(outputs["devices"])["decided"])
            self.assertEqual(markers, [])

    def test_the_checked_in_list_matches_the_pinned_xcode(self) -> None:
        # The real list against the real pins: Duo takes no Mac today. A pin
        # bump that leaves the list behind walks every family (above) and
        # this names the list to check again.
        devices = self.device_list()
        proc, outputs, _ = self.plan(devices, PINS.read_text())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        decision = json.loads(outputs["devices"])
        self.assertTrue(decision["decided"], decision.get("why"))
        self.assertEqual((decision["walk"], sorted(decision["skip"])), (["iphone", "ipad"], ["duo"]))

    def test_the_plans_duo_marker_stands_in_for_the_duo_leg(self) -> None:
        devices = self.device_list()
        proc, _, markers = self.plan(devices, self.matching_pins(devices))
        self.assertEqual((proc.returncode, markers), (0, ["duo.skipped.json"]), proc.stderr)
        code, text = self.report(*self.results("iphone", "ipad"), "--skipped", str(self.root / "planned/duo.skipped.json"))
        self.assertEqual(code, 0, text)
        self.assertIn("no duo suite result", self.report(*self.results("iphone", "ipad"))[1])

    def test_a_plan_that_drops_iphone_or_ipad_fails(self) -> None:
        for family, other in (("iphone", "ipad"), ("ipad", "iphone")):
            devices = self.device_list()
            devices["families"][family] = {"on_image": False, "reason": "not on this image"}
            proc, outputs, markers = self.plan(devices, self.matching_pins(devices))
            self.assertEqual(proc.returncode, 1, family)
            self.assertIn(f"the report requires {family}", proc.stderr)
            self.assertNotIn("families", outputs)
            self.assertEqual(markers, [])
            # A planned marker for a required family never passes the report.
            marker = self.root / f"{family}.skipped.json"
            marker.write_text(json.dumps({"family": family, "skipped": True, "planned": True, "reason": "x"}))
            duo = self.root / "duo.skipped.json"
            duo.write_text(json.dumps({"family": "duo", "skipped": True, "planned": True, "reason": "x"}))
            code, text = self.report(*self.results(other), "--skipped", str(marker), "--skipped", str(duo))
            self.assertEqual(code, 1)
            self.assertIn(f"no {family} suite result", text)

    def check(self, duo_on_image: bool, decision: dict,
              broken: bool = False) -> tuple[subprocess.CompletedProcess, Path, str]:
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        xcrun = bin_dir / "xcrun"
        xcrun.write_text(FAKE_XCRUN)
        xcrun.chmod(0o755)
        creates = self.root / "creates.log"
        creates.write_text("")
        out = self.root / "device-plan-mismatch.json"
        out.unlink(missing_ok=True)
        proc = self.script("check", "--plan", json.dumps(decision), "--picker", str(PICKER), "--out", str(out),
                           env={"PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                                "FAKE_SIM_DUO": "1" if duo_on_image else "0", "FAKE_SIM_CREATES": str(creates),
                                "FAKE_SIM_BROKEN": "1" if broken else "0"})
        return proc, out, creates.read_text()

    def test_a_leg_fails_loudly_when_the_image_disagrees_with_the_plan(self) -> None:
        skips_duo = {"decided": True, "xcode": "26.6", "walk": ["iphone", "ipad"], "skip": {"duo": "no Duo"}}
        proc, out, _ = self.check(False, skips_duo)
        self.assertEqual((proc.returncode, out.exists()), (0, False), proc.stderr)
        # The image gained the Duo the plan skipped: red, named, and nothing
        # created (the picker alone would create one).
        proc, out, creates = self.check(True, skips_duo)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("::error::the image has a duo simulator, but the plan skipped it", proc.stderr)
        self.assertEqual(json.loads(out.read_text())["mismatches"][0]["family"], "duo")
        self.assertEqual(creates, "")
        # The reverse: the plan walks Duo and the image has none.
        walks_duo = {"decided": True, "xcode": "26.6", "walk": ["iphone", "ipad", "duo"], "skip": {}}
        proc, out, _ = self.check(False, walks_duo)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("::error::the image has no duo simulator, but the plan walks it", proc.stderr)
        # A plan that decided nothing checks nothing.
        proc, out, _ = self.check(True, {"decided": False, "walk": ["iphone", "ipad", "duo"], "skip": {}})
        self.assertEqual((proc.returncode, out.exists()), (0, False))
        # A check that could not read the image is never agreement.
        proc, out, _ = self.check(False, skips_duo, broken=True)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("check could not read this image's simulators", proc.stderr)
        self.assertTrue(out.exists())
        # Nor is a plan or picker the check cannot load.
        out.unlink()
        proc = self.script("check", "--plan", "not json", "--picker", str(PICKER), "--out", str(out))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("::error::the device check could not run", proc.stderr)
        self.assertTrue(out.exists())

    def test_the_matrix_walks_only_the_plans_families(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-review-gate.yml").read_text()
        plan = workflow.split("\n  plan:\n", 1)[1].split("\n  lint:\n", 1)[0]
        reviewer = workflow.split("\n  reviewer-path:\n", 1)[1].split("\n  asc-validate:\n", 1)[0]
        report = workflow.split("\n  report:\n", 1)[1]
        self.assertIn("families: ${{ steps.devices.outputs.families }}", plan)
        self.assertIn("devices: ${{ steps.devices.outputs.devices }}", plan)
        self.assertIn(".github/scripts/ios_review_gate_devices.py plan", plan)
        self.assertIn("TRUST: ${{ github.repository_owner == 'manaflow-ai' }}", plan)
        # The planned skips reach the report through its review-gate-* download.
        self.assertIn("name: review-gate-planned-skips-${{ steps.plan.outputs.lane }}", plan)
        self.assertIn("${{ runner.temp }}/planned/*.skipped.json", plan)
        self.assertIn("        family: ${{ fromJSON(needs.plan.outputs.families) }}\n", reviewer)
        # Every leg checks the plan against its image; a mismatch fails the report.
        self.assertIn(".github/scripts/ios_review_gate_devices.py check", reviewer)
        self.assertIn('--out "$RESULTS/device-plan-mismatch.json"', reviewer)
        self.assertIn("            .github/scripts\n", reviewer)
        self.assertIn("find in -name 'device-plan-mismatch.json'", report)
        # The report's rules stay: iPhone required, Duo may skip, iPad may skip only on a pull request.
        self.assertIn("--expect-device iphone --expect-device-or-skipped duo", report)
        # iPad: required on every run but a pull request on the iPhone-only app (the plan's skip marker).
        self.assertIn('if [ "$EVENT" = pull_request ]; then args+=(--expect-device-or-skipped ipad); '
                      'else args+=(--expect-device ipad); fi', report)


class InternalSubmissionTests(unittest.TestCase):
    """cmux INTERNAL (dev.cmux.app.internal) to App Review: the builder's
    `submittable` input (off for nightlies), the gate's internal-submission
    lane, the receipt it writes on a YES, and the dispatch-only submit."""

    @staticmethod
    def workflow(name: str) -> dict:
        import yaml  # noqa: PLC0415
        return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())

    @staticmethod
    def triggers(doc: dict) -> dict:
        # PyYAML reads the bare key `on` as True.
        return doc.get("on", doc.get(True))

    def test_nightlies_stay_internal_only(self) -> None:
        doc = self.workflow("ios-internal-nightly.yml")
        submittable = self.triggers(doc)["workflow_dispatch"]["inputs"]["submittable"]
        self.assertEqual((submittable["type"], submittable["default"]), ("boolean", False))
        self.assertNotIn("submittable", (ROOT / ".github/workflows/ios-internal-nightly-trigger.yml").read_text())
        upload = next(s["run"] for s in doc["jobs"]["upload"]["steps"] if s.get("id") == "upload")
        self.assertIn("reach=(--internal-only)", upload)
        self.assertIn('[ "$SUBMITTABLE" != true ] || reach=(--submittable)', upload)

    def test_the_builder_gates_the_exact_ipa_and_writes_a_receipt_only_on_yes(self) -> None:
        jobs = self.workflow("ios-internal-nightly.yml")["jobs"]
        gate_job = jobs["review-gate"]
        self.assertEqual(gate_job["uses"], "./.github/workflows/ios-review-gate.yml")
        self.assertEqual(gate_job["with"]["lane"], "internal-submission")
        self.assertEqual(gate_job["with"]["ipa_artifact_name"], "cmux-internal-submission-ipa-${{ github.run_id }}")
        self.assertIn("inputs.submittable", gate_job["if"])
        # Run 45038240860: a called workflow gets no secret its caller does not pass, so asc validate had no key.
        asc_keys = {"ASC_API_KEY_ID", "ASC_API_ISSUER_ID", "ASC_API_KEY_P8_BASE64"}
        self.assertEqual(gate_job["secrets"], {k: f"${{{{ secrets.{k} }}}}" for k in asc_keys})
        declared = self.triggers(self.workflow("ios-review-gate.yml"))["workflow_call"]["secrets"]
        # The caller passes only the ASC key; the rest are declared for the gate's own
        # push/PR runs (routing token, R2 cache save) and stay empty when called.
        unpassed = {"GLAEDA_ROUTE_APP_KEY", "CI_CACHE_R2_ACCESS_KEY_ID",
                    "CI_CACHE_R2_SECRET_ACCESS_KEY", "CI_CACHE_R2_ACCOUNT_ID"}
        self.assertEqual(set(declared), asc_keys | unpassed)
        self.assertFalse(set(gate_job["secrets"]) & unpassed)
        receipt_if = jobs["submission-receipt"]["if"]
        for need in ("needs.review-gate.result == 'success'", "needs.review-gate.outputs.blocking == '0'",
                     "needs.review-gate.outputs.sha == inputs.sha"):
            self.assertIn(need, receipt_if)

    def test_the_gate_runs_asc_validate_for_internal_submissions_on_the_builder_branch(self) -> None:
        job = self.workflow("ios-review-gate.yml")["jobs"]["asc-validate"]
        self.assertIn("needs.plan.outputs.lane == 'internal-submission' && github.ref == 'refs/heads/rc/cnx-ios-builder'", job["if"])
        self.assertIn("vars.IOS_INTERNAL_APP_ID", job["env"]["ASC_APP_ID"])
        self.assertIn("options: [appstore, internal, internal-submission]",
                      (ROOT / ".github/workflows/ios-review-gate.yml").read_text())

    def test_the_submit_workflow_runs_only_by_hand_with_a_confirm(self) -> None:
        doc = self.workflow("ios-internal-submit.yml")
        on = self.triggers(doc)
        self.assertEqual(set(on), {"push", "workflow_dispatch"}, "no schedule, no workflow_call")
        self.assertEqual(on["push"], {"branches": ["rc/cnx-ios-builder"]})
        for name, job in doc["jobs"].items():
            self.assertIn("github.event_name == 'workflow_dispatch'", job["if"], name)
            self.assertIn("github.ref == 'refs/heads/rc/cnx-ios-builder'", job["if"], name)
        submit = doc["jobs"]["submit"]["steps"][-1]["run"]
        self.assertIn('[ "$CONFIRM" != SUBMIT ] || mode=--confirm-submit', submit)
        self.assertIn("mode=--dry-run", submit)

    def test_api_submission_keeps_release_keys_on_isolated_linux(self) -> None:
        job = self.workflow("ios-internal-submit.yml")["jobs"]["submit"]
        self.assertEqual(job["runs-on"], "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64' }}")
        self.assertEqual(job["environment"], "release")
        self.assertEqual(job["needs"], "check")
        steps = job["steps"]
        installer = next(s["run"] for s in steps if s.get("name") == "Install pinned Linux asc")
        self.assertIn("sha256sum --check --status", installer)
        self.assertLess(installer.index("sha256sum"), installer.index('"$bin/asc" --version'))
        self.assertIn("linux_$arch", installer)
        all_runs = "\n".join(s.get("run", "") for s in steps)
        self.assertNotIn("brew", all_runs)
        self.assertNotIn("select-ci-xcode", all_runs)
        self.assertIn('chmod 600 "$key_dir/AuthKey.p8"', all_runs)

    def test_the_submission_writes_cmux_internals_own_review_notes(self) -> None:
        # The INTERNAL record sells nothing: its submit writes review-notes-asc-internal.txt
        # (asc_review_package.py --config TestFlight) before it validates and submits.
        steps = self.workflow("ios-internal-submit.yml")["jobs"]["submit"]["steps"]
        self.assertIn("cmux-next-ios/AppStoreReview", steps[0]["with"]["sparse-checkout"].split())
        self.assertIn('--build-number "$BUILD_NUMBER" --config TestFlight "$mode"', steps[-1]["run"])
        script = (ROOT / "cmux-next-ios/scripts/asc_submit_review.sh").read_text()
        notes_at = script.index('asc_review_package.py" --app "$app" --config "$config" "${notes[@]}"')
        self.assertLess(notes_at, script.index("asc validate --app"))
        self.assertIn("[[ $dry_run == 0 ]] || notes+=(--dry-run)", script)
        proc = subprocess.run(["bash", str(ROOT / "cmux-next-ios/scripts/asc_submit_review.sh"), "submit", "--app", "1",
                               "--version", "1.2.0", "--build-number", "2", "--dry-run"], capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("submit needs --config AppStore or TestFlight", proc.stderr)

    def test_the_receipt_round_trips_and_refuses_another_run_or_a_blocker(self) -> None:
        nightly = self.workflow("ios-internal-nightly.yml")["jobs"]["submission-receipt"]["steps"][0]["run"]
        check = next(s["run"] for s in self.workflow("ios-internal-submit.yml")["jobs"]["check"]["steps"]
                     if s.get("id") == "receipt")
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            (tmp_path / "ipa").mkdir()
            (tmp_path / "ipa/CmuxMobileApp.ipa").write_bytes(b"ipa")
            import hashlib  # noqa: PLC0415
            ipa_sum = hashlib.sha256(b"ipa").hexdigest()
            env = dict(os.environ, RUNNER_TEMP=tmp, GITHUB_STEP_SUMMARY=str(tmp_path / "summary"), SHA="a" * 40,
                       MARKETING="1.2.0", BUILD_NUMBER="20261122120000", IPA_SHA256=ipa_sum, BLOCKING="0",
                       GITHUB_RUN_ID="123")
            self.assertEqual(subprocess.run(["bash", "-e", "-c", nightly], env=env).returncode, 0)
            receipt = tmp_path / "receipt/submission.json"

            def checked(run: str) -> tuple[int, str]:
                out = tmp_path / "out"
                out.write_text("")
                proc = subprocess.run(["bash", "-e", "-c", check], capture_output=True, text=True,
                                      env=dict(os.environ, RUNNER_TEMP=tmp, GITHUB_OUTPUT=str(out), BUILD_RUN=run))
                return proc.returncode, out.read_text()

            self.assertEqual(checked("123"), (0, f"marketing=1.2.0\nbuild_number=20261122120000\nsha={'a' * 40}\n"))
            self.assertEqual(checked("124")[0], 1, "another run's receipt")
            (tmp_path / "ipa/CmuxMobileApp.ipa").write_bytes(b"other")
            self.assertEqual(checked("123")[0], 1, "an IPA that is not the gated one")
            (tmp_path / "ipa/CmuxMobileApp.ipa").write_bytes(b"ipa")
            receipt.write_text(json.dumps(dict(json.loads(receipt.read_text()), blocking="2")))
            self.assertEqual(checked("123")[0], 1, "a gate with blockers")

    def test_scripts_refuse_an_internal_only_submission_and_a_submit_without_a_mode(self) -> None:
        proc = subprocess.run(["bash", str(ROOT / "cmux-next-ios/scripts/testflight-build.sh"), "--submittable", "--internal-only"],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("--internal-only would keep an App Store build out of App Review", proc.stderr)
        submit = ROOT / "cmux-next-ios/scripts/asc_submit_review.sh"
        for args, message in ((["submit", "--app", "6791408425", "--version", "1.2.0", "--build-number", "1"],
                               "exactly one of --dry-run or --confirm-submit"),
                              (["submit", "--app", "6791408425", "--version", "1.2.0", "--build-number", "1",
                                "--dry-run", "--confirm-submit"], "exactly one of --dry-run or --confirm-submit"),
                              (["attach", "--app", "x", "--version", "1.2.0", "--build-number", "1"], "--app must be"),
                              (["release"], "attach or submit")):
            proc = subprocess.run(["bash", str(submit), *args], capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0, args)
            self.assertIn(message, proc.stderr, args)


if __name__ == "__main__":
    unittest.main()
