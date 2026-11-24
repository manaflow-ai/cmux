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

    def test_package_names_and_empty_import_examples_are_not_dynamic_inputs(self) -> None:
        (self.root / "webviews/src/tools.ts").write_text(
            'export const tools = ["vite", "playwright", "child_process"];\n'
            '// A static import is synchronous; import() yields.\n'
            '// Generated from\n// schemas/motion.json; do not edit.\n')
        # Fixture setup is the base; only the subsequent leaf edit is the PR.
        git(self.root, "add", "webviews/src/tools.ts")
        git(self.root, "commit", "-qm", "fixture package-name prose")
        self.assertEqual(self.change("webviews/src/leaf.ts"), with_always("webviews/test/leaf.test.ts"))

    def test_spaced_static_imports_stay_in_the_import_graph(self) -> None:
        (self.root / "webviews/src/tools.ts").write_text('export const load = () => import( "./other" );\n')
        git(self.root, "add", "webviews/src/tools.ts")
        git(self.root, "commit", "-qm", "fixture static import")
        self.assertEqual(self.change("webviews/src/leaf.ts"), with_always("webviews/test/leaf.test.ts"))
        self.assertEqual(self.change("webviews/src/other.ts"),
                         with_always("webviews/test/other.test.ts", "webviews/test/tools.test.ts"))

    def test_plain_static_require_stays_in_the_import_graph(self) -> None:
        (self.root / "webviews/src/tools.ts").write_text('const other = require("./other");\n')
        git(self.root, "add", "webviews/src/tools.ts")
        git(self.root, "commit", "-qm", "fixture static require")
        self.assertEqual(self.change("webviews/src/leaf.ts"), with_always("webviews/test/leaf.test.ts"))
        self.assertEqual(self.change("webviews/src/other.ts"),
                         with_always("webviews/test/other.test.ts", "webviews/test/tools.test.ts"))

    def test_computed_imports_and_package_loads_still_run(self) -> None:
        for expression in ('import(name)', 'import( name )', 'import(/* runtime */ name)',
                           'import /* runtime */ (name)', 'import /* runtime */ ( name )',
                           'import /* static */ ("./other")', 'import(/* static */ "./other")',
                           'import("vite")', 'require("child_process")',
                           'import /* package */ ( "vite" )', 'require ( "child_process" )',
                           'require /* package */ (/* load */ "child_process")'):
            with self.subTest(expression=expression):
                (self.root / "webviews/src/tools.ts").write_text(f'export const load = () => {expression};\n')
                selected, _ = wa.Selector(self.root).select(["webviews/src/leaf.ts"])
                self.assertIn("webviews/test/tools.test.ts", selected)

    def test_commented_from_and_require_edges_remain_unresolved(self) -> None:
        for source in ('import { other } from /* static */ "./other";',
                       'export { other } from // static\n "./other";',
                       'const other = require /* static */ ("./other");',
                       'const other = require(/* static */ "./other");',
                       'const other = require ("./other");',
                       'const other = require(runtimePath);'):
            with self.subTest(source=source):
                (self.root / "webviews/src/tools.ts").write_text(source + "\n")
                selected, _ = wa.Selector(self.root).select(["webviews/src/other.ts"])
                self.assertIn("webviews/test/tools.test.ts", selected)

    def test_reviewed_runtime_loads_are_not_untracked_until_edited(self) -> None:
        reader = "webviews/src/agent-session/acpmux/frameOwners.ts"
        teardown = "webviews/test/support/domTeardown.ts"
        for path in (reader, teardown):
            destination = self.root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((ROOT / path).read_bytes())
        (self.root / "webviews/test/frames.test.ts").write_text(
            'import { browserOwnersEnv } from "../src/agent-session/acpmux/frameOwners";\n')
        (self.root / "webviews/test/settle.test.ts").write_text('import { settleReact } from "./support/domTeardown";\n')
        git(self.root, "add", "-A")
        selector = wa.Selector(self.root)
        self.assertEqual(sorted(selector.always), ALWAYS, "review the runtime loads after their content changes")
        for changed in ("webviews/test/leaf.test.ts", "webviews/src/leaf.ts", "unrelated/tool.py"):
            with self.subTest(changed=changed):
                selected, _ = selector.select([changed])
                self.assertNotIn("webviews/test/frames.test.ts", selected)
                self.assertNotIn("webviews/test/settle.test.ts", selected)
        selected, _ = selector.select([reader])
        self.assertIn("webviews/test/frames.test.ts", selected)  # an importer of a changed file, as any
        # An unreviewed edit fails open: every test reaching it runs on every change.
        for path, test in ((reader, "frames"), (teardown, "settle")):
            with self.subTest(edited=path):
                (self.root / path).write_text((self.root / path).read_text() + '\nimport(runtimePath);\n')
                selected, _ = wa.Selector(self.root).select(["webviews/test/other.test.ts"])
                self.assertIn(f"webviews/test/{test}.test.ts", selected)

    def test_a_deleted_source_selects_the_tests_reaching_what_still_names_it(self) -> None:
        self.assertEqual(self.change("webviews/src/dead.ts", delete=True), ALWAYS)
        self.assertEqual(self.change("webviews/src/leaf.ts", delete=True), with_always("webviews/test/leaf.test.ts"))

    def test_a_deleted_source_a_data_file_or_a_short_name_may_load_runs_everything(self) -> None:
        (self.root / "webviews/src/listed.ts").write_text("export const listed = 1;\n")
        (self.root / "webviews/src/list.json").write_text('{"module": "./src/listed"}\n')
        (self.root / "webviews/src/abc.ts").write_text("export const abc = 1;\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "fixture names")
        self.assertIsNone(self.change("webviews/src/listed.ts", delete=True))
        self.assertIsNone(self.change("webviews/src/abc.ts", delete=True))

    def test_the_undo_variable_restores_the_wider_selection(self) -> None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        (self.root / "webviews/scripts").mkdir(parents=True, exist_ok=True)
        (self.root / "webviews/scripts/table-baseline.tsv").write_text("a\t1\n")
        (self.root / "webviews/test/table.test.ts").write_text(
            'import { readFileSync } from "node:fs";\nreadFileSync("scripts/table-baseline.tsv");\n')
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "fixture reader")
        wa.NARROW = False
        try:
            self.assertIsNone(self.change("webviews/src/leaf.ts", delete=True))
            found, _ = ps.touched(wa.Selector(self.root), ["webviews/scripts/table-baseline.tsv"])
            self.assertIsNone(found)
        finally:
            wa.NARROW = True

    def test_the_preloads_imports_run_everything(self) -> None:
        self.assertIsNone(self.change("webviews/src/preloaded.ts"))
        self.assertIsNone(self.change("webviews/test/preload.ts"))

    def test_inputs_every_test_loads_run_everything(self) -> None:
        for path in ("webviews/package.json", "webviews/bun.lock", "webviews/bunfig.toml", "webviews/tsconfig.json",
                     "webviews/reactCompiler.mjs", "scripts/ci/webviews_affected.py", "scripts/ci/run-webviews-tests.sh",
                     ".github/workflows/ci-web.yml"):
            with self.subTest(path=path):
                self.assertIsNone(self.change(path))

    def test_unmapped_assets_and_names_in_data_files_select_the_always_set(self) -> None:
        # A css a page links, or a file a fixture names: only Vite, a browser or a file read loads them, and every
        # test doing those is always-run.
        self.assertEqual(self.change("webviews/src/page.css"), ALWAYS)
        self.assertEqual(self.change("cmux-tui/assets/fixture-icons.svg"), ALWAYS)
        (self.root / "webviews/test/fixture.test.ts").write_text('import data from "../src/fixture.json";\n')
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "fixture importer")
        self.assertEqual(self.change("cmux-tui/assets/fixture-icons.svg"), with_always("webviews/test/fixture.test.ts"))

    def test_a_name_in_a_resolution_config_runs_everything(self) -> None:
        (self.root / "shared").mkdir()
        (self.root / "shared/aliased-module.ts").write_text("export const a = 1;\n")
        (self.root / "tools").mkdir()
        (self.root / "tools/check-colors.py").write_text("x = 1\n")
        (self.root / "webviews/tsconfig.json").write_text('{"compilerOptions": {"paths": {"@a": ["../shared/aliased-module.ts"]}}}\n')
        (self.root / "webviews/package.json").write_text('{"scripts": {"colors": "python3 ../tools/check-colors.py"}}\n')
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "fixture configs")
        self.assertIsNone(self.change("shared/aliased-module.ts"))
        # A package.json script is a shell command: a test running it spawns a process, so it is always-run.
        self.assertEqual(self.change("tools/check-colors.py"), ALWAYS)
        (self.root / "webviews/package.json").write_text(
            '{"imports": {"#colors": "../tools/check-colors.py"}, "scripts": {}}\n')
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "fixture imports map")
        self.assertIsNone(self.change("tools/check-colors.py"))

    def test_vite_configs_scripts_and_helpers_outside_the_preload_select_their_tests(self) -> None:
        (self.root / "webviews/scripts").mkdir(parents=True, exist_ok=True)
        (self.root / "webviews/test/support").mkdir(parents=True, exist_ok=True)
        (self.root / "webviews/vite.config.ts").write_text('export default {};\n')
        (self.root / "webviews/scripts/table.mjs").write_text("export const t = 1;\n")
        (self.root / "webviews/test/support/helper.ts").write_text("export const h = 1;\n")
        (self.root / "webviews/test/helped.test.ts").write_text(
            'import { h } from "./support/helper";\nimport { t } from "../scripts/table.mjs";\n')
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "fixture helpers")
        # Vite builds and serves pages; every test that runs it, a browser, or reads a bundle is always-run.
        self.assertEqual(self.change("webviews/vite.config.ts"), ALWAYS)
        self.assertEqual(self.change("webviews/test/support/helper.ts"), with_always("webviews/test/helped.test.ts"))
        self.assertEqual(self.change("webviews/scripts/table.mjs"), with_always("webviews/test/helped.test.ts"))
        wa.NARROW = False
        try:
            self.assertIsNone(self.change("webviews/vite.config.ts"))
            self.assertIsNone(self.change("webviews/scripts/table.mjs"))
            self.assertIsNone(self.change("webviews/src/page.css"))
            self.assertIsNone(self.change("cmux-tui/assets/fixture-icons.svg"))
        finally:
            wa.NARROW = True

    def test_the_cli_prints_paths_under_webviews_or_nothing(self) -> None:
        self.change("webviews/src/leaf.ts")
        run = lambda: subprocess.run([sys.executable, str(ROOT / "scripts/ci/webviews_affected.py"), "--base", "HEAD^1",
                                      "--repo", str(self.root)], capture_output=True, text=True, check=True)
        self.assertEqual(run().stdout.split(), [t.removeprefix("webviews/") for t in with_always("webviews/test/leaf.test.ts")])
        self.change("webviews/package.json")
        self.assertEqual(run().stdout, "")



