#!/usr/bin/env python3
"""A non-cone sparse checkout carries every scripts/ci module its listed scripts import.

Many scripts/ci/*.py import siblings (`import deadline_http` after a sys.path insert of their own
folder, or `from x import y`, sometimes lazily inside a function). A workflow step that checks out a
few files with `sparse-checkout` and `sparse-checkout-cone-mode: false` must list those siblings too,
or the script dies with ModuleNotFoundError at run time: #40631 left deadline_http.py out of
ios-reliability-matrix.yml's runner job.

For every job and every actions/checkout step with a non-cone `sparse-checkout`, this test takes each
listed scripts/ci/**.py file, follows its imports transitively (ast, every `import X` and
`from X import ...` at any depth, functions included) and keeps the names that resolve to
scripts/ci/X.py, or to scripts/ci/<sub>/X.py when the importing script lives in scripts/ci/<sub>/
(its own folder is searched first, as Python's sys.path[0] is). Packages (X/__init__.py) and dotted
names (X.Y -> X/Y.py) resolve the same way. Relative imports resolve against the importing module's
package: `from . import a` loads pkg/__init__.py and pkg/a.py if it exists, `from .x import y` loads
pkg/x.py (or pkg/x/__init__.py and pkg/x/y.py), and each extra dot goes one folder up.

Each module in that closure must be checked out by the list. Git decides, not this test: for each
distinct list it builds a throwaway repo holding the listed files and the candidate modules, runs
`git sparse-checkout set --no-cone` with the list's patterns verbatim, and reads which files
`git ls-files -t` leaves without the skip-worktree bit. So directory entries, globs, leading slashes
and "!" exclusions mean exactly what they mean to actions/checkout (a "!file" exclusion beats a
later "dir/" include, as git matches the file itself before its parents).

Optional imports are skipped: an import inside a `try:` body whose handlers catch ImportError,
ModuleNotFoundError (or a bare `except:`/`except Exception`/`BaseException`) is not followed, since
the script runs without it. Imports have no allowlist.

The same lists must also hold the repo files their tests read. #41164 at af61f28e added a test to
tests/test_risk_tier.py that reads `ROOT / ".github/workflows/risk-tier.yml"`; risk-tier-tests.yml
checked out only the test and its script, so CI died with FileNotFoundError. For each test file
(test_*.py or *_test.py) the list names by exact path and the job's `run:` steps name, every path
it builds statically (`ROOT / "a/b"`, `ROOT / "a" / "b"`, `ROOT.joinpath(...)`, `.parents[n]`,
`os.path.join(HERE, ...)`, `open("a/b")`, `Path("a/b")`, `FILE = "a/b"; open(FILE)`) and reads or
runs (open() for reading, read_text/read_bytes, a module loaded by file, an argv element of a
subprocess, a path option's default, a call into its own function that reads that parameter) must
be checked out when it is a file in the repo, by the same git oracle. Writes do not count. A name's
value is the one live at the read, in program order (branches and loops keep what every path agrees
on), and a function sees a module name only when every assignment to it gives the same path, so
tmp fixtures never count. _ReadFinder has the details.

Plain scripts the job runs are checked the same way: perf-cron.py reads perf-budgets.json, and the
measure job of cmux-next-perf-budgets.yml checks out perf-cron.py alone. A script's subcommand may
never reach a read, so a script read the job provably never reaches is listed in READ_ALLOWLIST with
the reason and a `reach` pattern: the invocation (subcommand or flag) that would reach the read. The
entry fails when that pattern shows up in the job's `run:` steps, when its reason is blank, and when
the read is no longer flagged (a stale entry), so the list cannot rot. When in doubt, add the path to
the sparse list instead.

Run: python3 tests/test_ci_sparse_checkout_imports.py
"""

from __future__ import annotations

import ast
import os
import posixpath
import re
import subprocess
import tempfile
import textwrap
import unittest
from functools import lru_cache
from pathlib import Path

import yaml
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
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


@lru_cache(maxsize=None)
def _git_checked_out(entries: tuple[str, ...], paths: frozenset[str]) -> frozenset[str]:
    """Which of `paths` git checks out with these non-cone sparse patterns.

    Git is the oracle: a throwaway repo holding every path (empty files) is committed, then
    `git sparse-checkout set --no-cone` gets the patterns exactly as the workflow lists them, and
    the files git leaves without the skip-worktree bit (`git ls-files -t`: "H", not "S") are in.
    """
    if not paths:
        return frozenset()
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        _git(repo, "init", "-q")
        for rel in paths:
            (repo / rel).parent.mkdir(parents=True, exist_ok=True)
            (repo / rel).touch()
        _git(repo, "add", "-A")
        _git(repo, "commit", "-q", "--no-verify", "-m", "sparse oracle")
        _git(repo, "sparse-checkout", "set", "--no-cone", "--stdin", stdin="".join(f"{e}\n" for e in entries))
        out = _git(repo, "ls-files", "-t", "-z")
    present = set()
    for record in out.split("\0"):
        if record:
            tag, rel = record.split(" ", 1)
            if tag != "S":
                present.add(rel)
    return frozenset(present & paths)


def checked_out(entries: list[str], paths: set[str], root: Path) -> frozenset[str]:
    """Which repo-relative files in `paths` a non-cone sparse checkout with these entries holds.

    The throwaway repo also carries every entry that names a file in `root`, so the patterns see
    the same neighbours they would in the real tree. Cached per (entries, paths).
    """
    named = {e.lstrip("/") for e in entries if not e.startswith("!")}
    named = {rel for rel in named if rel and (root / rel).is_file()}
    return _git_checked_out(tuple(entries), frozenset(paths | named)) & paths


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


# --- import graph -----------------------------------------------------------------------------


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


