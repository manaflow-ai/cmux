#!/usr/bin/env python3
"""fast-checks.yml seeds SwiftPM's binary-artifact cache with curl before a Linux `swift build|test`.

Linux SwiftPM 6.2 and 6.3 crash (signal 4, `try!` in FoundationNetworking's EasyHandle.swift:312, libcurl
code 43) when several redirected binary-artifact downloads run at once (swiftlang/swift-corelibs-foundation#5445).
On 2026-10-30 base and PR fast checks of `swift test --package-path Packages/macOS/CmuxNext` (runs 41049880540,
41046951228) died in "Downloading binary artifact" before compiling anything. The workflow now runs
scripts/ci/swiftpm_prefetch_binary_artifacts.py, from its own commit, before the command; this keeps the step
and the script's cache naming, checksum checks and command parsing honest.
"""

from __future__ import annotations

import hashlib
import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "fast-checks.yml"
SCRIPT = ROOT / "scripts" / "ci" / "swiftpm_prefetch_binary_artifacts.py"

spec = importlib.util.spec_from_file_location("swiftpm_prefetch", SCRIPT)
prefetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prefetch)


def step(name: str) -> str:
    match = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)",
                      WORKFLOW.read_text(encoding="utf-8"), re.S | re.M)
    if not match:
        raise AssertionError(f"no step named {name!r}")
    return match.group(1)


