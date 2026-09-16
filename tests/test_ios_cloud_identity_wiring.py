"""Guard Cloud against restoring the removed pre-v2 connection composition."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
FEATURE = ROOT / "ios/cmuxPackage/Sources/cmuxFeature"


class CloudIdentityWiringTests(unittest.TestCase):
    def test_removed_runtime_is_not_compiled_again(self):
        self.assertFalse((FEATURE / "MobileIrohRuntimeComposition.swift").exists())

    def test_cloud_uses_the_app_owned_installation_identity(self):
        app = (ROOT / "ios/cmux/cmuxApp.swift").read_text()
        cloud = (FEATURE / "MobileCloudComposition.swift").read_text()
        self.assertIn("try? await Self.root.irx.installationDeviceID()", app)
        self.assertIn("deviceID: deviceID", cloud)
        self.assertNotIn("MobileIrohDurableDeviceIDResolver", cloud)


if __name__ == "__main__":
    unittest.main()
