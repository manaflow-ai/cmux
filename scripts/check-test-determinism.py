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

Detectors (all line/regex heuristics, never an AST):

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
import json
import pathlib
import re
import sys
from dataclasses import dataclass
from functools import lru_cache
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


@dataclass(frozen=True)
class _CallArgument:
    value_bounds: tuple[int, int]
    label: Optional[str]


@dataclass(frozen=True)
class _ArgvElement:
    value_bounds: tuple[int, int]
    literal: Optional[str]


@dataclass(frozen=True)
class _NetworkTargetSpec:
    verb_pattern: re.Pattern[str]
    positional_index: int
    labels: frozenset[str]


@dataclass(frozen=True)
class _InterpreterSourceSpec:
    executable_pattern: re.Pattern[str]
    source_flag_pattern: re.Pattern[str]
    options_with_values: frozenset[str]


@dataclass(frozen=True)
class _CommandWrapperSpec:
    options_with_values: frozenset[str]
    leading_operands: int = 0
    allows_assignments: bool = False


@dataclass(frozen=True)
class _FluentClientBinding:
    name: str
    kind: str
    constructor_end: int
    base_target_bounds: Optional[tuple[int, int]]
    scope_start: int
    scope_end: int
    is_instance_property: bool
    initialization_scope_end: Optional[int]


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

# Real-sleep call sites. Must be a genuine wall-clock sleep. These are all CALL
# forms (`foo.sleep(`, `sleep(`) so a quoted shell command embedded in a string
# literal (e.g. a terminal-parser fixture `consume("... sleep 5 ...")`) never
# matches: `sleep 5` has no following `(` and is not a call.
_SLEEP_CALL = re.compile(
    r"""(?x)
    \btime\.sleep\s*\(
  | \bsleep\s*\(                            # sleep(...) call (C/shell function form)
  | \busleep\s*\(
  | \bnanosleep\s*\(
  | Thread\.sleep\s*\(
  | Task\.sleep\s*\(
  | try\s+await\s+Task\.sleep
  | \basyncio\.sleep\s*\(
  | \bsetTimeout\s*\(                       # JS, when used as a bare delay
    """
)

# The shell BARE-COMMAND sleep form (`sleep 0.3`) has no parentheses, so it can
# only be recognized positionally. It is matched ONLY in shell files: in Swift /
# Python / TS the same character sequence is almost always a quoted string
# literal ("sleep 5" inside a terminal fixture), never a real delay. Requiring
# the bare form to sit at statement start (optionally after `;`, `&&`, `||`, or a
# pipe) keeps it from firing on `"... sleep 5 ..."` substrings.
_SHELL_BARE_SLEEP = re.compile(r"""(?x) (?:^|[;&|]) \s* sleep \s+ [\d.]""")

# Loop-body markers: if the sleep line itself is a loop header or sits in an
# obvious poll, we treat it as an allowed deadline-bounded poll, not a sync hack.
_LOOP_HEADER = re.compile(r"^\s*(while|for|until)\b|\bwhile\s+\[|\bfor\s+\w+\s+in\b")

# A hardcoded public URL. We require a scheme and a dotted host that is NOT
# loopback / private. data: and file: are excluded by requiring http(s).
_URL = re.compile(r"https?://([A-Za-z0-9._-]+)(?::\d+)?")

_AXIOS_METHOD_NAMES = (
    "delete",
    "get",
    "head",
    "options",
    "patchForm",
    "patch",
    "postForm",
    "post",
    "putForm",
    "put",
    "request",
)
_HTTPX_METHOD_NAMES = (
    "delete",
    "get",
    "head",
    "options",
    "patch",
    "post",
    "put",
    "request",
    "stream",
)
_AXIOS_METHOD_PATTERN = "(?:" + "|".join(_AXIOS_METHOD_NAMES) + ")"
_HTTPX_METHOD_PATTERN = "(?:" + "|".join(_HTTPX_METHOD_NAMES) + ")"

# A network-driving verb. We only flag a public URL when the SAME line also
# invokes one of these, so URLs used as string fixtures (markdown builders,
# canonical-URL assertions, toContain/toStartWith) are not false positives.
_NETWORK_VERB = re.compile(
    rf"""(?x)
    \bfetch\s*\(
  | \baxios\.create\s*\(
  | \baxios(?:\.{_AXIOS_METHOD_PATTERN})?\s*\(
  | \b(?:request|got|superagent|undici)\s*\(
  | \bhttp[sx]?\.(?:get|post|request)\s*\(
  | \bXMLHttpRequest\b
  | (?i:\b(?:xhr|xhttp|xmlhttprequest)\s*\.\s*open\s*\()  # xhr.open(method, url)
  | \brequests\.(?:get|post|put|delete|head|request)\s*\(
  | \burllib3.*\.request\s*\(
  | \burllib\b
  | \burlopen\s*\(
  | \bhttpx\.(?:Client|AsyncClient)\s*\(
  | \bhttpx\.{_HTTPX_METHOD_PATTERN}\s*\(
  | \bsession\.(?:get|post|request)\s*\(
  | \bcurl\b
  | \bWebSocket\s*\(
    """
)

_NETWORK_TARGET_LABELS = frozenset({"uri", "url"})
_NETWORK_BASE_TARGET_LABELS = frozenset({"base_url", "baseurl"})
_NETWORK_TARGET_SPECS = (
    _NetworkTargetSpec(
        verb_pattern=re.compile(
            r"\.open\s*\("
            r"|httpx.*\.(?:request|stream)\s*\("
            r"|(?:requests|session).*\.request\s*\("
        ),
        positional_index=1,
        labels=_NETWORK_TARGET_LABELS,
    ),
    _NetworkTargetSpec(
        verb_pattern=re.compile(r"urllib3.*\.request\s*\("),
        positional_index=1,
        labels=_NETWORK_TARGET_LABELS,
    ),
    _NetworkTargetSpec(
        verb_pattern=re.compile(r".*", re.DOTALL),
        positional_index=0,
        labels=_NETWORK_TARGET_LABELS,
    ),
)
_FLUENT_TERMINAL_CALLS = {
    "axios": re.compile(rf"\s*\.\s*{_AXIOS_METHOD_PATTERN}\s*\("),
    "httpx": re.compile(rf"\s*\.\s*{_HTTPX_METHOD_PATTERN}\s*\("),
}
_FLUENT_CLIENT_ASSIGNMENT = re.compile(
    r"""(?mx)
    (?:^|[;\n{])
    (?P<indent>[ \t]*)
    (?P<modifiers>
        (?:(?:abstract|accessor|declare|export|override|private|protected|public|readonly|static)\s+)*
    )
    (?:(?P<declaration>const|let|var)\s+)?
    (?P<binding>
        \#?[A-Za-z_$][A-Za-z0-9_$]*
        (?:\s*\.\s*[A-Za-z_$][A-Za-z0-9_$]*)*
    )
    [!?]?
    (?:\s*:\s*[^=\n;]+)?
    \s*=\s*(?:\(\s*)*\Z
    """
)

# Shell-string launchers evaluate their first argument as source.
_SHELL_CALL_LAUNCHER = re.compile(
    r"""(?x)
    \bos\.(?:system|popen)\s*\(
  | \bsubprocess\.get(?:status)?output\s*\(
  | (?<![A-Za-z0-9_.])(?:eval|execSync|execaCommand|execaCommandSync)\s*\(
  | \b(?:childProcess|child_process)\.(?:exec|execSync)\s*\(
    """
)

# Argv launchers execute only their command position. Later quoted arguments
# may be fixtures or rendered text and must not be promoted to shell source.
_ARGV_CALL_LAUNCHER = re.compile(
    r"""(?x)
    \bsubprocess\.(?:run|call|check_call|check_output|Popen)\s*\(
  | (?<![A-Za-z0-9_.])(?:execFile|execFileSync|spawn|spawnSync|execa)\s*\(
  | \b(?:childProcess|child_process)\.(?:execFile|execFileSync|spawn|spawnSync)\s*\(
  | (?P<bun>\bBun\.spawn(?:Sync)?\s*\()
    """
)

_ARGV_COMMAND_LABELS = frozenset({"args"})
_BUN_OBJECT_COMMAND_LABELS = frozenset({"cmd"})
_SHELL_MODE_LABELS = frozenset({"shell"})
_NO_ARGUMENT_LABELS: frozenset[str] = frozenset()
_JAVASCRIPT_SUFFIXES = frozenset(
    {".cjs", ".cts", ".js", ".jsx", ".mjs", ".mts", ".ts", ".tsx"}
)
_JAVASCRIPT_REGEX_PREFIX_KEYWORDS = frozenset(
    {
        "await",
        "case",
        "delete",
        "do",
        "else",
        "in",
        "instanceof",
        "of",
        "return",
        "throw",
        "typeof",
        "void",
        "yield",
    }
)

_SHELL_COMMAND_FLAG = re.compile(r"^(?:-[A-Za-z]*c[A-Za-z]*|--command)$")
_SHELL_OPTIONS_WITH_VALUES = frozenset(
    {"+O", "+o", "-O", "-o", "--init-file", "--profile", "--rcfile"}
)
_SHELL_SOURCE_SPEC = _InterpreterSourceSpec(
    executable_pattern=re.compile(r"^(?:bash|dash|fish|ksh|sh|zsh)$"),
    source_flag_pattern=_SHELL_COMMAND_FLAG,
    options_with_values=_SHELL_OPTIONS_WITH_VALUES,
)
_PYTHON_SOURCE_SPEC = _InterpreterSourceSpec(
    executable_pattern=re.compile(
        r"^(?:python(?:\d+(?:\.\d+)*t?)?|pypy(?:\d+(?:\.\d+)*)?)$"
    ),
    source_flag_pattern=re.compile(r"^-c$"),
    options_with_values=frozenset({"-W", "-X", "--check-hash-based-pycs"}),
)
_NODE_SOURCE_SPEC = _InterpreterSourceSpec(
    executable_pattern=re.compile(r"^(?:bun|node|nodejs)$"),
    source_flag_pattern=re.compile(r"^(?:-e|--eval|-p|--print)$"),
    options_with_values=frozenset(
        {
            "-C",
            "-r",
            "--conditions",
            "--env-file",
            "--env-file-if-exists",
            "--icu-data-dir",
            "--import",
            "--input-type",
            "--loader",
            "--openssl-config",
            "--require",
            "--title",
        }
    ),
)
_INTERPRETER_SOURCE_SPECS = (
    _SHELL_SOURCE_SPEC,
    _PYTHON_SOURCE_SPEC,
    _NODE_SOURCE_SPEC,
)

# Locate a shell program outside shell source; `_interpreter_command_source_bounds`
# owns option parsing and identifies the exact word consumed by -c/-lc/--command.
_SHELL_COMMAND_LAUNCHER = re.compile(
    r"""(?x)
    (?<![A-Za-z0-9_.-])
    (?:/(?:usr/)?bin/)?
    (?:bash|dash|fish|ksh|sh|zsh)
    \b
    """
)

