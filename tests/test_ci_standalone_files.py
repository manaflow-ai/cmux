#!/usr/bin/env python3
"""A script that is fetched or checked out with a few files runs with just those files.

cmux#62040 made cmux-tui/crates/acpmux/tests/fake_agent.py read a sibling guidance_sources.json at
import. The fleet's notify-banner-click probe (cmuxterm-hq, `.github/actions/cmux-files`) fetches
fake_agent.py alone, so the stub died with FileNotFoundError and the probe read a bare
`agent_session.refused` for about 17 h, which looked like a product regression (fixed by #63419).
tests/test_ci_sparse_checkout_imports.py follows imports under scripts/ and the reads of test files;
neither saw a non-test file outside scripts/ reading a data file beside itself at import.

This test runs each such script as its consumer does: for every file set below it builds an empty
temporary tree holding exactly that set at its repository paths, runs each set member with a
`__main__` guard there (module-level code only: imports, constants, files read at import; never
main()), and runs it the same way in the full tree. A script that loads in the full tree and dies
alone reads or imports something its set does not ship. It also follows each run script's static
imports (Python, `source` of a sibling shell file, relative JS/TS imports) and names any repository
file they reach outside the set, so a lazy import inside a function is caught too.

The sets:
- every actions/checkout step in this repository's workflows with a non-cone `sparse-checkout`
  (git decides what the list holds: `git sparse-checkout check-rules`);
- every set in .github/standalone-files.json: consumers outside this repository (cmuxterm-hq
  probes, fleet tools) that fetch single files by contents API, raw URL, `git show REF:path` or a
  sparse checkout of manaflow-ai/cmux at the branch tip. A consumer pinned to an older commit is
  left out until its pin moves (the pin's files are fixed). On the hq side,
  tools/fleet-reconcilers/test_sparse_checkout_imports.py checks hq's own sparse sets.

Fix a miss at the cause: make the script carry what it needs (fake_agent.py carries GUIDANCE_SOURCES
inline), or widen the consumer's list and this file's set to exactly what it runs.

Run: python3 tests/test_ci_standalone_files.py
"""

from __future__ import annotations

import ast
import importlib.util
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ".github/standalone-files.json"
# One run of a script's module-level code; a script that blocks at import (a server at module level)
# counts as loaded, in both trees alike.
RUN_SECONDS = 20
# A sparse list that holds more files than this is a directory checkout: its run scripts get the
# static checks only (copying thousands of files per set would cost minutes, and a whole folder ships
# its siblings anyway).
MAX_COPY_FILES = 1500
# What a set runs, unless it says: each file it names by exact path with one of these suffixes.
RUN_SUFFIXES = (".py", ".sh", ".js", ".mjs", ".cjs", ".ts")

_spec = importlib.util.spec_from_file_location(
    "sparse_imports", Path(__file__).resolve().parent / "test_ci_sparse_checkout_imports.py")
sparse_imports = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sparse_imports)

# The harness: the script's own folder first on sys.path, as `python3 FILE` puts it; argv[0] is the
# script; run_name is not "__main__", so a guarded main() never runs.
LOADER = (
    "import os, runpy, sys\n"
    "p = sys.argv[1]\n"
    "sys.argv = [p]\n"
    "sys.path.insert(0, os.path.dirname(os.path.abspath(p)))\n"
    "runpy.run_path(p, run_name='__standalone_check__')\n"
)


