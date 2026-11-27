#!/usr/bin/env python3
"""Tests for scripts/ci/spm_action_cache.py (no network, no SwiftPM: the manifest dump and toolchain are faked)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))

import spm_action_cache as ac  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

TOOLS = {"swift": "Swift 6.2", "xcodebuild": "Xcode 26.6", "sdk_version": "26.5", "sdk_build": "x",
         "developer_dir": "/Applications/Xcode.app/Contents/Developer", "arch": "arm64"}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env=git_fixture_env.fixture_env()).stdout


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.repo = base / "repo"
        self.root = base / "root"
        git_fixture_env.init_repo(self.repo)
        git(self.repo, "config", "user.email", "t@example.com")
        git(self.repo, "config", "user.name", "t")
        app = self.repo / "Packages/iOS/App"
        lib = self.repo / "Packages/iOS/Lib"
        other = self.repo / "Packages/iOS/Other"
        for d in (app / "Sources/App", lib / "Sources/Lib", other):
            d.mkdir(parents=True)
        (app / "Package.swift").write_text('let x = ProcessInfo.processInfo.environment["CMUX_FLAG"]\n')
        (app / "Sources/App/a.swift").write_text("let a = 1\n")
        (lib / "Package.swift").write_text("// lib\n")
        (lib / "Sources/Lib/l.swift").write_text("let l = 1\n")
        (other / "o.swift").write_text("let o = 1\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "init")
        self.app, self.lib = app, lib
        self.deps = {app.resolve(): {"dependencies": [{"fileSystem": [{"path": str(lib)}]}], "targets": []},
                     lib.resolve(): {"dependencies": [], "targets": []}}

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def dump(self, package: Path) -> dict:
        return self.deps[package.resolve()]

    def key(self, root: Path | None = None, args: list[str] | None = None) -> str:
        return ac.key_of(ac.key_inputs(self.repo, self.app, root or self.root, args or [], dump=self.dump,
                                       tools=lambda: dict(TOOLS)))


class KeyTests(Fixture):
    def test_closure_follows_local_path_dependencies_and_manifest_env(self) -> None:
        rels, envs = ac.closure(self.repo, self.app, dump=self.dump)
        self.assertEqual(rels, ["Packages/iOS/App", "Packages/iOS/Lib"])
        self.assertEqual(envs, ["CMUX_FLAG"])

    def test_same_inputs_same_key_on_another_checkout(self) -> None:
        clone = Path(self.tmp.name) / "clone"
        git_fixture_env.clone_repo(self.repo, clone, "-q")
        first = self.key()
        other = ac.key_of(ac.key_inputs(clone, clone / "Packages/iOS/App", self.root, [],
                                        dump=lambda p: {"dependencies": [{"fileSystem": [{"path": str(clone / "Packages/iOS/Lib")}]}],
                                                        "targets": []} if p.name == "App" else {"dependencies": [], "targets": []},
                                        tools=lambda: dict(TOOLS)))
        self.assertEqual(first, other)

    def test_a_dependency_change_changes_the_key_an_unrelated_one_does_not(self) -> None:
        before = self.key()
        (self.repo / "Packages/iOS/Other/o.swift").write_text("let o = 2\n")
        git(self.repo, "commit", "-qam", "other")
        self.assertEqual(before, self.key())
        (self.lib / "Sources/Lib/l.swift").write_text("let l = 2\n")
        git(self.repo, "commit", "-qam", "lib")
        self.assertNotEqual(before, self.key())

    def test_toolchain_path_env_and_args_are_in_the_key(self) -> None:
        before = self.key()
        self.assertNotEqual(before, self.key(root=Path(self.tmp.name) / "elsewhere"))
        self.assertNotEqual(before, self.key(args=["--build-tests"]))
        os.environ["CMUX_FLAG"] = "1"
        try:
            self.assertNotEqual(before, self.key())
        finally:
            del os.environ["CMUX_FLAG"]
        changed = ac.key_of(ac.key_inputs(self.repo, self.app, self.root, [], dump=self.dump,
                                          tools=lambda: {**TOOLS, "xcodebuild": "Xcode 26.7"}))
        self.assertNotEqual(before, changed)

    def test_a_dirty_tree_has_no_key(self) -> None:
        (self.lib / "Sources/Lib/l.swift").write_text("let l = 3\n")
        with self.assertRaises(ac.NoKey):
            self.key()

    def test_a_dependency_outside_the_checkout_has_no_key(self) -> None:
        self.deps[self.app.resolve()]["dependencies"][0]["fileSystem"][0]["path"] = "/nonexistent/outside"
        with self.assertRaises(ac.NoKey):
            self.key()


class StageAndRestoreTests(Fixture):
    def test_stage_writes_only_tracked_files_with_content_derived_times_and_keeps_build(self) -> None:
        (self.app / "untracked.swift").write_text("junk\n")
        kept = self.root / "Packages/iOS/App/.build"
        kept.mkdir(parents=True)
        (kept / "obj.o").write_text("o")
        rels, _ = ac.closure(self.repo, self.app, dump=self.dump)
        ac.stage(self.repo, rels, self.root)
        staged = self.root / "Packages/iOS/App/Sources/App/a.swift"
        self.assertTrue(staged.is_file())
        self.assertFalse((self.root / "Packages/iOS/App/untracked.swift").exists())
        self.assertFalse((self.root / "Packages/iOS/Other").exists())
        self.assertTrue((kept / "obj.o").is_file())
        blob = git(self.repo, "rev-parse", "HEAD:Packages/iOS/App/Sources/App/a.swift").strip()
        self.assertEqual(int(staged.stat().st_mtime), ac.blob_mtime(blob))

    def test_pack_then_restore_on_another_root_needs_the_same_key(self) -> None:
        build = self.root / "Packages/iOS/App/.build/debug"
        build.mkdir(parents=True)
        (build / "App.swiftmodule").write_text("module")
        archive = Path(self.tmp.name) / "a.tar"
        meta = ac.pack(self.root, "Packages/iOS/App", "k1", archive)
        self.assertEqual(meta["bytes"], archive.stat().st_size)
        other = Path(self.tmp.name) / "other-root"
        self.assertFalse(ac.restore(other, "Packages/iOS/App", "k2", archive))
        self.assertFalse((other / "Packages/iOS/App/.build").exists())
        self.assertTrue(ac.restore(other, "Packages/iOS/App", "k1", archive))
        self.assertEqual((other / "Packages/iOS/App/.build/debug/App.swiftmodule").read_text(), "module")

    def test_store_put_get_round_trip_and_wrong_key_misses(self) -> None:
        build = self.root / "Packages/iOS/App/.build"
        build.mkdir(parents=True)
        (build / "x").write_text("x")
        store = Path(self.tmp.name) / "store"
        ac.put(self.root, "Packages/iOS/App", "abcd", store)
        other = Path(self.tmp.name) / "r2"
        self.assertFalse(ac.get(other, "Packages/iOS/App", "abce", store))
        self.assertTrue(ac.get(other, "Packages/iOS/App", "abcd", store))
        self.assertEqual((other / "Packages/iOS/App/.build/x").read_text(), "x")
        meta = json.loads(ac.store_path(store, "abcd").with_suffix(".meta.json").read_text())
        self.assertEqual(meta["key"], "abcd")


if __name__ == "__main__":
    unittest.main()