def imported_names(source: str) -> set[tuple[int, str]]:
    """(level, module name) pairs imported anywhere in `source`, minus those guarded by an ImportError try.

    Level 0 is an absolute name. Level n > 0 is relative to the importing module's package, n - 1
    folders up; the name "" is that package itself (its __init__.py).
    """
    tree = ast.parse(source)
    optional: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Try) and any(_catches_import_error(h) for h in node.handlers):
            for stmt in node.body:
                for inner in ast.walk(stmt):
                    if isinstance(inner, (ast.Import, ast.ImportFrom)):
                        optional.add(id(inner))
    names: set[tuple[int, str]] = set()
    for node in ast.walk(tree):
        if id(node) in optional:
            continue
        if isinstance(node, ast.Import):
            names.update((0, alias.name) for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0 and not node.module:
                continue
            module = node.module or ""
            names.add((node.level, module))
            # `from pkg import mod` / `from . import mod` may name a submodule.
            prefix = f"{module}." if module else ""
            names.update((node.level, prefix + alias.name) for alias in node.names if alias.name != "*")
    return names


def _resolve_under(base: str, parts: list[str], root: Path) -> list[str]:
    """Files `parts` loads below folder `base`: each package's __init__.py, then the module."""
    if not parts:
        init = f"{base}/__init__.py"
        return [init] if (root / init).is_file() else []
    files = []
    for n in range(1, len(parts) + 1):
        stem = "/".join([base, *parts[:n]])
        if (root / f"{stem}.py").is_file():
            files.append(f"{stem}.py")
            break  # a module, not a package: deeper names are attributes
        if (root / stem / "__init__.py").is_file():
            files.append(f"{stem}/__init__.py")
            continue
        break
    return files


def resolve(name: str, script: str, root: Path, level: int = 0) -> list[str]:
    """Repo-relative files a module name loads from scripts/ci (own folder first), or [].

    A relative name (level > 0) resolves against the importing module's package: its own folder,
    one folder further up per extra dot.
    """
    script_dir = script.rsplit("/", 1)[0]
    parts = name.split(".") if name else []
    if level > 0:
        folders = script_dir.split("/")
        if level - 1 >= len(folders):
            return []
        base = "/".join(folders[: len(folders) - (level - 1)])
        return _resolve_under(base, parts, root)
    search = [script_dir] if script_dir == CI_DIR else [script_dir, CI_DIR]
    for base in search:
        files = _resolve_under(base, parts, root)
        if files:
            return files
    return []


def import_closure(script: str, root: Path) -> dict[str, str]:
    """Every scripts/ci module `script` needs transitively -> the module that imports it."""
    found: dict[str, str] = {}
    todo = [script]
    seen = {script}
    while todo:
        current = todo.pop()
        try:
            source = (root / current).read_text(encoding="utf-8")
            names = imported_names(source)
        except (OSError, SyntaxError, UnicodeDecodeError):
            continue
        for level, name in sorted(names):
            for dep in resolve(name, current, root, level):
                if dep not in seen:
                    seen.add(dep)
                    found[dep] = current
                    todo.append(dep)
    return found


# --- workflows --------------------------------------------------------------------------------


def non_cone_sparse_steps(root: Path):
    """(workflow, job, step name, entries) for each actions/checkout step with a non-cone sparse list."""
    for path in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        jobs = doc.get("jobs") if isinstance(doc, dict) else None
        for job_id, job in (jobs or {}).items():
            for index, step in enumerate((job or {}).get("steps") or []):
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
                yield path.name, str(job_id), name, sparse_entries(raw)


def find_misses(root: Path) -> list[str]:
    """One line per (step, missing module), naming the module that imports it."""
    misses = []
    for workflow, job, step, entries in non_cone_sparse_steps(root):
        listed = listed_ci_scripts(entries, root)
        closures = {script: import_closure(script, root) for script in listed}
        candidates = set(listed).union(*closures.values())
        present = checked_out(entries, candidates, root)
        found: dict[str, tuple[str, str]] = {}  # missing module -> (importer, listed script)
        for script in listed:
            if script not in present:
                continue  # excluded by a "!" entry: not checked out, nothing to run
            for dep, importer in closures[script].items():
                if dep in present:
                    continue
                # Prefer the shortest chain: an importer that is itself listed.
                if dep not in found or (importer == script and found[dep][0] != found[dep][1]):
                    found[dep] = (importer, script)
        for dep, (importer, script) in sorted(found.items()):
            misses.append(
                f"{workflow} {job} {step}: {importer} imports {dep}, not in its sparse checkout"
                + ("" if importer == script else f" (via {script})")
            )
    return misses


# --- files a run script reads ------------------------------------------------------------------


def is_test_file(rel: str) -> bool:
    """A unittest/pytest file: it runs every test in it, so every file it reads must be there."""
    name = rel.rsplit("/", 1)[-1]
    return name.startswith("test_") or name.endswith("_test.py")


def listed_run_scripts(entries: list[str], run_text: str, root: Path, tests_only: bool = False) -> list[str]:
    """.py files the entries name by exact path that the job's `run:` steps also name.

    Test files and plain scripts alike; `tests_only` keeps only test files (the scan before scripts
    were covered).
    """
    out = []
    for entry in entries:
        if entry.startswith("!"):
            continue
        rel = entry.lstrip("/")
        if not rel.endswith(".py") or any(ch in rel for ch in "*?["):
            continue
        if tests_only and not is_test_file(rel):
            continue
        if (root / rel).is_file() and re.search(rf"(?<![\w.-]){re.escape(rel)}\b", run_text):
            out.append(rel)
    return out


def _norm(rel: str) -> str | None:
    """A repo-relative posix path, normalized; None if it is absolute or leaves the repo."""
    if rel.startswith("/"):
        return None
    out = posixpath.normpath(rel) if rel else ""
    if out == ".":
        return ""
    if out == ".." or out.startswith("../") or (rel.startswith(_PARAM) and not out.startswith(_PARAM)):
        return None
    return out


def _join(base: str, *parts: str) -> str | None:
    return _norm(posixpath.join(base, *parts) if base else posixpath.join(*parts))


def _dirname(rel: str) -> str | None:
    if rel.startswith(_PARAM) and "/" not in rel:
        return None  # a parameter's folder is unknown
    return None if rel == "" else rel.rsplit("/", 1)[0] if "/" in rel else ""


_PATH_CALLS = {"Path", "PurePath", "PosixPath", "pathlib.Path", "pathlib.PurePath", "pathlib.PosixPath"}
_IDENTITY_METHODS = {"resolve", "absolute", "expanduser"}
_IDENTITY_OS = {"os.path.abspath", "os.path.realpath", "os.path.normpath", "os.fspath", "str"}
# Calls that run their argument (a script path in an argv list or alone): the job needs that file too.
_RUN_CALLS = {"subprocess.run", "subprocess.call", "subprocess.check_call", "subprocess.check_output",
              "subprocess.Popen", "check_call", "check_output", "Popen"}
# Calls that load the file at a positional index (or keyword).
_LOAD_CALLS = {"spec_from_file_location": (1, "location"), "SourceFileLoader": (1, "path"),
               "run_path": (0, "path_name"), "copyfile": (0, "src"), "copy": (0, "src"), "copy2": (0, "src")}
_LOAD_MODULES = {"spec_from_file_location": "importlib.util", "SourceFileLoader": "importlib.machinery",
                 "run_path": "runpy", "copyfile": "shutil", "copy": "shutil", "copy2": "shutil"}
_READ_METHODS = {"read_text", "read_bytes"}
# A function parameter's value inside its body: `{_PARAM}name` (+ "/suffix" once joined).
_PARAM = "\0param:"


def _dotted(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        head = _dotted(node.value)
        return f"{head}.{node.attr}" if head else None
    return None


def _literal(node: ast.AST) -> str | None:
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None


def _reads_mode(call: ast.Call, index: int) -> bool:
    """True when the call's mode (positional `index` or `mode=`) is absent or a literal that reads."""
    mode: ast.AST | None = call.args[index] if len(call.args) > index else None
    for keyword in call.keywords:
        if keyword.arg == "mode":
            mode = keyword.value
    if mode is None:
        return True
    literal = _literal(mode)
    return literal is not None and not set(literal) & set("wax")


def _bound_names(target: ast.AST) -> set[str]:
    """Names a binding target (or a pattern) rebinds."""
    out = set()
    for node in ast.walk(target):
        if isinstance(node, ast.Name):
            out.add(node.id)
        elif isinstance(node, (ast.MatchAs, ast.MatchStar)) and node.name:
            out.add(node.name)
        elif isinstance(node, ast.MatchMapping) and node.rest:
            out.add(node.rest)
    return out


def _local_names(func: ast.AST) -> set[str]:
    """Names local to a function: its parameters and every name its own body binds (not nested scopes)."""
    args = func.args
    names = {a.arg for a in [*args.posonlyargs, *args.args, *args.kwonlyargs]}
    names |= {a.arg for a in (args.vararg, args.kwarg) if a is not None}
    declared: set[str] = set()
    for node in _own_nodes(func.body if isinstance(func.body, list) else [ast.Expr(func.body)]):
        if isinstance(node, (ast.Global, ast.Nonlocal)):
            declared.update(node.names)
        names |= _binds(node)
    return names - declared


def _own_nodes(body: list[ast.stmt]):
    """Every node of these statements, not descending into nested functions, lambdas or classes."""
    todo = list(body)
    while todo:
        node = todo.pop()
        yield node
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
            continue
        todo.extend(ast.iter_child_nodes(node))


def _binds(node: ast.AST) -> set[str]:
    """Names one node binds in the scope it runs in."""
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        return {node.name}
    if isinstance(node, ast.Assign):
        return set().union(*(_bound_names(t) for t in node.targets))
    if isinstance(node, (ast.AnnAssign, ast.AugAssign, ast.NamedExpr)):
        return _bound_names(node.target)
    if isinstance(node, (ast.For, ast.AsyncFor)):
        return _bound_names(node.target)
    if isinstance(node, ast.withitem) and node.optional_vars is not None:
        return _bound_names(node.optional_vars)
    if isinstance(node, ast.ExceptHandler) and node.name:
        return {node.name}
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        return {(a.asname or a.name).split(".")[0] for a in node.names}
    if isinstance(node, ast.Delete):
        return set().union(*(_bound_names(t) for t in node.targets))
    if isinstance(node, ast.match_case):
        return _bound_names(node.pattern)
    return set()


def _agree(*envs: dict[str, str]) -> dict[str, str]:
    """The bindings every path agrees on."""
    first, *rest = envs
    return {k: v for k, v in first.items() if all(e.get(k) == v for e in rest)}


class _ReadFinder:
    """The repo paths a script reads, from the value each path expression has where the read happens.

    A read is `open()` in a reading mode, `.read_text()`/`.read_bytes()`/`.open()` on a path, a
    module loaded by file (`spec_from_file_location`, `SourceFileLoader`, `runpy.run_path`), a copy
    source, an argv element of a subprocess or `os.exec*`/`os.spawn*` call (running a repo script is
    a need of the job too), or an argument to one of the script's own functions that reads that
    parameter. Writes (`open(.., "w")`, `write_text`, `mkdir`) are not reads.

    Names are tracked in program order: an assignment replaces the value, branches keep only what
    every path agrees on, and a loop body sees what its first and later iterations agree on. A
    function sees a module name only when every module-level assignment to it gives the same value.
    A string constant is a path from the repo root (where the job runs the script), so
    `FILE = "docs/x.yml"; open(FILE)` counts.
    """

    def __init__(self, script: str, tree: ast.Module) -> None:
        self.script = script
        self.tree = tree
        self.funcs: dict[str, ast.AST] = {}
        defined: dict[str, int] = {}
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                defined[node.name] = defined.get(node.name, 0) + 1
                self.funcs[node.name] = node
        self.funcs = {n: f for n, f in self.funcs.items() if defined[n] == 1}
        self.param_reads: dict[str, dict[str, set[str]]] = {}  # function -> parameter -> suffixes read
        self.globals = self._stable_globals()

    # -- values --

    def _stable_globals(self) -> dict[str, str]:
        values: dict[str, list[ast.AST | None]] = {}
        global_in_funcs: set[str] = set()
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Global):
                global_in_funcs.update(node.names)
        for node in _own_nodes(self.tree.body):
            names = _binds(node)
            if not names:
                continue
            value = node.value if isinstance(node, ast.Assign) and all(
                isinstance(t, ast.Name) for t in node.targets) else None
            if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                value = node.value
            for name in names:
                values.setdefault(name, []).append(value)
        env: dict[str, str] = {}
        changed = True
        while changed:
            changed = False
            for name, nodes in values.items():
                if name in env or name in global_in_funcs or any(v is None for v in nodes):
                    continue
                results = {self.eval(v, env) for v in nodes}
                if len(results) == 1 and None not in results:
                    env[name] = results.pop()
                    changed = True
        return env

    def _string(self, node: ast.AST, env: dict[str, str]) -> str | None:
        literal = _literal(node)
        return literal if literal is not None else self.eval(node, env) if isinstance(node, ast.Name) else None

    def eval(self, node: ast.AST, env: dict[str, str]) -> str | None:
        if isinstance(node, ast.Constant):
            return _norm(node.value) if isinstance(node.value, str) and node.value else None
        if isinstance(node, ast.Name):
            return self.script if node.id == "__file__" else env.get(node.id)
        if isinstance(node, ast.Attribute):
            if node.attr == "parent":
                base = self.eval(node.value, env)
                return None if base is None else _dirname(base)
            return None
        if isinstance(node, ast.Subscript):
            if isinstance(node.value, ast.Attribute) and node.value.attr == "parents":
                index = node.slice
                if isinstance(index, ast.Constant) and isinstance(index.value, int) and index.value >= 0:
                    out = self.eval(node.value.value, env)
                    for _ in range(index.value + 1):
                        out = None if out is None else _dirname(out)
                    return out
            return None
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            base, part = self.eval(node.left, env), self._string(node.right, env)
            return None if base is None or part is None else _join(base, part)
        if isinstance(node, ast.Call):
            func = _dotted(node.func)
            if func in _PATH_CALLS or func in _IDENTITY_OS:
                if len(node.args) != 1 or (node.keywords and func not in _PATH_CALLS):
                    return None
                return self.eval(node.args[0], env)
            if node.keywords:
                return None
            if func == "os.path.dirname" and len(node.args) == 1:
                base = self.eval(node.args[0], env)
                return None if base is None else _dirname(base)
            if func == "os.path.join" and node.args:
                base = self.eval(node.args[0], env)
                parts = [self._string(a, env) for a in node.args[1:]]
                return None if base is None or None in parts else _join(base, *parts)
            if isinstance(node.func, ast.Attribute):
                method = node.func.attr
                if method in _IDENTITY_METHODS and not node.args:
                    return self.eval(node.func.value, env)
                if method == "joinpath" and node.args:
                    base = self.eval(node.func.value, env)
                    parts = [self._string(a, env) for a in node.args]
                    return None if base is None or None in parts else _join(base, *parts)
        return None

    # -- reads --

    def _sink_args(self, call: ast.Call) -> list[ast.AST]:
        """The argument expressions this call reads or runs."""
        func = _dotted(call.func) or ""
        last = call.func.attr if isinstance(call.func, ast.Attribute) else func
        if func in {"open", "io.open"} and call.args:
            return [call.args[0]] if _reads_mode(call, 1) else []
        if isinstance(call.func, ast.Attribute) and not call.args and last in _READ_METHODS:
            return [call.func.value]
        if isinstance(call.func, ast.Attribute) and last == "open" and func not in {"os.open"}:
            return [call.func.value] if _reads_mode(call, 0) else []
        if last in _LOAD_CALLS and (func == last or func == f"{_LOAD_MODULES[last]}.{last}"):
            index, keyword = _LOAD_CALLS[last]
            args = [call.args[index]] if len(call.args) > index else []
            return args + [k.value for k in call.keywords if k.arg == keyword]
        if last == "add_argument":
            # A path option's default is what the script opens unless the job passes the option.
            return [k.value for k in call.keywords if k.arg == "default"]
        if func in _RUN_CALLS or func.startswith(("os.exec", "os.spawn", "os.posix_spawn")):
            out = []
            for arg in [*call.args, *(k.value for k in call.keywords if k.arg == "args")]:
                out.extend(arg.elts if isinstance(arg, (ast.List, ast.Tuple)) else [arg])
            return [a for a in out if not isinstance(a, ast.Starred)]
        return []

    def _call_reads(self, call: ast.Call, env: dict[str, str]) -> list[str]:
        """Path values this call reads: its own sinks, or a read its callee does with an argument."""
        out = [v for v in (self.eval(a, env) for a in self._sink_args(call)) if v is not None]
        callee = self.funcs.get(call.func.id) if isinstance(call.func, ast.Name) else None
        reads = self.param_reads.get(call.func.id, {}) if callee is not None else {}
        if reads:
            args = callee.args
            positional = [a.arg for a in [*args.posonlyargs, *args.args]]
            bound = dict(zip(positional, call.args))
            bound.update({k.arg: k.value for k in call.keywords if k.arg})
            for param, suffixes in reads.items():
                value = self.eval(bound[param], env) if param in bound else None
                if value is not None:
                    out.extend(v for v in (_join(value, s) if s else value for s in suffixes) if v is not None)
        return out

    def record(self, expr: ast.AST | None, env: dict[str, str], shadow: frozenset[str] = frozenset()) -> None:
        """Note every read inside `expr`; names a lambda or comprehension rebinds are unknown in it."""
        if expr is None:
            return
        if shadow:
            env = {k: v for k, v in env.items() if k not in shadow}
        if isinstance(expr, ast.Lambda):
            self.record(expr.body, env, frozenset(_local_names(expr)))
            return
        if isinstance(expr, (ast.ListComp, ast.SetComp, ast.GeneratorExp, ast.DictComp)):
            names = frozenset().union(*(_bound_names(g.target) for g in expr.generators))
            for child in ast.iter_child_nodes(expr):
                self.record(child, env, names)
            return
        if isinstance(expr, ast.Call):
            self.reads.extend(self._call_reads(expr, env))
        for child in ast.iter_child_nodes(expr):
            if isinstance(child, ast.expr) or isinstance(child, (ast.keyword, ast.comprehension)):
                self.record(child, env)

    # -- statements --

    def run(self) -> set[str]:
        """Concrete reads of the whole module; also fills param_reads for calls into its functions."""
        for _ in range(5):
            before = {f: {p: set(s) for p, s in ps.items()} for f, ps in self.param_reads.items()}
            self.reads: list[str] = []
            self.block(self.tree.body, dict(self.globals), frozenset())
            if self.param_reads == before:
                break
        return {r for r in self.reads if _PARAM not in r}

    def function(self, func: ast.AST, outer_locals: frozenset[str], def_env: dict[str, str]) -> None:
        local = _local_names(func)
        hidden = outer_locals | local
        env = {k: v for k, v in self.globals.items() if k not in hidden}
        params = [a.arg for a in [*func.args.posonlyargs, *func.args.args, *func.args.kwonlyargs]]
        assigned = {n for node in _own_nodes(func.body) for n in _binds(node)}
        for param in params:
            if param not in assigned:
                env[param] = _PARAM + param
        start = len(self.reads)
        self.block(func.body, env, frozenset(hidden))
        found: dict[str, set[str]] = {}
        for value in self.reads[start:]:
            if value.startswith(_PARAM):
                name, _, suffix = value[len(_PARAM):].partition("/")
                found.setdefault(name, set()).add(suffix)
        # A call that leaves out a parameter reads its default.
        args = func.args
        positional = [*args.posonlyargs, *args.args]
        defaults = [*zip(positional[len(positional) - len(args.defaults):], args.defaults),
                    *((a, d) for a, d in zip(args.kwonlyargs, args.kw_defaults) if d is not None)]
        for arg, default in defaults:
            value = self.eval(default, def_env)
            if value is not None:
                self.reads.extend(v for v in (_join(value, s) if s else value
                                              for s in found.get(arg.arg, ())) if v is not None)
        if found and func.name in self.funcs and self.funcs[func.name] is func:
            merged = self.param_reads.setdefault(func.name, {})
            for name, suffixes in found.items():
                merged.setdefault(name, set()).update(suffixes)

    def block(self, body: list[ast.stmt], env: dict[str, str], locals_: frozenset[str]) -> dict[str, str]:
        env = dict(env)
        for stmt in body:
            env = self.stmt(stmt, env, locals_)
        return env

    def _kill(self, env: dict[str, str], names: set[str]) -> dict[str, str]:
        return {k: v for k, v in env.items() if k not in names}

    def _loop(self, stmt, env, locals_, head) -> dict[str, str]:
        state = env
        for _ in range(5):
            entry = head(state)
            after = self.block(stmt.body, entry, locals_)
            merged = _agree(state, after)
            if merged == state:
                break
            state = merged
        return self.block(stmt.orelse, state, locals_)

    def stmt(self, stmt: ast.stmt, env: dict[str, str], locals_: frozenset[str]) -> dict[str, str]:
        walrus = {n.target.id for n in ast.walk(stmt) if isinstance(n, ast.NamedExpr)
                  } if not isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) else set()
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for expr in [*stmt.decorator_list, *stmt.args.defaults, *stmt.args.kw_defaults]:
                self.record(expr, env)
            self.function(stmt, locals_, env)
            return self._kill(env, {stmt.name})
        if isinstance(stmt, ast.ClassDef):
            for expr in [*stmt.decorator_list, *stmt.bases]:
                self.record(expr, env)
            self.block(stmt.body, env, locals_)
            return self._kill(env, {stmt.name})
        if isinstance(stmt, (ast.Assign, ast.AnnAssign)):
            self.record(stmt.value, env)
            targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
            value = self.eval(stmt.value, env) if stmt.value is not None else None
            env = self._kill(env, set().union(*(_bound_names(t) for t in targets)) | walrus)
            if value is not None and len(targets) == 1 and isinstance(targets[0], ast.Name):
                env[targets[0].id] = value
            return env
        if isinstance(stmt, ast.If):
            self.record(stmt.test, env)
            env = self._kill(env, walrus)
            return _agree(self.block(stmt.body, env, locals_), self.block(stmt.orelse, env, locals_))
        if isinstance(stmt, (ast.For, ast.AsyncFor)):
            self.record(stmt.iter, env)
            env = self._kill(env, walrus)
            target = _bound_names(stmt.target)
            return self._loop(stmt, env, locals_, lambda e: self._kill(e, target))
        if isinstance(stmt, ast.While):
            def head(e):
                self.record(stmt.test, e)
                return self._kill(e, walrus)
            return self._loop(stmt, self._kill(env, walrus), locals_, head)
        if isinstance(stmt, (ast.With, ast.AsyncWith)):
            names: set[str] = set(walrus)
            for item in stmt.items:
                self.record(item.context_expr, env)
                names |= _binds(item)
            return self.block(stmt.body, self._kill(env, names), locals_)
        if isinstance(stmt, (ast.Try, getattr(ast, "TryStar", ast.Try))):
            after_body = self.block(stmt.body, env, locals_)
            assigned = {n for node in _own_nodes(stmt.body) for n in _binds(node)}
            entry = self._kill(env, assigned)
            ends = [self.block(stmt.orelse, after_body, locals_)]
            for handler in stmt.handlers:
                self.record(handler.type, entry)
                ends.append(self.block(handler.body, self._kill(entry, _binds(handler)), locals_))
            return self.block(stmt.finalbody, _agree(*ends), locals_)
        if isinstance(stmt, ast.Match):
            self.record(stmt.subject, env)
            ends = [env]
            for case in stmt.cases:
                case_env = self._kill(env, _binds(case))
                self.record(case.guard, case_env)
                ends.append(self.block(case.body, case_env, locals_))
            return _agree(*ends)
        for child in ast.iter_child_nodes(stmt):
            if isinstance(child, ast.expr):
                self.record(child, env)
        return self._kill(env, _binds(stmt) | walrus)


