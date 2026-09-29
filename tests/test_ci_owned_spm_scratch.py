#!/usr/bin/env python3
"""Tests for scripts/ci/owned_spm_scratch.py (no network, no SwiftPM)."""

from __future__ import annotations

import fcntl
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))

import owned_spm_scratch as scratch  # noqa: E402

WORKFLOW = ROOT / ".github/workflows/ci-macos.yml"
RUNNER = "mini-glaeda-2"


def make_entry(root: Path, name: str, size: int, built: float) -> Path:
    entry = root / name
    (entry / "pkg").mkdir(parents=True)
    (entry / "pkg" / "blob").write_bytes(b"x" * size)
    os.utime(entry / "pkg" / "blob", (built, built))
    scratch.lock_path(entry).touch()
    os.utime(scratch.lock_path(entry), (built, built))  # its last use
    return entry


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.workspace, self.store = base / "ws", base / "store"
        self.store.mkdir()
        self.scratch = self.store / scratch.SCRATCH
        # A manifest outside Packages/*/* (a vendored package) gets no scratch.
        for package in ("Packages/Shared/A", "Packages/macOS/B", "vendor/vendored"):
            (self.workspace / package).mkdir(parents=True)
            (self.workspace / package / "Package.swift").write_text("// swift-tools-version:5.9\n")

    def tearDown(self):
        for holder in scratch.HOLDERS:
            holder.kill()
            holder.wait()
        scratch.HOLDERS.clear()
        self.tmp.cleanup()

    def test_each_package_build_lives_outside_the_workspace_and_survives_a_clean(self):
        stale = self.workspace / "Packages/Shared/A/.build"
        stale.mkdir()
        (stale / "old").write_text("x")
        linked = scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-a")
        self.assertEqual(linked, ["Packages/Shared/A", "Packages/macOS/B"])
        build = self.workspace / "Packages/Shared/A/.build"
        self.assertTrue(build.is_symlink())
        (build / "product").write_text("built")
        build.unlink()  # checkout's `git clean -ffdx` removes the link, not its target
        scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-a")
        self.assertEqual((build / "product").read_text(), "built")
        self.assertEqual(build.resolve(), (self.scratch / "xcode-a/Packages__Shared__A").resolve())

    def test_another_toolchain_never_reuses_the_build(self):
        scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-a")
        (self.workspace / "Packages/Shared/A/.build/product").write_text("built by a")
        scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-b")
        self.assertFalse((self.workspace / "Packages/Shared/A/.build/product").exists())

    def test_the_fingerprint_covers_the_toolchain_and_the_workspace_path(self):
        with unittest.mock.patch.object(scratch.subprocess, "run") as run:
            run.return_value = unittest.mock.Mock(stdout="Xcode 26.6\n", stderr="")
            old = scratch.toolchain_fingerprint(Path("/a"))
            self.assertNotEqual(old, scratch.toolchain_fingerprint(Path("/b")))
            run.return_value = unittest.mock.Mock(stdout="Xcode 26.7\n", stderr="")
            self.assertNotEqual(old, scratch.toolchain_fingerprint(Path("/a")))

    def test_only_owned_runners_and_an_existing_store(self):
        self.assertEqual(scratch.link(self.workspace, self.store, "blacksmith-6vcpu-1", fingerprint="x"), [])
        self.assertEqual(scratch.link(self.workspace, self.store / "missing", RUNNER, fingerprint="x"), [])
        self.assertFalse((self.workspace / "Packages/Shared/A/.build").exists())

    def test_prune_caps_the_mini_oldest_build_first_across_runners(self):
        make_entry(self.scratch, "retired-runner", 100, 1)
        make_entry(self.scratch, "current", 100, 5)
        scratch.prune(self.scratch, max_bytes=150)
        self.assertEqual([path.name for path in scratch.entries(self.scratch)], ["current"])

    def test_prune_skips_a_directory_another_job_holds(self):
        held = make_entry(self.scratch, "busy", 100, 1)
        make_entry(self.scratch, "idle", 100, 5)
        with open(scratch.lock_path(held), "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_SH)
            scratch.prune(self.scratch, max_bytes=150)
        self.assertEqual([path.name for path in scratch.entries(self.scratch)], ["busy"])

    def test_the_link_holds_its_directory_for_the_job(self):
        scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-a")
        self.assertEqual(scratch.evict(self.store), [])
        for holder in scratch.HOLDERS:
            holder.kill()
            holder.wait()
        self.assertEqual(scratch.evict(self.store), [str(self.scratch / "xcode-a")])

    def test_a_half_deleted_directory_is_never_reused_and_is_swept(self):
        make_entry(self.scratch, f"{scratch.TRASH}old-123", 10, 1)
        self.assertEqual(scratch.entries(self.scratch), [])
        scratch.prune(self.scratch)
        self.assertEqual([path for path in self.scratch.glob(f"{scratch.TRASH}*") if path.is_dir()], [])

    def test_a_size_is_measured_once_until_the_directory_is_used_again(self):
        entry = make_entry(self.scratch, "a", 100, 1)
        self.assertEqual(scratch.tree_stats(entry), (100, 1))
        with unittest.mock.patch.object(scratch, "tree_bytes", side_effect=AssertionError("walked")):
            self.assertEqual(scratch.tree_stats(entry), (100, 1))
        (entry / "pkg" / "more").write_bytes(b"x" * 50)
        os.utime(scratch.lock_path(entry))  # a later link
        self.assertEqual(scratch.tree_stats(entry)[0], 150)

    def test_a_held_directory_is_measured_but_its_size_not_recorded(self):
        entry = make_entry(self.scratch, "busy", 100, 1)
        with open(scratch.lock_path(entry), "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_SH)
            self.assertEqual(scratch.tree_stats(entry)[0], 100)
        self.assertFalse(scratch.size_path(entry).exists())

    def test_the_holder_gives_up_its_lock_after_its_bound(self):
        lock = self.scratch / "x.lock"
        self.scratch.mkdir()
        code = ("import sys; sys.path.insert(0, sys.argv[1]); import owned_spm_scratch as s; "
                "s.HOLD_SECONDS = 1; s.main(['x', 'hold', sys.argv[2]])")
        holder = subprocess.Popen([sys.executable, "-c", code, str(ROOT / "scripts/ci"), str(lock)],
                                  stdout=subprocess.PIPE, text=True)
        self.assertEqual(holder.stdout.readline().strip(), scratch.HELD)
        holder.wait(timeout=30)
        with open(lock, "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)  # free again
        holder.stdout.close()

    def test_the_workflow_links_before_the_package_tests(self):
        text = WORKFLOW.read_text()
        self.assertLess(text.index("owned_spm_scratch.py link"), text.index("run: ./scripts/ci/package-test-lane.sh run"))


if __name__ == "__main__":
    unittest.main()
