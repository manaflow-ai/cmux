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

# High-confidence real-sleep call sites. Arbitrary `foo.sleep(...)` calls are
# excluded because injected test clocks and enum constructors use that spelling
# too. These are all CALL forms, so quoted `sleep 5` fixture data never matches.
_SLEEP_CALL = re.compile(
    r"""(?x)
    (?<!\.)\bsleep\s*\(                    # unqualified C-style sleep(...)
  | \b(?:Darwin|Glibc)\.sleep\s*\(
  | \busleep\s*\(
  | \bnanosleep\s*\(
  | Thread\.sleep\s*\(
  | \bTask(?:\s*<[^>\n]+>)?\s*\.sleep\s*\(
  | try\s+await\s+Task\.sleep
  | \b(?:ContinuousClock|SuspendingClock)\s*(?:\.\s*init)?\s*
    \(\s*\)\.sleep\s*\(
  | \bBun\.sleep\s*\(
  | \bsetTimeout\s*\(                       # JS, when used as a bare delay
    """
)

_NAMED_SLEEP_CALL = re.compile(
    r"(?<![.\w])(?:(self|Self)\s*[?!]?\s*\.\s*)?"
    r"([A-Za-z_]\w*)[?!]?\.sleep\s*\("
)
_MEMBER_CHAIN_SLEEP_CALL = re.compile(
    r"(?<![.\w])([A-Za-z_]\w*)[?!]?\s*\.\s*"
    r"([A-Za-z_]\w*)[?!]?\s*\.sleep\s*\("
)
_CONTINUED_SLEEP_CALL = re.compile(r"^\s*[?!]?\s*\.sleep\s*\(")
_PYTHON_SLEEP_MODULES = frozenset(
    ("time", "asyncio", "trio", "anyio", "gevent")
)
_PYTHON_MODULE_SLEEP_CALL = re.compile(
    r"(?<![.\w])([A-Za-z_]\w*)\.sleep\s*\("
)
_PYTHON_ASSIGNMENT_TARGET = re.compile(
    r"(?:^|;)\s*([A-Za-z_]\w*)\s*(?::[^=,\n]+)?=(?!=)"
)
_PYTHON_CHAINED_ASSIGNMENT_TARGET = re.compile(
    r"(?<![=!<>:])=\s*([A-Za-z_]\w*)\s*=(?!=)"
)
_PYTHON_DEFINITION_TARGET = re.compile(
    r"^\s*(?:async\s+)?(?:def|class)\s+([A-Za-z_]\w*)\b"
)
_PYTHON_FOR_TARGET = re.compile(
    r"^\s*(?:async\s+)?for\s+([A-Za-z_]\w*)\b"
)
_PYTHON_AS_TARGET = re.compile(r"\bas\s+([A-Za-z_]\w*)\b")
_PYTHON_DEL_TARGET = re.compile(r"^\s*del\s+([A-Za-z_]\w*)\b")
_PYTHON_FUNCTION_HEADER = re.compile(
    r"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\("
)
_PYTHON_CLASS_HEADER = re.compile(r"^\s*class\s+([A-Za-z_]\w*)\b")
_LOCAL_SCOPE_HEADER = re.compile(
    r"^\s*"
    r"(?:(?:@\w+(?:\([^)]*\))?|[A-Za-z_]\w*(?:\([^)]*\))?)\s+)*"
    r"(?:func\b|init[?!]?\s*\(|def\b)"
)
_CONDITIONAL_SCOPE_HEADER = re.compile(
    r"^\s*(?:}\s*else\s+)?(?:if|while|for)\b"
)
_RUNTIME_IF_SCOPE_HEADER = re.compile(
    r"^\s*(?:}\s*else\s+)?if\b"
)
_RUNTIME_ELSE_SCOPE_HEADER = re.compile(r"^\s*}\s*else\b")
_RUNTIME_ELSE_IF_SCOPE_HEADER = re.compile(r"^\s*}\s*else\s+if\b")
_DO_SCOPE_HEADER = re.compile(r"\bdo\s*$")
_SWITCH_SCOPE_HEADER = re.compile(r"^\s*switch\b")
_SWITCH_CASE_HEADER = re.compile(
    r"^\s*(?:@unknown\s+)?(?:case\b|default\s*:)"
)
_SWITCH_CASE_LEADING_BINDING = re.compile(
    r"^\s*(?:@unknown\s+)?case\s+(?:let|var)\b"
)
_COMPILATION_DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b")
_TYPE_SCOPE_HEADER = re.compile(
    r"\b(struct|class|actor|enum|extension|protocol)\s+"
    r"((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)"
)
_CLASS_INHERITANCE_HEADER = re.compile(
    r"\bclass\s+((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)\s*:\s*"
    r"((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)"
)
_FOR_SCOPE_BINDING = re.compile(
    r"^\s*for(?:\s+try)?(?:\s+await)?\s+([A-Za-z_]\w*)\s+in\b"
)
_REAL_CLOCK_TYPE = re.compile(
    r"^\s*:\s*(?:[A-Za-z_]\w*\.)*"
    r"(?:ContinuousClock|SuspendingClock)\??(?=\s|=|[,){]|$)"
)
_REAL_CLOCK_INIT = re.compile(
    r"^\s*(?::[^=]+)?=\s*(?:[A-Za-z_]\w*\.)*"
    r"(?:ContinuousClock|SuspendingClock)\s*(?:\.\s*init)?\s*\("
)
_REAL_CLOCK_CAST = re.compile(
    r".+\bas[!?]?\s+"
    r"((?:[A-Za-z_]\w*\.)*(?:ContinuousClock|SuspendingClock))\??\s*$"
)
_SLASH_NONCODE_MARKER = re.compile(r'//|/\*|"""|["\']')
_HASH_NONCODE_MARKER = re.compile(r'#|"""|["\']')
_BLOCK_COMMENT_MARKER = re.compile(r'/\*|\*/')
_DIRECT_ASSIGNMENT = re.compile(
    r"(?:^|[;{}])\s*([A-Za-z_]\w*)\s*=(?!=)\s*([^;]+)"
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


def _mask_noncode(lines: list[str], path_suffix: str) -> list[str]:
    """Replace quoted strings and block comments while preserving positions."""
    masked_lines: list[str] = []
    quote: Optional[str] = None
    block_comment_depth = 0
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
                if quote == '"""':
                    quote_end = line.find(quote, i)
                    if quote_end < 0:
                        masked[i:] = " " * (len(line) - i)
                        break
                    end = quote_end + len(quote)
                    masked[i:end] = " " * (end - i)
                    i = end
                    quote = None
                    continue

                quote_end = line.find(quote, i)
                escape = line.find("\\", i)
                if escape >= 0 and (quote_end < 0 or escape < quote_end):
                    end = min(len(line), escape + 2)
                    masked[i:end] = " " * (end - i)
                    i = end
                    continue
                if quote_end < 0:
                    masked[i:] = " " * (len(line) - i)
                    break
                end = quote_end + 1
                masked[i:end] = " " * (end - i)
                i = end
                quote = None
                continue

            marker = marker_pattern.search(line, i)
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

        # Single-line string delimiters cannot carry lexical scope across a
        # source line; an unterminated literal is safer to forget than to mask
        # the rest of the file and infer a stale binding.
        if quote in ('"', "'"):
            quote = None
        masked_lines.append("".join(masked))

    return masked_lines


def _annotated_receiver_kind(text: str, receiver: str) -> Optional[bool]:
    annotation = re.search(
        rf"\b{re.escape(receiver)}\s*:\s*"
        r"((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)",
        text,
    )
    if not annotation:
        return None
    type_name = annotation.group(1).rsplit(".", 1)[-1]
    return type_name in ("ContinuousClock", "SuspendingClock")


def _annotated_receiver_type(text: str, receiver: str) -> Optional[str]:
    """Return an explicitly annotated Swift-like receiver type."""
    annotation = re.search(
        rf"\b{re.escape(receiver)}\s*:\s*"
        r"((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)\??",
        text,
    )
    return annotation.group(1) if annotation else None


def _real_clock_cast_type(declaration: str) -> Optional[str]:
    """Return a concrete clock type when the initializer ends in a cast."""
    assignment = re.match(r"^\s*(?::[^=]+)?=\s*(.+)$", declaration)
    if not assignment:
        return None
    expression = assignment.group(1).strip()

    while expression.startswith("(") and expression.endswith(")"):
        depth = 0
        wraps_expression = True
        for index, character in enumerate(expression):
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0 and index != len(expression) - 1:
                    wraps_expression = False
                    break
        if not wraps_expression or depth != 0:
            break
        expression = expression[1:-1].strip()

    cast = _REAL_CLOCK_CAST.fullmatch(expression)
    return cast.group(1) if cast else None


def _captured_receiver_expression(text: str, receiver: str) -> Optional[str]:
    assignment = re.search(
        rf"(?:^|,)\s*(?:(?:weak|unowned(?:\([^)]*\))?)\s+)?"
        rf"{re.escape(receiver)}\s*=\s*([^,]+)",
        text,
    )
    if not assignment:
        return None
    return assignment.group(1).strip()


def _captured_receiver_kind(text: str, receiver: str) -> Optional[bool]:
    expression = _captured_receiver_expression(text, receiver)
    if expression is None:
        return None
    declaration = f"= {expression}"
    return bool(
        _REAL_CLOCK_INIT.search(declaration)
        or _real_clock_cast_type(declaration)
    )


def _captured_receiver_alias(
    text: str, receiver: str
) -> Optional[tuple[str, bool]]:
    expression = _captured_receiver_expression(text, receiver)
    if expression is None:
        return None
    alias = re.fullmatch(
        r"(?:(self)\s*\.\s*)?([A-Za-z_]\w*)[?!]?",
        expression,
    )
    if not alias:
        return None
    return (alias.group(2), alias.group(1) is not None)


def _closure_header_parts(text: str) -> Optional[tuple[Optional[str], str]]:
    """Return a leading capture list and parameter text before closure `in`."""
    in_token = re.search(r"\bin\b", text)
    if not in_token:
        return None
    parameters = text[: in_token.start()].strip()
    while parameters:
        attribute = re.match(r"@\w+(?:\([^)]*\))?\s*", parameters)
        if not attribute:
            break
        parameters = parameters[attribute.end() :].lstrip()

    if not parameters.startswith("["):
        return (None, parameters)
    depth = 0
    for index, character in enumerate(parameters):
        if character == "[":
            depth += 1
        elif character == "]":
            depth -= 1
            if depth == 0:
                return (
                    parameters[1:index],
                    parameters[index + 1 :].lstrip(),
                )
    return (None, parameters)


def _closure_receiver_kind(text: str, receiver: str) -> Optional[bool]:
    header_parts = _closure_header_parts(text)
    if header_parts is None:
        return None
    capture_list, parameters = header_parts
    captured_kind = (
        _captured_receiver_kind(capture_list, receiver)
        if capture_list is not None
        else None
    )
    if not parameters:
        return captured_kind
    if not (
        parameters.startswith("(")
        or re.fullmatch(r"[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*", parameters)
    ):
        return None
    annotated = _annotated_receiver_kind(parameters, receiver)
    if annotated is not None:
        return annotated
    if re.search(rf"\b{re.escape(receiver)}\b", parameters):
        return False
    return captured_kind


def _closure_receiver_alias(
    text: str, receiver: str
) -> Optional[tuple[str, bool]]:
    header_parts = _closure_header_parts(text)
    if header_parts is None:
        return None
    capture_list, _ = header_parts
    if capture_list is None:
        return None
    return _captured_receiver_alias(capture_list, receiver)


def _closure_header_text(text: str, following_lines: Iterable[str]) -> str:
    """Join a plausible multiline closure header through its `in` token."""
    if re.search(r"\bin\b", text):
        return text

    pieces = [text]
    started = bool(text.strip())
    for line in following_lines:
        stripped = line.strip()
        if not stripped:
            continue
        if not started:
            if not re.match(
                r"^(?:\[|@|\(|[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*\s*$)",
                stripped,
            ):
                break
            started = True
        pieces.append(line)
        if re.search(r"\bin\b", line):
            return "\n".join(pieces)
        if "{" in line or "}" in line or ";" in line:
            break
    return text


def _local_declarations(text: str) -> list[tuple[int, str, str]]:
    """Return individual `let`/`var` declarators on one line."""
    declarations: list[tuple[int, str, str]] = []

    for keyword in re.finditer(r"\b(?:let|var)\b", text):
        segment_start = keyword.end()
        paren_depth = 0
        bracket_depth = 0
        segments: list[tuple[int, int]] = []
        i = segment_start

        while i < len(text):
            char = text[i]
            if char == "(":
                paren_depth += 1
            elif char == ")" and paren_depth:
                paren_depth -= 1
            elif char == "[":
                bracket_depth += 1
            elif char == "]" and bracket_depth:
                bracket_depth -= 1
            elif not (paren_depth or bracket_depth):
                if char == ",":
                    segments.append((segment_start, i))
                    segment_start = i + 1
                elif char in ";{":
                    segments.append((segment_start, i))
                    break
            i += 1
        else:
            segments.append((segment_start, len(text)))

        for start, end in segments:
            segment = text[start:end]
            name = re.match(r"\s*([A-Za-z_]\w*)\b", segment)
            if not name:
                continue
            name_end = start + name.end()
            declarations.append(
                (
                    start + name.start(1),
                    name.group(1),
                    text[name_end:end],
                )
            )

    return declarations


def _split_top_level_segments(text: str) -> list[tuple[int, int]]:
    """Split comma-separated text while preserving nested call boundaries."""
    segments: list[tuple[int, int]] = []
    segment_start = 0
    paren_depth = 0
    bracket_depth = 0
    brace_depth = 0
    for index, character in enumerate(text):
        if character == "(":
            paren_depth += 1
        elif character == ")" and paren_depth:
            paren_depth -= 1
        elif character == "[":
            bracket_depth += 1
        elif character == "]" and bracket_depth:
            bracket_depth -= 1
        elif character == "{":
            brace_depth += 1
        elif character == "}" and brace_depth:
            brace_depth -= 1
        elif character == "," and not (
            paren_depth or bracket_depth or brace_depth
        ):
            segments.append((segment_start, index))
            segment_start = index + 1
    segments.append((segment_start, len(text)))
    return segments


def _tuple_receiver_declarations(
    text: str, receiver: str
) -> list[tuple[int, str]]:
    """Return direct tuple bindings for this receiver on one line."""
    declarations: list[tuple[int, str]] = []
    tuple_binding = re.compile(
        r"\b(?:let|var)\s*\(([^()]*)\)\s*=\s*\((.*)\)\s*(?:;|$)"
    )
    for match in tuple_binding.finditer(text):
        pattern = match.group(1)
        values = match.group(2)
        pattern_segments = _split_top_level_segments(pattern)
        value_segments = _split_top_level_segments(values)
        if len(pattern_segments) != len(value_segments):
            continue
        for (pattern_start, pattern_end), (value_start, value_end) in zip(
            pattern_segments, value_segments
        ):
            element = pattern[pattern_start:pattern_end]
            name = re.fullmatch(
                rf"\s*{re.escape(receiver)}\b(\s*:[^=]+)?\s*",
                element,
            )
            if not name:
                continue
            receiver_column = (
                match.start(1)
                + pattern_start
                + element.find(receiver)
            )
            annotation = name.group(1) or ""
            value = values[value_start:value_end].strip()
            declarations.append(
                (receiver_column, f"{annotation} = {value}")
            )
    return declarations


def _local_receiver_declarations(
    text: str, receiver: str
) -> list[tuple[int, str]]:
    """Return this receiver's individual `let`/`var` declarators on one line."""
    declarations = [
        (position, declaration)
        for position, name, declaration in _local_declarations(text)
        if name == receiver
    ]
    declarations.extend(_tuple_receiver_declarations(text, receiver))
    return declarations


def _local_receiver_assignments(
    text: str, receiver: str
) -> list[tuple[int, str]]:
    """Return direct assignment statements for this receiver on one line."""
    return [
        (match.start(1), f"= {match.group(2).strip()}")
        for match in _DIRECT_ASSIGNMENT.finditer(text)
        if match.group(1) == receiver
    ]


def _receiver_declaration_kind(
    declaration: str, following_lines: Iterable[str]
) -> bool:
    """Classify a receiver declaration, including a continued initializer."""
    probe = declaration
    if probe.rstrip().endswith(("=", ":")):
        continuation = next(
            (line.strip() for line in following_lines if line.strip()),
            "",
        )
        probe = f"{probe} {continuation}"
    return bool(
        _REAL_CLOCK_TYPE.search(probe)
        or _REAL_CLOCK_INIT.search(probe)
        or _real_clock_cast_type(probe)
    )


def _receiver_declaration_type(
    declaration: str, following_lines: Iterable[str]
) -> Optional[str]:
    """Return an explicit or directly initialized Swift-like value type."""
    probe = declaration
    if probe.rstrip().endswith(("=", ":")):
        continuation = next(
            (line.strip() for line in following_lines if line.strip()),
            "",
        )
        probe = f"{probe} {continuation}"
    annotation = re.match(
        r"^\s*:\s*((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)\??"
        r"(?=\s|=|[,){]|$)",
        probe,
    )
    if annotation:
        return annotation.group(1)
    cast_type = _real_clock_cast_type(probe)
    if cast_type:
        return cast_type
    initializer = re.match(
        r"^\s*(?::[^=]+)?=\s*"
        r"((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)\s*(?:[?!]\s*)?\(",
        probe,
    )
    return initializer.group(1) if initializer else None


def _receiver_declaration_inherits_kind(declaration: str, receiver: str) -> bool:
    stripped = declaration.strip()
    if not stripped or stripped == "else":
        return True
    return bool(
        re.fullmatch(
            rf"=\s*(?:self\s*\.\s*)?{re.escape(receiver)}[?!]?\s*(?:else)?",
            stripped,
        )
    )


def _receiver_declaration_alias(
    declaration: str,
) -> Optional[tuple[str, bool]]:
    """Return a simple source binding and whether it is `self`-qualified."""
    alias = re.fullmatch(
        r"=\s*(?:(self)\s*\.\s*)?([A-Za-z_]\w*)[?!]?\s*(?:else)?",
        declaration.strip(),
    )
    if not alias:
        return None
    return (alias.group(2), alias.group(1) is not None)


@dataclass
class _CompilationScopeFrame:
    base_scopes: list[dict[str, bool]]
    base_scope_kinds: list[str]
    base_scope_mutations: list[Optional[tuple[int, bool]]]
    base_scope_declared_real: list[bool]
    branch_scopes: list[list[dict[str, bool]]]
    branch_scope_mutations: list[
        list[Optional[tuple[int, bool]]]
    ]
    branch_scope_declared_real: list[list[bool]]
    has_else: bool = False


@dataclass
class _RuntimeScopeFrame:
    base_scopes: list[dict[str, bool]]
    base_scope_mutations: list[Optional[tuple[int, bool]]]
    base_scope_declared_real: list[bool]
    branch_scopes: list[list[dict[str, bool]]]
    branch_scope_mutations: list[
        list[Optional[tuple[int, bool]]]
    ]
    branch_scope_declared_real: list[list[bool]]
    has_else: bool = False


def _copy_scope_stack(
    scopes: list[dict[str, bool]],
) -> list[dict[str, bool]]:
    return [dict(scope) for scope in scopes]


def _merge_compilation_branches(
    frame: _CompilationScopeFrame, receiver: str
) -> list[dict[str, bool]]:
    branches = list(frame.branch_scopes)
    if not frame.has_else:
        branches.append(_copy_scope_stack(frame.base_scopes))

    merged = _copy_scope_stack(frame.base_scopes)
    for scope_index, scope in enumerate(merged):
        values = [
            branch[scope_index].get(receiver)
            for branch in branches
            if scope_index < len(branch)
        ]
        if any(value is True for value in values):
            scope[receiver] = True
        elif any(value is False for value in values):
            scope[receiver] = False
        else:
            scope.pop(receiver, None)
    return merged


def _merge_compilation_mutations(
    frame: _CompilationScopeFrame,
) -> list[Optional[tuple[int, bool]]]:
    branches = list(frame.branch_scope_mutations)
    if not frame.has_else:
        branches.append(list(frame.base_scope_mutations))

    merged = list(frame.base_scope_mutations)
    for scope_index in range(len(merged)):
        mutations = [
            branch[scope_index]
            for branch in branches
            if scope_index < len(branch)
            and branch[scope_index] is not None
        ]
        if not mutations:
            continue
        targets = {mutation[0] for mutation in mutations}
        if len(targets) == 1:
            merged[scope_index] = (
                targets.pop(),
                any(mutation[1] for mutation in mutations),
            )
        else:
            # Divergent lexical owners are ambiguous; retain the outermost
            # owner and degrade its kind to unknown/non-real.
            merged[scope_index] = (
                min(targets),
                False,
            )
    return merged


def _merge_compilation_declared_real(
    frame: _CompilationScopeFrame,
) -> list[bool]:
    branches = list(frame.branch_scope_declared_real)
    if not frame.has_else:
        branches.append(list(frame.base_scope_declared_real))
    return [
        all(
            scope_index < len(branch) and branch[scope_index]
            for branch in branches
        )
        for scope_index in range(len(frame.base_scope_declared_real))
    ]


def _merge_runtime_branches(
    frame: _RuntimeScopeFrame, receiver: str
) -> list[dict[str, bool]]:
    branches = list(frame.branch_scopes)
    if not frame.has_else:
        branches.append(_copy_scope_stack(frame.base_scopes))

    merged = _copy_scope_stack(frame.base_scopes)
    for scope_index, scope in enumerate(merged):
        values = [
            branch[scope_index].get(receiver)
            for branch in branches
            if scope_index < len(branch)
        ]
        if values and all(value is True for value in values):
            scope[receiver] = True
        elif any(value is False for value in values):
            scope[receiver] = False
        else:
            scope.pop(receiver, None)
    return merged


def _merge_runtime_mutations(
    frame: _RuntimeScopeFrame,
) -> list[Optional[tuple[int, bool]]]:
    branches = list(frame.branch_scope_mutations)
    if not frame.has_else:
        branches.append(list(frame.base_scope_mutations))

    merged = list(frame.base_scope_mutations)
    for scope_index in range(len(merged)):
        mutations = [
            branch[scope_index]
            for branch in branches
            if scope_index < len(branch)
        ]
        concrete = [mutation for mutation in mutations if mutation is not None]
        if not concrete:
            continue
        targets = {mutation[0] for mutation in concrete}
        if len(concrete) == len(mutations) and len(targets) == 1:
            merged[scope_index] = (
                targets.pop(),
                all(mutation[1] for mutation in concrete),
            )
        else:
            merged[scope_index] = (min(targets), False)
    return merged


def _merge_runtime_declared_real(frame: _RuntimeScopeFrame) -> list[bool]:
    branches = list(frame.branch_scope_declared_real)
    if not frame.has_else:
        branches.append(list(frame.base_scope_declared_real))
    return [
        all(
            scope_index < len(branch) and branch[scope_index]
            for branch in branches
        )
        for scope_index in range(len(frame.base_scope_declared_real))
    ]


def _nearest_receiver_kind(
    scopes: list[dict[str, bool]], receiver: str
) -> Optional[bool]:
    return next(
        (scope[receiver] for scope in reversed(scopes) if receiver in scope),
        None,
    )


def _switch_case_receiver_kind(
    candidate: str, receiver: str
) -> Optional[bool]:
    """Return the kind of a receiver bound by a Swift switch pattern."""
    if not _SWITCH_CASE_HEADER.match(candidate):
        return None

    pattern = re.split(r"\bwhere\b", candidate, maxsplit=1)[0]
    escaped_receiver = re.escape(receiver)
    has_local_binding = bool(
        re.search(
            rf"\b(?:let|var)\s+{escaped_receiver}\b",
            pattern,
        )
    )
    if not has_local_binding and _SWITCH_CASE_LEADING_BINDING.match(pattern):
        has_local_binding = bool(
            re.search(
                rf"(?<![.\w]){escaped_receiver}\b(?!\s*:)", pattern
            )
        )
    if not has_local_binding:
        return None

    has_explicit_real_type = bool(
        re.search(
            rf"\b{escaped_receiver}\b\s+as\s+"
            r"(?:[A-Za-z_]\w*\.)*(?:ContinuousClock|SuspendingClock)\b",
            pattern,
        )
    )
    return has_explicit_real_type


def _has_explicit_real_member(
    masked_lines: list[str],
    call_index: int,
    call_column: int,
    receiver: str,
    external_real_members: Optional[dict[str, set[str]]] = None,
) -> bool:
    """Find this type's explicit real-clock member, independent of file order."""
    depth = 0
    pending_type: Optional[str] = None
    active_types: list[tuple[str, int]] = []
    call_type: Optional[str] = None
    explicit_member_types: set[str] = set()
    real_member_types: set[str] = set()

    for line_index, candidate in enumerate(masked_lines):
        type_header = _TYPE_SCOPE_HEADER.search(candidate)
        if type_header:
            type_kind = type_header.group(1)
            declared_type = type_header.group(2)
            if (
                type_kind != "extension"
                and "." not in declared_type
                and active_types
            ):
                declared_type = f"{active_types[-1][0]}.{declared_type}"
            pending_type = declared_type
        events: list[tuple[int, str, Optional[str]]] = []
        events.extend(
            (position, "binding", declaration)
            for position, declaration in _local_receiver_declarations(
                candidate, receiver
            )
        )
        events.extend(
            (position, token, None)
            for position, token in enumerate(candidate)
            if token in "{}"
        )
        if line_index == call_index:
            events.append((call_column, "call", None))
        events.sort(key=lambda event: event[0])

        for _, event, declaration in events:
            if event == "call":
                if active_types:
                    call_type = active_types[-1][0]
            elif event == "{":
                depth += 1
                if pending_type is not None:
                    active_types.append((pending_type, depth))
                    pending_type = None
            elif event == "}":
                if active_types and active_types[-1][1] == depth:
                    active_types.pop()
                depth = max(0, depth - 1)
            elif (
                declaration is not None
                and active_types
                and depth == active_types[-1][1]
            ):
                type_name = active_types[-1][0]
                explicit_member_types.add(type_name)
                if _receiver_declaration_kind(
                    declaration, masked_lines[line_index + 1 :]
                ):
                    real_member_types.add(type_name)

    if call_type is None:
        return False
    if call_type in real_member_types:
        return True
    if call_type in explicit_member_types:
        return False
    return bool(
        external_real_members is not None
        and receiver in external_real_members.get(call_type, set())
    )


def _explicit_real_clock_members(
    masked_lines: list[str],
) -> dict[str, set[str]]:
    """Index explicit real-clock members by fully nested Swift type name."""
    depth = 0
    pending_type: Optional[str] = None
    active_types: list[tuple[str, int]] = []
    real_members: dict[str, set[str]] = {}

    for line_index, candidate in enumerate(masked_lines):
        type_header = _TYPE_SCOPE_HEADER.search(candidate)
        if type_header:
            type_kind = type_header.group(1)
            declared_type = type_header.group(2)
            if (
                type_kind != "extension"
                and "." not in declared_type
                and active_types
            ):
                declared_type = f"{active_types[-1][0]}.{declared_type}"
            pending_type = declared_type

        events: list[
            tuple[int, str, Optional[tuple[str, str]]]
        ] = []
        events.extend(
            (position, "binding", (name, declaration))
            for position, name, declaration in _local_declarations(candidate)
        )
        events.extend(
            (position, token, None)
            for position, token in enumerate(candidate)
            if token in "{}"
        )
        events.sort(key=lambda event: event[0])

        for _, event, binding in events:
            if event == "{":
                depth += 1
                if pending_type is not None:
                    active_types.append((pending_type, depth))
                    pending_type = None
            elif event == "}":
                if active_types and active_types[-1][1] == depth:
                    active_types.pop()
                depth = max(0, depth - 1)
            elif (
                binding is not None
                and active_types
                and depth == active_types[-1][1]
            ):
                name, declaration = binding
                if _receiver_declaration_kind(
                    declaration, masked_lines[line_index + 1 :]
                ):
                    real_members.setdefault(active_types[-1][0], set()).add(name)

    return real_members


def _explicit_type_parents(masked_lines: list[str]) -> dict[str, str]:
    """Index direct Swift class inheritance by fully nested type name."""
    depth = 0
    pending_type: Optional[str] = None
    active_types: list[tuple[str, int]] = []
    parents: dict[str, str] = {}

    for candidate in masked_lines:
        type_header = _TYPE_SCOPE_HEADER.search(candidate)
        if type_header:
            type_kind = type_header.group(1)
            source_type = type_header.group(2)
            declared_type = source_type
            if (
                type_kind != "extension"
                and "." not in declared_type
                and active_types
            ):
                declared_type = f"{active_types[-1][0]}.{declared_type}"
            pending_type = declared_type
            inheritance = _CLASS_INHERITANCE_HEADER.search(candidate)
            if (
                type_kind == "class"
                and inheritance is not None
                and inheritance.group(1) == source_type
            ):
                parents[declared_type] = inheritance.group(2)

        for token in candidate:
            if token == "{":
                depth += 1
                if pending_type is not None:
                    active_types.append((pending_type, depth))
                    pending_type = None
            elif token == "}":
                if active_types and active_types[-1][1] == depth:
                    active_types.pop()
                depth = max(0, depth - 1)

    return parents


def _propagate_inherited_real_members(
    real_members: dict[str, set[str]], parents: dict[str, str]
) -> None:
    """Add known real-clock members from indexed base classes to subclasses."""
    known_types = set(real_members) | set(parents)
    resolved: dict[str, set[str]] = {}

    def members_for(type_name: str, visiting: set[str]) -> set[str]:
        if type_name in resolved:
            return resolved[type_name]
        if type_name in visiting:
            return set()
        visiting = set(visiting)
        visiting.add(type_name)
        members = set(real_members.get(type_name, set()))
        parent = parents.get(type_name)
        if parent is not None:
            candidates = [parent]
            if "." in type_name and "." not in parent:
                candidates.insert(
                    0, f"{type_name.rsplit('.', 1)[0]}.{parent}"
                )
            parent_type = next(
                (candidate for candidate in candidates if candidate in known_types),
                None,
            )
            if parent_type is not None:
                members.update(members_for(parent_type, visiting))
        resolved[type_name] = members
        return members

    for type_name in parents:
        inherited = members_for(type_name, set())
        if inherited:
            real_members.setdefault(type_name, set()).update(inherited)


def _explicit_clock_member_kind(
    masked_lines: list[str], type_name: str, member: str
) -> Optional[bool]:
    """Return a same-file type member's explicit clock kind, if declared."""
    depth = 0
    pending_type: Optional[str] = None
    active_types: list[tuple[str, int]] = []
    kinds: list[bool] = []

    for line_index, candidate in enumerate(masked_lines):
        type_header = _TYPE_SCOPE_HEADER.search(candidate)
        if type_header:
            type_kind = type_header.group(1)
            declared_type = type_header.group(2)
            if (
                type_kind != "extension"
                and "." not in declared_type
                and active_types
            ):
                declared_type = f"{active_types[-1][0]}.{declared_type}"
            pending_type = declared_type

        events: list[
            tuple[int, str, Optional[tuple[str, str]]]
        ] = []
        events.extend(
            (position, "binding", (name, declaration))
            for position, name, declaration in _local_declarations(candidate)
        )
        events.extend(
            (position, token, None)
            for position, token in enumerate(candidate)
            if token in "{}"
        )
        events.sort(key=lambda event: event[0])

        for _, event, binding in events:
            if event == "{":
                depth += 1
                if pending_type is not None:
                    active_types.append((pending_type, depth))
                    pending_type = None
            elif event == "}":
                if active_types and active_types[-1][1] == depth:
                    active_types.pop()
                depth = max(0, depth - 1)
            elif (
                binding is not None
                and active_types
                and active_types[-1][0] == type_name
                and depth == active_types[-1][1]
                and binding[0] == member
            ):
                kinds.append(
                    _receiver_declaration_kind(
                        binding[1], masked_lines[line_index + 1 :]
                    )
                )

    if not kinds:
        return None
    return all(kinds)


def _resolve_named_receiver_type(
    masked_lines: list[str],
    call_index: int,
    call_column: int,
    receiver: str,
) -> Optional[str]:
    """Resolve a local value's explicit Swift-like type by lexical scope."""
    current = masked_lines[call_index]
    prefix_lines = masked_lines[:call_index] + [current[:call_column]]
    scopes: list[dict[str, Optional[str]]] = [{}]
    pending_function = False
    pending_parameter_seen = False
    pending_parameter_type: Optional[str] = None
    pending_function_paren_depth = 0
    pending_function_saw_parameters = False
    pending_conditional: Optional[dict[str, Optional[str]]] = None

    for candidate_index, candidate in enumerate(prefix_lines):
        if _LOCAL_SCOPE_HEADER.search(candidate):
            pending_function = True
            pending_parameter_seen = bool(
                re.search(rf"\b{re.escape(receiver)}\s*:", candidate)
            )
            pending_parameter_type = _annotated_receiver_type(
                candidate, receiver
            )
            pending_function_paren_depth = 0
            pending_function_saw_parameters = False
        elif pending_function and not pending_parameter_seen:
            pending_parameter_seen = bool(
                re.search(rf"\b{re.escape(receiver)}\s*:", candidate)
            )
            pending_parameter_type = _annotated_receiver_type(
                candidate, receiver
            )
        if _CONDITIONAL_SCOPE_HEADER.search(candidate):
            pending_conditional = {}

        events: list[tuple[int, str, Optional[str]]] = []
        events.extend(
            (position, "binding", declaration)
            for position, declaration in _local_receiver_declarations(
                candidate, receiver
            )
        )
        events.extend(
            (position, "assignment", declaration)
            for position, declaration in _local_receiver_assignments(
                candidate, receiver
            )
        )
        events.extend(
            (position, token, None)
            for position, token in enumerate(candidate)
            if token in "{}()"
        )
        events.sort(key=lambda event: event[0])

        for position, event, declaration in events:
            if event == "(":
                if pending_function:
                    pending_function_paren_depth += 1
                    pending_function_saw_parameters = True
            elif event == ")":
                if pending_function and pending_function_paren_depth:
                    pending_function_paren_depth -= 1
            elif event == "{":
                scope = dict(pending_conditional or {})
                pending_conditional = None
                is_function_body = bool(
                    pending_function
                    and pending_function_saw_parameters
                    and pending_function_paren_depth == 0
                )
                if is_function_body:
                    if pending_parameter_seen:
                        scope[receiver] = pending_parameter_type
                    pending_function = False
                    pending_parameter_seen = False
                    pending_parameter_type = None
                    pending_function_paren_depth = 0
                    pending_function_saw_parameters = False
                else:
                    closure_header = _closure_header_text(
                        candidate[position + 1 :],
                        prefix_lines[candidate_index + 1 :],
                    )
                    closure_type = _annotated_receiver_type(
                        closure_header, receiver
                    )
                    if closure_type is not None:
                        scope[receiver] = closure_type
                    elif re.search(
                        rf"\b{re.escape(receiver)}\b", closure_header
                    ):
                        scope[receiver] = None
                scopes.append(scope)
            elif event == "}":
                if len(scopes) > 1:
                    scopes.pop()
            elif declaration is not None:
                declared_type = _receiver_declaration_type(
                    declaration, prefix_lines[candidate_index + 1 :]
                )
                if event == "assignment":
                    binding_scope = next(
                        (
                            scope_index
                            for scope_index in range(
                                len(scopes) - 1, -1, -1
                            )
                            if receiver in scopes[scope_index]
                        ),
                        None,
                    )
                    if binding_scope is not None:
                        if binding_scope == len(scopes) - 1:
                            scopes[binding_scope][receiver] = declared_type
                        else:
                            # The assignment may be conditional or deferred;
                            # expose it only while this nested scope is active.
                            scopes[-1][receiver] = declared_type
                elif pending_conditional is not None:
                    pending_conditional[receiver] = declared_type
                else:
                    scopes[-1][receiver] = declared_type

    for scope in reversed(scopes):
        if receiver in scope:
            return scope[receiver]
    return None


def _is_explicit_real_clock_member_chain(
    masked_lines: list[str],
    idx: int,
    external_real_members: Optional[dict[str, set[str]]] = None,
) -> bool:
    """Recognize `value.clock.sleep` when both value type and member are explicit."""
    current = masked_lines[idx]
    chain = _MEMBER_CHAIN_SLEEP_CALL.search(current)
    call_column: int
    if chain:
        receiver = chain.group(1)
        member = chain.group(2)
        call_column = chain.start()
    else:
        continuation = _CONTINUED_SLEEP_CALL.search(current)
        if not continuation:
            return False
        previous_index = next(
            (
                line_index
                for line_index in range(idx - 1, -1, -1)
                if masked_lines[line_index].strip()
            ),
            None,
        )
        if previous_index is None:
            return False
        previous = masked_lines[previous_index]
        chain = re.search(
            r"(?<![.\w])([A-Za-z_]\w*)[?!]?\s*\.\s*"
            r"([A-Za-z_]\w*)[?!]?\s*$",
            previous,
        )
        if not chain:
            return False
        receiver = chain.group(1)
        member = chain.group(2)
        call_column = chain.start()
        idx = previous_index

    receiver_type = _resolve_named_receiver_type(
        masked_lines, idx, call_column, receiver
    )
    if receiver_type is None:
        return False
    same_file_kind = _explicit_clock_member_kind(
        masked_lines, receiver_type, member
    )
    if same_file_kind is not None:
        return same_file_kind
    return bool(
        external_real_members is not None
        and member in external_real_members.get(receiver_type, set())
    )


def _resolve_named_receiver_kind(
    masked_lines: list[str],
    call_index: int,
    call_column: int,
    receiver: str,
    self_receiver: bool,
    external_real_members: Optional[dict[str, set[str]]] = None,
    resolving: Optional[set[tuple[int, int, str, bool]]] = None,
) -> bool:
    """Resolve a receiver's clock kind at a Swift-like lexical position."""
    resolution_key = (call_index, call_column, receiver, self_receiver)
    resolving = set(resolving or ())
    if resolution_key in resolving:
        return False
    resolving.add(resolution_key)

    current = masked_lines[call_index]
    prefix_lines = masked_lines[:call_index] + [current[:call_column]]
    tracks_reassignment = any(
        _local_receiver_assignments(line, receiver)
        for line in prefix_lines
    )
    scopes: list[dict[str, bool]] = [{}]
    scope_kinds = ["root"]
    scope_mutations: list[Optional[tuple[int, bool]]] = [None]
    scope_declared_real = [False]
    pending_function = False
    pending_parameter: Optional[bool] = None
    pending_function_paren_depth = 0
    pending_function_saw_parameters = False
    pending_conditional: Optional[dict[str, bool]] = None
    pending_conditional_declared_real = False
    pending_switch = False
    pending_switch_case: Optional[list[str]] = None
    compilation_frames: list[_CompilationScopeFrame] = []
    runtime_frames: list[_RuntimeScopeFrame] = []

    def pop_scope() -> None:
        if len(scopes) <= 1:
            return
        scopes.pop()
        scope_kind = scope_kinds.pop()
        mutation = scope_mutations.pop()
        scope_declared_real.pop()
        if mutation is None:
            return
        target, assigned_kind = mutation
        if target >= len(scopes):
            return
        prior_kind = scopes[target].get(receiver)
        propagated_kind = (
            assigned_kind
            if scope_kind in ("do", "runtime_branch")
            or prior_kind == assigned_kind
            else False
        )
        if target == len(scopes) - 1:
            scopes[target][receiver] = propagated_kind
            return
        scopes[-1][receiver] = propagated_kind
        scope_mutations[-1] = (target, propagated_kind)

    for candidate_index, candidate in enumerate(prefix_lines):
        compilation_directive = _COMPILATION_DIRECTIVE.match(candidate)
        if compilation_directive:
            directive = compilation_directive.group(1)
            if directive == "if":
                compilation_frames.append(
                    _CompilationScopeFrame(
                        base_scopes=_copy_scope_stack(scopes),
                        base_scope_kinds=list(scope_kinds),
                        base_scope_mutations=list(scope_mutations),
                        base_scope_declared_real=list(scope_declared_real),
                        branch_scopes=[],
                        branch_scope_mutations=[],
                        branch_scope_declared_real=[],
                    )
                )
            elif directive in ("elseif", "else") and compilation_frames:
                frame = compilation_frames[-1]
                frame.branch_scopes.append(_copy_scope_stack(scopes))
                frame.branch_scope_mutations.append(
                    list(scope_mutations)
                )
                frame.branch_scope_declared_real.append(
                    list(scope_declared_real)
                )
                frame.has_else = frame.has_else or directive == "else"
                scopes = _copy_scope_stack(frame.base_scopes)
                scope_kinds = list(frame.base_scope_kinds)
                scope_mutations = list(frame.base_scope_mutations)
                scope_declared_real = list(frame.base_scope_declared_real)
            elif directive == "endif" and compilation_frames:
                frame = compilation_frames.pop()
                frame.branch_scopes.append(_copy_scope_stack(scopes))
                frame.branch_scope_mutations.append(
                    list(scope_mutations)
                )
                frame.branch_scope_declared_real.append(
                    list(scope_declared_real)
                )
                scopes = _merge_compilation_branches(frame, receiver)
                scope_kinds = list(frame.base_scope_kinds)
                scope_mutations = _merge_compilation_mutations(frame)
                scope_declared_real = _merge_compilation_declared_real(frame)
            continue

        switch_case_header = bool(_SWITCH_CASE_HEADER.match(candidate))
        if pending_switch_case is not None and not switch_case_header:
            pending_switch_case.append(candidate)
            case_receiver_kind = _switch_case_receiver_kind(
                " ".join(pending_switch_case), receiver
            )
            if (
                case_receiver_kind is not None
                and scope_kinds[-1] == "case"
            ):
                scopes[-1][receiver] = case_receiver_kind
                scope_declared_real[-1] = case_receiver_kind
            if candidate.rstrip().endswith(":"):
                pending_switch_case = None

        if switch_case_header:
            if len(scopes) > 1 and scope_kinds[-1] == "case":
                pop_scope()
            if scope_kinds[-1] == "switch":
                case_scope: dict[str, bool] = {}
                case_receiver_kind = _switch_case_receiver_kind(
                    candidate, receiver
                )
                if case_receiver_kind is not None:
                    case_scope[receiver] = case_receiver_kind
                scopes.append(case_scope)
                scope_kinds.append("case")
                scope_mutations.append(None)
                scope_declared_real.append(case_receiver_kind is True)
                pending_switch_case = (
                    None
                    if candidate.rstrip().endswith(":")
                    else [candidate]
                )

        runtime_else = tracks_reassignment and bool(
            _RUNTIME_ELSE_SCOPE_HEADER.match(candidate)
        )
        runtime_else_if = tracks_reassignment and bool(
            _RUNTIME_ELSE_IF_SCOPE_HEADER.match(candidate)
        )
        pending_runtime_branch = False
        if runtime_else and runtime_frames:
            pending_runtime_branch = True
            if not runtime_else_if:
                runtime_frames[-1].has_else = True
        elif tracks_reassignment and _RUNTIME_IF_SCOPE_HEADER.match(candidate):
            runtime_frames.append(
                _RuntimeScopeFrame(
                    base_scopes=_copy_scope_stack(scopes),
                    base_scope_mutations=list(scope_mutations),
                    base_scope_declared_real=list(scope_declared_real),
                    branch_scopes=[],
                    branch_scope_mutations=[],
                    branch_scope_declared_real=[],
                )
            )
            pending_runtime_branch = True

        if _LOCAL_SCOPE_HEADER.search(candidate):
            pending_function = True
            pending_parameter = _annotated_receiver_kind(candidate, receiver)
            pending_function_paren_depth = 0
            pending_function_saw_parameters = False
        elif pending_function and pending_parameter is None:
            pending_parameter = _annotated_receiver_kind(candidate, receiver)
        if _CONDITIONAL_SCOPE_HEADER.search(candidate):
            pending_conditional = {}
            pending_conditional_declared_real = False
            for_binding = _FOR_SCOPE_BINDING.search(candidate)
            if for_binding and for_binding.group(1) == receiver:
                pending_conditional[receiver] = False
        elif runtime_else:
            pending_conditional = {}
            pending_conditional_declared_real = False
        if _SWITCH_SCOPE_HEADER.search(candidate):
            pending_switch = True

        events: list[tuple[int, str, Optional[str]]] = []
        events.extend(
            (position, "binding", declaration)
            for position, declaration in _local_receiver_declarations(
                candidate, receiver
            )
        )
        events.extend(
            (position, "assignment", declaration)
            for position, declaration in _local_receiver_assignments(
                candidate, receiver
            )
        )
        events.extend(
            (pos, token, None)
            for pos, token in enumerate(candidate)
            if token in "{}()"
        )
        events.sort(key=lambda event: event[0])

        for pos, event, declaration in events:
            if event == "(":
                if pending_function:
                    pending_function_paren_depth += 1
                    pending_function_saw_parameters = True
            elif event == ")":
                if pending_function and pending_function_paren_depth:
                    pending_function_paren_depth -= 1
            elif event == "{":
                is_conditional_body = pending_conditional is not None
                is_switch_body = pending_switch
                scope = dict(pending_conditional or {})
                declared_real = (
                    pending_conditional_declared_real
                    if is_conditional_body
                    else False
                )
                pending_conditional = None
                pending_conditional_declared_real = False
                is_function_body = bool(
                    pending_function
                    and pending_function_saw_parameters
                    and pending_function_paren_depth == 0
                )
                if is_function_body:
                    scope_kind = "function"
                elif is_switch_body:
                    scope_kind = "switch"
                elif pending_runtime_branch:
                    scope_kind = "runtime_branch"
                elif is_conditional_body:
                    scope_kind = "conditional"
                elif _DO_SCOPE_HEADER.search(candidate[:pos]):
                    scope_kind = "do"
                else:
                    scope_kind = "block"
                if is_function_body:
                    if pending_parameter is not None:
                        scope[receiver] = pending_parameter
                        declared_real = pending_parameter
                    pending_function = False
                    pending_parameter = None
                    pending_function_paren_depth = 0
                    pending_function_saw_parameters = False
                if is_switch_body:
                    pending_switch = False
                closure_kind = None
                if not (
                    is_function_body
                    or is_conditional_body
                    or is_switch_body
                ):
                    closure_header = _closure_header_text(
                        candidate[pos + 1 :],
                        prefix_lines[candidate_index + 1 :],
                    )
                    capture_alias = _closure_receiver_alias(
                        closure_header, receiver
                    )
                    if capture_alias is not None:
                        alias_receiver, alias_is_self = capture_alias
                        closure_kind = _resolve_named_receiver_kind(
                            masked_lines,
                            candidate_index,
                            pos,
                            alias_receiver,
                            alias_is_self,
                            external_real_members,
                            resolving,
                        )
                    else:
                        closure_kind = _closure_receiver_kind(
                            closure_header, receiver
                        )
                if closure_kind is not None:
                    scope[receiver] = closure_kind
                    declared_real = bool(
                        _annotated_receiver_kind(closure_header, receiver)
                    )
                scopes.append(scope)
                scope_kinds.append(scope_kind)
                scope_mutations.append(None)
                scope_declared_real.append(declared_real)
                if pending_runtime_branch:
                    pending_runtime_branch = False
            elif event == "}":
                if len(scopes) > 1 and scope_kinds[-1] == "case":
                    pop_scope()
                if len(scopes) > 1:
                    closing_kind = scope_kinds[-1]
                    pop_scope()
                    if closing_kind == "runtime_branch" and runtime_frames:
                        frame = runtime_frames[-1]
                        frame.branch_scopes.append(
                            _copy_scope_stack(scopes)
                        )
                        frame.branch_scope_mutations.append(
                            list(scope_mutations)
                        )
                        frame.branch_scope_declared_real.append(
                            list(scope_declared_real)
                        )
                        if runtime_else:
                            scopes = _copy_scope_stack(frame.base_scopes)
                            scope_mutations = list(
                                frame.base_scope_mutations
                            )
                            scope_declared_real = list(
                                frame.base_scope_declared_real
                            )
                            runtime_else = False
                        else:
                            runtime_frames.pop()
                            scopes = _merge_runtime_branches(frame, receiver)
                            scope_mutations = _merge_runtime_mutations(frame)
                            scope_declared_real = (
                                _merge_runtime_declared_real(frame)
                            )
            elif declaration is not None:
                has_explicit_real_type = bool(
                    _REAL_CLOCK_TYPE.search(declaration)
                )
                if _receiver_declaration_inherits_kind(declaration, receiver):
                    inherited_kind = _nearest_receiver_kind(scopes, receiver)
                    kind = (
                        inherited_kind
                        if inherited_kind is not None
                        else False
                    )
                else:
                    alias = _receiver_declaration_alias(declaration)
                    if alias is not None:
                        alias_receiver, alias_is_self = alias
                        kind = _resolve_named_receiver_kind(
                            masked_lines,
                            candidate_index,
                            pos,
                            alias_receiver,
                            alias_is_self,
                            external_real_members,
                            resolving,
                        )
                    else:
                        kind = _receiver_declaration_kind(
                            declaration, prefix_lines[candidate_index + 1 :]
                        )
                if event == "assignment":
                    current_mutation = scope_mutations[-1]
                    binding_scope = (
                        current_mutation[0]
                        if current_mutation is not None
                        else next(
                            (
                                scope_index
                                for scope_index in range(
                                    len(scopes) - 1, -1, -1
                                )
                                if receiver in scopes[scope_index]
                            ),
                            None,
                        )
                    )
                    if binding_scope is None:
                        continue
                    if scope_declared_real[binding_scope]:
                        kind = True
                    if binding_scope == len(scopes) - 1:
                        scopes[binding_scope][receiver] = kind
                    else:
                        scopes[-1][receiver] = kind
                        scope_mutations[-1] = (binding_scope, kind)
                elif pending_conditional is not None:
                    pending_conditional[receiver] = kind
                    pending_conditional_declared_real = (
                        has_explicit_real_type
                    )
                else:
                    scopes[-1][receiver] = kind
                    scope_declared_real[-1] = has_explicit_real_type

    search_end = len(scopes)
    if self_receiver:
        search_end = next(
            (
                scope_index
                for scope_index, kind in enumerate(scope_kinds)
                if kind == "function"
            ),
            search_end,
        )
    for scope_index in range(search_end - 1, -1, -1):
        if receiver in scopes[scope_index]:
            return scopes[scope_index][receiver]
    return _has_explicit_real_member(
        masked_lines,
        call_index,
        call_column,
        receiver,
        external_real_members,
    )


def _is_named_real_clock_sleep(
    masked_lines: list[str],
    idx: int,
    external_real_members: Optional[dict[str, set[str]]] = None,
) -> bool:
    """Resolve a named receiver through Swift-like lexical brace scopes."""
    if _is_explicit_real_clock_member_chain(
        masked_lines, idx, external_real_members
    ):
        return True
    current = masked_lines[idx]
    sleep_match = _NAMED_SLEEP_CALL.search(current)
    sleep_start: int
    if sleep_match:
        self_receiver = sleep_match.group(1) is not None
        if (
            not self_receiver
            and current[: sleep_match.start()].rstrip().endswith(".")
        ):
            return False
        receiver = sleep_match.group(2)
        sleep_start = sleep_match.start()
    else:
        continuation = _CONTINUED_SLEEP_CALL.search(current)
        if not continuation:
            return False
        previous = next(
            (
                masked_lines[j].rstrip()
                for j in range(idx - 1, -1, -1)
                if masked_lines[j].strip()
            ),
            "",
        )
        if re.search(
            r"\b(?:ContinuousClock|SuspendingClock)\s*"
            r"(?:\.\s*init)?\s*\(\s*\)\s*$",
            previous,
        ) or re.search(r"\bTask(?:\s*<[^>\n]+>)?\s*$", previous):
            return True
        receiver_match = re.search(r"\b([A-Za-z_]\w*)[?!]?\s*$", previous)
        if not receiver_match:
            return False
        receiver_prefix = previous[: receiver_match.start()].rstrip()
        self_receiver = bool(
            re.search(
                r"\b(?:self|Self)\s*[?!]?\s*\.\s*$",
                receiver_prefix,
            )
        )
        if receiver_prefix.endswith(".") and not self_receiver:
            return False
        receiver = receiver_match.group(1)
        sleep_start = continuation.start()

    return _resolve_named_receiver_kind(
        masked_lines,
        idx,
        sleep_start,
        receiver,
        self_receiver,
        external_real_members,
    )


def _python_function_parameter_names(signature: str) -> set[str]:
    """Extract parameter bindings while respecting nested default expressions."""
    open_paren = signature.find("(")
    if open_paren < 0:
        return set()

    depth = 0
    start = open_paren + 1
    chunks: list[str] = []
    for index in range(open_paren, len(signature)):
        token = signature[index]
        if token == "(":
            depth += 1
        elif token == ")":
            depth -= 1
            if depth == 0:
                chunks.append(signature[start:index])
                break
        elif token == "," and depth == 1:
            chunks.append(signature[start:index])
            start = index + 1

    names: set[str] = set()
    for chunk in chunks:
        parameter = chunk.strip().lstrip("*").strip()
        if not parameter or parameter == "/":
            continue
        binding = re.match(r"([A-Za-z_]\w*)\b", parameter)
        if binding:
            names.add(binding.group(1))
    return names


@dataclass
class _PythonAliasScope:
    header_indent: int
    prior_values: dict[str, bool]
    kind: str
    resume_values: Optional[dict[str, bool]] = None


def _python_standard_sleep_lines(masked_lines: list[str]) -> set[int]:
    """Resolve standard Python sleep modules once with lexical namespaces."""
    active = set(_PYTHON_SLEEP_MODULES)
    scopes = [_PythonAliasScope(-1, {}, "root")]
    pending_scope_header: Optional[
        tuple[str, int, list[str], int]
    ] = None
    continuation_depth = 0
    backslash_continuation = False
    sleep_lines: set[int] = set()

    def set_alias(name: str, is_active: bool) -> None:
        prior_values = scopes[-1].prior_values
        prior_values.setdefault(name, name in active)
        if is_active:
            active.add(name)
        else:
            active.discard(name)

    def apply_values(values: dict[str, bool]) -> None:
        for name, is_active in values.items():
            if is_active:
                active.add(name)
            else:
                active.discard(name)

    def enter_scope(header_indent: int, kind: str) -> None:
        resume_values = None
        if scopes[-1].kind == "class":
            resume_values = {
                name: name in active for name in scopes[-1].prior_values
            }
            apply_values(scopes[-1].prior_values)
        scopes.append(
            _PythonAliasScope(
                header_indent,
                {},
                kind,
                resume_values,
            )
        )

    def pop_scope() -> None:
        frame = scopes.pop()
        prior_values = frame.prior_values
        for name, was_active in prior_values.items():
            if was_active:
                active.add(name)
            else:
                active.discard(name)
        if frame.resume_values is not None:
            apply_values(frame.resume_values)

    def update_continuation(line: str) -> None:
        nonlocal continuation_depth, backslash_continuation
        continuation_depth = max(
            0,
            continuation_depth
            + sum(line.count(opening) for opening in "([{")
            - sum(line.count(closing) for closing in ")]}")
        )
        backslash_continuation = line.rstrip().endswith("\\")

    for line_index, line in enumerate(masked_lines):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())

        if pending_scope_header is not None:
            kind, header_indent, signature_lines, paren_depth = (
                pending_scope_header
            )
            signature_lines.append(line)
            paren_depth += line.count("(") - line.count(")")
            if paren_depth > 0:
                pending_scope_header = (
                    kind,
                    header_indent,
                    signature_lines,
                    paren_depth,
                )
                continue
            enter_scope(header_indent, kind)
            if kind == "function":
                for name in _python_function_parameter_names(
                    " ".join(signature_lines)
                ):
                    set_alias(name, False)
            pending_scope_header = None
            continue

        is_continuation = continuation_depth > 0 or backslash_continuation
        if stripped and not is_continuation:
            while (
                len(scopes) > 1
                and indent <= scopes[-1].header_indent
            ):
                pop_scope()

        function_header = _PYTHON_FUNCTION_HEADER.match(line)
        if function_header:
            set_alias(function_header.group(1), False)
            paren_depth = line.count("(") - line.count(")")
            signature_lines = [line]
            if paren_depth > 0:
                pending_scope_header = (
                    "function",
                    indent,
                    signature_lines,
                    paren_depth,
                )
            else:
                enter_scope(indent, "function")
                for name in _python_function_parameter_names(line):
                    set_alias(name, False)
            continue

        class_header = _PYTHON_CLASS_HEADER.match(line)
        if class_header:
            set_alias(class_header.group(1), False)
            paren_depth = line.count("(") - line.count(")")
            signature_lines = [line]
            if paren_depth > 0:
                pending_scope_header = (
                    "class",
                    indent,
                    signature_lines,
                    paren_depth,
                )
            else:
                enter_scope(indent, "class")
            continue

        import_line = re.match(r"^\s*import\s+(.+)$", line)
        if import_line:
            for import_spec in import_line.group(1).split(","):
                direct = re.fullmatch(
                    r"\s*([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*",
                    import_spec,
                )
                if direct:
                    bound_name = direct.group(1).split(".", 1)[0]
                    if bound_name in _PYTHON_SLEEP_MODULES:
                        set_alias(bound_name, True)
                    else:
                        set_alias(bound_name, False)
                alias = re.fullmatch(
                    r"\s*([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)"
                    r"\s+as\s+([A-Za-z_]\w*)\s*",
                    import_spec,
                )
                if alias:
                    if alias.group(1) in _PYTHON_SLEEP_MODULES:
                        set_alias(alias.group(2), True)
                    else:
                        set_alias(alias.group(2), False)
            update_continuation(line)
            continue
        from_import = re.match(
            r"^\s*from\s+\S+\s+import\s+(.+)$", line
        )
        if from_import:
            for import_spec in from_import.group(1).split(","):
                binding = re.fullmatch(
                    r"\s*([A-Za-z_]\w*)"
                    r"(?:\s+as\s+([A-Za-z_]\w*))?\s*",
                    import_spec,
                )
                if binding:
                    set_alias(binding.group(2) or binding.group(1), False)
            update_continuation(line)
            continue

        rebound_names = {
            match.group(1)
            for pattern in (
                _PYTHON_ASSIGNMENT_TARGET,
                _PYTHON_CHAINED_ASSIGNMENT_TARGET,
                _PYTHON_DEFINITION_TARGET,
                _PYTHON_FOR_TARGET,
                _PYTHON_AS_TARGET,
                _PYTHON_DEL_TARGET,
            )
            for match in pattern.finditer(line)
        }
        for name in rebound_names:
            set_alias(name, False)

        if any(
            call.group(1) in active
            for call in _PYTHON_MODULE_SLEEP_CALL.finditer(line)
        ):
            sleep_lines.add(line_index)
        update_continuation(line)
    return sleep_lines


