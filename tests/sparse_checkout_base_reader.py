"""The sparse-checkout read detector as it was at 33852f74 (cmux#41221's base), frozen.

tests/test_ci_sparse_checkout_imports.py's differential test runs this and the current reader over
every tracked tests/*.py, the scripts the real-tree check scans and the review fixtures, and requires
the current reader to find everything this one finds, less an explicit list of reasoned removals
(writes, superseded values). Do not edit it to match the current reader: it is the reference.
Loaded by path; `python3 -I` puts no script folder on sys.path.
"""

from __future__ import annotations

import ast
import posixpath


def _norm(rel: str) -> str | None:
    """A repo-relative posix path, normalized; None if it is absolute or leaves the repo."""
    if rel.startswith("/"):
        return None
    out = posixpath.normpath(rel) if rel else ""
    if out == ".":
        return ""
    if out == ".." or out.startswith("../"):
        return None
    return out


def _join(base: str, *parts: str) -> str | None:
    return _norm(posixpath.join(base, *parts) if base else posixpath.join(*parts))


def _dirname(rel: str) -> str | None:
    return None if rel == "" else rel.rsplit("/", 1)[0] if "/" in rel else ""


_PATH_CALLS = {"Path", "PurePath", "PosixPath", "pathlib.Path"}
_IDENTITY_METHODS = {"resolve", "absolute", "expanduser"}
_IDENTITY_OS = {"os.path.abspath", "os.path.realpath", "os.path.normpath", "os.fspath", "str"}


def _dotted(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        head = _dotted(node.value)
        return f"{head}.{node.attr}" if head else None
    return None


def _literal(node: ast.AST) -> str | None:
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None


class _RepoPaths:
    """Evaluates expressions that name a repo-relative path statically.

    `__file__` is the script's own path; `Path("x")` and `open("x")` with a relative literal are
    taken from the repo root, where the workflow runs them. A name counts only when every
    assignment to it in the file evaluates to the same path, so a fixture variable reassigned to a
    tmp dir is never taken for the repo.
    """

    def __init__(self, script: str, tree: ast.AST) -> None:
        self.script = script
        self.env: dict[str, str] = {}
        assigns: dict[str, list[ast.AST]] = {}
        for node in ast.walk(tree):
            targets: list[ast.AST] = []
            value = None
            if isinstance(node, ast.Assign):
                targets, value = node.targets, node.value
            elif isinstance(node, (ast.AnnAssign, ast.AugAssign, ast.NamedExpr)):
                targets, value = [node.target], node.value
            elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
                targets, value = [node.target], None
            elif isinstance(node, (ast.With, ast.AsyncWith)):
                targets = [item.optional_vars for item in node.items if item.optional_vars is not None]
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                args = node.args
                targets = [ast.Name(id=a.arg) for a in [*args.posonlyargs, *args.args, *args.kwonlyargs]]
            for target in targets:
                for name in ast.walk(target):
                    if isinstance(name, ast.Name):
                        ok = isinstance(target, ast.Name) and value is not None and not isinstance(node, ast.AugAssign)
                        assigns.setdefault(name.id, []).append(value if ok else None)
        changed = True
        while changed:
            changed = False
            for name, values in assigns.items():
                if name in self.env or any(v is None for v in values):
                    continue
                results = {self.eval(v) for v in values}
                if len(results) == 1 and None not in results:
                    self.env[name] = results.pop()
                    changed = True

    def eval(self, node: ast.AST) -> str | None:
        if isinstance(node, ast.Name):
            if node.id == "__file__":
                return self.script
            return self.env.get(node.id)
        if isinstance(node, ast.Attribute):
            if node.attr == "parent":
                base = self.eval(node.value)
                return None if base is None else _dirname(base)
            return None
        if isinstance(node, ast.Subscript):
            if isinstance(node.value, ast.Attribute) and node.value.attr == "parents":
                index = node.slice
                if isinstance(index, ast.Constant) and isinstance(index.value, int) and index.value >= 0:
                    out = self.eval(node.value.value)
                    for _ in range(index.value + 1):
                        out = None if out is None else _dirname(out)
                    return out
            return None
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            base, part = self.eval(node.left), _literal(node.right)
            return None if base is None or part is None else _join(base, part)
        if isinstance(node, ast.Call):
            func = _dotted(node.func)
            if node.keywords:
                return None
            if func in _PATH_CALLS or func in _IDENTITY_OS:
                if len(node.args) != 1:
                    return None
                arg = node.args[0]
                literal = _literal(arg)
                if literal is not None:
                    return _norm(literal) if func in _PATH_CALLS and literal else None
                return self.eval(arg)
            if func == "os.path.dirname" and len(node.args) == 1:
                base = self.eval(node.args[0])
                return None if base is None else _dirname(base)
            if func == "os.path.join" and node.args:
                base = self.eval(node.args[0])
                parts = [_literal(a) for a in node.args[1:]]
                return None if base is None or None in parts else _join(base, *parts)
            if isinstance(node.func, ast.Attribute):
                method = node.func.attr
                if method in _IDENTITY_METHODS and not node.args:
                    return self.eval(node.func.value)
                if method == "joinpath" and node.args:
                    base = self.eval(node.func.value)
                    parts = [_literal(a) for a in node.args]
                    return None if base is None or None in parts else _join(base, *parts)
        return None


def base_read_paths(script: str, source: str, is_file, tree: ast.Module | None = None) -> set[str]:
    """33852f74's read_paths, verbatim but for its inputs: the source text (or its already parsed
    tree, shared with the current reader; this function does not change it) and an is_file predicate."""
    if tree is None:
        try:
            tree = ast.parse(source)
        except (SyntaxError, ValueError):
            return set()
    paths = _RepoPaths(script, tree)
    found: set[str] = set()
    for node in ast.walk(tree):
        rel = None
        if isinstance(node, ast.Call) and _dotted(node.func) in {"open", "io.open"} and node.args:
            literal = _literal(node.args[0])
            rel = _norm(literal) if literal else paths.eval(node.args[0])
        elif isinstance(node, (ast.BinOp, ast.Call, ast.Subscript, ast.Attribute)):
            rel = paths.eval(node)
        if rel and rel != script and is_file(rel):
            found.add(rel)
    return found
