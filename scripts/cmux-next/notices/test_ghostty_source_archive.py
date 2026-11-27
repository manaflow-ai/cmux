#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for ghostty_source_archive.py (stdlib unittest; no zig, no network).

The cmux-next release source archive holds Ghostty at the build's revision
and every Ghostty Zig package the build fetched, so the MPL-2.0 source offer
does not depend on upstream URLs.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ghostty_source_archive as archive  # noqa: E402

COMMIT = "c" * 40
Z2D = "z2d-0.11.0-j5P_HtLzDwBGyQt49DrT0v4BuVqI_SRs6CXsuj7eBVhR"
OLD = "N-V-__8AAG02ugUcWec-Ndp-i7JTsJ0dgF8nnJRUInkGLG7G"


def git(cwd: Path, *args: str) -> None:
    env = {**os.environ, "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z"}
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, env=env)


class Fixture:
    def __init__(self, root: Path):
        self.source = root / "ghostty"
        self.source.mkdir()
        (self.source / "build.zig.zon").write_text(f'.{{ .name = .ghostty, .dependencies = .{{ .z2d = .{{ .url = "https://x/z2d.tar.gz", .hash = "{Z2D}" }} }} }}\n')
        (self.source / "LICENSE").write_text("ghostty MIT\n")
        (self.source / "src").mkdir()
        (self.source / "src/main.zig").write_text("pub fn main() void {}\n")
        git(self.source, "init", "-q")
        git(self.source, "-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
        git(self.source, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "fixture")
        self.revision = subprocess.run(["git", "-C", str(self.source), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
        # Zig 0.16 layout (zig-pkg, untracked) and the older cache layout (p/).
        z2d = self.source / "zig-pkg" / Z2D
        (z2d / "src").mkdir(parents=True)
        (z2d / "src/z2d.zig").write_text("// SPDX-License-Identifier: MPL-2.0\n")
        (z2d / "build.zig.zon").write_text(".{ .name = .z2d }\n")
        script = z2d / "tool.sh"
        script.write_text("#!/bin/sh\n")
        script.chmod(0o755)
        self.cache = root / "zig-cache"
        old = self.cache / "p" / OLD
        old.mkdir(parents=True)
        (old / "LICENSE").write_text("old package license\n")
        (old / "a.c").write_text("int a;\n")
        (old / "link").symlink_to("a.c")
        self.manifest = root / "SOURCE-MANIFEST.json"
        self.manifest.write_text(json.dumps({
            "schema": 1, "ghostty_revision": self.revision, "unresolved_packages": [],
            "license_files": [],
            "zig_packages": {
                Z2D: {"dependency": "z2d", "url": "https://x/z2d.tar.gz"},
                OLD: {"dependency": "old", "url": "https://x/old.tar.gz"},
            },
        }))

    def build(self, out: Path) -> int:
        return archive.main([
            "build", "--ghostty-source", str(self.source), "--zig-cache", str(self.cache),
            "--license-manifest", str(self.manifest), "--revision", self.revision,
            "--cmux-commit", COMMIT, "--tag", "cmux-next-src-ccccccccccc", "--out", str(out),
        ])

    def verify(self, out: Path) -> int:
        return archive.main(["verify", "--archive", str(out), "--license-manifest", str(self.manifest), "--revision", self.revision])


NEXT_PKG = "uucode-0.2.0-ZZjBPuuFVgC8YZ8eld4fOKsZANLIhTFMzULQxhkLi1C7"


class NextFixture:
    """A second Ghostty tree (ghostty-next, the libghostty-vt source of bin/cmux)."""

    def __init__(self, root: Path):
        self.source = root / "ghostty-next"
        self.source.mkdir()
        (self.source / "build.zig.zon").write_text(f'.{{ .name = .ghostty, .dependencies = .{{ .uucode = .{{ .url = "https://x/u.tgz", .hash = "{NEXT_PKG}" }} }} }}\n')
        (self.source / "LICENSE").write_text("ghostty MIT\n")
        git(self.source, "init", "-q")
        git(self.source, "-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
        git(self.source, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "next")
        self.revision = subprocess.run(["git", "-C", str(self.source), "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
        package = self.source / "zig-pkg" / NEXT_PKG
        package.mkdir(parents=True)
        (package / "LICENSE.md").write_text("MIT\n")
        (package / "src.zig").write_text("// uucode\n")
        self.manifest = root / "NEXT-SOURCE-MANIFEST.json"
        self.manifest.write_text(json.dumps({
            "schema": 1, "ghostty_revision": self.revision, "unresolved_packages": [],
            "license_files": [], "zig_packages": {NEXT_PKG: {"dependency": "uucode", "url": "https://x/u.tgz"}},
        }))

    def build_args(self) -> list[str]:
        return ["--next-name", "ghostty-next", "--next-source", str(self.source),
                "--next-license-manifest", str(self.manifest), "--next-revision", self.revision]

    def verify_args(self) -> list[str]:
        return ["--next-name", "ghostty-next", "--next-license-manifest", str(self.manifest),
                "--next-revision", self.revision]


class GhosttyNextSourceArchiveTest(unittest.TestCase):
    """The archive also holds the ghostty-next tree and its Zig packages."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.fx = Fixture(self.root)
        self.next = NextFixture(self.root)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def build(self, out: Path) -> int:
        return archive.main([
            "build", "--ghostty-source", str(self.fx.source), "--zig-cache", str(self.fx.cache),
            "--license-manifest", str(self.fx.manifest), "--revision", self.fx.revision,
            "--cmux-commit", COMMIT, "--tag", "cmux-next-src-ccccccccccc", "--out", str(out),
            *self.next.build_args(),
        ])

    def verify(self, out: Path) -> int:
        return archive.main(["verify", "--archive", str(out), "--license-manifest", str(self.fx.manifest),
                             "--revision", self.fx.revision, *self.next.verify_args()])

    def test_archive_holds_both_trees(self) -> None:
        out = self.root / "a.tar.gz"
        self.assertEqual(self.build(out), 0)
        self.assertEqual(self.verify(out), 0)
        p = archive.prefix(COMMIT)
        with tarfile.open(out) as tar:
            names = set(tar.getnames())
            info = json.loads(tar.extractfile(f"{p}/CORRESPONDING-SOURCE.json").read())
        self.assertIn(f"{p}/ghostty-next/build.zig.zon", names)
        self.assertIn(f"{p}/zig-packages/{NEXT_PKG}/src.zig", names)
        self.assertIn(f"{p}/zig-packages/{Z2D}/src/z2d.zig", names)
        self.assertEqual(info["ghostty_next"]["path"], "ghostty-next")
        self.assertEqual(info["ghostty_next"]["revision"], self.next.revision)
        self.assertEqual(sorted(info["ghostty_next"]["zig_packages"]), [NEXT_PKG])

    def test_verify_needs_the_second_tree(self) -> None:
        out = self.root / "a.tar.gz"
        self.assertEqual(self.fx.build(out), 0)
        self.assertNotEqual(self.verify(out), 0)

    def test_verify_needs_every_ghostty_next_package(self) -> None:
        out = self.root / "a.tar.gz"
        self.assertEqual(self.build(out), 0)
        data = json.loads(self.next.manifest.read_text())
        data["zig_packages"]["N-V-__8AAMissingNextPackageXXXXXXXXXXXXXXXXXXXXX"] = {"dependency": "m", "url": "https://x/m"}
        self.next.manifest.write_text(json.dumps(data))
        self.assertNotEqual(self.verify(out), 0)


class GhosttySourceArchiveTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.fx = Fixture(self.root)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_same_input_gives_byte_identical_archives(self) -> None:
        a, b = self.root / "a.tar.gz", self.root / "b.tar.gz"
        self.assertEqual(self.fx.build(a), 0)
        os.utime(self.fx.source / "LICENSE", (1, 1))  # mtimes must not matter
        self.assertEqual(self.fx.build(b), 0)
        self.assertEqual(hashlib.sha256(a.read_bytes()).hexdigest(), hashlib.sha256(b.read_bytes()).hexdigest())
        with tarfile.open(a) as tar:
            members = tar.getmembers()
        self.assertEqual([m.name for m in members], sorted(m.name for m in members))
        for member in members:
            self.assertEqual((member.mtime, member.uid, member.gid, member.uname, member.gname), (0, 0, 0, "", ""), member.name)

    def test_archive_holds_ghostty_and_every_zig_package(self) -> None:
        out = self.root / "a.tar.gz"
        self.assertEqual(self.fx.build(out), 0)
        self.assertEqual(self.fx.verify(out), 0)
        with tarfile.open(out) as tar:
            names = set(tar.getnames())
            info = json.loads(tar.extractfile(f"{archive.prefix(COMMIT)}/CORRESPONDING-SOURCE.json").read())
            mode = tar.getmember(f"{archive.prefix(COMMIT)}/zig-packages/{Z2D}/tool.sh").mode
            link = tar.getmember(f"{archive.prefix(COMMIT)}/zig-packages/{OLD}/link")
        p = archive.prefix(COMMIT)
        self.assertIn(f"{p}/ghostty/build.zig.zon", names)
        self.assertNotIn(f"{p}/ghostty/zig-pkg/{Z2D}/build.zig.zon", names)
        self.assertIn(f"{p}/zig-packages/{Z2D}/src/z2d.zig", names)
        self.assertIn(f"{p}/zig-packages/{OLD}/a.c", names)
        self.assertEqual(mode, 0o755)
        self.assertTrue(link.issym())
        self.assertEqual(info["ghostty_revision"], self.fx.revision)
        self.assertEqual(info["cmux_commit"], COMMIT)
        self.assertEqual(info["tag_url"], "https://github.com/manaflow-ai/cmux/tree/cmux-next-src-ccccccccccc")
        self.assertEqual(sorted(info["zig_packages"]), sorted([Z2D, OLD]))

    def test_archive_missing_a_zig_package_fails_verification(self) -> None:
        out = self.root / "a.tar.gz"
        self.assertEqual(self.fx.build(out), 0)
        data = json.loads(self.fx.manifest.read_text())
        data["zig_packages"]["N-V-__8AAMissingPackageXXXXXXXXXXXXXXXXXXXXXXXXXX"] = {"dependency": "missing", "url": "https://x/m.tar.gz"}
        self.fx.manifest.write_text(json.dumps(data))
        self.assertNotEqual(self.fx.verify(out), 0)

    def test_build_fails_when_a_package_is_not_fetched(self) -> None:
        import shutil

        shutil.rmtree(self.fx.cache / "p" / OLD)
        self.assertNotEqual(self.fx.build(self.root / "a.tar.gz"), 0)

    def test_offer_text_names_the_archive_and_the_tag(self) -> None:
        stdout = io.StringIO()
        sys_stdout, sys.stdout = sys.stdout, stdout
        try:
            code = archive.main(["offer"])
        finally:
            sys.stdout = sys_stdout
        self.assertEqual(code, 0)
        text = stdout.getvalue().strip()
        self.assertIn("cmux-next-source-<build>.tar.gz", text)
        self.assertIn("https://github.com/manaflow-ai/cmux/releases/download/nightly-next/", text)
        self.assertIn("https://github.com/manaflow-ai/cmux/tree/cmux-next-src-<commit, 11 characters>", text)
        self.assertNotIn("\n", text)


if __name__ == "__main__":
    unittest.main()
