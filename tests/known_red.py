"""A test skipped because it is red on the base, until a checked-in date.

`@known_red(issue, until, reason)` skips the test with a reason that names the issue, the date and
the failing line. From `until` on, the test fails instead: "known red past its expiry: ...". So a
skip cannot outlive its issue unnoticed. Whoever fixes the issue removes the decorator; whoever
needs longer moves the date in a reviewed change. Nothing here calls GitHub: the date is the check.

`audit(paths)` lists the `@unittest.skip(...)` decorators in PATHS whose reason names a GitHub issue
but carry no expiry, so a bare skip against an issue is caught by tests/test_known_red.py. The reason is read
however it is written (positional or `reason=`, a concatenation, an f-string, `%`, a module constant, `skip`
imported from unittest); a reason it cannot work out from the file is listed as "skip reason not readable", so a
skip whose reason it cannot see fails closed (cmux#41434 review: only literal positional reasons were read).

Load this module by path, never `import known_red`: tests run as `python3 -I` have no script
directory on sys.path.
"""

from __future__ import annotations

import ast
import datetime as _dt
import functools
import re
import unittest
from pathlib import Path

ISSUE_URL = "https://github.com/manaflow-ai/cmux/issues/{n}"
ISSUE_IN_REASON = re.compile(r"(?:github\.com/[^/\s]+/[^/\s]+/issues/\d+|#\d+)")


def _today() -> _dt.date:
    return _dt.date.today()


def known_red(issue: int, until: str, reason: str, today=None):
    """Skip the test (naming ISSUE) before UNTIL (YYYY-MM-DD); from UNTIL on, fail it."""
    expiry = _dt.date.fromisoformat(until)
    url = ISSUE_URL.format(n=issue)
    said = f"known red until {until}: {reason} ({url})"

    def decorate(test):
        @functools.wraps(test)
        def run(self, *args, **kwargs):
            now = (today or _today)()
            if now < expiry:
                raise unittest.SkipTest(said)
            self.fail(f"known red past its expiry ({until}): {reason} ({url}). Fix it and remove "
                      f"@known_red, or move the date in a reviewed change.")

        run.known_red = {"issue": issue, "until": until, "reason": reason}
        return run

    return decorate


class _Unreadable(Exception):
    """A skip reason that is not worked out from the file alone (a call, an imported name)."""


def _fold(node, constants: dict):
    """The value of NODE from literals and the module's constants, or _Unreadable."""
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Name) and node.id in constants:
        return constants[node.id]
    if isinstance(node, ast.JoinedStr):
        parts = []
        for value in node.values:
            if isinstance(value, ast.FormattedValue):
                if value.format_spec is not None:
                    raise _Unreadable
                folded = _fold(value.value, constants)
                parts.append(repr(folded) if value.conversion == ord("r") else str(folded))
            else:
                parts.append(str(_fold(value, constants)))
        return "".join(parts)
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Mod)):
        left, right = _fold(node.left, constants), _fold(node.right, constants)
        try:
            return left + right if isinstance(node.op, ast.Add) else left % right
        except (TypeError, ValueError):
            raise _Unreadable from None
    if isinstance(node, ast.Tuple):
        return tuple(_fold(item, constants) for item in node.elts)
    raise _Unreadable


def _constants(tree) -> dict:
    """The module's top-level `NAME = <foldable>` assignments, in order."""
    constants: dict = {}
    for stmt in tree.body:
        targets = stmt.targets if isinstance(stmt, ast.Assign) else (
            [stmt.target] if isinstance(stmt, ast.AnnAssign) and stmt.value is not None else [])
        for target in targets:
            if isinstance(target, ast.Name):
                try:
                    constants[target.id] = _fold(stmt.value, constants)
                except _Unreadable:
                    constants.pop(target.id, None)
    return constants


def _skip_names(tree) -> set[str]:
    """Bare names that are unittest.skip here (`from unittest import skip [as name]`)."""
    return {alias.asname or alias.name for stmt in ast.walk(tree) if isinstance(stmt, ast.ImportFrom)
            and stmt.module == "unittest" for alias in stmt.names if alias.name == "skip"}


def audit(paths) -> list[str]:
    """`path:line` of each `@unittest.skip(...)` whose reason names an issue (bare, no expiry), and
    `path:line: skip reason not readable` of each whose reason is not worked out from the file (fails closed)."""
    found = []
    for path in paths:
        tree = ast.parse(Path(path).read_text(encoding="utf-8"))
        constants, bare = _constants(tree), _skip_names(tree)
        for node in ast.walk(tree):
            for dec in getattr(node, "decorator_list", []):
                if not isinstance(dec, ast.Call):
                    continue
                func = dec.func
                if not ((isinstance(func, ast.Attribute) and func.attr == "skip"
                         and getattr(func.value, "id", "") == "unittest")
                        or (isinstance(func, ast.Name) and func.id in bare)):
                    continue
                reasons = list(dec.args[:1]) + [k.value for k in dec.keywords if k.arg == "reason"]
                try:
                    if len(reasons) != 1 or any(k.arg is None for k in dec.keywords):
                        raise _Unreadable
                    text = str(_fold(reasons[0], constants))
                except _Unreadable:
                    found.append(f"{path}:{dec.lineno}: skip reason not readable")
                    continue
                if ISSUE_IN_REASON.search(text):
                    found.append(f"{path}:{dec.lineno}")
    return found
