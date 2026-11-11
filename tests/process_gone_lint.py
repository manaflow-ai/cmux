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
Bindings, references, signal_constant = _names.Bindings, _names.references, _names.signal_constant

KILLS = {"os.kill", "os.killpg", "posix.kill", "posix.killpg"}
SIGNAL_KEYWORDS = ("signal", "sig", "signum")


def _nonzero_signal(node, names):
    """True when NODE is a literal non-zero signal: a non-zero int, or a signal constant on a known path
    (signal.SIGKILL, signal.Signals.SIGTERM, SIGTERM imported from signal), or a choice between such. obj.SIGTERM of
    an unknown obj is not one."""
    if isinstance(node, ast.Constant):
        return isinstance(node.value, int) and not isinstance(node.value, bool) and node.value != 0
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        return _nonzero_signal(node.operand, names)
    if isinstance(node, ast.IfExp):
        return _nonzero_signal(node.body, names) and _nonzero_signal(node.orelse, names)
    return signal_constant(node, names)


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
    names = Bindings(tree)
    hits = []
    for functions, node, how, args, keywords in references(tree, names, KILLS):
        kind = "unresolved" if how == "escaped" else _verdict(args, keywords, names)
        if kind:
            hits.append((functions[0].name if functions else "<module>", node.lineno, kind))
    return sorted(set(hits), key=lambda h: (h[1], h[0], h[2]))
