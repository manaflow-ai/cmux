#!/usr/bin/env python3
"""No write is retried on a timeout that may have come after the server took it.

A RequestTimeout after the request went out says nothing of whether the server acted on it: GitHub may create a
comment and then answer too late. auto_triage.py retried every RequestTimeout, and a delayed answer to its comment
POST made two comments (Codex review of #40718, F1). deadline_http's RequestTimeout says whether the request was
sent (`sent`); a write may be retried only when it was not, or after a reconcile step reads what the server holds.

This scans scripts/ci for an `except` that catches RequestTimeout or TimeoutError (alone or in a tuple) in a
function that may write (a POST, PATCH, PUT or DELETE literal, or a Request built with a non-literal method or
with data), where the handler retries (the try is in a loop and the handler continues or falls through, or the
handler calls the function again), and the handler neither reads `.sent`, nor calls a function named *reconcile*,
nor retries only a read (compares the method with "GET" or "HEAD"). A write the server applies the same way twice
(an IndexNow submission) says so on the `except` line or the comment above it: `# timeout-retry-ok: <why a repeat is harmless>`.

Run: python3 tests/test_ci_timeout_retry_sent.py
"""

from __future__ import annotations

import ast
import sys
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCAN = ROOT / "scripts" / "ci"
WRITES = {"POST", "PATCH", "PUT", "DELETE"}
TIMEOUTS = {"RequestTimeout", "TimeoutError"}


def _catches_timeout(handler: ast.ExceptHandler) -> bool:
    kinds = handler.type.elts if isinstance(handler.type, ast.Tuple) else [handler.type]
    for kind in kinds:
        name = kind.attr if isinstance(kind, ast.Attribute) else getattr(kind, "id", None)
        if name in TIMEOUTS:
            return True
    return False


def _may_write(function: ast.AST) -> bool:
    for node in ast.walk(function):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value.upper() in WRITES:
            return True
        if isinstance(node, ast.Call):
            for keyword in node.keywords:
                value = keyword.value
                if keyword.arg == "method" and not (
                        isinstance(value, ast.Constant) and str(value.value).upper() in {"GET", "HEAD"}):
                    return True
                if keyword.arg == "data" and not (isinstance(value, ast.Constant) and value.value is None):
                    return True
    return False


def _called_name(call: ast.Call) -> str:
    func = call.func
    return func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", "")


def _checks_sent(handler: ast.ExceptHandler, lines: list[str]) -> bool:
    """Whether HANDLER makes its retry safe: reads .sent, calls a reconcile function, retries only a read, or
    carries a reviewed timeout-retry-ok comment."""
    # On the except line, or in the comment just above it.
    above = handler.lineno - 2
    while above >= 0 and lines[above].strip().startswith("#"):
        if "timeout-retry-ok:" in lines[above]:
            return True
        above -= 1
    if "timeout-retry-ok:" in lines[handler.lineno - 1]:
        return True
    for node in ast.walk(handler):
        if isinstance(node, ast.Attribute) and node.attr == "sent":
            return True
        if isinstance(node, ast.Call) and "reconcile" in _called_name(node).lower():
            return True
        if isinstance(node, ast.Compare):
            for side in [node.left, *node.comparators]:
                values = side.elts if isinstance(side, (ast.Tuple, ast.List, ast.Set)) else [side]
                if any(isinstance(v, ast.Constant) and v.value in ("GET", "HEAD") for v in values):
                    return True
    return False


def _retries(handler: ast.ExceptHandler, in_loop: bool, function_name: str) -> bool:
    for node in ast.walk(handler):
        if isinstance(node, ast.Call) and _called_name(node) == function_name:
            return True
    if not in_loop:
        return False
    if any(isinstance(node, ast.Continue) for node in ast.walk(handler)):
        return True
    return not isinstance(handler.body[-1], (ast.Raise, ast.Return, ast.Break))


