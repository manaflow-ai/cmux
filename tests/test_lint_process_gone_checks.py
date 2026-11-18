#!/usr/bin/env python3
"""Lint: a test never probes a process with signal 0; it uses tests/process_gone.py.

`os.kill(pid, 0)` or `os.killpg(pgid, 0)` races the kernel and the reaper: on a busy machine a killed process is
still in the process table for a moment, and signal 0 still reaches a zombie, so "it is gone" fails and "it still
runs" passes on a dead one. A loop around the probe is no proof of a wait (one with a single pass, or no sleep, checks
once). So every raw probe in a test file (test_*.py, *_test.py, *-test.py, *.test.py, or anything under a tests/
folder) is flagged, in any form: the test uses process_gone.died(pid), running(pid) or group_died(pgid), and ALLOWED,
with a reason, is the only escape. A file that cannot load the helper carries a copy of its functions (COPIES), and the
copy must match the helper.

Runs under plain python3: `python3 -I tests/test_lint_process_gone_checks.py`.
"""

from __future__ import annotations

import ast
import builtins
import importlib.util
import os
import signal
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("process_gone", ROOT / "tests" / "process_gone.py")
assert SPEC is not None and SPEC.loader is not None
process_gone = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(process_gone)
died, running, group_died = process_gone.died, process_gone.running, process_gone.group_died

# "path::function": why its raw signal-0 probe is right as it is.
ALLOWED: dict = {}
# A file that cannot load tests/process_gone.py (it runs from a scratch copy) carries a copy of these helper
# functions instead. Their probes are the helper's, and each must match the helper's own, so a change to one fails here
# until the other follows.
COPIES = {
    "cmux-tui/crates/acpmux/tests/fake_claude_auto.py": ("_state", "_exited"),
}
HELPER = "tests/process_gone.py"
THIS = "tests/test_lint_process_gone_checks.py"


def _signal_zero(node):
    """True for os.kill(X, 0) or os.killpg(X, 0)."""
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ("kill", "killpg")
            and isinstance(node.func.value, ast.Name) and node.func.value.id == "os" and len(node.args) == 2
            and isinstance(node.args[1], ast.Constant) and node.args[1].value == 0)


def _signal_zero_by_reference(node):
    """True for assertRaises(..., os.kill, X, 0): signal 0 sent through a callable."""
    return (isinstance(node, ast.Call) and len(node.args) >= 4 and isinstance(node.args[1], ast.Attribute)
            and node.args[1].attr in ("kill", "killpg") and isinstance(node.args[1].value, ast.Name)
            and node.args[1].value.id == "os" and isinstance(node.args[3], ast.Constant) and node.args[3].value == 0)


def find_source(source, name="<test>"):
    """(function, line) for every raw signal-0 probe in SOURCE: os.kill(X, 0) or os.killpg(X, 0), in any form, in or
    out of a loop. A loop is not proof of a wait (one with one pass, or no sleep, checks once), so every probe is
    flagged; the test uses process_gone's died(), running() or group_died() instead."""
    if "kill" not in source:
        return []
    try:
        tree = ast.parse(source, name)
    except SyntaxError:
        return []
    hits = []

    def visit(node, owner):
        for child in ast.iter_child_nodes(node):
            func = owner
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) and owner is None:
                func = child.name
            if _signal_zero(child) or _signal_zero_by_reference(child):
                hits.append((func or "<module>", child.lineno))
            visit(child, func)

    visit(tree, None)
    return hits


SKIP_DIRS = {".git", "node_modules", "vendor", "ghostty", "ghostty-next", "homebrew-cmux", "build", ".build",
             "target", "dist", "DerivedData", ".venv", "zig-cache", ".zig-cache", "zig-out"}


def python_files(root):
    found = []
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        found += [(Path(directory) / f).relative_to(root).as_posix() for f in files if f.endswith(".py")]
    return sorted(found)


def is_test_file(rel):
    name = rel.rsplit("/", 1)[-1]
    return (name.startswith("test_") or name.endswith(("_test.py", "-test.py", ".test.py"))
            or "/tests/" in "/" + rel)


