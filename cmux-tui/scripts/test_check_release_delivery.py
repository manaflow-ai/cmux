import datetime as dt
import unittest

from check_release_delivery import assess_delivery, newest_stable_tag, wheel_names


class ReleaseDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime(2026, 9, 16, tzinfo=dt.timezone.utc)
        self.version = "0.13.1"
        self.pypi = {
            "info": {"version": self.version},
            "releases": {
                self.version: [
                    {"filename": name, "yanked": False}
                    for name in wheel_names(self.version)
                ]
            },
        }
        self.npm = {"version": self.version}

    def assess(self, age=dt.timedelta(days=21)):
        return assess_delivery(
            self.version, self.now - age, self.pypi, self.npm, self.now, 7200
        )

    def test_forgotten_publishing_approval_is_failure_not_release_success(self):
        self.pypi = {"info": {"version": "0.12.1"}, "releases": {}}
        result = self.assess()
        self.assertEqual(result["status"], "failed")
        self.assertIn("PyPI latest is 0.12.1", " ".join(result["problems"]))

    def test_build_and_approval_grace_does_not_claim_delivery(self):
        self.pypi = {"info": {"version": "0.12.1"}, "releases": {}}
        self.assertEqual(self.assess(dt.timedelta(minutes=20))["status"], "pending")

    def test_both_registries_and_all_platform_wheels_are_required(self):
        self.assertEqual(self.assess()["status"], "complete")
        self.pypi["releases"][self.version].pop()
        result = self.assess()
        self.assertEqual(result["status"], "failed")
        self.assertIn("missing PyPI wheels", " ".join(result["problems"]))

    def test_yanked_wheel_does_not_count_as_available(self):
        self.pypi["releases"][self.version][0]["yanked"] = True
        self.assertEqual(self.assess()["status"], "failed")

    def test_pypi_success_does_not_hide_stale_npm(self):
        self.npm["version"] = "0.12.1"
        self.assertIn("npm latest is 0.12.1", " ".join(self.assess()["problems"]))

    def test_newer_registry_release_does_not_fail_older_tag_check(self):
        self.pypi["info"]["version"] = "0.14.0"
        self.npm["version"] = "0.14.0"
        self.assertEqual(self.assess()["status"], "complete")

    def test_tag_selection_uses_numeric_versions_and_ignores_prereleases(self):
        refs = [
            {"ref": "refs/tags/cmux-tui-v0.9.9"},
            {"ref": "refs/tags/cmux-tui-v0.13.1"},
            {"ref": "refs/tags/cmux-tui-v1.0.0-rc.1"},
            {"ref": "refs/tags/v5.0.0"},
        ]
        self.assertEqual(newest_stable_tag(refs), refs[1])


if __name__ == "__main__":
    unittest.main()
