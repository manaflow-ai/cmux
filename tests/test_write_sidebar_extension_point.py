#!/usr/bin/env python3
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/write-sidebar-extension-point.sh"


class ExtensionPointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.extensions = self.root / "cmux DEV.app/Contents/Extensions"
        self.point = "com.cmuxterm.app.debug.alpha.cmux.sidebar"

    def run_script(self, point=None):
        point = self.point if point is None else point
        env = dict(os.environ, BUILT_PRODUCTS_DIR=str(self.root),
                   CONTENTS_FOLDER_PATH="cmux DEV.app/Contents",
                   CMUX_SIDEBAR_EXTENSION_POINT_ID=point)
        subprocess.run(["bash", str(SCRIPT)], env=env, check=True,
                       capture_output=True, text=True)
        return self.extensions / (point + ".appextensionpoint")

    def check_declaration(self, path, point):
        declaration = plistlib.loads(path.read_bytes())
        self.assertEqual(list(declaration), [point])
        self.assertEqual(declaration[point], {
            "_EXScopeRestriction": "none",
            "EXExtensionPointIsPublic": True,
            "EXPresentsUserInterface": True,
        })

    def test_identical_generation_preserves_file(self):
        dest = self.run_script()
        os.utime(dest, ns=(1_600_000_000_000_000_000,) * 2)
        before = dest.stat()
        directory_before = self.extensions.stat()
        original = dest.read_bytes()
        self.run_script()
        after = dest.stat()
        self.assertEqual(dest.read_bytes(), original)
        self.assertEqual(after.st_ino, before.st_ino)
        self.assertEqual(after.st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.extensions.stat().st_mtime_ns,
                         directory_before.st_mtime_ns)

    def test_changed_tag_removes_stale_declarations(self):
        previous = self.run_script()
        unrelated = self.extensions / "preserve.txt"
        unrelated.write_text("keep")
        point = "com.cmuxterm.app.debug.beta.cmux.sidebar"
        dest = self.run_script(point)
        self.check_declaration(dest, point)
        self.assertFalse(previous.exists())
        self.assertEqual(unrelated.read_text(), "keep")
        self.assertEqual(list(self.extensions.glob("*.appextensionpoint")), [dest])

    def test_missing_output_is_regenerated(self):
        dest = self.run_script()
        dest.unlink()
        self.run_script()
        self.check_declaration(dest, self.point)

    def test_corrupt_output_is_repaired(self):
        dest = self.run_script()
        dest.write_bytes(b"not a plist")
        self.run_script()
        self.check_declaration(dest, self.point)

    def test_existing_symlink_is_replaced_without_modifying_target(self):
        dest = self.run_script()
        outside = self.root / "outside.plist"
        original = dest.read_bytes()
        outside.write_bytes(original)
        dest.unlink()
        dest.symlink_to(outside)
        self.run_script()
        self.assertFalse(dest.is_symlink())
        self.assertEqual(outside.read_bytes(), original)
        self.check_declaration(dest, self.point)

    def test_stale_declaration_cleaned_with_unchanged_current_point(self):
        dest = self.run_script()
        os.utime(dest, ns=(1_600_000_000_000_000_000,) * 2)
        before = dest.stat()
        stale = self.extensions / "com.cmuxterm.stale.appextensionpoint"
        stale.write_bytes(b"stale")
        self.run_script()
        self.assertFalse(stale.exists())
        self.assertEqual(dest.stat().st_ino, before.st_ino)
        self.assertEqual(dest.stat().st_mtime_ns, before.st_mtime_ns)
        self.check_declaration(dest, self.point)

    def test_directory_symlink_is_replaced_without_touching_target(self):
        dest = self.run_script()
        outside = self.root / "outside-directory"
        outside.mkdir()
        sentinel = outside / "keep.txt"
        sentinel.write_text("keep")
        dest.unlink()
        dest.symlink_to(outside, target_is_directory=True)
        self.run_script()
        self.assertFalse(dest.is_symlink())
        self.assertEqual(list(outside.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_text(), "keep")
        self.check_declaration(dest, self.point)


if __name__ == "__main__":
    unittest.main()
