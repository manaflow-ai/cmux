#!/usr/bin/env python3
"""The lint for "a killed process is not gone yet": find every signal-0 probe in a test's source.

A test that probes a process with signal 0, `os.kill(pid, 0)` or `os.killpg(pgid, 0)`, races the kernel and the
reaper: under load a killed process is still in the process table for a moment, and signal 0 still reaches a zombie,
so "it is gone" fails and "it still runs" passes on a dead one. A loop around the probe is no proof of a wait (one
with a single pass, or no sleep, checks once). So every raw probe in a test is flagged, in any form; the test uses
process_gone.died(pid), running(pid) or group_died(pgid). Names resolve through ast_names (beside this file), so an
alias, a star import, getattr or a signal on an unknown object is followed or reported, never passed.

    find_source(source, name)   [(function, line, "signal 0" | "unresolved")]

Source of truth: leo-workspace tools/process_gone_lint.py. cmuxterm-hq and cmux carry byte copies in tests/, pinned
in tests/process_gone.pin; each repo's own test decides which files it scans and what it allows.
"""
import ast
import importlib.util
import re
import sys
from pathlib import Path


def _sibling(name):
    """The module NAME.py beside this file, loaded by path (tests run under `python3 -I`: no script folder on
    sys.path), once per process."""
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / ("%s.py" % name))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


_names = _sibling("ast_names")
Bindings, references, Scopes, dotted = _names.Bindings, _names.references, _names.Scopes, _names.dotted

KILLS = {"os.kill", "os.killpg", "posix.kill", "posix.killpg"}
SIGNAL_KEYWORDS = ("signal", "sig", "signum")
# A source can reach os.kill without spelling "kill": getattr(os, name), __import__, a star import.
MAY_REACH_KILL = re.compile(r"kill|getattr|__import__|import\s+\*")


# Paths whose value is 0, as a signal: SIG_DFL is the default handler, 0, and signal 0 to kill() is the probe.
ZERO_PATHS = {"signal.SIG_DFL", "signal.Handlers.SIG_DFL"}
_FOLD = {ast.Add: lambda a, b: a + b, ast.Sub: lambda a, b: a - b, ast.Mult: lambda a, b: a * b,
         ast.FloorDiv: lambda a, b: a // b if b else None, ast.Mod: lambda a, b: a % b if b else None,
         ast.BitAnd: lambda a, b: a & b, ast.BitOr: lambda a, b: a | b, ast.BitXor: lambda a, b: a ^ b}


class _Values:
    """What a kill call's signal argument may be, as far as the source shows: {0, 9, ...} for ints, "signal" for a
    non-zero signal constant (signal.SIGTERM), or None when it cannot be told. A name has the values of its one
    binding in the scope that owns it (ast_names.Scopes), so `sig = 0; os.kill(p, sig)` is a probe; a parameter,
    a name bound more than once or through a star import, or a call is None (unresolved)."""

    def __init__(self, tree, names):
        self.names = names
        self.scopes = Scopes(tree)
        self.assigned = {}  # (scope, name) -> the value of its `NAME = VALUE`
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                self.assigned[(self.scopes.scope_of(node), node.targets[0].id)] = node.value
            elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value is not None:
                self.assigned[(self.scopes.scope_of(node), node.target.id)] = node.value

    def of(self, node, depth=0):
        """A set of what NODE may be (ints, or "signal"), or None when unknown."""
        if depth > 20:
            return None
        if isinstance(node, ast.Constant):
            v = node.value
            return {int(v)} if isinstance(v, (int, bool)) else None
        readings = dotted(node, self.names)
        if readings and readings & ZERO_PATHS and all(r in ZERO_PATHS or signal_constant_path(r) for r in readings):
            return {0} | ({"signal"} if readings - ZERO_PATHS else set())
        if readings and all(signal_constant_path(r) for r in readings):
            return {"signal"}
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
            inner = self.of(node.operand, depth + 1)
            if inner is None or "signal" in inner:
                return None if inner is None else inner
            return {-v if isinstance(node.op, ast.USub) else v for v in inner}
        if isinstance(node, ast.BinOp) and type(node.op) in _FOLD:
            left, right = self.of(node.left, depth + 1), self.of(node.right, depth + 1)
            if not left or not right or "signal" in left or "signal" in right:
                return None
            out = {_FOLD[type(node.op)](a, b) for a in left for b in right}
            return None if None in out else out
        if isinstance(node, ast.IfExp):
            body, orelse = self.of(node.body, depth + 1), self.of(node.orelse, depth + 1)
            return None if body is None or orelse is None else body | orelse
        if isinstance(node, ast.Name):
            owner = self.scopes.owner(node, node.id)
            if owner is None or self.scopes.star.get(owner) or self.scopes.binds[owner][node.id] != 1:
                return None
            value = self.assigned.get((owner, node.id))
            return None if value is None else self.of(value, depth + 1)
        return None


def signal_constant_path(reading):
    return _names.SIGNAL_CONSTANT.fullmatch(reading) is not None


def _verdict(args, keywords, values):
    """"signal 0", "unresolved" or None (a non-zero signal) for a kill call's ARGS and KEYWORDS. A signal that may
    be 0 (a literal 0, SIG_DFL, a name bound to 0, 1 - 1, a choice with 0 in it) is a probe; one whose value the
    source does not show (a parameter, a call, *args, **kwargs, obj.SIGTERM of an unknown obj) is unresolved."""
    if any(isinstance(a, ast.Starred) for a in args) or any(k.arg is None for k in keywords):
        return "unresolved"  # *args or **kwargs: the signal is not in the source
    sig = args[1] if len(args) >= 2 else next((k.value for k in keywords if k.arg in SIGNAL_KEYWORDS), None)
    if sig is None:
        return "unresolved"
    got = values.of(sig)
    if got is None:
        return "unresolved"
    if 0 in got:
        return "signal 0"
    return None


def find_source(source, name="<test>"):
    """(function, line, kind) for every signal-0 probe in SOURCE, in or out of a loop. A loop is not proof of a wait
    (one with one pass, or no sleep, checks once), so every probe is flagged; the test uses process_gone's died(),
    running() or group_died() instead.

    A probe is any call of something that resolves to os.kill or os.killpg (through `import os as o`,
    `from os import kill`, `k = os.kill`, getattr(os, "kill")) whose signal is not a non-zero one: kind "signal 0"
    for one that may be 0 (0, SIG_DFL, a name bound to 0, 1 - 1), "unresolved" for one the source does not show (a
    parameter, a call, *args, **kwargs). Passing
    os.kill as a value (assertRaises(E, os.kill, pid, 0), functools.partial) counts the arguments after it; a
    reference whose use cannot be followed is "unresolved" too. Nothing that might be a probe is skipped."""
    if not MAY_REACH_KILL.search(source):
        return []  # cheap skip: nothing here can name os.kill
    try:
        tree = ast.parse(source, name)
    except SyntaxError:
        return [("<module>", 0, "unresolved")]  # a file it cannot read is not a clean one
    names = Bindings(tree)
    values = _Values(tree, names)
    hits = []
    for functions, node, how, args, keywords in references(tree, names, KILLS):
        kind = "unresolved" if how == "escaped" else _verdict(args, keywords, values)
        if kind:
            hits.append((functions[0].name if functions else "<module>", node.lineno, kind))
    return sorted(set(hits), key=lambda h: (h[1], h[0], h[2]))
