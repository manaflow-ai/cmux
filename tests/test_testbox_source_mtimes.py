#!/usr/bin/env python3
"""The warm Testbox target dir is only correct if restore never makes a
changed source look old: Cargo would then skip rebuilding it."""

import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "blacksmith-testbox-source-mtimes.py"
OLD = 1_000_000_000 * 10**9


def run(*args: str) -> None:
    subprocess.run([sys.executable, "-I", str(SCRIPT), *args], check=True, capture_output=True)


class SourceMtimesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.box1 = tempfile.TemporaryDirectory()
        self.box2 = tempfile.TemporaryDirectory()
        self.manifest = os.path.join(self.box1.name, "manifest.tsv")
        for box in (self.box1.name, self.box2.name):
            os.makedirs(os.path.join(box, "cmux-tui", "src"))
            os.makedirs(os.path.join(box, "ghostty", "src"))
            os.makedirs(os.path.join(box, "web"))
        self.write(self.box1.name, "cmux-tui/src/same.rs", "fn same() {}\n")
        self.write(self.box1.name, "cmux-tui/src/changed.rs", "fn old() {}\n")
        self.write(self.box1.name, "ghostty/src/vt.zig", "const a = 1;\n")
        self.write(self.box1.name, "web/page.ts", "x\n")
        for path in pathlib.Path(self.box1.name).rglob("*"):
            if path.is_file():
                os.utime(path, ns=(OLD, OLD))
        run("record", self.box1.name, self.manifest)

        self.write(self.box2.name, "cmux-tui/src/same.rs", "fn same() {}\n")
        self.write(self.box2.name, "cmux-tui/src/changed.rs", "fn new() {}\n")
        self.write(self.box2.name, "cmux-tui/src/added.rs", "fn added() {}\n")
        self.write(self.box2.name, "ghostty/src/vt.zig", "const a = 1;\n")
        self.write(self.box2.name, "web/page.ts", "x\n")

    def tearDown(self) -> None:
        self.box1.cleanup()
        self.box2.cleanup()

    @staticmethod
    def write(box: str, relative: str, text: str) -> None:
        pathlib.Path(box, relative).write_text(text, encoding="utf-8")

    def mtime(self, relative: str) -> int:
        return os.lstat(os.path.join(self.box2.name, relative)).st_mtime_ns

    def test_only_identical_sources_get_their_recorded_mtime(self) -> None:
        run("restore", self.box2.name, self.manifest)
        self.assertEqual(self.mtime("cmux-tui/src/same.rs"), OLD)
        self.assertEqual(self.mtime("ghostty/src/vt.zig"), OLD)
        self.assertGreater(self.mtime("cmux-tui/src/changed.rs"), OLD)
        self.assertGreater(self.mtime("cmux-tui/src/added.rs"), OLD)
        # Only the Cargo-relevant source dirs are recorded.
        self.assertGreater(self.mtime("web/page.ts"), OLD)

    def test_a_hostile_manifest_cannot_leave_the_repository_or_follow_links(self) -> None:
        outside = os.path.join(self.box1.name, "outside.txt")
        pathlib.Path(outside).write_text("fn same() {}\n", encoding="utf-8")
        os.symlink(outside, os.path.join(self.box2.name, "cmux-tui", "src", "link.rs"))
        before = os.lstat(outside).st_mtime_ns
        with open(self.manifest, "a", encoding="utf-8") as handle:
            data = b"fn same() {}\n"
            blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
            handle.write(f"{blob}\t1\t../outside.txt\n")
            handle.write(f"{blob}\t1\tcmux-tui/../../outside.txt\n")
            handle.write(f"{blob}\t1\tcmux-tui/src/link.rs\n")
            handle.write("garbage line\n")
        run("restore", self.box2.name, self.manifest)
        self.assertEqual(os.lstat(outside).st_mtime_ns, before)

    def test_a_missing_manifest_is_a_cold_build(self) -> None:
        run("restore", self.box2.name, os.path.join(self.box2.name, "absent.tsv"))
        self.assertGreater(self.mtime("cmux-tui/src/same.rs"), OLD)


if __name__ == "__main__":
    unittest.main()
