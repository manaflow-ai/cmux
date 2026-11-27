#!/usr/bin/env python3
"""scripts/cmux-next/check-cef-sums.py refuses every SHA256SUMS or asset set
that would let an archive reach the cmux-cef bucket without its digest being
checked (the Codex reviews of #37825)."""
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "cmux-next", "check-cef-sums.py")


def run(*args):
    return subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True)


class CheckCefSumsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self.tmp.name, "assets")
        os.mkdir(self.dir)
        self.files = {"cef-1.0.0-cmux.1-macos-arm64.tar.xz": b"a", "cef-1.0.0-cmux.1-macos-arm64-debug.tar.xz": b"b"}
        for name, data in self.files.items():
            with open(os.path.join(self.dir, name), "wb") as f:
                f.write(data)
        self.write_sums("".join(f"{hashlib.sha256(d).hexdigest()}  {n}\n" for n, d in self.files.items()))

    def tearDown(self):
        self.tmp.cleanup()

    def write_sums(self, text):
        with open(os.path.join(self.dir, "SHA256SUMS"), "w") as f:
            f.write(text)

    def sums(self):
        return os.path.join(self.dir, "SHA256SUMS")

    def names(self, *names):
        path = os.path.join(self.tmp.name, "names")
        with open(path, "w") as f:
            f.write("\n".join(names) + "\n")
        return path

    def test_the_listed_set_passes(self):
        self.assertEqual(run("files", self.sums(), self.dir).returncode, 0)
        names = self.names(*self.files, "SHA256SUMS", "CMUX-ARTIFACT.json")
        self.assertEqual(run("names", self.sums(), names).returncode, 0)

    def test_a_trailing_space_entry_is_refused(self):
        first = next(iter(self.files))
        with open(self.sums()) as f:
            text = f.read().replace(f"{first}\n", f"{first} \n")
        self.write_sums(text)
        self.assertNotEqual(run("files", self.sums(), self.dir).returncode, 0)

    def test_a_malformed_line_is_refused(self):
        with open(self.sums(), "a") as f:
            f.write("zz  other.tar.xz\n")
        self.assertNotEqual(run("files", self.sums(), self.dir).returncode, 0)

    def test_a_duplicate_entry_is_refused(self):
        with open(self.sums()) as f:
            first_line = f.readline()
        with open(self.sums(), "a") as f:
            f.write(first_line)
        self.assertNotEqual(run("files", self.sums(), self.dir).returncode, 0)

    def test_an_unlisted_file_is_refused(self):
        for extra in ("extra.tar.xz", "cef-1.0.0-cmux.1-macos-arm64.tar.xz "):
            path = os.path.join(self.dir, extra)
            with open(path, "wb") as f:
                f.write(b"x")
            self.assertNotEqual(run("files", self.sums(), self.dir).returncode, 0, extra)
            os.remove(path)

    def test_a_replaced_archive_is_refused(self):
        with open(os.path.join(self.dir, next(iter(self.files))), "wb") as f:
            f.write(b"replaced")
        self.assertNotEqual(run("files", self.sums(), self.dir).returncode, 0)

    def test_an_unlisted_release_asset_is_refused(self):
        names = self.names(*self.files, "SHA256SUMS", "extra.tar.xz ")
        self.assertNotEqual(run("names", self.sums(), names).returncode, 0)
        names = self.names(next(iter(self.files)), "SHA256SUMS")
        self.assertNotEqual(run("names", self.sums(), names).returncode, 0)


if __name__ == "__main__":
    unittest.main()
