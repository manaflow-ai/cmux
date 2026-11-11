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
and the search path the script really gets: its own folder (sys.path[0]), then any PYTHONPATH the
workflow, the job or one of the job's steps sets. A script the job runs as `python -m pkg.main` (a
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

There is no allowlist. A script's own sys.path inserts of other folders and importlib calls are not
followed (as before).

Run: python3 tests/test_ci_sparse_checkout_imports.py
"""

from __future__ import annotations

import ast
import importlib.machinery
import modulefinder
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import contextmanager
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
    tree: Path, script: str, extra: tuple[str, ...], how: tuple[str, str] | None = None
) -> tuple[dict[str, str], dict[str, str]]:
    """Run ModuleFinder on `script` in `tree` with the search path the script gets.

    `how` is None for `python script.py` (sys.path[0] is the script's folder), or (module, folder)
    for `python -m module` run from that folder (sys.path[0]): the module is imported by name, so
    its parent packages (each __init__.py) load first, as they do at run time.

    Returns ({module: where it loads from}, {module: its importer}). Places are tree-relative: a
    file, or a folder ending in "/" for a namespace package. Modules outside the tree (builtins) and
    the script itself (__main__) are left out.
    """
    tree = tree.resolve()
    first = str(tree / script).rsplit("/", 1)[0] if how is None else str(tree / how[1])
    finder = _Finder([first, *(str(tree / rel) for rel in extra)])
    with _importer_cache_scope(tree):
        if how is None:
            finder.run_script(str(tree / script))
        else:
            try:
                finder.import_hook(how[0])
            except ImportError:
                pass  # the same in both runs when the module is not there
    places: dict[str, str] = {}
    for name, module in finder.modules.items():
        if name == "__main__":
            continue
        if module.__file__:
            location = Path(module.__file__)
            suffix = ""
        elif module.__path__:
            location = Path(module.__path__[0])
            suffix = "/"
        else:
            continue
        if location.is_relative_to(tree):
            places[name] = location.relative_to(tree).as_posix() + suffix
    return places, finder.importer


@lru_cache(maxsize=None)
def full_run(
    root: Path, script: str, extra: tuple[str, ...], how: tuple[str, str] | None
) -> tuple[dict[str, str], dict[str, str]]:
    return find_modules(root, script, extra, how)


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
    scripts: tuple[tuple[str, tuple[str, str] | None], ...],
    extra: tuple[str, ...],
) -> tuple[frozenset[str], dict[str, dict[str, str] | None]]:
    """The files this list checks out of `files`, and each script's modules in that tree (None if the
    script is not in it)."""
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp).resolve()
        present = make_sparse_tree(tree, entries, files, root)
        return present, {s: find_modules(tree, s, extra, how)[0] if s in present else None for s, how in scripts}


# --- workflows --------------------------------------------------------------------------------

_INLINE_PYTHONPATH = re.compile(r"(?:^|\s)PYTHONPATH=(\S+)")
_RUN_MODULE = re.compile(r"\bpython[\d.]*\b[^\n;&|]*?\s-m\s*([A-Za-z_][\w.]*)")


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


def _pythonpath_dirs(values: list[str], root: Path) -> tuple[str, ...]:
    """Repo-relative folders named by PYTHONPATH values (relative, or under ${{ github.workspace }})."""
    out: list[str] = []
    for value in values:
        for part in value.strip("'\"").split(":"):
            part = re.sub(r"^\$\{\{\s*github\.workspace\s*\}\}/?", "", part.strip())
            part = re.sub(r"^\$\{?GITHUB_WORKSPACE\}?/?", "", part)
            if not part or part.startswith("/") or "$" in part:
                continue
            rel = os.path.normpath(part)
            rel = "" if rel == "." else rel
            if not rel.startswith("..") and rel not in out and (root / rel).is_dir():
                out.append(rel)
    return tuple(out)


def _job_pythonpath(doc: dict, job: dict, root: Path) -> tuple[str, ...]:
    """PYTHONPATH the workflow, the job or any step of the job sets (env, or inline in a run line)."""
    values = []
    for scope in (doc, job, *[s for s in job.get("steps") or [] if isinstance(s, dict)]):
        env = scope.get("env")
        if isinstance(env, dict) and env.get("PYTHONPATH") is not None:
            values.append(str(env["PYTHONPATH"]))
        if scope is not doc and scope is not job and isinstance(scope.get("run"), str):
            values.extend(_INLINE_PYTHONPATH.findall(scope["run"]))
    return _pythonpath_dirs(values, root)


def non_cone_sparse_steps(root: Path):
    """(workflow, job, step name, entries, PYTHONPATH folders, `python -m` modules) per actions/checkout
    step with a non-cone sparse list."""
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
                yield (
                    path.name,
                    str(job_id),
                    name,
                    sparse_entries(raw),
                    _job_pythonpath(doc, job, root),
                    _job_run_modules(job),
                )


def find_misses(root: Path) -> list[str]:
    """One line per (step, missing module), naming the module that imports it."""
    root = root.resolve()
    misses = []
    for workflow, job, step, entries, extra, run_modules in non_cone_sparse_steps(root):
        listed = listed_ci_scripts(entries, root)
        if not listed:
            continue
        hows = {script: how_it_runs(script, run_modules) for script in listed}
        full = {script: full_run(root, script, extra, hows[script]) for script in listed}
        files = set(listed)
        for places, _ in full.values():
            files |= _files_for(places, root)
        # Files the list names stay too, so its patterns see the neighbours they see in the real tree.
        files |= {rel for rel in (e.lstrip("/") for e in entries if not e.startswith("!")) if rel and (root / rel).is_file()}
        present, sparse = sparse_runs(
            root, tuple(entries), frozenset(files), tuple((s, hows[s]) for s in listed), extra
        )
        found: dict[str, tuple[str, str]] = {}  # missing place -> (importer's place, listed script)
        for script in listed:
            if sparse[script] is None:
                continue  # excluded by a "!" entry: not checked out, nothing to run
            places, importer = full[script]
            lost = {}
            for name, place in places.items():
                there = sparse[script].get(name)
                if there == place:
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
                f"{workflow} {job} {step}: {by_place} imports {place}, not in its sparse checkout"
                + ("" if by_place == script else f" (via {script})")
            )
    return misses


# --- tests ------------------------------------------------------------------------------------


class SparseCheckoutImportTests(unittest.TestCase):
    def test_workflows_list_every_imported_ci_module(self) -> None:
        steps = list(non_cone_sparse_steps(ROOT))
        self.assertTrue(steps, "expected at least one non-cone sparse checkout in .github/workflows")
        misses = find_misses(ROOT)
        self.assertEqual(misses, [], "\n" + "\n".join(misses))

    def _fixture(self, tmp: Path, sparse: str, job_env: str = "", run: str = "true") -> Path:
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
                """
            )
            .replace("SPARSE", sparse)
            .replace("JOB_ENV", job_env)
            .replace("RUN", run),
            encoding="utf-8",
        )
        return tmp

    def _misses(self, sparse: str, job_env: str = "", run: str = "true") -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            return find_misses(self._fixture(Path(tmp), sparse, job_env, run))

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
