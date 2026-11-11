#!/usr/bin/env python3
"""A non-cone sparse checkout carries every scripts/ci module its listed scripts import.

Many scripts/ci/*.py import siblings (`import deadline_http` after a sys.path insert of their own
folder, or `from x import y`, sometimes lazily inside a function). A workflow step that checks out a
few files with `sparse-checkout` and `sparse-checkout-cone-mode: false` must list those siblings too,
or the script dies with ModuleNotFoundError at run time: #40631 left deadline_http.py out of
ios-reliability-matrix.yml's runner job.

The test is a differential oracle; it does not resolve imports itself. For every job and every
actions/checkout step with a non-cone `sparse-checkout`, each listed scripts/ci/**.py file is an entry
script, and the stdlib's modulefinder.ModuleFinder (which reads bytecode and never runs the script)
finds every module it loads, transitively, functions included, with Python's own import machinery
and the search path the script really gets: its own folder (sys.path[0]), then the PYTHONPATH it
runs with: the effective env (workflow, then job, then step, the inner one winning) of each run step
whose line names the script, or a `PYTHONPATH=...` on that line; with no such step, the job's env.
${{ github.workspace }} and $GITHUB_WORKSPACE are the repo root. An entry it cannot resolve (another
expression or variable, an absolute path, a path leaving the repo) is unverifiable, and fails. A script the job runs as `python -m pkg.main` (a
run line's dotted name is the end of its path) is imported by that name instead, from the folder
above the package, so its parent packages' __init__.py files load first, as at run time. It runs
twice:

  1. over the full repo tree;
  2. over the tree the list really checks out. Git makes that tree: a throwaway repo holds the
     modules run 1 found (real contents), `git sparse-checkout set --no-cone` gets the list's
     patterns verbatim, and the files it leaves without the skip-worktree bit are kept. So directory
     entries, globs, leading slashes and "!" exclusions mean exactly what they mean to
     actions/checkout (a "!file" exclusion beats a later "dir/" include).

A module run 1 loads that run 2 does not load from the same file is a miss, when the list does not
check that file out. (A checked-out module run 2 never reaches, because its importer is missing, is
not reported: the importer is.)

Two gaps in ModuleFinder are filled here, both in _Finder below:
  - Namespace packages (a folder without __init__.py): ModuleFinder crashes on them (the spec has
    no loader and no origin), so they load as a package whose __path__ is the spec's search
    locations. A stdlib top-level name never resolves to a namespace folder here, as the stdlib
    (which this search path leaves out, for speed) would win at run time.
  - Optional imports: ModuleFinder cannot tell them apart, and its badmodules only lists what it
    could not find in that run, so a module the sparse run lacks would be a miss even when the
    script catches the ImportError. An import inside a `try:` body whose handlers catch ImportError,
    ModuleNotFoundError (or a bare `except:`/`except Exception`/`BaseException`) is removed from the
    source before compiling, in both runs, since the script runs without it.

Dynamic imports fail closed. A sys.path change, importlib.import_module, importlib.__import__,
importlib.util.spec_from_file_location, runpy or __import__ anywhere in a listed script's closure
(found in each module's AST) makes the step unverifiable, unless DYNAMIC_IMPORT_AUDIT names that file,
call and argument text with a one-line reason; an audit entry that matches no live call fails too. Only exact,
provable forms are learned instead (the comment above DYNAMIC_CALLS lists them): sys.path.insert(0, P)
and sys.path.append(P) of a fixed repo folder join both runs' search path in order, and
spec_from_file_location(name, P) of a fixed repo file joins the closure and must be checked out, in
a `try:` or not, unless an audit entry keyed (loading file, loaded file) marks it optional. There is
no other allowlist.

Run: python3 tests/test_ci_sparse_checkout_imports.py
"""

from __future__ import annotations

import ast
import importlib.machinery
import modulefinder
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from collections import Counter
from contextlib import contextmanager
from functools import lru_cache
from pathlib import Path
from typing import NamedTuple

import yaml

ROOT = Path(__file__).resolve().parents[1]

# (file, call, argument text) -> why the modules that call loads need no listing; or (loading file,
# loaded file) -> why a load this check learned is optional. The argument text is the call's
# arguments as written (whitespace and quote style do not matter; a sys.path assignment gives its
# whole statement), so each call needs its own entry, and an entry whose call is edited or gone
# matches nothing and fails (see stale_audit_entries). One line of reason each.
DYNAMIC_IMPORT_AUDIT: dict[tuple[str, ...], str] = {
    ("scripts/ci/merge_main_resolver.py", "importlib.util.spec_from_file_location", "'merge_main_xcstrings', path"): (
        "loads scripts/merge-xcstrings.py under its tools_root argument; the catch-up checkout lists it"
    ),
    (
        "scripts/ci/stable_next.py",
        "importlib.util.spec_from_file_location",
        "'crash_ratchet', head_tree / 'scripts/cmux-next/crash_ratchet.py'",
    ): "loads crash_ratchet.py from the --head-tree archive it compares, not from this checkout",
    ("scripts/ci/web_subareas.py", "scripts/cmux-next/web-bundle-key.py"): (
        "optional: web_bundle_input_matcher() returns None when the key script is missing, and callers fall back"
    ),
    ("scripts/ci/next_macos_cascade.py", "__import__", "'os'"): (
        "the stdlib's os, only to build the sys.path insert of its own folder"
    ),
    (
        "scripts/ci/next_macos_cascade.py",
        "sys.path.insert",
        "0, __import__('os').path.dirname(__import__('os').path.abspath(__file__))",
    ): "inserts its own folder, which is already sys.path[0]",
    ("scripts/ci/portable_job_placement.py", "importlib.util.spec_from_file_location", "name, path"): (
        "_load() takes the literal names pr_runner_pool and side_lane_placement, files beside it the decide "
        "checkout lists"
    ),
}
CI_DIR = "scripts/ci"
OPTIONAL_HANDLERS = {"ImportError", "ModuleNotFoundError", "Exception", "BaseException"}


# --- sparse-checkout entries -------------------------------------------------------------------


def sparse_entries(raw: object) -> list[str]:
    """The entries of a `sparse-checkout` input: a block string, a one-line string, or a list."""
    if isinstance(raw, list):
        lines = [str(item) for item in raw]
    else:
        lines = str(raw).splitlines()
    out = []
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def _git(cwd: Path, *args: str, stdin: str | None = None) -> str:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY"):
        env.pop(key, None)
    result = subprocess.run(
        ["git", "-c", "user.name=x", "-c", "user.email=x", "-c", "commit.gpgsign=false", *args],
        cwd=cwd,
        env=env,
        input=stdin,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed in {cwd}: {result.stderr.strip()}")
    return result.stdout


def make_sparse_tree(tree: Path, entries: tuple[str, ...], files: frozenset[str], root: Path) -> frozenset[str]:
    """Fill `tree` with what these non-cone sparse patterns check out of `files` (copied from `root`).

    Git is the oracle: a throwaway repo holding every file is committed, then
    `git sparse-checkout set --no-cone` gets the patterns exactly as the workflow lists them. Files
    git marks skip-worktree (`git ls-files -t`: "S") are gone from the tree. Returns the kept files.
    """
    _git(tree, "init", "-q")
    for rel in files:
        (tree / rel).parent.mkdir(parents=True, exist_ok=True)
        (tree / rel).write_bytes((root / rel).read_bytes())
    _git(tree, "add", "-A")
    _git(tree, "commit", "-q", "--no-verify", "-m", "sparse oracle")
    _git(tree, "sparse-checkout", "set", "--no-cone", "--stdin", stdin="".join(f"{e}\n" for e in entries))
    present = set()
    for record in _git(tree, "ls-files", "-t", "-z").split("\0"):
        if record:
            tag, rel = record.split(" ", 1)
            if tag == "S":
                (tree / rel).unlink(missing_ok=True)
            else:
                present.add(rel)
    return frozenset(present)


def listed_ci_scripts(entries: list[str], root: Path) -> list[str]:
    """scripts/ci/**.py files the entries name by exact path (leading slash allowed)."""
    out = []
    for entry in entries:
        if entry.startswith("!"):
            continue
        rel = entry.lstrip("/")
        if rel.startswith(CI_DIR + "/") and rel.endswith(".py") and not any(ch in rel for ch in "*?["):
            if (root / rel).is_file():
                out.append(rel)
    return out


# --- import oracle ----------------------------------------------------------------------------

_NAMESPACE = "namespace"  # a file_info kind of our own: a folder without __init__.py


def _catches_import_error(handler: ast.ExceptHandler) -> bool:
    kind = handler.type
    if kind is None:
        return True
    names = kind.elts if isinstance(kind, ast.Tuple) else [kind]
    for name in names:
        ident = name.attr if isinstance(name, ast.Attribute) else getattr(name, "id", None)
        if ident in OPTIONAL_HANDLERS:
            return True
    return False


class _DropOptionalImports(ast.NodeTransformer):
    """Replace each import inside a `try:` body that catches ImportError with `pass`."""

    def __init__(self) -> None:
        self.guarded = 0

    def visit_Try(self, node: ast.Try) -> ast.AST:
        optional = any(_catches_import_error(h) for h in node.handlers)
        self.guarded += optional
        node.body = [self.visit(stmt) for stmt in node.body]
        self.guarded -= optional
        node.handlers = [self.visit(h) for h in node.handlers]
        node.orelse = [self.visit(stmt) for stmt in node.orelse]
        node.finalbody = [self.visit(stmt) for stmt in node.finalbody]
        return node

    visit_TryStar = visit_Try

    def _drop(self, node: ast.AST) -> ast.AST:
        return ast.copy_location(ast.Pass(), node) if self.guarded else node

    visit_Import = _drop
    visit_ImportFrom = _drop


@lru_cache(maxsize=None)
def _code(source: bytes):
    """The module's code with optional imports removed, or None when it does not parse."""
    try:
        tree = ast.parse(source)
    except (SyntaxError, ValueError):
        return None
    tree = ast.fix_missing_locations(_DropOptionalImports().visit(tree))
    return compile(tree, "<scanned>", "exec")


class _Finder(modulefinder.ModuleFinder):
    """ModuleFinder plus namespace packages, optional-import removal, and who imported what."""

    def __init__(self, path: list[str]) -> None:
        super().__init__(path=path)
        self.importer: dict[str, str] = {}  # module -> the module whose import statement loaded it
        self._scanning: list[str] = []

    def scan_code(self, co, m):
        # `from . import x` reaches import_hook with no caller, so the module being scanned is it.
        self._scanning.append(m.__name__)
        try:
            super().scan_code(co, m)
        finally:
            self._scanning.pop()

    def scan_opcodes(self, co):
        # ModuleFinder raises out of scan_code on `from . import x` in a module with no package (a
        # script); Python raises there at run time too, and loads nothing, so skip just that import.
        module = self.modules.get(self._scanning[-1]) if self._scanning else None
        for what, args in super().scan_opcodes(co):
            if what == "relative_import" and not args[2] and module is not None:
                try:
                    self.determine_parent(module, level=args[0])
                except ImportError:
                    continue
            yield what, args

    def import_hook(self, name, caller=None, fromlist=None, level=-1):
        by = caller.__name__ if caller else (self._scanning[-1] if self._scanning else "__main__")
        before = set(self.modules)
        try:
            return super().import_hook(name, caller, fromlist, level)
        finally:
            # Nested imports finish first, so they keep their own importer.
            for added in self.modules.keys() - before:
                self.importer.setdefault(added, by)

    def find_module(self, name, path, parent=None):
        if path is not None or name not in sys.builtin_module_names:
            spec = importlib.machinery.PathFinder.find_spec(name, self.path if path is None else path)
            if spec is not None and spec.origin is None and spec.submodule_search_locations is not None:
                if parent is None and name in sys.stdlib_module_names:
                    raise ImportError(name)  # the stdlib's own module wins over a namespace folder
                return None, list(spec.submodule_search_locations), ("", "", _NAMESPACE)
        return super().find_module(name, path, parent)

    def load_module(self, fqname, fp, pathname, file_info):
        kind = file_info[2]
        if kind == _NAMESPACE:
            module = self.add_module(fqname)
            module.__path__ = pathname
            return module
        if kind != modulefinder._PY_SOURCE:
            return super().load_module(fqname, fp, pathname, file_info)
        code = _code(fp.read())
        module = self.add_module(fqname)
        module.__file__ = pathname
        if code is not None:
            module.__code__ = code
            self.scan_code(code, module)
        return module


@contextmanager
def _importer_cache_scope(tree: Path):
    """Drop the import system's cached finders for `tree` afterwards, so they do not pile up."""
    try:
        yield
    finally:
        prefix = str(tree)
        for key in [k for k in sys.path_importer_cache if isinstance(k, str) and k.startswith(prefix)]:
            del sys.path_importer_cache[key]


def find_modules(
    tree: Path,
    script: str,
    search: tuple[str, ...],
    module: str | None = None,
    loaded: tuple[tuple[str, str], ...] = (),
) -> tuple[dict[str, str], dict[str, str]]:
    """Run ModuleFinder on `script` in `tree` with this search path (tree-relative folders, in order).

    `module` is None for `python script.py`, or the dotted name for `python -m module`: then the
    module is imported by name, so its parent packages (each __init__.py) load first, as they do at
    run time. `loaded` are (file, loader file) pairs a spec_from_file_location loads by path; each one
    in the tree is scanned too, with the same search path.

    Returns ({module: where it loads from}, {module: its importer}). Places are tree-relative: a
    file, or a folder ending in "/" for a namespace package. Modules outside the tree (builtins) and
    the script itself (__main__) are left out.
    """
    tree = tree.resolve()
    finder = _Finder([str(tree / rel) if rel else str(tree) for rel in search])
    with _importer_cache_scope(tree):
        if module is None:
            finder.run_script(str(tree / script))
        else:
            try:
                finder.import_hook(module)
            except ImportError:
                pass  # the same in both runs when the module is not there
        for file, loader in loaded:
            if (tree / file).is_file():
                name = f"<loaded {file}>"
                with open(tree / file, "rb") as fp:
                    finder.load_module(name, fp, str(tree / file), (".py", "rb", modulefinder._PY_SOURCE))
                finder.importer[name] = loader  # a file, not a module: find_misses reads it as a place
    places: dict[str, str] = {}
    for name, found in finder.modules.items():
        if name == "__main__":
            continue
        if found.__file__:
            location = Path(found.__file__)
            suffix = ""
        elif found.__path__:
            location = Path(found.__path__[0])
            suffix = "/"
        else:
            continue
        if location.is_relative_to(tree):
            places[name] = location.relative_to(tree).as_posix() + suffix
    return places, finder.importer


# --- dynamic imports: fail closed -------------------------------------------------------------
#
# ModuleFinder follows import statements only. A module that changes sys.path, or loads modules by
# a name or path it computes, can need files this check never sees. Each such call in a listed
# script's import closure is reported as unverifiable unless DYNAMIC_IMPORT_AUDIT names its file,
# call and argument text with a reason. The check learns only forms it can prove, and only these:
#   - sys.path.insert(0, P) and sys.path.append(P): P joins both runs' search path, each insert(0)
#     in front of everything before it (so the last one wins), each append at the end, but only when
#     their order is provable: every such call is a statement of the entry script's module body with
#     nothing before it that could import a non-stdlib module (so every import sees the final path;
#     a stdlib-named import before one counts only when no folder on the path offers a stdlib name), or no top-level name is offered twice among the
#     folders the checker models on the path (the entry folder, PYTHONPATH's, the inserted ones),
#     the stdlib and this interpreter's installed distributions, counting .py files, extension
#     modules and every folder (package or namespace) from the tree's full file list, so order cannot
#     change what loads (changes that only name the entry folder are harmless in any order). Otherwise each one is unverifiable. A search path that keeps changing
#     which file a module loads from is reported as "path search does not settle (A <-> B)";
#   - importlib.util.spec_from_file_location(name, P): the file at P joins the closure and must be
#     checked out, inside a `try:` or not. It is optional only when DYNAMIC_IMPORT_AUDIT says so,
#     keyed by (loading file, loaded file).
# P must be a fixed path in the repo: a string literal (relative to the run's working directory: the
# step's working-directory and the `cd`s before the command; no literal is fixed when that is unknown), or __file__ through Path(), str(), os.fspath(), .resolve(), .absolute(), .parent,
# .parents[N], / "literal", .with_name("literal"), .joinpath("literal"), os.path.abspath/realpath/
# dirname or os.path.join(..., "literal"), directly or through a name bound exactly once by a plain
# `NAME = ...` statement in the body of the innermost function around the call (or, for a name that
# function never binds, of the module; never at module level in a module with a star import), and
# that nothing else in that scope rebinds (no second assignment, `+=`, loop or with target,
# parameter, import, global...). Any other form, a keyword argument, or an insert at another index is
# unverifiable.

DYNAMIC_CALLS = {
    "sys.path.insert",
    "sys.path.append",
    "sys.path.extend",
    "importlib.import_module",
    "importlib.__import__",
    "importlib.util.spec_from_file_location",
    "runpy.run_path",
    "runpy.run_module",
    "__import__",
}
SYS_PATH_ASSIGNMENT = "sys.path assignment"


def _aliases(tree: ast.AST) -> dict[str, str]:
    """Local name -> the dotted name it stands for, from the module's import statements."""
    names: dict[str, str] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.asname:
                    names[alias.asname] = alias.name
                else:
                    first = alias.name.split(".", 1)[0]
                    names[first] = first
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            for alias in node.names:
                names[alias.asname or alias.name] = f"{node.module}.{alias.name}"
    return names


def _dotted(node: ast.AST, aliases: dict[str, str]) -> str | None:
    attrs = []
    while isinstance(node, ast.Attribute):
        attrs.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name):
        return None
    return ".".join([aliases.get(node.id, node.id), *reversed(attrs)])


_FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)


def _binding_counts(scope: ast.AST) -> Counter[str]:
    """How many times each name is bound anywhere inside `scope` (nested scopes included, which only
    makes a name harder to prove): assignments, augmented assignments, loop, with, except, walrus and
    match targets, del, imports, defs, classes, parameters, global and nonlocal. All but a plain
    assignment count twice, so they alone disqualify a name."""
    binds: Counter[str] = Counter()
    for node in ast.walk(scope):
        if isinstance(node, ast.Name) and not isinstance(node.ctx, ast.Load):
            binds[node.id] += 1
        elif isinstance(node, ast.arg):
            binds[node.arg] += 2
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node is not scope:
            binds[node.name] += 2
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                binds[(alias.asname or alias.name).split(".")[0]] += 2
        elif isinstance(node, (ast.Global, ast.Nonlocal)):
            for name in node.names:
                binds[name] += 2
        elif isinstance(node, (ast.ExceptHandler, ast.MatchAs, ast.MatchStar)) and node.name:
            binds[node.name] += 2
        elif isinstance(node, ast.MatchMapping) and node.rest:
            binds[node.rest] += 2
    return binds


def _bound_once(scope: ast.AST, star: bool = False) -> dict[str, ast.AST]:
    """Names `scope` (the module or one function) binds exactly once, by a plain `NAME = expr`
    statement directly in its body, and nowhere else inside it -> expr. A binding in a block (if, for,
    try...) never counts. With a star import in the module (`star`), no module-level name is provable."""
    if star and isinstance(scope, ast.Module):
        return {}
    binds = _binding_counts(scope)
    once: dict[str, ast.AST] = {}
    for node in getattr(scope, "body", []):
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if binds[node.targets[0].id] == 1:
                once[node.targets[0].id] = node.value
    return once


Bindings = dict[str, "tuple[ast.AST, Bindings] | None"]


def _scope_bindings(tree: ast.Module) -> dict[int, Bindings]:
    """For every node, the names a path there can use, each as (expression, the bindings of the scope
    that assigned it) so the expression is evaluated where it was written, not where it is used: the
    innermost function's provable names, None for any other name that function binds at all, then
    the enclosing functions' and the module's. A function's decorators, defaults and annotations
    belong to the scope around it (_evaluated_outside). Keyed by node id."""
    star = any(isinstance(n, ast.ImportFrom) and any(a.name == "*" for a in n.names) for n in ast.walk(tree))
    module: Bindings = {}
    module.update({name: (expr, module) for name, expr in _bound_once(tree, star).items()})
    out: dict[int, Bindings] = {}

    def visit(node: ast.AST, names: Bindings, outside: frozenset[int]) -> None:
        for child in ast.iter_child_nodes(node):
            if id(child) in outside:
                continue  # evaluated in the enclosing scope, already visited there
            if isinstance(child, _FUNCTIONS):
                inner: Bindings = dict(names)
                inner.update({name: None for name, count in _binding_counts(child).items() if count})
                if not isinstance(child, ast.Lambda):
                    inner.update({name: (expr, inner) for name, expr in _bound_once(child).items()})
                out[id(child)] = inner
                parts = _evaluated_outside(child)
                for part in parts:
                    out[id(part)] = names
                    visit(part, names, outside)
                visit(child, inner, outside | {id(part) for part in parts})
            else:
                out[id(child)] = names
                visit(child, names, outside)

    visit(tree, module, frozenset())
    return out


def _evaluated_outside(node: ast.AST) -> list[ast.AST]:
    """The parts of a def or lambda Python evaluates where it is defined, not in its own scope: the
    decorators, the parameter defaults and annotations, and the return annotation. (A class's bases,
    keywords and decorators need nothing: a class body is not a scope _scope_bindings models, so they
    already see the enclosing scope's names.)"""
    args = node.args
    parts: list[ast.AST] = [*getattr(node, "decorator_list", [])]
    parts += [d for d in [*args.defaults, *args.kw_defaults] if d is not None]
    params = [*args.posonlyargs, *args.args, *args.kwonlyargs, args.vararg, args.kwarg]
    parts += [p.annotation for p in params if p is not None and p.annotation is not None]
    if getattr(node, "returns", None) is not None:
        parts.append(node.returns)
    return parts


