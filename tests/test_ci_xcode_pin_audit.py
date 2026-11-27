"""Behavioral checks for the Xcode pin audit used by fleet operators."""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import xcode_pin_audit as audit


class XcodePinAudit(unittest.TestCase):
    def test_reports_missing_pool_pin_and_wrong_version_at_variable_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            apps_dir = Path(temporary)
            old = apps_dir / "Xcode_26.3.app"
            new = apps_dir / "Xcode_26.6.app"
            for app in (old, new):
                (app / "Contents" / "Developer").mkdir(parents=True)
            with patch.object(audit, "version", side_effect=lambda app: "26.3" if app == old else "26.5"):
                errors = audit.audit({"26.3", "26.6"}, {"CMUX_CI_XCODE_APP_PR": str(new)}, apps_dir)
            self.assertIn("pool pin Xcode 26.6 is missing", errors)
            self.assertIn(f"CMUX_CI_XCODE_APP_PR={new} requires Xcode 26.6; found 26.5", errors)

    def test_accepts_symlinked_app_when_versions_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            apps_dir = Path(temporary)
            actual = apps_dir / "Xcode.app"
            newer = apps_dir / "Xcode_26.6.app"
            for app in (actual, newer):
                (app / "Contents" / "Developer").mkdir(parents=True)
            link = apps_dir / "Xcode_26.3.app"
            link.symlink_to(actual, target_is_directory=True)
            with patch.object(audit, "version", side_effect=lambda app: "26.6" if app == newer else "26.3"):
                errors = audit.audit({"26.3", "26.6"}, {"CMUX_CI_XCODE_APP_PR": str(newer)}, apps_dir)
            self.assertEqual(errors, [])

    def test_reads_pool_pins_and_rejects_invalid_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "pins"
            path.write_text("# comment\n15 26.3\n26 26.6 # pool\n")
            self.assertEqual(audit.pool_pins(path), {"26.3", "26.6"})
            path.write_text("26 wrong\n")
            with self.assertRaises(ValueError):
                audit.pool_pins(path)

    def test_exact_reports_every_xcode_off_the_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            apps_dir = Path(temporary)
            pinned, old = apps_dir / "Xcode_27.2.app", apps_dir / "Xcode_26.6.app"
            for app in (pinned, old):
                (app / "Contents" / "Developer").mkdir(parents=True)
            (apps_dir / "Xcode.app").symlink_to(pinned, target_is_directory=True)
            with patch.object(audit, "version", side_effect=lambda app: "27.2" if app.resolve() == pinned else "26.6"):
                self.assertEqual(audit.off_pin({"27.2"}, apps_dir), [
                    f"{old} is Xcode 26.6, off the fleet pin 27.2; remove it after this host's first green job on the pin"])
                shutil.rmtree(old)
                self.assertEqual(audit.off_pin({"27.2"}, apps_dir), [])

    def test_exact_holds_host_to_its_own_major_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pins, apps_dir = root / "pins", root / "apps"
            pins.write_text("15 26.3\n26 27.2\n27 27.2\n")
            old = apps_dir / "Xcode_26.3.app"
            (old / "Contents" / "Developer").mkdir(parents=True)
            with patch.object(audit, "version", return_value="26.3"), \
                    patch("builtins.print") as printed:
                code = audit.main(["--exact", "--pins-file", str(pins), "--macos-major", "27",
                                   "--applications-dir", str(apps_dir)])
            self.assertEqual(code, 1)
            lines = [call.args[0] for call in printed.call_args_list]
            self.assertTrue(any("pool pin Xcode 27.2 is missing" in line for line in lines), lines)
            self.assertTrue(any("is Xcode 26.3, off the fleet pin 27.2" in line for line in lines), lines)

    def test_real_pins_put_every_fleet_major_on_one_xcode(self):
        pins = ROOT / "scripts/ci/xcode-pins.txt"
        self.assertEqual({audit.host_pin(pins, major) for major in ("26", "27")}, {"27.2"})


if __name__ == "__main__":
    unittest.main()
