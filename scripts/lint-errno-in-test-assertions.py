#!/usr/bin/env python3
"""Reject `errno` read inside a Swift test assertion's arguments.

    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)

`errno` is only meaningful immediately after the call that set it, and the C
library may change it inside any later call, even one that succeeds. Swift
Testing's `#expect` and `#require` expand into a call that builds the
expression description and source location before it evaluates the operands it
defers, so library code runs between the syscall and the `errno` read. That is
true across two assertions, as above, and inside one:

    #expect(kill(pid, 0) == -1 && errno == ESRCH)

expands to `__checkBinaryOperation(kill(pid, 0) == -1, { $0 && $1() },
errno == ESRCH, expression: ..., sourceLocation: ...)`, where the right-hand
side is an autoclosure evaluated only after those arguments are built. XCTest
assertions take autoclosures too; a message such as
`String(cString: strerror(errno))` is evaluated after the comparison failed.

The fix never changes the assertion, so this lint rejects every `errno` token
in an assertion's parenthesised arguments and prints the capture-first form.
A closure literal inside the arguments is exempt when its body makes a call
before it reads `errno`: the macro passes the closure through unchanged, so
`pid.map { kill($0, 0) != 0 && errno == ESRCH }` reads the `errno` its own
`kill` set, with nothing in between. A closure that reads `errno` before any
call of its own, such as `{ errno == ESRCH }()`, reads a value set outside it
and is rejected like a bare read.

Comments, string literals and regex literals are ignored; string
interpolations are scanned.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


REPO_ROOT = Path(__file__).resolve().parent.parent

# Swift test sources. Matches the paths the workflow guard router sends to the
# quality-determinism group, which runs this lint.
TEST_PATH = re.compile(
    r"^(?:cmuxTests|cmuxCLITests|cmuxCLITestSupport|cmuxUITests|ios/cmuxUITests)/.*\.swift$"
    r"|^Packages/.*/Tests/.*\.swift$"
)

ASSERTION = re.compile(r"(#expect|#require|\bXCTAssert[A-Za-z]*|\bXCTUnwrap)\s*\(")
ERRNO = re.compile(r"\berrno\b")
# A call inside a closure body: an identifier, `)`, `]`, `?`, `!` or `>`
# followed by `(`.
CALL = re.compile(r"(?:\w|[)\]?!>])\(")
# Where a bare `/` starts a regex literal instead of dividing: after an
# operator, an opening bracket, a separator, or one of these keywords.
REGEX_AFTER_PUNCTUATION = "([{,:;=!&|^?<>+-*%~"
REGEX_AFTER_KEYWORD = re.compile(r"\b(?:return|try|await|in|case|throw|where|else|if|guard|while)$")
# `Darwin.errno` and friends are the same global; any other `x.errno` is a
# member that happens to share the name.
MODULE_QUALIFIER = re.compile(r"\b(?:Darwin|Glibc|Musl|Foundation)\s*\.\s*$")

FIX_HINT = """\
Capture the result and errno into locals right after the call, then assert on
the locals:

    let killResult = kill(pid, 0)
    let killErrno = errno
    #expect(killResult == -1)
    #expect(killErrno == ESRCH)

The assertion macro runs library code between the call and a read of errno
inside its arguments, and that code may overwrite errno."""


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    macro: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: errno read inside {self.macro}(...)"


class _Masker:
    """Blank comments, string-literal and regex-literal text, keeping offsets."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.out = list(text)
        self.n = len(text)

    def blank(self, start: int, end: int) -> None:
        for index in range(start, min(end, self.n)):
            if self.out[index] != "\n":
                self.out[index] = " "

    def code(self, i: int, stop_at_close: bool) -> int:
        """Scan code from i. With stop_at_close, return at the unmatched `)`."""
        depth = 0
        text = self.text
        while i < self.n:
            ch = text[i]
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = self.n if end == -1 else end
                self.blank(i, end)
                i = end
            elif text.startswith("/*", i):
                i = self.block_comment(i)
            elif ch == '"' or (ch == "#" and self.raw_string_hashes(i) is not None):
                i = self.string(i)
            elif ch == "#" and self.extended_regex_hashes(i) is not None:
                i = self.extended_regex(i)
            elif ch == "/" and self.starts_bare_regex(i):
                i = self.bare_regex(i)
            elif ch == "(":
                depth += 1
                i += 1
            elif ch == ")":
                if stop_at_close and depth == 0:
                    return i
                depth -= 1
                i += 1
            else:
                i += 1
        return i

    def block_comment(self, i: int) -> int:
        start, depth, text = i, 0, self.text
        while i < self.n:
            if text.startswith("/*", i):
                depth += 1
                i += 2
            elif text.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    break
            else:
                i += 1
        self.blank(start, i)
        return i

    def raw_string_hashes(self, i: int) -> Optional[int]:
        j = i
        while j < self.n and self.text[j] == "#":
            j += 1
        if j < self.n and self.text[j] == '"' and j > i:
            return j - i
        return None

    def extended_regex_hashes(self, i: int) -> Optional[int]:
        j = i
        while j < self.n and self.text[j] == "#":
            j += 1
        if j < self.n and self.text[j] == "/" and j > i:
            return j - i
        return None

    def extended_regex(self, i: int) -> int:
        """`#/.../#`, which may span lines. It has no interpolation."""
        hashes = self.extended_regex_hashes(i) or 0
        start = i + hashes + 1
        end = self.text.find("/" + "#" * hashes, start)
        end = self.n if end == -1 else end
        self.blank(start, end)
        return min(end + 1 + hashes, self.n)

    def starts_bare_regex(self, i: int) -> bool:
        """A `/` in expression position, followed by a non-space, that closes
        on the same line. Anything else is division."""
        if i + 1 >= self.n or self.text[i + 1] in " \t\n":
            return False
        before = "".join(self.out[max(0, i - 80) : i]).rstrip()
        if before and before[-1] not in REGEX_AFTER_PUNCTUATION:
            if REGEX_AFTER_KEYWORD.search(before) is None:
                return False
        return self.bare_regex_end(i) is not None

    def bare_regex_end(self, i: int) -> Optional[int]:
        text = self.text
        j = i + 1
        while j < self.n and text[j] != "\n":
            if text[j] == "\\":
                j += 2
            elif text[j] == "/":
                # A bare regex literal cannot end in a space.
                return j if text[j - 1] not in " \t" else None
            else:
                j += 1
        return None

    def bare_regex(self, i: int) -> int:
        end = self.bare_regex_end(i)
        assert end is not None
        self.blank(i + 1, end)
        return end + 1

    def string(self, i: int) -> int:
        text = self.text
        hashes = 0
        while text[i] == "#":
            hashes += 1
            i += 1
        multiline = text.startswith('"""', i)
        quote = '"""' if multiline else '"'
        i += len(quote)
        closing = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        segment = i
        while i < self.n:
            if text.startswith(escape, i):
                after = i + len(escape)
                if after < self.n and text[after] == "(":
                    self.blank(segment, i)
                    i = self.code(after + 1, stop_at_close=True) + 1
                    segment = i
                else:
                    i = after + 1
            elif text.startswith(closing, i):
                self.blank(segment, i)
                return i + len(closing)
            elif not multiline and text[i] == "\n":
                break  # unterminated; resume as code on the next line
            else:
                i += 1
        self.blank(segment, i)
        return i


