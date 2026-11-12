#!/usr/bin/env python3
"""A Python script's progress line right before its kill never skips the kill when nobody reads its output.

The Python side of cmux#41832 review F1 (the shell side: tests/test_guard_logs_survive_closed_pipe.py). Python
ignores SIGPIPE, so a print to a stdout or stderr whose reader is gone (a cancelled run, a closed agent pipe, a hung-up
terminal) raises BrokenPipeError or OSError. A script that launched an app or a helper and prints a line right before
it stops it then dies at the print, and the app lives on. cmux#41803 F1 was this in push_range.py's fetch guard.

The fix, one form: the line goes through scripts/cmux-next/safe_log.py's safe_print, which drops the line on a closed
output instead of raising; or the print sits inside a `try` whose `finally` does the kill.

Two detectors:
- Behaviour rows: the real cleanup() of tab-switch-stages.py and terminal-cmd-click-e2e.py (a leftover process from
  the app bundle gets SIGTERM after a "leftover" line) and palette-open-stages.py (its virtual-display helper is
  terminated after a "cleanup" line) run with stdout and stderr on a pipe whose reader is gone; the process must be
  gone afterwards. Each script is executed without its closing `try: main() ...` statement, with rpc and the app's CLI
  stubbed, so only cleanup() runs.
- An AST scan of every Python file under scripts/: a print (to stdout or stderr), sys.stdout/stderr.write or
  os.write(1|2, ...) statement followed within WINDOW statements of the same block by one that kills (os.kill,
  os.killpg, .kill(), .terminate(), .send_signal(), signal.pidfd_send_signal), unless a `try` around it kills in its
  `finally`.

Not in CI (tests/test-execution.d/other.toml: manual; no new CI tests, Lawrence 2026-10-23): run
`python3 -I tests/test_python_guard_logs_survive_closed_pipe.py` after adding or changing a script that prints right
before it stops a process (about 20 s; needs python3 and ps).
"""

from __future__ import annotations

import ast
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

ROOT = Path(__file__).resolve().parents[1]
WINDOW = 3  # statements after the line, in the same block
KILL_ATTRS = {"kill", "killpg", "terminate", "send_signal", "pidfd_send_signal"}


def _is_stream(node: ast.AST) -> bool:
    return isinstance(node, ast.Attribute) and node.attr in ("stdout", "stderr")


def _is_log(stmt: ast.stmt) -> bool:
    """A statement that writes a line to stdout or stderr, which raises when nobody reads it."""
    if not isinstance(stmt, ast.Expr) or not isinstance(stmt.value, ast.Call):
        return False
    call, func = stmt.value, stmt.value.func
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


