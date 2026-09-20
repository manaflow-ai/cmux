#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SYNC = ROOT / "scripts" / "sync-test-wiring"
LINT = ROOT / "scripts" / "lint-pbxproj-test-wiring.sh"
NORMALIZER = ROOT / "scripts" / "normalize-pbxproj.py"
FIXTURES = ROOT / "tests" / "fixtures" / "pbxproj-test-wiring"


class SyncTestWiringTests(unittest.TestCase):
    def make_repo(self, fixture: str, files: list[str]) -> Path:
        tempdir = Path(tempfile.mkdtemp(prefix="cmux-sync-test-wiring-"))
        self.addCleanup(shutil.rmtree, tempdir, ignore_errors=True)
        (tempdir / "cmux.xcodeproj").mkdir()
        (tempdir / "cmuxTests").mkdir()
        shutil.copyfile(
            FIXTURES / fixture,
            tempdir / "cmux.xcodeproj" / "project.pbxproj",
        )
        for name in files:
            (tempdir / "cmuxTests" / name).write_text(
                "import Testing\n@Test func placeholder() {}\n", encoding="utf-8"
            )
        return tempdir

    def run_sync(self, repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [str(SYNC), "--repo-root", str(repo), *args],
            text=True,
            capture_output=True,
        )
        if check and result.returncode != 0:
            self.fail(
                f"sync failed ({result.returncode})\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        return result

    def run_lint(self, repo: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(LINT), "--repo-root", str(repo)],
            text=True,
            capture_output=True,
        )

    def project_text(self, repo: Path) -> str:
        return (repo / "cmux.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")

    def test_new_test_becomes_real_cmux_tests_member_and_lint_agrees(self) -> None:
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift", "NewTests.swift"])

        before = self.run_lint(repo)
        self.assertEqual(before.returncode, 1, before.stdout + before.stderr)
        self.assertIn("NewTests.swift", before.stdout + before.stderr)

        self.run_sync(repo)
        text = self.project_text(repo)
        self.assertIn("/* NewTests.swift */ = {isa = PBXFileReference;", text)
        self.assertIn("/* NewTests.swift in Sources */ = {isa = PBXBuildFile;", text)
        self.assertEqual(text.count("/* NewTests.swift */,"), 1)
        self.assertEqual(text.count("/* NewTests.swift in Sources */,"), 1)

        after = self.run_lint(repo)
        self.assertEqual(after.returncode, 0, after.stdout + after.stderr)
        self.assertIn("lint-pbxproj-test-wiring: ok", after.stdout)

    def test_new_entries_preserve_repo_pbxproj_normalization(self) -> None:
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift", "AlphaTests.swift"])
        self.run_sync(repo)
        result = subprocess.run(
            ["python3", str(NORMALIZER), "--check", str(repo / "cmux.xcodeproj" / "project.pbxproj")],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_blank_lines_in_sources_phase_stay_normalized(self) -> None:
        # The real project carries blank lines inside the cmuxTests Sources
        # `files` list, and the normalizer sorts them ahead of the entries.
        # Rewriting that list must leave them where the normalizer puts them,
        # or every sync produces a project that check-pbxproj.sh rejects.
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift", "AlphaTests.swift"])
        project = repo / "cmux.xcodeproj" / "project.pbxproj"
        text = project.read_text(encoding="utf-8")
        entry = "\t\t\t\t555555555555555555555555 /* ExistingTests.swift in Sources */,\n"
        self.assertEqual(text.count(entry), 1)
        project.write_text(text.replace(entry, "\n\n" + entry), encoding="utf-8")

        self.run_sync(repo)

        result = subprocess.run(
            ["python3", str(NORMALIZER), "--check", str(project)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("AlphaTests.swift in Sources", self.project_text(repo))

    def test_rerun_is_byte_for_byte_idempotent_and_check_is_clean(self) -> None:
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift", "NewTests.swift"])
        self.run_sync(repo)
        once = self.project_text(repo)
        second = self.run_sync(repo)
        twice = self.project_text(repo)
        self.assertEqual(once, twice)
        self.assertIn("sync-test-wiring: clean", second.stdout)
        checked = self.run_sync(repo, "--check")
        self.assertIn("sync-test-wiring: ok", checked.stdout)

    def test_incomplete_membership_is_repaired_including_dangling_source_id(self) -> None:
        repo = self.make_repo(
            "incomplete.pbxproj",
            ["ExistingTests.swift", "HalfWiredTests.swift", "DanglingTests.swift"],
        )
        check = self.run_sync(repo, "--check", check=False)
        self.assertEqual(check.returncode, 1)
        self.assertIn("HalfWiredTests.swift", check.stderr)
        self.assertIn("DanglingTests.swift", check.stderr)

        self.run_sync(repo)
        text = self.project_text(repo)
        self.assertIn(
            "ABABABABABABABABABABABAB /* DanglingTests.swift in Sources */ = {isa = PBXBuildFile;",
            text,
        )
        self.assertEqual(text.count("/* HalfWiredTests.swift in Sources */ = {isa = PBXBuildFile;"), 1)
        self.assertEqual(text.count("/* HalfWiredTests.swift in Sources */,"), 1)
        self.assertEqual(self.run_lint(repo).returncode, 0)

    def test_wrong_target_membership_is_rejected_without_writing(self) -> None:
        repo = self.make_repo(
            "wrong-target.pbxproj", ["ExistingTests.swift", "WrongTargetTests.swift"]
        )
        before = self.project_text(repo)
        result = self.run_sync(repo, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unexpected target(s): cmuxUITests", result.stderr)
        self.assertIn("refusing to change target membership", result.stderr)
        self.assertEqual(self.project_text(repo), before)

    def test_deleted_file_is_reported_by_check_then_pruned(self) -> None:
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift", "RemovedTests.swift"])
        self.run_sync(repo)
        (repo / "cmuxTests" / "RemovedTests.swift").unlink()

        check = self.run_sync(repo, "--check", check=False)
        self.assertEqual(check.returncode, 1)
        self.assertIn("removed deleted RemovedTests.swift from project wiring", check.stderr)

        self.run_sync(repo)
        self.assertNotIn("RemovedTests.swift", self.project_text(repo))
        self.assertEqual(self.run_sync(repo, "--check").returncode, 0)

    def test_generated_output_is_deterministic_across_creation_order(self) -> None:
        first = self.make_repo(
            "base.pbxproj", ["ExistingTests.swift", "AlphaTests.swift", "ZetaTests.swift"]
        )
        second = self.make_repo(
            "base.pbxproj", ["ExistingTests.swift", "ZetaTests.swift", "AlphaTests.swift"]
        )
        self.run_sync(first)
        self.run_sync(second)
        self.assertEqual(self.project_text(first), self.project_text(second))

    def test_same_target_duplicates_collapse_without_damaging_neighbor_objects(self) -> None:
        repo = self.make_repo("duplicate.pbxproj", ["ExistingTests.swift", "DuplicateTests.swift"])
        self.run_sync(repo)
        text = self.project_text(repo)
        self.assertEqual(text.count("/* DuplicateTests.swift */ = {isa = PBXFileReference;"), 1)
        self.assertEqual(text.count("/* DuplicateTests.swift in Sources */ = {isa = PBXBuildFile;"), 1)
        self.assertEqual(text.count("/* DuplicateTests.swift */,"), 1)
        self.assertEqual(text.count("/* DuplicateTests.swift in Sources */,"), 1)
        self.assertIn("ABCDEFABCDEFABCDEFABCDEF /* Neighbor.swift in Sources */", text)
        self.assertIn("FEDCBAFEDCBAFEDCBAFEDCBA /* Neighbor.swift */", text)

    def test_stale_comment_never_removes_an_unmanaged_source(self) -> None:
        for present in (True, False):
            with self.subTest(managed_file_present=present):
                repo = self.make_repo("base.pbxproj", ["ExistingTests.swift"] if present else [])
                project = repo / "cmux.xcodeproj/project.pbxproj"
                text = self.project_text(repo).replace(
                    "/* End PBXBuildFile section */",
                    "\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* ExistingTests.swift in Sources */ = "
                    "{isa = PBXBuildFile; fileRef = EEEEEEEEEEEEEEEEEEEEEEEE "
                    "/* ExternalPackageTests.swift */; };\n/* End PBXBuildFile section */",
                ).replace(
                    "files = (\n",
                    "files = (\n\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* ExistingTests.swift in Sources */,\n",
                    1,
                )
                project.write_text(text, encoding="utf-8")
                self.run_sync(repo)
                repaired = self.project_text(repo)
                self.assertIn("AAAAAAAAAAAAAAAAAAAAAAAA /* ExistingTests.swift in Sources */ =", repaired)
                self.assertIn("AAAAAAAAAAAAAAAAAAAAAAAA /* ExistingTests.swift in Sources */,", repaired)
                self.assertEqual(self.run_sync(repo, "--check").returncode, 0)

    def test_deleted_file_is_detected_after_its_group_child_was_removed(self) -> None:
        repo = self.make_repo("base.pbxproj", [])
        project = repo / "cmux.xcodeproj/project.pbxproj"
        project.write_text(self.project_text(repo).replace(
            "\t\t\t\t444444444444444444444444 /* ExistingTests.swift */,\n", ""
        ), encoding="utf-8")
        check = self.run_sync(repo, "--check", check=False)
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.run_sync(repo)
        text = self.project_text(repo)
        self.assertNotIn("444444444444444444444444", text)
        self.assertNotIn("555555555555555555555555", text)
        self.assertIn("EEEEEEEEEEEEEEEEEEEEEEEE", text)
        self.assertEqual(self.run_sync(repo, "--check").returncode, 0)

    def test_external_source_root_entry_is_preserved(self) -> None:
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift", "NewTests.swift"])
        before = self.project_text(repo)
        external_line = next(
            line for line in before.splitlines() if "ExternalPackageTests.swift */ =" in line
        )
        self.run_sync(repo)
        self.assertIn(external_line, self.project_text(repo))

    def test_dry_run_prints_diff_without_writing(self) -> None:
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift", "NewTests.swift"])
        before = self.project_text(repo)
        result = self.run_sync(repo, "--dry-run")
        self.assertIn("+++ cmux.xcodeproj/project.pbxproj", result.stdout)
        self.assertIn("NewTests.swift", result.stdout)
        self.assertEqual(self.project_text(repo), before)


    def test_generated_path_quotes_openstep_sensitive_filename(self) -> None:
        repo = self.make_repo(
            "base.pbxproj", ["ExistingTests.swift", "Foo+BarTests.swift"]
        )
        self.run_sync(repo)
        text = self.project_text(repo)
        self.assertIn('path = "Foo+BarTests.swift";', text)
        self.assertEqual(self.run_lint(repo).returncode, 0)

    def test_stale_build_and_sources_comments_are_repaired_by_identity(self) -> None:
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift"])
        project = repo / "cmux.xcodeproj" / "project.pbxproj"
        text = self.project_text(repo).replace(
            "ExistingTests.swift in Sources", "StaleDisplayName.swift in Sources"
        )
        project.write_text(text, encoding="utf-8")

        check = self.run_sync(repo, "--check", check=False)
        self.assertEqual(check.returncode, 1)
        self.run_sync(repo)
        repaired = self.project_text(repo)
        self.assertNotIn("StaleDisplayName.swift in Sources", repaired)
        self.assertEqual(
            repaired.count(
                "/* ExistingTests.swift in Sources */ = {isa = PBXBuildFile;"
            ),
            1,
        )
        self.assertEqual(
            repaired.count("/* ExistingTests.swift in Sources */,"),
            1,
        )
        self.assertEqual(self.run_lint(repo).returncode, 0)

    def test_second_same_path_ref_in_foreign_target_is_rejected(self) -> None:
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift"])
        project = repo / "cmux.xcodeproj" / "project.pbxproj"
        text = self.project_text(repo)
        text = text.replace(
            "/* End PBXBuildFile section */",
            "\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* ExistingTests.swift in Sources */ = "
            "{isa = PBXBuildFile; fileRef = CCCCCCCCCCCCCCCCCCCCCCCC "
            "/* ExistingTests.swift */; };\n/* End PBXBuildFile section */",
        )
        text = text.replace(
            "/* End PBXFileReference section */",
            "\t\tCCCCCCCCCCCCCCCCCCCCCCCC /* ExistingTests.swift */ = "
            '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
            'path = ExistingTests.swift; sourceTree = "<group>"; };\n'
            "/* End PBXFileReference section */",
        )
        text = text.replace(
            "\t\t777777777777777777777777 /* Sources */ = {\n"
            "\t\t\tisa = PBXSourcesBuildPhase;\n"
            "\t\t\tfiles = (\n"
            "\t\t\t);",
            "\t\t777777777777777777777777 /* Sources */ = {\n"
            "\t\t\tisa = PBXSourcesBuildPhase;\n"
            "\t\t\tfiles = (\n"
            "\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB "
            "/* ExistingTests.swift in Sources */,\n"
            "\t\t\t);",
        )
        project.write_text(text, encoding="utf-8")

        before = self.project_text(repo)
        result = self.run_sync(repo, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unexpected target(s)", result.stderr)
        self.assertEqual(self.project_text(repo), before)

    def test_multiline_file_reference_is_parsed_without_duplicate_creation(self) -> None:
        repo = self.make_repo("base.pbxproj", ["ExistingTests.swift"])
        project = repo / "cmux.xcodeproj" / "project.pbxproj"
        text = self.project_text(repo)
        old = (
            "\t\t444444444444444444444444 /* ExistingTests.swift */ = "
            '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
            'path = ExistingTests.swift; sourceTree = "<group>"; };'
        )
        new = (
            "\t\t444444444444444444444444 /* ExistingTests.swift */ = {\n"
            "\t\t\tisa = PBXFileReference;\n"
            "\t\t\tlastKnownFileType = sourcecode.swift;\n"
            "\t\t\tpath = ExistingTests.swift;\n"
            '\t\t\tsourceTree = "<group>";\n'
            "\t\t};"
        )
        self.assertIn(old, text)
        project.write_text(text.replace(old, new), encoding="utf-8")

        checked = self.run_sync(repo, "--check")
        self.assertEqual(checked.returncode, 0)
        repaired = self.project_text(repo)
        self.assertEqual(repaired.count("/* ExistingTests.swift */ = {"), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
