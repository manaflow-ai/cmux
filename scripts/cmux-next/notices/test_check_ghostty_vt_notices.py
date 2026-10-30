#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for check_ghostty_vt_notices.py (stdlib unittest, git fixtures).

bin/cmux links libghostty-vt from the Ghostty tree that ghostty-vt-sys's
build.rs selects: the `ghostty` submodule at older cmux-tui pins (80b6380f),
the `ghostty-next` submodule since 8aac5e8f3cb. The check reads that choice
and the submodule commit from the cmux tree it checks, never from a constant.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_ghostty_vt_notices as vt  # noqa: E402

BUILD_RS = """fn main() {{
    let ghostty_dir = match env::var("CMUX_GHOSTTY_SRC") {{
        {arm} => manifest_dir.join("../../../{source}"),
    }};
}}
"""
UUCODE = "uucode-0.2.0-ZZjBPuuFVgC8YZ8eld4fOKsZANLIhTFMzULQxhkLi1C7"
Z2D = "z2d-0.12.1-j5P_Hsw8EQAKyZTQICCQnAH2xYkLDW8k9uefbsYdfPZ-"
SIMD = "N-V-__8AAHighwayArchiveXXXXXXXXXXXXXXXXXXXXXXXXX"
ROOT_ZON = f""".{{
    .name = .ghostty,
    .dependencies = .{{
        // A comment with .hash = "not-a-dependency"
        .uucode = .{{ .url = "https://deps.files.ghostty.org/uucode.tgz", .hash = "{UUCODE}" }},
        .z2d = .{{ .url = "https://deps.files.ghostty.org/z2d.tgz", .hash = "{Z2D}", .lazy = true }},
        .highway = .{{ .path = "./pkg/highway" }},
    }},
}}
"""
HIGHWAY_ZON = f'.{{ .name = .highway, .dependencies = .{{ .highway = .{{ .url = "https://h.tgz", .hash = "{SIMD}" }} }} }}\n'


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True).stdout.strip()


def init(path: Path) -> None:
    path.mkdir(parents=True)
    git(path, "init", "-q")
    git(path, "config", "user.email", "t@example.com")
    git(path, "config", "user.name", "t")
    git(path, "config", "commit.gpgsign", "false")


def commit_all(path: Path) -> str:
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "fixture")
    return git(path, "rev-parse", "HEAD")


class Fixture:
    """A Ghostty repository and a cmux repository whose gitlinks point at it."""

    def __init__(self, work: Path, source: str, arm: str = "_") -> None:
        self.ghostty = work / "ghostty-repo"
        init(self.ghostty)
        (self.ghostty / "pkg/highway").mkdir(parents=True)
        (self.ghostty / "build.zig.zon").write_text(ROOT_ZON)
        (self.ghostty / "pkg/highway/build.zig.zon").write_text(HIGHWAY_ZON)
        (self.ghostty / "pkg/highway/build.zig").write_text("// wrapper\n")
        (self.ghostty / "LICENSE").write_text("MIT\n")
        self.vt_commit = commit_all(self.ghostty)
        (self.ghostty / "README.md").write_text("other commit\n")
        self.other_commit = commit_all(self.ghostty)
        self.cmux = work / "cmux"
        init(self.cmux)
        crate = self.cmux / "cmux-tui/crates/ghostty-vt-sys"
        crate.mkdir(parents=True)
        (crate / "build.rs").write_text(BUILD_RS.format(arm=arm, source=source))
        git(self.cmux, "add", "-A")
        links = {"ghostty": self.other_commit, "ghostty-next": self.other_commit}
        links[source] = self.vt_commit
        for path, commit in links.items():
            git(self.cmux, "update-index", "--add", "--cacheinfo", f"160000,{commit},{path}")
        git(self.cmux, "commit", "-q", "-m", "cmux")

    def manifest(self, work: Path, packages: list[str]) -> Path:
        path = work / f"manifest-{len(packages)}.json"
        path.write_text(json.dumps({
            "schema": 1, "ghostty_revision": "a" * 40, "unresolved_packages": [],
            "license_files": [{"package": p, "source_kind": "zig-cache"} for p in packages],
            "zig_packages": {},
        }))
        return path

    def run(self, *args: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HERE / "check_ghostty_vt_notices.py"), "--repo", str(self.cmux),
             "--vt-git-dir", str(self.ghostty), *(str(a) for a in args)],
            capture_output=True, text=True,
        )


