#!/usr/bin/env python3
"""The canonical build root must make the cache key runner-independent."""

from __future__ import annotations

import os
import json
import re
import subprocess
import sys
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

    def test_a_second_compile_slot_gets_keys_of_its_own(self):
        # An owned Mac's second compile slot builds at /private/tmp/cmux-ci-2:
        # different absolute paths in every entry, so it must never adopt a
        # seed or compilation cache keyed for the first slot's root.
        first, second = "/private/tmp/cmux-ci", "/private/tmp/cmux-ci-2"
        self.assertNotEqual(
            self._fp(f"{first}/src", f"{first}/derived-data-compile-admission", root=first),
            self._fp(f"{second}/src", f"{second}/derived-data-compile-admission", root=second))
        # The default root adds no line, so every existing key is unchanged.
        text = SCRIPT.read_text()
        self.assertIn('if [ "$CANONICAL_BUILD_ROOT" != /private/tmp/cmux-ci ]; then', text)

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

    def test_a_volume_without_clones_falls_back_to_an_exact_rsync(self):
        # `cp -c` needs APFS clones; anything else must still get an exact copy.
        self.assertEqual(self.run_script().returncode, 0)
        (self.root / "src" / "stale.txt").write_text("from an earlier job")
        packages = self.restored_packages()
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        (bin_dir / "cp").write_text("#!/bin/sh\nexit 1\n")
        (bin_dir / "cp").chmod(0o755)
        result = self.run_script(extra_env={"PATH": f"{bin_dir}:/usr/bin:/bin", "CMUX_CI_MOVE_SOURCE_PACKAGES": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("copying with rsync", result.stderr)
        self.assertFalse((self.root / "src" / "stale.txt").exists())
        self.assertEqual((self.root / "src" / "sub" / "keep.txt").read_text(), "keep")
        moved = self.root / "src" / ".ci-source-packages" / "checkouts" / "pkg" / "Package.swift"
        self.assertEqual(moved.read_text(), "restored")
        self.assertFalse(packages.exists())

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
                       CMUX_CI_SWIFTPM_KEEP_ENV="CALLS",
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
            # Derive the expected builds from the recipe rather than pinning a
            # count: version probes, one resolve, then one build per scheme.
            # A hardcoded total silently breaks whenever a scheme is added --
            # cmux-cli-tests did exactly that. The recipe now takes its scheme
            # list from PRODUCT_PROFILES, so read the same source it does.
            sys.path.insert(0, str(ROOT / "scripts" / "ci"))
            import product_input_identity as identity

            expected_schemes = list(identity.profile_schemes("app-host"))
            # Version probes are not pinned either: the build step reads the
            # Xcode version too, to decide the compilation cache (#14359).
            # Every other call is the one resolve or a scheme build.
            probes = [args for _cwd, args in records if args == ["-version"]]
            resolves = [args for _cwd, args in records if "-resolvePackageDependencies" in args]
            self.assertGreaterEqual(len(probes), 1)
            self.assertEqual(len(resolves), 1)
            self.assertEqual(len(records), len(probes) + len(resolves) + len(expected_schemes))
            # resolve() also passes -scheme (cmux-unit) alongside
            # -resolvePackageDependencies; only the build invocations count.
            built = [
                args[args.index("-scheme") + 1]
                for _cwd, args in records
                if "-scheme" in args and "-resolvePackageDependencies" not in args
            ]
            self.assertEqual(built, expected_schemes)
            # cmux-numeric-locale reuses the cmux-unit product instead of being
            # built again; tests/test_app_host_test_products.py holds the two
            # schemes equivalent.
            self.assertNotIn("cmux-numeric-locale", built)
            canonical_src = str((root / "src").resolve())
            for cwd, args in records:
                self.assertEqual(cwd, canonical_src)
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
                       CMUX_CI_SWIFTPM_KEEP_ENV="CALLS",
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
            canonical_src = str((root / "src").resolve())
            for cwd, _args in records:
                self.assertEqual(cwd, canonical_src)

class SeededBuildFileSystemModeTests(unittest.TestCase):
    """A seeded build must compare inputs by content, not by stat.

    Blacksmith images install Xcode at different times, so every SDK header
    and prebuilt module carries a different mtime on each image, and Xcode
    rewrites the generated package module maps with identical bytes on the
    first build after adoption. Under the default device-agnostic mode each of
    those invalidates the seed: run 36022099083 adopted a seed at distance 0
    and still reran 94 SwiftDriver and 64 SwiftEmitModule tasks.
    """

    def run_recipe(self, base: Path) -> tuple[list[dict], str]:
        bin_dir = base / "bin"
        bin_dir.mkdir()
        calls = base / "calls.jsonl"
        (bin_dir / "xcodebuild").write_text(
            "#!/usr/bin/env python3\n"
            "import os,sys,json\n"
            "with open(os.environ['CALLS'], 'a') as f:\n"
            " f.write(json.dumps({'args': sys.argv[1:], 'mode': os.environ.get('FileSystemMode'), 'env': dict(os.environ)})+'\\n')\n"
            "if '-version' in sys.argv: print('Xcode 26.3')\n"
            "if '-resolvePackageDependencies' in sys.argv:\n"
            " import pathlib\n"
            " p=pathlib.Path(sys.argv[sys.argv.index('-clonedSourcePackagesDirPath')+1])\n"
            " for a in ['sparkle/Sparkle/Sparkle.xcframework','sentry-cocoa/Sentry/Sentry.xcframework']: (p/'artifacts'/a).mkdir(parents=True,exist_ok=True)\n")
        (bin_dir / "xcodebuild").chmod(0o755)
        workspace = base / "checkout"
        (workspace / ".git").mkdir(parents=True)
        root = base / "canonical"
        root.mkdir()
        env = dict(os.environ, PATH=f"{bin_dir}:" + os.environ["PATH"], CALLS=str(calls),
                   CMUX_CI_SWIFTPM_KEEP_ENV="CALLS",
                   CMUX_CI_CANONICAL_ROOT=str(root),
                   # A caller's per-step noise, its tools and its settings.
                   GITHUB_RUN_ID="12345", HOME=str(base / "home"), CI="true",
                   CMUX_SKIP_ZIG_BUILD="1", CARGO_HOME=str(base / "cargo"),
                   CARGO_REGISTRIES_X_TOKEN="secret")
        env.pop("FileSystemMode", None)
        self.caller_env = env
        derived = str(root / "derived-data-compile-admission")
        fingerprints = []
        for args in [("canonical-fingerprint", derived),
                     ("canonical-resolve", derived, str(workspace / ".ci-source-packages")),
                     ("canonical-build", derived, str(workspace / ".ci-source-packages"), str(root / "cas"))]:
            result = subprocess.run([str(SCRIPT), *args], cwd=workspace, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            fingerprints.append(result.stdout.strip())
        return [json.loads(line) for line in calls.read_text().splitlines()], fingerprints[0]

    def test_every_scheme_builds_in_checksum_only_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            records, _ = self.run_recipe(Path(tmp))
        builds = [r for r in records if "build-for-testing" in r["args"]]
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import product_input_identity as identity

        self.assertEqual(len(builds), len(identity.profile_schemes("app-host")))
        for record in builds:
            self.assertEqual(record["mode"], "checksum-only", record["args"])

    def test_the_seed_fingerprint_names_the_mode(self):
        # A seed recorded under another mode reruns every task when adopted,
        # so it must not share a key with a checksum-only one.
        with tempfile.TemporaryDirectory() as tmp:
            _, fingerprint = self.run_recipe(Path(tmp))
        old = subprocess.run(
            ["shasum", "-a", "256"], input="canonical-v1\nXcode 26.3\nderived-data=derived-data-compile-admission\n",
            capture_output=True, text=True, check=True,
        ).stdout[:32]
        self.assertNotEqual(fingerprint, old)


class BuildEnvironmentTests(SeededBuildFileSystemModeTests):
    """Every scheme build reuses the manifests the resolve evaluated.

    SwiftPM keys each evaluated Package.swift on xcodebuild's whole
    environment, so a build under the caller's environment re-evaluated all
    of them: 18 to 44 s on the first scheme of every admission. The script
    phases still get the caller's PATH, HOME and settings, as build settings.
    """

    def test_builds_share_the_resolves_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            records, _ = self.run_recipe(Path(tmp))
        resolves = [r for r in records if "-resolvePackageDependencies" in r["args"]]
        builds = [r for r in records if "build-for-testing" in r["args"]]
        self.assertEqual(len(resolves), 1)
        self.assertTrue(builds)
        resolve_env = resolves[0]["env"]
        self.assertNotIn("GITHUB_RUN_ID", resolve_env)
        self.assertEqual(resolve_env.get("FileSystemMode"), "checksum-only")
        for record in builds:
            self.assertEqual(record["env"], resolve_env, record["args"])

    def test_script_phases_get_the_callers_path_home_and_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            records, _ = self.run_recipe(Path(tmp))
            caller = self.caller_env
        builds = [r for r in records if "build-for-testing" in r["args"]]
        self.assertTrue(builds)
        for record in builds:
            args = record["args"]
            for name in ("HOME", "CI", "CMUX_SKIP_ZIG_BUILD", "CARGO_HOME"):
                self.assertIn(f"{name}={caller[name]}", args)
            self.assertIn(f"CMUX_CALLER_PATH={caller['PATH']}", args)
            self.assertFalse(any(a.startswith("GITHUB_RUN_ID=") for a in args))
            self.assertFalse(any(a.startswith("CARGO_REGISTRIES_X_TOKEN=") for a in args))


class BuildPhaseCallerPathTests(unittest.TestCase):
    HELPER = ROOT / "scripts" / "build-phase-caller-path.sh"

    def path_after(self, path: str, caller: str | None) -> str:
        env = {"PATH": path}
        if caller is not None:
            env["CMUX_CALLER_PATH"] = caller
        return subprocess.run(
            ["/bin/bash", "-c", f'. "{self.HELPER}"; printf %s "$PATH"'],
            env=env, capture_output=True, text=True, check=True,
        ).stdout

    def test_the_callers_path_follows_xcodes_tool_directories(self):
        xcode = "/X/Toolchains/usr/bin:/X/usr/bin"
        self.assertEqual(
            self.path_after(f"{xcode}:/usr/bin:/bin:/usr/sbin:/sbin", "/home/.cargo/bin:/usr/bin:/bin"),
            f"{xcode}:/home/.cargo/bin:/usr/bin:/bin",
        )

    def test_without_a_caller_path_nothing_changes(self):
        path = "/X/usr/bin:/opt/homebrew/bin:/usr/bin:/bin"
        self.assertEqual(self.path_after(path, None), path)

    def test_every_tool_building_script_phase_sources_it(self):
        for script in ("build-command-palette-nucleo-ffi.sh", "build-diff-sidecar.sh",
                       "build-wireguard-go.sh", "build-app-bundled-resources.sh"):
            with self.subTest(script=script):
                text = (ROOT / "scripts" / script).read_text()
                self.assertIn("/build-phase-caller-path.sh\"", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
