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

# Test helpers loaded by path in each test file on purpose and never registered: `python3 -I` puts no folder on
# sys.path (tests/git_fixture_env.py, tests/process_gone.py, tests/guard_child_env.py, and tests/git_history.py and
# tests/known_red.py, whose docstrings say "Load this module by path, never `import ...`").
PRIVATE_COPIES = {"git_fixture_env", "process_gone", "guard_child_env", "git_history", "known_red"}

# Path loads this check found when it was widened to scripts' imports and to files more than one test loads, left
# to convert (the nine that made a second object at runtime are converted). Shrink-only: an entry that is no longer
# a finding fails the check, so remove it with the conversion; never add one.
LEFT = "no test in the shared set patches it through the other object yet; convert it to `import` when touched"
ALLOWED: dict[tuple[str, str], str] = {
    ("scripts/cmux-next/tests/test_bench_startup_daemon_build.py", "bench_ab"): LEFT,
    ("scripts/cmux-next/tests/test_perf_completeness.py", "xbench"): LEFT,
    ("scripts/cmux-next/tests/test_tag_teardown.py", "tag_teardown"): LEFT,
    ("scripts/measure/tests/bench-ab.test.py", "bench_ab"): LEFT,
    ("scripts/measure/tests/cu-arena.test.py", "arena"): LEFT,
    ("tests/test_app_crate_licenses.py", "check_app_crate_licenses"): LEFT,
    ("tests/test_app_ffi_release_workflow.py", "next_macos_cascade"): LEFT,
    ("tests/test_app_ffi_release_workflow.py", "queue_janitor"): LEFT,
    ("tests/test_app_host_test_products.py", "app_host_test_products"): LEFT,
    ("tests/test_base_red_excuse.py", "cargo_test_verdict"): LEFT,
    ("tests/test_build_metrics.py", "build_metrics"): LEFT,
    ("tests/test_cargo_test_verdict.py", "cargo_test_verdict"): LEFT,
    ("tests/test_ci_owned_pool_rescue.py", "owned_pool_rescue"): LEFT,
    ("tests/test_ci_owned_warm_state.py", "owned_warm_state"): LEFT,
    ("tests/test_ci_package_lane_suite_skips.py", "test_reds"): LEFT,
    ("tests/test_ci_package_result_reuse.py", "select_package_tests"): LEFT,
    ("tests/test_ci_parallel_artifact_transport.py", "parallel_artifact_download"): LEFT,
    ("tests/test_ci_r2_cache_census.py", "r2_cache_census"): LEFT,
    ("tests/test_ci_rescue_actors.py", "classify_failures"): LEFT,
    ("tests/test_ci_rescue_actors.py", "next_macos_cascade"): LEFT,
    ("tests/test_ci_rescue_actors.py", "pr_runner_pool"): LEFT,
    ("tests/test_ci_runs_on_fallback.py", "nightly_next_launch_smoke"): LEFT,
    ("tests/test_ci_starved_labels.py", "starved_labels"): LEFT,
    ("tests/test_ci_test_touches_diff.py", "test_touches_diff"): LEFT,
    ("tests/test_ci_web_test_failure_census.py", "web_test_failure_census"): LEFT,
    ("tests/test_cloud_pair_proof.py", "cmux_next_cloud_pair_proof"): LEFT,
    ("tests/test_cmux_next_checks_workflow.py", "next_macos_cascade"): LEFT,
    ("tests/test_cmux_next_guardrails_observation.py", "test_cmux_next_guardrails"): LEFT,
    ("tests/test_cmux_next_guardrails_qos.py", "test_cmux_next_guardrails"): LEFT,
    ("tests/test_cmux_next_visual_gate.py", "nightly_next_canary_mode"): LEFT,
    ("tests/test_cmux_tui_tree_handoff.py", "cmux_tui_tree_handoff"): LEFT,
    ("tests/test_fresh_home_launch_smoke.py", "fresh_home_launch_smoke"): LEFT,
    ("tests/test_gh_app_token.py", "prune_nightly_release_assets"): LEFT,
    ("tests/test_gh_pages.py", "gh_pages"): LEFT,
    ("tests/test_hosted_queue_wait.py", "hosted_queue_wait"): LEFT,
    ("tests/test_lan_product_source.py", "node_product_cache"): LEFT,
    ("tests/test_lan_product_source.py", "peer_product_source"): LEFT,
    ("tests/test_nightly_next_artifact_check.py", "verify_appcast_item"): LEFT,
    ("tests/test_nightly_next_canary_mode.py", "nightly_next_canary_mode"): LEFT,
    ("tests/test_nightly_next_feed_rollback.py", "nightly_next_feed_rollback"): LEFT,
    ("tests/test_nightly_next_fix_forward.py", "nightly_next_fix_forward"): LEFT,
    ("tests/test_nightly_next_launch_smoke.py", "nightly_next_feed_rollback"): LEFT,
    ("tests/test_nightly_next_launch_smoke.py", "nightly_next_launch_smoke"): LEFT,
    ("tests/test_nightly_next_launch_smoke.py", "nightly_next_live_feed_check"): LEFT,
    ("tests/test_nightly_next_live_feed_check.py", "nightly_next_live_feed_check"): LEFT,
    ("tests/test_nightly_next_train.py", "nightly_build_runner"): LEFT,
    ("tests/test_nightly_next_train.py", "nightly_next_fix_forward"): LEFT,
    ("tests/test_nightly_next_train.py", "nightly_next_train"): LEFT,
    ("tests/test_nightly_release_notes.py", "nightly_release_notes"): LEFT,
    ("tests/test_nightly_signer_jobs.py", "verify_appcast_item"): LEFT,
    ("tests/test_node_product_cache.py", "node_product_cache"): LEFT,
    ("tests/test_node_product_cache.py", "peer_product_source"): LEFT,
    ("tests/test_prune_nightly_release_assets.py", "prune_nightly_release_assets"): LEFT,
    ("tests/test_publish_nightly_next_r2.py", "nightly_next_feed_rollback"): LEFT,
    ("tests/test_publish_nightly_next_r2.py", "nightly_next_ring"): LEFT,
    ("tests/test_risk_tier.py", "risk_tier"): LEFT,
    ("tests/test_test_reds.py", "test_reds"): LEFT,
    ("tests/test_triage_rules.py", "triage_rules"): LEFT,
    ("tests/test_verification_receipt.py", "verification_receipt"): LEFT,
}


