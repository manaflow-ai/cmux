"""scripts/ci/ios_ci_profiles.py: which App Store profile CI may sign with."""

import datetime as dt
import hashlib
import importlib.util
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
