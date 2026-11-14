#!/usr/bin/env python3
"""A Python script's progress line right before its kill never skips the kill when nobody reads its output.

The Python side of cmux#41832 review F1 (the shell side: tests/test_guard_logs_survive_closed_pipe.py). Python
ignores SIGPIPE, so a print to a stdout or stderr whose reader is gone (a cancelled run, a closed agent pipe, a hung-up
terminal) raises BrokenPipeError or OSError. A script that launched an app or a helper and prints a line right before
it stops it then dies at the print, and the app lives on. cmux#41803 F1 was this in push_range.py's fetch guard.

The fix, one form: a cleanup path never calls print. In any function that stops a process, every line it writes goes
through scripts/cmux-next/safe_log.py's safe_print, which drops the line on a closed output instead of raising.

Two detectors:
- Behaviour rows: the real cleanup() of tab-switch-stages.py, terminal-cmd-click-e2e.py and terminal-keys-e2e.py (a
  leftover process from the app bundle gets SIGTERM after a "cleanup" or "leftover" line) and palette-open-stages.py
  (its virtual-display helper is terminated after a "cleanup" line) run with stdout and stderr on a pipe whose reader
  is gone; the process must be gone afterwards. Each script is executed without its closing `try: main() ...`
  statement, with rpc and the app's CLI stubbed, so only cleanup() runs.
- A whole-function AST rule over every Python file under scripts/, with no window: a function (nested ones each on
  their own) that anywhere in its body stops a process (os.kill, os.killpg, .kill(), .terminate(), .shutdown(),
  .send_signal(), signal.pidfd_send_signal, or a command line that runs kill, pkill, killall or a `shutdown`) may
  not print to stdout or stderr (print, sys.stdout/stderr.write, os.write(1|2, ...)) anywhere, at any depth: under an
  `if`, in a loop, in a `try` or `finally`, before or after the kill. Code outside any function counts per top-level
  statement, so a script's closing `try: ... finally:` that kills is one cleanup path. A three-statement window
  (cmux#41855) missed a log nested under an `if` and longer cleanup paths; this rule has nothing to miss by distance.

Not in CI (tests/test-execution.d/other.toml: manual; no new CI tests, Lawrence 2026-10-23): run
`python3 -I tests/test_python_guard_logs_survive_closed_pipe.py` after adding or changing a script that prints right
before it stops a process (about 20 s; needs python3 and ps).
"""

from __future__ import annotations

import ast
import builtins
import importlib.util
import json
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
KILL_CALLS = {"kill", "killpg", "terminate", "shutdown", "send_signal", "pidfd_send_signal"}
KILL_ARGV = {"kill", "pkill", "killall", "shutdown"}  # a command-line word that stops a process
SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


def _own_nodes(scope: ast.AST):
    """Every node in SCOPE, not counting functions or classes defined in it (each of those is a scope of its own)."""
    stack = list(ast.iter_child_nodes(scope))
    while stack:
        node = stack.pop()
        if isinstance(node, SCOPES):
            continue
        yield node
        stack.extend(ast.iter_child_nodes(node))


def _is_stream(node: ast.AST) -> bool:
    return isinstance(node, ast.Attribute) and node.attr in ("stdout", "stderr")


def is_log(call: ast.Call) -> bool:
    """A call that writes to stdout or stderr, which raises when nobody reads it."""
    func = call.func
    if isinstance(func, ast.Name) and func.id == "print":
        target = next((kw.value for kw in call.keywords if kw.arg == "file"), None)
        return target is None or _is_stream(target)
    if isinstance(func, ast.Attribute) and func.attr == "write":
        if _is_stream(func.value):
            return True
        if isinstance(func.value, ast.Name) and func.value.id == "os" and call.args:
            first = call.args[0]
            return isinstance(first, ast.Constant) and first.value in (1, 2)
    return False


def kills(call: ast.Call) -> bool:
    """A call that stops a process: a kill-style method or function, or a command line that runs kill or shutdown."""
    func = call.func
    name = func.attr if isinstance(func, ast.Attribute) else func.id if isinstance(func, ast.Name) else None
    if name in KILL_CALLS:
        return True
    return any(isinstance(arg, (ast.List, ast.Tuple))
               and any(isinstance(word, ast.Constant) and word.value in KILL_ARGV for word in arg.elts)
               for arg in call.args)


def cleanup_scopes(tree: ast.Module) -> list[ast.AST]:
    """Each function (nested ones too), and each top-level statement outside a function or class."""
    scopes: list[ast.AST] = [node for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))]
    scopes += [ast.Module(body=[stmt], type_ignores=[]) for stmt in tree.body if not isinstance(stmt, SCOPES)]
    return scopes


def unsafe_logs(tree: ast.Module) -> list[ast.Call]:
    """Every stdout or stderr write in a scope that also stops a process."""
    found = []
    for scope in cleanup_scopes(tree):
        calls = [node for node in _own_nodes(scope) if isinstance(node, ast.Call)]
        if any(kills(call) for call in calls):
            found.extend(call for call in calls if is_log(call))
    return sorted(found, key=lambda call: (call.lineno, call.col_offset))