STAGE = """import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame } from "./support/galleryFrame";
const server = await createServer({ configFile: "vite.config.gallery-dev.ts" });
const page = await (await chromium.launch()).newPage();
await page.goto(`http://x${galleryFrame("button-basic")}`);
"""
GALLERY = {
    "webviews/vite.config.gallery-dev.ts": 'import { defineConfig } from "vite";\nexport default defineConfig({});\n',
    "webviews/src/gallery/frame/main.ts": 'import { shell } from "../shell";\nexport const frame = shell;\n',
    "webviews/src/gallery/shell.ts": "export const shell = 1;\n",
    "webviews/scripts/agent-pane/bundle.mjs": 'import fs from "node:fs";\nexport const bundle = fs;\n',
    "webviews/src/agent-session/acpmux/dev.tsx": "export const dev = 1;\n",
    "webviews/test/support/galleryFrame.ts": 'import fs from "node:fs";\nexport const galleryFrame = (id: string) => id;\n',
    "webviews/src/ui/button.tsx": 'import "./button.css";\nexport const Button = 1;\n',
    "webviews/src/ui/button.css": ".button {}\n",
    "webviews/src/ui/button.gallery.tsx": 'import { Button } from "./button";\nexport default [{\n  id: "button-basic",\n  Button,\n}];\n',
    "webviews/src/ui/card.tsx": "export const Card = 1;\n",
    "webviews/src/ui/card.gallery.tsx": 'import { Card } from "./card";\nexport default [{\n  id: "card-basic",\n  Card,\n}];\n',
    "webviews/test/button-stage.test.ts": STAGE,
    "webviews/test/reads-stage.test.ts": STAGE.replace('import { chromium }', 'import { readFileSync } from "node:fs";\nimport { chromium }')
    + 'readFileSync("baseline.txt");\n',
    "webviews/test/support/sweep.ts": 'import { chromium } from "playwright";\nexport async function sweep(o: object) { return [o, chromium]; }\n',
    "webviews/test/sweep-1.test.ts": '// Part 1 of 2.\nimport { sweep } from "./support/sweep";\n\nawait sweep({\n  part: 1,\n  parts: 2,\n});\n',
    "webviews/test/sweep-env.test.ts": 'import { sweep } from "./support/sweep";\n\nawait sweep({ part: process.env.PART });\n',
    "webviews/vite.config.pane.mjs": 'import { defineConfig } from "vite";\nexport default defineConfig({ root: "src/pane" });\n',
    "webviews/src/pane/index.html": '<script type="module" src="./main.ts"></script>\n',
    "webviews/src/pane/main.ts": 'import { Card } from "../ui/card";\nexport const pane = Card;\n',
    "webviews/test/pane-page.test.ts": 'import { chromium } from "playwright";\nimport { createServer } from "vite";\n'
    'const server = await createServer({ configFile: "vite.config.pane.mjs" });\nconst url = "http://x/";\n'
    "const page = await (await chromium.launch()).newPage();\nawait page.goto(url);\n",
    "webviews/src/ops.ts": "/** The last import (RowState) of a profile. */\nexport const ops = 1;\n",
    "webviews/test/ops.test.ts": 'import { ops } from "../src/ops";\n',
    "schemas/theme/colors.json": "{}\n",
}
HARNESS = ("webviews/vite.config.gallery-dev.ts", "webviews/scripts/agent-pane/bundle.mjs",
           "webviews/test/support/galleryFrame.ts", "webviews/vite.config.pane.mjs")
