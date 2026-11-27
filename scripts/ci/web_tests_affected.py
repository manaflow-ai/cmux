#!/usr/bin/env python3
"""The web bun test files a change can break: each test's import closure plus the repo paths it reads by literal.

A feat-cmux-next pull request skips web-tests-1..4 unless it names a web input (pr_scope, #57511), so a change outside
web/ that a web test imports or reads (images/, .github/workflows/, a catalog) went red only in the post-merge batch.
This picks the few test files whose closure holds a changed path, so the step runs those and nothing else.

A test's closure: the files it reaches through relative and `@/` imports (import/export from, import(), require()),
resolved over the TypeScript extensions and index files, into any tracked path (web/ or not); plus the literal paths
those files hold (`"../services/x"`, `new URL("../../a.yml", import.meta.url)`, path.join("a", "b") parts), resolved
from the file's directory, from web/ and from the repository root. A literal naming a directory covers every file
under it. Anything it cannot resolve (a bare package, a computed path) it leaves out: fail open, the batch still runs
every test. A changed test file selects itself. A change to what every test loads (web/package.json, web/bun.lock,
web/bunfig.toml, web/tsconfig.json, the preload's closure) or a set over --cap selects nothing and says so: the
web-tests shards and the post-merge batch run them all.

  web_tests_affected.py [--rev REV] [--cap N] [--json] PATHS_FILE|-   one test path (web-relative) a line, or JSON
"""
from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TEST_RE = re.compile(r"(\.test|_test|\.spec|_spec)\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$")
CODE_EXTS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
GLOBAL = {"web/package.json", "web/bun.lock", "web/bunfig.toml", "web/tsconfig.json"}
PRELOAD = "web/tests/test-preload.ts"
DEFAULT_CAP = 80
IMPORT_RE = re.compile(
    r"""(?:\bfrom\s*|\bimport\s*\(\s*|\brequire\s*\(\s*|\bimport\s+|\bmock\.module\s*\(\s*)(["'])([^"'\n]+)\1""")
STRING_RE = re.compile(r"""(["'`])((?:[^"'`\\\n$]|\\.){1,200}?)\1""")
JOIN_RE = re.compile(r"""\b(?:join|resolve)\s*\(([^()]{0,400})\)""")


class Tree:
    """The tracked files at a revision (git ls-tree, git cat-file) or in the work tree (git ls-files)."""

    def __init__(self, rev: str | None) -> None:
        self.rev = rev
        cmd = ["git", "ls-tree", "-r", "--name-only", rev] if rev else ["git", "ls-files"]
        self.files = set(subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True).stdout.splitlines())
        self.dirs: set[str] = set()
        for f in self.files:
            d = posixpath.dirname(f)
            while d and d not in self.dirs:
                self.dirs.add(d)
                d = posixpath.dirname(d)
        self._cat: subprocess.Popen | None = None
        self._texts: dict[str, str] = {}

    def text(self, path: str) -> str:
        if path in self._texts:
            return self._texts[path]
        text = ""
        if self.rev is None:
            try:
                text = (ROOT / path).read_text(errors="replace")
            except OSError:
                pass
        else:
            if self._cat is None:
                self._cat = subprocess.Popen(["git", "cat-file", "--batch"], cwd=ROOT, stdin=subprocess.PIPE,
                                             stdout=subprocess.PIPE)
            assert self._cat.stdin and self._cat.stdout
            self._cat.stdin.write(f"{self.rev}:{path}\n".encode())
            self._cat.stdin.flush()
            header = self._cat.stdout.readline().split()
            if len(header) == 3:
                body = self._cat.stdout.read(int(header[2]))
                self._cat.stdout.read(1)
                text = body.decode(errors="replace")
        self._texts[path] = text
        return text


def norm(path: str) -> str | None:
    out = posixpath.normpath(path)
    return None if out.startswith("..") or out.startswith("/") else ("" if out == "." else out)


def resolve_module(tree: Tree, base: str) -> str | None:
    if base in tree.files:
        return base
    stem, ext = posixpath.splitext(base)
    candidates = [base + e for e in CODE_EXTS] + [base + "/index" + e for e in CODE_EXTS]
    if ext in (".js", ".jsx", ".mjs", ".cjs"):
        candidates += [stem + e for e in CODE_EXTS]
    return next((c for c in candidates if c in tree.files), None)


def specifier_base(spec: str, here: str) -> str | None:
    if spec.startswith("@/"):
        return norm("web/" + spec[2:])
    if spec.startswith("./") or spec.startswith("../") or spec in (".", ".."):
        return norm(posixpath.join(here, spec))
    return None