class _FixedPath:
    """Evaluates a path in the forms the comment above lists; None for anything else."""

    def __init__(
        self, here: Path, root: Path, aliases: dict[str, str], bindings: "Bindings", cwd: Path | None = None
    ) -> None:
        self.here, self.root, self.aliases, self.bindings = here, root, aliases, bindings
        self.cwd = cwd  # a relative literal's folder: the run's working directory, None when unknown

    def __call__(self, node: ast.AST, depth: int = 0) -> Path | None:
        if depth > 20:
            return None
        ev = lambda n: self(n, depth + 1)  # noqa: E731
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return None if os.path.isabs(node.value) or self.cwd is None else self.cwd / node.value
        if isinstance(node, ast.Name):
            if node.id == "__file__":
                return self.here
            bound = self.bindings.get(node.id)
            if bound is None:
                return None
            expr, scope = bound
            return _FixedPath(self.here, self.root, self.aliases, scope, self.cwd)(expr, depth + 1)
        if isinstance(node, ast.Attribute) and node.attr == "parent":
            base = ev(node.value)
            return None if base is None else Path(os.path.normpath(base)).parent
        if (
            isinstance(node, ast.Subscript)
            and isinstance(node.value, ast.Attribute)
            and node.value.attr == "parents"
            and isinstance(node.slice, ast.Constant)
            and isinstance(node.slice.value, int)
        ):
            base = ev(node.value.value)
            if base is None:
                return None
            parents = Path(os.path.normpath(base)).parents
            return parents[node.slice.value] if 0 <= node.slice.value < len(parents) else None
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            base = ev(node.left)
            right = node.right
            if base is not None and isinstance(right, ast.Constant) and isinstance(right.value, str):
                return base / right.value
            return None
        if isinstance(node, ast.Call) and not node.keywords:
            func, args = node.func, node.args
            if isinstance(func, ast.Attribute) and func.attr in ("resolve", "absolute") and not args:
                return ev(func.value)
            literals = all(isinstance(a, ast.Constant) and isinstance(a.value, str) for a in args)
            if isinstance(func, ast.Attribute) and func.attr == "with_name" and len(args) == 1 and literals:
                base = ev(func.value)
                return None if base is None else base.with_name(args[0].value)
            if isinstance(func, ast.Attribute) and func.attr == "joinpath" and args and literals:
                base = ev(func.value)
                return None if base is None else base.joinpath(*(a.value for a in args))
            name = _dotted(func, self.aliases)
            one = {"pathlib.Path", "str", "os.fspath", "os.path.abspath", "os.path.realpath"}
            if name in one and len(args) == 1:
                return ev(args[0])
            if name == "os.path.dirname" and len(args) == 1:
                base = ev(args[0])
                return None if base is None else Path(os.path.normpath(base)).parent
            if name == "os.path.join" and args:
                base = ev(args[0])
                for part in args[1:]:
                    if base is None or not (isinstance(part, ast.Constant) and isinstance(part.value, str)):
                        return None
                    base = base / part.value
                return base
        return None


def _call_text(node: ast.AST) -> str:
    """A dynamic call's arguments (a sys.path assignment's whole statement) as ast.unparse writes them,
    so whitespace, line breaks and quote style do not change it."""
    if not isinstance(node, ast.Call):
        return ast.unparse(node)
    return ", ".join([*(ast.unparse(a) for a in node.args), *(ast.unparse(k) for k in node.keywords)])


def normal_audit_key(key: tuple[str, ...]) -> tuple[str, ...]:
    """An audit key as the check compares it: (file, call, argument text) with the text normalized the
    way _call_text writes it, or (loading file, loaded file) for an optional load, unchanged."""
    if len(key) == 2:
        return key
    if len(key) != 3:
        raise ValueError(f"DYNAMIC_IMPORT_AUDIT key {key!r}: use (file, call, argument text) or (file, loaded file)")
    rel, call, text = key
    if call == SYS_PATH_ASSIGNMENT:
        return rel, call, ast.unparse(ast.parse(text).body[0])
    return rel, call, _call_text(ast.parse(f"f({text})", mode="eval").body)


_PATH_BUILDERS = {
    "pathlib.Path", "str", "os.fspath", "os.path.abspath", "os.path.realpath", "os.path.dirname", "os.path.join",
}


ORDERED = 1  # a path change no import can see half-done
AFTER_STDLIB_IMPORT = 2  # the same, but a stdlib-named import runs before it: ordered only if no repo
# folder on the search path offers a stdlib name (NameProof.shadows_stdlib), since that import, or one
# it makes, would load the repo's file from the path as it stood then.


def _clean_prefix_path_changes(tree: ast.Module, aliases: dict[str, str]) -> dict[int, int]:
    """ids of the sys.path calls that are statements of the module body with nothing before them that
    could import a module outside the stdlib -> ORDERED, or AFTER_STDLIB_IMPORT when an import of a
    stdlib name (not a builtin, which no folder can shadow) comes before it: before (and between) them
    only docstrings, imports of stdlib names, other such path calls, and plain assignments whose only
    calls build paths (_PATH_BUILDERS, .resolve(), .absolute(), .with_name(), .joinpath()). Every
    other import then runs after the last of them, so the final search path is the one it sees. A
    path call after anything else is not in the dict."""
    clean: dict[int, int] = {}
    stdlib_import = False
    for stmt in tree.body:
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant):
            continue
        if isinstance(stmt, ast.Import) and all(a.name.split(".")[0] in sys.stdlib_module_names for a in stmt.names):
            stdlib_import |= any(a.name.split(".")[0] not in sys.builtin_module_names for a in stmt.names)
            continue
        if isinstance(stmt, ast.ImportFrom) and stmt.level == 0 and (stmt.module or "").split(".")[0] in sys.stdlib_module_names:
            stdlib_import |= (stmt.module or "").split(".")[0] not in sys.builtin_module_names
            continue
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call):
            if _dotted(stmt.value.func, aliases) in ("sys.path.insert", "sys.path.append"):
                calls = [n for n in ast.walk(stmt.value) if isinstance(n, ast.Call) and n is not stmt.value]
                if all(_builds_path(c, aliases) for c in calls):
                    clean[id(stmt.value)] = AFTER_STDLIB_IMPORT if stdlib_import else ORDERED
                    continue
            return clean
        if isinstance(stmt, (ast.Assign, ast.AnnAssign)):
            value = stmt.value
            if value is not None and all(_builds_path(c, aliases) for c in ast.walk(value) if isinstance(c, ast.Call)):
                continue
        return clean
    return clean


def _builds_path(call: ast.Call, aliases: dict[str, str]) -> bool:
    if isinstance(call.func, ast.Attribute) and call.func.attr in ("resolve", "absolute", "with_name", "joinpath"):
        return True
    return _dotted(call.func, aliases) in _PATH_BUILDERS


@lru_cache(maxsize=None)
def dynamic_calls(
    root: Path, rel: str, cwd: str | None = ""
) -> tuple[tuple[tuple[str, str], ...], tuple[str, ...], tuple[tuple[str, int], ...]]:
    """What a file's dynamic imports do, in source order: (("insert" or "append", folder, ordered,
    call, line, argument text) for each fixed sys.path change, files learned spec_from_file_location
    calls load, unresolved (call, line, argument text)). A path change is `ordered` (ORDERED or
    AFTER_STDLIB_IMPORT, else 0) only when it is a statement of its own directly in the module body:
    straight-line code that runs once, in source order, at import (_clean_prefix_path_changes). The argument text is _call_text's, so the audit can name the exact call. A
    relative string literal names a path from `cwd`, the run's working directory (repo-relative; None
    when this check cannot resolve it, and then no literal is a fixed path)."""
    try:
        tree = ast.parse((root / rel).read_bytes())
    except (OSError, SyntaxError, ValueError):
        return (), (), ()
    aliases = _aliases(tree)
    scopes = _scope_bindings(tree)
    path_ops: list[tuple[str, str, bool, str, int, str]] = []
    top_level = _clean_prefix_path_changes(tree, aliases)
    loads: list[str] = []
    unresolved: list[tuple[str, int, str]] = []

    def in_repo(node: ast.AST, want_dir: bool) -> str | None:
        # A name resolves in the innermost function first, then at module level (lexical scope).
        start = None if cwd is None else root / cwd if cwd else root
        found = _FixedPath(root / rel, root, aliases, scopes.get(id(node), {}), start)(node)
        if found is None:
            return None
        found = Path(os.path.normpath(found))
        if not found.is_relative_to(root) or not (found.is_dir() if want_dir else found.is_file()):
            return None
        rel_found = found.relative_to(root).as_posix()
        return "" if rel_found == "." else rel_found

    kinds = (ast.Call, ast.Assign, ast.AugAssign, ast.AnnAssign)
    for node in sorted((n for n in ast.walk(tree) if isinstance(n, kinds)), key=lambda n: (n.lineno, n.col_offset)):
        if not isinstance(node, ast.Call):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                if isinstance(target, ast.Subscript):
                    target = target.value
                if _dotted(target, aliases) == "sys.path":
                    unresolved.append((SYS_PATH_ASSIGNMENT, node.lineno, _call_text(node)))
            continue
        name = _dotted(node.func, aliases)
        if name not in DYNAMIC_CALLS:
            continue
        args = node.args
        if not node.keywords and not any(isinstance(a, ast.Starred) for a in args):
            first = args[0] if args else None
            if name == "sys.path.insert" and len(args) == 2:
                if isinstance(first, ast.Constant) and type(first.value) is int and first.value == 0:
                    folder = in_repo(args[1], want_dir=True)
                    if folder is not None:
                        path_ops.append(
                            ("insert", folder, top_level.get(id(node), 0), name, node.lineno, _call_text(node))
                        )
                        continue
            elif name == "sys.path.append" and len(args) == 1:
                folder = in_repo(args[0], want_dir=True)
                if folder is not None:
                    path_ops.append(("append", folder, top_level.get(id(node), 0), name, node.lineno, _call_text(node)))
                    continue
            elif name == "importlib.util.spec_from_file_location" and len(args) == 2:
                file = in_repo(args[1], want_dir=False)
                if file is not None:
                    if file not in loads:
                        loads.append(file)
                    continue
        unresolved.append((name, node.lineno, _call_text(node)))
    return tuple(path_ops), tuple(loads), tuple(unresolved)


SEARCH_DOES_NOT_SETTLE = "path search does not settle"


class NameProof:
    """Proves that the order of some search-path folders cannot change what an import loads: no
    top-level name is offered by two of them, nor by one of them and the stdlib
    (sys.stdlib_module_names) or an installed distribution of this interpreter. The folders are every
    one the checker models on the path: sys.path[0] (the script's folder for `python script.py`, the
    working directory for `python -m`, `-c` and stdin), PYTHONPATH's and the inserted ones. Names come from the tree's full file list, built once
    per find_misses run (module_name_index), never from the sparse list or an earlier run."""

    def __init__(self, root: Path, outside: set[str] | None = None) -> None:
        self.root = root
        self._index: dict[str, set[str]] | None = None
        self._outside = outside  # stdlib and installed names; the oracle passes them in once

    def disjoint(self, folders: list[str]) -> bool:
        if self._index is None:
            self._index = module_name_index(self.root)
        if self._outside is None:
            self._outside = set(sys.stdlib_module_names) | _installed_names()
        seen: set[str] = set()
        for folder in dict.fromkeys(folders):
            offered = self._index.get(folder, set())
            if offered & seen or offered & self._outside:
                return False
            seen |= offered
        return True

    def shadows_stdlib(self, folders: list[str]) -> bool:
        """Whether any of these folders offers a stdlib name (a .py file, an extension module, or a
        folder) other than a builtin's: an import of that name, or one the stdlib makes, would load
        the repo's file from wherever the search path stood at that import."""
        if self._index is None:
            self._index = module_name_index(self.root)
        stdlib = set(sys.stdlib_module_names) - set(sys.builtin_module_names)
        return any(self._index.get(folder, set()) & stdlib for folder in dict.fromkeys(folders))


def _tree_files(root: Path) -> list[str]:
    """Every file of the tree: `git ls-files` (the checkout's revision) when `root` is a git work tree,
    else every file on disk (a test fixture). Never the sparse list."""
    if (root / ".git").exists():
        try:
            listed = subprocess.run(
                ["git", "-C", str(root), "ls-files", "-z"], capture_output=True, text=True, check=True
            ).stdout
            return [rel for rel in listed.split("\0") if rel]
        except (OSError, subprocess.CalledProcessError):
            pass
    out = []
    for folder, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d != ".git"]
        out += [os.path.relpath(os.path.join(folder, n), root).replace(os.sep, "/") for n in names]
    return out


def _top_name(entry: str, is_file: bool) -> str | None:
    """The top-level module name a folder entry offers, or None. A file: x.py, or an extension module
    x.so / x.pyd with or without an ABI tag (x.cpython-312-x86_64-linux-gnu.so). A folder: any folder
    with an identifier name, since Python imports one without __init__.py as a namespace package."""
    if not is_file:
        return entry if entry.isidentifier() else None
    if entry.endswith(".py"):
        name = entry[:-3]
    elif entry.endswith((".so", ".pyd")):
        name = entry.split(".", 1)[0]
    else:
        return None
    return name if name.isidentifier() else None


def module_name_index(root: Path) -> dict[str, set[str]]:
    """folder (repo-relative, "" for the root) -> the top-level names it offers, from one pass over
    the tree's full file list (see _tree_files and _top_name)."""
    index: dict[str, set[str]] = {}
    for rel in _tree_files(root):
        parts = rel.split("/")
        for depth in range(len(parts)):
            name = _top_name(parts[depth], depth == len(parts) - 1)
            if name is not None:
                index.setdefault("/".join(parts[:depth]), set()).add(name)
    return index


def _installed_names() -> set[str]:
    """Top-level names the distributions installed for this interpreter (sys.executable) provide."""
    import importlib.metadata

    names = set(importlib.metadata.packages_distributions())
    for dist in importlib.metadata.distributions():
        top = dist.read_text("top_level.txt") or ""
        names.update(line.strip() for line in top.splitlines() if line.strip())
    return names


def _search_path(
    names: "NameProof",
    entry: str,
    rel_ops: list[tuple[str, tuple]],
    base: str,
    extra: tuple[str, ...],
    audited: frozenset,
) -> tuple[list[str], list[str], list[tuple[str, str, int, str]]]:
    """(folders in front, folders at the end, path changes that cannot be ordered) from the closure's
    fixed sys.path changes, as (file, ops) in the order ModuleFinder met the files.

    Changes that only name the entry folder (already sys.path[0]) leave the search unchanged in any
    order. Otherwise the order must be provable: every change sits in the entry script, as a module
    statement with nothing that could import before it (_clean_prefix_path_changes), so every import
    sees the final path (a stdlib-named import before one counts only when no folder on the path
    offers a stdlib name: it is never trusted to be the stdlib's); or NameProof.disjoint holds for every folder the
    search path can hold, so any order loads the same files. When neither holds, each change that is not audited by (file, call,
    argument text) is unverifiable and none is learned; audited ones are dropped."""
    ops = [(rel, op) for rel, file_ops in rel_ops for op in file_ops]
    if all(op[1] == base for _, op in ops):
        return [], [], []
    files = {rel for rel, _ in ops}
    folders = [base, *extra, *(op[1] for _, op in ops)]
    ordered = files == {entry} and all(op[2] for _, op in ops)
    if ordered and any(op[2] == AFTER_STDLIB_IMPORT for _, op in ops) and names.shadows_stdlib(folders):
        ordered = False  # a stdlib-named import between the changes may load a repo file mid-way
    if ordered or names.disjoint(folders):
        front: list[str] = []
        back: list[str] = []
        for _, (kind, folder, *_rest) in ops:
            if kind == "insert":  # insert(0, x) puts x in front of every earlier entry
                if folder in front:
                    front.remove(folder)
                front.insert(0, folder)
            elif folder not in front and folder not in back:
                back.append(folder)
        return front, back, []
    unordered = []
    for rel, (_kind, _folder, _ordered, call, line, text) in ops:
        if (rel, call, text) not in audited:
            unordered.append((rel, call, line, text))
    return [], [], unordered


def full_run(
    root: Path,
    script: str,
    extra: tuple[str, ...],
    how: tuple[str, str] | None,
    audited: frozenset = frozenset(),
    names: NameProof | None = None,
    base: str | None = None,
    cwd: str | None = "",
) -> tuple[dict[str, str], dict[str, str], tuple[str, ...], tuple, tuple[tuple[str, str, int, str], ...]]:
    """ModuleFinder over the full tree: (places, importers, the search path used, the files loaded by
    path as (file, loader), unresolved dynamic calls as (file, call, line, argument text)). The
    closure's fixed sys.path changes build the search path when their order is provable
    (_search_path), and learned loads join the closure unless `audited` holds (loader, file); the run
    repeats until neither changes. A search that comes back to an earlier state without settling is
    one unresolved (script, SEARCH_DOES_NOT_SETTLE, 0, "A <-> B") naming the files that trade places.
    `base` is sys.path[0] (run_configs): the script's folder for `python script.py`, else the step's
    working directory. `cwd` is the run's working directory, for relative literals in path changes."""
    if base is None:
        base = default_base(script, how)
    module = how[0] if how else None
    names = names or NameProof(root)
    front: list[str] = []
    back: list[str] = []
    loaded: dict[str, str] = {}  # file -> the file that loads it
    states: list[tuple] = []
    for _ in range(20):
        search = tuple(dict.fromkeys([*front, base, *extra, *back]))
        places, importer = find_modules(root, script, search, module, tuple(loaded.items()))
        files = dict.fromkeys([script, *(p for p in places.values() if not p.endswith("/"))])
        new_loaded: dict[str, str] = {}
        unresolved = []
        rel_ops = []
        for rel in files:
            path_ops, loads, calls = dynamic_calls(root, rel, cwd)
            if path_ops:
                rel_ops.append((rel, path_ops))
            for file in loads:
                if (rel, file) not in audited:
                    new_loaded.setdefault(file, rel)
            unresolved += [(rel, call, line, text) for call, line, text in calls]
        new_front, new_back, unordered = _search_path(names, script, rel_ops, base, extra, audited)
        unresolved += unordered
        state = (front, back, loaded)
        states.append((state, places))
        if (new_front, new_back, new_loaded) == state:
            return places, importer, search, tuple(loaded.items()), tuple(unresolved)
        seen = [i for i, (old, _) in enumerate(states) if old == (new_front, new_back, new_loaded)]
        if seen:
            cycle = [p for _, p in states[seen[0]:]]
            names = sorted({n for p in cycle for n in p if len({q.get(n) for q in cycle}) > 1})
            sides = [" <-> ".join(dict.fromkeys(str(p.get(n)) for p in cycle)) for n in names]
            what = ", ".join(sides) or " <-> ".join(" ".join(st[0][0] + st[0][1]) or "(none)" for st in states[seen[0]:])
            # The files it would load are unknown: report only that, not misses from one of the states.
            return {}, {}, search, (), ((script, SEARCH_DOES_NOT_SETTLE, 0, what),)
        front, back, loaded = new_front, new_back, new_loaded
    return {}, {}, search, (), ((script, SEARCH_DOES_NOT_SETTLE, 0, "no fixed point in 20 rounds"),)


def _audit_live(root: Path, key: tuple[str, ...], cwd: str | None) -> bool:
    """Whether an audit entry matches a live call of its file when it runs from `cwd`, read by the same
    dynamic_calls (so the same relative-path resolution) that find_misses uses for that run. With the
    working directory unknown (None), where a load call points cannot be resolved, but the call itself
    is known: the entry is live only while the file has a load call that names its file from some
    folder of the tracked tree (a finite set, so `..` paths count too), and that run is already
    unverifiable."""
    path_ops, loads, calls = dynamic_calls(root, key[0], cwd)
    if len(key) == 2:
        if cwd is not None:
            return key[1] in loads
        if not any(call == "importlib.util.spec_from_file_location" for call, _, _ in calls):
            return key[1] in dynamic_calls(root, key[0], "")[1]  # no call depends on the directory
        return any(key[1] in dynamic_calls(root, key[0], folder)[1] for folder in _tree_folders(root))
    live_calls = {(c, t) for c, _, t in calls} | {(op[3], op[5]) for op in path_ops}
    return (key[1], normal_audit_key(key)[2]) in live_calls


@lru_cache(maxsize=None)
def _tree_folders(root: Path) -> tuple[str, ...]:
    """Every folder of the tracked tree ("" for the root), from _tree_files, in a fixed order."""
    folders = {""}
    for rel in _tree_files(root):
        parts = rel.split("/")[:-1]
        folders.update("/".join(parts[: i + 1]) for i in range(len(parts)))
    return tuple(sorted(folders))


def stale_audit_entries(
    root: Path, audit: dict[tuple[str, ...], str], ran_in: dict[str, set[str | None]] | None = None
) -> list[str]:
    """Audit entries that match nothing live: a file that is gone, no unresolved call of that kind with
    that argument text (so editing an audited call needs a fresh look), or a load the file no longer
    makes; and entries with no reason. `ran_in` maps a file to each working directory a checked run
    reads it from (None when unknown); an entry is live when it is live from any of them. A file no
    run reads is read from the repo root."""
    out = []
    for key, reason in sorted(audit.items()):
        rel, what = key[0], key[1]
        label = f"{rel} {what}" + (f"({key[2]})" if len(key) == 3 else "")
        if not (root / rel).is_file():
            out.append(f"DYNAMIC_IMPORT_AUDIT: {label}: the file is gone, drop the entry")
            continue
        normal_audit_key(key)  # a malformed key raises here, as before
        live = any(_audit_live(root, key, cwd) for cwd in sorted((ran_in or {}).get(rel) or {""}, key=str))
        if not live:
            out.append(f"DYNAMIC_IMPORT_AUDIT: {label}: no call in {rel} matches it; re-check the call and the entry")
        elif not str(reason).strip():
            out.append(f"DYNAMIC_IMPORT_AUDIT: {label}: give a one-line reason")
    return out


def _files_for(places: dict[str, str], root: Path) -> set[str]:
    """The files that make these modules: each module file, and a namespace folder's own files."""
    files = set()
    for place in places.values():
        if place.endswith("/"):
            files.update(f"{place}{p.name}" for p in (root / place).iterdir() if p.is_file())
        else:
            files.add(place)
    return files


@lru_cache(maxsize=None)
def sparse_runs(
    root: Path,
    entries: tuple[str, ...],
    files: frozenset[str],
    runs: tuple[tuple[tuple, tuple[str, ...], str | None, tuple[tuple[str, str], ...]], ...],
) -> tuple[frozenset[str], dict[tuple, dict[str, str] | None]]:
    """The files this list checks out of `files`, and each run's modules in that tree (None if its
    script is not in it). A run is keyed as in find_misses, with its search path, module and loaded files."""
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp).resolve()
        present = make_sparse_tree(tree, entries, files, root)
        return present, {
            run: find_modules(tree, run[0], search, module, loaded)[0] if run[0] in present else None
            for run, search, module, loaded in runs
        }