EDGED = {"webviews/test/button-stage.test.ts", "webviews/test/sweep-1.test.ts", "webviews/test/pane-page.test.ts"}


class GalleryEdgesTest(unittest.TestCase):
    """Stage, sweep and page tests leave the always-run set only through edges the selector follows."""

    def setUp(self) -> None:
        import hashlib  # noqa: PLC0415
        self.root = Path(tempfile.mkdtemp())
        git(self.root, "init", "-q")
        for path, text in {**TREE, **GALLERY}.items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(text)
        git(self.root, "add", "-A")
        pin = lambda f: hashlib.sha256((self.root / f).read_bytes()).hexdigest()  # noqa: E731
        self.saved = (wa.GALLERY_HARNESS, wa.SWEEP_HELPERS, wa.VITE_PAGES, wa.GALLERY_EDGES)
        wa.GALLERY_HARNESS = {f: pin(f) for f in HARNESS}
        wa.SWEEP_HELPERS = {"webviews/test/support/sweep.ts": pin("webviews/test/support/sweep.ts")}
        wa.VITE_PAGES = {"webviews/vite.config.pane.mjs": "webviews/src/pane"}

    def tearDown(self) -> None:
        wa.GALLERY_HARNESS, wa.SWEEP_HELPERS, wa.VITE_PAGES, wa.GALLERY_EDGES = self.saved

    def selected(self, selector: wa.Selector, path: str) -> set[str]:
        found, _ = selector.select([path])
        return set(found or ())

    def test_stage_sweep_and_page_tests_leave_the_always_set(self) -> None:
        selector = wa.Selector(self.root)
        self.assertEqual(set(selector.gallery), EDGED)
        self.assertTrue(EDGED.isdisjoint(selector.always))
        for kept in ("webviews/test/reads-stage.test.ts", "webviews/test/sweep-env.test.ts"):
            self.assertIn(kept, selector.always, "a read or a computed option keeps a test always-run")
        self.assertEqual(self.selected(selector, "webviews/src/leaf.ts") & EDGED, set())

    def test_a_stage_runs_for_its_entry_the_frame_and_the_zone(self) -> None:
        selector = wa.Selector(self.root)
        stage = "webviews/test/button-stage.test.ts"
        self.assertIn(stage, self.selected(selector, "webviews/src/ui/button.tsx"))
        self.assertNotIn(stage, self.selected(selector, "webviews/src/ui/card.tsx"))
        self.assertIn("webviews/test/pane-page.test.ts", self.selected(selector, "webviews/src/ui/card.tsx"))
        for path in ("webviews/src/gallery/shell.ts", "webviews/test/baseline.txt", "schemas/theme/colors.json"):
            with self.subTest(path=path):
                self.assertTrue(EDGED <= self.selected(selector, path))

    def test_an_imported_stylesheet_selects_its_importers_not_every_stage(self) -> None:
        selected = self.selected(wa.Selector(self.root), "webviews/src/ui/button.css")
        self.assertIn("webviews/test/button-stage.test.ts", selected)
        self.assertNotIn("webviews/test/pane-page.test.ts", selected)
        (self.root / "webviews/src/ui/theme.css").write_text('@import "./button.css";\n')
        git(self.root, "add", "-A")
        self.assertTrue(EDGED <= self.selected(wa.Selector(self.root), "webviews/src/ui/button.css"),
                        "a stylesheet another one @imports stays in the zone")

    def test_a_sweep_runs_for_every_entry(self) -> None:
        selector = wa.Selector(self.root)
        for path in ("webviews/src/ui/button.tsx", "webviews/src/ui/card.tsx", "webviews/test/support/sweep.ts"):
            with self.subTest(path=path):
                self.assertIn("webviews/test/sweep-1.test.ts", self.selected(selector, path))

    def test_an_edited_pin_or_the_switch_restores_the_always_set(self) -> None:
        (self.root / "webviews/scripts/agent-pane/bundle.mjs").write_text('import fs from "node:fs";\nfs.readdirSync(".");\n')
        self.assertEqual(wa.Selector(self.root).gallery, {})
        (self.root / "webviews/scripts/agent-pane/bundle.mjs").write_text(GALLERY["webviews/scripts/agent-pane/bundle.mjs"])
        (self.root / "webviews/test/support/sweep.ts").write_text(GALLERY["webviews/test/support/sweep.ts"] + "// edited\n")
        self.assertNotIn("webviews/test/sweep-1.test.ts", wa.Selector(self.root).gallery)
        wa.GALLERY_EDGES = False
        self.assertTrue(EDGED <= wa.Selector(self.root).always)

    def test_a_line_comment_naming_an_import_is_not_a_dynamic_import(self) -> None:
        prose = "const x = 1;\n// inflated on import (CMUX-570, app size).\n"
        self.assertFalse(wa.outside_doc(wa.UNTRACKED, prose))
        self.assertTrue(wa.outside_doc(wa.UNTRACKED, 'const x = 1; import (path);\n'))
        self.assertTrue(wa.outside_doc(wa.UNTRACKED, '// note\nimport (path);\n'))

    def test_a_doc_comment_naming_an_import_is_not_a_dynamic_import(self) -> None:
        self.assertNotIn("webviews/test/ops.test.ts", wa.Selector(self.root).always)
        self.assertTrue(wa.outside_doc(wa.UNTRACKED, '/** note */\nimport fs from "node:fs";\n'))
        wa.NARROW = False
        try:
            self.assertTrue(wa.outside_doc(wa.UNTRACKED, GALLERY["webviews/src/ops.ts"]))
        finally:
            wa.NARROW = True


