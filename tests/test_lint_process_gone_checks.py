#!/usr/bin/env python3
"""Lint: a test waits for a killed process to exit before asserting that it is gone.

`os.kill(pid, 0)` (or `os.killpg(pgid, 0)`) inside `assertRaises(ProcessLookupError)`, checked once right after a
kill, races the kernel and the reaper: on a busy machine the killed process is still in the process table for a
moment, and signal 0 still reaches a zombie. tests/process_gone.py's died(pid) and group_died(pgid) wait for the
exit with a deadline. This scan flags the one-shot check, outside a loop, in every Python file of the repository,
unless ALLOWED names the test with the reason its check cannot race.

Runs under plain python3: `python3 tests/test_lint_process_gone_checks.py`.
"""

from __future__ import annotations

import ast
import importlib.util
import os
import signal
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("process_gone", ROOT / "tests" / "process_gone.py")
assert SPEC is not None and SPEC.loader is not None
process_gone = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(process_gone)

# "path::test function": why its immediate check cannot race (the test reaped the process itself, say).
ALLOWED: dict[str, str] = {}
SKIP_DIRS = {".git", "node_modules", "vendor", "ghostty", "ghostty-next", "homebrew-cmux", "build", ".build",
             "target", "dist", "DerivedData", ".venv", "zig-cache", ".zig-cache", "zig-out"}


def _signal_zero(node: ast.AST) -> bool:
    """True for os.kill(X, 0) or os.killpg(X, 0)."""
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr in ("kill", "killpg") and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "os" and len(node.args) == 2
            and isinstance(node.args[1], ast.Constant) and node.args[1].value == 0)


def _expects_lookup_error(node: ast.AST) -> bool:
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "assertRaises" and bool(node.args)
            and isinstance(node.args[0], ast.Name) and node.args[0].id == "ProcessLookupError")


def _unlooped_signal_zero(stmts: list[ast.stmt]) -> bool:
    """True when STMTS send signal 0 outside any for or while loop (a loop is a bounded retry)."""
    todo: list[ast.AST] = list(stmts)
    while todo:
        node = todo.pop()
        if isinstance(node, (ast.For, ast.AsyncFor, ast.While)):
            continue
        if _signal_zero(node):
            return True
        todo.extend(ast.iter_child_nodes(node))
    return False


def _callable_form(node: ast.AST) -> bool:
    """self.assertRaises(ProcessLookupError, os.kill, pid, 0)."""
    return (_expects_lookup_error(node) and len(node.args) == 4 and isinstance(node.args[1], ast.Attribute)
            and node.args[1].attr in ("kill", "killpg") and isinstance(node.args[3], ast.Constant)
            and node.args[3].value == 0)


def scan_source(source: str, name: str) -> list[tuple[str, int]]:
    """(test function, line) for every one-shot "it is gone" check in SOURCE."""
    if "ProcessLookupError" not in source:
        return []
    try:
        tree = ast.parse(source, name)
    except SyntaxError:
        return []
    hits: list[tuple[str, int]] = []

    def visit(node: ast.AST, owner: str | None) -> None:
        for child in ast.iter_child_nodes(node):
            func = owner
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) and owner is None:
                func = child.name
            if isinstance(child, (ast.With, ast.AsyncWith)):
                if (any(_expects_lookup_error(item.context_expr) for item in child.items)
                        and _unlooped_signal_zero(child.body)):
                    hits.append((func or "<module>", child.lineno))
            elif _callable_form(child):
                hits.append((func or "<module>", child.lineno))
            visit(child, func)

    visit(tree, None)
    return hits


def scan_tree(root: Path = ROOT) -> dict[str, list[int]]:
    found: dict[str, list[int]] = {}
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for file in sorted(files):
            if not file.endswith(".py"):
                continue
            path = Path(directory) / file
            source = path.read_text(encoding="utf-8", errors="replace")
            rel = path.relative_to(root).as_posix()
            for func, line in scan_source(source, rel):
                found.setdefault(f"{rel}::{func}", []).append(line)
    return found


class TheTreeHasNoOneShotGoneCheck(unittest.TestCase):
    def test_no_test_checks_a_killed_process_is_gone_without_waiting(self) -> None:
        found = scan_tree()
        new = sorted(f"{key} (line {', '.join(map(str, lines))})" for key, lines in found.items()
                     if key not in ALLOWED)
        self.assertEqual(new, [], "a killed process is not gone yet: assert process_gone.died(pid) or "
                                  "group_died(pgid) from tests/process_gone.py, or list the test in ALLOWED in "
                                  "tests/test_lint_process_gone_checks.py with why it cannot race")

    def test_every_allowed_entry_is_live_and_explained(self) -> None:
        found = scan_tree()
        for key, why in ALLOWED.items():
            with self.subTest(key=key):
                self.assertIn(key, found, "stale: no one-shot check is left there")
                self.assertGreater(len(why), 10)


class TheScannerFindsTheForms(unittest.TestCase):
    def hits(self, source: str) -> list[str]:
        return [func for func, _ in scan_source(textwrap.dedent(source), "fixture.py")]

    def test_a_one_shot_check_fixture_is_red(self) -> None:
        source = """
            import os, time
            class T:
                def test_a(self):
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
                def test_b(self):
                    time.sleep(0.5)
                    with self.assertRaises(ProcessLookupError, msg="survived"):
                        os.killpg(pgid, 0)
                def test_c(self):
                    self.assertRaises(ProcessLookupError, os.kill, pid, 0)
        """
        self.assertEqual(self.hits(source), ["test_a", "test_b", "test_c"])
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "test_fixture.py").write_text(textwrap.dedent(source), encoding="utf-8")
            self.assertEqual(sorted(scan_tree(Path(directory))),
                             ["test_fixture.py::test_a", "test_fixture.py::test_b", "test_fixture.py::test_c"])

    def test_a_bounded_retry_a_real_signal_and_a_wait_are_not_flagged(self) -> None:
        source = """
            import os, time
            class T:
                def test_a(self):
                    with self.assertRaises(ProcessLookupError):
                        for _ in range(50):
                            os.kill(pid, 0)
                            time.sleep(0.1)
                def test_b(self):
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 9)
                def test_c(self):
                    self.assertTrue(process_gone.died(pid))
        """
        self.assertEqual(self.hits(source), [])


class TheHelpers(unittest.TestCase):
    def test_a_killed_child_not_reaped_yet_counts_as_died_and_a_live_one_does_not(self) -> None:
        # The window a one-shot check lands in under load: killed, but still in the process table.
        proc = subprocess.Popen(["sleep", "60"])
        try:
            self.assertFalse(process_gone.died(proc.pid, within=0.3))
            os.kill(proc.pid, signal.SIGKILL)
            self.assertTrue(process_gone.died(proc.pid))  # a zombie until the wait below reaps it
            self.assertIsNone(os.kill(proc.pid, 0))  # where the one-shot check failed: signal 0 still reaches it
        finally:
            proc.kill()
            proc.wait()
        self.assertTrue(process_gone.died(proc.pid))

    def test_a_group_is_gone_once_its_members_are_reaped(self) -> None:
        proc = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            self.assertFalse(process_gone.group_died(proc.pid, within=0.3))
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            self.assertTrue(process_gone.group_died(proc.pid))
        finally:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    unittest.main()
