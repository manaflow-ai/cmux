#!/usr/bin/env python3
"""High-precision static checker for test-code determinism in cmux.

Two principles are enforced:

1. INVERT THE TIME DEPENDENCY. A test must not depend on real wall-clock time.
   Time-driven behavior (timeouts, debounce, retry, animation) is tested by
   injecting a virtual/fake clock the test advances by hand, never by sleeping
   for real and hoping.
2. ASSERT ON CAUSALITY, NOT LATENCY. A correctness test waits ON a real
   completion signal (callback, resumed continuation, fulfilled expectation,
   async-stream yield, posted notification, or a deadline-bounded poll of a real
   state predicate) and asserts a logical invariant. It never waits a fixed
   duration and never asserts on a measured duration.

This checker is deliberately conservative: it flags ONLY unambiguous,
high-confidence flaky primitives so its false-positive rate stays near zero.
A noisy gate gets hated and reverted. When in doubt, it stays silent.

Detectors use conservative line/regex heuristics, with Python AST resolution
for direct standard-library sleep calls:

- assert-on-duration: an assertion comparing a wall-clock duration expression
  (elapsed_ms, perf_counter, DispatchTime.now, CACurrentMediaTime,
  .uptimeNanoseconds, monotonic(), a *_ms variable) against a numeric literal.
  This is the "assert on latency" ban.
- live-network-host: a hardcoded external URL/host driving real network from a
  test (public domain or public IP). Loopback, data:, and 0.0.0.0 are allowed.
- fixed-port-bind: binding/connecting a fixed non-zero port literal for a real
  listener. Port 0 (ephemeral) is allowed.
- sleep-then-assert: a real sleep immediately followed (within 3 non-blank
  lines) by an assertion, where the sleep is NOT a loop body (i.e. not a poll).
  This is the "sleep as synchronization" ban. Deadline-bounded polls and
  scenario-pacing sleeps with no trailing assert are allowed.

Usage:
    check-test-determinism.py                 # scan, print findings, exit 0
    check-test-determinism.py --strict        # exit 1 on any non-allowlisted finding
    check-test-determinism.py --write-allowlist
    check-test-determinism.py --roots ...     # override scan roots
    check-test-determinism.py --json
    check-test-determinism.py --self-test     # run built-in fixtures
"""

from __future__ import annotations

import argparse
import ast
import json
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Iterable, Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_ROOTS: tuple[str, ...] = (
    "cmuxTests",
    "cmuxUITests",
    "ios/cmuxUITests",
    "Packages",
    "tests",
    "tests_v2",
    "web/tests",
    "webviews/test",
)

DEFAULT_ALLOWLIST = ".github/test-determinism-allowlist.txt"

# Only files that look like test code are scanned. Packages/ is broad, so we
# additionally require a Tests path segment for files under it.
SCANNED_SUFFIXES = (".swift", ".py", ".sh", ".ts", ".tsx", ".js", ".mjs")

IGNORED_PATH_PARTS = (
    "/.build/",
    "/node_modules/",
    "/SourcePackages/",
    "/.ci-source-packages/",
    "/vendor/",
    "/ghostty/",
    "/DerivedData/",
    "/__pycache__/",
)

RULE_ASSERT_ON_DURATION = "assert-on-duration"
RULE_LIVE_NETWORK_HOST = "live-network-host"
RULE_FIXED_PORT_BIND = "fixed-port-bind"
RULE_SLEEP_THEN_ASSERT = "sleep-then-assert"

ALL_RULES = (
    RULE_ASSERT_ON_DURATION,
    RULE_LIVE_NETWORK_HOST,
    RULE_FIXED_PORT_BIND,
    RULE_SLEEP_THEN_ASSERT,
)

# ---------------------------------------------------------------------------
# Finding model
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Finding:
    path: str  # repo-relative posix path
    line: int  # 1-based
    rule: str
    snippet: str

    def key(self) -> tuple[str, str]:
        return (self.path, self.rule)

    def format(self) -> str:
        return f"{self.path}:{self.line}: {self.rule}: {self.snippet}"

    def to_dict(self) -> dict[str, object]:
        return {
            "path": self.path,
            "line": self.line,
            "rule": self.rule,
            "snippet": self.snippet,
        }


# ---------------------------------------------------------------------------
# Detector regexes
# ---------------------------------------------------------------------------

# An assertion-introducing token. Covers XCTest, Swift Testing, Python assert /
# unittest, custom `_must`, and `raise ... if` one-liners.
_ASSERT_TOKEN = re.compile(
    r"""(?x)
    \b(
        XCTAssert\w*        # XCTAssertEqual, XCTAssertLessThan, XCTAssertTrue, ...
      | XCTFail
      | \#expect           # Swift Testing
      | \#require
      | assert(?:Equal|Less|Greater|True|False|AlmostEqual)?  # python unittest + bare assert
      | self\.assert\w*
      | expect             # jest / vitest expect(...)
    )\b
    |
    \b\w*_must\w*\b        # custom must-helpers
    """
)

# `raise <Err> if <expr>` one-liner assertion (python).
_RAISE_IF = re.compile(r"\braise\b.+\bif\b")

# Wall-clock / monotonic duration tokens. Presence of one of these inside an
# assertion comparison is the signal.
# A MEASURED wall-clock duration token. The suffix forms (`*_ms`, `*Millis`)
# match a *measured* elapsed variable, not an ALL-CAPS epoch constant such as
# `T0_MS` or `START_EPOCH_MS` (a fixed baseline, deterministic). We therefore
# require the suffix-form identifiers to contain a lowercase letter.
_DURATION_TOKEN = re.compile(
    r"""(?x)
    \b[Ee]lapsed\w*\b
  | \bperf_counter\b
  | \bmonotonic\s*\(
  | \btime\.time\s*\(
  | DispatchTime\.now
  | CACurrentMediaTime
  | CFAbsoluteTimeGetCurrent
  | mach_absolute_time
  | \.uptimeNanoseconds
  | ContinuousClock
  | \bDate\s*\(\s*\)\s*\.timeIntervalSince
  | \b[Dd]uration\w*\b
  | \b(?=\w*[a-z])\w*_ms\b              # measured ms var; ALL-CAPS T0_MS excluded
  | \b(?=\w*[a-z])\w*[Mm]illis\w*\b
  | \b(?=\w*[a-z])\w*[Nn]anos\w*\b
    """
)

# A numeric literal (int or float, with optional underscores / suffix).
_NUMERIC_LITERAL = re.compile(r"(?<![\w.])\d[\d_]*(?:\.\d+)?\b")

# A threshold comparison: a relational operator with a numeric literal on one
# side. Excludes arrow functions (=>), equality (==, ===, !=, !==), and JSX/
# generics by requiring a number to sit immediately across the operator.
_DURATION_COMPARE = re.compile(
    r"""(?x)
    \d[\d_]*(?:\.\d+)?\s*(?:<=|>=|<|>)(?![=>])        # 250 < x
  | (?<![<>=!])(?:<=|>=|<|>)(?![=>])\s*\d[\d_]*(?:\.\d+)?  # x < 250
    """
)

