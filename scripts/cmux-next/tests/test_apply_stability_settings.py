#!/usr/bin/env python3
"""apply-stability-settings.py: the p10 Package.swift settings lander (p10-stability-198) renders
stability-settings.json rows into each closure manifest (the stabilitySwiftSettings literal, one generated block,
language-mode literals) idempotently, and flags p10 settings changed outside a lander commit."""

import contextlib
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


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE.parent / filename)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


lander = load("apply_stability_settings", "apply-stability-settings.py")

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

# The app manifest with p10-stability-037's shared constant: App carries it through uiSwiftSettings, AppTests not.
APP_WITH_CONSTANT = APP_MANIFEST.replace(
    "let package = Package(",
    "/// The compile-time safety settings (filled by the lander).\n"
    "let stabilitySwiftSettings: [SwiftSetting] = []\n\n"
    "let uiSwiftSettings: [SwiftSetting] = [\n    .swiftLanguageMode(.v6),\n] + stabilitySwiftSettings\n\n"
    "let package = Package(",
).replace('.target(name: "App", dependencies: [.product(name: "Foo", package: "Foo")]),',
          '.target(name: "App", dependencies: [.product(name: "Foo", package: "Foo")], swiftSettings: uiSwiftSettings),')

FOO_MANIFEST = """// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Foo",
    targets: [
        .target(name: "Foo", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "FooC"),
        .target(name: "FooCustom", path: "Custom/Dir"),
        .target(
            name: "FooLab",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("APPKIT_NATIVE"),
            ]
        ),
        .testTarget(name: "FooTests", dependencies: ["Foo"]),
    ]
)
"""

VENDORED_MANIFEST = """// swift-tools-version: 6.0

import PackageDescription

let package = Package(name: "Vendored", targets: [.target(name: "Vendored")])
"""

UNRELATED_MANIFEST = VENDORED_MANIFEST.replace("Vendored", "Unrelated")
APP = "Packages/macOS/CmuxNext/Package.swift"
FOO = "Packages/Shared/Foo/Package.swift"


def row(target="Foo", setting=".strictMemorySafety()", package="Packages/Shared/Foo", task="p10-stability-211", kind=None):
    data = {"task": task, "package": package, "target": target, "setting": setting, "reason": "test"}
    if kind:
        data["kind"] = kind
    return data


