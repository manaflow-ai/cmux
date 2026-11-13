#!/usr/bin/env python3
"""What a name read at one place in Python source is bound to, decided by the compiler's own symtable.

One resolver for every lint that asks "which binding does this read see": ast_names (and through it the os.kill
detectors and the lock-release dataflow), process_gone_lint, process_gone_cases and py39_check. It replaces the
per-file scope tables those kept by hand, each of which missed a different corner (a lambda parameter, a
comprehension target, a class body seen from an annotation scope, an import in one function hiding another's).

    r = Resolver(tree, source)       # source optional: without it the tree is unparsed for symtable
    r.scope_of(node)                 # the Scope NODE is evaluated in
    r.owners(node, name)             # [Scope, ..., BUILTINS] in the order Python looks, or None: unresolved
    r.sites(scope, name)             # the binding sites of NAME that land in SCOPE (NAME as name_at() gives it)
    r.name_at(node, name)            # NAME as Python spells it at NODE: `__x` in a class C's body or methods is _C__x
    r.values(node, name)             # (dotted values the read may have, complete?)

The scope tree is built from the AST, one Scope per module, class, def, lambda, comprehension and PEP 695 scope
(type parameters, a TypeVar's bound, a type alias's value), and every one is matched to its symtable table by kind,
name and line. Python's rules then come from the table, not from this file: whether a name is local, declared
global, free or an implicit global, and which enclosing function holds the cell a free name reads. A comprehension
the compiler inlines (PEP 709, 3.12+) has no table: its targets are its own and every other name is read as from a
function nested where it sits. A name read in an annotation scope inside a class body (a generic method's bound)
sees that class's names first, as at run time. A private name (`__x`, no trailing `__`) written or read anywhere
inside a class body, its methods included, is the mangled name symtable records (`_C__x`), as the compiler spells
it: owners() and values() take the name as the source spells it, and sites() the mangled one.

Anything symtable cannot decide (a scope that matches no table, a name its table lacks, source that does not
compile) is unresolved: owners() is None and a caller must not pass it (fail closed).

Vendored from teamleaderleo/leo-workspace tools/scope_resolver.py at 07b4c9bf9
(LW #4755, #4769, #4775); keep the compiler scope and binding rules together.
Local follow-up: record defaults in the shared argument walker, including lambda parameters.
Source of truth: leo-workspace tools/scope_resolver.py. Standard library only; runs on Python 3.9 (macOS's
/usr/bin/python3) and later.
"""
import ast
import builtins
import collections
import symtable
import sys

BUILTINS = "<builtins>"  # the last place a global read looks

FUNCTION_DEFS = (ast.FunctionDef, ast.AsyncFunctionDef)
COMPREHENSIONS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
_COMP_NAMES = {ast.ListComp: "listcomp", ast.SetComp: "setcomp", ast.DictComp: "dictcomp",
               ast.GeneratorExp: "genexpr"}
_TYPE_ALIAS = getattr(ast, "TypeAlias", ())
_MATCH_CAPTURES = tuple(getattr(ast, n) for n in ("MatchAs", "MatchStar") if hasattr(ast, n))
_MATCH_MAPPING = tuple(getattr(ast, n) for n in ("MatchMapping",) if hasattr(ast, n))
# Scope kinds whose names are their own (a function-like scope): a read of one of its locals never falls through.
FUNCTION_LIKE = ("function", "lambda", "comprehension", "typeparams", "bound", "alias")
# symtable's get_type() for each kind, across 3.9 to 3.13
_TABLE_KIND = {"module": "module", "class": "class", "function": "function", "type parameter": "typeparams",
               "type parameters": "typeparams", "TypeVar bound": "bound", "type variable": "bound",
               "type alias": "alias"}


class ScopeResolutionError(RuntimeError):
    """The compiler-backed scope map could not be built, so callers must refuse the file."""


def mangle(scope, name):
    """NAME as the compiler spells it in SCOPE: inside a class body, or any scope nested in one (a method, a lambda,
    a comprehension), `__x` with no trailing `__` is `_C__x`, C being the nearest class's name with its leading
    underscores stripped; a class named only underscores mangles nothing. Idempotent: `_C__x` is left alone."""
    if not name.startswith("__") or name.endswith("__") or "." in name:
        return name
    while scope is not None and scope.kind != "class":
        scope = scope.parent
    if scope is None:
        return name
    owner = scope.name.lstrip("_")
    return "_%s%s" % (owner, name) if owner else name