def _kills(node: ast.AST) -> bool:
    """True when NODE (not counting functions or classes defined in it) stops a process."""
    stack = [node]
    while stack:
        current = stack.pop()
        if isinstance(current, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
            continue
        if isinstance(current, ast.Call) and isinstance(current.func, ast.Attribute) and current.func.attr in KILL_ATTRS:
            return True
        stack.extend(ast.iter_child_nodes(current))
    return False


def _scan_tree(tree: ast.AST, rel: str) -> list[str]:
    guarded: set[int] = set()  # ids of statements inside a `try` whose `finally` kills
    for node in ast.walk(tree):
        if isinstance(node, ast.Try) and any(_kills(stmt) for stmt in node.finalbody):
            for stmt in node.body:
                guarded.update(id(inner) for inner in ast.walk(stmt))
    hits = []
    for node in ast.walk(tree):
        for field in ("body", "orelse", "finalbody"):
            block = getattr(node, field, None)
            if not isinstance(block, list) or not block or not isinstance(block[0], ast.stmt):
                continue
            for index, stmt in enumerate(block):
                if not _is_log(stmt) or id(stmt) in guarded:
                    continue
                if any(_kills(after) for after in block[index + 1:index + 1 + WINDOW]):
                    hits.append(f"{rel}:{stmt.lineno}: {ast.unparse(stmt)[:120]}")
    return hits


def scan_print_then_kill(root: Path = ROOT) -> list[str]:
    """Each print right before a kill that a closed output could stop, as path:line: statement."""
    hits = []
    for path in sorted((root / "scripts").rglob("*.py")):
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"))
        except (SyntaxError, UnicodeDecodeError, ValueError):
            continue
        hits.extend(_scan_tree(tree, path.relative_to(root).as_posix()))
    return sorted(hits, key=lambda hit: (hit.split(":")[0], int(hit.split(":")[1])))


def closed_pipe() -> int:
    """The write end of a pipe whose reader is already gone."""
    read_end, write_end = os.pipe()
    os.close(read_end)
    return write_end


def alive(pid: int) -> bool:
    """A process still running (a zombie counts as gone)."""
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii") as stat:
            return stat.read().rsplit(")", 1)[1].split()[0] != "Z"
    except FileNotFoundError:
        return False
    except OSError:
        pass
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


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
    if state.get("helper_pid_file"):
        helper = subprocess.Popen(["sleep", "600"], start_new_session=True)
        with open(state["helper_pid_file"], "w") as out:
            out.write(str(helper.pid))
        ns["VDISPLAY"] = helper
    ns["cleanup"]()
    """)


class CleanupRow(unittest.TestCase):
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

    def assert_gone(self, pid: int, what: str) -> None:
        deadline = time.monotonic() + 10
        while alive(pid) and time.monotonic() < deadline:
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
            time.sleep(0.1)
        self.assertFalse(alive(pid), what)

    def check_leftover(self, script: str) -> None:
        target = self.leftover()
        self.run_cleanup(script, {"set": {"LAUNCHED": [target]}})
        self.assert_gone(target, f"{script}: a line before the kill raised on the closed stdout; the leftover lives on")

    def test_tab_switch_stages_ends_leftovers_with_stdout_unread(self) -> None:
        self.check_leftover("tab-switch-stages.py")

    def test_terminal_cmd_click_e2e_ends_leftovers_with_stdout_unread(self) -> None:
        self.check_leftover("terminal-cmd-click-e2e.py")

    def test_palette_open_stages_ends_its_display_helper_with_stdout_unread(self) -> None:
        pid_file = self.tmp / "helper.pid"
        self.run_cleanup("palette-open-stages.py", {"set": {"LAUNCHED": []}, "helper_pid_file": str(pid_file)})
        self.assertTrue(pid_file.exists(), "the driver did not start the helper")
        helper = int(pid_file.read_text())
        self.kill_at_cleanup(helper)
        self.assert_gone(helper, "palette-open-stages.py: the cleanup line raised on the closed stdout; the helper lives on")


class ScanPrintThenKill(unittest.TestCase):
    def test_no_script_prints_unguarded_right_before_a_kill(self) -> None:
        hits = scan_print_then_kill()
        self.assertEqual(hits, [], "a print right before a kill raises on a closed output (BrokenPipeError) and skips "
                                   "the kill: use safe_log.safe_print, or kill in a `finally` around it:\n"
                                   + "\n".join(hits))

    def test_the_scan_sees_the_unsafe_forms_only(self) -> None:
        source = textwrap.dedent("""\
            def unsafe(app):
                print("stopping", app.pid, flush=True)
                app.terminate()

            def unsafe_stderr(pid):
                sys.stderr.write("stopping\\n")
                x = 1
                os.kill(pid, 15)

            def safe_helper(app):
                safe_print("stopping", flush=True)
                app.terminate()

            def safe_finally(app):
                try:
                    print("stopping", flush=True)
                finally:
                    app.kill()

            def to_a_file(app, log):
                print("stopping", file=log)
                app.terminate()

            def far_away(app):
                print("start")
                a = 1
                b = 2
                c = 3
                app.terminate()

            def nested_def(app):
                print("serving")
                def later():
                    app.kill()
            """)
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "scripts").mkdir()
            (Path(tmp) / "scripts" / "fixture.py").write_text(source)
            hits = scan_print_then_kill(Path(tmp))
        self.assertEqual([int(hit.split(":")[1]) for hit in hits], [2, 6])


if __name__ == "__main__":
    unittest.main()
