"""A test skipped because it is red on the base, until a checked-in date.

`@known_red(issue, until, reason)` skips the test with a reason that names the issue, the date and
the failing line. From `until` on, the test fails instead: "known red past its expiry: ...". So a
skip cannot outlive its issue unnoticed. Whoever fixes the issue removes the decorator; whoever
needs longer moves the date in a reviewed change. Nothing here calls GitHub: the date is the check.

`audit(paths)` lists the `@unittest.skip(...)` decorators in PATHS whose reason names a GitHub issue
but carry no expiry, so a bare skip against an issue is caught by tests/test_known_red.py.

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


def audit(paths) -> list[str]:
    """`path:line` of each `@unittest.skip("...")` whose reason names an issue (bare, no expiry)."""
    found = []
    for path in paths:
        tree = ast.parse(Path(path).read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            for dec in getattr(node, "decorator_list", []):
                if not (isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute)
                        and dec.func.attr == "skip" and getattr(dec.func.value, "id", "") == "unittest"):
                    continue
                text = " ".join(a.value for a in dec.args if isinstance(a, ast.Constant) and isinstance(a.value, str))
                if ISSUE_IN_REASON.search(text):
                    found.append(f"{path}:{dec.lineno}")
    return found
