#!/usr/bin/env python3
"""apply-stability-settings.py: the p10 Package.swift settings lander (p10-stability-198) renders
stability-settings.json rows into one generated block per closure manifest, idempotently, and flags p10
settings changed outside a lander commit."""

import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "apply-stability-settings.py"
SPEC = importlib.util.spec_from_file_location("apply_stability_settings", SCRIPT)
assert SPEC and SPEC.loader
lander = importlib.util.module_from_spec(SPEC)
sys.modules["apply_stability_settings"] = lander
SPEC.loader.exec_module(lander)

APP_MANIFEST = """// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CmuxNext",
    dependencies: [
        .package(path: "../../Shared/Foo"),
        .package(path: "../../Shared/Vendored"),
        .package(path: "../../../vendor/outside"),
    ],
    targets: [
        .target(name: "App", dependencies: [.product(name: "Foo", package: "Foo")]),
        .testTarget(
            name: "AppTests",
            dependencies: ["App"]
        ),
    ]
)
"""

FOO_MANIFEST = """// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Foo",
    targets: [
        .target(name: "Foo", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "FooC"),
        .target(name: "FooCustom", path: "Custom/Dir"),
        .testTarget(name: "FooTests", dependencies: ["Foo"]),
    ]
)
"""

VENDORED_MANIFEST = """// swift-tools-version: 6.0

import PackageDescription

let package = Package(name: "Vendored", targets: [.target(name: "Vendored")])
"""

UNRELATED_MANIFEST = VENDORED_MANIFEST.replace("Vendored", "Unrelated")


def row(target="Foo", setting=".strictMemorySafety()", package="Packages/Shared/Foo", task="p10-stability-211"):
    return {"task": task, "package": package, "target": target, "setting": setting, "reason": "test"}


class LanderRepo:
    """A throwaway repository with a two-package closure, a vendored package and one outside the closure."""

    def __init__(self, directory: str):
        self.root = Path(directory)
        files = {
            "Packages/macOS/CmuxNext/Package.swift": APP_MANIFEST,
            "Packages/macOS/CmuxNext/Sources/App/App.swift": "public enum App {}\n",
            "Packages/macOS/CmuxNext/Tests/AppTests/AppTests.swift": "import App\n",
            "Packages/Shared/Foo/Package.swift": FOO_MANIFEST,
            "Packages/Shared/Foo/Sources/Foo/Foo.swift": "public struct Foo {}\n",
            "Packages/Shared/Foo/Sources/FooC/foo.c": "int foo(void) { return 0; }\n",
            "Packages/Shared/Foo/Custom/Dir/Nested/Custom.swift": "struct Custom {}\n",
            "Packages/Shared/Foo/Tests/FooTests/FooTests.swift": "import Foo\n",
            "Packages/Shared/Vendored/Package.swift": VENDORED_MANIFEST,
            "Packages/Shared/Vendored/SOURCE": "sha: 0\n",
            "Packages/Shared/Vendored/Sources/Vendored/V.swift": "struct V {}\n",
            "Packages/Shared/Unrelated/Package.swift": UNRELATED_MANIFEST,
            "Packages/Shared/Unrelated/Sources/Unrelated/U.swift": "struct U {}\n",
        }
        for path, text in files.items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(text)
        self.rows([])

    def rows(self, rows):
        path = self.root / lander.SETTINGS_FILE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"rows": rows}, indent=2) + "\n")

    def read(self, path):
        return (self.root / path).read_text()

    def run(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = lander.main(list(argv), root=self.root)
        return code, out.getvalue(), err.getvalue()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True, check=True).stdout

    def init_git(self):
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.git("config", "commit.gpgsign", "false")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")


class ApplyStabilitySettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = LanderRepo(self.temp.name)
        self.foo = "Packages/Shared/Foo/Package.swift"

    def tearDown(self):
        self.temp.cleanup()

    def test_closure_follows_path_dependencies_inside_packages_only(self):
        self.assertEqual(
            lander.closure(self.repo.root),
            ["Packages/macOS/CmuxNext", "Packages/Shared/Foo", "Packages/Shared/Vendored"],
        )

    def test_swift_targets_skip_c_targets_and_honor_path(self):
        self.assertEqual(lander.swift_targets(self.repo.root, "Packages/Shared/Foo"), ["Foo", "FooCustom", "FooTests"])

    def test_no_rows_changes_nothing(self):
        before = self.repo.read(self.foo)
        self.assertEqual(self.repo.run("--write"), (0, "", ""))
        self.assertEqual(self.repo.read(self.foo), before)
        self.assertEqual(self.repo.run("--check")[0], 0)

    def test_write_adds_block_bumps_tools_and_is_idempotent(self):
        self.repo.rows([row()])
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("Packages/Shared/Foo/Package.swift: stale", err)
        self.assertEqual(self.repo.run("--write")[0], 0)
        text = self.repo.read(self.foo)
        self.assertTrue(text.startswith("// swift-tools-version: 6.2\n"))
        self.assertIn('            "Foo",\n        ],\n        settings: [\n            .strictMemorySafety(),\n', text)
        self.assertTrue(text.endswith(lander.END))
        self.assertIn(FOO_MANIFEST.split("\n", 1)[1], text, "hand-written lines stay as they were")
        self.assertEqual(self.repo.run("--write"), (0, "", ""), "a second run writes nothing")
        self.assertEqual(self.repo.read(self.foo), text)
        self.assertEqual(self.repo.run("--check")[0], 0)
        self.assertEqual(self.repo.read("Packages/macOS/CmuxNext/Package.swift"), APP_MANIFEST)

    def test_removing_rows_removes_block_and_keeps_tools(self):
        self.repo.rows([row()])
        self.repo.run("--write")
        self.repo.rows([])
        self.repo.run("--write")
        self.assertEqual(self.repo.read(self.foo), FOO_MANIFEST.replace("6.0", "6.2", 1))

    def test_star_target_groups_targets_and_keeps_row_order(self):
        self.repo.rows([
            row(target="*", setting=".strictMemorySafety()"),
            row(target="FooTests", setting='.enableUpcomingFeature("ExistentialAny")'),
            row(target="*", setting=".strictMemorySafety()", task="p10-stability-079"),
        ])
        self.repo.run("--write")
        block = lander.block_of(self.repo.read(self.foo))
        self.assertIn('"Foo",\n            "FooCustom",\n        ],\n        settings: [\n            .strictMemorySafety(),\n        ]', block)
        self.assertIn('"FooTests",\n        ],\n        settings: [\n            .strictMemorySafety(),\n'
                      '            .enableUpcomingFeature("ExistentialAny"),\n        ]', block)
        self.assertNotIn("FooC\"", block)
        self.assertEqual(block.count(".strictMemorySafety()"), 2)

    def test_star_package_covers_closure_and_skips_vendored(self):
        self.repo.rows([row(package="*", target="*", setting='.treatWarning("StrictMemorySafety", as: .error)')])
        self.assertEqual(self.repo.run("--write")[0], 0)
        app = self.repo.read("Packages/macOS/CmuxNext/Package.swift")
        self.assertIn('"App",\n            "AppTests",', app)
        self.assertEqual(self.repo.read("Packages/Shared/Vendored/Package.swift"), VENDORED_MANIFEST)
        self.assertEqual(self.repo.read("Packages/Shared/Unrelated/Package.swift"), UNRELATED_MANIFEST)

    def test_refusals(self):
        cases = {
            "not an allowed form": row(setting='.unsafeFlags(["-Ounchecked"])'),
            "not a Swift target": row(target="FooC"),
            "not a CmuxNext closure package": row(package="Packages/Shared/Unrelated", target="Unrelated"),
            "vendored verbatim": row(package="Packages/Shared/Vendored", target="Vendored"),
            "not a task id": row(task="someone"),
        }
        for message, bad in cases.items():
            with self.subTest(message):
                self.repo.rows([bad])
                code, _, err = self.repo.run("--write")
                self.assertEqual(code, 2)
                self.assertIn(message, err)
                self.assertEqual(self.repo.read(self.foo), FOO_MANIFEST)

    def test_conflicting_warning_levels_are_refused(self):
        self.repo.rows([
            row(setting='.treatWarning("StrictMemorySafety", as: .error)'),
            row(setting='.treatWarning("StrictMemorySafety", as: .warning)'),
        ])
        code, _, err = self.repo.run("--write")
        self.assertEqual(code, 2)
        self.assertIn("rows ask for both", err)

    def test_hand_written_lander_only_setting_fails_check(self):
        (self.repo.root / self.foo).write_text(
            FOO_MANIFEST.replace("[.swiftLanguageMode(.v6)]", "[.swiftLanguageMode(.v6), .strictMemorySafety()]"))
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("lander-only setting", err)

    def test_hand_edited_block_fails_check(self):
        self.repo.rows([row()])
        self.repo.run("--write")
        text = self.repo.read(self.foo)
        (self.repo.root / self.foo).write_text(text.replace('"Foo",', '"Foo",\n            "FooTests",'))
        self.assertEqual(self.repo.run("--check")[0], 1)

    def test_commit_lands_one_commit_and_verify_commits_flags_hand_edits(self):
        self.repo.init_git()
        self.repo.rows([row()])
        self.repo.git("commit", "-q", "-am", "p10-stability-211: add a row")
        code, out, err = self.repo.run("--commit")
        self.assertEqual(code, 0, err)
        self.assertIn("cmux-ci build cmux --ref", out)
        subject = self.repo.git("log", "-1", "--format=%s").strip()
        self.assertTrue(subject.startswith(lander.LANDER_SUBJECT))
        self.assertEqual(self.repo.git("show", "--name-only", "--format=", "HEAD").split(), [self.foo])
        self.assertEqual(self.repo.run("--commit")[1], "nothing to land: every manifest matches the rows\n")

        text = self.repo.read(self.foo)
        (self.repo.root / self.foo).write_text(text.replace(".strictMemorySafety(),", ""))
        self.repo.git("commit", "-q", "-am", "p04-input-012: unrelated work")
        self.assertEqual(self.repo.run("--verify-commits", "HEAD~2..HEAD~1")[0], 0)
        code, _, err = self.repo.run("--verify-commits", "HEAD~2..HEAD")
        self.assertEqual(code, 1)
        self.assertIn("changes p10 settings outside a lander commit (p04-input-012: unrelated work)", err)

    def test_commit_refuses_a_dirty_manifest(self):
        self.repo.init_git()
        self.repo.rows([row()])
        (self.repo.root / self.foo).write_text(FOO_MANIFEST + "// local edit\n")
        code, _, err = self.repo.run("--commit")
        self.assertEqual(code, 2)
        self.assertIn("uncommitted edits", err)

    def test_checked_in_rows_match_the_manifests(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = lander.main(["--check"])
        self.assertEqual(code, 0, err.getvalue())
        self.assertIn("Packages/Shared/CmuxMessagesLab", lander.closure(lander.ROOT))


if __name__ == "__main__":
    unittest.main()