class LanderRepo:
    """A throwaway repository with a two-package closure, a vendored package and one outside the closure."""

    def __init__(self, directory: str):
        self.root = Path(directory)
        files = {
            APP: APP_MANIFEST,
            "Packages/macOS/CmuxNext/Sources/App/App.swift": "public enum App {}\n",
            "Packages/macOS/CmuxNext/Tests/AppTests/AppTests.swift": "import App\n",
            FOO: FOO_MANIFEST,
            "Packages/Shared/Foo/Sources/Foo/Foo.swift": "public struct Foo {}\n",
            "Packages/Shared/Foo/Sources/FooC/foo.c": "int foo(void) { return 0; }\n",
            "Packages/Shared/Foo/Custom/Dir/Nested/Custom.swift": "struct Custom {}\n",
            "Packages/Shared/Foo/Sources/FooLab/Lab.swift": "struct Lab {}\n",
            "Packages/Shared/Foo/Tests/FooTests/FooTests.swift": "import Foo\n",
            "Packages/Shared/Vendored/Package.swift": VENDORED_MANIFEST,
            "Packages/Shared/Vendored/SOURCE": "sha: 0\n",
            "Packages/Shared/Vendored/Sources/Vendored/V.swift": "struct V {}\n",
            "Packages/Shared/Unrelated/Package.swift": UNRELATED_MANIFEST,
            "Packages/Shared/Unrelated/Sources/Unrelated/U.swift": "struct U {}\n",
        }
        for path, text in files.items():
            self.write(path, text)
        self.rows([])

    def write(self, path, text):
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text(text)

    def rows(self, rows):
        self.write(lander.SETTINGS_FILE, json.dumps({"rows": rows}, indent=2) + "\n")

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
        self.git("config", "core.hooksPath", str(self.root / ".no-hooks"))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")

    def commit_all(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").strip()


class ApplyStabilitySettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = LanderRepo(self.temp.name)
        self.tree = lander.WorkTree(self.repo.root)

    def tearDown(self):
        self.temp.cleanup()

    def test_closure_follows_path_dependencies_inside_packages_only(self):
        self.assertEqual(
            lander.closure(self.tree),
            ["Packages/macOS/CmuxNext", "Packages/Shared/Foo", "Packages/Shared/Vendored"],
        )

    def test_targets_by_language_honor_path(self):
        self.assertEqual(lander.targets(self.tree, "Packages/Shared/Foo"),
                         {"Foo": "swift", "FooC": "c", "FooCustom": "swift", "FooLab": "swift", "FooTests": "swift"})

    def test_no_rows_changes_nothing(self):
        before = self.repo.read(FOO)
        self.assertEqual(self.repo.run("--write"), (0, "", ""))
        self.assertEqual(self.repo.read(FOO), before)
        self.assertEqual(self.repo.run("--check")[0], 0)

    def test_write_adds_block_bumps_tools_and_is_idempotent(self):
        self.repo.rows([row()])
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn(f"{FOO}: stale", err)
        self.assertEqual(self.repo.run("--write")[0], 0)
        text = self.repo.read(FOO)
        self.assertTrue(text.startswith("// swift-tools-version: 6.2\n"))
        self.assertIn('            "Foo",\n        ],\n        settings: [\n            .strictMemorySafety(),\n', text)
        self.assertIn("target.swiftSettings = (target.swiftSettings ?? []) + group.settings", text)
        self.assertTrue(text.endswith(lander.END))
        self.assertIn(FOO_MANIFEST.split("\n", 1)[1], text, "hand-written lines stay as they were")
        self.assertEqual(self.repo.run("--write"), (0, "", ""), "a second run writes nothing")
        self.assertEqual(self.repo.read(FOO), text)
        self.assertEqual(self.repo.run("--check")[0], 0)
        self.assertEqual(self.repo.read(APP), APP_MANIFEST)

    def test_removing_rows_removes_block_and_keeps_tools(self):
        self.repo.rows([row()])
        self.repo.run("--write")
        self.repo.rows([])
        self.repo.run("--write")
        self.assertEqual(self.repo.read(FOO), FOO_MANIFEST.replace("6.0", "6.2", 1))

    def test_star_target_groups_targets_and_keeps_row_order(self):
        self.repo.rows([
            row(target="*", setting=".strictMemorySafety()"),
            row(target="FooTests", setting='.enableUpcomingFeature("ExistentialAny")'),
            row(target="*", setting=".strictMemorySafety()", task="p10-stability-079"),
        ])
        self.repo.run("--write")
        block = lander.block_of(self.repo.read(FOO))
        self.assertIn('"Foo",\n            "FooCustom",\n            "FooLab",\n        ],\n        settings: [\n'
                      '            .strictMemorySafety(),\n        ]', block)
        self.assertIn('"FooTests",\n        ],\n        settings: [\n            .strictMemorySafety(),\n'
                      '            .enableUpcomingFeature("ExistentialAny"),\n        ]', block)
        self.assertNotIn('"FooC"', block)
        self.assertEqual(block.count(".strictMemorySafety()"), 2)

    def test_star_package_covers_closure_skips_vendored_and_says_so(self):
        self.repo.rows([row(package="*", target="*", setting='.treatWarning("StrictMemorySafety", as: .error)')])
        code, _, err = self.repo.run("--write")
        self.assertEqual(code, 0)
        self.assertIn("note: p10-stability-211: Packages/Shared/Vendored is vendored verbatim, so its swift targets "
                      'Vendored do not get .treatWarning("StrictMemorySafety", as: .error)', err)
        self.assertIn('"App",\n            "AppTests",', self.repo.read(APP))
        self.assertEqual(self.repo.read("Packages/Shared/Vendored/Package.swift"), VENDORED_MANIFEST)
        self.assertEqual(self.repo.read("Packages/Shared/Unrelated/Package.swift"), UNRELATED_MANIFEST)
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 0, "a vendored package is a note, not a failure")
        self.assertIn("Packages/Shared/Vendored is vendored verbatim", err)

    def test_language_mode_row_replaces_the_literal(self):
        self.repo.rows([row(target="FooLab", setting=".swiftLanguageMode(.v6)", task="p10-stability-045")])
        self.assertEqual(self.repo.run("--write")[0], 0)
        text = self.repo.read(FOO)
        self.assertNotIn("swiftLanguageMode(.v5)", text)
        self.assertIn("                .swiftLanguageMode(.v6),\n                .define(\"APPKIT_NATIVE\"),", text)
        self.assertNotIn(lander.BEGIN, text, "a mode needs no block")
        self.assertEqual(self.repo.run("--write"), (0, "", ""))
        self.assertEqual(self.repo.run("--check")[0], 0)

    def test_language_mode_row_needs_one_literal(self):
        self.repo.rows([row(target="FooCustom", setting=".swiftLanguageMode(.v6)")])
        code, _, err = self.repo.run("--write")
        self.assertEqual(code, 2)
        self.assertIn("FooCustom: a language-mode row needs exactly one literal", err)
        self.assertEqual(self.repo.read(FOO), FOO_MANIFEST)

    def test_c_rows_append_c_settings_to_c_targets(self):
        flags = '.unsafeFlags(["-fstack-protector-strong", "-ftrivial-auto-var-init=pattern"])'
        self.repo.rows([row(target="*", setting=flags, kind="c", task="p10-stability-162"),
                        row(target="FooC", setting='.enableWarning("unsafe-buffer-usage")', kind="c", task="p10-stability-162")])
        self.assertEqual(self.repo.run("--write")[0], 0)
        block = lander.block_of(self.repo.read(FOO))
        self.assertIn("let stabilityCSettingGroups: [(targets: [String], settings: [CSetting])] = [", block)
        self.assertIn(f'"FooC",\n        ],\n        settings: [\n            {flags},\n'
                      '            .enableWarning("unsafe-buffer-usage"),\n        ]', block)
        self.assertIn("target.cSettings = (target.cSettings ?? []) + group.settings", block)
        self.assertNotIn("stabilitySettingGroups:", block, "no Swift group without Swift rows")
        self.assertEqual(self.repo.run("--write"), (0, "", ""))

    def test_constant_takes_package_wide_swift_rows(self):
        self.repo.write(APP, APP_WITH_CONSTANT)
        self.repo.rows([row(package="*", target="*"),
                        row(package="Packages/macOS/CmuxNext", target="App", setting='.enableUpcomingFeature("X")')])
        self.assertEqual(self.repo.run("--write")[0], 0)
        text = self.repo.read(APP)
        self.assertIn("let stabilitySwiftSettings: [SwiftSetting] = [\n    .strictMemorySafety(),\n]\n", text)
        block = lander.block_of(text)
        self.assertIn('"App",\n        ],\n        settings: [\n            .enableUpcomingFeature("X"),\n        ]', block)
        self.assertIn('"AppTests",\n        ],\n        settings: [\n            .strictMemorySafety(),\n        ]', block,
                      "a target without the constant gets the setting from the block")
        self.assertEqual(text.count(".strictMemorySafety()"), 2, "App gets it once, through the constant")
        self.assertEqual(lander.hand_set(text), [], "the constant is the lander's")
        self.assertEqual(self.repo.run("--write")[:2], (0, ""), "a second run writes nothing")
        self.repo.rows([])
        self.repo.run("--write")
        self.assertEqual(self.repo.read(APP), APP_WITH_CONSTANT)

    def test_refusals(self):
        cases = {
            "not an allowed swift form": row(setting='.unsafeFlags(["-Ounchecked"])'),
            "not in HARDENING_FLAGS": row(target="FooC", setting='.unsafeFlags(["-Ounchecked"])', kind="c"),
            "not a Swift target": row(target="FooC"),
            "not a C target": row(target="Foo", setting='.define("X")', kind="c"),
            "not a CmuxNext closure package": row(package="Packages/Shared/Unrelated", target="Unrelated"),
            "vendored verbatim": row(package="Packages/Shared/Vendored", target="Vendored"),
            "not a task id": row(task="someone"),
            'its target is "*"': row(package="*", target="Foo"),
        }
        for message, bad in cases.items():
            with self.subTest(message):
                self.repo.rows([bad])
                code, _, err = self.repo.run("--write")
                self.assertEqual(code, 2)
                self.assertIn(message, err)
                self.assertEqual(self.repo.read(FOO), FOO_MANIFEST)

    def test_conflicting_rows_are_refused(self):
        for settings in (('.treatWarning("StrictMemorySafety", as: .error)', '.treatWarning("StrictMemorySafety", as: .warning)'),
                         (".swiftLanguageMode(.v6)", ".swiftLanguageMode(.v5)")):
            with self.subTest(settings[0]):
                self.repo.rows([row(target="FooLab", setting=s) for s in settings])
                code, _, err = self.repo.run("--write")
                self.assertEqual(code, 2)
                self.assertIn("rows ask for both", err)

    def test_hand_written_lander_only_setting_fails_check(self):
        (self.repo.root / FOO).write_text(
            FOO_MANIFEST.replace("[.swiftLanguageMode(.v6)]", "[.swiftLanguageMode(.v6), .strictMemorySafety()]"))
        code, _, err = self.repo.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("lander-only setting", err)

    def test_hand_edited_block_fails_check(self):
        self.repo.rows([row()])
        self.repo.run("--write")
        text = self.repo.read(FOO)
        (self.repo.root / FOO).write_text(text.replace('"Foo",', '"Foo",\n            "FooTests",'))
        self.assertEqual(self.repo.run("--check")[0], 1)

    def test_check_rev_judges_a_commit(self):
        self.repo.init_git()
        self.repo.rows([row()])
        self.repo.commit_all("p10-stability-211: add a row")
        self.repo.run("--write")
        self.assertEqual(self.repo.run("--check")[0], 0)
        code, _, err = self.repo.run("--check", "--rev", "HEAD")
        self.assertEqual(code, 1, "the commit has the row but not the rewrite")
        self.assertIn(f"{FOO}: stale", err)

    def test_commit_lands_one_commit_and_verify_commits_flags_hand_edits(self):
        self.repo.init_git()
        self.repo.rows([row()])
        self.repo.commit_all("p10-stability-211: add a row")
        code, out, err = self.repo.run("--commit")
        self.assertEqual(code, 0, err)
        sha = self.repo.git("rev-parse", "HEAD").strip()
        self.assertIn(f"git push origin HEAD\n  cmux-ci build cmux --ref {sha} --tag stability-settings-{sha[:9]} "
                      f"--workspace <PR or branch URL> --receipt artifacts/fleet/{sha}-submit.json\n  cmux-ci wait", out)
        self.assertTrue(self.repo.git("log", "-1", "--format=%s").startswith(lander.LANDER_SUBJECT))
        self.assertEqual(self.repo.git("show", "--name-only", "--format=", "HEAD").split(), [FOO])
        self.assertEqual(self.repo.run("--verify-commits", "HEAD~2..HEAD")[0], 0, "a real lander commit passes")
        self.assertEqual(self.repo.run("--commit")[1], "nothing to land: every manifest matches the rows\n")

        (self.repo.root / FOO).write_text(self.repo.read(FOO).replace(".strictMemorySafety(),", ""))
        self.repo.commit_all("p04-input-012: unrelated work")
        self.assertEqual(self.repo.run("--verify-commits", "HEAD~2..HEAD~1")[0], 0)
        code, _, err = self.repo.run("--verify-commits", "HEAD~2..HEAD")
        self.assertEqual(code, 1)
        self.assertIn("changes p10 settings outside a lander commit (p04-input-012: unrelated work)", err)

    def test_verify_commits_flags_row_settings_tools_and_fake_lander_commits(self):
        self.repo.init_git()
        self.repo.rows([row(target="*", setting='.enableUpcomingFeature("StrictConcurrency")', task="p10-stability-038"),
                        row(target="FooLab", setting=".swiftLanguageMode(.v6)", task="p10-stability-045")])
        base = self.repo.commit_all("p10-stability-038: rows")
        cases = {
            "a row's setting by hand": ("p04-input-012: x", FOO_MANIFEST.replace(
                '.define("APPKIT_NATIVE"),', '.define("APPKIT_NATIVE"),\n                .enableUpcomingFeature("StrictConcurrency"),')),
            "a language flip by hand": ("p04-input-012: x", FOO_MANIFEST.replace(".swiftLanguageMode(.v5)", ".swiftLanguageMode(.v6)")),
            "a tools bump by hand": ("p04-input-012: x", FOO_MANIFEST.replace("6.0", "6.2", 1)),
            "a fake lander commit": (f"{lander.LANDER_SUBJECT} hand edit", FOO_MANIFEST.replace(".v5", ".v6")),
        }
        for name, (subject, text) in cases.items():
            with self.subTest(name):
                self.repo.git("checkout", "-q", "--detach", base)
                self.repo.write(FOO, text)
                self.repo.commit_all(subject)
                code, _, err = self.repo.run("--verify-commits", f"{base}..HEAD", "--rev", "HEAD")
                self.assertEqual(code, 1, err)
        self.repo.git("checkout", "-q", "--detach", base)
        self.repo.write(FOO, FOO_MANIFEST.replace('.target(name: "FooC"),', '.target(name: "FooC"),\n        .target(name: "FooNew"),'))
        self.repo.commit_all("p04-input-012: a new target, no p10 setting")
        self.assertEqual(self.repo.run("--verify-commits", f"{base}..HEAD")[0], 0)
        self.repo.git("checkout", "-q", "--detach", base)
        self.repo.run("--write")
        self.repo.write("Packages/Shared/Foo/Sources/Foo/Foo.swift", "public struct Foo { }\n")
        self.repo.commit_all(f"{lander.LANDER_SUBJECT} with a source change")
        code, _, err = self.repo.run("--verify-commits", f"{base}..HEAD")
        self.assertEqual(code, 1)
        self.assertIn("not only closure manifests", err)

    def test_commit_refuses_uncommitted_rows(self):
        self.repo.init_git()
        self.repo.rows([row()])
        code, _, err = self.repo.run("--commit")
        self.assertEqual(code, 2)
        self.assertIn("stability-settings.json has uncommitted changes", err)
        self.assertEqual(self.repo.read(FOO), FOO_MANIFEST)

    def test_commit_refuses_a_dirty_manifest(self):
        self.repo.init_git()
        self.repo.rows([row()])
        self.repo.commit_all("p10-stability-211: add a row")
        (self.repo.root / FOO).write_text(FOO_MANIFEST + "// local edit\n")
        code, _, err = self.repo.run("--commit")
        self.assertEqual(code, 2)
        self.assertIn("uncommitted edits", err)

    def test_failed_commit_restores_the_manifests(self):
        self.repo.init_git()
        self.repo.rows([row()])
        self.repo.commit_all("p10-stability-211: add a row")
        hooks = self.repo.root / ".no-hooks"
        hooks.mkdir()
        (hooks / "pre-commit").write_text("#!/bin/sh\necho refused by hook >&2\nexit 1\n")
        (hooks / "pre-commit").chmod(0o755)
        code, _, err = self.repo.run("--commit")
        self.assertEqual(code, 2)
        self.assertIn("the lander commit failed", err)
        self.assertIn("refused by hook", err)
        self.assertEqual(self.repo.read(FOO), FOO_MANIFEST)
        self.assertEqual(self.repo.git("status", "--porcelain", "--", FOO), "")

    def test_prepush_gate_refuses_a_hand_set_p10_setting(self):
        gate = load("cmux_next_prepush_gate_for_stability", "prepush-gate.py")
        self.repo.init_git()
        self.repo.rows([row(target="*", setting='.enableUpcomingFeature("StrictConcurrency")', task="p10-stability-038")])
        base = self.repo.commit_all("p10-stability-038: rows")
        self.repo.write(FOO, FOO_MANIFEST.replace("[.swiftLanguageMode(.v6)]",
                                                  '[.swiftLanguageMode(.v6), .enableUpcomingFeature("StrictConcurrency")]'))
        head = self.repo.commit_all("p04-input-012: by hand")

        class Own:
            pass
        own = Own()
        own.base, own.head, own.before = base, head, ()
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertTrue(gate.stability_settings(self.repo.root, [own], HERE.parent))
        self.assertIn("changes p10 settings outside a lander commit", err.getvalue())
        own.before = ((base, head),)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(gate.stability_settings(self.repo.root, [own], HERE.parent), "a range the push does not own")
        own.base, own.before = head, ()
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(gate.stability_settings(self.repo.root, [own], HERE.parent), "no Package.swift change")

    def test_checked_in_rows_match_the_manifests(self):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = lander.main(["--check"])
        self.assertEqual(code, 0, err.getvalue())
        self.assertIn("Packages/Shared/CmuxMessagesLab", lander.closure(lander.WorkTree(lander.ROOT)))


if __name__ == "__main__":
    unittest.main()