def _git(*args: str, stdin: str | None = None, root: Path = ROOT) -> str:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
    result = subprocess.run(["git", *args], cwd=root, env=env, input=stdin, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


@lru_cache(maxsize=None)
def tracked_files(root: Path = ROOT) -> tuple[str, ...]:
    return tuple(p for p in _git("ls-files", "-z", root=root).split("\0") if p)


@lru_cache(maxsize=None)
def materialized(entries: tuple[str, ...], cone: bool, root: Path = ROOT) -> frozenset[str]:
    """The tracked files a sparse checkout with these patterns holds, as git itself decides."""
    with tempfile.NamedTemporaryFile("w", suffix=".sparse", delete=False) as rules:
        rules.write("".join(f"{e}\n" for e in entries))
    try:
        out = _git("sparse-checkout", "check-rules", "-z", "--cone" if cone else "--no-cone",
                   "--rules-file", rules.name, stdin="\0".join(tracked_files(root)) + "\0", root=root)
    finally:
        os.unlink(rules.name)
    return frozenset(p for p in out.split("\0") if p)


# --- file sets --------------------------------------------------------------------------------


def jobs_with_a_full_checkout(root: Path = ROOT) -> set[tuple[str, str]]:
    """(workflow, job) for each job that also checks this repository out whole: a sparse step there
    (a harness pinned into .harness, then copied over the full tree) runs beside every file."""
    found = set()
    for path in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        doc = sparse_imports._load_workflow(path)
        jobs = doc.get("jobs") if isinstance(doc, dict) else None
        for job_id, job in (jobs or {}).items():
            for step in (job or {}).get("steps") or []:
                if not isinstance(step, dict) or not str(step.get("uses") or "").startswith("actions/checkout@"):
                    continue
                options = step.get("with") or {}
                repo = str(options.get("repository") or "manaflow-ai/cmux")
                if options.get("sparse-checkout") is None and repo.endswith("/cmux"):
                    found.add((path.name, str(job_id)))
    return found


def workflow_sets(root: Path = ROOT):
    """(label, files, run) for each non-cone sparse checkout in this repo's workflows."""
    full = jobs_with_a_full_checkout(root)
    for workflow, job, step, entries in sparse_imports.non_cone_sparse_steps(root):
        if (workflow, job) in full:
            continue
        files = materialized(tuple(entries), False, root)
        run = [e.lstrip("/") for e in entries
               if not e.startswith("!") and e.lstrip("/") in files and e.endswith(RUN_SUFFIXES)]
        yield f"{workflow} {job} {step}", files, run


def manifest_sets(root: Path = ROOT):
    """(label, files, run) for each external consumer's set in .github/standalone-files.json."""
    doc = json.loads((root / MANIFEST).read_text(encoding="utf-8"))
    for item in doc["sets"]:
        entries = item["files"]
        files = materialized(tuple(entries), bool(item.get("cone", False)), root)
        run = item.get("run")
        if run is None:
            run = [e for e in entries if e.endswith(RUN_SUFFIXES) and e in files]
        yield item["consumer"], files, list(run)


# --- static references ------------------------------------------------------------------------

_SH_DIR_VAR = re.compile(r"""^\s*(?:local\s+|readonly\s+|declare\s+\S+\s+)?([A-Za-z_][A-Za-z0-9_]*)=.*dirname.*(?:BASH_SOURCE|\$0)""")
_SH_SOURCE = re.compile(r"""^\s*(?:source|\.)\s+["']?(\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?|\$\(dirname\s+["']?\$(?:\{BASH_SOURCE(?:\[0\])?\}|0)["']?\))/([A-Za-z0-9_./-]+)""")
_JS_IMPORT = re.compile(r"""(?:\bfrom\s+|\bimport\s*\(\s*|\brequire\s*\(\s*|^\s*import\s+)["'](\.{1,2}/[^"']+)["']""", re.M)
_JS_EXTS = ("", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".json", "/index.ts", "/index.js")


def _norm(rel: str) -> str | None:
    out = posixpath.normpath(rel)
    return None if out.startswith("..") else out


def static_refs(script: str, root: Path = ROOT) -> dict[str, str]:
    """Repository files `script` reaches by import or `source` -> the file that reaches it."""
    if script.endswith(".py"):
        return sparse_imports.import_closure(script, root)
    try:
        text = (root / script).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return {}
    here = posixpath.dirname(script)
    found: dict[str, str] = {}
    if script.endswith(".sh") or text.startswith("#!/bin/bash") or text.startswith("#!/usr/bin/env bash"):
        dir_vars = {m.group(1) for line in text.splitlines() if (m := _SH_DIR_VAR.match(line))}
        for line in text.splitlines():
            m = _SH_SOURCE.match(line)
            if not m or (m.group(2) and m.group(2) not in dir_vars):
                continue
            rel = _norm(posixpath.join(here, m.group(3)))
            if rel and (root / rel).is_file():
                found[rel] = script
    elif script.endswith((".js", ".mjs", ".cjs", ".ts", ".tsx")):
        for spec in _JS_IMPORT.findall(text):
            base = _norm(posixpath.join(here, spec))
            for ext in _JS_EXTS:
                if base and (root / (base + ext)).is_file():
                    found[base + ext] = script
                    break
    return found


# --- running alone ----------------------------------------------------------------------------


def has_main_guard(script: str, root: Path = ROOT) -> bool:
    """Only a script whose main() waits behind `if __name__ == "__main__"` is safe to load here."""
    try:
        tree = ast.parse((root / script).read_text(encoding="utf-8"))
    except (OSError, SyntaxError, UnicodeDecodeError):
        return False
    for node in tree.body:
        if isinstance(node, ast.If) and "__name__" in ast.unparse(node.test) and "__main__" in ast.unparse(node.test):
            return True
    return False


def load(script_path: Path, cwd: Path, home: Path) -> tuple[bool, str]:
    """(loaded, stderr tail) for one run of the script's module-level code."""
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home), "LANG": "C.UTF-8",
           "TMPDIR": str(home), "PYTHONDONTWRITEBYTECODE": "1"}
    try:
        result = subprocess.run([sys.executable, "-I", "-c", LOADER, str(script_path)], cwd=cwd, env=env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=RUN_SECONDS)
    except subprocess.TimeoutExpired:
        return True, ""
    tail = "\n".join(result.stderr.strip().splitlines()[-4:])
    return result.returncode == 0, tail


