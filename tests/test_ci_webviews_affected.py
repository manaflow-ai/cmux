#!/usr/bin/env python3
"""scripts/ci/webviews_affected.py picks the webviews test files a pull request can affect.

A fixture repository holds a small webviews tree: a hub module most tests import, a leaf
module one test imports, a test that reads files from disk, and a source that names a file
outside webviews/. Each case diffs one commit against its parent and checks the selection,
including the cases that must run every file (a build input, an unmapped asset, a name found
in a non-code file).
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import webviews_affected as wa  # noqa: E402

TREE = {
    "webviews/package.json": "{}\n",
    "webviews/src/hub.ts": "export const hub = 1;\n",
    "webviews/src/leaf.ts": 'import { hub } from "./hub";\nexport const leaf = hub;\n',
    "webviews/src/other.ts": 'import { hub } from "./hub";\nexport const other = hub;\n',
    "webviews/src/dead.ts": "export const dead = 1;\n",
    "webviews/src/strings.ts": 'export const path = "schemas/settings/settings-schema.json";\n',
    "webviews/src/page.css": "body {}\n",
    "webviews/src/fixture.json": '{"file": "cmux-tui/assets/fixture-icons.svg"}\n',
    "webviews/test/leaf.test.ts": 'import { leaf } from "../src/leaf";\n',
    "webviews/test/other.test.ts": 'import { other } from "../src/other";\n',
    "webviews/test/strings.test.ts": 'import { path } from "../src/strings";\n',
    "webviews/test/scan.test.ts": 'import { readFileSync } from "node:fs";\nreadFileSync("src/x");\n',
    "schemas/settings/settings-schema.json": "{}\n",
    "cmux-tui/assets/fixture-icons.svg": "<svg/>\n",
    "docs/readme.md": "x\n",
    "unrelated/tool.py": "x = 1\n",
}


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout


class SelectTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "t@t")
        git(self.root, "config", "user.name", "t")
        for path, text in TREE.items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(text)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "base")

    def change(self, *paths: str, delete: bool = False) -> list[str] | None:
        for path in paths:
            if delete:
                git(self.root, "rm", "-q", path)
            else:
                (self.root / path).parent.mkdir(parents=True, exist_ok=True)
                with open(self.root / path, "a") as out:
                    out.write("// changed\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "change")
        files = wa.changed(self.root, "HEAD^1", "HEAD")
        selected, _ = wa.Selector(self.root).select(files)
        return None if selected is None else sorted(selected)

    def test_a_leaf_selects_its_importer_and_the_disk_readers(self) -> None:
        self.assertEqual(self.change("webviews/src/leaf.ts"),
                         ["webviews/test/leaf.test.ts", "webviews/test/scan.test.ts"])

    def test_a_hub_selects_every_test_that_reaches_it(self) -> None:
        self.assertEqual(self.change("webviews/src/hub.ts"),
                         ["webviews/test/leaf.test.ts", "webviews/test/other.test.ts", "webviews/test/scan.test.ts"])

    def test_a_changed_test_runs_itself(self) -> None:
        self.assertEqual(self.change("webviews/test/other.test.ts"),
                         ["webviews/test/other.test.ts", "webviews/test/scan.test.ts"])

    def test_a_file_outside_webviews_selects_the_tests_reaching_what_names_it(self) -> None:
        self.assertEqual(self.change("schemas/settings/settings-schema.json"),
                         ["webviews/test/scan.test.ts", "webviews/test/strings.test.ts"])

    def test_a_file_no_webviews_source_names_and_docs_select_only_disk_readers(self) -> None:
        self.assertEqual(self.change("unrelated/tool.py", "docs/readme.md"), ["webviews/test/scan.test.ts"])

    def test_a_source_no_test_imports_and_a_deleted_test_select_only_disk_readers(self) -> None:
        self.assertEqual(self.change("webviews/src/dead.ts"), ["webviews/test/scan.test.ts"])
        self.assertEqual(self.change("webviews/test/leaf.test.ts", delete=True), ["webviews/test/scan.test.ts"])

    def test_build_inputs_unmapped_assets_and_names_in_data_files_run_everything(self) -> None:
        self.assertIsNone(self.change("webviews/package.json"))
        self.assertIsNone(self.change("webviews/src/page.css"))
        self.assertIsNone(self.change("cmux-tui/assets/fixture-icons.svg"))
        self.assertIsNone(self.change("scripts/ci/webviews_affected.py"))

    def test_the_cli_prints_paths_under_webviews_or_nothing(self) -> None:
        self.change("webviews/src/leaf.ts")
        run = lambda: subprocess.run([sys.executable, str(ROOT / "scripts/ci/webviews_affected.py"), "--base", "HEAD^1",
                                      "--repo", str(self.root)], capture_output=True, text=True, check=True)
        self.assertEqual(run().stdout.split(), ["test/leaf.test.ts", "test/scan.test.ts"])
        self.change("webviews/package.json")
        self.assertEqual(run().stdout, "")


if __name__ == "__main__":
    unittest.main()
