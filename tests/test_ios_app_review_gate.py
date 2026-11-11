"""cmux-next-ios/scripts/app_review_gate.py: each rejection class is caught on a fixture of the
NEXT iOS app (cmux-next-ios), and the real history names detectors that exist."""

from __future__ import annotations

import importlib.util
import json
import plistlib
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

    def test_missing_account_deletion_blocks(self) -> None:
        write(self.root, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileSettings/SettingsPages.swift", 'Text("Account")\n')
        self.assertIn("account.deletion", self.rules(self.run_lint()))

    def test_external_purchase_link_blocks(self) -> None:
        write(self.root, "cmux-next-ios/App/Buy.swift", 'let u = URL(string: "https://checkout.stripe.com/x")\n')
        self.assertIn("iap.external-purchase", self.rules(self.run_lint()))

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

    def test_asc_validates_the_app_store_configurations_version(self) -> None:
        self.assertEqual(gate.marketing_version(self.root, "appstore"), "1.0.0")
        self.assertEqual(gate.marketing_version(self.root, "internal"), "1.2.0")

    def test_missing_store_metadata_is_a_clear_blocker(self) -> None:
        import shutil
        shutil.rmtree(self.root / "cmux-next-ios/AppStoreReview/metadata")
        lint = self.run_lint()
        self.assertIn("metadata.missing", self.rules(lint))
        self.assertTrue(any("cmux-next-ios/AppStoreReview/metadata" in f.message for f in lint.findings))

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

    def test_no_billing_rules_remain(self) -> None:
        # The NEXT app sells nothing: StoreKit alone must not ask for plans,
        # Restore Purchases or subscription links.
        write(self.root, "cmux-next-ios/App/Store.swift", "import StoreKit\n")
        rules = {f.rule for f in self.run_lint().findings}
        self.assertFalse({r for r in rules if r.startswith(("iap.restore", "iap.disclosure", "metadata.subscription"))}, rules)

    def test_history_detector_that_vanished_blocks(self) -> None:
        write(self.root, "cmux-next-ios/AppStoreReview/rejection-history.json",
              json.dumps({"rejections": [{"date": "d", "guideline": "2.1", "summary": "s", "detectors": ["uitest:testGone"]}]}))
        self.assertIn("history.detector-missing", self.rules(self.run_lint()))

    def test_face_id_without_purpose_string_blocks(self) -> None:
        write(self.root, "cmux-next-ios/App/Keys.swift", "import LocalAuthentication\nlet c = LAContext()\n")
        lint = gate.Lint(self.root, "appstore")
        lint.check_info_plist({"ITSAppUsesNonExemptEncryption": False}, "Info.plist")
        self.assertIn("privacy.purpose-string", self.rules(lint))

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


class RealTreeTests(unittest.TestCase):
    """The checked-in history, the NEXT app's UI tests and the gate agree."""

    def test_every_rejection_names_a_detector_that_exists_here(self) -> None:
        lint = gate.Lint(ROOT, "appstore")
        lint.check_history()
        self.assertEqual([f.message for f in lint.findings], [])

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
        self.assertFalse("Billing" in tests or "StoreKit" in tests)


if __name__ == "__main__":
    unittest.main()