def test_files(root: Path = ROOT) -> list[Path]:
    found = set(root.glob("tests/*.py")) | set(root.glob("scripts/**/tests/*.py")) | set(root.glob("scripts/tests/*.py"))
    return sorted(found)


BY_NAME = {"import_module", "__import__"}


def scan(path: Path) -> tuple[set[str], list[tuple[int, str, str]], list[tuple[int, str]]]:
    """(names the file imports, [(line, loader, stem)] of its path loads of a repository file, [(line, call)] of its
    imports by a name this scan cannot read). An import by name is `import x`, import_module("x") or __import__("x"),
    or a call of the file's own import helper (`def load(name, ...): ... importlib.import_module(name)`) as
    load("x"); any other import_module or __import__ call, or a helper call with a computed name, is unread."""
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

    def loads_its_first_argument(function: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
        if not function.args.args:
            return False
        first = function.args.args[0].arg
        return any(isinstance(n, ast.Call)
                   and (n.func.attr if isinstance(n.func, ast.Attribute) else getattr(n.func, "id", None)) in LOADERS
                   and first in {name for arg in n.args for name in names(arg)}
                   for n in ast.walk(function))

    # A file's own loader helper (`def load(name): spec_from_file_location(name, ...)`), called as load("stem").
    helpers = {node.name for node in ast.walk(tree)
               if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and loads_its_first_argument(node)}

    def called_name(call: ast.Call) -> str | None:
        return call.func.attr if isinstance(call.func, ast.Attribute) else getattr(call.func, "id", None)

    # A file's own import helper (`def load(name): ... importlib.import_module(name)`), called as load("stem"): an
    # import by name, like the import_module call inside it, which reads the helper's first argument.
    import_helpers: set[str] = set()
    forwarded: set[int] = set()
    for function in ast.walk(tree):
        if isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)) and function.args.args:
            first = function.args.args[0].arg
            for n in ast.walk(function):
                if isinstance(n, ast.Call) and called_name(n) in BY_NAME and n.args \
                        and isinstance(n.args[0], ast.Name) and n.args[0].id == first:
                    import_helpers.add(function.name)
                    forwarded.add(id(n))

    def literal(call: ast.Call) -> str | None:
        arg = call.args[0] if call.args else None
        if isinstance(arg, ast.Constant) and isinstance(arg.value, str) and arg.value:
            return arg.value.split(".")[0]
        return None
    unread: list[tuple[int, str]] = []

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
            if called in BY_NAME or called in import_helpers:
                name = literal(node)
                if name:
                    imported.add(name)
                elif id(node) not in forwarded:
                    unread.append((node.lineno, f"{called}()"))
                if called in BY_NAME:
                    continue
            if called in helpers and node.args and isinstance(node.args[0], ast.Constant) \
                    and isinstance(node.args[0].value, str) and IDENTIFIER.fullmatch(node.args[0].value):
                loads.append((node.lineno, f"{called}()", node.args[0].value))
                continue
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
    return imported, loads, unread