def scan(root=ROOT):
    found = {}
    for rel in python_files(root):
        if rel in (HELPER, THIS) or not is_test_file(rel):
            continue  # the helper is where signal 0 is read right; this file holds the forms on purpose
        try:
            source = (root / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:  # a sparse checkout leaves tracked files out
            continue
        for func, line in find_source(source, rel):
            if func in COPIES.get(rel, ()):
                continue  # a copy of the helper, held to it by copy_drift()
            found.setdefault("%s::%s" % (rel, func), []).append(line)
    return found


def _functions(source, name):
    """{function name: its AST without the docstring} for SOURCE's top-level functions."""
    out = {}
    for node in ast.parse(source, name).body:
        if isinstance(node, ast.FunctionDef):
            body = node.body
            if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant):
                body = body[1:]
            out[node.name] = ast.dump(ast.Module(body=body, type_ignores=[]))
    return out


def copy_drift(root=ROOT, copies=None):
    """["path::function"] for each copied helper function that is missing from its copy or differs from the helper."""
    helper = _functions((root / HELPER).read_text(encoding="utf-8"), HELPER)
    drift = []
    for rel, names in sorted((COPIES if copies is None else copies).items()):
        copy = _functions((root / rel).read_text(encoding="utf-8"), rel)
        drift += ["%s::%s" % (rel, n) for n in names if n not in helper or copy.get(n) != helper[n]]
    return drift


class NoRawSignalZeroProbe(unittest.TestCase):
    def test_every_copy_of_the_helper_matches_it(self):
        self.assertEqual(copy_drift(), [], "a copy of tests/process_gone.py differs from it: change both together")

    def test_no_test_probes_a_process_with_signal_zero(self):
        new = sorted("%s (line %s)" % (k, ", ".join(map(str, v))) for k, v in scan().items() if k not in ALLOWED)
        self.assertEqual(new, [], "a killed process is not gone yet: use process_gone.died(pid), running(pid) or "
                                  "group_died(pgid), or list the test in ALLOWED in tests/test_lint_process_gone_checks.py "
                                  "with why its probe is right")

    def test_no_allowed_entry_is_stale_or_unexplained(self):
        found = scan()
        for key, why in ALLOWED.items():
            with self.subTest(key=key):
                self.assertIn(key, found, "stale: no signal-0 probe left")
                self.assertGreater(len(why), 10)


class TheScannerFindsTheForms(unittest.TestCase):
    def hits(self, src):
        return [f for f, _ in find_source(src)]

    def test_a_tree_with_a_probe_in_a_test_file_is_red(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "tests").mkdir()
            (Path(d) / "tests" / "test_x.py").write_text("import os\ndef test_a():\n    os.kill(1, 0)\n")
            (Path(d) / "tool.py").write_text("import os\ndef alive(p):\n    os.kill(p, 0)\n")  # not a test
            self.assertEqual(sorted(scan(Path(d))), ["tests/test_x.py::test_a"])

    def test_a_copy_that_drifts_from_the_helper_is_red(self):
        import tempfile
        helper = "import os\ndef _exited(pid):\n    \"\"\"doc\"\"\"\n    os.kill(pid, 0)\n    return True\n"
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "tests").mkdir()
            (Path(d) / HELPER).write_text(helper)
            (Path(d) / "tests" / "fake.py").write_text(helper.replace('"""doc"""', '"""other doc"""'))
            copies = {"tests/fake.py": ("_exited",)}
            self.assertEqual(copy_drift(Path(d), copies), [])  # the same code under another docstring
            (Path(d) / HELPER).write_text(helper.replace("return True", "return False"))
            self.assertEqual(copy_drift(Path(d), copies), ["tests/fake.py::_exited"])  # the helper changed alone
            (Path(d) / "tests" / "fake.py").write_text("import os\n")
            self.assertEqual(copy_drift(Path(d), copies), ["tests/fake.py::_exited"])  # the copy was dropped

    def test_every_signal_zero_probe_is_found(self):
        src = ("import os, time\nclass T:\n"
               "    def test_a(self):\n        with self.assertRaises(ProcessLookupError):\n            os.kill(p, 0)\n"
               "    def test_b(self):\n        time.sleep(0.5)\n"
               "        with self.assertRaises(ProcessLookupError, msg='x'):\n            os.killpg(g, 0)\n"
               "    def test_c(self):\n        self.assertRaises(ProcessLookupError, os.kill, p, 0)\n"
               "    def test_d(self):\n        os.kill(p, 0)  # 'it still runs'\n"
               "def alive(p):\n    try:\n        os.kill(p, 0)\n    except OSError:\n        return False\n"
               "    return True\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b", "test_c", "test_d", "alive"])

    def test_a_probe_inside_a_loop_is_found_too(self):
        # review of #4363 (F1): a loop with one pass, or none that sleeps, still checks once
        src = ("import os, time\nclass T:\n"
               "    def test_a(self):\n        with self.assertRaises(ProcessLookupError):\n"
               "            for _ in range(1):\n                os.kill(p, 0)\n"
               "    def test_b(self):\n        for _ in range(50):\n            try:\n                os.kill(p, 0)\n"
               "            except ProcessLookupError:\n                break\n            time.sleep(0.1)\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b"])

    def test_a_real_signal_and_the_helpers_are_not_flagged(self):
        src = ("import os, signal\nclass T:\n"
               "    def test_a(self):\n        os.kill(p, 9)\n        os.killpg(g, signal.SIGKILL)\n"
               "        self.assertTrue(died(p))\n        self.assertTrue(running(q))\n")
        self.assertEqual(self.hits(src), [])