class ResolveSourceTest(unittest.TestCase):
    def test_ghostty_next_source(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = Fixture(Path(raw), "ghostty-next")
            self.assertEqual(vt.resolve_vt_source(fixture.cmux, "HEAD"), ("ghostty-next", fixture.vt_commit))

    def test_ghostty_submodule_source_at_an_old_pin(self) -> None:
        # 80b6380f's build.rs: `Err(_) => manifest_dir.join("../../../ghostty")`.
        with tempfile.TemporaryDirectory() as raw:
            fixture = Fixture(Path(raw), "ghostty", arm="Err(_)")
            self.assertEqual(vt.resolve_vt_source(fixture.cmux, "HEAD"), ("ghostty", fixture.vt_commit))

    def test_a_build_rs_without_exactly_one_source_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = Fixture(Path(raw), "ghostty-next")
            build_rs = fixture.cmux / "cmux-tui/crates/ghostty-vt-sys/build.rs"
            build_rs.write_text(build_rs.read_text() + 'let x = manifest_dir.join("../../../ghostty");\n')
            commit_all(fixture.cmux)
            with self.assertRaises(vt.CheckError):
                vt.resolve_vt_source(fixture.cmux, "HEAD")


class OverrideTest(unittest.TestCase):
    """cmux-browser builds cmux-tui with its own Ghostty pin
    (cmux-tui-ghostty-revision.txt), not the cmux gitlink."""

    def test_no_override_uses_the_gitlink(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = Fixture(Path(raw), "ghostty", arm="Err(_)")
            result = fixture.run("--print-source")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"libghostty-vt source: ghostty {fixture.vt_commit}", result.stdout)
            self.assertIn("commit source: gitlink of HEAD", result.stdout)

    def test_override_revision_wins(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = Fixture(Path(raw), "ghostty", arm="Err(_)")
            result = fixture.run("--print-source", "--ghostty-revision", fixture.other_commit)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"libghostty-vt source: ghostty {fixture.other_commit}", result.stdout)
            self.assertIn("commit source: product override (--ghostty-revision)", result.stdout)

    def test_override_file_wins(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work = Path(raw)
            fixture = Fixture(work, "ghostty", arm="Err(_)")
            pin = work / "cmux-tui-ghostty-revision.txt"
            pin.write_text(f"{fixture.other_commit}\n")
            result = fixture.run("--print-source", "--ghostty-revision-file", pin)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"libghostty-vt source: ghostty {fixture.other_commit}", result.stdout)
            self.assertIn(f"commit source: product override ({pin})", result.stdout)

    def test_override_commit_that_does_not_exist_fails(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = Fixture(Path(raw), "ghostty", arm="Err(_)")
            result = fixture.run("--print-source", "--ghostty-revision", "d" * 40)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("d" * 40, result.stderr)


class DependencyTest(unittest.TestCase):
    def test_declared_closure_follows_path_packages_and_ignores_comments(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = Fixture(Path(raw), "ghostty-next")
            deps = vt.declared_packages(fixture.ghostty, fixture.vt_commit)
            self.assertEqual({d.package_hash for d in deps}, {UUCODE, Z2D, SIMD})
            lazy = {d.package_hash: d.lazy for d in deps}
            self.assertTrue(lazy[Z2D])
            self.assertFalse(lazy[UUCODE])


class CheckTest(unittest.TestCase):
    def test_covered_ghostty_next_passes_and_prints_the_source(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work = Path(raw)
            fixture = Fixture(work, "ghostty-next")
            result = fixture.run("--license-manifest", fixture.manifest(work, [UUCODE, Z2D, SIMD]))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"libghostty-vt source: ghostty-next {fixture.vt_commit}", result.stdout)

    def test_covered_ghostty_submodule_passes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work = Path(raw)
            fixture = Fixture(work, "ghostty", arm="Err(_)")
            result = fixture.run("--license-manifest", fixture.manifest(work, [UUCODE, Z2D, SIMD]))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"libghostty-vt source: ghostty {fixture.vt_commit}", result.stdout)

    def test_an_uncovered_package_fails_and_is_named(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work = Path(raw)
            fixture = Fixture(work, "ghostty-next")
            result = fixture.run("--license-manifest", fixture.manifest(work, [Z2D, SIMD]))
            self.assertEqual(result.returncode, 1)
            self.assertIn(UUCODE, result.stderr)
            self.assertIn("uucode", result.stderr)

    def test_manifests_combine(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work = Path(raw)
            fixture = Fixture(work, "ghostty-next")
            result = fixture.run(
                "--license-manifest", fixture.manifest(work, [UUCODE]),
                "--license-manifest", fixture.manifest(work, [Z2D, SIMD, "x"]),
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_print_source_only(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            fixture = Fixture(Path(raw), "ghostty-next")
            result = fixture.run("--print-source")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines()[0], f"libghostty-vt source: ghostty-next {fixture.vt_commit}")

    def test_vendored_directories_of_the_vt_tree_are_checked(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work = Path(raw)
            fixture = Fixture(work, "ghostty-next")
            (fixture.ghostty / "pkg/newlib").mkdir()
            (fixture.ghostty / "pkg/newlib/lib.c").write_text("int f(void);\n")
            vt_commit = commit_all(fixture.ghostty)
            git(fixture.cmux, "update-index", "--cacheinfo", f"160000,{vt_commit},ghostty-next")
            git(fixture.cmux, "commit", "-q", "-m", "bump")
            result = fixture.run("--license-manifest", fixture.manifest(work, [UUCODE, Z2D, SIMD]))
            self.assertEqual(result.returncode, 1)
            self.assertIn("pkg/newlib", result.stderr)


class LinkGraphTest(unittest.TestCase):
    """--link-graph: the packages that libghostty-vt.a's DWARF names
    (vt_link_graph.py, made on a Testbox) must be declared and covered."""

    def graph(self, work: Path, fixture: Fixture, packages: dict[str, list[str]], **extra: object) -> Path:
        path = work / "vt-link-graph.json"
        targets = {
            target: {"packages": hashes, "package_files": {h: 1 for h in hashes}, "vendored": {"pkg/highway": 2},
                     "zig_lib": {"std": 10}, "ghostty_files": 100, "generated_files": 3,
                     "unattributed": list(extra.get("unattributed", [])), "names": {}, "source_paths": 120}
            for target, hashes in packages.items()
        }
        path.write_text(json.dumps({
            "schema": 1, "source": extra.get("source", "ghostty-next"), "commit": extra.get("commit", fixture.vt_commit),
            "zig": "0.16.0", "flags": ["-Demit-lib-vt=true", "-Dstrip=false"], "dwarfdump": "fixture", "targets": targets,
        }))
        return path

    def run_graph(self, *packages: str, **extra: object) -> subprocess.CompletedProcess[str]:
        work = Path(self._tmp.name)
        fixture = Fixture(work, "ghostty-next")
        graph = self.graph(work, fixture, {"aarch64-macos": [UUCODE], "x86_64-linux-musl": list(packages)}, **extra)
        return fixture.run("--license-manifest", fixture.manifest(work, [UUCODE, Z2D, SIMD]), "--link-graph", graph)

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_linked_packages_are_reported_against_the_declared_set(self) -> None:
        result = self.run_graph(SIMD)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("linked 2 of 3 declared Zig packages", result.stdout)
        self.assertIn(f"declared, not linked: z2d {Z2D}", result.stdout)

    def test_a_graph_for_another_commit_fails(self) -> None:
        result = self.run_graph(SIMD, commit="c" * 40)
        self.assertEqual(result.returncode, 1)
        self.assertIn("c" * 40, result.stderr)
        self.assertIn("vt_link_graph.py", result.stderr)

    def test_a_linked_package_that_is_not_declared_fails(self) -> None:
        result = self.run_graph("other-1.0.0-XXXX")
        self.assertEqual(result.returncode, 1)
        self.assertIn("other-1.0.0-XXXX", result.stderr)

    def test_a_linked_package_without_a_notice_fails(self) -> None:
        work = Path(self._tmp.name)
        fixture = Fixture(work, "ghostty-next")
        graph = self.graph(work, fixture, {"aarch64-macos": [UUCODE, Z2D]})
        result = fixture.run("--license-manifest", fixture.manifest(work, [UUCODE, SIMD]), "--link-graph", graph)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"linked Zig package z2d {Z2D} is in no license manifest", result.stderr)

    def test_check_link_graph_passes_for_the_gitlink_commit(self) -> None:
        work = Path(self._tmp.name)
        fixture = Fixture(work, "ghostty-next")
        result = fixture.run("--check-link-graph", self.graph(work, fixture, {"aarch64-macos": [UUCODE]}))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_gitlink_change_with_a_stale_graph_fails(self) -> None:
        # check-repo: a ghostty-next bump lands only with a regenerated graph.
        work = Path(self._tmp.name)
        fixture = Fixture(work, "ghostty-next")
        graph = self.graph(work, fixture, {"aarch64-macos": [UUCODE]})
        git(fixture.cmux, "update-index", "--cacheinfo", f"160000,{fixture.other_commit},ghostty-next")
        git(fixture.cmux, "commit", "-q", "-m", "bump ghostty-next")
        result = fixture.run("--check-link-graph", graph)
        self.assertEqual(result.returncode, 1)
        self.assertIn(fixture.other_commit, result.stderr)
        self.assertIn("vt_link_graph.py generate", result.stderr)
        self.assertIn("testbox", result.stderr.lower())

    def test_an_unattributed_source_path_fails(self) -> None:
        result = self.run_graph(SIMD, unattributed=["/opt/elsewhere/x.c"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("/opt/elsewhere/x.c", result.stderr)


if __name__ == "__main__":
    unittest.main()