# --- workflows --------------------------------------------------------------------------------

_SHELL_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_RUN_MODULE = re.compile(r"\bpython[\d.]*\b[^\n;&|]*?\s-m\s*([A-Za-z_][\w.]*)")
_WORKSPACE = re.compile(r"^(?:\$\{\{\s*github\.workspace\s*\}\}|\$\{GITHUB_WORKSPACE\}|\$GITHUB_WORKSPACE\b)")


def effective_env(doc: dict, job: dict, step: dict | None = None) -> dict:
    """The env a step sees: the workflow's, then the job's, then the step's, the inner one winning a
    key, as GitHub merges them. (Kept here until tests/workflow_jobs.py carries this merge.)"""
    env: dict = {}
    for scope in (doc, job, step or {}):
        layer = scope.get("env") if isinstance(scope, dict) else None
        if isinstance(layer, dict):
            env.update({str(key): value for key, value in layer.items()})
    return env


def _job_run_modules(job: dict) -> tuple[str, ...]:
    """Module names the job's run lines start with `python -m`."""
    found: list[str] = []
    for step in job.get("steps") or []:
        if isinstance(step, dict) and isinstance(step.get("run"), str):
            found.extend(m for m in _RUN_MODULE.findall(step["run"]) if m not in found)
    return tuple(found)


def how_it_runs(script: str, modules: tuple[str, ...]) -> tuple[str, str] | None:
    """(module, folder) when the job runs `script` as `python -m module` (the dotted name is the end of
    its path, or of its package's path for a __main__.py), else None (`python script.py`)."""
    for module in modules:
        rel = module.replace(".", "/")
        for tail, name in ((f"{rel}.py", module), (f"{rel}/__main__.py", f"{module}.__main__")):
            if script == tail or script.endswith("/" + tail):
                return name, script[: -len(tail)].rstrip("/")
    return None


def default_base(script: str, how: tuple[str, str] | None) -> str:
    """sys.path[0] when nothing says otherwise: the module's root folder for `python -m`, else the
    script's folder."""
    return how[1] if how else script.rsplit("/", 1)[0]


_PYTHON = r"\bpython[\d.]*(?:\s+-[A-Za-z]*[BdEhiIOPqsSuvVWxX][A-Za-z]*)*"
_RUN_CODE = re.compile(_PYTHON + r"\s+-[A-Za-z]*c")
_RUN_STDIN = re.compile(_PYTHON + r"(?:\s+-(?=\s|$)|\s*<|\s*$)")
_HEREDOC = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?")


def _resolve_dir(raw: str, cwd: str | None, root: Path) -> str | None:
    """The repo folder `cd raw` lands in from `cwd`, or None when this check cannot tell (a variable,
    an absolute path, a folder outside the repo or not in it)."""
    if cwd is None:
        return None
    part = raw.strip().strip("'\"")
    anchored = _WORKSPACE.match(part)
    if anchored:
        part, cwd = part[anchored.end():].lstrip("/") or ".", ""
    if not part or part.startswith(("/", "~", "-")) or "$" in part or "`" in part:
        return None
    rel = os.path.normpath(os.path.join(cwd, part)) if cwd else os.path.normpath(part)
    if rel == ".." or rel.startswith("../"):
        return None
    rel = "" if rel == "." else rel
    return rel if (root / rel).is_dir() else None


def _step_cwd(doc: dict, job: dict, step: dict, root: Path) -> str | None:
    """The folder a run step starts in: its working-directory, else the job's, then the workflow's
    defaults.run.working-directory, else the repo root."""
    for scope, key in ((step, None), (job, "defaults"), (doc, "defaults")):
        if not isinstance(scope, dict):
            continue
        holder = scope if key is None else ((scope.get(key) or {}).get("run") or {})
        if isinstance(holder, dict) and holder.get("working-directory") is not None:
            return _resolve_dir(str(holder["working-directory"]), "", root)
    return ""


class _Tok(NamedTuple):
    """One token of a shell line: kind "word", "op" (structure: only an unquoted ( ) && || ; & | |&
    or a case terminator), "redir" (a redirection operator) or "bad" (a ( right after a word: an
    array, a function definition or a glob, all outside the grammar)."""

    kind: str
    text: str  # a word without its quotes; an operator as written
    raw: str  # as written
    quoted: bool  # some part of the word was quoted or escaped
    start: int
    end: int


_OPS = (
    "&&", "||", ";;&", ";;", ";&", "|&", "&>>", "&>", "<<<", "<<-", "<<", ">>", ">&", "<&", "<>", ">|",
    ";", "&", "|", "(", ")", "<", ">",
)
_REDIRECTIONS = {"&>>", "&>", "<<<", "<<-", "<<", ">>", ">&", "<&", "<>", ">|", "<", ">"}
_WORD_END = frozenset(" \t;&|()<>")


def _skip_double(line: str, i: int) -> int | None:
    """The index past the `"` that closes a double-quoted string whose body starts at `i`."""
    while i < len(line):
        c = line[i]
        if c == "\\":
            i += 2
        elif c == '"':
            return i + 1
        elif line.startswith(("$(", "${"), i):
            j = _skip_nested(line, i + 2, line[i + 1], ")" if line[i + 1] == "(" else "}")
            if j is None:
                return None
            i = j
        elif c == "`":
            j = _skip_backtick(line, i + 1)
            if j is None:
                return None
            i = j
        else:
            i += 1
    return None


def _skip_backtick(line: str, i: int) -> int | None:
    while i < len(line):
        if line[i] == "\\":
            i += 2
        elif line[i] == "`":
            return i + 1
        else:
            i += 1
    return None


