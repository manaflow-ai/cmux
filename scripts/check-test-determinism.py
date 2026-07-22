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
    \btime\.sleep\s*\(
  | (?<!\.)\bsleep\s*\(                    # unqualified C-style sleep(...)
  | \b(?:Darwin|Glibc)\.sleep\s*\(
  | \busleep\s*\(
  | \bnanosleep\s*\(
  | Thread\.sleep\s*\(
  | \bTask(?:\s*<[^>\n]+>)?\s*\.sleep\s*\(
  | try\s+await\s+Task\.sleep
  | \b(?:ContinuousClock|SuspendingClock)\s*\(\s*\)\.sleep\s*\(
  | \basyncio\.sleep\s*\(
  | \bsetTimeout\s*\(                       # JS, when used as a bare delay
    """
)

_NAMED_SLEEP_CALL = re.compile(
    r"(?<![.\w])(?:(self)\s*\.\s*)?([A-Za-z_]\w*)[?!]?\.sleep\s*\("
)
_CONTINUED_SLEEP_CALL = re.compile(r"^\s*[?!]?\s*\.sleep\s*\(")
_LOCAL_SCOPE_HEADER = re.compile(
    r"^\s*"
    r"(?:(?:@\w+(?:\([^)]*\))?|[A-Za-z_]\w*(?:\([^)]*\))?)\s+)*"
    r"(?:func\b|init[?!]?\s*\(|def\b)"
)
_CONDITIONAL_SCOPE_HEADER = re.compile(
    r"^\s*(?:}\s*else\s+)?(?:if|while|for)\b"
)
_COMPILATION_DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b")
_FOR_SCOPE_BINDING = re.compile(
    r"^\s*for(?:\s+try)?(?:\s+await)?\s+([A-Za-z_]\w*)\s+in\b"
)
_REAL_CLOCK_TYPE = re.compile(
    r"^\s*:\s*(?:[A-Za-z_]\w*\.)*"
    r"(?:ContinuousClock|SuspendingClock)\??(?=\s|=|[,){]|$)"
)
_REAL_CLOCK_INIT = re.compile(
    r"^\s*(?::[^=]+)?=\s*(?:[A-Za-z_]\w*\.)*"
    r"(?:ContinuousClock|SuspendingClock)\s*\("
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
    line_comment = "#" if path_suffix in (".py", ".sh") else "//"

    for line in lines:
        masked = list(line)
        i = 0
        while i < len(line):
            if block_comment_depth:
                masked[i] = " "
                if line.startswith("/*", i):
                    masked[i : i + 2] = "  "
                    block_comment_depth += 1
                    i += 2
                elif line.startswith("*/", i):
                    masked[i : i + 2] = "  "
                    block_comment_depth -= 1
                    i += 2
                else:
                    i += 1
                continue

            if quote:
                if line.startswith(quote, i):
                    masked[i : i + len(quote)] = " " * len(quote)
                    i += len(quote)
                    quote = None
                elif quote != '"""' and line[i] == "\\":
                    masked[i] = " "
                    if i + 1 < len(line):
                        masked[i + 1] = " "
                    i += 2
                else:
                    masked[i] = " "
                    i += 1
                continue

            if line.startswith(line_comment, i):
                masked[i:] = " " * (len(line) - i)
                break
            if line.startswith("/*", i):
                masked[i : i + 2] = "  "
                block_comment_depth = 1
                i += 2
            elif line.startswith('"""', i):
                masked[i : i + 3] = "   "
                quote = '"""'
                i += 3
            elif line[i] in ('"', "'"):
                masked[i] = " "
                quote = line[i]
                i += 1
            else:
                i += 1

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


def _captured_receiver_kind(text: str, receiver: str) -> Optional[bool]:
    assignment = re.search(
        rf"(?:^|,)\s*(?:(?:weak|unowned(?:\([^)]*\))?)\s+)?"
        rf"{re.escape(receiver)}\s*=\s*([^,]+)",
        text,
    )
    if not assignment:
        return None
    return bool(_REAL_CLOCK_INIT.search(f"= {assignment.group(1)}"))


def _closure_receiver_kind(text: str, receiver: str) -> Optional[bool]:
    in_token = re.search(r"\bin\b", text)
    if not in_token:
        return None
    parameters = text[: in_token.start()].strip()
    captured_kind: Optional[bool] = None
    while parameters:
        attribute = re.match(r"@\w+(?:\([^)]*\))?\s*", parameters)
        if attribute:
            parameters = parameters[attribute.end() :].lstrip()
            continue
        if parameters.startswith("["):
            depth = 0
            capture_list_end: Optional[int] = None
            for index, character in enumerate(parameters):
                if character == "[":
                    depth += 1
                elif character == "]":
                    depth -= 1
                    if depth == 0:
                        capture_list_end = index + 1
                        break
            if capture_list_end is not None:
                captured_kind = _captured_receiver_kind(
                    parameters[1 : capture_list_end - 1], receiver
                )
                parameters = parameters[capture_list_end:].lstrip()
                continue
        break
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


def _local_receiver_declarations(
    text: str, receiver: str
) -> list[tuple[int, str]]:
    """Return this receiver's individual `let`/`var` declarators on one line."""
    declarations: list[tuple[int, str]] = []

    for keyword in re.finditer(r"\b(?:let|var)\b", text):
        segment_start = keyword.end()
        paren_depth = 0
        bracket_depth = 0
        angle_depth = 0
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
            elif char == "<":
                angle_depth += 1
            elif char == ">" and angle_depth:
                angle_depth -= 1
            elif not (paren_depth or bracket_depth or angle_depth):
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
            if not name or name.group(1) != receiver:
                continue
            name_end = start + name.end()
            declarations.append((start + name.start(1), text[name_end:end]))

    return declarations


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
    return bool(_REAL_CLOCK_TYPE.search(probe) or _REAL_CLOCK_INIT.search(probe))


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


@dataclass
class _CompilationScopeFrame:
    base_scopes: list[dict[str, bool]]
    base_scope_kinds: list[str]
    branch_scopes: list[list[dict[str, bool]]]
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


def _nearest_receiver_kind(
    scopes: list[dict[str, bool]], receiver: str
) -> Optional[bool]:
    return next(
        (scope[receiver] for scope in reversed(scopes) if receiver in scope),
        None,
    )


def _is_named_real_clock_sleep(masked_lines: list[str], idx: int) -> bool:
    """Resolve a named receiver through Swift-like lexical brace scopes."""
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
            r"\b(?:ContinuousClock|SuspendingClock)\s*\(\s*\)\s*$", previous
        ) or re.search(r"\bTask(?:\s*<[^>\n]+>)?\s*$", previous):
            return True
        receiver_match = re.search(r"\b([A-Za-z_]\w*)[?!]?\s*$", previous)
        if not receiver_match:
            return False
        receiver_prefix = previous[: receiver_match.start()].rstrip()
        self_receiver = bool(re.search(r"\bself\s*\.\s*$", receiver_prefix))
        if receiver_prefix.endswith(".") and not self_receiver:
            return False
        receiver = receiver_match.group(1)
        sleep_start = continuation.start()

    prefix_lines = masked_lines[:idx] + [current[:sleep_start]]
    scopes: list[dict[str, bool]] = [{}]
    scope_kinds = ["root"]
    pending_function = False
    pending_parameter: Optional[bool] = None
    pending_function_paren_depth = 0
    pending_function_saw_parameters = False
    pending_conditional: Optional[dict[str, bool]] = None
    compilation_frames: list[_CompilationScopeFrame] = []

    for candidate_index, candidate in enumerate(prefix_lines):
        compilation_directive = _COMPILATION_DIRECTIVE.match(candidate)
        if compilation_directive:
            directive = compilation_directive.group(1)
            if directive == "if":
                compilation_frames.append(
                    _CompilationScopeFrame(
                        base_scopes=_copy_scope_stack(scopes),
                        base_scope_kinds=list(scope_kinds),
                        branch_scopes=[],
                    )
                )
            elif directive in ("elseif", "else") and compilation_frames:
                frame = compilation_frames[-1]
                frame.branch_scopes.append(_copy_scope_stack(scopes))
                frame.has_else = frame.has_else or directive == "else"
                scopes = _copy_scope_stack(frame.base_scopes)
                scope_kinds = list(frame.base_scope_kinds)
            elif directive == "endif" and compilation_frames:
                frame = compilation_frames.pop()
                frame.branch_scopes.append(_copy_scope_stack(scopes))
                scopes = _merge_compilation_branches(frame, receiver)
                scope_kinds = list(frame.base_scope_kinds)
            continue

        if _LOCAL_SCOPE_HEADER.search(candidate):
            pending_function = True
            pending_parameter = _annotated_receiver_kind(candidate, receiver)
            pending_function_paren_depth = 0
            pending_function_saw_parameters = False
        elif pending_function and pending_parameter is None:
            pending_parameter = _annotated_receiver_kind(candidate, receiver)
        if _CONDITIONAL_SCOPE_HEADER.search(candidate):
            pending_conditional = {}
            for_binding = _FOR_SCOPE_BINDING.search(candidate)
            if for_binding and for_binding.group(1) == receiver:
                pending_conditional[receiver] = False

        events: list[tuple[int, str, Optional[str]]] = []
        events.extend(
            (position, "binding", declaration)
            for position, declaration in _local_receiver_declarations(
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
                scope = dict(pending_conditional or {})
                pending_conditional = None
                is_function_body = bool(
                    pending_function
                    and pending_function_saw_parameters
                    and pending_function_paren_depth == 0
                )
                scope_kind = "function" if is_function_body else "block"
                if is_function_body:
                    if pending_parameter is not None:
                        scope[receiver] = pending_parameter
                    pending_function = False
                    pending_parameter = None
                    pending_function_paren_depth = 0
                    pending_function_saw_parameters = False
                closure_kind = None
                if not is_function_body and not is_conditional_body:
                    closure_header = _closure_header_text(
                        candidate[pos + 1 :],
                        prefix_lines[candidate_index + 1 :],
                    )
                    closure_kind = _closure_receiver_kind(closure_header, receiver)
                if closure_kind is not None:
                    scope[receiver] = closure_kind
                scopes.append(scope)
                scope_kinds.append(scope_kind)
            elif event == "}":
                if len(scopes) > 1:
                    scopes.pop()
                    scope_kinds.pop()
            elif declaration is not None:
                if _receiver_declaration_inherits_kind(declaration, receiver):
                    inherited_kind = _nearest_receiver_kind(scopes, receiver)
                    kind = (
                        inherited_kind
                        if inherited_kind is not None
                        else False
                    )
                else:
                    kind = _receiver_declaration_kind(
                        declaration, prefix_lines[candidate_index + 1 :]
                    )
                if pending_conditional is not None:
                    pending_conditional[receiver] = kind
                else:
                    scopes[-1][receiver] = kind

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
    return False


def detect_sleep_then_assert(
    lines: list[str], masked_lines: list[str], idx: int, path_suffix: str
) -> bool:
    """Sleep on lines[idx] followed by an assertion within 3 non-blank lines."""
    line = masked_lines[idx]
    is_sleep = bool(_SLEEP_CALL.search(line)) or _is_named_real_clock_sleep(
        masked_lines, idx
    )
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
    needs_sleep_mask = "sleep" in text or "setTimeout" in text
    masked_lines = (
        [_strip_comment(line, suffix) for line in _mask_noncode(raw_lines, suffix)]
        if needs_sleep_mask
        else code_lines
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
        if detect_sleep_then_assert(code_lines, masked_lines, i, suffix):
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
            "Tests/NamedClockTests.swift",
            "let clock = ContinuousClock()\n"
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
            "time.sleep(0.3)\n"
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
            "Tests/SecondRealClockBindingTests.swift",
            "let fakeClock = TestRelayClock(), clock = ContinuousClock()\n"
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
            "Packages/CmuxClock/Tests/ConditionalCompilationVirtualClockTests.swift",
            "#if os(macOS)\n"
            "let clock = TestRelayClock()\n"
            "#else\n"
            "let clock = ManualClock()\n"
            "#endif\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
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
            "Packages/CmuxClock/Tests/FirstVirtualClockBindingTests.swift",
            "let clock = TestRelayClock(), wallClock = ContinuousClock()\n"
            "try await clock.sleep(until: deadline)\n"
            "#expect(await clockEvents.next() == expected)\n",
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
