#!/usr/bin/env python3
"""PR catch-up (RFC #14631, slice 1): merge the base, resolve only generated files.

Each case builds a small git repository in a temp dir with a base branch and a
pull request branch, runs scripts/ci/catch_up_pr.py through its CLI the way
the workflow does, and checks both the JSON result and the repository it left
behind: a merge commit with the resolved files, or an untouched head with the
blocking files named. The real normalizer, schema generator and xcstrings
merger resolve conflicts; a stub tools root stands in for a failing generator.

The last cases read .github/workflows/pr-catch-up.yml: it runs on
pull_request_target and issue_comment next to a write token, so it must only
execute the trusted base checkout's scripts and never interpolate event text
into a shell.
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

    def test_same_setting_added_with_different_values_stops(self) -> None:
        setting = "\t\t\t\tSWIFT_VERSION = {};\n"
        self.assertIsNone(MODULE.union_hunk([setting.format("5.0")], [], [setting.format("6.0")]))
        self.assertEqual(
            MODULE.union_hunk(["\t\t\t\tA = 1;\n"], [], ["\t\t\t\tB = 2;\n"]),
            ["\t\t\t\tA = 1;\n", "\t\t\t\tB = 2;\n"],
        )


class CommentTests(unittest.TestCase):
    def test_blocked_comment_lists_files_inertly(self) -> None:
        result = {"status": "blocked", "base": "a" * 40,
                  "blocking": [{"path": "evil`@team.md", "reason": "changed by @someone"}]}
        text = MODULE.render_comment(result, "not-attempted", "main", "feature", "https://run")
        self.assertIn("`evil'@team.md`", text)
        self.assertNotIn("@someone", text)
        self.assertIn("Nothing was pushed", text)
        self.assertNotIn("\u2014", text)

    def test_pushed_without_ci_says_so(self) -> None:
        result = {"status": "merged", "base": "a" * 40, "head_after": "b" * 40,
                  "resolved": [{"path": "x.xcstrings", "method": "xcstrings key-level union"}]}
        text = MODULE.render_comment(result, "pushed-without-ci", "main", "feature", "")
        self.assertIn("`bbbbbbbbbbbb`", text)
        self.assertIn("CI will not start on its own", text)


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
                                  "issue_comment": {"types": ["created"]}})
        self.assertEqual(self.workflow["permissions"], {})

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
        self.assertEqual(len(checkouts), 2)
        for step in checkouts:
            self.assertIs(step["with"]["persist-credentials"], False)
            self.assertFalse(step["with"].get("submodules"), "submodules would fetch PR-chosen URLs")

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