def _skip_nested(line: str, i: int, opener: str, closer: str) -> int | None:
    """The index past the `closer` that matches an `opener` just before `i` ($( ... ), ${ ... },
    <( ... )), skipping quotes and nested substitutions; None if it never closes."""
    depth = 1
    while i < len(line):
        c = line[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = line.find("'", i + 1)
            if j < 0:
                return None
            i = j + 1
            continue
        if c == '"' or c == "`":
            j = _skip_double(line, i + 1) if c == '"' else _skip_backtick(line, i + 1)
            if j is None:
                return None
            i = j
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def _shell_tokens(line: str) -> list[_Tok] | None:
    """One logical line's tokens, or None when it does not lex (an unclosed quote or substitution).
    Quoting decides structure: a quoted or escaped ( ) ; & | is part of a word, never an operator.
    $( ... ), ${ ... }, backquotes, <( ... ) and >( ... ) stay inside the word they are in."""
    toks: list[_Tok] = []
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if c in " \t":
            i += 1
            continue
        if c == "#":
            break  # a comment: the rest of the line
        if c in "<>" and line.startswith("(", i + 1):  # process substitution
            j = _skip_nested(line, i + 2, "(", ")")
            if j is None:
                return None
            toks.append(_Tok("word", line[i:j], line[i:j], True, i, j))
            i = j
            continue
        op = next((o for o in _OPS if line.startswith(o, i)), None)
        if op is not None:
            toks.append(_Tok("redir" if op in _REDIRECTIONS else "op", op, op, False, i, i + len(op)))
            i += len(op)
            continue
        start, text, quoted = i, [], False
        while i < n and line[i] not in _WORD_END:
            c = line[i]
            if c == "\\":
                text.append(line[i + 1 : i + 2])
                quoted = True
                i += 2
            elif c == "'":
                j = line.find("'", i + 1)
                if j < 0:
                    return None
                text.append(line[i + 1 : j])
                quoted = True
                i = j + 1
            elif c == '"':
                j = _skip_double(line, i + 1)
                if j is None:
                    return None
                text.append(line[i + 1 : j - 1])
                quoted = True
                i = j
            elif line.startswith(("$(", "${"), i):
                j = _skip_nested(line, i + 2, line[i + 1], ")" if line[i + 1] == "(" else "}")
                if j is None:
                    return None
                text.append(line[i:j])
                i = j
            elif c == "`":
                j = _skip_backtick(line, i + 1)
                if j is None:
                    return None
                text.append(line[i:j])
                i = j
            else:
                text.append(c)
                i += 1
        toks.append(_Tok("word", "".join(text), line[start:i], quoted, start, i))
        if i < n and line[i] == "(":
            toks.append(_Tok("bad", "(", "(", False, i, i + 1))
            i += 1
    return toks


def _line_commands(line: str) -> list[list[str]] | None:
    """The words of each simple command on a logical line (redirections kept as words), split at
    unquoted operators, without the reserved words before a command; None when it does not lex."""
    toks = _shell_tokens(line)
    if toks is None:
        return None
    commands: list[list[str]] = [[]]
    for tok in toks:
        if tok.kind in ("op", "bad"):
            commands.append([])
        elif tok.quoted or tok.text not in _LEADING_RESERVED or commands[-1]:
            commands[-1].append(tok.text)
    return [command for command in commands if command]


_LEADING_RESERVED = {"then", "do", "else", "elif", "!", "time", "if", "while", "until", "{", "}"}
_GIVES_UP = {"eval", "source", ".", "pushd", "popd", "case", "esac", "function", "select", "coproc", "]]"}
_EXIT_TRAPS = {"EXIT", "0", "INT", "TERM", "HUP", "QUIT", "SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"}
_UNQUOTED_GLOB = re.compile(r"[*?\[]")
_NOT_FOUND = object()
_SUBSHELL_COMMAND = _Tok("word", "( ... )", "( ... )", True, 0, 0)


def _command_name(command: list[_Tok]) -> tuple[_Tok | None, list[str]]:
    """A simple command's name (after its VAR=value words) and its arguments' text."""
    at = 0
    while at < len(command) and not command[at].quoted and _SHELL_ASSIGNMENT.match(command[at].raw):
        at += 1
    if at == len(command):
        return None, []
    return command[at], [tok.text for tok in command[at + 1 :]]


_OK, _FAILED, _EXEMPT = 1, 0, -1


class _Shell:
    """Where a run step's shell is, read one logical line at a time: a repo folder, or None when this
    check cannot tell. It reads only a small grammar and gives up everywhere else, for good:

      - lists: pipelines joined by && and ||, ended by ;, & or the end of the line;
      - pipelines of simple commands, optionally after !; ( ... ) subshells; { ... } groups;
      - if / while / until / for blocks, read as one command: a cd anywhere inside one makes the
        directory unknown;
      - in a simple command, only cd (one plain argument), exit, return, set (errexit) and trap
        (exit-time signals only) matter; every other command may succeed or fail and changes nothing.

    Anything else gives up: case, functions, arrays, [[ ]], (( )), eval, source, ., pushd, popd,
    exec with a command, builtin/command cd, a command name built from a variable or substitution,
    shopt, CDPATH, a trap that can run mid-step, a here-doc (after its line), or a line that does not
    lex. Structure comes only from unquoted operators (_shell_tokens).

    It tracks the possible (directory, last status, dies) states through an and-or list: a cd may
    fail, so it changes the directory only for what runs after it succeeds; `a && cd x` or `a || cd x`
    may skip it. A list whose last pipeline fails ends the step under errexit (bash -e, GitHub's
    default), so its failing branch does not go on; with errexit off it does. Bash ignores errexit
    for everything to the left of && or ||, after !, and in an if/while/until condition, nested
    groups and subshells included. Inside a group or subshell it is not yet known whether the group
    is one of those, so a failing branch goes on there, marked with the group's depth: if that
    group, or one around it, turns out to be left of && or ||, or after !, the mark is cleared and
    the branch is real; at the top level a marked branch is dropped. In a condition nothing is
    marked. A failure bash does not exit for (left of && or ||, after !, in a condition) keeps that
    mark in its status, so a group that ends with one does not end the step either.

    errexit itself is known only while every path runs each `set -e` / `set +e`: one inside a group,
    or after && or ||, that changes it makes it unknown, and then no failing branch is dropped. A cd
    in a { ... } group that also holds a ! or a redirect, or with a redirect on the group, makes the
    directory after the group unknown (a conservative rule beside the model above).

    When a list ends, two possible directories make it unknown. A ( ... ) restores the directory at its matching ), across lines; a cd in a pipeline of
    two or more commands or in the background changes nothing."""

    def __init__(self, cwd: str | None, root: Path, errexit: bool | None = True) -> None:
        self.root = root
        self.errexit = errexit  # None: unknown
        # (cwd, status, dies). status is _OK, _FAILED (errexit applies) or _EXEMPT (a failure bash does
        # not exit for). dies is 0, or the depth of the outermost group a failure under errexit
        # happened in; that branch ended the step unless a group at that depth or above it turns out
        # to be left of && or ||, after ! or in a condition.
        self.states: tuple[tuple[str | None, int, int], ...] = ((cwd, _OK, 0),)
        self.risky = False  # this group holds a ! or a redirect
        self.moved = False  # the group just closed held a cd
        self.op: str | None = None  # "&&" or "||" before the next pipeline, None at a list's start
        self.tail: tuple[tuple, tuple, bool] | None = None  # the list's last pipeline: (outcomes, skipped, negated)
        self.frames: tuple[tuple, ...] = ()
        self.command: list[_Tok] = []
        self.group: tuple | None = None  # the states a { ... } or block just closed with
        self.ended: tuple = self.states  # the states the last list ended with, its last status kept
        self.ignore = False  # errexit is ignored here: in an if/while/until condition
        self.pipe: list[tuple[list[_Tok], tuple | None]] = []
        self.negate = False
        self.cds = 0  # cd commands read, so a block knows whether it held one
        self.condition = False  # inside [[ ... ]]: its operators are words
        self.lost = False

    def copy(self) -> "_Shell":
        other = _Shell.__new__(_Shell)
        other.__dict__.update(self.__dict__)
        other.command = list(self.command)
        other.pipe = list(self.pipe)
        return other

    @property
    def cwd(self) -> str | None:
        return self._collapse(self.states)

    def _collapse(self, states) -> str | None:
        found = {state[0] for state in states}
        return None if self.lost or len(found) != 1 else found.pop()

    def _merge(self, states, keep_status: bool = False) -> tuple:
        """One state per (dies) mark, or per (status, dies) with `keep_status`; two directories in one
        make it unknown."""
        out = []
        for ok, dies in dict.fromkeys((state[1] if keep_status else _OK, state[2]) for state in states):
            same = [s for s in states if s[2] == dies and (not keep_status or s[1] == ok)]
            out.append((self._collapse(same), ok, dies))
        return tuple(out)

    def _split(self) -> tuple[tuple, tuple]:
        """(states the next pipeline runs in, states that skip it), as (cwd, ok, dies)."""
        if self.op is None:
            return self.states, ()
        want = self.op == "&&"
        return tuple(s for s in self.states if (s[1] == _OK) == want), tuple(s for s in self.states if (s[1] == _OK) != want)

    def _in_block(self) -> bool:
        return any(frame[0] == "block" for frame in self.frames)

    def _end_command(self, upto):
        command, self.command = self.command, []
        group, self.group = self.group, None
        if not command and group is None:
            return _NOT_FOUND
        self.pipe.append((command, group))
        if upto is not None and command and upto(" ".join(tok.text for tok in command)):
            return self._collapse(self._split()[0])
        return _NOT_FOUND

    def _allowed(self, command: list[_Tok]) -> bool:
        """Whether this simple command is inside the grammar."""
        name, words = _command_name(command)
        if name is None:
            return True
        if "$" in name.raw or "`" in name.raw or name.text in _GIVES_UP:
            return False  # a computed name may be cd
        if name.text in ("builtin", "command") and set(words) & {"cd", "pushd", "popd", "eval", "source", "."}:
            return False
        if name.text == "exec" and words:
            return False
        if name.text == "shopt" and set(words) & {"cdable_vars", "autocd"}:
            return False
        return name.text != "trap" or set(words[1:]) <= _EXIT_TRAPS or words[:1] in (["-p"], ["-l"])

    def _outcomes(self, command: list[_Tok], cwd: str | None) -> list[tuple[str | None, bool]]:
        """A lone simple command's outcomes from `cwd`: it may succeed or fail; exit and return end
        the path; a cd that succeeds lands in its folder (None when this check cannot resolve it)."""
        name, _ = _command_name(command)
        if name is not None and name.text in ("exit", "return"):
            return []
        if name is None or name.text != "cd":
            return [(cwd, True), (cwd, False)]
        args = command[command.index(name) + 1 :]
        landed = None
        if len(args) == 1 and not self._in_block():
            arg = args[0]
            plain = not arg.text.startswith("-") and "`" not in arg.raw
            if plain and (arg.quoted or not _UNQUOTED_GLOB.search(arg.raw)):
                landed = _resolve_dir(arg.text, cwd, self.root)
        return [(landed, True), (cwd, False)]

    def _end_pipeline(self, background: bool = False, suppressed: bool = False) -> bool:
        """False when the check gives up. `suppressed`: the pipeline is left of && or ||."""
        pipe, self.pipe = self.pipe, []
        negated, self.negate = self.negate, False
        if not pipe:
            return True
        for command, group in pipe:
            if command and group is not None:
                return False  # words after a block or group
            if command and not self._allowed(command):
                return False
            name = _command_name(command)[0] if command else None
            self.cds += name is not None and name.text == "cd"
        runs, skipped = self._split()
        alone = len(pipe) == 1 and not background  # else each command runs in a subshell
        command, group = pipe[0]
        name, words = _command_name(command) if command else (None, [])
        if name is not None and name.text == "set":
            for flag, following in zip(words, [*words[1:], ""]):
                if re.fullmatch(r"[-+][A-Za-z]*e[A-Za-z]*", flag) or (flag in ("-o", "+o") and following == "errexit"):
                    value = flag.startswith("-")
                    every_path = alone and not self.frames and self.op is None and not self.ignore
                    # One that only some paths run (in a group, after && or ||) leaves it unknown.
                    self.errexit = value if every_path or self.errexit == value else None
        outcomes: list[tuple[str | None, bool]] = []
        for cwd, _, dies in dict.fromkeys(runs):
            if alone and group is not None:
                outcomes += group
            elif alone and command:
                outcomes += [(where, _OK if ok else _FAILED, dies) for where, ok in self._outcomes(command, cwd)]
            else:
                outcomes += [(cwd, _OK, dies), (cwd, _FAILED, dies)]
        depth = len(self.frames)
        if suppressed or negated:  # errexit was off for everything in there
            outcomes = [(cwd, ok, 0 if dies > depth else dies) for cwd, ok, dies in outcomes]
        elif depth == 0:  # it was on: the branches that failed in there ended the step
            outcomes = [state for state in outcomes if not state[2]]
        else:  # it was on in there; whether it is out here, the enclosing groups will say
            outcomes = [(cwd, ok, min(dies, depth)) for cwd, ok, dies in outcomes]
        if negated:  # its failure is one bash does not exit for
            outcomes = [(cwd, _EXEMPT if ok == _OK else _OK, dies) for cwd, ok, dies in outcomes]
        elif suppressed or self.ignore:
            outcomes = [(cwd, _EXEMPT if ok == _FAILED else ok, dies) for cwd, ok, dies in outcomes]
        self.tail = (tuple(outcomes), skipped, negated)
        self.states = tuple(dict.fromkeys([*outcomes, *skipped]))
        return True

    def _end_list(self) -> None:
        if self.tail is not None:
            outcomes, skipped, negated = self.tail
            if self.errexit and not self.ignore and not negated:  # a failing last pipeline ends the step
                if self.frames:  # unless a group around it turns out to be conditional: mark it
                    depth = len(self.frames)
                    outcomes = tuple(
                        (cwd, ok, min(dies or depth, depth) if ok == _FAILED else dies) for cwd, ok, dies in outcomes
                    )
                else:
                    outcomes = tuple(s for s in outcomes if s[1] != _FAILED)
            self.states = tuple(dict.fromkeys([*outcomes, *skipped]))
        self.tail = None
        self.ended = self._merge(self.states, keep_status=True)
        self.states = self._merge(self.states)
        self.op = None

    def _open(self, kind: str) -> None:
        runs = self._split()[0]
        saved = (
            self.states, self.op, self.tail, tuple(self.command), tuple(self.pipe), self.errexit, self.negate,
            self.cds, self.ended, self.ignore, self.risky,
        )
        self.frames += ((kind, saved),)
        self.risky = False
        self.states, self.op, self.tail = self._merge(runs), None, None
        self.ended = self.states
        self.command, self.pipe, self.negate = [], [], False

    def _close(self) -> None:
        kind, (states, op, tail, command, pipe, errexit, negate, cds, ended, ignore, risky) = self.frames[-1]
        self.frames = self.frames[:-1]
        inner_risky, self.risky = self.risky, risky or self.risky
        self.moved = self.cds != cds
        inner = self.ended
        start = self._merge(self._split_of(states, op))
        self.states, self.op, self.tail = states, op, tail
        self.command, self.pipe, self.negate, self.ended, self.ignore = list(command), list(pipe), negate, ended, ignore
        if kind == "sub":
            self.errexit = errexit
            self.command = [_SUBSHELL_COMMAND]  # it leaves the directory as it was
        elif kind == "block":  # if / loop: unknown after a cd inside, else as it started
            where = {cwd if self.cds == cds else None for cwd, _, _ in start}
            self.group = tuple((cwd, ok, dies) for cwd in where for ok in (_OK, _EXEMPT) for _, _, dies in start)
        elif inner_risky and self.moved:  # a cd beside a ! or a redirect: unknown, conservatively
            self.group = tuple((None, ok, dies) for _, ok, dies in inner)
        else:  # a { ... } group: the states its last list ended with (none when it ended the step)
            self.group = inner

    @staticmethod
    def _split_of(states, op) -> tuple:
        if op is None:
            return states
        return tuple(s for s in states if (s[1] == _OK) == (op == "&&"))

    def feed(self, line: str, upto=None) -> str | None:
        """Read one logical line. With `upto`, stop at the first command whose text `upto` accepts and
        return the directory it runs in; otherwise (or when none matches) the directory after the line."""
        if self.lost:
            return None
        toks = _shell_tokens(line)
        if toks is None or "CDPATH" in line:
            self.lost = True
            return None
        joined = bool(toks) and toks[-1].kind == "op" and toks[-1].text in ("&&", "||", "|", "|&")
        here_doc = False
        redirect = False
        end = _Tok("op", "\n", "\n", False, len(line), len(line))
        for at, tok in enumerate(toks if joined else [*toks, end]):
            if self.condition and tok is not end:
                self.command.append(tok)  # [[ ... ]]: one command, whatever it holds
                self.condition = not (tok.kind == "word" and not tok.quoted and tok.text == "]]")
                continue
            if tok.kind == "bad":
                self.lost = True  # an array, a function definition or a glob group
                return None
            if redirect:
                redirect = False
                if tok.kind == "word":
                    continue  # the redirection's target
                self.lost = True
                return None
            if tok.kind == "redir":
                self.risky = True
                if self.group is not None and not self.command:  # on a group or block: it may not run
                    start = self._merge(self._split()[0])
                    if self.moved:
                        self.group = tuple((None, ok, dies) for _, ok, dies in self.group) + ((None, _FAILED, 0),)
                    else:
                        self.group += tuple((cwd, _FAILED, dies) for cwd, _, dies in start)
                previous = self.command[-1] if self.command else None
                if previous is not None and previous.end == tok.start and previous.raw.isdigit():
                    self.command.pop()  # 2>&1: the 2 is the redirection's
                here_doc |= tok.text in ("<<", "<<-")
                redirect = True
                continue
            if tok.kind == "word":
                if not self._word(tok):
                    self.lost = True
                    return None
                continue
            if tok.text == "(":
                following = toks[at + 1] if at + 1 < len(toks) else None
                if self.command or self.group is not None or (following is not None and following.text == "(" and following.start == tok.end):
                    self.lost = True  # ( in an argument, or (( arithmetic ))
                    return None
                self._open("sub")
                continue
            if tok.text in (";;", ";&", ";;&") or (tok.text == ")" and not (self.frames and self.frames[-1][0] == "sub")):
                self.lost = True  # case, or a ) this check cannot place
                return None
            found = self._end_command(upto)
            if found is not _NOT_FOUND:
                return found
            if tok.text in ("|", "|&"):
                continue
            if not self._end_pipeline(background=tok.text == "&", suppressed=tok.text in ("&&", "||")):
                self.lost = True
                return None
            if tok.text in ("&&", "||"):
                self.op = tok.text
                continue
            self._end_list()
            if tok.text == ")":
                self._close()
        if redirect or self.condition:
            self.lost = True
        if here_doc:
            self.lost = True  # its body is not shell, and this check does not follow where it ends
        return self.cwd

    def _word(self, tok: _Tok) -> bool:
        """Read one word; False when the check gives up."""
        if self.command or self.group is not None:
            if self.group is not None:
                return False  # words after a block or group
            self.command.append(tok)
            return True
        if tok.quoted:
            self.command.append(tok)
            return True
        top = self.frames[-1][0] if self.frames else None
        word = tok.text
        if word in ("if", "while", "until", "for"):
            self._open("block")
            self.ignore = self.ignore or word != "for"  # a condition: errexit is ignored in it
        elif word in ("fi", "done"):
            if top != "block":
                return False
            self._close()
        elif word in ("then", "do", "else", "elif"):
            if top != "block":
                return False
            outer_ignore = self.frames[-1][1][-1]
            self.ignore = True if word == "elif" else outer_ignore
        elif word == "{":
            self._open("group")
        elif word == "}":
            if top != "group":
                return False
            self._close()
        elif word == "!":
            self.negate = not self.negate
            self.risky = True
        elif word == "time":
            pass
        elif word in _GIVES_UP:
            return False
        else:
            self.command.append(tok)
            self.condition = word == "[["
        return True


def _step_shell(doc: dict, job: dict, step: dict) -> bool | None:
    """Whether the step's shell stops at a failing command (GitHub runs bash and sh with -e unless the
    step, or the job's or workflow's defaults.run, names a shell command line without it), or None
    when the shell is not bash or sh (pwsh, python, cmd...): then the run is not shell text this
    check reads."""
    for scope, key in ((step, None), (job, "defaults"), (doc, "defaults")):
        if not isinstance(scope, dict):
            continue
        holder = scope if key is None else ((scope.get(key) or {}).get("run") or {})
        shell = holder.get("shell") if isinstance(holder, dict) else None
        if shell is not None:
            shell = str(shell).strip()
            if shell.split(" ", 1)[0].rsplit("/", 1)[-1] not in ("bash", "sh"):
                return None
            return shell in ("bash", "sh") or bool(re.search(r"\s-[A-Za-z]*e|\s-o\s+errexit", shell))
    return True


def _run_kind(text: str) -> str:
    if _RUN_MODULE.search(text):
        return "module"
    if _RUN_CODE.search(text):
        return "code"
    return "stdin" if _RUN_STDIN.search(text) else "script"


def _script_command(line: str, script: str, how: tuple[str, str] | None) -> str:
    """The command on this logical line that names `script` (the whole line if it does not lex)."""
    for command in _line_commands(line) or []:
        if _mentions(" ".join(command), script, how):
            return " ".join(command)
    return line


@lru_cache(maxsize=None)
def _run_lines(
    run: str, root: Path, start: str | None, errexit: bool = True
) -> tuple[tuple[str, str, str, _Shell], ...]:
    """(logical line, the line holding its command, how Python runs there, the shell before that line,
    a _Shell to copy and never change) per logical line of a run script. How: "module" (-m), "code" (-c), "stdin" (`python -`, `python <`, or
    the body of a heredoc fed to python, whose command line is the heredoc's), "text" (the body of
    another command's heredoc), else "script". Parsed once per step, not once per listed script."""
    return tuple(_run_lines_uncached(run, root, start, errexit))


def _run_lines_uncached(run: str, root: Path, start: str | None, errexit: bool = True):
    shell = _Shell(start, root, errexit)
    heredoc: tuple[str, str, _Shell] | None = None  # (delimiter, its python line, the shell there)
    for line in _logical_lines(run):
        if heredoc is not None:
            if line.strip() == heredoc[0]:
                heredoc = None
            elif heredoc[1]:
                yield line, heredoc[1], "stdin", heredoc[2]
            else:
                yield line, line, "text", heredoc[2]  # another command's heredoc: read as before
            continue
        kind = _run_kind(line)
        before = shell.copy()
        yield line, line, kind, before
        marker = _HEREDOC.search(line)
        if marker:
            # A heredoc fed to python is its program; any other command's heredoc is not shell either.
            heredoc = (marker.group(1), line if kind == "stdin" else "", before)
        shell.feed(line)


def pythonpath_dirs(value: object, root: Path, cwd: str | None = "") -> tuple[tuple[str, ...], list[str]]:
    """(repo folders, entries it cannot resolve) of one PYTHONPATH value. ${{ github.workspace }} and
    $GITHUB_WORKSPACE are the repo root; a relative entry is relative to `cwd`, the working directory
    Python starts in (an empty entry is that folder itself), as Python reads it; other expressions,
    variables, absolute paths, paths leaving the repo, and relative entries when `cwd` is unknown
    (None) cannot be resolved."""
    if value is None or not str(value).strip().strip("'\""):
        return (), []
    folders: list[str] = []
    bad: list[str] = []
    for raw in str(value).strip().strip("'\"").split(":"):
        part = raw.strip()
        anchored = _WORKSPACE.match(part)
        if anchored:
            part = part[anchored.end():].lstrip("/") or "."
        elif cwd is None:
            bad.append(raw.strip() or "(empty: the working directory)")
            continue
        else:
            part = os.path.join(cwd, part or ".") if cwd else part or "."
        if part.startswith("/") or "$" in part:
            bad.append(raw.strip())
            continue
        rel = os.path.normpath(part)
        if rel == ".." or rel.startswith("../"):
            bad.append(raw.strip())
            continue
        rel = "" if rel == "." else rel
        if rel not in folders and (root / rel).is_dir():
            folders.append(rel)
    return tuple(folders), bad


def _mentions(line: str, script: str, how: tuple[str, str] | None) -> bool:
    if script in line or re.search(rf"(?<![\w./-]){re.escape(script.rsplit('/', 1)[1])}(?![\w-])", line):
        return True
    return how is not None and how[0].removesuffix(".__main__") in _RUN_MODULE.findall(line)


def _logical_lines(run: str) -> list[str]:
    """A run script's lines as the shell reads them: a backslash at a line's end joins the next."""
    return re.sub(r"\\\r?\n", "", run).splitlines()


def _command_env(
    line: str, script: str, how: tuple[str, str] | None, needle: str | None = None
) -> dict[str, str] | None:
    """The VAR=value words before the command on this logical line that runs `script` (or, given
    `needle`, the first command containing it: the python a heredoc feeds) ({} if none, or no command
    on it names the script); None when the line does not lex."""
    commands = _line_commands(line)
    if commands is None:
        return None
    for command in commands:
        if not (needle in " ".join(command) if needle else _mentions(" ".join(command), script, how)):
            continue
        assigned: dict[str, str] = {}
        for word in command[1:] if command[:1] == ["env"] else command:
            if not _SHELL_ASSIGNMENT.match(word):
                break
            key, value = word.split("=", 1)
            assigned[key] = value
        return assigned
    return {}


def run_configs(
    doc: dict, job: dict, script: str, how: tuple[str, str] | None, root: Path
) -> tuple[list[tuple[tuple[str, ...], str, str | None]], list[str]]:
    """Each distinct (PYTHONPATH as repo folders, sys.path[0], working directory or None when it
    cannot be resolved) `script` runs with, and why any of it
    cannot be verified. For each run step whose script names `script` on a logical line (continuations
    joined), PYTHONPATH is a `PYTHONPATH=...` before that command, else the step's effective env; with
    no such step, the job's (workflow then job) env. sys.path[0] is the script's folder for `python
    script.py`; for `python -m`, `python -c` and Python reading stdin it is the working directory (the
    step's working-directory and the `cd`s before the command), as Python puts it there. A line naming
    the script that does not lex, a step that sets PYTHONPATH any other way (export, another
    command), a working directory this check cannot resolve, or a `python -m` whose module is in
    neither the working directory nor PYTHONPATH, cannot be verified."""
    values: list[tuple[object, str, str | None]] = []
    bad: list[str] = []
    default = default_base(script, how)
    for step in job.get("steps") or []:
        if not (isinstance(step, dict) and isinstance(step.get("run"), str)):
            continue
        consumed = 0
        named = False
        errexit = _step_shell(doc, job, step)
        start = _step_cwd(doc, job, step, root) if errexit is not None else None
        lines = _run_lines(step["run"], root, start, bool(errexit))
        for line, command_line, kind, shell in lines:
            if not _mentions(line, script, how):
                continue
            named = True
            text = kind == "text"
            if text:
                kind = "script"
            elif command_line == line:  # a command line: the command that names the script decides
                kind = _run_kind(_script_command(line, script, how))
            if kind == "module" and not (how and how[0].removesuffix(".__main__") in _RUN_MODULE.findall(line)):
                kind = "script"  # another module (pytest, unittest) runs the script: sys.path[0] as before
            names_it = (lambda c: "python" in c) if kind == "stdin" else (lambda c: _mentions(c, script, how))
            here = shell.cwd if text else shell.copy().feed(command_line, names_it)
            if kind == "script":
                base: str | None = default
            else:
                base = here
                if base is None:
                    flag = {"module": "-m", "code": "-c"}.get(kind, "reading stdin")
                    bad.append(f"runs with `python {flag}` from a working directory this check cannot resolve")
                    continue
            assigned = _command_env(command_line, script, how, None if kind != "stdin" else "python")
            if assigned is None:
                bad.append(f"runs from a line this check cannot parse: {line.strip()[:120]!r}")
                continue
            if "PYTHONPATH" in assigned:
                consumed += 1
                values.append((assigned["PYTHONPATH"], base, here))
            else:
                values.append((effective_env(doc, job, step).get("PYTHONPATH"), base, here))
        if named and step["run"].count("PYTHONPATH") > consumed:
            bad.append("runs in a step that sets or reads PYTHONPATH where this check cannot follow it")
    if not values:
        values.append((effective_env(doc, job).get("PYTHONPATH"), default, ""))
    configs: list[tuple[tuple[str, ...], str, str | None]] = []
    for value, base, here in values:
        folders, unresolved = pythonpath_dirs(value, root, here)
        bad += [
            f"runs with PYTHONPATH entry {entry!r}, which this check cannot resolve to a repo folder"
            for entry in unresolved
        ]
        if how and how[1] != base and how[1] not in folders:
            bad.append(
                f"runs as `python -m {how[0].removesuffix('.__main__')}` from {base or 'the repo root'}, "
                "where this check cannot find the module"
            )
            continue
        if (folders, base, here) not in configs:
            configs.append((folders, base, here))
    return configs, list(dict.fromkeys(bad))


def non_cone_sparse_steps(root: Path):
    """(workflow, job, step name, entries, workflow document, job) per actions/checkout step with a
    non-cone sparse list."""
    for path in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        jobs = doc.get("jobs") if isinstance(doc, dict) else None
        for job_id, job in (jobs or {}).items():
            job = job or {}
            for index, step in enumerate(job.get("steps") or []):
                if not isinstance(step, dict):
                    continue
                if not str(step.get("uses") or "").startswith("actions/checkout@"):
                    continue
                options = step.get("with") or {}
                raw = options.get("sparse-checkout")
                if raw is None:
                    continue
                cone = options.get("sparse-checkout-cone-mode")
                if not (cone is False or str(cone).strip().lower() == "false"):
                    continue
                name = str(step.get("name") or f"step {index}")
                yield path.name, str(job_id), name, sparse_entries(raw), doc, job


UNVERIFIABLE = "which this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"


def find_misses(root: Path, audit: dict[tuple[str, ...], str] | None = None) -> list[str]:
    """One line per (step, missing module), naming the module that imports it; one per (step, file,
    call) for an unaudited dynamic import in a listed script's closure, and per (step, script,
    entry) for a PYTHONPATH entry that cannot be resolved; one per stale audit entry."""
    root = root.resolve()
    audit = audit or {}
    audited = {normal_audit_key(key) for key in audit}
    frozen_audit = frozenset(audit)
    names = NameProof(root)  # one full-tree name index per run
    _run_lines.cache_clear()  # run steps parse once per run, never from an earlier one
    _tree_folders.cache_clear()
    memo: dict[tuple, tuple] = {}  # full_run results within this run
    misses = []
    ran_in: dict[str, set[str | None]] = {}  # file -> working directories its checked runs read it from
    for workflow, job_id, step, entries, doc, job in non_cone_sparse_steps(root):
        listed = listed_ci_scripts(entries, root)
        if not listed:
            continue
        prefix = f"{workflow} {job_id} {step}: "
        modules = _job_run_modules(job)
        runs = []  # (script, how, PYTHONPATH folders, sys.path[0], working directory)
        bad_paths: list[str] = []
        for script in listed:
            how = how_it_runs(script, modules)
            configs, bad = run_configs(doc, job, script, how, root)
            runs += [(script, how, extra, base, cwd) for extra, base, cwd in configs]
            bad_paths += [f"{prefix}{script} {why}" for why in bad]
        full = {}
        for run in runs:
            if run not in memo:
                memo[run] = full_run(root, run[0], run[2], run[1], frozen_audit, names, run[3], run[4])
            full[run] = memo[run]
            closure = [run[0], *(p for p in full[run][0].values() if not p.endswith("/"))]
            for rel in closure:
                ran_in.setdefault(rel, set()).add(run[4])
        files = set(listed)
        for places, *_ in full.values():
            files |= _files_for(places, root)
        # Files the list names stay too, so its patterns see the neighbours they see in the real tree.
        files |= {rel for rel in (e.lstrip("/") for e in entries if not e.startswith("!")) if rel and (root / rel).is_file()}
        present, sparse = sparse_runs(
            root,
            tuple(entries),
            frozenset(files),
            tuple((run, full[run][2], run[1][0] if run[1] else None, full[run][3]) for run in runs),
        )
        found: dict[str, tuple[str, str]] = {}  # missing place -> (importer's place, listed script)
        unverifiable: dict[tuple[str, str, str], tuple[int, str]] = {}  # (file, call, args) -> (line, script)
        unsettled: dict[str, str] = {}  # script -> the files its search trades
        for run in runs:
            script = run[0]
            if sparse[run] is None:
                continue  # excluded by a "!" entry: not checked out, nothing to run
            places, importer, _, _, calls = full[run]
            for rel, call, line, text in calls:
                key = (rel, call, text)
                if call == SEARCH_DOES_NOT_SETTLE:
                    unsettled.setdefault(rel, text)
                    continue
                if key not in audited and (key not in unverifiable or (rel == script and unverifiable[key][1] != rel)):
                    unverifiable[key] = (line, script)
            lost = {}
            for name, place in places.items():
                if sparse[run].get(name) == place:
                    continue
                checked_out = (
                    any(f.startswith(place) for f in present) if place.endswith("/") else place in present
                )
                if not checked_out:
                    lost[name] = place  # else run 2 never reached it: its importer is the miss
            for name, place in lost.items():
                if place.endswith("/") and any(p != place and p.startswith(place) for p in lost.values()):
                    continue  # a namespace folder: its missing modules say it
                by = importer.get(name, "__main__")
                by_place = script if by == "__main__" else places.get(by, by)
                # Prefer the shortest chain: an importer that is itself listed.
                if place not in found or (by_place == script and found[place][0] != found[place][1]):
                    found[place] = (by_place, script)
        for place, (by_place, script) in sorted(found.items()):
            misses.append(
                f"{prefix}{by_place} imports {place}, not in its sparse checkout"
                + ("" if by_place == script else f" (via {script})")
            )
        for (rel, call, text), (line, script) in sorted(unverifiable.items()):
            what = f"assigns sys.path ({text})" if call == SYS_PATH_ASSIGNMENT else f"calls {call}({text})"
            misses.append(
                f"{prefix}{rel} {what} (line {line}), {UNVERIFIABLE}" + ("" if rel == script else f" (via {script})")
            )
        misses += [f"{prefix}{rel} unverifiable: {SEARCH_DOES_NOT_SETTLE} ({what})" for rel, what in sorted(unsettled.items())]
        misses += sorted(set(bad_paths))
    return misses + stale_audit_entries(root, audit, ran_in)


# --- shell fixtures and the bash oracle -------------------------------------------------------
#
# Each shape: (run, errexit, script, the directory `python3 script` starts in by this check; None
# is unknown). The bash oracle below runs every one of them in bash itself.

_SHELL_FOLDERS = ("scripts/ci", "scripts/a", "lib")
_CI = "scripts/ci"
_SHELL_SHAPES: tuple[tuple[str, bool, str, str | None], ...] = (
    # Subshells end at their matching ), across lines and next to other operators.
    ("(\ncd scripts/ci\n)\npython3 x", True, "x", ""),
    ("(cd scripts/ci && true); python3 x", True, "x", ""),
    ("x=$(cd scripts/ci && pwd)\npython3 x", True, "x", ""),
    ("cd scripts && (cd ci && python3 x)", True, "x", _CI),
    # A failed cd inside a group goes on there if the group turns out to be left of && or ||, which
    # is not known yet where python runs inside it: unknown.
    ("cd scripts && (cd ci; python3 x)", True, "x", None),
    # A pipeline or & runs its commands in subshells.
    ("cd scripts/ci | cat\npython3 x", True, "x", ""),
    ("cd scripts/ci &\npython3 x", True, "x", ""),
    # Known: a cd that must have worked.
    ("cd scripts/ci\npython3 x", True, "x", _CI),
    ("cd scripts/ci; python3 x", True, "x", _CI),
    ("cd scripts/ci && python3 x", True, "x", _CI),
    ("cd scripts/ci &&\n  python3 x", True, "x", _CI),
    ("cd scripts/ci || exit 1\npython3 x", True, "x", _CI),
    ("{ cd scripts/ci; }\npython3 x", True, "x", _CI),
    ("cd \"scripts/ci\"\npython3 x", True, "x", _CI),
    ("cd ${{ github.workspace }}/scripts/ci\npython3 x", True, "x", _CI),
    ("if true; then echo; exit 1; fi\ncd scripts/ci\npython3 x", True, "x", _CI),
    ("for f in a b; do echo \"$f\"; done\npython3 x", True, "x", ""),
    ("cd scripts/ci 2>&1 > /dev/null\npython3 x", True, "x", _CI),
    ("! true\ncd scripts/ci\npython3 x", True, "x", _CI),
    # Unknown: a cd that may not have run.
    ("true || cd scripts/ci\npython3 x", True, "x", None),
    ("true && cd scripts/ci\npython3 x", True, "x", None),
    ("true && { cd scripts/ci; }\npython3 x", True, "x", None),
    ("! cd scripts/ci\npython3 x", True, "x", None),
    ("if true; then cd scripts/ci; fi\npython3 x", True, "x", None),
    ("if true; then\n  cd scripts/ci\nfi\npython3 x", True, "x", None),
    ("for d in a; do cd scripts/ci; done\npython3 x", True, "x", None),
    ("while false; do\n  cd scripts/ci\ndone\npython3 x", True, "x", None),
    # Review of #41035, F1: without errexit a failed cd goes on.
    ("set +e\ncd scripts/ci\npython3 x", True, "x", None),
    ("cd scripts/ci\npython3 x", False, "x", None),
    ("cd scripts/ci || exit 1\npython3 x", False, "x", _CI),
    ("set -e\ncd scripts/ci\npython3 x", False, "x", _CI),
    # F2: case (with or without a leading ( in its pattern) is outside the grammar.
    ("case a in (a) cd scripts/ci;; esac\npython3 x", True, "x", None),
    ("case a in a) cd scripts/ci;; esac\npython3 x", True, "x", None),
    ("case a in (b) true;; esac\npython3 x", True, "x", None),
    # F3: quoted punctuation is a word, never structure.
    ("echo '('\ncd scripts/ci\necho ')'\npython3 x", True, "x", _CI),
    ("echo \")\" ; cd scripts/ci\npython3 x", True, "x", _CI),
    ("echo \\( && true\ncd scripts/ci\npython3 x", True, "x", _CI),
    ("(echo ')'; cd scripts/ci)\npython3 x", True, "x", ""),
    ("echo '&&' || cd scripts/ci\npython3 x", True, "x", None),
    ("echo 'a;b' # ) ; cd scripts/ci\npython3 x", True, "x", ""),
    # Review of #41051, F2: errexit is off to the left of && and ||, after !, and in if/while/until
    # conditions, for everything nested there, so a failed cd inside goes on.
    ("{ cd scripts/ci > lib; :; } && python3 x", True, "x", None),
    ("{ cd scripts/ci > lib; :; } && true\npython3 x", True, "x", None),
    ("{ cd scripts/ci; :; } || true\npython3 x", True, "x", None),
    ("( { cd scripts/ci > lib; :; } && python3 x )", True, "x", None),
    ("( cd scripts/ci > lib; : ) && python3 x", True, "x", ""),
    ("{ ( cd scripts/ci; : ) && { cd scripts/ci > lib; :; }; } && python3 x", True, "x", None),
    ("{ { cd scripts/ci > lib; :; }; :; } && python3 x", True, "x", None),
    ("if { cd scripts/ci; false; }; then true; fi\npython3 x", True, "x", None),
    ("if { cd scripts/ci; false; }; then python3 x; fi", True, "x", None),
    ("while { cd scripts/ci; false; }; do true; done\npython3 x", True, "x", None),
    ("! { cd scripts/ci; }\npython3 x", True, "x", None),
    ("! { cd scripts/ci; false; }\npython3 x", True, "x", None),
    # ... and on everywhere else, nested groups included.
    ("{ cd scripts/ci; :; }\npython3 x", True, "x", _CI),
    ("{ { cd scripts/ci; }; :; }\npython3 x", True, "x", _CI),
    ("{ cd scripts/ci; } || exit 1\npython3 x", True, "x", _CI),
    ("if true; then { cd scripts/a; }; fi\npython3 x", True, "x", None),
    # Review of #41068 and the generative oracle's seeds at cc20acab: a group's status keeps whether
    # its failure was exempt from errexit, a set -e / +e that not every path runs leaves errexit
    # unknown, and a cd in a group that also has ! or a redirect is unknown.
    ("{ ! cd scripts/ci; }\npython3 x", True, "x", None),  # seed 15746
    ("{ cd scripts/ci > / && :; }\npython3 x", True, "x", None),
    ("{ ! : && cd scripts/a > /; } ; python3 x", True, "x", None),  # seed 17557
    ("{ ! cd .. && true; }\npython3 x", True, "x", None),  # seed 35154
    ("{ set -e && ! { ! { cd lib > /; }\n} && ( cd ci && true )\n}\npython3 x", True, "x", None),  # seed 38087
    ("set +e || set -e || set -e\ncd scripts/ci > /\npython3 x", True, "x", None),  # seed 46581
    ("true || { false || set -e; } && true\ncd lib > / ; python3 x", False, "x", None),  # seed 27650
    ("{ false && set -e && cd scripts/ci > /; }\npython3 x", False, "x", None),  # seed 40274
    ("{ cd scripts/ci && :; }\npython3 x", True, "x", None),
    ("{ cd scripts/ci && :; } || exit 1\npython3 x", True, "x", _CI),
    ("set +e\nset -e\ncd scripts/ci\npython3 x", True, "x", _CI),
    # Review of #41088: a compound command's own redirection failing is not a status ! inverts:
    # bash takes the || branch here.
    ("! { exit 1; } > / || cd scripts/ci\npython3 x", True, "x", None),
    # Outside the grammar: the directory is unknown from there on.
    ("go() { cd scripts/ci; }\npython3 x", True, "x", None),
    ("function go {\n  cd scripts/ci\n}\npython3 x", True, "x", None),
    ("go() { true; }\npython3 x", True, "x", None),
    ("arr=(a b)\npython3 x", True, "x", None),
    ("eval 'cd scripts/ci'\npython3 x", True, "x", None),
    ("source /dev/null\npython3 x", True, "x", None),
    (". /dev/null\npython3 x", True, "x", None),
    ("pushd scripts/ci\npython3 x", True, "x", None),
    ("popd\npython3 x", True, "x", None),
    ("builtin cd scripts/ci\npython3 x", True, "x", None),
    ("D=cd; $D scripts/ci\npython3 x", True, "x", None),
    ("$(echo cd) scripts/ci\npython3 x", True, "x", None),
    ("CDPATH=scripts cd ci\npython3 x", True, "x", None),
    ("(( 1 )) && cd scripts/ci\npython3 x", True, "x", None),
    ("[[ -d scripts/ci && 1 < 2 ]] && cd scripts/ci\npython3 x", True, "x", None),
    ("[[ \"$x\" =~ ^(a|b)$ ]] || true\ncd scripts/ci\npython3 x", True, "x", _CI),
    ("trap 'cd scripts/ci' ERR\npython3 x", True, "x", None),
    ("cat <<EOF\ncd scripts/ci\nEOF\npython3 x", True, "x", None),
    ("echo 'unclosed\npython3 x", True, "x", None),
    # Ones that stay known around constructs that look alike.
    ("trap 'rm -f t' EXIT\ncd scripts/ci\npython3 x", True, "x", _CI),
    ("command -v python3\ncd scripts/ci\npython3 x", True, "x", _CI),
    ("python3 - <<'EOF'\nprint(1)\nEOF", True, "-", ""),
    # The differential oracle's run shapes.
    ("cd scripts/ci && PYTHONPATH=lib python3 entry.py", True, "entry.py", _CI),
    ("cd scripts && PYTHONPATH=lib python3 -m ci.entry", True, "-m", "scripts"),
)
_OR_SHAPES: tuple[tuple[str, str, str | None], ...] = (
    ("cd scripts/ci && true || python3 x.py", "x.py", None),
    ("cd scripts/ci && python3 a.py || python3 b.py", "a.py", _CI),
    ("cd scripts/ci && python3 a.py || python3 b.py", "b.py", None),
    ("cd scripts/ci && python3 a.py || python3 b.py && python3 c.py", "c.py", None),
    ("cd scripts/ci && true || true\npython3 d.py", "d.py", None),
)


def _shell_cwds(run: str, root: Path, errexit: bool, script: str) -> list[str | None]:
    """The directory this check gives `python3 script` on each logical line that names it."""
    needle = f"python3 {script}"
    return [
        shell.copy().feed(line, lambda command: needle in command)
        for line, _, kind, shell in _run_lines_uncached(run, root, "", errexit)
        if needle in line and kind != "text"
    ]


_BASH_PRELUDE = r"""
exec 3>>"$__ORACLE_OUT"
__oracle_decide() {
  # The count lives in a file: command_not_found_handle and ( ... ) run in subshells.
  local i
  i=$(( $(<"$__ORACLE_N") + 1 ))
  echo "$i" > "$__ORACLE_N"
  if [ "$i" -gt 64 ]; then exit 97; fi
  echo "__STUB" >&3
  [ "${__ORACLE_BITS:i-1:1}" != 1 ]
}
python() { echo "__PY ${BASH_LINENO[0]} $PWD" >&3; __oracle_decide; }
kill() { __oracle_decide; }
exec() { __oracle_decide; }
ulimit() { __oracle_decide; }
python3() { echo "__PY ${BASH_LINENO[0]} $PWD" >&3; __oracle_decide; }
command_not_found_handle() { __oracle_decide; }
"""
_BASH_PATHS = 32  # paths per run at most: every success/failure mix up to 5 stubbed commands, else a sample
_PYTHON_CALL = re.compile(r"(?<![\w./$-])python3?(?![\w.-])")


def _bash_runs(run: str, root: Path, start: str, errexit: bool, bits: str, tmp: Path) -> tuple[int, list[tuple[int, str]]] | None:
    """Run `run` in bash from root/start, every command but bash's builtins stubbed (succeeding or
    failing by `bits`, one per call, then succeeding) and python/python3 reporting $PWD. Returns (stub
    calls, [(physical line, $PWD) per python call]), or None when it does not finish in 5 s."""
    out = tmp / f"out-{bits or 'none'}"
    out.write_text("")
    (tmp / "count").write_text("0")
    script = tmp / "run.sh"
    text = run.replace("${{ github.workspace }}", str(root))
    script.write_text(re.sub(r"\$\{\{.*?\}\}", "expr", text))
    empty = tmp / "path"
    empty.mkdir(exist_ok=True)
    env = {
        "PATH": str(empty), "HOME": str(tmp), "BASH_ENV": str(tmp / "prelude.sh"), "__ORACLE_OUT": str(out), "__ORACLE_N": str(tmp / "count"),
        "__ORACLE_BITS": bits, "GITHUB_WORKSPACE": str(root), "GITHUB_OUTPUT": str(tmp / "gh-out"),
        "GITHUB_ENV": str(tmp / "gh-env"), "GITHUB_STEP_SUMMARY": str(tmp / "gh-summary"), "GITHUB_PATH": str(tmp / "gh-path"),
    }
    (tmp / "prelude.sh").write_text(_BASH_PRELUDE)
    flags = ["-e"] if errexit else []
    try:
        subprocess.run(
            [_BASH, "--noprofile", "--norc", *flags, str(script)], cwd=root / start, env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
            start_new_session=True,
        )
    except subprocess.TimeoutExpired:
        return None
    calls, seen = 0, []
    for line in out.read_text(errors="replace").splitlines():
        if line == "__STUB":
            calls += 1
        elif line.startswith("__PY "):
            _, number, pwd = line.split(" ", 2)
            seen.append((int(number), pwd))
    return calls, seen


_BASH = shutil.which("bash") or "/bin/bash"
_bash_oracle_plant = False  # test hook, see test_fixture_bash_oracle_catches_a_wrong_known_directory


def _bit_paths(calls: int) -> list[str]:
    if 2 ** calls <= _BASH_PATHS:
        return [format(n, f"0{calls}b") if calls else "" for n in range(2 ** calls)]
    paths = ["", "1" * calls]
    paths += ["0" * k + "1" for k in range(calls)]
    paths += ["1" * k + "0" for k in range(1, calls)]
    return list(dict.fromkeys(paths))[:_BASH_PATHS]


def bash_oracle_case(case: tuple[str, str, bool, frozenset[str], str]) -> list[tuple[str, str]]:
    """(outcome, detail) per logical line of one run that calls python in bash: "agree" (this check's
    known directory is where bash ran python on every path), "unknown" (this check gives None),
    "skipped" (more than one python call on the line), "timeout", or "disagree" with the details."""
    label, run, errexit, folders, start = case
    out: list[tuple[str, str]] = []
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name).resolve()
        root = tmp / "repo"
        for folder in {*folders, start}:
            (root / folder).mkdir(parents=True, exist_ok=True)
        first = _bash_runs(run, root, start, errexit, "", tmp)
        if first is None:
            return [("timeout", label)]
        observed: dict[int, set[str]] = {}
        for bits in _bit_paths(first[0]):
            result = first if bits == "" else _bash_runs(run, root, start, errexit, bits, tmp)
            if result is None:
                out.append(("timeout", f"{label} bits {bits}"))
                continue
            for number, pwd in result[1]:
                rel = os.path.relpath(pwd, root)
                observed.setdefault(number, set()).add("" if rel == "." else rel if not rel.startswith("..") else "<outside>")
        physical: dict[int, int] = {}
        logical = 0
        for number, text in enumerate(run.split("\n"), 1):
            physical[number] = logical
            if not text.endswith("\\"):
                logical += 1
        lines = list(_run_lines_uncached(run, root, start, errexit))
        by_line: dict[int, set[str]] = {}
        for number, places in observed.items():
            by_line.setdefault(physical.get(number, -1), set()).update(places)
        for index, places in sorted(by_line.items()):
            if not 0 <= index < len(lines):
                out.append(("skipped", f"{label}: line {index}"))
                continue
            line, _, kind, shell = lines[index]
            if kind == "text" or len(_PYTHON_CALL.findall(line)) != 1:
                out.append(("skipped", f"{label}: {line.strip()[:80]}"))
                continue
            checked = shell.copy().feed(line, lambda command: bool(_PYTHON_CALL.search(command)))
            if _bash_oracle_plant and checked is not None:
                checked = "<planted>"  # test hook: a checker that is wrong wherever it knows
            if checked is None:
                out.append(("unknown", label))
            elif places == {checked}:
                out.append(("agree", label))
            else:
                out.append(("disagree", f"{label}: {line.strip()[:80]!r}: this check {checked!r}, bash {sorted(places)}"))
    return out


