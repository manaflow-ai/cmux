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
entry fails when that pattern matches the arguments of a command in the job's `run:` steps that
runs the script (read as shell words with shlex: quotes, `\\` continuations, `&&`/`;`/`|`, env
prefixes), when its reason is blank, and when the read is no longer flagged (a stale entry), so the
list cannot rot. When in doubt, add the path to
the sparse list instead.

Run: python3 tests/test_ci_sparse_checkout_imports.py
"""

from __future__ import annotations

import ast
import multiprocessing
import os
import posixpath
import re
import shlex
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

# tests/sparse_checkout_base_reader.py: the read detector at 33852f74, the differential test's reference.
_base_reader_spec = _git_fixture_importlib.spec_from_file_location(
    "sparse_checkout_base_reader",
    _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "sparse_checkout_base_reader.py"))
sparse_checkout_base_reader = _git_fixture_importlib.module_from_spec(_base_reader_spec)
_base_reader_spec.loader.exec_module(sparse_checkout_base_reader)

ROOT = Path(__file__).resolve().parents[1]
CI_DIR = "scripts/ci"
OPTIONAL_HANDLERS = {"ImportError", "ModuleNotFoundError", "Exception", "BaseException"}


# --- the repo's files ----------------------------------------------------------------------------
#
# What the repo holds comes from git's index, not the working tree: a sparse worktree leaves files
# out, and a check that asked the disk passed there while CI, with every file, failed (#41221 at
# a77b32f4: Native/DiffSidecar/Cargo.toml). A folder that is not a git work tree's top (a fixture's
# tmp root) is read from disk.


@lru_cache(maxsize=None)
def _git_index(root: str) -> frozenset[str] | None:
    """Every file git tracks in the work tree whose top is `root`, or None when `root` is not one."""
    try:
        top = subprocess.run(["git", "-C", root, "rev-parse", "--show-toplevel"], capture_output=True,
                             text=True, check=True).stdout.strip()
        if Path(top).resolve() != Path(root).resolve():
            return None
        out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return frozenset(rel for rel in out.split("\0") if rel)


def repo_has(root: Path, rel: str) -> bool:
    """Whether the repo at `root` has the file `rel` (in git's index, or on disk outside git)."""
    index = _git_index(str(root))
    if index is not None and rel in index:
        return True
    try:
        return (root / rel).is_file()
    except (OSError, ValueError):  # a name too long or with a NUL is no file
        return False


@lru_cache(maxsize=None)
def _git_source(root: str, rel: str) -> str | None:
    result = subprocess.run(["git", "-C", root, "show", f":{rel}"], capture_output=True)
    return result.stdout.decode("utf-8", errors="replace") if result.returncode == 0 else None


def repo_source(root: Path, rel: str) -> str | None:
    """The text of the repo file `rel`: the working tree's copy, or the index's when a sparse checkout left it out."""
    try:
        return (root / rel).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        pass
    return _git_source(str(root), rel) if _git_index(str(root)) is not None else None


def repo_workflows(root: Path) -> list[str]:
    """The workflow file names under .github/workflows."""
    index = _git_index(str(root))
    names = {p.name for p in (root / ".github" / "workflows").glob("*.y*ml")}
    if index is not None:
        names |= {rel.rsplit("/", 1)[1] for rel in index
                  if rel.startswith(".github/workflows/") and rel.count("/") == 2 and rel.endswith((".yml", ".yaml"))}
    return sorted(names)


@lru_cache(maxsize=128)
def parse_python(source: str) -> ast.Module | None:
    """One parse per source, shared by the import check and both read detectors (never mutated).
    Bounded: the differential test asks for each file's tree twice in a row, and hundreds of kept
    trees cost seconds to free at exit."""
    try:
        return ast.parse(source)
    except (SyntaxError, ValueError):
        return None


@lru_cache(maxsize=None)
def _parse_yaml(text: str):
    """One parse per distinct workflow text: every job and test re-read the same workflows."""
    return yaml.safe_load(text) or {}


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
    named = {rel for rel in named if rel and repo_has(root, rel)}
    return _git_checked_out(tuple(entries), frozenset(paths | named)) & paths


def listed_ci_scripts(entries: list[str], root: Path) -> list[str]:
    """scripts/ci/**.py files the entries name by exact path (leading slash allowed)."""
    out = []
    for entry in entries:
        if entry.startswith("!"):
            continue
        rel = entry.lstrip("/")
        if rel.startswith(CI_DIR + "/") and rel.endswith(".py") and not any(ch in rel for ch in "*?["):
            if repo_has(root, rel):
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
    tree = parse_python(source)
    if tree is None:
        raise SyntaxError("unparsable")
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
        return [init] if repo_has(root, init) else []
    files = []
    for n in range(1, len(parts) + 1):
        stem = "/".join([base, *parts[:n]])
        if repo_has(root, f"{stem}.py"):
            files.append(f"{stem}.py")
            break  # a module, not a package: deeper names are attributes
        if repo_has(root, f"{stem}/__init__.py"):
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
            source = repo_source(root, current)
            if source is None:
                continue
            names = imported_names(source)
        except (SyntaxError, ValueError):
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
    for name in repo_workflows(root):
        path = root / ".github" / "workflows" / name
        doc = _parse_yaml(repo_source(root, f".github/workflows/{name}") or "")
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
        if repo_has(root, rel) and re.search(rf"(?<![\w.-]){re.escape(rel)}\b", run_text):
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
# Calls that create, change or remove the path they are given: (method names on the path), (functions -> arg index).
_WRITE_METHODS = {"write_text", "write_bytes", "mkdir", "touch", "unlink", "rmdir", "symlink_to", "hardlink_to",
                  "chmod", "rename", "replace"}
_WRITE_FUNCS = {"os.makedirs": 0, "os.mkdir": 0, "os.remove": 0, "os.unlink": 0, "os.rmdir": 0,
                "shutil.rmtree": 0, "shutil.copy": 1, "shutil.copy2": 1, "shutil.copyfile": 1,
                "shutil.copytree": 1, "shutil.move": 1, "os.rename": 1, "os.replace": 1, "os.symlink": 1}


class _Text(str):
    """A plain string value (a constant, a parameter): a path only where it is used as one."""


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


def _merge(*envs: dict[str, frozenset[str]]) -> dict[str, frozenset[str]]:
    """What a name may hold after any of these paths: the union of each path's values."""
    out: dict[str, frozenset[str]] = {}
    for env in envs:
        for name, values in env.items():
            out[name] = out.get(name, frozenset()) | values
    return out


_MAX_VALUES = 64  # a name built up in a loop stops growing here


class _ReadFinder:
    """The repo paths a script uses, from the values each path expression may have where it is used.

    Every use of a path value counts (a read, a run, `.exists()`, an argument to any function, a
    dict value), except as what a write call writes, creates or removes (`write_text`,
    `open(.., "w")`, `mkdir`, `shutil.copy`'s target, ...), and except as the value of an
    assignment to a name the file loads: those loads count instead, at the values live there. So a
    value replaced before any use never counts. A plain string (a constant, a parameter) counts only
    where a call reads or runs it (`open(FILE)`, `subprocess.run([.., FILE])`, a module loaded by
    file, an argparse path default) or once a path is built from it.

    A name holds the set of paths it may have, in program order: an assignment replaces the set,
    branches and loop iterations take the union, and a function sees the module's names as the
    module body leaves them (its parameters stand for what callers pass: a call into a function
    that reads a parameter reads the argument, and a parameter default is read when it is left out).
    """

    def __init__(self, script: str, tree: ast.Module) -> None:
        self.script = script
        self.tree = tree
        self.funcs: dict[str, ast.AST] = {}
        defined: dict[str, int] = {}
        self.param_reads: dict[str, dict[str, set[str]]] = {}  # function -> parameter -> suffixes read
        # One walk of the tree: functions defined once, loaded names, and each statement's walrus
        # targets (the statement that holds the `:=` and every statement around it, as the
        # per-statement walk it replaces found them).
        self.loaded: set[str] = set()
        self.walrus: dict[int, set[str]] = {}
        self._local_cache: dict[int, set[str]] = {}
        stack: list[tuple[ast.AST, tuple[int, ...]]] = [(tree, ())]
        while stack:
            node, holders = stack.pop()
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
                self.loaded.add(node.id)
            if isinstance(node, ast.NamedExpr):
                for holder in holders:
                    self.walrus.setdefault(holder, set()).add(node.target.id)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                defined[node.name] = defined.get(node.name, 0) + 1
                self.funcs[node.name] = node
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                inner = holders  # a def holds no walrus of its own; the statements around it still do
            elif isinstance(node, ast.stmt):
                inner = holders + (id(node),)
            else:
                inner = holders
            stack.extend((child, inner) for child in ast.iter_child_nodes(node))
        self.funcs = {n: f for n, f in self.funcs.items() if defined[n] == 1}
        self.module_env: dict[str, frozenset[str]] = {}
        self.skip_functions = False
        self.in_class = 0
        self.reads: list[str] = []

    # -- values --

    def _strings(self, node: ast.AST, env) -> frozenset[str]:
        literal = _literal(node)
        if literal is not None:
            return frozenset({literal})
        return env.get(node.id, frozenset()) if isinstance(node, ast.Name) else frozenset()

    @staticmethod
    def _each(values, fn) -> frozenset[str]:
        out = set()
        for value in values:
            result = fn(value)
            if result is not None:
                out.add(result)
            if len(out) >= _MAX_VALUES:
                break
        return frozenset(out)

    def evals(self, node: ast.AST, env) -> frozenset[str]:
        """Every repo-relative path `node` may evaluate to (empty when unknown)."""
        none: frozenset[str] = frozenset()
        if isinstance(node, ast.Constant):
            if not (isinstance(node.value, str) and node.value):
                return none
            out = _norm(node.value)
            return none if out is None else frozenset({_Text(out)})
        if isinstance(node, ast.Name):
            return frozenset({self.script}) if node.id == "__file__" else env.get(node.id, none)
        if isinstance(node, ast.Attribute):
            return self._each(self.evals(node.value, env), _dirname) if node.attr == "parent" else none
        if isinstance(node, ast.Subscript):
            if isinstance(node.value, ast.Attribute) and node.value.attr == "parents":
                index = node.slice
                if isinstance(index, ast.Constant) and isinstance(index.value, int) and index.value >= 0:
                    out = self.evals(node.value.value, env)
                    for _ in range(index.value + 1):
                        out = self._each(out, _dirname)
                    return out
            return none
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            parts = self._strings(node.right, env)
            return self._each([(b, p) for b in self.evals(node.left, env) for p in parts], lambda bp: _join(*bp))
        if isinstance(node, ast.Call):
            func = _dotted(node.func)
            if func in _PATH_CALLS or func in _IDENTITY_OS:
                if len(node.args) != 1 or (node.keywords and func not in _PATH_CALLS):
                    return none
                out = self.evals(node.args[0], env)
                return self._each(out, str) if func in _PATH_CALLS else out  # Path(text) is a path
            if node.keywords:
                return none
            if func == "os.path.dirname" and len(node.args) == 1:
                return self._each(self.evals(node.args[0], env), _dirname)
            if func == "os.path.join" and node.args:
                return self._joined(self.evals(node.args[0], env), node.args[1:], env)
            if isinstance(node.func, ast.Attribute):
                method = node.func.attr
                if method in _IDENTITY_METHODS and not node.args:
                    return self.evals(node.func.value, env)
                if method == "joinpath" and node.args:
                    return self._joined(self.evals(node.func.value, env), node.args, env)
        return none

    def _joined(self, bases, part_nodes, env) -> frozenset[str]:
        combos = [(b,) for b in bases]
        for part in part_nodes:
            strings = self._strings(part, env)
            combos = [c + (s,) for c in combos for s in strings][:_MAX_VALUES]
        return self._each(combos, lambda c: _join(*c))

    # -- reads --

    def _sink_args(self, call: ast.Call) -> list[ast.AST]:
        """The argument expressions this call reads or runs."""
        func = _dotted(call.func) or ""
        last = call.func.attr if isinstance(call.func, ast.Attribute) else func
        if func in {"open", "io.open"}:
            target = [call.args[0]] if call.args else [k.value for k in call.keywords if k.arg == "file"]
            return target if _reads_mode(call, 1) else []
        if isinstance(call.func, ast.Attribute) and last in _READ_METHODS:
            return [call.func.value]  # read_text("utf-8"): its arguments are encoding and errors
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

    def _write_targets(self, call: ast.Call) -> list[ast.AST]:
        """The path expressions this call writes, creates or removes (not reads)."""
        func = _dotted(call.func) or ""
        if func in {"open", "io.open"}:
            target = [call.args[0]] if call.args else [k.value for k in call.keywords if k.arg == "file"]
            return [] if _reads_mode(call, 1) else target
        if isinstance(call.func, ast.Attribute):
            if call.func.attr in _WRITE_METHODS:
                return [call.func.value]
            if call.func.attr == "open" and func != "os.open" and not _reads_mode(call, 0):
                return [call.func.value]
        index = _WRITE_FUNCS.get(func)
        return [call.args[index]] if index is not None and len(call.args) > index else []

    def _call_reads(self, call: ast.Call, env) -> list[str]:
        """Path values this call reads: its own sinks, or a read its callee does with an argument."""
        out = [v for a in self._sink_args(call) for v in self.evals(a, env)]
        callee = self.funcs.get(call.func.id) if isinstance(call.func, ast.Name) else None
        reads = self.param_reads.get(call.func.id, {}) if callee is not None else {}
        if reads:
            args = callee.args
            positional = [a.arg for a in [*args.posonlyargs, *args.args]]
            bound = dict(zip(positional, call.args))
            bound.update({k.arg: k.value for k in call.keywords if k.arg})
            for param, suffixes in reads.items():
                for value in self.evals(bound[param], env) if param in bound else ():
                    out.extend(v for v in (_join(value, s) if s else value for s in suffixes) if v is not None)
        return out

    def _chain(self, node: ast.AST, env) -> set[int]:
        """`node` and the sub-expressions that carry the same path values into it (`str(Path(ROOT / x))`)."""
        values = self.evals(node, env)
        out = {id(node)}
        if not values:
            return out
        todo = list(ast.iter_child_nodes(node))
        while todo:
            child = todo.pop()
            if isinstance(child, ast.expr) and self.evals(child, env) == values:
                out.add(id(child))
                todo.extend(ast.iter_child_nodes(child))
        return out

    def record(self, expr: ast.AST | None, env, shadow: frozenset[str] = frozenset(),
               skip: frozenset[int] = frozenset()) -> None:
        """Note every repo path `expr` uses, at the values live here (see the class docstring).

        `skip` holds the nodes that are only written to or only assigned; names a lambda or
        comprehension rebinds are unknown in it.
        """
        if expr is None:
            return
        if shadow:
            env = {k: v for k, v in env.items() if k not in shadow}
        if isinstance(expr, ast.Lambda):
            local = self._local_cache.get(id(expr))
            if local is None:
                local = self._local_cache[id(expr)] = _local_names(expr)
            self.record(expr.body, env, frozenset(local))
            return
        if isinstance(expr, (ast.ListComp, ast.SetComp, ast.GeneratorExp, ast.DictComp)):
            names = frozenset().union(*(_bound_names(g.target) for g in expr.generators))
            for child in ast.iter_child_nodes(expr):
                self.record(child, env, names, skip)
            return
        if isinstance(expr, ast.Call):
            self.reads.extend(self._call_reads(expr, env))
            for target in self._write_targets(expr):
                skip = skip | self._chain(target, env)
        if id(expr) not in skip and isinstance(expr, (ast.Name, ast.BinOp, ast.Call, ast.Subscript, ast.Attribute)):
            if not (isinstance(expr, ast.Name) and not isinstance(expr.ctx, ast.Load)):
                self.reads.extend(v for v in self.evals(expr, env) if not isinstance(v, _Text))
        for child in ast.iter_child_nodes(expr):
            if isinstance(child, ast.expr) or isinstance(child, (ast.keyword, ast.comprehension)):
                self.record(child, env, frozenset(), skip)

    # -- statements --

    def run(self) -> set[str]:
        """Every path the module uses; also fills param_reads for calls into its functions."""
        self.skip_functions = True
        self.module_env = self.block(self.tree.body, {}, frozenset())
        self.skip_functions = False
        for _ in range(5):
            before = {f: {p: set(s) for p, s in ps.items()} for f, ps in self.param_reads.items()}
            self.reads = []
            self.block(self.tree.body, {}, frozenset())
            if self.param_reads == before:
                break
        return {r for r in self.reads if _PARAM not in r}

    def function(self, func: ast.AST, outer_locals: frozenset[str], def_env) -> None:
        if self.skip_functions:
            return
        local = self._local_cache.get(id(func))
        if local is None:
            local = self._local_cache[id(func)] = _local_names(func)
        hidden = outer_locals | local
        env = {k: v for k, v in self.module_env.items() if k not in hidden}
        for name in outer_locals - local:  # a closure sees its enclosing function's bindings
            if name in def_env:
                env[name] = def_env[name]
        params = [a.arg for a in [*func.args.posonlyargs, *func.args.args, *func.args.kwonlyargs]]
        for param in params:  # bound at entry; an assignment in the body replaces it from there on
            env[param] = frozenset({_Text(_PARAM + param)})
        start = len(self.reads)
        in_class, self.in_class = self.in_class, 0
        self.block(func.body, env, frozenset(hidden))
        self.in_class = in_class
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
            for value in self.evals(default, def_env):
                self.reads.extend(v for v in (_join(value, s) if s else value
                                              for s in found.get(arg.arg, ())) if v is not None)
        if found and func.name in self.funcs and self.funcs[func.name] is func:
            merged = self.param_reads.setdefault(func.name, {})
            for name, suffixes in found.items():
                merged.setdefault(name, set()).update(suffixes)

    def block(self, body: list[ast.stmt], env, locals_: frozenset[str]):
        env = dict(env)
        for stmt in body:
            env = self.stmt(stmt, env, locals_)
        return env

    def _kill(self, env, names: set[str]):
        return {k: v for k, v in env.items() if k not in names}

    def _loop(self, stmt, env, locals_, head):
        state = env
        for _ in range(5):
            after = self.block(stmt.body, head(state), locals_)
            merged = _merge(state, after)
            if merged == state:
                break
            state = merged
        return self.block(stmt.orelse, state, locals_)

    def stmt(self, stmt: ast.stmt, env, locals_: frozenset[str]):
        walrus = self.walrus.get(id(stmt), set())
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for expr in [*stmt.decorator_list, *stmt.args.defaults, *stmt.args.kw_defaults]:
                self.record(expr, env)
            self.function(stmt, locals_, env)
            return self._kill(env, {stmt.name})
        if isinstance(stmt, ast.ClassDef):
            for expr in [*stmt.decorator_list, *stmt.bases]:
                self.record(expr, env)
            self.in_class += 1
            self.block(stmt.body, env, locals_)
            self.in_class -= 1
            return self._kill(env, {stmt.name})
        if isinstance(stmt, (ast.Assign, ast.AnnAssign)):
            targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
            names_only = all(isinstance(t, ast.Name) for t in targets)
            # A class attribute is read as self.NAME, which no load of the name shows: it counts here.
            used = not self.in_class and any(isinstance(t, ast.Name) and t.id in self.loaded for t in targets)
            skip = frozenset(self._chain(stmt.value, env)) if stmt.value is not None and names_only and used else frozenset()
            self.record(stmt.value, env, skip=skip)
            values = self.evals(stmt.value, env) if stmt.value is not None else frozenset()
            env = self._kill(env, set().union(*(_bound_names(t) for t in targets)) | walrus)
            if values:
                for target in targets:  # `a = b = Path(...)` binds both
                    if isinstance(target, ast.Name):
                        env[target.id] = values
            return env
        if isinstance(stmt, ast.If):
            self.record(stmt.test, env)
            env = self._kill(env, walrus)
            return _merge(self.block(stmt.body, env, locals_), self.block(stmt.orelse, env, locals_))
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
            entry = _merge(env, after_body)
            ends = [self.block(stmt.orelse, after_body, locals_)]
            for handler in stmt.handlers:
                self.record(handler.type, entry)
                ends.append(self.block(handler.body, self._kill(entry, _binds(handler)), locals_))
            return self.block(stmt.finalbody, _merge(*ends), locals_)
        if isinstance(stmt, ast.Match):
            self.record(stmt.subject, env)
            ends = [env]
            for case in stmt.cases:
                case_env = self._kill(env, _binds(case))
                self.record(case.guard, case_env)
                ends.append(self.block(case.body, case_env, locals_))
            return _merge(*ends)
        for child in ast.iter_child_nodes(stmt):
            if isinstance(child, ast.expr):
                self.record(child, env)
        return self._kill(env, _binds(stmt) | walrus)


@lru_cache(maxsize=None)
def _reads_unfiltered(script: str, source: str) -> frozenset[str]:
    """Every path the reader finds in one (script, source), before the existence filter: memoized, as
    the real-tree check, the allowlist check and the differential test ask for the same scripts."""
    tree = parse_python(source)
    return frozenset() if tree is None else frozenset(_ReadFinder(script, tree).run())


def reads_in_source(script: str, source: str, is_file) -> set[str]:
    """The paths `script` (with this source) reads or runs that `is_file` says are repo files."""
    return {rel for rel in _reads_unfiltered(script, source) if rel and rel != script and is_file(rel)}


def read_paths(script: str, root: Path) -> set[str]:
    """Repo files `script` reads or runs by a statically known path (`ROOT / "a/b"`, `open(FILE)`, ...).

    Only paths that are files in `root` count; directories, globs and anything built from a value
    that is not known where the read happens are skipped.
    """
    source = repo_source(root, script)
    return set() if source is None else reads_in_source(script, source, lambda rel: repo_has(root, rel))


def _job_run_text(root: Path, workflow: str, job: str) -> str:
    doc = _parse_yaml(repo_source(root, f".github/workflows/{workflow}") or "")
    steps = ((doc.get("jobs") or {}).get(job) or {}).get("steps") or []
    return "\n".join(str(step.get("run") or "") for step in steps if isinstance(step, dict))


def _job_run_blocks(root: Path, workflow: str, job: str) -> list[str]:
    doc = _parse_yaml(repo_source(root, f".github/workflows/{workflow}") or "")
    steps = ((doc.get("jobs") or {}).get(job) or {}).get("steps") or []
    return [str(step.get("run") or "") for step in steps if isinstance(step, dict)]


_SHELL_SEPARATORS = set(";&|()`\n")


def _shell_tokens(text: str) -> list[str]:
    """Words and separators of a shell text, as shlex reads them; a newline is a separator."""
    lexer = shlex.shlex(text, posix=True, punctuation_chars=";&|()<>`\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    return list(lexer)


def _substitutions(word: str) -> list[str]:
    """The texts of the `$(...)` and backtick command substitutions inside one shell word."""
    out = []
    index = 0
    while index < len(word):
        if word.startswith("$(", index) and not word.startswith("$((", index):
            depth, end = 1, index + 2
            while end < len(word) and depth:
                depth += {"(": 1, ")": -1}.get(word[end], 0)
                end += 1
            out.append(word[index + 2:end - 1 if depth == 0 else end])
            index = end
        elif word[index] == "`":
            end = word.find("`", index + 1)
            end = len(word) if end < 0 else end
            out.append(word[index + 1:end])
            index = end + 1
        else:
            index += 1
    return out


def shell_commands(run_text: str, depth: int = 0) -> list[list[str]]:
    """The simple commands of a `run:` block, each a list of words with quotes removed.

    `\\`-newline continuations join lines; newlines, `;`, `&&`, `||`, `|`, `&` and parentheses
    separate commands; leading `NAME=value` assignments are dropped. A command substitution inside a
    word (`out="$(python3 x.py report)"`, backticks) is read as commands of its own. A block shlex
    cannot read whole (an unbalanced quote in a heredoc) is read line by line, and a line it cannot
    read is split on whitespace.
    """
    text = re.sub(r"\\\r?\n", " ", run_text)
    try:
        tokens = _shell_tokens(text)
    except ValueError:
        tokens = []
        for line in text.splitlines():
            try:
                tokens.extend(_shell_tokens(line))
            except ValueError:
                tokens.extend(line.split())
            tokens.append("\n")
    commands: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if depth < 8 and ("$(" in token or "`" in token):
            for inner in _substitutions(token):
                commands.extend(shell_commands(inner, depth + 1))
        if token and set(token) <= _SHELL_SEPARATORS:
            if current:
                commands.append(current)
            current = []
        elif not current and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token, re.S):
            continue
        else:
            current.append(token)
    if current:
        commands.append(current)
    return commands


def script_arguments(run_blocks: list[str], script: str) -> list[list[str]]:
    """For each command that names `script` (by path, `$X/`-prefixed or bare file name), the words after it."""
    base = script.rsplit("/", 1)[-1]
    out = []
    for block in run_blocks:
        for command in shell_commands(block):
            for index, word in enumerate(command):
                if word == base or word.endswith("/" + base):
                    out.append(command[index + 1:])
                    break
    return out


def reach_matches(reach: str | tuple[str, ...], args: list[str]) -> bool:
    """Whether a script's argument words match an allowlist `reach`.

    `reach` is one alternative or a tuple of them; an alternative is a space-separated run of regexes,
    each full-matching one word, matched at any position. Words are compared as words, so the
    argument `"report failed"` is not the subcommand `report`.
    """
    for alternative in (reach,) if isinstance(reach, str) else reach:
        patterns = alternative.split()
        for start in range(len(args) - len(patterns) + 1):
            if all(re.fullmatch(p, w, re.S) for p, w in zip(patterns, args[start:])):
                return True
    return False


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
# for the invocation that would reach the read (the subcommand or flag), matched on the argument words
# of every command of the job's `run:` steps that runs the script (reach_matches: each space-separated
# regex full-matches one word; a tuple lists alternatives); the entry is void when one matches. The reason names the condition. Checked against the tree at 2026-11-11.
READ_ALLOWLIST: list[tuple[str, str, str, str, str | tuple[str, ...], str]] = [
    ("ci-web.yml", "webviews-test-history", "scripts/ci/webviews_test_history.py", "scripts/cmux-next/web-bundle-key.py",
     "inputs",
     "run only by inputs(), the `inputs` subcommand; this job runs `fetch` and `record` and takes the key the "
     "shards' full checkouts computed"),
    ("cmux-next-frame-pacing.yml", "bench", "scripts/cmux-next/instant-new-surfaces-bench.py",
     "scripts/cmux-next/new-pane-start-state-bench.py", "--bench=new-pane-start-state",
     "exec'd only when argv holds `--bench=new-pane-start-state` (scripts/measure/instant-new-surfaces.sh's "
     "fleet route); no step of this job passes it"),
    ("cmux-next-frame-pacing.yml", "bench", "scripts/cmux-next/bench-startup.py", "scripts/cmux-next/perf-stress-session.py",
     ("--profile stress", "--profile=stress"),
     "loaded only by seed_stress(), under `--profile stress`; this job passes `--profile empty` and "
     "`--profile realistic`"),
    ("cmux-next-media.yml", "route", "scripts/cmux-next/media/whats-new-clips.py", "scripts/pr-media.py",
     "publish(-auto)?",
     "loaded only by pr_media_module(), from the `publish` and `publish-auto` subcommands; this job runs `plan`"),
    ("cmux-next-perf-budgets.yml", "measure", "scripts/cmux-next/perf-cron.py", "scripts/ci/cmux_tui_tree_key.py",
     "plan",
     "run only by tree_published(), reached only from the `plan` subcommand; this job runs `fleet-check`, "
     "`run-part` and `part-cleanup`"),
    ("cmux-next-perf-budgets.yml", "measure", "scripts/cmux-next/perf-cron.py", "scripts/cmux-next/perf-budgets.json",
     "report",
     "read only by cmd_report (the `report` subcommand) when a measurement finishes; this job runs `fleet-check`, "
     "`run-part` and `part-cleanup` (the report job checks it out)"),
    ("cmux-next-perf-budgets.yml", "measure", "scripts/cmux-next/perf-cron.py", "scripts/cmux-next/perf-budgets.py",
     "report",
     "loaded only by load_budgets_module(), from cmd_report (the `report` subcommand); this job runs "
     "`fleet-check`, `run-part` and `part-cleanup` (the report job checks it out)"),
    ("cmux-next-perf-budgets.yml", "report", "scripts/cmux-next/perf-cron.py", "scripts/ci/cmux_tui_tree_key.py",
     "plan",
     "run only by tree_published(), reached only from the `plan` subcommand; this job runs `fetch-result`, "
     "`report` and `dispatch-next`"),
    ("cmux-next-quality-report.yml", "report", "scripts/cmux-next/perf-cron.py", "scripts/ci/cmux_tui_tree_key.py",
     "plan",
     "run only by tree_published(), reached only from the `plan` subcommand; this job runs `fetch-state`"),
    ("cmux-next-perf-budgets.yml", "measure", "scripts/cmux-next/perf-cron.py", "scripts/run-diff-sidecar-cargo.sh",
     "run-linux-part",
     "run only by cmd_run_linux_part (linux_bench_runs(ROOT, part)), the `run-linux-part` subcommand a Linux host "
     "runs in a full checkout of the measured commit (part_config's linux_bench_runs(\"\", ...) only hashes the "
     "argv); this job runs `fleet-check`, `run-part` and `part-cleanup`"),
    ("cmux-next-perf-budgets.yml", "report", "scripts/cmux-next/perf-cron.py", "scripts/run-diff-sidecar-cargo.sh",
     "run-linux-part",
     "run only by cmd_run_linux_part (linux_bench_runs(ROOT, part)), the `run-linux-part` subcommand a Linux host "
     "runs in a full checkout of the measured commit (part_config's linux_bench_runs(\"\", ...) only hashes the "
     "argv); this job runs `fetch-result`, `report` and `dispatch-next`"),
    ("cmux-next-quality-report.yml", "report", "scripts/cmux-next/perf-cron.py", "scripts/run-diff-sidecar-cargo.sh",
     "run-linux-part",
     "run only by cmd_run_linux_part (linux_bench_runs(ROOT, part)), the `run-linux-part` subcommand a Linux host "
     "runs in a full checkout of the measured commit (part_config's linux_bench_runs(\"\", ...) only hashes the "
     "argv); this job runs `fetch-state`"),
    ("cmux-next-perf-budgets.yml", "measure", "scripts/cmux-next/perf-cron.py", "Native/DiffSidecar/Cargo.toml",
     "run-linux-part",
     "the sidecar bench's --manifest-path in linux_bench_runs(ROOT, part), run only by cmd_run_linux_part, the "
     "`run-linux-part` subcommand a Linux host runs in a full checkout of the measured commit; this job runs `fleet-check`, `run-part` and `part-cleanup`"),
    ("cmux-next-perf-budgets.yml", "report", "scripts/cmux-next/perf-cron.py", "Native/DiffSidecar/Cargo.toml",
     "run-linux-part",
     "the sidecar bench's --manifest-path in linux_bench_runs(ROOT, part), run only by cmd_run_linux_part, the "
     "`run-linux-part` subcommand a Linux host runs in a full checkout of the measured commit; this job runs `fetch-result`, `report` and `dispatch-next`"),
    ("cmux-next-quality-report.yml", "report", "scripts/cmux-next/perf-cron.py", "Native/DiffSidecar/Cargo.toml",
     "run-linux-part",
     "the sidecar bench's --manifest-path in linux_bench_runs(ROOT, part), run only by cmd_run_linux_part, the "
     "`run-linux-part` subcommand a Linux host runs in a full checkout of the measured commit; this job runs `fetch-state`"),
    ("stable-next.yml", "tick", "scripts/ci/stable_next.py", "scripts/ci/publish-nightly-next-r2.py",
     "write-feed",
     "loaded only by _r2_module(), from the `write-feed` subcommand (stable-next-rollback.yml); this job runs "
     "`window` and `published-tonight`"),
    ("stable-next.yml", "crash-class", "scripts/ci/stable_next.py", "scripts/ci/publish-nightly-next-r2.py",
     "write-feed",
     "loaded only by _r2_module(), from the `write-feed` subcommand (stable-next-rollback.yml); this job runs "
     "`crash-delta`"),
    ("stable-next.yml", "soak", "scripts/ci/stable_next.py", "scripts/ci/publish-nightly-next-r2.py",
     "write-feed",
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
        if not reach or not all(str(alt).strip() for alt in ((reach,) if isinstance(reach, str) else reach)):
            problems.append(f"{entry} has no reach pattern: the invocation that would reach the read")
            continue
        if not any(r[:2] == (workflow, job) and r[3:] == (script, rel) for r in records):
            problems.append(f"{entry} is stale: the read is no longer flagged; remove the entry")
            continue
        if any(reach_matches(reach, args) for args in script_arguments(_job_run_blocks(root, workflow, job), script)):
            problems.append(f"{entry} no longer holds: the job runs {script} with arguments matching {reach!r}; "
                            "add the path to its sparse list")
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
        # `.exists()` is a use, as it was for the base reader (33852f74): only writes and replaced values are gone.
        self.assertEqual(self._read_files(body), ["docs/j.json", "docs/live.md", "docs/r.md", "docs/x.md"])

    def test_f1_branches_and_loops_count_every_value_a_read_may_see(self) -> None:
        # A name holds every path it may have: old.md when the branch is not taken, x.md on the second
        # iteration. Only a value every path replaces before the use (gen.md) is gone.
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
                g = ROOT / "docs/gen.md"
                if sys.argv:
                    g = Path(tmp) / "a"
                else:
                    g = Path(tmp) / "b"
                g.read_text()
        """
        self.assertEqual(self._read_files(body), ["docs/live.md", "docs/old.md", "docs/x.md"])

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
        # A function sees CHANGED as the module body leaves it: gen.md, not the replaced old.md.
        self.assertEqual(self._read_files(body), ["docs/c.yml", "docs/gen.md", "docs/live.md", "docs/x.md"])

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
        # A path handed to any function counts, as for the base reader, even one that only writes it.
        self.assertEqual(self._read_files(body), ["docs/d.md", "docs/gen.md", "docs/h.md", "docs/p.md", "tools/run.py"])

    # Review of 6e9fbd93: F1-F3 were reads the base reader (33852f74) saw and the rewrite lost.
    F1_TO_F3_BODY = """\
        from pathlib import Path

        def load(path):
            path = Path(path)
            return path.read_text()

        def test_regressions():
            Path("docs/r.md").read_text("utf-8")
            open(file=Path("docs/c.yml")).read()
            load(Path("docs/d.md"))
            a = b = Path("docs/h.md")
            a.read_text()
            b.read_bytes()
    """

    def test_review_f1_to_f3_encoding_file_keyword_param_rebind_chained_assign(self) -> None:
        self.assertEqual(self._read_files(self.F1_TO_F3_BODY), ["docs/c.yml", "docs/d.md", "docs/h.md", "docs/r.md"])

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
PERF_CRON_READS = {"scripts/ci/cmux_tui_tree_key.py", "scripts/cmux-next/perf-budgets.json", "scripts/cmux-next/perf-budgets.py"}


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
            if entry[:2] == ("cmux-next-perf-budgets.yml", "measure") and entry[3] in PERF_CRON_READS:
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

    def _run_block(self, root: Path, block: str) -> None:
        path = root / ".github/workflows/cmux-next-perf-budgets.yml"
        lines = "".join(" " * 10 + line + "\n" for line in textwrap.dedent(block).strip("\n").splitlines())
        path.write_text(path.read_text() + "      - run: |\n" + lines)

    def test_reach_matches_quoted_and_compound_invocations(self) -> None:
        # Review of 33852f74: `python3 -I "scripts/cmux-next/perf-cron.py" report` got past the reach regex,
        # which wanted whitespace right after `.py`. The run text is now read as shell words.
        reaching = {
            "double quotes": 'python3 -I "scripts/cmux-next/perf-cron.py" report --repo "$GITHUB_REPOSITORY"',
            "single quotes": "python3 -I 'scripts/cmux-next/perf-cron.py' 'report'",
            "workspace prefix, env and &&": 'cd "$RUNNER_TEMP" && PYTHONUNBUFFERED=1 python3 '
                                             '"$GITHUB_WORKSPACE/scripts/cmux-next/perf-cron.py" report',
            "continuations": "python3 -I scripts/cmux-next/perf-cron.py \\\n  --verbose \\\n  report --dir x",
            "after ; and in a pipe": "true; python3 scripts/cmux-next/perf-cron.py report | tee log",
        }
        for name, block in reaching.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                root = self._root(Path(tmp))
                self._run_block(root, block)
                problems = unhandled_read_misses(root, self._measure_allowlist())
                self.assertEqual(sum("no longer holds" in p for p in problems), 2, problems)
        holding = {
            "echoed text": 'echo "perf-cron.py report"',
            "another command": "python3 scripts/cmux-next/perf-cron.py fleet-check; echo report",
        }
        for name, block in holding.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                root = self._root(Path(tmp))
                self._run_block(root, block)
                self.assertEqual(unhandled_read_misses(root, self._measure_allowlist()), [])

    def test_review_f4_command_substitutions_are_read(self) -> None:
        for name, block in {
            "quoted assignment": 'result="$(python3 scripts/cmux-next/perf-cron.py report)"',
            "unquoted assignment": "result=$(python3 scripts/cmux-next/perf-cron.py report --dir x)",
            "inside a quoted word": 'echo "got: $(python3 -I "scripts/cmux-next/perf-cron.py" report)"',
            "backticks": "result=`python3 scripts/cmux-next/perf-cron.py report`",
        }.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                root = self._root(Path(tmp))
                self._run_block(root, block)
                problems = unhandled_read_misses(root, self._measure_allowlist())
                self.assertEqual(sum("no longer holds" in p for p in problems), 2, problems)

    def test_review_f5_reach_matches_words_not_text(self) -> None:
        for block in (
            'python3 scripts/cmux-next/perf-cron.py part-cleanup --why "report failed"',
            'python3 scripts/cmux-next/perf-cron.py part-cleanup --why "x report"',
        ):
            with self.subTest(block), tempfile.TemporaryDirectory() as tmp:
                root = self._root(Path(tmp))
                self._run_block(root, block)
                self.assertEqual(unhandled_read_misses(root, self._measure_allowlist()), [])
        self.assertTrue(reach_matches(("--profile stress", "--profile=stress"), ["--app", "x", "--profile", "stress"]))
        self.assertTrue(reach_matches(("--profile stress", "--profile=stress"), ["--profile=stress"]))
        self.assertFalse(reach_matches(("--profile stress", "--profile=stress"), ["--profile", "stress-lite"]))

    def test_shell_commands_split_like_the_shell(self) -> None:
        self.assertEqual(
            shell_commands('A=1 B="x y" python3 "a b.py" c \\\n d && e | f; g\n# note\nh \'i j\' &'),
            [["python3", "a b.py", "c", "d"], ["e"], ["f"], ["g"], ["h", "i j"]],
        )
        # An unbalanced quote (a heredoc's apostrophe) falls back to reading line by line.
        self.assertEqual(shell_commands("cat <<EOF\nit's\nEOF\npython3 x.py report"),
                         [["cat", "<<", "EOF"], ["it's"], ["EOF"], ["python3", "x.py", "report"]])

    def test_real_allowlist_entries_are_well_formed(self) -> None:
        seen = set()
        for workflow, job, script, rel, reach, reason in READ_ALLOWLIST:
            key = (workflow, job, script, rel)
            self.assertNotIn(key, seen, f"duplicate READ_ALLOWLIST entry {key}")
            seen.add(key)
            alternatives = (reach,) if isinstance(reach, str) else reach
            self.assertTrue(reason.strip() and alternatives and all(a.strip() for a in alternatives), key)
            for alternative in alternatives:
                for pattern in alternative.split():
                    re.compile(pattern)
            self.assertTrue(repo_has(ROOT, f".github/workflows/{workflow}"), key)
            self.assertTrue(repo_has(ROOT, script) and repo_has(ROOT, rel), key)


# The differential corpus's fixtures: (name, the script path it stands at, source). Names start with
# "fixture:"; the repo files they may read are docs/* and tools/run.py.
DIFFERENTIAL_FIXTURES = [
    ("fixture:writes-and-superseded", "tests/test_risk_tier.py", textwrap.dedent("""\
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
    """)),
    ("fixture:review-f1-f3", "tests/test_risk_tier.py",
     textwrap.dedent(SparseCheckoutReadTests.F1_TO_F3_BODY).replace("from pathlib import Path\n", textwrap.dedent("""\
        from pathlib import Path
        ROOT = Path(__file__).resolve().parents[1]
        CONFIG = ROOT / "docs/c.yml"
        BRANCH = ROOT / "docs/p.md"

        class Holder:
            SCRIPT = ROOT / "tools/run.py"

        def pick(fish):
            if fish:
                script = ROOT / "docs/j.json"
            else:
                script = ROOT / f"docs/{fish}.md"
            return script

        def test_uses():
            CONFIG.stat()
            SCRIPT = 1
            print(BRANCH, SCRIPT)
    """))),
]

DIFFERENTIAL_FIXTURES.append(("fixture:closure", "tests/test_risk_tier.py", textwrap.dedent("""\
    from pathlib import Path

    def outer():
        p = Path("docs/x.md")

        def inner():
            return p.read_text()

        return inner()
""")))

# What the base reader (33852f74) found that the current reader does not, each with why: only
# writes and values replaced before any use. (corpus file, repo path, why)
READ_REMOVALS = [
    ("fixture:writes-and-superseded", "docs/old.md", "superseded: `out` is rebound to a tmp path before its only use"),
    ("fixture:writes-and-superseded", "docs/gen.md", "a write: write_text"),
    ("fixture:writes-and-superseded", "docs/w.md", "a write: open(.., \"w\")"),
    ("fixture:writes-and-superseded", "docs/a.md", "a write: open(.., mode=\"a\")"),
]


def _tracked_files(root: Path) -> frozenset[str] | None:
    return _git_index(str(root))


def differential_corpus(root: Path, tracked: set[str]) -> list[tuple[str, str, str, object]]:
    """(name, script path, source, is_file) for every tracked tests/*.py, every script the real-tree
    check scans, and DIFFERENTIAL_FIXTURES. Files and their existence come from repo_has/repo_source
    (git's index), the same answers the real-tree check gets, so a full and a sparse checkout agree."""
    scripts = {rel for rel in tracked if rel.startswith("tests/") and rel.count("/") == 1 and rel.endswith(".py")}
    for workflow, job, _step, entries in non_cone_sparse_steps(root):
        scripts.update(listed_run_scripts(entries, _job_run_text(root, workflow, job), root))
    corpus = []
    for rel in sorted(scripts):
        corpus.append((rel, rel, repo_source(root, rel) or "", lambda path: repo_has(root, path)))
    fixture_files = lambda rel: rel.startswith("docs/") or rel == "tools/run.py"  # noqa: E731
    corpus.extend((name, script, source, fixture_files) for name, script, source in DIFFERENTIAL_FIXTURES)
    return corpus


# The corpus a forked worker compares; set by base_minus_current before the pool forks.
_DIFF_CORPUS: list[tuple[str, str, str, object]] = []


def _base_minus_current(index: int) -> tuple[str, list[str]]:
    """(corpus name, paths the base reader finds in that file and the current one does not)."""
    name, script, source, is_file = _DIFF_CORPUS[index]
    tree = parse_python(source)
    if tree is None:
        return name, []  # neither reader reads an unparsable file
    base = sparse_checkout_base_reader.base_read_paths(script, source, is_file, tree)
    return name, sorted(base - reads_in_source(script, source, is_file))


def base_minus_current(corpus: list[tuple[str, str, str, object]]) -> list[tuple[str, list[str]]]:
    """_base_minus_current over the corpus, in corpus order. Each file is independent, so the files
    are split over forked workers: they inherit the loaded module and the corpus, and only their
    results come back through a pipe (no function is pickled, so this works however the module was
    loaded). Serially where fork is not available."""
    global _DIFF_CORPUS
    _DIFF_CORPUS = corpus
    workers = min(8, os.cpu_count() or 1, len(corpus))
    try:
        context = multiprocessing.get_context("fork")
    except ValueError:
        context = None
    if context is None or workers < 2:
        return [_base_minus_current(i) for i in range(len(corpus))]

    def work(indices: list[int], conn) -> None:
        try:
            conn.send([(i, _base_minus_current(i)) for i in indices])
        except BaseException as error:  # noqa: BLE001 - surfaced in the parent
            conn.send(error)
        finally:
            conn.close()

    jobs = []
    for worker in range(workers):
        receive, send = context.Pipe(duplex=False)
        process = context.Process(target=work, args=(list(range(worker, len(corpus), workers)), send))
        process.start()
        send.close()
        jobs.append((process, receive))
    results: dict[int, tuple[str, list[str]]] = {}
    failure = None
    for process, receive in jobs:
        try:
            got = receive.recv()
        except EOFError:
            got = RuntimeError(f"differential worker {process.pid} died (exit {process.exitcode})")
        process.join()
        if isinstance(got, BaseException):
            failure = failure or got
        else:
            results.update(got)
    if failure is not None:
        raise failure
    return [results[i] for i in range(len(corpus))]


class SparseReadDifferentialTests(unittest.TestCase):
    """The current reader finds everything the base reader (33852f74, #41221's base) found, less READ_REMOVALS.

    #41221's rewrite lost reads the base reader saw (review of 6e9fbd93: read_text("utf-8"),
    open(file=...), a parameter rebound in its function, `a = b = ...`); this keeps any later change
    from losing one silently.
    """

    def test_current_reader_is_a_superset_of_the_base_reader(self) -> None:
        tracked = _tracked_files(ROOT)
        if tracked is None:
            self.skipTest("not a git checkout")
        allowed = {(name, rel) for name, rel, _why in READ_REMOVALS}
        lost, removed = [], set()
        for name, missing in base_minus_current(differential_corpus(ROOT, tracked)):
            for rel in missing:
                if (name, rel) in allowed:
                    removed.add((name, rel))
                else:
                    lost.append(f"{name}: the base reader finds {rel}, the current one does not")
        self.assertEqual(lost, [], "\n" + "\n".join(lost))
        stale = sorted(allowed - removed)
        self.assertEqual(stale, [], f"READ_REMOVALS entries no longer removed: {stale}")
        # Every read the current reader finds in a job's run scripts is listed in its sparse checkout or
        # allowlisted: a77b32f4's reads and its allowlist drifted apart (Native/DiffSidecar/Cargo.toml).
        unhandled = unhandled_read_misses(ROOT)
        self.assertEqual(unhandled, [], "\n" + "\n".join(unhandled))

    def test_removals_have_reasons(self) -> None:
        for name, rel, why in READ_REMOVALS:
            self.assertTrue(why.strip() and why.split(":")[0] in {"a write", "superseded"}, (name, rel, why))


if __name__ == "__main__":
    unittest.main()
