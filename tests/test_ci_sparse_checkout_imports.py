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

Run: python3 tests/test_ci_sparse_checkout_imports.py
"""

from __future__ import annotations

import ast
import os
import subprocess
import tempfile
import textwrap
import unittest
from functools import lru_cache
from pathlib import Path

import yaml

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


# --- tests ------------------------------------------------------------------------------------


class SparseCheckoutImportTests(unittest.TestCase):
    def test_workflows_list_every_imported_ci_module(self) -> None:
        steps = list(non_cone_sparse_steps(ROOT))
        self.assertTrue(steps, "expected at least one non-cone sparse checkout in .github/workflows")
        misses = find_misses(ROOT)
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


if __name__ == "__main__":
    unittest.main()