def bash_oracle_cases(root: Path | None = None) -> list[tuple[str, str, bool, frozenset[str], str]]:
    """Every shell fixture in this file, and, given the repo `root`, every workflow run step in bash
    or sh that calls python and changes folder (its folders and working directory as in the repo)."""
    folders = frozenset(_SHELL_FOLDERS)
    cases = [(f"shape {run!r}", run, errexit, folders, "") for run, errexit, _, _ in _SHELL_SHAPES]
    cases += [(f"or {run!r}", run, True, folders, "") for run in dict.fromkeys(r for r, _, _ in _OR_SHAPES)]
    if root is None:
        return cases
    repo_folders = frozenset(
        rel.rsplit("/", 1)[0] for rel in _tree_files(root) if "/" in rel
    )
    for path in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job_id, job in ((doc.get("jobs") or {}) if isinstance(doc, dict) else {}).items():
            for index, step in enumerate((job or {}).get("steps") or []):
                run = step.get("run") if isinstance(step, dict) else None
                if not isinstance(run, str) or not _PYTHON_CALL.search(run):
                    continue
                if not re.search(r"\b(?:cd|pushd|popd)\b|\(", run):
                    continue
                errexit = _step_shell(doc, job or {}, step)
                start = _step_cwd(doc, job or {}, step, root)
                if errexit is None or start is None:
                    continue
                folders = frozenset(f for f in repo_folders if f in run)
                cases.append((f"{path.name} {job_id} step {index}", run, errexit, folders, start))
    return cases


def run_bash_oracle(cases) -> tuple[Counter, list[str]]:
    import multiprocessing
    from concurrent.futures import ProcessPoolExecutor

    counts: Counter = Counter()
    disagreements: list[str] = []
    workers = max(1, os.cpu_count() or 1)
    with ProcessPoolExecutor(workers, mp_context=multiprocessing.get_context("fork")) as pool:
        for results in pool.map(bash_oracle_case, cases, chunksize=4):
            if not results:
                counts["unreached"] += 1  # bash never ran python on any path
            for outcome, detail in results:
                counts[outcome] += 1
                if outcome == "disagree":
                    disagreements.append(detail)
    return counts, disagreements


# --- generated shell programs -------------------------------------------------------------------
#
# Review of #41068, round five of review-found bash disagreements: random programs from a small
# grammar go through the bash oracle, so a gap shows up here before a review finds it. The grammar
# composes cd (to folders that exist, do not exist, or lie outside the repo), !, { } groups,
# ( ) subshells, &&, ||, ;, if / else, a redirect that always fails (> /), set -e / set +e and the
# builtins true, false and :, nested up to depth 3, one python3 call somewhere in it, under bash
# with and without -e. Review of #41088: exit and exit 1 too, a while false loop, and a redirect on a
# compound command itself ({ }, ( ), if, while), one that fails (> /) or not (> /dev/null), so a
# compound's own redirection failing is in the grammar, under ! included. Every command but python is a builtin, so bash takes one path per python
# status. Seeds are fixed, so a disagreement reproduces from its seed.

GENERATED_SHELL_SEEDS = int(os.environ.get("SPARSE_SHELL_SEEDS", "20000"))
_GEN_TARGETS = ("scripts/ci", "scripts", "ci", "lib", "missing", "..", "scripts/a")
_GEN_SIMPLE = (
    "true", "false", ":", "cd {d}", "cd {d}", "cd {d}", "cd {d} > /", ": > /", "set -e", "set +e",
    "exit", "exit 1",
)
_GEN_REDIRECTS = ("", "", "", " > /", " > /dev/null")


def _generated_shell(seed: int) -> tuple[str, bool]:
    """(run script, errexit) for one seed: one python3 call in a random program of the grammar."""
    import random

    rng = random.Random(seed)

    def sep(newline_ok: bool = True) -> str:
        return "\n" if newline_ok and rng.random() < 0.3 else "; "

    def body(depth: int, most: int) -> str:
        # Sometimes a body that always leaves (every path ends in exit), the case a redirect on the
        # compound around it matters most for.
        if rng.random() < 0.15:
            return rng.choice(("exit", "exit 1", "false || exit 1", "exit 1 && true"))
        return and_or_list(depth, most)

    def command(depth: int) -> str:
        r = rng.random()
        if depth < 3 and r < 0.15:
            return "{ " + body(depth + 1, 3) + sep() + "}" + rng.choice(_GEN_REDIRECTS)
        if depth < 3 and r < 0.27:
            return "( " + body(depth + 1, 3) + " )" + rng.choice(_GEN_REDIRECTS)
        if depth < 3 and r < 0.35:
            text = "if " + and_or_list(depth + 1, 2) + sep() + "then " + and_or_list(depth + 1, 3)
            if rng.random() < 0.4:
                text += sep() + "else " + and_or_list(depth + 1, 3)
            return text + sep() + "fi" + rng.choice(_GEN_REDIRECTS)
        # if / while bodies use and_or_list: a body() there would end the program on most paths.
        if depth < 3 and r < 0.38:
            return "while false; do " + and_or_list(depth + 1, 2) + sep() + "done" + rng.choice(_GEN_REDIRECTS)
        return "\0"

    def pipeline(depth: int) -> str:
        text = command(depth)
        return ("! " + text) if rng.random() < 0.2 else text

    def and_or_list(depth: int, most: int) -> str:
        parts = [pipeline(depth)]
        for _ in range(rng.randint(0, most - 1)):
            parts += [rng.choice(("&&", "||", "&&", "||", ";")), pipeline(depth)]
        return " ".join(parts)

    lines = [and_or_list(0, 3) for _ in range(rng.randint(1, 4))]
    text = "\n".join(lines)
    slots = text.count("\0")
    # Half the time python runs on a line of its own at the end, where everything before it counts.
    python = rng.randrange(slots) if slots and rng.random() < 0.5 else -1
    out, index = [], 0
    for chunk in text.split("\0")[:-1]:
        out.append(chunk)
        if index == python:
            out.append("python3 x")
        else:
            choice = rng.choice(_GEN_SIMPLE)
            if choice.startswith("exit") and rng.random() < 0.5:
                choice = "true"  # exit, but not so often that python is rarely reached
            out.append(choice.format(d=rng.choice(_GEN_TARGETS)))
        index += 1
    out.append(text.split("\0")[-1])
    run = "".join(out)
    if python == -1:
        run += "\npython3 x"
    if not run.endswith("\n"):
        run += "\n"
    return run, rng.random() < 0.75


def generated_shell_cases(seeds: int, start: int = 0) -> list[tuple[str, str, bool, frozenset[str], str]]:
    folders = frozenset(_SHELL_FOLDERS)
    cases = []
    for seed in range(start, start + seeds):
        run, errexit = _generated_shell(seed)
        cases.append((f"seed {seed} (errexit {'on' if errexit else 'off'}) {run!r}", run, errexit, folders, ""))
    return cases


# --- tests ------------------------------------------------------------------------------------


