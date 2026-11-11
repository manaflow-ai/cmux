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
import collections
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

        def declare(node, scope):
            """Every scope's global and nonlocal names, before any binding is read: a declaration applies to its
            whole scope, so `import os; global os` binds the module's os, as `global os; import os` does."""
            for child in ast.iter_child_nodes(node):
                if isinstance(child, (ast.Global, ast.Nonlocal)):
                    g, n = declared.setdefault(scope, (set(), set()))
                    (g if isinstance(child, ast.Global) else n).update(child.names)
                declare(child, child if isinstance(child, SCOPES) else scope)

        skip = set()  # id() of a def's or class's outer parts, already walked in the scope around it

        def walk(node, scope):
            for child in ast.iter_child_nodes(node):
                if id(child) in skip:
                    continue
                self.scope[id(child)] = scope
                inner = scope
                if isinstance(child, SCOPES):
                    inner = child
                    self.parent[child] = scope
                elif isinstance(scope, ast.ClassDef) and isinstance(child, (ast.Lambda,) + COMPREHENSIONS):
                    # A lambda or comprehension in a class body does not see the class's names either (#4468 F1):
                    # it is a scope of its own here, past which chain() skips the class. Its first iterable, or a
                    # lambda's defaults, run in the class body.
                    inner = child
                    self.parent[child] = scope
                    if isinstance(child, ast.Lambda):
                        outer = child.args.defaults + [d for d in child.args.kw_defaults if d is not None]
                    else:
                        outer = [child.generators[0].iter]
                    for o in outer:
                        self.scope[id(o)] = scope
                        walk(_Holder(o), scope)
                    skip.update(id(o) for o in outer)
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    a = child.args
                    positional = a.posonlyargs + a.args
                    pairs = list(zip(positional[len(positional) - len(a.defaults):], a.defaults))
                    pairs += [(arg, d) for arg, d in zip(a.kwonlyargs, a.kw_defaults) if d is not None]
                    for arg, default in pairs:
                        self.defaults.add(id(default))
                        assigns.append((ast.Assign(targets=[ast.Name(id=arg.arg, ctx=ast.Store())], value=default),
                                        child))
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    # Decorators, defaults, annotations and a class's bases run in the scope around the def or
                    # class (a method's `send=os.kill` sees the class body's `import os`); only the body is inside.
                    outer = outer_parts(child)
                    for o in outer:
                        self.scope[id(o)] = scope
                        walk(_Holder(o), scope)
                    skip.update(id(o) for o in outer)
                if isinstance(child, (ast.Assign, ast.AnnAssign, ast.NamedExpr)):
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
        declare(tree, tree)
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
        """SCOPE, then the scopes a read in it falls through to: as in Python, a class body's names are seen in that
        body only, not by the methods (or classes) inside it."""
        out = [scope]
        while out[-1] in self.parent:
            out.append(self.parent[out[-1]])
        return out[:1] + [s for s in out[1:] if not isinstance(s, ast.ClassDef)]

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


class _Holder(ast.AST):
    """A node with NODE as its one child, so _walk judges NODE itself."""
    _fields = ("node",)

    def __init__(self, node):
        super().__init__()
        self.node = node


NONLOCAL = "<nonlocal>"  # where a binding through `nonlocal` lands, for bindings_of: never the binding scope's own
# match statements are 3.10+; macOS's /usr/bin/python3 is 3.9, whose ast has none of these (LW#4428 F4)
MATCH_CAPTURES = tuple(getattr(ast, n) for n in ("MatchAs", "MatchStar") if hasattr(ast, n))
MATCH_MAPPING = tuple(getattr(ast, n) for n in ("MatchMapping",) if hasattr(ast, n))
MATCH = getattr(ast, "Match", ())
FUNCTION_SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)
COMPREHENSIONS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
ALL_SCOPES = (ast.Module, ast.ClassDef) + FUNCTION_SCOPES + COMPREHENSIONS