_SHELL_EVAL_LAUNCHER = re.compile(
    r"(?x)(?<![A-Za-z0-9_.-])eval\s+(?:--\s+)?"
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
    """Best-effort removal of trailing comments for non-network detectors."""
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


def _python_f_string_starts_at(line: str, quote_index: int) -> bool:
    # A string prefix is at most two characters. Inspect only that local token:
    # searching the entire preceding source for every quote makes a whole-file
    # lexical pass quadratic on large test fixtures.
    for prefix_length, valid_prefixes in ((2, ("fr", "rf")), (1, ("f",))):
        prefix_start = quote_index - prefix_length
        if prefix_start < 0:
            continue
        if line[prefix_start:quote_index].lower() not in valid_prefixes:
            continue
        if prefix_start > 0:
            previous = line[prefix_start - 1]
            if previous.isascii() and (previous.isalnum() or previous == "_"):
                continue
        return True
    return False


def _quote_delimiter_at(line: str, quote_index: int) -> str:
    quote = line[quote_index]
    triple = quote * 3
    return triple if line.startswith(triple, quote_index) else quote


# Whole-file network candidates are one-shot inputs whose source keys dominate
# cache memory. Cache only small repeated launcher/chunk inputs.
_LEXER_CACHE_SOURCE_LIMIT = 16 * 1024
_C_STYLE_BLOCK_COMMENT_SUFFIXES = frozenset(
    {".swift", ".ts", ".tsx", ".js", ".mjs"}
)


def _line_comment_marker_length(
    source: str,
    index: int,
    path_suffix: str,
) -> int:
    if path_suffix in (".py", ".sh"):
        if source[index] != "#":
            return 0
        if path_suffix == ".sh" and index > 0:
            previous = source[index - 1]
            if not (previous.isspace() or previous in ";|&()<>\n"):
                return 0
        return 1
    return 2 if source.startswith("//", index) else 0


def _javascript_regex_literal_starts_at(
    source: str,
    index: int,
    executable: bytearray,
    comments: bytearray,
) -> bool:
    """Return whether a slash starts a JavaScript regex literal."""
    previous = index - 1
    while previous >= 0 and (
        source[previous].isspace() or comments[previous]
    ):
        previous -= 1
    if previous < 0:
        return True

    character = source[previous]
    # A literal (string, template, or prior regex) ends an expression. Its
    # delimiter is deliberately non-executable in the lexical mask. The one
    # opening delimiter that can prefix a regex is a template's `${` field.
    if not executable[previous]:
        return (
            character == "{"
            and previous > 0
            and source[previous - 1] == "$"
        )

    if character.isascii() and (character.isalnum() or character in "_$"):
        token_start = previous
        while token_start > 0:
            candidate = source[token_start - 1]
            if not (
                candidate.isascii()
                and (candidate.isalnum() or candidate in "_$")
            ):
                break
            token_start -= 1
        token = source[token_start : previous + 1]
        before_token = token_start - 1
        while before_token >= 0 and (
            source[before_token].isspace() or comments[before_token]
        ):
            before_token -= 1
        if before_token >= 0 and source[before_token] == ".":
            return False
        return token in _JAVASCRIPT_REGEX_PREFIX_KEYWORDS

    if character in ")]}'\"`.":
        return False
    if (
        character in "+-"
        and previous > 0
        and source[previous - 1] == character
        and executable[previous - 1]
    ):
        return False
    return True


def _lexical_positions(
    line: str,
    path_suffix: str = "",
) -> tuple[bytes, bytes]:
    """Return compact executable-code and line-comment masks for source text.

    The network detector intentionally accepts URLs in string arguments to real
    clients (for example, ``fetch("https://...")``), so stripping every string
    would hide the URL it needs to inspect.  The *client verb*, however, must be
    executable code.  Ignoring verbs quoted as fixture/output text keeps a line
    such as ``expect(html).toContain("curl https://...")`` from looking like a
    network call while preserving the real ``fetch(...)`` case.

    Interpolated strings need one extra distinction: JavaScript backtick,
    Python f-string, and Swift string text is inert, while ``${...}``, ``{...}``,
    and ``\\(...)`` replacement fields are executable code. Shell double quotes
    also preserve executable ``$(...)`` and backtick substitutions. This
    remains a conservative lexer, not a full language parser.
    """
    executable = bytearray(len(line))
    comments = bytearray(len(line))
    # Contexts are (kind, nesting, closing_delimiter). Interpolation contexts
    # use nesting as their delimiter depth; Swift raw string text stores its
    # opening hash count there. Nested quote/template contexts sit above them.
    contexts: list[tuple[str, int, str]] = [("code", 0, "")]
    is_shell = path_suffix == ".sh"
    index = 0
    while index < len(line):
        kind, brace_depth, delimiter = contexts[-1]
        character = line[index]

        if kind == "block-comment":
            if path_suffix == ".swift" and line.startswith("/*", index):
                comments[index : index + 2] = b"\x01\x01"
                contexts[-1] = (kind, brace_depth + 1, delimiter)
                index += 2
                continue
            if line.startswith("*/", index):
                comments[index : index + 2] = b"\x01\x01"
                if brace_depth == 1:
                    contexts.pop()
                else:
                    contexts[-1] = (kind, brace_depth - 1, delimiter)
                index += 2
                continue
            if character != "\n":
                comments[index] = True
            index += 1
            continue

        if kind == "string-text":
            swift_interpolation = (
                "\\" + ("#" * brace_depth) + "("
                if path_suffix == ".swift"
                else ""
            )
            if swift_interpolation and line.startswith(
                swift_interpolation,
                index,
            ):
                interpolation_end = index + len(swift_interpolation)
                executable[index:interpolation_end] = (
                    b"\x01" * len(swift_interpolation)
                )
                contexts.append(("swift-string-expression", 1, ""))
                index = interpolation_end
                continue
            if character == "\\":
                index += 1 if path_suffix == ".swift" and brace_depth else 2
                continue
            if line.startswith(delimiter, index):
                contexts.pop()
                index += len(delimiter)
                continue
            index += 1
            continue

        if kind == "regex-text":
            if character == "\\":
                index += 2
                continue
            if character in "\r\n":
                contexts.pop()
                executable[index] = True
                index += 1
                continue
            if character == "[" and brace_depth == 0:
                contexts[-1] = (kind, 1, delimiter)
            elif character == "]" and brace_depth == 1:
                contexts[-1] = (kind, 0, delimiter)
            elif character == "/" and brace_depth == 0:
                contexts.pop()
                index += 1
                while index < len(line) and line[index] in "dgimsuvy":
                    index += 1
                continue
            index += 1
            continue

        if kind == "shell-double-text":
            if character == "\\":
                index += 2
                continue
            if character == '"':
                contexts.pop()
                index += 1
                continue
            if character == "$" and index + 1 < len(line) and line[index + 1] == "(":
                executable[index] = True
                executable[index + 1] = True
                contexts.append(("shell-command-substitution", 1, ""))
                index += 2
                continue
            if character == "`":
                executable[index] = True
                contexts.append(("shell-backtick-substitution", 0, "`"))
                index += 1
                continue
            index += 1
            continue

        if kind == "f-string-text":
            if character == "\\":
                index += 2
                continue
            if line.startswith(delimiter, index):
                contexts.pop()
                index += len(delimiter)
                continue
            if character == "{" and index + 1 < len(line) and line[index + 1] == "{":
                index += 2
                continue
            if character == "}" and index + 1 < len(line) and line[index + 1] == "}":
                index += 2
                continue
            if character == "{":
                contexts.append(("f-string-expression", 1, ""))
            index += 1
            continue

        if kind == "template-text":
            if character == "\\":
                index += 2
                continue
            if character == "`":
                contexts.pop()
                index += 1
                continue
            if character == "$" and index + 1 < len(line) and line[index + 1] == "{":
                contexts.append(("template-expression", 1, ""))
                index += 2
                continue
            index += 1
            continue

        if kind == "shell-backtick-substitution" and character == "`":
            executable[index] = True
            contexts.pop()
            index += 1
            continue

        if (
            path_suffix in _C_STYLE_BLOCK_COMMENT_SUFFIXES
            and line.startswith("/*", index)
        ):
            comments[index : index + 2] = b"\x01\x01"
            contexts.append(("block-comment", 1, ""))
            index += 2
            continue

        comment_marker_length = _line_comment_marker_length(
            line,
            index,
            path_suffix,
        )
        if comment_marker_length:
            comment_end = line.find("\n", index + comment_marker_length)
            if comment_end == -1:
                comment_end = len(line)
            comments[index:comment_end] = b"\x01" * (comment_end - index)
            index = comment_end
            continue

        if (
            path_suffix in _JAVASCRIPT_SUFFIXES
            and character == "/"
            and _javascript_regex_literal_starts_at(
                line,
                index,
                executable,
                comments,
            )
        ):
            contexts.append(("regex-text", 0, "/"))
            index += 1
            continue

        executable[index] = True
        if character == "\\" and index + 1 < len(line):
            # Outside a literal, shell uses a backslash to quote the next
            # character (notably the close/escaped/reopen idiom: '\\''), and
            # every scanned language uses backslash-newline continuation. The
            # escaped character is data, not a delimiter or grouping token.
            index += 2
            continue
        if is_shell and character == "$" and index + 1 < len(line) and line[index + 1] == "(":
            executable[index + 1] = True
            contexts.append(("shell-command-substitution", 1, ""))
            index += 2
            continue
        if character in ("'", '"'):
            opening_delimiter = (
                character
                if is_shell
                else _quote_delimiter_at(line, index)
            )
            swift_raw_hashes = 0
            if path_suffix == ".swift":
                hash_index = index
                while hash_index > 0 and line[hash_index - 1] == "#":
                    hash_index -= 1
                swift_raw_hashes = index - hash_index
            closing_delimiter = (
                opening_delimiter + ("#" * swift_raw_hashes)
            )
            opening_start = index - swift_raw_hashes
            opening_end = min(
                index + len(opening_delimiter),
                len(line),
            )
            for delimiter_index in range(opening_start, opening_end):
                executable[delimiter_index] = False
            string_kind = (
                "shell-double-text"
                if is_shell and character == '"'
                else (
                    "f-string-text"
                    if _python_f_string_starts_at(line, index)
                    else "string-text"
                )
            )
            contexts.append(
                (string_kind, swift_raw_hashes, closing_delimiter)
            )
            index += len(opening_delimiter)
            continue
        if character == "`":
            if is_shell:
                contexts.append(("shell-backtick-substitution", 0, "`"))
            else:
                executable[index] = False
                contexts.append(("template-text", 0, "`"))
        elif kind in (
            "shell-command-substitution",
            "swift-string-expression",
        ) and character == "(":
            contexts[-1] = (kind, brace_depth + 1, delimiter)
        elif kind in (
            "shell-command-substitution",
            "swift-string-expression",
        ) and character == ")":
            if brace_depth == 1:
                contexts.pop()
            else:
                contexts[-1] = (kind, brace_depth - 1, delimiter)
        elif kind in ("template-expression", "f-string-expression") and character == "{":
            contexts[-1] = (kind, brace_depth + 1, delimiter)
        elif kind in ("template-expression", "f-string-expression") and character == "}":
            if brace_depth == 1:
                contexts.pop()
            else:
                contexts[-1] = (kind, brace_depth - 1, delimiter)
        index += 1

    return bytes(executable), bytes(comments)


@lru_cache(maxsize=128)
def _cached_lexical_positions(
    line: str,
    path_suffix: str,
) -> tuple[bytes, bytes]:
    return _lexical_positions(line, path_suffix)


def _source_lexical_positions(
    line: str,
    path_suffix: str = "",
) -> tuple[bytes, bytes]:
    if len(line) > _LEXER_CACHE_SOURCE_LIMIT:
        return _lexical_positions(line, path_suffix)
    return _cached_lexical_positions(line, path_suffix)


def _executable_code_positions(
    line: str,
    path_suffix: str = "",
) -> bytes:
    return _source_lexical_positions(line, path_suffix)[0]


def _strip_comments(source: str, path_suffix: str) -> str:
    comments = _source_lexical_positions(source, path_suffix)[1]
    if not any(comments):
        return source
    return "".join(
        " " if comments[index] else character
        for index, character in enumerate(source)
    )


def _is_inside_string_literal(
    line: str,
    offset: int,
    path_suffix: str = "",
) -> bool:
    positions = _executable_code_positions(line, path_suffix)
    return 0 <= offset < len(positions) and not positions[offset]


def _call_end(
    line: str,
    opening_paren: int,
    path_suffix: str = "",
) -> int:
    """Return the closing parenthesis offset, or the physical line end."""
    depth = 0
    executable = _executable_code_positions(line, path_suffix)
    for index in range(opening_paren, len(line)):
        if not executable[index]:
            continue
        character = line[index]
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return index
    return len(line)


def _quoted_argument_bounds(
    line: str,
    argument_start: int,
) -> Optional[tuple[int, int]]:
    """Return content bounds for the first quoted positional or keyword argument."""
    index = argument_start
    while index < len(line) and line[index].isspace():
        index += 1

    keyword = re.match(r"[A-Za-z_][A-Za-z0-9_]*\s*=\s*", line[index:])
    if keyword:
        index += len(keyword.group(0))

    # Python string prefixes may precede a shell command string.
    prefix = re.match(r"(?i)(?:[rubf]{1,2})?(?=['\"`])", line[index:])
    if prefix:
        index += len(prefix.group(0))
    if index >= len(line) or line[index] not in ("'", '"', "`"):
        return None

    delimiter = "`" if line[index] == "`" else _quote_delimiter_at(line, index)
    content_start = index + len(delimiter)
    index = content_start
    while index < len(line):
        if line[index] == "\\":
            index += 2
            continue
        if line.startswith(delimiter, index):
            return content_start, index
        index += 1
    return content_start, len(line)


def _trim_bounds(line: str, start: int, end: int) -> tuple[int, int]:
    while start < end and line[start].isspace():
        start += 1
    while end > start and line[end - 1].isspace():
        end -= 1
    return start, end


_ARGUMENT_LABEL = re.compile(
    r"""(?x)
    (?:
        (?P<bare>[A-Za-z_][A-Za-z0-9_]*)\s*(?:=|:)
      | (?P<quote>["'])(?P<quoted>[A-Za-z_][A-Za-z0-9_]*)(?P=quote)\s*:
      | \[\s*(?P<computed_quote>["'`])
        (?P<computed>[A-Za-z_][A-Za-z0-9_]*)
        (?P=computed_quote)\s*\]\s*:
    )
    \s*
    """
)


def _parse_call_argument(
    line: str,
    bounds: tuple[int, int],
) -> _CallArgument:
    start, end = bounds
    label_match = _ARGUMENT_LABEL.match(line[start:end])
    label = (
        next(
            (
                label_match.group(group)
                for group in ("bare", "quoted", "computed")
                if label_match.group(group) is not None
            ),
            None,
        )
        if label_match
        else None
    )
    if label_match:
        start += len(label_match.group(0))
    return _CallArgument(
        value_bounds=_trim_bounds(line, start, end),
        label=label,
    )


def _arguments_in_range(
    line: str,
    start: int,
    end: int,
    path_suffix: str = "",
) -> list[_CallArgument]:
    """Return comma-delimited arguments without splitting nested expressions."""
    executable = _executable_code_positions(line, path_suffix)
    arguments: list[_CallArgument] = []
    argument_start = start
    paren_depth = 0
    bracket_depth = 0
    brace_depth = 0

    for index in range(argument_start, end):
        if not executable[index]:
            continue
        character = line[index]
        if character == "(":
            paren_depth += 1
        elif character == ")":
            paren_depth = max(0, paren_depth - 1)
        elif character == "[":
            bracket_depth += 1
        elif character == "]":
            bracket_depth = max(0, bracket_depth - 1)
        elif character == "{":
            brace_depth += 1
        elif character == "}":
            brace_depth = max(0, brace_depth - 1)
        elif character == "," and not (paren_depth or bracket_depth or brace_depth):
            bounds = _trim_bounds(line, argument_start, index)
            if bounds[0] < bounds[1]:
                arguments.append(_parse_call_argument(line, bounds))
            argument_start = index + 1

    bounds = _trim_bounds(line, argument_start, end)
    if bounds[0] < bounds[1]:
        arguments.append(_parse_call_argument(line, bounds))
    return arguments


def _call_arguments(
    line: str,
    opening_paren: int,
    path_suffix: str = "",
) -> list[_CallArgument]:
    """Return top-level call arguments without splitting nested expressions."""
    return _arguments_in_range(
        line,
        opening_paren + 1,
        _call_end(line, opening_paren, path_suffix),
        path_suffix,
    )


def _object_properties(
    line: str,
    bounds: tuple[int, int],
    path_suffix: str = "",
) -> list[_CallArgument]:
    """Return the top-level properties of an object literal argument."""
    start, end = _trim_bounds(line, *bounds)
    if end - start < 2 or line[start] != "{" or line[end - 1] != "}":
        return []
    return _arguments_in_range(line, start + 1, end - 1, path_suffix)


def _select_labeled_argument(
    arguments: list[_CallArgument],
    labels: frozenset[str],
) -> Optional[_CallArgument]:
    return next(
        (
            argument
            for argument in arguments
            if argument.label is not None
            and argument.label.lower() in labels
        ),
        None,
    )


def _select_call_argument(
    arguments: list[_CallArgument],
    labels: frozenset[str],
    positional_index: int,
) -> Optional[_CallArgument]:
    if labeled := _select_labeled_argument(arguments, labels):
        return labeled

    positional_arguments = [
        argument
        for argument in arguments
        if argument.label is None
    ]
    if positional_index >= len(positional_arguments):
        return None
    return positional_arguments[positional_index]


def _argv_source_ranges(
    line: str,
    opening_paren: int,
    path_suffix: str = "",
    object_command_labels: frozenset[str] = _NO_ARGUMENT_LABELS,
) -> list[tuple[int, int]]:
    """Return only command/argv inputs, excluding later launcher options."""
    arguments = _call_arguments(line, opening_paren, path_suffix)
    if not arguments:
        return []

    command_argument = _select_call_argument(
        arguments,
        _ARGV_COMMAND_LABELS,
        positional_index=0,
    )
    if command_argument is None:
        return []

    first = command_argument.value_bounds
    if object_command_labels and line[first[0] : first[0] + 1] == "{":
        object_command = _select_labeled_argument(
            _object_properties(line, first, path_suffix),
            object_command_labels,
        )
        return [object_command.value_bounds] if object_command is not None else []

    ranges = [first]
    if (
        command_argument.label is not None
        or line[first[0] : first[0] + 1] in ("(", "[")
    ):
        return ranges

    positional_arguments = [
        argument
        for argument in arguments
        if argument.label is None
    ]
    if len(positional_arguments) > 1:
        second = positional_arguments[1].value_bounds
        if line[second[0] : second[0] + 1] in ("(", "["):
            ranges.append(second)
    return ranges


def _argv_element(
    line: str,
    bounds: tuple[int, int],
) -> _ArgvElement:
    """Return an argv element while retaining dynamic positional slots."""
    start, end = _trim_bounds(line, *bounds)
    prefix = re.match(r"(?i)(?:[rubf]{1,2})?(?=['\"`])", line[start:end])
    quote_start = start + len(prefix.group(0)) if prefix else start
    if quote_start >= end or line[quote_start] not in ("'", '"', "`"):
        return _ArgvElement((start, end), None)

    delimiter = (
        "`"
        if line[quote_start] == "`"
        else _quote_delimiter_at(line, quote_start)
    )
    literal_bounds = _quoted_argument_bounds(line, start)
    if (
        literal_bounds is None
        or literal_bounds[1] + len(delimiter) != end
    ):
        return _ArgvElement((start, end), None)
    return _ArgvElement(
        literal_bounds,
        line[literal_bounds[0] : literal_bounds[1]],
    )


def _argv_range_elements(
    line: str,
    bounds: tuple[int, int],
    path_suffix: str,
) -> list[_ArgvElement]:
    """Split one command source range into top-level argv elements."""
    start, end = _trim_bounds(line, *bounds)
    if start >= end or line[start] not in ("(", "["):
        return [_argv_element(line, (start, end))]

    opening = line[start]
    closing = ")" if opening == "(" else "]"
    executable = _executable_code_positions(line, path_suffix)
    depth = 0
    container_end: Optional[int] = None
    for index in range(start, end):
        if not executable[index]:
            continue
        if line[index] == opening:
            depth += 1
        elif line[index] == closing:
            depth -= 1
            if depth == 0:
                container_end = index
                break
    if container_end is None:
        return []

    return [
        _argv_element(line, argument.value_bounds)
        for argument in _arguments_in_range(
            line,
            start + 1,
            container_end,
            path_suffix,
        )
    ]


def _argv_elements(
    line: str,
    opening_paren: int,
    path_suffix: str = "",
    object_command_labels: frozenset[str] = _NO_ARGUMENT_LABELS,
) -> list[_ArgvElement]:
    """Return positional argv elements when argv[0] is a quoted literal."""
    ranges = _argv_source_ranges(
        line,
        opening_paren,
        path_suffix,
        object_command_labels,
    )
    if not ranges:
        return []

    elements = [
        element
        for source_range in ranges
        for element in _argv_range_elements(
            line,
            source_range,
            path_suffix,
        )
    ]
    if not elements or elements[0].literal is None:
        return []
    return elements


_SHELL_ASSIGNMENT_WORD = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_SHELL_REDIRECTION_PREFIX = re.compile(
    r"^(?:\d+|\{[A-Za-z_][A-Za-z0-9_]*\})?"
    r"(?:<<<|<<-|<<|<>|&>>|&>|>>|>\||<&|>&|<|>)"
)
_COMMAND_WRAPPER_SPECS = {
    "builtin": _CommandWrapperSpec(frozenset()),
    "command": _CommandWrapperSpec(frozenset()),
    "env": _CommandWrapperSpec(
        frozenset({"-C", "--chdir", "-S", "--split-string", "-u", "--unset"}),
        allows_assignments=True,
    ),
    "exec": _CommandWrapperSpec(frozenset()),
    "gtimeout": _CommandWrapperSpec(
        frozenset({"-k", "--kill-after", "-s", "--signal"}),
        leading_operands=1,
    ),
    "nice": _CommandWrapperSpec(
        frozenset({"-n", "--adjustment"}),
    ),
    "nohup": _CommandWrapperSpec(frozenset()),
    "sudo": _CommandWrapperSpec(
        frozenset(
            {
                "-C",
                "--close-from",
                "-D",
                "--chdir",
                "-R",
                "--chroot",
                "-T",
                "--command-timeout",
                "-U",
                "--other-user",
                "-a",
                "--auth-type",
                "-c",
                "--login-class",
                "-g",
                "--group",
                "-h",
                "--host",
                "-p",
                "--prompt",
                "-r",
                "--role",
                "-t",
                "--type",
                "-u",
                "--user",
            }
        ),
        allows_assignments=True,
    ),
    "time": _CommandWrapperSpec(
        frozenset({"-f", "--format", "-o", "--output"}),
    ),
    "timeout": _CommandWrapperSpec(
        frozenset({"-k", "--kill-after", "-s", "--signal"}),
        leading_operands=1,
    ),
}
_SHELL_CONTROL_FLOW_PREFIXES = frozenset(
    {"!", "do", "elif", "else", "if", "then", "until", "while", "{"}
)


def _is_shell_command_separator(
    line: str,
    index: int,
    executable: bytes,
) -> bool:
    """Return whether an executable shell metacharacter splits commands."""
    character = line[index]
    if character not in ";|&\n":
        return False
    if character in ";\n":
        return True

    previous = line[index - 1] if index > 0 and executable[index - 1] else ""
    following = (
        line[index + 1]
        if index + 1 < len(line) and executable[index + 1]
        else ""
    )
    if character == "&" and (previous in "<>" or following == ">"):
        return False
    return not (character == "|" and previous == ">")


def _shell_command_region_bounds(
    line: str,
    offset: int,
) -> tuple[int, int]:
    """Return the shell command region containing an executable offset."""
    executable = _executable_code_positions(line, ".sh")
    contexts: list[str] = []
    starts = [0]

    for index in range(min(offset, len(line))):
        if not executable[index]:
            continue
        character = line[index]
        if character == "(":
            contexts.append("paren")
            starts.append(index + 1)
        elif character == ")":
            if contexts and contexts[-1] == "paren":
                contexts.pop()
                starts.pop()
            else:
                # An unmatched close parenthesis terminates a shell case arm's
                # pattern. The command list begins immediately after it.
                starts[-1] = index + 1
        elif character == "`":
            if contexts and contexts[-1] == "backtick":
                contexts.pop()
                starts.pop()
            else:
                contexts.append("backtick")
                starts.append(index + 1)
        elif _is_shell_command_separator(line, index, executable):
            starts[-1] = index + 1

    start = starts[-1]
    base_depth = len(contexts)
    for index in range(offset, len(line)):
        if not executable[index]:
            continue
        character = line[index]
        if character == "(":
            contexts.append("paren")
        elif character == ")":
            if len(contexts) == base_depth and contexts[-1:] == ["paren"]:
                return start, index
            if contexts and contexts[-1] == "paren":
                contexts.pop()
        elif character == "`":
            if contexts and contexts[-1] == "backtick":
                if len(contexts) == base_depth:
                    return start, index
                contexts.pop()
            else:
                contexts.append("backtick")
        elif (
            _is_shell_command_separator(line, index, executable)
            and len(contexts) == base_depth
        ):
            return start, index
    return start, len(line)


def _shell_redirection_next_index(
    line: str,
    words: list[tuple[int, int]],
    index: int,
) -> Optional[int]:
    """Return the word after a shell redirection and its optional operand."""
    start, end = words[index]
    raw = line[start:end]
    match = _SHELL_REDIRECTION_PREFIX.match(raw)
    if match is None:
        return None

    executable = _executable_code_positions(line, ".sh")
    if not all(executable[start + offset] for offset in range(match.end())):
        return None
    if match.end() < len(raw):
        return index + 1
    return min(len(words), index + 2)


def _shell_next_non_redirection_index(
    line: str,
    words: list[tuple[int, int]],
    index: int,
) -> int:
    while index < len(words):
        next_index = _shell_redirection_next_index(
            line,
            words,
            index,
        )
        if next_index is None:
            break
        index = next_index
    return index


def _command_wrapper_nested_index(
    arguments: list[Optional[str]],
    wrapper_index: int,
    spec: _CommandWrapperSpec,
) -> Optional[int]:
    """Return the nested command index after a wrapper's own arguments."""
    index = wrapper_index + 1
    while index < len(arguments):
        argument = arguments[index]
        if argument is None:
            return None
        if argument == "--":
            index += 1
            break

        flag, separator, _ = argument.partition("=")
        if flag in spec.options_with_values:
            index += 1
            if not separator and index < len(arguments):
                index += 1
            continue
        if argument.startswith("-"):
            index += 1
            continue
        break

    operands_remaining = spec.leading_operands
    while operands_remaining and index < len(arguments):
        index += 1
        operands_remaining -= 1

    if spec.allows_assignments:
        while index < len(arguments):
            argument = arguments[index]
            if argument is None:
                return None
            if not _SHELL_ASSIGNMENT_WORD.match(argument):
                break
            index += 1
    return index


def _command_executable_index(
    arguments: list[Optional[str]],
    start_index: int = 0,
) -> Optional[int]:
    """Resolve nested command wrappers to the executable token."""
    index = start_index
    while index < len(arguments):
        command = arguments[index]
        if command is None:
            return None
        command_name = command.rsplit("/", 1)[-1]
        spec = _COMMAND_WRAPPER_SPECS.get(command_name)
        if spec is None:
            return index
        index = _command_wrapper_nested_index(
            arguments,
            index,
            spec,
        )
        if index is None:
            return None
    return None


def _shell_command_word_bounds(
    line: str,
    offset: int,
) -> Optional[tuple[int, int]]:
    """Return the shell word that owns command position around an offset."""
    start, end = _shell_command_region_bounds(line, offset)
    words = _shell_word_bounds(line, start, end)
    index = 0
    while index < len(words):
        if index == 0:
            if (body_start := _shell_function_prefix_end(line, words)) is not None:
                index = body_start
                continue
        if (next_index := _shell_redirection_next_index(line, words, index)) is not None:
            index = next_index
            continue
        raw = line[words[index][0] : words[index][1]]
        is_unquoted = raw[:1] not in ("'", '"')
        if is_unquoted and _SHELL_ASSIGNMENT_WORD.match(raw):
            index += 1
            continue
        command, _ = _shell_word_value_and_bounds(line, words[index])
        command_name = command.rsplit("/", 1)[-1]
        if is_unquoted and command_name in _SHELL_CONTROL_FLOW_PREFIXES:
            index += 1
            continue
        if command_name in _COMMAND_WRAPPER_SPECS:
            wrapper_words: list[tuple[int, int]] = []
            wrapper_index = index
            while wrapper_index < len(words):
                wrapper_index = _shell_next_non_redirection_index(
                    line,
                    words,
                    wrapper_index,
                )
                if wrapper_index >= len(words):
                    break
                wrapper_words.append(words[wrapper_index])
                wrapper_index += 1
            wrapper_arguments = [
                _shell_word_value_and_bounds(line, word)[0]
                for word in wrapper_words
            ]
            executable_index = _command_executable_index(
                wrapper_arguments,
            )
            return (
                wrapper_words[executable_index]
                if executable_index is not None
                else None
            )
        return words[index]
    return None


def _shell_statement_end(line: str, start: int) -> int:
    executable = _executable_code_positions(line, ".sh")
    for index in range(start, len(line)):
        if executable[index] and _is_shell_command_separator(line, index, executable):
            return index
    return len(line)


def _shell_word_bounds(
    line: str,
    start: int,
    end: int,
) -> list[tuple[int, int]]:
    """Return shell words while preserving their source offsets."""
    executable = _executable_code_positions(line, ".sh")
    words: list[tuple[int, int]] = []
    index = start
    while index < end:
        while index < end:
            if executable[index] and line[index].isspace():
                index += 1
                continue
            if (
                executable[index]
                and line[index] == "\\"
                and index + 1 < end
                and line[index + 1] == "\n"
            ):
                index += 2
                continue
            break
        if index >= end or (
            executable[index]
            and _is_shell_command_separator(line, index, executable)
        ):
            break
        word_start = index
        while index < end:
            if (
                executable[index]
                and line[index] == "\\"
                and index + 1 < end
                and line[index + 1] == "\n"
            ):
                index += 2
                continue
            if executable[index] and (
                line[index].isspace()
                or _is_shell_command_separator(line, index, executable)
            ):
                break
            index += 1
        words.append((word_start, index))
    return words


def _shell_word_value_and_bounds(
    line: str,
    bounds: tuple[int, int],
) -> tuple[str, tuple[int, int]]:
    start, end = bounds
    if end - start >= 2 and line[start] in ("'", '"') and line[end - 1] == line[start]:
        start += 1
        end -= 1
    return line[start:end], (start, end)


def _shell_function_prefix_end(
    line: str,
    words: list[tuple[int, int]],
) -> Optional[int]:
    """Return the first body-command index for a shell function definition."""
    if not words:
        return None
    values = [
        _shell_word_value_and_bounds(line, word)[0]
        for word in words
    ]
    if values[0].endswith("()") and len(values) > 1 and values[1] == "{":
        return 2
    if (
        len(values) > 2
        and values[1] == "()"
        and values[2] == "{"
    ):
        return 3
    if values[0] == "function":
        index = 2
        if len(values) > 1 and values[1].endswith("()"):
            index = 2
        if len(values) > index and values[index] == "{":
            return index + 1
    if values[0] == "{":
        return 1
    return None


def _shell_env_split_source_bounds(
    line: str,
    offset: int,
) -> Optional[tuple[int, int]]:
    """Return the command range consumed by a shell-form ``env -S`` wrapper."""
    statement_start, statement_end = _shell_command_region_bounds(line, offset)
    words = _shell_word_bounds(line, statement_start, statement_end)
    index = 0
    while index < len(words):
        if (next_index := _shell_redirection_next_index(line, words, index)) is not None:
            index = next_index
            continue
        raw = line[words[index][0] : words[index][1]]
        value, _ = _shell_word_value_and_bounds(line, words[index])
        if raw[:1] not in ("'", '"') and _SHELL_ASSIGNMENT_WORD.match(raw):
            index += 1
            continue
        if value.rsplit("/", 1)[-1] != "env":
            return None
        index += 1
        break
    if index == 0 or index >= len(words):
        return None

    while index < len(words):
        value, bounds = _shell_word_value_and_bounds(line, words[index])
        if value in ("-S", "--split-string"):
            if index + 1 >= len(words):
                return None
            source_word = words[index + 1]
            _source_value, source_bounds = _shell_word_value_and_bounds(
                line,
                source_word,
            )
            source_end = (
                source_bounds[1]
                if line[source_word[0] : source_word[1]].startswith(("'", '"'))
                else statement_end
            )
            return (source_bounds[0], source_end)
        if value.startswith("-S") and len(value) > 2:
            return (bounds[0] + 2, bounds[1])
        if value.startswith("--split-string="):
            return (bounds[0] + len("--split-string="), bounds[1])
        if value in ("-C", "--chdir", "-u", "--unset"):
            index += 2
            continue
        if value.startswith("-") or _SHELL_ASSIGNMENT_WORD.match(value):
            index += 1
            continue
        return None
    return None


def _evaluated_source_argument_bounds(
    line: str,
    arguments: list[tuple[int, int]],
    spec: _InterpreterSourceSpec,
) -> Optional[tuple[int, int]]:
    index = 0
    while index < len(arguments):
        argument, argument_bounds = _shell_word_value_and_bounds(
            line,
            arguments[index],
        )
        if argument == "--":
            return None

        flag, separator, _ = argument.partition("=")
        if spec.source_flag_pattern.fullmatch(flag):
            if separator:
                source_start = argument_bounds[0] + len(flag) + 1
                source_bounds = (source_start, argument_bounds[1])
                return _quoted_argument_bounds(line, source_start) or source_bounds
            if index + 1 >= len(arguments):
                return None
            source_start = arguments[index + 1][0]
            return _quoted_argument_bounds(line, source_start) or arguments[index + 1]

        if argument in spec.options_with_values:
            index += 2
            continue
        if argument.startswith(("-", "+")):
            index += 1
            continue
        return None
    return None


def _interpreter_source_spec(executable: str) -> Optional[_InterpreterSourceSpec]:
    executable_name = executable.rsplit("/", 1)[-1]
    return next(
        (
            spec
            for spec in _INTERPRETER_SOURCE_SPECS
            if spec.executable_pattern.fullmatch(executable_name)
        ),
        None,
    )


def _interpreter_command_source_bounds(
    line: str,
    command_end: int,
    spec: _InterpreterSourceSpec,
) -> Optional[tuple[int, int]]:
    statement_end = _shell_statement_end(line, command_end)
    words = _shell_word_bounds(line, command_end, statement_end)
    return _evaluated_source_argument_bounds(line, words, spec)


def _shell_eval_target_ranges(
    line: str,
    argument_start: int,
    verb_start: int,
) -> list[tuple[int, int]]:
    statement_end = _shell_statement_end(line, argument_start)
    arguments = _shell_word_bounds(line, argument_start, statement_end)
    source_parts: list[str] = []
    source_length = 0
    source_verb_start: Optional[int] = None

    for argument in arguments:
        value, value_bounds = _shell_word_value_and_bounds(line, argument)
        if source_parts:
            source_length += 1
        if _bounds_contain_offset(value_bounds, verb_start):
            source_verb_start = source_length + verb_start - value_bounds[0]
        source_parts.append(value)
        source_length += len(value)

    if source_verb_start is None:
        return []
    source = " ".join(source_parts)
    nested_match = next(
        (
            match
            for match in _NETWORK_VERB.finditer(source)
            if match.start() <= source_verb_start < match.end()
        ),
        None,
    )
    if nested_match is None:
        return []
    nested_targets = _network_target_ranges(source, nested_match, ".sh")
    if not any(
        _contains_public_network_url(source[start:end])
        for start, end in nested_targets
    ):
        return []
    statement_start, _ = _shell_command_region_bounds(line, verb_start)
    return [(statement_start, statement_end)]


def _call_uses_explicit_shell(
    line: str,
    opening_paren: int,
    path_suffix: str = "",
) -> bool:
    arguments = _call_arguments(line, opening_paren, path_suffix)
    candidates = list(arguments)
    if path_suffix in _JAVASCRIPT_SUFFIXES:
        for argument in arguments:
            candidates.extend(
                _object_properties(line, argument.value_bounds, path_suffix)
            )

    shell_mode = _select_labeled_argument(candidates, _SHELL_MODE_LABELS)
    if shell_mode is None:
        return False

    start, end = shell_mode.value_bounds
    raw_value = line[start:end].strip()
    if raw_value in ("True", "true"):
        return True

    # Python accepts any truthy value for ``shell``.  Keep the detector
    # conservative, but recognize numeric literals whose truthiness is known
    # without evaluating arbitrary test code (for example ``shell=1``).
    if re.fullmatch(r"[+-]?(?:[1-9]\d*|0[xX][0-9a-fA-F]+)", raw_value):
        return True

    quoted = _quoted_argument_bounds(line, start)
    return quoted is not None and quoted[0] < quoted[1] < end


def _argv_interpreter_source_context(
    line: str,
    opening_paren: int,
    path_suffix: str = "",
    object_command_labels: frozenset[str] = _NO_ARGUMENT_LABELS,
) -> Optional[tuple[tuple[int, int], _InterpreterSourceSpec]]:
    """Return a known interpreter's evaluated source range and language spec."""
    elements = _argv_elements(
        line,
        opening_paren,
        path_suffix,
        object_command_labels,
    )
    token_index = _argv_executable_index(elements)
    if token_index is None or len(elements) - token_index < 2:
        return None

    executable = elements[token_index].literal
    if executable is None:
        return None
    spec = _interpreter_source_spec(executable)
    if spec is None:
        return None
    source_bounds = _evaluated_source_argument_bounds(
        line,
        [element.value_bounds for element in elements[token_index + 1 :]],
        spec,
    )
    return (source_bounds, spec) if source_bounds is not None else None


def _argv_interpreter_source_bounds(
    line: str,
    opening_paren: int,
    path_suffix: str = "",
    object_command_labels: frozenset[str] = _NO_ARGUMENT_LABELS,
) -> Optional[tuple[int, int]]:
    """Return the argv word a known interpreter consumes as evaluated source."""
    context = _argv_interpreter_source_context(
        line,
        opening_paren,
        path_suffix,
        object_command_labels,
    )
    return context[0] if context is not None else None


def _interpreter_source_suffix(spec: _InterpreterSourceSpec) -> str:
    if spec is _SHELL_SOURCE_SPEC:
        return ".sh"
    if spec is _PYTHON_SOURCE_SPEC:
        return ".py"
    return ".ts"


def _nested_network_source_target_ranges(
    line: str,
    source_bounds: tuple[int, int],
    verb_start: int,
    path_suffix: str,
    require_public_url: bool = True,
) -> list[tuple[int, int]]:
    """Resolve a network verb inside a command string using that language's rules."""
    if not _bounds_contain_offset(source_bounds, verb_start):
        return []
    source_start, source_end = source_bounds
    source = line[source_start:source_end]
    relative_verb_start = verb_start - source_start
    nested_match = next(
        (
            nested
            for nested in _NETWORK_VERB.finditer(source)
            if nested.start() <= relative_verb_start < nested.end()
        ),
        None,
    )
    if nested_match is None:
        return []
    nested_ranges = _network_target_ranges(source, nested_match, path_suffix)
    if require_public_url and not any(
        _contains_public_network_url(source[start:end])
        for start, end in nested_ranges
    ):
        return []
    return [
        (source_start + start, source_start + end)
        for start, end in nested_ranges
    ]


def _argv_env_split_source_bounds(
    line: str,
    opening_paren: int,
    path_suffix: str,
    object_command_labels: frozenset[str],
) -> Optional[tuple[int, int]]:
    """Return the command string consumed by an argv-form ``env -S`` wrapper."""
    elements = _argv_elements(
        line,
        opening_paren,
        path_suffix,
        object_command_labels,
    )
    if not elements or elements[0].literal is None:
        return None
    if elements[0].literal.rsplit("/", 1)[-1] != "env":
        return None

    index = 1
    while index < len(elements):
        value = elements[index].literal
        if value is None:
            return None
        bounds = elements[index].value_bounds
        if value in ("-S", "--split-string"):
            return (
                elements[index + 1].value_bounds
                if index + 1 < len(elements)
                else None
            )
        if value.startswith("-S") and len(value) > 2:
            return (bounds[0] + 2, bounds[1])
        if value.startswith("--split-string="):
            return (bounds[0] + len("--split-string="), bounds[1])
        if value in ("-C", "--chdir", "-u", "--unset"):
            index += 2
            continue
        if value.startswith("-") or _SHELL_ASSIGNMENT_WORD.match(value):
            index += 1
            continue
        return None
    return None


def _argv_executable_index(
    elements: list[_ArgvElement],
) -> Optional[int]:
    if not elements:
        return None
    return _command_executable_index(
        [element.literal for element in elements]
    )


def _argv_executable_bounds(
    line: str,
    opening_paren: int,
    path_suffix: str = "",
    object_command_labels: frozenset[str] = _NO_ARGUMENT_LABELS,
) -> Optional[tuple[int, int]]:
    elements = _argv_elements(
        line,
        opening_paren,
        path_suffix,
        object_command_labels,
    )
    index = _argv_executable_index(elements)
    return elements[index].value_bounds if index is not None else None


def _bounds_contain_offset(bounds: tuple[int, int], offset: int) -> bool:
    return bounds[0] <= offset < bounds[1]


def _concatenated_literal_source(
    line: str,
    bounds: tuple[int, int],
) -> Optional[str]:
    """Reconstruct adjacent quoted literals joined by ``+`` from one argument."""
    start, end = _trim_bounds(line, *bounds)
    cursor = start
    parts: list[str] = []
    while cursor < end:
        while cursor < end and line[cursor].isspace():
            cursor += 1
        if cursor >= end:
            break
        literal = _quoted_argument_bounds(line, cursor)
        if literal is None:
            return None
        content_start, content_end = literal
        quote_start = cursor
        prefix = re.match(r"(?i)(?:[rubf]{1,2})?(?=['\"`])", line[cursor:end])
        if prefix is not None:
            quote_start += len(prefix.group(0))
        delimiter = (
            "`"
            if line[quote_start] == "`"
            else _quote_delimiter_at(line, quote_start)
        )
        parts.append(line[content_start:content_end])
        cursor = content_end + len(delimiter)
        while cursor < end and line[cursor].isspace():
            cursor += 1
        if cursor >= end:
            break
        if line[cursor] != "+":
            return None
        cursor += 1
    return "".join(parts) if parts else None


def _explicit_shell_literal_target_ranges(
    line: str,
    opening_paren: int,
    path_suffix: str,
) -> list[tuple[int, int]]:
    """Return a command argument range when explicit shell code is hardcoded."""
    if not _call_uses_explicit_shell(line, opening_paren, path_suffix):
        return []
    arguments = _call_arguments(line, opening_paren, path_suffix)
    command_argument = _select_call_argument(
        arguments,
        _ARGV_COMMAND_LABELS,
        0,
    )
    if command_argument is None:
        return []
    source = _concatenated_literal_source(line, command_argument.value_bounds)
    if source is None or not _contains_public_network_url(source):
        return []
    if _live_network_verb_offsets(source, ".sh"):
        return [command_argument.value_bounds]
    return []


def _argv_execution_target_ranges(
    line: str,
    opening_paren: int,
    verb_start: int,
    path_suffix: str,
    object_command_labels: frozenset[str] = _NO_ARGUMENT_LABELS,
) -> list[tuple[int, int]]:
    interpreter_context = _argv_interpreter_source_context(
        line,
        opening_paren,
        path_suffix,
        object_command_labels,
    )
    if interpreter_context is not None:
        evaluated_source, source_spec = interpreter_context
        if _bounds_contain_offset(evaluated_source, verb_start):
            return _nested_network_source_target_ranges(
                line,
                evaluated_source,
                verb_start,
                _interpreter_source_suffix(source_spec),
            )

    env_split_source = _argv_env_split_source_bounds(
        line,
        opening_paren,
        path_suffix,
        object_command_labels,
    )
    if env_split_source is not None:
        env_split_ranges = _nested_network_source_target_ranges(
            line,
            env_split_source,
            verb_start,
            ".sh",
        )
        if env_split_ranges:
            return env_split_ranges
        if _bounds_contain_offset(env_split_source, verb_start):
            return []

    literal_ranges = _explicit_shell_literal_target_ranges(
        line,
        opening_paren,
        path_suffix,
    )
    if literal_ranges:
        return literal_ranges

    executable_bounds = _argv_executable_bounds(
        line,
        opening_paren,
        path_suffix,
        object_command_labels,
    )
    if executable_bounds is None or not _bounds_contain_offset(
        executable_bounds,
        verb_start,
    ):
        return []

    command = line[executable_bounds[0] : executable_bounds[1]]
    if any(character.isspace() for character in command) and not _call_uses_explicit_shell(
        line,
        opening_paren,
        path_suffix,
    ):
        return []

    source_ranges = _argv_source_ranges(
        line,
        opening_paren,
        path_suffix,
        object_command_labels,
    )
    if not source_ranges:
        return []
    return [(verb_start, source_ranges[0][1]), *source_ranges[1:]]


def _launcher_target_ranges(
    line: str,
    verb_start: int,
    path_suffix: str,
) -> list[tuple[int, int]]:
    for launcher in _SHELL_CALL_LAUNCHER.finditer(line):
        if launcher.start() >= verb_start:
            break
        if _is_inside_string_literal(line, launcher.start(), path_suffix):
            continue
        opening_paren = line.find("(", launcher.start(), launcher.end())
        if opening_paren == -1:
            continue
        arguments = _call_arguments(line, opening_paren, path_suffix)
        if not arguments:
            continue
        command_bounds = arguments[0].value_bounds
        first_literal = _quoted_argument_bounds(line, command_bounds[0])
        if (
            first_literal is not None
            and first_literal[1] <= command_bounds[1]
            and _bounds_contain_offset(command_bounds, verb_start)
        ):
            return [command_bounds]

    for launcher in _ARGV_CALL_LAUNCHER.finditer(line):
        if launcher.start() >= verb_start:
            break
        if _is_inside_string_literal(line, launcher.start(), path_suffix):
            continue
        opening_paren = line.find("(", launcher.start(), launcher.end())
        if opening_paren == -1:
            continue
        ranges = _argv_execution_target_ranges(
            line,
            opening_paren,
            verb_start,
            path_suffix,
            (
                _BUN_OBJECT_COMMAND_LABELS
                if launcher.group("bun") is not None
                else _NO_ARGUMENT_LABELS
            ),
        )
        if ranges:
            return ranges

    if path_suffix == ".sh":
        command_word = _shell_command_word_bounds(line, verb_start)
        if command_word is not None:
            executable, _ = _shell_word_value_and_bounds(
                line,
                command_word,
            )
            spec = _interpreter_source_spec(executable)
            if spec is not None:
                bounds = _interpreter_command_source_bounds(
                    line,
                    command_word[1],
                    spec,
                )
                if bounds is not None and _bounds_contain_offset(
                    bounds,
                    verb_start,
                ):
                    statement_start, _ = _shell_command_region_bounds(
                        line,
                        verb_start,
                    )
                    return [(statement_start, bounds[1])]
    else:
        for launcher in _SHELL_COMMAND_LAUNCHER.finditer(line):
            if launcher.start() >= verb_start:
                break
            if _is_inside_string_literal(
                line,
                launcher.start(),
                path_suffix,
            ):
                continue
            bounds = _interpreter_command_source_bounds(
                line,
                launcher.end(),
                _SHELL_SOURCE_SPEC,
            )
            if bounds is not None and _bounds_contain_offset(
                bounds,
                verb_start,
            ):
                return [bounds]

    if path_suffix == ".sh":
        for launcher in _SHELL_EVAL_LAUNCHER.finditer(line):
            if launcher.start() >= verb_start:
                break
            command_word = _shell_command_word_bounds(line, launcher.start())
            if command_word is None or not _bounds_contain_offset(
                command_word,
                launcher.start(),
            ):
                continue
            ranges = _shell_eval_target_ranges(
                line,
                launcher.end(),
                verb_start,
            )
            if ranges:
                return ranges
    return []


def _network_target_spec(matched_verb: str) -> _NetworkTargetSpec:
    return next(
        spec
        for spec in _NETWORK_TARGET_SPECS
        if spec.verb_pattern.search(matched_verb)
    )


def _fluent_client_kind(matched_verb: str) -> Optional[str]:
    normalized = matched_verb.lstrip().lower()
    if normalized.startswith("axios.create"):
        return "axios"
    if normalized.startswith(("httpx.client", "httpx.asyncclient")):
        return "httpx"
    return None


def _fluent_terminal_opening_paren(
    line: str,
    constructor_opening_paren: int,
    client_kind: str,
    path_suffix: str,
) -> Optional[int]:
    constructor_end = _call_end(
        line,
        constructor_opening_paren,
        path_suffix,
    )
    if constructor_end >= len(line):
        return None
    terminal_start = constructor_end + 1
    # A constructor can be wrapped in one or more grouping parentheses before
    # the fluent request method (for example ``(axios.create(...)).get(...)``).
    # Skip only closing delimiters and whitespace here; the constructor call
    # itself was already bounded by ``_call_end``.
    while terminal_start < len(line):
        if line[terminal_start].isspace() or line[terminal_start] == ")":
            terminal_start += 1
            continue
        break
    terminal = _FLUENT_TERMINAL_CALLS[client_kind].match(
        line,
        terminal_start,
    )
    return terminal.end() - 1 if terminal is not None else None


def _fluent_base_target_ranges(
    line: str,
    constructor_opening_paren: Optional[int],
    terminal_target: _CallArgument,
    path_suffix: str,
) -> list[tuple[int, int]]:
    """Return a fluent client's base URL when its request target is relative."""
    if constructor_opening_paren is None:
        return []
    target_start, target_end = terminal_target.value_bounds
    if _URL.search(line[target_start:target_end]):
        return []

    base_target = _fluent_constructor_base_target(
        line,
        constructor_opening_paren,
        path_suffix,
    )
    return [base_target.value_bounds] if base_target is not None else []


def _fluent_constructor_base_target(
    source: str,
    constructor_opening_paren: int,
    path_suffix: str,
) -> Optional[_CallArgument]:
    """Return a fluent constructor's explicit base-URL argument."""
    constructor_arguments = _call_arguments(
        source,
        constructor_opening_paren,
        path_suffix,
    )
    candidates = list(constructor_arguments)
    for argument in constructor_arguments:
        candidates.extend(
            _object_properties(source, argument.value_bounds, path_suffix)
        )
    return _select_labeled_argument(
        candidates,
        _NETWORK_BASE_TARGET_LABELS,
    )


def _javascript_assignment_is_instance_field(
    source: str,
    constructor_start: int,
    path_suffix: str,
    match: re.Match[str],
) -> bool:
    """Return whether an assignment declares an instance class field."""
    if (
        path_suffix not in _JAVASCRIPT_SUFFIXES
        or match.group("declaration") is not None
        or "static" in match.group("modifiers").split()
        or "." in match.group("binding")
    ):
        return False

    executable = _executable_code_positions(source, path_suffix)
    brace_stack: list[int] = []
    for index in range(constructor_start):
        if not executable[index]:
            continue
        if source[index] == "{":
            brace_stack.append(index)
        elif source[index] == "}" and brace_stack:
            brace_stack.pop()
    if not brace_stack:
        return False

    class_brace = brace_stack[-1]
    window_start = max(0, class_brace - 2048)
    declaration = "".join(
        source[index] if executable[index] else " "
        for index in range(window_start, class_brace)
    )
    return bool(re.search(r"\bclass\b[^{};]*$", declaration))


def _fluent_assignment_binding(
    source: str,
    constructor_start: int,
    constructor_end: int,
    path_suffix: str,
) -> Optional[tuple[str, str, bool]]:
    """Return a simple assignment or Python context-manager binding."""
    window_floor = max(0, constructor_start - 512)
    window_start = source.rfind("\n", 0, window_floor) + 1
    match = _FLUENT_CLIENT_ASSIGNMENT.search(
        source[window_start:constructor_start]
    )
    if match is not None:
        binding = re.sub(r"\s*\.\s*", ".", match.group("binding"))
        is_instance_field = _javascript_assignment_is_instance_field(
            source,
            constructor_start,
            path_suffix,
            match,
        )
        if is_instance_field:
            binding = f"this.{binding}"
        return binding, match.group("indent"), is_instance_field

    if path_suffix != ".py":
        return None
    line_end = source.find("\n", constructor_end)
    if line_end == -1:
        line_end = len(source)
    context_binding = re.match(
        r"\s+as\s+([A-Za-z_][A-Za-z0-9_]*)\s*:",
        source[constructor_end + 1 : line_end],
    )
    if context_binding is None:
        return None
    body_start = line_end + 1
    while body_start < len(source):
        body_end = source.find("\n", body_start)
        if body_end == -1:
            body_end = len(source)
        body_line = source[body_start:body_end]
        if body_line.strip():
            body_indent = re.match(r"[ \t]*", body_line)
            if body_indent is not None:
                return context_binding.group(1), body_indent.group(0), False
            return None
        body_start = body_end + 1
    return None


def _python_binding_scope_end(
    source: str,
    constructor_end: int,
    binding_indent: str,
) -> int:
    """Bound a local Python binding to its indentation scope."""
    if not binding_indent:
        return len(source)
    line_start = source.find("\n", constructor_end)
    if line_start == -1:
        return len(source)
    line_start += 1
    while line_start < len(source):
        line_end = source.find("\n", line_start)
        if line_end == -1:
            line_end = len(source)
        physical_line = source[line_start:line_end]
        if physical_line.strip():
            indent = re.match(r"[ \t]*", physical_line)
            if indent is not None and len(indent.group(0)) < len(binding_indent):
                return line_start
        line_start = line_end + 1
    return len(source)


def _python_instance_binding_scope_bounds(
    source: str,
    constructor_start: int,
    constructor_end: int,
    binding_indent: str,
) -> tuple[int, int]:
    """Bound a self property to its owning Python class."""
    line_start = source.rfind("\n", 0, constructor_start) + 1
    while line_start > 0:
        previous_end = line_start - 1
        previous_start = source.rfind("\n", 0, previous_end) + 1
        physical_line = source[previous_start:previous_end]
        stripped = physical_line.lstrip()
        indent_width = len(physical_line) - len(stripped)
        if indent_width < len(binding_indent) and re.match(
            r"class\b.*:\s*$",
            stripped,
        ):
            scope_start = previous_end + 1
            scan_start = source.find("\n", constructor_end)
            if scan_start == -1:
                return scope_start, len(source)
            scan_start += 1
            while scan_start < len(source):
                scan_end = source.find("\n", scan_start)
                if scan_end == -1:
                    scan_end = len(source)
                candidate = source[scan_start:scan_end]
                if candidate.strip():
                    candidate_indent = len(candidate) - len(candidate.lstrip())
                    if candidate_indent <= indent_width:
                        return scope_start, scan_start
                scan_start = scan_end + 1
            return scope_start, len(source)
        line_start = previous_start
    return (
        constructor_end + 1,
        _python_binding_scope_end(
            source,
            constructor_end,
            binding_indent,
        ),
    )


def _javascript_binding_scope_bounds(
    source: str,
    constructor_start: int,
    constructor_end: int,
    binding_name: str,
    path_suffix: str,
) -> tuple[int, int]:
    """Bound a JavaScript binding to its enclosing brace scope."""
    executable = _executable_code_positions(source, path_suffix)
    brace_stack: list[int] = []
    for index in range(constructor_start):
        if not executable[index]:
            continue
        if source[index] == "{":
            brace_stack.append(index)
        elif source[index] == "}" and brace_stack:
            brace_stack.pop()

    binding_depth = max(
        0,
        len(brace_stack) - (1 if binding_name.startswith("this.") else 0),
    )
    scope_start = brace_stack[binding_depth - 1] + 1 if binding_depth else 0
    brace_depth = len(brace_stack)
    for index in range(constructor_end + 1, len(source)):
        if not executable[index]:
            continue
        if source[index] == "{":
            brace_depth += 1
        elif source[index] == "}":
            brace_depth -= 1
            if brace_depth < binding_depth:
                return scope_start, index
    return scope_start, len(source)


def _fluent_binding_scope(
    source: str,
    constructor_start: int,
    constructor_end: int,
    binding_name: str,
    binding_indent: str,
    path_suffix: str,
    is_javascript_class_field: bool,
) -> tuple[int, int, bool]:
    if path_suffix == ".py":
        if binding_name.startswith("self."):
            scope_start, scope_end = _python_instance_binding_scope_bounds(
                source,
                constructor_start,
                constructor_end,
                binding_indent,
            )
            return scope_start, scope_end, True
        return (
            constructor_end + 1,
            _python_binding_scope_end(
                source,
                constructor_end,
                binding_indent,
            ),
            False,
        )
    scope_start, scope_end = _javascript_binding_scope_bounds(
        source,
        constructor_start,
        constructor_end,
        "" if is_javascript_class_field else binding_name,
        path_suffix,
    )
    is_instance_property = binding_name.startswith("this.")
    return (
        scope_start if is_instance_property else constructor_end + 1,
        scope_end,
        is_instance_property,
    )


def _stored_fluent_client_bindings(
    source: str,
    path_suffix: str,
) -> list[_FluentClientBinding]:
    """Find stored clients and their optional hardcoded base URL."""
    if path_suffix != ".py" and path_suffix not in _JAVASCRIPT_SUFFIXES:
        return []
    executable = _executable_code_positions(source, path_suffix)
    bindings: list[_FluentClientBinding] = []
    for constructor in _NETWORK_VERB.finditer(source):
        kind = _fluent_client_kind(constructor.group(0))
        if kind is None or not executable[constructor.start()]:
            continue
        opening_paren = source.rfind(
            "(",
            constructor.start(),
            constructor.end(),
        )
        if opening_paren == -1:
            continue
        base_target = _fluent_constructor_base_target(
            source,
            opening_paren,
            path_suffix,
        )
        constructor_end = _call_end(source, opening_paren, path_suffix)
        assignment = _fluent_assignment_binding(
            source,
            constructor.start(),
            constructor_end,
            path_suffix,
        )
        if assignment is None:
            continue
        name, binding_indent, is_javascript_class_field = assignment
        scope_start, scope_end, is_instance_property = _fluent_binding_scope(
            source,
            constructor.start(),
            constructor_end,
            name,
            binding_indent,
            path_suffix,
            is_javascript_class_field,
        )
        initialization_scope_end: Optional[int] = None
        if is_instance_property:
            if is_javascript_class_field:
                initialization_scope_end = constructor_end
            elif path_suffix == ".py":
                initialization_scope_end = _python_binding_scope_end(
                    source,
                    constructor_end,
                    binding_indent,
                )
            else:
                _, initialization_scope_end = _javascript_binding_scope_bounds(
                    source,
                    constructor.start(),
                    constructor_end,
                    "",
                    path_suffix,
                )
        bindings.append(
            _FluentClientBinding(
                name=name,
                kind=kind,
                constructor_end=constructor_end,
                base_target_bounds=(
                    base_target.value_bounds if base_target is not None else None
                ),
                scope_start=scope_start,
                scope_end=scope_end,
                is_instance_property=is_instance_property,
                initialization_scope_end=initialization_scope_end,
            )
        )
    return bindings


def _binding_expression_pattern(binding: str) -> str:
    return r"\s*\.\s*".join(
        re.escape(component)
        for component in binding.split(".")
    )


def _call_object_properties(
    source: str,
    arguments: list[_CallArgument],
    path_suffix: str,
) -> list[_CallArgument]:
    return [
        property_argument
        for argument in arguments
        for property_argument in _object_properties(
            source,
            argument.value_bounds,
            path_suffix,
        )
    ]


def _axios_invocation_method(matched_verb: str) -> Optional[str]:
    match = re.match(
        r"\s*axios(?:\s*\.\s*([A-Za-z]+))?\s*\(",
        matched_verb,
        re.IGNORECASE,
    )
    if match is None:
        return None
    method = (match.group(1) or "call").lower()
    return None if method == "create" else method


def _axios_call_base_target(
    source: str,
    arguments: list[_CallArgument],
    path_suffix: str,
) -> Optional[_CallArgument]:
    return _select_labeled_argument(
        _call_object_properties(source, arguments, path_suffix),
        _NETWORK_BASE_TARGET_LABELS,
    )


def _fluent_method_target(
    source: str,
    opening_paren: int,
    client_kind: str,
    method: str,
    path_suffix: str,
) -> Optional[_CallArgument]:
    arguments = _call_arguments(source, opening_paren, path_suffix)
    candidates = list(arguments)
    if client_kind == "axios" and method == "request":
        candidates.extend(
            _call_object_properties(source, arguments, path_suffix)
        )
    positional_index = (
        1
        if client_kind == "httpx" and method in ("request", "stream")
        else 0
    )
    return _select_call_argument(
        candidates,
        _NETWORK_TARGET_LABELS,
        positional_index,
    )


def _has_executable_match(
    pattern: re.Pattern[str],
    source: str,
    start: int,
    end: int,
    executable: bytes,
) -> bool:
    return any(
        executable[match.start()]
        for match in pattern.finditer(source, start, end)
    )


def _stored_fluent_client_verb_offsets(
    source: str,
    path_suffix: str,
) -> list[int]:
    """Return request offsets for stored clients with a public base URL."""
    executable = _executable_code_positions(source, path_suffix)
    offsets: set[int] = set()
    for binding in _stored_fluent_client_bindings(source, path_suffix):
        expression = _binding_expression_pattern(binding.name)
        method_names = (
            _AXIOS_METHOD_NAMES
            if binding.kind == "axios"
            else _HTTPX_METHOD_NAMES
        )
        method_pattern = re.compile(
            rf"(?<![A-Za-z0-9_$]){expression}"
            rf"\s*\.\s*(?P<method>{'|'.join(method_names)})\s*\("
        )
        reassignment_pattern = re.compile(
            rf"(?<![A-Za-z0-9_$]){expression}"
            r"\s*(?:\:\s*[^=\n;]+)?\s*=(?!=|>)"
        )
        search_start = binding.scope_start
        initialization_reassigned = (
            binding.initialization_scope_end is not None
            and _has_executable_match(
                reassignment_pattern,
                source,
                binding.constructor_end + 1,
                binding.initialization_scope_end,
                executable,
            )
        )
        for call in method_pattern.finditer(
            source,
            search_start,
            binding.scope_end,
        ):
            if binding.is_instance_property:
                call_is_in_initialization_scope = (
                    binding.initialization_scope_end is not None
                    and binding.constructor_end < call.start()
                    < binding.initialization_scope_end
                )
                if call_is_in_initialization_scope:
                    if _has_executable_match(
                        reassignment_pattern,
                        source,
                        binding.constructor_end + 1,
                        call.start(),
                        executable,
                    ):
                        continue
                elif initialization_reassigned:
                    continue
            elif _has_executable_match(
                reassignment_pattern,
                source,
                search_start,
                call.start(),
                executable,
            ):
                break
            if not executable[call.start()]:
                continue
            target = _fluent_method_target(
                source,
                call.end() - 1,
                binding.kind,
                call.group("method"),
                path_suffix,
            )
            if target is None:
                continue
            target_start, target_end = target.value_bounds
            target_source = source[target_start:target_end]
            if _URL.search(target_source):
                if _contains_public_network_url(target_source):
                    offsets.add(call.start())
                continue
            if binding.kind == "axios":
                call_arguments = _call_arguments(
                    source,
                    call.end() - 1,
                    path_suffix,
                )
                base_override = _axios_call_base_target(
                    source,
                    call_arguments,
                    path_suffix,
                )
                if base_override is not None:
                    base_start, base_end = base_override.value_bounds
                    base_source = source[base_start:base_end]
                    if _URL.search(base_source):
                        if _contains_public_network_url(base_source):
                            offsets.add(call.start())
                        continue
            if binding.base_target_bounds is not None:
                base_start, base_end = binding.base_target_bounds
                if _contains_public_network_url(source[base_start:base_end]):
                    offsets.add(call.start())
    return sorted(offsets)


def _direct_network_target_ranges(
    line: str,
    match: re.Match[str],
    path_suffix: str,
) -> list[tuple[int, int]]:
    matched_verb = match.group(0).lower()
    if matched_verb.strip() == "curl":
        if path_suffix == ".sh":
            command_word = _shell_command_word_bounds(line, match.start())
            if command_word is None or not _bounds_contain_offset(
                command_word,
                match.start(),
            ):
                return []
            command, _ = _shell_word_value_and_bounds(line, command_word)
            if command.rsplit("/", 1)[-1] != "curl":
                return []
            statement_start, statement_end = _shell_command_region_bounds(
                line,
                match.start(),
            )
            return [(statement_start, statement_end)]

        statement_end = line.find("\n", match.start())
        return [(match.start(), len(line) if statement_end == -1 else statement_end)]

    opening_paren = line.rfind("(", match.start(), match.end())
    if opening_paren == -1:
        following = match.end()
        while following < len(line) and line[following].isspace():
            following += 1
        if following < len(line) and line[following] == "(":
            opening_paren = following
    if opening_paren == -1:
        return []

    constructor_opening_paren: Optional[int] = None
    if client_kind := _fluent_client_kind(matched_verb):
        constructor_opening_paren = opening_paren
        opening_paren = _fluent_terminal_opening_paren(
            line,
            constructor_opening_paren,
            client_kind,
            path_suffix,
        )
        if opening_paren is None:
            return []

    arguments = _call_arguments(line, opening_paren, path_suffix)
    axios_method = _axios_invocation_method(matched_verb)
    target_arguments = list(arguments)
    if axios_method in ("call", "request"):
        target_arguments.extend(
            _call_object_properties(line, arguments, path_suffix)
        )
    target_verb = line[match.start() : opening_paren + 1]
    spec = _network_target_spec(target_verb)
    positional_index = spec.positional_index
    if matched_verb.strip().startswith("superagent"):
        positional_arguments = [
            argument
            for argument in target_arguments
            if argument.label is None
        ]
        if len(positional_arguments) >= 2:
            positional_index = 1
    target = _select_call_argument(
        target_arguments,
        spec.labels,
        positional_index,
    )
    if target is None:
        return []
    fluent_base_ranges = _fluent_base_target_ranges(
        line,
        constructor_opening_paren,
        target,
        path_suffix,
    )
    target_start, target_end = target.value_bounds
    if (
        client_kind == "axios"
        and not _URL.search(line[target_start:target_end])
    ):
        base_override = _axios_call_base_target(
            line,
            arguments,
            path_suffix,
        )
        if base_override is not None:
            base_start, base_end = base_override.value_bounds
            if _URL.search(line[base_start:base_end]):
                fluent_base_ranges = [base_override.value_bounds]
    target_ranges = [
        target.value_bounds,
        *fluent_base_ranges,
    ]
    if axios_method is not None and not _URL.search(line[target_start:target_end]):
        base_target = _axios_call_base_target(
            line,
            arguments,
            path_suffix,
        )
        if base_target is not None:
            target_ranges.append(base_target.value_bounds)
    return target_ranges


def _is_callable_declaration(
    line: str,
    match: re.Match[str],
    path_suffix: str,
) -> bool:
    """Return whether a generic request-shaped match declares a callable."""
    prefix = line[: match.start()]
    if re.search(r"\b(?:async\s+)?function\s*$|\b(?:def|func)\s*$", prefix):
        return True

    opening_paren = line.find("(", match.start(), match.end())
    if opening_paren == -1:
        return False
    closing_paren = _call_end(line, opening_paren, path_suffix)
    cursor = closing_paren + 1
    while cursor < len(line) and line[cursor].isspace():
        cursor += 1
    if line.startswith("=>", cursor):
        return True
    if cursor < len(line) and line[cursor] == "{":
        return True
    if cursor < len(line) and line[cursor] == ":":
        brace = line.find("{", cursor)
        semicolon = line.find(";", cursor)
        return brace != -1 and (semicolon == -1 or brace < semicolon)
    return False


def _network_target_ranges(
    line: str,
    match: re.Match[str],
    path_suffix: str,
) -> list[tuple[int, int]]:
    verb_start = match.start()
    if _is_callable_declaration(line, match, path_suffix):
        return []
    if path_suffix == ".sh":
        env_split_source = _shell_env_split_source_bounds(line, verb_start)
        if env_split_source is not None:
            env_split_ranges = _nested_network_source_target_ranges(
                line,
                env_split_source,
                verb_start,
                ".sh",
            )
            if env_split_ranges:
                return env_split_ranges
            if _bounds_contain_offset(env_split_source, verb_start):
                statement_start, statement_end = _shell_command_region_bounds(
                    line,
                    verb_start,
                )
                command_ranges = _nested_network_source_target_ranges(
                    line,
                    env_split_source,
                    verb_start,
                    ".sh",
                    require_public_url=False,
                )
                if command_ranges and _contains_public_network_url(
                    line[statement_start:statement_end]
                ):
                    return [(statement_start, statement_end)]
                return []
    if path_suffix == ".sh" and match.group(0).lower().strip() == "curl":
        direct_ranges = _direct_network_target_ranges(line, match, path_suffix)
        if direct_ranges:
            return direct_ranges
        return _launcher_target_ranges(line, verb_start, path_suffix)
    if _is_inside_string_literal(line, verb_start, path_suffix):
        return _launcher_target_ranges(line, verb_start, path_suffix)
    return _direct_network_target_ranges(line, match, path_suffix)


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


def detect_live_network_host(line: str, path_suffix: str = "") -> bool:
    # High-precision signal only: an actual http(s):// URL with a public host that
    # is ALSO handed to a network-driving verb on the same line (fetch/axios/
    # requests/urlopen/...). A URL used as a string fixture (markdown builder,
    # canonical-URL assertion, toContain) opens no socket and is not flagged.
    # Bare quoted IPs in data structures are likewise too ambiguous to flag.
    # Loopback/private/CGNAT/RFC2606 hosts are allowed.
    # A verb mentioned inside asserted/rendered text is fixture data, not code
    # that can drive the network. URLs remain inspectable inside string
    # arguments because only the verb's lexical position is filtered here.
    return bool(_live_network_verb_offsets(line, path_suffix))


def _contains_public_network_url(source: str) -> bool:
    for match in _URL.finditer(source):
        host = match.group(1)
        if "." not in host:
            continue  # bare hostname, not a real domain
        if _PRIVATE_HOST.search(host):
            continue
        if _looks_like_ipv4(host) and _is_private_ipv4(host):
            continue
        return True
    return False


def _live_network_verb_offsets(
    source: str,
    path_suffix: str = "",
) -> list[int]:
    if not _contains_public_network_url(source):
        return []
    offsets: list[int] = []
    for match in _NETWORK_VERB.finditer(source):
        target_ranges = _network_target_ranges(source, match, path_suffix)
        if any(
            _contains_public_network_url(source[start:end])
            for start, end in target_ranges
        ):
            offsets.append(match.start())
    return offsets


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


def detect_sleep_then_assert(lines: list[str], idx: int, path_suffix: str) -> bool:
    """Sleep on lines[idx] followed by an assertion within 3 non-blank lines."""
    line = lines[idx]
    is_sleep = bool(_SLEEP_CALL.search(line))
    if not is_sleep and path_suffix == ".sh":
        is_sleep = bool(_SHELL_BARE_SLEEP.search(line))
    if not is_sleep:
        return False
    if _sleep_in_loop(lines, idx):
        return False
    seen = 0
    for j in range(idx + 1, len(lines)):
        nxt = _strip_comment(lines[j], path_suffix)
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


def _logical_network_chunks(
    source: str,
    path_suffix: str = "",
) -> list[tuple[int, str]]:
    """Group continuations for network calls without inheriting outer test scopes."""
    if not source:
        return []

    executable = _executable_code_positions(source, path_suffix)
    chunks: list[tuple[int, str]] = []
    start = 0
    start_line = 1
    physical_line_start = 0
    current_line = 1
    paren_depth = 0
    bracket_depth = 0
    network_context = False

    for index, character in enumerate(source):
        if executable[index]:
            if character == "(":
                paren_depth += 1
            elif character == ")":
                paren_depth = max(0, paren_depth - 1)
            elif character == "[":
                bracket_depth += 1
            elif character == "]":
                bracket_depth = max(0, bracket_depth - 1)

        if character != "\n":
            continue

        physical_line = source[physical_line_start:index]
        network_context = network_context or any(
            pattern.search(physical_line)
            for pattern in (
                _NETWORK_VERB,
                _SHELL_CALL_LAUNCHER,
                _ARGV_CALL_LAUNCHER,
                _SHELL_COMMAND_LAUNCHER,
                _SHELL_EVAL_LAUNCHER,
            )
        )
        previous = index - 1
        while previous >= start and source[previous] in " \t":
            previous -= 1
        line_continues = (
            previous >= start
            and source[previous] == "\\"
            and executable[previous]
        )
        next_code = index + 1
        while next_code < len(source) and source[next_code] in " \t\r":
            next_code += 1
        fluent_continuation = (
            network_context
            and next_code < len(source)
            and source[next_code] == "."
            and executable[next_code]
        )
        should_split = (
            executable[index]
            and not line_continues
            and not fluent_continuation
            and (
                not network_context
                or (paren_depth == 0 and bracket_depth == 0)
            )
        )
        if should_split:
            chunks.append((start_line, source[start:index]))
            start = index + 1
            start_line = current_line + 1
            paren_depth = 0
            bracket_depth = 0
            network_context = False
        physical_line_start = index + 1
        current_line += 1

    chunks.append((start_line, source[start:]))
    return chunks


def scan_text(rel_posix: str, text: str) -> list[Finding]:
    suffix = pathlib.PurePosixPath(rel_posix).suffix
    raw_lines = text.splitlines()
    code_lines = [_strip_comment(line, suffix) for line in raw_lines]
    findings: list[Finding] = []
    if _NETWORK_VERB.search(text) and _contains_public_network_url(text):
        network_source = _strip_comments(text, suffix)
        live_network_lines = {
            start_line + chunk.count("\n", 0, offset)
            for start_line, chunk in _logical_network_chunks(network_source, suffix)
            for offset in _live_network_verb_offsets(chunk, suffix)
        }
        live_network_lines.update(
            1 + network_source.count("\n", 0, offset)
            for offset in _stored_fluent_client_verb_offsets(
                network_source,
                suffix,
            )
        )
    else:
        live_network_lines = set()

    for i, code in enumerate(code_lines):
        if not code.strip():
            continue
        line_no = i + 1
        snippet = raw_lines[i].strip()

        if detect_assert_on_duration(code):
            findings.append(Finding(rel_posix, line_no, RULE_ASSERT_ON_DURATION, snippet))
        if line_no in live_network_lines:
            findings.append(Finding(rel_posix, line_no, RULE_LIVE_NETWORK_HOST, snippet))
        if detect_fixed_port_bind(code):
            findings.append(Finding(rel_posix, line_no, RULE_FIXED_PORT_BIND, snippet))
        if detect_sleep_then_assert(code_lines, i, suffix):
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
            "tests/curl.sh",
            "curl -fsSL https://cmux.com/install.sh | sh\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_leading_attached_redirection.sh",
            ">/tmp/out curl -fsSL https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_leading_separate_redirection.sh",
            "2> /tmp/error curl -fsSL https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_dollar_substitution.sh",
            'body="$(curl -fsSL https://api.openai.com/v1/items)"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_backtick_substitution.sh",
            'body="`curl -fsSL https://api.openai.com/v1/items`"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/quoted_curl_command.sh",
            '"/usr/bin/curl" -fsSL https://api.openai.com/v1/items\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/quoted_shell_command.sh",
            "'bash' -c 'curl -fsSL https://api.openai.com/v1/items'\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/subprocess_curl.py",
            'subprocess.run(["curl", "https://api.openai.com/v1/items"], check=True)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/subprocess_keyword_args_curl.py",
            (
                "subprocess.run(\n"
                "    check=True,\n"
                '    args=["curl", "https://api.openai.com/v1/items"],\n'
                ")\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/exec_curl.ts",
            'execSync("curl -fsSL https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/exec_concatenated_curl.ts",
            (
                'execSync("curl -fsSL " + '
                '"https://api.openai.com/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/child_process_exec_curl.ts",
            'child_process.exec("curl -fsSL https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/child_process_spawn_curl.ts",
            (
                'child_process.spawn("curl", [\n'
                '  "https://api.openai.com/v1/items",\n'
                "]);\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/child_process_spawn_shell_path.ts",
            (
                'child_process.spawn("curl https://api.openai.com/v1/items", {\n'
                '  shell: "/bin/bash",\n'
                "});\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/child_process_spawn_quoted_shell_key.ts",
            (
                'child_process.spawn("curl https://api.openai.com/v1/items", {\n'
                '  "shell": "/bin/bash",\n'
                "});\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/child_process_spawn_computed_shell_key.ts",
            (
                'child_process.spawn("curl https://api.openai.com/v1/items", {\n'
                '  ["shell"]: "/bin/bash",\n'
                "});\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/child_process_spawn_template_computed_shell_key.ts",
            (
                'child_process.spawn("curl https://api.openai.com/v1/items", {\n'
                '  [`shell`]: "/bin/bash",\n'
                "});\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/bun_spawn_options_curl.ts",
            (
                "Bun.spawn({\n"
                '  cmd: ["curl", "https://api.openai.com/v1/items"],\n'
                '  stdout: "pipe",\n'
                "});\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/bun_spawn_quoted_cmd_key.ts",
            (
                "Bun.spawn({\n"
                '  "cmd": ["curl", "https://api.openai.com/v1/items"],\n'
                "});\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/bun_spawn_computed_cmd_key.ts",
            (
                "Bun.spawn({\n"
                '  ["cmd"]: ["curl", "https://api.openai.com/v1/items"],\n'
                "});\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/bun_spawn_template_computed_cmd_key.ts",
            (
                "Bun.spawn({\n"
                '  [`cmd`]: ["curl", "https://api.openai.com/v1/items"],\n'
                "});\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/os_popen_curl.py",
            'os.popen("curl -fsSL https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/getoutput_curl.py",
            'subprocess.getoutput("curl -fsSL https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/getoutput_keyword_curl.py",
            'subprocess.getoutput(cmd="curl -fsSL https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/getstatusoutput_curl.py",
            'subprocess.getstatusoutput("curl -fsSL https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/exec_file_curl.ts",
            'execFile("curl", ["https://api.openai.com/v1/items"], callback)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/subprocess_shell_curl.py",
            'subprocess.run("curl https://api.openai.com/v1/items", shell=True)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/subprocess_shell_concatenated_curl.py",
            'subprocess.run("curl -fsSL " + "https://api.openai.com/v1/items", shell=True)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/subprocess_shell_truthy_integer.py",
            'subprocess.run("curl https://api.openai.com/v1/items", shell=1)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/template_interpolation_fetch.ts",
            'const result = `${await fetch("https://api.openai.com/v1/items")}`;\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "cmuxTests/swift_interpolation_fetch.swift",
            (
                'let value = "\\(try await fetch('
                '\"https://api.openai.com/v1/items\"))"\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "cmuxTests/swift_raw_interpolation_fetch.swift",
            (
                'let value = #"\\#(try await fetch('
                '"https://api.openai.com/v1/items"))"#\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/backtick_url_then_fetch.ts",
            (
                "const docs = `https://cmux.com`;\n"
                'const result = await fetch("https://api.openai.com/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/block_comment_then_fetch.ts",
            (
                "/* Don't call production from fixture helpers. */\n"
                'const result = await fetch("https://api.openai.com/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/regex_quote_then_fetch.ts",
            (
                'const quoted = /"/;\n'
                'await fetch("https://api.openai.com/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/regex_character_class_then_fetch.ts",
            (
                'const quoted = /["/]/;\n'
                'await fetch("https://api.openai.com/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/regex_escape_then_fetch.ts",
            (
                'const escaped = /\\/"/;\n'
                'await fetch("https://api.openai.com/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/template_regex_then_fetch.ts",
            (
                'const matched = `${/"/.test(value)}`;\n'
                'await fetch("https://api.openai.com/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/return_regex_then_fetch.ts",
            (
                'function quoted() { return /"/; }\n'
                'await fetch("https://api.openai.com/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/division_then_fetch.ts",
            (
                "const ratio = total / divisor;\n"
                'await fetch("https://api.openai.com/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/fstring_network.py",
            'payload = f"{requests.get(\'https://api.openai.com/v1/items\')}"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_command_network.sh",
            'bash -c "curl -fsSL https://api.openai.com/v1/items"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/python_command_network.sh",
            (
                "python3 -c 'requests.get(\"https://api.openai.com/v1/items\")'\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/node_command_network.sh",
            (
                "node -e 'fetch(\"https://api.openai.com/v1/items\")'\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/timeout_curl.sh",
            "timeout 10 curl -fsSL https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/timeout_option_curl.sh",
            (
                "timeout -k 2 --signal=TERM 10 "
                "curl -fsSL https://api.openai.com/v1/items\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/sudo_curl.sh",
            "sudo curl -fsSL https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/nested_sudo_timeout_curl.sh",
            (
                "sudo -u root timeout --kill-after=2 10 "
                "curl -fsSL https://api.openai.com/v1/items\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/subprocess_argv_sudo_curl.py",
            (
                'subprocess.run(["sudo", "-u", "root", "curl", '
                '"https://api.openai.com/v1/items"])\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/subprocess_argv_sudo_dynamic_user_curl.py",
            (
                'subprocess.run(["sudo", "-u", user, "curl", '
                '"https://api.openai.com/v1/items"])\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/subprocess_env_split_curl.py",
            'subprocess.run(["env", "-S", "curl https://api.openai.com/v1/items"])\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/env_split_curl.sh",
            'env -S "curl -fsSL https://api.openai.com/v1/items"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/spawn_argv_timeout_curl.ts",
            (
                'spawn("timeout", ["10", "curl", '
                '"https://api.openai.com/v1/items"]);\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/spawn_argv_timeout_dynamic_signal_curl.ts",
            (
                'spawn("timeout", ["-s", signal, "10", "curl", '
                '"https://api.openai.com/v1/items"]);\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/sudo_assignment_curl.sh",
            "sudo API_ENV=test curl https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/nice_curl.sh",
            "nice -n 5 curl https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/time_curl.sh",
            "time -f '%E' curl https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/gtimeout_curl.sh",
            "gtimeout --foreground 10 curl https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_long_options_network.sh",
            (
                "bash --noprofile --norc --rcfile /tmp/empty "
                '-c "curl -fsSL https://api.openai.com/v1/items"\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_eval_network.sh",
            'eval "curl -fsSL https://api.openai.com/v1/items"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_eval_unquoted_network.sh",
            "eval curl -fsSL https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_if_eval_unquoted_network.sh",
            "if eval curl -fsSL https://api.openai.com/v1/items; then :; fi\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_if_curl_network.sh",
            "if curl -fsSL https://api.openai.com/v1/items; then :; fi\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_function_curl_network.sh",
            "fetch_data() { curl -fsSL https://api.openai.com/v1/items; }\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_assignment_curl_network.sh",
            'API_URL=https://api.openai.com/v1/items curl "$API_URL"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_assignment_env_split_network.sh",
            'API_URL=https://api.openai.com/v1/items env -S "curl $API_URL"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_while_curl_network.sh",
            "while curl -fsSL https://api.openai.com/v1/items; do :; done\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_until_curl_network.sh",
            "until curl -fsSL https://api.openai.com/v1/items; do :; done\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_negated_curl_network.sh",
            "! curl -fsSL https://api.openai.com/v1/items\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_case_curl_network.sh",
            (
                'case "$mode" in\n'
                "  live) curl -fsSL https://api.openai.com/v1/items ;;\n"
                "esac\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_case_eval_network.sh",
            (
                'case "$mode" in\n'
                "  live) eval curl -fsSL https://api.openai.com/v1/items ;;\n"
                "esac\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/shell_eval_multiple_args.sh",
            (
                'eval "set -e;" \\\n'
                '  "curl -fsSL https://api.openai.com/v1/items"\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/eval_fetch.ts",
            'eval(\'fetch("https://api.openai.com/v1/items")\');\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/xhr_open.ts",
            'xhr.open("GET", "https://api.openai.com/v1/items");\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/xhr_open_dynamic_method.ts",
            'xhr.open(method, "https://api.openai.com/v1/items");\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/requests_request.py",
            'requests.request("GET", "https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/urllib3_method_first_request.py",
            'urllib3.PoolManager().request("GET", "https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/superagent_method_first.ts",
            'superagent("GET", "https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/superagent_dynamic_method.ts",
            'superagent(method, "https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/superagent_url_only.ts",
            'superagent("https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_module_stream.py",
            'httpx.stream("GET", "https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_client_get.py",
            'httpx.Client().get("https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_client_stream.py",
            (
                'httpx.Client().stream('
                '"GET", "https://api.openai.com/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_client_base_url_get.py",
            (
                'httpx.Client(base_url="https://api.openai.com")'
                '.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_parenthesized_client_base_url_get.py",
            (
                '(httpx.Client(base_url="https://api.openai.com"))'
                '.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_nested_client_get.py",
            (
                "httpx.Client("
                "timeout=httpx.Timeout(5), "
                'base_url="https://api.openai.com"'
                ').get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_multiline_client_get.py",
            (
                "httpx.Client(\n"
                "    timeout=httpx.Timeout(5),\n"
                '    base_url="https://api.openai.com",\n'
                ').get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_multiline_grouped_chain.ts",
            (
                "axios.create({\n"
                '  baseURL: "https://api.openai.com"\n'
                "})\n"
                '  .get("/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_stored_client_get.py",
            (
                'client = httpx.Client(base_url="https://api.openai.com")\n'
                'client.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_module_client_nested_shadow.py",
            (
                'client = httpx.Client(base_url="https://api.openai.com")\n'
                "def helper():\n"
                "    client = FakeClient()\n"
                'client.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_parenthesized_stored_client_get.py",
            (
                'client = (httpx.Client(base_url="https://api.openai.com"))\n'
                'client.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_stored_client_explicit_public_target.py",
            (
                "client = httpx.Client()\n"
                'client.get("https://api.openai.com/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_context_client_get.py",
            (
                'with httpx.Client(base_url="https://api.openai.com") as client:\n'
                '    client.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_instance_client_get.py",
            (
                "class LiveClientTest:\n"
                "    def setUp(self):\n"
                '        self.client = httpx.Client(base_url="https://api.openai.com")\n'
                "\n"
                "    def test_items(self):\n"
                '        self.client.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_instance_client_source_order.py",
            (
                "class LiveClientTest:\n"
                "    def test_items(self):\n"
                '        self.client.get("/v1/items")\n'
                "\n"
                "    def setUp(self):\n"
                '        self.client = httpx.Client(base_url="https://api.openai.com")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/httpx_instance_client_teardown.py",
            (
                "class LiveClientTest:\n"
                "    def setUp(self):\n"
                '        self.client = httpx.Client(base_url="https://api.openai.com")\n'
                "\n"
                "    def tearDown(self):\n"
                "        self.client = None\n"
                "\n"
                "    def test_items(self):\n"
                '        self.client.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_client_get.ts",
            'axios.create().get("https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_options.ts",
            'axios.options("https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_request_base_url.ts",
            (
                'await axios.get("/v1/items", {\n'
                '  baseURL: "https://api.openai.com",\n'
                "});\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_nested_factory_options.ts",
            (
                "axios.create(makeConfig())"
                '.options("https://api.openai.com/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_client_base_url_get.ts",
            (
                'axios.create({ baseURL: "https://api.openai.com" })'
                '.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_parenthesized_client_base_url_get.ts",
            (
                '(axios.create({ baseURL: "https://api.openai.com" }))'
                '.get("/v1/items")\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_client_request_base_override.ts",
            (
                'axios.create({ baseURL: "http://127.0.0.1:4321" })'
                '.get("/v1/items", { baseURL: "https://api.openai.com" })\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_stored_client_get.ts",
            (
                'const client = axios.create({ baseURL: "https://api.openai.com" });\n'
                'await client.get("/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_exported_stored_client_get.ts",
            (
                'export const client = axios.create({ baseURL: "https://api.openai.com" });\n'
                'await client.get("/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_parenthesized_stored_client_get.ts",
            (
                'const client = (axios.create({ baseURL: "https://api.openai.com" }));\n'
                'await client.get("/v1/items");\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_stored_client_public_base_override.ts",
            (
                'const client = axios.create({ baseURL: "http://127.0.0.1:4321" });\n'
                'await client.get("/v1/items", '
                '{ baseURL: "https://api.openai.com" });\n'
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_instance_client_get.ts",
            (
                "class LiveClientTest {\n"
                "  beforeEach() {\n"
                '    this.client = axios.create({ baseURL: "https://api.openai.com" });\n'
                "  }\n"
                "\n"
                "  async testItems() {\n"
                '    await this.client.get("/v1/items");\n'
                "  }\n"
                "}\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/axios_class_field_client_get.ts",
            (
                "class LiveClientTest {\n"
                "  private readonly client: AxiosInstance = "
                'axios.create({ baseURL: "https://api.openai.com" });\n'
                "\n"
                "  async testItems() {\n"
                '    await this.client.get("/v1/items");\n'
                "  }\n"
                "}\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/requests_keyword_url.py",
            (
                "requests.get(\n"
                "    timeout=1,\n"
                '    url="https://api.openai.com/v1/items",\n'
                ")\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/requests_request_keyword_url.py",
            (
                "requests.request(\n"
                '    url="https://api.openai.com/v1/items",\n'
                '    method="GET",\n'
                ")\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/subprocess_shell_argv.py",
            'subprocess.run(["bash", "-c", "curl https://api.openai.com/v1/items"])\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/spawn_shell_argv.ts",
            'spawn("sh", ["-c", "curl https://api.openai.com/v1/items"])\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/python_command_source.py",
            (
                "subprocess.run([\n"
                '    "python3",\n'
                '    "-c",\n'
                '    "requests.get(\\\'https://api.openai.com/v1/items\\\')",\n'
                "])\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/node_eval_source.ts",
            (
                'spawn("node", [\n'
                '  "--eval",\n'
                '  "fetch(\\\'https://api.openai.com/v1/items\\\')",\n'
                "]);\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/node_attached_eval_source.ts",
            (
                'spawn("node", [\n'
                '  "--eval=fetch(\\\'https://api.openai.com/v1/items\\\')",\n'
                "]);\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/multiline_subprocess_shell.py",
            (
                "subprocess.run(\n"
                '    "curl https://api.openai.com/v1/items",\n'
                "    shell=True,\n"
                ")\n"
            ),
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/env_curl.py",
            'subprocess.run(["/usr/bin/env", "curl", "https://api.openai.com/v1/items"])\n',
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
            "cmuxUITests/f.swift",
            "try await Task.sleep(nanoseconds: 300_000_000)\nXCTAssertTrue(view.exists)\n",
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
        # Deterministic scenario-pacing sleep with NO following assertion.
        (
            "tests/n1.py",
            "time.sleep(0.05)\nproc.write('next command\\n')\nproc.flush()\n",
        ),
        # Deadline-bounded poll of a real predicate: sleep is inside a while loop.
        (
            "tests/n2.py",
            (
                "deadline = time.monotonic() + 5\n"
                "while time.monotonic() < deadline:\n"
                "    if widget.is_rendered():\n"
                "        break\n"
                "    time.sleep(0.05)\n"
                "assert widget.is_rendered()\n"
            ),
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
        # A rendered shell command is output text. Merely asserting that it is
        # present does not execute curl or open a network connection.
        (
            "web/tests/n18b.ts",
            'expect(html).toContain("curl -fsSL https://cmux.com/install.sh | sh")\n',
        ),
        # The same applies to source-code examples embedded in asserted text.
        (
            "web/tests/n18c.ts",
            'expect(help).toContain("fetch(\\"https://cmux.com/status\\")")\n',
        ),
        # A process-launch example remains inert when the launcher itself is
        # part of the asserted string rather than executable code.
        (
            "web/tests/n18d.ts",
            "expect(help).toContain('execSync(\\\"curl https://cmux.com/status\\\")')\n",
        ),
        # Unrelated object methods named exec/eval/spawn do not launch processes.
        (
            "web/tests/n18d_regex_exec.ts",
            'pattern.exec("curl https://api.openai.com/v1/items")\n',
        ),
        (
            "web/tests/n18d_schema_eval.ts",
            'schema.eval("fetch(\\\"https://api.openai.com/v1/items\\\")")\n',
        ),
        (
            "web/tests/n18d_pool_spawn.ts",
            (
                'pool.spawn("curl", [\n'
                '  "https://api.openai.com/v1/items",\n'
                "]);\n"
            ),
        ),
        (
            "web/tests/n18d_request_helper.ts",
            (
                'function request(body, url = "https://cmux.com/status") {\n'
                "  return new Request(url, { body });\n"
                "}\n"
            ),
        ),
        (
            "web/tests/n18d_fake_open.ts",
            'fake.open("read", "https://api.openai.com/v1/items");\n',
        ),
        (
            "tests/n18d_python_exec.py",
            'exec("curl https://api.openai.com/v1/items")\n',
        ),
        # Plain template text is still fixture data; only `${...}` regions are
        # executable JavaScript.
        (
            "web/tests/n18e.ts",
            'const example = `fetch("https://api.openai.com/v1/items")`;\n',
        ),
        # Escaped braces are literal f-string text, not a replacement field.
        (
            "tests/n18f.py",
            'payload = f"{{requests.get(\'https://api.openai.com/v1/items\')}}"\n',
        ),
        # An escaped Swift interpolation marker is inert string text.
        (
            "cmuxTests/n18f_swift_escaped_interpolation.swift",
            (
                'let example = "\\\\(fetch('
                '\\"https://api.openai.com/v1/items\\"))"\n'
            ),
        ),
        # A rendered shell invocation remains inert when the shell launcher is
        # itself inside asserted fixture text.
        (
            "web/tests/n18g.ts",
            'expect(help).toContain(\'bash -c "curl https://api.openai.com/v1/items"\')\n',
        ),
        # A network-looking later argv element is data passed to a different
        # executable, not a command of its own.
        (
            "tests/n18h.py",
            'subprocess.run(["printf", "curl https://api.openai.com/v1/items"])\n',
        ),
        (
            "web/tests/n18i.ts",
            'spawn("echo", ["curl https://api.openai.com/v1/items"])\n',
        ),
        (
            "tests/n18i_subprocess_sudo_option_value.py",
            (
                'subprocess.run(["sudo", "-p", "curl", "echo", '
                '"https://api.openai.com/v1/items"])\n'
            ),
        ),
        (
            "tests/n18i_subprocess_sudo_dynamic_argument.py",
            (
                'subprocess.run(["sudo", sudo_argument, "curl", '
                '"https://api.openai.com/v1/items"])\n'
            ),
        ),
        (
            "web/tests/n18i_spawn_timeout_option_value.ts",
            (
                'spawn("timeout", ["-s", "curl", "10", "echo", '
                '"https://api.openai.com/v1/items"]);\n'
            ),
        ),
        # An empty Node shell path is falsey and leaves the command in direct
        # executable mode; the whitespace-containing command cannot run curl.
        (
            "web/tests/n18i_empty_shell.ts",
            (
                'child_process.spawn("curl https://api.openai.com/v1/items", {\n'
                '  shell: "",\n'
                "});\n"
            ),
        ),
        # A dictionary entry named shell is process environment data, not
        # Python's shell= call argument.
        (
            "tests/n18i_python_shell_env.py",
            (
                'subprocess.run("curl https://api.openai.com/v1/items",\n'
                '    env={"shell": "/bin/bash"})\n'
            ),
        ),
        # Bun's object form executes only cmd[0]. Later argv strings and option
        # metadata are data and must not become network invocation targets.
        (
            "web/tests/n18i_bun_options_data.ts",
            (
                "Bun.spawn({\n"
                '  cmd: ["printf", "curl https://api.openai.com/v1/items"],\n'
                '  env: { DOCS_URL: "https://cmux.com" },\n'
                "});\n"
            ),
        ),
        # Unquoted shell arguments are still data when curl does not own
        # command position.
        (
            "tests/n18i_shell_argument.sh",
            "printf curl https://api.openai.com/v1/items\n",
        ),
        (
            "tests/n18i_timeout_inert_curl.sh",
            (
                "timeout 10 printf '%s\\n' "
                "'curl https://api.openai.com/v1/items'\n"
            ),
        ),
        (
            "tests/n18i_sudo_inert_curl.sh",
            "sudo echo curl https://api.openai.com/v1/items\n",
        ),
        (
            "tests/n18i_timeout_option_value.sh",
            "timeout -s curl 10 echo https://api.openai.com/v1/items\n",
        ),
        (
            "tests/n18i_sudo_option_value.sh",
            "sudo -p curl echo https://api.openai.com/v1/items\n",
        ),
        (
            "tests/n18i_time_option_value.sh",
            "time -f curl echo https://api.openai.com/v1/items\n",
        ),
        # Redirections do not promote later argv data into command position.
        (
            "tests/n18i_shell_redirected_argument.sh",
            "printf >/tmp/out curl https://api.openai.com/v1/items\n",
        ),
        # Merely passing eval and curl as arguments does not execute either one.
        (
            "tests/n18i_shell_eval_argument.sh",
            "printf eval curl https://api.openai.com/v1/items\n",
        ),
        # Eval parses its joined arguments as a shell command. Curl is inert
        # when it is only an argument to the command selected by that source.
        (
            "tests/n18i_shell_eval_data_argument.sh",
            "eval echo curl https://api.openai.com/v1/items\n",
        ),
        # A case pattern names data, not a command. The command begins only
        # after the arm's unmatched close parenthesis.
        (
            "tests/n18i_shell_case_pattern.sh",
            (
                'case "$mode" in\n'
                '  curl) printf "%s\\n" "https://api.openai.com/v1/items" ;;\n'
                "esac\n"
            ),
        ),
        # Python does not split a string command unless shell=True is explicit.
        (
            "tests/n18j.py",
            'subprocess.run("curl https://api.openai.com/v1/items")\n',
        ),
        # Shell-looking later arguments remain inert when the actual executable
        # is not a shell.
        (
            "tests/n18k.py",
            'subprocess.run(["printf", "bash", "-c", "curl https://api.openai.com/v1/items"])\n',
        ),
        # A later quoted argv element is not the executable when argv[0] is a
        # dynamic expression.
        (
            "tests/n18k_dynamic_command.py",
            (
                "subprocess.run([\n"
                "    helper,\n"
                '    "curl",\n'
                '    "https://api.openai.com/v1/items",\n'
                "])\n"
            ),
        ),
        # Multiline literal contents are fixture text in every scanned language,
        # even when a middle physical line looks like executable source.
        (
            "tests/n18l.py",
            (
                'fixture = """\n'
                'fetch("https://api.openai.com/v1/items")\n'
                '"""\n'
            ),
        ),
        (
            "web/tests/n18m.ts",
            (
                "const fixture = `\n"
                'fetch("https://api.openai.com/v1/items")\n'
                "`;\n"
            ),
        ),
        (
            "cmuxTests/n18n.swift",
            (
                'let fixture = """\n'
                'fetch("https://api.openai.com/v1/items")\n'
                '"""\n'
            ),
        ),
        # Hash comments are inert in Python and at shell word boundaries.
        (
            "tests/n18o_python_line_comment.py",
            '# fetch("https://api.openai.com/v1/items")\n',
        ),
        (
            "tests/n18o_shell_whitespace_comment.sh",
            "printf ok; # curl -fsSL https://api.openai.com/v1/items\n",
        ),
        (
            "tests/n18o_shell_operator_comment.sh",
            "printf ok;# curl -fsSL https://api.openai.com/v1/items\n",
        ),
        # Network examples inside C-style block comments remain inert.
        (
            "web/tests/n18o.ts",
            (
                "/*\n"
                'fetch("https://api.openai.com/v1/items");\n'
                "*/\n"
            ),
        ),
        # Swift block comments nest, so the outer comment still owns source
        # after the inner close delimiter.
        (
            "cmuxTests/n18p.swift",
            (
                "/* outer\n"
                "/* inner */\n"
                'fetch("https://api.openai.com/v1/items")\n'
                "*/\n"
            ),
        ),
        # A later shell statement is not source consumed by the preceding eval.
        (
            "tests/n18q_eval_statement.sh",
            (
                'eval "printf ok"; '
                'printf "%s\\n" "curl https://api.openai.com/v1/items"\n'
            ),
        ),
        # Public metadata does not turn a loopback argv target into live access.
        (
            "tests/n18r_argv_env_url.py",
            (
                "subprocess.run(\n"
                '    ["curl", "http://127.0.0.1:4321/health"],\n'
                '    env={"DOCS_URL": "https://cmux.com"},\n'
                ")\n"
            ),
        ),
        # Network API metadata is not the target URL.
        (
            "web/tests/n18s_fetch_header.ts",
            (
                "await fetch(\n"
                '  "http://127.0.0.1:4321/health",\n'
                '  { headers: { Referer: "https://cmux.com" } },\n'
                ");\n"
            ),
        ),
        (
            "tests/n18t_requests_header.py",
            (
                "requests.get(\n"
                '    "http://127.0.0.1:4321/health",\n'
                '    headers={"Referer": "https://cmux.com"},\n'
                ")\n"
            ),
        ),
        # A labeled loopback target stays local even when later metadata is public.
        (
            "tests/n18u_requests_keyword_url.py",
            (
                "requests.get(\n"
                "    timeout=1,\n"
                '    url="http://127.0.0.1:4321/health",\n'
                '    headers={"Referer": "https://cmux.com"},\n'
                ")\n"
            ),
        ),
        # Interpreter script arguments are data, not evaluated command source.
        (
            "tests/n18v_python_script_argument.py",
            (
                "subprocess.run([\n"
                '    "python3",\n'
                '    "script.py",\n'
                '    "requests.get(\\\'https://api.openai.com/v1/items\\\')",\n'
                "])\n"
            ),
        ),
        # Interpreted source must still be parsed for command position: printing
        # a network-looking example is not a live request.
        (
            "tests/n18v_bash_echo_source.py",
            (
                "subprocess.run([\n"
                '    "bash", "-c", "echo curl https://api.openai.com/v1/items"\n'
                "])\n"
            ),
        ),
        (
            "tests/n18v_python_print_source.py",
            (
                "subprocess.run([\n"
                '    "python3", "-c", \'print("curl https://api.openai.com/v1/items")\'\n'
                "])\n"
            ),
        ),
        (
            "tests/n18v_env_split_echo.py",
            'subprocess.run(["env", "-S", "echo curl https://api.openai.com/v1/items"])\n',
        ),
        (
            "tests/n18v_env_split_echo.sh",
            'env -S "echo curl https://api.openai.com/v1/items"\n',
        ),
        (
            "web/tests/n18w_node_script_argument.ts",
            (
                'spawn("node", [\n'
                '  "script.js",\n'
                '  "fetch(\\\'https://api.openai.com/v1/items\\\')",\n'
                "]);\n"
            ),
        ),
        # A configured public base URL is inert until the stored client drives
        # a request, and a later reassignment invalidates that client binding.
        (
            "tests/n18x_httpx_stored_without_request.py",
            (
                'client = httpx.Client(base_url="https://api.openai.com")\n'
                "assert client is not None\n"
            ),
        ),
        (
            "tests/n18y_httpx_reassigned.py",
            (
                'client = httpx.Client(base_url="https://api.openai.com")\n'
                "client = FakeClient()\n"
                'client.get("/v1/items")\n'
            ),
        ),
        (
            "tests/n18y_httpx_instance_reassigned_in_setup.py",
            (
                "class LocalClientTest:\n"
                "    def setUp(self):\n"
                '        self.client = httpx.Client(base_url="https://api.openai.com")\n'
                "        self.client = FakeClient()\n"
                "\n"
                "    def test_items(self):\n"
                '        self.client.get("/v1/items")\n'
            ),
        ),
        # An explicit absolute request target overrides a stored base URL.
        (
            "web/tests/n18z_axios_loopback_override.ts",
            (
                'const client = axios.create({ baseURL: "https://api.openai.com" });\n'
                'await client.get("http://127.0.0.1:4321/health");\n'
            ),
        ),
        (
            "web/tests/n18z_axios_request_loopback_base.ts",
            (
                'await axios.get("/health", {\n'
                '  baseURL: "http://127.0.0.1:4321",\n'
                '  headers: { Referer: "https://cmux.com" },\n'
                "});\n"
            ),
        ),
        (
            "web/tests/n18z_axios_stored_loopback_base_override.ts",
            (
                'const client = axios.create({ baseURL: "https://api.openai.com" });\n'
                'await client.get("/health", { baseURL: "http://127.0.0.1:4321" });\n'
            ),
        ),
        (
            "web/tests/n18z_axios_chained_loopback_base_override.ts",
            (
                'await axios.create({ baseURL: "https://api.openai.com" })'
                '.get("/health", { baseURL: "http://127.0.0.1:4321" });\n'
            ),
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
            (
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
                "        _must('ok' in body, body)\n"
            ),
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