# High-confidence real-sleep call sites, scoped to the source language where
# each spelling identifies a known runtime API. Arbitrary `clock.sleep(...)`
# calls and implicit Swift enum values such as `.sleep(...)` stay silent because
# resolving those correctly requires compiler semantics.
_SWIFT_SLEEP_CALL = re.compile(
    r"""(?x)
    (?<![.\w])sleep\s*\(                  # unqualified POSIX sleep(...)
  | (?<![.\w])usleep\s*\(
  | (?<![.\w])nanosleep\s*\(
  | (?<![.\w])(?:Darwin|Glibc)\.(?:sleep|usleep|nanosleep)\s*\(
  | (?<![.\w])(?:Foundation\.)?Thread\.sleep\s*\(
  | (?<![.\w])Task(?:\s*<[^>\n]+>)?\s*\.sleep\s*\(
    """
)
_PYTHON_SLEEP_MODULES = frozenset(("time", "asyncio", "trio", "anyio", "gevent"))
_JS_SLEEP_CALL = re.compile(
    r"""(?x)
    (?<![.\w])Bun\.sleep\s*\(
  | (?<![.\w])(?:global|globalThis|self|window)\.setTimeout\s*\(
  | (?<![.\w])setTimeout\s*\(
    """
)
_JS_SUFFIXES = (".ts", ".tsx", ".js", ".mjs")

_SLASH_NONCODE_MARKER = re.compile(r'//|/\*|"""|\'\'\'|["\'`]')
_HASH_NONCODE_MARKER = re.compile(r'#|"""|\'\'\'|["\']')
_BLOCK_COMMENT_MARKER = re.compile(r'/\*|\*/')

_ASSERTION_HINTS = ("assert", "expect", "require", "XCT", "raise", "must")
_BIND_HINTS = ("bind", "connect", "connect_ex", "createServer")


# The shell BARE-COMMAND sleep form (`sleep 0.3`) has no parentheses, so it can
# only be recognized positionally. It is matched ONLY in shell files: in Swift /
# Python / TS the same character sequence is almost always a quoted string
# literal ("sleep 5" inside a terminal fixture), never a real delay. Requiring
# the bare form to sit at statement start (optionally after `;`, `&&`, `||`, or a
# pipe) keeps it from firing on `"... sleep 5 ..."` substrings.
_SHELL_BARE_SLEEP = re.compile(
    r"""(?x)
    (?:
        ^ | [;&|({] | (?<!\\)\$\(| (?<!\\)`
      | \b(?:if|elif|while|until|then|do|else)\b
      | (?<!\S)!
    )
    \s* sleep (?=\s|$)
  | ^\s* [^;&()]+ (?:\|[^;&()]+)* \) \s* sleep (?=\s|$)
    """
)

# Loop-body markers: if the sleep line itself is a loop header or sits in an
# obvious poll, we treat it as an allowed deadline-bounded poll, not a sync hack.
_LOOP_HEADER = re.compile(r"^\s*(while|for|until)\b|\bwhile\s+\[|\bfor\s+\w+\s+in\b")

# A hardcoded public URL. We require a scheme and a dotted host that is NOT
# loopback / private. data: and file: are excluded by requiring http(s).
_URL = re.compile(r"https?://([A-Za-z0-9._-]+)(?::\d+)?")

# A network-driving verb. We only flag a public URL when the SAME line also
# invokes one of these, so URLs used as string fixtures (markdown builders,
# canonical-URL assertions, toContain/toStartWith) are not false positives.
_NETWORK_VERB = re.compile(
    r"""(?x)
    \bfetch\s*\(
  | \baxios(?:\.\w+)?\s*\(
  | \b(?:request|got|superagent|undici)\s*\(
  | \bhttp[sx]?\.(?:get|post|request)\s*\(
  | \bXMLHttpRequest\b
  | \.open\s*\(\s*["'][A-Z]+["']\s*,                 # xhr.open("GET", url)
  | \brequests\.(?:get|post|put|delete|head|request)\s*\(
  | \burllib\b
  | \burlopen\s*\(
  | \bhttpx\.\w+\s*\(
  | \bsession\.(?:get|post|request)\s*\(
  | \bcurl\b
  | \bWebSocket\s*\(
    """
)

# Private / loopback hostnames and IPs that are NOT live network.
_PRIVATE_HOST = re.compile(
    r"""(?xi)
    ^localhost$
  | ^127\.\d+\.\d+\.\d+$
  | ^0\.0\.0\.0$
  | ^::1$
  | ^10\.\d+\.\d+\.\d+$
  | ^192\.168\.\d+\.\d+$
  | ^172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+$
  | ^[A-Za-z0-9._-]*\.local$
  | ^[A-Za-z0-9._-]*\.test$
  | ^[A-Za-z0-9._-]*\.example$        # example.test style placeholders without TLD dot
  | ^example\.(?:com|org|net)$        # RFC 2606 reserved, safe placeholders
  | ^[A-Za-z0-9._-]*\.invalid$
    """
)

# A bare public IPv4 literal (used outside a URL), e.g. connect("8.8.8.8", ...).
_PUBLIC_IP = re.compile(r"(?<![\d.])((?:\d{1,3})\.(?:\d{1,3})\.(?:\d{1,3})\.(?:\d{1,3}))(?![\d.])")

# Fixed-port bind / connect. We require a verb that takes an ADDRESS (bind /
# connect / connect_ex / createServer.listen(port)). We deliberately exclude the
# POSIX `listen(fd, backlog)` syscall: its second arg is a connection backlog,
# not a port, so `listen(fd, 1)` must not be read as a host/port tuple.
_BIND_VERB = re.compile(r"\b(bind|connect|connect_ex|createServer)\b")
# host+port tuple where the host is a STRING or an address-like identifier. We
# require the host to be quoted OR a known address name so `listen(fd, 1)`-style
# (fd, backlog) pairs and arbitrary two-arg calls do not match.
_HOST_PORT_TUPLE = re.compile(
    r"""(?x)
    \(\s*
    (?:
        ["'][^"']*["']                    # quoted host: ('127.0.0.1', 8080)
      | (?:host|addr|address|ip|HOST|ADDR|bindHost|listenHost)\w*   # named address var
    )
    \s*,\s*
    (\d+)                                 # port literal -> group 1
    \s*[\),]
    """
)
# NOTE: we intentionally do NOT match a single-arg `.listen(N)` form. In Python
# (the bulk of these tests) `sock.listen(backlog)` takes a connection backlog,
# not a port, so flagging it produces false positives. A real fixed-port bind
# always names the address: `bind(("host", PORT))`, which the tuple form catches.


# ---------------------------------------------------------------------------
# Per-line / per-file detectors
# ---------------------------------------------------------------------------


def _strip_comment(line: str, path_suffix: str) -> str:
    """Best-effort removal of trailing line comments so we don't flag comments.

    Conservative: only strips when the comment marker is clearly not inside a
    string by a cheap heuristic (even count of quotes before it).
    """
    markers = ["#"] if path_suffix in (".py", ".sh") else ["//"]
    out = line
    for marker in markers:
        idx = out.find(marker)
        while idx != -1:
            prefix = out[:idx]
            if prefix.count('"') % 2 == 0 and prefix.count("'") % 2 == 0:
                out = prefix
                break
            idx = out.find(marker, idx + len(marker))
    return out


def _is_assertion_line(line: str) -> bool:
    return bool(_ASSERT_TOKEN.search(line) or _RAISE_IF.search(line))


