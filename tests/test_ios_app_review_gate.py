"""cmux-next-ios/scripts/app_review_gate.py: each rejection class is caught on a fixture of the
NEXT iOS app (cmux-next-ios), and the real history names detectors that exist."""

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
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

    def manifests(self, app: list[str], **extensions: list[str]) -> None:
        def body(categories: list[str]) -> str:
            return plistlib.dumps({"NSPrivacyTracking": False, "NSPrivacyAccessedAPITypes": [
                {"NSPrivacyAccessedAPIType": c, "NSPrivacyAccessedAPITypeReasons": ["X.1"]} for c in categories]}).decode()
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
        reviewer = workflow.split("\n  reviewer-path:\n", 1)[1].split("\n  walk:\n", 1)[0]
        walk = workflow.split("\n  walk:\n", 1)[1].split("\n  asc-validate:\n", 1)[0]
        report = workflow.split("\n  report:\n", 1)[1]
        # The iPad leg runs the agent pass; the phones walk in their own job.
        self.assertIn("        family: [ipad]\n", reviewer)
        self.assertIn("        family: [iphone, duo]\n", walk)
        for job in (reviewer, walk):
            self.assertIn("fail-fast: false", job)
            self.assertIn("name: Reviewer path (${{ needs.plan.outputs.lane }}, ${{ matrix.family }})", job)
            self.assertIn("name: review-gate-path-${{ env.LANE }}-${{ matrix.family }}", job)
            self.assertNotIn("for family in", job)
        self.assertIn("needs: [plan, lint, reviewer-path, walk, asc-validate]", report)
        self.assertIn("pattern: review-gate-*", report)
        self.assertIn("--expect-device iphone --expect-device ipad --expect-device-or-skipped duo", report)
        self.assertIn("find in -name '*.skipped.json'", report)

    def test_the_phone_walks_hold_no_secret_and_take_an_owned_simulator_mini(self) -> None:
        # The iPhone and Duo walks need no credential, so they take the
        # runner job's pick (an owned simulator mini when one is free)
        # instead of queueing on the ephemeral macOS pool beside the iPad
        # leg, which keeps that pool for the agent pass's token. In run
        # 43591424745 the legs waited 34 to 65 minutes there.
        import yaml
        jobs = yaml.safe_load((ROOT / ".github/workflows/ios-review-gate.yml").read_text())["jobs"]
        walk, ipad = jobs["walk"], jobs["reviewer-path"]
        self.assertNotIn("secrets.", yaml.safe_dump(walk))
        self.assertNotIn("environment", walk)
        self.assertEqual(walk["needs"], ["plan", "runner"])
        self.assertEqual(walk["runs-on"], (
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && "
            "github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-6vcpu-macos-26' || "
            "fromJSON(github.run_attempt > 1 && needs.runner.outputs.retry_runs_on || needs.runner.outputs.runs_on) }}"))
        self.assertEqual(walk["env"]["FRESH_SIMULATOR"], "1")
        remove = next(step for step in walk["steps"] if step.get("name") == "Remove the leg's simulator")
        self.assertIn("always()", remove["if"])
        self.assertIn('xcrun simctl delete "$UDID"', remove["run"])
        # The credentialed leg keeps the ephemeral pool and its environment.
        self.assertIn("fromJSON(vars.RUNNER_POOLS).macos_26", ipad["runs-on"])
        self.assertEqual(ipad["environment"]["name"], "cmux-next-development")
        self.assertEqual(ipad["strategy"]["matrix"]["family"], ["ipad"])
        pick = next(step for step in jobs["runner"]["steps"] if step.get("id") == "pool")
        self.assertIn("--lane review-gate", pick["run"])
        self.assertIn('--called "$CALLED"', pick["run"])
        # The steps the two legs share are written once (YAML anchors), so
        # the legs cannot drift apart.
        names = [step.get("name") for step in walk["steps"]]
        for step in ipad["steps"]:
            if step.get("name") not in ("Agent reviewer pass", "Upload results"):
                self.assertIn(step.get("name"), names)
                self.assertIs(step, walk["steps"][names.index(step.get("name"))], step.get("name"))

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

    def test_missing_results_and_the_agent_pass_are_judged_apart_from_the_baseline(self) -> None:
        # Fail closed: a suite that never reported is new, whatever is known.
        _, known = self.ratchet_inputs([])
        agent = self.root / "agent-findings.json"
        agent.write_text(json.dumps([{"rule": "agent", "guideline": "2.1(a)", "severity": "blocker",
                                      "source": "agent reviewer pass", "message": "m", "where": "s.png"}]))
        out = self.root / "report.md"
        self.assertEqual(gate.main(["report", "--asc-skipped", "--extra", str(agent),
                                    "--known-blockers", str(known), "--out", str(out)]), 0)
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
        self.assertFalse("Billing" in tests or "StoreKit" in tests)

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
            self.assertNotIn("agent", rule, "the agent pass is never pinned")

    def test_pushes_and_pull_requests_fail_on_a_new_blocker(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-review-gate.yml").read_text()
        self.assertIn('--known-blockers "base/$known" --proposed-known-blockers "$known"', workflow)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", workflow)
        self.assertNotIn("ADVISORY", workflow)
        pull_request = workflow.split("  pull_request:", 1)[1].split("  workflow_dispatch:", 1)[0]
        self.assertIn('"cmux-next-ios/**"', pull_request)


AGENT_SPEC = importlib.util.spec_from_file_location(
    "app_review_agent_pass", ROOT / "cmux-next-ios/scripts/app_review_agent_pass.py")
agent_pass = importlib.util.module_from_spec(AGENT_SPEC)
assert AGENT_SPEC.loader
sys.modules[AGENT_SPEC.name] = agent_pass
AGENT_SPEC.loader.exec_module(agent_pass)

# A stand-in `claude`: writes what the real agent would (a findings array to
# the path the prompt names, one screenshot per step in its folder), or
# nothing, as STUB_CLAUDE says.
STUB_CLAUDE = """#!/usr/bin/env python3
import os, re, sys
prompt = sys.argv[sys.argv.index("-p") + 1]
mode = os.environ.get("STUB_CLAUDE", "verdict")
if mode in ("verdict", "no-screens"):
    path = re.search(r"write ONLY a JSON array to (\\S+) where", prompt).group(1)
    open(path, "w").write('[{"severity": "warning", "guideline": "4.0", "message": "m", "where": "step-01-launch.png"}]')
if mode == "verdict":
    open("step-01-launch.png", "wb").write(b"png")
print('{"result": "done"}')
sys.exit(1 if mode == "crash" else 0)
"""


class AgentReviewerPassTests(unittest.TestCase):
    """The agent pass is a check: one that judged nothing is red, never a pass."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.app = self.root / "CmuxMobileApp.app"
        self.app.mkdir()
        self.out = self.root / "agent-pass"
        self.findings = self.root / "agent-findings.json"
        self.saved = {k: os.environ.get(k) for k in ("PATH", "STUB_CLAUDE")}
        self.bundle_id = agent_pass.bundle_id
        agent_pass.bundle_id = lambda app: "com.cmux.app"

    def tearDown(self) -> None:
        agent_pass.bundle_id = self.bundle_id
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def tool(self, name: str, body: str = "#!/bin/sh\nexit 0\n") -> None:
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def run_pass(self, mode: str = "verdict") -> tuple[int, list[dict]]:
        os.environ["PATH"] = f"{self.bin}{os.pathsep}/usr/bin{os.pathsep}/bin"
        os.environ["STUB_CLAUDE"] = mode
        argv = sys.argv
        sys.argv = ["app_review_agent_pass.py", "--udid", "UDID", "--app", str(self.app),
                    "--setup", str(self.root / "none.md"), "--out", str(self.out), "--findings", str(self.findings)]
        try:
            code = agent_pass.main()
        finally:
            sys.argv = argv
        return code, json.loads(self.findings.read_text())

    def test_a_pass_with_no_agent_tools_is_red(self) -> None:
        # Job 132387096997 and every run since: axe never installed, and the
        # pass wrote one warning and exited 0 in about two seconds.
        self.tool("xcrun")
        code, findings = self.run_pass()
        self.assertNotEqual(code, 0)
        self.assertEqual([(f["rule"], f["severity"]) for f in findings], [("agent.unavailable", "blocker")])

    def test_an_agent_that_left_no_verdict_is_red(self) -> None:
        for name in ("xcrun", "axe"):
            self.tool(name)
        self.tool("claude", STUB_CLAUDE)
        for mode in ("silent", "crash"):
            code, findings = self.run_pass(mode)
            self.assertNotEqual(code, 0, mode)
            self.assertIn(("agent.no-verdict", "blocker"), [(f["rule"], f["severity"]) for f in findings], mode)

    def test_an_agent_that_never_looked_at_the_app_is_red(self) -> None:
        for name in ("xcrun", "axe"):
            self.tool(name)
        self.tool("claude", STUB_CLAUDE)
        code, findings = self.run_pass("no-screens")
        self.assertNotEqual(code, 0)
        self.assertIn(("agent.no-walk", "blocker"), [(f["rule"], f["severity"]) for f in findings])

    def test_an_agent_verdict_passes_and_keeps_its_findings(self) -> None:
        for name in ("xcrun", "axe"):
            self.tool(name)
        self.tool("claude", STUB_CLAUDE)
        code, findings = self.run_pass("verdict")
        self.assertEqual(code, 0)
        self.assertEqual([(f["rule"], f["severity"], f["guideline"]) for f in findings],
                         [("agent.reviewer", "warning", "4.0")])

    def report(self, *extra: str) -> tuple[int, str]:
        out = self.root / "report.md"
        out.unlink(missing_ok=True)
        try:
            code = gate.main(["report", "--asc-skipped", *extra, "--out", str(out)])
        except SystemExit as exit:  # a flag the report does not know
            code = exit.code
        return code, out.read_text() if out.exists() else ""

    def test_the_report_blocks_when_the_expected_agent_verdict_never_arrived(self) -> None:
        code, text = self.report("--expect-agent")
        self.assertEqual(code, 1)
        self.assertIn("the agent reviewer pass left no verdict", text)
        verdict = self.root / "agent-findings.json"
        verdict.write_text("[]")
        self.assertEqual(self.report("--expect-agent", "--extra", str(verdict))[0], 0)
        # A fork pull request has no token: the pass skips by name and the
        # report says so, as a warning.
        skipped = self.root / "agent-skipped.json"
        skipped.write_text(json.dumps({"skipped": True, "reason": "no agent token for this event (fork pull request)"}))
        code, text = self.report("--expect-agent", "--agent-skipped", str(skipped))
        self.assertEqual(code, 0)
        self.assertIn("no agent token for this event", text)

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

    def test_a_fresh_leg_asks_the_picker_for_its_own_simulator(self) -> None:
        # An owned mini keeps its simulators between jobs: a leg there walks
        # a device it created, never one an earlier run signed in on.
        picker = self.root / "picker.py"
        picker.write_text("import sys\nprint(' '.join(sys.argv[1:]))\n")
        for fresh, expect in (("", "UDID=--family duo --print-udid\n"),
                              ("1", "UDID=--family duo --print-udid --fresh\n")):
            results = self.root / f"results-fresh-{fresh}"
            results.mkdir()
            github_env = self.root / f"env-fresh-{fresh}"
            github_env.write_text("")
            subprocess.run(["bash", "-e", str(ROOT / "cmux-next-ios/scripts/app_review_pick_step.sh"), "duo"],
                           env=dict(os.environ, RESULTS=str(results), GITHUB_ENV=str(github_env),
                                    PICKER=str(picker), FRESH_SIMULATOR=fresh), check=True)
            self.assertEqual(github_env.read_text(), expect)

    def test_a_fresh_pick_creates_a_device_even_when_one_exists(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "app_review_pick_simulator", ROOT / "cmux-next-ios/scripts/app_review_pick_simulator.py")
        picker = importlib.util.module_from_spec(spec)
        assert spec.loader
        spec.loader.exec_module(picker)
        runtime = {"identifier": "iOS-26-1", "version": "26.1", "platform": "iOS", "isAvailable": True}
        listings = {
            "runtimes": {"runtimes": [runtime]},
            "devices": {"devices": {"iOS-26-1": [{"name": "iPhone 17 Pro Max", "udid": "OLD"}]}},
            "devicetypes": {"devicetypes": [{"name": "iPhone 17 Pro Max", "identifier": "pro-max"}]},
        }
        created = []
        picker.simctl = lambda *args: listings[args[0]]
        picker.subprocess = type("Subprocess", (), {
            "check_output": staticmethod(lambda argv, text: created.append(argv) or "NEW\n")})
        self.assertEqual(picker.pick("iphone"), "OLD")
        self.assertEqual(created, [])
        os.environ["GITHUB_RUN_ID"] = "7"
        try:
            self.assertEqual(picker.pick("iphone", fresh=True), "NEW")
        finally:
            os.environ.pop("GITHUB_RUN_ID")
        self.assertEqual(created, [["xcrun", "simctl", "create", "cmux review gate 7 iphone",
                                    "pro-max", "iOS-26-1"]])

    def test_only_the_pickers_no_simulator_exit_skips_a_device(self) -> None:
        # Exit 3 is "no simulator for this family on the image": the leg
        # skips with a marker the report reads. Any other failure fails the
        # leg, so the report blocks on its missing result (#42997 review).
        self.assertEqual(self.pick(0), (0, "UDID=SIM-UDID\n", []))
        code, env, files = self.pick(3)
        self.assertEqual((code, env, files), (0, "", ["duo.skipped.json"]))
        code, env, files = self.pick(1)
        self.assertEqual((code, env, files), (1, "", []))

    def test_the_workflow_runs_the_agent_pass_as_a_check(self) -> None:
        workflow = (ROOT / ".github/workflows/ios-review-gate.yml").read_text()
        step = workflow.split("      - name: Agent reviewer pass\n", 1)[1].split("      - name: Upload results\n", 1)[0]
        self.assertNotIn("continue-on-error", step)
        self.assertIn("agent-skipped.json", step)
        self.assertIn("cmux-next-ios/scripts/app_review_pick_step.sh", workflow)
        report = workflow.split("\n  report:\n", 1)[1]
        self.assertIn("--expect-agent", report)
        self.assertIn("--agent-skipped", report)


if __name__ == "__main__":
    unittest.main()