class SparseCheckoutImportTests(unittest.TestCase):
    def test_workflows_list_every_imported_ci_module(self) -> None:
        steps = list(non_cone_sparse_steps(ROOT))
        self.assertTrue(steps, "expected at least one non-cone sparse checkout in .github/workflows")
        misses = find_misses(ROOT, DYNAMIC_IMPORT_AUDIT)
        self.assertEqual(misses, [], "\n" + "\n".join(misses))

    def _fixture(
        self,
        tmp: Path,
        sparse: str,
        job_env: str = "",
        run: str = "true",
        wf_env: str = "",
        run_env: str = "",
        more: dict[str, str] | None = None,
    ) -> Path:
        files = {
            "scripts/ci/runner.py": "import sys\nsys.path.insert(0, '.')\nfrom helper import go\n",
            "scripts/ci/helper.py": "def go():\n    import deadline_http\n    return deadline_http\n",
            "scripts/ci/deadline_http.py": "import urllib.request\n",
            "scripts/ci/optional_user.py": "try:\n    import extra\nexcept ImportError:\n    extra = None\n",
            "scripts/ci/extra.py": "",
            "scripts/ci/sub/step.py": "import local_helper\nimport deadline_http\n",
            "scripts/ci/sub/local_helper.py": "",
            "scripts/ci/pkg_user.py": "import pkg\n",
            "scripts/ci/pkg/__init__.py": "from . import helper\n",
            "scripts/ci/pkg/helper.py": "from .deep import z\n",
            "scripts/ci/pkg/deep.py": "z = 1\n",
            # F1: inside pkg/, a plain `import helper` loads scripts/ci/helper.py (the entry script's
            # folder is sys.path[0]), not pkg/helper.py.
            "scripts/ci/f1_entry.py": "import pkg.runner\n",
            "scripts/ci/pkg/runner.py": "import helper\n",
            # F2: a namespace package (no __init__.py).
            "scripts/ci/ns_user.py": "from nspkg import tool\n",
            "scripts/ci/nspkg/tool.py": "from . import util\n",
            "scripts/ci/nspkg/util.py": "",
            # F3: run as `python -m mpkg.main`, so mpkg/__init__.py loads before main's relative import.
            "scripts/ci/mpkg/__init__.py": "",
            "scripts/ci/mpkg/main.py": "from .helper import go\n",
            "scripts/ci/mpkg/helper.py": "def go():\n    return 1\n",
            # Dynamic imports: one this check cannot follow, and a fixed sys.path insert it learns.
            "scripts/ci/dyn.py": "import importlib\nmod = importlib.import_module('helper')\n",
            "scripts/ci/lit.py": (
                "import sys\nfrom pathlib import Path\n"
                "HERE = Path(__file__).resolve()\n"
                "sys.path.insert(0, str(HERE.parents[1]))\n"
                "import toplib\n"
            ),
            "scripts/toplib.py": "",
            "scripts/ci/varpath.py": "import sys, os\nsys.path.append(os.environ['X'])\n",
            "scripts/ci/dyn2.py": (
                "import importlib\na = importlib.import_module('helper')\nb = importlib.import_module('extra')\n"
            ),
            "scripts/ci/dyn_ws.py": 'import importlib\nmod = importlib.import_module(  "helper"  )\n',
            "scripts/ci/loader.py": (
                "import importlib.util\nfrom pathlib import Path\n"
                "spec = importlib.util.spec_from_file_location('k', Path(__file__).with_name('loaded-by-path.py'))\n"
            ),
            "scripts/ci/loaded-by-path.py": "import deadline_http\n",
            # PYTHONPATH: the step's env overrides the workflow's; github.workspace is the repo root.
            "scripts/ci/pp_user.py": "import pphelper\n",
            "scripts/defaults/pphelper.py": "",
            "scripts/actual/pphelper.py": "",
            "scripts/ci/ws_user.py": "import ws_mod\n",
            "ws_mod.py": "",
            # Codex's four holes in what the check learns.
            "scripts/ci/order.py": (
                "import sys\nsys.path.insert(0, 'scripts/first')\nsys.path.insert(0, 'scripts/second')\nimport ordmod\n"
            ),
            "scripts/first/ordmod.py": "",
            "scripts/second/ordmod.py": "",
            "scripts/ci/tryload.py": (
                "import importlib.util\nfrom pathlib import Path\n"
                "try:\n"
                "    spec = importlib.util.spec_from_file_location('t', Path(__file__).with_name('tried.py'))\n"
                "except ImportError:\n"
                "    spec = None\n"
            ),
            "scripts/ci/tried.py": "",
            "scripts/ci/rebind.py": (
                "import sys\nP = 'scripts/a'\nP += 'b'\nsys.path.insert(0, P)\nimport rbmod\n"
            ),
            "scripts/a/rbmod.py": "",
            "scripts/ab/rbmod.py": "",
            # Follow-ups to #40876: call order, scope and a search that does not settle.
            "scripts/ci/fnorder.py": (
                "import sys\n"
                "def add_b():\n    sys.path.insert(0, 'scripts/b')\n"
                "def add_a():\n    sys.path.insert(0, 'scripts/a')\n"
                "add_a()\nadd_b()\nimport ordmod2\n"
            ),
            "scripts/a/ordmod2.py": "",
            "scripts/b/ordmod2.py": "",
            "scripts/ci/xfile.py": "import sys\nimport xside\nsys.path.insert(0, 'scripts/a')\nimport ordmod2\n",
            "scripts/ci/xside.py": "import sys\nsys.path.insert(0, 'scripts/b')\n",
            "scripts/ci/star.py": (
                "import sys\nfrom starconf import *\n"
                "def f():\n    P = 'scripts/a'\n    return P\n"
                "sys.path.insert(0, P)\nimport ordmod2\n"
            ),
            "scripts/ci/starconf.py": "P = 'scripts/b'\n",
            "scripts/ci/osc_entry.py": "import oschelper\n",
            "scripts/ci/oschelper.py": "import sys\nsys.path.insert(0, 'scripts/alternate')\n",
            "scripts/alternate/oschelper.py": "",
        }
        files.update(more or {})
        for rel, body in files.items():
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (tmp / rel).write_text(body, encoding="utf-8")
        workflow = tmp / ".github" / "workflows" / "w.yml"
        workflow.parent.mkdir(parents=True, exist_ok=True)
        workflow.write_text(
            textwrap.dedent(
                """\
                on: push
                WF_ENV
                jobs:
                  run:
                    runs-on: ubuntu-latest
                    JOB_ENV
                    steps:
                      - name: Check out
                        uses: actions/checkout@v4
                        with:
                          sparse-checkout: SPARSE
                          sparse-checkout-cone-mode: false
                      - name: Cone checkout is not checked
                        uses: actions/checkout@v4
                        with:
                          sparse-checkout: scripts/ci/runner.py
                      - run: RUN
                        RUN_ENV
                """
            )
            .replace("SPARSE", sparse)
            .replace("JOB_ENV", job_env)
            .replace("RUN_ENV", run_env)
            .replace("RUN", run)
            .replace("WF_ENV", wf_env),
            encoding="utf-8",
        )
        return tmp

    def _misses(
        self,
        sparse: str,
        job_env: str = "",
        run: str = "true",
        audit=None,
        wf_env: str = "",
        run_env: str = "",
        more: dict[str, str] | None = None,
    ) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            return find_misses(self._fixture(Path(tmp), sparse, job_env, run, wf_env, run_env, more), audit)

    def block(self, *lines: str) -> str:
        return "|\n" + "\n".join(" " * 12 + line for line in lines)

    def test_fixture_reports_a_missing_transitive_import(self) -> None:
        # runner imports helper at load; helper imports deadline_http lazily inside a function.
        self.assertEqual(
            self._misses(self.block("scripts/ci/runner.py")),
            [
                "w.yml run Check out: scripts/ci/helper.py imports scripts/ci/deadline_http.py, "
                "not in its sparse checkout (via scripts/ci/runner.py)",
                "w.yml run Check out: scripts/ci/runner.py imports scripts/ci/helper.py, not in its sparse checkout",
            ],
        )
        self.assertEqual(
            self._misses(self.block("scripts/ci/runner.py", "scripts/ci/helper.py")),
            [
                "w.yml run Check out: scripts/ci/helper.py imports scripts/ci/deadline_http.py, "
                "not in its sparse checkout"
            ],
        )

    def test_fixture_reports_a_missing_direct_import(self) -> None:
        misses = self._misses("/scripts/ci/runner.py")  # one line, leading slash
        self.assertIn(
            "w.yml run Check out: scripts/ci/runner.py imports scripts/ci/helper.py, not in its sparse checkout",
            misses,
        )
        self.assertEqual(len(misses), 2, misses)

    def test_fixture_passes_once_listed(self) -> None:
        self.assertEqual(
            self._misses(self.block("/scripts/ci/runner.py", "scripts/ci/helper.py", "scripts/ci/deadline_http.py")),
            [],
        )

    def test_fixture_passes_with_directory_entries(self) -> None:
        for entry in ("scripts/ci", "scripts/", "/scripts/ci/", "/*", "scripts/ci/*.py"):
            with self.subTest(entry=entry):
                self.assertEqual(self._misses(self.block("scripts/ci/runner.py", entry)), [])

    def test_fixture_exclusion_uncovers_a_module(self) -> None:
        misses = self._misses(self.block("/scripts/ci/runner.py", "/*", "!scripts/ci/deadline_http.py"))
        self.assertTrue(any("imports scripts/ci/deadline_http.py" in m for m in misses), misses)

    def test_fixture_subdir_script_resolves_own_folder_then_pythonpath(self) -> None:
        # Run as a script, sub/step.py searches its own folder; scripts/ci only when PYTHONPATH says so.
        self.assertEqual(
            self._misses(self.block("scripts/ci/sub/step.py")),
            ["w.yml run Check out: scripts/ci/sub/step.py imports scripts/ci/sub/local_helper.py, not in its sparse checkout"],
        )
        for env in ("env: {PYTHONPATH: scripts/ci}", "env: {PYTHONPATH: '${{ github.workspace }}/scripts/ci'}"):
            with self.subTest(env=env):
                misses = self._misses(self.block("scripts/ci/sub/step.py"), env)
                self.assertEqual(
                    sorted(m.split(": ", 1)[1] for m in misses),
                    [
                        "scripts/ci/sub/step.py imports scripts/ci/deadline_http.py, not in its sparse checkout",
                        "scripts/ci/sub/step.py imports scripts/ci/sub/local_helper.py, not in its sparse checkout",
                    ],
                )
                self.assertEqual(self._misses(self.block("scripts/ci/sub/", "scripts/ci/deadline_http.py"), env), [])

    def test_fixture_exclusion_before_a_directory_include_still_excludes(self) -> None:
        # Git matches the file before its parent folders, so "!helper" beats the later "dir/".
        self.assertEqual(
            self._misses(self.block("scripts/ci/runner.py", "!scripts/ci/helper.py", "scripts/ci/")),
            ["w.yml run Check out: scripts/ci/runner.py imports scripts/ci/helper.py, not in its sparse checkout"],
        )

    def test_fixture_follows_relative_imports_transitively(self) -> None:
        # pkg_user imports pkg; pkg/__init__.py does `from . import helper`; helper does `from .deep import z`.
        self.assertEqual(
            self._misses(self.block("scripts/ci/pkg_user.py", "/scripts/ci/pkg/*", "!scripts/ci/pkg/deep.py")),
            [
                "w.yml run Check out: scripts/ci/pkg/helper.py imports scripts/ci/pkg/deep.py, "
                "not in its sparse checkout (via scripts/ci/pkg_user.py)"
            ],
        )
        listed = ("scripts/ci/pkg_user.py", "scripts/ci/pkg/__init__.py", "scripts/ci/pkg/helper.py")
        self.assertEqual(
            self._misses(self.block(*listed)),
            [
                "w.yml run Check out: scripts/ci/pkg/helper.py imports scripts/ci/pkg/deep.py, "
                "not in its sparse checkout (via scripts/ci/pkg_user.py)"
            ],
        )
        self.assertEqual(self._misses(self.block(*listed, "scripts/ci/pkg/deep.py")), [])
        self.assertEqual(self._misses(self.block("scripts/ci/pkg_user.py", "scripts/ci/pkg/")), [])

    def test_fixture_skips_imports_guarded_by_import_error(self) -> None:
        self.assertEqual(self._misses(self.block("scripts/ci/optional_user.py")), [])

    def test_fixture_f1_plain_import_in_a_package_resolves_from_the_entry_folder(self) -> None:
        # pkg/runner.py's `import helper` is scripts/ci/helper.py; pkg/helper.py (checked out) is not it.
        self.assertEqual(
            self._misses(self.block("scripts/ci/f1_entry.py", "scripts/ci/pkg/")),
            [
                "w.yml run Check out: scripts/ci/helper.py imports scripts/ci/deadline_http.py, "
                "not in its sparse checkout (via scripts/ci/f1_entry.py)",
                "w.yml run Check out: scripts/ci/pkg/runner.py imports scripts/ci/helper.py, "
                "not in its sparse checkout (via scripts/ci/f1_entry.py)",
            ],
        )
        listed = ("scripts/ci/f1_entry.py", "scripts/ci/pkg/", "scripts/ci/helper.py", "scripts/ci/deadline_http.py")
        self.assertEqual(self._misses(self.block(*listed)), [])

    def test_fixture_f2_namespace_package_without_init(self) -> None:
        self.assertEqual(
            self._misses(self.block("scripts/ci/ns_user.py")),
            [
                "w.yml run Check out: scripts/ci/ns_user.py imports scripts/ci/nspkg/tool.py, not in its sparse checkout",
                "w.yml run Check out: scripts/ci/nspkg/tool.py imports scripts/ci/nspkg/util.py, "
                "not in its sparse checkout (via scripts/ci/ns_user.py)",
            ],
        )
        self.assertEqual(
            self._misses(self.block("scripts/ci/ns_user.py", "scripts/ci/nspkg/tool.py")),
            [
                "w.yml run Check out: scripts/ci/nspkg/tool.py imports scripts/ci/nspkg/util.py, "
                "not in its sparse checkout (via scripts/ci/ns_user.py)"
            ],
        )
        self.assertEqual(self._misses(self.block("scripts/ci/ns_user.py", "scripts/ci/nspkg/")), [])

    def test_fixture_dynamic_import_is_unverifiable_unless_audited(self) -> None:
        listed = self.block("scripts/ci/dyn.py", "scripts/ci/helper.py", "scripts/ci/deadline_http.py")
        self.assertEqual(
            self._misses(listed),
            [
                "w.yml run Check out: scripts/ci/dyn.py calls importlib.import_module('helper') (line 2), which "
                "this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
            ],
        )
        audit = {("scripts/ci/dyn.py", "importlib.import_module", "'helper'"): "loads helper.py, listed beside it"}
        self.assertEqual(self._misses(listed, audit=audit), [])

    def test_fixture_audit_names_one_call_not_a_kind(self) -> None:
        # dyn2.py makes two import_module calls; the entry for one leaves the other unverifiable.
        listed = self.block("scripts/ci/dyn2.py", "scripts/ci/helper.py", "scripts/ci/deadline_http.py")
        audit = {("scripts/ci/dyn2.py", "importlib.import_module", "'helper'"): "loads helper.py, listed beside it"}
        self.assertEqual(
            self._misses(listed, audit=audit),
            [
                "w.yml run Check out: scripts/ci/dyn2.py calls importlib.import_module('extra') (line 3), which "
                "this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
            ],
        )

    def test_fixture_an_edited_audited_call_makes_its_entry_stale(self) -> None:
        # The entry was written for import_module('other'); the file now calls import_module('helper').
        listed = self.block("scripts/ci/dyn.py", "scripts/ci/helper.py", "scripts/ci/deadline_http.py")
        audit = {("scripts/ci/dyn.py", "importlib.import_module", "'other'"): "loads other.py"}
        self.assertEqual(
            self._misses(listed, audit=audit),
            [
                "w.yml run Check out: scripts/ci/dyn.py calls importlib.import_module('helper') (line 2), which "
                "this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT",
                "DYNAMIC_IMPORT_AUDIT: scripts/ci/dyn.py importlib.import_module('other'): no call in "
                "scripts/ci/dyn.py matches it; re-check the call and the entry",
            ],
        )

    def test_fixture_whitespace_and_quotes_do_not_change_the_audit_match(self) -> None:
        # dyn.py writes import_module('helper'), dyn_ws.py import_module(  "helper"  ); one spelling
        # of the entry matches both, and so does a spelling with other spaces and quotes.
        for script in ("scripts/ci/dyn.py", "scripts/ci/dyn_ws.py"):
            for text in ("'helper'", '  "helper" '):
                with self.subTest(script=script, text=text):
                    listed = self.block(script, "scripts/ci/helper.py", "scripts/ci/deadline_http.py")
                    audit = {(script, "importlib.import_module", text): "loads helper.py, listed beside it"}
                    self.assertEqual(self._misses(listed, audit=audit), [])

    def test_fixture_stale_audit_entries_fail(self) -> None:
        listed = self.block("scripts/ci/dyn.py", "scripts/ci/helper.py", "scripts/ci/deadline_http.py")
        audit = {
            ("scripts/ci/dyn.py", "importlib.import_module", "'helper'"): "loads helper.py, listed beside it",
            ("scripts/ci/dyn.py", "runpy.run_path", "'x.py'"): "a call the file does not make",
            ("scripts/ci/dyn.py", "scripts/ci/nothing.py"): "a load the file does not make",
            ("scripts/ci/gone.py", "importlib.import_module", "'helper'"): "a file that does not exist",
        }
        self.assertEqual(
            self._misses(listed, audit=audit),
            [
                "DYNAMIC_IMPORT_AUDIT: scripts/ci/dyn.py runpy.run_path('x.py'): no call in scripts/ci/dyn.py "
                "matches it; re-check the call and the entry",
                "DYNAMIC_IMPORT_AUDIT: scripts/ci/dyn.py scripts/ci/nothing.py: no call in scripts/ci/dyn.py "
                "matches it; re-check the call and the entry",
                "DYNAMIC_IMPORT_AUDIT: scripts/ci/gone.py importlib.import_module('helper'): the file is gone, "
                "drop the entry",
            ],
        )

    VENDOR = {
        "scripts/ci/vend.py": (
            "import importlib.util\n"
            "try:\n"
            "    spec = importlib.util.spec_from_file_location('v', 'vendor/x.py')\n"
            "except ImportError:\n"
            "    spec = None\n"
        ),
        "scripts/ci/vendor/x.py": "",
    }

    def test_fixture_review_41012_f2_an_audit_entry_is_read_from_the_run_working_directory(self) -> None:
        # From scripts/ci, 'vendor/x.py' is scripts/ci/vendor/x.py: the audited optional load is live,
        # not stale (read from the repo root it named nothing).
        audit = {("scripts/ci/vend.py", "scripts/ci/vendor/x.py"): "optional: vend.py runs without it"}
        listed = self.block("scripts/ci/vend.py")
        self.assertEqual(
            self._misses(listed, run="python3 vend.py", run_env="working-directory: scripts/ci", audit=audit, more=self.VENDOR),
            [],
        )
        # An unknown working directory makes the load unverifiable, never the entry stale.
        self.assertEqual(
            self._misses(
                listed, run=self.block("true || cd scripts/ci", "python3 scripts/ci/vend.py"), audit=audit, more=self.VENDOR
            ),
            [
                "w.yml run Check out: scripts/ci/vend.py calls importlib.util.spec_from_file_location('v', "
                "'vendor/x.py') (line 3), which this check cannot follow; make the import static or audit it in "
                "DYNAMIC_IMPORT_AUDIT"
            ],
        )
        # A load the file no longer makes from where it runs is still stale.
        gone = {("scripts/ci/vend.py", "scripts/ci/vendor/y.py"): "a load the file does not make"}
        self.assertEqual(
            self._misses(listed, run="python3 vend.py", run_env="working-directory: scripts/ci", audit=gone, more=self.VENDOR),
            [
                "w.yml run Check out: scripts/ci/vend.py imports scripts/ci/vendor/x.py, not in its sparse checkout",
                "DYNAMIC_IMPORT_AUDIT: scripts/ci/vend.py scripts/ci/vendor/y.py: no call in scripts/ci/vend.py "
                "matches it; re-check the call and the entry",
            ],
        )

    def test_fixture_review_41051_f1_an_unknown_directory_keeps_an_entry_only_while_its_load_call_exists(self) -> None:
        # From an unknown directory the load's path cannot be resolved, but whether the call is there
        # still can: a deleted load call leaves its audit entry stale.
        audit = {("scripts/ci/vend.py", "scripts/ci/vendor/x.py"): "optional: vend.py runs without it"}
        run = self.block("true || cd scripts/ci", "python3 scripts/ci/vend.py")
        listed = self.block("scripts/ci/vend.py")
        no_call = {**self.VENDOR, "scripts/ci/vend.py": "import importlib.util\n"}
        self.assertEqual(
            self._misses(listed, run=run, audit=audit, more=no_call),
            [
                "DYNAMIC_IMPORT_AUDIT: scripts/ci/vend.py scripts/ci/vendor/x.py: no call in scripts/ci/vend.py "
                "matches it; re-check the call and the entry"
            ],
        )
        # A load call that names another file from every directory does not keep it alive either.
        other = {**self.VENDOR, "scripts/ci/vend.py": self.VENDOR["scripts/ci/vend.py"].replace("vendor/x.py", "vendor/z.py")}
        self.assertIn(
            "DYNAMIC_IMPORT_AUDIT: scripts/ci/vend.py scripts/ci/vendor/x.py: no call in scripts/ci/vend.py "
            "matches it; re-check the call and the entry",
            self._misses(listed, run=run, audit=audit, more=other),
        )

    def test_fixture_review_41068_f2_an_unknown_directory_probes_every_tracked_folder(self) -> None:
        # '../../shared/x.py' names shared/x.py from scripts/ci, a folder that is not on the way to it:
        # from an unknown directory the entry is live, and the load unverifiable, not stale.
        audit = {("scripts/ci/vend.py", "shared/x.py"): "optional: vend.py runs without it"}
        more = {
            **self.VENDOR,
            "scripts/ci/vend.py": self.VENDOR["scripts/ci/vend.py"].replace("vendor/x.py", "../../shared/x.py"),
            "shared/x.py": "",
        }
        self.assertEqual(
            self._misses(
                self.block("scripts/ci/vend.py"),
                run=self.block("true || cd scripts/ci", "python3 scripts/ci/vend.py"),
                audit=audit,
                more=more,
            ),
            [
                "w.yml run Check out: scripts/ci/vend.py calls importlib.util.spec_from_file_location('v', "
                "'../../shared/x.py') (line 3), which this check cannot follow; make the import static or audit "
                "it in DYNAMIC_IMPORT_AUDIT"
            ],
        )

    def test_fixture_fixed_sys_path_insert_joins_the_search_path(self) -> None:
        # lit.py inserts scripts/ (parents[1] of its file) and imports toplib from there.
        self.assertEqual(
            self._misses(self.block("scripts/ci/lit.py")),
            ["w.yml run Check out: scripts/ci/lit.py imports scripts/toplib.py, not in its sparse checkout"],
        )
        self.assertEqual(self._misses(self.block("scripts/ci/lit.py", "scripts/toplib.py")), [])
        # A folder computed at run time is not fixed: unverifiable.
        self.assertEqual(
            self._misses(self.block("scripts/ci/varpath.py")),
            [
                "w.yml run Check out: scripts/ci/varpath.py calls sys.path.append(os.environ['X']) (line 2), which "
                "this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
            ],
        )

    def test_fixture_fixed_spec_from_file_location_joins_the_closure(self) -> None:
        self.assertEqual(
            self._misses(self.block("scripts/ci/loader.py")),
            [
                "w.yml run Check out: scripts/ci/loaded-by-path.py imports scripts/ci/deadline_http.py, "
                "not in its sparse checkout (via scripts/ci/loader.py)",
                "w.yml run Check out: scripts/ci/loader.py imports scripts/ci/loaded-by-path.py, not in its sparse checkout",
            ],
        )
        listed = ("scripts/ci/loader.py", "scripts/ci/loaded-by-path.py", "scripts/ci/deadline_http.py")
        self.assertEqual(self._misses(self.block(*listed)), [])

    def test_fixture_step_pythonpath_overrides_the_workflow_one(self) -> None:
        # Codex: concatenating the workflow's and the step's PYTHONPATH let defaults/pphelper.py mask the
        # missing actual/pphelper.py the step really loads.
        self.assertEqual(
            self._misses(
                self.block("scripts/ci/pp_user.py", "scripts/defaults/pphelper.py"),
                wf_env="env: {PYTHONPATH: scripts/defaults}",
                run="python3 scripts/ci/pp_user.py",
                run_env="env: {PYTHONPATH: scripts/actual}",
            ),
            ["w.yml run Check out: scripts/ci/pp_user.py imports scripts/actual/pphelper.py, not in its sparse checkout"],
        )
        # An inline PYTHONPATH on the line that runs the script wins over the step's env.
        self.assertEqual(
            self._misses(
                self.block("scripts/ci/pp_user.py", "scripts/actual/pphelper.py"),
                run="PYTHONPATH=scripts/defaults python3 scripts/ci/pp_user.py",
                run_env="env: {PYTHONPATH: scripts/actual}",
            ),
            ["w.yml run Check out: scripts/ci/pp_user.py imports scripts/defaults/pphelper.py, not in its sparse checkout"],
        )

    def test_fixture_workspace_pythonpath_is_the_repo_root(self) -> None:
        # Codex: ${{ github.workspace }} and $GITHUB_WORKSPACE became empty and were dropped.
        for value in ("'${{ github.workspace }}'", "$GITHUB_WORKSPACE", "'${GITHUB_WORKSPACE}/'"):
            with self.subTest(value=value):
                self.assertEqual(
                    self._misses(self.block("scripts/ci/ws_user.py"), job_env=f"env: {{PYTHONPATH: {value}}}"),
                    ["w.yml run Check out: scripts/ci/ws_user.py imports ws_mod.py, not in its sparse checkout"],
                )
        # An entry that names nothing this check can resolve is unverifiable, so it fails.
        self.assertEqual(
            self._misses(self.block("scripts/ci/ws_user.py"), job_env="env: {PYTHONPATH: '${{ env.TOOLS }}/lib'}"),
            [
                "w.yml run Check out: scripts/ci/ws_user.py runs with PYTHONPATH entry '${{ env.TOOLS }}/lib', "
                "which this check cannot resolve to a repo folder"
            ],
        )

    def test_fixture_codex_each_insert_0_goes_in_front(self) -> None:
        # insert(0, first) then insert(0, second): second is searched first, so ordmod is second's.
        self.assertEqual(
            self._misses(self.block("scripts/ci/order.py", "scripts/first/ordmod.py")),
            ["w.yml run Check out: scripts/ci/order.py imports scripts/second/ordmod.py, not in its sparse checkout"],
        )
        self.assertEqual(self._misses(self.block("scripts/ci/order.py", "scripts/second/ordmod.py")), [])

    def test_fixture_codex_a_load_in_try_except_import_error_is_required(self) -> None:
        self.assertEqual(
            self._misses(self.block("scripts/ci/tryload.py")),
            ["w.yml run Check out: scripts/ci/tryload.py imports scripts/ci/tried.py, not in its sparse checkout"],
        )
        audit = {("scripts/ci/tryload.py", "scripts/ci/tried.py"): "optional: the script runs on without it"}
        self.assertEqual(self._misses(self.block("scripts/ci/tryload.py"), audit=audit), [])

    def test_fixture_codex_continued_line_pythonpath(self) -> None:
        # The step's PYTHONPATH= sits on a line the backslash joins to the command.
        self.assertEqual(
            self._misses(
                self.block("scripts/ci/pp_user.py", "scripts/defaults/pphelper.py"),
                wf_env="env: {PYTHONPATH: scripts/defaults}",
                # YAML double quotes: the run script is `PYTHONPATH=scripts/actual \<newline>  python3 ...`.
                run='"PYTHONPATH=scripts/actual \\\\\\n  python3 scripts/ci/pp_user.py"',
            ),
            ["w.yml run Check out: scripts/ci/pp_user.py imports scripts/actual/pphelper.py, not in its sparse checkout"],
        )
        # A line naming the script that does not lex, or an export, cannot be verified.
        self.assertEqual(
            self._misses(
                self.block("scripts/ci/pp_user.py", "scripts/defaults/pphelper.py"),
                run="'python3 scripts/ci/pp_user.py \"unterminated'",
            ),
            [
                "w.yml run Check out: scripts/ci/pp_user.py runs from a line this check cannot parse: "
                "'python3 scripts/ci/pp_user.py \"unterminated'"
            ],
        )
        self.assertEqual(
            self._misses(
                self.block("scripts/ci/pp_user.py", "scripts/defaults/pphelper.py"),
                run="'export PYTHONPATH=scripts/actual; python3 scripts/ci/pp_user.py'",
            ),
            [
                "w.yml run Check out: scripts/ci/pp_user.py runs in a step that sets or reads PYTHONPATH where "
                "this check cannot follow it"
            ],
        )

    def test_fixture_codex_path_ops_in_functions_have_no_proven_order(self) -> None:
        # add_b is defined first but add_a() runs first: Python searches scripts/b first. Calls inside
        # functions have no order this check can prove, so they are unverifiable, not learned.
        unverifiable = "which this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
        self.assertEqual(
            self._misses(self.block("scripts/ci/fnorder.py", "scripts/b/ordmod2.py")),
            [
                f"w.yml run Check out: scripts/ci/fnorder.py calls sys.path.insert(0, 'scripts/a') (line 5), {unverifiable}",
                f"w.yml run Check out: scripts/ci/fnorder.py calls sys.path.insert(0, 'scripts/b') (line 3), {unverifiable}",
            ],
        )
        # Module-level inserts in two files: their relative order depends on where the import runs.
        self.assertEqual(
            self._misses(self.block("scripts/ci/xfile.py", "scripts/ci/xside.py", "scripts/a/ordmod2.py")),
            [
                f"w.yml run Check out: scripts/ci/xfile.py calls sys.path.insert(0, 'scripts/a') (line 3), {unverifiable}",
                f"w.yml run Check out: scripts/ci/xside.py calls sys.path.insert(0, 'scripts/b') (line 2), {unverifiable} "
                "(via scripts/ci/xfile.py)",
            ],
        )

    # disj.py inserts scripts/p1 and scripts/p2 from two functions, so their order is not provable;
    # it is learned only while no folder on the path offers a name another one (or the stdlib, or an
    # installed package) offers too.
    DISJ = {
        "scripts/ci/disj.py": (
            "import sys\n"
            "def b():\n    sys.path.insert(0, 'scripts/p2')\n"
            "def a():\n    sys.path.insert(0, 'scripts/p1')\n"
            "a()\nb()\nimport p1only\n"
        ),
        "scripts/p1/p1only.py": "",
        "scripts/p2/p2only.py": "",
    }
    DISJ_UNVERIFIABLE = [
        "w.yml run Check out: scripts/ci/disj.py calls sys.path.insert(0, 'scripts/p1') (line 5), which this check "
        "cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT",
        "w.yml run Check out: scripts/ci/disj.py calls sys.path.insert(0, 'scripts/p2') (line 3), which this check "
        "cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT",
    ]

    def _disj(self, *extra_listed: str, **more: str) -> list[str]:
        listed = self.block("scripts/ci/disj.py", "scripts/p1/p1only.py", *extra_listed)
        return self._misses(listed, more={**self.DISJ, **more})

    def test_fixture_disjoint_folders_are_learned_in_any_order(self) -> None:
        self.assertEqual(self._disj(), [])

    def test_fixture_disjoint_proof_two_folders_gain_a_shared_name(self) -> None:
        self.assertEqual(self._disj(**{"scripts/p2/p1only.py": ""}), self.DISJ_UNVERIFIABLE)

    def test_fixture_disjoint_proof_package_dir_against_py_file(self) -> None:
        self.assertEqual(
            self._disj(**{"scripts/p1/shared.py": "", "scripts/p2/shared/__init__.py": ""}), self.DISJ_UNVERIFIABLE
        )

    def test_fixture_disjoint_proof_stdlib_name(self) -> None:
        # A local json.py inserted at sys.path[0] shadows the stdlib's json.
        self.assertEqual(self._disj(**{"scripts/p1/json.py": ""}), self.DISJ_UNVERIFIABLE)

    def test_fixture_disjoint_proof_namespace_dir(self) -> None:
        # nsdir/ has no __init__.py in p1 (a namespace portion) and is a module in p2.
        self.assertEqual(
            self._disj(**{"scripts/p1/nsdir/deep/x.py": "", "scripts/p2/nsdir.py": ""}), self.DISJ_UNVERIFIABLE
        )

    def test_fixture_disjoint_proof_extension_module(self) -> None:
        # fastmod.cpython-312-x86_64-linux-gnu.so is the module fastmod, like fastmod.py.
        self.assertEqual(
            self._disj(**{"scripts/p1/fastmod.cpython-312-x86_64-linux-gnu.so": "", "scripts/p2/fastmod.py": ""}),
            self.DISJ_UNVERIFIABLE,
        )

    def test_fixture_review_f1_an_import_between_path_changes_sees_the_earlier_path(self) -> None:
        # insert a; import ordmod; insert b: Python loads a/ordmod.py. With only b/ordmod.py listed the
        # sparse run would fail, so the change after the import cannot be learned as if it came first.
        more = {
            "scripts/ci/between.py": (
                "import sys\nsys.path.insert(0, 'scripts/first')\nimport ordmod\nsys.path.insert(0, 'scripts/second')\n"
            ),
        }
        self.assertEqual(
            self._misses(self.block("scripts/ci/between.py", "scripts/second/ordmod.py"), more=more),
            [
                "w.yml run Check out: scripts/ci/between.py calls sys.path.insert(0, 'scripts/first') (line 2), which "
                "this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT",
                "w.yml run Check out: scripts/ci/between.py calls sys.path.insert(0, 'scripts/second') (line 4), "
                "which this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT",
            ],
        )

    def test_fixture_review_f2_an_inherited_name_keeps_its_defining_scope(self) -> None:
        # outer() binds Q = a.py and P = Q; inner() binds its own Q = b.py and loads P, which is a.py at run
        # time. Q is bound in two scopes, so P is not provable: the load must not be learned as b.py.
        more = {
            "scripts/lib/a.py": "import deadline_http\n",
            "scripts/lib/b.py": "",
            "scripts/ci/nested.py": (
                "import importlib.util\n"
                "def outer():\n"
                "    Q = 'scripts/lib/a.py'\n"
                "    P = Q\n"
                "    def inner():\n"
                "        Q = 'scripts/lib/b.py'\n"
                "        return importlib.util.spec_from_file_location('m', P)\n"
                "    return inner()\n"
                "outer()\n"
            ),
        }
        self.assertEqual(
            self._misses(self.block("scripts/ci/nested.py", "scripts/lib/b.py"), more=more),
            [
                "w.yml run Check out: scripts/ci/nested.py calls importlib.util.spec_from_file_location('m', P) "
                "(line 7), which this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
            ],
        )

    def test_fixture_review_40923_f1_a_stdlib_named_import_between_path_changes_is_not_trusted(self) -> None:
        # insert one; import json; insert two, with json in both folders: Python loads one's json (a
        # repo file shadows the stdlib), so a list with only two's json must not pass. A json.py file
        # and a json/ package with __init__.py shadow it alike.
        script = "import sys\nsys.path.insert(0, 'scripts/one')\nimport json\nsys.path.insert(0, 'scripts/two')\n"
        expected = [
            "w.yml run Check out: scripts/ci/sj.py calls sys.path.insert(0, 'scripts/one') (line 2), which "
            "this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT",
            "w.yml run Check out: scripts/ci/sj.py calls sys.path.insert(0, 'scripts/two') (line 4), "
            "which this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT",
        ]
        for form, (one, two) in {
            "file": ("scripts/one/json.py", "scripts/two/json.py"),
            "package": ("scripts/one/json/__init__.py", "scripts/two/json/__init__.py"),
        }.items():
            with self.subTest(form=form):
                more = {"scripts/ci/sj.py": script, one: "", two: ""}
                self.assertEqual(self._misses(self.block("scripts/ci/sj.py", two), more=more), expected)

    # A def's decorators, defaults and annotations run in the scope around it, so a name there is the
    # enclosing scope's, not the body's: P is a.py where they run, though the body binds P = b.py.
    ENCLOSING = {
        "scripts/lib/a.py": "",
        "scripts/lib/b.py": "",
    }

    def _enclosing(self, source: str) -> list[str]:
        more = {**self.ENCLOSING, "scripts/ci/enc.py": "import importlib.util\nP = 'scripts/lib/a.py'\n" + source}
        return self._misses(self.block("scripts/ci/enc.py", "scripts/lib/b.py"), more=more)

    def _unfollowable(self, line: int) -> list[str]:
        return [
            f"w.yml run Check out: scripts/ci/enc.py calls importlib.util.spec_from_file_location('m', P) "
            f"(line {line}), which this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
        ]

    def test_fixture_review_40923_f2_defaults_and_annotations_use_the_enclosing_scope(self) -> None:
        # P is bound in the module and in f, so it is provable in neither for the default: unverifiable,
        # never b.py from f's body.
        body = "    P = 'scripts/lib/b.py'\n    return P\n"
        call = "importlib.util.spec_from_file_location('m', P)"
        for label, head in {
            "default": f"def f(spec={call}):\n",
            "keyword-only default": f"def f(*, spec={call}):\n",
            "parameter annotation": f"def f(spec: {call} = None):\n",
            "return annotation": f"def f() -> {call}:\n",
        }.items():
            with self.subTest(form=label):
                self.assertEqual(self._enclosing(head + body), self._unfollowable(3))

    def test_fixture_review_40923_f2_decorators_use_the_enclosing_scope(self) -> None:
        source = (
            "def deco(spec):\n    return lambda fn: fn\n"
            "@deco(importlib.util.spec_from_file_location('m', P))\n"
            "def f():\n    P = 'scripts/lib/b.py'\n    return P\n"
        )
        self.assertEqual(self._enclosing(source), self._unfollowable(5))

    def test_fixture_review_40923_f2_lambda_defaults_use_the_enclosing_scope(self) -> None:
        # The lambda binds only `spec`; its default's P is the module's a.py, which must be listed.
        source = "g = lambda spec=importlib.util.spec_from_file_location('m', P): spec\n"
        self.assertEqual(
            self._enclosing(source),
            ["w.yml run Check out: scripts/ci/enc.py imports scripts/lib/a.py, not in its sparse checkout"],
        )

    def test_fixture_review_40923_f2_class_bases_and_keywords_use_the_enclosing_scope(self) -> None:
        # A base, class keyword or class decorator runs where the class is defined: P is the module's
        # a.py, which must be listed. (A class body is not a scope the check models, so its names
        # never were the body's; this guards that.)
        source = (
            "def keep(cls):\n    return cls\n"
            "@keep\n"
            "class C(dict, spec=importlib.util.spec_from_file_location('m', P)):\n"
            "    def m(self):\n        return 1\n"
            "class D(importlib.util.spec_from_file_location('m', P).__class__):\n"
            "    pass\n"
        )
        self.assertEqual(
            self._enclosing(source),
            ["w.yml run Check out: scripts/ci/enc.py imports scripts/lib/a.py, not in its sparse checkout"],
        )

    # Shell text is not straight-line code (review of #41017): a ( ... ) restores the directory at its
    # matching ), across lines and next to other operators; a cd that may not run makes it unknown.
    # PYTHONPATH=lib is relative to the directory python starts in, the repo root here, where Python
    # loads lib/witness.py (scripts/ci/witness.py is a decoy the old reading picked).
    WITNESS = {"scripts/ci/wentry.py": "import witness\n", "scripts/ci/witness.py": "", "lib/witness.py": ""}
    WITNESS_RUN = "PYTHONPATH=lib python3 -c \"import runpy; runpy.run_path('scripts/ci/wentry.py')\""

    def test_fixture_review_41017_a_subshell_cd_ends_at_its_matching_paren(self) -> None:
        listed = self.block("scripts/ci/wentry.py", "scripts/ci/witness.py")
        for label, lines in {
            "multi-line": ("(", "cd scripts/ci", ")", self.WITNESS_RUN),
            "next to ;": ("(cd scripts/ci && true); " + self.WITNESS_RUN,),
        }.items():
            with self.subTest(shape=label):
                self.assertEqual(
                    self._misses(listed, run=self.block(*lines), more=self.WITNESS),
                    ["w.yml run Check out: scripts/ci/wentry.py imports lib/witness.py, not in its sparse checkout"],
                )

    def test_fixture_review_41017_a_conditional_cd_makes_the_directory_unknown(self) -> None:
        listed = self.block("scripts/ci/wentry.py", "scripts/ci/witness.py")
        self.assertEqual(
            self._misses(listed, run=self.block("true || cd scripts/ci", self.WITNESS_RUN), more=self.WITNESS),
            [
                "w.yml run Check out: scripts/ci/wentry.py runs in a step that sets or reads PYTHONPATH where "
                "this check cannot follow it",
                "w.yml run Check out: scripts/ci/wentry.py runs with `python -c` from a working directory this "
                "check cannot resolve",
            ],
        )

    def test_fixture_review_41035_f1_a_step_shell_without_errexit_is_read_without_it(self) -> None:
        # `shell: bash {0}` runs without -e: the cd may fail and the step go on in the repo root, so the
        # -c run's directory is unknown, through run_configs. GitHub's default and `shell: bash` keep -e.
        listed = self.block("scripts/ci/wentry.py", "scripts/ci/witness.py")
        run = self.block("cd scripts/ci", self.WITNESS_RUN)
        self.assertEqual(
            self._misses(listed, run=run, run_env="shell: bash {0}", more=self.WITNESS),
            [
                "w.yml run Check out: scripts/ci/wentry.py runs in a step that sets or reads PYTHONPATH where "
                "this check cannot follow it",
                "w.yml run Check out: scripts/ci/wentry.py runs with `python -c` from a working directory this "
                "check cannot resolve",
            ],
        )
        for shell in ("", "shell: bash", "shell: bash -e {0}"):
            with self.subTest(shell=shell or "(default)"):
                self.assertEqual(self._misses(listed, run=run, run_env=shell, more=self.WITNESS), [])

    def test_fixture_review_41017_the_shell_directory_in_every_shape(self) -> None:
        # The directory each command starts in, per _SHELL_SHAPES; None is unknown (unverifiable).
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for folder in _SHELL_FOLDERS:
                (root / folder).mkdir(parents=True, exist_ok=True)
            for run, errexit, script, want in _SHELL_SHAPES:
                with self.subTest(run=run, errexit=errexit, script=script):
                    self.assertEqual(_shell_cwds(run, root, errexit, script), [want])

    def test_fixture_review_41035_after_an_or_the_directory_is_unknown(self) -> None:
        # In `cd x && a || b`, b runs when the cd or a failed, so b's directory is unknown, and so is
        # everything after a || in that list and after the list ends. Only a, after the &&, is in x.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts/ci").mkdir(parents=True)
            for run, script, want in _OR_SHAPES:
                with self.subTest(run=run, script=script):
                    self.assertEqual(_shell_cwds(run, root, True, script), [want])

    # Python puts the working directory, not the script's folder, first for `python -m`, `python -c`
    # and stdin; relative path literals name paths from it too. Both tests/ and scripts/ci/tests/ hold
    # a `tests` package.
    CWD = {
        "scripts/ci/mx.py": (
            "import os\nimport sys\ndef extend():\n"
            "    sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mxvendor'))\n"
            "extend()\nimport tests.mxhelp\n"
        ),
        "scripts/ci/mxvendor/mxv.py": "",
        "scripts/ci/mx2.py": "import tests.mxhelp\n",
        "scripts/ci/mx3.py": "import tests.mxhelp\n",
        "scripts/ci/mxlit.py": "import sys\nsys.path.insert(0, 'mxlitdir')\nimport mxlitmod\n",
        "scripts/ci/mxlitdir/mxlitmod.py": "",
        "scripts/ci/mx4.py": "import mxlitmod\n",
        "mxlitdir/mxlitmod.py": "",
        "tests/__init__.py": "",
        "tests/mxhelp.py": "",
        "scripts/ci/tests/__init__.py": "",
        "scripts/ci/tests/mxhelp.py": "",
    }
    IN_SCRIPTS_CI = "working-directory: scripts/ci\n        env:\n          PYTHONPATH: ${{ github.workspace }}"

    def test_fixture_review_m_a_module_run_counts_its_working_directory_in_the_proof(self) -> None:
        # `python -m scripts.ci.mx` from scripts/ci, found through PYTHONPATH: sys.path is [scripts/ci,
        # the repo root], both offer `tests`, so the append in extend() cannot be ordered by a proof.
        listed = self.block(
            "scripts/ci/mx.py", "tests/__init__.py", "tests/mxhelp.py",
            "scripts/ci/tests/__init__.py", "scripts/ci/tests/mxhelp.py",
        )
        self.assertEqual(
            self._misses(listed, run="python3 -m scripts.ci.mx", run_env=self.IN_SCRIPTS_CI, more=self.CWD),
            [
                "w.yml run Check out: scripts/ci/mx.py calls sys.path.append(os.path.join(os.path.dirname("
                "os.path.abspath(__file__)), 'mxvendor')) (line 4), which this check cannot follow; make the "
                "import static or audit it in DYNAMIC_IMPORT_AUDIT"
            ],
        )

    def test_fixture_review_41012_f1_a_cd_under_if_leaves_python_m_unverifiable(self) -> None:
        # The reviewer's shape: the cd under `if` may or may not run, so `python -m` has no known
        # working directory.
        listed = self.block("scripts/ci/mx2.py", "tests/__init__.py", "tests/mxhelp.py")
        run = self.block("if true; then cd scripts/ci; fi", "python3 -m scripts.ci.mx2")
        self.assertEqual(
            self._misses(listed, run=run, more=self.CWD),
            [
                "w.yml run Check out: scripts/ci/mx2.py runs with `python -m` from a working directory this check "
                "cannot resolve"
            ],
        )

    def test_fixture_review_m_a_module_run_imports_from_its_working_directory_first(self) -> None:
        # The same step with no path change: `tests` is scripts/ci/tests (the working directory), not
        # the repo root's.
        listed = self.block("scripts/ci/mx2.py", "tests/__init__.py", "tests/mxhelp.py")
        self.assertEqual(
            self._misses(listed, run="python3 -m scripts.ci.mx2", run_env=self.IN_SCRIPTS_CI, more=self.CWD),
            [
                "w.yml run Check out: scripts/ci/mx2.py imports scripts/ci/tests/__init__.py, not in its sparse checkout",
                "w.yml run Check out: scripts/ci/mx2.py imports scripts/ci/tests/mxhelp.py, not in its sparse checkout",
            ],
        )

    def test_fixture_review_m_code_and_stdin_runs_import_from_the_working_directory(self) -> None:
        # `python -c` and a heredoc fed to python from the repo root: `tests` is the root's.
        listed = self.block("scripts/ci/mx3.py", "scripts/ci/tests/__init__.py", "scripts/ci/tests/mxhelp.py")
        expected = [
            "w.yml run Check out: scripts/ci/mx3.py imports tests/__init__.py, not in its sparse checkout",
            "w.yml run Check out: scripts/ci/mx3.py imports tests/mxhelp.py, not in its sparse checkout",
        ]
        runs = {
            "-c": "python3 -c \"import runpy; runpy.run_path('scripts/ci/mx3.py')\"",
            "heredoc": "|\n            python3 - <<'EOF'\n            import runpy\n"
            "            runpy.run_path('scripts/ci/mx3.py')\n            EOF",
        }
        for label, run in runs.items():
            with self.subTest(run=label):
                self.assertEqual(self._misses(listed, run=run, more=self.CWD), expected)

    def test_fixture_oracle_a_relative_pythonpath_is_relative_to_the_working_directory(self) -> None:
        # Found by the differential oracle: `cd scripts/ci && PYTHONPATH=mxlitdir python3 mx4.py` puts
        # scripts/ci/mxlitdir on the path, not the repo root's mxlitdir.
        listed = self.block("scripts/ci/mx4.py", "mxlitdir/mxlitmod.py")
        self.assertEqual(
            self._misses(listed, run="cd scripts/ci && PYTHONPATH=mxlitdir python3 mx4.py", more=self.CWD),
            [
                "w.yml run Check out: scripts/ci/mx4.py imports scripts/ci/mxlitdir/mxlitmod.py, "
                "not in its sparse checkout"
            ],
        )

    def test_fixture_review_m_a_relative_literal_names_a_path_from_the_working_directory(self) -> None:
        # `python3 mxlit.py` in scripts/ci: 'mxlitdir' is scripts/ci/mxlitdir, not the root's mxlitdir.
        listed = self.block("scripts/ci/mxlit.py", "mxlitdir/mxlitmod.py")
        self.assertEqual(
            self._misses(listed, run="python3 mxlit.py", run_env="working-directory: scripts/ci", more=self.CWD),
            [
                "w.yml run Check out: scripts/ci/mxlit.py imports scripts/ci/mxlitdir/mxlitmod.py, "
                "not in its sparse checkout"
            ],
        )

    def test_fixture_codex_a_star_import_makes_module_names_unprovable(self) -> None:
        # P at module level comes from `from starconf import *` (scripts/b); f()'s local P = 'scripts/a'
        # is another scope and must not stand in for it.
        self.assertEqual(
            self._misses(self.block("scripts/ci/star.py", "scripts/ci/starconf.py", "scripts/b/ordmod2.py")),
            [
                "w.yml run Check out: scripts/ci/star.py calls sys.path.insert(0, P) (line 6), which this check "
                "cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
            ],
        )

    def test_fixture_codex_a_search_that_does_not_settle_is_reported(self) -> None:
        # scripts/ci/oschelper.py inserts scripts/alternate, whose own oschelper.py inserts nothing: each
        # search path picks the other file. The insert is in an imported module and both folders hold
        # oschelper, so neither the ordered case nor the no-shared-names case proves it: it is reported as
        # a call this check cannot follow before the search could cycle, and the rest of the scan still runs.
        self.assertEqual(
            self._misses(self.block("scripts/ci/osc_entry.py", "scripts/ci/oschelper.py", "scripts/ci/runner.py")),
            [
                "w.yml run Check out: scripts/ci/helper.py imports scripts/ci/deadline_http.py, not in its sparse "
                "checkout (via scripts/ci/runner.py)",
                "w.yml run Check out: scripts/ci/runner.py imports scripts/ci/helper.py, not in its sparse checkout",
                "w.yml run Check out: scripts/ci/oschelper.py calls sys.path.insert(0, 'scripts/alternate') (line 2), "
                "which this check cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT "
                "(via scripts/ci/osc_entry.py)",
            ],
        )

    def test_fixture_codex_a_rebound_name_is_not_fixed(self) -> None:
        # P = "scripts/a"; P += "b": the insert is of scripts/ab, so P is not a fixed path.
        self.assertEqual(
            self._misses(self.block("scripts/ci/rebind.py", "scripts/a/rbmod.py")),
            [
                "w.yml run Check out: scripts/ci/rebind.py calls sys.path.insert(0, P) (line 4), which this check "
                "cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
            ],
        )

    def test_fixture_f3_run_as_module_needs_the_package_init(self) -> None:
        # `python -m mpkg.main` imports mpkg (its __init__.py) before main's `from .helper import go`.
        listed = self.block("scripts/ci/mpkg/main.py", "scripts/ci/mpkg/helper.py")
        for run in ("cd scripts/ci && python3 -m mpkg.main", "cd scripts/ci; python -u -m mpkg.main --flag"):
            with self.subTest(run=run):
                self.assertEqual(
                    self._misses(listed, run=run),
                    [
                        "w.yml run Check out: scripts/ci/mpkg/main.py imports scripts/ci/mpkg/__init__.py, "
                        "not in its sparse checkout"
                    ],
                )
        # From the repo root, Python finds no mpkg (the working directory is sys.path[0]): fail closed.
        self.assertEqual(
            self._misses(listed, run="python -u -m mpkg.main --flag"),
            [
                "w.yml run Check out: scripts/ci/mpkg/main.py runs as `python -m mpkg.main` from the repo root, "
                "where this check cannot find the module"
            ],
        )
        run = "cd scripts/ci && python3 -m mpkg.main"
        self.assertEqual(
            self._misses(self.block("scripts/ci/mpkg/main.py"), run=run),
            [
                "w.yml run Check out: scripts/ci/mpkg/main.py imports scripts/ci/mpkg/__init__.py, "
                "not in its sparse checkout",
                "w.yml run Check out: scripts/ci/mpkg/main.py imports scripts/ci/mpkg/helper.py, "
                "not in its sparse checkout",
            ],
        )
        self.assertEqual(self._misses(self.block("scripts/ci/mpkg/"), run=run), [])