def detect_assert_on_duration(line: str) -> bool:
    if not _is_assertion_line(line):
        return False
    if not _DURATION_TOKEN.search(line):
        return False
    if not _NUMERIC_LITERAL.search(line):
        return False
    # A latency assertion is a ONE-SIDED bound on a measured clock value: a
    # threshold comparison (`elapsed < 5`, `t > 0.18`) or a Less/Greater assert
    # helper (`XCTAssertLessThan(elapsed, 250)`). We deliberately do NOT treat an
    # exact-equality assert as a latency assert: `XCTAssertEqual(x.duration,
    # 0.225, accuracy:)` and `hidden_duration_ms == 11250` verify a CONFIGURED
    # constant, which is deterministic. Only a one-sided wall-clock bound flakes.
    has_threshold_compare = bool(_DURATION_COMPARE.search(line))
    has_relational_assert = bool(
        re.search(
            r"XCTAssert(?:LessThan\w*|GreaterThan\w*)"
            r"|\bassert(?:Less|Greater)\w*\b",
            line,
        )
    )
    return has_threshold_compare or has_relational_assert


def detect_live_network_host(line: str) -> bool:
    # High-precision signal only: an actual http(s):// URL with a public host that
    # is ALSO handed to a network-driving verb on the same line (fetch/axios/
    # requests/urlopen/...). A URL used as a string fixture (markdown builder,
    # canonical-URL assertion, toContain) opens no socket and is not flagged.
    # Bare quoted IPs in data structures are likewise too ambiguous to flag.
    # Loopback/private/CGNAT/RFC2606 hosts are allowed.
    if not _NETWORK_VERB.search(line):
        return False
    for match in _URL.finditer(line):
        host = match.group(1)
        if "." not in host:
            continue  # bare hostname, not a real domain
        if _PRIVATE_HOST.search(host):
            continue
        if _looks_like_ipv4(host) and _is_private_ipv4(host):
            continue
        return True
    return False


def _looks_like_ipv4(text: str) -> bool:
    parts = text.split(".")
    if len(parts) != 4:
        return False
    try:
        return all(0 <= int(p) <= 255 for p in parts)
    except ValueError:
        return False


def _is_private_ipv4(text: str) -> bool:
    """Loopback, RFC1918, link-local, and CGNAT (100.64.0.0/10) ranges."""
    try:
        a, b, _c, _d = (int(p) for p in text.split("."))
    except ValueError:
        return False
    if a == 127 or a == 0:
        return True
    if a == 10:
        return True
    if a == 192 and b == 168:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    if a == 169 and b == 254:
        return True
    if a == 100 and 64 <= b <= 127:  # CGNAT (Tailscale)
        return True
    return False


def detect_fixed_port_bind(line: str) -> bool:
    if not _BIND_VERB.search(line):
        return False
    for match in _HOST_PORT_TUPLE.finditer(line):
        try:
            port = int(match.group(1))
        except ValueError:
            continue
        if port != 0:
            return True
    return False


def _sleep_in_loop(lines: list[str], idx: int) -> bool:
    """True if the sleep on lines[idx] is plausibly a poll-loop body.

    A poll is allowed: it returns the instant the predicate holds and only the
    deadline bounds failure. The sleep is a poll body when the sleep line itself
    is a loop header, or when an ENCLOSING loop header sits above it.

    Enclosing headers are found by indentation: walking backwards from the sleep,
    a line whose indent is strictly less than every line seen below it (tracked as
    `enclosing_indent`) is a header of a block the sleep lives in. The first such
    header that is a loop (`while` / `for` / `until`) means the sleep is a poll
    body. We stop once indent reaches column 0 (we have left the function), so a
    deeply nested poll loop is still recognized regardless of body length, while a
    flat `sleep(); assert` at the same indent (no enclosing loop) is not.
    """
    if _LOOP_HEADER.search(lines[idx]):
        return True
    sleep_indent = len(lines[idx]) - len(lines[idx].lstrip())
    if sleep_indent == 0:
        return False
    enclosing_indent = sleep_indent
    for j in range(idx - 1, -1, -1):
        prev = lines[j]
        if not prev.strip():
            continue
        prev_indent = len(prev) - len(prev.lstrip())
        # Only lines that dedent past everything seen so far are enclosing
        # headers; siblings and nested lines at >= enclosing_indent are skipped.
        if prev_indent >= enclosing_indent:
            continue
        enclosing_indent = prev_indent
        if _LOOP_HEADER.search(prev):
            return True
        if prev_indent == 0:
            break
    return False


def _sleep_call_pattern(path_suffix: str) -> Optional[re.Pattern[str]]:
    if path_suffix == ".swift":
        return _SWIFT_SLEEP_CALL
    if path_suffix in _JS_SUFFIXES:
        return _JS_SLEEP_CALL
    return None


_PYTHON_MODULE_BINDING = "module"
_PYTHON_FUNCTION_BINDING = "function"
_PYTHON_SHADOWED_BINDING = "shadowed"


@dataclass
class _PythonScope:
    """One Python lexical namespace used by the sleep-call resolver."""

    kind: str
    parent: Optional["_PythonScope"]
    bindings: dict[str, str]