def two_object_loads(root: Path = ROOT) -> tuple[list[str], dict[str, set[str]], dict[str, set[str]]]:
    """Path loads of a repository module that something else also reaches: a test or a script imports it by name,
    or another test file loads it by path too. Each makes a second module object for one file. Returns the findings
    (less PRIVATE_COPIES), plus who among the tests imports and who loads each module."""
    # Only a stem that names one repository file: run.py, publish.py and driver.py each name several, and which one
    # a by-name import reaches depends on the importer's folder.
    stems = collections.Counter(p.stem for p in [*root.glob("scripts/**/*.py"), *root.glob("tests/*.py")])
    modules = {stem for stem, count in stems.items() if count == 1}
    importers: dict[str, set[str]] = collections.defaultdict(set)
    loaders: dict[str, list[tuple[str, int, str]]] = collections.defaultdict(list)
    unread: list[str] = []
    tests = test_files(root)
    for path in tests:
        rel = path.relative_to(root).as_posix()
        imported, loads, unknown = scan(path)
        unread.extend(f"{rel}:{line}: {called} imports a module by a name this check cannot read, so it cannot tell "
                      "which files share it. Pass a literal name (to import_module or the file's own load helper)."
                      for line, called in unknown)
        for name in imported:
            importers[name].add(rel)
        for line, called, stem in loads:
            loaders[stem].append((rel, line, called))
    # Scripts import their siblings by name, and a test that imports such a script imports them with it.
    script_importers: dict[str, set[str]] = collections.defaultdict(set)
    for path in sorted(set(root.glob("scripts/**/*.py")) - set(tests)):
        try:
            imported, _, _ = scan(path)
        except (SyntaxError, UnicodeDecodeError):
            continue
        for name in imported:
            script_importers[name].add(path.relative_to(root).as_posix())
    findings = list(unread)
    for stem, sites in sorted(loaders.items()):
        if stem not in modules or stem in PRIVATE_COPIES:
            continue
        loading_files = {rel for rel, _, _ in sites}
        for rel, line, called in sites:
            others = sorted((importers.get(stem, set()) | script_importers.get(stem, set())) - {rel})
            also_loaded = sorted(loading_files - {rel})
            if others:
                why = f"{', '.join(others[:3])} import it by name"
            elif also_loaded:
                why = f"{', '.join(also_loaded[:3])} load it by path too"
            else:
                continue
            findings.append(f"{rel}:{line}: {called} loads {stem}.py by path, but {why}: two module objects for one "
                            f"file. Put its folder on sys.path and `import {stem}` instead.")
    return findings, importers, {stem: {rel for rel, _, _ in sites} for stem, sites in loaders.items()}


