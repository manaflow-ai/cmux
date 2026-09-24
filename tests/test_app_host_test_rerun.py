#!/usr/bin/env python3
"""Tests for scripts/ci/app_host_test_rerun.py and the workflow that drives it."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import app_host_test_rerun as rerun  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "app-host-test-rerun.yml"


def run_git(cwd: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=cwd, text=True).strip()


class RepositoryFixture:
    def __init__(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name)
        run_git(self.path, "init", "-q", "-b", "main")
        run_git(self.path, "config", "user.email", "test@example.com")
        run_git(self.path, "config", "user.name", "Test")

    def commit(self, path: str, content: str) -> str:
        target = self.path / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        run_git(self.path, "add", path)
        run_git(self.path, "commit", "-q", "-m", path)
        return run_git(self.path, "rev-parse", "HEAD")

    def close(self) -> None:
        self.directory.cleanup()


class EligibilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = RepositoryFixture()
        self.addCleanup(self.repo.close)

    def test_stops_at_the_first_ancestor_with_an_app_change(self) -> None:
        older_app = self.repo.commit("Sources/App.swift", "1")
        same_app = self.repo.commit("Sources/App.swift", "2")
        built = self.repo.commit("cmuxTests/ATests.swift", "a")
        head = self.repo.commit("cmuxTests/BTests.swift", "b")
        eligible, blocker = rerun.eligible_revisions(head, 50, cwd=str(self.repo.path))
        self.assertEqual(eligible, [head, built, same_app])
        self.assertEqual(blocker["revision"], older_app)
        self.assertEqual(blocker["paths"], ["Sources/App.swift"])

    def test_a_project_file_change_is_not_test_only(self) -> None:
        self.repo.commit("cmuxTests/ATests.swift", "a")
        base = self.repo.commit("cmux.xcodeproj/project.pbxproj", "x")
        head = self.repo.commit("cmux.xcodeproj/project.pbxproj", "y")
        self.assertEqual(rerun.non_test_changes(base, head, cwd=str(self.repo.path)), ["cmux.xcodeproj/project.pbxproj"])

    def test_limit_bounds_the_walk(self) -> None:
        for index in range(5):
            head = self.repo.commit("cmuxTests/ATests.swift", str(index))
        eligible, blocker = rerun.eligible_revisions(head, 3, cwd=str(self.repo.path))
        self.assertEqual(len(eligible), 3)
        self.assertIsNone(blocker)


class ProductLookupTests(unittest.TestCase):
    def fake_api(self, runs: dict[str, list[dict]], artifacts: dict[str, list[dict]]):
        calls = []

        def api(path: str) -> dict:
            calls.append(path)
            match = re.search(r"head_sha=(\w+)", path)
            if match:
                return {"workflow_runs": runs.get(match.group(1), [])}
            match = re.search(r"runs/(\d+)/artifacts", path)
            return {"artifacts": artifacts.get(match.group(1), [])}

        return api, calls

    def test_picks_the_nearest_revision_and_newest_run_with_products(self) -> None:
        products = {"id": 7, "name": "app-host-products-v1-abc-1", "expired": False}
        api, _ = self.fake_api(
            {"near": [], "far": [{"id": 1, "created_at": "2026-01-01"}, {"id": 2, "created_at": "2026-01-02"}]},
            {"2": [{"id": 9, "name": "xcode-build-metrics-2-1"}, products], "1": [products]},
        )
        found = rerun.find_products("o/r", ["near", "far"], api)
        self.assertEqual(found["revision"], "far")
        self.assertEqual(found["run_id"], "2")
        self.assertEqual(found["artifact"]["id"], 7)

    def test_ignores_expired_products(self) -> None:
        api, _ = self.fake_api(
            {"only": [{"id": 1, "created_at": "x"}]},
            {"1": [{"id": 3, "name": "app-host-products-v1-abc-1", "expired": True}]},
        )
        self.assertIsNone(rerun.find_products("o/r", ["only"], api))


class SelectorTests(unittest.TestCase):
    def test_normalizes_separators_and_prefix(self) -> None:
        self.assertEqual(
            rerun.parse_selectors("Suite/testA,\ncmuxTests/Suite/testB()  -only-testing:Other"),
            ["cmuxTests/Suite/testA", "cmuxTests/Suite/testB()", "cmuxTests/Other"],
        )

    def test_rejects_shell_and_empty_input(self) -> None:
        for text in ("Suite/test;rm", "Suite/$(x)", "   "):
            with self.assertRaises(ValueError):
                rerun.parse_selectors(text)


PROJECT = """// !$*UTF8*$!
{
\tobjects = {
\t\tB1 /* Pkg in Frameworks */ = {isa = PBXBuildFile; productRef = P1 /* Pkg */; };
\t\tB2 /* XCTest.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = F1 /* XCTest.framework */; };
\t\tB3 /* Other in Frameworks */ = {isa = PBXBuildFile; productRef = P2 /* Other */; };
\t\tPH1 /* Frameworks */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\tB1 /* Pkg in Frameworks */,
\t\t\t\tB2 /* XCTest.framework in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
\t\tT1 /* cmuxTests */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = (
\t\t\t\tS1 /* Sources */,
\t\t\t\tPH1 /* Frameworks */,
\t\t\t);
\t\t\tdependencies = (
\t\t\t\tD1 /* PBXTargetDependency */,
\t\t\t);
\t\t\tname = cmuxTests;
\t\t\tpackageProductDependencies = (
\t\t\t\tP1 /* Pkg */,
\t\t\t);
\t\t};
\t\tT2 /* cmux */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tdependencies = (
\t\t\t\tD2 /* PBXTargetDependency */,
\t\t\t);
\t\t\tname = cmux;
\t\t\tpackageProductDependencies = (
\t\t\t\tP2 /* Other */,
\t\t\t);
\t\t};
\t\tP1 /* Pkg */ = {isa = XCSwiftPackageProductDependency; package = K1; productName = Pkg; };
\t\tP2 /* Other */ = {
\t\t\tisa = XCSwiftPackageProductDependency;
\t\t\tproductName = Other;
\t\t};
\t};
}
"""


class DetachTests(unittest.TestCase):
    def test_cuts_only_the_test_target_loose(self) -> None:
        text, products = rerun.detach_project(PROJECT)
        self.assertEqual(products, ["Pkg"])
        test_target = text[text.index("T1 /* cmuxTests */") : text.index("T2 /* cmux */")]
        self.assertNotIn("D1", test_target)
        self.assertNotIn("P1 /* Pkg */,", test_target)
        phase = text[text.index("PH1 /* Frameworks */ = {") : text.index("T1 /* cmuxTests */")]
        self.assertNotIn("B1", phase)
        self.assertIn("B2 /* XCTest.framework in Frameworks */,", phase)
        app_target = text[text.index("T2 /* cmux */") :]
        self.assertIn("D2 /* PBXTargetDependency */,", app_target)
        self.assertIn("P2 /* Other */,", app_target)

    def test_the_real_project_still_has_a_detachable_test_target(self) -> None:
        original = (ROOT / "cmux.xcodeproj" / "project.pbxproj").read_text()
        text, products = rerun.detach_project(original)
        self.assertIn("CmuxFoundation", products)
        self.assertLess(len(text), len(original))
        # Only removals: every surviving line was already in the project.
        self.assertTrue(set(text.splitlines()) <= set(original.splitlines()))

    def test_links_frameworks_and_prelinked_objects(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            debug = Path(directory)
            (debug / "PackageFrameworks" / "Pkg_-1A2B_PackageProduct.framework").mkdir(parents=True)
            (debug / "PackageFrameworks" / "PkgExtra_3C_PackageProduct.framework").mkdir()
            (debug / "Static.o").write_text("")
            self.assertEqual(
                rerun.link_inputs(["Pkg", "Static"], debug),
                ["-framework", "Pkg_-1A2B_PackageProduct", str(debug / "Static.o")],
            )
            with self.assertRaisesRegex(ValueError, "Missing"):
                rerun.link_inputs(["Missing"], debug)

    def test_generates_module_maps_for_package_c_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            debug = root / "Build" / "Products" / "Debug"
            debug.mkdir(parents=True)
            (debug / "AtomicsC.o").write_text("")
            (debug / "Swifty.o").write_text("")
            (debug / "Swifty.swiftmodule").mkdir()
            (debug / "include").mkdir()
            package = root / "Packages" / "Pkg"
            (package / "Sources" / "AtomicsC" / "include").mkdir(parents=True)
            (package / "Package.swift").write_text('.target(name: "AtomicsC", publicHeadersPath: "include")')
            project = root / "project.pbxproj"
            project.write_text(PROJECT)
            (debug / "PackageFrameworks" / "Pkg_1_PackageProduct.framework").mkdir(parents=True)
            host = debug / "Host App.app" / "Contents"
            (host / "PlugIns" / "cmuxTests.xctest").mkdir(parents=True)
            (host / "MacOS").mkdir()
            (host / "MacOS" / "Host App.debug.dylib").write_text("")
            self.assertEqual(rerun.c_module_targets(debug), ["AtomicsC"])
            args = argparse.Namespace(
                project=str(project), derived_data=str(root), xcconfig=str(root / "x.xcconfig"),
                target="cmuxTests", package_root=[str(root / "Packages")],
            )
            with unittest.mock.patch("sys.stdout"):
                rerun.detach(args, dump=lambda _: {"targets": [{"name": "AtomicsC", "path": None, "publicHeadersPath": "include"}]})
            generated = root / "Build" / "Intermediates.noindex" / "GeneratedModuleMaps" / "AtomicsC.modulemap"
            self.assertIn(f'umbrella "{package / "Sources" / "AtomicsC" / "include"}"', generated.read_text())
            xcconfig = (root / "x.xcconfig").read_text()
            self.assertIn(f"-fmodule-map-file={generated}", xcconfig)
            self.assertIn(f"-I{debug / 'include'}", xcconfig)
            self.assertIn("-framework Pkg_1_PackageProduct", xcconfig)
            self.assertIn(f'"{host / "MacOS" / "Host App.debug.dylib"}"', xcconfig)

    def test_umbrella_header_wins_over_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            include = Path(directory)
            (include / "Mod.h").write_text("")
            self.assertIn(f'umbrella header "{include / "Mod.h"}"', rerun.module_map("Mod", include))


class DownloadTests(unittest.TestCase):
    def test_parallel_transport_gets_a_numeric_artifact_id(self) -> None:
        import parallel_artifact_download as transport

        seen = {}

        def metadata(repository, artifact_id):
            seen["metadata"] = artifact_id
            return {"size_in_bytes": 1}

        def fetch(repository, artifact_id, target, size):
            seen["fetch"] = artifact_id
            raise transport.TransportError("stop after the id check")

        with tempfile.TemporaryDirectory() as directory, \
                unittest.mock.patch.object(transport, "artifact_metadata", metadata), \
                unittest.mock.patch.object(transport, "download_zip", fetch), \
                unittest.mock.patch.object(rerun.subprocess, "run") as run, \
                unittest.mock.patch("sys.stdout"):
            rerun.main([
                "download", "--repository", "o/r", "--run-id", "5", "--artifact-id", "42",
                "--artifact-name", "app-host-products-v1-x-1", "--destination", f"{directory}/products",
            ])
        self.assertEqual(seen, {"metadata": 42, "fetch": 42})
        self.assertEqual(run.call_args.args[0][:3], ["gh", "run", "download"])


class WorkflowTests(unittest.TestCase):
    def test_runs_on_a_fork_without_repository_variables(self) -> None:
        labels = re.findall(r"runs-on: (.*)", WORKFLOW.read_text())
        self.assertEqual(len(labels), 2)
        for label in labels:
            self.assertTrue(
                label.startswith("${{ github.repository_owner != 'manaflow-ai' && '"),
                f"a fork must reach a hosted label before any variable: {label}",
            )

    def test_the_helper_comes_from_the_workflow_revision(self) -> None:
        text = WORKFLOW.read_text()
        self.assertNotIn("python3 scripts/ci/app_host_test_rerun.py", text)
        self.assertEqual(text.count("path: .rerun-tools"), 2)


if __name__ == "__main__":
    unittest.main()
