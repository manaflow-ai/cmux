#!/usr/bin/env python3
"""One module object per script, whichever test loads it first.

tests/test_ci_change_areas.py loaded scripts/ci/cmux_next_route.py by path and put that second module object in
sys.modules. Run in one pytest process after it, test_cmux_next_route.py's LinuxLaneTests imported the copy and
patched SWIFT_JOB_INPUTS there, while route() (imported when pytest collected the file) read the first object, so
test_a_linux_guard_test_a_mac_tier_reads_keeps_its_tier failed only in a shared process.

The class: a test loads a file by path (importlib's spec_from_file_location, SourceFileLoader, imp.load_source,
runpy.run_path or run_module) while another test imports the same file by name. Two module objects then exist for
one file, and a patch of one is not seen through the other. A test imports such a file by name instead (after
putting its folder on sys.path), which returns the module sys.modules already holds.

Three checks:
- No test loads by path a repository file that some test imports by name (static, every test file).
- Importing the test files that share script modules, forward and reversed, leaves one module object per file.
- The polluter and the test it broke pass together in both orders, in one process.
"""
from __future__ import annotations

import ast
import collections
import importlib.util
import json
import os
import re
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOADERS = {"spec_from_file_location", "SourceFileLoader", "load_source", "run_path", "run_module"}
IDENTIFIER = re.compile(r"[A-Za-z_]\w*")


def test_files(root: Path = ROOT) -> list[Path]:
    found = set(root.glob("tests/*.py")) | set(root.glob("scripts/**/tests/*.py")) | set(root.glob("scripts/tests/*.py"))
    return sorted(found)


