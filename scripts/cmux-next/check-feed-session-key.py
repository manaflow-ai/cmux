#!/usr/bin/env python3
"""FEED-SESSION-KEY guard (review of manaflow-ai/cmux#41240, finding F1).

The feed bridge posts one phone item per acpmux prompt and withdraws it when the
prompt is answered elsewhere. It must key every add and every withdraw on ONE id
per session: the row's `qualifiedSessionId` (`peer/id`, which acpmux sends on a
peer's rows and on every notice of a peer's session), or this daemon's own raw
`sessionId` for its own sessions. That key is made in one place,
`AcpmuxPendingReads.sessionKey(_:)`. A raw `sessionId` read anywhere else on the
feed path names no peer: two peers can share it, and a prompt that recovery
posted under the qualified id is never withdrawn by a notice read by the raw id,
so a stale item stays on the phone.

This guard fails when a file on the feed path
  - reads `"sessionId"` from a row, notice or reply (`x["sessionId"]`);
    writing it into a request (`["sessionId": key]`) is fine;
  - builds a `peer/id` key by hand (a line that reads `["peer"]` and
    interpolates `/\\(`).
The patterns run on whole statements, not physical lines: a subscript, a call,
a string literal (single-line, triple-quoted multi-line, `#"raw"#`), an interpolation
`\\( ... )`, and a line that ends with or starts with an operator continue the
statement on the next line, so a read or key split across lines is still one
statement (review of #41471, F1). Comments (`//`, nested `/* */`) are dropped,
and the text of a string literal is masked, so a comment or a string that only
mentions sessionId is not flagged. A finding names the line its statement
starts on. A statement that must do either (sessionKey's own body) carries
`feed-key-allow: <reason>` on one of its lines.

The feed path: every Swift file under CmuxNextApp/Feed/, the dialog desk's
prompt list (Approvals/AgentDialogLine.swift), and the recovery reads it shares
(AcpmuxPendingReads.swift, AcpmuxSessionListGate.swift).

Tested by scripts/cmux-next/tests/check-feed-session-key.test.sh.

Usage: scripts/cmux-next/check-feed-session-key.py [repo-root]
Exit 0 clean, 1 with findings, 2 on a usage error.
"""

from __future__ import annotations

import bisect
import re
import sys
from pathlib import Path

SOURCES = "Packages/macOS/CmuxNext/Sources"
FEED_DIRS = [f"{SOURCES}/CmuxNextApp/Feed"]
FEED_FILES = [
    f"{SOURCES}/CmuxNextAgentPane/Approvals/AgentDialogLine.swift",
    f"{SOURCES}/CmuxNextAgentPane/AcpmuxPendingReads.swift",
    f"{SOURCES}/CmuxNextAgentPane/AcpmuxSessionListGate.swift",
]
ALLOW = "feed-key-allow:"

# A read of the raw id: the key in a subscript, not a dictionary literal's `"sessionId":`.
RAW_READ = re.compile(r'\[\s*"sessionId"\s*\]')
# A hand-made qualified key: the peer read and a `/\(` interpolation in one statement.
PEER_READ = re.compile(r'\[\s*"peer"\s*\]')
HAND_KEY = re.compile(r'/\\\(')

# A statement goes on past a newline when its code so far ends with one of these,
_CONTINUE_AFTER = ("=", "??", "+", "-", "*", "&&", "||", ",", ".", "->")
# or when the next line starts with one of these.
_CONTINUE_BEFORE = (".", "??", "&&", "||", "?", ":", "+", "-", "=")


def feed_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for directory in FEED_DIRS:
        path = root / directory
        if path.is_dir():
            files.extend(sorted(path.rglob("*.swift")))
    for name in FEED_FILES:
        path = root / name
        if path.is_file():
            files.append(path)
    return files