class PullRequestShardsTest(unittest.TestCase):
    """scripts/ci/webviews_pr_shards.py: a pull request runs shard 1 and each shard that holds a test its change
    touches (edits, or imports a changed webviews file); never the always-run set alone; every shard for a build
    or runner input."""

    setUp = SelectTest.setUp

    def touched(self, *paths: str, delete: bool = False) -> list[str] | None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        for path in paths:
            if delete:
                git(self.root, "rm", "-q", path)
            else:
                (self.root / path).parent.mkdir(parents=True, exist_ok=True)
                with open(self.root / path, "a") as out:
                    out.write("// changed\n")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "change")
        found, _ = ps.touched(wa.Selector(self.root), wa.changed(self.root, "HEAD^1", "HEAD"))
        return None if found is None else sorted(found)

    def test_a_source_touches_the_tests_that_import_it_not_the_always_set(self) -> None:
        self.assertEqual(self.touched("webviews/src/leaf.ts"), ["webviews/test/leaf.test.ts"])
        self.assertEqual(self.touched("webviews/src/hub.ts"), [])  # only through leaf.ts and other.ts
        self.assertEqual(self.touched("webviews/test/other.test.ts"), ["webviews/test/other.test.ts"])

    def test_a_change_outside_webviews_touches_no_test(self) -> None:
        self.assertEqual(self.touched("unrelated/tool.py"), [])
        self.assertEqual(self.touched("schemas/settings/settings-schema.json"), [])

    def test_a_test_helper_or_webviews_script_touches_its_importers(self) -> None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        self.assertTrue(ps.HOP.search("webviews/test/support/papercutChat.ts"))
        self.assertTrue(ps.HOP.search("webviews/scripts/design-tokens-baseline.jsonl"))
        self.assertFalse(ps.HOP.search("webviews/package.json"))
        self.assertFalse(ps.HOP.search("webviews/test/preload.ts"))
        (self.root / "webviews/test/support").mkdir(parents=True, exist_ok=True)
        (self.root / "webviews/test/support/helper.ts").write_text("export const h = 1;\n")
        (self.root / "webviews/test/helped.test.ts").write_text('import { h } from "./support/helper";\n')
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "helper")
        self.assertEqual(self.touched("webviews/test/support/helper.ts"), ["webviews/test/helped.test.ts"])
        self.assertEqual(self.touched("webviews/scripts/baseline.jsonl"), [])
        self.assertIsNone(self.touched("webviews/test/preload.ts"))

    def test_a_script_a_build_input_loads_runs_every_shard_and_a_read_one_its_readers(self) -> None:
        (self.root / "webviews/scripts/lint").mkdir(parents=True, exist_ok=True)
        (self.root / "webviews/scripts/plugin.mjs").write_text('import { d } from "./dep.mjs";\nexport const p = d;\n')
        (self.root / "webviews/scripts/dep.mjs").write_text("export const d = 1;\n")
        (self.root / "webviews/scripts/lint/rule.mjs").write_text("export default {};\n")
        (self.root / "webviews/scripts/table-baseline.tsv").write_text("a\t1\n")
        (self.root / "webviews/scripts/other-baseline.tsv").write_text("b\t2\n")
        (self.root / "webviews/scripts/check-only.mjs").write_text("export {};\n")
        (self.root / "webviews/package.json").write_text('{"scripts": {"check": "bun scripts/check-only.mjs"}}\n')
        (self.root / "webviews/vite.config.ts").write_text(
            'import { p } from "./scripts/plugin.mjs";\n'
            'const rule = new URL("./scripts/lint/rule.mjs", import.meta.url);\nexport default { p, rule };\n')
        (self.root / "webviews/test/table.test.ts").write_text(
            'import { readFileSync } from "node:fs";\nreadFileSync("scripts/table-baseline.tsv");\n'
            'readFileSync(join(dir, "other-baseline.tsv"));\n')
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "scripts")
        self.assertIsNone(self.touched("webviews/scripts/plugin.mjs"))
        self.assertIsNone(self.touched("webviews/scripts/dep.mjs"))  # through the plugin
        self.assertIsNone(self.touched("webviews/scripts/lint/rule.mjs"))  # named, not imported
        # Read as data, or named by a file reader: the reader's tests, not every shard.
        self.assertEqual(self.touched("webviews/scripts/table-baseline.tsv"), ["webviews/test/table.test.ts"])
        self.assertEqual(self.touched("webviews/scripts/other-baseline.tsv"), ["webviews/test/table.test.ts"])
        self.assertEqual(self.touched("webviews/scripts/check-only.mjs"), [])  # only shard 1's checks run it

    def test_build_and_runner_inputs_run_every_shard(self) -> None:
        self.assertIsNone(self.touched("webviews/package.json"))
        self.assertIsNone(self.touched("scripts/ci/run-webviews-tests.sh"))

    def test_a_deleted_source_touches_the_tests_that_still_name_it(self) -> None:
        self.assertEqual(self.touched("webviews/src/leaf.ts", delete=True), ["webviews/test/leaf.test.ts"])
        (self.root / "webviews/src/listed.ts").write_text("export const listed = 1;\n")
        (self.root / "webviews/src/list.json").write_text('{"module": "./src/listed"}\n')
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "fixture names")
        self.assertIsNone(self.touched("webviews/src/listed.ts", delete=True))

    def test_no_touched_test_runs_shard_1_and_all_means_all(self) -> None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        self.touched("unrelated/tool.py")
        self.assertEqual(ps.pick(self.root, "HEAD^1", "HEAD", 12), ([1], "the change touches no webviews test", {1: []}))
        run = subprocess.run([sys.executable, str(ROOT / "scripts/ci/webviews_pr_shards.py"), "--all", "--count", "3"],
                             capture_output=True, text=True, check=True)
        self.assertEqual(run.stdout.strip(), '[{"shard":1,"shard_count":3},{"shard":2,"shard_count":3},{"shard":3,"shard_count":3}]')
        self.touched("webviews/package.json")
        self.assertEqual(ps.pick(self.root, "HEAD^1", "HEAD", 3)[0], [1, 2, 3])

    def test_files_of_lists_the_named_shards_files_webviews_relative(self) -> None:
        """react-apps-base-early replays base reds only among these (RFD 0023 item 3): the picked shards' own split."""
        import webviews_pr_shards as ps  # noqa: PLC0415
        self.touched("webviews/src/leaf.ts")
        split = {1: {"webviews/test/a.test.ts"}, 2: {"webviews/test/leaf.test.ts"}, 3: {"webviews/test/other.test.ts"}}
        seen: list[int] = []
        real = ps.shard_files
        ps.shard_files = lambda repo, shard, count, selected: (seen.append(shard), split[shard])[1]
        try:
            self.assertEqual(ps.files_of(self.root, "HEAD^1", "HEAD", 3, [1, 2]), ["test/a.test.ts", "test/leaf.test.ts"])
        finally:
            ps.shard_files = real
        self.assertEqual(seen, [1, 2])

    def test_a_picked_shard_past_1_owns_only_its_touched_tests(self) -> None:
        """--direct-out: touched tests past shard 1 fold into shard 1's one job (up to FOLD_MAX), not any shard's closure share."""
        import webviews_pr_shards as ps  # noqa: PLC0415
        self.touched("webviews/src/leaf.ts")
        split = {1: set(), 2: {"webviews/test/leaf.test.ts", "webviews/test/a.test.ts"}, 3: {"webviews/test/other.test.ts"},
                 4: set()}
        real = ps.shard_files
        ps.shard_files = lambda repo, shard, count, selected: split[shard]
        try:
            shards, _, own = ps.pick(self.root, "HEAD^1", "HEAD", 4)
            self.assertEqual((shards, own), ([1], {1: ["test/leaf.test.ts"]}))
            # Touched tests in several shards past 1 join shard 1's one job.
            self.touched("webviews/test/other.test.ts", "webviews/test/leaf.test.ts")
            shards, _, own = ps.pick(self.root, "HEAD^1", "HEAD", 4)
            self.assertEqual((shards, own), ([1], {1: ["test/leaf.test.ts", "test/other.test.ts"]}))
            # More than FOLD_MAX keep their own job under the lowest shard.
            ps.FOLD_MAX = 1
            try:
                shards, _, own = ps.pick(self.root, "HEAD^1", "HEAD", 4)
            finally:
                ps.FOLD_MAX = 40
            self.assertEqual((shards, own), ([1, 2], {1: [], 2: ["test/leaf.test.ts", "test/other.test.ts"]}))
        finally:
            ps.shard_files = real
        self.touched("webviews/package.json")
        self.assertEqual(ps.pick(self.root, "HEAD^1", "HEAD", 3)[2], {})  # every shard runs its whole split

    def test_a_ci_web_or_selection_edit_alone_runs_shard_1_and_two_sampled_shards(self) -> None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        real = ps.shard_files
        ps.shard_files = lambda repo, shard, count, selected: {"webviews/test/leaf.test.ts"} if shard == 5 else set()
        try:
            for path in (".github/workflows/ci-web.yml", "scripts/ci/webviews_affected.py",
                         "scripts/ci/focused_tests.py", "scripts/ci/webviews_pr_shards.py"):
                self.touched(path)
                head = git(self.root, "rev-parse", "HEAD").strip()
                shards, why, own = ps.pick(self.root, "HEAD^1", "HEAD", 12)
                sample = ps.sampled_shards(head, 12)
                self.assertEqual(len(sample), 2)
                self.assertTrue(set(sample) <= set(range(2, 13)))
                self.assertEqual((shards, own), ([1, *sample], {1: []}))
                self.assertIn(ps.SAMPLE_WHY, why)
            # A source edit beside it adds its touched tests as one job, unless a sampled shard already runs them.
            self.touched(".github/workflows/ci-web.yml", "webviews/src/leaf.ts")
            sample = ps.sampled_shards(git(self.root, "rev-parse", "HEAD").strip(), 12)
            shards, _, own = ps.pick(self.root, "HEAD^1", "HEAD", 12)
            if 5 in sample:
                self.assertEqual((shards, own), ([1, *sample], {1: []}))
            else:
                self.assertEqual((shards, own), (sorted({1, 5, *sample}), {1: [], 5: ["test/leaf.test.ts"]}))
        finally:
            ps.shard_files = real
        # A build input beside it still runs every shard.
        self.touched(".github/workflows/ci-web.yml", "webviews/package.json")
        self.assertEqual(ps.pick(self.root, "HEAD^1", "HEAD", 12)[0], list(range(1, 13)))

    def test_the_sample_is_fixed_per_head_and_rotates_across_heads(self) -> None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        heads = [f"{n:040x}" for n in range(200)]
        self.assertEqual(ps.sampled_shards(heads[0], 12), ps.sampled_shards(heads[0], 12))
        seen = {shard for h in heads for shard in ps.sampled_shards(h, 12)}
        self.assertEqual(seen, set(range(2, 13)))
        self.assertEqual(ps.sampled_shards(heads[0], 2), [2])

    def test_the_sample_off_switch_and_the_summary(self) -> None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        self.touched(".github/workflows/ci-web.yml")
        summary = self.root / "summary.md"
        script = str(ROOT / "scripts/ci/webviews_pr_shards.py")
        run = subprocess.run([sys.executable, script, "--base", "HEAD^1", "--count", "12", "--repo", str(self.root),
                              "--summary", str(summary)], capture_output=True, text=True, check=True,
                             env=dict(os.environ, CI_WEBVIEWS_PUSH_CLASSES="0"))
        self.assertEqual(len(__import__("json").loads(run.stdout)), 3, run.stderr)
        text = summary.read_text()
        self.assertIn("sampled shards", text)
        self.assertIn("`full-ci` label", text)
        self.assertIn("CI_WEBVIEWS_CI_EDIT_SAMPLE", text)
        old = os.environ.get("CI_WEBVIEWS_CI_EDIT_SAMPLE")
        os.environ["CI_WEBVIEWS_CI_EDIT_SAMPLE"] = "0"
        try:
            self.assertEqual(ps.pick(self.root, "HEAD^1", "HEAD", 12)[0], list(range(1, 13)))
        finally:
            if old is None:
                del os.environ["CI_WEBVIEWS_CI_EDIT_SAMPLE"]
            else:
                os.environ["CI_WEBVIEWS_CI_EDIT_SAMPLE"] = old

    def test_files_of_refuses_shards_outside_the_count(self) -> None:
        run = subprocess.run([sys.executable, str(ROOT / "scripts/ci/webviews_pr_shards.py"), "--base", "HEAD^1",
                              "--count", "3", "--files-of", "4"], capture_output=True, text=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(run.stdout, "")


class PushClassTest(unittest.TestCase):
    """webviews_pr_shards.classify: every pull request push is fast (docs or comments only), sampled (shard 1, the
    touched tests, and two head-sampled shards where the pick would have run every shard) or full (a FULL path).
    Leo, 2026-11-22: "there must surely be some changes which can get the fast track route. like a nexus card." """

    setUp = SelectTest.setUp

    def commit(self, edits: dict[str, str]) -> None:
        for path, text in edits.items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(text)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "change")

    def classify(self, edits: dict[str, str], count: int = 12):
        import webviews_pr_shards as ps  # noqa: PLC0415
        self.commit(edits)
        real = ps.shard_files
        ps.shard_files = lambda repo, shard, n, selected: {"webviews/test/leaf.test.ts"} if shard == 5 else set()
        try:
            return ps.classify(self.root, "HEAD^1", "HEAD", count)
        finally:
            ps.shard_files = real

    def head(self) -> str:
        return git(self.root, "rev-parse", "HEAD").strip()

    def test_comment_only_edits_are_fast(self) -> None:
        cls, shards, why, own = self.classify({"webviews/src/leaf.ts": TREE["webviews/src/leaf.ts"] + "// a note\n"})
        self.assertEqual((cls, shards, own), ("fast", [1], {}))
        self.assertIn("changes only comments", why)
        block = 'import { hub } from "./hub";\n/**\n * Why leaf exists.\n */\nexport const leaf = hub;\n'
        self.assertEqual(self.classify({"webviews/src/leaf.ts": block})[0], "fast")
        self.assertEqual(self.classify({"unrelated/tool.py": "# why\nx = 1\n"})[0], "fast")

    def test_a_tool_directive_or_a_code_line_is_not_a_comment_edit(self) -> None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        leaf = TREE["webviews/src/leaf.ts"]
        for added in ("// @ts-expect-error\n", "/* oxlint-disable */\n", "export const more = 2;\n"):
            self.assertFalse(ps.comment_only("webviews/src/leaf.ts", leaf, leaf + added), added)
        # A `*` continuation line is code, and a `//` inside a string is not a comment.
        self.assertFalse(ps.comment_only("a.ts", "const x = 1\n  * 2;\n", "const x = 1\n  * 3;\n"))
        self.assertFalse(ps.comment_only("a.ts", 'const u = "a // b";\n', 'const u = "a // c";\n'))
        self.assertFalse(ps.comment_only("a.ts", None, "// new file\n"))
        self.assertFalse(ps.comment_only("a.json", "{}\n", "{} \n"))
        self.assertTrue(ps.comment_only("a.yml", "a: 1\n", "# why\na: 1\n"))
        self.assertFalse(ps.comment_only("a.sh", "echo\n", "#!/bin/bash\necho\n"))
        cls, shards, _, _ = self.classify({"webviews/src/leaf.ts": leaf + "// @ts-ignore\n"})
        self.assertEqual((cls, shards), ("sampled", [1]))

    def test_a_doc_is_fast_unless_a_webviews_file_reads_it(self) -> None:
        self.assertEqual(self.classify({"docs/readme.md": "y\n"})[0], "fast")
        self.assertEqual(self.classify({"webviews/src/gallery/sample.md": "y\n"})[0], "sampled")  # imported ?raw
        self.assertEqual(self.classify({"README.md": "y\n"})[0], "sampled")  # named by src/docs.ts

    def test_a_code_edit_is_sampled_with_its_touched_tests(self) -> None:
        cls, shards, _, own = self.classify({"webviews/src/leaf.ts": 'import { hub } from "./hub";\nexport const leaf = hub + 1;\n'})
        self.assertEqual((cls, shards, own), ("sampled", [1], {1: ["test/leaf.test.ts"]}))
        cls, shards, why, _ = self.classify({"unrelated/tool.py": "x = 2\n"})
        self.assertEqual((cls, shards), ("sampled", [1]))
        self.assertIn("touches no webviews test", why)

    def test_an_every_shard_input_outside_full_is_sampled(self) -> None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        for path in (".github/workflows/ci-web.yml", "webviews/vite.config.ts", "scripts/ci/webviews_affected.py"):
            cls, shards, why, _ = self.classify({path: "x = 1\n" if path.endswith(".py") else "const a = 1;\n"})
            sample = ps.sampled_shards(self.head(), 12)
            self.assertEqual(cls, "sampled", path)
            self.assertTrue(set(shards) >= {1, *sample} and len(shards) <= 4, (path, shards))
            self.assertIn(ps.SAMPLE_WHY, why)
        # A comment-only edit of this workflow is fast.
        self.commit({".github/workflows/ci-web.yml": "on: push\n"})
        self.assertEqual(self.classify({".github/workflows/ci-web.yml": "# why\non: push\n"})[0], "fast")

    def test_full_paths_run_every_shard(self) -> None:
        import webviews_pr_shards as ps  # noqa: PLC0415
        for path in ("scripts/ci/run-webviews-tests.sh", "scripts/ci/webviews_test_shards.py",
                     "scripts/ci/webviews_test_results.py", "webviews/bun.lock", "webviews/package.json",
                     "webviews/bunfig.toml", "webviews/test/preload.ts"):
            cls, shards, why, own = self.classify({path: f"changed {path}\n", "docs/readme.md": f"{path}\n"})
            self.assertEqual((cls, shards, own), ("full", list(range(1, 13)), {}), path)
            self.assertIn(path, why)
        self.assertLessEqual(len(ps.FULL), 6)  # the list stays short

    def run_cli(self, *args: str, classes: str = "1") -> tuple[list, str, str]:
        import json  # noqa: PLC0415
        summary, class_out = self.root / "summary.md", self.root / "class.txt"
        for f in (summary, class_out):
            f.unlink(missing_ok=True)
        run = subprocess.run([sys.executable, str(ROOT / "scripts/ci/webviews_pr_shards.py"), "--count", "12",
                              "--repo", str(self.root), "--summary", str(summary), "--class-out", str(class_out),
                              *args], capture_output=True, text=True, check=True,
                             env=dict(os.environ, CI_WEBVIEWS_PUSH_CLASSES=classes))
        return (json.loads(run.stdout), summary.read_text() if summary.exists() else "",
                class_out.read_text().strip() if class_out.exists() else "")

    def test_the_summary_names_the_class_the_rule_and_the_full_run(self) -> None:
        self.commit({"webviews/src/leaf.ts": TREE["webviews/src/leaf.ts"] + "// a note\n"})
        shards, text, cls = self.run_cli("--base", "HEAD^1")
        self.assertEqual((len(shards), cls), (1, "fast"))
        self.assertIn("react-apps-check: fast", text)
        self.assertIn("Rule: webviews/src/leaf.ts changes only comments", text)
        self.assertIn("`full-ci` label", text)
        self.assertIn("CI_WEBVIEWS_PUSH_CLASSES", text)
        shards, text, cls = self.run_cli("--all", "--full-why", "a push run on the base")
        self.assertEqual((len(shards), cls), (12, "full"))
        self.assertIn("Rule: a push run on the base", text)

    def test_the_off_switch_returns_the_pick_before_the_classes(self) -> None:
        self.commit({"webviews/vite.config.ts": "const a = 1;\n"})
        self.assertEqual(len(self.run_cli("--base", "HEAD^1")[0]) < 12, True)
        shards, _, cls = self.run_cli("--base", "HEAD^1", classes="0")
        self.assertEqual((len(shards), cls), (12, ""))