def findings(source: str, path: str = "<fixture>") -> list[str]:
    tree = ast.parse(source)
    lines = source.splitlines()
    found: list[str] = []

    def visit(node: ast.AST, function: ast.AST | None, in_loop: bool) -> None:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            function, in_loop = node, False
        if isinstance(node, ast.Try) and function is not None and _may_write(function):
            for handler in node.handlers:
                if (handler.type is not None and _catches_timeout(handler)
                        and _retries(handler, in_loop, function.name) and not _checks_sent(handler, lines)):
                    found.append(f"{path}:{handler.lineno}: {function.name}() retries a write on a timeout "
                                 f"without reading .sent or calling a reconcile function")
        for child in ast.iter_child_nodes(node):
            loop = in_loop or (isinstance(node, (ast.For, ast.While, ast.AsyncFor)) and child not in node.orelse)
            visit(child, function, loop)

    visit(tree, None, False)
    return found


def scan() -> list[str]:
    found: list[str] = []
    for path in sorted(SCAN.rglob("*.py")):
        try:
            source = path.read_text(encoding="utf-8")
            found.extend(findings(source, str(path.relative_to(ROOT))))
        except (SyntaxError, UnicodeDecodeError):
            continue
    return found


RETRIED_POST = """
    def post(url, body):
        for attempt in range(3):
            try:
                return deadline_http.request(Request(url, data=body, method="POST"), 30)
            except (URLError, deadline_http.RequestTimeout):
                time.sleep(1)
                continue
"""

RETRIED_BY_FALLTHROUGH = """
    def call(method, url):
        while True:
            try:
                return deadline_http.request(Request(url, method=method), 30)
            except TimeoutError:
                log("again")
"""

RETRIED_BY_RECURSION = """
    def comment(url, body):
        try:
            return deadline_http.request(url, 30, data=body)
        except deadline_http.RequestTimeout:
            return comment(url, body)
"""

CHECKS_SENT = """
    def post(url, body):
        for attempt in range(3):
            try:
                return deadline_http.request(Request(url, data=body, method="POST"), 30)
            except deadline_http.RequestTimeout as error:
                if error.sent:
                    raise
                continue
"""

RECONCILES = """
    def post(url, body):
        for attempt in range(3):
            try:
                return deadline_http.request(Request(url, data=body, method="POST"), 30)
            except deadline_http.RequestTimeout:
                if reconcile_comment(url):
                    return None
                continue
"""

READ_ONLY = """
    def get(url):
        for attempt in range(3):
            try:
                return deadline_http.request(url, 30)
            except deadline_http.RequestTimeout:
                continue
"""

RETRIES_ONLY_A_READ = """
    def call(method, url, body=None):
        for attempt in range(2):
            try:
                return deadline_http.request(Request(url, data=body, method=method), 30)
            except (URLError, TimeoutError, OSError) as error:
                if attempt == 0 and method == "GET":
                    continue
                raise RuntimeError(error) from error
"""

REVIEWED_IDEMPOTENT = """
    def submit(url, body):
        for attempt in range(3):
            try:
                return urlopen(Request(url, data=body), timeout=30)
            except TimeoutError:  # timeout-retry-ok: the same submission twice is the same submission
                time.sleep(1)
"""

GIVES_UP = """
    def post(url, body):
        for attempt in range(3):
            try:
                return deadline_http.request(Request(url, data=body, method="POST"), 30)
            except deadline_http.RequestTimeout as error:
                raise SystemExit(f"{url}: {error}")
"""


class FixtureTest(unittest.TestCase):
    def test_flags_a_retried_write(self) -> None:
        for name, source in (("loop", RETRIED_POST), ("fallthrough", RETRIED_BY_FALLTHROUGH),
                             ("recursion", RETRIED_BY_RECURSION)):
            with self.subTest(name):
                self.assertEqual(len(findings(textwrap.dedent(source))), 1)

    def test_passes_a_checked_or_unretried_one(self) -> None:
        for name, source in (("sent", CHECKS_SENT), ("reconcile", RECONCILES), ("read only", READ_ONLY),
                             ("retries only a read", RETRIES_ONLY_A_READ), ("reviewed", REVIEWED_IDEMPOTENT),
                             ("gives up", GIVES_UP)):
            with self.subTest(name):
                self.assertEqual(findings(textwrap.dedent(source)), [])


class TreeTest(unittest.TestCase):
    def test_scripts_ci_retries_no_write_blindly(self) -> None:
        found = scan()
        self.assertEqual(found, [], "\n" + "\n".join(found))


if __name__ == "__main__":
    unittest.main()
