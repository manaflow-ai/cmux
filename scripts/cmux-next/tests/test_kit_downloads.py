"""kit_downloads: a live kit's "nothing was downloaded" check must be able to fail.

Before, pdf-live and ext-mv2-live looked only in their own folder, so against a build that saved elsewhere (a
Release build, or one from before CMUX_NEXT_DOWNLOADS_DIR) the check passed with no file looked at.
Run: python3 -m unittest scripts/cmux-next/tests/test_kit_downloads.py
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import kit_downloads  # noqa: E402


class KitDownloadsTests(unittest.TestCase):
    def setUp(self):
        # A private temporary folder for the whole test, so `remove`'s refusal is tried on a folder the test made,
        # never on a real one (HOME can be inside $TMPDIR in a sandbox).
        self.root = tempfile.mkdtemp(prefix="kit-downloads-root-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.root, ignore_errors=True))
        self.outside = os.path.join(self.root, "outside")
        os.makedirs(self.outside)
        tmp = os.path.join(self.root, "tmp")
        os.makedirs(tmp)
        saved = tempfile.tempdir
        tempfile.tempdir = tmp
        self.addCleanup(setattr, tempfile, "tempdir", saved)
        self.folder = kit_downloads.make("kit-downloads-test-")

    def test_a_build_that_reports_no_folder_gives_no_verdict(self):
        for reply in ({"downloads": []}, {"result": {"downloads": []}}, {"error": "unknown method debug.downloads"}, None):
            with self.assertRaises(kit_downloads.FolderMismatch, msg=str(reply)):
                kit_downloads.require(reply, self.folder)

    def test_a_build_that_saves_elsewhere_gives_no_verdict(self):
        with self.assertRaises(kit_downloads.FolderMismatch):
            kit_downloads.require({"downloads": [], "folder": "/Users/someone/Downloads"}, self.folder)

    def test_the_kits_folder_passes_bare_or_under_result_and_through_a_link(self):
        self.assertEqual(kit_downloads.require({"downloads": [], "folder": self.folder}, self.folder), self.folder)
        self.assertEqual(kit_downloads.require({"result": {"folder": os.path.realpath(self.folder)}}, self.folder),
                         self.folder)

    def test_remove_deletes_the_kits_folder_and_never_one_outside_the_temporary_folder(self):
        open(os.path.join(self.folder, "x.pdf"), "w").close()
        kit_downloads.remove(self.folder)
        self.assertFalse(os.path.exists(self.folder))
        kit_downloads.remove(self.outside)  # refused: not inside the temporary folder
        self.assertTrue(os.path.isdir(self.outside))
        kit_downloads.remove(tempfile.gettempdir())  # refused: the temporary folder itself
        self.assertTrue(os.path.isdir(tempfile.gettempdir()))


if __name__ == "__main__":
    unittest.main()
