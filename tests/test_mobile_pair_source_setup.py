#!/usr/bin/env python3
"""Use real Git trees and descendant processes to exercise bounded source setup."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("matrix_sources", ROOT / "scripts/ci/mobile_pair_matrix.py")
matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(matrix)


class Sources(unittest.TestCase):
    def test_path_graph_includes_inheritance_targets_dev_and_patches(self):
        docs = {
            "cmux-next-ios/rust/Cargo.toml": '''[workspace]
members=["crates/phone"]
[workspace.dependencies]
shared={path="../../cmux-tui/crates/shared"}
[patch.crates-io]
patched={path="../../cmux-tui/vendor/patched"}
''',
            "cmux-next-ios/rust/crates/phone/Cargo.toml": '''[package]
name="phone"
[dependencies]
shared.workspace=true
[target.'cfg(unix)'.dev-dependencies]
testdep={path="../../../../cmux-tui/crates/testdep"}
''',
            "cmux-tui/Cargo.toml": '''[workspace]
[workspace.dependencies]
transitive={path="crates/transitive"}
''',
            "cmux-tui/crates/shared/Cargo.toml": '''[package]
name="shared"
[build-dependencies]
transitive.workspace=true
''',
            "cmux-tui/crates/transitive/Cargo.toml": '[package]\nname="transitive"',
            "cmux-tui/crates/testdep/Cargo.toml": '[package]\nname="testdep"',
            "cmux-tui/vendor/patched/Cargo.toml": '[package]\nname="patched"',
            "unrelated/Cargo.toml": 'intentionally invalid test fixture [',
        }
        self.assertEqual(matrix.cargo_paths(docs), [
            "cmux-next-ios/rust", "cmux-tui/crates/shared", "cmux-tui/crates/testdep",
            "cmux-tui/crates/transitive", "cmux-tui/vendor/patched"])

    def test_missing_dependency_fails_before_checkout(self):
        with self.assertRaisesRegex(ValueError, "missing local dependency"):
            matrix.cargo_paths({"cmux-next-ios/rust/Cargo.toml": {
                "workspace": {}, "dependencies": {"missing": {"path": "../gone"}}}})

    def fixture(self, directory):
        repo = Path(directory) / "repo"
        repo.mkdir()
        def git(*args):
            return subprocess.check_output(["git", "-C", str(repo), *args], text=True,
                                           stderr=subprocess.DEVNULL).strip()
        git("init")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        git("config", "core.hooksPath", "/dev/null")
        files = {
            "cmux-next-ios/rust/Cargo.toml": '[workspace]\nmembers=["phone"]\n',
            "cmux-next-ios/rust/phone/Cargo.toml": '[package]\nname="phone"\n[dependencies]\nshared={path="../../../cmux-tui/crates/shared"}\n',
            "cmux-next-ios/rust/phone/src/lib.rs": '// phone\n',
            "cmux-tui/Cargo.toml": '[workspace]\nmembers=["crates/shared"]\n',
            "cmux-tui/crates/shared/Cargo.toml": '[package]\nname="shared"\n',
            "cmux-tui/crates/shared/src/lib.rs": '// shared\n',
            "cmux-tui/crates/unrelated/big.rs": '// excluded\n',
            "webviews/unrelated.ts": '// excluded\n',
        }
        for name, text in files.items():
            p = repo / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
        git("add", ".")
        git("commit", "-qm", "fixture")
        git("remote", "add", "origin", str(repo))
        return repo, git("rev-parse", "HEAD"), git

    def test_real_sparse_tree_keeps_dependencies_and_removes_registration(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, sha, git = self.fixture(directory)
            tree = Path(directory) / "source"
            added = []
            try:
                matrix.prepare_source(repo, sha, tree, added)
                self.assertTrue((tree / "cmux-tui/crates/shared/src/lib.rs").exists())
                self.assertTrue((tree / "cmux-tui/Cargo.toml").exists())
                self.assertFalse((tree / "cmux-tui/crates/unrelated").exists())
                self.assertFalse((tree / "webviews").exists())
                self.assertEqual(subprocess.check_output(
                    ["git", "-C", str(tree), "rev-parse", "HEAD"], text=True).strip(), sha)
            finally:
                matrix.cleanup_sources(repo, added)
            self.assertFalse(tree.exists())
            self.assertNotIn(str(tree), git("worktree", "list", "--porcelain"))

    def test_failed_materialization_still_removes_own_registered_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, sha, git = self.fixture(directory)
            tree = Path(directory) / "partial"
            added = []
            original = matrix.run_source
            def fail(command, **kwargs):
                if "sparse-checkout" in command:
                    raise subprocess.TimeoutExpired(command, 120)
                return original(command, **kwargs)
            with patch.object(matrix, "run_source", side_effect=fail):
                with self.assertRaises(subprocess.TimeoutExpired):
                    matrix.prepare_source(repo, sha, tree, added)
            self.assertEqual(added, [tree])
            matrix.cleanup_sources(repo, added)
            self.assertFalse(tree.exists())
            self.assertNotIn(str(tree), git("worktree", "list", "--porcelain"))

    @unittest.skipUnless(os.name == "posix", "Git process groups require POSIX")
    def test_timeout_stops_term_ignoring_descendant_before_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "writes"
            child_pid = Path(directory) / "child.pid"
            child = ("import os,signal,time; from pathlib import Path; "
                     "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                     f"Path({str(child_pid)!r}).write_text(str(os.getpid())); "
                     f"f=open({str(marker)!r},'a',buffering=1); "
                     "exec('while True:\\n f.write(\"x\"); time.sleep(.02)')")
            parent = ("import subprocess,time; "
                      f"subprocess.Popen([{sys.executable!r},'-c',{child!r}]); time.sleep(30)")
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    matrix.run_source([sys.executable, "-c", parent], timeout=2)
                self.assertTrue(child_pid.exists(), "descendant must actually run before timeout")
                before = marker.read_bytes()
                time.sleep(.15)
                self.assertEqual(marker.read_bytes(), before, "descendant still writes after timeout")
            finally:
                if child_pid.exists():
                    try:
                        os.kill(int(child_pid.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
