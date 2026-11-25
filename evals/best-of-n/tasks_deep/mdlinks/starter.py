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


def code_ranges(md: str) -> list[tuple[int, int]]:
    """(start, end) offsets of every code span and fenced block in `md`, in order, not overlapping."""
    ranges = []
    pos = 0
    fence_start = None
    prose_start = 0
    prose = []  # (start, end) of prose stretches between fenced blocks
    for line in md.splitlines(keepends=True):
        if line.lstrip(" ").startswith("```"):
            if fence_start is None:
                prose.append((prose_start, pos))
                fence_start = pos
            else:
                ranges.append((fence_start, pos + len(line)))
                fence_start = None
                prose_start = pos + len(line)
        pos += len(line)
    if fence_start is not None:
        ranges.append((fence_start, len(md)))
    else:
        prose.append((prose_start, len(md)))
    for start, end in prose:
        ranges.extend((start + m.start(), start + m.end()) for m in re.finditer(r"`[^`]*`", md[start:end]))
    return sorted(ranges)


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
    matches = sorted(list(LINK_RE.finditer(md)) + list(IMAGE_RE.finditer(md)), key=lambda m: m.start())
    for m in matches:
        out.append(md[pos:m.start(2)])
        out.append(fn(m.group(2)))
        pos = m.end(2)
    out.append(md[pos:])
    return "".join(out)
