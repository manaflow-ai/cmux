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
import re
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
ALLOWED: dict = {
    "scripts/perf-bench/tests/test_session_real.py::test_the_agents_command_ends_the_cli_types_into_the_shell_and_gives_exit_0":
        "no probe: it saves os.kill in a tuple to put it back after replacing it with a recorder, and never calls it",
    "tests/test_cmux_next_prepush_gate.py::test_a_hook_stopped_by_a_signal_during_a_check_never_says_it_passed":
        "no probe: os.kill(pid, signum) sends the loop's signal.SIGTERM or signal.SIGINT to a running hook",
    "tests/test_verify_cmux_tui_hosted.py::signal_case":
        "no probe: os.kill/os.killpg(pid, signum) send the case's signal, which every caller names as signal.SIGINT, "
        "signal.SIGTERM or signal.SIGHUP",
}
# A file that cannot load tests/process_gone.py (it runs from a scratch copy) carries a copy of these helper
# functions instead. Their probes are the helper's, and each must match the helper's own, so a change to one fails here
# until the other follows.
COPIES = {
    "cmux-tui/crates/acpmux/tests/fake_claude_auto.py": ("_state", "_exited"),
}
HELPER = "tests/process_gone.py"
THIS = "tests/test_lint_process_gone_checks.py"


KILLS = {"os.kill", "os.killpg", "posix.kill", "posix.killpg"}
SIGNAL_KEYWORDS = ("signal", "sig", "signum")


def _bindings(tree):
    """{name: what it is bound to} for SOURCE's imports and plain assignments, in any scope: a module ("os",
    "posix", "signal") or one of its functions or constants ("os.kill", "signal.SIGKILL"). A name bound to
    anything else is left out."""
    names = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name in ("os", "posix", "signal"):
                    names[a.asname or a.name] = a.name
        elif isinstance(node, ast.ImportFrom) and node.module in ("os", "posix", "signal") and not node.level:
            for a in node.names:
                names[a.asname or a.name] = "%s.%s" % (node.module, a.name)
    assigns = [n for n in ast.walk(tree) if isinstance(n, (ast.Assign, ast.AnnAssign, ast.NamedExpr))]
    for _ in range(len(assigns) + 1):  # k = os.kill; j = k: until nothing new resolves
        grew = False
        for node in assigns:
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            dotted = _dotted(node.value, names)
            for t in targets:
                if isinstance(t, ast.Name) and dotted and names.get(t.id) != dotted:
                    names[t.id] = dotted
                    grew = True
        if not grew:
            break
    return names


def _dotted(node, names):
    """What NODE names through NAMES ("os.kill", "signal.SIGKILL", "os"), or None."""
    if isinstance(node, ast.Name):
        return names.get(node.id)
    if isinstance(node, ast.Attribute):
        base = _dotted(node.value, names)
        return "%s.%s" % (base, node.attr) if base else None
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "getattr"
            and len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and isinstance(node.args[1].value, str)):
        base = _dotted(node.args[0], names)  # getattr(os, "kill")
        return "%s.%s" % (base, node.args[1].value) if base else None
    return None


def _nonzero_signal(node, names):
    """True when NODE is a literal non-zero signal: a non-zero int, or a signal module constant (signal.SIGKILL,
    signal.Signals.SIGTERM, SIGTERM imported from signal), or a choice between such."""
    if isinstance(node, ast.Constant):
        return isinstance(node.value, int) and not isinstance(node.value, bool) and node.value != 0
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        return _nonzero_signal(node.operand, names)
    if isinstance(node, ast.IfExp):
        return _nonzero_signal(node.body, names) and _nonzero_signal(node.orelse, names)
    if isinstance(node, ast.Attribute):  # signal.SIGTERM, mod.signal.SIGTERM, __import__("signal").SIGTERM
        return re.fullmatch(r"SIG[A-Z0-9]+", node.attr) is not None
    return re.fullmatch(r"signal\.SIG[A-Z0-9]+", _dotted(node, names) or "") is not None


def _verdict(args, keywords, names):
    """"signal 0", "unresolved" or None (a literal non-zero signal) for a kill call's ARGS and KEYWORDS."""
    if any(isinstance(a, ast.Starred) for a in args) or any(k.arg is None for k in keywords):
        return "unresolved"  # *args or **kwargs: the signal is not in the source
    sig = args[1] if len(args) >= 2 else next((k.value for k in keywords if k.arg in SIGNAL_KEYWORDS), None)
    if sig is None:
        return "unresolved"
    if isinstance(sig, ast.Constant) and sig.value == 0:
        return "signal 0"
    return None if _nonzero_signal(sig, names) else "unresolved"