class WorkflowTests(unittest.TestCase):
    def test_prefetch_runs_before_the_command(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        order = [text.index(f"- name: {name}\n") for name in (
            "Mount package and compilation caches", "Check out the SwiftPM artifact prefetch",
            "Prefetch SwiftPM binary artifacts", "Run fast checks")]
        self.assertEqual(order, sorted(order))

    def test_the_script_comes_from_the_workflow_commit(self) -> None:
        # The source snapshot is untrusted (and a feat-cmux-next snapshot lacks main's scripts).
        body = step("Check out the SwiftPM artifact prefetch")
        self.assertIn("ref: ${{ github.sha }}", body)
        self.assertIn("path: .fast-checks-tools", body)
        self.assertIn("persist-credentials: false", body)
        self.assertIn("sparse-checkout: scripts/ci/swiftpm_prefetch_binary_artifacts.py", body)

    def test_the_store_lives_on_the_cache_disk(self) -> None:
        body = step("Prefetch SwiftPM binary artifacts")
        self.assertIn('"$GITHUB_WORKSPACE/.fast-checks-tools/scripts/ci/swiftpm_prefetch_binary_artifacts.py"', body)
        self.assertIn("--store /home/runner/.cache/fast-checks/swiftpm-artifacts", body)
        self.assertIn('--command "$FAST_CHECKS_COMMAND" --directory "$FAST_CHECKS_DIRECTORY"', body)

    def test_both_steps_run_only_for_swift_commands(self) -> None:
        for name in ("Check out the SwiftPM artifact prefetch", "Prefetch SwiftPM binary artifacts"):
            self.assertIn("if: contains(inputs.command, 'swift')", step(name))


class CacheNameTests(unittest.TestCase):
    def test_matches_swiftpm_mangling(self) -> None:
        # TSCUtility's spm_mangledToC99ExtendedIdentifier, which SwiftPM's BinaryArtifactsManager keys on.
        url = "https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-619b/CCmuxAppFFI.xcframework.zip"
        self.assertEqual(prefetch.swiftpm_cache_key(url),
                         "https___github_com_manaflow_ai_cmux_releases_download_cmux_app_ffi_619b_"
                         "CCmuxAppFFI_xcframework_zip")

    def test_a_leading_digit_becomes_underscore(self) -> None:
        self.assertEqual(prefetch.swiftpm_cache_key("9a.b"), "_a_b")

    def test_a_non_ascii_url_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            prefetch.swiftpm_cache_key("https://example.com/é.zip")

    def test_cache_follows_xdg(self) -> None:
        self.assertEqual(prefetch.swiftpm_artifact_cache({"XDG_CACHE_HOME": "/x", "HOME": "/h"}),
                         Path("/x/org.swift.swiftpm/artifacts"))
        self.assertEqual(prefetch.swiftpm_artifact_cache({"HOME": "/h"}),
                         Path("/h/.cache/org.swift.swiftpm/artifacts"))


class CommandCacheTests(unittest.TestCase):
    def test_cache_follows_the_command(self) -> None:
        env = prefetch.command_env("XDG_CACHE_HOME=/tmp/c swift test")
        self.assertEqual(prefetch.swiftpm_artifact_cache({"HOME": "/h", **env}),
                         Path("/tmp/c/org.swift.swiftpm/artifacts"))
        self.assertEqual(prefetch.command_cache_path("swift test --cache-path /x/spm"), "/x/spm")
        self.assertEqual(prefetch.command_cache_path("swift test --cache-path=rel", "/w"), "/w/rel")
        self.assertIsNone(prefetch.command_cache_path("swift test -- --cache-path /x"))
        self.assertEqual(prefetch.swiftpm_artifact_cache({"HOME": "/h"}, "/x/spm"), Path("/x/spm/artifacts"))

    def test_main_seeds_the_cache_the_command_reads(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            seen = []
            original = prefetch.seed
            prefetch.seed = lambda packages, store, cache, swift, env=None: seen.append(cache) or 0
            try:
                prefetch.main(["--store", tmp, "--swift", "true",
                               "--command", f"XDG_CACHE_HOME={tmp}/xdg swift test --package-path P"])
                prefetch.main(["--store", tmp, "--swift", "true",
                               "--command", f"swift build --cache-path {tmp}/cp"])
            finally:
                prefetch.seed = original
        self.assertEqual(seen, [Path(tmp) / "xdg/org.swift.swiftpm/artifacts", Path(tmp) / "cp/artifacts"])


class CommandTests(unittest.TestCase):
    def test_swiftpm_commands_name_their_package(self) -> None:
        cases = {
            "swift test --package-path Packages/macOS/CmuxNext --filter X": ["Packages/macOS/CmuxNext"],
            "swift build --package-path=Packages/A": ["Packages/A"],
            "env FOO=1 swift-test": ["."],
            "CMUX_X=1 swift test --filter Y && echo done": ["."],
        }
        for command, expected in cases.items():
            self.assertEqual(prefetch.package_paths(command), expected, command)
        self.assertEqual(prefetch.package_paths("swift test", "Packages/B"), ["Packages/B"])

    def test_inline_assignments_reach_the_manifest(self) -> None:
        self.assertEqual(prefetch.command_env("CMUX_TERMINAL_CLIENT_MODEL_ONLY=1 swift test"),
                         {"CMUX_TERMINAL_CLIENT_MODEL_ONLY": "1"})
        self.assertEqual(prefetch.command_env("env A=1 B=x swift build"), {"A": "1", "B": "x"})
        self.assertEqual(prefetch.command_env("swift test A=1"), {})

    def test_other_commands_seed_nothing(self) -> None:
        for command in ("swift package dump-package", "swift test --help", "swift --version", "cargo test",
                        "bash -c 'swift test'", "swift test 'unterminated"):
            self.assertEqual(prefetch.package_paths(command), [], command)


class DumpTests(unittest.TestCase):
    def test_reads_remote_zip_binary_targets(self) -> None:
        good = "a" * 64
        dump = {"targets": [
            {"type": "binary", "url": "https://h/x.zip", "checksum": good.upper()},
            {"type": "binary", "path": "Local.xcframework"},
            {"type": "binary", "url": "https://h/index.artifactbundleindex", "checksum": good},
            {"type": "binary", "url": "https://h/bad.zip", "checksum": "nope"},
            {"type": "regular", "name": "Lib"},
        ]}
        self.assertEqual(prefetch.binary_artifacts(dump), [("https://h/x.zip", good)])

    def test_reads_local_path_dependencies(self) -> None:
        # Swift 6.2 dump-package: PackageDependency's enum coding.
        dump = {"dependencies": [
            {"fileSystem": [{"identity": "cmuxghosttykit", "nameForTargetDependencyResolutionOnly": None,
                             "path": "/abs/Pkg", "productFilter": None, "traits": []}]},
            {"sourceControl": [{"identity": "x", "location": {"remote": [{"urlString": "https://h/x"}]}}]},
        ]}
        self.assertEqual(prefetch.local_dependencies(dump, Path("/root/P")), [Path("/abs/Pkg")])

    def test_reads_a_flat_file_system_dependency(self) -> None:
        dump = {"dependencies": [{"kind": "fileSystem", "location": "../Sibling"},
                                 {"kind": "sourceControl", "location": "https://h/x"}]}
        self.assertEqual(prefetch.local_dependencies(dump, Path("/root/P")), [Path("/root/Sibling")])


class SoftFailureTests(unittest.TestCase):
    def test_a_malformed_package_resolved_still_seeds_the_rest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp)
            (package / "Package.resolved").write_text("{not json")
            dump = {"targets": [{"type": "binary", "url": "https://h/x.zip", "checksum": "b" * 64}]}
            original = prefetch.dump_package
            prefetch.dump_package = lambda path, swift="swift", env=None: dump
            try:
                found = prefetch.graph_artifacts(package, package / "store")
            finally:
                prefetch.dump_package = original
        self.assertEqual(found, [("https://h/x.zip", "b" * 64)])

    def test_a_listing_failure_never_fails_the_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp)
            (package / "Package.swift").write_text("")

            def broken(package, store, swift, env):
                raise RuntimeError("boom")
            self.assertEqual(prefetch.seed([package], package / "s", package / "c", collect=broken), 0)


class SeedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.store, self.cache = self.root / "store", self.root / "cache"
        self.package = self.root / "pkg"
        self.package.mkdir()
        (self.package / "Package.swift").write_text("// swift-tools-version: 6.2\n")
        self.body = b"zip bytes"
        self.checksum = hashlib.sha256(self.body).hexdigest()
        self.downloads: list[str] = []

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def download(self, body: bytes):
        def fetch(url: str, destination: Path) -> None:
            self.downloads.append(url)
            destination.write_bytes(body)
        return fetch

    def seed(self, artifacts, body: bytes) -> int:
        return prefetch.seed([self.package], self.store, self.cache, download=self.download(body),
                             collect=lambda package, store, swift, env: list(artifacts))

    def test_puts_each_artifact_at_swiftpm_cache_name(self) -> None:
        url = "https://github.com/o/r/releases/download/v1/A.xcframework.zip"
        self.assertEqual(self.seed([(url, self.checksum)], self.body), 0)
        entry = self.cache / prefetch.swiftpm_cache_key(url)
        self.assertEqual(entry.read_bytes(), self.body)
        self.assertEqual((self.store / "sha256" / f"{self.checksum}.zip").read_bytes(), self.body)

    def test_a_warm_store_downloads_nothing(self) -> None:
        url = "https://h/A.zip"
        self.seed([(url, self.checksum)], self.body)
        (self.cache / prefetch.swiftpm_cache_key(url)).unlink()
        self.downloads.clear()
        self.assertEqual(self.seed([(url, self.checksum)], self.body), 0)
        self.assertEqual(self.downloads, [])
        self.assertTrue((self.cache / prefetch.swiftpm_cache_key(url)).is_file())

    def test_a_checksum_mismatch_is_never_cached(self) -> None:
        url = "https://h/A.zip"
        self.assertEqual(self.seed([(url, self.checksum)], b"tampered"), 1)
        self.assertFalse((self.cache / prefetch.swiftpm_cache_key(url)).exists())
        self.assertEqual(list((self.store / "sha256").iterdir()), [])

    def test_a_corrupt_store_entry_is_fetched_again(self) -> None:
        blob = self.store / "sha256" / f"{self.checksum}.zip"
        blob.parent.mkdir(parents=True)
        blob.write_bytes(b"corrupt")
        self.assertEqual(self.seed([("https://h/A.zip", self.checksum)], self.body), 0)
        self.assertEqual(blob.read_bytes(), self.body)
        self.assertEqual(self.downloads, ["https://h/A.zip"])

    def test_a_failed_download_is_left_for_swiftpm(self) -> None:
        def fail(url: str, destination: Path) -> None:
            raise OSError("network down")
        missed = prefetch.seed([self.package], self.store, self.cache, download=fail,
                               collect=lambda package, store, swift, env: [("https://h/A.zip", self.checksum)])
        self.assertEqual(missed, 1)
        self.assertFalse(self.cache.exists() and any(self.cache.iterdir()))


if __name__ == "__main__":
    unittest.main()
