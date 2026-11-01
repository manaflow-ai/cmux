#!/usr/bin/env python3
"""check-package-dependency-lists.py: the CmuxNextAppTests dependencies stay one sorted entry per
line, so two pull requests that each add a module merge without a conflict (2026-10-20: six
pull requests were CONFLICTING again within twenty minutes of a rebase on that list)."""

import importlib.util
import json
import re
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "check-package-dependency-lists.py"
SPEC = importlib.util.spec_from_file_location("check_package_dependency_lists", SCRIPT)
assert SPEC and SPEC.loader
lint = importlib.util.module_from_spec(SPEC)
sys.modules["check_package_dependency_lists"] = lint
SPEC.loader.exec_module(lint)


def manifest(*entries: str) -> str:
    body = "".join(f"                {entry}\n" for entry in entries)
    return (
        "let package = Package(\n"
        "    targets: [\n"
        "        .testTarget(\n"
        '            name: "CmuxNextAppTests",\n'
        f"            dependencies: [ {lint.MARKER}\n"
        f"{body}"
        "            ],\n"
        "            swiftSettings: uiSwiftSettings\n"
        "        ),\n"
        "    ]\n"
        ")\n"
    )


BASE = ('"CmuxNextActions",', '"CmuxNextFeed",', '"CmuxNextTabs",',
        '.product(name: "CmuxHomeCore", package: "CmuxHomeCore"),')


class CheckTests(unittest.TestCase):
    def problems(self, text: str) -> list[str]:
        return lint.check(text, fix=False)[0]

    def test_the_committed_manifest_is_canonical(self):
        self.assertEqual(self.problems(lint.DEFAULT_MANIFEST.read_text(encoding="utf-8")), [])

    def test_a_sorted_list_passes(self):
        self.assertEqual(self.problems(manifest(*BASE)), [])

    def test_an_unsorted_list_fails_and_fix_sorts_it_with_its_comments(self):
        text = manifest('"CmuxNextTabs",', "// Feed's tests read the timeline.", '"CmuxNextFeed",')
        self.assertIn("CmuxNextAppTests: entries are not sorted (run with --fix)", self.problems(text))
        fixed = lint.check(text, fix=True)[1]
        self.assertEqual(fixed, manifest("// Feed's tests read the timeline.", '"CmuxNextFeed",', '"CmuxNextTabs",'))
        self.assertEqual(self.problems(fixed), [])

    def test_two_entries_on_a_line_fail(self):
        problems = self.problems(manifest('"CmuxNextActions", "CmuxNextFeed",'))
        self.assertTrue(any("one entry per line" in p for p in problems), problems)

    def test_a_missing_trailing_comma_fails(self):
        problems = self.problems(manifest('"CmuxNextActions",', '"CmuxNextFeed"'))
        self.assertTrue(any("must end in a comma" in p for p in problems), problems)

    def test_a_duplicate_fails(self):
        problems = self.problems(manifest('"CmuxNextFeed",', '"CmuxNextFeed",'))
        self.assertIn('CmuxNextAppTests: duplicate entry "CmuxNextFeed",', problems)

    def test_a_trailing_comment_fails(self):
        problems = self.problems(manifest('"CmuxNextFeed", // the timeline'))
        self.assertTrue(any("own line above" in p for p in problems), problems)

    def test_the_app_tests_list_must_carry_the_marker(self):
        text = manifest(*BASE).replace(f" {lint.MARKER}", "")
        self.assertTrue(any("lacks the marker" in p for p in self.problems(text)))

    def test_fix_on_the_command_line_rewrites_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Package.swift"
            path.write_text(manifest('"CmuxNextTabs",', '"CmuxNextFeed",'), encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), "--fix", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(path.read_text(encoding="utf-8"), manifest('"CmuxNextFeed",', '"CmuxNextTabs",'))


