#!/usr/bin/env python3
"""The canonical build root must make the cache key runner-independent."""

from __future__ import annotations

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

    def run_script(self, workspace=None, root=None):
        return subprocess.run(
            [str(ROOT / "scripts" / "ci" / "canonical-build-root.sh"), str(workspace or self.workspace)],
            env={"PATH": "/usr/bin:/bin", "CMUX_CI_CANONICAL_ROOT": str(root or self.root)},
            text=True, capture_output=True,
        )

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