class Scopes:
    """Python's own scope rules for any name, for a lint that resolves values (a knob's literal, a constant) rather
    than os.kill. scope_of(node) is the scope NODE is evaluated in; binds[scope] counts each name SCOPE binds itself;
    owner(node, name) is the scope whose binding a read of NAME at NODE sees, or None when nothing in the source
    binds it (a builtin, or a name only a star import could bring).

    As Python does: a class body's names are seen in that body only, not by its methods or by a comprehension in it
    (whose first iterable is still the class body's); decorators, defaults, annotations and a class's bases are
    evaluated in the enclosing scope; global and nonlocal cover their whole scope, wherever they sit; a walrus in a
    comprehension binds in the enclosing function or module. star[scope] is True when SCOPE has `from M import *`:
    any name read through it may be one it bound, so a lint must count such a read as unresolved."""

    def __init__(self, tree):
        self.root = tree
        self.parent = {}  # scope -> the scope it sits in
        self.scope = {id(tree): tree}  # id(node) -> the scope NODE is evaluated in
        self.binds = {tree: collections.Counter()}
        self.globals, self.nonlocals = {}, {}
        self._declare(tree, tree)  # before any binding: a declaration covers its whole scope
        self.star = {}
        self.walrus = set()  # id() of a walrus target
        self.walrus_expr = {}  # id() of a walrus target -> its NamedExpr
        self.annotation_only = set()  # id() of the target of `x: T` with no value: local to its scope, bound by nothing
        self.sites = {}  # id() of a node that binds -> [(name, the scope the binding lands in, or NONLOCAL)]
        self._outside = []  # (scope, name) bound through nonlocal: counted where it lands, once all scopes are known
        self._walk(tree, tree)
        for scope, name in self._outside:
            self.binds[self._enclosing_function(scope, name) or self.root][name] += 1

    def _declare(self, node, scope):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.Global):
                self.globals.setdefault(scope, set()).update(child.names)
            elif isinstance(child, ast.Nonlocal):
                self.nonlocals.setdefault(scope, set()).update(child.names)
            inner = child if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) else scope
            self._declare(child, inner)

    def _enclosing_function(self, scope, name):
        """The nearest function around SCOPE (a class skipped) that binds NAME, for SCOPE's `nonlocal NAME`."""
        s = self.parent.get(scope)
        while s is not None and s is not self.root:
            if isinstance(s, FUNCTION_SCOPES) and (self.binds[s][name] or name in self.nonlocals.get(s, ())):
                return s if name not in self.nonlocals.get(s, ()) else self._enclosing_function(s, name)
            s = self.parent.get(s)
        return None

    def _enter(self, node, outer):
        self.parent[node] = outer
        self.binds[node] = collections.Counter()

    def _bind(self, scope, name, site=None):
        if name in self.globals.get(scope, ()):
            self.binds[self.root][name] += 1
            land = self.root
        elif name in self.nonlocals.get(scope, ()):
            self._outside.append((scope, name))
            land = NONLOCAL
        else:
            self.binds[scope][name] += 1
            land = scope
        if site is not None:
            self.sites.setdefault(id(site), []).append((name, land))

    def _walk(self, node, scope):
        for child in ast.iter_child_nodes(node):
            self.scope[id(child)] = scope
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                self._bind(scope, child.name, child)
                outer = list(child.decorator_list)
                if isinstance(child, ast.ClassDef):
                    outer += child.bases + [k.value for k in child.keywords]
                else:
                    outer += self._outer_of_args(child.args) + ([child.returns] if child.returns else [])
                for o in outer:
                    self.scope[id(o)] = scope
                    self._walk_one(o, scope)
                self._enter(child, scope)
                if not isinstance(child, ast.ClassDef):
                    self._bind_args(child, child.args)
                for stmt in child.body:
                    self.scope[id(stmt)] = child
                    self._walk_one(stmt, child)
            elif isinstance(child, ast.Lambda):
                for o in self._outer_of_args(child.args):
                    self.scope[id(o)] = scope
                    self._walk_one(o, scope)
                self._enter(child, scope)
                self._bind_args(child, child.args)
                self.scope[id(child.body)] = child
                self._walk_one(child.body, child)
            elif isinstance(child, COMPREHENSIONS):
                first = child.generators[0].iter
                self.scope[id(first)] = scope
                self._walk_one(first, scope)
                self._enter(child, scope)
                for i, gen in enumerate(child.generators):
                    for part in [gen.target] + ([gen.iter] if i else []) + gen.ifs:
                        self.scope[id(part)] = child
                        self._walk_one(part, child)
                for part in ([child.key, child.value] if isinstance(child, ast.DictComp) else [child.elt]):
                    self.scope[id(part)] = child
                    self._walk_one(part, child)
            else:
                if isinstance(child, ast.AnnAssign) and child.value is None:
                    self.annotation_only.add(id(child.target))
                self._note(child, scope)
                self._walk(child, scope)

    def _walk_one(self, node, scope):
        """NODE itself in SCOPE (a def, class, lambda or comprehension opens its own scope), then what is inside."""
        self._walk(_Holder(node), scope)

    @staticmethod
    def _outer_of_args(a):
        out = a.defaults + [d for d in a.kw_defaults if d]
        for arg in a.posonlyargs + a.args + a.kwonlyargs + [a.vararg, a.kwarg]:
            if arg is not None and arg.annotation is not None:
                out.append(arg.annotation)
        return out

    def _bind_args(self, scope, a):
        for arg in a.posonlyargs + a.args + a.kwonlyargs + [a.vararg, a.kwarg]:
            if arg is not None:
                self._bind(scope, arg.arg)

    def _note(self, node, scope):
        """Record what NODE itself binds or declares in SCOPE."""
        if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
            target = scope
            if isinstance(scope, COMPREHENSIONS) and id(node) in self.walrus:
                while isinstance(target, COMPREHENSIONS):
                    target = self.parent[target]  # PEP 572: a walrus in a comprehension binds outside it
            # `fd: object` makes fd local, as Python's compiler does, but runs no binding: no site for bindings_of
            self._bind(target, node.id, None if id(node) in self.annotation_only else node)
        elif isinstance(node, ast.NamedExpr):
            self.walrus.add(id(node.target))
            self.walrus_expr[id(node.target)] = node
        elif isinstance(node, ast.ExceptHandler) and node.name:
            self._bind(scope, node.name, node)
        elif isinstance(node, ast.alias):
            if node.name == "*":
                self.star[scope] = True
            else:
                self._bind(scope, (node.asname or node.name).split(".")[0], node)
        elif isinstance(node, MATCH_CAPTURES) and node.name:
            self._bind(scope, node.name, node)
        elif isinstance(node, MATCH_MAPPING) and node.rest:
            self._bind(scope, node.rest, node)

    def bindings_of(self, node, parts=None):
        """(name, site) for every name NODE binds in the scope NODE is evaluated in, read from PARTS (default: NODE
        itself). A compound statement is read by its header only (header(): an if's test, a for's target and
        iter, a with's items, a match's subject, a handler's name and type); its body's statements bind on their
        own. A binding is a Name target (an assignment's, an unpacking's, an augmented one's, a for's, a with's,
        a del's), a walrus (one in a comprehension binds in the enclosing scope, PEP 572), an except handler's
        name, an import, a match capture, or a def's or class's own name. An attribute or subscript target
        (f.attr = 1, d[k] = v) binds nothing. Never looks into a nested def, class or lambda body, whose names
        are its own; a def's decorators and defaults, a lambda's defaults and a class's bases are read, as they
        run in the enclosing scope. An annotation with no value (`fd: object`) binds nothing at runtime. A name
        declared global lands in the module and one declared nonlocal in an enclosing def, so neither is a
        binding of a function's own. SITE is the NamedExpr for a walrus, else the node that binds (the Name
        target, the handler, the alias, the def)."""
        scope = self.scope_of(node)
        out = []
        stack = list(parts if parts is not None else [node])
        while stack:
            n = stack.pop()
            for name, land in self.sites.get(id(n), ()):
                if land is scope:
                    out.append((name, self.walrus_expr.get(id(n), n)))
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
                stack += n.decorator_list + self._outer_of_args(n.args) + ([n.returns] if n.returns else [])
            elif isinstance(n, ast.ClassDef):
                stack += n.decorator_list + n.bases + [k.value for k in n.keywords]
            elif isinstance(n, ast.Lambda):
                stack += self._outer_of_args(n.args)
            else:
                stack += header(n)
        out.reverse()  # source order, as the stack was walked from the back
        return out


    def scope_of(self, node):
        return self.scope.get(id(node), self.root)

    def owner(self, node, name):
        """The scope whose binding a read of NAME at NODE sees, or None."""
        scope, first = self.scope_of(node), True
        while scope is not None:
            if not first and isinstance(scope, ast.ClassDef):
                scope = self.parent.get(scope)  # a class body is not seen from a scope inside it
                continue
            if name in self.globals.get(scope, ()):
                return self.root if self.binds[self.root][name] else None
            if name in self.nonlocals.get(scope, ()):
                return self._enclosing_function(scope, name)
            if self.binds[scope][name]:
                return scope
            scope, first = self.parent.get(scope), False
        return None


