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


def _parenthesis_delta_outside_quoted_strings(line: str) -> int:
    """Net parenthesis depth contributed by executable code on one line."""
    quote: Optional[str] = None
    escaped = False
    delta = 0
    for char in line:
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif quote is None:
            if char in ("'", '"', "`"):
                quote = char
            elif char == "(":
                delta += 1
            elif char == ")":
                delta -= 1
        elif char == quote:
            quote = None
    return delta


def _store_assertion_statement_contexts(
    contexts: dict[int, tuple[str, int]],
    indexes: list[int],
    lines: list[str],
) -> None:
    statement = "\n".join(lines)
    line_offset = 0
    for index, line in zip(indexes, lines):
        contexts[index] = (statement, line_offset)
        line_offset += len(line) + 1


def _assertion_statement_contexts(lines: list[str]) -> dict[int, tuple[str, int]]:
    """Map assertion lines to their complete expression and line offset."""
    contexts: dict[int, tuple[str, int]] = {}
    assertion_depth: Optional[int] = None
    assertion_indexes: list[int] = []
    assertion_lines: list[str] = []
    for index, line in enumerate(lines):
        if assertion_depth is None:
            if not _is_assertion_line(line):
                continue
            assertion_depth = 0

        assertion_indexes.append(index)
        assertion_lines.append(line)
        assertion_depth += _parenthesis_delta_outside_quoted_strings(line)
        if assertion_depth <= 0:
            _store_assertion_statement_contexts(
                contexts,
                assertion_indexes,
                assertion_lines,
            )
            assertion_depth = None
            assertion_indexes = []
            assertion_lines = []

    if assertion_indexes:
        _store_assertion_statement_contexts(
            contexts,
            assertion_indexes,
            assertion_lines,
        )
    return contexts


_INERT_TEXT_MATCHER = re.compile(r"\.(?:toContain|toStartWith)\s*\(")
_ASSIGNED_REFERENCE = re.compile(
    r"""(?x)
    ^\s*
    (?:(?:const|let|var)\s+)?
    (
        [A-Za-z_$][A-Za-z0-9_$]*
        (?:\.[A-Za-z_$][A-Za-z0-9_$]*)*
    )
    (?:\s*:\s*[^=]+)?
    \s*=(?!=|>)
    """
)


def _quoted_string_span_containing(
    text: str,
    index: int,
) -> Optional[tuple[int, int, str]]:
    quote: Optional[str] = None
    quote_start = -1
    escaped = False
    for position, char in enumerate(text):
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif quote is None:
            if char in ("'", '"', "`"):
                quote = char
                quote_start = position
        elif char == quote:
            if quote_start < index < position:
                return (quote_start, position, quote)
            quote = None
            quote_start = -1
        if position > index and quote is None:
            return None

    if quote is not None and quote_start < index:
        return (quote_start, len(text), quote)
    return None


def _string_literal_interpolates(
    text: str,
    start: int,
    end: int,
    quote: str,
    path_suffix: str,
) -> bool:
    prefix_start = start
    while prefix_start > 0 and text[prefix_start - 1] in "rRbBuUfF":
        prefix_start -= 1
    prefix = text[prefix_start:start]
    content = text[start + 1:end]
    if path_suffix == ".py":
        return "f" in prefix.lower()
    if path_suffix in (".js", ".mjs", ".ts", ".tsx"):
        return quote == "`" and "${" in content
    if path_suffix == ".swift":
        return quote == '"' and "\\(" in content
    if path_suffix == ".sh":
        return quote == "`" or (
            quote == '"' and ("$(" in content or "${" in content)
        )
    return False


def _is_static_text_matcher_literal(
    statement: str,
    match_index: int,
    path_suffix: str,
) -> bool:
    span = _quoted_string_span_containing(statement, match_index)
    if span is None:
        return False
    quote_start, quote_end, quote = span
    if _string_literal_interpolates(
        statement,
        quote_start,
        quote_end,
        quote,
        path_suffix,
    ):
        return False

    for matcher in _INERT_TEXT_MATCHER.finditer(statement):
        if matcher.end() > quote_start:
            continue
        if statement[matcher.end():quote_start].strip():
            continue
        if re.match(r"^\s*,?\s*\)", statement[quote_end + 1:]):
            return True
    return False


