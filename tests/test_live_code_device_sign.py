#!/usr/bin/env python3
"""scripts/live-code/patch.py: a patch for an iPhone (not its Simulator) is never signed ad hoc.

cmux Dev on a device loads only a patch its own team signed (CmuxLiveCode DevicePatchSignature.swift),
so patch.py refuses before the link instead of making a patch the phone refuses.
"""
import importlib.util
import os
import unittest

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
spec = importlib.util.spec_from_file_location("patch", os.path.join(ROOT, "scripts", "live-code", "patch.py"))
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class DeviceSignTests(unittest.TestCase):
    def test_a_device_target_is_told_from_the_simulator_and_the_mac(self):
        self.assertTrue(patch.is_device_target("arm64-apple-ios17.0"))
        self.assertFalse(patch.is_device_target("arm64-apple-ios17.0-simulator"))
        self.assertFalse(patch.is_device_target("arm64-apple-macos14.0"))

    def test_an_ad_hoc_device_patch_is_refused(self):
        self.assertIn("--sign", patch.device_sign_refusal("arm64-apple-ios17.0", "-"))
        self.assertIsNone(patch.device_sign_refusal("arm64-apple-ios17.0", "0123456789ABCDEF0123456789ABCDEF01234567"))
        self.assertIsNone(patch.device_sign_refusal("arm64-apple-ios17.0-simulator", "-"))
        self.assertIsNone(patch.device_sign_refusal("arm64-apple-macos14.0", "-"))


if __name__ == "__main__":
    unittest.main()