class _PythonSleepVisitor(ast.NodeVisitor):
    """Find exact trusted ``sleep`` calls without guessing receiver types."""

    def __init__(self) -> None:
        self.module_scope = _PythonScope(
            kind="module",
            parent=None,
            bindings={
                name: _PYTHON_MODULE_BINDING
                for name in _PYTHON_SLEEP_MODULES
            },
        )
        self.scope = self.module_scope
        self.sleep_lines: set[int] = set()

    def _resolve(self, name: str) -> Optional[str]:
        scope: Optional[_PythonScope] = self.scope
        while scope is not None:
            binding = scope.bindings.get(name)
            if binding is not None:
                return binding
            scope = scope.parent
        return None

    def _bind(self, name: str, binding: str = _PYTHON_SHADOWED_BINDING) -> None:
        self.scope.bindings[name] = binding

    def _bind_target(self, target: ast.expr) -> None:
        if isinstance(target, ast.Name):
            self._bind(target.id)
        elif isinstance(target, (ast.List, ast.Tuple)):
            for element in target.elts:
                self._bind_target(element)
        elif isinstance(target, ast.Starred):
            self._bind_target(target.value)

    def _visit_target_expressions(self, target: ast.expr) -> None:
        if isinstance(target, ast.Attribute):
            self.visit(target.value)
        elif isinstance(target, ast.Subscript):
            self.visit(target.value)
            self.visit(target.slice)
        elif isinstance(target, (ast.List, ast.Tuple)):
            for element in target.elts:
                self._visit_target_expressions(element)
        elif isinstance(target, ast.Starred):
            self._visit_target_expressions(target.value)

    def _lexical_parent(self) -> _PythonScope:
        scope = self.scope
        while scope.kind == "class" and scope.parent is not None:
            scope = scope.parent
        return scope

    def _scope_state(self) -> dict[str, str]:
        return self.scope.bindings.copy()

    def _restore_scope_state(self, state: dict[str, str]) -> None:
        self.scope.bindings = state.copy()

    def _merge_scope_states(self, states: list[dict[str, str]]) -> None:
        def merge(mappings: list[dict[str, str]]) -> dict[str, str]:
            result: dict[str, str] = {}
            keys = set().union(*(mapping.keys() for mapping in mappings))
            for key in keys:
                values = {mapping.get(key) for mapping in mappings}
                result[key] = (
                    values.pop()
                    if len(values) == 1 and None not in values
                    else _PYTHON_SHADOWED_BINDING
                )
            return result

        self.scope.bindings = merge(states)

    def _visit_branch_blocks(
        self,
        blocks: list[list[ast.stmt]],
    ) -> None:
        base = self._scope_state()
        states: list[dict[str, str]] = []
        for block in blocks:
            self._restore_scope_state(base)
            for statement in block:
                self.visit(statement)
            states.append(self._scope_state())
        self._merge_scope_states(states)

    def _argument_nodes(self, arguments: ast.arguments) -> list[ast.arg]:
        result = list(arguments.posonlyargs) + list(arguments.args)
        if arguments.vararg is not None:
            result.append(arguments.vararg)
        result.extend(arguments.kwonlyargs)
        if arguments.kwarg is not None:
            result.append(arguments.kwarg)
        return result

    def _visit_argument_expressions(self, arguments: ast.arguments) -> None:
        for default in arguments.defaults:
            self.visit(default)
        for default in arguments.kw_defaults:
            if default is not None:
                self.visit(default)
        for argument in self._argument_nodes(arguments):
            if argument.annotation is not None:
                self.visit(argument.annotation)

    def _visit_function(
        self,
        node: ast.FunctionDef | ast.AsyncFunctionDef,
    ) -> None:
        for decorator in node.decorator_list:
            self.visit(decorator)
        self._visit_argument_expressions(node.args)
        if node.returns is not None:
            self.visit(node.returns)
        for type_parameter in getattr(node, "type_params", ()):
            self.visit(type_parameter)

        # The function name is available when its body eventually executes.
        self._bind(node.name)
        parent = self._lexical_parent()
        previous_scope = self.scope
        self.scope = _PythonScope("function", parent, {})
        for argument in self._argument_nodes(node.args):
            self._bind(argument.arg)
        for statement in node.body:
            self.visit(statement)
        self.scope = previous_scope

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self._visit_function(node)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self._visit_function(node)

    def visit_Lambda(self, node: ast.Lambda) -> None:
        self._visit_argument_expressions(node.args)
        parent = self._lexical_parent()
        previous_scope = self.scope
        self.scope = _PythonScope("function", parent, {})
        for argument in self._argument_nodes(node.args):
            self._bind(argument.arg)
        self.visit(node.body)
        self.scope = previous_scope

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        for decorator in node.decorator_list:
            self.visit(decorator)
        for base in node.bases:
            self.visit(base)
        for keyword in node.keywords:
            self.visit(keyword.value)
        for type_parameter in getattr(node, "type_params", ()):
            self.visit(type_parameter)

        # Methods execute after the class object has replaced this outer name.
        self._bind(node.name)
        parent = self._lexical_parent()
        previous_scope = self.scope
        self.scope = _PythonScope("class", parent, {})
        for statement in node.body:
            self.visit(statement)
        self.scope = previous_scope

    def visit_Import(self, node: ast.Import) -> None:
        for alias in node.names:
            name = alias.asname or alias.name.split(".", maxsplit=1)[0]
            binding = (
                _PYTHON_MODULE_BINDING
                if alias.name in _PYTHON_SLEEP_MODULES
                else _PYTHON_SHADOWED_BINDING
            )
            self._bind(name, binding)

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        if any(alias.name == "*" for alias in node.names):
            visible_names: set[str] = set()
            scope: Optional[_PythonScope] = self.scope
            while scope is not None:
                visible_names.update(scope.bindings)
                scope = scope.parent
            for name in visible_names:
                if self._resolve(name) in (
                    _PYTHON_MODULE_BINDING,
                    _PYTHON_FUNCTION_BINDING,
                ):
                    self._bind(name)
            return

        for alias in node.names:
            name = alias.asname or alias.name
            binding = (
                _PYTHON_FUNCTION_BINDING
                if (
                    node.level == 0
                    and node.module in _PYTHON_SLEEP_MODULES
                    and alias.name == "sleep"
                )
                else _PYTHON_SHADOWED_BINDING
            )
            self._bind(name, binding)

    def visit_Assign(self, node: ast.Assign) -> None:
        self.visit(node.value)
        for target in node.targets:
            self._visit_target_expressions(target)
            self._bind_target(target)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        self.visit(node.annotation)
        if node.value is not None:
            self.visit(node.value)
        self._visit_target_expressions(node.target)
        self._bind_target(node.target)

    def visit_AugAssign(self, node: ast.AugAssign) -> None:
        self._visit_target_expressions(node.target)
        self.visit(node.value)
        self._bind_target(node.target)

    def visit_NamedExpr(self, node: ast.NamedExpr) -> None:
        self.visit(node.value)
        self._bind_target(node.target)

    def visit_Delete(self, node: ast.Delete) -> None:
        for target in node.targets:
            self._visit_target_expressions(target)
            self._bind_target(target)

    def visit_If(self, node: ast.If) -> None:
        self.visit(node.test)
        self._visit_branch_blocks([node.body, node.orelse])

    def _visit_loop(
        self,
        body: list[ast.stmt],
        orelse: list[ast.stmt],
        target: Optional[ast.expr] = None,
    ) -> None:
        base = self._scope_state()
        states: list[dict[str, str]] = []

        self._restore_scope_state(base)
        for statement in orelse:
            self.visit(statement)
        states.append(self._scope_state())

        self._restore_scope_state(base)
        if target is not None:
            self._visit_target_expressions(target)
            self._bind_target(target)
        for statement in body:
            self.visit(statement)
        for statement in orelse:
            self.visit(statement)
        states.append(self._scope_state())

        self._merge_scope_states(states)

    def visit_For(self, node: ast.For) -> None:
        self.visit(node.iter)
        self._visit_loop(node.body, node.orelse, node.target)

    def visit_AsyncFor(self, node: ast.AsyncFor) -> None:
        self.visit_For(node)

    def visit_While(self, node: ast.While) -> None:
        self.visit(node.test)
        self._visit_loop(node.body, node.orelse)

    def visit_With(self, node: ast.With) -> None:
        for item in node.items:
            self.visit(item.context_expr)
            if item.optional_vars is not None:
                self._visit_target_expressions(item.optional_vars)
                self._bind_target(item.optional_vars)
        for statement in node.body:
            self.visit(statement)

    def visit_AsyncWith(self, node: ast.AsyncWith) -> None:
        self.visit_With(node)

    def visit_ExceptHandler(self, node: ast.ExceptHandler) -> None:
        if node.type is not None:
            self.visit(node.type)
        if node.name is not None:
            self._bind(node.name)
        for statement in node.body:
            self.visit(statement)

    def _visit_try(
        self,
        body: list[ast.stmt],
        handlers: list[ast.ExceptHandler],
        orelse: list[ast.stmt],
        finalbody: list[ast.stmt],
    ) -> None:
        base = self._scope_state()
        states = [base]

        self._restore_scope_state(base)
        for statement in body:
            self.visit(statement)
        for statement in orelse:
            self.visit(statement)
        states.append(self._scope_state())

        for handler in handlers:
            self._restore_scope_state(base)
            self.visit(handler)
            states.append(self._scope_state())

        self._merge_scope_states(states)
        for statement in finalbody:
            self.visit(statement)

    def visit_Try(self, node: ast.Try) -> None:
        self._visit_try(
            node.body,
            node.handlers,
            node.orelse,
            node.finalbody,
        )

    def visit_TryStar(self, node: ast.TryStar) -> None:
        self._visit_try(
            node.body,
            node.handlers,
            node.orelse,
            node.finalbody,
        )

    def _bind_match_pattern(self, pattern: ast.pattern) -> None:
        for child in ast.walk(pattern):
            if isinstance(child, ast.MatchAs) and child.name is not None:
                self._bind(child.name)
            elif isinstance(child, ast.MatchStar) and child.name is not None:
                self._bind(child.name)
            elif (
                isinstance(child, ast.MatchMapping)
                and child.rest is not None
            ):
                self._bind(child.rest)

    def visit_Match(self, node: ast.Match) -> None:
        self.visit(node.subject)
        base = self._scope_state()
        states = [base]
        for case in node.cases:
            self._restore_scope_state(base)
            self._bind_match_pattern(case.pattern)
            if case.guard is not None:
                self.visit(case.guard)
            for statement in case.body:
                self.visit(statement)
            states.append(self._scope_state())
        self._merge_scope_states(states)

    def _visit_comprehension(
        self,
        generators: list[ast.comprehension],
        values: list[ast.expr],
    ) -> None:
        if not generators:
            for value in values:
                self.visit(value)
            return

        # The outermost iterator runs in the parent scope. Comprehension
        # targets and the remaining expressions live in an isolated scope.
        self.visit(generators[0].iter)
        previous_scope = self.scope
        self.scope = _PythonScope("function", self._lexical_parent(), {})
        first = generators[0]
        self._visit_target_expressions(first.target)
        self._bind_target(first.target)
        for condition in first.ifs:
            self.visit(condition)
        for generator in generators[1:]:
            self.visit(generator.iter)
            self._visit_target_expressions(generator.target)
            self._bind_target(generator.target)
            for condition in generator.ifs:
                self.visit(condition)
        for value in values:
            self.visit(value)
        self.scope = previous_scope

    def visit_ListComp(self, node: ast.ListComp) -> None:
        self._visit_comprehension(node.generators, [node.elt])

    def visit_SetComp(self, node: ast.SetComp) -> None:
        self._visit_comprehension(node.generators, [node.elt])

    def visit_GeneratorExp(self, node: ast.GeneratorExp) -> None:
        self._visit_comprehension(node.generators, [node.elt])

    def visit_DictComp(self, node: ast.DictComp) -> None:
        self._visit_comprehension(node.generators, [node.key, node.value])

    def visit_Call(self, node: ast.Call) -> None:
        function = node.func
        if (
            isinstance(function, ast.Attribute)
            and function.attr == "sleep"
            and isinstance(function.value, ast.Name)
            and self._resolve(function.value.id) == _PYTHON_MODULE_BINDING
        ):
            self.sleep_lines.add(node.lineno - 1)
        elif (
            isinstance(function, ast.Name)
            and self._resolve(function.id) == _PYTHON_FUNCTION_BINDING
        ):
            self.sleep_lines.add(node.lineno - 1)
        self.generic_visit(node)


