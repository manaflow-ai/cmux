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
(found in each module's AST) makes the step unverifiable, unless DYNAMIC_IMPORT_AUDIT names that file
and call with a one-line reason; an audit entry whose file or call is gone fails too. Only exact,
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
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest
from collections import Counter
from contextlib import contextmanager
from functools import lru_cache
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]

# (file, call) -> why the modules it loads need no listing, or (file, loaded file) -> why a load this
# check learned is optional. One line each; an entry naming a file, a call or a load that is gone
# fails (see stale_audit_entries).
DYNAMIC_IMPORT_AUDIT: dict[tuple[str, str], str] = {
    ("scripts/ci/merge_main_resolver.py", "importlib.util.spec_from_file_location"): (
        "loads scripts/merge-xcstrings.py under its tools_root argument; the catch-up checkout lists it"
    ),
    ("scripts/ci/stable_next.py", "importlib.util.spec_from_file_location"): (
        "_ratchet_module() loads scripts/cmux-next/crash_ratchet.py from the --head-tree archive it compares, "
        "not from this checkout"
    ),
    ("scripts/ci/web_subareas.py", "scripts/cmux-next/web-bundle-key.py"): (
        "optional: web_bundle_input_matcher() returns None when the key script is missing, and callers fall back"
    ),
    ("scripts/ci/next_macos_cascade.py", "__import__"): (
        '__import__("os") of the stdlib, only to build the sys.path insert of its own folder'
    ),
    ("scripts/ci/next_macos_cascade.py", "sys.path.insert"): (
        "inserts its own folder (dirname of abspath(__file__)), which is already sys.path[0]"
    ),
    ("scripts/ci/side_lane_placement.py", "importlib.util.spec_from_file_location"): (
        "loads pr_runner_pool.py and next_macos_cascade.py beside it (a `path` name bound in two functions); "
        "the decide checkout lists both"
    ),
    ("scripts/ci/portable_job_placement.py", "importlib.util.spec_from_file_location"): (
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
# script's import closure is reported as unverifiable unless DYNAMIC_IMPORT_AUDIT names its file and
# call with a reason. The check learns only forms it can prove, and only these:
#   - sys.path.insert(0, P) and sys.path.append(P): P joins both runs' search path, each insert(0)
#     in front of everything before it (so the last one wins), each append at the end;
#   - importlib.util.spec_from_file_location(name, P): the file at P joins the closure and must be
#     checked out, inside a `try:` or not. It is optional only when DYNAMIC_IMPORT_AUDIT says so,
#     keyed by (loading file, loaded file).
# P must be a fixed path in the repo: a string literal (relative to the repo root, the run step's
# directory), or __file__ through Path(), str(), os.fspath(), .resolve(), .absolute(), .parent,
# .parents[N], / "literal", .with_name("literal"), .joinpath("literal"), os.path.abspath/realpath/
# dirname or os.path.join(..., "literal"), directly or through a name the module binds exactly once
# (`NAME = ...`) and never rebinds in any scope (no second assignment, `+=`, loop or with target,
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


def _bound_once(tree: ast.AST) -> dict[str, ast.AST]:
    """Names the module binds exactly once, by a plain `NAME = expr`, and nowhere else in any scope
    (no other assignment, augmented assignment, loop, with, except or walrus target, del, import,
    def, class, parameter, global, nonlocal or match capture of that name) -> expr."""
    binds: Counter[str] = Counter()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and not isinstance(node.ctx, ast.Load):
            binds[node.id] += 1
        elif isinstance(node, ast.arg):
            binds[node.arg] += 2
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
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
    once: dict[str, ast.AST] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if binds[node.targets[0].id] == 1:
                once[node.targets[0].id] = node.value
    return once


class _FixedPath:
    """Evaluates a path in the forms the comment above lists; None for anything else."""

    def __init__(self, here: Path, root: Path, aliases: dict[str, str], bindings: dict[str, ast.AST]) -> None:
        self.here, self.root, self.aliases, self.bindings = here, root, aliases, bindings

    def __call__(self, node: ast.AST, depth: int = 0) -> Path | None:
        if depth > 20:
            return None
        ev = lambda n: self(n, depth + 1)  # noqa: E731
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return None if os.path.isabs(node.value) else self.root / node.value
        if isinstance(node, ast.Name):
            if node.id == "__file__":
                return self.here
            bound = self.bindings.get(node.id)
            return None if bound is None else ev(bound)
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


@lru_cache(maxsize=None)
def dynamic_calls(
    root: Path, rel: str
) -> tuple[tuple[tuple[str, str], ...], tuple[str, ...], tuple[tuple[str, int], ...]]:
    """What a file's dynamic imports do, in source order: (("insert" or "append", folder) for each
    learned sys.path change, files learned spec_from_file_location calls load, unresolved (call, line))."""
    try:
        tree = ast.parse((root / rel).read_bytes())
    except (OSError, SyntaxError, ValueError):
        return (), (), ()
    aliases = _aliases(tree)
    fixed = _FixedPath(root / rel, root, aliases, _bound_once(tree))
    path_ops: list[tuple[str, str]] = []
    loads: list[str] = []
    unresolved: list[tuple[str, int]] = []

    def in_repo(node: ast.AST, want_dir: bool) -> str | None:
        found = fixed(node)
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
                    unresolved.append((SYS_PATH_ASSIGNMENT, node.lineno))
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
                        path_ops.append(("insert", folder))
                        continue
            elif name == "sys.path.append" and len(args) == 1:
                folder = in_repo(args[0], want_dir=True)
                if folder is not None:
                    path_ops.append(("append", folder))
                    continue
            elif name == "importlib.util.spec_from_file_location" and len(args) == 2:
                file = in_repo(args[1], want_dir=False)
                if file is not None:
                    if file not in loads:
                        loads.append(file)
                    continue
        unresolved.append((name, node.lineno))
    return tuple(path_ops), tuple(loads), tuple(unresolved)


@lru_cache(maxsize=None)
def full_run(
    root: Path, script: str, extra: tuple[str, ...], how: tuple[str, str] | None, audited: frozenset = frozenset()
) -> tuple[dict[str, str], dict[str, str], tuple[str, ...], tuple, tuple[tuple[str, str, int], ...]]:
    """ModuleFinder over the full tree: (places, importers, the search path used, the files loaded by
    path as (file, loader), unresolved dynamic calls as (file, call, line)). Learned sys.path changes
    in the closure (the script first, then modules as ModuleFinder meets them, each in source order)
    build the search path, and learned loads join the closure unless `audited` holds (loader, file);
    the run repeats until neither changes."""
    base = how[1] if how else script.rsplit("/", 1)[0]
    module = how[0] if how else None
    front: list[str] = []
    back: list[str] = []
    loaded: dict[str, str] = {}  # file -> the file that loads it
    for _ in range(10):
        search = tuple(dict.fromkeys([*front, base, *extra, *back]))
        places, importer = find_modules(root, script, search, module, tuple(loaded.items()))
        files = dict.fromkeys([script, *(p for p in places.values() if not p.endswith("/"))])
        new_front: list[str] = []
        new_back: list[str] = []
        new_loaded: dict[str, str] = {}
        unresolved = []
        for rel in files:
            path_ops, loads, calls = dynamic_calls(root, rel)
            for op, folder in path_ops:
                if op == "insert":  # insert(0, x) puts x in front of every earlier entry
                    if folder in new_front:
                        new_front.remove(folder)
                    new_front.insert(0, folder)
                elif folder not in new_front and folder not in new_back:
                    new_back.append(folder)
            for file in loads:
                if (rel, file) not in audited:
                    new_loaded.setdefault(file, rel)
            unresolved += [(rel, call, line) for call, line in calls]
        if (new_front, new_back, new_loaded) == (front, back, loaded):
            return places, importer, search, tuple(loaded.items()), tuple(unresolved)
        front, back, loaded = new_front, new_back, new_loaded
    raise RuntimeError(f"{script}: the dynamic imports in its closure never settle")


def stale_audit_entries(root: Path, audit: dict[tuple[str, str], str]) -> list[str]:
    """Audit entries naming a file that is gone, a call it no longer makes unresolved or a file it no
    longer loads, or with no reason."""
    out = []
    for (rel, call), reason in sorted(audit.items()):
        if not (root / rel).is_file():
            out.append(f"DYNAMIC_IMPORT_AUDIT: {rel} {call}: the file is gone, drop the entry")
            continue
        _, loads, calls = dynamic_calls(root, rel)
        if call not in {c for c, _ in calls} and call not in loads:
            out.append(f"DYNAMIC_IMPORT_AUDIT: {rel} {call}: {rel} no longer makes that call, drop the entry")
        elif not str(reason).strip():
            out.append(f"DYNAMIC_IMPORT_AUDIT: {rel} {call}: give a one-line reason")
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

_SHELL_OPERATORS = {";", "&&", "||", "|", "&", "|&", "(", ")", ";;", "!"}
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


def pythonpath_dirs(value: object, root: Path) -> tuple[tuple[str, ...], list[str]]:
    """(repo folders, entries it cannot resolve) of one PYTHONPATH value. ${{ github.workspace }} and
    $GITHUB_WORKSPACE are the repo root; other expressions, variables, absolute paths and paths
    leaving the repo cannot be resolved."""
    if value is None:
        return (), []
    folders: list[str] = []
    bad: list[str] = []
    for raw in str(value).strip().strip("'\"").split(":"):
        part = raw.strip()
        if not part:
            continue
        anchored = _WORKSPACE.match(part)
        if anchored:
            part = part[anchored.end():].lstrip("/") or "."
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


def _command_env(line: str, script: str, how: tuple[str, str] | None) -> dict[str, str] | None:
    """The VAR=value words before the command on this logical line that runs `script` ({} if none,
    or no command on it names the script); None when shlex cannot split the line."""
    lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        words = list(lexer)
    except ValueError:
        return None
    commands: list[list[str]] = [[]]
    for word in words:
        if word in _SHELL_OPERATORS:
            commands.append([])
        else:
            commands[-1].append(word)
    for command in commands:
        if not _mentions(" ".join(command), script, how):
            continue
        assigned: dict[str, str] = {}
        for word in command[1:] if command[:1] == ["env"] else command:
            if not _SHELL_ASSIGNMENT.match(word):
                break
            key, value = word.split("=", 1)
            assigned[key] = value
        return assigned
    return {}


def pythonpath_configs(
    doc: dict, job: dict, script: str, how: tuple[str, str] | None, root: Path
) -> tuple[list[tuple[str, ...]], list[str]]:
    """Each distinct PYTHONPATH (as repo folders) `script` runs with, and why any of it cannot be
    verified. For each run step whose script names `script` on a logical line (continuations
    joined), it is a `PYTHONPATH=...` before that command, else the step's effective env; with no
    such step, the job's (workflow then job) env. A line naming the script that shlex cannot split,
    or a step that sets PYTHONPATH any other way (export, another command), cannot be verified."""
    values: list[object] = []
    bad: list[str] = []
    for step in job.get("steps") or []:
        if not (isinstance(step, dict) and isinstance(step.get("run"), str)):
            continue
        consumed = 0
        named = False
        for line in _logical_lines(step["run"]):
            if not _mentions(line, script, how):
                continue
            named = True
            assigned = _command_env(line, script, how)
            if assigned is None:
                bad.append(f"runs from a line this check cannot parse: {line.strip()[:120]!r}")
                continue
            if "PYTHONPATH" in assigned:
                consumed += 1
                values.append(assigned["PYTHONPATH"])
            else:
                values.append(effective_env(doc, job, step).get("PYTHONPATH"))
        if named and step["run"].count("PYTHONPATH") > consumed:
            bad.append("runs in a step that sets or reads PYTHONPATH where this check cannot follow it")
    if not values:
        values.append(effective_env(doc, job).get("PYTHONPATH"))
    configs: list[tuple[str, ...]] = []
    for value in values:
        folders, unresolved = pythonpath_dirs(value, root)
        bad += [
            f"runs with PYTHONPATH entry {entry!r}, which this check cannot resolve to a repo folder"
            for entry in unresolved
        ]
        if folders not in configs:
            configs.append(folders)
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


def find_misses(root: Path, audit: dict[tuple[str, str], str] | None = None) -> list[str]:
    """One line per (step, missing module), naming the module that imports it; one per (step, file,
    call) for an unaudited dynamic import in a listed script's closure, and per (step, script,
    entry) for a PYTHONPATH entry that cannot be resolved; one per stale audit entry."""
    root = root.resolve()
    audit = audit or {}
    misses = []
    for workflow, job_id, step, entries, doc, job in non_cone_sparse_steps(root):
        listed = listed_ci_scripts(entries, root)
        if not listed:
            continue
        prefix = f"{workflow} {job_id} {step}: "
        modules = _job_run_modules(job)
        runs = []  # (script, how, PYTHONPATH folders)
        bad_paths: list[str] = []
        for script in listed:
            how = how_it_runs(script, modules)
            configs, bad = pythonpath_configs(doc, job, script, how, root)
            runs += [(script, how, extra) for extra in configs]
            bad_paths += [f"{prefix}{script} {why}" for why in bad]
        full = {run: full_run(root, run[0], run[2], run[1], frozenset(audit)) for run in runs}
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
        unverifiable: dict[tuple[str, str], tuple[int, str]] = {}  # (file, call) -> (line, listed script)
        for run in runs:
            script = run[0]
            if sparse[run] is None:
                continue  # excluded by a "!" entry: not checked out, nothing to run
            places, importer, _, _, calls = full[run]
            for rel, call, line in calls:
                key = (rel, call)
                if key not in audit and (key not in unverifiable or (rel == script and unverifiable[key][1] != rel)):
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
        for (rel, call), (line, script) in sorted(unverifiable.items()):
            misses.append(
                f"{prefix}{rel} calls {call} (line {line}), {UNVERIFIABLE}" + ("" if rel == script else f" (via {script})")
            )
        misses += sorted(set(bad_paths))
    return misses + stale_audit_entries(root, audit)


# --- tests ------------------------------------------------------------------------------------


class SparseCheckoutImportTests(unittest.TestCase):
    def test_workflows_list_every_imported_ci_module(self) -> None:
        steps = list(non_cone_sparse_steps(ROOT))
        self.assertTrue(steps, "expected at least one non-cone sparse checkout in .github/workflows")
        misses = find_misses(ROOT, DYNAMIC_IMPORT_AUDIT)
        self.assertEqual(misses, [], "\n" + "\n".join(misses))

    def _fixture(
        self, tmp: Path, sparse: str, job_env: str = "", run: str = "true", wf_env: str = "", run_env: str = ""
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
        }
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
        self, sparse: str, job_env: str = "", run: str = "true", audit=None, wf_env: str = "", run_env: str = ""
    ) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            return find_misses(self._fixture(Path(tmp), sparse, job_env, run, wf_env, run_env), audit)

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
                "w.yml run Check out: scripts/ci/dyn.py calls importlib.import_module (line 2), which this check "
                "cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
            ],
        )
        audit = {("scripts/ci/dyn.py", "importlib.import_module"): "loads helper.py, listed beside it"}
        self.assertEqual(self._misses(listed, audit=audit), [])

    def test_fixture_stale_audit_entries_fail(self) -> None:
        listed = self.block("scripts/ci/dyn.py", "scripts/ci/helper.py", "scripts/ci/deadline_http.py")
        audit = {
            ("scripts/ci/dyn.py", "importlib.import_module"): "loads helper.py, listed beside it",
            ("scripts/ci/dyn.py", "runpy.run_path"): "a call the file does not make",
            ("scripts/ci/gone.py", "importlib.import_module"): "a file that does not exist",
        }
        self.assertEqual(
            self._misses(listed, audit=audit),
            [
                "DYNAMIC_IMPORT_AUDIT: scripts/ci/dyn.py runpy.run_path: scripts/ci/dyn.py no longer makes that "
                "call, drop the entry",
                "DYNAMIC_IMPORT_AUDIT: scripts/ci/gone.py importlib.import_module: the file is gone, drop the entry",
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
                "w.yml run Check out: scripts/ci/varpath.py calls sys.path.append (line 2), which this check "
                "cannot follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
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
        # A line naming the script that shlex cannot split, or an export, cannot be verified.
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

    def test_fixture_codex_a_rebound_name_is_not_fixed(self) -> None:
        # P = "scripts/a"; P += "b": the insert is of scripts/ab, so P is not a fixed path.
        self.assertEqual(
            self._misses(self.block("scripts/ci/rebind.py", "scripts/a/rbmod.py")),
            [
                "w.yml run Check out: scripts/ci/rebind.py calls sys.path.insert (line 4), which this check cannot "
                "follow; make the import static or audit it in DYNAMIC_IMPORT_AUDIT"
            ],
        )

    def test_fixture_f3_run_as_module_needs_the_package_init(self) -> None:
        # `python -m mpkg.main` imports mpkg (its __init__.py) before main's `from .helper import go`.
        listed = self.block("scripts/ci/mpkg/main.py", "scripts/ci/mpkg/helper.py")
        for run in ("cd scripts/ci && python3 -m mpkg.main", "python -u -m mpkg.main --flag"):
            with self.subTest(run=run):
                self.assertEqual(
                    self._misses(listed, run=run),
                    [
                        "w.yml run Check out: scripts/ci/mpkg/main.py imports scripts/ci/mpkg/__init__.py, "
                        "not in its sparse checkout"
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


if __name__ == "__main__":
    unittest.main()