def read_paths(script: str, root: Path) -> set[str]:
    """Repo files `script` reads or runs by a statically known path (`ROOT / "a/b"`, `open(FILE)`, ...).

    Only paths that are files in `root` count; directories, globs and anything built from a value
    that is not known where the read happens are skipped.
    """
    try:
        tree = ast.parse((root / script).read_text(encoding="utf-8"))
    except (OSError, SyntaxError, UnicodeDecodeError):
        return set()
    return {rel for rel in _ReadFinder(script, tree).run() if rel and rel != script and (root / rel).is_file()}


def _job_run_text(root: Path, workflow: str, job: str) -> str:
    doc = yaml.safe_load((root / ".github" / "workflows" / workflow).read_text(encoding="utf-8")) or {}
    steps = ((doc.get("jobs") or {}).get(job) or {}).get("steps") or []
    return "\n".join(str(step.get("run") or "") for step in steps if isinstance(step, dict))


def read_miss_records(root: Path, tests_only: bool = False) -> list[tuple[str, str, str, str, str]]:
    """(workflow, job, step, run file, repo file it reads that the sparse list leaves out)."""
    records = []
    for workflow, job, step, entries in non_cone_sparse_steps(root):
        scripts = listed_run_scripts(entries, _job_run_text(root, workflow, job), root, tests_only)
        reads = {script: read_paths(script, root) for script in scripts}
        candidates = set(scripts).union(*reads.values())
        present = checked_out(entries, candidates, root)
        for script in scripts:
            if script not in present:
                continue
            for rel in sorted(reads[script] - present):
                records.append((workflow, job, step, script, rel))
    return records


