#!/usr/bin/env python3
"""job_input_fingerprint.py dev-release-product: the compiled DEV Release app's key is its content.

The key lets a later run reuse the compiled app instead of compiling it, so every path that can
reach the app must change it (a missed input ships a stale app) and paths that cannot (docs, tests,
other products) must not. The same tree under another commit gives the same key: producer and
consumer both key the tree they check out and build (the pushed or dispatched commit's).
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import job_input_fingerprint as fingerprint  # noqa: E402

TOOLCHAIN = {"xcode": "Xcode 26.0 Build version 17A324", "sdk": "26.0 25A350", "arch": "arm64",
             "recipe": "dev-release-product-v1", "tui_tree": "own"}
FILES = {
    ".github/workflows/cmux-next.yml": "name: cmux-next\n",
    ".github/workflows/other.yml": "name: other\n",
    ".github/actions/setup/action.yml": "runs: {}\n",
    "cmux.xcodeproj/project.pbxproj": "A /* x */ = {path = THIRD_PARTY_LICENSES.md; sourceTree = SOURCE_ROOT; };\n",
    "THIRD_PARTY_LICENSES.md": "licenses\n",
    "README.md": "readme\n",
    "Packages/macOS/CmuxNext/Package.swift": "// package\n",
    "Packages/macOS/CmuxNext/Sources/App/App.swift": "let app = 1\n",
    "Packages/macOS/CmuxNext/Tests/AppTests/AppTests.swift": "let test = 1\n",
    "Packages/Shared/Core/Sources/Core/Core.swift": "let core = 1\n",
    "Packages/Shared/Core/Tests/CoreTests/CoreTests.swift": "let coreTest = 1\n",
    "scripts/cmux-next/check-cmux-scheme-compile.sh": "xcodebuild\n",
    "scripts/cmux-next/tests/compile.test.sh": "test\n",
    "scripts/cmux-next/cmux-tui-tree-inputs.txt": "tree cmux-tui\nblob backend/catalog/ops.json\n",
    "cmux-tui/src/main.rs": "fn main() {}\n",
    "backend/catalog/ops.json": "{}\n",
    "backend/server.ts": "server\n",
    "ios/App.swift": "classic ios\n",
    "webviews/src/app.ts": "app\n",
    "web/data/model-catalog/models.json": "{}\n",
    "web/pages/index.tsx": "page\n",
    "docs/guide.md": "guide\n",
    "docs/mdm/profile.mobileconfig": "mdm\n",
    "plans/cmux-next/shell.md": "plan\n",
    "plans/cmux-next/daemon-capabilities.json": "{}\n",
    "tests/test_something.py": "test\n",
        "cmux-next-ios/App.swift": "ios\n",
}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                               "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull,
                               "GIT_CONFIG_SYSTEM": os.devnull}).stdout


class ProductKey(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        git(self.root, "init", "-q")
        for name, text in FILES.items():
            self.write(name, text)
        self.commit()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name: str, text: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message: str = "c") -> None:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "--allow-empty", "-m", message)

    def key(self, **values: str) -> str:
        extra = [f"{name}={value}" for name, value in {**TOOLCHAIN, **values}.items()]
        return fingerprint.fingerprint(str(self.root), "HEAD", "dev-release-product", extra)[0]

    def changes(self, name: str) -> bool:
        before = self.key()
        path = self.root / name
        self.write(name, (path.read_text() if path.exists() else "") + "changed\n")
        self.commit()
        return self.key() != before

    def test_the_key_is_content_only(self):
        before = self.key()
        self.commit("another commit on the same tree")
        self.assertEqual(self.key(), before)

    def test_every_product_input_changes_the_key(self):
        for name in ("Packages/macOS/CmuxNext/Sources/App/App.swift", "Packages/Shared/Core/Sources/Core/Core.swift",
                     "Packages/macOS/CmuxNext/Package.swift", "cmux.xcodeproj/project.pbxproj",
                     "scripts/cmux-next/check-cmux-scheme-compile.sh", "cmux-tui/src/main.rs", "webviews/src/app.ts",
                     ".github/workflows/cmux-next.yml", ".github/actions/setup/action.yml", "README.md",
                     "THIRD_PARTY_LICENSES.md", "plans/cmux-next/daemon-capabilities.json",
                     # Kept inside excluded directories: named by another input list.
                     "docs/mdm/profile.mobileconfig",
                     "web/data/model-catalog/models.json", "backend/catalog/ops.json",
                     # A path no rule names is an input.
                     "backend/server.ts", "web/pages/index.tsx", "cmux-next-ios/App.swift",
                     "NewProduct/Thing.swift"):
            with self.subTest(name=name):
                self.assertTrue(self.changes(name), f"{name} must change the key")

    def test_paths_that_cannot_reach_the_app_keep_the_key(self):
        for name in ("Packages/macOS/CmuxNext/Tests/AppTests/AppTests.swift",
                     "Packages/Shared/Core/Tests/CoreTests/CoreTests.swift", "scripts/cmux-next/tests/compile.test.sh",
                     "docs/guide.md", "plans/cmux-next/shell.md", "tests/test_something.py",
                     ".github/workflows/other.yml", "ios/App.swift"):
            with self.subTest(name=name):
                self.assertFalse(self.changes(name), f"{name} must not change the key")

    def test_the_toolchain_recipe_and_cmux_tui_tree_count(self):
        before = self.key()
        for name, value in (("xcode", "Xcode 26.1 Build version 17B1"), ("sdk", "26.1 25B1"), ("arch", "x86_64"),
                            ("recipe", "dev-release-product-v0"), ("tui_tree", "a" * 40)):
            with self.subTest(name=name):
                self.assertNotEqual(self.key(**{name: value}), before)

    def test_a_missing_toolchain_value_gives_no_key(self):
        with self.assertRaises(fingerprint.Unresolved):
            fingerprint.fingerprint(str(self.root), "HEAD", "dev-release-product", ["xcode=x", "sdk=y", "arch=arm64"])


class RealTree(unittest.TestCase):
    """The repository's own tree: what the app is built from is never excluded."""

    def inputs(self) -> dict[str, str]:
        return fingerprint.product_inputs(str(ROOT), "HEAD")

    def covered(self, inputs: dict[str, str], path: str) -> bool:
        return any(path == top or path.startswith(top + "/") for top in inputs)

    def test_the_app_sources_project_and_bundled_files_are_inputs(self):
        inputs = self.inputs()
        for path in ("cmux.xcodeproj/project.pbxproj", "THIRD_PARTY_LICENSES.md", "LICENSE", "Resources",
                     "Packages/macOS/CmuxNext/Sources", "Packages/macOS/CmuxNext/Package.swift",
                     "Packages/macOS/CmuxNext/Package.resolved", "cmux-tui", "webviews",
                     "scripts/cmux-next/bundle-cli-resources.sh", "scripts/cmux-next/check-cmux-scheme-compile.sh",
                     "backend/catalog/cloud-relay-operations.json", "cmux-next-ios/rust", "tests/fixtures/classic-to-next",
                     "scripts/build-diff-sidecar.sh", "Native", "vendor", "ghostty", ".github/workflows/cmux-next.yml",
                     "skills"):
            with self.subTest(path=path):
                self.assertTrue(self.covered(inputs, path), f"{path} must be a DEV Release product input")
        self.assertFalse(self.covered(inputs, "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests"))

    def test_every_xcode_project_reference_is_an_input(self):
        text = (ROOT / "cmux.xcodeproj/project.pbxproj").read_text()
        inputs = self.inputs()
        for path in re.findall(r'path = "?([^";]+)"?; sourceTree = SOURCE_ROOT;', text):
            with self.subTest(path=path):
                self.assertTrue(self.covered(inputs, fingerprint.normalize(path)))

    def test_no_shipped_package_target_lives_under_tests(self):
        # Packages/*/Tests is excluded. A non-test target there must be test support only; review a
        # new one before adding it here (the app must not link it).
        test_support = {"CmuxNextTestExitTrace", "CmuxHomeCoreTestSupport"}
        found = set()
        for manifest in ROOT.glob("Packages/**/Package.swift"):
            text = manifest.read_text()
            for match in re.finditer(r'\.(target|executableTarget)\(\s*name:\s*"([^"]+)"(.*?)\n\s*\)', text, re.S):
                if re.search(r'path:\s*"Tests[/"]', match.group(3)):
                    found.add(match.group(2))
        self.assertLessEqual(found, test_support, f"package targets under Tests/: {sorted(found - test_support)}")

    def test_every_tracked_path_a_build_script_names_is_an_input(self):
        # The Xcode build phases and the compile step's scripts copy files into the app
        # (bundle-cli-resources.sh's backend catalogs). Any tracked path one of them names outside a
        # comment must be keyed, or a change to it would reuse a stale app.
        scripts = [ROOT / "scripts/cmux-next/check-cmux-scheme-compile.sh", ROOT / "scripts/build-diff-sidecar.sh"]
        scripts += sorted(ROOT.glob("scripts/cmux-next/bundle-*.sh")) + sorted(ROOT.glob("scripts/cmux-next/embed-*.sh"))
        scripts += sorted(ROOT.glob("scripts/cmux-next/build-*.sh"))
        tracked = set(subprocess.run(["git", "-C", str(ROOT), "ls-files"], check=True, capture_output=True,
                                     text=True).stdout.splitlines())
        inputs = self.inputs()
        for script in scripts:
            for line in script.read_text().splitlines():
                code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
                for path in re.findall(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+", code):
                    if path in tracked:
                        with self.subTest(script=script.name, path=path):
                            self.assertTrue(self.covered(inputs, path), f"{script.name} names {path}, not keyed")



if __name__ == "__main__":
    unittest.main()