def sharing_test_files(root: Path = ROOT) -> list[str]:
    """Every test file that imports a repository module two or more test files import by name, plus every file that
    loads by path a module some test imports by name. Found from the imports, not from the path loads left, so a file
    whose path load became an import stays covered."""
    _, importers, loaders = two_object_loads(root)
    modules = {p.stem for p in [*root.glob("scripts/**/*.py"), *root.glob("tests/*.py")]}
    shared = {rel for stem, files in importers.items() if stem in modules and len(files) >= 2 for rel in files}
    shared |= {rel for stem in importers if stem in loaders for rel in importers[stem] | loaders[stem]}
    return sorted(rel for rel in shared if (root / rel).is_file())


# Run in a fresh interpreter: imports each test module in the given order, then reports any repository file that
# sys.modules holds a module object of (what `import name` returns) while a test module's globals hold another.
# A test file this host cannot import (one that loads a Mac library) is listed apart and skipped.
# Private copies nothing registers (tests/git_fixture_env.py, loaded by path in each test file by design because
# `python3 -I` puts no folder on sys.path) are no second object of an importable module, so they do not count.
ONE_OBJECT_PER_FILE = textwrap.dedent('''
    import importlib, json, os, sys, types
    root, order = sys.argv[1], json.loads(sys.argv[2])
    for folder in {os.path.dirname(os.path.join(root, rel)) for rel in order}:
        sys.path.insert(0, folder)
    loaded, unimportable = [], {}
    for rel in order:
        try:
            loaded.append(importlib.import_module(os.path.basename(rel)[:-3]))
        except Exception as error:  # a test that needs a Mac library (bench_launch's libproc) cannot import here
            unimportable[rel] = type(error).__name__ + ": " + str(error)[:200]
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
    print(json.dumps({"two": two, "unimportable": unimportable}))
''')

# Run in a fresh interpreter: imports each test module in the given order and reports, per file, every sys.modules
# entry named after a repository module (a stem from argv[3]) that its import added or replaced with a stub (None, a
# SimpleNamespace, a bare ModuleType with no spec or file). A stub left there is what the next test's `import name`
# gets instead of the real module.
STUBS_LEFT = textwrap.dedent('''
    import importlib, json, os, sys, types
    root, order, stems = sys.argv[1], json.loads(sys.argv[2]), set(json.loads(sys.argv[3]))
    def real(module):
        return isinstance(module, types.ModuleType) and (
            getattr(module, "__spec__", None) is not None or getattr(module, "__file__", None))
    left, unimportable = {}, {}
    for rel in order:
        folder = os.path.dirname(os.path.join(root, rel))
        if folder not in sys.path:
            sys.path.insert(0, folder)
        before = dict(sys.modules)
        try:
            importlib.import_module(os.path.basename(rel)[:-3])
        except BaseException as error:  # a test that needs a Mac library cannot import here
            unimportable[rel] = type(error).__name__ + ": " + str(error)[:200]
        names = sorted(name for name, module in sys.modules.items()
                       if name in stems and before.get(name) is not module and not real(module))
        if names:
            left[rel] = names
    print(json.dumps({"left": left, "unimportable": unimportable}))
''')

# A test file that stubs a module others import for real must take its stub back out (#41653 review).
STUB_POLLUTER, STUB_VICTIM = "test_perf_completeness", "test_teardown_clone_cleanup"
STUB_SUITES = ROOT / "scripts/cmux-next/tests"


def stubbing_test_files(root: Path = ROOT) -> list[str]:
    """Every test file whose source writes to sys.modules: the ones that can leave a stub there."""
    found = set(test_files(root)) | set(root.glob("scripts/**/test_*.py"))
    return sorted(p.relative_to(root).as_posix() for p in found if "sys.modules" in p.read_text(encoding="utf-8"))


POLLUTER = "tests/test_ci_change_areas.py::test_cmux_next_does_not_run_full_suite_for_unrelated_packages"
VICTIM = "tests/test_cmux_next_route.py::LinuxLaneTests::test_a_linux_guard_test_a_mac_tier_reads_keeps_its_tier"


