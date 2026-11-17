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
        reviewer = workflow.split("\n  reviewer-path:\n", 1)[1].split("\n  asc-validate:\n", 1)[0]
        report = workflow.split("\n  report:\n", 1)[1]
        self.assertIn("fail-fast: false", reviewer)
        self.assertIn("        family: ${{ fromJSON(needs.plan.outputs.families) }}\n", reviewer)
        self.assertIn("name: review-gate-path-${{ env.LANE }}-${{ matrix.family }}", reviewer)
        self.assertNotIn("for family in", reviewer)
        self.assertIn("needs: [plan, lint, reviewer-path, asc-validate]", report)
        self.assertIn("pattern: review-gate-*", report)
        self.assertIn("--expect-device iphone --expect-device ipad --expect-device-or-skipped duo", report)
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
if mode in ("verdict", "no-screens", "verdict-then-crash"):
    path = re.search(r"write ONLY a JSON array to (\\S+) where", prompt).group(1)
    open(path, "w").write('[{"severity": "warning", "guideline": "4.0", "message": "m", "where": "step-01-launch.png"}]')
if mode in ("verdict", "verdict-then-crash"):
    open("step-01-launch.png", "wb").write(b"png")
print('{"result": "done"}')
sys.exit(1 if mode in ("crash", "verdict-then-crash") else 0)
"""

# The CLI's final result object (`--output-format json`) for each call, one
# STUB_CLAUDE_SCRIPT entry per call (the last repeats), counted in
# STUB_CLAUDE_CALLS. "zero-usage" is what gate run 43621274696 (job
# 132527403700) got from a rate-limited account: about 2 s, no API time, no
# tokens. "429" carries the API's status; "crash" spent real tokens and then
# failed; "verdict" writes findings and a screenshot like STUB_CLAUDE does.
STUB_CLAUDE_SCRIPTED = """#!/usr/bin/env python3
import json, os, re, sys
prompt = sys.argv[sys.argv.index("-p") + 1]
calls = os.environ["STUB_CLAUDE_CALLS"]
with open(calls, "a") as fh:
    fh.write("call\\n")
n = len(open(calls).read().splitlines())
script = os.environ["STUB_CLAUDE_SCRIPT"].split(",")
mode = script[min(n, len(script)) - 1]
base = {"type": "result", "session_id": "s", "num_turns": 1, "duration_ms": 2000}
if mode == "zero-usage":
    result = dict(base, subtype="success", is_error=False, duration_api_ms=0, stop_reason="stop_sequence",
                  total_cost_usd=0, result="", usage={"input_tokens": 0, "output_tokens": 0})
elif mode in ("429", "429-after-walk"):
    if mode == "429-after-walk":
        open("step-01-launch.png", "wb").write(b"png")
    result = dict(base, subtype="error_during_execution", is_error=True, api_error_status=429, duration_api_ms=812,
                  api_error_type="rate_limit_error", total_cost_usd=0, result="API Error: 429",
                  usage={"input_tokens": 0, "output_tokens": 0})