def _read_miss_line(record: tuple[str, str, str, str, str]) -> str:
    workflow, job, step, script, rel = record
    return f"{workflow} {job} {step}: {script} reads {rel}, not in its sparse checkout"


def find_read_misses(root: Path, tests_only: bool = False) -> list[str]:
    """One line per (step, run file, repo file it reads that the sparse list leaves out)."""
    return [_read_miss_line(record) for record in read_miss_records(root, tests_only)]


# A script read the job never reaches: (workflow, job, script, path, reach, reason). `reach` is a regex
# for the invocation that would reach the read (the subcommand or flag); the entry is void when the
# job's `run:` steps match it. The reason names the condition. Checked against the tree at 2026-11-11.
READ_ALLOWLIST: list[tuple[str, str, str, str, str, str]] = [
    ("ci-web.yml", "webviews-test-history", "scripts/ci/webviews_test_history.py", "scripts/cmux-next/web-bundle-key.py",
     r"webviews_test_history\.py\s+inputs\b",
     "run only by inputs(), the `inputs` subcommand; this job runs `fetch` and `record` and takes the key the "
     "shards' full checkouts computed"),
    ("cmux-next-frame-pacing.yml", "bench", "scripts/cmux-next/instant-new-surfaces-bench.py",
     "scripts/cmux-next/new-pane-start-state-bench.py", r"--bench=new-pane-start-state",
     "exec'd only when argv holds `--bench=new-pane-start-state` (scripts/measure/instant-new-surfaces.sh's "
     "fleet route); no step of this job passes it"),
    ("cmux-next-frame-pacing.yml", "bench", "scripts/cmux-next/bench-startup.py", "scripts/cmux-next/perf-stress-session.py",
     r"--profile[ =]stress",
     "loaded only by seed_stress(), under `--profile stress`; this job passes `--profile empty` and "
     "`--profile realistic`"),
    ("cmux-next-media.yml", "route", "scripts/cmux-next/media/whats-new-clips.py", "scripts/pr-media.py",
     r"whats-new-clips\.py\s+publish",
     "loaded only by pr_media_module(), from the `publish` and `publish-auto` subcommands; this job runs `plan`"),
    ("cmux-next-perf-budgets.yml", "measure", "scripts/cmux-next/perf-cron.py", "scripts/ci/cmux_tui_tree_key.py",
     r"perf-cron\.py\s+plan\b",
     "run only by tree_published(), reached only from the `plan` subcommand; this job runs `fleet-check`, "
     "`run-part` and `part-cleanup`"),
    ("cmux-next-perf-budgets.yml", "measure", "scripts/cmux-next/perf-cron.py", "scripts/cmux-next/perf-budgets.json",
     r"perf-cron\.py\s+report\b",
     "read only by cmd_report (the `report` subcommand) when a measurement finishes; this job runs `fleet-check`, "
     "`run-part` and `part-cleanup` (the report job checks it out)"),
    ("cmux-next-perf-budgets.yml", "measure", "scripts/cmux-next/perf-cron.py", "scripts/cmux-next/perf-budgets.py",
     r"perf-cron\.py\s+report\b",
     "loaded only by load_budgets_module(), from cmd_report (the `report` subcommand); this job runs "
     "`fleet-check`, `run-part` and `part-cleanup` (the report job checks it out)"),
    ("cmux-next-perf-budgets.yml", "report", "scripts/cmux-next/perf-cron.py", "scripts/ci/cmux_tui_tree_key.py",
     r"perf-cron\.py\s+plan\b",
     "run only by tree_published(), reached only from the `plan` subcommand; this job runs `fetch-result`, "
     "`report` and `dispatch-next`"),
    ("cmux-next-quality-report.yml", "report", "scripts/cmux-next/perf-cron.py", "scripts/ci/cmux_tui_tree_key.py",
     r"perf-cron\.py\s+plan\b",
     "run only by tree_published(), reached only from the `plan` subcommand; this job runs `fetch-state`"),
    ("stable-next.yml", "tick", "scripts/ci/stable_next.py", "scripts/ci/publish-nightly-next-r2.py",
     r"stable_next\.py\s+write-feed",
     "loaded only by _r2_module(), from the `write-feed` subcommand (stable-next-rollback.yml); this job runs "
     "`window` and `published-tonight`"),
    ("stable-next.yml", "crash-class", "scripts/ci/stable_next.py", "scripts/ci/publish-nightly-next-r2.py",
     r"stable_next\.py\s+write-feed",
     "loaded only by _r2_module(), from the `write-feed` subcommand (stable-next-rollback.yml); this job runs "
     "`crash-delta`"),
    ("stable-next.yml", "soak", "scripts/ci/stable_next.py", "scripts/ci/publish-nightly-next-r2.py",
     r"stable_next\.py\s+write-feed",
     "loaded only by _r2_module(), from the `write-feed` subcommand (stable-next-rollback.yml); this job runs "
     "`soak` and `sentry-new-crashes`"),
]