def find_source(source, name="<test>"):
    """(function, line, kind) for every signal-0 probe in SOURCE, in or out of a loop. A loop is not proof of a wait
    (one with one pass, or no sleep, checks once), so every probe is flagged; the test uses process_gone's died(),
    running() or group_died() instead.

    A probe is any call of something that resolves to os.kill or os.killpg (through `import os as o`,
    `from os import kill`, `k = os.kill`, getattr(os, "kill")) whose signal is not a literal non-zero one: kind
    "signal 0" for a literal 0, "unresolved" for a signal the source does not show (a name, *args, **kwargs). Passing
    os.kill as a value (assertRaises(E, os.kill, pid, 0), functools.partial) counts the arguments after it; a
    reference whose use cannot be followed is "unresolved" too. Nothing that might be a probe is skipped."""
    if "kill" not in source:
        return []
    try:
        tree = ast.parse(source, name)
    except SyntaxError:
        return [("<module>", 0, "unresolved")]  # a file it cannot read is not a clean one
    names = _bindings(tree)
    hits = []
    seen = set()  # reference nodes already judged as a call's func or as an argument

    def is_kill(node):
        return _dotted(node, names) in KILLS

    def visit(node, owner):
        for child in ast.iter_child_nodes(node):
            func = owner
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) and owner is None:
                func = child.name
            if isinstance(child, ast.Call):
                if is_kill(child.func):
                    seen.add(id(child.func))
                    kind = _verdict(child.args, child.keywords, names)
                    if kind:
                        hits.append((func or "<module>", child.lineno, kind))
                for i, a in enumerate(child.args):
                    if is_kill(a):  # assertRaises(E, os.kill, pid, 0): the arguments after it are its own;
                        seen.add(id(a))  # threading.Timer(t, os.kill, (pid, sig)): a tuple right after it holds them
                        rest = child.args[i + 1:]
                        if rest and isinstance(rest[0], (ast.Tuple, ast.List)):
                            rest = rest[0].elts
                        kind = _verdict(rest, [], names)
                        if kind:
                            hits.append((func or "<module>", child.lineno, kind))
            elif (isinstance(child, (ast.Name, ast.Attribute, ast.Call)) and id(child) not in seen and is_kill(child)
                  and isinstance(getattr(child, "ctx", ast.Load()), ast.Load) and not isinstance(node, ast.Attribute)):
                if not (isinstance(node, (ast.Assign, ast.AnnAssign, ast.NamedExpr)) and node.value is child):
                    hits.append((func or "<module>", child.lineno, "unresolved"))  # returned, stored, wrapped
            visit(child, func)

    visit(tree, None)
    return sorted(set(hits), key=lambda h: (h[1], h[0], h[2]))


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
        for func, line, kind in find_source(source, rel):
            if func in COPIES.get(rel, ()):
                continue  # a copy of the helper, held to it by copy_drift()
            found.setdefault("%s::%s" % (rel, func), []).append(line if kind == "signal 0" else "%s (%s)" % (line, kind))
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
        return [f for f, *_ in find_source(src)]

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

    def test_every_way_to_reach_os_kill_is_resolved(self):
        # review of #41326 (F2): an import, an alias, a keyword or getattr hid a probe from the scanner
        src = ("import os, signal\nfrom os import kill\nfrom os import killpg as kpg\nimport os as o\n"
               "k = os.kill\nj = k\n"
               "def test_a():\n    kill(p, 0)\n"
               "def test_b():\n    os.kill(p, sig=0)\n"
               "def test_c():\n    k(p, 0)\n"
               "def test_d():\n    j(p, 0)\n"
               "def test_e():\n    kpg(g, 0)\n"
               "def test_f():\n    o.kill(p, 0)\n"
               "def test_g():\n    getattr(os, 'kill')(p, 0)\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b", "test_c", "test_d", "test_e", "test_f", "test_g"])

    def test_a_signal_the_source_does_not_show_is_flagged_unresolved(self):
        # review of #41326 (F2) and #4379: a splat, a name or a reference that escapes is never skipped
        src = ("import os, signal\nfrom os import kill\n"
               "def test_a():\n    os.kill(*(p, 0))\n"
               "def test_b(args):\n    os.kill(*args)\n"
               "def test_c(sig):\n    os.kill(p, sig)\n"
               "def test_d(kw):\n    os.kill(p, **kw)\n"
               "def test_e():\n    return kill\n"
               "def test_f():\n    os.kill(p, signal.SIGTERM)\n    kill(p, 9)\n    os.killpg(g, signal.SIGKILL)\n"
               "    self.addCleanup(os.kill, p, signal.SIGKILL)\n    threading.Timer(1, os.kill, (p, signal.SIGINT))\n"
               "    os.kill(p, mod.signal.SIGTERM)\n"
               "def test_g():\n    threading.Timer(1, os.kill, (p, 0))\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b", "test_c", "test_d", "test_e", "test_g"])
        self.assertEqual([k for *_, k in find_source(src)], ["unresolved"] * 5 + ["signal 0"])

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



