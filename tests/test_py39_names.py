#!/usr/bin/env python3
"""What the git hooks install runs on Python 3.9, macOS's /usr/bin/python3.

install-git-hooks.sh installs with whichever python3 resolves; on a Mac that is /usr/bin/python3, 3.9.6. cmux#41827
review: check-test-redefinitions.py named `ast.match_case` (3.10+), which raised AttributeError on 3.9 for every
ordinary tests/ file, so the pre-push gate refused clean pushes as no verdict. A newer Python parses and runs that
file fine, so only a real 3.9 sees it.

The files are what install-git-hooks.sh installs: scripts/cmux-next's tracked .py (its own, lint/ and arch_rules/,
the COPY_CHECKERS set) and every scripts/**/*.py the installer names. UnderPython39 checks, with a real 3.9:
- each file parses under it (a `match` statement, a PEP 701 f-string, `except*`);
- each stdlib module the files import and each stdlib name they read (a load; `mod.name = x` reads nothing) is one
  3.9 has, or the read is guarded (below). Attribute presence is probed separately from a same-named submodule's
  importability, and a shadowed module alias is unknown. Ported from cmuxterm-hq's tests/test_py39_names.py (the same
  scan for hq's and leo-workspace's tools), with its guards;
- no `X | Y` annotation runs when a def or a module/class body runs, in a file without
  `from __future__ import annotations` (TypeError on 3.9), and no `zip(..., strict=...)` (TypeError on 3.9);
- check-test-redefinitions.py's suite passes under the 3.9.
A guard keeps 3.9 off the code it protects, and only that code:
- an `if`/`while`/conditional whose test 3.9 can be read for: `hasattr(M, "N")` of a stdlib module (whether the
  3.9 probe found M.N), `getattr(M, "N", default)` of a name 3.9 lacks (the literal default), or `sys.version_info`
  compared with a literal (evaluated as 3.9.0), joined by `not`/`and`/`or`. A False test protects the body, a True
  one the `else`; any other test is unknown and protects nothing;
- in an `and`, an earlier operand that is False on 3.9; in an `or`, an earlier one that is True. A later operand
  protects nothing;
- a `try` body whose handler catches AttributeError or ImportError (its `else` and `finally` are not protected);
- a statement after an `if` whose 3.9 branch always leaves (ends in return, raise, sys.exit or os.exec*);
- unittest's `skipIf`/`skipUnless` that skips the enclosing def or class on 3.9; `getattr(MOD, "NAME", default)`.
A name 3.9 gained in a security release (BACKPORTED: the tar filters) counts as missing: a Mac's 3.9 is 3.9.6.
A file a hook never runs that needs a newer Python goes in EXCLUDED with its reason.

The 3.9 is $PY39, else python3.9 or /usr/bin/python3 when either is 3.9, else uv's managed 3.9 (installed when
missing; uv itself from pip into a cache venv when the machine has none). With none to be had the test fails rather
than pass unchecked. Run it on the fleet: `python3 tests/test_py39_names.py` (CLAUDE.md: no new CI tests).
"""

import ast
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
# Load beside this suite even under python -I; no runtime/install dependency on another repository.
_scope_spec = importlib.util.spec_from_file_location("py39_scope_resolver", HERE / "py39_scope_resolver.py")
scope_resolver = importlib.util.module_from_spec(_scope_spec)
_scope_spec.loader.exec_module(scope_resolver)
INSTALLER = "scripts/install-git-hooks.sh"
COPIED = re.compile(r"^scripts/cmux-next/(?:[^/]+|lint/.+|arch_rules/.+)\.py$")  # install-git-hooks.sh COPY_CHECKERS
NAMED = re.compile(r"\bscripts/[\w./-]+\.py\b")
PY39 = (3, 9)
# In CPython 3.9 on Linux, but only when the build saw the kernel headers for them; a managed 3.9 built on an older
# glibc lacks them, and on a Mac they never exist, so code reaches them only behind its own platform check.
PLATFORM_ONLY = {("os", "pidfd_open"), ("signal", "pidfd_send_signal"), ("os", "memfd_create")}
PLATFORM_PREFIX = (("os", "MFD_"),)
GUARD_CALLS = {"hasattr", "getattr"}
# Names 3.9 gained in a security release (PEP 706's tar filters, 3.9.17) that the Mac's /usr/bin/python3 (3.9.6)
# lacks, so a newer 3.9 that has them still counts them as missing.
BACKPORTED = {("tarfile", n) for n in ("data_filter", "tar_filter", "fully_trusted_filter", "FilterError",
                                       "AbsolutePathError", "OutsideDestinationError", "SpecialFileError",
                                       "AbsoluteLinkError", "LinkOutsideDestinationError", "LinkFallbackError")}
# Files the scan skips, each with its reason: one documented as 3.11+ only, or a frozen copy whose live version is
# checked where it lives.
EXCLUDED = {  # path: why no hook runs it, so macOS's 3.9 never does
    "scripts/cmux-next/herdr-sync.py": "a vendor sync run by hand with 3.11+ (tomllib, datetime.UTC); no hook runs it",
    "scripts/cmux-next/browser-host-release.py": "cmux-browser-host's release job runs it with CI's 3.11+ (tomllib); "
                                                 "no hook runs it",
}
CAUGHT = {"AttributeError", "ImportError", "ModuleNotFoundError", "Exception", "BaseException"}