class ImportTests(unittest.TestCase):
    """A target that imports another local target declares it (2026-10-24: CmuxNextDaemonTests imported
    CmuxNextCompat undeclared, and incremental builds linked a stale object against an old Mutex symbol)."""

    PACKAGE = (
        "let package = Package(\n"
        "    targets: [\n"
        "        .target(\n"
        '            name: "CmuxNextCompat",\n'
        "            dependencies: []\n"
        "        ),\n"
        "        .target(\n"
        '            name: "CmuxNextDaemon",\n'
        '            dependencies: ["CmuxNextCompat"]\n'
        "        ),\n"
        "        .testTarget(\n"
        '            name: "CmuxNextDaemonTests",\n'
        "            dependencies: [DEPS]\n"
        "        ),\n"
        "    ]\n"
        ")\n"
    )

    def problems(self, deps: str, source: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for folder in ("Sources/CmuxNextCompat", "Sources/CmuxNextDaemon", "Tests/CmuxNextDaemonTests"):
                (root / folder).mkdir(parents=True)
            (root / "Sources/CmuxNextDaemon/A.swift").write_text("import CmuxNextCompat\n", encoding="utf-8")
            (root / "Tests/CmuxNextDaemonTests/RetryWakeFolderTests.swift").write_text(source, encoding="utf-8")
            text = self.PACKAGE.replace("DEPS", deps)
            with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset()):
                return lint.import_problems(text, root)

    def test_an_undeclared_local_import_fails(self):
        problems = self.problems('"CmuxNextDaemon"', "import CmuxNextCompat\n@testable import CmuxNextDaemon\n")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("CmuxNextDaemonTests: imports CmuxNextCompat but does not declare it", problems[0])

    def test_a_declared_import_and_a_system_import_pass(self):
        self.assertEqual(self.problems('"CmuxNextCompat", "CmuxNextDaemon"',
                                       "import Foundation\nimport CmuxNextCompat\n@testable import CmuxNextDaemon\n"), [])

    def test_an_import_in_a_string_or_comment_is_no_import(self):
        # A generator test's golden source says `import CmuxNextCompat` inside a string literal.
        source = ('@testable import CmuxNextDaemon\n'
                  '// import CmuxNextCompat\n'
                  'let golden = """\n'
                  '    public import CmuxNextCompat\n'
                  '    """\n')
        self.assertEqual(self.problems('"CmuxNextDaemon"', source), [])

    def test_a_target_named_with_target_name_is_declared(self):
        # `.target(name: "X")` tells a target from a product of the same name.
        self.assertEqual(self.problems('.target(name: "CmuxNextCompat"), "CmuxNextDaemon"',
                                       "import CmuxNextCompat\n@testable import CmuxNextDaemon\n"), [])

    def test_a_baseline_line_that_is_fixed_must_go(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Sources/CmuxNextCompat").mkdir(parents=True)
            text = "let package = Package(\n    targets: [\n        .target(\n            name: \"CmuxNextCompat\"\n        ),\n    ]\n)\n"
            with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset({"CmuxNextApp: CmuxNextFileGrid"})):
                problems = lint.import_problems(text, root)
        self.assertEqual(problems, ["IMPORT_BASELINE lists CmuxNextApp: CmuxNextFileGrid, which is declared or gone now: drop its line"])

    def test_the_committed_package_declares_its_imports(self):
        root = lint.DEFAULT_MANIFEST.parent
        self.assertEqual(lint.import_problems(lint.DEFAULT_MANIFEST.read_text(encoding="utf-8"), root), [])


class MergeTests(unittest.TestCase):
    """Git's own line merge (what GitHub runs) on two branches that each add a module."""

    def git(self, *args: str) -> subprocess.CompletedProcess:
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
                   GIT_COMMITTER_EMAIL="t@e", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(["git", "-C", self.root, *args], env=env, capture_output=True, text=True)

    def branch(self, name: str, *entries: str) -> None:
        self.git("checkout", "-q", "-b", name, "main")
        Path(self.root, "Package.swift").write_text(manifest(*sorted(entries)), encoding="utf-8")
        self.git("commit", "-qam", name)

    def merge(self, left: tuple, right: tuple) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            self.root = tmp
            self.git("init", "-q", "-b", "main")
            Path(tmp, "Package.swift").write_text(manifest(*BASE), encoding="utf-8")
            self.git("add", ".")
            self.git("commit", "-qm", "base")
            self.branch("left", *BASE, *left)
            self.branch("right", *BASE, *right)
            result = self.git("merge", "-q", "--no-edit", "left")
            result.merged = Path(tmp, "Package.swift").read_text(encoding="utf-8")
            return result

    def test_additions_in_different_places_merge_cleanly_and_stay_sorted(self):
        result = self.merge(('"CmuxNextBrowserHistory",',), ('"CmuxNextNowPlaying",',))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(lint.check(result.merged, fix=False)[0], [])
        self.assertIn('"CmuxNextBrowserHistory",', result.merged)
        self.assertIn('"CmuxNextNowPlaying",', result.merged)


