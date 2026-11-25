"""Find each `${{ ... }}` in a workflow value the way GitHub does: with a tokenizer, not a regex.

A string literal in an expression may hold `}}` (`format('{{{0}}}', x)` writes JSON braces) and `''` is an escaped
quote inside one. A regex such as `\\$\\{\\{(.*?)\\}\\}` or `\\$\\{\\{[^}]*\\}\\}` ends the expression at the first
`}}` (or `}`), so whatever follows the cut reads as plain text: a matrix read, a secret or `github.token` there is
missed and the guard that reads it passes (Codex review of #41768, F1). Here an expression ends at the first `}}`
outside a single-quoted literal. One that never ends raises Unterminated, so a guard fails closed instead of
reading part of it; contents(text, strict=False) returns the rest of the text for a reader that counts more, never
less.

EXPRESSION and STRIPPED answer the re.Pattern calls guards made on the old regexes (findall, finditer, search,
fullmatch, sub, split); STRIPPED's group(1) is the contents without surrounding whitespace, as `\\s*(.*?)\\s*` gave.
All but fullmatch raise Unterminated; fullmatch answers None (no whole expression).
tests/test_ci_expression_scans.py names any regex under scripts/ or tests/ that still scans `${{ }}` itself.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator

OPEN = "${{"
CLOSE = "}}"


class Unterminated(ValueError):
    """A `${{` with no `}}` after it outside a string literal."""

    def __init__(self, text: str, start: int) -> None:
        super().__init__(f"unterminated ${{{{ at offset {start}: {text[start:start + 80]!r}")
        self.start = start


def _end(text: str, start: int) -> int:
    """The offset of the `}}` that ends the expression opened at `start`, or -1."""
    i, quoted = start + len(OPEN), False
    while i < len(text):
        char = text[i]
        if char == "'":
            if quoted and text.startswith("''", i):
                i += 2  # an escaped quote: still inside the literal
                continue
            quoted = not quoted
        elif not quoted and text.startswith(CLOSE, i):
            return i
        i += 1
    return -1


def _spans(text: str, strict: bool) -> Iterator[tuple[int, int, int]]:
    """(start, end, contents end) of each expression; see spans()."""
    start = text.find(OPEN)
    while start != -1:
        close = _end(text, start)
        if close == -1:
            if strict:
                raise Unterminated(text, start)
            yield start, len(text), len(text)
            return
        yield start, close + len(CLOSE), close
        start = text.find(OPEN, close + len(CLOSE))


def spans(text: str, strict: bool = True) -> Iterator[tuple[int, int]]:
    """(start, end) of each whole `${{ ... }}` in `text`. An unterminated one raises Unterminated, or with
    strict=False runs to the end of the text."""
    for start, end, _ in _spans(text, strict):
        yield start, end


def contents(text: str, strict: bool = True) -> list[str]:
    """The contents of each `${{ }}` in `text` (see spans())."""
    return [text[start + len(OPEN):inner_end] for start, _, inner_end in _spans(text, strict)]


class Match:
    """One expression: group(0) is `${{ ... }}`, group(1) its contents (stripped for STRIPPED)."""

    def __init__(self, text: str, start: int, end: int, strip: bool) -> None:
        self.string, self._start, self._end = text, start, end
        inner = text[start + len(OPEN):end - len(CLOSE)]
        self._inner = inner.strip() if strip else inner

    def group(self, index: int = 0) -> str:
        if index == 0:
            return self.string[self._start:self._end]
        if index == 1:
            return self._inner
        raise IndexError("no such group")

    def __getitem__(self, index: int) -> str:
        return self.group(index)

    def groups(self) -> tuple[str]:
        return (self._inner,)

    def start(self, index: int = 0) -> int:
        return self._start

    def end(self, index: int = 0) -> int:
        return self._end

    def span(self, index: int = 0) -> tuple[int, int]:
        return self._start, self._end


class Scanner:
    def __init__(self, strip: bool) -> None:
        self.strip = strip

    def finditer(self, text: str) -> Iterator[Match]:
        for start, end in spans(text):
            yield Match(text, start, end, self.strip)

    def findall(self, text: str) -> list[str]:
        return [match.group(1) for match in self.finditer(text)]

    def search(self, text: str) -> Match | None:
        return next(self.finditer(text), None)

    def fullmatch(self, text: str) -> Match | None:
        """The one expression that is all of `text`, else None: also for text whose `${{` never ends, which is no
        whole expression (the callers' fallback for that is the one for plain text or several expressions)."""
        try:
            found = list(self.finditer(text))
        except Unterminated:
            return None
        return found[0] if len(found) == 1 and found[0].span() == (0, len(text)) else None

    def sub(self, repl: str | Callable[[Match], str], text: str) -> str:
        out, last = [], 0
        for match in self.finditer(text):
            out += [text[last:match.start()], repl(match) if callable(repl) else repl]
            last = match.end()
        return "".join(out) + text[last:]

    def split(self, text: str) -> list[str]:
        """Like re.split with one group: text, contents, text, ..."""
        out, last = [], 0
        for match in self.finditer(text):
            out += [text[last:match.start()], match.group(1)]
            last = match.end()
        return out + [text[last:]]


EXPRESSION = Scanner(strip=False)
STRIPPED = Scanner(strip=True)