# --- differential oracle ------------------------------------------------------------------------
#
# Random programs run under real Python; for each, the checker must name the repo files the run
# loaded (its entry script, every module file in sys.modules at exit, every file loaded by path), or
# say it cannot verify the run. Naming exactly them is "verified"; naming more is "superset" (see
# _oracle_case); missing one is a divergence. A run that raises is not a case; the generator keeps
# going until it has enough cases. Seeds are fixed, so a divergence reproduces from its seed.

ORACLE_CASES = int(os.environ.get("SPARSE_ORACLE_CASES", "1000"))
ORACLE_SEED = int(os.environ.get("SPARSE_ORACLE_SEED", "40923"))
# Ratchet: on seed 40923 and 1000 cases the checker names more files than Python loaded in this many
# cases (ModuleFinder's over-approximation). A checker that names extra files more often fails;
# lower it when the checker gets tighter.
ORACLE_SUPERSET_LIMIT = 1
# Test hook: the checker also names one file Python did not load (a sloppier checker), to show the
# ratchet catches it.
_oracle_extra_file = False
_ORACLE_FOLDERS = ("scripts/ci", "scripts/a", "scripts/b", "lib", "")
_ORACLE_NAMES = ("m0", "m1", "m2", "m3", "m4", "tests", "shared")
_ORACLE_TRACE = (
    "import atexit as _oracle_atexit, sys as _oracle_sys\n"
    "_oracle_atexit.register(lambda: print('ORACLE', repr(sorted({os.path.abspath(getattr(m, '__file__', None) or '/') "
    "for m in list(_oracle_sys.modules.values())}))))\n"
)


