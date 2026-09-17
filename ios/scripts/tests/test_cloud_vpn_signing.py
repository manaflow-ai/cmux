import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("signing", Path(__file__).parents[1] / "cloud-vpn-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class CloudVPNSigningTests(unittest.TestCase):
    def profile(self, bundle="dev.cmux.ios.vpn1"):
        return {
            "application-identifier": "TEAM." + bundle,
            "keychain-access-groups": ["TEAM.*"],
            signing.NETWORK_EXTENSION: ["packet-tunnel-provider"],
        }

    def test_host_gets_exact_groups_and_preserves_push(self):
        profile = self.profile()
        signed = {"application-identifier": profile["application-identifier"], "aps-environment": "development"}
        desired = signing.required_entitlements(profile, signed, "dev.cmux.ios.vpn1", "dev.cmux.ios.vpn1", True)
        self.assertEqual(desired["keychain-access-groups"], ["TEAM.dev.cmux.ios.vpn1", "TEAM.dev.cmux.ios.vpn1.cloud-vpn"])
        self.assertEqual(desired["aps-environment"], "development")

    def test_extension_cannot_read_host_authentication(self):
        profile = self.profile("dev.cmux.ios.vpn1.tunnel")
        desired = signing.required_entitlements(profile, profile, "dev.cmux.ios.vpn1.tunnel", "dev.cmux.ios.vpn1", False)
        self.assertEqual(desired["keychain-access-groups"], ["TEAM.dev.cmux.ios.vpn1.cloud-vpn"])

    def test_missing_capability_fails(self):
        profile = self.profile()
        del profile[signing.NETWORK_EXTENSION]
        with self.assertRaises(ValueError):
            signing.required_entitlements(profile, profile, "dev.cmux.ios.vpn1", "dev.cmux.ios.vpn1", True)

    def test_sibling_profile_fails(self):
        profile = self.profile("dev.cmux.ios.other")
        with self.assertRaises(ValueError):
            signing.required_entitlements(profile, profile, "dev.cmux.ios.vpn1", "dev.cmux.ios.vpn1", True)

    def test_shared_group_must_be_authorized(self):
        profile = self.profile()
        profile["keychain-access-groups"] = ["TEAM.dev.cmux.ios.vpn1"]
        with self.assertRaises(ValueError):
            signing.required_entitlements(profile, profile, "dev.cmux.ios.vpn1", "dev.cmux.ios.vpn1", True)


if __name__ == "__main__":
    unittest.main()
