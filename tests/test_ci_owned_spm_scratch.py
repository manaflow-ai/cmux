#!/usr/bin/env python3
"""Tests for scripts/ci/owned_spm_scratch.py (no network, no SwiftPM)."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))

import owned_spm_scratch as scratch  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/ci-macos.yml"


class Link(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.workspace, self.store = base / "ws", base / "store"
        self.store.mkdir()
        for package in ("Packages/Shared/A", "Packages/macOS/B", "vendor/bonsplit"):
            (self.workspace / package).mkdir(parents=True)
            (self.workspace / package / "Package.swift").write_text("// swift-tools-version:5.9\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_each_package_build_lives_outside_the_workspace_and_survives_a_clean(self):
        stale = self.workspace / "Packages/Shared/A/.build"
        stale.mkdir()
        (stale / "old").write_text("x")
        linked = scratch.link(self.workspace, self.store, "cmux11s-mac-mini-glaeda-2")
        self.assertEqual(linked, ["Packages/Shared/A", "Packages/macOS/B", "vendor/bonsplit"])
        build = self.workspace / "Packages/Shared/A/.build"
        self.assertTrue(build.is_symlink())
        (build / "product").write_text("built")
        build.unlink()  # checkout's `git clean -ffdx` removes the link, not its target
        scratch.link(self.workspace, self.store, "cmux11s-mac-mini-glaeda-2")
        self.assertEqual((build / "product").read_text(), "built")
        target = self.store / "spm-scratch/cmux11s-mac-mini-glaeda-2/Packages__Shared__A"
        self.assertEqual(build.resolve(), target.resolve())

    def test_only_owned_runners_and_an_existing_store(self):
        self.assertEqual(scratch.link(self.workspace, self.store, "blacksmith-6vcpu-1"), [])
        self.assertEqual(scratch.link(self.workspace, self.store / "missing", "x-glaeda"), [])
        self.assertFalse((self.workspace / "Packages/Shared/A/.build").exists())

    def test_prune_drops_the_least_recently_used_first(self):
        runner = self.store / "spm-scratch" / "r-glaeda"
        for index, name in enumerate(("old", "new")):
            (runner / name).mkdir(parents=True)
            (runner / name / "blob").write_bytes(b"x" * 100)
            os.utime(runner / name, (index, index))
        scratch.prune(runner, max_bytes=150)
        self.assertEqual(sorted(path.name for path in runner.iterdir()), ["new"])

    def test_the_workflow_links_before_the_package_tests(self):
        text = WORKFLOW.read_text()
        self.assertLess(text.index("owned_spm_scratch.py link"), text.index("- name: Run Bonsplit package tests"))


if __name__ == "__main__":
    unittest.main()
