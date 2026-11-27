#!/usr/bin/env python3
"""A test file never defines one name twice in one class or module body (ruff/pyflakes F811).

cmux#41779 review: tests/test_git_history.py had two `count_fetches` helpers in one TestCase. Python
keeps the last one, so the first, which held a lock for the parallel test's appends, was dead code
and the parallel test appended from several threads without it: a flake nobody could see by
reading the helper that looked right. The sweep found three more in tests/.

  python  Each tests/**/*.py file: a `def`, `async def` or `class` statement whose name an earlier
          `def`/`async def`/`class` in the same module or class body already took. A body is read
          on its own, so a method and a module function of one name, or two classes each with a
          `setUp`, are fine. `@overload`, `@x.setter`, `@x.getter` and `@x.deleter` defs are the
          intended re-use of a name and are skipped.

A redefinition that is meant (a deliberate override in the same body) has no reason to exist: keep
the one that should win, delete the other. Exits 1 with one line per hit; 0 when clean; 2 when a file
does not parse (`path:line: does not parse: ...`): the file was not read, so that is no verdict, and the
pre-push gate refuses it rather than pass a file it could not judge.

  python3 scripts/cmux-next/check-test-redefinitions.py [--root DIR] [FILE ...]

The pre-push gate (prepush-gate.py, "Test redefinitions") runs it on the tests/ files a push changes, at the base and
the head, and refuses only a redefinition the push adds. Local only, like SwiftFormat: no new CI gate.
"""
from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# What this check reads.
INPUTS = ("tests/**/*.py",)
INTENDED_REUSE = frozenset({"overload", "setter", "getter", "deleter"})
DEFINITIONS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
# Blocks a scope can sit in. `match` cases are ast.match_case, which Python 3.9 (macOS /usr/bin/python3, which
# install-git-hooks.sh accepts) does not have: getattr, so 3.9 builds this tuple too (a 3.9 parse has no match).
BLOCKS = (ast.stmt, ast.excepthandler, getattr(ast, "match_case", ()))
# A file the check could not read: its line, and the exit that says "no verdict" (not 1, a verdict).
UNPARSED = ": does not parse: "
UNPARSED_EXIT = 2


def _reuses_its_name(node: ast.AST) -> bool:
    for decorator in getattr(node, "decorator_list", ()):
        target = decorator.func if isinstance(decorator, ast.Call) else decorator
        name = target.attr if isinstance(target, ast.Attribute) else getattr(target, "id", None)
        if name in INTENDED_REUSE:
            return True
    return False


def _scopes(node: ast.AST):
    """Each `def`, `async def` or `class` that opens a scope directly under NODE's scope, at any depth of `if`,
    `try`/`except`/`else`/`finally`, `with`, `for`, `while` or `match` blocks, never inside another scope."""
    for child in ast.iter_child_nodes(node):
        if isinstance(child, DEFINITIONS):
            yield child
        elif isinstance(child, BLOCKS):
            yield from _scopes(child)


def _bodies(tree: ast.Module):
    """Each module or class body, with the dotted scope name a finding reports: one recursive visit, so each class
    is read once, under the scope it sits in (a class in a method of a class is `Outer.method.Inner.`)."""
    def visit(prefix: str, node: ast.AST):
        for child in _scopes(node):
            scope = f"{prefix}{child.name}."
            if isinstance(child, ast.ClassDef):
                yield scope, child.body
            yield from visit(scope, child)

    yield "", tree.body
    yield from visit("", tree)


def scan_source(source: str, path: str) -> list[str]:
    """One line per name defined twice in one body: `path:line: Scope.name redefines line N`."""
    try:
        tree = ast.parse(source, path)
    except SyntaxError as error:
        return [f"{path}:{error.lineno or 1}{UNPARSED}{error.msg}"]
    hits = []
    for scope, body in _bodies(tree):
        first: dict[str, int] = {}
        for node in body:
            if not isinstance(node, DEFINITIONS) or _reuses_its_name(node):
                continue
            if node.name in first:
                hits.append((node.lineno, f"{path}:{node.lineno}: {scope}{node.name} redefines line {first[node.name]}; "
                             "Python keeps only this one, so the first is dead code. Keep one."))
            else:
                first[node.name] = node.lineno
    # Sorted by line before it is text: a path may hold `:` (`tests/a:b.py`), so a line number is never read back out
    # of a hit (#41827 review: that read crashed the checker on such a path).
    return [hit for _, hit in sorted(hits)]


def test_files(root: Path) -> list[Path]:
    return sorted(path for path in (root / "tests").rglob("*.py") if path.is_file())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("files", nargs="*", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    hits = []
    for path in args.files or test_files(root):
        shown = path.resolve().relative_to(root) if path.resolve().is_relative_to(root) else path
        hits += scan_source(path.read_text(encoding="utf-8"), str(shown))
    for hit in hits:
        print(hit)
    if any(UNPARSED in hit for hit in hits):
        print("a tests/ file does not parse, so it was not checked: no verdict.", file=sys.stderr)
        return UNPARSED_EXIT
    if hits:
        print(f"{len(hits)} redefinition(s) in tests/ (ruff F811): the earlier definition never runs.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
