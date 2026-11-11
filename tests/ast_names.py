#!/usr/bin/env python3
"""Resolve what a name in Python source may be bound to, per scope, and find every reference to a set of functions.

The one resolver behind the detectors that look for os.kill and its kin: leo-workspace's process_gone lint and
proc_guard detector, and the process_gone lint cmuxterm-hq and cmux vendor. They resolve aliases one way: `import os
as o`, `import os.path`, `from os import kill`, `from os import *`, `k = os.kill`, getattr(os, "kill") and a
parameter default all reach os.kill, getattr(os, name) may be any of os's names, and a reference whose use cannot be
followed is reported as escaped, never passed (fail closed).

Source of truth: leo-workspace tools/ast_names.py. cmuxterm-hq and cmux carry byte copies in tests/, pinned in
tests/process_gone.pin. Standard library only.
"""
import ast
import re

MODULES = ("os", "posix", "signal")
# What `from M import *` binds that a detector reads, the same on every platform: os's and posix's kill and killpg,
# signal's pidfd_send_signal; signal's SIG* constants are read through STAR_SIGNAL when a name is looked up.
STAR = {"os": ("kill", "killpg"), "posix": ("kill", "killpg"), "signal": ("pidfd_send_signal",)}
STAR_SIGNAL = re.compile(r"SIG[A-Z0-9]+")
# The only paths that read as a signal constant: signal.SIGTERM (signal.Signals.SIGTERM too) and os.SIGTERM.
SIGNAL_CONSTANT = re.compile(r"(signal|os)\.(Signals\.)?SIG[A-Z0-9]+")


