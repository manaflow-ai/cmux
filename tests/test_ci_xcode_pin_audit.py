"""Behavioral checks for the Xcode pin audit used by fleet operators."""

from __future__ import annotations

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


if __name__ == "__main__":
    unittest.main()