def _statement_segment_boundaries(line: str) -> list[int]:
    """Indexes of top-level, outside-quote executable statement separators."""
    boundaries: list[int] = []
    quote: Optional[str] = None
    escaped = False
    parenthesis_depth = 0
    index = 0
    while index < len(line):
        char = line[index]
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif quote is not None:
            if char == quote:
                quote = None
        elif char in ("'", '"', "`"):
            quote = char
        elif char == "(":
            parenthesis_depth += 1
        elif char == ")":
            parenthesis_depth = max(0, parenthesis_depth - 1)
        elif parenthesis_depth == 0 and char == ";":
            boundaries.append(index)
        elif parenthesis_depth == 0 and line.startswith(("&&", "||"), index):
            boundaries.append(index)
            index += 1
        index += 1
    return boundaries


def _statement_segment_index(boundaries: list[int], match_index: int) -> int:
    """Return the statement segment containing a source match."""
    return sum(boundary < match_index for boundary in boundaries)


def _statement_segment_bounds(
    line: str,
    boundaries: list[int],
    segment_index: int,
) -> tuple[int, int]:
    """Return the half-open source range for one top-level statement segment."""
    if segment_index == 0:
        start = 0
    else:
        separator = boundaries[segment_index - 1]
        separator_width = 2 if line.startswith(("&&", "||"), separator) else 1
        start = separator + separator_width
    end = boundaries[segment_index] if segment_index < len(boundaries) else len(line)
    return (start, end)


def _assigned_reference_for_url(
    line: str,
    url_index: int,
    boundaries: list[int],
) -> Optional[str]:
    """Return the statement reference whose RHS contains the URL, if any."""
    segment_index = _statement_segment_index(boundaries, url_index)
    segment_start, segment_end = _statement_segment_bounds(
        line,
        boundaries,
        segment_index,
    )
    segment = line[segment_start:segment_end]
    assignment = _ASSIGNED_REFERENCE.match(segment)
    if assignment is None or assignment.end() > url_index - segment_start:
        return None
    return assignment.group(1)


def _reference_match_is_executable(
    text: str,
    match: re.Match[str],
    path_suffix: str,
) -> bool:
    """Whether a reference occurrence is code or real string interpolation."""
    span = _quoted_string_span_containing(text, match.start())
    if span is None:
        return True
    quote_start, quote_end, quote = span
    if not _string_literal_interpolates(
        text,
        quote_start,
        quote_end,
        quote,
        path_suffix,
    ):
        return False

    before = text[quote_start + 1:match.start()]
    after = text[match.end():quote_end]
    if path_suffix in (".js", ".mjs", ".ts", ".tsx"):
        return before.rfind("${") > before.rfind("}") and "}" in after
    if path_suffix == ".py":
        return before.rfind("{") > before.rfind("}") and "}" in after
    if path_suffix == ".swift":
        return before.rfind("\\(") > before.rfind(")") and ")" in after
    if path_suffix == ".sh" and quote == '"':
        return before.endswith("${") and after.startswith("}")
    return False


def _reference_pattern(reference: str) -> re.Pattern[str]:
    """Pattern for a standalone reference read, including property prefixes."""
    return re.compile(
        rf"(?<![\w.$]){re.escape(reference)}(?![\w$:=])"
    )


def _range_uses_reference(
    text: str,
    reference: str,
    start: int,
    end: int,
    path_suffix: str,
) -> bool:
    """Whether executable code in a source range reads the reference."""
    if path_suffix == ".sh":
        shell_reference = re.compile(
            rf"\$(?:\{{{re.escape(reference)}\}}|"
            rf"{re.escape(reference)}(?![A-Za-z0-9_]))"
        )
        for match in shell_reference.finditer(text, start, end):
            span = _quoted_string_span_containing(text, match.start())
            if span is None or span[2] != "'":
                return True

    return any(
        _reference_match_is_executable(text, match, path_suffix)
        for match in _reference_pattern(reference).finditer(text, start, end)
    )