SCOPES = (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


class Bindings:
    """What each name may be bound to, per scope: a module ("os", "posix", "signal") or one of its functions or
    constants ("os.kill", "signal.SIGKILL"), through imports and plain assignments. A name read in a scope may be
    anything it is bound to there or in any scope around it, so `import signal as os` in one function neither hides
    nor changes another function's os.kill, and where two bindings meet the reading that finds a kill wins. A name
    bound to anything else is left out."""

    def __init__(self, tree):
        self.scope = {}  # id(node) -> the Module, function or class it is read in
        self.parent = {}  # scope -> the scope around it
        self.table = {}  # scope -> {name: {dotted, ...}}
        declared = {}  # scope -> ({global names}, {nonlocal names})
        assigns = []
        self.defaults = set()  # id() of a parameter default in a def: def stop(pid, kill=os.kill) binds kill

        def walk(node, scope):
            for child in ast.iter_child_nodes(node):
                self.scope[id(child)] = scope
                inner = scope
                if isinstance(child, SCOPES):
                    inner = child
                    self.parent[child] = scope
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    a = child.args
                    positional = a.posonlyargs + a.args
                    pairs = list(zip(positional[len(positional) - len(a.defaults):], a.defaults))
                    pairs += [(arg, d) for arg, d in zip(a.kwonlyargs, a.kw_defaults) if d is not None]
                    for arg, default in pairs:
                        self.defaults.add(id(default))
                        assigns.append((ast.Assign(targets=[ast.Name(id=arg.arg, ctx=ast.Store())], value=default),
                                        child))
                if isinstance(child, (ast.Global, ast.Nonlocal)):
                    g, n = declared.setdefault(scope, (set(), set()))
                    (g if isinstance(child, ast.Global) else n).update(child.names)
                elif isinstance(child, (ast.Assign, ast.AnnAssign, ast.NamedExpr)):
                    assigns.append((child, scope))
                elif isinstance(child, ast.Import):
                    for a in child.names:
                        if a.name in MODULES:
                            self._bind(scope, a.asname or a.name, a.name, declared)
                        elif a.asname is None and a.name.split(".")[0] in MODULES:
                            head = a.name.split(".")[0]  # import os.path binds os itself
                            self._bind(scope, head, head, declared)
                elif (isinstance(child, ast.ImportFrom) and child.module in MODULES
                      and not child.level):
                    for a in child.names:
                        if a.name == "*":  # from os import *: kill among what it binds
                            for n in STAR[child.module]:
                                self._bind(scope, n, "%s.%s" % (child.module, n), declared)
                            if child.module == "signal":
                                self.table.setdefault(scope, {}).setdefault("*", set()).add("signal")
                        else:
                            self._bind(scope, a.asname or a.name, "%s.%s" % (child.module, a.name), declared)
                walk(child, inner)

        self.root = tree
        self.scope[id(tree)] = tree
        walk(tree, tree)
        for _ in range(len(assigns) + 1):  # k = os.kill; j = k: until nothing new resolves
            grew = False
            for node, scope in assigns:
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for value in dotted(node.value, self):
                    for t in targets:
                        if isinstance(t, ast.Name):
                            grew |= self._bind(scope, t.id, value, declared)
            if not grew:
                break

    def _bind(self, scope, name, value, declared):
        g, n = declared.get(scope, ((), ()))
        if name in g:
            targets = [self.root]
        elif name in n:  # nonlocal: any function around it, the conservative reading
            targets = [s for s in self.chain(scope)[1:] if s is not self.root] or [self.root]
        else:
            targets = [scope]
        grew = False
        for s in targets:
            seen = self.table.setdefault(s, {}).setdefault(name, set())
            if value not in seen:
                seen.add(value)
                grew = True
        return grew

    def chain(self, scope):
        out = [scope]
        while out[-1] in self.parent:
            out.append(self.parent[out[-1]])
        return out

    def lookup(self, node, name):
        scope = self.scope.get(id(node), self.root)
        found = set()
        for s in self.chain(scope):
            table = self.table.get(s, {})
            found |= table.get(name, set())
            if "signal" in table.get("*", ()) and STAR_SIGNAL.fullmatch(name):
                found.add("signal." + name)  # from signal import *: SIGTERM
        return found


def dotted(node, names):
    """Every thing NODE may name through NAMES ("os.kill", "signal.SIGKILL", "os"); empty when none is known. An
    attribute of a module the source picks at run time (getattr(os, name)) is "os.*": it may be any of them."""
    if isinstance(node, ast.Name):
        return names.lookup(node, node.id)
    if isinstance(node, ast.Attribute):
        return {"%s.%s" % (b, node.attr) for b in dotted(node.value, names) if not b.endswith(".*")} | \
            {b for b in dotted(node.value, names) if b.endswith(".*")}
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        if node.func.id == "getattr" and len(node.args) >= 2:
            bases = {b for b in dotted(node.args[0], names) if not b.endswith(".*")}
            attr = node.args[1]
            if isinstance(attr, ast.Constant) and isinstance(attr.value, str):
                return {"%s.%s" % (b, attr.value) for b in bases}  # getattr(os, "kill")
            return {"%s.*" % b for b in bases}  # getattr(os, name): any of os's names
        if (node.func.id == "__import__" and node.args and isinstance(node.args[0], ast.Constant)
                and node.args[0].value in MODULES):
            return {node.args[0].value}  # __import__("signal").SIGTERM
    return set()


def may_be(readings, targets):
    """True when one of READINGS (from dotted) may be one of TARGETS: itself, or "os.*" for any "os.<name>"."""
    return any(r in targets or (r.endswith(".*") and any(t.startswith(r[:-1]) for t in targets)) for r in readings)


def signal_constant(node, names):
    """True when every reading of NODE is a signal constant on a known path (signal.SIGTERM, signal.Signals.SIGTERM,
    os.SIGTERM, SIGTERM imported from signal). An attribute of something unknown (obj.SIGTERM, mod.signal.SIGTERM) is
    not one: it is unresolved."""
    readings = dotted(node, names)
    return bool(readings) and all(SIGNAL_CONSTANT.fullmatch(r) for r in readings)


def references(tree, names, targets):
    """Yield (functions, node, how, args, keywords) for every reference in TREE that may resolve to one of TARGETS
    ("os.kill", ...). FUNCTIONS is the list of function definitions around it, outermost first. HOW is:
    - "call": NODE is a call of it; ARGS and KEYWORDS are the call's own.
    - "passed": NODE is a call that takes it as a positional argument (assertRaises(E, os.kill, pid, 0),
      threading.Timer(t, os.kill, (pid, sig))); ARGS are the arguments after it (a tuple right after it unpacked).
    - "escaped": NODE is the reference itself, used where it cannot be followed: returned, stored on an attribute or
      in a class body, passed by keyword, put in a container, or read through (os.kill.__call__). ARGS is None.
    A reference bound to a plain name outside a class body (k = os.kill), or the default of a def's parameter
    (def stop(pid, kill=os.kill)), is followed through that name instead: calls of the name are judged as calls."""
    targets = set(targets)
    seen = set()  # reference nodes already reported as a call's func or as an argument

    def hit(node):
        return may_be(dotted(node, names), targets)

    def visit(node, functions):
        for child in ast.iter_child_nodes(node):
            inner = functions + [child] if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) else functions
            if isinstance(child, ast.Call):
                if hit(child.func):
                    seen.add(id(child.func))
                    yield functions, child, "call", child.args, child.keywords
                for i, a in enumerate(child.args):
                    if hit(a):
                        seen.add(id(a))
                        rest = child.args[i + 1:]
                        if rest and isinstance(rest[0], (ast.Tuple, ast.List)):
                            rest = rest[0].elts
                        yield functions, child, "passed", rest, []
            if (isinstance(child, (ast.Name, ast.Attribute, ast.Call)) and id(child) not in seen and hit(child)
                    and isinstance(getattr(child, "ctx", ast.Load()), ast.Load)):
                followed = id(child) in names.defaults or (
                            isinstance(node, (ast.Assign, ast.AnnAssign, ast.NamedExpr)) and node.value is child
                            and all(isinstance(t, ast.Name) for t in
                                    (node.targets if isinstance(node, ast.Assign) else [node.target]))
                            and not isinstance(names.scope.get(id(node)), ast.ClassDef))
                if not followed:
                    yield functions, child, "escaped", None, None
            yield from visit(child, inner)

    yield from visit(tree, [])