def unhandled_read_misses(root: Path, allowlist=READ_ALLOWLIST, records=None) -> list[str]:
    """Every read miss no valid allowlist entry covers, then every allowlist entry that is invalid.

    An entry is invalid with a blank reason, when the job's `run:` steps match its `reach` pattern
    (the job now takes the path to the read), or when no read it names is flagged (stale).
    """
    if records is None:
        records = read_miss_records(root)
    problems = []
    covered: set[tuple[str, str, str, str]] = set()
    for workflow, job, script, rel, reach, reason in allowlist:
        entry = f"READ_ALLOWLIST entry ({workflow}, {job}, {script}, {rel})"
        if not str(reason or "").strip():
            problems.append(f"{entry} has no reason: name the condition the job never hits")
            continue
        if not str(reach or "").strip():
            problems.append(f"{entry} has no reach pattern: the invocation that would reach the read")
            continue
        if not any(r[:2] == (workflow, job) and r[3:] == (script, rel) for r in records):
            problems.append(f"{entry} is stale: the read is no longer flagged; remove the entry")
            continue
        run_text = _job_run_text(root, workflow, job).replace("\\\n", " ")
        if re.search(reach, run_text):
            problems.append(f"{entry} no longer holds: the job's run steps match {reach!r}; add the path to its sparse list")
            continue
        covered.add((workflow, job, script, rel))
    unhandled = [_read_miss_line(r) for r in records if (r[0], r[1], r[3], r[4]) not in covered]
    return unhandled + problems