def copy_set(files: frozenset[str], dest: Path, root: Path = ROOT) -> None:
    for rel in files:
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        src = root / rel
        if src.is_symlink() or not src.is_file():
            continue  # a submodule gitlink or a symlink: nothing a lone fetch would carry either
        shutil.copyfile(src, target)


def find_misses(sets, root: Path = ROOT) -> list[str]:
    """One line per (set, run script, what it needs that the set leaves out)."""
    misses: list[str] = []
    baseline: dict[str, tuple[bool, str]] = {}
    done: set[tuple[frozenset[str], str]] = set()
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp) / "home"
        home.mkdir()
        for label, files, run in sets:
            run = [s for s in run if s in files and (root / s).is_file()]
            if not run:
                continue
            for script in run:
                for dep, importer in sorted(static_refs(script, root).items()):
                    if dep not in files:
                        via = "" if importer == script else f" (via {importer})"
                        misses.append(f"{label}: {script} imports {dep}, not in its set{via}")
            runnable = [s for s in run if s.endswith(".py") and has_main_guard(s, root)
                        and (files, s) not in done]
            if not runnable or len(files) > MAX_COPY_FILES:
                continue
            alone = Path(tempfile.mkdtemp(dir=tmp))
            copy_set(files, alone, root)
            for script in runnable:
                done.add((files, script))
                if script not in baseline:
                    baseline[script] = load(root / script, root, home)
                if not baseline[script][0]:
                    continue  # does not load in the full tree either (a missing third-party module)
                ok, tail = load(alone / script, alone, home)
                if not ok:
                    misses.append(f"{label}: {script} fails to load with only its set:\n    "
                                  + tail.replace("\n", "\n    "))
            shutil.rmtree(alone, ignore_errors=True)
    return misses


# --- tests ------------------------------------------------------------------------------------