# Three targets in the shapes Package.swift has: an inline list, a multi-line list with several entries per line
# and a marked sorted list.
FIX_MANIFEST = (
    "let package = Package(\n"
    "    targets: [\n"
    "        .target(\n"
    '            name: "CmuxNextCompat"\n'
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextHome",\n'
    '            dependencies: ["CmuxNextCompat"],\n'
    "        ),\n"
    "        .testTarget(\n"
    '            name: "CmuxNextHomeEngineTests",\n'
    "            dependencies: [\n"
    '                "CmuxNextHomeEngine", "CmuxNextDaemon",\n'
    '                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),\n'
    "            ],\n"
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextHomeEngine"\n'
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextDaemon"\n'
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextAppCore"\n'
    "        ),\n"
    "        .testTarget(\n"
    '            name: "CmuxNextAppTests",\n'
    "            dependencies: [  MARKER_PLACEHOLDER\n"
    '                "CmuxNextApp",\n'
    '                "CmuxNextApps",\n'
    '                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),\n'
    "            ],\n"
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextApp"\n'
    "        ),\n"
    "        .target(\n"
    '            name: "CmuxNextApps"\n'
    "        ),\n"
    "    ]\n"
    ")\n"
)


class FixImportsTests(unittest.TestCase):
    """--fix-imports declares a new undeclared import where the list keeps its shape (2026-10-29: the two pushes
    #27173 and #27219 repaired by hand)."""

    def manifest_text(self) -> str:
        return FIX_MANIFEST.replace("MARKER_PLACEHOLDER", lint.MARKER)

    def test_a_marked_list_gets_the_entry_in_sorted_order(self):
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextAppTests", "CmuxNextAppCore")
        self.assertIn('                "CmuxNextApp",\n                "CmuxNextAppCore",\n                "CmuxNextApps",\n',
                      fixed)
        self.assertEqual(lint.check(fixed, fix=False)[0], [])

    def test_a_multi_line_list_gets_the_entry_on_its_own_line_before_the_bracket(self):
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextHomeEngineTests", "CmuxNextHome")
        self.assertIn('.product(name: "CmuxHomeCore", package: "CmuxHomeCore"),\n                "CmuxNextHome",\n'
                      "            ],", fixed)

    def test_a_last_entry_with_a_trailing_comment_gets_its_comma_before_the_comment(self):
        # Review of 115ed33e: the comma went after the comment, inside it, and the array lacked one between entries.
        text = (
            "        .target(\n"
            '            name: "CmuxNextAgentPane",\n'
            "            dependencies: [\n"
            '                "CmuxNextCompat" // the compat shims\n'
            "            ]\n"
            "        ),\n")
        fixed = lint.add_dependency(text, "CmuxNextAgentPane", "CmuxNextDaemon")
        self.assertIn('                "CmuxNextCompat", // the compat shims\n                "CmuxNextDaemon",\n'
                      "            ]\n", fixed)

    def test_an_inline_list_gets_the_entry_before_the_bracket(self):
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextHome", "CmuxNextDaemon")
        self.assertIn('dependencies: ["CmuxNextCompat", "CmuxNextDaemon"],', fixed)

    def test_a_target_without_dependencies_gets_a_list_after_its_name_with_a_comma(self):
        # Review of 6d8b96f: the list went in with no comma after `name: "X"`, which is not valid Swift.
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextCompat", "CmuxNextDaemon")
        self.assertIn('name: "CmuxNextCompat",\n            dependencies: ["CmuxNextDaemon"]\n        ),', fixed)
        self.assertEqual(lint.manifest_targets(fixed)["CmuxNextCompat"][1], {"CmuxNextDaemon"})

    def test_a_target_in_a_block_comment_declares_nothing(self):
        # Review of c9beb1af: a commented-out duplicate after the real declaration replaced its span, so the
        # duplicate's dependencies were read as the target's and an undeclared import passed.
        text = self.manifest_text().replace(
            "    ]\n)\n",
            '    ]\n)\n/*\n        .target(\n            name: "CmuxNextCompat",\n'
            '            dependencies: ["CmuxNextDaemon"]\n        ),\n*/\n', 1)
        self.assertIn("/*", text)
        self.assertEqual(lint.manifest_targets(text)["CmuxNextCompat"][1], set())
        fixed = lint.add_dependency(text, "CmuxNextCompat", "CmuxNextDaemon")
        self.assertIn('name: "CmuxNextCompat",\n            dependencies: ["CmuxNextDaemon"]\n        ),', fixed)
        self.assertTrue(fixed.endswith('dependencies: ["CmuxNextDaemon"]\n        ),\n*/\n'))

    def test_a_dependencies_list_in_a_block_comment_declares_nothing(self):
        # Review of 3f01de17: `argument()` skipped `//` but not `/* */`, so a commented-out list was read as the
        # target's dependencies and an undeclared import passed; --fix-imports then edited inside the comment.
        text = self.manifest_text().replace('name: "CmuxNextCompat"\n',
                                            'name: "CmuxNextCompat" /* , dependencies: ["CmuxNextDaemon"] */\n', 1)
        self.assertIn("/* , dependencies", text)
        self.assertEqual(lint.manifest_targets(text)["CmuxNextCompat"][1], set())
        fixed = lint.add_dependency(text, "CmuxNextCompat", "CmuxNextDaemon")
        self.assertIn('/* , dependencies: ["CmuxNextDaemon"] */', fixed)
        self.assertEqual(fixed.count('"CmuxNextDaemon"'), text.count('"CmuxNextDaemon"') + 1)
        self.assertEqual(lint.manifest_targets(fixed)["CmuxNextCompat"][1], {"CmuxNextDaemon"})

    def test_a_name_followed_by_other_arguments_keeps_its_comma_once(self):
        text = self.manifest_text().replace('name: "CmuxNextCompat"\n',
                                            'name: "CmuxNextCompat",\n            path: "Sources/Compat"\n')
        fixed = lint.add_dependency(text, "CmuxNextCompat", "CmuxNextDaemon")
        self.assertIn('name: "CmuxNextCompat",\n            dependencies: ["CmuxNextDaemon"],\n'
                      '            path: "Sources/Compat"\n', fixed)

    def test_only_the_named_target_changes(self):
        # CmuxNextApp is a prefix of CmuxNextApps and CmuxNextAppTests: the exact name is the one changed.
        fixed = lint.add_dependency(self.manifest_text(), "CmuxNextApp", "CmuxNextDaemon")
        self.assertIn('name: "CmuxNextApp",\n            dependencies: ["CmuxNextDaemon"]\n', fixed)
        self.assertEqual(fixed.count("CmuxNextDaemon"), self.manifest_text().count("CmuxNextDaemon") + 1)

    # The CmuxNextAgentPane shape: an inline list that wraps, closes after a .product on its second line, and is
    # followed by a multi-line resources list whose `],` stands alone.
    AGENT_PANE = (
        "let package = Package(\n"
        "    targets: [\n"
        "        .target(\n"
        '            name: "CmuxNextAgentPane",\n'
        '            dependencies: ["CmuxNextCompat", "CmuxNextDaemon",\n'
        '                           .product(name: "CmuxAppAttest", package: "CmuxAppAttest")],\n'
        "            resources: [\n"
        '                .process("Resources/Localizable.xcstrings"),\n'
        '                .copy("Resources/agent-pane"),\n'
        "            ],\n"
        "            swiftSettings: uiSwiftSettings\n"
        "        ),\n"
        "    ]\n"
        ")\n")

    def test_the_entry_goes_into_the_dependencies_array_not_the_next_list(self):
        # Review of 6d8b96f: the insertion took the next standalone `],` (resources'), and the reader then counted
        # the entry as declared.
        fixed = lint.add_dependency(self.AGENT_PANE, "CmuxNextAgentPane", "CmuxNextBrowser")
        self.assertIn('package: "CmuxAppAttest"), "CmuxNextBrowser"],\n            resources: [\n'
                      '                .process("Resources/Localizable.xcstrings"),\n'
                      '                .copy("Resources/agent-pane"),\n            ],\n', fixed)
        self.assertEqual(lint.manifest_targets(fixed)["CmuxNextAgentPane"][1],
                         {"CmuxNextCompat", "CmuxNextDaemon", "CmuxNextBrowser"})

    def test_the_reader_does_not_take_a_following_list_for_dependencies(self):
        text = self.AGENT_PANE.replace('.copy("Resources/agent-pane"),', '"CmuxNextBrowser",')
        self.assertEqual(lint.manifest_targets(text)["CmuxNextAgentPane"][1], {"CmuxNextCompat", "CmuxNextDaemon"})

    def test_brackets_in_strings_and_comments_do_not_end_the_list(self):
        text = self.AGENT_PANE.replace('"CmuxNextDaemon",\n', '"CmuxNextDaemon", // a ] in a comment\n').replace(
            '"Resources/agent-pane"', '"Resources/a]b"')
        fixed = lint.add_dependency(text, "CmuxNextAgentPane", "CmuxNextBrowser")
        self.assertEqual(lint.manifest_targets(fixed)["CmuxNextAgentPane"][1],
                         {"CmuxNextCompat", "CmuxNextDaemon", "CmuxNextBrowser"})

    def test_every_target_of_the_committed_package_reads_the_same_as_before(self):
        # The bracket-matched reader against the committed Package.swift: every target is found, and a `resources:`
        # or `exclude:` string never counts as a dependency.
        text = lint.DEFAULT_MANIFEST.read_text(encoding="utf-8")
        targets = lint.manifest_targets(text)
        self.assertGreater(len(targets), 100)
        # Review of 6e507c72: one-line declarations count too (the reader saw only `.target(` alone on its line).
        self.assertIn("CmuxNextMallocZone", targets)
        self.assertIn("CmuxNextRemoteLayer", targets)
        self.assertEqual(len(targets), len(re.findall(r"(?m)^\s*\.(?:target|testTarget|executableTarget)\(", text)))
        for name, (_, declared, _) in targets.items():
            self.assertFalse({d for d in declared if "/" in d or "." in d}, name)

    def test_an_unknown_target_is_an_error(self):
        with self.assertRaises(lint.FixError):
            lint.add_dependency(self.manifest_text(), "CmuxNextNope", "CmuxNextDaemon")

    def run_script(self, root: Path, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(SCRIPT), *args, str(root / "Package.swift")],
                              capture_output=True, text=True)

    def test_the_two_real_incidents_are_found_named_and_fixed(self):
        # a63986a4: a CmuxNextHomeEngineTests file gained `import CmuxNextHome`; e875485c: a CmuxNextAppTests file
        # gained `@testable import CmuxNextAppCore`. Neither target declared it.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text(self.manifest_text(), encoding="utf-8")
            for folder, text in (("Tests/CmuxNextHomeEngineTests/Unanswered.swift", "import CmuxNextHome\n"),
                                 ("Tests/CmuxNextAppTests/Restore.swift", "@testable import CmuxNextAppCore\n"),
                                 ("Sources/CmuxNextCompat/A.swift", "import Foundation\n")):
                (root / folder).parent.mkdir(parents=True, exist_ok=True)
                (root / folder).write_text(text, encoding="utf-8")
            with unittest.mock.patch.dict(os.environ, {}):
                red = self.run_script(root, "--json")
            self.assertEqual(red.returncode, 1, red.stderr)
            self.assertIn('Fix: add "CmuxNextHome" to the dependencies of CmuxNextHomeEngineTests', red.stderr)
            self.assertIn('Fix: add "CmuxNextAppCore" to the dependencies of CmuxNextAppTests', red.stderr)
            missing = json.loads(red.stdout)["missing"]
            self.assertEqual(missing, [{"target": "CmuxNextAppTests", "module": "CmuxNextAppCore"},
                                       {"target": "CmuxNextHomeEngineTests", "module": "CmuxNextHome"}])

            fixed = self.run_script(root, "--fix-imports", "--json")

            # The fixture holds none of IMPORT_BASELINE's targets, so its lines read as stale here; nothing else is red.
            # With --json, stdout is the one JSON object: the fixer's lines go to stderr (review of befae46a).
            after = json.loads(fixed.stdout)
            self.assertEqual(after["missing"], [])
            self.assertEqual([p for p in after["problems"] if "IMPORT_BASELINE lists" not in p], [])
            self.assertIn("declared CmuxNextHome in the dependencies of CmuxNextHomeEngineTests", fixed.stderr)
            again = self.run_script(root, "--json")
            self.assertNotIn("does not declare", again.stderr)


    def test_fix_with_json_prints_only_the_json_object_on_stdout(self):
        # Review of befae46a: --fix printed "sorted the dependency lists in ..." on stdout before the JSON object.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text(manifest('"CmuxNextTabs",', '"CmuxNextFeed",'), encoding="utf-8")
            (root / "Sources").mkdir()
            (root / "Tests/CmuxNextAppTests").mkdir(parents=True)

            fixed = self.run_script(root, "--fix", "--json")

            self.assertEqual(json.loads(fixed.stdout), {"problems": [p for p in json.loads(fixed.stdout)["problems"]
                                                                     if "IMPORT_BASELINE lists" in p], "missing": []})
            self.assertIn("sorted the dependency lists in", fixed.stderr)
            self.assertEqual((root / "Package.swift").read_text(encoding="utf-8"),
                             manifest('"CmuxNextFeed",', '"CmuxNextTabs",'))

    ONE_LINE = (
        "let package = Package(\n"
        "    targets: [\n"
        '        .target(name: "CmuxNextCompat"),\n'
        "        // QuartzCore's CALayerHost.\n"
        '        .target(name: "CmuxNextRemoteLayer", linkerSettings: [.linkedFramework("QuartzCore")]),\n'
        '        .testTarget(name: "CmuxNextRemoteLayerTests", dependencies: ["CmuxNextRemoteLayer"]),\n'
        "    ]\n"
        ")\n")

    def test_a_one_line_target_s_undeclared_import_is_found_and_declared(self):
        # Review of 6e507c72: a target declared on one line was never read, so its sources were never scanned and a
        # push could add an undeclared import to it.
        targets = lint.manifest_targets(self.ONE_LINE)
        self.assertEqual(sorted(targets), ["CmuxNextCompat", "CmuxNextRemoteLayer", "CmuxNextRemoteLayerTests"])
        self.assertEqual(targets["CmuxNextRemoteLayerTests"][0], "testTarget")
        # A `.target(name:)` entry in a dependencies list is a dependency, not a declaration.
        nested = lint.target_spans('.testTarget(name: "T", dependencies: [.target(name: "A")]),\n.target(name: "A"),\n')
        self.assertEqual({name: kind for name, (kind, _, _) in nested.items()}, {"T": "testTarget", "A": "target"})
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Package.swift").write_text(self.ONE_LINE, encoding="utf-8")
            for folder, text in (("Sources/CmuxNextCompat/A.swift", "import Foundation\n"),
                                 ("Sources/CmuxNextRemoteLayer/Host.swift", "import CmuxNextCompat\n"),
                                 ("Tests/CmuxNextRemoteLayerTests/T.swift", "import CmuxNextCompat\n")):
                (root / folder).parent.mkdir(parents=True, exist_ok=True)
                (root / folder).write_text(text, encoding="utf-8")

            red = self.run_script(root, "--json")

            self.assertEqual(red.returncode, 1, red.stderr)
            self.assertEqual(json.loads(red.stdout)["missing"],
                             [{"target": "CmuxNextRemoteLayer", "module": "CmuxNextCompat"},
                              {"target": "CmuxNextRemoteLayerTests", "module": "CmuxNextCompat"}])

            fixed = self.run_script(root, "--fix-imports", "--json")

            self.assertEqual(json.loads(fixed.stdout)["missing"], [], fixed.stderr)
            text = (root / "Package.swift").read_text(encoding="utf-8")
            declared = lint.manifest_targets(text)
            self.assertEqual(declared["CmuxNextRemoteLayer"][1], {"CmuxNextCompat"})
            self.assertEqual(declared["CmuxNextRemoteLayerTests"][1], {"CmuxNextRemoteLayer", "CmuxNextCompat"})
            self.assertIn('linkerSettings: [.linkedFramework("QuartzCore")]', text)