# --- tests ------------------------------------------------------------------------------------


class SparseCheckoutImportTests(unittest.TestCase):
    def test_workflows_list_every_imported_ci_module(self) -> None:
        steps = list(non_cone_sparse_steps(ROOT))
        self.assertTrue(steps, "expected at least one non-cone sparse checkout in .github/workflows")
        misses = find_misses(ROOT)
        self.assertEqual(misses, [], "\n" + "\n".join(misses))

    def test_workflows_list_every_repo_file_their_tests_and_scripts_read(self) -> None:
        misses = unhandled_read_misses(ROOT)
        self.assertEqual(misses, [], "\n" + "\n".join(misses))

    def _fixture(self, tmp: Path, sparse: str) -> Path:
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
                jobs:
                  run:
                    runs-on: ubuntu-latest
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
                """
            ).replace("SPARSE", sparse),
            encoding="utf-8",
        )
        return tmp

    def _misses(self, sparse: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            return find_misses(self._fixture(Path(tmp), sparse))

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

    def test_fixture_subdir_script_resolves_own_folder_then_ci(self) -> None:
        misses = self._misses(self.block("scripts/ci/sub/step.py"))
        self.assertEqual(
            sorted(m.split(": ", 1)[1] for m in misses),
            [
                "scripts/ci/sub/step.py imports scripts/ci/deadline_http.py, not in its sparse checkout",
                "scripts/ci/sub/step.py imports scripts/ci/sub/local_helper.py, not in its sparse checkout",
            ],
        )
        self.assertEqual(self._misses(self.block("scripts/ci/sub/", "scripts/ci/deadline_http.py")), [])

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
            ["w.yml run Check out: scripts/ci/pkg/helper.py imports scripts/ci/pkg/deep.py, not in its sparse checkout"],
        )
        self.assertEqual(self._misses(self.block(*listed, "scripts/ci/pkg/deep.py")), [])
        self.assertEqual(self._misses(self.block("scripts/ci/pkg_user.py", "scripts/ci/pkg/")), [])

    def test_fixture_skips_imports_guarded_by_import_error(self) -> None:
        self.assertEqual(self._misses(self.block("scripts/ci/optional_user.py")), [])


# The workflow and test of #41164 at af61f28e, cut to what the check reads: the test opens
# .github/workflows/risk-tier.yml, which the job's sparse list left out (FileNotFoundError in CI).
RISK_TIER_TESTS_YML = """\
on: pull_request
jobs:
  tests:
    name: risk tier tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
          sparse-checkout: |
            scripts/ci/risk_tier.py
            tests/test_risk_tier.py
            tests/git_fixture_env.py
EXTRA          sparse-checkout-cone-mode: false
      - run: python3 tests/test_risk_tier.py -v
"""

TEST_RISK_TIER_PY = """\
import importlib.util
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("risk_tier", ROOT / "scripts/ci/risk_tier.py")


def test_a_held_takeback_names_the_line_to_paste_in_its_error():
    held = (ROOT / ".github/workflows/risk-tier.yml").read_text()
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out"
        out.write_text(held)
        path = os.path.join(tmp, "f")
        open(path, "w").write("x")