def scan(tree: Tree, path: str, files: set[str], dirs: set[str]) -> list[str]:
    """Adds the literal paths `path` names to files/dirs and returns the code modules it imports."""
    text = tree.text(path)
    here = posixpath.dirname(path)
    modules = []
    for match in IMPORT_RE.finditer(text):
        base = specifier_base(match.group(2), here)
        target = resolve_module(tree, base) if base is not None else None
        if target:
            modules.append(target)
    literals = [m.group(2) for m in STRING_RE.finditer(text)]
    for match in JOIN_RE.finditer(text):
        parts = [m.group(2) for m in STRING_RE.finditer(match.group(1))]
        if len(parts) > 1:
            literals.append("/".join(parts))
    for lit in literals:
        if " " in lit or "\\" in lit or "://" in lit or len(lit) < 1:
            continue
        relative = lit in (".", "..") or lit.startswith("./") or lit.startswith("../")
        if not relative and "/" not in lit.strip("/"):
            continue
        bases = [posixpath.join(here, lit)] if relative else [lit.strip("/"), "web/" + lit.strip("/")]
        for base in bases:
            target = norm(base)
            if target is None:
                continue
            if target in tree.files:
                files.add(target)
                if target.endswith(CODE_EXTS):
                    modules.append(target)
                break
            if target == "" or target in tree.dirs:
                if target not in ("", "web"):
                    dirs.add(target)
                break
            module = resolve_module(tree, target) if relative else None
            if module:
                modules.append(module)
                break
    return modules


def closure(tree: Tree, start: str, memo: dict[str, tuple[frozenset, frozenset]]) -> tuple[frozenset, frozenset]:
    """Every file and literal directory `start` reaches (iterative; the per-module scan is cached)."""
    files: set[str] = {start}
    dirs: set[str] = set()
    todo = [start]
    while todo:
        path = todo.pop()
        if path not in memo:
            f: set[str] = set()
            d: set[str] = set()
            mods = scan(tree, path, f, d) if path.endswith(CODE_EXTS) else []
            memo[path] = (frozenset(f | set(mods)), frozenset(d))
        f, d = memo[path]
        dirs |= d
        for nxt in f:
            if nxt not in files:
                files.add(nxt)
                if nxt.endswith(CODE_EXTS):
                    todo.append(nxt)
    return frozenset(files), frozenset(dirs)


def web_tests(tree: Tree) -> list[str]:
    out = []
    for f in tree.files:
        if not f.startswith("web/") or not TEST_RE.search(f):
            continue
        parts = f.split("/")[1:-1]
        if any(p == "node_modules" or p.startswith(".") for p in parts):
            continue
        out.append(f)
    return sorted(out)


def select(tree: Tree, changed: list[str], cap: int = DEFAULT_CAP) -> dict:
    changed = sorted(set(c for c in changed if c))
    memo: dict[str, tuple[frozenset, frozenset]] = {}
    preload, _ = closure(tree, PRELOAD, memo) if PRELOAD in tree.files else (frozenset(), frozenset())
    everything = sorted(c for c in changed if c in GLOBAL or c in preload)
    if everything:
        return {"tests": [], "skipped": f"{everything[0]} is loaded by every web test", "changed": changed}
    tests = web_tests(tree)
    picked = []
    for test in tests:
        files, dirs = closure(tree, test, memo)
        if any(c in files or any(c.startswith(d + "/") for d in dirs) for c in changed):
            picked.append(test)
    # A deleted or renamed test: the changed path itself, when it is still a test at this tree, is in `tests` already.
    if len(picked) > cap:
        return {"tests": [], "skipped": f"{len(picked)} test files over the cap of {cap}", "changed": changed,
                "would": len(picked)}
    return {"tests": picked, "skipped": None, "changed": changed, "of": len(tests)}


def read_paths(arg: str) -> list[str]:
    text = sys.stdin.read() if arg == "-" else Path(arg).read_text()
    stripped = text.strip()
    if stripped.startswith("["):
        return [str(p) for p in json.loads(stripped)]
    return [line.strip() for line in text.splitlines() if line.strip()]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("paths", help="the changed paths, one a line or a JSON list; - reads stdin")
    ap.add_argument("--rev", help="read the tree at this revision (git) instead of the work tree")
    ap.add_argument("--cap", type=int, default=DEFAULT_CAP)
    ap.add_argument("--json", action="store_true", help="print the whole result as JSON")
    args = ap.parse_args(argv)
    try:
        result = select(Tree(args.rev), read_paths(args.paths), args.cap)
    except Exception as error:  # fail open: the batch runs every web test
        print(f"web_tests_affected: cannot select ({error}); none picked", file=sys.stderr)
        result = {"tests": [], "skipped": f"error: {error}"}
    if args.json:
        print(json.dumps(result, indent=2))
        return 0
    if result.get("skipped"):
        print(f"web_tests_affected: none picked: {result['skipped']}", file=sys.stderr)
    for test in result["tests"]:
        print(test[len("web/"):])
    return 0


if __name__ == "__main__":
    sys.exit(main())