HEAL_SPEC = importlib.util.spec_from_file_location("package_deps_heal", HERE.parent / "package_deps_heal.py")
heal = importlib.util.module_from_spec(HEAL_SPEC)
sys.modules["package_deps_heal"] = heal
HEAL_SPEC.loader.exec_module(heal)


class HealTests(unittest.TestCase):
    """package_deps_heal.py: a direct push that adds an undeclared import becomes a fix pull request on its own
    branch, never a push to feat-cmux-next."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="package-deps-heal-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.origin = self.root / "origin.git"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@e", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@e", GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        subprocess.run(["git", "init", "-q", "--bare", "-b", "feat-cmux-next", str(self.origin)], check=True,
                       env=self.env)
        self.git("init", "-q", "-b", "feat-cmux-next", cwd=self.root, target=str(self.repo))
        self.git("remote", "add", "origin", str(self.origin))
        package = self.repo / heal.MANIFEST
        package.parent.mkdir(parents=True)
        package.write_text(FIX_MANIFEST.replace("MARKER_PLACEHOLDER", lint.MARKER), encoding="utf-8")
        self.write("Tests/CmuxNextHomeEngineTests/Old.swift", "import CmuxNextHomeEngine\n")
        self.write("Sources/CmuxNextCompat/A.swift", "import Foundation\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        self.git("push", "-q", "origin", "feat-cmux-next")

    def git(self, *args, cwd=None, target=None):
        command = ["git", *([] if target else ["-C", str(self.repo)]), *args, *([target] if target else [])]
        return subprocess.run(command, cwd=cwd, env=self.env, text=True, capture_output=True, check=True).stdout

    def write(self, relative, text):
        path = self.repo / heal.MANIFEST
        path = path.parent / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def bad_push(self):
        """The a63986a4 shape: a test file gains `import CmuxNextHome`, pushed straight to the branch."""
        self.write("Tests/CmuxNextHomeEngineTests/Unanswered.swift", "import CmuxNextHome\nimport CmuxNextHomeEngine\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "test(home): an unanswered group start says the cloud did not answer")
        self.git("push", "-q", "origin", "feat-cmux-next")
        return self.git("rev-parse", "HEAD").strip()

    def test_a_green_tree_plans_nothing(self):
        out = self.root / "plan"
        with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset()), \
                unittest.mock.patch.object(heal, "load_check", lambda: lint):
            result = heal.plan(self.repo, "HEAD", out)
        self.assertEqual(result, {"red": "false"})
        self.assertFalse(out.exists())
        self.assertEqual(self.git("status", "--porcelain"), "")

    def plan(self):
        out = self.root / "plan"
        with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset()), \
                unittest.mock.patch.object(heal, "load_check", lambda: lint):
            return heal.plan(self.repo, "HEAD", out, "manaflow-ai/cmux", "https://ci/run/1"), out

    def test_a_simulated_bad_push_plans_the_fix_pull_request(self):
        offending = self.bad_push()

        result, out = self.plan()

        self.assertEqual(result["red"], "true")
        self.assertEqual(result["fixable"], "true")
        self.assertTrue(result["branch"].startswith("autofix/package-deps-"), result)
        self.assertEqual((out / "branch").read_text().strip(), result["branch"])
        self.assertEqual((out / "title").read_text().strip(),
                         "fix(cmux-next): CmuxNextHomeEngineTests declares CmuxNextHome, which it imports")
        body = (out / "body.md").read_text()
        self.assertIn(f"https://github.com/manaflow-ai/cmux/commit/{offending}", body, "names the offending commit")
        self.assertIn("test(home): an unanswered group start", body)
        self.assertIn("| `CmuxNextHomeEngineTests` | `CmuxNextHome` |", body)
        self.assertIn("Opened by https://ci/run/1.", body)
        self.assertIn(offending[:10], (out / "commit-message").read_text())
        self.assertEqual((out / "labels").read_text().strip(), "risk:low")
        manifest = (self.repo / heal.MANIFEST).read_text()
        self.assertIn('"CmuxNextHome",', manifest)
        changed = self.git("diff", "--name-only").split()
        self.assertEqual(changed, [heal.MANIFEST], "only Package.swift changes")
        self.assertEqual(lint.missing_imports(manifest, (self.repo / heal.MANIFEST).parent), [])

    def test_a_stale_baseline_line_beside_a_fixable_import_opens_nothing(self):
        # Review of 8e00c8ba: the check after the repair counted only "does not declare" problems, so a stale
        # IMPORT_BASELINE line passed it and the planned fix pull request was itself red on the dependency check.
        self.bad_push()
        out = self.root / "plan"
        with unittest.mock.patch.object(lint, "IMPORT_BASELINE", frozenset({"CmuxNextCompat: CmuxNextHome"})), \
                unittest.mock.patch.object(heal, "load_check", lambda: lint):
            result = heal.plan(self.repo, "HEAD", out)
        self.assertEqual(result, {"red": "true", "fixable": "false"})
        self.assertFalse(out.exists())
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_the_same_gap_plans_the_same_branch(self):
        self.bad_push()
        first, _ = self.plan()
        self.git("checkout", "-q", "--", heal.MANIFEST)
        self.write("Sources/CmuxNextCompat/B.swift", "import Foundation\n")  # an unrelated later push
        second, _ = self.plan()
        self.assertEqual(first["branch"], second["branch"])

    def fake_gh(self, listed="[]", closed="[]"):
        tools = self.root / "bin"
        tools.mkdir(exist_ok=True)
        log = self.root / "gh.log"
        (tools / "gh").write_text(
            "#!/bin/sh\n"
            f'printf "%s\\n" "$*" >> "{log}"\n'
            f'case "$*" in *"--state open"*) echo \'{listed}\' ;; *"--state all"*) echo \'{closed}\' ;; '
            '"pr create"*) echo https://github.com/x/y/pull/9 ;; esac\n')
        (tools / "gh").chmod(0o755)
        return tools, log

    def test_open_pushes_only_the_autofix_branch_and_opens_its_pull_request(self):
        self.bad_push()
        result, out = self.plan()
        before = subprocess.run(["git", "-C", str(self.origin), "rev-parse", "feat-cmux-next"], env=self.env,
                                text=True, capture_output=True).stdout.strip()
        tools, log = self.fake_gh()

        with unittest.mock.patch.dict(os.environ, {**self.env, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}):
            url = heal.open_pr(self.repo, out)

        self.assertEqual(url, "https://github.com/x/y/pull/9")
        heads = subprocess.run(["git", "-C", str(self.origin), "for-each-ref", "--format=%(refname:short) %(objectname)",
                                "refs/heads"], env=self.env, text=True, capture_output=True).stdout.split("\n")
        self.assertIn(f"feat-cmux-next {before}", heads, "feat-cmux-next must not move")
        self.assertTrue(any(h.startswith(result["branch"] + " ") for h in heads), heads)
        create = [line for line in log.read_text().splitlines() if line.startswith("pr create")]
        self.assertEqual(len(create), 1, log.read_text())
        self.assertIn("--base feat-cmux-next", create[0])
        self.assertIn(f"--head {result['branch']}", create[0])
        self.assertIn("--label risk:low", create[0])

    def test_open_does_nothing_when_the_branch_already_has_an_open_pull_request(self):
        self.bad_push()
        _, out = self.plan()
        tools, log = self.fake_gh(listed='[{"url": "https://github.com/x/y/pull/8"}]')
        with unittest.mock.patch.dict(os.environ, {**self.env, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}):
            self.assertEqual(heal.open_pr(self.repo, out), "already open: https://github.com/x/y/pull/8")
        self.assertNotIn("pr create", log.read_text())

    def earlier_run_pushed(self, branch):
        """BRANCH on the remote as an earlier run left it: its own commit, which this run's commit does not extend."""
        commit = self.git("commit-tree", "HEAD^{tree}", "-m", "an earlier run's fix").strip()
        self.git("push", "-q", "origin", f"{commit}:refs/heads/{branch}")

    def test_a_pushed_branch_whose_pull_request_was_never_opened_gets_one(self):
        # Review of 1f94c38c: a run whose push succeeded but whose `gh pr create` failed left the branch on the remote,
        # and every later run stopped at "not pushed", so the repair was stranded for good.
        self.bad_push()
        result, out = self.plan()
        self.earlier_run_pushed(result["branch"])
        tools, log = self.fake_gh()
        with unittest.mock.patch.dict(os.environ, {**self.env, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}):
            self.assertEqual(heal.open_pr(self.repo, out), "https://github.com/x/y/pull/9")
        create = [line for line in log.read_text().splitlines() if line.startswith("pr create")]
        self.assertEqual(len(create), 1, log.read_text())
        self.assertIn(f"--head {result['branch']}", create[0])

    def test_a_branch_with_a_closed_pull_request_is_left_alone(self):
        self.bad_push()
        result, out = self.plan()
        self.earlier_run_pushed(result["branch"])
        tools, log = self.fake_gh(closed='[{"url": "https://github.com/x/y/pull/7"}]')
        with unittest.mock.patch.dict(os.environ, {**self.env, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}):
            self.assertIn("pull/7", heal.open_pr(self.repo, out))
        self.assertNotIn("pr create", log.read_text())

    def test_the_branch_names_only_the_missing_imports_when_there_are_any(self):
        # Review of 1f94c38c (P3): the digest also took the sorting problems, so a later push that only sorted the
        # lists gave the same import gap a second branch and a second pull request.
        self.assertEqual(heal.branch_for([("T", "M")], ["a list out of order"]), heal.branch_for([("T", "M")], []))
        self.assertNotEqual(heal.branch_for([], ["a"]), heal.branch_for([], ["b"]))

    def test_the_workflow_runs_only_on_feat_cmux_next(self):
        # Review of 1f94c38c: a workflow_dispatch from another branch would open a fix pull request carrying that
        # branch's own commits.
        workflow = (HERE.parents[2] / ".github/workflows/cmux-next-package-deps-heal.yml").read_text()
        self.assertIn("if: github.repository == 'manaflow-ai/cmux' && github.ref == 'refs/heads/feat-cmux-next'",
                      workflow)

    def test_open_refuses_any_branch_but_an_autofix_one(self):
        self.bad_push()
        _, out = self.plan()
        (out / "branch").write_text("feat-cmux-next\n")
        with self.assertRaises(SystemExit):
            heal.open_pr(self.repo, out)


if __name__ == "__main__":
    unittest.main()
