"""The Chromium Host's window lines in cmux's app log, counted per --native-ui row of chromium-host-bench.py (task
p01-process-068 of plans/cmux-next/chrome-parity/p01-process.md).

The host (ChromiumHost/src/host_blocked_widgets.h) writes one line per Chromium widget the fork blocked (fork API 31,
cmux_set_blocked_widget_handler) and dismissed:

  cmux-chromium-host: BLOCKED_WIDGET browser=7 widget=11 kind=0 class=JavaScriptTabModalDialogViewViews
      rect=10,20,300,120 visible=1 owner=js-dialog action=dismissed

and one per host window its backstop found on screen and took off it:

  cmux-chromium-host: UNEXPECTED_WINDOW class=NSPanel title=1a2b3c4d action=ordered-out

A row passes this check with 0 unexpected windows and every blocked widget either dismissed (a logged dismissal) or
of a kind a cmux UI owns (owner other than none). A widget whose dismissal was refused with no owner keeps its page
waiting on a dialog no one sees: that fails the row.
"""
import os
import re

LINE = re.compile(r"\b(BLOCKED_WIDGET|UNEXPECTED_WINDOW)((?: [a-z_]+=\S*)+)")
FIELD = re.compile(r" ([a-z_]+)=(\S*)")


def parse(line):
    """The host line in `line` as {"what": "BLOCKED_WIDGET" | "UNEXPECTED_WINDOW", field: value...}, or None."""
    found = LINE.search(line)
    if not found:
        return None
    record = {"what": found.group(1)}
    record.update(FIELD.findall(found.group(2)))
    return record


def handled(widget):
    """A blocked widget the acceptance allows: dismissed (or gone by itself) with a logged line, or owned by a cmux UI."""
    return widget.get("action") in ("dismissed", "gone") or widget.get("owner", "none") != "none"


def count(lines):
    """The window block of one row from its log lines: blocked widgets by class, the unhandled ones, unexpected windows."""
    blocked, unexpected = [], []
    for line in lines:
        record = parse(line)
        if record is None:
            continue
        (blocked if record["what"] == "BLOCKED_WIDGET" else unexpected).append(record)
    by_class = {}
    for widget in blocked:
        name = widget.get("class", "-")
        by_class[name] = by_class.get(name, 0) + 1
    unhandled = [widget for widget in blocked if not handled(widget)]
    return {
        "blocked_widgets": len(blocked),
        "blocked_by_class": by_class,
        "blocked_by_owner": _tally(blocked, "owner"),
        "unhandled_widgets": unhandled,
        "unexpected_windows": len(unexpected),
        "unexpected": unexpected,
        "ok": not unexpected and not unhandled,
    }


def _tally(records, field):
    out = {}
    for record in records:
        key = record.get(field, "none")
        out[key] = out.get(key, 0) + 1
    return out


class LogCursor:
    """The app log from a point on: `take()` gives the lines written since the last take (or since it was made)."""

    def __init__(self, path):
        self.path = path
        self.offset = self._size()

    def _size(self):
        try:
            return os.path.getsize(self.path) if self.path else 0
        except OSError:
            return 0

    def take(self):
        try:
            with open(self.path, "rb") as log:
                log.seek(self.offset)
                data = log.read()
        except (OSError, TypeError):
            return []
        # Only whole lines: a line still being written is read by the next take.
        end = data.rfind(b"\n") + 1
        self.offset += end
        return data[:end].decode("utf-8", errors="replace").splitlines()


def checked(row, lines):
    """`row` with its "host_windows" block from `lines`; a row that passed fails when the block does."""
    block = count(lines)
    row = dict(row)
    row["host_windows"] = block
    if row.get("ok") and not block["ok"]:
        row["ok"] = False
        row["host_windows_failed"] = (f"{block['unexpected_windows']} unexpected host windows, "
                                      f"{len(block['unhandled_widgets'])} blocked widgets with no owner or dismissal")
    return row


def failing(rows):
    """`(name, reason)` for each failing row of a native-ui result, in its order."""
    out = []
    for name, row in rows.items():
        if not isinstance(row, dict):  # the rows' own failure to start: {"error": "the probe never loaded: ..."}
            out.append((name, str(row)[:300]))
            continue
        if row.get("ok"):
            continue
        reason = (row.get("host_windows_failed") or row.get("not_run") or row.get("error") or
                  row.get("reason") or "row checks failed")
        out.append((name, str(reason)[:300]))
    return out