elif mode == "weekly":
    # The CLI's own result in gate run 43637095919 (job 132576237860), trimmed.
    result = dict(base, subtype="success", is_error=True, duration_api_ms=0, stop_reason="stop_sequence",
                  total_cost_usd=0, terminal_reason="api_error", api_error_status=429,
                  api_error_type="rate_limit_error", api_error_origin="first_party", api_error="usage_limit_reached",
                  result="You've hit your weekly limit \\u00b7 resets Nov 18 at 3am (UTC)",
                  usage={"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0})
elif mode == "crash":
    # Real API work, then a failure whose free text names a rate limit:
    # text never classifies, only the result's fields do.
    result = dict(base, subtype="error_during_execution", is_error=True, duration_api_ms=41000, total_cost_usd=0.31,
                  result="Settings shows: rate limit exceeded (429), try again later. Notes: " + prompt[-300:],
                  usage={"input_tokens": 5200, "output_tokens": 900})
else:
    path = re.search(r"write ONLY a JSON array to (\\S+) where", prompt).group(1)
    open(path, "w").write('[{"severity": "info", "guideline": "4.0", "message": "m", "where": "step-01-launch.png"}]')
    if mode != "verdict-no-screens":
        open("step-01-launch.png", "wb").write(b"png")
    result = dict(base, subtype="success", is_error=False, duration_api_ms=90000, total_cost_usd=1.2, result="done",
                  usage={"input_tokens": 9000, "output_tokens": 2000})
print(json.dumps(result))
sys.exit(0 if mode in ("verdict", "verdict-no-screens") else 1)
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
        self.saved = {k: os.environ.get(k) for k in ("PATH", "STUB_CLAUDE", "STUB_CLAUDE_SCRIPT", "STUB_CLAUDE_CALLS",
                                                     "APP_REVIEW_AGENT_RETRY_BACKOFF_S")}
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

    def test_a_verdict_written_before_the_agent_stopped_still_counts(self) -> None:
        # Out of turns after writing its findings: the verdict stands, with
        # a warning that the walk may be partial (#43045 review).
        for name in ("xcrun", "axe"):
            self.tool(name)
        self.tool("claude", STUB_CLAUDE)
        code, findings = self.run_pass("verdict-then-crash")
        self.assertEqual(code, 0)
        self.assertEqual([f["severity"] for f in findings], ["warning", "warning"])
        self.assertIn("may be incomplete", findings[1]["message"])

    def run_scripted(self, *script: str, setup: str = "") -> tuple[int, list[dict], int]:
        """The pass against STUB_CLAUDE_SCRIPTED: its exit, its findings and
        how many times it called `claude`. The backoff is 0 so no test sleeps."""
        for name in ("xcrun", "axe"):
            self.tool(name)
        self.tool("claude", STUB_CLAUDE_SCRIPTED)
        calls = self.root / "claude-calls"
        calls.unlink(missing_ok=True)
        os.environ["STUB_CLAUDE_SCRIPT"] = ",".join(script)
        os.environ["STUB_CLAUDE_CALLS"] = str(calls)
        os.environ["APP_REVIEW_AGENT_RETRY_BACKOFF_S"] = "0"
        if setup:
            (self.root / "none.md").write_text(setup)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code, findings = self.run_pass("scripted")
        self.stderr = stderr.getvalue()
        return code, findings, len(calls.read_text().splitlines()) if calls.exists() else 0

    def marker(self) -> dict | None:
        """The one `::error::agent.api-unavailable {json}` line the pass printed, parsed, or None."""
        lines = [line for line in self.stderr.splitlines() if line.startswith("::error::")]
        found = [line for line in lines if line.startswith("::error::agent.api-unavailable {")]
        if not found:
            return None
        self.assertEqual(lines, found, "the marker is the pass's only error line, so a classifier can trust it alone")
        return json.loads(found[0].removeprefix("::error::agent.api-unavailable "))

    def test_a_weekly_limit_ends_red_at_once_with_the_reset_time(self):
        # Gate run 43637095919 (job 132576237860): the account's weekly limit,
        # which a 60 s retry cannot clear, so the pass does not wait for one.
        code, findings, calls = self.run_scripted("weekly", "verdict")
        self.assertEqual(code, 1)
        self.assertEqual(calls, 1)
        self.assertEqual([(f["rule"], f["severity"]) for f in findings], [("agent.api-unavailable", "blocker")])
        message = findings[0]["message"]
        self.assertTrue(message.startswith("agent pass: API unavailable (rate limited)"), message)
        for part in ("weekly limit", "resets Nov 18 at 3am (UTC)", "api_error=usage_limit_reached", "duration_api_ms=0"):
            self.assertIn(part, message)
        marker = self.marker()
        self.assertIsNotNone(marker, self.stderr)
        self.assertEqual({k: marker.get(k) for k in ("duration_api_ms", "input_tokens", "api_error", "limit", "resets",
                                                     "attempts")},
                         {"duration_api_ms": 0, "input_tokens": 0, "api_error": "usage_limit_reached",
                          "limit": "weekly", "resets": "Nov 18 at 3am (UTC)", "attempts": 1})
        self.assertEqual(findings[0]["api"], marker)

    def test_a_rate_limited_agent_retries_once_then_ends_red_as_api_unavailable(self) -> None:
        # Gate run 43621274696 (job 132527403700): the CLI came back in about
        # 2 s with duration_api_ms 0 and no tokens, the shared account rate
        # limited, and the red read as the PR's own "no verdict".
        code, findings, calls = self.run_scripted("zero-usage", "zero-usage")
        self.assertEqual(code, 1)
        self.assertEqual(calls, 2)
        self.assertEqual([(f["rule"], f["severity"]) for f in findings], [("agent.api-unavailable", "blocker")])
        self.assertTrue(findings[0]["message"].startswith("agent pass: API unavailable (rate limited)"), findings)
        self.assertIn("duration_api_ms=0", findings[0]["message"])
        self.assertIn("input_tokens=0", findings[0]["message"])
        marker = self.marker()
        self.assertIsNotNone(marker, self.stderr)
        self.assertEqual((marker["duration_api_ms"], marker["input_tokens"], marker["attempts"]), (0, 0, 2))

    def test_a_429_then_a_real_verdict_passes_on_the_retry(self) -> None:
        code, findings, calls = self.run_scripted("429", "verdict")
        self.assertEqual(calls, 2)
        self.assertEqual(code, 0)
        self.assertEqual([(f["rule"], f["severity"]) for f in findings], [("agent.reviewer", "info")])

    def test_the_retry_needs_its_own_screenshots(self) -> None:
        # A 429 after attempt 1 took screenshots: those are set aside, so a
        # retry verdict with no walk of its own is still agent.no-walk
        # (#43238 review).
        code, findings, calls = self.run_scripted("429-after-walk", "verdict-no-screens")
        self.assertEqual(calls, 2)
        self.assertEqual(code, 1)
        self.assertEqual([f["rule"] for f in findings], ["agent.no-walk"])
        self.assertTrue((self.out / "attempt-1-step-01-launch.png").exists())

    def test_a_crash_that_spent_tokens_is_not_retried(self) -> None:
        code, findings, calls = self.run_scripted("crash", "verdict")
        self.assertEqual(calls, 1)
        self.assertEqual(code, 1)
        self.assertEqual([(f["rule"], f["severity"]) for f in findings], [("agent.no-verdict", "blocker")])

    def test_rate_limit_text_in_the_pr_or_app_never_classifies(self) -> None:
        # The reviewer notes (PR content, which the stub echoes into the
        # result text) and the agent's own text (what it read in the app)
        # both say "rate limit"; only the CLI's result fields may say the API
        # was unavailable.
        code, findings, calls = self.run_scripted(
            "crash", "verdict", setup="If you see 'rate limit exceeded' (429, overloaded), the API is unavailable.")
        self.assertEqual(calls, 1)
        self.assertEqual(code, 1)
        self.assertEqual([f["rule"] for f in findings], ["agent.no-verdict"])
        self.assertNotIn("API unavailable", findings[0]["message"])
        self.assertIsNone(self.marker())

    def test_the_report_blocks_on_an_api_unavailable_pass_as_on_no_verdict(self) -> None:
        verdicts = {}
        for rule in ("agent.no-verdict", "agent.api-unavailable"):
            path = self.root / f"{rule}.json"
            path.write_text(json.dumps([{"rule": rule, "guideline": "2.1", "severity": "blocker",
                                         "source": "agent reviewer pass", "message": "m", "where": ""}]))
            verdicts[rule] = self.report("--expect-agent", "--extra", str(path))[0]
        self.assertEqual(verdicts, {"agent.no-verdict": 1, "agent.api-unavailable": 1})

    def test_the_agent_launches_the_app_the_way_the_reviewer_walk_does(self) -> None:
        # Gate run 43591424745: the pass launched the app with no mock
        # account, so the sign-in buttons the prompt promised were the live
        # ones, and the agent stopped at sign-in with nothing else judged.
        # The walk (AppReviewGateUITests.launch) starts the mock account
        # signed out, in English, with no restored tab; the agent's first
        # launch must match it, and every relaunch the agent makes keeps the
        # mock account.
        swift = (ROOT / "cmux-next-ios/UITests/AppReviewGateUITests.swift").read_text()
        helper = swift.split("    private func launch(", 1)[1].split("\n    }\n", 1)[0]
        walk_args = re.search(r'app\.launchArguments \+= \[([^\]]*)\]\n        app\.launchEnvironment', helper).group(1)
        walk_args = re.findall(r'"([^"]*)"', walk_args)
        self.assertIn('app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"', helper)
        self.assertIn('app.launchEnvironment["CMUX_MOBILE_CLEAR_AUTH"] = "1"', helper)

        log = self.root / "calls.jsonl"
        recorder = (
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            f"open({str(log)!r}, 'a').write(json.dumps({{'tool': os.path.basename(sys.argv[0]), 'argv': sys.argv[1:],"
            " 'child': {k[13:]: v for k, v in os.environ.items() if k.startswith('SIMCTL_CHILD_')}}) + '\\n')\n"
        )
        self.tool("xcrun", recorder)
        self.tool("axe")
        self.tool("claude", recorder + STUB_CLAUDE.split("\n", 1)[1])
        code, _ = self.run_pass("verdict")
        self.assertEqual(code, 0)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        launches = [c for c in calls if c["tool"] == "xcrun" and c["argv"][:2] == ["simctl", "launch"]]
        self.assertEqual(len(launches), 1, calls)
        self.assertEqual(launches[0]["argv"], ["simctl", "launch", "UDID", "com.cmux.app", *walk_args])
        self.assertEqual(launches[0]["child"], {"CMUX_MOBILE_MOCK_AUTH": "1", "CMUX_MOBILE_CLEAR_AUTH": "1"})
        # The agent's own `xcrun simctl launch` inherits the mock account
        # but not the sign-out, so a relaunch keeps a signed-in reviewer
        # signed in.
        agent = [c for c in calls if c["tool"] == "claude"]
        self.assertEqual([c["child"] for c in agent], [{"CMUX_MOBILE_MOCK_AUTH": "1"}])
        # The prompt hands the agent the same relaunch and the mock email
        # code the app accepts (CmuxMobileAuthModel), the reviewer's path.
        prompt = agent[0]["argv"][agent[0]["argv"].index("-p") + 1]
        self.assertIn(f"xcrun simctl launch UDID com.cmux.app {shlex.join(walk_args)}", prompt)
        auth = (ROOT / "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileAuth/CmuxMobileAuthModel.swift").read_text()
        code_value = re.search(r'guard code == "(\d+)" else \{ throw AuthError\.invalidCode \}', auth).group(1)
        self.assertIn(f"code {code_value}", prompt)

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
        # Only a fork pull request (no secrets) skips; a missing token
        # anywhere else is red (#43045 review).
        self.assertIn("FORK_PULL_REQUEST: ${{ github.event_name == 'pull_request' && "
                      "github.event.pull_request.head.repo.full_name != github.repository }}", step)
        self.assertIn('if [ "$FORK_PULL_REQUEST" = true ]; then', step)
        self.assertIn("cmux-next-ios/scripts/app_review_pick_step.sh", workflow)
        report = workflow.split("\n  report:\n", 1)[1]
        self.assertIn("--expect-agent", report)
        self.assertIn("--agent-skipped", report)

    def test_notes_and_verify_evidence_alone_never_start_the_gate(self) -> None:
        # cmux#43251 changed only cmux-next-ios/SECURITY.md and verify/parity-mac.md under the
        # app and still walked the reviewer path on every device, agent pass included.
        import yaml  # noqa: PLC0415

        doc = yaml.safe_load((ROOT / ".github/workflows/ios-review-gate.yml").read_text())
        on = doc.get("on", doc.get(True))
        for event in ("push", "pull_request"):
            patterns = on[event]["paths"]
            with self.subTest(event=event):
                for path in ("cmux-next-ios/SECURITY.md", "cmux-next-ios/verify/parity-mac.md",
                             "cmux-next-ios/verify/alignment/alignscan.swift", "Packages/Shared/README.md"):
                    self.assertFalse(github_paths_match(patterns, path), path)
                for path in ("cmux-next-ios/CmuxMobileApp/App.swift", "cmux-next-ios/project.yml",
                             "cmux-next-ios/AppStoreReview/reviewer-setup.md",
                             "cmux-next-ios/AppStoreReview/known-blockers.json",
                             "Packages/Shared/Sources/X.swift", ".github/workflows/ios-review-gate.yml"):
                    self.assertTrue(github_paths_match(patterns, path), path)

    def test_notes_and_verify_evidence_alone_never_start_the_kit_tests(self) -> None:
        # cmux#43251 changed only cmux-next-ios/SECURITY.md and verify/parity-mac.md under the
        # app and still ran CmuxMobileKit's tests, then went red on kit tests it never touched.
        import yaml  # noqa: PLC0415

        doc = yaml.safe_load((ROOT / ".github/workflows/cmux-next-ios-kit.yml").read_text())
        on = doc.get("on", doc.get(True))
        for event in ("push", "pull_request"):
            patterns = on[event]["paths"]
            with self.subTest(event=event):
                for path in ("cmux-next-ios/SECURITY.md", "cmux-next-ios/verify/parity-mac.md",
                             "cmux-next-ios/verify/alignment/alignscan.swift",
                             "cmux-next-ios/CmuxMobileKit/README.md", "Packages/Shared/CmuxSpinner/README.md"):
                    self.assertFalse(github_paths_match(patterns, path), path)
                for path in ("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/X.swift",
                             "cmux-next-ios/CmuxMobileKit/Package.swift", "cmux-next-ios/rust/Cargo.toml",
                             "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileModel/Resources/notes.md",
                             "Packages/Shared/CmuxSpinner/Sources/CmuxSpinner/Resources/x.md",
                             "Packages/iOS/CmuxConversation/Sources/X.swift",
                             ".github/workflows/cmux-next-ios-kit.yml"):
                    self.assertTrue(github_paths_match(patterns, path), path)


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
        # The report's rules stay: iPhone and iPad required, only Duo may skip.
        self.assertIn("--expect-device iphone --expect-device ipad --expect-device-or-skipped duo", report)


if __name__ == "__main__":
    unittest.main()