def detect_sleep_then_assert(
    lines: list[str],
    masked_lines: list[str],
    idx: int,
    path_suffix: str,
    external_real_members: Optional[dict[str, set[str]]] = None,
    python_standard_sleep: bool = False,
) -> bool:
    """Sleep on lines[idx] followed by an assertion within 3 non-blank lines."""
    line = masked_lines[idx]
    has_sleep_token = "sleep" in line or "setTimeout" in line
    is_sleep = has_sleep_token and (
        bool(_SLEEP_CALL.search(line))
        or _is_named_real_clock_sleep(
            masked_lines, idx, external_real_members
        )
    )
    if not is_sleep and path_suffix == ".py":
        is_sleep = python_standard_sleep
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


def scan_text(
    rel_posix: str,
    text: str,
    external_real_members: Optional[dict[str, set[str]]] = None,
) -> list[Finding]:
    suffix = pathlib.PurePosixPath(rel_posix).suffix
    raw_lines = text.splitlines()
    code_lines = [_strip_comment(line, suffix) for line in raw_lines]
    needs_sleep_mask = "sleep" in text or "setTimeout" in text
    masked_lines = (
        [_strip_comment(line, suffix) for line in _mask_noncode(raw_lines, suffix)]
        if needs_sleep_mask
        else code_lines
    )
    python_standard_sleep_lines = (
        _python_standard_sleep_lines(masked_lines)
        if suffix == ".py" and needs_sleep_mask
        else set()
    )
    findings: list[Finding] = []

    for i, code in enumerate(code_lines):
        if not code.strip():
            continue
        line_no = i + 1
        snippet = raw_lines[i].strip()

        if detect_assert_on_duration(code):
            findings.append(Finding(rel_posix, line_no, RULE_ASSERT_ON_DURATION, snippet))
        if detect_live_network_host(code):
            findings.append(Finding(rel_posix, line_no, RULE_LIVE_NETWORK_HOST, snippet))
        if detect_fixed_port_bind(code):
            findings.append(Finding(rel_posix, line_no, RULE_FIXED_PORT_BIND, snippet))
        if detect_sleep_then_assert(
            code_lines,
            masked_lines,
            i,
            suffix,
            external_real_members,
            i in python_standard_sleep_lines,
        ):
            findings.append(Finding(rel_posix, line_no, RULE_SLEEP_THEN_ASSERT, snippet))

    return findings


