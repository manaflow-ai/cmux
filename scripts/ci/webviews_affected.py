#!/usr/bin/env python3
"""The webviews test files a pull request's change can affect, for the react-apps-check shards.

    webviews_affected.py --base REF [--head REF] [--repo DIR]

Prints the selected test files (relative to webviews/, one per line) for
CMUX_WEB_TEST_FILES, or nothing when every file must run, and why on stderr. A
feat-cmux-next push runs every file whatever this says (ci-web.yml passes it only on a
pull request), so a base never loses a suite.

The selection is focused_tests.py's webviews import graph with no cap, plus rules that keep
it from missing a test:
  - a changed test file runs itself; a deleted one, or a deleted source, selects nothing;
  - a file under webviews/ selects every test that imports it, directly or through other
    modules;
  - a file anywhere that a webviews source names (its repo path, its path under webviews/,
    or a basename of 10 characters or more) selects the tests that reach that source; a
    name found in a non-code file (a fixture, a config) selects everything;
  - a test that reads files from disk (readFileSync, readdir, a glob, Bun.file) always runs:
    no import graph covers what it reads;
  - a build or runner input (webviews/package.json, bun.lock, bunfig, tsconfig, vite configs,
    webviews/scripts/, the test support dir, the runner scripts, this file, ci-web.yml)
    selects everything, as does any other file under webviews/ no rule maps.
Docs (.md) and files no webviews source names select nothing.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import focused_tests as ft  # noqa: E402

WEB = "webviews/"
EVERYTHING = re.compile(
    r"^webviews/(package\.json|bun\.lock|bunfig\.toml|tsconfig[^/]*\.json|vite[^/]*\.(ts|mjs|js)|"
    r"reactCompiler\.mjs|scripts/|test/support/|test/setup)"
    r"|^scripts/ci/(run-webviews-tests\.sh|webviews-tests-new-reds\.sh|webviews_test_[^/]*\.py|webviews_affected\.py"
    r"|focused_tests\.py)$|^\.github/workflows/ci-web\.yml$|^config/vite-plus/")
READS_FILES = re.compile(r"readFileSync|readdirSync|readdir\(|Bun\.Glob|new Glob|import\.meta\.glob|globSync|Bun\.file\(")
NAME_MIN = 10


class Selector:
    def __init__(self, root: Path):
        self.root = root
        self.graph = ft.WebTests(root)
        self.text = {f: (root / f).read_text(encoding="utf-8", errors="replace") for f in self.graph.known
                     if f.endswith(ft.EXTENSIONS) or f.endswith(".json")}
        self.always = {t for t in self.graph.tests if READS_FILES.search(self.text.get(t, ""))}

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
            if EVERYTHING.search(f):
                return None, f"{f} is a build or runner input"
            if f.endswith(".md"):
                continue
            if f.startswith(WEB):
                if f in self.graph.tests:
                    out.add(f)
                    continue
                if not (self.root / f).exists() and (ft.WEB_TEST.search(f) or f.endswith(ft.EXTENSIONS)):
                    continue
                hit = self.reaching(f)
                if hit:
                    out |= hit
                    continue
                if f.endswith(ft.EXTENSIONS) and f.startswith(WEB + "src/"):
                    continue  # source no test imports
            named = self.named_by(f)
            if named is None:
                return None, f"{f} is named by a webviews file outside the import graph"
            if f.startswith(WEB) and not named and not f.endswith(ft.EXTENSIONS):
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