class CiWebWorkflowTest(unittest.TestCase):
    """ci-web.yml parses strictly (no duplicate keys) and wires the push class from the pick to the shards."""

    def test_strict_parse_and_class_wiring(self) -> None:
        try:
            import yaml  # noqa: PLC0415
        except ImportError:
            self.skipTest("PyYAML is not installed")

        class Strict(yaml.SafeLoader):
            pass

        def mapping(loader, node, deep=False):
            keys = [loader.construct_object(k, deep=deep) for k, _ in node.value]
            dupes = {k for k in keys if keys.count(k) > 1}
            if dupes:
                raise yaml.constructor.ConstructorError(None, None, f"duplicate keys {sorted(map(str, dupes))}",
                                                        node.start_mark)
            return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)

        Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
        text = (ROOT / ".github/workflows/ci-web.yml").read_text()
        doc = yaml.load(text, Loader=Strict)  # noqa: S506 - a SafeLoader subclass
        jobs = doc["jobs"]
        self.assertIn("CI_WEBVIEWS_PUSH_CLASSES", doc["env"])
        self.assertEqual(jobs["web-subarea-scope"]["outputs"]["react_class"], "${{ steps.react-shards.outputs.class }}")
        pick = next(s for s in jobs["web-subarea-scope"]["steps"] if s.get("id") == "react-shards")
        self.assertIn("--class-out", pick["run"])
        self.assertIn('echo "class=', pick["run"])
        test = next(s for s in jobs["react-apps-check-shard"]["steps"] if s.get("id") == "webview-tests")
        self.assertEqual(test["env"]["REACT_APPS_CLASS"], "${{ needs.web-subarea-scope.outputs.react_class }}")
        self.assertIn('"$REACT_APPS_CLASS" = fast', test["run"])
        # The base batch's culprit bisect is cmux-next-web.yml's web-bisect (scripts/ci/web_coalesce.py): its
        # report names each culprit commit for the auto-revert, with this run's URL.
        web = yaml.load((ROOT / ".github/workflows/cmux-next-web.yml").read_text(), Loader=Strict)  # noqa: S506
        step = next(s for s in web["jobs"]["web-bisect"]["steps"] if s.get("name") == "Bisect the new webview reds")
        self.assertIn("--run-url", step["run"])
        self.assertNotIn("webviews-culprit-bisect", jobs)

if __name__ == "__main__":
    unittest.main()