def _files():
    """What install-git-hooks.sh installs: scripts/cmux-next's tracked .py (COPY_CHECKERS) and each
    scripts/**/*.py the installer names."""
    listed = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", "scripts/cmux-next"],
                            capture_output=True, check=True).stdout.decode("utf-8", "surrogateescape").split("\0")
    names = {name for name in listed if COPIED.match(name)}
    for line in (ROOT / INSTALLER).read_text(encoding="utf-8").splitlines():
        if not line.lstrip().startswith("#"):  # a comment names a file it does not install
            names |= set(NAMED.findall(line))
    return [ROOT / name for name in sorted(names) if (ROOT / name).is_file()]


# What 3.9 reports for the version a guard tests: the tuple, and its fields by name.
V39 = (3, 9, 0, "final", 0)
V39_FIELDS = {"major": 3, "minor": 9, "micro": 0}


def _version_value(expr):
    """The value EXPR has on 3.9 when it reads sys.version_info (whole, sliced, indexed or a field), else None."""
    if isinstance(expr, ast.Attribute) and expr.attr == "version_info":
        return V39
    if isinstance(expr, ast.Name) and expr.id == "version_info":
        return V39
    if isinstance(expr, ast.Attribute) and expr.attr in V39_FIELDS and _version_value(expr.value) == V39:
        return V39_FIELDS[expr.attr]
    if isinstance(expr, ast.Subscript) and _version_value(expr.value) == V39:
        sl = expr.slice.value if isinstance(expr.slice, getattr(ast, "Index", ())) else expr.slice
        try:
            if isinstance(sl, ast.Slice):
                parts = [None if x is None else ast.literal_eval(x) for x in (sl.lower, sl.upper, sl.step)]
                return V39[slice(*parts)]
            return V39[ast.literal_eval(sl)]
        except (ValueError, TypeError, IndexError):
            return None
    return None


_CMP = {ast.Lt: lambda a, b: a < b, ast.LtE: lambda a, b: a <= b, ast.Gt: lambda a, b: a > b,
        ast.GtE: lambda a, b: a >= b, ast.Eq: lambda a, b: a == b, ast.NotEq: lambda a, b: a != b}


# What _on39 knows of the file and the 3.9 it reads a hasattr/getattr for: the file's stdlib aliases (set by
# sites() and runtime_sites() per file), and the (module, name) pairs unguarded() probed in the 3.9 with the ones it
# lacks. Attribute presence and submodule importability are separate probes; a pair it did not probe is unknown.
_SCOPE = {"alias": {}, "probed": set(), "attr_lacks": set(), "import_lacks": set()}


class _LexicalAliases:
    """Stdlib imports as seen at each read, using the compiler-backed lexical resolver."""

    def __init__(self, tree):
        self.resolver = scope_resolver.Resolver(tree)
        std = set(getattr(sys, "stdlib_module_names", ()))
        self.modules = {a.name if a.asname else a.name.split(".")[0]
                        for n in ast.walk(tree) if isinstance(n, ast.Import)
                        for a in n.names if a.name.split(".")[0] in std}

    def modules_at(self, node):
        values, _ = self.resolver.values(node, node.id)
        return values & self.modules

    def for_name(self, node):
        values, complete = self.resolver.values(node, node.id)
        return next(iter(values)) if complete and len(values) == 1 and values <= self.modules else None


def _aliases(tree):
    return _LexicalAliases(tree)


def _guard_pair(expr):
    """(module, name) when EXPR is hasattr(M, "N") or getattr(M, "N", ...) of a stdlib module alias, else None."""
    if (isinstance(expr, ast.Call) and isinstance(expr.func, ast.Name) and expr.func.id in GUARD_CALLS
            and len(expr.args) >= 2 and isinstance(expr.args[0], ast.Name)
            and isinstance(expr.args[1], ast.Constant) and isinstance(expr.args[1].value, str)):
        module = _SCOPE["alias"].for_name(expr.args[0])
        if module is not None:
            return module, expr.args[1].value
    return None


def _attr_on39(expr):
    """What hasattr/getattr EXPR is on 3.9, from the probe: hasattr is whether 3.9 has the name; getattr of a name
    3.9 lacks is its literal default. Anything else (an object not a stdlib module, a name not probed, one only
    some platforms have, getattr of a name 3.9 has) is None: the scan cannot say."""
    pair = _guard_pair(expr)
    if pair is None or pair not in _SCOPE["probed"] or pair in PLATFORM_ONLY or any(
            pair[0] == pm and pair[1].startswith(pre) for pm, pre in PLATFORM_PREFIX):
        return None
    missing = pair in _SCOPE["attr_lacks"]
    if expr.func.id == "hasattr":
        return not missing
    if not missing or len(expr.args) < 3:
        return None
    try:
        return bool(ast.literal_eval(expr.args[2]))
    except (ValueError, TypeError, SyntaxError, RecursionError):
        return None


