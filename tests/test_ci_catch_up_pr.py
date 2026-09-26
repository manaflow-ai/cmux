#!/usr/bin/env python3
"""PR catch-up (RFC #14631, slice 1): merge the base, resolve only generated files.

Each case builds a small git repository in a temp dir with a base branch and a
pull request branch, runs scripts/ci/catch_up_pr.py through its CLI the way
the workflow does, and checks both the JSON result and the repository it left
behind: a merge commit with the resolved files, or an untouched head with the
blocking files named. The real normalizer, schema generator and xcstrings
merger resolve conflicts; a stub tools root stands in for a failing generator.

The last cases read .github/workflows/pr-catch-up.yml: it runs on
pull_request_target, issue_comment and main's green CI fast guards runs next
to a write token, so it must only execute the trusted base checkout's scripts
and never interpolate event text into a shell.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/catch_up_pr.py"
WORKFLOW = ROOT / ".github/workflows/pr-catch-up.yml"
SPEC = importlib.util.spec_from_file_location("catch_up_pr", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

# Isolated from the developer's git config (a configured xcstrings driver or
# hooks path would change what the merge does), with auto maintenance off:
# a background `git maintenance` makes the temp dir cleanup flaky.
GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_AUTHOR_NAME": "Catch Up Test",
    "GIT_AUTHOR_EMAIL": "catch-up@example.invalid",
    "GIT_COMMITTER_NAME": "Catch Up Test",
    "GIT_COMMITTER_EMAIL": "catch-up@example.invalid",
}

PBX_HEADER = "// !$*UTF8*$!\n{\n\tobjectVersion = 60;\n\tobjects = {\n\n"
PBX_FOOTER = "\t};\n\trootObject = R00000000000000000000000 /* Project object */;\n}\n"


def pbxproj_ids(files: dict[str, int]) -> str:
    """A small normalized project whose app target compiles `files` (name to object id number)."""
    build, refs, phase = [], [], []
    for name, number in files.items():
        build_id, ref_id = f"B{number:023d}", f"F{number:023d}"
        build.append(f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n")
        refs.append(f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n")
        phase.append(f"\t\t\t\t{build_id} /* {name} in Sources */,\n")
    return (
        PBX_HEADER
        + "/* Begin PBXBuildFile section */\n" + "".join(build) + "/* End PBXBuildFile section */\n\n"
        + "/* Begin PBXFileReference section */\n" + "".join(refs) + "/* End PBXFileReference section */\n\n"
        + "/* Begin PBXSourcesBuildPhase section */\n"
        + "\t\tS00000000000000000000000 /* Sources */ = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tfiles = (\n"
        + "".join(phase) + "\t\t\t);\n\t\t};\n/* End PBXSourcesBuildPhase section */\n"
        + PBX_FOOTER
    )


def unit(value: str) -> dict:
    return {"localizations": {"en": {"stringUnit": {"state": "translated", "value": value}}}}


def catalog(**strings: str) -> str:
    document = {"sourceLanguage": "en", "strings": {k: unit(v) for k, v in strings.items()}, "version": "1.0"}
    return json.dumps(document, ensure_ascii=False, indent=2) + "\n"


def schema(a: int, z: int) -> str:
    # Unchanged lines between "a" and "z" let git merge edits to each cleanly.
    return f'{{\n  "a": {a},\n  "m1": 0,\n  "m2": 0,\n  "m3": 0,\n  "z": {z}\n}}\n'


class Fixture:
    """A repository with `main` and a `pr` branch checked out."""

    def __init__(self, root: Path) -> None:
        self.path = root / "repo"
        self.path.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "maintenance.auto", "false")
        self.git("config", "gc.auto", "0")

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "maintenance.auto=false", "-c", "gc.auto=0", *args],
            cwd=self.path, env=GIT_ENV, check=True, capture_output=True, text=True,
        ).stdout.strip()

    def write(self, files: dict[str, str]) -> None:
        for name, text in files.items():
            path = self.path / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")

    def commit(self, files: dict[str, str], message: str) -> str:
        self.write(files)
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def regenerate_schema(self) -> None:
        (self.path / MODULE.SCHEMA_SWIFT).parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [sys.executable, str(ROOT / MODULE.SCHEMA_GENERATOR), "--root", str(self.path)],
            check=True, capture_output=True,
        )

    def branches(self, base: dict, main: dict, pr: dict, schema_regen: bool = False) -> None:
        self.write(base)
        if schema_regen:
            self.regenerate_schema()
        self.commit({}, "base")
        self.git("checkout", "-q", "-b", "pr")
        self.write(pr)
        if schema_regen:
            self.regenerate_schema()
        self.commit({}, "pr change")
        self.git("checkout", "-q", "main")
        self.write(main)
        if schema_regen:
            self.regenerate_schema()
        self.commit({}, "main change")
        self.git("checkout", "-q", "pr")

    def read(self, name: str) -> str:
        return (self.path / name).read_text(encoding="utf-8")


class CatchUpCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = Fixture(self.tmp)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def catch_up(self, tools_root: Path = ROOT) -> tuple[int, dict]:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "merge", "--base", "main", "--repo", str(self.repo.path),
             "--tools-root", str(tools_root), "--json", "--note", "Requested in a test."],
            env=GIT_ENV, capture_output=True, text=True,
        )
        return completed.returncode, json.loads(completed.stdout)

    def assert_merged(self, code: int, result: dict, before: str) -> None:
        self.assertEqual((code, result["status"]), (0, "merged"), result)
        self.assertEqual(result["blocking"], [])
        head = self.repo.git("rev-parse", "HEAD")
        self.assertEqual(result["head_after"], head)
        parents = self.repo.git("rev-list", "--parents", "-n", "1", "HEAD").split()[1:]
        self.assertEqual(parents, [before, self.repo.git("rev-parse", "main")])
        self.assertEqual(self.repo.git("status", "--porcelain"), "")
        message = self.repo.git("log", "-1", "--format=%B")
        self.assertIn(f"Catch-up-previous-head: {before}", message)
        self.assertIn("Requested in a test.", message)

    def assert_blocked(self, code: int, result: dict, before: str, paths: list[str]) -> None:
        self.assertEqual((code, result["status"]), (1, "blocked"), result)
        self.assertEqual([item["path"] for item in result["blocking"]], paths)
        self.assertEqual(self.repo.git("rev-parse", "HEAD"), before, "a blocked catch-up must not commit")
        self.assertEqual(self.repo.git("status", "--porcelain"), "", "the merge must be aborted")
        with self.assertRaises(subprocess.CalledProcessError):
            self.repo.git("rev-parse", "--verify", "--quiet", "MERGE_HEAD")


class MergeTests(CatchUpCase):
    def test_clean_merge_commits_a_no_ff_merge(self) -> None:
        self.repo.branches({"a.txt": "a\n", "b.txt": "b\n"}, {"a.txt": "main\n"}, {"b.txt": "pr\n"})
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_merged(code, result, before)
        self.assertEqual(result["resolved"], [])
        self.assertEqual((self.repo.read("a.txt"), self.repo.read("b.txt")), ("main\n", "pr\n"))

    def test_up_to_date_head_is_left_alone(self) -> None:
        self.repo.commit({"a.txt": "a\n"}, "base")
        self.repo.git("checkout", "-q", "-b", "pr")
        before = self.repo.commit({"a.txt": "pr\n"}, "pr change")
        code, result = self.catch_up()
        self.assertEqual((code, result["status"], result["head_after"]), (0, "up_to_date", before))
        self.assertEqual(self.repo.git("rev-parse", "HEAD"), before)

    def test_dirty_tree_is_an_error_not_a_merge(self) -> None:
        self.repo.branches({"a.txt": "a\n"}, {"a.txt": "main\n"}, {"b.txt": "pr\n"})
        self.repo.write({"b.txt": "uncommitted\n"})
        code, result = self.catch_up()
        self.assertEqual((code, result["status"]), (2, "error"), result)
        self.assertIn("uncommitted", result["message"])

    def test_unknown_conflict_stops_and_names_the_file(self) -> None:
        self.repo.branches(
            {"README.md": "one\n", "Resources/Localizable.xcstrings": catalog(a="A")},
            {"README.md": "main\n", "Resources/Localizable.xcstrings": catalog(a="A", b="B")},
            {"README.md": "pr\n", "Resources/Localizable.xcstrings": catalog(a="A", c="C")},
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, ["README.md"])
        self.assertIn("not a generated file", result["blocking"][0]["reason"])

    def test_one_sided_delete_stops(self) -> None:
        self.repo.branches({"a.txt": "a\n"}, {"a.txt": "main\n"}, {"b.txt": "pr\n"})
        self.repo.git("rm", "-q", "a.txt")
        self.repo.git("commit", "-q", "-m", "delete on pr")
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, ["a.txt"])
        self.assertIn("deleted on one side", result["blocking"][0]["reason"])


class UntrustedTreeTests(CatchUpCase):
    """The head is untrusted: its attributes and symlinks must not steer the merge."""

    def test_head_gitattributes_cannot_choose_the_union_driver(self) -> None:
        self.repo.branches(
            {"app.swift": "let a = 1\n"},
            {"app.swift": "let a = 2\n"},
            {"app.swift": "let a = 3\n", ".gitattributes": "* merge=union\n"},
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, ["app.swift"])

    def test_symlinked_schema_is_not_read_into_the_commit(self) -> None:
        secret = self.tmp / "secret.txt"
        secret.write_text("RUNNER SECRET\n", encoding="utf-8")
        self.repo.branches({MODULE.SCHEMA_JSON: schema(1, 1), "README.md": "a\n"}, {"README.md": "main\n"}, {},
                           schema_regen=True)
        link = self.repo.path / MODULE.SCHEMA_JSON
        link.unlink()
        link.symlink_to(secret)
        self.repo.commit({}, "schema becomes a symlink")
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, [MODULE.SCHEMA_SWIFT])
        self.assertIn("symlink", result["blocking"][0]["reason"])

    def test_symlinked_generated_swift_is_not_written_through(self) -> None:
        victim = self.tmp / "victim.txt"
        victim.write_text("untouched\n", encoding="utf-8")
        self.repo.branches(
            {MODULE.SCHEMA_JSON: schema(1, 1)},
            {MODULE.SCHEMA_JSON: schema(2, 1)},
            {MODULE.SCHEMA_JSON: schema(1, 2)},
            schema_regen=True,
        )
        swift = self.repo.path / MODULE.SCHEMA_SWIFT
        swift.unlink()
        swift.symlink_to(victim)
        self.repo.commit({}, "generated Swift becomes a symlink")
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        # Git also lists the symlink side under `<path>~<commit>` for the type conflict.
        blocked = [item["path"] for item in result["blocking"]]
        self.assert_blocked(code, result, before, blocked)
        self.assertEqual(blocked[0], MODULE.SCHEMA_SWIFT)
        self.assertEqual(victim.read_text(encoding="utf-8"), "untouched\n")

    def test_non_utf8_catalog_blocks_instead_of_crashing(self) -> None:
        path = "Resources/Localizable.xcstrings"
        self.repo.branches({path: catalog(a="A")}, {path: catalog(a="A", b="B")}, {})
        (self.repo.path / path).write_bytes(b"\xff\xfe not utf-8\n")
        self.repo.commit({}, "binary catalog")
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, [path])


class XcstringsTests(CatchUpCase):
    PATH = "Resources/Localizable.xcstrings"

    def test_disjoint_keys_union(self) -> None:
        self.repo.branches(
            {self.PATH: catalog(a="A", z="Z")},
            {self.PATH: catalog(a="A", b="B", z="Z")},
            {self.PATH: catalog(a="A", c="C", z="Z")},
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_merged(code, result, before)
        self.assertEqual([item["path"] for item in result["resolved"]], [self.PATH])
        strings = json.loads(self.repo.read(self.PATH))["strings"]
        self.assertEqual(set(strings), {"a", "b", "c", "z"})

    def test_same_key_changed_on_both_sides_stops(self) -> None:
        self.repo.branches(
            {self.PATH: catalog(a="A", z="Z")},
            {self.PATH: catalog(a="main A", z="Z")},
            {self.PATH: catalog(a="pr A", z="Z")},
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, [self.PATH])
        self.assertIn("strings.a", result["blocking"][0]["reason"])
        comment = MODULE.render_comment(result, "not-attempted", "main", "pr", "")
        self.assertIn("both sides: `strings.a`", comment)


class SchemaTests(CatchUpCase):
    def test_conflicting_generated_swift_is_regenerated_from_merged_schema(self) -> None:
        self.repo.branches(
            {MODULE.SCHEMA_JSON: schema(1, 1)},
            {MODULE.SCHEMA_JSON: schema(2, 1)},
            {MODULE.SCHEMA_JSON: schema(1, 2)},
            schema_regen=True,
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_merged(code, result, before)
        self.assertEqual([item["path"] for item in result["resolved"]], [MODULE.SCHEMA_SWIFT])
        self.assertEqual(self.repo.read(MODULE.SCHEMA_JSON), schema(2, 2))
        check = subprocess.run(
            [sys.executable, str(ROOT / MODULE.SCHEMA_GENERATOR), "--root", str(self.repo.path), "--check"],
            capture_output=True, text=True,
        )
        self.assertEqual(check.returncode, 0, check.stdout)

    def test_conflicting_schema_source_stops(self) -> None:
        self.repo.branches(
            {MODULE.SCHEMA_JSON: schema(1, 1)},
            {MODULE.SCHEMA_JSON: schema(2, 1)},
            {MODULE.SCHEMA_JSON: schema(3, 1)},
            schema_regen=True,
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, [MODULE.SCHEMA_JSON, MODULE.SCHEMA_SWIFT])

    def test_invalid_merged_schema_is_not_regenerated(self) -> None:
        # Each side's edit is valid JSON; their clean textual merge is not.
        base = '{\n  "a": 1,\n  "m1": 0,\n  "m2": 0,\n  "m3": 0,\n  "z": 1\n}\n'
        self.repo.branches(
            {MODULE.SCHEMA_JSON: base},
            {MODULE.SCHEMA_JSON: base.replace('"a": 1,', '"a": 2')},
            {MODULE.SCHEMA_JSON: base.replace('"z": 1', '"z": 2,\n  "y": 3')},
            schema_regen=False,
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, [MODULE.SCHEMA_SWIFT])
        self.assertIn("not valid JSON", result["blocking"][0]["reason"])

    def test_generator_failure_stops(self) -> None:
        tools = self.tmp / "tools"
        for script in (MODULE.NORMALIZER, MODULE.XCSTRINGS_MERGER):
            (tools / script).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / script, tools / script)
        (tools / MODULE.SCHEMA_GENERATOR).write_text(
            "import sys\nprint('stub generator broke', file=sys.stderr)\nsys.exit(3)\n", encoding="utf-8",
        )
        self.repo.branches(
            {MODULE.SCHEMA_JSON: schema(1, 1)},
            {MODULE.SCHEMA_JSON: schema(2, 1)},
            {MODULE.SCHEMA_JSON: schema(1, 2)},
            schema_regen=True,
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up(tools_root=tools)
        self.assert_blocked(code, result, before, [MODULE.SCHEMA_SWIFT])
        self.assertIn("stub generator broke", result["blocking"][0]["reason"])

    def test_tree_generator_is_never_run(self) -> None:
        # The pull request's own generator must not run, even when it is the
        # only copy of the file in the merged tree.
        canary = self.tmp / "ran"
        hostile = f"from pathlib import Path\nPath({str(canary)!r}).write_text('ran')\n"
        self.repo.branches(
            {MODULE.SCHEMA_JSON: schema(1, 1), MODULE.SCHEMA_GENERATOR: hostile, MODULE.NORMALIZER: hostile},
            {MODULE.SCHEMA_JSON: schema(2, 1)},
            {MODULE.SCHEMA_JSON: schema(1, 2)},
            schema_regen=True,
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_merged(code, result, before)
        self.assertFalse(canary.exists(), "catch-up ran a script from the merged tree")


class PbxprojTests(CatchUpCase):
    def test_both_sides_adding_files_union_and_normalize(self) -> None:
        self.repo.branches(
            {MODULE.PBXPROJ: pbxproj_ids({"A.swift": 1})},
            {MODULE.PBXPROJ: pbxproj_ids({"A.swift": 1, "B.swift": 2})},
            {MODULE.PBXPROJ: pbxproj_ids({"A.swift": 1, "C.swift": 3})},
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_merged(code, result, before)
        self.assertEqual([item["path"] for item in result["resolved"]], [MODULE.PBXPROJ])
        self.assertEqual(self.repo.read(MODULE.PBXPROJ), pbxproj_ids({"A.swift": 1, "B.swift": 2, "C.swift": 3}))

    def test_same_file_added_on_both_sides_is_one_entry(self) -> None:
        self.repo.branches(
            {MODULE.PBXPROJ: pbxproj_ids({"A.swift": 1})},
            {MODULE.PBXPROJ: pbxproj_ids({"A.swift": 1, "B.swift": 2, "D.swift": 4})},
            {MODULE.PBXPROJ: pbxproj_ids({"A.swift": 1, "B.swift": 2, "C.swift": 3})},
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_merged(code, result, before)
        self.assertEqual(
            self.repo.read(MODULE.PBXPROJ),
            pbxproj_ids({"A.swift": 1, "B.swift": 2, "C.swift": 3, "D.swift": 4}),
        )

    def test_changed_line_on_both_sides_stops(self) -> None:
        base = pbxproj_ids({"A.swift": 1})
        self.repo.branches(
            {MODULE.PBXPROJ: base},
            {MODULE.PBXPROJ: base.replace("objectVersion = 60", "objectVersion = 70")},
            {MODULE.PBXPROJ: base.replace("objectVersion = 60", "objectVersion = 77")},
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, [MODULE.PBXPROJ])

    def test_colliding_object_ids_stop(self) -> None:
        # Two branches that minted the same object id for different files: the
        # union is well formed text, and the normalizer must reject it.
        self.repo.branches(
            {MODULE.PBXPROJ: pbxproj_ids({"A.swift": 1})},
            {MODULE.PBXPROJ: pbxproj_ids({"A.swift": 1, "B.swift": 2})},
            {MODULE.PBXPROJ: pbxproj_ids({"A.swift": 1, "C.swift": 2})},
        )
        before = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assert_blocked(code, result, before, [MODULE.PBXPROJ])
        self.assertIn("added the same entry differently", result["blocking"][0]["reason"])

    def union_of(self, ours_lines: str, theirs_lines: str) -> str:
        head = ("// !$*UTF8*$!\n{\n\tobjects = {\n\t\tCFG /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n"
                "\t\t\tbuildSettings = {\n\t\t\t\tPRODUCT_NAME = cmux;\n")
        tail = "\t\t\t\tSDKROOT = macosx;\n\t\t\t};\n\t\t\tname = Debug;\n\t\t};\n\t};\n\trootObject = CFG;\n}\n"
        return MODULE.union_pbxproj(head + tail, head + ours_lines + tail, head + theirs_lines + tail)

    def test_same_setting_added_with_different_values_stops(self) -> None:
        with self.assertRaisesRegex(ValueError, "repeats a key: SWIFT_VERSION"):
            self.union_of("\t\t\t\tSWIFT_VERSION = 6.0;\n", "\t\t\t\tSWIFT_VERSION = 5.0;\n")
        merged = self.union_of("\t\t\t\tA_FLAG = 1;\n", "\t\t\t\tB_FLAG = 2;\n")
        self.assertIn("A_FLAG = 1;", merged)
        self.assertIn("B_FLAG = 2;", merged)

    def test_setting_added_as_a_list_and_a_scalar_stops(self) -> None:
        # A multi-line `KEY = (` is a key too (security review repro, case 1).
        with self.assertRaisesRegex(ValueError, "OTHER_SWIFT_FLAGS"):
            self.union_of('\t\t\t\tOTHER_SWIFT_FLAGS = (\n\t\t\t\t\t"-DFOO",\n\t\t\t\t);\n',
                          '\t\t\t\tOTHER_SWIFT_FLAGS = "-DBAR";\n')

    def test_repeated_setting_next_to_an_added_list_stops(self) -> None:
        # One side also opens a list, which used to switch the settings check
        # off (security review repro, case 2).
        with self.assertRaisesRegex(ValueError, "SWIFT_VERSION"):
            self.union_of('\t\t\t\tSWIFT_VERSION = 6.0;\n\t\t\t\tLD_FLAGS = (\n\t\t\t\t\t"-x",\n\t\t\t\t);\n',
                          "\t\t\t\tSWIFT_VERSION = 5.0;\n")

    def test_duplicate_keys_sees_every_dictionary(self) -> None:
        text = "{ a = 1; b = { c = (x, y); c = 2; }; d = { a = 1; }; }"
        self.assertEqual(MODULE.duplicate_keys(text), ["c"])


class VerifyTests(CatchUpCase):
    """The push job's own check of the merge commit (`catch_up_pr.py verify`)."""

    PATH = "Resources/Localizable.xcstrings"

    def merged(self) -> tuple[str, str, str]:
        self.repo.branches(
            {self.PATH: catalog(a="A", z="Z"), "app.txt": "a\n"},
            {self.PATH: catalog(a="A", b="B", z="Z"), "app.txt": "main\n"},
            {self.PATH: catalog(a="A", c="C", z="Z")},
        )
        head = self.repo.git("rev-parse", "HEAD")
        code, result = self.catch_up()
        self.assertEqual(code, 0, result)
        return head, self.repo.git("rev-parse", "main"), result["head_after"]

    def verify(self, head: str, base: str, merged: str, tip: str = "main") -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "verify", "--repo", str(self.repo.path), "--head", head,
             "--base", base, "--merged", merged, "--base-tip", tip],
            env=GIT_ENV, capture_output=True, text=True,
        )

    def test_real_catch_up_merge_passes(self) -> None:
        head, base, merged = self.merged()
        completed = self.verify(head, base, merged)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_extra_change_in_the_merge_fails(self) -> None:
        head, base, merged = self.merged()
        self.repo.write({"app.txt": "sneaky\n"})
        self.repo.git("add", "-A")
        self.repo.git("commit", "-q", "--amend", "--no-edit")
        tampered = self.repo.git("rev-parse", "HEAD")
        completed = self.verify(head, base, tampered)
        self.assertEqual(completed.returncode, 1)
        self.assertIn("app.txt differs", completed.stderr)

    def test_wrong_parents_fail(self) -> None:
        head, base, merged = self.merged()
        completed = self.verify(base, head, merged)
        self.assertEqual(completed.returncode, 1)
        self.assertIn("merge parents", completed.stderr)
        completed = self.verify(head, base, head)
        self.assertEqual(completed.returncode, 1)

    def test_base_off_the_base_branch_fails(self) -> None:
        head, base, merged = self.merged()
        self.repo.git("branch", "-f", "rewound", "main~1")
        completed = self.verify(head, base, merged, tip="rewound")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("not on the base branch", completed.stderr)