def _network_call_uses_reference(
    line: str,
    verb_match: re.Match[str],
    reference: str,
    segment_end: int,
    path_suffix: str,
) -> bool:
    """Whether a network call directly consumes the assigned reference."""
    reference_pattern = _reference_pattern(reference)
    if verb_match.group(0).lower() == "curl":
        shell_arguments = line[verb_match.end():segment_end]
        if path_suffix == ".sh":
            shell_reference = re.compile(
                rf"\$(?:\{{{re.escape(reference)}\}}|"
                rf"{re.escape(reference)}(?![A-Za-z0-9_]))"
            )
            return shell_reference.search(shell_arguments) is not None
        return any(
            _reference_match_is_executable(line, match, path_suffix)
            for match in reference_pattern.finditer(
                line,
                verb_match.end(),
                segment_end,
            )
        )

    open_parenthesis = line.find("(", verb_match.start(), segment_end)
    if open_parenthesis == -1:
        return False

    quote: Optional[str] = None
    escaped = False
    depth = 0
    close_parenthesis = segment_end
    for index in range(open_parenthesis, segment_end):
        char = line[index]
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif quote is not None:
            if char == quote:
                quote = None
        elif char in ("'", '"', "`"):
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                close_parenthesis = index
                break

    return any(
        _reference_match_is_executable(line, match, path_suffix)
        for match in reference_pattern.finditer(
            line,
            open_parenthesis + 1,
            close_parenthesis,
        )
    )


def _network_call_uses_derived_reference(
    line: str,
    boundaries: list[int],
    initial_reference: str,
    url_segment: int,
    active_verb_matches: list[tuple[re.Match[str], int]],
    path_suffix: str,
) -> bool:
    """Trace URL-derived references until one is consumed by a network call."""
    active_references = {initial_reference}
    final_segment = len(boundaries)
    for segment_index in range(url_segment + 1, final_segment + 1):
        segment_start, segment_end = _statement_segment_bounds(
            line,
            boundaries,
            segment_index,
        )
        segment = line[segment_start:segment_end]
        assignment = _ASSIGNED_REFERENCE.match(segment)
        if assignment is not None:
            assigned_reference = assignment.group(1)
            rhs_start = segment_start + assignment.end()
            derives_from_public_url = any(
                _range_uses_reference(
                    line,
                    reference,
                    rhs_start,
                    segment_end,
                    path_suffix,
                )
                for reference in active_references
            )
            if derives_from_public_url:
                active_references.add(assigned_reference)
            else:
                active_references.discard(assigned_reference)

        for verb_match, verb_segment in active_verb_matches:
            if verb_segment != segment_index:
                continue
            if any(
                _network_call_uses_reference(
                    line,
                    verb_match,
                    reference,
                    segment_end,
                    path_suffix,
                )
                for reference in active_references
            ):
                return True
    return False


def detect_live_network_host(
    line: str,
    *,
    path_suffix: str,
    assertion_context: Optional[tuple[str, int]] = None,
) -> bool:
    # High-precision signal only: an actual http(s):// URL with a public host that
    # is ALSO handed to a network-driving verb on the same line (fetch/axios/
    # requests/urlopen/...). A URL used as a string fixture (markdown builder,
    # canonical-URL assertion, toContain) opens no socket and is not flagged.
    # Bare quoted IPs in data structures are likewise too ambiguous to flag.
    # Loopback/private/CGNAT/RFC2606 hosts are allowed.
    # Exempt only a proven static expected-text literal: the whole first
    # argument to a known text matcher. Quoted commands passed through arbitrary
    # wrappers and interpolated strings remain active by default instead of
    # relying on an incomplete executor allowlist.
    if assertion_context is not None:
        statement, line_offset = assertion_context
    else:
        statement, line_offset = "", 0

    def is_static_matcher_literal(match_index: int) -> bool:
        return assertion_context is not None and _is_static_text_matcher_literal(
            statement,
            line_offset + match_index,
            path_suffix,
        )

    boundaries = _statement_segment_boundaries(line)
    active_verb_matches = [
        (match, _statement_segment_index(boundaries, match.start()))
        for match in _NETWORK_VERB.finditer(line)
        if not is_static_matcher_literal(match.start())
    ]
    if not active_verb_matches:
        return False
    active_verb_segments = {segment for _match, segment in active_verb_matches}

    for match in _URL.finditer(line):
        if is_static_matcher_literal(match.start()):
            continue
        host = match.group(1)
        if "." not in host:
            continue  # bare hostname, not a real domain
        if _PRIVATE_HOST.search(host):
            continue
        if _looks_like_ipv4(host) and _is_private_ipv4(host):
            continue
        url_segment = _statement_segment_index(boundaries, match.start())
        if url_segment in active_verb_segments:
            return True
        reference = _assigned_reference_for_url(
            line,
            match.start(),
            boundaries,
        )
        if reference is None:
            continue
        if _network_call_uses_derived_reference(
            line,
            boundaries,
            reference,
            url_segment,
            active_verb_matches,
            path_suffix,
        ):
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