def zombie_child():
    """A SIGKILLed child of this process that nothing has reaped: a zombie until proc.wait()."""
    proc = subprocess.Popen(["sleep", "60"])
    os.kill(proc.pid, signal.SIGKILL)
    return proc


def zombie_not_ours():
    """(holder, pid): a zombie whose parent, HOLDER, never reaps it; not this process's child."""
    holder = subprocess.Popen([sys.executable, "-c",
                               "import os, signal, sys, time\npid = os.fork()\n"
                               "if pid == 0:\n    time.sleep(60)\n    os._exit(0)\n"
                               "os.kill(pid, signal.SIGKILL)\nprint(pid, flush=True)\ntime.sleep(60)\n"],
                              stdout=subprocess.PIPE, text=True)
    return holder, int(holder.stdout.readline())



class AsOnMacOS:
    """No pidfd and no /proc, as on macOS: died() has to tell a zombie by other means."""

    def __enter__(self):
        real_open = builtins.open

        def no_proc(path, *args, **kwargs):
            if str(path).startswith("/proc/"):
                raise FileNotFoundError(2, "No such file or directory", str(path))
            return real_open(path, *args, **kwargs)
        real_isdir = os.path.isdir
        self.patches = [mock.patch.object(process_gone.os, "pidfd_open", side_effect=AttributeError, create=True),
                        mock.patch("builtins.open", no_proc),
                        mock.patch.object(process_gone.os.path, "isdir",
                                          lambda p: False if str(p).startswith("/proc") else real_isdir(p))]
        for p in self.patches:
            p.start()
        return self

    def __exit__(self, *exc):
        for p in reversed(self.patches):
            p.stop()


class TheHelpers(unittest.TestCase):
    def test_a_killed_child_not_reaped_yet_counts_as_died_and_a_live_one_does_not(self):
        live = subprocess.Popen(["sleep", "60"])
        proc = zombie_child()
        try:
            self.assertFalse(died(live.pid, within=0.3))
            self.assertTrue(running(live.pid))
            self.assertTrue(died(proc.pid))  # a zombie until the wait below reaps it
            self.assertFalse(running(proc.pid))
            self.assertIsNone(os.kill(proc.pid, 0))  # where the raw probe was wrong: signal 0 still reaches it
        finally:
            for p in (live, proc):
                p.kill()
                p.wait()
        self.assertTrue(died(proc.pid))  # reaped: gone

    def test_without_a_pidfd_or_proc_a_zombie_still_counts_as_died(self):
        # review of #4363 (F2): on macOS died() polled signal 0, which a zombie answers, for the whole 10 s
        live = subprocess.Popen(["sleep", "60"])
        proc = zombie_child()
        holder, orphan = zombie_not_ours()
        try:
            with AsOnMacOS():
                began = time.monotonic()
                self.assertTrue(died(proc.pid, within=5), "our own unreaped child")
                self.assertTrue(died(orphan, within=5), "another process's unreaped child")
                self.assertLess(time.monotonic() - began, 4)  # found, not timed out
                self.assertFalse(died(live.pid, within=0.3))
                self.assertTrue(running(live.pid))
                self.assertFalse(running(orphan))
        finally:
            for p in (live, proc, holder):
                p.kill()
                p.wait()
            holder.stdout.close()

    def test_a_group_is_gone_once_its_members_are_reaped(self):
        proc = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            self.assertFalse(group_died(proc.pid, within=0.3))
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            self.assertTrue(group_died(proc.pid))
        finally:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    unittest.main()
