#!/usr/bin/env python3
"""Tests for scripts/ci/app_host_test_rerun.py and the workflow that drives it."""

from __future__ import annotations

import argparse
import os
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

    def test_docs_and_ci_changes_do_not_change_the_app(self) -> None:
        base = self.repo.commit("Sources/App.swift", "1")
        self.repo.commit("docs/ci-runners.md", "x")
        self.repo.commit(".github/workflows/ci.yml", "x")
        head = self.repo.commit("scripts/ci/tool.py", "x")
        self.assertEqual(rerun.non_test_changes(base, head, cwd=str(self.repo.path)), [])

    def test_bundled_markdown_and_skills_change_the_app(self) -> None:
        # The app copies these into its resources; the rerun keeps CI's app.
        base = self.repo.commit("Sources/App.swift", "1")
        self.repo.commit("Resources/en.lproj/cloud-agent-skill.md", "x")
        head = self.repo.commit("skills/cmux-cua/SKILL.md", "x")
        self.assertEqual(
            rerun.non_test_changes(base, head, cwd=str(self.repo.path)),
            ["Resources/en.lproj/cloud-agent-skill.md", "skills/cmux-cua/SKILL.md"],
        )

    def test_no_neutral_path_is_referenced_by_the_project(self) -> None:
        paths = re.findall(r'path = "?([^";]+)"?;', (ROOT / "cmux.xcodeproj" / "project.pbxproj").read_text())
        for path in paths:
            if path.startswith(rerun.OUTSIDE_THE_APP) or path + "/" in rerun.OUTSIDE_THE_APP:
                self.assertIn(path, ("cmuxTests", "cmuxUITests"), path)

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