def mask_non_code(text: str) -> str:
    masker = _Masker(text)
    masker.code(0, stop_at_close=False)
    return "".join(masker.out)


def _argument_end(masked: str, open_paren: int) -> int:
    depth = 0
    for index in range(open_paren, len(masked)):
        if masked[index] == "(":
            depth += 1
        elif masked[index] == ")":
            depth -= 1
            if depth == 0:
                return index
    return len(masked)


def _closure_calls_before(masked: str, lo: int, index: int) -> bool:
    # The call must finish before the read: a call whose arguments hold the
    # errno token reads errno before that call runs.
    return any(
        _argument_end(masked, call.end() - 1) < index
        for call in CALL.finditer(masked, lo + 1, index)
    )


def _closure_spans(masked: str, start: int, end: int) -> List[Tuple[int, int]]:
    spans: List[Tuple[int, int]] = []
    depth = 0
    opened = start
    for index in range(start, end):
        if masked[index] == "{":
            if depth == 0:
                opened = index
            depth += 1
        elif masked[index] == "}" and depth > 0:
            depth -= 1
            if depth == 0:
                spans.append((opened, index))
    if depth > 0:
        spans.append((opened, end))
    return spans


def _is_errno_global(masked: str, index: int, end: int) -> bool:
    before = masked[max(0, index - 80) : index].rstrip()
    if before.endswith("."):
        return MODULE_QUALIFIER.search(before) is not None
    # An argument label such as `POSIXError(errno: value)`.
    after = masked[index + len("errno") : end].lstrip()
    if after.startswith(":") and before.endswith(("(", ",")):
        return False
    return True


def scan_source(text: str, path: str) -> List[Finding]:
    """One finding per source line that reads errno inside an assertion."""
    masked = mask_non_code(text)
    by_line: Dict[int, Finding] = {}
    for match in ASSERTION.finditer(masked):
        open_paren = match.end() - 1
        end = _argument_end(masked, open_paren)
        closures = _closure_spans(masked, open_paren, end)
        for token in ERRNO.finditer(masked, open_paren, end):
            index = token.start()
            # A closure reads the errno of its own earlier call; one that reads
            # errno first sees a value set before the assertion ran.
            if any(
                lo < index < hi and _closure_calls_before(masked, lo, index)
                for lo, hi in closures
            ):
                continue
            if not _is_errno_global(masked, index, end):
                continue
            line = masked.count("\n", 0, index) + 1
            # A nested assertion repeats its parent's tokens; keep the outer one.
            by_line.setdefault(line, Finding(path, line, match.group(1)))
    return [by_line[line] for line in sorted(by_line)]


def tracked_test_sources(root: Path) -> List[str]:
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--", "*.swift"],
        cwd=root,
        capture_output=True,
        check=True,
    ).stdout.decode("utf-8").split("\0")
    return sorted(path for path in listed if path and TEST_PATH.match(path))


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root",
        type=Path,
        default=REPO_ROOT,
        help="repository checkout to scan (default: this script's checkout)",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Swift files to scan, relative to the repository root "
        "(default: every tracked Swift test source)",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()
    paths = args.paths or tracked_test_sources(root)

    findings: List[Finding] = []
    for path in paths:
        try:
            text = (root / path).read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            print(f"{path}: cannot read: {error}", file=sys.stderr)
            return 2
        if "errno" in text:
            findings.extend(scan_source(text, path))

    if findings:
        for finding in findings:
            print(finding, file=sys.stderr)
        print(f"\n{FIX_HINT}", file=sys.stderr)
        return 1
    print(f"errno is captured before every assertion in {len(paths)} Swift test files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
