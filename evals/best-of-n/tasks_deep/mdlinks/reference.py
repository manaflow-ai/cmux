"""Link handling for markdown in the agent chat pane and in rendered READMEs.

Finds inline links `[text](url)`, images `![alt](src)` and autolinks `<https://...>`, and rewrites link targets
(for example to make repo-relative links absolute). Nothing inside code is a link: code is a CommonMark code span
(a run of N backticks up to the next run of exactly N backticks; an unmatched run is plain text) or a fenced code
block (a line of 3+ backticks or 3+ tildes indented at most 3 spaces, up to a line of the same character at least
as long with nothing else on it, or to the end of the document). Code is returned and rewritten as it is.
"""
import re

LINK_RE = re.compile(r"(?<!\!)\[([^\[\]]*)\]\(([^()\s]*)(?:\s+\"([^\"]*)\")?\)")
IMAGE_RE = re.compile(r"\!\[([^\[\]]*)\]\(([^()\s]*)(?:\s+\"([^\"]*)\")?\)")
AUTOLINK_RE = re.compile(r"<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\s]*)>")
_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")


def code_ranges(md: str) -> list[tuple[int, int]]:
    """(start, end) offsets of every code span and fenced block in `md`, in order, not overlapping."""
    ranges = []
    lines = md.splitlines(keepends=True)
    pos = 0
    fence = None  # (char, length, start offset) while inside a fenced block
    prose_start = 0
    prose = []  # (start, end) of prose stretches between fenced blocks
    for line in lines:
        if fence is None:
            m = _FENCE_OPEN.match(line)
            if m and not (m.group(1)[0] == "`" and "`" in line[m.end():]):
                prose.append((prose_start, pos))
                fence = (m.group(1)[0], len(m.group(1)), pos)
        else:
            char, length, start = fence
            stripped = line.strip()
            if (len(line) - len(line.lstrip(" ")) <= 3 and len(stripped) >= length
                    and stripped == char * len(stripped)):
                ranges.append((start, pos + len(line)))
                fence = None
                prose_start = pos + len(line)
        pos += len(line)
    if fence is not None:
        ranges.append((fence[2], len(md)))
    else:
        prose.append((prose_start, len(md)))
    for start, end in prose:
        ranges.extend(_span_ranges(md, start, end))
    return sorted(ranges)


def _span_ranges(md: str, start: int, end: int) -> list[tuple[int, int]]:
    out = []
    runs = [(m.start(), m.end()) for m in re.finditer(r"`+", md[start:end])]
    i = 0
    while i < len(runs):
        a, b = runs[i]
        n = b - a
        for j in range(i + 1, len(runs)):
            c, d = runs[j]
            if d - c == n:
                out.append((start + a, start + d))
                i = j + 1
                break
        else:
            i += 1
    return out


def _outside_code(md: str, regex: re.Pattern):
    ranges = code_ranges(md)
    for m in regex.finditer(md):
        if not any(s <= m.start() < e or s < m.end() <= e for s, e in ranges):
            yield m


def find_links(md: str) -> list[tuple[str, str]]:
    """(text, url) of each inline link outside code, in document order. Images are not links."""
    return [(m.group(1), m.group(2)) for m in _outside_code(md, LINK_RE)]


def find_images(md: str) -> list[tuple[str, str]]:
    """(alt, src) of each image outside code, in document order."""
    return [(m.group(1), m.group(2)) for m in _outside_code(md, IMAGE_RE)]


def find_autolinks(md: str) -> list[str]:
    """The URL of each autolink outside code, in document order."""
    return [m.group(1) for m in _outside_code(md, AUTOLINK_RE)]


def all_urls(md: str) -> list[str]:
    """Every link, image and autolink target outside code, in document order, without duplicates."""
    found = []
    for regex, group in ((LINK_RE, 2), (IMAGE_RE, 2), (AUTOLINK_RE, 1)):
        found.extend((m.start(), m.group(group)) for m in _outside_code(md, regex))
    seen, out = set(), []
    for _, url in sorted(found):
        if url not in seen:
            seen.add(url)
            out.append(url)
    return out


def rewrite_links(md: str, fn) -> str:
    """`md` with each inline link's and image's url replaced by `fn(url)`; text, titles and code unchanged."""
    out = []
    pos = 0
    matches = sorted(list(_outside_code(md, LINK_RE)) + list(_outside_code(md, IMAGE_RE)), key=lambda m: m.start())
    for m in matches:
        out.append(md[pos:m.start(2)])
        out.append(fn(m.group(2)))
        pos = m.end(2)
    out.append(md[pos:])
    return "".join(out)