class StandaloneFilesTests(unittest.TestCase):
    def test_every_external_set_runs_alone(self) -> None:
        misses = find_misses(manifest_sets())
        self.assertEqual(misses, [], "\n" + "\n".join(misses))

    def test_every_workflow_sparse_set_runs_alone(self) -> None:
        misses = find_misses(workflow_sets())
        self.assertEqual(misses, [], "\n" + "\n".join(misses))

    def test_manifest_names_only_tracked_files(self) -> None:
        doc = json.loads((ROOT / MANIFEST).read_text(encoding="utf-8"))
        tracked = set(tracked_files())
        def present(path: str) -> bool:
            bare = path.strip("/")
            return bare in tracked or any(t.startswith(bare + "/") for t in tracked)
        stale = [f"{item['consumer']}: {path}" for item in doc["sets"]
                 for path in item["files"] + item.get("run", [])
                 if not item.get("cone") and not path.startswith("!") and not present(path)]
        self.assertEqual(stale, [], "a set names a file this tree no longer has: drop it here and in the consumer")


class DetectorSelfTests(unittest.TestCase):
    """The detector catches the #62040 shape: a script that reads a file beside itself at import."""

    def _repo(self, files: dict[str, str]) -> Path:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        for rel, text in files.items():
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (tmp / rel).write_text(text)
        _git("init", "-q", root=tmp)
        _git("add", "-A", root=tmp)
        tracked_files.cache_clear()
        materialized.cache_clear()
        self.addCleanup(tracked_files.cache_clear)
        self.addCleanup(materialized.cache_clear)
        return tmp

    AGENT = ("import json, os\n"
             "HERE = os.path.dirname(os.path.abspath(__file__))\n"
             "SOURCES = json.load(open(os.path.join(HERE, 'guidance_sources.json')))\n"
             "def main():\n    pass\n"
             "if __name__ == '__main__':\n    main()\n")

    def test_a_sibling_read_at_import_is_a_miss(self) -> None:
        root = self._repo({"t/fake_agent.py": self.AGENT, "t/guidance_sources.json": "[]"})
        files = materialized(("t/fake_agent.py",), False, root)
        misses = find_misses([("probe", files, ["t/fake_agent.py"])], root)
        self.assertEqual(len(misses), 1, misses)
        self.assertIn("guidance_sources.json", misses[0])

    def test_shipping_the_sibling_passes(self) -> None:
        root = self._repo({"t/fake_agent.py": self.AGENT, "t/guidance_sources.json": "[]"})
        files = materialized(("t/fake_agent.py", "t/guidance_sources.json"), False, root)
        self.assertEqual(find_misses([("probe", files, ["t/fake_agent.py"])], root), [])

    def test_a_lazy_sibling_import_is_a_miss(self) -> None:
        root = self._repo({"s/run.py": "def f():\n    import helper\nif __name__ == '__main__':\n    f()\n",
                           "s/helper.py": ""})
        files = materialized(("s/run.py",), False, root)
        misses = find_misses([("job", files, ["s/run.py"])], root)
        self.assertEqual(misses, ["job: s/run.py imports s/helper.py, not in its set"])

    def test_a_sourced_shell_sibling_is_a_miss(self) -> None:
        root = self._repo({"s/run.sh": 'here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)\nsource "$here/lib.sh"\n',
                           "s/lib.sh": ""})
        files = materialized(("s/run.sh",), False, root)
        self.assertEqual(find_misses([("job", files, ["s/run.sh"])], root),
                         ["job: s/run.sh imports s/lib.sh, not in its set"])

    def test_a_relative_js_import_is_a_miss(self) -> None:
        root = self._repo({"s/plan.js": "const x = require('./lib');\n", "s/lib.js": ""})
        files = materialized(("s/plan.js",), False, root)
        self.assertEqual(find_misses([("job", files, ["s/plan.js"])], root),
                         ["job: s/plan.js imports s/lib.js, not in its set"])


if __name__ == "__main__":
    unittest.main()