def _on39(expr):
    """What a guard test EXPR is on 3.9: True, False, or None when it is not a guard this scan can read.

    `hasattr(M, "N")` is whether 3.9 has M.N, and `getattr(M, "N", default)` of a name 3.9 lacks is the default
    (_attr_on39; cmux#41827 review: every hasattr/getattr was False, so `if hasattr(sys, "version_info"):` hid what
    it protects); a comparison of sys.version_info with a literal is evaluated against 3.9.0; `not`, `and` and `or`
    combine those."""
    if isinstance(expr, ast.Call) and isinstance(expr.func, ast.Name) and expr.func.id in GUARD_CALLS:
        return _attr_on39(expr)
    if isinstance(expr, ast.UnaryOp) and isinstance(expr.op, ast.Not):
        inner = _on39(expr.operand)
        return None if inner is None else not inner
    if isinstance(expr, ast.BoolOp):
        vals = [_on39(v) for v in expr.values]
        short = isinstance(expr.op, ast.Or)  # `or` is decided by a True, `and` by a False
        if short in vals:
            return short
        return None if None in vals else not short
    if isinstance(expr, ast.Compare):
        left = expr.left
        for op, right in zip(expr.ops, expr.comparators):
            a, b = _version_value(left), _version_value(right)
            if (a is None) is (b is None) or type(op) not in _CMP:
                return None  # a guard compares sys.version_info with a literal
            try:
                a = ast.literal_eval(left) if a is None else a
                b = ast.literal_eval(right) if b is None else b
                if not _CMP[type(op)](a, b):
                    return False
            except (ValueError, TypeError, SyntaxError, RecursionError):
                return None
            left = right
        return True
    return None


def _ends(stmts):
    """True when the block STMTS always leaves at its last statement: a return, raise, sys.exit, os._exit, os.exec*."""
    last = stmts[-1] if stmts else None
    if isinstance(last, (ast.Raise, ast.Return)):
        return True
    if isinstance(last, ast.Expr) and isinstance(last.value, ast.Call):
        f = last.value.func
        name = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
        return name in ("exit", "_exit") or name.startswith("exec")
    return False


def _gated(block, child):
    """True when a statement before CHILD in BLOCK is an `if` that 3.9 always leaves the scope in (devbuild's
    `if sys.version_info < (3, 11): ... raise SystemExit(...)`): 3.9 never reaches CHILD."""
    for stmt in block:
        if stmt is child:
            return False
        if isinstance(stmt, ast.If):
            on39 = _on39(stmt.test)
            if (on39 is True and _ends(stmt.body)) or (on39 is False and _ends(stmt.orelse)):
                return True
    return False


def _skip_decorated(node):
    """True when a unittest skipIf/skipUnless on NODE skips it on 3.9."""
    for d in getattr(node, "decorator_list", ()):
        if not (isinstance(d, ast.Call) and d.args):
            continue
        name = d.func.attr if isinstance(d.func, ast.Attribute) else getattr(d.func, "id", "")
        if name in ("skipIf", "skipUnless") and _on39(d.args[0]) is (name == "skipIf"):
            return True
    return False


def _catches(handler):
    t = handler.type
    if t is None:
        return True
    names = t.elts if isinstance(t, ast.Tuple) else [t]
    return any((n.id if isinstance(n, ast.Name) else getattr(n, "attr", "")) in CAUGHT for n in names)


def _parents(tree):
    parent = {}
    for n in ast.walk(tree):
        for c in ast.iter_child_nodes(n):
            parent[id(c)] = n
    return parent


def _guarded(node, parent):
    """True when 3.9 never runs NODE: it sits on the branch, or after the operand, that a guard closes there."""
    child, n = node, parent.get(id(node))
    while n is not None:
        if isinstance(n, (ast.If, ast.While, ast.IfExp)) and child is not n.test:
            on39 = _on39(n.test)
            body = n.body if isinstance(n.body, list) else [n.body]
            if on39 is not None and (any(child is b for b in body)) is (not on39):
                return True
        if isinstance(n, ast.BoolOp):
            at = next(i for i, v in enumerate(n.values) if v is child)
            stop = isinstance(n.op, ast.Or)  # an earlier operand of this value ends the chain before it
            if any(_on39(v) is stop for v in n.values[:at]):
                return True
        if isinstance(n, ast.Try) and any(child is b for b in n.body) and any(_catches(h) for h in n.handlers):
            return True
        if (isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
                and any(child is b for b in n.body) and _skip_decorated(n)):
            return True
        for field in ("body", "orelse", "finalbody"):
            block = getattr(n, field, None)
            if isinstance(block, list) and any(child is b for b in block) and _gated(block, child):
                return True
        child, n = n, parent.get(id(n))
    return False