def zombie_group():
    """(holder, pgid): a process group whose one member is a zombie its parent, HOLDER, never reaps."""
    holder = subprocess.Popen([sys.executable, "-c",
                               "import os, signal, sys, time\npid = os.fork()\n"
                               "if pid == 0:\n    os.setpgid(0, 0)\n    time.sleep(60)\n    os._exit(0)\n"
                               "try:\n    os.setpgid(pid, pid)\nexcept OSError:\n    pass\n"
                               "while os.getpgid(pid) != pid:\n    time.sleep(0.01)\n"
                               "os.kill(pid, signal.SIGKILL)\nprint(pid, flush=True)\ntime.sleep(60)\n"],
                              stdout=subprocess.PIPE, text=True)
    return holder, int(holder.stdout.readline())


class RefusesGroupSignalZero:
    """Signal 0 to a process group that exists is refused with EPERM, as macOS does for a group of zombies only. On
    macOS itself the kernel's own answer is used."""

    def __enter__(self):
        if sys.platform == "darwin":
            self.patch = None
            return self
        real = os.killpg

        def killpg(pgid, sig):
            real(pgid, sig)
            if sig == 0:
                raise PermissionError(1, "Operation not permitted")
        self.patch = mock.patch.object(process_gone.os, "killpg", killpg)
        self.patch.start()
        return self

    def __exit__(self, *exc):
        if self.patch:
            self.patch.stop()


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
                # Nothing reaps either zombie during these waits (this test, and HOLDER, never wait on them), so
                # True can only come from seeing the zombie; the old poll answered False at the deadline.
                self.assertTrue(died(proc.pid, within=5), "our own unreaped child")
                self.assertTrue(died(orphan, within=5), "another process's unreaped child")
                self.assertIsNone(holder.poll(), "HOLDER ended, which would have reaped its child")
                self.assertFalse(died(live.pid, within=0.3))
                self.assertTrue(running(live.pid))
                self.assertFalse(running(orphan))
        finally:
            for p in (live, proc, holder):
                p.kill()
                p.wait()
            holder.stdout.close()

    def test_a_pidfd_past_fd_setsize_is_still_waited_on(self):
        # review of #41326 (F1): select.select() refused a pidfd at or above FD_SETSIZE (1024) with ValueError
        if not hasattr(os, "pidfd_open"):
            self.skipTest("no pidfd here: died() polls the state instead")
        import resource
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft < 1300:
            if hard != resource.RLIM_INFINITY and hard < 1300:
                self.skipTest("this host allows %d open files" % hard)
            resource.setrlimit(resource.RLIMIT_NOFILE, (1300, hard))
            self.addCleanup(resource.setrlimit, resource.RLIMIT_NOFILE, (soft, hard))
        fds = [os.open(os.devnull, os.O_RDONLY) for _ in range(1100)]
        live = subprocess.Popen(["sleep", "60"])
        proc = zombie_child()
        try:
            self.assertFalse(died(live.pid, within=0.3))
            self.assertTrue(died(proc.pid))
        finally:
            for fd in fds:
                os.close(fd)
            for p in (live, proc):
                p.kill()
                p.wait()

    def test_a_group_of_zombies_that_refuses_signal_zero_counts_as_died(self):
        # review of #41326 (F3): macOS answers EPERM for a group that holds only zombies; died() is True for them
        holder, pgid = zombie_group()
        live = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            with RefusesGroupSignalZero():
                # HOLDER never reaps its child during the wait, so True can only come from reading the members.
                self.assertTrue(group_died(pgid, within=5), "a group of zombies only")
                self.assertIsNone(holder.poll(), "HOLDER ended, which would have reaped its child")
                self.assertFalse(group_died(live.pid, within=0.3), "a live group that refuses signal 0")
        finally:
            for p in (live, holder):
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