def scan_print_in_cleanup(root: Path = ROOT) -> list[str]:
    """Each print in a function that stops a process, as path:line: call."""
    hits = []
    for path in sorted((root / "scripts").rglob("*.py")):
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"))
        except (SyntaxError, UnicodeDecodeError, ValueError):
            continue
        rel = path.relative_to(root).as_posix()
        hits.extend(f"{rel}:{call.lineno}: {ast.unparse(call)[:120]}" for call in unsafe_logs(tree))
    return sorted(hits, key=lambda hit: (hit.split(":")[0], int(hit.split(":")[1])))


def closed_pipe() -> int:
    """The write end of a pipe whose reader is already gone."""
    read_end, write_end = os.pipe()
    os.close(read_end)
    return write_end


# tests/process_gone.py, loaded by path (`python3 -I` puts no script folder on sys.path). Its probe reads /proc where
# /proc exists and asks `ps` where it does not: macOS has no /proc, and a probe that read a missing /proc entry as
# "gone" passed assert_gone with the target still running (review of cmux#41850 F1).
_process_gone_spec = importlib.util.spec_from_file_location("process_gone", ROOT / "tests" / "process_gone.py")
process_gone = importlib.util.module_from_spec(_process_gone_spec)
_process_gone_spec.loader.exec_module(process_gone)


def alive(pid: int) -> bool:
    """A process still running (a zombie counts as gone), with or without /proc."""
    return process_gone.running(pid)


class NoProcfs:
    """No /proc and no pidfd, as on macOS: the probe must still see a live process."""

    def __enter__(self) -> "NoProcfs":
        real_open, real_isdir, real_exists = builtins.open, os.path.isdir, os.path.exists

        def no_proc(path, *args, **kwargs):
            if str(path).startswith("/proc"):
                raise FileNotFoundError(2, "No such file or directory", str(path))
            return real_open(path, *args, **kwargs)
        self.patches = [mock.patch.object(os, "pidfd_open", side_effect=AttributeError, create=True),
                        mock.patch("builtins.open", no_proc),
                        mock.patch.object(os.path, "isdir", lambda p: False if str(p).startswith("/proc") else real_isdir(p)),
                        mock.patch.object(os.path, "exists", lambda p: False if str(p).startswith("/proc") else real_exists(p))]
        for patch in self.patches:
            patch.start()
        return self

    def __exit__(self, *exc: object) -> None:
        for patch in reversed(self.patches):
            patch.stop()