def scan_text(rel_posix: str, text: str) -> list[Finding]:
    suffix = pathlib.PurePosixPath(rel_posix).suffix
    raw_lines = text.splitlines()
    code_lines = [_strip_comment(l, suffix) for l in raw_lines]
    assertion_contexts = _assertion_statement_contexts(code_lines)
    findings: list[Finding] = []

    for i, code in enumerate(code_lines):
        if not code.strip():
            continue
        line_no = i + 1
        snippet = raw_lines[i].strip()

        if detect_assert_on_duration(code):
            findings.append(Finding(rel_posix, line_no, RULE_ASSERT_ON_DURATION, snippet))
        if detect_live_network_host(
            code,
            path_suffix=suffix,
            assertion_context=assertion_contexts.get(i),
        ):
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
            "tests/curl-quoted-separator.sh",
            'curl -H "X-Test: a&&b" https://cmux.com/install.sh\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/curl-shell-string.sh",
            'bash -c "curl -fsSL https://cmux.com/install.sh"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/curl-subprocess.py",
            'subprocess.run("curl -fsSL https://cmux.com/install.sh", shell=True, check=True)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/curl-subprocess-multiline.py",
            "assert subprocess.run(\n"
            '    "curl -fsSL https://cmux.com/install.sh",\n'
            "    shell=True,\n"
            "    check=False,\n"
            ").returncode == 0\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/requests-fstring.py",
            "assert f\"{requests.get('https://api.openai.com/v1/items')}\" == expected\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/project-command-wrapper.py",
            'assert _run("curl -fsSL https://cmux.com/install.sh").returncode == 0\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/fetch-template.ts",
            "const result = `${await fetch('https://api.openai.com/v1/items')}`\n",
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/mixed-fetches.ts",
            'fetch("http://127.0.0.1:4321"); fetch("https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/fetch-conditional-and.ts",
            'fetch(enabled && "https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/fetch-conditional-or.ts",
            'fetch(cachedURL || "https://api.openai.com/v1/items")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-fetch.ts",
            'const url = "https://api.openai.com/v1/items"; await fetch(url)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/assigned-request.py",
            'url = "https://api.openai.com/v1/items"; requests.get(url)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-request-wrapper.ts",
            'const request = new Request("https://api.openai.com/v1/items"); '
            'await fetch(request)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/assigned-request-wrapper.py",
            'request = Request("https://api.openai.com/v1/items"); '
            'urlopen(request)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "cmuxTests/assigned-request-wrapper.swift",
            'let request = URLRequest(url: URL(string: '
            '"https://api.openai.com/v1/items")!); fetch(request)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-request-alias.ts",
            'const url = "https://api.openai.com/v1/items"; '
            'const request = new Request(url); await fetch(request)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/assigned-request-alias.py",
            'url = "https://api.openai.com/v1/items"; '
            'request = Request(url); urlopen(request)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-config-alias.ts",
            'const url = "https://api.openai.com/v1/items"; '
            'const config = { method: "GET", url }; await axios(config)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-transitive-alias.ts",
            'const url = "https://api.openai.com/v1/items"; '
            'const request = new Request(url); const options = { request }; '
            'await fetch(options)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-property.ts",
            'config.url = "https://api.openai.com/v1/items"; '
            'await fetch(config.url)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-config.ts",
            'const cfg = { method: "GET", '
            'url: "https://api.openai.com/v1/items" }; await axios(cfg)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-array.ts",
            'const urls = ["http://127.0.0.1:4321", '
            '"https://api.openai.com/v1/items"]; await fetch(urls[1])\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-fetch-template.ts",
            'const url = "https://api.openai.com/v1/items"; fetch(`${url}/next`)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/assigned-request-fstring.py",
            'url = "https://api.openai.com/v1/items"; requests.get(f"{url}/next")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/assigned-curl.sh",
            'url="https://cmux.com/install.sh"; curl "$url"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/assigned-curl-braced.sh",
            'endpoint="https://cmux.com"; curl "${endpoint}/install.sh"\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/assigned-curl-fstring.py",
            'url="https://cmux.com/install.sh"; '
            'subprocess.run(f"curl {url}", shell=True)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "web/tests/assigned-curl-template.ts",
            'const url="https://cmux.com/install.sh"; exec(`curl ${url}`)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "cmuxTests/assigned-curl-interpolation.swift",
            'let url="https://cmux.com/install.sh"; run("curl \\(url)")\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "tests/assigned-curl-wrapper.py",
            'url="https://cmux.com/install.sh"; _run("curl " + url)\n',
            {RULE_LIVE_NETWORK_HOST},
        ),
        (
            "cmuxTests/assigned-fetch-interpolation.swift",
            'let url = "https://api.openai.com/v1/items"; fetch("\\(url)/next")\n',
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
            "web/tests/n17b.ts",
            'expect(text).toContain(\n'
            '  "curl -fsSL https://cmux.com/install.sh | sh",\n'
            ')\n',
        ),
        (
            "web/tests/n17c.ts",
            'expect(text).toStartWith("curl -fsSL https://cmux.com/install.sh | sh")\n',
        ),
        (
            "web/tests/n17d.ts",
            'fetch("http://127.0.0.1:4321"); '
            'expect(text).toContain("https://cmux.com/docs/api")\n',
        ),
        (
            "web/tests/n17e.ts",
            'fetch("http://127.0.0.1:4321"); '
            'const docs = "https://cmux.com/docs/api"\n',
        ),
        (
            "web/tests/n17f.ts",
            'fetch("http://127.0.0.1:4321") && '
            'render("https://cmux.com/docs/api")\n',
        ),
        (
            "web/tests/n17g.ts",
            'fetch("http://127.0.0.1:4321") || '
            'render("https://cmux.com/docs/api")\n',
        ),
        (
            "web/tests/n17h.ts",
            'expect(text).toContain("curl $(uname) https://cmux.com/install.sh")\n',
        ),
        (
            "web/tests/n17i.ts",
            'expect(text).toContain("curl ${HOME} https://cmux.com/install.sh")\n',
        ),
        (
            "web/tests/n17j.ts",
            'const docs = "https://cmux.com/docs/api"; '
            'await fetch("http://127.0.0.1:4321")\n',
        ),
        (
            "web/tests/n17k.ts",
            'let url = "https://cmux.com/docs/api"; '
            'url = "http://127.0.0.1:4321"; await fetch(url)\n',
        ),
        (
            "tests/n17l.py",
            'url = "https://cmux.com/docs/api"; '
            'requests.get(url="http://127.0.0.1:4321")\n',
        ),
        (
            "web/tests/n17m.tsx",
            'const node = <Thing url="https://cmux.com/docs/api" />; fetch(url)\n',
        ),
        (
            "tests/n17n.sh",
            'url="https://cmux.com/install.sh"; curl "http://127.0.0.1/install.sh"\n',
        ),
        (
            "tests/n17o.sh",
            'url="https://cmux.com/install.sh"; '
            'url="http://127.0.0.1/install.sh"; curl "$url"\n',
        ),
        (
            "tests/n17p.py",
            'url="https://cmux.com/install.sh"; '
            'subprocess.run(f"curl url", shell=True)\n',
        ),
        (
            "web/tests/n17q.ts",
            'const url="https://cmux.com/install.sh"; '
            'exec(`curl ${other}/url`)\n',
        ),
        (
            "web/tests/n17r.ts",
            'const cfg = { url: "https://cmux.com/docs/api" }; '
            'cfg = { url: "http://127.0.0.1:4321" }; axios(cfg)\n',
        ),
        (
            "web/tests/n17s.ts",
            'config.url = "https://cmux.com/docs/api"; '
            'config.url = "http://127.0.0.1:4321"; fetch(config.url)\n',
        ),
        (
            "web/tests/n17t.ts",
            'let url = "https://cmux.com/docs/api"; '
            'url = "http://127.0.0.1:4321"; '
            'const request = new Request(url); fetch(request)\n',
        ),
        (
            "web/tests/n17u.ts",
            'const url = "https://cmux.com/docs/api"; '
            'let request = new Request(url); '
            'request = new Request("http://127.0.0.1:4321"); fetch(request)\n',
        ),
        (
            "web/tests/n17v.ts",
            'const url = "https://cmux.com/docs/api"; '
            'const request = new Request("http://127.0.0.1:4321"); '
            'fetch(request); render(url)\n',
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