class _Lexer:
    """Renders Swift source as code: comments dropped, string text masked.

    A string literal renders as `"` + its text, where every character but a
    letter, digit, `_`, `/` or space is `_`, + `"`, and each interpolation
    `\\( ... )` inside it renders as `\\(` + its code + `)`. So `x["sessionId"]`
    stays `x["sessionId"]`, while a string that only mentions it does not.
    """

    def __init__(self, text: str) -> None:
        self.t = text
        self.n = len(text)

    def skip_comment(self, i: int) -> int | None:
        """The index after a comment that starts at i, or None when none does."""
        t = self.t
        if t.startswith("//", i):
            j = t.find("\n", i)
            return self.n if j < 0 else j
        if t.startswith("/*", i):
            depth, j = 0, i
            while j < self.n:
                if t.startswith("/*", j):
                    depth += 1
                    j += 2
                elif t.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        return j
                else:
                    j += 1
            return self.n
        return None

    def string(self, i: int) -> tuple[str, int] | None:
        """(rendered, index after) for a string literal at i, else None."""
        t, n = self.t, self.n
        hashes = 0
        while i + hashes < n and t[i + hashes] == "#":
            hashes += 1
        p = i + hashes
        if p >= n or t[p] != '"':
            return None
        multiline = t.startswith('"""', p)
        quote = '"""' if multiline else '"'
        close = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        p += len(quote)
        out = ['"']
        while p < n:
            if t.startswith(close, p):
                return "".join(out) + '"', p + len(close)
            if t.startswith(escape, p):
                q = p + len(escape)
                if q < n and t[q] == "(":
                    code, p = self.interpolation(q + 1)
                    out.append("\\(" + code + ")")
                else:
                    out.append("_")
                    p = q + 1
                continue
            c = t[p]
            if c == "\n" and not multiline:
                break  # unterminated: end it at the line
            out.append(c if c.isalnum() or c in "_/ " else "_")
            p += 1
        return "".join(out) + '"', p

    def interpolation(self, p: int) -> tuple[str, int]:
        """(code, index after the closing paren) for `\\(` code starting at p."""
        t, n = self.t, self.n
        out: list[str] = []
        depth = 0
        while p < n:
            skipped = self.skip_comment(p)
            if skipped is not None:
                out.append(" ")
                p = skipped
                continue
            c = t[p]
            if c in '#"':
                lit = self.string(p)
                if lit is not None:
                    out.append(lit[0])
                    p = lit[1]
                    continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    return "".join(out), p + 1
                depth -= 1
            out.append(" " if c == "\n" else c)
            p += 1
        return "".join(out), n

    def next_line_continues(self, p: int) -> bool:
        """Whether the line starting at p opens with a continuation operator."""
        end = self.t.find("\n", p)
        rest = self.t[p:self.n if end < 0 else end].lstrip()
        return rest.startswith(_CONTINUE_BEFORE) and not rest.startswith(("//", "/*"))

    def statements(self) -> list[tuple[int, int, str]]:
        """(first index, last index, code) of each statement.

        A statement ends at `;`, at a `{` or `}`, or at a newline, all outside
        (), [], strings and comments, unless the line continues it.
        """
        t, n = self.t, self.n
        out: list[tuple[int, int, str]] = []
        buf: list[str] = []
        first = last = -1
        depth = 0

        def flush() -> None:
            nonlocal buf, first, last, depth
            code = "".join(buf)
            if first >= 0 and code.strip():
                out.append((first, last, code))
            buf, first, last, depth = [], -1, -1, 0

        i = 0
        while i < n:
            skipped = self.skip_comment(i)
            if skipped is not None:
                buf.append(" ")
                i = skipped
                continue
            c = t[i]
            if c in '#"':
                lit = self.string(i)
                if lit is not None:
                    if first < 0:
                        first = i
                    buf.append(lit[0])
                    last, i = lit[1] - 1, lit[1]
                    continue
            if c == "\n":
                code = "".join(buf).rstrip()
                if depth == 0 and not code.endswith(_CONTINUE_AFTER) \
                        and not self.next_line_continues(i + 1):
                    flush()
                else:
                    buf.append(" ")
                i += 1
                continue
            if depth == 0 and c in "{};":
                flush()
                i += 1
                continue
            if c in "([":
                depth += 1
            elif c in ")]":
                depth = max(0, depth - 1)
            if not c.isspace():
                if first < 0:
                    first = i
                last = i
            buf.append(c)
            i += 1
        flush()
        return out


def findings(root: Path) -> list[str]:
    out: list[str] = []
    for path in feed_files(root):
        rel = path.relative_to(root)
        text = path.read_text(encoding="utf-8")
        lines = text.split("\n")
        newlines = [i for i, c in enumerate(text) if c == "\n"]
        for first, last, code in _Lexer(text).statements():
            start = bisect.bisect_left(newlines, first)
            end = bisect.bisect_left(newlines, last)
            if any(ALLOW in line for line in lines[start:end + 1]):
                continue
            if RAW_READ.search(code):
                out.append(f"{rel}:{start + 1}: reads the raw sessionId; key the feed on "
                           "AcpmuxPendingReads.sessionKey(_:) (qualifiedSessionId for a peer)")
            elif PEER_READ.search(code) and HAND_KEY.search(code):
                out.append(f"{rel}:{start + 1}: builds a peer/id key by hand; use "
                           "AcpmuxPendingReads.sessionKey(_:)")
    return out


def main(argv: list[str]) -> int:
    if len(argv) > 2 or (len(argv) == 2 and argv[1].startswith("-")):
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    root = Path(argv[1]) if len(argv) == 2 else Path(__file__).resolve().parents[2]
    found = findings(root)
    for finding in found:
        print(finding, file=sys.stderr)
    if found:
        print(f"check-feed-session-key: {len(found)} finding(s). A statement that must read it carries "
              f"`{ALLOW} <reason>`.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