# Runs one script's cleanup(): the script's module code without its closing `try: main() ...`, rpc and the CLI stubbed
# (no app to talk to), time.sleep capped, then the state file's settings, then cleanup().
DRIVER = textwrap.dedent("""\
    import ast, json, os, subprocess, sys, time, types
    path, state_path = sys.argv[1], sys.argv[2]
    state = json.load(open(state_path))
    tree = ast.parse(open(path).read())
    assert isinstance(tree.body[-1], ast.Try), "the script no longer ends with its try: main() statement"
    tree.body = tree.body[:-1]
    sys.argv = [path] + state["argv"]
    sys.path.insert(0, os.path.dirname(path))
    ns = {"__name__": "guard_row", "__file__": path}
    exec(compile(tree, path, "exec"), ns)
    ns["rpc"] = lambda *args, **kwargs: {}
    ns["CLI"] = "/bin/true"
    ns["time"] = types.SimpleNamespace(**{**vars(time), "sleep": lambda seconds: time.sleep(min(seconds, 0.5))})
    ns.update(state.get("set", {}))
    if state.get("helper_pid"):  # the test's own live helper, standing in for the display helper the script starts
        pid = state["helper_pid"]
        ns["VDISPLAY"] = types.SimpleNamespace(pid=pid, poll=lambda: None,
                                               terminate=lambda: os.kill(pid, __import__("signal").SIGTERM))
    ns["cleanup"]()
    """)


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory(prefix="cmux-pyguard.")
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(os.path.realpath(tmp.name))
        self.app = self.tmp / "cmux DEV guardrow.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.cmuxterm.test.guardrow"}))

    def kill_at_cleanup(self, pid: int) -> None:
        def stop() -> None:
            try:
                os.kill(pid, signal.SIGKILL)  # a process this test started (directly or through the driver)
            except ProcessLookupError:
                pass
        self.addCleanup(stop)

    def leftover(self) -> int:
        """A process whose command runs from the app bundle, as a helper the app left behind; it dies on SIGTERM."""
        proc = subprocess.Popen(["bash", "-c", 'exec -a "$0" sleep 600', f"{self.app}/Contents/MacOS/cmux-helper"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)
        self.addCleanup(proc.wait)
        self.kill_at_cleanup(proc.pid)
        time.sleep(0.3)  # until bash has exec'd sleep under the bundle path
        return proc.pid

    def run_cleanup(self, script: str, state: dict) -> None:
        state_path = self.tmp / "state.json"
        state_path.write_text(json.dumps({"argv": ["--tag", "guardrow", "--app", str(self.app), "--out", str(self.tmp)],
                                          **state}))
        out, err = closed_pipe(), closed_pipe()
        try:
            proc = subprocess.Popen([sys.executable, "-I", "-c", DRIVER, str(ROOT / "scripts/cmux-next" / script),
                                     str(state_path)], stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                    env={**os.environ, "TMPDIR": str(self.tmp)}, start_new_session=True)
        finally:
            os.close(out)
            os.close(err)
        proc.wait(timeout=60)

    def assert_gone(self, pid: int, what: str, within: float = 10) -> None:
        self.assertTrue(process_gone.died(pid, within=within), what)

    def assert_seen_alive(self, pid: int) -> None:
        """The probe's self-check: a process this test just started must read as alive, or assert_gone proves nothing."""
        self.assertTrue(alive(pid), f"the probe cannot see live pid {pid}; assert_gone would pass on any target")

    def check_leftover(self, script: str) -> None:
        target = self.leftover()
        self.assert_seen_alive(target)
        self.run_cleanup(script, {"set": {"LAUNCHED": [target]}})
        self.assert_gone(target, f"{script}: a line before the kill raised on the closed stdout; the leftover lives on")


class CleanupRow(Fixture):
    def test_tab_switch_stages_ends_leftovers_with_stdout_unread(self) -> None:
        self.check_leftover("tab-switch-stages.py")

    def test_terminal_cmd_click_e2e_ends_leftovers_with_stdout_unread(self) -> None:
        self.check_leftover("terminal-cmd-click-e2e.py")

    def test_terminal_keys_e2e_ends_leftovers_with_stdout_unread(self) -> None:
        # Its cleanup() prints "cleanup" first, many statements before the kill: the window scan never saw it.
        self.check_leftover("terminal-keys-e2e.py")

    def test_palette_open_stages_ends_its_display_helper_with_stdout_unread(self) -> None:
        proc = subprocess.Popen(["sleep", "600"], stdin=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(proc.wait)
        helper = proc.pid
        self.kill_at_cleanup(helper)
        self.assert_seen_alive(helper)
        self.run_cleanup("palette-open-stages.py", {"set": {"LAUNCHED": []}, "helper_pid": helper})
        self.assert_gone(helper, "palette-open-stages.py: the cleanup line raised on the closed stdout; the helper lives on")


class ProbeWithoutProcfs(Fixture):
    """Review of cmux#41850 F1: on macOS there is no /proc; the probe must still see a live process."""

    def test_a_live_process_reads_as_alive_with_procfs_hidden(self) -> None:
        target = self.leftover()
        with NoProcfs():
            self.assertTrue(alive(target), "with /proc hidden, a live process read as gone")

    def test_a_surviving_target_fails_assert_gone_with_procfs_hidden(self) -> None:
        target = self.leftover()
        with NoProcfs(), self.assertRaises(AssertionError, msg="assert_gone passed with its target still running"):
            self.assert_gone(target, "the target lives on", within=1)


class ScanPrintInCleanup(unittest.TestCase):
    def test_no_function_that_stops_a_process_prints(self) -> None:
        hits = scan_print_in_cleanup()
        self.assertEqual(hits, [], "a print in a function that stops a process raises on a closed output "
                                   "(BrokenPipeError) and can skip the kill: use safe_log.safe_print for every line "
                                   "in it:\n" + "\n".join(hits))

    def test_the_rule_sees_every_print_in_a_cleanup_and_none_elsewhere(self) -> None:
        source = textwrap.dedent("""\
            def adjacent(app):
                print("stopping", app.pid, flush=True)
                app.terminate()

            def nested_under_if(host, procs):
                if host:
                    print("cloud cleanup:", host, flush=True)
                for p in procs:
                    p.terminate()

            def long_path(app):
                print("cleanup", flush=True)
                a = 1
                b = 2
                c = 3
                d = 4
                os.kill(app.pid, 9)

            def after_the_kill(pid):
                os.killpg(pid, 15)
                sys.stderr.write("killed\\n")

            def shuts_down(server):
                os.write(2, b"bye")
                server.shutdown()

            def by_command_line(pid):
                print("stopping")
                subprocess.run(["kill", str(pid)])

            def safe(app):
                safe_print("stopping", flush=True)
                app.terminate()

            def to_a_file(app, log):
                print("stopping", file=log)
                app.terminate()

            def no_kill():
                print("hello")

            def outer(app):
                print("serving")
                def inner():
                    app.kill()
                return inner

            try:
                main()
            finally:
                print("quit")
                if APP:
                    os.kill(APP.pid, 9)

            print("module line, no kill in its statement")
            """)
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "scripts").mkdir()
            (Path(tmp) / "scripts" / "fixture.py").write_text(source)
            hits = scan_print_in_cleanup(Path(tmp))
        self.assertEqual([int(hit.split(":")[1]) for hit in hits], [2, 7, 12, 21, 24, 28, 51])


if __name__ == "__main__":
    unittest.main()