def _python_real_sleep_lines(text: str) -> set[int]:
    """Locate direct trusted Python sleep APIs with lexical AST resolution."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return set()
    visitor = _PythonSleepVisitor()
    visitor.visit(tree)
    return visitor.sleep_lines


def _unescaped_token_index(line: str, token: str, start: int) -> int:
    """Return the next token not preceded by an odd backslash run."""
    index = line.find(token, start)
    while index >= 0:
        backslashes = 0
        cursor = index - 1
        while cursor >= 0 and line[cursor] == "\\":
            backslashes += 1
            cursor -= 1
        if backslashes % 2 == 0:
            return index
        index = line.find(token, index + len(token))
    return -1


def _mask_noncode(lines: list[str], path_suffix: str) -> list[str]:
    """Replace quoted strings and comments while preserving line positions."""
    masked_lines: list[str] = []
    quote: Optional[str] = None
    block_comment_depth = 0
    template_interpolation_depths: list[int] = []
    shell_interpolations: list[tuple[str, int]] = []
    hash_comments = path_suffix in (".py", ".sh")
    marker_pattern = (
        _HASH_NONCODE_MARKER if hash_comments else _SLASH_NONCODE_MARKER
    )

    for line in lines:
        masked = list(line)
        i = 0
        while i < len(line):
            if block_comment_depth:
                marker = _BLOCK_COMMENT_MARKER.search(line, i)
                if marker is None:
                    masked[i:] = " " * (len(line) - i)
                    break
                masked[i : marker.end()] = " " * (marker.end() - i)
                if marker.group() == "/*":
                    block_comment_depth += 1
                else:
                    block_comment_depth -= 1
                i = marker.end()
                continue

            if quote:
                quote_end = line.find(quote, i)
                escape = line.find("\\", i)
                if path_suffix in _JS_SUFFIXES and quote == "`":
                    interpolation_start = _unescaped_token_index(
                        line,
                        "${",
                        i,
                    )
                    if interpolation_start >= 0 and (
                        quote_end < 0 or interpolation_start < quote_end
                    ) and (
                        escape < 0 or interpolation_start < escape
                    ):
                        masked[i:interpolation_start] = " " * (
                            interpolation_start - i
                        )
                        template_interpolation_depths.append(1)
                        quote = None
                        i = interpolation_start + 2
                        continue

                if path_suffix == ".sh" and quote == '"':
                    dollar_start = line.find("$(", i)
                    backtick_start = _unescaped_token_index(line, "`", i)
                    if dollar_start >= 0 and (
                        backtick_start < 0 or dollar_start < backtick_start
                    ):
                        interpolation_start = dollar_start
                        interpolation_kind = "paren"
                        interpolation_token_length = 2
                    elif backtick_start >= 0:
                        interpolation_start = backtick_start
                        interpolation_kind = "backtick"
                        interpolation_token_length = 1
                    else:
                        interpolation_start = -1
                    if interpolation_start >= 0 and (
                        quote_end < 0 or interpolation_start < quote_end
                    ) and (
                        escape < 0 or interpolation_start < escape
                    ):
                        masked[i:interpolation_start] = " " * (
                            interpolation_start - i
                        )
                        shell_interpolations.append(
                            (interpolation_kind, 1)
                        )
                        quote = None
                        i = interpolation_start + interpolation_token_length
                        continue
                if escape >= 0 and (quote_end < 0 or escape < quote_end):
                    end = min(len(line), escape + 2)
                    masked[i:end] = " " * (end - i)
                    i = end
                    continue
                if quote_end < 0:
                    masked[i:] = " " * (len(line) - i)
                    break
                end = quote_end + len(quote)
                masked[i:end] = " " * (end - i)
                i = end
                quote = None
                continue

            marker = marker_pattern.search(line, i)
            if path_suffix == ".sh" and shell_interpolations:
                interpolation_kind, depth = shell_interpolations[-1]
                if interpolation_kind == "backtick":
                    delimiter = _unescaped_token_index(line, "`", i)
                    if delimiter >= 0 and (
                        marker is None or delimiter < marker.start()
                    ):
                        shell_interpolations.pop()
                        quote = '"'
                        i = delimiter + 1
                        continue
                else:
                    opening = _unescaped_token_index(line, "(", i)
                    closing = _unescaped_token_index(line, ")", i)
                    delimiters = [
                        index
                        for index in (opening, closing)
                        if index >= 0
                    ]
                    delimiter = min(delimiters) if delimiters else -1
                    if delimiter >= 0 and (
                        marker is None or delimiter < marker.start()
                    ):
                        if line[delimiter] == "(":
                            shell_interpolations[-1] = (
                                interpolation_kind,
                                depth + 1,
                            )
                        elif depth == 1:
                            shell_interpolations.pop()
                            quote = '"'
                        else:
                            shell_interpolations[-1] = (
                                interpolation_kind,
                                depth - 1,
                            )
                        i = delimiter + 1
                        continue
            if (
                path_suffix in _JS_SUFFIXES
                and template_interpolation_depths
            ):
                opening = line.find("{", i)
                closing = line.find("}", i)
                braces = [index for index in (opening, closing) if index >= 0]
                brace = min(braces) if braces else -1
                if brace >= 0 and (
                    marker is None or brace < marker.start()
                ):
                    if line[brace] == "{":
                        template_interpolation_depths[-1] += 1
                    else:
                        template_interpolation_depths[-1] -= 1
                        if template_interpolation_depths[-1] == 0:
                            template_interpolation_depths.pop()
                            quote = "`"
                    i = brace + 1
                    continue
            if marker is None:
                break
            token = marker.group()
            if token == ("#" if hash_comments else "//"):
                masked[marker.start() :] = " " * (
                    len(line) - marker.start()
                )
                break
            masked[marker.start() : marker.end()] = " " * len(token)
            i = marker.end()
            if token == "/*":
                block_comment_depth = 1
            else:
                quote = token

        # Shell quotes may span physical lines; Swift/Python/JS single and
        # double quotes do not in the forms this conservative lexer supports.
        if quote in ('"', "'") and path_suffix != ".sh":
            quote = None
        masked_lines.append("".join(masked))

    return masked_lines


def detect_sleep_then_assert(
    lines: list[str],
    masked_lines: list[str],
    idx: int,
    path_suffix: str,
    python_sleep_lines: Optional[set[int]] = None,
) -> bool:
    """Sleep on lines[idx] followed by an assertion within 3 non-blank lines."""
    line = masked_lines[idx]
    sleep_pattern = _sleep_call_pattern(path_suffix)
    is_sleep = (
        idx in python_sleep_lines
        if python_sleep_lines is not None
        else bool(sleep_pattern and sleep_pattern.search(line))
    )
    if path_suffix == ".sh":
        is_sleep = bool(_SHELL_BARE_SLEEP.search(line))
    if not is_sleep:
        return False
    if _sleep_in_loop(lines, idx):
        return False
    seen = 0
    for j in range(idx + 1, len(lines)):
        nxt = masked_lines[j]
        if not nxt.strip():
            continue
        seen += 1
        if seen > 3:
            break
        # If we run into a loop header right after the sleep, the following
        # assert is inside a poll, not gated solely by the sleep.
        if _LOOP_HEADER.search(nxt):
            return False
        if _is_assertion_line(nxt):
            return True
    return False


# ---------------------------------------------------------------------------
# File scanning
# ---------------------------------------------------------------------------


def is_ignored_path(rel_posix: str) -> bool:
    normalized = "/" + rel_posix.lstrip("/")
    return any(part in normalized for part in IGNORED_PATH_PARTS)


def _looks_like_test_file(rel_posix: str, root: str) -> bool:
    suffix = pathlib.PurePosixPath(rel_posix).suffix
    if suffix not in SCANNED_SUFFIXES:
        return False
    # Under Packages/, only scan files inside a Tests path segment.
    if root == "Packages" and "/Tests/" not in ("/" + rel_posix):
        return False
    return True


def scan_text(rel_posix: str, text: str) -> list[Finding]:
    suffix = pathlib.PurePosixPath(rel_posix).suffix
    raw_lines = text.splitlines()
    code_lines = [_strip_comment(line, suffix) for line in raw_lines]
    sleep_pattern = _sleep_call_pattern(suffix)
    has_sleep_candidate = (
        "sleep" in text
        if suffix == ".py"
        else bool(sleep_pattern and sleep_pattern.search(text))
    )
    if not has_sleep_candidate and suffix == ".sh":
        has_sleep_candidate = any(
            _SHELL_BARE_SLEEP.search(line) for line in code_lines
        )
    masked_lines = (
        _mask_noncode(raw_lines, suffix) if has_sleep_candidate else code_lines
    )
    python_sleep_lines = (
        _python_real_sleep_lines(text)
        if suffix == ".py" and has_sleep_candidate
        else None
    )
    if suffix == ".py":
        has_sleep_candidate = bool(python_sleep_lines)
    findings: list[Finding] = []

    for i, code in enumerate(code_lines):
        if not code.strip():
            continue
        line_no = i + 1
        snippet = raw_lines[i].strip()

        if any(
            hint in code for hint in _ASSERTION_HINTS
        ) and detect_assert_on_duration(code):
            findings.append(Finding(rel_posix, line_no, RULE_ASSERT_ON_DURATION, snippet))
        if "http" in code and detect_live_network_host(code):
            findings.append(Finding(rel_posix, line_no, RULE_LIVE_NETWORK_HOST, snippet))
        if any(hint in code for hint in _BIND_HINTS) and detect_fixed_port_bind(code):
            findings.append(Finding(rel_posix, line_no, RULE_FIXED_PORT_BIND, snippet))
        if (
            has_sleep_candidate
            and (
                (python_sleep_lines is not None and i in python_sleep_lines)
                or "sleep" in code
                or "setTimeout" in code
            )
            and detect_sleep_then_assert(
                code_lines,
                masked_lines,
                i,
                suffix,
                python_sleep_lines,
            )
        ):
            findings.append(Finding(rel_posix, line_no, RULE_SLEEP_THEN_ASSERT, snippet))

    return findings


def collect_findings(repo_root: pathlib.Path, roots: Iterable[str]) -> list[Finding]:
    findings: list[Finding] = []
    for root in roots:
        root_path = repo_root / root
        if not root_path.exists():
            continue
        if root_path.is_file():
            candidates = [root_path]
        else:
            candidates = sorted(p for p in root_path.rglob("*") if p.is_file())
        for path in candidates:
            try:
                rel_posix = path.relative_to(repo_root).as_posix()
            except ValueError:
                rel_posix = path.as_posix()
            if is_ignored_path(rel_posix):
                continue
            if not _looks_like_test_file(rel_posix, root):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            findings.extend(scan_text(rel_posix, text))
    findings.sort(key=lambda f: (f.path, f.line, f.rule))
    return findings


# ---------------------------------------------------------------------------
# Allowlist
# ---------------------------------------------------------------------------


def load_allowlist(path: pathlib.Path) -> set[tuple[str, str]]:
    allow: set[tuple[str, str]] = set()
    if not path.exists():
        return allow
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                raise ValueError(
                    f"{path}:{line_number}: expected 'relpath<TAB>rule[<TAB>reason]'"
                )
            rel_path, rule = parts[0].strip(), parts[1].strip()
            if rule not in ALL_RULES:
                raise ValueError(f"{path}:{line_number}: unknown rule {rule!r}")
            allow.add((rel_path, rule))
    return allow


def write_allowlist(path: pathlib.Path, findings: list[Finding]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    keys = sorted({f.key() for f in findings})
    with path.open("w", encoding="utf-8") as handle:
        handle.write("# Test-determinism gate allowlist (grandfathered legacy debt).\n")
        handle.write("# Format: relpath<TAB>rule<TAB>short reason\n")
        handle.write("# A finding whose (path, rule) appears here is suppressed.\n")
        handle.write("# Remove a line once the underlying test is determinized.\n")
        for rel_path, rule in keys:
            handle.write(f"{rel_path}\t{rule}\tgrandfathered\n")


def filter_allowlisted(
    findings: list[Finding], allow: set[tuple[str, str]]
) -> tuple[list[Finding], list[Finding]]:
    active: list[Finding] = []
    suppressed: list[Finding] = []
    for finding in findings:
        if finding.key() in allow:
            suppressed.append(finding)
        else:
            active.append(finding)
    return active, suppressed


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------


def _self_test() -> int:
    # (filename, source, expected rules present, rules that must NOT be present)
    positives: list[tuple[str, str, set[str]]] = [
        (
            "cmuxTests/a.swift",
            "let elapsed = end - start\nXCTAssertLessThan(elapsedMs, 250)\n",
            {RULE_ASSERT_ON_DURATION},
        ),
        (
            "tests/b.py",
            "elapsed_ms = (time.perf_counter() - t0) * 1000\nassert elapsed_ms < 50\n",
            {RULE_ASSERT_ON_DURATION},
        ),
        (
            "tests/raiseif.py",
            "elapsed_ms = clock()\nraise AssertionError('slow') if elapsed_ms > 100 else None\n",
            {RULE_ASSERT_ON_DURATION},
        ),
        (
            "web/tests/c.ts",
            "const res = await fetch('https://api.openai.com/v1/items')\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/c2.ts",
            "await fetch('https://93.184.216.34/probe')\n",  # public IP in a real URL
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/d.py",
            "sock.connect(('8.8.8.8', 53))\n",  # bare IP -> only the fixed port is high-confidence
            {RULE_FIXED_PORT_BIND},
        ),
        (
            "tests/port.py",
            "server.bind(('127.0.0.1', 8080))\n",
            {RULE_FIXED_PORT_BIND},
        ),
        (
            "tests/e.py",
            "time.sleep(0.3)\nassert widget.is_rendered()\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/time-alias.py",
            "import time as clock_time\n"
            "clock_time.sleep(0.3)\n"
            "assert widget.is_rendered()\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/time-import-list.py",
            "import os, time as clock_time\n"
            "clock_time.sleep(0.3)\n"
            "assert widget.is_rendered()\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/sleep-alias.py",
            "from asyncio import sleep as pause\n"
            "await pause(0.3)\n"
            "assert widget.is_rendered()\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "cmuxUITests/f.swift",
            "try await Task.sleep(nanoseconds: 300_000_000)\nXCTAssertTrue(view.exists)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "cmuxTests/darwin-usleep.swift",
            "Darwin.usleep(1)\n#expect(finished)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "cmuxTests/glibc-nanosleep.swift",
            "Glibc.nanosleep(nil, nil)\n#expect(finished)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/interpolation.sh",
            'actual="$(start_job; sleep 1; read_state)"\n'
            'assert "$actual" "$expected"\n',
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/direct-interpolation.sh",
            'actual="$(sleep 1)"\n'
            'assert "$actual" "$expected"\n',
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/backtick-interpolation.sh",
            "actual=`sleep 1`\n"
            'assert "$actual" "$expected"\n',
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/multiline-interpolation.sh",
            'actual="$(sleep 1\n'
            ')"\n'
            'assert "$actual" "$expected"\n',
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "web/tests/interpolation.ts",
            "const actual = `${await Bun.sleep(1)}`\n"
            "expect(actual).toBeTruthy()\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "web/tests/multiline-interpolation.ts",
            "const actual = `${\n"
            "  await Bun.sleep(1)\n"
            "}`\n"
            "expect(actual).toBeTruthy()\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/sh.sh",
            "sleep 1\ntest -f /tmp/out || exit 1\n",
            set(),  # shell `test -f` is not in our assertion vocabulary; ensure no false negative is required
        ),
        # Shell bare-command sleep at statement start, then an assertion helper.
        (
            "tests/sh2.sh",
            "sleep 0.3\nassert \"$actual\" \"$expected\"\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
    ]

    negatives: list[tuple[str, str]] = [
        # Swift enum values represent virtual-clock events, not real delays.
        (
            "Packages/Shared/CmuxIrohTransport/Tests/Refresh.swift",
            "#expect(await clockEvents.next() == .sleep(initialRefresh))\n"
            "clock.advance(to: initialRefresh)\n"
            "#expect(await clockEvents.next() == .sleep(replacementRefresh))\n"
            "#expect(await endpoint.updateCount == 2)\n",
        ),
        # Unknown receiver-qualified sleeps stay silent without compiler semantics.
        (
            "cmuxTests/virtual.swift",
            "try await clock.sleep(until: deadline)\n"
            "#expect(await completed)\n"
            "try await ContinuousClock().sleep(until: deadline)\n"
            "#expect(await completed)\n",
        ),
        # A known module name nested under another receiver is not a direct API.
        (
            "tests/nested-runtime.py",
            "fixture.trio.sleep(0.1)\n"
            "assert completed\n"
            "fixture.time.sleep(0.1)\n"
            "assert completed\n",
        ),
        (
            "tests/shadowed-runtime.py",
            "time = fake_clock\n"
            "time.sleep(0.1)\n"
            "assert completed\n"
            "def wait(asyncio):\n"
            "    asyncio.sleep(0.1)\n"
            "    assert completed\n",
        ),
        (
            "tests/import-shadowed-runtime.py",
            "import fake_clock as time\n"
            "time.sleep(0.1)\n"
            "assert completed\n",
        ),
        (
            "tests/expression-shadowed-runtime.py",
            "def wait(factory=make(), time=fake_clock):\n"
            "    time.sleep(0.1)\n"
            "    assert completed\n"
            "if (asyncio := fake_clock):\n"
            "    pass\n"
            "await asyncio.sleep(0.1)\n"
            "assert completed\n",
        ),
        # Runtime spellings only identify direct APIs in their own language.
        (
            "cmuxTests/cross-language.swift",
            "Bun.sleep(1)\n"
            "#expect(completed)\n"
            "time.sleep(1)\n"
            "#expect(completed)\n",
        ),
        (
            "tests/cross-language.py",
            "Bun.sleep(1)\n"
            "assert completed\n"
            "setTimeout(done, 1)\n"
            "assert completed\n",
        ),
        (
            "web/tests/cross-language.ts",
            "time.sleep(1)\n"
            "expect(completed).toBe(true)\n"
            "Task.sleep(1)\n"
            "expect(completed).toBe(true)\n",
        ),
        # Known sleep API names inside strings or comments are fixture data.
        (
            "cmuxTests/sleep-text.swift",
            "let source = \"Task.sleep(nanoseconds: 1)\"\n"
            "#expect(source.isEmpty == false)\n"
            "// Thread.sleep(forTimeInterval: 1)\n"
            "#expect(finished)\n",
        ),
        (
            "web/tests/sleep-text.ts",
            "const source = `setTimeout(resolve, 1)`\n"
            "expect(source).toBeTruthy()\n"
            'const nested = `${"Bun.sleep(1)"}`\n'
            "expect(nested).toBeTruthy()\n"
            "const escaped = `\\${Bun.sleep(1)}`\n"
            "expect(escaped).toBeTruthy()\n",
        ),
        (
            "tests/sleep-text.sh",
            "actual=\"$(printf 'sleep 1')\"\n"
            'assert "$actual" "$expected"\n'
            'escaped="\\$(sleep 1)"\n'
            'assert "$escaped" "$expected"\n'
            'escaped_backtick="\\`sleep 1\\`"\n'
            'assert "$escaped_backtick" "$expected"\n',
        ),
        # Deterministic scenario-pacing sleep with NO following assertion.
        (
            "tests/n1.py",
            "time.sleep(0.05)\nproc.write('next command\\n')\nproc.flush()\n",
        ),
        # Deadline-bounded poll of a real predicate: sleep is inside a while loop.
        (
            "tests/n2.py",
            "deadline = time.monotonic() + 5\n"
            "while time.monotonic() < deadline:\n"
            "    if widget.is_rendered():\n"
            "        break\n"
            "    time.sleep(0.05)\n"
            "assert widget.is_rendered()\n",
        ),
        # data: URL must not be a live-network finding.
        (
            "web/tests/n3.ts",
            "const img = 'data:image/png;base64,iVBORw0KGgoAAAA'\n",
        ),
        # loopback URL is allowed.
        (
            "web/tests/n4.ts",
            "await fetch('http://127.0.0.1:4321/health')\n",
        ),
        # localhost URL is allowed.
        (
            "web/tests/n5.ts",
            "await fetch('http://localhost/health')\n",
        ),
        # Ephemeral port 0 bind is allowed.
        (
            "tests/n6.py",
            "server.bind(('127.0.0.1', 0))\n",
        ),
        # Virtual-clock advance + invariant assert: not a wall-clock assert.
        (
            "cmuxTests/n7.swift",
            "clock.advance(by: .milliseconds(250))\nXCTAssertEqual(model.state, .timedOut)\n",
        ),
        # Awaiting a real expectation/signal then asserting an invariant.
        (
            "cmuxTests/n8.swift",
            "await fulfillment(of: [didFinish], timeout: 5)\nXCTAssertEqual(result, .ok)\n",
        ),
        # Asserting a count (non-duration) against a literal is fine.
        (
            "tests/n9.py",
            "assert len(rows) < 100\n",
        ),
        # example.com placeholder is RFC-reserved, not live network.
        (
            "web/tests/n10.ts",
            "const base = 'https://example.com'\n",
        ),
        # A sleep then a loop header (poll) afterward, not gated by the sleep.
        (
            "tests/n11.py",
            "time.sleep(0.1)\nwhile not done():\n    poll()\n",
        ),
        # Version-looking dotted number, not a network target.
        (
            "tests/n12.py",
            "assert version == '1.2.3'\n",
        ),
        # Bare public IP in a data fixture (route table) is too ambiguous to flag.
        (
            "web/tests/n13.ts",
            'const r = { endpoint: { host: "8.8.8.8", port: 53 } }\n',
        ),
        # CGNAT (Tailscale) host inside a real URL is private, not live network.
        (
            "web/tests/n14.ts",
            "await fetch('http://100.64.1.2:51001/status')\n",
        ),
        # Arrow function and a count assertion sharing a *_ms property name.
        (
            "web/tests/n15.ts",
            'expect(attrs.filter((a) => a.key === "vm.total_ms")).toHaveLength(1)\n',
        ),
        # XCTAssertEqual on a non-duration value with a literal: not a latency assert.
        (
            "cmuxTests/n16.swift",
            "XCTAssertEqual(rows.count, 3)\n",
        ),
        # Public URL used as a STRING fixture (no network verb): not live network.
        (
            "web/tests/n17.ts",
            'expect(text).toContain("Docs: https://cmux.com/docs/api")\n',
        ),
        (
            "web/tests/n18.ts",
            'const llms = buildLlmsText("https://cmux.com")\n',
        ),
        # A quoted shell command embedded in a Swift terminal-parser fixture is a
        # STRING literal, not a real delay: "sleep 5" must not flag sleep-then-assert.
        (
            "cmuxTests/n19.swift",
            'parser.consume(mark("A") + "sleep 5" + mark("C"))\n#expect(parser.blocks.count == 1)\n',
        ),
        # Same bare-command form in Python source is also a string fixture, not a sleep.
        (
            "tests/n20.py",
            'proc.send("sleep 5\\n")\nassert proc.alive\n',
        ),
        # Deadline-bounded poll whose loop body is several statements deep and the
        # trailing sleep is the LAST statement of the loop (the assert is after the
        # loop). The enclosing `while` must be found regardless of body length.
        (
            "tests/n21.py",
            "        body = ''\n"
            "        deadline = time.time() + 15.0\n"
            "        while time.time() < deadline:\n"
            "            try:\n"
            "                body = fetch()\n"
            "            except Exception:\n"
            "                time.sleep(0.5)\n"
            "                continue\n"
            "            if 'ok' in body:\n"
            "                break\n"
            "            time.sleep(0.3)\n"
            "        _must('ok' in body, body)\n",
        ),
    ]

    failures: list[str] = []

    for name, src, expected in positives:
        rules = {f.rule for f in scan_text(name, src)}
        missing = expected - rules
        if missing:
            failures.append(f"POSITIVE {name}: missing {sorted(missing)} (got {sorted(rules)})")

    for name, src in negatives:
        rules = {f.rule for f in scan_text(name, src)}
        if rules:
            failures.append(f"NEGATIVE {name}: unexpected {sorted(rules)}")

    if failures:
        print("self-test FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    total = len(positives) + len(negatives)
    print(f"self-test OK: {len(positives)} positive + {len(negatives)} negative fixtures passed ({total} total)")
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _resolve_roots(repo_root: pathlib.Path, roots: Optional[list[str]]) -> tuple[str, ...]:
    return tuple(roots) if roots else DEFAULT_ROOTS


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--repo-root",
        default=pathlib.Path.cwd(),
        type=pathlib.Path,
        help="repository root to scan (default: cwd)",
    )
    parser.add_argument(
        "--allowlist",
        default=pathlib.Path(DEFAULT_ALLOWLIST),
        type=pathlib.Path,
        help="allowlist file of grandfathered (path, rule) findings",
    )
    parser.add_argument(
        "--roots",
        nargs="+",
        default=None,
        help="override repo-relative roots/globs to scan",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero if any non-allowlisted finding exists",
    )
    parser.add_argument(
        "--write-allowlist",
        action="store_true",
        help="regenerate the allowlist from the current findings",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit findings as JSON",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run built-in detector fixtures and exit",
    )
    args = parser.parse_args(argv)

    if args.self_test:
        return _self_test()

    repo_root = args.repo_root.resolve(strict=False)
    allowlist_path = (
        args.allowlist if args.allowlist.is_absolute() else repo_root / args.allowlist
    )
    roots = _resolve_roots(repo_root, args.roots)

    findings = collect_findings(repo_root, roots)

    if args.write_allowlist:
        write_allowlist(allowlist_path, findings)
        print(f"Wrote {allowlist_path} with {len({f.key() for f in findings})} entr(ies)")
        return 0

    try:
        allow = load_allowlist(allowlist_path)
    except ValueError as exc:
        print(f"Error reading allowlist: {exc}", file=sys.stderr)
        return 2

    active, suppressed = filter_allowlisted(findings, allow)

    if args.json:
        payload = {
            "active": [f.to_dict() for f in active],
            "suppressed": [f.to_dict() for f in suppressed],
            "counts": {
                "active": len(active),
                "suppressed": len(suppressed),
                "total": len(findings),
            },
        }
        print(json.dumps(payload, indent=2))
    else:
        for finding in active:
            print(finding.format())
        print("")
        print(
            f"test-determinism: {len(active)} active finding(s), "
            f"{len(suppressed)} allowlisted, {len(findings)} total"
        )
        if active and not args.strict:
            print("(non-strict mode: not failing. Run with --strict to enforce.)")

    if args.strict and active:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
