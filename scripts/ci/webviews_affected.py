#!/usr/bin/env python3
"""The webviews test files a pull request's change can affect, for the react-apps-check shards.

    webviews_affected.py --base REF [--head REF] [--repo DIR]

Prints the selected test files (relative to webviews/, one per line) for
CMUX_WEB_TEST_FILES, or nothing when every file must run, and why on stderr. A
feat-cmux-next push runs every file whatever this says (ci-web.yml passes it only on a
pull request), so a base never loses a suite.

The selection is focused_tests.py's webviews import graph with no cap, plus rules that keep
it from missing a test:
  - a changed test file runs itself; a deleted test selects nothing, and a deleted source
    selects the tests reaching any code file that still names it in an import specifier
    (everything when a non-code file names it);
  - a file under webviews/ selects every test that imports it, directly or through other
    modules (a template-literal import counts by its static path, an asset import by its path
    without the query: `./fixture.md?raw`);
  - a file anywhere that a webviews source names (its repo path, its path under webviews/,
    or a basename of 10 characters or more) selects the tests that reach that source; a
    name found in a resolution config (tsconfig, bunfig, package.json outside "scripts")
    selects everything, and one in any other non-code file (a fixture, a baseline) the tests
    that import that file (a file read of it is always-run already);
  - a test always runs when it, or any module it imports, does what no import graph follows:
    reads files (sync or async, a glob, Bun.file), imports a computed path or an alias, starts
    Vite or a browser, or spawns a process. Two reviewed loads that read nothing a test controls
    (RUNTIME_LOADS) are exempt at their pinned content. A prose "import (" inside a line-opening
    doc comment is not a dynamic import;
  - three kinds of browser test leave the always-run set through an edge the graph follows
    (CI_WEBVIEWS_GALLERY_EDGES=0 or CI_WEBVIEWS_NARROW_SELECTION=0 keeps them always-run):
    a gallery stage test (galleryFrame("<id>") on the gallery's Vite config) depends on the
    gallery files that define each entry id it spells; a sweep test (one call of a reviewed
    SWEEP_HELPERS helper with literal options) on every gallery entry file; a Vite page test
    (VITE_PAGES) on its config and every HTML page's module scripts under that root. Each also
    depends on the gallery's frame, config and pane stylesheet (GALLERY_ROOTS), and on the
    gallery zone: any webviews non-code file, any webviews file nothing imports, and the files
    outside webviews/ the gallery server reads (GALLERY_OUTSIDE, the fixture roots) select
    them all. The harness that loads them (GALLERY_HARNESS) and the sweep helpers are pinned
    by sha256; one edit turns the edges off until it is reviewed again. A test that reads,
    spawns, routes, opens another URL or computes an option stays always-run;
  - an input every test loads (EVERY_TEST: webviews/package.json, bun.lock, bunfig, tsconfig,
    the React Compiler config, the preload bunfig loads before every file and what it imports,
    the runner scripts, this file, ci-web.yml) selects everything. A vite config, a webviews
    script or a test helper outside the preload selects the tests that import it, and a file
    under webviews/ nothing imports or names only the always-run set: only Vite, a browser, a
    glob, a file read or a spawn can load those, and every test doing one is always-run.
    CI_WEBVIEWS_NARROW_SELECTION=0 runs everything for them again.
Docs (.md) no test imports and files no webviews source names select nothing.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import focused_tests as ft  # noqa: E402

WEB = "webviews/"
EVERYTHING = re.compile(
    r"^webviews/(package\.json|bun\.lock|bunfig\.toml|tsconfig[^/]*\.json|vite[^/]*\.(ts|mjs|js)|"
    r"reactCompiler\.mjs|scripts/|test/support/|test/setup|test/preload)"
    r"|^scripts/ci/(run-webviews-tests\.sh|webviews-tests-new-reds\.sh|webviews_test_[^/]*\.py|webviews_affected\.py"
    r"|focused_tests\.py)$|^\.github/workflows/ci-web\.yml$|^config/vite-plus/")
# The inputs of EVERYTHING that reach every test file, so select() runs every file for them. The rest of EVERYTHING
# (vite configs, webviews/scripts/, test/support/ outside the preload) reaches only the tests that import it or read
# it, which select() finds like a source's; webviews_pr_shards.py still picks every shard for them (EVERYTHING).
#   - package.json, bun.lock, bunfig.toml: the dependency and toolchain pins every file runs on;
#   - tsconfig*.json: Bun reads its paths and JSX settings for every file it transpiles;
#   - reactCompiler.mjs: the compiler transform the runner warms for the run (not proven narrower);
#   - test/setup*, test/preload* and the preload's imports (Selector.preload): loaded before every file;
#   - the runner, splitter, result parser and selection scripts, ci-web.yml (the jobs that run and pick the tests:
#     on the 158-diff replay all 37 of its edits touched those jobs), config/vite-plus/.
# A vite config feeds only what Vite builds or serves; every test that runs Vite, a browser, a build or reads a
# built bundle is in the always-run set already (UNTRACKED: vite, playwright, a spawn, a file read).
EVERY_TEST = re.compile(
    r"^webviews/(package\.json|bun\.lock|bunfig\.toml|tsconfig[^/]*\.json|reactCompiler\.mjs|test/setup|test/preload)"
    r"|^scripts/ci/(run-webviews-tests\.sh|webviews-tests-new-reds\.sh|webviews_test_[^/]*\.py|webviews_affected\.py"
    r"|focused_tests\.py)$|^\.github/workflows/ci-web\.yml$|^config/vite-plus/")
# The non-code webviews files that steer module resolution or the runner for every file: a name in them may be an
# import target (tsconfig paths, package.json imports/exports/workspaces, bunfig preload). A name in any other
# non-code file (a fixture, a baseline, a changelog dump) is data: only a module that reads files, globs or imports
# a computed path can turn it into a load, and every test reaching such a module is always-run.
RESOLUTION = re.compile(r"^webviews/(package\.json|bunfig\.toml|tsconfig[^/]*\.json)$")
# What a module does that the import graph cannot follow: read files, import a computed path or
# an alias, run Vite or a browser (which load the app themselves), or spawn a process. App code
# under src/ names things like readFile as data, so there it counts only by the import it needs.
JS_GAP = r"(?:\s|/\*[\s\S]*?\*/|//[^\n]*\n)*"
JS_COMMENT = r"(?:/\*[\s\S]*?\*/|//[^\n]*\n)"
UNTRACKED = re.compile(
    rf"(?:\bfrom{JS_GAP}|\bimport{JS_GAP}(?:\({JS_GAP})?|\brequire{JS_GAP}\({JS_GAP})[\"']"
    r"(?:(?:node:)?fs(?:/promises)?|vite|playwright|(?:node:)?child_process)[\"']"
    r"|Bun\.Glob|new Glob|import\.meta\.glob|globSync|Bun\.file\("
    # Look ahead BEFORE consuming spaces: otherwise regex backtracking treats the
    # space in import( './module' ) as a computed expression. An empty import()
    # example in prose is not an expression either.
    # The graph does not parse comments inside imports. Keep those unresolved,
    # including static relative imports, until its parser can follow them.
    r"|\bfrom\s*" + JS_COMMENT + JS_GAP + r"[\"']"
    r"|\bimport\s*" + JS_COMMENT + JS_GAP + r"(?=[({*\"'`])"
    # Plain require("./module") is already an edge. Only grammar the graph
    # cannot read (a gap before the paren, comments, or a computed path) taints it.
    r"|\brequire(?=\s|/)" + JS_GAP + r"\("
    r"|\brequire\((?!\s*[\"'])\s*(?=[\w$({\[/`])"
    r"|import" + JS_GAP + r"\((?!\s*[\"'`])\s*(?=[\w$({\[/])"
    r"|import" + JS_GAP + r"\(" + JS_GAP + r"`[^`]*\$\{"
    r"|(from\s+|import\(\s*)[\"']cmux:|Bun\.spawn")
UNTRACKED_OUTSIDE_SRC = re.compile(r"readFile|readdir|createServer\(|requireBrowserLane|spawnSync|execSync|execFile")
TEMPLATE_IMPORT = re.compile(r"import\(\s*`(\.{1,2}/[^`$?]+)")
# An asset imported with a query (`./fixture.md?raw`, `./clip.webp?url`): an edge to the asset itself.
QUERY_IMPORT = re.compile(r"""(?:from\s+|import\(\s*)["'](\.{1,2}/[^"'?]+)\?[\w&=-]+["']""")
PRELOAD = WEB + "test/preload.ts"
NAME_MIN = 10
# Undo: the repository variable CI_WEBVIEWS_NARROW_SELECTION=0 (ci-web.yml hands it to every job) turns off
# what 2026-11-22 added: RUNTIME_LOADS, a deleted source's namers (deleted_namers) and a read script's readers
# (webviews_pr_shards.read_beyond_imports). Each then runs what it ran before, or more.
NARROW = os.environ.get("CI_WEBVIEWS_NARROW_SELECTION", "1") != "0"
# Reviewed loads the import graph cannot follow that read nothing a test or its change controls. Pinned
# to the reviewed content: any edit puts the file back among the untracked modules, so every test that
# reaches it runs again until it is reviewed again. On 2026-11-22's tree these two made 835 of the 2,101
# always-run tests, and with frameOwners' table consumers 18 of the 42 red files a shard 1 job (137100131913)
# then retried alone.
#   - frameOwners.ts imports the built pane's own chunks/frame-sites.js, beside document.baseURI. Only
#     `bundle.mjs --frame-sites` writes one; a test with no such bundle beside its document gets null. The
#     one test that writes a table (agent-pane-frame-sites.test.ts) reads files, and a browser test that
#     loads a built page uses Playwright: both stay always-run on their own.
#   - domTeardown.ts requires the npm package `scheduler` from react-dom's folder: bun.lock, a build input,
#     decides what it loads. It is in the preload's imports too, so its own edit runs everything.
RUNTIME_LOADS = {
    WEB + "src/agent-session/acpmux/frameOwners.ts":
        "99c31528e5b7e676cb9aee8e069cd77f8cee5feb8af52119801287a48cd6c37e",
    WEB + "test/support/domTeardown.ts":
        "bc39e128441ba75445140da45a75078d5f2659612ca1be66c36cb6730e9b1ec5",
}
# An import specifier that ends in a module's name, with or without its extension or a query.
SPECIFIER = r"""["'`][^"'`\n]*/{}(?:\.[\w.]+)?(?:\?[^"'`\n]*)?["'`]"""

# Gallery stage tests: a browser test that serves the gallery with vite.config.gallery-dev.ts and opens only
# `galleryFrame(id)` stages. galleryFrame puts the file defining `id` in the URL (`entryPath`), and the frame then
# loads that file alone (src/gallery/registry.ts), so what the page runs is the import closure of the frame, the
# Vite config and that entry file: real edges, not "always". Such a test leaves the always-run set; it runs for a
# change in any of those closures, a webviews file outside every test's import graph (a stylesheet's @import, a
# fixture, a script the harness spawns), or a file outside webviews/ the harness reads (GALLERY_OUTSIDE).
# Off with CI_WEBVIEWS_GALLERY_EDGES=0 (or CI_WEBVIEWS_NARROW_SELECTION=0): they are always-run again.
GALLERY_EDGES = NARROW and os.environ.get("CI_WEBVIEWS_GALLERY_EDGES", "1") != "0"
GALLERY_CONFIG = WEB + "vite.config.gallery-dev.ts"
# What every stage loads besides its entry: the Vite config (and its plugins), the frame's script (frame.html's
# only module) and the pane stylesheet galleryHost builds by running bundle.mjs over the pane's dev entry.
GALLERY_ROOTS = (GALLERY_CONFIG, WEB + "src/gallery/frame/main.ts", WEB + "scripts/agent-pane/bundle.mjs",
                 WEB + "src/agent-session/acpmux/dev.tsx")
# Files outside webviews/ the gallery server reads (galleryHost.ts, goldenLooks.ts, firstPartyPreviews.ts, plugins'
# fs.allow): themes, the Swift design tunables and web theme, the pane build script, the fixture index and the
# schemas it serves, first-party previews, example looks. The fixture index's roots are added at run time.
GALLERY_OUTSIDE = re.compile(r"^(Resources/|Packages/macOS/CmuxNext/Sources/CmuxNextDesign/|schemas/|examples/looks/"
                             r"|first-party-apps/[^/]+/preview/|scripts/cmux-next/build-agent-pane-web\.sh$)")
# The reviewed harness: every module in GALLERY_ROOTS' closures, galleryFrame.ts's and requireBrowserLane.ts's that
# reads files, spawns or imports what no graph follows. Their reads are the zone above (webviews/ non-graph files,
# GALLERY_OUTSIDE, the gallery files themselves), or home-folder and dev-only routes the gallery config leaves out.
# Pinned like RUNTIME_LOADS: an edit to one puts every gallery stage test back in the always-run set (the edit
# selects them all anyway) until the pin is renewed (a reviewer recomputes its sha256).
GALLERY_HARNESS = {
    "webviews/dev-server/agentGitHost.ts": "33a6bae12270443476a0a86432534b9593801edc59c3913131906acba020a449",
    "webviews/dev-server/diffHost.ts": "04fa1052aa2bb63296dbc89e82a31c2bd3590f04238be054a3b64f8c75a94bca",
    "webviews/dev-server/diffLanguages.ts": "6c6dd22dc1f9005954b4a43a5bfce3e44f9b480f01bcf35477ab3525496fc6ec",
    "webviews/dev-server/editorHost.ts": "775ebfb6949361f9783d5b9a66c2bc6ca3c3951a448cfb7e087cbe15cf1c1e39",
    "webviews/dev-server/firstPartyPreviews.ts": "a03b66effef3f17a9a6266ceaf7f447fe08c5e3d99366c0ff34d3cd8dd8b60f5",
    "webviews/dev-server/galleryHost.ts": "76c2f1a4d2628a31c29490ba256f20ac457f10e460f59c5d881092f0edad9778",
    "webviews/dev-server/galleryLive.ts": "416f427f016a38ed2a58a7d05cea0dc4496d9a21d749912dfa7f7bdea45748cd",
    "webviews/dev-server/goldenLooks.ts": "042104cbaebef90fc8578375b604ff9d18996176be7b64d8525963007f115aa6",
    "webviews/dev-server/markdownHost.ts": "0f089dd4131797750e5f12d6e7db4a82361c9c6403eff6afc43a88135c58f9e1",
    "webviews/dev-server/perfLint.ts": "8fb5e8907322ad2a74bb06a02805df730b295fc8a5f1969823e82a80118a2230",
    "webviews/dev-server/plugins.ts": "bdb2657673982829b79b8ff73be9f2552fec1fb0e6dd971256c5b903e8ab562c",
    "webviews/dev-server/viewerEmptyHost.ts": "00d07085fc72ae42a23409117789a397b23e18fd51fa7884dc7c520f07b5a772",
    "webviews/reactCompiler.mjs": "cf69080f14637c1d71ef8defe0b2373072c85ac554eb0e766f628783a396f38d",
    "webviews/scripts/agent-pane/artifactRuntimePlugin.mjs": "3d0b42f53ce581e23083ffeacbdfcce6850563096dacf272e029265abc5e6302",
    "webviews/scripts/agent-pane/frameSites.mjs": "c9bf51c01da0196c88d0044e5ae06f82eece1a17ba911d3e259ca0479ce4e913",
    "webviews/scripts/agent-pane/jsonParsePlugin.mjs": "42cfa8b6f0fb61a98a49ccbb3644c20e7ca7fc75964578d19a0033ade435086e",
    "webviews/scripts/agent-pane/katexStylePlugin.mjs": "ac55c5b747f9baa4db25e2a23d4407d336c390499f7f93bdff7c2e453540f9c2",
    "webviews/scripts/agent-pane/reactCompilerPlugin.mjs": "a293c15161984bf6d32a14b865b9859ce46a85fac68c5f20ee93763af21a508d",
    "webviews/scripts/agent-pane/tailwindCompile.mjs": "6a78ccc7e85c6c923c353687765af998adafc94dd5482b0d5b32e8f1c9342d08",
    "webviews/scripts/pages/gen-design-scale.mjs": "de97c6b6ac0deea3933079cb7ef1e6ac601ea24cb11f28f187bab4c47c3bb2ee",
    "webviews/scripts/bundle-metafile.mjs": "831962bec2e77c7b0fd92c3a058e4513d3c995b0e6d82981ce8c52389cda4840",
    "webviews/scripts/gallery/entries.ts": "43ae4eb980d25a0745ebc95a70c23a99a51dc464a8c910c8ca350f7ff7be58ea",
    "webviews/scripts/packed-shiki-data.mjs": "334a89d6ac88c7f2b7704aa80687ff946329d408b029042ba61278932d41e88b",
    "webviews/src/diff-viewer/importHunks.ts": "734e4b333f6d11f9c6cfbe52b890712ddb5a8527aa763fbe01d13a72066cee44",
    "webviews/src/gallery/entryStore.ts": "c04482199aa91b40359f5b88c25d4c1e7e23cfecc26e8c1530aade0ff8777842",
    "webviews/src/gallery/frame/liveErrors.ts": "f553033653f2ca9e6a7a1277e9351452001f70bc55a91861d8c1bc16ea50b5bc",
    "webviews/src/gallery/registry.ts": "26564ec915a72c5f3eb1d00766c1c6d42354ae922bb0ee1b73ccb535e4744ff4",
    "webviews/src/pages/editor/main.tsx": "fcf6a290b299f6c48b38fcedfbcc551c5c0186362ea671df603ab9b40d8982f3",
    "webviews/src/pages/editor/view.ts": "6c142785fe0b2f042a1739163e636962cdc6846700f06b56b15f5785ca8556f9",
    "webviews/test/support/galleryFrame.ts": "1f9eb44639c07f42cd34050c8a02454537c52be5152f778904f8a9ed7d0ab3c0",
    "webviews/test/support/requireBrowserLane.ts": "150ec45c9b3aeb1e9781442bbfc85f44ec5ff65e06babe0c429da4efe94a3890",
    "webviews/test/support/systemChrome.ts": "0507f6cb924086aa87d15a541c3bec4387e0ecddf70544e6d2505e3d56b9961b",
    "webviews/vite.config.acpmux-pane.mjs": "b693a61ac81f7bdd2a2fd23c7852d1fab11cfaf18fcee75f9a7eae21b0f345c3",
    "webviews/vite.config.settings-page.mjs": "2f522df32899cae1068eef1085ad3309fdeebf08cf9b38d35875c67d74f8b077",
    "webviews/scripts/agent-pane/paneLocales.mjs": "9cc8c34c48d1da374160cf266a19134cd32f67c593e0a803753fa6d356202093",
    "webviews/scripts/pages/split-strings.mjs": "58c8e95e8abcc440e30a36fdb4ab44da20cc203a4c7f5f2a6dd20b063930de5b",
    # GALLERY_ROOTS' closure modules the graph cannot follow: bundle.mjs reads only its own outputs (outfile and
    # its chunks/); frameOwners.ts's dynamic import is chunks/frame-sites.js beside the document (none in the gallery);
    # customizeLooks.ts's import.meta.glob reads examples/looks/*/cmux-setup.json (GALLERY_OUTSIDE).
    "webviews/scripts/agent-pane/bundle.mjs": "87c755f96e7e58d80ee81bfe5a047b26f2b3de221f7e7795cc2497fc9e506f6a",
    "webviews/src/agent-session/acpmux/frameOwners.ts": "99c31528e5b7e676cb9aee8e069cd77f8cee5feb8af52119801287a48cd6c37e",
    "webviews/src/pages/settings/customizeLooks.ts": "a363b52647f381cb53ced55783fddd32e0e82716bdcdaaae2f0926efaeed2cfa",
}
# galleryFrame.ts's own test for the file that defines an entry id (galleryEntryPath).
GALLERY_ID_LINE = re.compile(r'^\s*id:\s*"([^"\n]+)",?\s*$', re.M)
GALLERY_FILE = re.compile(r"\.gallery\.tsx?$")
# What a stage test's own text may do beyond the import graph: launch a browser, start the gallery's Vite server,
# write (never read) files. Anything else (a read, a spawn, another page, a script or file handed to the page)
# keeps it always-run.
STAGE_FS_IMPORT = re.compile(r"""\bimport\s*(\{[^}]*\})?\s*(?:from\s*)?["'](?:node:)?fs(?:/promises)?["']""")
STAGE_FS_WRITES = {"writeFile", "writeFileSync", "mkdir", "mkdirSync", "mkdtemp", "mkdtempSync", "rm", "rmSync"}
_STAGE_REFUSED = (
    r"\b(?:addScriptTag|addStyleTag|addInitScript)\(\s*\{[^}]*\bpath\s*:|\.route\(|\brouteFromHAR\b|\bsetInputFiles\b"
    # A page or module URL no edge covers: a file URL, a source path, a Vite internal.
    r"|file:/|[\"'`/]src/|/@(?:fs|id|vite)/"
    r"|readFile|readdir|existsSync|statSync|Bun\.file|\bspawn|(?<![.\w])exec(?:Sync|File)?\("
    # An entry id built at run time: `agent-pane.${x}` or "agent-pane." + x.
    r"|[\"'`][a-z0-9-]+\.(?:\$\{|[\"']\s*\+)")
# A Vite page test may open any page its server has (all are edges); a gallery stage test only galleryFrame() stages,
# so it also may not name an HTML page or build a bare server root URL (the shell: every gallery file).
PAGE_REFUSED = re.compile(_STAGE_REFUSED)
STAGE_REFUSED = re.compile(r"\.html\b|(?:127\.0\.0\.1|localhost):\$\{[\w.()!]+\}/?[\"'`](?!\s*\+\s*galleryFrame\()|"
                           + _STAGE_REFUSED)
# Vite page tests: a browser test that starts Vite with one of these reviewed configs and drives its pages. The
# edge is the config's closure plus every HTML page under the config's root and its module scripts' closures: an
# over-approximation of what the test opens. (vite.config.ts serves every page under webviews/,
# among them modules that glob fixtures: not here yet.)
VITE_PAGES = {
    WEB + "vite.config.acpmux-pane.mjs": WEB + "src/agent-session/acpmux",
    WEB + "vite.config.settings-page.mjs": WEB + "src/pages/settings",
}
HTML_SCRIPT = re.compile(r"""<script\b([^>]*)>([\s\S]*?)</script>""", re.I)
# Static imports: the graph's edges, so their specifiers (a ../src/ path) are no page URL.
# Sweep helpers: each opens every gallery entry (split into parts at run time), so a test that only calls one with
# literal options depends on every entry file, the gallery harness and the files the helper reads: baselines under
# webviews/, in the gallery zone. Reviewed and pinned like the harness.
SWEEP_HELPERS = {
    WEB + "test/support/controlContrastScan.ts": "7c5586b29d354347f14f0ae35b4d28d4d3b0b53362121b087453ddac53ecce79",
    WEB + "test/support/accentGlassScan.ts": "7dfafa128407921195974f42bee32a240e5e168ef1ae289fd575114c2e8cdfa5",
    WEB + "test/support/stageBrowser.ts": "6cb7b5ec94e3360ba6412da77989118ac64efbd27703caa39acbb5b0b0842a9b",
}
# A sweep test's text without comments and static imports: one call with literal options, nothing else.
_SWEEP_CALL = r"""[\w$]+\(\s*\{\s*(?:[\w$]+\s*:\s*(?:"[^"\\\n]*"|\d+)\s*,?\s*)*\}\s*\)"""
SWEEP_TEXT = re.compile(rf"""\s*await\s+(?:{_SWEEP_CALL}|requireBrowserLane\(\s*"[^"\\\n]*"\s*,\s*\(\)\s*=>\s*{_SWEEP_CALL}\s*\))\s*;?\s*""")

STATIC_IMPORT = re.compile(r"""^\s*(?:import|export)\b[^;]*?\bfrom\s*["'][^"']+["'];?|^\s*import\s*["'][^"']+["'];?""", re.M)
STAGE_ALLOWED = re.compile(r"playwright|[\"']vite[\"']|requireBrowserLane|createServer\(|(?:node:)?fs(?:/promises)?[\"']")
STRING_LITERAL = re.compile(r"""["']([a-z0-9][a-z0-9.-]*)["']""")
JS_COMMENTS = re.compile(r"/\*[\s\S]*?\*/|(?<![:\"'`\\])//[^\n]*")


class Selector:
    def __init__(self, root: Path):
        self.root = root
        self.graph = ft.WebTests(root)
        self.text = {f: (root / f).read_text(encoding="utf-8", errors="replace") for f in self.graph.known
                     if f.endswith(ft.EXTENSIONS) or f.endswith(".json")}
        for source, text in self.text.items():
            for spec in TEMPLATE_IMPORT.findall(text) + QUERY_IMPORT.findall(text):
                target = self.graph.resolve(source, spec)
                if target:
                    self.graph.importers.setdefault(target, set()).add(source)
        self.imports: dict[str, set[str]] = {}
        for target, importers in self.graph.importers.items():
            for source in importers:
                self.imports.setdefault(source, set()).add(target)
        untracked = {f for f, text in self.text.items() if outside_doc(UNTRACKED, text)
                     or (not f.startswith(WEB + "src/") or f in self.graph.tests) and UNTRACKED_OUTSIDE_SRC.search(text)}
        reviewed = {f for f, digest in RUNTIME_LOADS.items() if NARROW and f in self.text
                    and hashlib.sha256((root / f).read_bytes()).hexdigest() == digest}
        self.always = {t for t in self.graph.tests if self.closure(t) & (untracked - reviewed)}
        self.preload = self.closure(PRELOAD)
        self.gallery: dict[str, set[str]] = self.gallery_stages(untracked - reviewed) if GALLERY_EDGES else {}
        self.always -= set(self.gallery)
        for test, entries in self.gallery.items():
            for target in (*GALLERY_ROOTS, *entries):
                self.imports.setdefault(test, set()).add(target)
                self.graph.importers.setdefault(target, set()).add(test)
        self.css_texts: dict[str, str] | None = None
        self.gallery_outside = [root.rstrip("/") + "/" for root in self.fixture_roots()]

    def pinned(self, pins: dict[str, str]) -> bool:
        return all(f in self.text and hashlib.sha256((self.root / f).read_bytes()).hexdigest() == digest
                   for f, digest in pins.items())

    def fixture_roots(self) -> list[str]:
        try:
            roots = json.loads((self.root / "schemas/gallery/fixtures.json").read_text(encoding="utf-8")).get("roots")
        except (OSError, ValueError, AttributeError):
            return [""]  # unreadable: every path outside webviews/ is in the zone
        return [r for r in roots if isinstance(r, str)] if isinstance(roots, list) else [""]

    def gallery_stages(self, untracked: set[str]) -> dict[str, set[str]]:
        """The always-run tests proven to be gallery stage tests, each with the entry files it opens."""
        if not self.pinned(GALLERY_HARNESS):
            return {}
        harness = set(GALLERY_HARNESS)
        base = set().union(*(self.closure(r) for r in GALLERY_ROOTS))
        if (base & untracked) - harness:
            return {}
        # Entry id to the gallery files with galleryEntryPath's `id: "<id>"` line (more than one: it throws).
        ids: dict[str, set[str]] = {}
        for f, text in self.text.items():
            if f.startswith(WEB + "src/") and GALLERY_FILE.search(f):
                for entry in GALLERY_ID_LINE.findall(text):
                    ids.setdefault(entry, set()).add(f)
        out: dict[str, set[str]] = {}
        pages: dict[str, set[str] | None] = {}
        sweep: set[str] | None = None
        for test in sorted(self.always):
            helpers = (self.closure(test) & untracked) - harness - {test}
            if any(f.startswith(WEB + "src/") for f in helpers):
                continue
            if helpers and helpers <= set(SWEEP_HELPERS):
                if sweep is None:
                    sweep = self.sweep_edges(ids, untracked - harness - set(SWEEP_HELPERS))
                body = STATIC_IMPORT.sub("", JS_COMMENTS.sub("", self.text[test]))
                configs = set(re.findall(r"vite\.config[\w.-]*", body))
                if sweep and SWEEP_TEXT.fullmatch(body) and configs <= {GALLERY_CONFIG.removeprefix(WEB)}:
                    out[test] = sweep
                continue
            text = self.stage_text(test)
            if text is None or "galleryFrame(" not in text:
                named = set(re.findall(r"vite\.config[\w.-]*", JS_COMMENTS.sub("", self.text[test])))
                config = WEB + next(iter(named)) if len(named) == 1 else ""
                if config not in VITE_PAGES or "createServer(" not in self.text[test]:
                    continue
                if self.stage_text(test, config) is None or any(self.stage_text(f, config) is None for f in helpers):
                    continue
                if config not in pages:
                    pages[config] = self.page_edges(config, untracked - harness)
                if pages[config] is not None:
                    out[test] = pages[config]
                continue
            if any(self.stage_text(f) is None for f in helpers):
                continue
            # Every entry id the test or its own helpers (outside src/) spell: an over-approximation of what it opens.
            literals = set(STRING_LITERAL.findall(text))
            for f in self.closure(test) - {test} - harness - base:
                if not f.startswith(WEB + "src/") and f in self.text:
                    literals |= set(STRING_LITERAL.findall(JS_COMMENTS.sub("", self.text[f])))
            found = [ids[lit] for lit in literals if lit in ids]
            if not found or any(len(files) > 1 for files in found):
                continue
            entries = set().union(*found)
            reach = set().union(*(self.closure(e) for e in entries))
            if not (reach & untracked) - harness:
                out[test] = entries
        return out

    def sweep_edges(self, ids: dict[str, set[str]], untracked: set[str]) -> set[str]:
        """Every gallery entry file and the sweep helpers, or nothing when the helpers' pins or an entry's reach fail."""
        if not self.pinned(SWEEP_HELPERS):
            return set()
        entries = set().union(*ids.values())
        if any(self.closure(e) & untracked for e in entries):
            return set()
        return entries | set(SWEEP_HELPERS)

    def page_edges(self, config: str, untracked: set[str]) -> set[str] | None:
        """The config and every HTML page's module scripts under its root, or None when one cannot be followed."""
        root = VITE_PAGES[config]
        out = {config}
        for page in sorted(f for f in self.graph.known if f.endswith(".html") and f.startswith(root + "/")
                           and "/node_modules/" not in f):
            html = (self.root / page).read_text(encoding="utf-8", errors="replace")
            for attrs, body in HTML_SCRIPT.findall(html):
                src = re.search(r"""\bsrc\s*=\s*["']([^"']+)["']""", attrs)
                if not src:
                    if "type" in attrs and "module" in attrs and re.search(r"\bimport\b", body):
                        return None  # an inline module's imports: not followed
                    continue
                spec = src.group(1).split("?")[0]
                if re.match(r"\w+:|//", spec):
                    continue  # another origin: not a file
                target = (os.path.normpath(root + spec) if spec.startswith("/")
                          else os.path.normpath(os.path.join(os.path.dirname(page), spec)))
                if target not in self.graph.known:
                    return None
                out.add(target)
        reach = set().union(*(self.closure(f) for f in out))
        return None if reach & untracked else out

    def stage_text(self, f: str, config: str = GALLERY_CONFIG) -> str | None:
        """A stage test's or its helper's text without comments and static imports, or None when it does what no
        edge covers: reads files, spawns, imports a computed path, serves another Vite config or opens a page other
        than a gallery stage. Launching a browser, starting the gallery's Vite server and writing files are fine."""
        text = STATIC_IMPORT.sub("", JS_COMMENTS.sub("", self.text[f]))
        gallery = config == GALLERY_CONFIG
        if (STAGE_REFUSED if gallery else PAGE_REFUSED).search(text):
            return None
        if gallery and any(not self.frame_url(arg, text) for arg in call_args(text, "goto")):
            return None
        if "createServer" in text and set(re.findall(r"vite\.config[\w.-]*", text)) != {config.removeprefix(WEB)}:
            return None
        raw = JS_COMMENTS.sub("", self.text[f])
        for m in STAGE_FS_IMPORT.finditer(raw):
            names = {n.split(" as ")[0].strip() for n in (m.group(1) or "").strip("{}").split(",") if n.strip()}
            if not m.group(1) or not names <= STAGE_FS_WRITES:
                return None
        for m in [*UNTRACKED.finditer(raw), *UNTRACKED_OUTSIDE_SRC.finditer(raw)]:
            if not STAGE_ALLOWED.search(m.group(0)) and not re.fullmatch(r"import\s*\(\s*", m.group(0)):
                return None
        if re.search(r"\bimport\s*\(\s*(?![\"']vite[\"'])", text):
            return None  # a dynamic import other than Vite's own
        return text

    @staticmethod
    def frame_url(arg: str, text: str) -> bool:
        """Whether a page.goto argument opens a gallery stage: a galleryFrame() URL, a name holding one, or a call
        of a function the test defines around galleryFrame(). STAGE_REFUSED has already turned away every other
        way the test could spell a URL."""
        arg = arg.strip()
        if "galleryFrame(" in arg or arg.startswith(('"about:blank"', "'about:blank'")):
            return True
        if re.fullmatch(r"[\w$.]+(\s*,[\s\S]*)?", arg):
            return True
        call = re.match(r"([\w$]+)\(", arg)
        if not call:
            return False
        name = re.escape(call.group(1))
        definition = re.search(rf"(?:function\s+{name}\s*\(|\b{name}\s*=\s*(?:async\s*)?\()", text)
        return bool(definition) and "galleryFrame(" in text[definition.end():definition.end() + 600]

    def in_gallery_zone(self, f: str) -> bool:
        """Whether a changed path can reach a gallery stage other than through the import graph."""
        if not self.gallery:
            return False
        if f.startswith(WEB):
            if f.endswith(".css") and self.css_imported(f):
                return False  # only its importers load it: the graph's edge, as for any test
            return not f.endswith(ft.EXTENSIONS) or not f.startswith(WEB + "src/") and not self.reaching(f)
        return bool(GALLERY_OUTSIDE.search(f)) or any(f.startswith(r) for r in self.gallery_outside)

    def css_imported(self, f: str) -> bool:
        """Whether a stylesheet reaches a page only through the modules that import it: a module imports it and no
        other webviews stylesheet or HTML page names it (an @import, a <link>)."""
        if not self.graph.importers.get(f):
            return False
        if self.css_texts is None:
            self.css_texts = {g: (self.root / g).read_text(encoding="utf-8", errors="replace")
                              for g in self.graph.known if g.endswith((".css", ".html")) and "/node_modules/" not in g}
        name = Path(f).name
        return not any(name in text for g, text in self.css_texts.items() if g != f)

    def closure(self, path: str) -> set[str]:
        """`path` and every module it imports, transitively."""
        seen, frontier = {path}, [path]
        while frontier:
            frontier = [i for f in frontier for i in self.imports.get(f, ()) if i not in seen]
            seen.update(frontier)
        return seen

    def reaching(self, path: str) -> set[str]:
        return {t for _, t in self.graph.for_file(path)}

    def named_by(self, path: str) -> set[str] | None:
        name = Path(path).name
        keys = [path, path.removeprefix(WEB)] + ([name] if len(name) >= NAME_MIN else [])
        out: set[str] = set()
        for source, text in self.text.items():
            if source == path or not any(k in text for k in keys):
                continue
            if not source.endswith(ft.EXTENSIONS) and self.resolves(source, text, keys):
                return None
            out |= self.reaching(source)
        return out

    @staticmethod
    def resolves(source: str, text: str, keys: list[str]) -> bool:
        """Whether a non-code file naming one of KEYS may resolve it as a module (RESOLUTION; package.json outside
        its "scripts", which only shell commands run: a test running one spawns a process and is always-run)."""
        if not NARROW:
            return True
        if not RESOLUTION.search(source):
            return False
        if source.endswith("package.json"):
            try:
                data = json.loads(text)
            except ValueError:
                return True
            if isinstance(data, dict):
                data.pop("scripts", None)
            text = json.dumps(data)
        return any(k in text for k in keys)

    def deleted_reach(self, path: str) -> set[str] | None:
        """The tests a deleted source can still affect, or None when only every file is safe."""
        namers = self.deleted_namers(path)
        return None if namers is None else set().union(set(), *(self.reaching(f) for f in namers))

    def deleted_namers(self, path: str) -> set[str] | None:
        """The code files that still name a deleted source in an import, or None when only every file is safe.

        A module that imported it and still does is broken (the type check in shard 1 fails on it), and one
        whose import the change edited is itself in the diff: either way some file still names it in an
        import. So the tests reaching any code file whose text holds an import specifier ending in its name
        (its folder's name for an index file), the same as a name found in source. A glob, a computed import
        or a file read loads it unnamed: those tests are already always-run. A non-code file naming it, or a
        name under 4 characters, runs everything.
        """
        p = Path(path)
        name = p.parent.name if p.stem == "index" else p.stem
        if not NARROW or len(name) < 4:
            return None
        pattern = re.compile(SPECIFIER.format(re.escape(name)))
        out: set[str] = set()
        for source, text in self.text.items():
            if pattern.search(text):
                if not source.endswith(ft.EXTENSIONS):
                    return None
                out.add(source)
        return out

    def select(self, files: list[str]) -> tuple[set[str] | None, str]:
        """(test files under the repo root, or None for every file; the reason for None)."""
        out: set[str] = set()
        for f in files:
            if (EVERY_TEST if NARROW else EVERYTHING).search(f) or f in self.preload:
                return None, f"{f} is a build or runner input"
            if self.in_gallery_zone(f):
                out |= set(self.gallery)
            if f.startswith(WEB):
                if f in self.graph.tests:
                    out.add(f)
                    continue
                if not (self.root / f).exists() and ft.WEB_TEST.search(f):
                    continue
                if not (self.root / f).exists() and f.endswith(ft.EXTENSIONS):
                    hit = self.deleted_reach(f)
                    if hit is None:
                        return None, f"{f} was deleted, and a non-code file or a short name may load it"
                    out |= hit
                    continue
                hit = self.reaching(f)
                if hit:
                    out |= hit
                    continue
                if f.endswith(ft.EXTENSIONS) and f.startswith(WEB + "src/") or f in self.graph.importers:
                    continue  # source, or an asset a module imports, that no test reaches
            if f.endswith(".md"):
                continue  # a doc no test imports; a name in prose (README.md, AGENTS.md) is no read
            named = self.named_by(f)
            if named is None:
                return None, f"{f} is named by a webviews resolution config ({RESOLUTION.pattern})"
            if f.startswith(WEB) and not named and not f.endswith(ft.EXTENSIONS) and not NARROW:
                # A webviews file nothing imports or names loads only through Vite or a page (a browser), a glob, a
                # directory read or a spawn: every test doing those is always-run (UNTRACKED).
                return None, f"no rule maps {f}"
            out |= named
        return out | self.always, ""


# A doc or line comment that opens a line: prose such as "the last import (ImportStepModel)" or "inflated on import
# (CMUX-570)" is not a dynamic import. A match that starts inside one is skipped; one that starts in code
# (`from /* note */ "x"`) still counts.
DOC_COMMENT = re.compile(r"^[ \t]*/\*\*[\s\S]*?\*/", re.M)
LINE_COMMENT = re.compile(r"^[ \t]*//[^\n]*", re.M)


def outside_doc(pattern: re.Pattern[str], text: str) -> bool:
    """Whether pattern matches text somewhere other than inside a line-opening doc or line comment (always, unless
    narrow)."""
    if not NARROW:
        return bool(pattern.search(text))
    docs = [m.span() for m in DOC_COMMENT.finditer(text)] if "/**" in text else []
    docs += [m.span() for m in LINE_COMMENT.finditer(text)] if "//" in text else []
    return any(not any(a <= m.start() < b for a, b in docs) for m in pattern.finditer(text))


def call_args(text: str, name: str) -> list[str]:
    """The argument text of every `name(...)` call (balanced parentheses)."""
    out = []
    for m in re.finditer(rf"\b{name}\(", text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[i], 0)
            i += 1
        out.append(text[m.end():i - 1])
    return out


def changed(root: Path, base: str, head: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "diff", "--no-renames", "--name-only", base, head],
                         capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True)
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    args = ap.parse_args(argv)
    try:
        files = changed(args.repo, args.base, args.head)
    except subprocess.CalledProcessError as err:
        print(f"webviews affected: cannot diff {args.base}..{args.head} ({err.stderr.strip()}); every file runs",
              file=sys.stderr)
        return 0
    selector = Selector(args.repo)
    selected, why = selector.select(files)
    if not selected:
        print(f"webviews affected: every file runs: {why}", file=sys.stderr)
        return 0
    print(f"webviews affected: {len(selected)} of {len(selector.graph.tests)} test files for {len(files)} changed paths", file=sys.stderr)
    for f in sorted(selected):
        print(f.removeprefix(WEB))
    return 0


if __name__ == "__main__":
    sys.exit(main())
