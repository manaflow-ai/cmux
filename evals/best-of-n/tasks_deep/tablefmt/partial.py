"""Plain-text tables for `cmux ls`, `cmux agents` and the `--table` output of other list commands.

    NAME        STATUS   AGE
    ----------  -------  ---
    build-mac   running  3m
    日本語の作業  idle     12h

Columns are sized to their widest cell, optionally capped; a cell wider than its column is cut with an ellipsis.
"""
import unicodedata

ELLIPSIS = "…"


def cell_text(value) -> str:
    """The text a cell shows: None is empty, everything else is `str(value)`, newlines become spaces."""
    if value is None:
        return ""
    return str(value).replace("\r\n", " ").replace("\n", " ")


def text_width(text: str) -> int:
    """Terminal cells `text` takes: wide and fullwidth characters take 2, combining marks 0, the rest 1."""
    width = 0
    for ch in text:
        if unicodedata.combining(ch):
            continue
        width += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return width


def clip(text: str, width: int) -> str:
    """`text` if it fits `width` cells, else its longest prefix that fits with an ellipsis after it."""
    if len(text) <= width:
        return text
    if width <= 0:
        return ""
    return text[:width - 1] + ELLIPSIS


def pad(text: str, width: int, align: str = "l") -> str:
    """`text` padded with spaces to `width` cells: "l" left, "r" right, "c" centre (odd space on the right)."""
    gap = max(0, width - text_width(text))
    if align == "r":
        return " " * gap + text
    if align == "c":
        return " " * (gap // 2) + text + " " * (gap - gap // 2)
    return text + " " * gap


def column_widths(headers, rows, max_width=None) -> list[int]:
    """Each column's width: its widest cell (header included), capped at `max_width` when given."""
    widths = [text_width(cell_text(h)) for h in headers]
    for row in rows:
        for i, value in enumerate(row):
            widths[i] = max(widths[i], text_width(cell_text(value)))
    if max_width is not None:
        widths = [min(w, max_width) for w in widths]
    return widths


def normalize_rows(headers, rows) -> list[list]:
    """Rows padded with None (or cut) to the header's length."""
    n = len(headers)
    return [list(row)[:n] + [None] * (n - len(row)) for row in rows]


def render(headers, rows, align=None, max_width=None, sep="  ", rule="-") -> str:
    """The table as text: a header line, a rule line (`rule` repeated to each column's width, omitted when `rule`
    is empty), then one line per row. Columns are joined by `sep`; trailing spaces are stripped from every line.
    `align` is a string or list of "l"/"r"/"c" per column (default all "l"); the header follows its column's
    alignment."""
    rows = normalize_rows(headers, rows)
    aligns = list(align) if align else ["l"] * len(headers)
    aligns += ["l"] * (len(headers) - len(aligns))
    widths = column_widths(headers, rows, max_width)

    def line(values):
        cells = [pad(clip(cell_text(v), w), w, a) for v, w, a in zip(values, widths, aligns)]
        return sep.join(cells).rstrip()

    out = [line(headers)]
    if rule:
        out.append(sep.join(rule * w for w in widths).rstrip())
    out.extend(line(row) for row in rows)
    return "\n".join(out)


def render_records(records, columns, **kwargs) -> str:
    """`render` over dicts: `columns` is a list of (header, key) pairs; a missing key is an empty cell."""
    headers = [h for h, _ in columns]
    rows = [[rec.get(k) for _, k in columns] for rec in records]
    return render(headers, rows, **kwargs)