"""


class SparseCheckoutReadTests(unittest.TestCase):
    def _misses(self, files: dict[str, str], extra: str = "", tests_only: bool = False) -> list[str]:
        base = {
            "scripts/ci/risk_tier.py": "",
            "tests/git_fixture_env.py": "",
            ".github/workflows/risk-tier.yml": "on: pull_request\n",
            "tests/test_risk_tier.py": TEST_RISK_TIER_PY,
            ".github/workflows/risk-tier-tests.yml": RISK_TIER_TESTS_YML.replace("EXTRA", extra),
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel, body in {**base, **files}.items():
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text(body, encoding="utf-8")
            return find_read_misses(root, tests_only)

    def test_pr_41164_at_af61f28e_reports_the_unlisted_workflow_read(self) -> None:
        self.assertEqual(
            self._misses({}),
            [
                "risk-tier-tests.yml tests step 0: tests/test_risk_tier.py reads "
                ".github/workflows/risk-tier.yml, not in its sparse checkout"
            ],
        )

    def test_pr_41164_fix_passes(self) -> None:
        for entry in (".github/workflows/risk-tier.yml", "/.github/workflows/", ".github/workflows/*.yml"):
            with self.subTest(entry=entry):
                self.assertEqual(self._misses({}, extra=f"            {entry}\n"), [])

    def test_exclusion_uncovers_a_read(self) -> None:
        misses = self._misses({}, extra="            /.github/\n            !.github/workflows/risk-tier.yml\n")
        self.assertEqual(len(misses), 1, misses)

    def test_path_forms_resolve_to_repo_files(self) -> None:
        body = textwrap.dedent(
            """\
            import os
            from pathlib import Path
            REPO_ROOT = Path(__file__).resolve().parent.parent
            CI = REPO_ROOT / "scripts" / "ci"
            HERE = os.path.dirname(os.path.abspath(__file__))
            a = (CI / "a.json").read_text()
            b = REPO_ROOT.joinpath("docs", "b.md").read_text()
            c = open("docs/c.txt").read()
            d = Path("docs/d.txt").read_text()
            e = open(os.path.join(HERE, "..", "docs", "e.txt")).read()
            """
        )
        files = {f"docs/{n}": "" for n in ("b.md", "c.txt", "d.txt", "e.txt")}
        misses = self._misses({"tests/test_risk_tier.py": body, "scripts/ci/a.json": "{}", **files})
        self.assertEqual(
            sorted(m.split(": ", 1)[1].split(" reads ")[1].split(",")[0] for m in misses),
            ["docs/b.md", "docs/c.txt", "docs/d.txt", "docs/e.txt", "scripts/ci/a.json"],
        )

    def test_tmp_fixtures_missing_files_and_reassigned_names_are_not_reads(self) -> None:
        body = textwrap.dedent(
            """\
            import tempfile
            from pathlib import Path
            ROOT = Path(__file__).resolve().parents[1]
            base = ROOT
            with tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                (base / "docs/x.md").write_text("")
                (Path(tmp) / "docs/x.md").read_text()
            (ROOT / "docs/not-in-repo.md").exists()
            (ROOT / "docs").is_dir()
            """
        )
        self.assertEqual(self._misses({"tests/test_risk_tier.py": body, "docs/x.md": ""}), [])

    def _read_files(self, body: str) -> list[str]:
        files = {f"docs/{n}": "" for n in ("old.md", "live.md", "gen.md", "w.md", "a.md", "x.md", "c.yml", "d.md",
                                            "h.md", "p.md", "r.md", "j.json")}
        files["tools/run.py"] = ""
        misses = self._misses({"tests/test_risk_tier.py": textwrap.dedent(body), **files})
        return sorted(m.split(" reads ", 1)[1].split(",", 1)[0] for m in misses)

    def test_f1_only_reads_count_with_the_value_live_at_the_read(self) -> None:
        # Codex F1 on b57e775d: a repo path later replaced by a tmp path, and writes, counted as reads.
        body = """\
            import json
            import os
            import tempfile
            from pathlib import Path
            ROOT = Path(__file__).resolve().parents[1]

            def test_writes_and_superseded_paths():
                out = ROOT / "docs/old.md"
                out = Path(tempfile.mkdtemp()) / "old.md"
                out.read_text()
                (ROOT / "docs/gen.md").write_text("x")
                open(ROOT / "docs/w.md", "w").write("x")
                with open(os.path.join(ROOT, "docs", "a.md"), mode="a") as f:
                    f.write("x")
                (ROOT / "docs/x.md").exists()

            def test_reads_see_the_live_value():
                p = Path(tempfile.mkdtemp()) / "live.md"
                p = ROOT / "docs/live.md"
                p.read_text()
                with open(ROOT / "docs/r.md") as f:
                    f.read()
                json.load((ROOT / "docs/j.json").open())
        """
        self.assertEqual(self._read_files(body), ["docs/j.json", "docs/live.md", "docs/r.md"])

    def test_f1_branches_and_loops_keep_only_agreed_values(self) -> None:
        body = """\
            import sys
            from pathlib import Path
            ROOT = Path(__file__).resolve().parents[1]

            def test_branch(tmp):
                p = ROOT / "docs/old.md"
                if sys.argv:
                    p = Path(tmp)
                p.read_text()
                for q in (1, 2):
                    p.read_text()
                    p = ROOT / "docs/x.md"
                r = ROOT / "docs/live.md"
                for q in (1, 2):
                    r.read_text()
        """
        self.assertEqual(self._read_files(body), ["docs/live.md"])

    def test_f2_constant_string_paths_resolve(self) -> None:
        # Codex F2 on b57e775d: FILE = "docs/x.yml"; open(FILE) was never resolved.
        body = """\
            from pathlib import Path
            ROOT = Path(__file__).resolve().parents[1]
            CONFIG = "docs/c.yml"
            NAME = "x.md"
            CHANGED = "docs/old.md"
            CHANGED = "docs/gen.md"

            def test_constants():
                open(CONFIG).read()
                (ROOT / "docs" / NAME).read_text()
                open(CHANGED).read()
                local = "docs/live.md"
                Path(local).read_text()
        """
        self.assertEqual(self._read_files(body), ["docs/c.yml", "docs/live.md", "docs/x.md"])

    def test_runs_defaults_and_helpers_count_as_reads(self) -> None:
        body = """\
            import argparse
            import subprocess
            import sys
            from pathlib import Path
            ROOT = Path(__file__).resolve().parents[1]

            def load(path=ROOT / "docs/d.md"):
                return path.read_text()

            def read_it(path):
                return load(path)

            def write_it(path):
                path.write_text("x")

            def test_calls():
                subprocess.run([sys.executable, str(ROOT / "tools/run.py")], check=True)
                load()
                read_it(ROOT / "docs/h.md")
                write_it(ROOT / "docs/gen.md")
                argparse.ArgumentParser().add_argument("--map", type=Path, default=ROOT / "docs/p.md")
        """
        self.assertEqual(self._read_files(body), ["docs/d.md", "docs/h.md", "docs/p.md", "tools/run.py"])

    def test_scripts_are_scanned_unless_tests_only(self) -> None:
        # A plain script the job runs is scanned too; tests_only is the scan before it was.
        workflow = RISK_TIER_TESTS_YML.replace("tests/test_risk_tier.py", "tools/run_me.py").replace("EXTRA", "")
        files = {
            ".github/workflows/risk-tier-tests.yml": workflow,
            "tools/run_me.py": TEST_RISK_TIER_PY,
        }
        self.assertEqual(len(self._misses(files)), 1)
        self.assertEqual(self._misses(files, tests_only=True), [])


# cmux-next-perf-budgets.yml's measure job at feat-cmux-next a8227e44, cut to what the check reads: it
# checks out perf-cron.py alone and runs three of its subcommands.
PERF_BUDGETS_YML = """\
on: workflow_dispatch
jobs:
  measure:
    name: perf cron part (fleet, background)
    runs-on: ${{ vars.CI_PERF_CRON_GATEWAY }}
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          persist-credentials: false
          submodules: false
          fetch-depth: 1
          sparse-checkout: scripts/cmux-next/perf-cron.pyEXTRA
          sparse-checkout-cone-mode: false

      - name: Run one part on its host when the fleet is idle
        id: part
        run: |
          set -uo pipefail
          out="$RUNNER_TEMP/perf-cron-part"
          python3 -I scripts/cmux-next/perf-cron.py fleet-check --client "$client" --worker "${WORKER:-cmux20-bench}" --yield-mode "$YIELD_MODE" \\
            --not-started "$out/not-started.json" --output "$RUNNER_TEMP/fleet.out" | tee "$RUNNER_TEMP/fleet.log"
          python3 -I scripts/cmux-next/perf-cron.py run-part --client "$client" --sha "$SHA" --args "$PART_ARGS" \\
            --out "$out" | tee "$RUNNER_TEMP/part.log"

      - name: Cancel a step left running and record the attempt
        if: always()
        run: |
          python3 -I scripts/cmux-next/perf-cron.py part-cleanup --out "$RUNNER_TEMP/perf-cron-part" \\
            --client "$client" --why "run step ${WHY:-not run}"