class PullRequestProductTests(unittest.TestCase):
    """A pull_request run built its merge commit, not the head_sha GitHub reports."""

    PRODUCTS = {"id": 7, "name": "app-host-products-v1-abc-1", "expired": False, "size_in_bytes": 1}

    def setUp(self) -> None:
        self.repo = RepositoryFixture()
        self.addCleanup(self.repo.close)
        self.base = self.repo.commit("Sources/App.swift", "1")
        run_git(self.repo.path, "checkout", "-q", "-b", "topic")
        self.head = self.repo.commit("cmuxTests/ATests.swift", "a")
        run_git(self.repo.path, "checkout", "-q", "main")
        self.base = self.repo.commit("Sources/Other.swift", "base moved")
        run_git(self.repo.path, "merge", "-q", "--no-ff", "-m", "Merge topic", "topic")
        self.merge = run_git(self.repo.path, "rev-parse", "HEAD")
        run_git(self.repo.path, "checkout", "-q", "topic")

    def pull_request_run(self, merge: str | None = None, run_id: int = 5) -> dict:
        ref = [{"path": "o/r/.github/workflows/ci-macos.yml@x", "ref": "refs/pull/1/merge", "sha": merge or self.merge}]
        return {"id": run_id, "event": "pull_request", "head_sha": self.head, "referenced_workflows": ref}

    def built(self, run: dict) -> str:
        return rerun.built_revision(run, cwd=str(self.repo.path), fetch=lambda revision: None)

    def test_a_push_run_built_its_head(self) -> None:
        self.assertEqual(self.built({"id": 1, "event": "push", "head_sha": self.head}), self.head)

    def test_a_pull_request_run_built_the_recorded_merge(self) -> None:
        self.assertEqual(self.built(self.pull_request_run()), self.merge)

    def test_a_recorded_commit_that_does_not_merge_the_head_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "not a merge of its head"):
            self.built(self.pull_request_run(merge=self.base))

    def test_a_pull_request_run_without_a_recorded_merge_is_rejected(self) -> None:
        run = self.pull_request_run()
        run["referenced_workflows"] = []
        with self.assertRaisesRegex(ValueError, "no single merge commit"):
            self.built(run)

    def dispatched_run(self, built: str, run_id: int = 6) -> dict:
        title = f"cmuxTests/ATests on blacksmith-6vcpu-macos-26 @ {built} [abc123]"
        return {"id": run_id, "event": "workflow_dispatch", "head_sha": self.head, "display_title": title,
                "path": ".github/workflows/test-e2e.yml"}

    def test_a_dispatched_ci_run_built_its_head(self) -> None:
        # ci-main-full-suite.yml dispatches main's ci.yml, titled just "CI".
        run = {"id": 7, "event": "workflow_dispatch", "head_sha": self.head, "display_title": "CI",
               "path": ".github/workflows/ci.yml"}
        self.assertEqual(self.built(run), self.head)

    def test_a_dispatched_run_built_the_revision_its_title_names(self) -> None:
        self.assertEqual(self.built(self.dispatched_run(self.base)), self.base)

    def test_a_dispatched_run_without_a_full_revision_is_rejected(self) -> None:
        run = self.dispatched_run(self.base)
        run["display_title"] = "cmuxTests/ATests on blacksmith-6vcpu-macos-26 @ my-branch"
        with self.assertRaisesRegex(ValueError, "no full revision"):
            self.built(run)

    def plan(self, ref: str, source_run_id: str, api) -> dict:
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(self.repo.path)
        args = argparse.Namespace(
            ref=ref, repository="o/r", only_testing="ATests", source_run_id=source_run_id, max_commits=10
        )
        with unittest.mock.patch.object(rerun, "product_runner", return_value="runner"):
            return rerun.plan(args, api=api)

    def test_plan_compares_the_test_ref_against_the_merge(self) -> None:
        # The merge carries the base's app change, which the head does not.
        def api(path: str) -> dict:
            if path.endswith("/artifacts?per_page=100"):
                return {"artifacts": [self.PRODUCTS]}
            return self.pull_request_run()

        with self.assertRaises(SystemExit) as raised:
            self.plan(self.head, "5", api)
        self.assertIn(f"run 5 built {self.merge}", str(raised.exception))
        self.assertIn("Sources/Other.swift", str(raised.exception))

    def test_plan_emits_the_merge_as_the_source_revision(self) -> None:
        # A head that is up to date with its base merges to the same app.
        run_git(self.repo.path, "merge", "-q", "--no-ff", "-m", "Merge main", "main")
        self.head = run_git(self.repo.path, "rev-parse", "HEAD")
        run_git(self.repo.path, "checkout", "-q", "main")
        run_git(self.repo.path, "merge", "-q", "--no-ff", "-m", "Merge topic", "topic")
        self.merge = run_git(self.repo.path, "rev-parse", "HEAD")
        run_git(self.repo.path, "checkout", "-q", "topic")
        tested = self.repo.commit("cmuxTests/BTests.swift", "b")

        def api(path: str) -> dict:
            if path.endswith("/artifacts?per_page=100"):
                return {"artifacts": [self.PRODUCTS]}
            return self.pull_request_run()

        planned = self.plan(tested, "5", api)
        self.assertEqual(planned["source_sha"], self.merge)
        self.assertEqual(planned["changed_tests"], "cmuxTests/BTests.swift")

    def test_automatic_plan_passes_over_a_merge_with_base_app_changes(self) -> None:
        # The newer pull_request run for this head built a merge that also
        # carries the base's app change; the older push run built the head.
        runs = [
            {**self.pull_request_run(run_id=2), "created_at": "2026-01-02"},
            {"id": 1, "event": "push", "head_sha": self.head, "created_at": "2026-01-01"},
        ]

        def api(path: str) -> dict:
            if "head_sha=" in path:
                return {"workflow_runs": runs if f"head_sha={self.head}" in path else []}
            return {"artifacts": [self.PRODUCTS]}

        planned = self.plan(self.head, "", api)
        self.assertEqual((planned["source_run_id"], planned["source_sha"]), ("1", self.head))

    def test_automatic_plan_passes_over_a_dispatched_run_of_another_revision(self) -> None:
        # test-e2e.yml runs list under main's head but compile the branch they test.
        runs = [
            {**self.dispatched_run(self.base, run_id=2), "created_at": "2026-01-02"},
            {"id": 1, "event": "push", "head_sha": self.head, "created_at": "2026-01-01"},
        ]

        def api(path: str) -> dict:
            if "head_sha=" in path:
                return {"workflow_runs": runs if f"head_sha={self.head}" in path else []}
            return {"artifacts": [self.PRODUCTS]}

        planned = self.plan(self.head, "", api)
        self.assertEqual((planned["source_run_id"], planned["source_sha"]), ("1", self.head))

    def test_lookup_reports_the_built_revision_and_skips_ineligible_merges(self) -> None:
        runs = {"h": [{"id": 1, "created_at": "2026-01-02"}, {"id": 2, "created_at": "2026-01-01"}]}

        def api(path: str) -> dict:
            match = re.search(r"head_sha=(\w+)", path)
            if match:
                return {"workflow_runs": runs.get(match.group(1), [])}
            return {"artifacts": [self.PRODUCTS]}

        found = rerun.find_products("o/r", ["h"], api, lambda run, revision: None if run["id"] == 1 else "merge")
        self.assertEqual((found["run_id"], found["revision"]), ("2", "merge"))


