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
    (RUNTIME_LOADS) are exempt at their pinned content;
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
