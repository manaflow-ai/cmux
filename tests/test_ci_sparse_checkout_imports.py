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
the script runs without it. There is no allowlist.

The same lists must also hold the repo files their tests read. #41164 at af61f28e added a test to
tests/test_risk_tier.py that reads `ROOT / ".github/workflows/risk-tier.yml"`; risk-tier-tests.yml
checked out only the test and its script, so CI died with FileNotFoundError. For each test file
(test_*.py or *_test.py) the list names by exact path and the job's `run:` steps name, every path
it builds statically (`ROOT / "a/b"`, `ROOT / "a" / "b"`, `ROOT.joinpath(...)`, `.parents[n]`,
`os.path.join(HERE, ...)`, `open("a/b")`, `Path("a/b")`) that is a file in the repo must be
checked out, by the same git oracle. A name counts only when every assignment to it gives the same
repo path, so tmp fixtures never count. Scripts are not checked this way: a subcommand may never
reach a read, while a test file runs all of its tests.

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


def listed_run_scripts(entries: list[str], run_text: str, root: Path, tests_only: bool = True) -> list[str]:
    """.py files the entries name by exact path that the job's `run:` steps also name.

    By default only test files: a script's run may take a subcommand that never reaches a read,
    while a test file runs all of its tests.
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
    if out == ".." or out.startswith("../"):
        return None
    return out


def _join(base: str, *parts: str) -> str | None:
    return _norm(posixpath.join(base, *parts) if base else posixpath.join(*parts))


def _dirname(rel: str) -> str | None:
    return None if rel == "" else rel.rsplit("/", 1)[0] if "/" in rel else ""


_PATH_CALLS = {"Path", "PurePath", "PosixPath", "pathlib.Path"}
_IDENTITY_METHODS = {"resolve", "absolute", "expanduser"}
_IDENTITY_OS = {"os.path.abspath", "os.path.realpath", "os.path.normpath", "os.fspath", "str"}


def _dotted(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        head = _dotted(node.value)
        return f"{head}.{node.attr}" if head else None
    return None


def _literal(node: ast.AST) -> str | None:
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None


class _RepoPaths:
    """Evaluates expressions that name a repo-relative path statically.

    `__file__` is the script's own path; `Path("x")` and `open("x")` with a relative literal are
    taken from the repo root, where the workflow runs them. A name counts only when every
    assignment to it in the file evaluates to the same path, so a fixture variable reassigned to a
    tmp dir is never taken for the repo.
    """

    def __init__(self, script: str, tree: ast.AST) -> None:
        self.script = script
        self.env: dict[str, str] = {}
        assigns: dict[str, list[ast.AST]] = {}
        for node in ast.walk(tree):
            targets: list[ast.AST] = []
            value = None
            if isinstance(node, ast.Assign):
                targets, value = node.targets, node.value
            elif isinstance(node, (ast.AnnAssign, ast.AugAssign, ast.NamedExpr)):
                targets, value = [node.target], node.value
            elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
                targets, value = [node.target], None
            elif isinstance(node, (ast.With, ast.AsyncWith)):
                targets = [item.optional_vars for item in node.items if item.optional_vars is not None]
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                args = node.args
                targets = [ast.Name(id=a.arg) for a in [*args.posonlyargs, *args.args, *args.kwonlyargs]]
            for target in targets:
                for name in ast.walk(target):
                    if isinstance(name, ast.Name):
                        ok = isinstance(target, ast.Name) and value is not None and not isinstance(node, ast.AugAssign)
                        assigns.setdefault(name.id, []).append(value if ok else None)
        changed = True
        while changed:
            changed = False
            for name, values in assigns.items():
                if name in self.env or any(v is None for v in values):
                    continue
                results = {self.eval(v) for v in values}
                if len(results) == 1 and None not in results:
                    self.env[name] = results.pop()
                    changed = True

    def eval(self, node: ast.AST) -> str | None:
        if isinstance(node, ast.Name):
            if node.id == "__file__":
                return self.script
            return self.env.get(node.id)
        if isinstance(node, ast.Attribute):
            if node.attr == "parent":
                base = self.eval(node.value)
                return None if base is None else _dirname(base)
            return None
        if isinstance(node, ast.Subscript):
            if isinstance(node.value, ast.Attribute) and node.value.attr == "parents":
                index = node.slice
                if isinstance(index, ast.Constant) and isinstance(index.value, int) and index.value >= 0:
                    out = self.eval(node.value.value)
                    for _ in range(index.value + 1):
                        out = None if out is None else _dirname(out)
                    return out
            return None
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            base, part = self.eval(node.left), _literal(node.right)
            return None if base is None or part is None else _join(base, part)
        if isinstance(node, ast.Call):
            func = _dotted(node.func)
            if node.keywords:
                return None
            if func in _PATH_CALLS or func in _IDENTITY_OS:
                if len(node.args) != 1:
                    return None
                arg = node.args[0]
                literal = _literal(arg)
                if literal is not None:
                    return _norm(literal) if func in _PATH_CALLS and literal else None
                return self.eval(arg)
            if func == "os.path.dirname" and len(node.args) == 1:
                base = self.eval(node.args[0])
                return None if base is None else _dirname(base)
            if func == "os.path.join" and node.args:
                base = self.eval(node.args[0])
                parts = [_literal(a) for a in node.args[1:]]
                return None if base is None or None in parts else _join(base, *parts)
            if isinstance(node.func, ast.Attribute):
                method = node.func.attr
                if method in _IDENTITY_METHODS and not node.args:
                    return self.eval(node.func.value)
                if method == "joinpath" and node.args:
                    base = self.eval(node.func.value)
                    parts = [_literal(a) for a in node.args]
                    return None if base is None or None in parts else _join(base, *parts)
        return None


def read_paths(script: str, root: Path) -> set[str]:
    """Repo files `script` names by a statically known path (`ROOT / "a/b"`, `open("a/b")`, ...).

    Only paths that are files in `root` count; directories, globs and anything built from a
    variable that is not always the same repo path are skipped.
    """
    try:
        tree = ast.parse((root / script).read_text(encoding="utf-8"))
    except (OSError, SyntaxError, UnicodeDecodeError):
        return set()
    paths = _RepoPaths(script, tree)
    found: set[str] = set()
    for node in ast.walk(tree):
        rel = None
        if isinstance(node, ast.Call) and _dotted(node.func) in {"open", "io.open"} and node.args:
            literal = _literal(node.args[0])
            rel = _norm(literal) if literal else paths.eval(node.args[0])
        elif isinstance(node, (ast.BinOp, ast.Call, ast.Subscript, ast.Attribute)):
            rel = paths.eval(node)
        if rel and rel != script and (root / rel).is_file():
            found.add(rel)
    return found


def _job_run_text(root: Path, workflow: str, job: str) -> str:
    doc = yaml.safe_load((root / ".github" / "workflows" / workflow).read_text(encoding="utf-8")) or {}
    steps = ((doc.get("jobs") or {}).get(job) or {}).get("steps") or []
    return "\n".join(str(step.get("run") or "") for step in steps if isinstance(step, dict))


def find_read_misses(root: Path, tests_only: bool = True) -> list[str]:
    """One line per (step, run test file, repo file it reads that the sparse list leaves out)."""
    misses = []
    for workflow, job, step, entries in non_cone_sparse_steps(root):
        scripts = listed_run_scripts(entries, _job_run_text(root, workflow, job), root, tests_only)
        reads = {script: read_paths(script, root) for script in scripts}
        candidates = set(scripts).union(*reads.values())
        present = checked_out(entries, candidates, root)
        for script in scripts:
            if script not in present:
                continue
            for rel in sorted(reads[script] - present):
                misses.append(f"{workflow} {job} {step}: {script} reads {rel}, not in its sparse checkout")
    return misses


# --- tests ------------------------------------------------------------------------------------


class SparseCheckoutImportTests(unittest.TestCase):
    def test_workflows_list_every_imported_ci_module(self) -> None:
        steps = list(non_cone_sparse_steps(ROOT))
        self.assertTrue(steps, "expected at least one non-cone sparse checkout in .github/workflows")
        misses = find_misses(ROOT)
        self.assertEqual(misses, [], "\n" + "\n".join(misses))

    def test_workflows_list_every_repo_file_their_tests_read(self) -> None:
        misses = find_read_misses(ROOT)
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
    def _misses(self, files: dict[str, str], extra: str = "", tests_only: bool = True) -> list[str]:
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

    def test_scripts_are_skipped_unless_asked(self) -> None:
        # A script's subcommand may never reach a read; a test file runs every test.
        workflow = RISK_TIER_TESTS_YML.replace("tests/test_risk_tier.py", "tools/run_me.py").replace("EXTRA", "")
        files = {
            ".github/workflows/risk-tier-tests.yml": workflow,
            "tools/run_me.py": TEST_RISK_TIER_PY,
        }
        self.assertEqual(self._misses(files), [])
        self.assertEqual(len(self._misses(files, tests_only=False)), 1)


if __name__ == "__main__":
    unittest.main()
