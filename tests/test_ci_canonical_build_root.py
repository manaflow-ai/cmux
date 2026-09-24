#!/usr/bin/env python3
"""The canonical build root must make the cache key runner-independent."""

from __future__ import annotations

import os
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "compile-app-host-test-product.sh"

# The two layouts observed in CI. One underscore is the whole difference, and
# it was enough to give the nightly seed and pull-request admission different
# cache keys, so every admission compiled from scratch.
BLACKSMITH = "/Users/runner/_work/cmux/cmux"
WARP = "/Users/runner/work/cmux/cmux"


def fingerprint(workspace: str, derived_data: str, *, xcode: str = "Xcode 26.3", root: str | None = None,
                base: Path | None = None) -> str:
    """Run the script's fingerprint subcommand from a real directory.

    The script reads $PWD, so the simulated layout has to exist on disk;
    injecting the variable would be overwritten by cd.
    """
    assert base is not None, "pass a tmp base so the layouts are real paths"
    stub_dir = base / "bin"
    stub_dir.mkdir(exist_ok=True)
    (stub_dir / "xcodebuild").write_text(f"#!/bin/sh\necho '{xcode}'\n")
    (stub_dir / "xcodebuild").chmod(0o755)
    cwd = base / workspace.lstrip("/")
    cwd.mkdir(parents=True, exist_ok=True)
    env = {"PATH": f"{stub_dir}:/usr/bin:/bin"}
    if root is not None:
        env["CMUX_CI_CANONICAL_ROOT"] = str(base / root.lstrip("/"))
    result = subprocess.run(
        [str(SCRIPT), "fingerprint", str(base / derived_data.lstrip("/"))],
        cwd=cwd, env=env, text=True, capture_output=True, check=True,
    )
    return result.stdout.strip()


class CanonicalFingerprintTests(unittest.TestCase):
    def _fp(self, *a, **k):
        return fingerprint(*a, base=self.base, **k)

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = Path(self._tmp.name)

    def test_the_two_runner_layouts_disagree_today(self):
        # This is the bug: same repo, same toolchain, same purpose, two keys.
        blacksmith = self._fp(BLACKSMITH, "/Users/runner/_work/_temp/cmux-derived-data-compile-admission")
        warp = self._fp(WARP, "/Users/runner/work/_temp/cmux-derived-data-compile-admission")
        self.assertNotEqual(blacksmith, warp)

    def test_canonical_paths_agree_across_runner_layouts(self):
        # Both pools build from the same canonical root, so the key matches and
        # one seed serves both.
        root = "/private/tmp/cmux-ci"
        blacksmith = self._fp(f"{root}/src", f"{root}/derived-data-compile-admission", root=root)
        warp = self._fp(f"{root}/src", f"{root}/derived-data-compile-admission", root=root)
        self.assertEqual(blacksmith, warp)

    def test_canonical_key_differs_from_the_path_scoped_key(self):
        root = "/private/tmp/cmux-ci"
        canonical = self._fp(f"{root}/src", f"{root}/derived-data-compile-admission", root=root)
        legacy = self._fp(BLACKSMITH, "/Users/runner/_work/_temp/cmux-derived-data-compile-admission")
        self.assertNotEqual(canonical, legacy)

    def test_a_noncanonical_build_keeps_its_private_key(self):
        # Fail closed: an unconverted lane must not claim the shared key and
        # download a seed whose entries cannot hit its paths.
        root = "/private/tmp/cmux-ci"
        canonical = self._fp(f"{root}/src", f"{root}/derived-data-compile-admission", root=root)
        for workspace, derived in (
            (BLACKSMITH, f"{root}/derived-data-compile-admission"),   # canonical derived data only
            (f"{root}/src", "/Users/runner/_work/_temp/derived-data"),  # canonical source only
            (f"{root}/src", f"{root}/nested/derived-data"),             # not directly beneath the root
        ):
            with self.subTest(workspace=workspace, derived=derived):
                self.assertNotEqual(self._fp(workspace, derived, root=root), canonical)

    def test_purposes_stay_separate_under_the_canonical_root(self):
        # Two purposes are two directories, so their entries cannot hit each
        # other and they must not share a key.
        root = "/private/tmp/cmux-ci"
        admission = self._fp(f"{root}/src", f"{root}/derived-data-compile-admission", root=root)
        release = self._fp(f"{root}/src", f"{root}/derived-data-release", root=root)
        self.assertNotEqual(admission, release)

    def test_toolchain_still_invalidates_the_canonical_key(self):
        root = "/private/tmp/cmux-ci"
        old = self._fp(f"{root}/src", f"{root}/derived-data-compile-admission", xcode="Xcode 26.3", root=root)
        new = self._fp(f"{root}/src", f"{root}/derived-data-compile-admission", xcode="Xcode 27.0", root=root)
        self.assertNotEqual(old, new)