class CommentTests(unittest.TestCase):
    def test_blocked_comment_lists_files_inertly(self) -> None:
        result = {"status": "blocked", "base": "a" * 40,
                  "blocking": [{"path": "evil`@team.md", "reason": "changed by @someone"}]}
        text = MODULE.render_comment(result, "not-attempted", "main", "feature", "https://run")
        self.assertIn("`evil'@team.md`", text)
        self.assertNotIn("@someone", text)
        self.assertIn("Nothing was pushed", text)
        self.assertNotIn("\u2014", text)

    def test_automatic_comment_is_marked_with_the_tried_head(self) -> None:
        head = "c" * 40
        result = {"status": "blocked", "base": "a" * 40, "blocking": [{"path": "README.md", "reason": "not generated"}]}
        text = MODULE.render_auto_comment(result, "not-attempted", "main", "feature", "https://run", head)
        self.assertTrue(text.startswith(f"<!-- cmux-auto-catch-up head={head} -->\n"), text)
        self.assertIn("will not try this head again", text)
        self.assertIn("no-auto-catch-up", text)
        self.assertTrue(text.endswith("[Catch-up run](https://run)</sub>"), "the run link stays last")
        # Posted on many pull requests: no mention, no issue cross-reference.
        self.assertNotIn("@", text)
        self.assertNotIn("#", text.replace("<!-- cmux-auto-catch-up", ""))
        self.assertNotIn("\u2014", text)

    def test_automatic_push_comment_says_how_to_pull(self) -> None:
        result = {"status": "merged", "base": "a" * 40, "head_after": "b" * 40, "resolved": []}
        text = MODULE.render_auto_comment(result, "pushed", "main", "feature", "", "c" * 40)
        self.assertIn("Caught `feature` up", text)
        self.assertIn("git pull --no-rebase", text)
        self.assertIn("do not force-push", text)

    def test_automatic_path_stays_silent_when_nobody_must_act(self) -> None:
        merged = {"status": "merged", "base": "a" * 40, "head_after": "b" * 40}
        for push in ("rejected", "unverified", "skipped-no-app-token"):
            self.assertEqual(MODULE.render_auto_comment(merged, push, "main", "f", "", "c" * 40), "", push)
        self.assertEqual(MODULE.render_auto_comment({"status": "up_to_date"}, "not-attempted", "main", "f", "",
                                                    "c" * 40), "")
        # No head to key the marker on: saying something would repeat every run.
        blocked = {"status": "blocked", "blocking": []}
        self.assertEqual(MODULE.render_auto_comment(blocked, "not-attempted", "main", "f", "", ""), "")
        self.assertTrue(MODULE.render_auto_comment(merged, "needs-workflows", "main", "f", "", "c" * 40))
        self.assertTrue(MODULE.render_auto_comment(merged, "push-denied", "main", "f", "", "c" * 40))

    def test_automatic_path_stays_silent_on_an_error_or_no_result(self) -> None:
        # A lost runner or a crash is not something the author must fix, and
        # a marker would stop every later attempt on this head.
        for result in ({"status": "error", "message": "git failed"}, {}, {"status": ""}, {"status": "weird"}):
            for push in ("not-attempted", "unverified"):
                self.assertEqual(MODULE.render_auto_comment(result, push, "main", "f", "", "c" * 40), "",
                                 (result, push))
        with tempfile.TemporaryDirectory() as tmp:
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "comment", "--result", str(Path(tmp) / "missing.json"),
                 "--push", "not-attempted", "--auto", "--head-sha", "c" * 40], capture_output=True, text=True)
        self.assertEqual((completed.returncode, completed.stdout), (0, ""))

    def test_blocked_paths_cannot_mention_anyone(self) -> None:
        result = {"status": "blocked", "base": "a" * 40,
                  "blocking": [{"path": "@team/x.swift", "reason": "ask @someone about #12"}]}
        text = MODULE.render_auto_comment(result, "not-attempted", "main", "f", "", "c" * 40)
        self.assertIn("`@team/x.swift`", text, "a path is inline code")
        self.assertNotRegex(text, r"(?<![`\u200b])@someone")

    def test_automatic_comment_cli_prints_nothing_when_silent(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = Path(tmp) / "result.json"
            result.write_text(json.dumps({"status": "up_to_date"}), encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "comment", "--result", str(result), "--push", "not-attempted",
                 "--auto", "--head-sha", "c" * 40], capture_output=True, text=True)
        self.assertEqual((completed.returncode, completed.stdout), (0, ""))

    def test_pushed_without_ci_says_so(self) -> None:
        result = {"status": "merged", "base": "a" * 40, "head_after": "b" * 40,
                  "resolved": [{"path": "x.xcstrings", "method": "xcstrings key-level union"}]}
        text = MODULE.render_comment(result, "pushed-without-ci", "main", "feature", "")
        self.assertIn("`bbbbbbbbbbbb`", text)
        self.assertIn("CI will not start on its own", text)


