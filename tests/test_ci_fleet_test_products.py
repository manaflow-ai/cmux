#!/usr/bin/env python3
"""scripts/ci/fleet-test-products.py: the archive checks and the same-length path mapping."""
from __future__ import annotations

import importlib.util
import io
import os
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("fleet_test_products", ROOT / "scripts/ci/fleet-test-products.py")
ftp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ftp)


def archive(members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for name, kind, data in members:
            info = tarfile.TarInfo(name)
            if kind == "sym":
                info.type, info.linkname = tarfile.SYMTYPE, data
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    buf.seek(0)
    return tarfile.open(fileobj=buf)


class FleetTestProductsTests(unittest.TestCase):
    def test_members_outside_the_manifest_or_links_out_are_refused(self):
        ok = archive([("A.xctest/Contents/MacOS/A", "file", b"x"), ("F.framework/Current", "sym", "Versions/A")])
        self.assertEqual(len(list(ftp.safe_members(ok, ["A.xctest", "F.framework"]))), 2)
        for bad in ([("B.xctest/x", "file", b"x")], [("../x", "file", b"x")],
                    [("A.xctest/l", "sym", "/etc/passwd")]):
            with self.assertRaises(SystemExit):
                list(ftp.safe_members(archive(bad), ["A.xctest"]))

    def test_alias_has_src_roots_length_and_points_at_the_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = "/home/cmux/lanes/pool/cmux"
            alias = ftp.alias_for(src, Path(tmp))
            try:
                self.assertEqual(len(alias), len(src))
                self.assertEqual(os.readlink(alias), tmp)
            finally:
                os.unlink(alias)
            with self.assertRaises(SystemExit):
                ftp.alias_for("/a/b", Path(tmp))

    def test_relocate_rewrites_every_copy_in_place_and_names_the_mach_o_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "A.xctest/Contents/MacOS").mkdir(parents=True)
            old, new = b"/home/cmux/lanes/pool/cmux", b"/tmp/cmux-ftp-0123456789ab"
            binary = root / "A.xctest/Contents/MacOS/A"
            body = b"\xcf\xfa\xed\xfe" + b"\0" * 12 + old + b"/Sources/x.swift\0" + old + b"/.build\0"
            binary.write_bytes(body)
            (root / "R.bundle").mkdir()
            (root / "R.bundle/Info.plist").write_bytes(b"<string>other</string>")
            edited, machos = ftp.relocate(root, old, new)
            self.assertEqual((edited, machos), (1, [binary]))
            got = binary.read_bytes()
            self.assertEqual(len(got), len(body))
            self.assertNotIn(old, got)
            self.assertEqual(got.count(new), 2)
            self.assertEqual(ftp.bundle_of(binary, root), root / "A.xctest")


if __name__ == "__main__":
    unittest.main()
