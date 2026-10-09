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
        os.makedirs(os.path.join(self.box1.name, "ghostty", "include"))
        os.makedirs(os.path.join(self.box2.name, "ghostty", "include"))
        self.write(self.box1.name, "ghostty/include/a.h", "a\n")
        self.write(self.box2.name, "ghostty/include/a.h", "a\n")
        self.write(self.box2.name, "ghostty/include/b.h", "b\n")
        for path in pathlib.Path(self.box1.name).rglob("*"):
            os.utime(path, ns=(OLD, OLD))
        for top in ("cmux-tui", "ghostty"):
            os.utime(os.path.join(self.box1.name, top), ns=(OLD, OLD))
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
        # Cargo's rerun-if-changed on a directory also compares directory
        # mtimes: a directory with the same entries gets its mtime back, a
        # directory that gained or lost an entry stays fresh.
        self.assertEqual(self.mtime("ghostty/src"), OLD)
        self.assertEqual(self.mtime("ghostty"), OLD)
        self.assertGreater(self.mtime("ghostty/include"), OLD)
        self.assertGreater(self.mtime("cmux-tui/src"), OLD)

    def test_restore_never_dates_a_file_into_the_future(self) -> None:
        path = os.path.join(self.box2.name, "cmux-tui", "src", "same.rs")
        os.utime(path, ns=(OLD - 10**9, OLD - 10**9))
        run("restore", self.box2.name, self.manifest)
        self.assertEqual(self.mtime("cmux-tui/src/same.rs"), OLD - 10**9)

    def test_a_hostile_manifest_cannot_leave_the_repository_or_follow_links(self) -> None:
        outside = os.path.join(self.box1.name, "outside.txt")
        pathlib.Path(outside).write_text("fn same() {}\n", encoding="utf-8")
        os.symlink(outside, os.path.join(self.box2.name, "cmux-tui", "src", "link.rs"))
        before = os.lstat(outside).st_mtime_ns
        with open(self.manifest, "a", encoding="utf-8") as handle:
            data = b"fn same() {}\n"
            blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
            handle.write(f"F\t{blob}\t1\t../outside.txt\n")
            handle.write(f"F\t{blob}\t1\tcmux-tui/../../outside.txt\n")
            handle.write(f"F\t{blob}\t1\tcmux-tui/src/link.rs\n")
            handle.write("garbage line\n")
        run("restore", self.box2.name, self.manifest)
        self.assertEqual(os.lstat(outside).st_mtime_ns, before)

    def test_a_missing_manifest_is_a_cold_build(self) -> None:
        run("restore", self.box2.name, os.path.join(self.box2.name, "absent.tsv"))
        self.assertGreater(self.mtime("cmux-tui/src/same.rs"), OLD)


class NativeCpuOutputTests(unittest.TestCase):
    """ghostty-vt-sys builds libghostty-vt for zig's native CPU. A warm target
    dir from a Testbox on another CPU model made every test binary that links
    it die with SIGILL (tbx_01m4gb5w6fhvccqwwjj54emkss, 2026-10-09), so restore
    must drop those outputs when the CPU differs from the recording box."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = os.path.join(self.tmp.name, "repo")
        self.target = os.path.join(self.repo, "cmux-tui", "target")
        os.makedirs(os.path.join(self.repo, "cmux-tui", "src"))
        self.manifest = os.path.join(self.target, ".cmux-testbox-source-mtimes.tsv")
        self.native = [
            os.path.join(self.target, "debug", "build", "ghostty-vt-sys-1a2b"),
            os.path.join(self.target, "debug", ".fingerprint", "ghostty-vt-sys-1a2b"),
            os.path.join(self.target, "x86_64-pc-windows-gnu", "debug", "build", "ghostty-vt-sys-3c4d"),
        ]
        self.portable = os.path.join(self.target, "debug", "build", "serde-5e6f")
        for path in self.native + [self.portable]:
            os.makedirs(path)
            pathlib.Path(path, "output").write_text("x", encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def cpuinfo(self, flags: str) -> str:
        path = os.path.join(self.tmp.name, f"cpuinfo-{flags.replace(' ', '-')}")
        pathlib.Path(path).write_text(
            f"processor\t: 0\nmodel name\t: Test CPU\nflags\t\t: {flags}\n\n", encoding="utf-8"
        )
        return path

    def run_with_cpu(self, command: str, flags: str) -> None:
        subprocess.run(
            [sys.executable, "-I", str(SCRIPT), command, self.repo, self.manifest],
            check=True,
            capture_output=True,
            env={**os.environ, "CMUX_TESTBOX_CPUINFO": self.cpuinfo(flags)},
        )

    def test_same_cpu_keeps_native_outputs(self) -> None:
        self.run_with_cpu("record", "sse2 avx2 avx512f")
        self.run_with_cpu("restore", "sse2 avx2 avx512f")
        for path in self.native + [self.portable]:
            self.assertTrue(os.path.isdir(path), path)

    def test_a_different_cpu_drops_only_native_outputs(self) -> None:
        self.run_with_cpu("record", "sse2 avx2 avx512f")
        self.run_with_cpu("restore", "sse2 avx2")
        for path in self.native:
            self.assertFalse(os.path.exists(path), path)
        self.assertTrue(os.path.isdir(self.portable))

    def test_a_snapshot_without_a_cpu_record_drops_native_outputs(self) -> None:
        self.run_with_cpu("restore", "sse2 avx2")
        for path in self.native:
            self.assertFalse(os.path.exists(path), path)
        self.assertTrue(os.path.isdir(self.portable))


if __name__ == "__main__":
    unittest.main()