class CanonicalRootMaterializationTests(unittest.TestCase):
    """The root has to be a real directory, exact, and refuse unsafe inputs."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = Path(self._tmp.name)
        self.workspace = self.base / "ws"
        (self.workspace / "sub").mkdir(parents=True)
        (self.workspace / ".git").mkdir()
        (self.workspace / "sub" / "keep.txt").write_text("keep")
        self.root = self.base / "canon"

    def run_script(self, workspace=None, root=None, extra_env=None):
        return subprocess.run(
            [str(ROOT / "scripts" / "ci" / "canonical-build-root.sh"), str(workspace or self.workspace)],
            env={"PATH": "/usr/bin:/bin", "CMUX_CI_CANONICAL_ROOT": str(root or self.root), **(extra_env or {})},
            text=True, capture_output=True,
        )

    def restored_packages(self) -> Path:
        packages = self.workspace / ".ci-source-packages"
        (packages / "checkouts" / "pkg").mkdir(parents=True)
        (packages / "checkouts" / "pkg" / "Package.swift").write_text("restored")
        return packages

    def test_admission_moves_the_restored_package_cache_instead_of_copying_it(self):
        # The restored `spm-` cache is most of the tree by bytes, and admission
        # never reads the workspace copy again, so it moves it into place
        # rather than paying a second full copy before resolve.
        packages = self.restored_packages()
        stale = self.root / "src" / ".ci-source-packages" / "checkouts" / "stale"
        stale.mkdir(parents=True)
        result = self.run_script(extra_env={"CMUX_CI_MOVE_SOURCE_PACKAGES": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        moved = self.root / "src" / ".ci-source-packages" / "checkouts" / "pkg" / "Package.swift"
        self.assertEqual(moved.read_text(), "restored")
        self.assertFalse(packages.exists())
        # A reused runner's earlier packages must not survive the move.
        self.assertFalse(stale.exists())
        self.assertEqual((self.root / "src" / "sub" / "keep.txt").read_text(), "keep")

    def test_moving_without_a_restored_cache_still_clears_stale_packages(self):
        stale = self.root / "src" / ".ci-source-packages" / "checkouts" / "stale"
        stale.mkdir(parents=True)
        result = self.run_script(extra_env={"CMUX_CI_MOVE_SOURCE_PACKAGES": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "src" / ".ci-source-packages").exists())

    def test_other_callers_keep_their_workspace_package_cache(self):
        # app-host-test-rerun.yml reads the workspace copy after canonical
        # resolve, so the move is opt-in.
        packages = self.restored_packages()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertTrue((packages / "checkouts" / "pkg" / "Package.swift").is_file())
        self.assertTrue((self.root / "src" / ".ci-source-packages" / "checkouts" / "pkg" / "Package.swift").is_file())

    def test_runtime_source_alias_resolves_embedded_file_paths(self):
        result = subprocess.run(
            [str(ROOT / "scripts/ci/canonical-build-root.sh"), "--runtime-source", str(self.workspace)],
            env={"PATH": "/usr/bin:/bin", "CMUX_CI_CANONICAL_ROOT": str(self.root)},
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "src/sub/keep.txt").read_text(), "keep")
        # Runtime aliasing must not trick a later compiler into using a
        # workspace-dependent realpath under the shared fingerprint.
        self.assertEqual(self.run_script().returncode, 0)
        self.assertFalse((self.root / "src").is_symlink())
        self.assertEqual((self.root / "src/sub/keep.txt").read_text(), "keep")
        refused = subprocess.run(
            [str(ROOT / "scripts/ci/canonical-build-root.sh"), "--runtime-source", str(self.root / "src")],
            env={"PATH": "/usr/bin:/bin", "CMUX_CI_CANONICAL_ROOT": str(self.root)},
            text=True, capture_output=True,
        )
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual((self.root / "src/sub/keep.txt").read_text(), "keep")

    def test_the_canonical_source_is_a_real_directory_not_a_symlink(self):
        # A symlink resolves back to the pool-specific path, which would make
        # the shared key claim a match the compiler does not honour.
        self.assertEqual(self.run_script().returncode, 0)
        self.assertTrue((self.root / "src").is_dir())
        self.assertFalse((self.root / "src").is_symlink())

    def test_a_stale_symlink_from_an_older_revision_is_replaced(self):
        self.root.mkdir(parents=True)
        (self.root / "src").symlink_to(self.workspace)
        self.assertEqual(self.run_script().returncode, 0)
        self.assertFalse((self.root / "src").is_symlink())

    def test_a_reused_runner_cannot_leak_a_previous_job_into_the_build(self):
        self.assertEqual(self.run_script().returncode, 0)
        (self.root / "src" / "stale.txt").write_text("from an earlier job")
        (self.workspace / "sub" / "keep.txt").unlink()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertFalse((self.root / "src" / "stale.txt").exists())
        self.assertFalse((self.root / "src" / "sub" / "keep.txt").exists())

    def test_it_refuses_inputs_that_would_produce_a_wrong_build(self):
        cases = {
            "root inside the workspace": {"root": self.workspace / "inner"},
            "missing workspace": {"workspace": self.base / "absent"},
        }
        for label, kwargs in cases.items():
            with self.subTest(case=label):
                self.assertNotEqual(self.run_script(**kwargs).returncode, 0)

    def test_a_tree_without_git_is_refused_because_stamping_needs_it(self):
        bare = self.base / "nogit"
        bare.mkdir()
        result = self.run_script(workspace=bare, root=self.base / "canon2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(".git", result.stderr)


class CanonicalRecipeTests(unittest.TestCase):
    def test_resolve_build_and_fingerprint_use_canonical_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            workspace = base / "runner-layout" / "checkout"
            workspace.mkdir(parents=True)
            (workspace / ".git").mkdir()
            bin_dir = base / "bin"
            bin_dir.mkdir()
            calls = base / "calls.jsonl"
            xcode = bin_dir / "xcodebuild"
            xcode.write_text("#!/usr/bin/env python3\n" +
                "import os,sys,json,pathlib\n" +
                "with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps([os.getcwd(),sys.argv[1:]])+'\\n')\n" +
                "if '-version' in sys.argv: print('Xcode 26.3')\n" +
                "if '-resolvePackageDependencies' in sys.argv:\n" +
                " p=pathlib.Path(sys.argv[sys.argv.index('-clonedSourcePackagesDirPath')+1])\n" +
                " for a in ['sparkle/Sparkle/Sparkle.xcframework','sentry-cocoa/Sentry/Sentry.xcframework']: (p/'artifacts'/a).mkdir(parents=True,exist_ok=True)\n")
            xcode.chmod(0o755)
            root = base / "canonical"
            root.mkdir()
            (root / "src").symlink_to(workspace)
            env = dict(os.environ, PATH=f"{bin_dir}:" + os.environ['PATH'], CALLS=str(calls),
                       CMUX_CI_CANONICAL_ROOT=str(root))
            derived = str(root / "derived-data-compile-admission")
            packages = str(workspace / ".ci-source-packages")
            for args in [("canonical-fingerprint", derived),
                         ("canonical-resolve", derived, packages),
                         ("canonical-build", derived, packages, str(root / "cas"))]:
                result = subprocess.run([str(SCRIPT), *args], cwd=workspace, env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            records = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(len(records), 5)
            for cwd, args in records:
                self.assertEqual(cwd, str(root / "src"))
                if '-clonedSourcePackagesDirPath' in args:
                    self.assertEqual(args[args.index('-clonedSourcePackagesDirPath')+1],
                                     str(root / 'src' / '.ci-source-packages'))
                    self.assertEqual(args[args.index('-derivedDataPath')+1], derived)


    def test_build_alone_refuses_a_stale_runtime_alias(self):
        # The recipe above runs fingerprint first, which strips the alias, so it
        # only covers `build` transitively. A lane that compiles without
        # fingerprinting first would follow the alias to the pool-specific
        # realpath and write those entries under the pool-independent key --
        # a seed that downloads and then cannot hit.
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            workspace = base / "runner-layout" / "checkout"
            workspace.mkdir(parents=True)
            (workspace / ".git").mkdir()
            bin_dir = base / "bin"
            bin_dir.mkdir()
            calls = base / "calls.jsonl"
            xcode = bin_dir / "xcodebuild"
            xcode.write_text("#!/usr/bin/env python3\n" +
                "import os,sys,json\n" +
                "with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps([os.getcwd(),sys.argv[1:]])+'\\n')\n" +
                "if '-version' in sys.argv: print('Xcode 26.3')\n")
            xcode.chmod(0o755)
            root = base / "canonical"
            root.mkdir()
            (root / "src").symlink_to(workspace)
            env = dict(os.environ, PATH=f"{bin_dir}:" + os.environ['PATH'], CALLS=str(calls),
                       CMUX_CI_CANONICAL_ROOT=str(root))
            derived = str(root / "derived-data-compile-admission")
            result = subprocess.run(
                [str(SCRIPT), "canonical-build", derived,
                 str(workspace / ".ci-source-packages"), str(root / "cas")],
                cwd=workspace, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "src").is_symlink())
            records = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertTrue(records)
            for cwd, _args in records:
                self.assertEqual(cwd, str(root / "src"))

if __name__ == "__main__":
    unittest.main(verbosity=2)