class ScriptModuleLoadTests(unittest.TestCase):
    def test_no_test_loads_by_path_a_file_another_test_imports_by_name(self):
        findings, _, _ = two_object_loads()
        unread = [finding for finding in findings if " loads " not in finding]  # never allowed
        found = {(finding.split(":")[0], finding.split(" loads ", 1)[1].split(".py by path")[0]): finding
                 for finding in findings if " loads " in finding}
        new = sorted([*unread, *(finding for key, finding in found.items() if key not in ALLOWED)])
        self.assertEqual(new, [], "\n" + "\n".join(new))
        converted = sorted(f"{rel} ({stem})" for rel, stem in ALLOWED if (rel, stem) not in found)
        self.assertEqual(converted, [], "no longer path-loaded: remove from ALLOWED (shrink-only)\n" + "\n".join(converted))

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
            (root / "scripts/ci").mkdir(parents=True)
            for name in ("cmux_next_route", "ring", "placement"):
                (root / f"scripts/ci/{name}.py").write_text("")
            # A script imports placement by name; a test loads it through its own helper.
            (root / "scripts/ci/runner.py").write_text("import placement\n")
            (root / "tests/test_c.py").write_text(textwrap.dedent('''
                import importlib.util
                from pathlib import Path
                SCRIPTS = Path(__file__).resolve().parents[1] / "scripts/ci"
                def load(name):
                    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    return module
                placement = load("placement")
                ring = importlib.util.spec_from_file_location("ring", SCRIPTS / "ring.py")
            '''))
            # Two test files load ring.py by path, and nothing imports it by name.
            (root / "tests/test_d.py").write_text(
                "import importlib.util\nfrom pathlib import Path\nROOT = Path(__file__).resolve().parents[1]\n"
                "ring = importlib.util.spec_from_file_location(\"ring\", ROOT / \"scripts/ci/ring.py\")\n")
            findings, _, _ = two_object_loads(root)
        route = [f for f in findings if "cmux_next_route.py by path" in f]
        self.assertEqual(len(route), 2, findings)
        self.assertTrue(all(f.startswith("tests/test_a.py:") for f in route), findings)
        self.assertEqual(len([f for f in findings if "load() loads placement.py" in f and "runner.py" in f]), 1, findings)
        self.assertEqual(sorted(f.split(":")[0] for f in findings if "ring.py by path" in f),
                         ["tests/test_c.py", "tests/test_d.py"], findings)
        self.assertEqual(len(findings), 5, findings)

    def test_importing_the_sharing_test_files_in_either_order_leaves_one_module_per_file(self):
        shared = sharing_test_files()
        # The files whose path loads became imports, so a path load put back in any of them is caught here too.
        required = ("tests/test_cmux_next_route.py", "tests/test_ci_change_areas.py",
                    "tests/test_ci_guard_check_isolation.py", "scripts/cmux-next/tests/test_build_names.py")
        for rel in required:
            self.assertIn(rel, shared)
        for order in (shared, list(reversed(shared))):
            with self.subTest(first=order[0]):
                done = subprocess.run([sys.executable, "-c", ONE_OBJECT_PER_FILE, str(ROOT), json.dumps(order)],
                                      cwd=ROOT, capture_output=True, text=True, timeout=600,
                                      env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
                self.assertEqual(done.returncode, 0, done.stderr[-4000:])
                result = json.loads(done.stdout.strip().splitlines()[-1])
                self.assertEqual(result["two"], {})
                # Files this host cannot import are skipped, never the ones the check is about, and never most.
                for rel in required:
                    self.assertNotIn(rel, result["unimportable"])
                self.assertLess(len(result["unimportable"]), len(order) // 10, result["unimportable"])

    def test_files_importing_through_a_load_helper_are_in_the_sharing_set(self):
        """#41653 review: `def load(name): ... return importlib.import_module(name)` called as load("procs") is an
        import by name, so the files that do it share their modules; an import by a name scan() cannot read fails."""
        shared = sharing_test_files()
        for rel in ("tests/test_ci_route_refusal_detail.py", "tests/test_gh_call_log.py",
                    "scripts/cmux-next/tests/test_teardown_clone_cleanup.py"):
            self.assertIn(rel, shared)
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tests").mkdir()
            (root / "scripts/ci").mkdir(parents=True)
            (root / "scripts/ci/ring.py").write_text("")
            (root / "tests/test_a.py").write_text(textwrap.dedent('''
                import importlib, sys
                def load(name, path=None):
                    sys.path.insert(0, "scripts/ci")
                    return importlib.import_module(name)
                ring = load("ring")
            '''))
            (root / "tests/test_b.py").write_text("import ring\n")
            (root / "tests/test_c.py").write_text(textwrap.dedent('''
                import importlib
                NAME = "ri" + "ng"
                ring = importlib.import_module(NAME)
                def go(stem):
                    return __import__(stem.upper())
            '''))
            imported, _, _ = scan(root / "tests/test_a.py")
            self.assertIn("ring", imported)
            self.assertIn("tests/test_a.py", sharing_test_files(root))
            findings, _, _ = two_object_loads(root)
        unread = sorted(f for f in findings if "cannot read" in f)
        self.assertEqual([f.split(":")[:2] for f in unread], [["tests/test_c.py", "4"], ["tests/test_c.py", "6"]], findings)

    def test_no_test_file_leaves_a_stub_module_behind(self):
        """#41653 review: test_perf_completeness.py put an empty `procs` in sys.modules at import and left it, so
        test_teardown_clone_cleanup.py's `import procs` got the stub when it ran later in one process."""
        order = stubbing_test_files()
        for rel in ("scripts/cmux-next/tests/test_perf_completeness.py", "scripts/tests/test_readiness_soak.py",
                    "scripts/cmux-next/test_split_scale_background.py"):
            self.assertIn(rel, order)
        stems = sorted({p.stem for p in [*ROOT.glob("scripts/**/*.py"), *ROOT.glob("tests/*.py")]})
        done = subprocess.run([sys.executable, "-c", STUBS_LEFT, str(ROOT), json.dumps(order), json.dumps(stems)], cwd=ROOT,
                              capture_output=True, text=True, timeout=600,
                              env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(done.returncode, 0, done.stderr[-4000:])
        result = json.loads(done.stdout.strip().splitlines()[-1])
        self.assertEqual(result["left"], {}, json.dumps(result, indent=1))
        self.assertNotIn("scripts/cmux-next/tests/test_perf_completeness.py", result["unimportable"])
        self.assertLess(len(result["unimportable"]), len(order) // 4, result["unimportable"])

    def test_the_procs_stub_polluter_and_its_victim_pass_in_either_order(self):
        driver = ("import sys, unittest\nsys.path.insert(0, sys.argv[1])\n"
                  "suite = unittest.defaultTestLoader.loadTestsFromNames(sys.argv[2:])\n"
                  "sys.exit(not unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful())\n")
        for order in ((STUB_POLLUTER, STUB_VICTIM), (STUB_VICTIM, STUB_POLLUTER)):
            with self.subTest(first=order[0]):
                done = subprocess.run([sys.executable, "-c", driver, str(STUB_SUITES), *order], cwd=ROOT,
                                      capture_output=True, text=True, timeout=600)
                self.assertEqual(done.returncode, 0, done.stdout[-2000:] + done.stderr[-4000:])

    @unittest.skipUnless(importlib.util.find_spec("pytest"), "needs pytest")
    def test_the_route_polluter_and_its_victim_pass_in_either_order(self):
        for order in ((POLLUTER, VICTIM), (VICTIM, POLLUTER)):
            with self.subTest(first=order[0]):
                done = subprocess.run([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "-p", "no:randomly",
                                       *order], cwd=ROOT, capture_output=True, text=True, timeout=600)
                self.assertEqual(done.returncode, 0, done.stdout[-4000:] + done.stderr[-2000:])


if __name__ == "__main__":
    unittest.main()
