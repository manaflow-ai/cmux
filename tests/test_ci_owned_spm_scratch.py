#!/usr/bin/env python3
"""Tests for scripts/ci/owned_spm_scratch.py (no network, no SwiftPM)."""

from __future__ import annotations

import fcntl
import json
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
NEXT_WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
RUNNER = "mini-glaeda-2"


def make_entry(root: Path, name: str, size: int, built: float) -> Path:
    entry = root / name
    (entry / "pkg").mkdir(parents=True)
    (entry / "pkg" / "blob").write_bytes(b"x" * size)
    os.utime(entry / "pkg" / "blob", (built, built))
    scratch.lock_path(entry).touch()
    os.utime(scratch.lock_path(entry), (built, built))  # its last use
    return entry


def git(workspace: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(workspace), *args], check=True, capture_output=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                        "GIT_COMMITTER_EMAIL": "t@t"})


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

        # Plenty of disk unless a test says otherwise.
        self.reserve = unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=0)
        self.reserve.start()
        # A new root's size before any is measured: small, so the tests' disk always has room unless one says not.
        self.floor = unittest.mock.patch.object(scratch, "ROOT_BYTES_UNMEASURED", 1024)
        self.floor.start()

    def tearDown(self):
        self.reserve.stop()
        self.floor.stop()
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

    def test_a_kept_build_drops_its_resource_bundles_and_keeps_its_modules(self):
        # SwiftPM never deletes a resource the tree no longer has from a kept bundle: cmux#26961's
        # job compiled a MiscHandlers.xcstrings another branch's job on that runner had copied there.
        scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-a")
        products = self.workspace / "Packages/macOS/B/.build/arm64-apple-macosx/debug"
        bundle = products / "B_Pane.bundle"
        bundle.mkdir(parents=True)
        (bundle / "MiscHandlers.xcstrings").write_text("{}")
        (products / "description.json").write_text("{}")
        (products / "Pane.build").mkdir()
        (products / "Pane.build" / "Pane.swift.o").write_text("object")
        # A dependency checkout that ships a .bundle is not a build product.
        shipped = self.workspace / "Packages/macOS/B/.build/checkouts/dep/Shipped.bundle"
        shipped.mkdir(parents=True)
        (self.workspace / "Packages/macOS/B/.build").unlink()  # the next job's checkout clean
        scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-a")
        self.assertFalse(bundle.exists())
        self.assertEqual((products / "Pane.build" / "Pane.swift.o").read_text(), "object")
        self.assertTrue(shipped.is_dir())

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

    def test_the_fingerprint_covers_the_vendored_bonsplit_commit(self):
        # A package test object compiled against one bonsplit must never link
        # against another: SwiftPM's mtime check does not see a submodule that
        # moved back to older sources, and a stale object then fails to link.
        bonsplit = {"commit": "a" * 40}

        def run(command, **kwargs):
            if "rev-parse" in command:
                return unittest.mock.Mock(stdout=bonsplit["commit"] + "\n", stderr="")
            return unittest.mock.Mock(stdout="Xcode 26.6\n", stderr="")

        with unittest.mock.patch.object(scratch.subprocess, "run", side_effect=run):
            old = scratch.toolchain_fingerprint(Path("/a"))
            bonsplit["commit"] = "b" * 40
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

    def built(self, fingerprint: str) -> None:
        products = self.scratch / fingerprint / "Packages__macOS__B/arm64-apple-macosx/debug"
        products.mkdir(parents=True, exist_ok=True)
        (products / "description.json").write_text("{}")
        (products / "B.swiftmodule").write_bytes(b"m" * 64)

    def verdict(self, fingerprint: str) -> dict:
        verdict: dict = {}
        scratch.link(self.workspace, self.store, RUNNER, fingerprint=fingerprint, verdict=verdict)
        return verdict

    def test_the_first_link_on_a_mini_starts_cold_first_on_host(self):
        self.assertEqual(self.verdict("xcode-a"), {"state": "cold", "reason": "first on host", "bytes": 0})

    def test_a_link_that_finds_its_build_starts_warm_with_its_bytes(self):
        self.verdict("xcode-a")
        self.built("xcode-a")
        verdict = self.verdict("xcode-a")
        self.assertEqual((verdict["state"], verdict["reason"]), ("warm", "kept"))
        self.assertGreaterEqual(verdict["bytes"], 66)

    def test_a_linked_directory_that_never_built_is_cold(self):
        self.verdict("xcode-a")
        self.assertEqual(self.verdict("xcode-a")["reason"], "never built")

    def test_a_new_fingerprint_and_an_evicted_one_are_told_apart(self):
        self.verdict("xcode-a")
        self.built("xcode-a")
        self.assertEqual(self.verdict("xcode-b")["reason"], "new fingerprint")
        for holder in scratch.HOLDERS:
            holder.kill()
            holder.wait()
        scratch.HOLDERS.clear()
        scratch.evict(self.store)
        self.assertEqual(self.verdict("xcode-a"), {"state": "cold", "reason": "evicted", "bytes": 0})

    def test_the_verdict_file_is_this_jobs_for_the_runner_hook(self):
        temp = Path(self.tmp.name) / "runner-temp"
        temp.mkdir()
        environ = {"RUNNER_TEMP": str(temp), "GITHUB_RUN_ID": "41121262424", "GITHUB_RUN_ATTEMPT": "2"}
        path = scratch.write_warm_start("warm", 12 * 1024**3, "kept", environ)
        self.assertEqual(path, temp / scratch.WARM_START_FILE)
        self.assertEqual(json.loads(path.read_text()), {
            "schema": "cmux-warm-start/v1", "run_id": "41121262424", "run_attempt": "2",
            "source": "spm_scratch", "state": "warm", "bytes": 12 * 1024**3, "reason": "kept"})
        self.assertLess(path.stat().st_size, 4096)
        self.assertEqual(list(temp.iterdir()), [path])  # no staged leftovers
        self.assertIsNone(scratch.write_warm_start("cold", 0, "x", {}))

    def test_the_command_writes_the_verdict(self):
        temp = Path(self.tmp.name) / "runner-temp"
        temp.mkdir()
        env = {**os.environ, "RUNNER_TEMP": str(temp), "RUNNER_NAME": RUNNER, "GITHUB_RUN_ID": "7",
               "GITHUB_RUN_ATTEMPT": "1", "PATH": os.environ.get("PATH", "")}
        code = ("import sys; sys.path.insert(0, sys.argv[1]); import owned_spm_scratch as s; "
                "s.toolchain_fingerprint = lambda w: 'xcode-a'; "
                "code = s.main(['x', 'link', sys.argv[2], sys.argv[3]]); "
                "[(h.kill(), h.wait()) for h in s.HOLDERS]; sys.exit(code)")
        result = subprocess.run([sys.executable, "-c", code, str(ROOT / "scripts/ci"), str(self.workspace),
                                 str(self.store)], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("starts cold (first on host, 0.0 GiB kept)", result.stdout)
        payload = json.loads((temp / scratch.WARM_START_FILE).read_text())
        self.assertEqual((payload["state"], payload["reason"], payload["run_id"]), ("cold", "first on host", "7"))

    def checkout(self) -> Path:
        git(self.workspace, "init", "-q")
        (self.workspace / "Packages/macOS/B/Sources").mkdir(parents=True)
        (self.workspace / "Packages/macOS/B/Sources/b.swift").write_text("let b = 1\n")
        (self.workspace / "tool.sh").write_text("#!/bin/sh\n")
        os.chmod(self.workspace / "tool.sh", 0o755)
        os.symlink("Packages/macOS/B", self.workspace / "b-link")
        (self.workspace / ".gitignore").write_text(".build\nignored/\n")
        (self.workspace / "ignored").mkdir()
        (self.workspace / "ignored/huge").write_text("not mirrored")
        git(self.workspace, "add", "-A")
        git(self.workspace, "commit", "-qm", "one")
        return self.workspace

    def lease(self, fingerprints=("root-0", "root-1"), verdict=None):
        return scratch.lease(self.workspace, self.store, RUNNER, verdict=verdict, fingerprints=list(fingerprints))

    def test_a_lease_mirrors_the_checkout_and_links_the_roots_packages(self):
        self.checkout()
        verdict = {}
        source = self.lease(verdict=verdict)
        self.assertEqual(source, self.scratch / "root-0" / scratch.SHARED_SOURCE)
        self.assertEqual((source / "Packages/macOS/B/Sources/b.swift").read_text(), "let b = 1\n")
        self.assertTrue(os.access(source / "tool.sh", os.X_OK))
        self.assertEqual(os.readlink(source / "b-link"), "Packages/macOS/B")
        self.assertTrue((source / ".git/HEAD").is_file())
        self.assertFalse((source / "ignored").exists())  # ignored outputs of other jobs stay in the workspace
        self.assertEqual((source / "Packages/macOS/B/.build").resolve(),
                         (self.scratch / "root-0/Packages__macOS__B").resolve())
        self.assertEqual(verdict, {"state": "cold", "reason": "first on host", "bytes": 0})

    def test_an_unchanged_file_keeps_its_time_in_the_root_and_a_changed_one_is_newer(self):
        self.checkout()
        source = self.lease()
        old = source / "Packages/Shared/A/Package.swift"
        changed = source / "Packages/macOS/B/Sources/b.swift"
        for path in (old, changed):
            os.utime(path, (1000, 1000))
        scratch.release_holders()
        (self.workspace / "Packages/macOS/B/Sources/b.swift").write_text("let b = 2\n")
        os.utime(self.workspace / "Packages/Shared/A/Package.swift", (5_000_000, 5_000_000))  # another slot's checkout time
        self.assertEqual(self.lease(), source)
        self.assertEqual(old.stat().st_mtime, 1000)
        self.assertEqual(changed.read_text(), "let b = 2\n")
        self.assertGreater(changed.stat().st_mtime, 1000)

    def test_a_file_gone_from_the_checkout_goes_from_the_root_but_the_kept_build_stays(self):
        self.checkout()
        source = self.lease()
        built = source / "Packages/macOS/B/.build/product"
        built.write_text("built")
        (source / "stray").mkdir()
        (source / "stray/file").write_text("x")
        scratch.release_holders()
        git(self.workspace, "rm", "-q", "tool.sh")
        self.lease()
        self.assertFalse((source / "tool.sh").exists())
        self.assertFalse((source / "stray").exists())
        self.assertEqual(built.read_text(), "built")

    def replace_in_checkout(self, name: str, make) -> None:
        path = self.workspace / name
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            import shutil
            shutil.rmtree(path)
        make(path)
        git(self.workspace, "add", "-A")
        git(self.workspace, "commit", "-qm", "replace")

    def test_a_link_to_a_directory_replaced_by_a_real_directory_is_never_followed(self):
        # The root's b-link -> Packages/macOS/B; the next checkout makes b-link a real directory. The mirror must
        # write b-link/new into a real b-link, never through the old link into Packages/macOS/B.
        self.checkout()
        source = self.lease()
        scratch.release_holders()

        def real_dir(path):
            path.mkdir()
            (path / "new.swift").write_text("let n = 1\n")
        self.replace_in_checkout("b-link", real_dir)
        self.lease()
        self.assertFalse((source / "b-link").is_symlink())
        self.assertEqual((source / "b-link/new.swift").read_text(), "let n = 1\n")
        self.assertFalse((source / "Packages/macOS/B/new.swift").exists())
        self.assertEqual((source / "Packages/macOS/B/Sources/b.swift").read_text(), "let b = 1\n")

    def test_a_link_outside_the_root_is_never_written_through(self):
        # A root whose link points outside it (an absolute link the last checkout had) must never take writes
        # meant for a real directory of the same name.
        self.checkout()
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        (outside / "keep.swift").write_text("outside\n")
        os.symlink(str(outside), self.workspace / "ext")
        git(self.workspace, "add", "-A")
        git(self.workspace, "commit", "-qm", "ext")
        source = self.lease()
        scratch.release_holders()

        def real_dir(path):
            path.mkdir()
            (path / "keep.swift").write_text("inside\n")
            (path / "deeper").mkdir()
            (path / "deeper/x.swift").write_text("x\n")
        self.replace_in_checkout("ext", real_dir)
        self.lease()
        self.assertEqual((outside / "keep.swift").read_text(), "outside\n")
        self.assertEqual(sorted(p.name for p in outside.iterdir()), ["keep.swift"])
        self.assertFalse((source / "ext").is_symlink())
        self.assertEqual((source / "ext/keep.swift").read_text(), "inside\n")
        self.assertEqual((source / "ext/deeper/x.swift").read_text(), "x\n")

    def test_a_link_ancestor_of_an_unchanged_file_is_replaced_not_trusted(self):
        # The file's content matches through the old link, so it would be "kept"; the link must still become a
        # real directory holding the file.
        self.checkout()
        source = self.lease()
        scratch.release_holders()

        def real_dir(path):
            path.mkdir()
            (path / "Sources").mkdir()
            (path / "Sources/b.swift").write_text("let b = 1\n")
        self.replace_in_checkout("b-link", real_dir)
        self.lease()
        self.assertFalse((source / "b-link").is_symlink())
        self.assertEqual((source / "b-link/Sources/b.swift").read_text(), "let b = 1\n")
        self.assertEqual((source / "Packages/macOS/B/Sources/b.swift").read_text(), "let b = 1\n")

    def test_a_file_replaced_by_a_directory_and_back(self):
        self.checkout()
        source = self.lease()
        scratch.release_holders()

        def real_dir(path):
            path.mkdir()
            (path / "inner.sh").write_text("inner\n")
        self.replace_in_checkout("tool.sh", real_dir)
        self.assertEqual(self.lease(), source)
        self.assertEqual((source / "tool.sh/inner.sh").read_text(), "inner\n")
        scratch.release_holders()
        self.replace_in_checkout("tool.sh", lambda path: path.write_text("file again\n"))
        self.lease()
        self.assertEqual((source / "tool.sh").read_text(), "file again\n")

    def test_a_tracked_link_at_the_old_staging_name_never_takes_the_copy(self):
        # The mirror used to stage a copy at .<name>.mirror-<pid>; a checkout that tracks a link of that name
        # (mirrored first: it sorts before <name>) pointing outside the root must not receive the copy.
        self.checkout()
        victim = Path(self.tmp.name) / "victim"
        victim.write_text("outside\n")
        os.chmod(victim, 0o600)
        os.symlink(str(victim), self.workspace / f".a.swift.mirror-{os.getpid()}")
        (self.workspace / "a.swift").write_text("let a = 1\n")
        os.chmod(self.workspace / "a.swift", 0o755)
        git(self.workspace, "add", "-A")
        git(self.workspace, "commit", "-qm", "staging name")
        source = self.lease()
        self.assertEqual(victim.read_text(), "outside\n")
        self.assertEqual(victim.stat().st_mode & 0o777, 0o600)
        self.assertEqual((source / "a.swift").read_text(), "let a = 1\n")
        self.assertFalse((source / "a.swift").is_symlink())
        self.assertTrue(os.access(source / "a.swift", os.X_OK))
        self.assertEqual(os.readlink(source / f".a.swift.mirror-{os.getpid()}"), str(victim))
        self.assertEqual([p.name for p in source.iterdir() if ".mirror" in p.name and not p.is_symlink()], [])

    def test_a_package_under_a_linked_directory_is_never_linked(self):
        # A tracked Packages/Linked -> outside: its packages' .build lives outside the tree, never replaced.
        self.checkout()
        outside = Path(self.tmp.name) / "outside-pkgs"
        (outside / "C/.build").mkdir(parents=True)
        (outside / "C/Package.swift").write_text("// swift-tools-version:5.9\n")
        (outside / "C/.build/keep").write_text("outside build\n")
        os.symlink(str(outside), self.workspace / "Packages/Linked")
        git(self.workspace, "add", "-A")
        git(self.workspace, "commit", "-qm", "linked packages")
        source = self.lease()
        self.assertEqual((outside / "C/.build/keep").read_text(), "outside build\n")
        self.assertFalse((outside / "C/.build").is_symlink())
        self.assertNotIn(source / "Packages/Linked/C", scratch.packages(source))
        self.assertEqual(scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-a"),
                         ["Packages/Shared/A", "Packages/macOS/B"])
        self.assertFalse((outside / "C/.build").is_symlink())

    def test_a_root_entry_that_is_a_link_is_never_built_in(self):
        self.checkout()
        outside = Path(self.tmp.name) / "outside-root"
        outside.mkdir()
        self.scratch.mkdir()
        os.symlink(str(outside), self.scratch / "root-0")
        source = self.lease()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertTrue(source.is_relative_to(self.scratch))
        self.assertFalse(any(part.is_symlink() for part in [source, *source.parents] if part.is_relative_to(self.scratch)))

    def test_a_package_that_cannot_be_linked_fails_the_lease(self):
        self.checkout()
        real = scratch.Path.symlink_to

        def refuse(self_, target, target_is_directory=False):
            if self_.name == ".build" and "macOS" in str(self_):
                raise PermissionError(13, "denied")
            return real(self_, target, target_is_directory)
        with unittest.mock.patch.object(scratch.Path, "symlink_to", refuse):
            with self.assertRaises(OSError):
                self.lease()

    def test_a_directory_the_cleanup_walk_cannot_read_fails_the_mirror(self):
        # os.walk skips a directory it cannot list unless told otherwise: its stale files would stay in the root.
        self.checkout()
        self.lease()
        scratch.release_holders()
        real_walk = os.walk

        def walk_that_cannot_read(top, topdown=True, onerror=None, followlinks=False):
            if onerror is not None:
                onerror(PermissionError(13, "Permission denied", str(Path(top) / "stale")))
            return real_walk(top, topdown, onerror, followlinks)
        with unittest.mock.patch.object(scratch.os, "walk", walk_that_cannot_read):
            with self.assertRaises(OSError):
                self.lease()

    def test_a_scratch_entry_that_is_a_link_is_never_linked_pruned_or_built_in(self):
        outside = Path(self.tmp.name) / "outside-scratch"
        bundle = outside / "Packages__macOS__B/arm64-apple-macosx/debug/B_Pane.bundle"
        bundle.mkdir(parents=True)
        (bundle.parent / "description.json").write_text("{}")
        (bundle / "keep").write_text("outside\n")
        self.scratch.mkdir()
        os.symlink(str(outside), self.scratch / "xcode-a")
        self.assertEqual(scratch.entries(self.scratch), [])
        scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-a")
        self.assertEqual((bundle / "keep").read_text(), "outside\n")
        self.assertEqual(sorted(p.name for p in outside.iterdir()), ["Packages__macOS__B"])
        self.assertFalse((self.scratch / "xcode-a").is_symlink())
        self.assertTrue((self.workspace / "Packages/macOS/B/.build").resolve().is_relative_to(self.scratch.resolve()))

    def test_a_package_directory_in_the_scratch_that_is_a_link_is_replaced(self):
        outside = Path(self.tmp.name) / "outside-package"
        (outside / "arm64-apple-macosx/debug/B.bundle").mkdir(parents=True)
        (outside / "arm64-apple-macosx/debug/description.json").write_text("{}")
        (self.scratch / "xcode-a").mkdir(parents=True)
        os.symlink(str(outside), self.scratch / "xcode-a/Packages__macOS__B")
        scratch.link(self.workspace, self.store, RUNNER, fingerprint="xcode-a")
        self.assertTrue((outside / "arm64-apple-macosx/debug/B.bundle").is_dir())
        self.assertFalse((self.scratch / "xcode-a/Packages__macOS__B").is_symlink())

    def test_jobs_starting_together_never_make_more_roots_than_the_disk_holds(self):
        # Root 0 is built (100 bytes) and held; root 1 was just made by another job and is held, unbuilt.
        # The disk has room above the reserve for one more root's worth, which root 1 will take: no root 2.
        self.checkout()
        names = ("root-0", "root-1", "root-2", "root-3")
        self.lease(names)
        self.built("root-0")
        (self.scratch / "root-0/blob").write_bytes(b"x" * 100)
        self.lease(names)
        self.assertTrue((self.scratch / "root-1").is_dir())
        with unittest.mock.patch.object(scratch, "free_bytes", return_value=1000 + 150), \
                unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=1000), \
                unittest.mock.patch.object(scratch, "tree_stats", return_value=(100, 1.0)):
            self.assertIsNone(self.lease(names))
        self.assertFalse((self.scratch / "root-2").exists())

    def test_every_new_root_is_admitted_against_the_disk_not_only_the_first(self):
        # Root 0 is held and unbuilt (pending); the job loses root 1 to another job after the first check:
        # root 2 is checked again, and with room for only one pending root it is not made.
        self.checkout()
        self.lease(("root-0", "root-1", "root-2"))
        self.scratch.mkdir(exist_ok=True)
        with open(scratch.lock_path(self.scratch / "root-1"), "a") as other:
            fcntl.flock(other, fcntl.LOCK_EX)
            with unittest.mock.patch.object(scratch, "free_bytes", return_value=1000 + 150), \
                    unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=1000), \
                    unittest.mock.patch.object(scratch, "tree_stats", return_value=(100, 1.0)):
                self.assertIsNone(self.lease(("root-0", "root-1", "root-2")))
        self.assertFalse((self.scratch / "root-2").exists())

    def test_a_root_that_is_a_link_is_admitted_against_the_disk(self):
        self.checkout()
        self.lease(("root-0", "root-1"))
        self.built("root-0")
        outside = Path(self.tmp.name) / "outside-root-1"
        outside.mkdir()
        os.symlink(str(outside), self.scratch / "root-1")
        with unittest.mock.patch.object(scratch, "free_bytes", return_value=10), \
                unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=10):
            self.assertIsNone(self.lease(("root-0", "root-1")))
        self.assertTrue((self.scratch / "root-1").is_symlink())  # not replaced: no room for a root

    def test_a_case_only_rename_respells_the_entry_on_a_case_insensitive_disk(self):
        # On case-insensitive APFS, Foo.swift renamed to foo.swift finds the old entry under the new name; the
        # cleanup walk, which lists Foo.swift, must not then delete the file. Simulated: the parent lists only
        # Foo.swift and both spellings are one file.
        parent = Path(self.tmp.name) / "ci"
        parent.mkdir()
        (parent / "Foo.swift").write_text("x")
        same = os.lstat(parent / "Foo.swift")
        renamed = []
        real_lstat = os.lstat

        def lstat(path, *args, **kwargs):
            if os.path.basename(path) in ("Foo.swift", "foo.swift"):
                return same
            return real_lstat(path, *args, **kwargs)
        with unittest.mock.patch.object(scratch.os, "lstat", lstat), \
                unittest.mock.patch.object(scratch.os, "rename", lambda a, b: renamed.append((str(a), str(b)))):
            listings: dict = {}
            scratch.respell(parent / "foo.swift", listings)
        self.assertEqual(renamed, [(str(parent / "Foo.swift"), str(parent / "foo.swift"))])
        self.assertIn("foo.swift", listings[str(parent)])
        self.assertNotIn("Foo.swift", listings[str(parent)])

    def test_two_files_that_differ_in_case_on_a_case_sensitive_disk_are_both_kept(self):
        parent = Path(self.tmp.name) / "cs"
        parent.mkdir()
        (parent / "Foo.swift").write_text("a")
        (parent / "foo.swift").write_text("b")
        with unittest.mock.patch.object(scratch.os, "rename", side_effect=AssertionError("renamed")):
            scratch.respell(parent / "foo.swift", {})
            scratch.respell(parent / "Bar.swift", {})  # absent: nothing to respell

    def test_case_only_renames_keep_every_file_in_the_root(self):
        probe = Path(self.tmp.name) / "CaseProbe"
        probe.write_text("x")
        if not (Path(self.tmp.name) / "caseprobe").exists():
            self.skipTest("the disk is case-sensitive (macOS minis are not)")
        self.checkout()
        source = self.lease()
        scratch.release_holders()
        git(self.workspace, "mv", "tool.sh", "Tool.sh")
        git(self.workspace, "mv", "Packages/macOS/B/Sources", "Packages/macOS/B/sources")
        git(self.workspace, "commit", "-qm", "case")
        self.lease()
        self.assertIn("Tool.sh", os.listdir(source))
        self.assertIn("sources", os.listdir(source / "Packages/macOS/B"))
        self.assertEqual((source / "Packages/macOS/B/sources/b.swift").read_text(), "let b = 1\n")

    def test_resource_bundles_are_never_dropped_through_a_link(self):
        # A kept build whose <triple> or <config> folder is a link outside the scratch: its bundles are not ours.
        outside = Path(self.tmp.name) / "outside-build"
        (outside / "debug/Other.bundle").mkdir(parents=True)
        (outside / "debug/description.json").write_text("{}")
        (outside / "triple/debug/Deep.bundle").mkdir(parents=True)
        (outside / "triple/debug/description.json").write_text("{}")
        build = self.scratch / "xcode-a/Packages__macOS__B"
        (build / "arm64-apple-macosx").mkdir(parents=True)
        os.symlink(str(outside / "debug"), build / "arm64-apple-macosx/debug")
        os.symlink(str(outside / "triple"), build / "x86_64-apple-macosx")
        own = build / "arm64-apple-macosx/release"
        (own / "Own.bundle").mkdir(parents=True)
        (own / "description.json").write_text("{}")
        self.assertEqual(scratch.drop_resource_bundles(build), [own / "Own.bundle"])
        self.assertTrue((outside / "debug/Other.bundle").is_dir())
        self.assertTrue((outside / "triple/debug/Deep.bundle").is_dir())

    def test_an_empty_store_with_no_room_above_the_reserve_makes_no_root(self):
        # No root measured yet: a new root still needs room for a whole build, not zero bytes.
        self.checkout()
        with unittest.mock.patch.object(scratch, "ROOT_BYTES_UNMEASURED", 10**9), \
                unittest.mock.patch.object(scratch, "free_bytes", return_value=10**9 + 10), \
                unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=10**9):
            self.assertIsNone(self.lease())
        self.assertFalse((self.scratch / "root-0").exists())

    def test_jobs_starting_on_an_empty_store_reserve_room_for_each_pending_root(self):
        # Another job just made root 0 (held, unbuilt) on an empty store: with room for one root, no second.
        self.checkout()
        self.lease(("root-0", "root-1"))
        with unittest.mock.patch.object(scratch, "ROOT_BYTES_UNMEASURED", 10**6), \
                unittest.mock.patch.object(scratch, "free_bytes", return_value=10**6 + 10**6 // 2), \
                unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=0):
            self.assertIsNone(self.lease(("root-0", "root-1")))
        self.assertFalse((self.scratch / "root-1").exists())

    def test_a_root_evicted_before_its_lock_is_taken_goes_through_admission(self):
        self.checkout()
        self.lease(("root-0",))
        scratch.release_holders()
        real_open = os.open

        def evict_then_open(path, *args, **kwargs):
            if str(path) == str(scratch.lock_path(self.scratch / "root-0")) and (self.scratch / "root-0").is_dir():
                scratch.drop(self.scratch / "root-0")  # prune on another slot, after the scan
            return real_open(path, *args, **kwargs)
        with unittest.mock.patch.object(scratch.os, "open", evict_then_open), \
                unittest.mock.patch.object(scratch, "free_bytes", return_value=10), \
                unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=10):
            self.assertIsNone(self.lease(("root-0",)))  # no room: not remade without admission
        self.assertFalse((self.scratch / "root-0").exists())

    def test_a_directory_replaced_by_a_link(self):
        self.checkout()
        source = self.lease()
        scratch.release_holders()
        self.replace_in_checkout("Packages/macOS/B/Sources", lambda path: os.symlink("../../Shared/A", path))
        self.lease()
        self.assertEqual(os.readlink(source / "Packages/macOS/B/Sources"), "../../Shared/A")
        self.assertTrue((source / "Packages/Shared/A/Package.swift").is_file())

    def test_a_root_another_job_holds_is_never_shared_and_a_second_root_is_made(self):
        self.checkout()
        first = self.lease()
        second = self.lease()
        self.assertEqual(first.parent.name, "root-0")
        self.assertEqual(second.parent.name, "root-1")
        self.assertIsNone(self.lease())  # both held: the caller links its own workspace
        scratch.release_holders()
        self.assertEqual(self.lease().parent.name, "root-0")  # the lowest free root, the warmest

    def test_two_jobs_that_both_find_no_root_make_two(self):
        # Both saw an empty scratch: the one that loses root 0's lock goes on to root 1.
        self.checkout()
        self.scratch.mkdir()
        with open(scratch.lock_path(self.scratch / "root-0"), "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)  # another job is making root 0 right now
            self.assertEqual(self.lease(("root-0", "root-1", "root-2")).parent.name, "root-1")

    def test_a_job_that_takes_root_0_after_the_scan_sends_the_other_to_root_1(self):
        # The production numbering, not test fingerprints: both jobs scanned an empty scratch (no
        # directory, no lock file), then the other job locked root 0 before this one tried it.
        self.checkout()
        parts = ("x", "s", "b")
        self.scratch.mkdir()
        other = []

        def parts_then_the_other_job_locks_root_0(workspace):
            handle = open(scratch.lock_path(self.scratch / scratch.shared_fingerprint(parts, 0)), "a")
            fcntl.flock(handle, fcntl.LOCK_EX)
            other.append(handle)
            return parts

        with unittest.mock.patch.object(scratch, "toolchain_parts", side_effect=parts_then_the_other_job_locks_root_0):
            source = scratch.lease(self.workspace, self.store, RUNNER)
        other[0].close()
        self.assertEqual(source, self.scratch / scratch.shared_fingerprint(parts, 1) / scratch.SHARED_SOURCE)

    def test_a_lock_error_that_is_not_contention_is_raised_not_skipped(self):
        self.checkout()
        with unittest.mock.patch.object(scratch.fcntl, "flock", side_effect=OSError(37, "No locks available")):
            with self.assertRaises(OSError):
                self.lease()

    def test_a_root_above_a_pruned_one_is_still_found_and_reused(self):
        self.checkout()
        self.lease(("root-0", "root-1", "root-2"))
        self.lease(("root-0", "root-1", "root-2"))
        third = self.lease(("root-0", "root-1", "root-2"))
        self.assertEqual(third.parent.name, "root-2")
        self.built("root-2")
        scratch.release_holders()
        for name in ("root-0", "root-1"):
            scratch.drop(self.scratch / name)
        with unittest.mock.patch.object(scratch, "free_bytes", return_value=10), \
                unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=10):
            verdict = {}
            self.assertEqual(self.lease(("root-0", "root-1", "root-2"), verdict=verdict), third)
        self.assertEqual(verdict["state"], "warm")

    def test_the_scan_covers_every_root_a_lock_file_names(self):
        self.checkout()
        parts = ("x", "s", "b")
        with unittest.mock.patch.object(scratch, "toolchain_parts", return_value=parts):
            self.scratch.mkdir()
            for k in range(3):
                scratch.lock_path(self.scratch / scratch.shared_fingerprint(parts, k)).touch()
            high = self.scratch / scratch.shared_fingerprint(parts, 2)
            (high / "Packages__macOS__B/arm64-apple-macosx/debug").mkdir(parents=True)
            (high / "Packages__macOS__B/arm64-apple-macosx/debug/description.json").write_text("{}")
            with unittest.mock.patch.object(scratch, "free_bytes", return_value=0):
                self.assertEqual(scratch.lease(self.workspace, self.store, RUNNER), high / scratch.SHARED_SOURCE)

    def test_a_kept_root_starts_warm(self):
        self.checkout()
        self.lease()
        self.built("root-0")
        scratch.release_holders()
        verdict = {}
        self.lease(verdict=verdict)
        self.assertEqual((verdict["state"], verdict["reason"]), ("warm", "kept"))

    def test_no_new_root_without_room_above_the_reserve(self):
        self.checkout()
        self.lease()
        self.built("root-0")
        with unittest.mock.patch.object(scratch, "free_bytes", return_value=10), \
                unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=10):
            self.assertIsNone(self.lease())
        self.assertFalse((self.scratch / "root-1").exists())

    def test_a_leased_root_is_held_against_prune_and_glaeda_disk(self):
        self.checkout()
        self.lease()
        self.assertEqual(scratch.evict(self.store), [])
        with open(scratch.lock_path(self.scratch / "root-0"), "a") as handle:
            with self.assertRaises(OSError):
                fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)  # exclusive: not even a link shares it
        scratch.release_holders()
        self.assertEqual(scratch.evict(self.store), [str(self.scratch / "root-0")])

    def test_the_cap_is_the_free_space_above_the_reserve(self):
        make_entry(self.scratch, "old", 100, 1)
        make_entry(self.scratch, "new", 100, 5)
        with unittest.mock.patch.object(scratch, "free_bytes", return_value=1000), \
                unittest.mock.patch.object(scratch, "disk_reserve_bytes", return_value=1050):
            scratch.prune(self.scratch)  # 50 bytes short: the older one goes
        self.assertEqual([path.name for path in scratch.entries(self.scratch)], ["new"])
        with unittest.mock.patch.object(scratch, "free_bytes", return_value=10**12):
            make_entry(self.scratch, "again", 100, 1)
            scratch.prune(self.scratch)
        self.assertEqual(len(scratch.entries(self.scratch)), 2)

    def test_the_reserve_is_glaedas_floor_plus_one_jobs_growth_from_the_host_manifest(self):
        self.reserve.stop()
        try:
            manifest = Path(self.tmp.name) / "mini-fleet.json"
            manifest.write_text(json.dumps({"defaults": {"disk": {"min_free_gib": 30, "job_growth_gib": 20,
                                                                   "cleanup_start_gib": 120}},
                                            "hosts": {"m": {"overrides": {"disk": {"min_free_gib": 40}}}}}))
            self.assertEqual(scratch.disk_reserve_bytes((manifest,)), 60 * 1024**3)
            self.assertEqual(scratch.disk_reserve_bytes((Path(self.tmp.name) / "missing.json",)), 50 * 1024**3)
        finally:
            self.reserve.start()

    def test_the_fast_tier_builds_in_the_leased_root(self):
        text = NEXT_WORKFLOW.read_text()
        job = text[text.index("\n  fast-tier:\n"):text.index("\n  fast-tier-cargo:\n")]
        self.assertIn("owned_spm_scratch.py lease", job)
        self.assertNotIn("owned_spm_scratch.py link", job)
        self.assertIn('--root "${{ steps.spm-root.outputs.root || github.workspace }}"', job)
        self.assertLess(job.index("owned_spm_scratch.py lease"), job.index("scripts/cmux-next/fast-tier.py"))

    def test_the_workflow_links_before_the_package_tests(self):
        text = WORKFLOW.read_text()
        self.assertLess(text.index("owned_spm_scratch.py link"), text.index("run: ./scripts/ci/package-test-lane.sh run"))


if __name__ == "__main__":
    unittest.main()
