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
    selects everything (the tests that imported it are gone from the graph);
  - a file under webviews/ selects every test that imports it, directly or through other
    modules (a template-literal import counts by its static path, an asset import by its path
    without the query: `./fixture.md?raw`);
  - a file anywhere that a webviews source names (its repo path, its path under webviews/,
    or a basename of 10 characters or more) selects the tests that reach that source; a
    name found in a non-code file (a fixture, a config) selects everything;
  - a test always runs when it, or any module it imports, does what no import graph follows:
    reads files (sync or async, a glob, Bun.file), imports a computed path or an alias, starts
    Vite or a browser, or spawns a process. The content-pinned generated frame-table reader
    is exempt only when all changed files are isolated tests that cannot feed its bundle;
  - a build or runner input (webviews/package.json, bun.lock, bunfig, tsconfig, vite configs,
    webviews/scripts/, the test support dir, the preload bunfig loads before every file and
    what it imports, the runner scripts, this file, ci-web.yml) selects everything, as does
    any other file under webviews/ no rule maps.
Docs (.md) no test imports and files no webviews source names select nothing.
"""
from __future__ import annotations

import argparse
import hashlib
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
# This reader loads only the generated bundle's site table. A standalone test
# file cannot change that table. Pin the reviewed reader: any edit restores the
# unresolved fallback until its inputs have been reviewed again. Production
# changes still select every consumer, as do tests imported by production code.
GENERATED_READERS = {
    WEB + "src/agent-session/acpmux/frameOwners.ts":
        "99c31528e5b7e676cb9aee8e069cd77f8cee5feb8af52119801287a48cd6c37e",
}


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
        generated = {f for f, digest in GENERATED_READERS.items() if f in self.text
                     and hashlib.sha256((root / f).read_bytes()).hexdigest() == digest}
        self.generated = set().union(*(self.reaching(f) for f in generated)) if generated else set()
        self.always = {t for t in self.graph.tests if self.closure(t) & (untracked - generated)}
        self.preload = self.closure(PRELOAD)

    def isolated_test(self, path: str) -> bool:
        """A test cannot feed a bundle if every reverse edge stays in test files.

        Helpers, fixtures, deleted files and unresolved inputs are not exempt.
        Follow all reverse edges, including test -> helper -> production.
        """
        if path not in self.graph.tests:
            return False
        seen, frontier = set(), [path]
        while frontier:
            source = frontier.pop()
            if source in seen:
                continue
            seen.add(source)
            if source not in self.graph.tests:
                return False
            frontier.extend(self.graph.importers.get(source, ()))
        return True

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
            if not source.endswith(ft.EXTENSIONS):
                return None
            out |= self.reaching(source)
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
                    return None, f"{f} was deleted"
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
        generated = self.generated if any(not self.isolated_test(f) for f in files) else set()
        return out | self.always | generated, ""


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
