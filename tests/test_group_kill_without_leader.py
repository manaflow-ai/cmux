#!/usr/bin/env python3
"""A cleanup that owns a process group kills the group, whatever its leader's state.

cmux#41767 review F1 [P2]: rust-live.py's Builder.cancel() cleaned up the build's process group only while
proc.poll() is None. A build whose leader had exited while a descendant still ran got no signal at all, and the
descendant ran into later builds. The same class as cmux#41832: cleanup keyed on the parent alone.

The group id is the leader's pid (start_new_session=True), and the kernel keeps that id while any member lives, so
os.killpg(pid) still reaches the descendants after the leader exited and was reaped. ProcessLookupError means the
group is empty.

- A behaviour row runs the real Builder.run_build and cancel() on a leader that starts a child and exits. The child
  must be gone after cancel().
- An AST scan of scripts/ flags (A) an os.killpg reached only while the leader is alive (inside `if p.poll() is
  None`, `if p.returncode is None`, `if t.is_alive()`, or after `if p.poll() is not None: return`), and (B) a
  .kill() or .terminate() of a Popen started in its own session (start_new_session=True, process_group=0 or
  preexec_fn=os.setsid) in a function or class that never kills its group. Self-check rows keep the scan honest.
"""
from __future__ import annotations

import ast
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"


# ---------------------------------------------------------------- the scan

def _is_killpg(node: ast.AST) -> bool:
    if not isinstance(node, ast.Call):
        return False
    func = node.func
    return (isinstance(func, ast.Attribute) and func.attr == "killpg") or (isinstance(func, ast.Name) and func.id == "killpg")


def _liveness_reads(test: ast.AST) -> list[tuple[str, bool]]:
    """(object, alive) for each liveness read in TEST: alive is True for `p.poll() is None`, `p.returncode is None`
    and `t.is_alive()`, False for `p.poll() is not None`, `p.returncode is not None` and `not t.is_alive()`."""
    parents = {child: parent for parent in ast.walk(test) for child in ast.iter_child_nodes(parent)}
    reads = []
    for node in ast.walk(test):
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.comparators[0], ast.Constant) \
                and node.comparators[0].value is None and isinstance(node.ops[0], (ast.Is, ast.IsNot)):
            left = node.left
            subject = None
            if isinstance(left, ast.Call) and isinstance(left.func, ast.Attribute) and left.func.attr == "poll":
                subject = ast.unparse(left.func.value)
            elif isinstance(left, ast.Attribute) and left.attr == "returncode":
                subject = ast.unparse(left.value)
            if subject is not None:
                reads.append((subject, isinstance(node.ops[0], ast.Is)))
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "is_alive":
            negated = isinstance(parents.get(node), ast.UnaryOp) and isinstance(parents[node].op, ast.Not)
            reads.append((ast.unparse(node.func.value), not negated))
    return reads


def _killpg_subject(call: ast.Call) -> str | None:
    """p for os.killpg(p.pid, ...)."""
    if call.args and isinstance(call.args[0], ast.Attribute) and call.args[0].attr == "pid":
        return ast.unparse(call.args[0].value)
    return None


def _own_session(call: ast.Call) -> bool:
    for kw in call.keywords:
        value = kw.value
        if kw.arg == "start_new_session" and isinstance(value, ast.Constant) and value.value is True:
            return True
        if kw.arg == "process_group" and isinstance(value, ast.Constant) and value.value == 0:
            return True
        if kw.arg == "preexec_fn" and "setsid" in ast.unparse(value):
            return True
    return False


def _is_popen(call: ast.AST) -> bool:
    if not isinstance(call, ast.Call):
        return False
    func = call.func
    return (isinstance(func, ast.Attribute) and func.attr == "Popen") or (isinstance(func, ast.Name) and func.id == "Popen")