class Scope:
    """One scope: KIND is module, class, function, lambda, comprehension, typeparams (a generic def's, class's or
    alias's type parameters), bound (a TypeVar's bound or default) or alias (a type alias's value). NODE is its AST
    node (for typeparams, bound and alias: the def, class, type parameter or alias statement it belongs to)."""

    def __init__(self, kind, node, parent, name, lineno):
        self.kind, self.node, self.parent, self.name, self.lineno = kind, node, parent, name, lineno
        self.children = []
        self.table = None  # its symtable table; None for an inlined comprehension, or when broken
        self.inlined = False
        self.broken = parent is not None and parent.broken
        self.sites = collections.defaultdict(list)  # name -> [site node], the bindings that land here
        self.stars = []  # modules `from M import *` reads in here
        self.foreign = collections.defaultdict(list)  # name -> [site] written here from a nested scope
        self.globals, self.nonlocals = set(), set()
        if parent is not None:
            parent.children.append(self)

    def __repr__(self):
        return "<Scope %s %s:%s>" % (self.kind, self.name, self.lineno)


class Resolver:
    def __init__(self, tree, source=None, star=None):
        self.tree = tree
        self.star = star  # star(module, name) -> the paths `from module import *` may bind NAME to
        self.scope = {}  # id(node) -> Scope it is evaluated in
        self.written = []  # (name, site, Scope written in, how): how is "walrus", "plain" or "param"
        self.defaults = {}  # id(arg) -> its default node, for a def's or lambda's parameter
        self.annotation_only = set()  # id() of the target of `x: T` with no value
        self.unplaced = set()  # names with a write symtable could not place
        self._walrus = set()  # id() of a walrus target
        self.root = Scope("module", tree, None, "top", 0)
        self.scope[id(tree)] = self.root
        self._walk(tree, self.root)
        self._match(tree, source)
        self.landing = {}  # id(site) -> [(name, Scope it lands in)]
        for name, site, scope, how in self.written:
            land = self._land(scope, name, how)
            self.landing.setdefault(id(site), []).append((name, land))
            if land is not None:
                land.sites[name].append(site)
                if land is not scope and how != "walrus":
                    land.foreign[name].append(site)  # written from a nested scope, through global or nonlocal
            else:
                self.unplaced.add(name)  # a write symtable cannot place may land in any scope
        self._memo, self._busy = {}, set()

    # --- the scope tree ---------------------------------------------------------------------------------------

    def _put(self, node, scope):
        self.scope[id(node)] = scope
        self._walk(node, scope, own=True)

    def _write(self, name, site, scope, how="plain"):
        self.written.append((mangle(scope, name), site, scope, how))

    def _type_params(self, node, scope):
        params = getattr(node, "type_params", None) or []
        if not params:
            return scope
        name = node.name if isinstance(node.name, str) else node.name.id  # a type alias's name is a Name
        tp = Scope("typeparams", node, scope, name, node.lineno)
        for p in params:
            self._write(p.name, p, tp)
            self.scope[id(p)] = tp
            for part in ("bound", "default_value"):
                expr = getattr(p, part, None)
                if expr is not None:
                    self._put(expr, Scope("bound", p, tp, p.name, expr.lineno))
        return tp

    def _args(self, a, outer):
        """A def's or lambda's parameters, after walking their defaults in OUTER, where Python evaluates them."""
        for d in a.defaults + [d for d in a.kw_defaults if d is not None]:
            self._put(d, outer)
        positional = a.posonlyargs + a.args
        pairs = list(zip(positional[len(positional) - len(a.defaults):], a.defaults))
        pairs += [(x, d) for x, d in zip(a.kwonlyargs, a.kw_defaults) if d is not None]
        for x, d in pairs:
            self.defaults[id(x)] = d
        return [x for x in a.posonlyargs + a.args + a.kwonlyargs + [a.vararg, a.kwarg] if x is not None]

    def _walk(self, node, scope, own=False):
        children = [node] if own else ast.iter_child_nodes(node)
        for child in children:
            self.scope[id(child)] = scope
            if isinstance(child, FUNCTION_DEFS):
                self._write(child.name, child, scope)
                a = child.args
                params = self._args(a, scope)
                for d in child.decorator_list:
                    self._put(d, scope)
                inner = self._type_params(child, scope)
                for x in params:
                    if x.annotation is not None:
                        self._put(x.annotation, inner)
                if child.returns is not None:
                    self._put(child.returns, inner)
                body = Scope("function", child, inner, child.name, child.lineno)
                for x in params:
                    self.scope[id(x)] = body
                    self._write(x.arg, x, body, "param")
                for stmt in child.body:
                    self._put(stmt, body)
            elif isinstance(child, ast.ClassDef):
                self._write(child.name, child, scope)
                for d in child.decorator_list:
                    self._put(d, scope)
                inner = self._type_params(child, scope)
                for b in child.bases + [k.value for k in child.keywords]:
                    self._put(b, inner)
                body = Scope("class", child, inner, child.name, child.lineno)
                for stmt in child.body:
                    self._put(stmt, body)
            elif _TYPE_ALIAS and isinstance(child, _TYPE_ALIAS):
                self._write(child.name.id, child.name, scope)
                self.scope[id(child.name)] = scope
                inner = self._type_params(child, scope)
                self._put(child.value, Scope("alias", child, inner, child.name.id, child.lineno))
            elif isinstance(child, ast.Lambda):
                params = self._args(child.args, scope)
                body = Scope("lambda", child, scope, "lambda", child.lineno)
                for x in params:
                    self.scope[id(x)] = body
                    if x.annotation is not None:  # a lambda's parameters have none; kept for symmetry
                        self._put(x.annotation, scope)
                    self._write(x.arg, x, body, "param")
                self._put(child.body, body)
            elif isinstance(child, COMPREHENSIONS):
                self._put(child.generators[0].iter, scope)
                body = Scope("comprehension", child, scope, _COMP_NAMES[type(child)], child.lineno)
                for i, gen in enumerate(child.generators):
                    for part in [gen.target] + ([gen.iter] if i else []) + gen.ifs:
                        self._put(part, body)
                for part in ([child.key, child.value] if isinstance(child, ast.DictComp) else [child.elt]):
                    self._put(part, body)
            else:
                self._note(child, scope)
                self._walk(child, scope)

    def _note(self, node, scope):
        if isinstance(node, ast.AnnAssign) and node.value is None:
            self.annotation_only.add(id(node.target))
        if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
            if id(node) not in self.annotation_only:
                self._write(node.id, node, scope, "walrus" if id(node) in self._walrus else "plain")
        elif isinstance(node, ast.NamedExpr):
            self._walrus.add(id(node.target))
        elif isinstance(node, ast.ExceptHandler) and node.name:
            self._write(node.name, node, scope)
        elif isinstance(node, ast.alias):
            if node.name == "*":
                pass  # recorded by the ImportFrom
            else:
                self._write((node.asname or node.name).split(".")[0], node, scope)
        elif isinstance(node, ast.ImportFrom) and any(a.name == "*" for a in node.names):
            scope.stars.append(node.module if not node.level else None)
        elif isinstance(node, ast.Global):
            scope.globals.update(mangle(scope, n) for n in node.names)
        elif isinstance(node, ast.Nonlocal):
            scope.nonlocals.update(mangle(scope, n) for n in node.names)
        elif _MATCH_CAPTURES and isinstance(node, _MATCH_CAPTURES) and node.name:
            self._write(node.name, node, scope)
        elif _MATCH_MAPPING and isinstance(node, _MATCH_MAPPING) and node.rest:
            self._write(node.rest, node, scope)

    # --- matching scopes to symtable ------------------------------------------------------------------------

    def _match(self, tree, source):
        """Give every scope its symtable table, matched by kind, name and line; a scope with none is broken."""
        lines = None
        if source is None:
            try:
                source = ast.unparse(tree) if hasattr(ast, "unparse") else None
            except Exception as exc:
                raise ScopeResolutionError("could not unparse the source: %s" % exc) from exc
            if source is not None:
                lines = self._relines(tree, source)
                if lines is None:
                    raise ScopeResolutionError("could not align reparsed scopes with the source")
        try:
            top = symtable.symtable(source, "<scope_resolver>", "exec") if source is not None else None
        except (SyntaxError, ValueError, TypeError) as exc:
            raise ScopeResolutionError("could not build the scope table: %s" % exc) from exc
        if top is None:
            raise ScopeResolutionError("could not build the scope table")
        self.root.table = top
        try:
            self._pair(self.root, lines or {})
        except RecursionError as exc:
            raise ScopeResolutionError("could not pair the scope tables: %s" % exc) from exc

    @staticmethod
    def _relines(tree, source):
        """{id(scope node): its line in SOURCE} (TREE unparsed), so keys match what symtable reports; None when the
        reparsed tree's scopes do not line up with TREE's."""
        try:
            again = ast.parse(source)
        except SyntaxError:
            return None
        kinds = (ast.ClassDef, ast.Lambda) + FUNCTION_DEFS + COMPREHENSIONS + ((_TYPE_ALIAS,) if _TYPE_ALIAS else ())
        mine = [n for n in ast.walk(tree) if isinstance(n, kinds)]
        theirs = [n for n in ast.walk(again) if isinstance(n, kinds)]
        if [type(n) for n in mine] != [type(n) for n in theirs]:
            return None
        return {id(a): b.lineno for a, b in zip(mine, theirs)}

    def _key(self, scope, lines):
        if scope.kind == "bound":
            return "bound", scope.name, None  # one bound per type parameter name in its typeparams table
        kind = {"lambda": "function", "comprehension": "function"}.get(scope.kind, scope.kind)
        return kind, scope.name, lines.get(id(scope.node), scope.lineno)

    def _below(self, scope):
        """SCOPE's child scopes that have a table of their own in SCOPE's table: through an inlined comprehension."""
        out = []
        for child in scope.children:
            out.append(child)
            if child.inlined:
                out.extend(self._below(child))
        return out

    def _pair(self, scope, lines):
        tables = collections.defaultdict(list)
        for t in scope.table.get_children():
            kind = _TABLE_KIND.get(str(t.get_type()), str(t.get_type()))
            tables[(kind, t.get_name(), None if kind == "bound" else t.get_lineno())].append(t)
        # an inlined comprehension (PEP 709) has no table: decide before grouping its parent's children
        pending = list(scope.children)
        while pending:
            child = pending.pop(0)
            if (child.kind == "comprehension" and not isinstance(child.node, ast.GeneratorExp)
                    and sys.version_info >= (3, 12) and not tables.get(self._key(child, lines))):
                child.inlined = True
                pending[:0] = child.children
        groups = collections.defaultdict(list)
        for child in self._below(scope):
            if not child.inlined:
                groups[self._key(child, lines)].append(child)
        for key, mine in groups.items():
            theirs = tables.get(key, [])
            if len(theirs) != len(mine):
                raise ScopeResolutionError("could not pair scope %s" % (key,))
            for s, t in zip(mine, theirs):
                s.table = t
                self._pair(s, lines)

    def _break(self, scope):
        scope.broken = True
        for c in scope.children:
            self._break(c)

    # --- Python's rules, from the tables --------------------------------------------------------------------

    @staticmethod
    def _sym(scope, name):
        try:
            return scope.table.lookup(name)
        except (KeyError, AttributeError):
            return None

    def _comp_locals(self, scope):
        return {n for n, sites in scope.sites.items() if sites}

    def _land(self, scope, name, how):
        """The Scope a binding of NAME written in SCOPE lands in, or None when it cannot be told."""
        if how == "walrus":
            while scope.kind == "comprehension":
                scope = scope.parent  # PEP 572: a walrus in a comprehension binds where the comprehension is
        if scope.kind == "comprehension" and scope.inlined:
            return scope
        if scope.broken:
            return None
        if scope is self.root:
            return scope
        sym = self._sym(scope, name)
        if sym is None:
            return None
        if sym.is_declared_global():
            return self.root
        if sym.is_free() or (hasattr(sym, "is_nonlocal") and sym.is_nonlocal()):
            return self._cell(scope.parent, name)
        return scope

    def _cell(self, scope, name):
        """The function-like scope from SCOPE outward whose local NAME a free read sees (classes skipped)."""
        while scope is not None and scope is not self.root:
            if scope.broken:
                return None
            if scope.kind == "class":
                scope = scope.parent
                continue
            if scope.inlined:
                if name in self._comp_locals(scope):
                    return scope
                scope = scope.parent
                continue
            sym = self._sym(scope, name)
            if sym is not None and sym.is_local() and not sym.is_declared_global():
                return scope
            scope = scope.parent
        return None

    def _classdict(self, scope):
        """The class body an annotation scope reads first (`__classdict__`), or None."""
        if scope.kind not in ("typeparams", "bound", "alias") or self._sym(scope, "__classdict__") is None:
            return None
        s = scope.parent
        while s is not None and s.kind != "class":
            s = s.parent
        return s

    def owners(self, node, name):
        """Where a read of NAME at NODE looks, in Python's order: a list of Scopes ending, for a global read, in
        BUILTINS. None when symtable cannot decide it (unresolved)."""
        return self.owners_in(self.scope_of(node), name)

    def owners_in(self, scope, name):
        name = mangle(scope, name)
        if scope.broken:
            return None
        if scope.inlined:
            if name in self._comp_locals(scope):
                return [scope]
            return self._from_nested(scope.parent, name)
        sym = self._sym(scope, name)
        if sym is None:
            return None
        k = self._classdict(scope)
        prefix = [k] if k is not None else []
        if sym.is_declared_global():
            return prefix + [self.root, BUILTINS]
        if scope is self.root:
            return [self.root, BUILTINS]
        if sym.is_free():
            cell = self._cell(scope.parent, name)
            if cell is None:
                return None
            return ([scope] if scope.kind == "class" else prefix) + [cell]
        if sym.is_local():
            return [scope, self.root, BUILTINS] if scope.kind == "class" else [scope]
        return prefix + [self.root, BUILTINS]

    def _from_nested(self, scope, name):
        """Where a function nested in SCOPE reads NAME (an inlined comprehension's free or global name)."""
        while scope is not None:
            if scope.broken:
                return None
            if scope is self.root:
                return [self.root, BUILTINS]
            if scope.kind == "class":
                scope = scope.parent
                continue
            if scope.inlined:
                if name in self._comp_locals(scope):
                    return [scope]
                scope = scope.parent
                continue
            sym = self._sym(scope, name)
            if sym is not None:
                if sym.is_declared_global():
                    return [self.root, BUILTINS]
                if sym.is_local():
                    return [scope]
                if not sym.is_free():
                    k = self._classdict(scope)
                    return ([k] if k is not None else []) + [self.root, BUILTINS]
            scope = scope.parent
        return None

    def scope_of(self, node):
        return self.scope.get(id(node), self.root)

    def name_at(self, node, name):
        """NAME as Python spells it where NODE is evaluated: a private name inside a class is mangled (mangle())."""
        return mangle(self.scope_of(node), name)

    def sites(self, scope, name):
        return scope.sites.get(name, []) if scope is not BUILTINS else []

    def rewritten(self, scope, name):
        """True when NAME in SCOPE may be rebound by code that runs at another time: a nested def's or lambda's
        `global NAME` or `nonlocal NAME` write lands in SCOPE (LW#4517 F1), or a write of NAME symtable could not
        place. A read of it then may see any of SCOPE's bindings, whatever the statement order says."""
        return scope is not BUILTINS and (bool(scope.foreign.get(name)) or name in self.unplaced)

    def landed(self, site):
        """[(name, Scope or None)] for what SITE binds."""
        return self.landing.get(id(site), [])

    def scopes(self):
        out, stack = [], [self.root]
        while stack:
            s = stack.pop()
            out.append(s)
            stack.extend(reversed(s.children))
        return out

    # --- values: what a name may name, as a dotted path ----------------------------------------------------

    def values(self, node, name):
        """(paths, complete): the dotted paths ("os", "os.kill", "builtins.len") a read of NAME at NODE may hold,
        and whether every binding it may see is one whose path the source shows. Unresolved reads take every
        binding of NAME anywhere in the source, and are never complete."""
        owners = self.owners(node, name)
        return self.values_of(owners, self.name_at(node, name), at=node)

    def values_of(self, owners, name, at=None):
        if owners is None:
            out = set()
            for s in self.scopes():
                for site in s.sites.get(name, ()):
                    out |= self._site_value(site, name)[0]
            for s in self.scopes():
                out |= self._stars(s, name)
            if hasattr(builtins, name):
                out.add("builtins." + name)
            return out, False
        out, complete = set(), True
        for o in owners:
            if o is BUILTINS:
                if hasattr(builtins, name):
                    out.add("builtins." + name)
                else:
                    complete = False
                break
            held = self.in_handler(o, name, at)
            sites = held if held is not None else o.sites.get(name, [])
            if len(sites) > 1:
                complete = False
            for site in sites:
                got, ok = self._site_value(site, name)
                out |= got
                complete &= ok
            if held is not None:
                break  # inside `except E as NAME`: the exception, or what the handler bound since (#4769 F1)
            if o.stars:
                out |= self._stars(o, name)
                complete = False
            if sites and (o.kind != "class" or self.bound_before(o, name, at)):
                break  # a class body's read sees the module's binding only while the class has not bound it yet
            if o.kind in FUNCTION_LIKE:
                complete = complete and bool(sites)
                break
        return out, complete

    def bound_before(self, cls, name, at):
        """True when the read AT, evaluated in class body CLS, surely runs after CLS bound NAME: a binding of it that
        surely ran once its top-level statement of the body finished (sure_sites()) comes before the read's
        statement, and nothing that unbinds NAME (unbinds(): a `del NAME`, an `except ... as NAME` handler) from that
        statement up to the read's may have unbound it. Anything else (no
        read node, a binding under an if, try, loop or match, a for target, a walrus on a short-circuit branch)
        may leave NAME unbound in the class when the read runs, so the read may still see the module's.
        Every binding form is judged by one rule, not by a list of statement kinds (LW#4710 F1: `os += ()` and
        `(os := None)` were missed)."""
        if at is None or self.scope_of(at) is not cls:
            return False
        if not hasattr(self, "_body_index"):
            self._body_index = {}
        index = self._body_index.get(id(cls))
        if index is None:
            index = self._body_index[id(cls)] = {}
            for i, stmt in enumerate(cls.node.body):
                for n in ast.walk(stmt):
                    index.setdefault(id(n), i)
        read = index.get(id(at))
        if read is None:
            return False
        sites = cls.sites.get(name, [])
        dels = [index.get(id(s), -1) for s in sites if self.unbinds(s)]
        body = cls.node.body
        for site in sites:
            i = index.get(id(site))
            if i is None or i >= read or any(i <= d <= read for d in dels):
                continue
            if any(s is site for s in self.sure_sites(body[i])):
                return True
        return False

    def in_handler(self, scope, name, at):
        """The binding sites a read of NAME at AT sees when AT runs inside the body of an `except E as NAME` handler
        of SCOPE (evaluated in SCOPE itself, or in a list, set or dict comprehension there): that handler, which
        holds the exception, and the sites of NAME in its body, which may have rebound it since. None when AT is in
        no such handler. Python binds NAME as the handler starts and deletes it as it ends, so a read in the handler
        never sees what NAME held before the try, nor anything outside the handler; a read after the try still sees
        those (unbinds(), bound_before()). The innermost handler of that name wins. The handler's type expression runs
        before the bind and is not its body (#4769 F1: `except E as os: os.kill(...)` read the imported os)."""
        if at is None or scope is BUILTINS:
            return None
        s = self.scope_of(at)
        while s is not scope and s is not None and (s.inlined or (s.kind == "comprehension"
                                                                    and not isinstance(s.node, ast.GeneratorExp))):
            s = s.parent  # a list, set or dict comprehension runs where it stands; a generator may run later
        if s is not scope:
            return None
        handlers = [h for h in scope.sites.get(name, ()) if isinstance(h, ast.ExceptHandler)]
        if not handlers:
            return None
        if not hasattr(self, "_handler_body"):
            self._handler_body = {}
        best = None
        for h in handlers:
            body = self._handler_body.get(id(h))
            if body is None:
                body = self._handler_body[id(h)] = {id(n) for stmt in h.body for n in ast.walk(stmt)}
            if id(at) in body and (best is None or len(body) < len(best[1])):
                best = (h, body)
        if best is None:
            return None
        h, body = best
        return [h] + [site for site in scope.sites.get(name, ()) if site is not h and id(site) in body]

    @staticmethod
    def unbinds(site):
        """True when binding site SITE may leave its name unbound once it ran: `del NAME`, and an `except E as NAME`
        handler, which Python ends with an implicit `del NAME` (so a handler that ran, surely or maybe, leaves NAME
        unbound, or possibly unbound, after its try statement whatever bound it before; #4755 F1)."""
        return (isinstance(site, ast.Name) and isinstance(site.ctx, ast.Del)) or isinstance(site, ast.ExceptHandler)

    @classmethod
    def sure_sites(cls, stmt):
        """The binding sites in STMT that have surely run once STMT finished normally: what a later statement of
        the same block may count on. A def's or class's or type alias's name; an import's aliases; every Name of
        an assignment's targets (nested tuples and starred ones included), an augmented assignment's target, an
        annotated assignment's target when it has a value; the Name a with statement's first item binds (a tuple
        target may fail to unpack and a suppressing __exit__ hides that; a later item's context may fail the same
        way); and a walrus that runs whenever STMT does (sure_walruses()). Never a for target (the loop may run zero
        times), a match capture (another case may match), an except name or anything in a block of a compound
        statement, nor a del."""
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            return [stmt]
        if _TYPE_ALIAS and isinstance(stmt, _TYPE_ALIAS):
            return [stmt.name]
        if isinstance(stmt, (ast.Import, ast.ImportFrom)):
            return [a for a in stmt.names if a.name != "*"]
        out, exprs = [], []
        if isinstance(stmt, ast.Assign):
            out += [n for t in stmt.targets for n in cls._target_names(t)]
            exprs = [stmt.value]
        elif isinstance(stmt, ast.AugAssign):
            out += cls._target_names(stmt.target)
            exprs = [stmt.value]
        elif isinstance(stmt, ast.AnnAssign) and stmt.value is not None:
            out += cls._target_names(stmt.target)
            exprs = [stmt.value]
        elif isinstance(stmt, (ast.With, ast.AsyncWith)) and stmt.items:
            first = stmt.items[0]
            if isinstance(first.optional_vars, ast.Name):
                out.append(first.optional_vars)
            exprs = [first.context_expr]
        elif isinstance(stmt, ast.Expr):
            exprs = [stmt.value]
        elif isinstance(stmt, (ast.If, ast.While)):
            exprs = [stmt.test]
        elif isinstance(stmt, (ast.For, ast.AsyncFor)):
            exprs = [stmt.iter]
        elif type(stmt).__name__ == "Match":
            exprs = [stmt.subject]
        for e in exprs:
            out += cls.sure_walruses(e)
        return out

    @staticmethod
    def _target_names(target):
        """The Name nodes an assignment to TARGET binds: itself, or every Name in a tuple or list target, through
        nesting and a starred element; an attribute or subscript target binds none."""
        if isinstance(target, ast.Name):
            return [target]
        if isinstance(target, ast.Starred):
            return Resolver._target_names(target.value)
        if isinstance(target, (ast.Tuple, ast.List)):
            return [n for e in target.elts for n in Resolver._target_names(e)]
        return []

    @staticmethod
    def sure_walruses(expr):
        """The targets of the walruses in EXPR that run whenever EXPR is evaluated in full: not on a short-circuit
        branch (an `and`/`or` operand after the first, a chained comparison's later operands, an if-expression's
        arms) and not in a nested scope (a lambda, a comprehension)."""
        out, todo = [], [expr]
        while todo:
            n = todo.pop()
            if isinstance(n, ast.NamedExpr):
                out.append(n.target)
                todo.append(n.value)
            elif isinstance(n, ast.BoolOp):
                todo.append(n.values[0])
            elif isinstance(n, ast.Compare):
                todo += [n.left, n.comparators[0]]
            elif isinstance(n, ast.IfExp):
                todo.append(n.test)
            elif isinstance(n, (ast.Lambda,) + COMPREHENSIONS):
                continue
            else:
                todo.extend(ast.iter_child_nodes(n))
        return out

    def _stars(self, scope, name):
        out = set()
        for module in scope.stars:
            out |= set(self.star(module, name)) if self.star and module else set()
        return out

    def _site_value(self, site, name):
        key = (id(site), name)
        if key in self._memo:
            return self._memo[key]
        if key in self._busy:
            return set(), False
        self._busy.add(key)
        try:
            got = self._compute(site, name)
        finally:
            self._busy.discard(key)
        self._memo[key] = got
        return got

    def _compute(self, site, name):
        if isinstance(site, ast.alias):
            imp = self._import_of(site)
            if isinstance(imp, ast.Import):
                if site.asname:
                    return {site.name}, True
                return {site.name.split(".")[0]}, True
            if isinstance(imp, ast.ImportFrom) and not imp.level and imp.module:
                return {"%s.%s" % (imp.module, site.name)}, True
            return set(), False
        if isinstance(site, ast.arg):
            d = self.defaults.get(id(site))
            return (self.dotted(d), False) if d is not None else (set(), False)
        if isinstance(site, ast.Name):
            value = self._assigned(site)
            if value is not None:
                return self.dotted_info(value)
        return set(), False

    def _import_of(self, alias):
        if not hasattr(self, "_imports"):
            self._imports = {}
            for n in ast.walk(self.tree):
                if isinstance(n, (ast.Import, ast.ImportFrom)):
                    for a in n.names:
                        self._imports[id(a)] = n
        return self._imports.get(id(alias))

    def _assigned(self, target):
        """The value a Name target is bound to when it is a whole target (x = v, x: T = v, (x := v)), else None."""
        if not hasattr(self, "_values_at"):
            self._values_at = {}
            for n in ast.walk(self.tree):
                if isinstance(n, ast.Assign):
                    for t in n.targets:
                        if isinstance(t, ast.Name):
                            self._values_at[id(t)] = n.value
                elif isinstance(n, (ast.AnnAssign, ast.NamedExpr)) and isinstance(n.target, ast.Name) \
                        and n.value is not None:
                    self._values_at[id(n.target)] = n.value
        return self._values_at.get(id(target))

    def dotted(self, node):
        """Every dotted path NODE may name ("os.kill", "signal.SIGKILL", "os"); empty when none is known. An attribute
        the source picks at run time (getattr(os, name)) is "os.*": any of them."""
        return self.dotted_info(node)[0]

    def dotted_info(self, node):
        """The dotted paths NODE may name and whether its source binding is complete."""
        if isinstance(node, ast.Name):
            return self.values(node, node.id)
        if isinstance(node, ast.NamedExpr):  # (probe := os.kill)(p, 0): the walrus is its value
            return self.dotted_info(node.value)
        if isinstance(node, ast.Attribute):
            base, complete = self.dotted_info(node.value)
            return ({"%s.%s" % (b, node.attr) for b in base if not b.endswith(".*")} | \
                    {b for b in base if b.endswith(".*")}), complete
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            func, func_complete = self.values(node.func, node.func.id)
            if "builtins.getattr" in func and len(node.args) >= 2:
                bases, base_complete = self.dotted_info(node.args[0])
                bases = {b for b in bases if not b.endswith(".*")}
                attr = node.args[1]
                if isinstance(attr, ast.Constant) and isinstance(attr.value, str):
                    return {"%s.%s" % (b, attr.value) for b in bases}, func_complete and base_complete
                return {"%s.*" % b for b in bases}, func_complete and base_complete
            if ("builtins.__import__" in func and node.args and isinstance(node.args[0], ast.Constant)
                    and isinstance(node.args[0].value, str)):
                module = node.args[0].value
                fromlist = next((kw.value for kw in node.keywords if kw.arg == "fromlist"), None)
                if len(node.args) >= 4:
                    fromlist = node.args[3]
                if fromlist is None:
                    return {module.split(".")[0]}, func_complete
                if isinstance(fromlist, (ast.List, ast.Tuple, ast.Set)) and not fromlist.elts:
                    return {module.split(".")[0]}, func_complete
                if isinstance(fromlist, (ast.List, ast.Tuple, ast.Set)) and not any(
                        isinstance(item, ast.Starred) for item in fromlist.elts):
                    return {module}, func_complete
                return {module.split(".")[0]}, False
        return set(), False
