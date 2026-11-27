"""cloud-chat-matrix.py reads a shipped NIGHTLY's sign-in without `app call` (run 45882299909)."""
import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts" / "cmux-next"
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("cloud_chat_matrix", SCRIPTS / "cloud-chat-matrix.py")
MATRIX = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MATRIX)


def app_with(bundle_id: str) -> str:
    root = Path(tempfile.mkdtemp()) / "x.app"
    (root / "Contents").mkdir(parents=True)
    with open(root / "Contents/Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    return str(root)


class ShippedApp(unittest.TestCase):
    def test_nightly_is_shipped(self):
        self.assertTrue(MATRIX.shipped_app(app_with("com.cmuxterm.app.nightly")))

    def test_tagged_debug_is_not(self):
        self.assertFalse(MATRIX.shipped_app(app_with("com.cmuxterm.app.debug.ccp-1")))

    def test_missing_app_is_not(self):
        self.assertFalse(MATRIX.shipped_app(None))
        self.assertFalse(MATRIX.shipped_app("/nonexistent.app"))


if __name__ == "__main__":
    unittest.main()
