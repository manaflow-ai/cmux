"""scripts/ci/ios_ci_profiles.py: which App Store profile CI may sign with."""

import base64
import datetime as dt
import hashlib
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_spec = importlib.util.spec_from_file_location(
    "ios_ci_profiles", Path(__file__).resolve().parents[1] / "scripts/ci/ios_ci_profiles.py")
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

CI_CERT = b"ci-certificate-der"
OTHER_CERT = b"someone-elses-certificate-der"
CI_SHA1 = hashlib.sha1(CI_CERT).hexdigest().upper()
TEAM_BUNDLE = "7WLXT3NR37.dev.cmux.app.internal"


def profile(certs, days=200, app=TEAM_BUNDLE):
    return {
        "DeveloperCertificates": certs,
        "ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=days),
        "Entitlements": {"application-identifier": app},
    }


class Usable(unittest.TestCase):
    def test_a_profile_that_lists_ci_certificate_is_used(self):
        self.assertEqual(mod.usable(profile([OTHER_CERT, CI_CERT]), CI_SHA1, TEAM_BUNDLE, 3), "")

    def test_a_profile_regenerated_without_ci_certificate_is_refused_by_name(self):
        why = mod.usable(profile([OTHER_CERT]), CI_SHA1, TEAM_BUNDLE, 3)
        self.assertIn("does not list CI's certificate", why)
        self.assertIn(CI_SHA1, why)

    def test_a_profile_about_to_expire_is_regenerated(self):
        self.assertIn("expires", mod.usable(profile([CI_CERT], days=1), CI_SHA1, TEAM_BUNDLE, 3))

    def test_a_profile_for_another_bundle_is_refused(self):
        why = mod.usable(profile([CI_CERT], app="7WLXT3NR37.dev.cmux.app.demo"), CI_SHA1, TEAM_BUNDLE, 3)
        self.assertIn("not " + TEAM_BUNDLE, why)


class RegenerateSetting(unittest.TestCase):
    def test_regeneration_is_on_by_default(self):
        self.assertTrue(mod.regenerate_default({}))
        self.assertTrue(mod.regenerate_default({mod.REGENERATE_ENV: ""}))
        self.assertTrue(mod.regenerate_default({mod.REGENERATE_ENV: "1"}))

    def test_the_variable_turns_it_off(self):
        for value in ("0", "false", "No", " off "):
            self.assertFalse(mod.regenerate_default({mod.REGENERATE_ENV: value}), value)



def _tlv(tag, body):
    n = len(body)
    length = bytes([n]) if n < 0x80 else bytes([0x82]) + n.to_bytes(2, "big")
    return bytes([tag]) + length + body


def fake_cert(serial: bytes, padding=0):
    tbs = _tlv(0xA0, _tlv(0x02, b"\x02")) + _tlv(0x02, serial) + _tlv(0x30, b"x" * padding)
    return _tlv(0x30, _tlv(0x30, tbs) + _tlv(0x30, b""))


class Certificate(unittest.TestCase):
    def test_the_serial_is_read_from_the_der(self):
        self.assertEqual(mod.certificate_serial(fake_cert(bytes.fromhex("00A1B2C3"))), "A1B2C3")
        self.assertEqual(mod.certificate_serial(fake_cert(bytes.fromhex("7F01"), padding=300)), "7F01")
        self.assertEqual(mod.certificate_serial(b"\x30"), "")

    def test_ci_certificate_is_found_by_content_or_by_serial(self):
        by_content = {"data": [{"id": "OTHER", "attributes": {"serialNumber": "11"}},
                               {"id": "CI", "attributes": {"certificateContent": base64.b64encode(CI_CERT).decode()}}]}
        self.assertEqual(mod.certificate_id(by_content, CI_SHA1, "A1B2"), "CI")
        by_serial = {"data": [{"id": "OTHER", "attributes": {"serialNumber": "11"}},
                              {"id": "CI", "attributes": {"serialNumber": "00a1b2"}}]}
        self.assertEqual(mod.certificate_id(by_serial, CI_SHA1, "A1B2"), "CI")
        self.assertEqual(mod.certificate_id(by_serial, CI_SHA1, ""), "")


