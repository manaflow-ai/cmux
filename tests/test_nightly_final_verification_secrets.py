#!/usr/bin/env python3
"""The consolidated verification phase cannot precede another secret use."""
import unittest

from test_ci_signing_keychain_is_deleted_before_bundle_code import check_job


class FinalVerificationTests(unittest.TestCase):
    def job(self):
        return {
            "environment": "release-next",
            "runs-on": "blacksmith-6vcpu-macos-26",
            "steps": [
                {"run": "scripts/ci/signing-keychain.sh create", "env": {
                    "APPLE_CERTIFICATE_BASE64": "${{ secrets.APPLE_CERTIFICATE_BASE64 }}"}},
                {"run": "scripts/ci/signing-keychain.sh delete", "if": "always()"},
                {"run": 'scripts/verify-diff-sidecar-artifact.sh "$APP" --require-signed'},
            ],
        }

    def verdict(self, job, name="nightly.yml build-sign-notarize-nightly"):
        failures = []
        check_job(name, job, failures)
        return failures

    def test_final_phase_passes(self):
        self.assertEqual(self.verdict(self.job()), [])

    def test_secret_after_verification_is_rejected_even_with_condition(self):
        job = self.job()
        job["steps"].append({"if": "always()", "run": "publish", "env": {
            "KEY": "${{ secrets.SPARKLE_PRIVATE_KEY }}"}})
        self.assertTrue(any("holds secrets" in f for f in self.verdict(job)))

    def test_keychain_must_be_deleted_before_verification(self):
        job = self.job()
        job["steps"][1], job["steps"][2] = job["steps"][2], job["steps"][1]
        self.assertTrue(self.verdict(job))

    def test_same_step_secret_is_rejected(self):
        job = self.job()
        job["steps"][-1]["env"] = {"KEY": "${{ secrets.ASC_API_KEY_P8_BASE64 }}"}
        self.assertTrue(any("holds secrets" in f for f in self.verdict(job)))

    def test_exception_does_not_apply_to_other_jobs(self):
        self.assertTrue(any("holds secrets" in f for f in self.verdict(self.job(), "other.yml sign")))


if __name__ == "__main__":
    unittest.main()