def sites(path):
    """[(module, name, line, guarded)] for each import of a stdlib module (name None) and each read of a stdlib
    module's top-level name in PATH. Only a load is a read: `mod.name = x` and `del mod.name` read nothing."""
    try:
        tree = ast.parse(path.read_bytes(), str(path))
    except (SyntaxError, ValueError):
        return []  # a file 3.9 cannot parse is py39_check's to report
    std = set(getattr(sys, "stdlib_module_names", ()))
    try:
        alias = _SCOPE["alias"] = _aliases(tree)
    except scope_resolver.ScopeResolutionError as exc:
        raise AssertionError("%s: scope resolution refused: %s" % (path, exc)) from exc
    parent = _parents(tree)

    def guarded(node):
        return _guarded(node, parent)

    out = []
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            for a in n.names:
                if a.name.split(".")[0] in std:
                    out.append((a.name, None, n.lineno, guarded(n), "import"))
        elif isinstance(n, ast.ImportFrom) and n.module and not n.level and n.module.split(".")[0] in std:
            out.append((n.module, None, n.lineno, guarded(n), "import"))
            for a in n.names:
                out.append((n.module, a.name, n.lineno, guarded(n), "import"))
        elif (isinstance(n, ast.Attribute) and isinstance(n.ctx, ast.Load) and isinstance(n.value, ast.Name)):
            for module in sorted(alias.modules_at(n.value)):
                out.append((module, n.attr, n.lineno, guarded(n), "attr"))
    return out


def guard_pairs(path):
    """{(module, name)} for each hasattr/getattr of a stdlib module's name in PATH: what the probe must ask 3.9."""
    try:
        tree = ast.parse(path.read_bytes(), str(path))
    except (SyntaxError, ValueError):
        return set()
    try:
        _SCOPE["alias"] = _aliases(tree)
    except scope_resolver.ScopeResolutionError as exc:
        raise AssertionError("%s: scope resolution refused: %s" % (path, exc)) from exc
    return {pair for n in ast.walk(tree) for pair in [_guard_pair(n)] if pair is not None}


def runtime_sites(path):
    """["path:line: what"] for each 3.10+ runtime form in PATH that 3.9 runs: an `X | Y` annotation a def or a
    module/class body evaluates (no `from __future__ import annotations`), or an unguarded `zip(..., strict=...)`."""
    try:
        tree = ast.parse(path.read_bytes(), str(path))
    except (SyntaxError, ValueError):
        return []
    rel = path.relative_to(ROOT).as_posix()
    _SCOPE["alias"] = _aliases(tree)
    parent = _parents(tree)
    out = []
    future = any(isinstance(n, ast.ImportFrom) and n.module == "__future__" and
                 any(a.name == "annotations" for a in n.names) for n in tree.body)
    if not future:
        notes = []
        for n in ast.walk(tree):
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
                a = n.args
                notes += [x.annotation for x in a.posonlyargs + a.args + a.kwonlyargs + [a.vararg, a.kwarg]
                          if x is not None and x.annotation is not None]
                notes += [n.returns] if n.returns is not None else []
            if isinstance(n, (ast.Module, ast.ClassDef)):
                notes += [x.annotation for x in n.body if isinstance(x, ast.AnnAssign)]
        for note in notes:
            union = next((x for x in ast.walk(note) if isinstance(x, ast.BinOp) and isinstance(x.op, ast.BitOr)), None)
            if union is not None and not _guarded(note, parent):
                out.append("%s:%d: X | Y annotation (TypeError on 3.9; add `from __future__ import annotations`)"
                           % (rel, union.lineno))
    for n in ast.walk(tree):
        if (isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "zip"
                and any(k.arg == "strict" for k in n.keywords) and not _guarded(n, parent)):
            out.append("%s:%d: zip(strict=) (TypeError on 3.9)" % (rel, n.lineno))
    return out


PARSE = r"""
import ast, sys
for path in sys.stdin.read().splitlines():
    try:
        ast.parse(open(path, "rb").read(), path)
    except (SyntaxError, ValueError) as e:
        print("%s:%s: does not parse under Python 3.9: %s" % (path, getattr(e, "lineno", None) or 1, getattr(e, "msg", e)))
"""


def unparsed(python, files=None):
    """["path:line: ..."] for each file PYTHON (a 3.9) cannot parse."""
    files = list(files if files is not None else _files())
    out = subprocess.run([python, "-I", "-c", PARSE], input="\n".join(str(p) for p in files), capture_output=True,
                         text=True, timeout=600)
    if out.returncode != 0:
        raise AssertionError("the 3.9 parse failed: " + out.stderr[-2000:])
    return [line.replace(str(ROOT) + "/", "", 1) for line in out.stdout.splitlines()]


LACKS = r"""
import importlib, json, sys
missing = []
for module, name in json.load(sys.stdin):
    try:
        mod = importlib.import_module(module)
    except Exception:
        if name is None:
            missing.append([module, name, True, True])
        continue
    if name is None:
        continue
    attr_missing = not hasattr(mod, name)
    import_missing = False
    if attr_missing:
        try:
            importlib.import_module(module + "." + name)
        except Exception:
            import_missing = True
    if attr_missing or import_missing:
        missing.append([module, name, attr_missing, import_missing])
print(json.dumps(missing))
"""


def _here_has(module, name):
    """True when this Python has MODULE (and NAME in it): a name a newer stdlib added, not one no stdlib has here."""
    try:
        __import__(module)
        if name is not None and not hasattr(sys.modules[module], name):
            __import__(module + "." + name)
    except Exception:
        return False
    return True