def scan(source: str, name: str = "<source>") -> list[str]:
    tree = ast.parse(source)
    parents: dict[ast.AST, ast.AST] = {}
    for parent in ast.walk(tree):
        for child in ast.iter_child_nodes(parent):
            parents[child] = parent
    findings = []

    # (A) a group kill reached only while the leader is alive.
    for func in ast.walk(tree):
        if not isinstance(func, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for call in ast.walk(func):
            if not _is_killpg(call):
                continue
            gate = None
            node = call
            while node is not func and gate is None:
                parent = parents[node]
                if isinstance(parent, ast.If) and node in parent.body and any(a for _, a in _liveness_reads(parent.test)):
                    gate = parent
                node = parent
            subject = _killpg_subject(call)
            if gate is None and subject is not None:
                # `if p.poll() is not None: return` earlier in the function: the kill below runs only for a live leader.
                # A kill in the `finally` of a try around the return still runs.
                finals = []
                node = call
                while node is not func:
                    parent = parents[node]
                    if isinstance(parent, ast.Try) and node in parent.finalbody:
                        finals.append(parent)
                    node = parent
                for stmt in ast.walk(func):
                    if (isinstance(stmt, ast.If) and stmt.lineno < call.lineno and (subject, False) in _liveness_reads(stmt.test)
                            and stmt.body and isinstance(stmt.body[-1], ast.Return)
                            and not any(_is_killpg(n) for n in ast.walk(stmt))
                            and not any(stmt in set(ast.walk(ast.Module(body=t.body, type_ignores=[]))) for t in finals)):
                        gate = stmt
                        break
            if gate is not None:
                findings.append(f"{name}:{call.lineno}: os.killpg runs only while the leader is alive "
                                f"(gate at line {gate.lineno}); a descendant of an exited leader is never killed")

    # (B) only the leader of an own-session Popen is stopped, and its group never is.
    for assign in ast.walk(tree):
        if not (isinstance(assign, ast.Assign) and _is_popen(assign.value) and _own_session(assign.value)):
            continue
        for target in assign.targets:
            if not isinstance(target, (ast.Name, ast.Attribute)):
                continue
            key = ast.unparse(target)
            scope: ast.AST = tree
            node = assign
            while node in parents:
                node = parents[node]
                if isinstance(target, ast.Attribute) and isinstance(node, ast.ClassDef):
                    scope = node
                    break
                if isinstance(target, ast.Name) and isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    scope = node
                    break
            if any(_is_killpg(n) for n in ast.walk(scope)):
                continue
            for call in ast.walk(scope):
                if (isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
                        and call.func.attr in ("kill", "terminate") and ast.unparse(call.func.value) == key):
                    findings.append(f"{name}:{call.lineno}: {key}.{call.func.attr}() stops only the leader of the group "
                                    f"started at line {assign.lineno}; its children keep running")
    return findings


def scan_scripts() -> list[str]:
    findings = []
    for path in sorted(SCRIPTS.rglob("*.py")):
        try:
            source = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        try:
            findings += scan(source, str(path.relative_to(ROOT)))
        except SyntaxError:
            continue
    return findings


class ScanTests(unittest.TestCase):
    def test_scripts_kill_the_group_whatever_the_leader_state(self) -> None:
        findings = scan_scripts()
        self.assertEqual(findings, [], "\n".join(findings))

    def test_scan_flags_a_kill_inside_a_liveness_gate(self) -> None:
        source = textwrap.dedent("""
            def cancel(proc):
                if proc and proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
        """)
        self.assertEqual(len(scan(source)), 1)

    def test_scan_flags_a_kill_after_an_early_return_for_a_dead_leader(self) -> None:
        source = textwrap.dedent("""
            def stop(proc):
                if proc is None or proc.poll() is not None:
                    return
                os.killpg(proc.pid, signal.SIGTERM)
        """)
        self.assertEqual(len(scan(source)), 1)

    def test_scan_flags_a_kill_gated_on_a_waiter_thread(self) -> None:
        source = textwrap.dedent("""
            def preempt(proc, waiter):
                os.killpg(proc.pid, signal.SIGTERM)
                waiter.join(5)
                if waiter.is_alive():
                    os.killpg(proc.pid, signal.SIGKILL)
        """)
        self.assertEqual(len(scan(source)), 1)

    def test_scan_passes_an_ungated_group_kill(self) -> None:
        source = textwrap.dedent("""
            def cancel(proc):
                if proc is None:
                    return
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(proc.pid, sig)
                    except ProcessLookupError:
                        return
                    if proc.poll() is None:
                        proc.wait(timeout=5)
        """)
        self.assertEqual(scan(source), [])

    def test_scan_passes_an_unrelated_returncode_check_before_the_kill(self) -> None:
        source = textwrap.dedent("""
            def run(check, proc):
                if check.returncode != 0:
                    return 1
                os.killpg(proc.pid, signal.SIGKILL)
        """)
        self.assertEqual(scan(source), [])

    def test_scan_passes_a_kill_of_what_an_exited_leader_left(self) -> None:
        source = textwrap.dedent("""
            def start(sup):
                if sup.poll() is not None:
                    os.killpg(sup.pid, signal.SIGKILL)
                    return fail()
        """)
        self.assertEqual(scan(source), [])

    def test_scan_passes_a_kill_in_a_finally_after_an_early_return(self) -> None:
        source = textwrap.dedent("""
            def measure(child):
                try:
                    if child.poll() is not None:
                        return None
                    return sample(child)
                finally:
                    os.killpg(child.pid, signal.SIGKILL)
        """)
        self.assertEqual(scan(source), [])

    def test_scan_flags_a_leader_only_kill_of_an_own_session_popen(self) -> None:
        source = textwrap.dedent("""
            def run():
                daemon = subprocess.Popen(["d"], start_new_session=True)
                daemon.terminate()
            class Recorder:
                def start(self):
                    self.proc = subprocess.Popen(["r"], preexec_fn=os.setsid)
                def stop(self):
                    self.proc.kill()
        """)
        self.assertEqual(len(scan(source)), 2)

    def test_scan_passes_a_group_kill_and_a_plain_popen(self) -> None:
        source = textwrap.dedent("""
            def run():
                daemon = subprocess.Popen(["d"], start_new_session=True)
                try:
                    os.killpg(daemon.pid, signal.SIGTERM)
                except ProcessLookupError:
                    daemon.kill()
                plain = subprocess.Popen(["p"])
                plain.kill()
        """)
        self.assertEqual(scan(source), [])


# ---------------------------------------------------------------- the behaviour row

def _load_rust_live():
    spec = importlib.util.spec_from_file_location("rust_live_group_kill", ROOT / "scripts/cmux-next/rust-live.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses look their module up here
    spec.loader.exec_module(module)
    return module


def _gone(pid: int) -> bool:
    """No such process, or a zombie its new parent has not reaped yet."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return state == "" or state.startswith("Z")


def _wait_for(predicate, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


class RustLiveCancelTests(unittest.TestCase):
    def test_cancel_kills_a_child_its_exited_leader_left(self) -> None:
        rust_live = _load_rust_live()
        with tempfile.TemporaryDirectory(prefix="group-kill-") as scratch:
            scratch_path = Path(scratch)
            pid_file = scratch_path / "child.pid"
            builder = rust_live.Builder(scratch_path, scratch_path / "state", None, None)
            # The leader starts a child that keeps the build's output open, records its pid, and exits at once.
            argv = ["sh", "-c", f'sleep 600 & echo $! > "{pid_file}"; exit 0']
            done = threading.Event()
            thread = threading.Thread(target=lambda: (builder.run_build(argv), done.set()), daemon=True)
            thread.start()
            child = None
            try:
                self.assertTrue(_wait_for(lambda: pid_file.is_file() and pid_file.read_text().strip(), 10),
                                "the leader never recorded its child")
                child = int(pid_file.read_text().strip())
                self.assertTrue(_wait_for(lambda: builder.current is not None, 10), "run_build never set its build")
                leader = builder.current
                # The leader exits (and is reaped here) while its child lives on in the build's group.
                self.assertTrue(_wait_for(lambda: leader.poll() is not None, 10), "the leader did not exit")
                self.assertFalse(_gone(child), "the child should still run before cancel()")
                builder.cancel()
                self.assertTrue(_wait_for(lambda: _gone(child), 10),
                                f"cancel() left the exited leader's child {child} running (cmux#41767 review F1)")
                self.assertTrue(done.wait(10), "run_build did not return once the group was gone")
            finally:
                # This row's own child only, by the pid it recorded.
                if child is not None and not _gone(child):
                    try:
                        os.kill(child, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main(verbosity=2)