def scan(path: Path) -> tuple[set[str], list[tuple[int, str, str]]]:
    """(names the file imports, [(line, loader, stem)] of its path loads of a repository file)."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    assigns: dict[str, list[ast.AST]] = collections.defaultdict(list)
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AnnAssign) and node.value is not None:
            targets = [node.target]
        else:
            continue
        for target in targets:
            if isinstance(target, ast.Name):
                assigns[target.id].append(node.value)

    def names(node: ast.AST) -> set[str]:
        return {n.id for n in ast.walk(node) if isinstance(n, ast.Name)}

    def in_repo(node: ast.AST, seen: frozenset[str]) -> bool:
        # A path built from __file__ (ROOT, HERE, SCRIPT ...) names a repository file; one built from a temporary
        # folder names a copy, which no other test imports.
        if "__file__" in names(node):
            return True
        return any(in_repo(value, seen | {name}) for name in names(node) - seen for value in assigns.get(name, []))

    def file_name(node: ast.AST, seen: frozenset[str] = frozenset()) -> str | None:
        for n in ast.walk(node):
            if isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value.endswith(".py"):
                return n.value
        for name in names(node) - seen:
            for value in assigns.get(name, []):
                found = file_name(value, seen | {name})
                if found:
                    return found
        return None

    imported: set[str] = set()
    loads: list[tuple[int, str, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            imported.add(node.module.split(".")[0])
        elif isinstance(node, ast.Call):
            func = node.func
            called = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
            if called == "import_module" and node.args and isinstance(node.args[0], ast.Constant):
                imported.add(str(node.args[0].value).split(".")[0])
            if called not in LOADERS:
                continue
            if called == "run_module":
                if node.args and isinstance(node.args[0], ast.Constant):
                    loads.append((node.lineno, called, str(node.args[0].value).split(".")[0]))
                continue
            target = node.args[0] if called == "run_path" else (node.args[1] if len(node.args) > 1 else None)
            if target is None:
                continue
            name = file_name(target)
            if name and in_repo(target, frozenset()) and IDENTIFIER.fullmatch(Path(name).stem):
                loads.append((node.lineno, called, Path(name).stem))
    return imported, loads


def two_object_loads(root: Path = ROOT) -> tuple[list[str], dict[str, set[str]], dict[str, set[str]]]:
    """Path loads of a file another test imports by name, plus who imports and who loads each module."""
    importers: dict[str, set[str]] = collections.defaultdict(set)
    loaders: dict[str, list[tuple[str, int, str]]] = collections.defaultdict(list)
    for path in test_files(root):
        rel = path.relative_to(root).as_posix()
        imported, loads = scan(path)
        for name in imported:
            importers[name].add(rel)
        for line, called, stem in loads:
            loaders[stem].append((rel, line, called))
    findings = [
        f"{rel}:{line}: {called} loads {stem}.py by path, but {', '.join(sorted(importers[stem])[:3])} import it by "
        f"name: two module objects for one file. Put its folder on sys.path and `import {stem}` instead."
        for stem, sites in sorted(loaders.items()) if importers.get(stem)
        for rel, line, called in sites
    ]
    return findings, importers, {stem: {rel for rel, _, _ in sites} for stem, sites in loaders.items()}


# Run in a fresh interpreter: imports each test module in the given order, then reports any repository file that
# sys.modules holds a module object of (what `import name` returns) while a test module's globals hold another.
# Private copies nothing registers (tests/git_fixture_env.py, loaded by path in each test file by design because
# `python3 -I` puts no folder on sys.path) are no second object of an importable module, so they do not count.
ONE_OBJECT_PER_FILE = textwrap.dedent('''
    import importlib, json, os, sys, types
    root, order = sys.argv[1], json.loads(sys.argv[2])
    for folder in {os.path.dirname(os.path.join(root, rel)) for rel in order}:
        sys.path.insert(0, folder)
    loaded = [importlib.import_module(os.path.basename(rel)[:-3]) for rel in order]
    def file_of(module):
        path = getattr(module, "__file__", None)
        real = os.path.realpath(path) if path else ""
        return real if real.startswith(os.path.realpath(root) + os.sep) else None
    registered = {}
    for name, module in list(sys.modules.items()):
        if isinstance(module, types.ModuleType) and file_of(module):
            registered.setdefault(file_of(module), {})[id(module)] = name
    held = {}
    for test in loaded:
        for value in vars(test).values():
            if isinstance(value, types.ModuleType) and file_of(value) in registered:
                held.setdefault(file_of(value), {})[id(value)] = test.__name__ + "." + value.__name__
    two = {}
    for path, objects in registered.items():
        every = {**held.get(path, {}), **objects}
        if len(every) > 1:
            two[os.path.relpath(path, root)] = sorted(every.values())
    print(json.dumps(two))
''')

POLLUTER = "tests/test_ci_change_areas.py::test_cmux_next_does_not_run_full_suite_for_unrelated_packages"
VICTIM = "tests/test_cmux_next_route.py::LinuxLaneTests::test_a_linux_guard_test_a_mac_tier_reads_keeps_its_tier"


class ScriptModuleLoadTests(unittest.TestCase):
    def test_no_test_loads_by_path_a_file_another_test_imports_by_name(self):
        findings, _, _ = two_object_loads()
        self.assertEqual(findings, [], "\n" + "\n".join(findings))

    def test_the_scan_finds_the_route_copy_that_broke_linux_lane_tests(self):
        """The detector itself: the polluting load, in a scratch tree, is a finding."""
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tests").mkdir()
            (root / "tests/test_a.py").write_text(textwrap.dedent('''
                import importlib.util, sys
                from pathlib import Path
                ROOT = Path(__file__).resolve().parents[1]
                def test_copy():
                    spec = importlib.util.spec_from_file_location("cmux_next_route", ROOT / "scripts/ci/cmux_next_route.py")
                    router = importlib.util.module_from_spec(spec)
                    sys.modules[spec.name] = router
                    spec.loader.exec_module(router)
                def test_runpy():
                    import runpy
                    runpy.run_path(str(ROOT / "scripts/ci/cmux_next_route.py"))
                def test_temporary_copy(tmp):
                    spec = importlib.util.spec_from_file_location("cmux_next_route", tmp / "cmux_next_route.py")
            '''))
            (root / "tests/test_b.py").write_text("import cmux_next_route\n")
            findings, _, _ = two_object_loads(root)
        self.assertEqual(len(findings), 2, findings)
        self.assertTrue(all(f.startswith("tests/test_a.py:") and "cmux_next_route.py by path" in f for f in findings),
                        findings)

    def test_importing_the_sharing_test_files_in_either_order_leaves_one_module_per_file(self):
        _, importers, loaders = two_object_loads()
        # Every test file that imports a module some test also loads, or used to load, by path.
        shared = sorted({rel for stem in importers if stem in loaders for rel in importers[stem] | loaders[stem]}
                        | {"tests/test_ci_change_areas.py", "tests/test_cmux_next_route.py"})
        shared = [rel for rel in shared if rel.startswith("tests/test_") and (ROOT / rel).is_file()]
        self.assertIn("tests/test_cmux_next_route.py", shared)
        for order in (shared, list(reversed(shared))):
            with self.subTest(first=order[0]):
                done = subprocess.run([sys.executable, "-c", ONE_OBJECT_PER_FILE, str(ROOT), json.dumps(order)],
                                      cwd=ROOT, capture_output=True, text=True, timeout=600,
                                      env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
                self.assertEqual(done.returncode, 0, done.stderr[-4000:])
                self.assertEqual(json.loads(done.stdout.strip().splitlines()[-1]), {})

    @unittest.skipUnless(importlib.util.find_spec("pytest"), "needs pytest")
    def test_the_route_polluter_and_its_victim_pass_in_either_order(self):
        for order in ((POLLUTER, VICTIM), (VICTIM, POLLUTER)):
            with self.subTest(first=order[0]):
                done = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "-p", "no:randomly",
                                       *order], cwd=ROOT, capture_output=True, text=True, timeout=600)
                self.assertEqual(done.returncode, 0, done.stdout[-4000:] + done.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