def _version(python):
    out = subprocess.run([python, "-c", "import sys; print(*sys.version_info[:2])"], capture_output=True, text=True)
    return tuple(int(x) for x in out.stdout.split()) if out.returncode == 0 else None


def _uv():
    """uv: on PATH, else from pip into a venv of its own under the user's cache (a runner's system pip is externally
    managed, and an older pip has no --break-system-packages)."""
    if shutil.which("uv"):
        return [shutil.which("uv")]
    venv = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "cmux-py39" / "uv-venv"
    uv = venv / "bin" / "uv"
    if not uv.is_file():
        subprocess.run([sys.executable, "-m", "venv", str(venv)], capture_output=True, timeout=300)
        subprocess.run([str(venv / "bin" / "python"), "-m", "pip", "install", "-q", "--disable-pip-version-check",
                        "uv"], capture_output=True, timeout=600)
    return [str(uv)] if uv.is_file() else None


def python39():
    """The path of a Python 3.9, or None."""
    for cand in (os.environ.get("PY39"), shutil.which("python3.9"), "/usr/bin/python3"):
        if cand and _version(cand) == PY39:
            return cand
    uv = _uv()
    if not uv:
        return None
    found = subprocess.run(uv + ["python", "find", "3.9"], capture_output=True, text=True, timeout=120)
    if found.returncode != 0:
        subprocess.run(uv + ["python", "install", "3.9"], capture_output=True, timeout=600)
        found = subprocess.run(uv + ["python", "find", "3.9"], capture_output=True, text=True, timeout=120)
    path = found.stdout.strip().splitlines()[-1] if found.returncode == 0 and found.stdout.strip() else None
    return path if path and _version(path) == PY39 else None


def unguarded(python, files=None):
    """["path:line: module.name"] for each unguarded read of a stdlib name PYTHON lacks and this Python has."""
    files = list(files if files is not None else _files())
    # The probe first: what a hasattr/getattr guard is on 3.9 depends on whether 3.9 has the name it tests.
    _SCOPE["probed"], _SCOPE["attr_lacks"], _SCOPE["import_lacks"] = set(), set(), set()
    names = {(m, a) for p in files for (m, a, _, _, _) in sites(p)} | {pair for p in files for pair in guard_pairs(p)}
    names = sorted(names, key=lambda x: (x[0], x[1] or ""))
    out = subprocess.run([python, "-I", "-c", LACKS], input=json.dumps(names), capture_output=True, text=True,
                         timeout=300)
    if out.returncode != 0:
        raise AssertionError("the 3.9 probe failed: " + out.stderr[-2000:])
    missing = json.loads(out.stdout)
    _SCOPE["probed"] = set(names)
    _SCOPE["attr_lacks"] = {tuple(x[:2]) for x in missing if x[2]} | BACKPORTED
    _SCOPE["import_lacks"] = {tuple(x[:2]) for x in missing if x[3]} | BACKPORTED
    found = [(p, s) for p in files for s in sites(p)]
    bad = []
    for p, (m, a, line, ok, kind) in found:
        # A direct `module.name` read is also satisfied by an importable submodule (`http.client`); only guard
        # evaluation above needs the attribute-presence probe to distinguish that case.
        lacks = _SCOPE["import_lacks"]
        if ok or (m, a) not in lacks or (m, a) in PLATFORM_ONLY or (a is not None and any(
                m == pm and a.startswith(pre) for pm, pre in PLATFORM_PREFIX)):
            continue
        if not _here_has(m, a):
            continue  # this Python lacks it too: not a name a newer stdlib added
        rel = p.relative_to(ROOT).as_posix()
        if rel in EXCLUDED:
            continue
        bad.append("%s:%d: %s" % (rel, line, m if a is None else m + "." + a))
    return bad