def _swift_test_bundle_key(rel_posix: str) -> str:
    """Return the source boundary that shares Swift test-target type members."""
    parts = pathlib.PurePosixPath(rel_posix).parts
    if not parts:
        return "."
    if parts[0] in ("cmuxTests", "cmuxUITests"):
        return parts[0]
    if len(parts) > 1 and parts[:2] == ("ios", "cmuxUITests"):
        return "ios/cmuxUITests"
    if "Tests" in parts:
        tests_index = parts.index("Tests")
        bundle_end = tests_index + 1
        if bundle_end < len(parts) - 1:
            bundle_end += 1
        return "/".join(parts[:bundle_end])
    return pathlib.PurePosixPath(rel_posix).parent.as_posix()


def scan_sources(sources: Iterable[tuple[str, str]]) -> list[Finding]:
    """Scan sources while sharing Swift members within each test target."""
    source_list = list(sources)
    bundle_members: dict[str, dict[str, set[str]]] = {}

    for rel_posix, text in source_list:
        suffix = pathlib.PurePosixPath(rel_posix).suffix
        if suffix != ".swift" or not (
            "ContinuousClock" in text or "SuspendingClock" in text
        ):
            continue
        raw_lines = text.splitlines()
        masked_lines = [
            _strip_comment(line, suffix)
            for line in _mask_noncode(raw_lines, suffix)
        ]
        bundle = _swift_test_bundle_key(rel_posix)
        index = bundle_members.setdefault(bundle, {})
        for type_name, member_names in _explicit_real_clock_members(
            masked_lines
        ).items():
            index.setdefault(type_name, set()).update(member_names)

    bundle_parents: dict[str, dict[str, str]] = {}
    for rel_posix, text in source_list:
        if pathlib.PurePosixPath(rel_posix).suffix != ".swift":
            continue
        bundle = _swift_test_bundle_key(rel_posix)
        if bundle not in bundle_members or not _CLASS_INHERITANCE_HEADER.search(
            text
        ):
            continue
        masked_lines = _mask_noncode(text.splitlines(), ".swift")
        bundle_parents.setdefault(bundle, {}).update(
            _explicit_type_parents(masked_lines)
        )

    for bundle, parents in bundle_parents.items():
        _propagate_inherited_real_members(
            bundle_members.setdefault(bundle, {}), parents
        )

    findings: list[Finding] = []
    for rel_posix, text in source_list:
        suffix = pathlib.PurePosixPath(rel_posix).suffix
        external_real_members = None
        if suffix == ".swift":
            bundle = _swift_test_bundle_key(rel_posix)
            external_real_members = bundle_members.get(bundle)
        findings.extend(scan_text(rel_posix, text, external_real_members))
    return findings


