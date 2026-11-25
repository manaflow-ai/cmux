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
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

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
    "webviews/src/pool.ts": "export const pool = 1;\n",
    "webviews/src/app.ts": 'import { hub } from "./hub";\nexport const app = hub;\n',
    "webviews/src/files.ts": 'import { readFile } from "node:fs/promises";\nexport const read = readFile;\n',
    "webviews/src/tools.ts": 'export const tools = ["readFile", "readdir"];\n',
    "webviews/test/pool.test.ts": "const load = () => import(`../src/pool.ts`);\n",
    "webviews/test/fresh.test.ts": "const load = () => import(`../src/pool.ts?${Math.random()}`);\n",
    "webviews/test/served.test.ts": 'const { createServer } = await import("vite");\n',
    "webviews/test/tools.test.ts": 'import { tools } from "../src/tools";\n',
    "webviews/test/helper.test.ts": 'import { read } from "../src/files";\n',
    "webviews/test/preload.ts": 'import { hub } from "../src/preloaded";\n',
    "webviews/src/preloaded.ts": "export const hub = 1;\n",
    "schemas/settings/settings-schema.json": "{}\n",
    "cmux-tui/assets/fixture-icons.svg": "<svg/>\n",
    "docs/readme.md": "x\n",
    "webviews/src/gallery/sample.md": "x\n",
    "webviews/src/raw.ts": 'import TEXT from "./gallery/sample.md?raw";\nexport const raw = TEXT;\n',
    "webviews/test/raw.test.ts": 'import { raw } from "../src/raw";\n',
    "webviews/src/art.webp": "x\n",
    "webviews/src/art.ts": 'import ART from "./art.webp?url";\nexport const art = ART;\n',
    "webviews/src/docs.ts": 'export const doc = "README.md";\n',
    "webviews/test/docs.test.ts": 'import { doc } from "../src/docs";\n',
    "README.md": "x\n",
    "unrelated/tool.py": "x = 1\n",
}


# Tests the import graph cannot cover, which every selection runs: one reads files, one imports
# a computed path, one starts Vite, one imports a helper that reads files.
ALWAYS = ["webviews/test/fresh.test.ts", "webviews/test/helper.test.ts", "webviews/test/scan.test.ts",
          "webviews/test/served.test.ts"]


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout


def with_always(*tests: str) -> list[str]:
    return sorted(set(tests) | set(ALWAYS))


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
                         with_always("webviews/test/leaf.test.ts"))

    def test_a_hub_selects_every_test_that_reaches_it(self) -> None:
        self.assertEqual(self.change("webviews/src/hub.ts"),
                         with_always("webviews/test/leaf.test.ts", "webviews/test/other.test.ts"))

    def test_a_changed_test_runs_itself(self) -> None:
        self.assertEqual(self.change("webviews/test/other.test.ts"),
                         with_always("webviews/test/other.test.ts"))

    def test_a_file_outside_webviews_selects_the_tests_reaching_what_names_it(self) -> None:
        self.assertEqual(self.change("schemas/settings/settings-schema.json"),
                         with_always("webviews/test/strings.test.ts"))

    def test_a_file_no_webviews_source_names_and_docs_select_only_the_always_set(self) -> None:
        self.assertEqual(self.change("unrelated/tool.py", "docs/readme.md"), ALWAYS)

    def test_a_source_no_test_imports_and_a_deleted_test_select_only_the_always_set(self) -> None:
        self.assertEqual(self.change("webviews/src/dead.ts"), ALWAYS)
        self.assertEqual(self.change("webviews/test/leaf.test.ts", delete=True), ALWAYS)

    def test_a_template_import_reaches_its_static_path(self) -> None:
        self.assertEqual(self.change("webviews/src/pool.ts"), with_always("webviews/test/pool.test.ts"))

    def test_an_asset_imported_with_a_query_selects_the_tests_reaching_its_importer(self) -> None:
        self.assertEqual(self.change("webviews/src/gallery/sample.md"), with_always("webviews/test/raw.test.ts"))
        self.assertEqual(self.change("webviews/src/art.webp"), ALWAYS)

    def test_a_doc_named_in_prose_selects_only_the_always_set(self) -> None:
        self.assertEqual(self.change("README.md"), ALWAYS)

    def test_strings_naming_file_reads_in_app_code_do_not_mark_a_test(self) -> None:
        self.assertEqual(self.change("webviews/src/tools.ts"), with_always("webviews/test/tools.test.ts"))

    def test_a_deleted_source_and_the_preloads_imports_run_everything(self) -> None:
        self.assertIsNone(self.change("webviews/src/dead.ts", delete=True))
        self.assertIsNone(self.change("webviews/src/preloaded.ts"))
        self.assertIsNone(self.change("webviews/test/preload.ts"))

    def test_build_inputs_unmapped_assets_and_names_in_data_files_run_everything(self) -> None:
        self.assertIsNone(self.change("webviews/package.json"))
        self.assertIsNone(self.change("webviews/src/page.css"))
        self.assertIsNone(self.change("cmux-tui/assets/fixture-icons.svg"))
        self.assertIsNone(self.change("scripts/ci/webviews_affected.py"))

    def test_the_cli_prints_paths_under_webviews_or_nothing(self) -> None:
        self.change("webviews/src/leaf.ts")
        run = lambda: subprocess.run([sys.executable, str(ROOT / "scripts/ci/webviews_affected.py"), "--base", "HEAD^1",
                                      "--repo", str(self.root)], capture_output=True, text=True, check=True)
        self.assertEqual(run().stdout.split(), [t.removeprefix("webviews/") for t in with_always("webviews/test/leaf.test.ts")])
        self.change("webviews/package.json")
        self.assertEqual(run().stdout, "")


if __name__ == "__main__":
    unittest.main()