class UnderPython39(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.python = python39()
        if cls.python is None:
            raise AssertionError("no Python 3.9 found or installable (set PY39, or install uv); refusing to pass the "
                                 "files a Mac runs with 3.9 unchecked")

    def test_every_stdlib_name_3_9_lacks_is_read_behind_a_guard(self):
        bad = unguarded(self.python)
        self.assertEqual(bad, [], "Python 3.9 lacks these names and nothing guards the read; use "
                                  "getattr(MOD, NAME, default), or a hasattr / sys.version_info test:\n"
                         + "\n".join(bad))

    def test_every_hook_file_parses_under_python_3_9(self):
        bad = unparsed(self.python)
        self.assertEqual(bad, [], "\n".join(bad))

    def test_no_hook_file_runs_a_3_10_form(self):
        bad = [line for p in _files() if p.relative_to(ROOT).as_posix() not in EXCLUDED for line in runtime_sites(p)]
        self.assertEqual(bad, [], "\n".join(bad))

    def test_the_redefinition_checker_suite_passes_under_python_3_9(self):
        # cmux#41827 review: the checker's suite, run by a real 3.9 (the reviewer's row: a 3.9 run on a plain file).
        out = subprocess.run([self.python, "-I", str(HERE / "test_check_test_redefinitions.py"), "-v"],
                             capture_output=True, text=True, timeout=1800, cwd=ROOT)
        self.assertEqual(out.returncode, 0, "under %s:\n%s" % (self.python, (out.stdout + out.stderr)[-6000:]))
        self.assertRegex(out.stderr, r"\nRan [1-9]", "no test ran")

    def test_the_runtime_scan_sees_each_3_10_form(self):
        import tempfile
        global ROOT
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "probe.py"
            p.write_text("import sys\n"
                         "def f(x: int | None) -> None:\n    pass\n"
                         "def g():\n    y: int | None = None\n    return y\n"
                         "pairs = zip([1], [2], strict=True)\n"
                         "if sys.version_info >= (3, 10):\n    ok = zip([1], [2], strict=True)\n")
            old, ROOT = ROOT, Path(d)
            try:
                got = runtime_sites(p)
                q = Path(d) / "future.py"
                q.write_text("from __future__ import annotations\ndef f(x: int | None) -> None:\n    pass\n")
                self.assertEqual(runtime_sites(q), [])
            finally:
                ROOT = old
        self.assertEqual([line.split(":")[1] for line in got], ["2", "7"], got)

    def test_match_case_reads_as_bare_and_its_getattr_as_guarded(self):
        """cmux#41827: check-test-redefinitions.py's tuple, and the fix."""
        self.scan("import ast\n"
                  "a = (ast.stmt, ast.excepthandler, ast.match_case)  # bare: ast.match_case\n"
                  "b = (ast.stmt, ast.excepthandler, getattr(ast, 'match_case', ()))\n")

    def scan(self, text):
        """unguarded() on TEXT as probe.py, against what each `# bare: X` comment says its line reports."""
        import re
        import tempfile
        global ROOT
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "probe.py"
            p.write_text(text)
            old, ROOT = ROOT, Path(d)
            try:
                got = unguarded(self.python, [p])
            finally:
                ROOT = old
        want = ["probe.py:%d: %s" % (i, name) for i, line in enumerate(text.splitlines(), 1)
                for m in re.finditer(r"# bare: (.*)", line) for name in m.group(1).split(", ")]
        self.assertTrue(want, "a fixture with nothing bare checks nothing")
        key = lambda s: (int(s.split(":")[1]), s)
        self.assertEqual(sorted(got, key=key), sorted(want, key=key))

    def test_the_scan_sees_each_guard_and_each_bare_read(self):
        self.scan("import ast, sys, contextlib\n"
                  "a = (ast.MatchAs, ast.MatchStar)  # bare: ast.MatchAs, ast.MatchStar\n"
                  "b = getattr(ast, 'MatchAs', ())\n"
                  "if sys.version_info >= (3, 10):\n    c = ast.MatchAs\n"
                  "if hasattr(ast, 'TryStar'):\n    d = ast.TryStar\n"
                  "e = hasattr(sys, 'stdlib_module_names') and sys.stdlib_module_names\n"
                  "try:\n    from typing import ParamSpec\nexcept ImportError:\n    pass\n"
                  "from typing import ParamSpec  # bare: typing.ParamSpec\n"
                  "with contextlib.chdir('/'):  # bare: contextlib.chdir\n    pass\n")

    def test_a_store_or_del_of_a_name_is_no_read(self):
        """lw#4557 F1: test_lane_vm_node's `tarfile.data_filter = saved` restores the name; it reads nothing."""
        self.scan("import contextlib, ast\n"
                  "contextlib.chdir = None\n"
                  "del contextlib.chdir\n"
                  "ast.MatchAs = ast.MatchStar  # bare: ast.MatchStar\n")

    def test_a_name_a_later_3_9_backported_still_counts(self):
        """lw#4557 F2: tarfile.data_filter is in 3.9.17+, not in the Mac's 3.9.6 (codex-review-box's unpack)."""
        self.scan("import tarfile\n"
                  "f = tarfile.data_filter  # bare: tarfile.data_filter\n"
                  "if hasattr(tarfile, 'data_filter'):\n    g = tarfile.data_filter\n"
                  "try:\n    pass\nexcept tarfile.FilterError:  # bare: tarfile.FilterError\n    pass\n")

    def test_an_import_of_a_module_3_9_lacks_is_a_site(self):
        """lw#4557 F3, hq#9647 F2: `import tomllib` (codex-review-box, cmux-next-receipts.py) fails on 3.9."""
        self.scan("import tomllib  # bare: tomllib\n"
                  "import json, tomllib as t  # bare: tomllib\n"
                  "from tomllib import loads  # bare: tomllib\n"
                  "x = tomllib.loads\n"  # the module's import is its one site
                  "try:\n    import tomllib\nexcept ImportError:\n    tomllib = None\n"
                  "try:\n    from tomllib import loads\nexcept ModuleNotFoundError:\n    pass\n"
                  "try:\n    pass\nexcept ImportError:\n    pass\nelse:\n    import tomllib  # bare: tomllib\n"
                  "def f():\n    import tomllib  # bare: tomllib\n"
                  "import zoneinfo, graphlib, json\n")  # 3.9 has these

    def test_a_guard_protects_only_the_branch_3_9_skips(self):
        """lw#4557 F4: the `else` of a positive test, and an operand after the guard, are what 3.9 runs."""
        self.scan("import ast, sys, unittest\n"
                  "if hasattr(ast, 'MatchAs'):\n    pass\nelse:\n    a = ast.MatchAs  # bare: ast.MatchAs\n"
                  "if not hasattr(ast, 'MatchAs'):\n    pass\nelse:\n    b = ast.MatchAs\n"
                  "if sys.version_info < (3, 10):\n    c = ast.MatchAs  # bare: ast.MatchAs\nelse:\n    c = ast.MatchAs\n"
                  "if sys.version_info[:2] >= (3, 10) and sys.platform == 'linux':\n    d = ast.MatchAs\n"
                  "if sys.version_info >= (3, 10) or sys.platform == 'linux':\n    e = ast.MatchAs  # bare: ast.MatchAs\n"
                  "if sys.version_info.minor >= 10 and sys.version_info.major == 3:\n    f = ast.MatchAs\n"
                  "g = hasattr(ast, 'MatchAs') or ast.MatchAs  # bare: ast.MatchAs\n"
                  "h = ast.MatchAs and hasattr(ast, 'MatchAs')  # bare: ast.MatchAs\n"
                  "i = sys.version_info < (3, 10) or ast.MatchAs\n"
                  "j = ast.MatchAs if sys.version_info >= (3, 10) else None\n"
                  "k = None if sys.version_info >= (3, 10) else ast.MatchAs  # bare: ast.MatchAs\n"
                  "if sys.version_info >= (3, 10) or True:\n    l = ast.MatchAs  # bare: ast.MatchAs\n"
                  "if sys.platform == 'darwin':\n    m = ast.MatchAs  # bare: ast.MatchAs\n"
                  "while hasattr(ast, 'MatchAs'):\n    n = ast.MatchAs\n    break\nelse:\n    n = ast.MatchStar  # bare: ast.MatchStar\n"
                  "@unittest." "skipIf(sys.version_info < (3, 10), 'match')\ndef o():\n    return ast.MatchAs\n"
                  "@unittest." "skipUnless(sys.version_info < (3, 10), 'old')\ndef p():\n    return ast.MatchAs  # bare: ast.MatchAs\n"
                  "@unittest." "skipUnless(hasattr(ast, 'MatchAs'), 'match')\ndef q():\n    return ast.MatchAs\n")

    def test_a_hasattr_of_a_name_3_9_has_guards_nothing(self):
        """cmux#41827 review (F1): _on39 read every hasattr/getattr as False on 3.9, so a test of a name 3.9 has
        (True there) hid the 3.10 read under it. A guard is False only for a name 3.9 lacks."""
        self.scan("import ast, sys\n"
                  "if hasattr(sys, 'version_info'):\n    a = ast.match_case  # bare: ast.match_case\n"
                  "if hasattr(ast, 'match_case'):\n    b = ast.match_case\n"
                  "if getattr(sys, 'version_info', None):\n    c = ast.match_case  # bare: ast.match_case\n"
                  "if getattr(ast, 'match_case', None):\n    d = ast.match_case\n"
                  "if hasattr(thing, 'x'):\n    e = ast.match_case  # bare: ast.match_case\n")

    def test_attribute_presence_is_separate_from_submodule_importability(self):
        """cmux#41945 F1: importing importlib.resources succeeds even when the fresh importlib module has no
        `resources` attribute; the 3.9 probe must preserve that distinction for hasattr guards."""
        self.scan("import ast, importlib\n"
                  "if hasattr(importlib, 'resources'):\n"
                  "    pass\n"
                  "else:\n"
                  "    value = ast.match_case  # bare: ast.match_case\n")

    def test_a_shadowed_module_alias_is_unknown(self):
        """cmux#41945 F2: a function parameter shadows an imported module alias, so its guard cannot hide the
        incompatible read in the branch the scanner evaluates for Python 3.9."""
        self.scan("import ast, sys\n"
                  "def check(sys):\n"
                  "    if hasattr(sys, 'version_info'):\n"
                  "        pass\n"
                  "    else:\n"
                  "        value = ast.match_case  # bare: ast.match_case\n")

    def test_assignment_preserves_uncertain_default_binding(self):
        """cmux#42240 F1: an assignment from a default-bound parameter remains uncertain to the guard resolver."""
        self.scan("import ast, sys\n"
                  "def check(candidate=sys):\n"
                  "    alias = candidate\n"
                  "    if hasattr(alias, 'version_info'):\n"
                  "        pass\n"
                  "    else:\n"
                  "        value = ast.match_case  # bare: ast.match_case\n")

    def test_import_call_fromlist_keeps_the_imported_module(self):
        """cmux#42289 F1: __import__ returns the requested submodule when fromlist is nonempty."""
        tree = ast.parse("load = __import__('xml.etree.ElementTree', fromlist=['ElementTree'])\n"
                         "value = load\n")
        resolver = scope_resolver.Resolver(tree)
        read = tree.body[1].value
        values, complete = resolver.values(read, read.id)
        self.assertEqual(values, {"xml.etree.ElementTree"})
        self.assertTrue(complete)

    def test_multiple_callee_bindings_are_not_complete(self):
        """cmux#42289 F2: an ambiguous call cannot certainly return the imported module."""
        tree = ast.parse("from pathlib import Path\n"
                         "load = __import__\n"
                         "load = Path\n"
                         "value = load('sys')\n"
                         "result = value\n")
        resolver = scope_resolver.Resolver(tree)
        read = tree.body[4].value
        values, complete = resolver.values(read, read.id)
        self.assertIn("sys", values)
        self.assertFalse(complete)

    def test_scope_build_failure_refuses_the_file(self):
        """cmux#42289 F3: a deeply nested expression that cannot be unparsed is a named refusal."""
        import tempfile
        global ROOT
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "probe.py"
            p.write_text("value = " + "x + " * 399 + "x\n")
            old = ROOT
            ROOT = Path(d)
            try:
                with self.assertRaisesRegex(AssertionError, r"scope resolution refused"):
                    sites(p)
            finally:
                ROOT = old

    def test_scope_constructor_recursion_is_a_named_refusal(self):
        """Failures while walking the AST must refuse before any binding can be lost."""
        tree = ast.parse("value = " + "x + " * 1499 + "x\n")
        with self.assertRaisesRegex(scope_resolver.ScopeResolutionError, r"scope.*recursion"):
            scope_resolver.Resolver(tree)

    def test_import_as_shadowing_is_lexical(self):
        self.scan("import ast as parser\n"
                  "def shadow(parser):\n    return parser.match_case\n"
                  "value = parser.match_case  # bare: ast.match_case\n")

    def test_from_import_shadowing_is_lexical(self):
        self.scan("import ast\n"
                  "def shadow():\n"
                  "    from sys import version_info as ast\n"
                  "    return ast.match_case\n"
                  "value = ast.match_case  # bare: ast.match_case\n")

    def test_except_as_shadowing_is_lexical(self):
        self.scan("import ast\n"
                  "def shadow():\n"
                  "    try:\n        pass\n"
                  "    except Exception as ast:\n"
                  "        return ast.match_case\n"
                  "value = ast.match_case  # bare: ast.match_case\n")

    def test_match_binding_shadowing_is_lexical(self):
        self.scan("import ast\n"
                  "def shadow(value):\n"
                  "    match value:\n"
                  "        case ast:\n"
                  "            return ast.match_case\n"
                  "value = ast.match_case  # bare: ast.match_case\n")

    def test_del_binding_shadowing_is_lexical(self):
        self.scan("import ast\n"
                  "def shadow():\n"
                  "    del ast\n"
                  "    return ast.match_case\n"
                  "value = ast.match_case  # bare: ast.match_case\n")

    def test_an_exit_gate_protects_what_follows_it(self):
        """devbuild's `if sys.version_info < (3, 11): ... raise SystemExit(...)`, codex-review-box's sys.exit, a return."""
        self.scan("import sys, ast\n"
                  "x = ast.MatchAs  # bare: ast.MatchAs\n"
                  "if sys.version_info < (3, 10):\n    print('old')\n"  # does not leave: no gate
                  "y = ast.MatchAs  # bare: ast.MatchAs\n"
                  "def f():\n    if not hasattr(ast, 'MatchAs'):\n        return None\n    return ast.MatchAs\n"
                  "if sys.version_info < (3, 11):\n    sys.stderr.write('needs 3.11')\n    sys.exit(3)\n"
                  "import tomllib\n"
                  "def g():\n    return ast.MatchStar\n")


def newer_python():
    """A Python 3.10 or newer to run this suite with, or None: the scan needs the newer stdlib's table."""
    for cand in ("python3.13", "python3.12", "python3.11", "python3.10", "python3"):
        path = shutil.which(cand)
        version = _version(path) if path else None
        if version and version >= (3, 10):
            return path
    uv = _uv()
    found = subprocess.run(uv + ["python", "find", "3.12"], capture_output=True, text=True, timeout=120) if uv else None
    path = found.stdout.strip().splitlines()[-1] if found and found.returncode == 0 and found.stdout.strip() else None
    return path if path and (_version(path) or (0,)) >= (3, 10) else None


if sys.version_info[:2] == PY39:
    # Run on a 3.9 itself, there is no newer stdlib in this process to ask what 3.9 lacks; the same suite runs
    # under a newer Python instead (which asks this 3.9), so a 3.9 run checks as much as any other.
    del UnderPython39

    class RerunUnderANewerPython(unittest.TestCase):
        def test_the_suite_passes_under_a_newer_python(self):
            newer = newer_python()
            self.assertIsNotNone(newer, "no Python 3.10+ found or installable (install uv); refusing to pass the "
                                        "files a Mac runs with 3.9 unchecked")
            out = subprocess.run([newer, str(Path(__file__).resolve()), "-v"], capture_output=True, text=True,
                                 timeout=3600, env=dict(os.environ, PY39=sys.executable))
            self.assertEqual(out.returncode, 0, (out.stdout + out.stderr)[-6000:])
            self.assertRegex(out.stderr, r"\nRan [1-9]", "no test ran")


if __name__ == "__main__":
    unittest.main()