def collect_findings(repo_root: pathlib.Path, roots: Iterable[str]) -> list[Finding]:
    source_paths: list[tuple[pathlib.Path, str]] = []
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
            source_paths.append((path, rel_posix))

    bundle_members: dict[str, dict[str, set[str]]] = {}
    for path, rel_posix in source_paths:
        suffix = pathlib.PurePosixPath(rel_posix).suffix
        if suffix != ".swift":
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if not ("ContinuousClock" in text or "SuspendingClock" in text):
            continue
        masked_lines = [
            _strip_comment(line, suffix)
            for line in _mask_noncode(text.splitlines(), suffix)
        ]
        bundle = _swift_test_bundle_key(rel_posix)
        index = bundle_members.setdefault(bundle, {})
        for type_name, member_names in _explicit_real_clock_members(
            masked_lines
        ).items():
            index.setdefault(type_name, set()).update(member_names)

    bundle_parents: dict[str, dict[str, str]] = {}
    for path, rel_posix in source_paths:
        if pathlib.PurePosixPath(rel_posix).suffix != ".swift":
            continue
        bundle = _swift_test_bundle_key(rel_posix)
        if bundle not in bundle_members:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if not _CLASS_INHERITANCE_HEADER.search(text):
            continue
        masked_lines = _mask_noncode(text.splitlines(), ".swift")
        bundle_parents.setdefault(bundle, {}).update(
            _explicit_type_parents(masked_lines)
        )

    for bundle, parents in bundle_parents.items():
        _propagate_inherited_real_members(
            bundle_members.setdefault(bundle, {}), parents
        )

    findings: list[Finding] = []
    for path, rel_posix in source_paths:
        suffix = pathlib.PurePosixPath(rel_posix).suffix
        external_real_members = None
        if suffix == ".swift":
            bundle = _swift_test_bundle_key(rel_posix)
            external_real_members = bundle_members.get(bundle)
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        findings.extend(scan_text(rel_posix, text, external_real_members))
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
            "tests/free_sleep.py",
            "sleep(0.3)\nassert widget.is_rendered()\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/QualifiedClockTests.swift",
            "try await ContinuousClock().sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ExplicitInitQualifiedClockTests.swift",
            "try await ContinuousClock.init().sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/NamedClockTests.swift",
            "let clock = ContinuousClock()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/CastRealClockTests.swift",
            "let clock = makeClock() as ContinuousClock\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ParenthesizedCastRealClockTests.swift",
            "let clock = (makeClock() as Swift.SuspendingClock)\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/CastCaptureRealClockTests.swift",
            "let work = { [clock = makeClock() as ContinuousClock] in\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ExplicitInitNamedClockTests.swift",
            "let clock = Swift.SuspendingClock.init()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/TupleBoundRealClockTests.swift",
            "let (_, clock) = (fixture, ContinuousClock())\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ReassignedRealClockTests.swift",
            "var clock: any Clock<Duration> = TestRelayClock()\n"
            "clock = ContinuousClock()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/DoReassignedRealClockTests.swift",
            "var clock: any Clock<Duration> = TestRelayClock()\n"
            "do {\n"
            "    clock = ContinuousClock()\n"
            "}\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ConditionalBranchReassignedRealClockTests.swift",
            "var clock: any Clock<Duration> = TestRelayClock()\n"
            "if shouldWait {\n"
            "    clock = ContinuousClock()\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ConditionalSameKindReassignedRealClockTests.swift",
            "var clock: any Clock<Duration> = ContinuousClock()\n"
            "if shouldReset {\n"
            "    clock = ContinuousClock()\n"
            "}\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/TypedOpaqueReassignedRealClockTests.swift",
            "var clock: ContinuousClock = .init()\n"
            "clock = makeClock()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/TypedDeferredRealClockTests.swift",
            "let clock: ContinuousClock\n"
            "clock = .init()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ExhaustiveReassignedRealClockTests.swift",
            "var clock: any Clock<Duration> = TestRelayClock()\n"
            "if usePrimary {\n"
            "    clock = ContinuousClock()\n"
            "} else {\n"
            "    clock = ContinuousClock()\n"
            "}\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/MultilineNamedClockTests.swift",
            "let clock =\n"
            "    ContinuousClock()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/InjectedRealClockTests.swift",
            "func verify(clock: ContinuousClock) async {\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/DefaultedExistentialRealClockTests.swift",
            "func verify(\n"
            "    clock: any Clock<Duration> = ContinuousClock()\n"
            ") async {\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ClosureDefaultRealClockParameterTests.swift",
            "func verify(\n"
            "    clock: ContinuousClock,\n"
            "    callback: () -> Void = {}\n"
            ") async {\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/MultilineClosureRealClockParameterTests.swift",
            "let work = {\n"
            "    (clock: ContinuousClock) in\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/CaptureListClosureRealClockParameterTests.swift",
            "let work = { [weak self] (clock: ContinuousClock) in\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/AssignedCaptureRealClockTests.swift",
            "let work = { [clock = ContinuousClock()] in\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/AliasedCaptureRealClockTests.swift",
            "let realClock = ContinuousClock()\n"
            "let work = { [clock = realClock] in\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/SwitchCaseRealClockTests.swift",
            "func verify(clock: TestRelayClock) async {\n"
            "    switch mode {\n"
            "    case .real:\n"
            "        let clock = ContinuousClock()\n"
            "        try await clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    case .virtual:\n"
            "        break\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/TypedSwitchPatternRealClockTests.swift",
            "func verify(clock: TestRelayClock) async {\n"
            "    switch state {\n"
            "    case let .ready(clock as ContinuousClock):\n"
            "        try await clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/MultilineTypedSwitchPatternRealClockTests.swift",
            "func verify(clock: TestRelayClock) async {\n"
            "    switch state {\n"
            "    case let .ready(\n"
            "        clock as ContinuousClock\n"
            "    ):\n"
            "        try await clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/LabeledSwitchPatternOuterClockTests.swift",
            "func verify() async {\n"
            "    let clock = ContinuousClock()\n"
            "    switch state {\n"
            "    case let .ready(clock: value):\n"
            "        consume(value)\n"
            "        try await clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/URLBlockCommentBeforeRealClockTests.swift",
            "/* See https://example.test for the fixture contract. */\n"
            "let clock = ContinuousClock()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/TripleQuoteLineCommentBeforeRealSleepTests.swift",
            "// Syntax example only: \"\"\"\n"
            "Thread.sleep(forTimeInterval: 0.3)\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/DarwinSleepTests.swift",
            "Darwin.sleep(1)\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/GlibcSleepTests.swift",
            "Glibc.sleep(1)\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "web/tests/BunSleepTests.ts",
            "await Bun.sleep(300)\n"
            "expect(widget.isRendered).toBe(true)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/trio_sleep.py",
            "await trio.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/anyio_sleep.py",
            "await anyio.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/gevent_sleep.py",
            "gevent.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/aliased_time_sleep.py",
            "import time as clock_time\n"
            "clock_time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/restored_aliased_time_sleep.py",
            "import time as clock_time\n"
            "def pace():\n"
            "    clock_time = TestClock()\n"
            "    clock_time.sleep(0.3)\n"
            "clock_time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/restored_alias_after_outdented_continuation.py",
            "import time as clock_time\n"
            "def pace():\n"
            "    values = (\n"
            "        1,\n"
            ")\n"
            "    clock_time = TestClock(values)\n"
            "    clock_time.sleep(0.3)\n"
            "clock_time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/aliased_asyncio_sleep.py",
            "import asyncio as aio\n"
            "await aio.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/asyncio_submodule_sleep.py",
            "import asyncio.subprocess\n"
            "await asyncio.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/import_then_sleep.py",
            "import time; time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/keyword_argument_before_sleep.py",
            "import time\n"
            "configure(time=fake_clock)\n"
            "time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/class_scope_before_sleep.py",
            "import time\n"
            "class Fixture:\n"
            "    time = TestClock()\n"
            "time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/multiline_class_scope_before_sleep.py",
            "import time\n"
            "class Fixture(\n"
            "    BaseFixture,\n"
            "):\n"
            "    time = TestClock()\n"
            "time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/class_member_not_method_scope.py",
            "import time\n"
            "class Fixture:\n"
            "    time = TestClock()\n"
            "    def verify(self):\n"
            "        time.sleep(0.3)\n"
            "        assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/multiple_sleep_calls.py",
            "fake.sleep(); time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/aliased_trio_sleep.py",
            "import trio as trio_runtime\n"
            "await trio_runtime.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/aliased_anyio_sleep.py",
            "import anyio as anyio_runtime\n"
            "await anyio_runtime.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/aliased_gevent_sleep.py",
            "import gevent as gevent_runtime\n"
            "gevent_runtime.sleep(0.3)\n"
            "assert widget.is_rendered\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/QualifiedRealClockInitializerTests.swift",
            "let clock = Swift.ContinuousClock()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/QualifiedRealClockParameterTests.swift",
            "func verify(clock: Swift.SuspendingClock) async {\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/SelfRealClockPropertyTests.swift",
            "struct Fixture {\n"
            "    let clock: ContinuousClock\n"
            "    func verify() async {\n"
            "        try await self.clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/OptionalSelfRealClockPropertyTests.swift",
            "final class Fixture {\n"
            "    let clock: ContinuousClock\n"
            "    func verify() {\n"
            "        let work = { [weak self] in\n"
            "            try await self?.clock.sleep(for: .milliseconds(300))\n"
            "            #expect(widget.isRendered)\n"
            "        }\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ForcedSelfRealClockPropertyTests.swift",
            "final class Fixture {\n"
            "    let clock: ContinuousClock\n"
            "    func verify() {\n"
            "        let work = { [weak self] in\n"
            "            try await self!.clock.sleep(for: .milliseconds(300))\n"
            "            #expect(widget.isRendered)\n"
            "        }\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/StaticSelfRealClockPropertyTests.swift",
            "struct Fixture {\n"
            "    static let clock = ContinuousClock()\n"
            "    static func verify() async {\n"
            "        try await Self.clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/LaterSelfRealClockPropertyTests.swift",
            "struct Fixture {\n"
            "    func verify() async {\n"
            "        try await self.clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "    let clock: ContinuousClock\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/LaterBareRealClockPropertyTests.swift",
            "struct Fixture {\n"
            "    func verify() async {\n"
            "        try await clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "    let clock = ContinuousClock()\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ExtensionRealClockPropertyTests.swift",
            "struct Fixture {\n"
            "    func verify() async {\n"
            "        try await self.clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n"
            "extension Fixture {\n"
            "    var clock: ContinuousClock { ContinuousClock() }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/WrappedSelfRealClockPropertyTests.swift",
            "struct Fixture {\n"
            "    let clock: ContinuousClock\n"
            "    func verify() async {\n"
            "        try await self.clock\n"
            "            .sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/TypedRealClockMemberChainTests.swift",
            "struct Fixture {\n"
            "    let clock: ContinuousClock\n"
            "}\n"
            "let fixture: Fixture = Fixture(clock: ContinuousClock())\n"
            "try await fixture.clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/InjectedRealClockMemberChainTests.swift",
            "struct Fixture {\n"
            "    let clock: ContinuousClock\n"
            "}\n"
            "func verify(fixture: Fixture) async {\n"
            "    try await fixture.clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/SecondRealClockBindingTests.swift",
            "let fakeClock = TestRelayClock(), clock = ContinuousClock()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ComparisonBeforeRealClockBindingTests.swift",
            "let isReady = count < limit, clock = ContinuousClock()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/GenericBeforeRealClockBindingTests.swift",
            "let values = Result<Int, String>.success(1), clock = ContinuousClock()\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/CapturedRealClockTests.swift",
            "func verify() async {\n"
            "    let clock = ContinuousClock()\n"
            "    let work = {\n"
            "        try await clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/RealClockAfterNestedBlockTests.swift",
            "func verify() async {\n"
            "    let clock = ContinuousClock()\n"
            "    if shouldPrepare {\n"
            "        prepare()\n"
            "    }\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/RealClockAfterConditionalShadowTests.swift",
            "func verify(clock: ContinuousClock, candidate: TestRelayClock?) async {\n"
            "    if let clock = candidate {\n"
            "        consume(clock)\n"
            "    }\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ShorthandOptionalRealClockTests.swift",
            "let clock: ContinuousClock? = ContinuousClock()\n"
            "if let clock {\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ExplicitOptionalRealClockTests.swift",
            "func verify(clock: ContinuousClock?) async {\n"
            "    if let clock = clock {\n"
            "        try await clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ShorthandGuardRealClockTests.swift",
            "func verify(clock: ContinuousClock?) async {\n"
            "    guard let clock else { return }\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/SelfOptionalRealClockTests.swift",
            "struct Fixture {\n"
            "    let clock: ContinuousClock?\n"
            "    func verify() async {\n"
            "        if let clock = self.clock {\n"
            "            try await clock.sleep(for: .milliseconds(300))\n"
            "            #expect(widget.isRendered)\n"
            "        }\n"
            "    }\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/DifferentNameOptionalRealClockTests.swift",
            "func verify(candidate: ContinuousClock?) async {\n"
            "    guard let clock = candidate else { return }\n"
            "    try await clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ConditionalCompilationRealClockFirstTests.swift",
            "#if os(macOS)\n"
            "let clock = ContinuousClock()\n"
            "#else\n"
            "let clock = TestRelayClock()\n"
            "#endif\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/ConditionalCompilationRealClockLastTests.swift",
            "#if os(Linux)\n"
            "let clock = TestRelayClock()\n"
            "#else\n"
            "let clock = ContinuousClock()\n"
            "#endif\n"
            "try await clock.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/WrappedRealClockSleepTests.swift",
            "func verify() async {\n"
            "    let clock = ContinuousClock()\n"
            "    try await clock\n"
            "        .sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/WrappedConstructedClockSleepTests.swift",
            "try await ContinuousClock()\n"
            "    .sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "tests/assert_sleep.py",
            "assert await asyncio.sleep(0.3) is None\n"
            "assert widget.is_rendered()\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "cmuxUITests/f.swift",
            "try await Task.sleep(nanoseconds: 300_000_000)\nXCTAssertTrue(view.exists)\n",
            {RULE_SLEEP_THEN_ASSERT},
        ),
        (
            "Tests/SpecializedTaskSleepTests.swift",
            "try await Task<Never, Never>.sleep(for: .milliseconds(300))\n"
            "#expect(widget.isRendered)\n",
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
        (
            "tests/shell_glob_sleep.sh",
            "files=(\"$fixture_dir\"/*)\n"
            "sleep 0.3\n"
            "assert \"$actual\" \"$expected\"\n",
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
        # A fake-clock event named `.sleep` is data, not a real delay. The
        # following assertions consume causal AsyncStream signals directly.
        (
            "Packages/CmuxClock/Tests/VirtualClockTests.swift",
            "#expect(await clockEvents.next() == .sleep(initialRefresh))\n"
            "clock.advance(to: initialRefresh)\n"
            "#expect(await clockEvents.next() == .sleep(replacementRefresh))\n"
            "#expect(await broker.requests() == 1)\n",
        ),
        # The implicit-member event remains data when formatting moves it to a
        # continuation line that does not itself contain the assertion token.
        (
            "Packages/CmuxClock/Tests/FormattedVirtualClockTests.swift",
            "#expect(await clockEvents.next() ==\n"
            "    .sleep(initialRefresh))\n"
            "#expect(await broker.requests() == 1)\n",
        ),
        # A fully qualified virtual-clock event constructor is also data, not a
        # known real clock API, even when an assertion follows immediately.
        (
            "Packages/CmuxClock/Tests/QualifiedVirtualClockTests.swift",
            "let expected = TestRelayClock.Event.sleep(initialRefresh)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        # The same method spelling stays deterministic when the nearest local
        # receiver binding is a test clock rather than a standard real clock.
        (
            "Packages/CmuxClock/Tests/InjectedVirtualClockTests.swift",
            "let clock = TestRelayClock()\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/ClosureDefaultVirtualClockParameterTests.swift",
            "func verifyVirtual(\n"
            "    clock: TestRelayClock,\n"
            "    callback: () -> Void = {}\n"
            ") async {\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        # A standard-clock binding in a previous function must not leak into a
        # later function whose same-named clock is injected.
        (
            "Packages/CmuxClock/Tests/ScopedVirtualClockTests.swift",
            "func makeRealClock() {\n"
            "    let clock = ContinuousClock()\n"
            "}\n"
            "func verifyVirtual(clock: TestRelayClock) async {\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        # Function modifiers must not hide the scope boundary and let a real
        # clock binding leak into a later function's injected-clock receiver.
        (
            "Packages/CmuxClock/Tests/PrivateScopedVirtualClockTests.swift",
            "private func makeRealClock() {\n"
            "    let clock = ContinuousClock()\n"
            "}\n"
            "private func verifyVirtual(clock: TestRelayClock) async {\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/StaticScopedVirtualClockTests.swift",
            "static func makeRealClock() {\n"
            "    let clock = ContinuousClock()\n"
            "}\n"
            "static func verifyVirtual(clock: TestRelayClock) async {\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/FailableInitializerVirtualClockTests.swift",
            "struct Fixture {\n"
            "    let clock = ContinuousClock()\n"
            "    init?(clock: TestRelayClock) async {\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await clockEvents.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/IUOInitializerVirtualClockTests.swift",
            "struct Fixture {\n"
            "    let clock = ContinuousClock()\n"
            "    init!(clock: TestRelayClock) async {\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await clockEvents.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        # A binding inside a completed sibling closure or nested block is not
        # visible at the later injected-clock call site.
        (
            "Packages/CmuxClock/Tests/ClosureScopedVirtualClockTests.swift",
            "let producer = {\n"
            "    let clock = ContinuousClock()\n"
            "}\n"
            "let consumer = { (clock: TestRelayClock) in\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/BlockScopedVirtualClockTests.swift",
            "func verifyVirtual(clock: TestRelayClock) async {\n"
            "    if shouldCreateRealClock {\n"
            "        let clock = ContinuousClock()\n"
            "        consume(clock)\n"
            "    }\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        # An inner fake clock shadows an outer real clock while that lexical
        # scope is active, including when it arrives as a closure parameter.
        (
            "Packages/CmuxClock/Tests/ShadowedVirtualClockTests.swift",
            "func verifyVirtual() async {\n"
            "    let clock = ContinuousClock()\n"
            "    if shouldUseVirtualClock {\n"
            "        let clock = TestRelayClock()\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await clockEvents.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/ClosureParameterVirtualClockTests.swift",
            "func verifyVirtual() async {\n"
            "    let clock = ContinuousClock()\n"
            "    let work = { (clock: TestRelayClock) in\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await clockEvents.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/MultilineClosureParameterVirtualClockTests.swift",
            "func verifyVirtual() async {\n"
            "    let clock = ContinuousClock()\n"
            "    let work = {\n"
            "        (clock: TestRelayClock) in\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await clockEvents.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CaptureListClosureParameterVirtualClockTests.swift",
            "func verifyVirtual() async {\n"
            "    let clock = ContinuousClock()\n"
            "    let work = { [weak self] (clock: TestRelayClock) in\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await clockEvents.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/AssignedCaptureVirtualClockTests.swift",
            "func verifyVirtual() async {\n"
            "    let clock = ContinuousClock()\n"
            "    let work = { [clock = TestRelayClock()] in\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await clockEvents.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/AliasedCaptureVirtualClockTests.swift",
            "func verifyVirtual() async {\n"
            "    let testClock = TestRelayClock()\n"
            "    let work = { [clock = testClock] in\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await clockEvents.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/NestedInitializerVirtualClockTests.swift",
            "let clock = TestRelayClock(reference: { let fallback = ContinuousClock(); return fallback }())\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/NestedArgumentVirtualClockTests.swift",
            "let clock = TestRelayClock(reference: ContinuousClock())\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/NestedCastVirtualClockTests.swift",
            "let clock = TestRelayClock(reference: makeClock() as ContinuousClock)\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        # A conditional real-clock binding must disappear with its branch and
        # leave the injected outer fake clock authoritative afterward.
        (
            "Packages/CmuxClock/Tests/ExpiredConditionalClockTests.swift",
            "func verifyVirtual(clock: TestRelayClock, candidate: ContinuousClock?) async {\n"
            "    if let clock: ContinuousClock = candidate {\n"
            "        consume(clock)\n"
            "    }\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/ShorthandOptionalVirtualClockTests.swift",
            "let clock: TestRelayClock? = TestRelayClock()\n"
            "if let clock {\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/ExplicitOptionalVirtualClockTests.swift",
            "func verify(clock: TestRelayClock?) async {\n"
            "    if let clock = clock {\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await clockEvents.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/ShorthandGuardVirtualClockTests.swift",
            "func verify(clock: TestRelayClock?) async {\n"
            "    guard let clock else { return }\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/DifferentNameOptionalVirtualClockTests.swift",
            "func verify(candidate: TestRelayClock?) async {\n"
            "    guard let clock = candidate else { return }\n"
            "    try await clock.sleep(until: deadline)\n"
            "    #expect(await clockEvents.next() == expected)\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/ConditionalCompilationVirtualClockTests.swift",
            "#if os(macOS)\n"
            "let clock = TestRelayClock()\n"
            "#else\n"
            "let clock = ManualClock()\n"
            "#endif\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/SwitchCaseVirtualClockTests.swift",
            "func verify(clock: TestRelayClock) async {\n"
            "    switch mode {\n"
            "    case .real:\n"
            "        let clock = ContinuousClock()\n"
            "        consume(clock)\n"
            "    case .virtual:\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/SwitchPatternVirtualClockTests.swift",
            "func verify() async {\n"
            "    let clock = ContinuousClock()\n"
            "    switch state {\n"
            "    case let .ready(clock):\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/MultilineSwitchPatternVirtualClockTests.swift",
            "func verify() async {\n"
            "    let clock = ContinuousClock()\n"
            "    switch state {\n"
            "    case let .ready(\n"
            "        clock\n"
            "    ):\n"
            "        try await clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        # Sleep-shaped fixture data and comments remain non-executable even when
        # a real clock with the same receiver name is visible.
        (
            "Packages/CmuxClock/Tests/StringSleepFixtureTests.swift",
            "let clock = ContinuousClock()\n"
            "let command = \"clock.sleep(for: .seconds(1))\"\n"
            "#expect(command.contains(\"sleep\"))\n",
        ),
        (
            "Packages/CmuxClock/Tests/CommentSleepFixtureTests.swift",
            "let clock = ContinuousClock()\n"
            "/* clock.sleep(for: .seconds(1)) */\n"
            "#expect(widget.isRendered)\n",
        ),
        (
            "Packages/CmuxClock/Tests/WrappedVirtualClockTests.swift",
            "let clock = TestRelayClock()\n"
            "try await clock\n"
            "    .sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        # Member-chain receivers are not resolved from an unrelated bare local
        # that happens to share their final property name.
        (
            "Packages/CmuxClock/Tests/MemberClockTests.swift",
            "let clock = ContinuousClock()\n"
            "let fixture = VirtualClockFixture()\n"
            "try await fixture.clock.sleep(until: deadline)\n"
            "#expect(await fixture.events.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/WrappedMemberClockTests.swift",
            "let clock = ContinuousClock()\n"
            "let fixture = VirtualClockFixture()\n"
            "try await fixture.clock\n"
            "    .sleep(until: deadline)\n"
            "#expect(await fixture.events.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/SelfVirtualClockPropertyTests.swift",
            "struct Fixture {\n"
            "    let clock: TestRelayClock\n"
            "    func verify() async {\n"
            "        let clock = ContinuousClock()\n"
            "        try await self.clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/OptionalSelfVirtualClockPropertyTests.swift",
            "final class Fixture {\n"
            "    let clock: TestRelayClock\n"
            "    func verify() {\n"
            "        let work = { [weak self] in\n"
            "            try await self?.clock.sleep(until: deadline)\n"
            "            #expect(await events.next() == expected)\n"
            "        }\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/LaterSelfVirtualClockPropertyTests.swift",
            "struct Fixture {\n"
            "    func verify() async {\n"
            "        try await self.clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "    let clock: TestRelayClock\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/UnrelatedRealClockPropertyTests.swift",
            "struct VirtualFixture {\n"
            "    func verify() async {\n"
            "        try await self.clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "    let clock: TestRelayClock\n"
            "}\n"
            "struct RealFixture {\n"
            "    let clock: ContinuousClock\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/NestedTypeNameCollisionTests.swift",
            "enum A {\n"
            "    struct Fixture {\n"
            "        let clock: ContinuousClock\n"
            "    }\n"
            "}\n"
            "enum B {\n"
            "    struct Fixture {\n"
            "        func verify() async {\n"
            "            try await self.clock.sleep(until: deadline)\n"
            "            #expect(await events.next() == expected)\n"
            "        }\n"
            "        let clock: TestRelayClock\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/FirstVirtualClockBindingTests.swift",
            "let clock = TestRelayClock(), wallClock = ContinuousClock()\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/TupleBoundVirtualClockTests.swift",
            "let (_, clock) = (fixture, TestRelayClock())\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/ReassignedVirtualClockTests.swift",
            "var clock: any Clock<Duration> = ContinuousClock()\n"
            "clock = TestRelayClock()\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/DoReassignedVirtualClockTests.swift",
            "var clock: any Clock<Duration> = ContinuousClock()\n"
            "do {\n"
            "    clock = TestRelayClock()\n"
            "}\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/ConditionalReassignedVirtualClockTests.swift",
            "var clock: any Clock<Duration> = ContinuousClock()\n"
            "if shouldUseVirtualClock {\n"
            "    clock = TestRelayClock()\n"
            "}\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "Packages/CmuxClock/Tests/ConditionalMaybeRealClockTests.swift",
            "var clock: any Clock<Duration> = TestRelayClock()\n"
            "if shouldUseRealClock {\n"
            "    clock = ContinuousClock()\n"
            "}\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
        ),
        (
            "tests/ShadowedSleepModuleAliasTests.py",
            "import time as clock_time\n"
            "clock_time = TestClock()\n"
            "clock_time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
        ),
        (
            "tests/SemicolonShadowedSleepModuleAliasTests.py",
            "import time as clock_time\n"
            "prepare(); clock_time = TestClock()\n"
            "clock_time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
        ),
        (
            "tests/ChainedShadowedSleepModuleAliasTests.py",
            "import time as clock_time\n"
            "fixture = clock_time = TestClock()\n"
            "clock_time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
        ),
        (
            "tests/MultilineParameterSleepModuleAliasTests.py",
            "import time as clock_time\n"
            "def verify(\n"
            "    clock_time: TestClock,\n"
            "):\n"
            "    clock_time.sleep(0.3)\n"
            "    assert widget.is_rendered\n",
        ),
        (
            "tests/ClassScopedSleepModuleAliasTests.py",
            "import time\n"
            "class Fixture:\n"
            "    time = TestClock()\n"
            "    time.sleep(0.3)\n"
            "    assert widget.is_rendered\n",
        ),
        (
            "tests/ShadowedTimeModuleTests.py",
            "time = TestClock()\n"
            "time.sleep(0.3)\n"
            "assert widget.is_rendered\n",
        ),
        (
            "tests/ShadowedAsyncioModuleTests.py",
            "asyncio = TestClock()\n"
            "await asyncio.sleep(0.3)\n"
            "assert widget.is_rendered\n",
        ),
        (
            "tests/ShadowedTrioModuleTests.py",
            "trio = TestClock()\n"
            "await trio.sleep(0.3)\n"
            "assert widget.is_rendered\n",
        ),
        (
            "tests/ShadowedAnyioModuleTests.py",
            "anyio = TestClock()\n"
            "await anyio.sleep(0.3)\n"
            "assert widget.is_rendered\n",
        ),
        (
            "tests/ShadowedGeventModuleTests.py",
            "gevent = TestClock()\n"
            "gevent.sleep(0.3)\n"
            "assert widget.is_rendered\n",
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

    cross_file_sources = [
        (
            "Tests/SplitFixture.swift",
            "struct SplitFixture {\n"
            "    let clock: ContinuousClock\n"
            "}\n",
        ),
        (
            "Tests/SplitFixture+Refresh.swift",
            "extension SplitFixture {\n"
            "    func verifyRefresh() async {\n"
            "        try await self.clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
        ),
    ]
    cross_file_rules = {
        finding.rule
        for finding in scan_sources(cross_file_sources)
    }
    if RULE_SLEEP_THEN_ASSERT not in cross_file_rules:
        failures.append(
            "POSITIVE cross-file real clock member: missing "
            f"{RULE_SLEEP_THEN_ASSERT!r} (got {sorted(cross_file_rules)})"
        )

    cross_file_chain_sources = [
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/Support/Fixture.swift",
            "struct Fixture {\n"
            "    let clock: ContinuousClock\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/FixtureClockTests.swift",
            "func verify(fixture: Fixture) async {\n"
            "    try await fixture.clock.sleep(for: .milliseconds(300))\n"
            "    #expect(widget.isRendered)\n"
            "}\n",
        ),
    ]
    cross_file_chain_rules = {
        finding.rule for finding in scan_sources(cross_file_chain_sources)
    }
    if RULE_SLEEP_THEN_ASSERT not in cross_file_chain_rules:
        failures.append(
            "POSITIVE cross-file chained real clock member: missing "
            f"{RULE_SLEEP_THEN_ASSERT!r} "
            f"(got {sorted(cross_file_chain_rules)})"
        )

    cross_target_sources = [
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/Support/SplitFixture.swift",
            "struct SplitFixture {\n"
            "    let clock: ContinuousClock\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/SplitFixture+Refresh.swift",
            "extension SplitFixture {\n"
            "    func verifyRefresh() async {\n"
            "        try await self.clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
        ),
    ]
    cross_target_rules = {
        finding.rule for finding in scan_sources(cross_target_sources)
    }
    if RULE_SLEEP_THEN_ASSERT not in cross_target_rules:
        failures.append(
            "POSITIVE cross-directory test-target member: missing "
            f"{RULE_SLEEP_THEN_ASSERT!r} (got {sorted(cross_target_rules)})"
        )

    cross_primary_sources = [
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/Fixture.swift",
            "struct Fixture {\n"
            "    func verifyRefresh() async {\n"
            "        try await self.clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/Support/Fixture+Clock.swift",
            "extension Fixture {\n"
            "    var clock: ContinuousClock { ContinuousClock() }\n"
            "}\n",
        ),
    ]
    cross_primary_rules = {
        finding.rule for finding in scan_sources(cross_primary_sources)
    }
    if RULE_SLEEP_THEN_ASSERT not in cross_primary_rules:
        failures.append(
            "POSITIVE primary-type call with extension real member: missing "
            f"{RULE_SLEEP_THEN_ASSERT!r} (got {sorted(cross_primary_rules)})"
        )

    inherited_member_sources = [
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/Support/BaseFixture.swift",
            "class BaseFixture {\n"
            "    let clock = ContinuousClock()\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/InheritedClockTests.swift",
            "final class InheritedClockTests: BaseFixture {\n"
            "    func verifyRefresh() async {\n"
            "        try await self.clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
        ),
    ]
    inherited_member_rules = {
        finding.rule for finding in scan_sources(inherited_member_sources)
    }
    if RULE_SLEEP_THEN_ASSERT not in inherited_member_rules:
        failures.append(
            "POSITIVE inherited real clock member: missing "
            f"{RULE_SLEEP_THEN_ASSERT!r} (got {sorted(inherited_member_rules)})"
        )

    qualified_inherited_member_sources = [
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/Support/BaseFixture.swift",
            "enum Support {\n"
            "    class BaseFixture {\n"
            "        let clock = ContinuousClock()\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/QualifiedClockTests.swift",
            "final class QualifiedClockTests: Support.BaseFixture {\n"
            "    func verifyRefresh() async {\n"
            "        try await self.clock.sleep(for: .milliseconds(300))\n"
            "        #expect(widget.isRendered)\n"
            "    }\n"
            "}\n",
        ),
    ]
    qualified_inherited_member_rules = {
        finding.rule
        for finding in scan_sources(qualified_inherited_member_sources)
    }
    if RULE_SLEEP_THEN_ASSERT not in qualified_inherited_member_rules:
        failures.append(
            "POSITIVE qualified inherited real clock member: missing "
            f"{RULE_SLEEP_THEN_ASSERT!r} "
            f"(got {sorted(qualified_inherited_member_rules)})"
        )

    cross_file_negatives = [
        (
            "Tests/SplitNestedRealFixture.swift",
            "enum A {\n"
            "    struct Fixture {\n"
            "        let clock: ContinuousClock\n"
            "    }\n"
            "}\n",
        ),
        (
            "Tests/SplitNestedVirtualFixture.swift",
            "enum B {\n"
            "    struct Fixture {\n"
            "        let clock: TestRelayClock\n"
            "    }\n"
            "}\n",
        ),
        (
            "Tests/SplitNestedVirtualFixture+Refresh.swift",
            "extension B.Fixture {\n"
            "    func verifyRefresh() async {\n"
            "        try await self.clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Tests/UnrelatedRealFixture.swift",
            "struct CollisionFixture {\n"
            "    let clock: ContinuousClock\n"
            "}\n",
        ),
        (
            "Tests/UnrelatedVirtualFixture.swift",
            "struct CollisionFixture {\n"
            "    let clock: TestRelayClock\n"
            "    func verifyRefresh() async {\n"
            "        try await self.clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/Support/VirtualBaseFixture.swift",
            "class VirtualBaseFixture {\n"
            "    let clock = TestRelayClock()\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/InheritedVirtualClockTests.swift",
            "final class InheritedVirtualClockTests: VirtualBaseFixture {\n"
            "    func verifyRefresh() async {\n"
            "        try await self.clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/LocalBaseFixture.swift",
            "class BaseFixture {\n"
            "    let clock = ContinuousClock()\n"
            "}\n",
        ),
        (
            "Packages/CmuxClock/Tests/CmuxClockTests/QualifiedVirtualClockTests.swift",
            "final class QualifiedVirtualClockTests: Support.BaseFixture {\n"
            "    func verifyRefresh() async {\n"
            "        try await self.clock.sleep(until: deadline)\n"
            "        #expect(await events.next() == expected)\n"
            "    }\n"
            "}\n",
        ),
    ]
    cross_file_negative_rules = {
        finding.rule for finding in scan_sources(cross_file_negatives)
    }
    if cross_file_negative_rules:
        failures.append(
            "NEGATIVE cross-file member identity: unexpected "
            f"{sorted(cross_file_negative_rules)}"
        )

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