"""

# scripts/cmux-next/perf-cron.py at feat-cmux-next a8227e44, cut to its three repo reads (same lines).
PERF_CRON_PY = """\
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def load_budgets_module():
    spec = importlib.util.spec_from_file_location("perf_budgets", os.path.join(HERE, "perf-budgets.py"))
    return spec


def tree_published(sha):
    return subprocess.run([sys.executable, os.path.join(ROOT, "scripts/ci/cmux_tui_tree_key.py"), "--version", "1", sha])


def cmd_report(o):
    mod = load_budgets_module()
    budgets = json.load(open(os.path.join(HERE, "perf-budgets.json")))
"""

MEASURE = "cmux-next-perf-budgets.yml measure step 0: scripts/cmux-next/perf-cron.py reads "


class PerfCronScriptReadTests(unittest.TestCase):
    def _root(self, tmp: Path, extra: str = "", run: str = "") -> Path:
        workflow = PERF_BUDGETS_YML.replace("EXTRA", extra)
        if run:
            workflow += f"      - run: {run}\n"
        files = {
            ".github/workflows/cmux-next-perf-budgets.yml": workflow,
            "scripts/cmux-next/perf-cron.py": PERF_CRON_PY,
            "scripts/cmux-next/perf-budgets.json": "{}\n",
            "scripts/cmux-next/perf-budgets.py": "",
            "scripts/ci/cmux_tui_tree_key.py": "",
        }
        for rel, body in files.items():
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (tmp / rel).write_text(body, encoding="utf-8")
        return tmp

    def _measure_allowlist(self, **change):
        out = []
        for entry in READ_ALLOWLIST:
            if entry[:2] == ("cmux-next-perf-budgets.yml", "measure"):
                out.append(tuple(change.get(entry[3], entry)))
        self.assertEqual(len(out), 3, out)
        return out

    def test_feat_cmux_next_a8227e44_perf_cron_reads_perf_budgets_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(Path(tmp))
            self.assertEqual(
                find_read_misses(root),
                [
                    MEASURE + "scripts/ci/cmux_tui_tree_key.py, not in its sparse checkout",
                    MEASURE + "scripts/cmux-next/perf-budgets.json, not in its sparse checkout",
                    MEASURE + "scripts/cmux-next/perf-budgets.py, not in its sparse checkout",
                ],
            )
            # The scan before scripts were covered saw none of it.
            self.assertEqual(find_read_misses(root, tests_only=True), [])

    def test_listing_the_file_clears_it(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(Path(tmp), extra="\n          # perf-budgets.json\n")
            self.assertIn(MEASURE + "scripts/cmux-next/perf-budgets.json, not in its sparse checkout", find_read_misses(root))
        with tempfile.TemporaryDirectory() as tmp:
            # A one-line list becomes a block with the file added.
            workflow_root = self._root(Path(tmp))
            path = workflow_root / ".github/workflows/cmux-next-perf-budgets.yml"
            path.write_text(
                path.read_text().replace(
                    "sparse-checkout: scripts/cmux-next/perf-cron.py\n",
                    "sparse-checkout: |\n            scripts/cmux-next/perf-cron.py\n"
                    "            scripts/cmux-next/perf-budgets.json\n",
                )
            )
            misses = find_read_misses(workflow_root)
            self.assertEqual(len(misses), 2, misses)
            self.assertFalse(any("perf-budgets.json" in m for m in misses), misses)

    def test_allowlist_covers_reads_the_job_never_reaches(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(Path(tmp))
            self.assertEqual(unhandled_read_misses(root, self._measure_allowlist()), [])
            # Without an entry the read is unhandled.
            partial = [e for e in self._measure_allowlist() if e[3] != "scripts/cmux-next/perf-budgets.json"]
            self.assertEqual(
                unhandled_read_misses(root, partial),
                [MEASURE + "scripts/cmux-next/perf-budgets.json, not in its sparse checkout"],
            )

    def test_allowlist_entry_needs_a_reason(self) -> None:
        json_path = "scripts/cmux-next/perf-budgets.json"
        for reason in ("", "   "):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as tmp:
                root = self._root(Path(tmp))
                old = next(e for e in self._measure_allowlist() if e[3] == json_path)
                allow = self._measure_allowlist(**{json_path: (*old[:5], reason)})
                problems = unhandled_read_misses(root, allow)
                self.assertIn(MEASURE + json_path + ", not in its sparse checkout", problems)
                self.assertTrue(any("has no reason" in p for p in problems), problems)

    def test_stale_allowlist_entry_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self._root(Path(tmp))
            path = root / ".github/workflows/cmux-next-perf-budgets.yml"
            path.write_text(
                path.read_text().replace(
                    "sparse-checkout: scripts/cmux-next/perf-cron.py\n",
                    "sparse-checkout: |\n            scripts/cmux-next/perf-cron.py\n"
                    "            scripts/cmux-next/perf-budgets.json\n",
                )
            )
            self.assertEqual(
                unhandled_read_misses(root, self._measure_allowlist()),
                [
                    "READ_ALLOWLIST entry (cmux-next-perf-budgets.yml, measure, scripts/cmux-next/perf-cron.py, "
                    "scripts/cmux-next/perf-budgets.json) is stale: the read is no longer flagged; remove the entry"
                ],
            )

    def test_allowlist_entry_voids_once_the_job_reaches_the_read(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run = 'python3 -I scripts/cmux-next/perf-cron.py report --repo "$GITHUB_REPOSITORY" --dir "$dir"'
            root = self._root(Path(tmp), run=run)
            problems = unhandled_read_misses(root, self._measure_allowlist())
            self.assertIn(MEASURE + "scripts/cmux-next/perf-budgets.json, not in its sparse checkout", problems)
            self.assertIn(MEASURE + "scripts/cmux-next/perf-budgets.py, not in its sparse checkout", problems)
            self.assertEqual(sum("no longer holds" in p for p in problems), 2, problems)
            self.assertNotIn(MEASURE + "scripts/ci/cmux_tui_tree_key.py, not in its sparse checkout", problems)

    def test_real_allowlist_entries_are_well_formed(self) -> None:
        seen = set()
        for workflow, job, script, rel, reach, reason in READ_ALLOWLIST:
            key = (workflow, job, script, rel)
            self.assertNotIn(key, seen, f"duplicate READ_ALLOWLIST entry {key}")
            seen.add(key)
            self.assertTrue(reason.strip() and reach.strip(), key)
            re.compile(reach)
            self.assertTrue((ROOT / ".github/workflows" / workflow).is_file(), key)
            self.assertTrue((ROOT / script).is_file() and (ROOT / rel).is_file(), key)


if __name__ == "__main__":
    unittest.main()