class ProductRunnerTests(unittest.TestCase):
    """The rerun must land on the pool whose Xcode compiled the products."""

    @staticmethod
    def api_for(jobs: list[dict]):
        def api(path: str) -> dict:
            assert re.search(r"runs/5/jobs", path), path
            return {"jobs": jobs, "total_count": len(jobs)}

        return api

    def test_follows_compile_admission_to_macos_26(self) -> None:
        api = self.api_for([
            {"name": "guards / linux", "labels": ["blacksmith-4vcpu-ubuntu-2404"]},
            {"name": "macos / macOS compile admission", "labels": ["blacksmith-6vcpu-macos-26"]},
        ])
        self.assertEqual(rerun.product_runner("o/r", "5", api), "blacksmith-6vcpu-macos-26")

    def test_github_hosted_admission_maps_to_the_same_macos(self) -> None:
        api = self.api_for([{"name": "macos / macOS compile admission", "labels": ["macos-26"]}])
        self.assertEqual(rerun.product_runner("o/r", "5", api), "blacksmith-6vcpu-macos-26")

    def test_owned_pool_admission_maps_to_the_lane_xcode_pool(self) -> None:
        # An owned Mac carries the pull-request lane's Xcode, the macOS 26 pools' pin.
        api = self.api_for([{"name": "macos / macOS compile admission", "labels": ["glaeda-std-xcode-26.6"]}])
        self.assertEqual(rerun.product_runner("o/r", "5", api), "blacksmith-6vcpu-macos-26")

    def test_macos_15_admission_and_unknown_producers_stay_on_macos_15(self) -> None:
        api = self.api_for([{"name": "macos / macOS compile admission", "labels": ["blacksmith-6vcpu-macos-15"]}])
        self.assertEqual(rerun.product_runner("o/r", "5", api), "blacksmith-6vcpu-macos-15")
        self.assertEqual(rerun.product_runner("o/r", "5", self.api_for([])), "blacksmith-6vcpu-macos-15")


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