def _oracle_program(seed: int) -> tuple[dict[str, str], str, dict, str]:
    """(files, entry script, run step, how real Python is started) for one random case."""
    import random

    rng = random.Random(seed)
    files: dict[str, str] = {}
    shape = rng.choice(("script", "script-cd", "module", "module-cd", "code", "stdin"))
    first = {"script": "scripts/ci", "script-cd": "scripts/ci", "module-cd": "scripts"}.get(shape, "")
    # One shape per name, so every import form fits wherever the name is found; most names sit in
    # the folder Python searches first, the rest in folders only a path change or PYTHONPATH adds.
    kinds = {name: rng.choice(("module", "module", "package", "namespace")) for name in _ORACLE_NAMES}
    offered: list[tuple[str, str]] = []
    for name in _ORACLE_NAMES:
        hosts = [first] if rng.random() < 0.7 else []
        hosts += rng.sample(_ORACLE_FOLDERS, rng.randint(0 if hosts else 1, 2))
        for folder in dict.fromkeys(hosts):
            at = f"{folder}/{name}" if folder else name
            if kinds[name] == "module":
                files[f"{at}.py"] = ""
            elif kinds[name] == "package":
                files[f"{at}/__init__.py"] = rng.choice(("", "from . import sub\n"))
                files[f"{at}/sub.py"] = ""
            else:
                files[f"{at}/sub.py"] = ""
        offered.append((name, kinds[name]))

    def import_line() -> str:
        # Mostly a form that fits a shape the name has somewhere, so most programs run.
        name, shape = rng.choice(offered)
        if shape == "module":
            return f"import {name}\n"
        return rng.choice((f"import {name}\n", f"import {name}.sub\n", f"from {name} import sub\n"))

    # Plain modules import each other a little, sometimes inside a function they call.
    for rel in [r for r in files if r.endswith(".py")]:
        if rng.random() < 0.4:
            line = import_line()
            files[rel] += line if rng.random() < 0.6 else f"def _f():\n    {line}_f()\n"
        if rng.random() < 0.12:
            target = rng.choice(_ORACLE_FOLDERS[:4])
            files[rel] = f"import sys\nsys.path.insert(0, {target!r})\n" + files[rel]

    entry = "scripts/ci/entry.py"
    here = "os.path.dirname(os.path.abspath(__file__))"

    def folder_expr(folder: str) -> str:
        form = rng.random()
        if form < 0.5 or not folder.startswith("scripts/"):
            return repr(folder or ".")
        tail = folder.split("/", 1)[1]
        return f"os.path.join({here}, '..', {tail!r})"

    body: list[str] = ["import os\n", "import sys\n", "import importlib.util\n"]
    calls: list[str] = []
    functions: list[str] = []
    for k in range(rng.randint(0, 4)):
        what = rng.random()
        folder = rng.choice(_ORACLE_FOLDERS[:4])
        if what < 0.35:
            stmt = f"sys.path.insert(0, {folder_expr(folder)})\n"
        elif what < 0.55:
            stmt = f"sys.path.append({folder_expr(folder)})\n"
        elif what < 0.7:
            stmt = import_line()
        elif what < 0.82:
            stmt = f"P{k} = {folder_expr(folder)}\nsys.path.insert(0, P{k})\n"
        else:
            loaded = f"scripts/b/loaded{k}.py"
            files[loaded] = import_line() if rng.random() < 0.5 else ""
            where = f"os.path.join({here}, '..', 'b', 'loaded{k}.py')" if rng.random() < 0.7 else repr(loaded)
            stmt = (
                f"_spec{k} = importlib.util.spec_from_file_location('loaded{k}', {where})\n"
                f"_mod{k} = importlib.util.module_from_spec(_spec{k})\n"
                f"sys.modules['loaded{k}'] = _mod{k}\n"
                f"_spec{k}.loader.exec_module(_mod{k})\n"
            )
        if rng.random() < 0.4:
            functions.append(f"def step{k}():\n" + textwrap.indent(stmt, "    "))
            calls.append(f"step{k}()\n")
        else:
            calls.append(stmt)
    rng.shuffle(calls)  # functions run in any order, not their definition order
    for _ in range(rng.randint(1, 3)):
        calls.insert(rng.randint(0, len(calls)), import_line())
    files[entry] = "".join(body + functions + calls) + _ORACLE_TRACE

    python = "python3" if rng.random() < 0.15 else "python3 -S"
    lib = rng.random() < 0.35
    value = rng.choice(("lib", "lib", "../../lib", ":lib", "${{ github.workspace }}/lib"))
    if "workspace" in value:
        prefix = ""
    else:
        prefix = f"PYTHONPATH={value} " if lib and rng.random() < 0.5 else ""
    step: dict = {}
    if lib and not prefix:
        step["env"] = {"PYTHONPATH": value}
    run_code = f"import runpy; runpy.run_path({entry!r}, run_name='__main__')"
    run = {
        "script": f"{prefix}{python} {entry}",
        "script-cd": f"cd scripts/ci && {prefix}{python} entry.py",
        "module": f"{prefix}{python} -m scripts.ci.entry",
        "module-cd": f"cd scripts && {prefix}{python} -m ci.entry",
        "code": f'{prefix}{python} -c "{run_code}"',
        "stdin": f"{prefix}{python} - <<'EOF'\n{run_code}\nEOF",
    }[shape]
    step["run"] = run
    return files, entry, step, shape


def _unverifiable_reason(root: Path, cwd: str | None, entry: str, unresolved: tuple) -> str:
    """One short reason for an unverifiable run, from its first unresolved call."""
    rel, call, _line, text = unresolved[0]
    if call == SEARCH_DOES_NOT_SETTLE:
        return SEARCH_DOES_NOT_SETTLE
    where = "the entry script" if rel == entry else "an imported module"
    path_ops = dynamic_calls(root, rel, cwd)[0]
    if any(op[3] == call and op[5] == text for op in path_ops):
        return f"{call} of a fixed folder in {where}, in an order it cannot prove"
    return f"{call} in {where}, in a form it cannot follow"


def _oracle_case(seed: int, outside: set[str]) -> tuple[str, str] | None:
    """("verified" | "superset" | "unverifiable" | "invalid" | "divergence", detail) for one case: for
    "superset", the seed and the extra files; for "unverifiable", one short reason."""
    files, entry, step, shape = _oracle_program(seed)
    return _oracle_judge(files, entry, step, outside, seed, shape)


def _oracle_judge(
    files: dict[str, str], entry: str, step: dict, outside: set[str], seed: int | None = None, shape: str = ""
) -> tuple[str, str]:
    """_oracle_case's verdict on one program: its files, entry script and run step, run under real
    Python in a fresh repo and then checked."""
    import json

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve() / "repo"
        for rel, body in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(body, encoding="utf-8")
        shim = Path(tmp) / "bin"
        shim.mkdir()
        (shim / "python3").symlink_to(sys.executable)
        env = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON")}
        env.update(PATH=f"{shim}:{env.get('PATH', '')}", PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1")
        # GitHub expands ${{ github.workspace }} before the shell runs.
        env.update({k: str(v).replace("${{ github.workspace }}", str(root)) for k, v in (step.get("env") or {}).items()})
        done = subprocess.run(
            ["bash", "-e", "-c", step["run"]], cwd=root, env=env, capture_output=True, text=True, timeout=30
        )
        if done.returncode != 0:
            return "invalid", done.stderr[-300:]
        traced = [line for line in done.stdout.splitlines() if line.startswith("ORACLE ")]
        if len(traced) != 1:
            return "invalid", done.stdout[-300:]
        real = {entry}
        for path in ast.literal_eval(traced[0][len("ORACLE "):]):
            if path and Path(path).resolve().is_relative_to(root):
                real.add(Path(path).resolve().relative_to(root).as_posix())

        job = {"steps": [step]}
        doc = {"jobs": {"run": job}}
        how = how_it_runs(entry, _job_run_modules(job))
        configs, bad = run_configs(doc, job, entry, how, root)
        if bad:
            return "unverifiable", re.sub(r"'[^']*'|`[^`]*`", "...", bad[0])
        if len(configs) != 1:
            return "divergence", f"{len(configs)} run configs for one run"
        extra, base, cwd = configs[0]
        names = NameProof(root, outside)
        places, _, _, loaded, unresolved = full_run(root, entry, extra, how, frozenset(), names, base, cwd)
        if unresolved:
            return "unverifiable", _unverifiable_reason(root, cwd, entry, unresolved)
        checked = {entry} | {p for p in places.values() if not p.endswith("/")} | {f for f, _ in loaded}
        if _oracle_extra_file:
            checked |= set(sorted(set(files) - real)[:1])
        if checked != real:
            # More than Python loaded is ModuleFinder's known over-approximation (`from m import sub`
            # after m's __init__ bound a `sub` attribute still counts m/sub.py): it can only ask the
            # list for an extra file. Missing a file Python loaded is a divergence.
            if real < checked:
                return "superset", f"seed {seed}: extra {', '.join(sorted(checked - real))}"
            return "divergence", json.dumps(
                {"seed": seed, "shape": shape, "run": step, "files": files,
                 "only_checker": sorted(checked - real), "only_python": sorted(real - checked)},
                indent=1,
            )
        return "verified", ""


class OracleResult:
    """Outcome counts over exactly `cases` cases that ran, in seed order, with the divergences'
    details, the supersets (seed and extra files) and the unverifiable reasons by count."""

    def __init__(self) -> None:
        self.counts: Counter = Counter()
        self.divergences: list[str] = []
        self.supersets: list[str] = []
        self.reasons: Counter = Counter()

    def report(self) -> str:
        lines = [f"supersets: {len(self.supersets)} (limit {ORACLE_SUPERSET_LIMIT})"]
        lines += [f"  {line}" for line in self.supersets]
        lines.append("top unverifiable reasons:")
        lines += [f"  {n} {reason}" for reason, n in self.reasons.most_common(3)]
        return "\n".join(lines)


def run_oracle(cases: int = ORACLE_CASES, seed: int = ORACLE_SEED) -> OracleResult:
    import multiprocessing
    from concurrent.futures import ProcessPoolExecutor

    outside = set(sys.stdlib_module_names) | _installed_names()
    result = OracleResult()
    workers = max(1, os.cpu_count() or 1)
    done = 0
    with ProcessPoolExecutor(workers, mp_context=multiprocessing.get_context("fork")) as pool:
        next_seed = seed * 1_000_000
        while done < cases:
            want = cases - done
            batch = range(next_seed, next_seed + max(want + want // 2, workers))
            next_seed = batch.stop
            for outcome, detail in pool.map(_oracle_case, batch, [outside] * len(batch), chunksize=8):
                if done == cases:
                    break  # a fixed case count, in seed order, so the ratchet compares like with like
                result.counts[outcome] += 1
                if outcome == "invalid":
                    continue
                done += 1
                if outcome == "divergence":
                    result.divergences.append(detail)
                elif outcome == "superset":
                    result.supersets.append(detail)
                elif outcome == "unverifiable":
                    result.reasons[detail] += 1
    return result


class SparseCheckoutOracleTests(unittest.TestCase):
    def test_random_programs_match_real_python_or_are_unverifiable(self) -> None:
        import time

        started = time.monotonic()
        result = run_oracle()
        took = time.monotonic() - started
        print(
            f"sparse-checkout oracle: {dict(result.counts)} in {took:.1f}s on {os.cpu_count()} cpus\n{result.report()}",
            file=sys.stderr,
        )
        self.assertEqual(result.divergences[:3], [], f"{len(result.divergences)} divergences")
        if (ORACLE_SEED, ORACLE_CASES) == (40923, 1000):
            self.assertLessEqual(
                len(result.supersets), ORACLE_SUPERSET_LIMIT,
                "the checker names files Python did not load more often than before:\n" + "\n".join(result.supersets),
            )
        self.assertGreaterEqual(result.counts["verified"], ORACLE_CASES // 4, dict(result.counts))

    def test_fixture_oracle_shell_cwd_shapes_are_verified_or_unverifiable(self) -> None:
        # Review of #41017: real Python runs from the repo root and loads lib/witness.py; a checker that
        # reads shell text as straight-line code thinks it runs in scripts/ci and names the decoy there.
        outside = set(sys.stdlib_module_names) | _installed_names()
        files = {
            "scripts/ci/wentry.py": "import os\nimport witness\n" + _ORACLE_TRACE,
            "scripts/ci/witness.py": "",
            "lib/witness.py": "",
        }
        python = "PYTHONPATH=lib python3 -c \"import runpy; runpy.run_path('scripts/ci/wentry.py', run_name='__main__')\""
        for shape, run, want in (
            ("multi-line subshell", f"(\ncd scripts/ci\n)\n{python}", "verified"),
            ("subshell next to ;", f"(cd scripts/ci && true); {python}", "verified"),
            ("conditional cd", f"true || cd scripts/ci\n{python}", "unverifiable"),
        ):
            with self.subTest(shape=shape):
                outcome, detail = _oracle_judge(files, "scripts/ci/wentry.py", {"run": run}, outside, shape=shape)
                self.assertEqual(outcome, want, detail)

    def test_bash_agrees_wherever_the_check_knows_the_directory(self) -> None:
        # Review of #41035: every shell fixture here and every workflow step that calls python and
        # changes folder, run in bash with each other command stubbed to succeed or fail (every mix up
        # to 5 commands, else a sample) and python reporting $PWD. Wherever this check gives a known
        # directory for a python call, bash ran it there on every path.
        import time

        started = time.monotonic()
        counts, disagreements = run_bash_oracle(bash_oracle_cases(ROOT))
        print(f"bash oracle: {dict(counts)} in {time.monotonic() - started:.1f}s", file=sys.stderr)
        self.assertFalse(disagreements, f"{len(disagreements)} disagreements:\n" + "\n".join(disagreements))
        self.assertGreater(counts["agree"], 0, dict(counts))

    def test_generated_shell_programs_agree_with_bash(self) -> None:
        # GENERATED_SHELL_SEEDS random programs of the grammar above (20000 by default), each through
        # bash: wherever this check gives a known directory for the python call, bash ran it there.
        import time

        started = time.monotonic()
        counts, disagreements = run_bash_oracle(generated_shell_cases(GENERATED_SHELL_SEEDS))
        print(
            f"generated shell oracle: {GENERATED_SHELL_SEEDS} seeds, {dict(counts)} in {time.monotonic() - started:.1f}s",
            file=sys.stderr,
        )
        self.assertFalse(disagreements, f"{len(disagreements)} disagreements:\n" + "\n".join(disagreements[:40]))
        self.assertGreater(counts["agree"], GENERATED_SHELL_SEEDS // 10, dict(counts))

    def test_fixture_bash_oracle_catches_a_wrong_known_directory(self) -> None:
        # A checker that names a wrong known directory fails the oracle: bash ran `python3 x` in
        # scripts/ci, the planted checker says otherwise.
        global _bash_oracle_plant
        case = ("planted", "cd scripts/ci\npython3 x", True, frozenset(_SHELL_FOLDERS), "")
        self.assertEqual(run_bash_oracle([case]), (Counter(agree=1), []))
        _bash_oracle_plant = True
        try:
            counts, disagreements = run_bash_oracle([case])
        finally:
            _bash_oracle_plant = False
        self.assertEqual(counts, Counter(disagree=1), disagreements)

    def test_fixture_the_superset_ratchet_catches_a_checker_that_names_an_extra_file(self) -> None:
        # The same oracle, with a checker that also names one file the run did not load: 100 cases
        # already exceed the limit pinned for 1000.
        global _oracle_extra_file
        _oracle_extra_file = True
        try:
            result = run_oracle(100)
        finally:
            _oracle_extra_file = False
        self.assertGreater(len(result.supersets), ORACLE_SUPERSET_LIMIT, result.report())
        self.assertEqual(result.divergences, [])


if __name__ == "__main__":
    unittest.main()