class ReadResultTests(unittest.TestCase):
    """catch_up_pr.py read-result: the push job's only reader of the merge job's artifact."""

    HEAD, BASE, MERGED = "a" * 40, "b" * 40, "c" * 40

    def good(self, **changes: object) -> dict:
        return {"refusal": "", "head_ref": "feature/x", "head_sha": self.HEAD, "base_ref": "main",
                "status": "merged", "base_sha": self.BASE, "merged_sha": self.MERGED, **changes}

    def read(self, data: object, pin: str = "", raw: str | None = None) -> tuple[dict[str, str], str]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "outputs.json"
            path.write_text(raw if raw is not None else json.dumps(data), encoding="utf-8")
            completed = subprocess.run([sys.executable, "-I", str(SCRIPT), "read-result", "--file", str(path),
                                        "--pin", pin], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        lines = completed.stdout.splitlines()
        self.assertTrue(all("=" in line for line in lines), lines)
        return dict(line.split("=", 1) for line in lines), completed.stderr

    def test_valid_result_passes_through(self) -> None:
        outputs, _ = self.read(self.good(), pin=self.HEAD)
        self.assertEqual(outputs, {"status": "merged", "head_sha": self.HEAD, "base_sha": self.BASE,
                                   "merged_sha": self.MERGED, "head_ref": "feature/x", "base_ref": "main"})

    def test_line_break_cannot_add_an_output(self) -> None:
        outputs, _ = self.read(self.good(head_ref="x\nmerged_sha=" + "d" * 40, status="merged\nok=true"))
        self.assertEqual(outputs["head_ref"], "")
        self.assertEqual(outputs["status"], "")
        self.assertEqual(outputs["merged_sha"], self.MERGED)
        self.assertNotIn("ok", outputs)

    def test_bad_commit_id_yields_nothing_to_push(self) -> None:
        for key in ("head_sha", "base_sha", "merged_sha"):
            for bad in ("A" * 40, "a" * 39, "--upload-pack=x", "HEAD"):
                outputs, warning = self.read(self.good(**{key: bad}))
                self.assertNotIn("merged_sha", outputs, (key, bad))
                self.assertIn(f"bad commit id in {key}", warning)

    def test_bad_branch_names_yield_nothing_to_push(self) -> None:
        for bad in ("../main", "-x", "a b", "refs/heads/../x", "x..y", "x.lock"):
            outputs, warning = self.read(self.good(head_ref=bad))
            self.assertNotIn("status", outputs, bad)
            self.assertIn("bad branch name in head_ref", warning)

    def test_unknown_status_reads_as_error(self) -> None:
        outputs, _ = self.read(self.good(status="pushed"))
        self.assertEqual(outputs["status"], "error")

    def test_result_for_another_head_than_the_pin(self) -> None:
        outputs, warning = self.read(self.good(), pin="e" * 40)
        self.assertEqual(outputs, {})
        self.assertIn("another head", warning)

    def test_refusal_is_one_line_without_workflow_commands(self) -> None:
        outputs, _ = self.read({"refusal": "closed ::error::x"})
        self.assertEqual(outputs, {"status": "", "head_sha": "", "base_sha": "", "merged_sha": "", "head_ref": "",
                                   "base_ref": "", "refusal": "closed :error:x"})
        outputs, _ = self.read({"refusal": "one\n::set-output name=x::y"})
        self.assertNotIn("refusal", outputs)
        outputs, _ = self.read({"refusal": "x" * 5000})
        self.assertEqual(len(outputs["refusal"]), MODULE.REFUSAL_LIMIT)

    def test_missing_or_unreadable_file_is_no_answer(self) -> None:
        outputs, warning = self.read(None, raw="{not json")
        self.assertEqual(outputs, {})
        self.assertIn("not an object", warning)
        outputs, _ = self.read(["merged"])
        self.assertEqual(outputs, {})
        completed = subprocess.run([sys.executable, "-I", str(SCRIPT), "read-result", "--file", "/nonexistent/x.json"],
                                   capture_output=True, text=True)
        self.assertEqual((completed.returncode, completed.stdout), (0, ""))


def upload_step(job: dict) -> dict:
    return next(step for step in job["steps"] if "upload-artifact" in str(step.get("uses")))


def run_steps(workflow: dict) -> list[dict]:
    return [step for job in workflow["jobs"].values() for step in job.get("steps", [])]


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.workflow = yaml.safe_load(cls.text)

    def test_triggers(self) -> None:
        events = self.workflow.get("on", self.workflow.get(True))
        self.assertEqual(events, {"pull_request_target": {"types": ["labeled"]},
                                  "issue_comment": {"types": ["created"]},
                                  "workflow_run": {"workflows": ["CI fast guards"], "types": ["completed"],
                                                   "branches": ["main"]}})
        self.assertEqual(self.workflow["permissions"], {})

    def test_automatic_path_starts_only_from_main_going_green(self) -> None:
        condition = " ".join(self.workflow["jobs"]["select"]["if"].split())
        for clause in ("github.event_name == 'workflow_run'", "github.event.workflow_run.event == 'push'",
                       "github.event.workflow_run.path == '.github/workflows/ci-fast-guards.yml'",
                       "github.event.workflow_run.head_branch == 'main'",
                       "github.event.workflow_run.conclusion == 'success'",
                       "github.event.workflow_run.head_repository.full_name == github.repository",
                       "vars.GLAEDA_ROUTE_APP_ID != ''"):
            self.assertIn(clause, condition)
        self.assertTrue(all(level == "read" for level in self.workflow["jobs"]["select"]["permissions"].values()))
        # The gate never runs for it, so no requester text reaches that path.
        self.assertNotIn("workflow_run", self.workflow["jobs"]["gate"]["if"])

    def test_per_pull_request_jobs_are_a_matrix(self) -> None:
        jobs = self.workflow["jobs"]
        for name in ("merge", "finish"):
            strategy = jobs[name]["strategy"]
            self.assertIs(strategy["fail-fast"], False, name)
            self.assertEqual(strategy["matrix"],
                             "${{ fromJSON(needs.select.outputs.matrix || needs.gate.outputs.matrix) }}", name)
            self.assertEqual(jobs[name]["env"]["PR_NUMBER"], "${{ matrix.pr }}", name)
            self.assertIs(jobs[name]["concurrency"]["cancel-in-progress"], False, name)
        # finish waits for every merge entry, so all of a default selection merges at once.
        self.assertGreaterEqual(jobs["merge"]["strategy"]["max-parallel"], 15)
        self.assertLessEqual(jobs["finish"]["strategy"]["max-parallel"], 3)
        # A request by hand and the automatic path never share a group: GitHub
        # keeps one pending job per group, and a newer one replaces it.
        self.assertEqual(jobs["merge"]["concurrency"]["group"],
                         "${{ github.event_name == 'workflow_run' && format('pr-catch-up-auto-merge-{0}', matrix.pr)"
                         " || format('pr-catch-up-merge-{0}', matrix.pr) }}")
        self.assertIs(upload_step(jobs["merge"])["with"]["overwrite"], True)
        pin = next(step for step in jobs["merge"]["steps"] if step.get("id") == "pr")["env"]["PIN"]
        self.assertEqual(pin, "${{ matrix.pin }}")
        # Each entry's result travels in its own artifact.
        upload = next(step for step in jobs["merge"]["steps"] if "upload-artifact" in str(step.get("uses")))
        download = next(step for step in jobs["finish"]["steps"] if "download-artifact" in str(step.get("uses")))
        self.assertEqual(upload["with"]["name"], download["with"]["name"])
        self.assertIn("matrix.pr", upload["with"]["name"])

    def test_automatic_path_never_pushes_with_the_actions_token(self) -> None:
        push = next(step for step in self.workflow["jobs"]["finish"]["steps"] if step.get("id") == "push")["run"]
        self.assertLess(push.index('[[ -z "$token" && "$AUTO" == true ]]'), push.index('token="$ACTIONS_TOKEN"'))
        self.assertIn("skipped-no-app-token", push)

    def test_finish_validates_the_matrix_handoff(self) -> None:
        # ReadResultTests runs this command against crafted artifacts.
        read = next(step for step in self.workflow["jobs"]["finish"]["steps"] if step.get("id") == "merge")
        self.assertIn('"$TRUSTED/scripts/ci/catch_up_pr.py" read-result', read["run"])
        self.assertIn('--pin "$PIN"', read["run"])
        self.assertEqual(read["env"]["PIN"], "${{ matrix.pin }}")

    def test_no_event_text_in_shell(self) -> None:
        # Titles, branch names and comment bodies reach steps through env only.
        for step in run_steps(self.workflow):
            self.assertNotIn("${{", step.get("run", ""), step.get("name"))

    def test_only_trusted_scripts_run(self) -> None:
        for step in run_steps(self.workflow):
            script = step.get("run", "")
            for match in re.finditer(r"(?<![\w-])(?:python3|bash|sh)\s+(\S+)", script):
                self.assertTrue(match.group(1).startswith(('"$TRUSTED/', "-")), (step.get("name"), match.group(0)))
            self.assertNotRegex(script, r"\$CANDIDATE/(scripts|\.github)", step.get("name"))

    def test_checkouts_do_not_keep_credentials(self) -> None:
        checkouts = [step for step in run_steps(self.workflow) if str(step.get("uses", "")).startswith("actions/checkout@")]
        self.assertEqual(len(checkouts), 4)
        for step in checkouts:
            self.assertIs(step["with"]["persist-credentials"], False)
            self.assertFalse(step["with"].get("submodules"), "submodules would fetch PR-chosen URLs")
            self.assertIs(step["with"]["lfs"], False)

    def test_untrusted_checkout_job_holds_no_write_token(self) -> None:
        jobs = self.workflow["jobs"]
        for name, job in jobs.items():
            refs = [step["with"]["ref"] for step in job.get("steps", [])
                    if str(step.get("uses", "")).startswith("actions/checkout@")]
            if any("head_sha" in ref for ref in refs):
                self.assertEqual(name, "merge")
                self.assertTrue(all(level == "read" for level in job["permissions"].values()), job["permissions"])
                self.assertEqual(job["env"]["GIT_LFS_SKIP_SMUDGE"], "1")
            elif refs:
                self.assertEqual(refs, ["${{ github.sha }}"], name)

    def test_only_writers_reach_a_concurrency_group(self) -> None:
        jobs = self.workflow["jobs"]
        self.assertNotIn("concurrency", jobs["gate"])
        self.assertNotIn("concurrency", self.workflow)
        self.assertEqual(jobs["merge"]["needs"], ["gate", "select"])
        self.assertIn("needs.gate.outputs.allowed == 'true' && needs.gate.outputs.refusal == ''", jobs["merge"]["if"])
        self.assertIn("needs.select.result == 'success'", jobs["merge"]["if"])
        # finish also runs for a non-writer's label (to remove it), so its
        # shared group is chosen by the gate's writer decision or main's own
        # green run; anyone else gets a group of their own run and cannot
        # cancel a pending push.
        group = jobs["finish"]["concurrency"]["group"]
        self.assertTrue(group.startswith("${{ needs.select.result == 'success' && format('pr-catch-up-auto-push-{0}',"
                                         " matrix.pr) || needs.gate.outputs.allowed == 'true'"
                                         " && format('pr-catch-up-push-"), group)
        self.assertIn("github.run_id", group)
        self.assertEqual(jobs["finish"]["env"]["AUTHORIZED"],
                         "${{ needs.gate.outputs.allowed == 'true' || needs.select.result == 'success' }}")

    def pr_script(self) -> str:
        return next(step["run"] for step in self.workflow["jobs"]["merge"]["steps"] if step.get("id") == "pr")

    def test_head_is_pinned(self) -> None:
        script = self.pr_script()
        self.assertIn('"$head_sha" != "$EVENT_HEAD_SHA"', script)
        self.assertIn('"$head_sha" != "$PIN"', script)
        gate = self.workflow["jobs"]["gate"]["steps"][0]["run"]
        self.assertIn("[0-9a-f]{40}))?$", gate, "a pin must be a full sha")
        # Names are validated before they reach a URL.
        self.assertLess(script.index('check-ref-format --branch "$head_ref"'), script.index("branches/$head_ref_url"))

    def test_fork_heads_are_refused(self) -> None:
        gate = self.workflow["jobs"]["gate"]["steps"][0]["run"]
        self.assertIn("isCrossRepository", gate)
        self.assertIn("only runs on branches in this repository", gate)
        self.assertIn("needs.gate.outputs.refusal == ''", self.workflow["jobs"]["merge"]["if"])
        self.assertIn('"$cross" != false', self.pr_script())
        self.assertNotIn("maintainerCanModify", self.text)
        self.assertNotIn("action_required", self.text)

    def test_finish_does_not_trust_the_merge_job(self) -> None:
        steps = {step.get("id"): step for step in self.workflow["jobs"]["finish"]["steps"]}
        verify = steps["verify"]["run"]
        self.assertIn(".headRefOid == $sha", verify)
        self.assertIn(".isCrossRepository == false", verify)
        self.assertIn('catch_up_pr.py" verify', verify)
        self.assertEqual(steps["push"]["if"], "steps.verify.outputs.ok == 'true'")
        self.assertIn("steps.verify.outputs.ok == 'true'", steps["app-token"]["if"])

    def test_actions_are_pinned(self) -> None:
        for step in run_steps(self.workflow):
            uses = step.get("uses")
            if uses:
                self.assertRegex(uses, r"@[0-9a-f]{40}$")

    def test_runner_is_github_hosted(self) -> None:
        for job in self.workflow["jobs"].values():
            self.assertEqual(job["runs-on"], "ubuntu-24.04")


if __name__ == "__main__":
    unittest.main()