# Every asc call shape the script may make, as the repo's other asc caller
# (.github/scripts/install-app-store-provisioning-profile.sh) already uses it, plus
# `profiles delete`. The runner's asc may predate newer flags (--fields, list --name):
# PR #45734's first head used them and the step would have failed before any profile.
ALLOWED_ASC_FLAGS = {
    ("certificates", "list"): {"--certificate-type", "--paginate", "--output"},
    ("bundle-ids", "list"): {"--paginate", "--output"},
    ("profiles", "list"): {"--profile-type", "--paginate", "--output"},
    ("profiles", "create"): {"--name", "--profile-type", "--bundle", "--certificate", "--output"},
    ("profiles", "download"): {"--id", "--output"},
    ("profiles", "delete"): {"--id", "--confirm", "--output"},
}


class AscCalls(unittest.TestCase):
    def run_main(self, profiles, regenerate):
        calls = []

        def fake_asc_run(*args):
            calls.append(args)
            if args[:2] == ("certificates", "list"):
                return '{"data": [{"id": "CERT", "attributes": {"serialNumber": "A1B2"}}]}'
            if args[:2] == ("bundle-ids", "list"):
                return ('{"data": [' + ",".join(
                    f'{{"id": "B{i}", "attributes": {{"identifier": "{b}"}}}}' for i, b in enumerate(
                        ["dev.cmux.app.internal", "dev.cmux.app.internal.notification-content",
                         "dev.cmux.app.internal.notification-service"])) + "]}")
            if args[:2] == ("profiles", "list"):
                return profiles
            if args[:2] == ("profiles", "create"):
                return '{"data": {"id": "NEW", "attributes": {}}}'
            if args[:2] == ("profiles", "download"):
                Path(args[args.index("--output") + 1]).write_bytes(b"ci-profile")
                return ""
            return "{}"

        def fake_decode(content):
            return {**profile([CI_CERT]), "UUID": "U"}

        with tempfile.TemporaryDirectory() as out, \
                mock.patch.object(mod, "asc_run", side_effect=fake_asc_run), \
                mock.patch.object(mod, "keychain_identities", return_value=[CI_SHA1]), \
                mock.patch.object(mod, "keychain_certificate", return_value=fake_cert(bytes.fromhex("A1B2"))), \
                mock.patch.object(mod, "decode_profile", side_effect=fake_decode), \
                mock.patch.object(mod, "usable", return_value=""), \
                mock.patch.object(sys, "argv", ["ios_ci_profiles.py", "--keychain", "k", "--out-dir", out,
                                                "--github-env", str(Path(out) / "env"),
                                                "--regenerate" if regenerate else "--no-regenerate"]):
            self.assertEqual(mod.main(), 0)
            env = (Path(out) / "env").read_text()
        return calls, env

    def assert_known_shapes(self, calls):
        for args in calls:
            flags = {a for a in args if a.startswith("--")}
            self.assertIn(args[:2], ALLOWED_ASC_FLAGS, args)
            self.assertLessEqual(flags, ALLOWED_ASC_FLAGS[args[:2]], args)

    def test_fetch_uses_only_known_asc_flags(self):
        listed = '{"data": [' + ",".join(
            f'{{"id": "P{i}", "attributes": {{"name": "cmux Internal Distribution CI{s}", "profileState": "ACTIVE"}}}}'
            for i, s in enumerate(["", " Notification Content", " Notification Service"])) + "]}"
        calls, env = self.run_main(listed, regenerate=False)
        self.assert_known_shapes(calls)
        self.assertEqual([a[:2] for a in calls].count(("profiles", "create")), 0)
        self.assertIn("CMUX_MOBILE_PROFILE_PATH=", env)
        self.assertIn("CMUX_MOBILE_SERVICE_EXTENSION_PROFILE_PATH=", env)

    def test_regenerate_uses_only_known_asc_flags(self):
        listed = '{"data": [{"id": "OLD", "attributes": {"name": "cmux Internal Distribution CI", "profileState": "INVALID"}}]}'
        calls, _ = self.run_main(listed, regenerate=True)
        self.assert_known_shapes(calls)
        self.assertIn(("profiles", "delete", "--id", "OLD", "--confirm", "--output", "json"), calls)
        self.assertEqual([a[:2] for a in calls].count(("profiles", "create")), 3)


if __name__ == "__main__":
    unittest.main()
