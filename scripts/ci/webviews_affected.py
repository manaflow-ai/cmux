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
    name found in a non-code file (a fixture, a config) selects everything;
  - a test always runs when it, or any module it imports, does what no import graph follows:
    reads files (sync or async, a glob, Bun.file), imports a computed path or an alias, starts
    Vite or a browser, or spawns a process. Two reviewed loads that read nothing a test controls
    (RUNTIME_LOADS) are exempt at their pinned content;
  - a build or runner input (webviews/package.json, bun.lock, bunfig, tsconfig, vite configs,
    webviews/scripts/, the test support dir, the preload bunfig loads before every file and
    what it imports, the runner scripts, this file, ci-web.yml) selects everything, as does
    any other file under webviews/ no rule maps.
Docs (.md) no test imports and files no webviews source names select nothing.
"""
from __future__ import annotations

import argparse
import hashlib
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
# Undo: the repository variable CI_WEBVIEWS_PAGE_CLOSURE=0 (ci-web.yml hands it to every job) puts every browser
# test back among the always-run files (PageMap below).
PAGE_CLOSURE = os.environ.get("CI_WEBVIEWS_PAGE_CLOSURE", "1") != "0"
# Browser test helpers whose only loads the graph cannot follow are the browser itself, Vite on a config the test (or
# the helper) names, and the gallery's entry lookup (galleryFrame.ts reads the *.gallery files for the one that defines
# an id; entries.ts is that list). Each is under test/support/ or dev-server/, so its own edit runs every file
# (test/support/ is a build input; dev-server/ is in every config's closure, below).
BROWSER_HELPERS = frozenset(WEB + f for f in (
    "test/support/systemChrome.ts", "test/support/requireBrowserLane.ts", "test/support/warmDevServer.ts",
    "test/support/galleryFrame.ts", "test/support/paintedFrames.ts", "test/support/papercutChat.ts",
    "test/support/liveTurnRuns.ts", "test/support/focusByKey.ts", "test/support/pinArms.ts",
    "test/support/frames120.ts", "test/support/transcriptDragStays.ts", "test/support/compactModelMenu.ts",
    "test/support/openRunningTray.ts", "scripts/gallery/entries.ts", "dev-server/goldenLooks.ts",
    "dev-server/galleryHost.ts"))
# What a browser test may do itself that the graph cannot follow: import Playwright or Vite, start Vite, take the
# browser lane. Anything else (a file read, a spawn, a glob, a computed import) leaves it always-run.
BROWSER_OWN = re.compile(
    r"""(?:\bfrom\s*|\bimport\s*\(\s*)["'](?:playwright|vite)["']|\bcreateServer\(|\brequireBrowserLane\b""")
# A test that walks every gallery entry, or builds a stage URL by hand, opens what no literal names.
WHOLE_GALLERY = re.compile(r"loadEntrySources|galleryFiles\(|frame\.html|entryPath|import\.meta\.glob|/live\b")
VITE_CONFIG = re.compile(r"\bvite\.config[\w.-]*\.(?:ts|mjs)\b")
HTML_PAGE = re.compile(r"[\w./-]*[\w-]+\.html\b")
GALLERY_ID = re.compile(r"""^\s*id:\s*"([^"\n]+)",?\s*$""", re.M)
LITERAL = re.compile(r""""([^"\\\n]{2,})"|'([^'\\\n]{2,})'|`([^`$\\\n]{2,})`""")
PAGE_SCRIPT = re.compile(r"""<(?:script|link)\b[^>]*\b(?:src|href)=["']([^"':?#]+)""")
# A repo path a dev server reads outside webviews/ (`path.join(repoRoot, "Resources/ghostty/themes")`): its literal.
REPO_LITERAL = re.compile(r"""["'`]([A-Z][\w.-]*(?:/[\w.@-]+)*|[a-z][\w-]*/[\w.@/-]+)["'`]""")
BARE_LITERAL = re.compile(r"""["'`]([\w.-]+)["'`]""")
GALLERY_FILE = re.compile(r"\.gallery\.(?:ts|tsx)$")
GALLERY_FRAME = WEB + "src/gallery/frame.html"
# Reviewed loads in a page's closure that the graph cannot follow and that load nothing a change outside the page's
# inputs controls, pinned to their reviewed content (an edit puts the page back in doubt: its tests always run):
#   - registry.ts globs every *.gallery file; galleryFrame's entryPath narrows the stage to the one file it names.
#   - entryStore.ts and importHunks.ts only match the pattern in prose and in a regex for PHP/Ruby source.
#   - liveErrors.ts imports Vite's own client; editor/main.tsx globs Monaco's message files (bun.lock decides them);
#     editor/view.ts imports `cmux:pierre-filetypes`, a virtual module of a dev-server plugin (in every config's
#     closure, so in each test's inputs).
PAGE_LOADS = {
    WEB + "src/gallery/registry.ts": "26564ec915a72c5f3eb1d00766c1c6d42354ae922bb0ee1b73ccb535e4744ff4",
    WEB + "src/gallery/entryStore.ts": "c04482199aa91b40359f5b88c25d4c1e7e23cfecc26e8c1530aade0ff8777842",
    WEB + "src/pages/editor/main.tsx": "fcf6a290b299f6c48b38fcedfbcc551c5c0186362ea671df603ab9b40d8982f3",
    WEB + "src/gallery/frame/liveErrors.ts": "f553033653f2ca9e6a7a1277e9351452001f70bc55a91861d8c1bc16ea50b5bc",
    WEB + "src/diff-viewer/importHunks.ts": "734e4b333f6d11f9c6cfbe52b890712ddb5a8527aa763fbe01d13a72066cee44",
    WEB + "src/pages/editor/view.ts": "6c142785fe0b2f042a1739163e636962cdc6846700f06b56b15f5785ca8556f9",
}

# An import specifier that ends in a module's name, with or without its extension or a query.
SPECIFIER = r"""["'`][^"'`\n]*/{}(?:\.[\w.]+)?(?:\?[^"'`\n]*)?["'`]"""


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
        untracked = {f for f, text in self.text.items() if UNTRACKED.search(text)
                     or (not f.startswith(WEB + "src/") or f in self.graph.tests) and UNTRACKED_OUTSIDE_SRC.search(text)}
        reviewed = {f for f, digest in RUNTIME_LOADS.items() if NARROW and f in self.text
                    and hashlib.sha256((root / f).read_bytes()).hexdigest() == digest}
        self.always = {t for t in self.graph.tests if self.closure(t) & (untracked - reviewed)}
        self.preload = self.closure(PRELOAD)
        # Browser tests tied to the pages they open (PageMap): out of the always-run set, selected by their inputs.
        self.pages: dict[str, PageInputs] = {}
        self.by_input: dict[str, set[str]] = {}
        if PAGE_CLOSURE:
            try:
                self.pages = PageMap(self, untracked - reviewed).build()
            except Exception as err:  # noqa: BLE001 - any failure keeps every browser test always-run
                print(f"webviews affected: page map failed ({type(err).__name__}: {err}); browser tests always run",
                      file=sys.stderr)
                self.pages = {}
        for test, page in self.pages.items():
            for f in page.inputs:
                self.by_input.setdefault(f, set()).add(test)
        self.always -= set(self.pages)

    def closure(self, path: str) -> set[str]:
        """`path` and every module it imports, transitively."""
        seen, frontier = {path}, [path]
        while frontier:
            frontier = [i for f in frontier for i in self.imports.get(f, ()) if i not in seen]
            seen.update(frontier)
        return seen

    def reaching(self, path: str) -> set[str]:
        return {t for _, t in self.graph.for_file(path)} | self.by_input.get(path, set())

    def page_tests(self, files: list[str]) -> set[str]:
        """The page-mapped browser tests a change reaches beyond their imports (PageMap's rules for a change)."""
        out: set[str] = set()
        for f in files:
            if f in self.graph.tests:
                continue
            if f.startswith(WEB):
                if not f.endswith(ft.EXTENSIONS) or not (self.root / f).exists():
                    # CSS, HTML, JSON, an image or fixture, a deleted file: a dev server or a stylesheet may load it
                    # with no import edge (a CSS @import, a plugin's read, a glob). Every page-mapped test runs.
                    return set(self.pages)
                out |= self.by_input.get(f, set())
                if GALLERY_FILE.search(f):
                    # galleryFrame.ts finds an entry's file by its `id:` line in every gallery file: a file that
                    # now (or also) defines a named id changes which file a stage loads.
                    ids = set(GALLERY_ID.findall(self.text.get(f, "")))
                    out |= {t for t, page in self.pages.items() if page.ids & ids}
                continue
            out |= {t for t, page in self.pages.items()
                    if any(f == root or f.startswith(root.rstrip("/") + "/") for root in page.roots)}
        return out

    def named_by(self, path: str) -> set[str] | None:
        name = Path(path).name
        keys = [path, path.removeprefix(WEB)] + ([name] if len(name) >= NAME_MIN else [])
        out: set[str] = set()
        for source, text in self.text.items():
            if source == path or not any(k in text for k in keys):
                continue
            if not source.endswith(ft.EXTENSIONS):
                return None
            out |= self.reaching(source)
        return out

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
            if EVERYTHING.search(f) or f in self.preload:
                return None, f"{f} is a build or runner input"
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
                return None, f"{f} is named by a webviews file outside the import graph"
            if f.startswith(WEB) and not named and not f.endswith(ft.EXTENSIONS):
                return None, f"no rule maps {f}"
            out |= named
        return out | self.always | self.page_tests(files), ""


class PageInputs:
    """What a page-mapped browser test can load: webviews files (`inputs`), repo paths outside webviews/ its dev
    server reads (`roots`), and the gallery entry ids it opens (`ids`)."""

    def __init__(self, inputs: set[str], roots: set[str], ids: set[str]):
        self.inputs, self.roots, self.ids = inputs, roots, ids


class PageMap:
    """Ties each browser test to the pages it opens, so a pull request runs it only when its change can reach them.

    The always-run set was nearly all browser tests (2026-11-22: 782 of 1,266 files, 41.6k of the suite's 45.8k
    manifest test-seconds), each always-run only because it starts Vite and Playwright. What it can load is:
      - its own import closure (helpers included);
      - every Vite config it or a helper names (`configFile: ".../vite.config.gallery-dev.ts"`), with each config's
        closure (dev-server/ plugins, the React compiler, postcss) and the repo paths outside webviews/ those modules
        quote (`path.join(repoRoot, "Resources/ghostty/themes")`, schemas/gallery/fixtures.json's roots);
      - the pages it names: each `.html` literal (every webviews page whose path ends in it), the config root's
        index.html when the config has its own root (the agent pane's `/`), each page's <script>/<link> closure;
      - for a gallery stage (galleryFrame/warmGalleryFrame with an entry id literal): the stage frame and the gallery
        file that defines each id the test quotes (galleryFrame narrows the frame to that file: entryPath).
    A test stays always-run when anything else is in doubt: an untracked module outside BROWSER_HELPERS, its own file
    read, spawn or computed import, no config named, a config whose root it cannot read, a webviews-rooted config with
    no page named, an .html literal no page matches, a gallery test with no known id or a whole-gallery walk
    (WHOLE_GALLERY), or a page whose closure holds an untracked module other than the gallery registry's glob.
    A change selects a mapped test when it touches the test or any input (`reaching`), defines a quoted gallery id,
    falls under a read root, or is any non-code or deleted file under webviews/ (`page_tests`).
    """

    def __init__(self, selector: "Selector", untracked: set[str]):
        self.s = selector
        self.reviewed = {f for f, digest in PAGE_LOADS.items() if f in selector.text
                         and hashlib.sha256((selector.root / f).read_bytes()).hexdigest() == digest}
        self.untracked = untracked
        self.html = {f for f in selector.graph.known if f.startswith(WEB) and f.endswith(".html")}
        self.ids: dict[str, set[str]] = {}
        for f, text in selector.text.items():
            if GALLERY_FILE.search(f):
                for i in GALLERY_ID.findall(text):
                    self.ids.setdefault(i, set()).add(f)
        listing = subprocess.run(["git", "-C", str(selector.root), "ls-tree", "--name-only", "HEAD"],
                                 capture_output=True, text=True, check=True).stdout
        self.top = set(listing.split()) - {"webviews"}
        self._configs: dict[str, tuple[set[str], set[str], str | None] | None] = {}
        self._pages: dict[str, set[str] | None] = {}
        self.why: dict[str, str] = {}

    def miss(self, t: str, why: str) -> None:
        self.why[t] = why
        return None

    def build(self) -> dict[str, PageInputs]:
        out = {}
        for t in sorted(self.s.always):
            page = self.test(t)
            if page is not None:
                out[t] = page
        return out

    def roots(self, files: set[str]) -> set[str]:
        """Repo paths outside webviews/ that these modules quote."""
        out: set[str] = set()
        for f in files:
            text = self.s.text.get(f, "")
            for lit in REPO_LITERAL.findall(text):
                if lit.split("/", 1)[0] in self.top:
                    out.add(lit.rstrip("/"))
            if f.startswith(WEB + "dev-server/") or "/" not in f.removeprefix(WEB):
                # A dev server or config joins a top-level folder alone (`path.join(repoRoot, "first-party-apps")`).
                out |= {lit for lit in BARE_LITERAL.findall(text) if lit in self.top}
        if any("schemas/gallery/fixtures.json" in self.s.text.get(f, "") for f in files):
            index = self.s.root / "schemas/gallery/fixtures.json"
            try:
                import json
                out |= {str(r).strip("/") for r in json.loads(index.read_text()).get("roots", [])}
            except (OSError, ValueError, AttributeError):
                out.add("schemas")  # unreadable: the fixtures' whole folder stands for them
        return out

    def config(self, name: str) -> tuple[set[str], set[str], str | None] | None:
        """(the config's closure, its read roots, its own root dir or None for webviews/), or None if unreadable."""
        if name in self._configs:
            return self._configs[name]
        path = WEB + name
        result = None
        if path in self.s.text:
            text = self.s.text[path]
            closure = self.s.closure(path)
            for shared in ("reactCompiler.mjs", "postcss.config.mjs"):
                if WEB + shared in self.s.text:
                    closure |= self.s.closure(WEB + shared)
            for base in list(closure):
                if base.startswith(WEB) and "/" not in base.removeprefix(WEB) and VITE_CONFIG.search(base):
                    closure |= self.s.closure(base)  # a config that spreads another (`...base`)
            root: str | None = None
            m = re.search(r"^\s*root:\s*([\w$]+|path\.(?:join|resolve)\([^)]*\))\s*,", text, re.M)
            ok = True
            if m:
                expr = m.group(1)
                if not expr.startswith("path."):
                    d = re.search(rf"\bconst\s+{re.escape(expr)}\s*=\s*(path\.(?:join|resolve)\([^)]*\))", text)
                    expr = d.group(1) if d else ""
                lits = re.findall(r"""["']([^"']+)["']""", expr)
                if expr.startswith("path.") and "webviewsRoot" in expr and len(lits) == 1:
                    root = WEB + lits[0].strip("/").removeprefix("./")
                else:
                    ok = False
            result = (closure, self.roots(closure), root) if ok else None
        self._configs[name] = result
        return result

    def page(self, html: str, root: str | None) -> set[str] | None:
        """The page and every module its <script>/<link> tags load, or None when one is untracked or unresolved."""
        if html in self._pages:
            return self._pages[html]
        out = {html}
        result: set[str] | None = out
        text = (self.s.root / html).read_text(encoding="utf-8", errors="replace")
        for src in PAGE_SCRIPT.findall(text):
            if src.startswith(("http", "//")):
                continue
            if src.startswith("/"):
                candidates = [os.path.normpath((root or WEB.rstrip("/")) + src), os.path.normpath(WEB + src)]
            else:
                candidates = [os.path.normpath(os.path.join(os.path.dirname(html), src))]
            hit = next((c for c in candidates if c in self.s.graph.known), None)
            if hit is None:
                if src.startswith("/@"):
                    continue  # Vite's own client
                result = None
                break
            closure = self.s.closure(hit)
            if closure & self.untracked - self.reviewed:
                result = None
                break
            out |= closure
        self._pages[html] = result
        return result

    def test(self, t: str) -> PageInputs | None:
        s = self.s
        closure = s.closure(t)
        if (closure & self.untracked) - BROWSER_HELPERS - {t}:
            return self.miss(t, "1")
        own = BROWSER_OWN.sub("", s.text[t])
        if UNTRACKED.search(own) or UNTRACKED_OUTSIDE_SRC.search(own):
            return self.miss(t, "2")
        named = [f for f in closure if f == t or f.startswith(WEB + "test/")]
        helpers_ok = {WEB + "test/support/galleryFrame.ts"}
        texts = [s.text.get(f, "") for f in named]
        if any(WHOLE_GALLERY.search(s.text.get(f, "")) for f in named if f not in helpers_ok):
            return self.miss(t, "3")
        configs = {c for text in texts for c in VITE_CONFIG.findall(text)}
        if not configs:
            return self.miss(t, "4")
        inputs, roots = set(closure), self.roots(closure)
        own_root_index: set[str] = set()
        webviews_rooted = False
        for name in configs:
            got = self.config(name)
            if got is None:
                return self.miss(t, "5")
            c_closure, c_roots, root = got
            inputs |= c_closure
            roots |= c_roots
            if root is None:
                webviews_rooted = True
            elif root + "/index.html" in self.html:
                own_root_index.add(root + "/index.html")
        pages = set(own_root_index)
        for text in texts:
            for lit in HTML_PAGE.findall(text):
                tail = lit.lstrip("./")
                hits = {h for h in self.html if h == WEB + tail or h.endswith("/" + tail)}
                if not hits:
                    return self.miss(t, "6")
                pages |= hits
        ids: set[str] = set()
        gallery = any(re.search(r"\b(?:warmGalleryFrame|galleryFrame)\(", s.text.get(f, ""))
                      for f in named if f not in helpers_ok)
        if gallery:
            ids = {lit for text in texts for m in LITERAL.findall(text) for lit in m if lit in self.ids}
            if not ids:
                return self.miss(t, "7")
            pages.add(GALLERY_FRAME)
            for i in ids:
                for f in self.ids[i]:
                    inputs |= s.closure(f)
        if webviews_rooted and not (pages - own_root_index):
            return self.miss(t, "8")
        for html in pages:
            got = self.page(html, None)
            if got is None:
                return self.miss(t, "9")
            inputs |= got
        return PageInputs(inputs, roots, ids)


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
