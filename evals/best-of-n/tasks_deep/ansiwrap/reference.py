"""Width-aware text helpers for the status bar and the agent transcript pane.

Text that reaches the terminal may carry SGR colour codes and other CSI escape sequences, and may hold East Asian
wide characters (CJK, fullwidth forms, most emoji) that take two cells. Everything here works in terminal cells.
"""
import re
import unicodedata

# A CSI sequence: ESC [ parameter bytes, intermediate bytes, one final byte. OSC: ESC ] ... BEL or ESC \.
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
ELLIPSIS = "…"


def strip_ansi(text: str) -> str:
    """`text` without its escape sequences."""
    return ANSI_RE.sub("", text)


def char_width(ch: str) -> int:
    """Cells one code point takes: 0 for combining marks and controls, 2 for wide/fullwidth, else 1."""
    if unicodedata.combining(ch) or unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    if ord(ch) < 32 or 0x7F <= ord(ch) < 0xA0:
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def display_width(text: str) -> int:
    """Cells `text` takes on screen."""
    return sum(char_width(ch) for ch in strip_ansi(text))


def tokens(text: str):
    """(piece, is_escape) pairs: each escape sequence whole, every other code point on its own."""
    pos = 0
    for m in ANSI_RE.finditer(text):
        for ch in text[pos:m.start()]:
            yield ch, False
        yield m.group(0), True
        pos = m.end()
    for ch in text[pos:]:
        yield ch, False


def _take(text: str, width: int) -> tuple[str, str]:
    """Split `text` into the longest head that fits `width` cells and the rest. Escape sequences stay whole and go
    with the head while it still has room for what follows them."""
    head = []
    used = 0
    toks = list(tokens(text))
    for i, (piece, esc) in enumerate(toks):
        if esc:
            head.append(piece)
            continue
        w = char_width(piece)
        if used + w > width:
            rest = "".join(p for p, _ in toks[i:])
            return "".join(head), rest
        head.append(piece)
        used += w
    return "".join(head), ""


def pad(text: str, width: int, align: str = "left") -> str:
    """`text` padded with spaces to `width` cells. Text already that wide or wider is returned unchanged.
    `align` is "left", "right" or "center" (an odd leftover space goes on the right)."""
    gap = width - display_width(text)
    if gap <= 0:
        return text
    if align == "right":
        return " " * gap + text
    if align == "center":
        left = gap // 2
        return " " * left + text + " " * (gap - left)
    return text + " " * gap


def truncate(text: str, width: int, ellipsis: str = ELLIPSIS) -> str:
    """`text` if it fits in `width` cells, else its longest head that fits together with `ellipsis`."""
    if display_width(text) <= width:
        return text
    room = width - display_width(ellipsis)
    if room <= 0:
        return _take(ellipsis, width)[0]
    head, _ = _take(text, room)
    return head + ellipsis


def fit(text: str, width: int, align: str = "left") -> str:
    """Exactly `width` cells: truncated if too long, padded if too short."""
    return pad(truncate(text, width), width, align)


def wrap(text: str, width: int) -> list[str]:
    """Greedy word wrap of `text` into lines of at most `width` cells. Words are split on spaces; a word wider than
    `width` is broken across lines. Runs of spaces between words collapse to one."""
    if width < 1:
        raise ValueError("width must be at least 1")
    lines: list[str] = []
    line = ""
    line_w = 0
    for word in text.split():
        w = display_width(word)
        if line and line_w + 1 + w <= width:
            line += " " + word
            line_w += 1 + w
            continue
        if line:
            lines.append(line)
            line, line_w = "", 0
        while w > width:
            head, word = _take(word, width)
            if not strip_ansi(head):
                # a single character wider than the line: put it on its own line
                head, word = _take(word, display_width(word))[0][:1], word[1:]
            lines.append(head)
            w = display_width(word)
        line, line_w = word, w
    if line:
        lines.append(line)
    return lines


def status_line(left: str, right: str, width: int) -> str:
    """One `width`-cell status bar: `left` flush left, `right` flush right, `left` truncated if both do not fit."""
    room = width - display_width(right) - 1
    if room < 1:
        return fit(right, width, "right")
    return fit(left, room) + " " + right