class SourcePruningTests(unittest.TestCase):
    """A rerun compiles only the test sources its suites can reach."""

    SOURCES = {
        "ATests.swift": "final class ATests: XCTestCase {\n    func testOne() { XCTAssertEqual(makeWidget().size, 2) }\n}\n",
        "ATests+More.swift": "extension ATests {\n    func testTwo() {}\n}\n",
        "WidgetSupport.swift": "func makeWidget() -> Widget { Widget(size: 2) }\nstruct Widget { let size: Int }\n",
        "Unrelated.swift": "final class BTests: XCTestCase {\n    func testThree() { XCTAssertTrue(true) }\n}\n",
        "Private.swift": "private func makeWidget() -> Int { 1 }\nstruct Other {}\n",
        "Members.swift": "extension Widget {\n    var doubled: Int { size * 2 }\n    func unused() {\n        let size = 3\n    }\n}\n",
        "Conformance.swift": "extension Widget: Equatable {}\n",
        "Init.swift": "extension Widget {\n    init() { self.init(size: 1) }\n}\n",
    }

    def closure(self, suites: set[str], **changes: str) -> set[str] | None:
        return rerun.source_closure({**self.SOURCES, **changes}, suites)

    def test_follows_the_suite_to_the_helpers_it_uses(self) -> None:
        self.assertEqual(
            self.closure({"ATests"}),
            {"ATests.swift", "ATests+More.swift", "WidgetSupport.swift", "Init.swift"},
        )

    def test_an_extension_member_or_conformance_comes_in_once_it_is_used(self) -> None:
        uses = "final class ATests: XCTestCase {\n    func testOne() { XCTAssertEqual(makeWidget().doubled, makeWidget() as Equatable) }\n}\n"
        kept = self.closure({"ATests"}, **{"ATests.swift": uses})
        self.assertIn("Members.swift", kept)
        self.assertIn("Conformance.swift", kept)

    def test_a_local_variable_in_an_extension_is_not_a_member(self) -> None:
        self.assertNotIn("Members.swift", self.closure({"ATests"}))

    def test_a_suite_not_declared_at_the_top_level_compiles_everything(self) -> None:
        self.assertIsNone(self.closure({"ATests", "MissingTests"}))

    def test_prunes_only_test_sources_and_keeps_everything_else(self) -> None:
        original = (ROOT / "cmux.xcodeproj" / "project.pbxproj").read_text()
        sources = {path.name for path in (ROOT / "cmuxTests").rglob("*.swift")}
        text, dropped = rerun.prune_project(original, {"CmuxPopoverGroupTests.swift"}, sources)
        self.assertEqual(dropped, len(sources) - 1)
        # Only removals; the rewritten list may re-indent the lines it keeps.
        self.assertTrue({line.strip() for line in text.splitlines()} <= {line.strip() for line in original.splitlines()})
        phase = text[text.index("F1000005A1B2C3D4E5F60718 /* Sources */ = {"):]
        phase = phase[: phase.index("};")]
        self.assertIn("CmuxPopoverGroupTests.swift in Sources", phase)
        # The bundle also compiles CLI sources and the Objective-C release guard.
        self.assertIn("CLIError.swift in Sources", phase)
        self.assertIn("CmuxTestWindowReleaseGuard.m in Sources", phase)

    def test_the_real_suites_reach_a_small_closure(self) -> None:
        sources = {path.name: path.read_text(errors="replace") for path in (ROOT / "cmuxTests").rglob("*.swift")}
        kept = rerun.source_closure(sources, {"CmuxPopoverGroupTests"})
        self.assertIn("CmuxPopoverGroupTests.swift", kept)
        self.assertLess(len(kept), len(sources) // 10)

    def test_the_workflow_falls_back_to_every_source(self) -> None:
        text = WORKFLOW.read_text()
        step = text[text.index("- name: Compile only the cmuxTests bundle"): text.index("- name: Stage and validate products")]
        self.assertLess(step.index("app_host_test_rerun.py\" prune"), step.index('cp "$RUNNER_TEMP/detached.pbxproj"'))
        self.assertIn("&& compile; then", step)


class WorkflowTests(unittest.TestCase):
    def test_runs_on_a_fork_without_repository_variables(self) -> None:
        labels = re.findall(r"runs-on: (.*)", WORKFLOW.read_text())
        self.assertEqual(len(labels), 2)
        for label in labels:
            self.assertTrue(
                label.startswith("${{ github.repository_owner != 'manaflow-ai' && '"),
                f"a fork must reach a hosted label before any variable: {label}",
            )

    def test_every_swiftpm_cache_key_carries_the_layout_version(self) -> None:
        # #14013 moved the artifact zips into the seed and bumped the layout;
        # a key without it restores a pre-#14013 seed, and resolution then
        # downloads the artifacts again (116 s in run 36012287965).
        for workflow in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
            for key in re.findall(r"key: (spm-.*)", workflow.read_text()):
                self.assertIn("scripts/ci/swiftpm-cache-layout", key, f"{workflow.name}: {key}")

    def test_the_helper_comes_from_the_workflow_revision(self) -> None:
        text = WORKFLOW.read_text()
        self.assertNotIn("python3 scripts/ci/app_host_test_rerun.py", text)
        self.assertEqual(text.count("path: .rerun-tools"), 2)



TAKE_ROOT = ROOT / "scripts" / "ci" / "take-product-canonical-root.sh"


class CanonicalRootTests(unittest.TestCase):
    """An owned Mac runs two canonical roots; the rerun must hold the one it builds in."""

    def step(self, name: str) -> str:
        text = WORKFLOW.read_text()
        start = text.index(f"- name: {name}")
        end = text.find("\n      - name: ", start + 1)
        return text[start: end if end != -1 else len(text)]

    def take(self, derived: str | None, env_root: str | None = None, helper_exit: int = 0,
             helper: bool = True) -> tuple[int, str, list[str]]:
        with tempfile.TemporaryDirectory() as tmp:
            receipt = Path(tmp, "cmux-test-products.json")
            receipt.write_text("{}" if derived is None else '{"derived": "%s"}' % derived)
            calls = Path(tmp, "calls")
            fake = Path(tmp, "glaeda-canonical-root")
            fake.write_text(f'#!/bin/sh\necho "$*" >> "{calls}"\necho /ignored\nexit {helper_exit}\n')
            fake.chmod(0o755)
            env = {"PATH": os.environ["PATH"],
                   "CMUX_CI_CANONICAL_ROOT_HELPER": str(fake) if helper else str(Path(tmp, "missing"))}
            if env_root is not None:
                env["CMUX_CI_CANONICAL_ROOT"] = env_root
            result = subprocess.run([str(TAKE_ROOT), str(receipt)], env=env, capture_output=True, text=True)
            taken = calls.read_text().splitlines() if calls.exists() else []
            return result.returncode, result.stdout.strip(), taken

    def test_the_workflow_names_no_canonical_root_itself(self) -> None:
        # The root comes from the product's receipt, or CMUX_CI_CANONICAL_ROOT,
        # falling back to /private/tmp/cmux-ci only inside the helper.
        code = [line for line in WORKFLOW.read_text().splitlines() if not line.lstrip().startswith("#")]
        offending = [line for line in code if re.search(r"/private/tmp/cmux-ci\b", line)]
        self.assertEqual(offending, [])
        self.assertIn('root="${CMUX_CI_CANONICAL_ROOT:-/private/tmp/cmux-ci}"', TAKE_ROOT.read_text())
        rerun_env = WORKFLOW.read_text().split("\n  rerun:\n", 1)[1].split("\n    steps:\n", 1)[0]
        self.assertNotIn("CANONICAL_ROOT:", rerun_env)
        self.assertNotIn("COMPILE_DERIVED_DATA:", rerun_env)

    def test_the_root_is_held_before_its_derived_data_is_replaced(self) -> None:
        self.assertIn('"$helper" take "$root" --wait 1800', TAKE_ROOT.read_text())
        text = WORKFLOW.read_text()
        # One job-owned replacement, in the step that takes the root first.
        self.assertEqual(text.count('rm -rf "$COMPILE_DERIVED_DATA"'), 1)
        step = self.step("Unpack products at the path CI compiled them")
        self.assertLess(step.index("take-product-canonical-root.sh"), step.index('rm -rf "$COMPILE_DERIVED_DATA"'))
        self.assertIn('"$GITHUB_WORKSPACE/.rerun-tools/scripts/ci/take-product-canonical-root.sh"', step)
        # The products are unpacked beside the job, not over a root, until then.
        self.assertIn('-C "$staged"', step)
        self.assertLess(step.index('rm -rf "$COMPILE_DERIVED_DATA"'), step.index('mv "$staged" "$COMPILE_DERIVED_DATA"'))
        # canonical-resolve reads CMUX_CI_CANONICAL_ROOT, so it must agree.
        for name in ("CMUX_CI_CANONICAL_ROOT", "CANONICAL_ROOT", "COMPILE_DERIVED_DATA"):
            self.assertIn(f'echo "{name}=', step)
        # The tests run from DerivedData of this job's own, as the shard jobs do.
        self.assertIn('derived="$RUNNER_TEMP/cmux-derived-data-rerun"', self.step("Stage and validate products"))

    def test_the_helper_takes_the_producers_root(self) -> None:
        for root in ("/private/tmp/cmux-ci", "/private/tmp/cmux-ci-2", "/private/tmp/cmux-ci-12"):
            # The producer's root wins over the one glaeda handed this job.
            code, out, taken = self.take(f"{root}/derived-data-compile-admission", env_root="/private/tmp/cmux-ci-3")
            self.assertEqual((code, out, taken), (0, root, [f"take {root} --wait 1800"]), root)

    def test_a_receipt_without_a_canonical_root_keeps_this_jobs(self) -> None:
        # Blacksmith: nothing exported, so the historical root.
        self.assertEqual(self.take(None), (0, "/private/tmp/cmux-ci", ["take /private/tmp/cmux-ci --wait 1800"]))
        self.assertEqual(self.take("/Users/runner/elsewhere", env_root="/private/tmp/cmux-ci-2"),
                         (0, "/private/tmp/cmux-ci-2", ["take /private/tmp/cmux-ci-2 --wait 1800"]))
        for bad in ("/tmp/elsewhere", "/private/tmp/cmux-ci-x", "/private/tmp/cmux-ci/../x"):
            code, _, taken = self.take(None, env_root=bad)
            self.assertNotEqual(code, 0, bad)
            self.assertEqual(taken, [], bad)
        for bad in ("/private/tmp/cmux-ci-x/derived-data-compile-admission",
                    "/private/tmp/cmux-ci/../x/derived-data-compile-admission"):
            self.assertEqual(self.take(bad)[1], "/private/tmp/cmux-ci", bad)

    def test_ephemeral_runners_have_no_helper_and_a_busy_root_fails(self) -> None:
        self.assertEqual(self.take("/private/tmp/cmux-ci-2/derived-data-compile-admission", helper=False),
                         (0, "/private/tmp/cmux-ci-2", []))
        code, out, taken = self.take("/private/tmp/cmux-ci/derived-data-compile-admission", helper_exit=1)
        self.assertEqual((code, out), (1, ""))
        self.assertEqual(taken, ["take /private/tmp/cmux-ci --wait 1800"])


if __name__ == "__main__":
    unittest.main()
