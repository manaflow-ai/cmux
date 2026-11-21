#!/usr/bin/env python3
"""side-instance.sh make with no --from refuses a default app built over 7 days ago.

cmux20's /Applications/cmux NEXT.app was a Safari download of a 2026-10-28 build that nothing updated; each side
instance copied from it read inside ~/Downloads at launch and put macOS's Downloads prompt on the fleet Mac's
unattended screen (2026-11-18). An app named with --from is copied whatever its age.
PlistBuddy, codesign, xattr and defaults are stand-ins (test_side_instance_remake_clears_old_identity.py's), so this
runs anywhere with bash and python3.
"""

import os
import plistlib
import subprocess
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_side_instance_remake_clears_old_identity as remake  # noqa: E402

SCRIPT = remake.SCRIPT
DAY = 24 * 3600


class SideInstanceStaleDefaultTests(unittest.TestCase):
    setUp = remake.SideInstanceRemakeTests.setUp
    app = remake.SideInstanceRemakeTests.app

    def default_app(self, age_days: float) -> Path:
        app = self.app("default", "com.cmuxterm.app.nightly.cmux-next", "")
        when = time.time() - age_days * DAY
        os.utime(app / "Contents/Info.plist", (when, when))
        self.env["SIDE_INSTANCE_DEFAULT_APP"] = str(app)
        return app

    def make(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(SCRIPT), "make", "probe", *args], env=self.env, capture_output=True,
                              text=True)

    def made(self) -> bool:
        return (self.tmp / "side/probe/.side-instance").is_file()

    def test_a_stale_default_app_is_refused_and_nothing_is_copied(self):
        self.default_app(21)
        result = self.make()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("built over 7 days ago", result.stderr)
        self.assertIn("--from", result.stderr)
        self.assertFalse(self.made())

    def test_a_current_default_app_is_copied(self):
        self.default_app(1)
        result = self.make()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.made())

    def test_an_old_app_named_with_from_is_copied(self):
        old = self.default_app(21)
        result = self.make("--from", str(old))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.made())


if __name__ == "__main__":
    unittest.main()
