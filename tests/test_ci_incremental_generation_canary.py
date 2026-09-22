#!/usr/bin/env python3
"""Offline regression coverage for the disposable incremental-generation canary."""

from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
BENCHMARK = ROOT / "scripts/ci/benchmark-incremental-generation.py"

spec = importlib.util.spec_from_file_location("incremental_generation_canary", BENCHMARK)
assert spec and spec.loader
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


class IncrementalGenerationCanaryTests(unittest.TestCase):
    def test_xcodebuild_wrapper_adds_timing_summary_without_recursing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            realbin = root / "realbin"
            realbin.mkdir()
            capture = root / "args.txt"
            fake = realbin / "xcodebuild"
            fake.write_text(
                "#!/bin/bash\n"
                "printf '%s\\n' \"$@\" > \"$CAPTURE\"\n"
            )
            fake.chmod(0o755)
            with mock.patch.dict(os.environ, {"PATH": str(realbin)}):
                wrapper, env = bench.make_xcodebuild_wrapper(root / "wrapper-root")
            env["CAPTURE"] = str(capture)
            subprocess.run([str(wrapper), "build-for-testing", "foo"], check=True, env=env)
            args = capture.read_text().splitlines()
            self.assertEqual(args, ["build-for-testing", "foo", "-showBuildTimingSummary"])

            subprocess.run([str(wrapper), "-version"], check=True, env=env)
            self.assertEqual(capture.read_text().splitlines(), ["-version"])
    def test_parse_build_log_keeps_incremental_and_cas_evidence_separate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "cmux-build.log"
            log.write_text(
                "SwiftCompile normal arm64 /tmp/A.swift (in target 'cmux' from project 'cmux')\n"
                "Cache hit\n"
                "SwiftCompile normal arm64 /tmp/B.swift (in target 'cmux' from project 'cmux')\n"
                "Cache miss\n"
                "Build Timing Summary\n"
                "SwiftCompile (4 tasks) | 4.25 seconds\n"
                "SwiftEmitModule (1 task) | 1.75 seconds\n"
            )
            parsed = bench.parse_build_log(log)
            self.assertEqual(parsed["swift_compile_log_lines"], 2)
            self.assertEqual(parsed["swift_compile_source_file_lines"], 2)
            self.assertEqual(parsed["swift_compile_source_file_lines_by_target"], {"cmux": 2})
            self.assertEqual(parsed["swift_compile_task_count"], 4)
            self.assertEqual(parsed["emit_module_task_count"], 1)
            self.assertEqual(parsed["cas_hit_mentions"], 1)
            self.assertEqual(parsed["cas_miss_mentions"], 1)
            self.assertEqual(parsed["cas_hit_mentions_by_target"], {"cmux": 1})
            self.assertEqual(parsed["cas_miss_mentions_by_target"], {"cmux": 1})
            self.assertEqual(parsed["swift_compile_timing_seconds"], 4.25)
            self.assertEqual(parsed["emit_module_seconds"], 1.75)

    def test_blob_normalization_keeps_unchanged_mtime_and_changes_edited_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "repo"
            repo.mkdir()
            git(repo, "init", "-q")
            git(repo, "config", "user.name", "Canary Test")
            git(repo, "config", "user.email", "canary@example.invalid")
            (repo / "Sources").mkdir()
            unchanged = repo / "Sources/AppDelegate.swift"
            edited = repo / "Sources/MobileTerminalByteTee.swift"
            unchanged.write_text("let unchanged = 1\n")
            edited.write_text("let changed = 1\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "A")
            base = git(repo, "rev-parse", "HEAD")

            bench.normalize_tracked_mtimes(repo)
            unchanged_a = unchanged.stat().st_mtime_ns
            edited_a = edited.stat().st_mtime_ns

            edited.write_text("let changed = 2\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "B")
            target = git(repo, "rev-parse", "HEAD")

            git(repo, "checkout", "-q", "--detach", base)
            git(repo, "checkout", "-q", "--detach", target)
            bench.normalize_tracked_mtimes(repo)
            self.assertEqual(unchanged.stat().st_mtime_ns, unchanged_a)
            self.assertNotEqual(edited.stat().st_mtime_ns, edited_a)

    def test_restored_worktree_advances_only_changed_source_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            origin = root / "origin"
            origin.mkdir()
            git(origin, "init", "-q")
            git(origin, "config", "user.name", "Canary Test")
            git(origin, "config", "user.email", "canary@example.invalid")
            sources = origin / "Sources"
            sources.mkdir()
            unchanged = sources / "AppDelegate.swift"
            edited = sources / "Mobile" / "MobileTerminalByteTee.swift"
            edited.parent.mkdir()
            unchanged.write_text("let unchanged = 1\n")
            edited.write_text("let changed = 1\n")
            git(origin, "add", ".")
            git(origin, "commit", "-qm", "generation A")
            base = git(origin, "rev-parse", "HEAD")

            bench.normalize_tracked_mtimes(origin)
            unchanged_seed_mtime = unchanged.stat().st_mtime_ns
            edited_seed_mtime = edited.stat().st_mtime_ns

            archive = root / "worktree.tar.gz"
            bench.gzip_tar(origin, archive, excludes=("./.git",))

            time.sleep(0.01)
            edited.write_text("let changed = 2\n")
            git(origin, "add", ".")
            git(origin, "commit", "-qm", "generation B")
            target = git(origin, "rev-parse", "HEAD")

            restored = root / "restored"
            metrics = root / "source.json"
            bench.source_restored(
                restored,
                archive,
                str(origin),
                base,
                target,
                metrics,
                synthetic_merge=False,
            )
            payload = json.loads(metrics.read_text())
            self.assertTrue(payload["unchanged_mtime_preserved"])
            self.assertTrue(payload["edited_mtime_changed"])
            self.assertEqual(payload["sample_unchanged_mtime_ns_before"], unchanged_seed_mtime)
            self.assertEqual(payload["sample_unchanged_mtime_ns_after"], unchanged_seed_mtime)
            self.assertEqual(payload["edited_mtime_ns_before"], edited_seed_mtime)
            self.assertEqual(payload["head"], target)
            self.assertEqual(git(restored, "status", "--porcelain", "--untracked-files=all"), "")

    def test_synthetic_merge_uses_candidate_tree_and_preserves_unchanged_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            origin = root / "origin"
            origin.mkdir()
            git(origin, "init", "-q")
            git(origin, "config", "user.name", "Canary Test")
            git(origin, "config", "user.email", "canary@example.invalid")
            sources = origin / "Sources"
            sources.mkdir()
            unchanged = sources / "AppDelegate.swift"
            edited = sources / "Mobile" / "MobileTerminalByteTee.swift"
            edited.parent.mkdir()
            unchanged.write_text("let unchanged = 1\n")
            edited.write_text("let changed = 1\n")
            git(origin, "add", ".")
            git(origin, "commit", "-qm", "generation A")
            base = git(origin, "rev-parse", "HEAD")
            base_tree = git(origin, "rev-parse", "HEAD^{tree}")

            archive = root / "worktree.tar.gz"
            bench.gzip_tar(origin, archive, excludes=("./.git",))

            edited.write_text("let changed = 2\n")
            git(origin, "add", ".")
            git(origin, "commit", "-qm", "generation B")
            target = git(origin, "rev-parse", "HEAD")
            target_tree = git(origin, "rev-parse", "HEAD^{tree}")
            self.assertNotEqual(base_tree, target_tree)

            restored = root / "restored"
            metrics = root / "source.json"
            bench.source_restored(
                restored,
                archive,
                str(origin),
                base,
                target,
                metrics,
                synthetic_merge=True,
            )
            payload = json.loads(metrics.read_text())
            self.assertEqual(payload["tree"], target_tree)
            self.assertNotEqual(payload["head"], target)
            self.assertTrue(payload["unchanged_mtime_preserved"])
            self.assertTrue(payload["edited_mtime_changed"])

    def test_missing_tracked_seed_files_are_repaired_without_touching_existing_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "repo"
            repo.mkdir()
            git(repo, "init", "-q")
            git(repo, "config", "user.name", "Canary Test")
            git(repo, "config", "user.email", "canary@example.invalid")
            (repo / "Sources").mkdir()
            source = repo / "Sources/AppDelegate.swift"
            resource = repo / "Resources/ghostty/themes/example"
            resource.parent.mkdir(parents=True)
            source.write_text("let source = 1\n")
            resource.write_text("theme\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "seed")

            source_mtime = 1_600_000_000_000_000_123
            os.utime(source, ns=(source_mtime, source_mtime))
            resource.unlink()

            repaired = bench.restore_missing_tracked_files(repo)
            self.assertEqual(repaired, ["Resources/ghostty/themes/example"])
            self.assertEqual(source.stat().st_mtime_ns, source_mtime)
            self.assertEqual(resource.read_text(), "theme\n")
            self.assertEqual(git(repo, "status", "--porcelain", "--untracked-files=all"), "")

    def test_old_archive_submodule_worktrees_are_removed_before_rehydrate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "repo"
            repo.mkdir()
            (repo / ".gitmodules").write_text(
                '[submodule "dep"]\n\tpath = vendor/dep\n\turl = https://example.invalid/dep.git\n'
            )
            dep = repo / "vendor/dep"
            dep.mkdir(parents=True)
            (dep / "stale").write_text("old archive bytes\n")
            self.assertEqual(bench.configured_submodule_paths(repo), ["vendor/dep"])
            self.assertEqual(bench.remove_restored_submodule_worktrees(repo), ["vendor/dep"])
            self.assertFalse(dep.exists())

            (repo / ".gitmodules").write_text(
                '[submodule "bad"]\n\tpath = ../escape\n\turl = https://example.invalid/bad.git\n'
            )
            with self.assertRaises(SystemExit):
                bench.configured_submodule_paths(repo)
    def test_archive_validator_rejects_traversal_and_escaping_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            traversal = root / "traversal.tar.gz"
            with tarfile.open(traversal, "w:gz") as archive:
                data = b"escape"
                member = tarfile.TarInfo("../escape")
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            with self.assertRaises(SystemExit):
                bench.validate_tar_archive(traversal)

            escaping = root / "escaping.tar.gz"
            with tarfile.open(escaping, "w:gz") as archive:
                member = tarfile.TarInfo("link")
                member.type = tarfile.SYMTYPE
                member.linkname = "../../outside"
                archive.addfile(member)
            with self.assertRaises(SystemExit):
                bench.validate_tar_archive(escaping)
    def test_archive_validator_allows_only_in_root_absolute_derived_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            derived = root / "derived"
            derived.mkdir()
            archive = root / "derived.tar.gz"
            inside = derived / "Build/Products/Debug/lib.dylib"
            with tarfile.open(archive, "w:gz") as tar:
                member = tarfile.TarInfo("Build/Intermediates.noindex/link")
                member.type = tarfile.SYMTYPE
                member.linkname = str(inside)
                tar.addfile(member)

            stats = bench.validate_tar_archive(
                archive,
                allowed_absolute_symlink_root=derived,
            )
            self.assertEqual(stats["absolute_symlink_count"], 1)

            with self.assertRaises(SystemExit):
                bench.validate_tar_archive(archive)
            with self.assertRaises(SystemExit):
                bench.validate_tar_archive(
                    archive,
                    allowed_absolute_symlink_root=root / "relocated",
                )

    def test_archive_keeps_only_bounded_derived_data_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()
            git(repo, "init", "-q")
            git(repo, "config", "user.name", "Canary Test")
            git(repo, "config", "user.email", "canary@example.invalid")
            (repo / "Sources" / "Mobile").mkdir(parents=True)
            app_delegate = repo / "Sources/AppDelegate.swift"
            app_delegate.write_text("let a = 1\\n")
            (repo / "Sources/Mobile/MobileTerminalByteTee.swift").write_text("let b = 1\\n")
            tracked_resource = repo / "Resources/ghostty/themes/example"
            tracked_resource.parent.mkdir(parents=True)
            tracked_resource.write_text("theme\\n")
            (repo / ".gitignore").write_text("ignored.bin\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "seed")
            ignored = repo / "ignored.bin"
            ignored.write_bytes(b"ignored")
            exact_mtime = 1_600_000_000_123_456_789
            os.utime(app_delegate, ns=(exact_mtime, exact_mtime))

            derived = root / "derived"
            for relative in (
                "Build/Intermediates.noindex",
                "Build/Products/Debug",
                "ModuleCache.noindex",
                "SDKStatCaches.noindex",
                "Index.noindex",
            ):
                item = derived / relative
                item.mkdir(parents=True, exist_ok=True)
                (item / "marker").write_text(relative + "\\n")

            out = root / "archive"
            metrics = root / "metrics.json"
            bench.archive_generation(repo, derived, out, metrics)

            with tarfile.open(out / "worktree.tar.gz", "r:gz") as archive:
                source_members = {member.name: member for member in archive.getmembers()}
            self.assertIn("Sources/AppDelegate.swift", source_members)
            self.assertIn("Resources/ghostty/themes/example", source_members)
            self.assertNotIn("ignored.bin", source_members)
            self.assertEqual(
                source_members["Sources/AppDelegate.swift"].pax_headers.get("mtime"),
                "1600000000.123456789",
            )

            with tarfile.open(out / "derived-data.tar.gz", "r:gz") as archive:
                names = set(archive.getnames())
            self.assertTrue(any(name.startswith("Build/Intermediates.noindex") for name in names))
            self.assertTrue(any(name.startswith("Build/Products/Debug") for name in names))
            self.assertTrue(any(name.startswith("ModuleCache.noindex") for name in names))
            self.assertTrue(any(name.startswith("SDKStatCaches.noindex") for name in names))
            self.assertFalse(any(name.startswith("Index.noindex") for name in names))

            payload = json.loads(metrics.read_text())
            self.assertLess(payload["reusable_derived_data_disk_bytes"], payload["derived_data_disk_bytes"])

    def test_workflow_has_r2_parity_and_normalized_checkout_control(self) -> None:
        workflow = (ROOT / ".github/workflows/incremental-state-canary.yml").read_text()
        self.assertIn("CI_CACHE_R2_PUBLIC_URL: ${{ vars.CI_CACHE_R2_PUBLIC_URL }}", workflow)
        self.assertIn("- fresh-normalized-restored-dd", workflow)
        self.assertIn("Normalize fresh B mtimes from Git blob IDs", workflow)
        self.assertIn("branches:\n      - exp/incremental-state-canary-20260921", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("merge_group:", workflow)
    def test_archive_refuses_dirty_seed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "repo"
            repo.mkdir()
            git(repo, "init", "-q")
            git(repo, "config", "user.name", "Canary Test")
            git(repo, "config", "user.email", "canary@example.invalid")
            (repo / "Sources" / "Mobile").mkdir(parents=True)
            (repo / "Sources/AppDelegate.swift").write_text("let a = 1\n")
            (repo / "Sources/Mobile/MobileTerminalByteTee.swift").write_text("let b = 1\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "seed")
            (repo / "untracked.txt").write_text("dirty\n")
            derived = root / "derived"
            derived.mkdir()
            with self.assertRaises(SystemExit):
                bench.archive_generation(repo, derived, root / "archive", root / "metrics.json")


if __name__ == "__main__":
    unittest.main()