def header(node):
    """What a statement runs before its body: an if's or while's test, a for's target and iter, a with's items, a
    match's subject, an except handler's type; nothing for a try. Any other node: all its children."""
    if isinstance(node, (ast.If, ast.While)):
        return [node.test]
    if isinstance(node, (ast.For, ast.AsyncFor)):
        return [node.target, node.iter]
    if isinstance(node, (ast.With, ast.AsyncWith)):
        return list(node.items)
    if isinstance(node, MATCH):
        return [node.subject]
    if isinstance(node, ast.ExceptHandler):
        return [node.type] if node.type is not None else []
    if isinstance(node, ast.Try) or type(node).__name__ == "TryStar":
        return []
    return list(ast.iter_child_nodes(node))


def outer_parts(node):
    """The parts of a def or class that run in the scope around it: decorators, parameter defaults and annotations,
    the return annotation, a class's bases and keywords."""
    out = list(node.decorator_list)
    if isinstance(node, ast.ClassDef):
        return out + node.bases + list(node.keywords)
    a = node.args
    out += a.defaults + [d for d in a.kw_defaults if d is not None]
    for arg in a.posonlyargs + a.args + a.kwonlyargs + [a.vararg, a.kwarg]:
        if arg is not None and arg.annotation is not None:
            out.append(arg.annotation)
    return out + ([node.returns] if node.returns is not None else [])
