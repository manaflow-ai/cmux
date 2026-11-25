"""R3a, the content half (cmux-ad 2026-10-31, fuzz rows d/e findings e1, e2): after a resize (and after any
reattach), the screen the app's view shows must equal the daemon terminal's screen, row by row.

The size checks (grid == fit(bounds) == PTY == daemon) pass while a view that restored a wrong replay or snapshot
shows other content: VT fuzz finding e2 draws the last row 43 columns to the right after a resize, e1 loses a
soft-wrapped cell. This module is the shared comparison, so every harness judges the same way:
  - the smoke gate's R3a step and the action fuzzer (scripts/journeys ext_smoke.py / ext_fuzz.py, row m),
  - a DEBUG in-app check (port `rows`/`difference` to Swift; same rules),
  - any Rust or Python harness that has the two texts.

Inputs are the two texts the public reads give:
  - daemon: `cmux terminal <term> screen read` -> {"text", "cols", "rows", "revision", ...}; its text is PHYSICAL
    rows (one line per grid row, soft wraps already split);
  - view: `debug.surfaces` {"text": true} -> the pane's "text"; it is LOGICAL lines (soft-wrapped rows joined).
Both are cut into physical rows at the grid's column count by display width (wide = 2 cells, combining = 0),
trailing blanks of each row and trailing blank rows dropped, then compared row by row. Text only: styles and the
cursor are not in both reads (the cursor is checked when the caller passes both).

`settled_difference(read_daemon, read_view, cols)` reads daemon, view, daemon again and judges only when the two
daemon reads have the same revision (no output landed between the reads); else it retries, and after `tries` it
returns a NOVERDICT result instead of a false FAIL.
"""
import time
import unicodedata


def _cell_width(ch):
    if unicodedata.combining(ch) or ch in "‍︎️" or unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def rows(text, cols):
    """`text` cut into physical rows of at most `cols` cells; each row right-trimmed; trailing blank rows dropped."""
    cols = max(1, int(cols))
    out = []
    for line in (text or "").split("\n"):
        row, used = [], 0
        for ch in line:
            width = _cell_width(ch)
            if used + width > cols and used > 0:
                out.append("".join(row).rstrip())
                row, used = [], 0
            row.append(ch)
            used += width
        out.append("".join(row).rstrip())
    while out and not out[-1]:
        out.pop()
    return out


def difference(daemon_text, view_text, cols, daemon_cursor=None, view_cursor=None):
    """None when the view shows the daemon's screen; else {"row", "daemon", "view", "daemon_rows", "view_rows"}
    for the first differing row (or {"cursor": ...} when only the cursors differ)."""
    want, have = rows(daemon_text, cols), rows(view_text, cols)
    for index in range(max(len(want), len(have))):
        a = want[index] if index < len(want) else ""
        b = have[index] if index < len(have) else ""
        if a != b:
            return {"row": index, "daemon": a, "view": b, "daemon_rows": len(want), "view_rows": len(have)}
    if daemon_cursor is not None and view_cursor is not None and tuple(daemon_cursor) != tuple(view_cursor):
        return {"cursor": {"daemon": list(daemon_cursor), "view": list(view_cursor)}}
    return None


def settled_difference(read_daemon, read_view, cols=None, tries=5, pause=0.2):
    """Judge one terminal: `read_daemon()` -> the screen read dict, `read_view()` -> the view's text.
    Returns {"verdict": "PASS"|"FAIL"|"NOVERDICT", "difference": ..., "tries": n}."""
    for attempt in range(1, tries + 1):
        first = read_daemon()
        view = read_view()
        second = read_daemon()
        if first.get("revision") is not None and first.get("revision") == second.get("revision"):
            width = cols or second.get("cols")
            diff = difference(second.get("text"), view, width)
            return {"verdict": "FAIL" if diff else "PASS", "difference": diff, "tries": attempt, "cols": width}
        time.sleep(pause)
    return {"verdict": "NOVERDICT", "difference": None, "tries": tries,
            "reason": "the daemon screen kept changing between reads (output still arriving)"}
