"""The Chromium Host's window lines in cmux's app log, counted per --native-ui row of chromium-host-bench.py (task
p01-process-068 of plans/cmux-next/chrome-parity/p01-process.md).

The host (ChromiumHost/src/host_blocked_widgets.h) writes a line for each Chromium widget the fork blocked (fork API
31, cmux_set_blocked_widget_handler) once its dismissal ran, and one more if a refused widget hides later:

  cmux-chromium-host: BLOCKED_WIDGET browser=7 widget=11 kind=0 class=JavaScriptTabModalDialogViewViews
      rect=10,20,300,120 visible=1 owner=js-dialog action=dismissed

and one per host window its backstop found on screen and took off it:

  cmux-chromium-host: UNEXPECTED_WINDOW class=NSPanel title=1a2b3c4d action=ordered-out

A widget reaches the host only when no cmux UI took its request first (owner= names the cmux UI of its kind). The host
dismisses it as Chrome's Escape does, except a permission prompt: Escape on it is a recorded dismissal that counts
toward the origin's embargo (PermissionDecisionAutoBlocker), so the host holds it (action held) until Chromium ends it.

The bench adds what the window server shows at the row's end: the host's on-screen windows with alpha above 0
(on_screen_windows of the host pid), so a window the host's backstop missed still fails its row.

A row passes this check with 0 unexpected windows, no host window on screen, and every blocked widget's last line in
it a logged dismissal (action dismissed) or a hide before the dismissal ran (gone). A widget that still shows (refused,
close-failed, held) keeps its page waiting on a request no one sees: that fails the row.
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
    """A blocked widget line the acceptance allows: a logged dismissal, or a hide before the dismissal ran."""
    return widget.get("action") in ("dismissed", "gone")


def count(lines, on_screen=()):
    """The window block of one row from its log lines: blocked widgets by class, the unhandled ones, unexpected windows.
    A widget with two lines (refused, then dismissed when it hid at last) counts once, by its last line; one that was
    held stays unhandled after Chromium ended it (no one saw the request). `on_screen`: the host's visible windows the
    bench read at the row's end (visible()), None when they could not be read, which fails too: nothing shows the
    screen clear."""
    latest, held, unexpected = {}, set(), []
    for line in lines:
        record = parse(line)
        if record is None:
            continue
        if record["what"] == "BLOCKED_WIDGET":
            key = (record.get("browser"), record.get("widget"))
            latest.pop(key, None)  # re-inserted: the widgets stay in the order of their last line
            latest[key] = record
            if record.get("action") == "held":
                held.add(key)
        else:
            unexpected.append(record)
    blocked = list(latest.values())
    by_class = {}
    for widget in blocked:
        name = widget.get("class", "-")
        by_class[name] = by_class.get(name, 0) + 1
    unhandled = [widget for key, widget in latest.items() if key in held or not handled(widget)]
    shown = None if on_screen is None else list(on_screen)
    return {
        "blocked_widgets": len(blocked),
        "blocked_by_class": by_class,
        "blocked_by_owner": _tally(blocked, "owner"),
        "unhandled_widgets": unhandled,
        "unexpected_windows": len(unexpected),
        "unexpected": unexpected,
        "on_screen_windows": shown,
        "ok": not unexpected and not unhandled and shown == [],
    }


def visible(windows):
    """The windows of the bench's on_screen_windows(pid) a person can see (alpha above 0); None stays None."""
    return None if windows is None else [window for window in windows if (window.get("alpha") or 0) > 0]


def summary(block):
    """Why `block` fails, in one line."""
    shown = block["on_screen_windows"]
    screen = "the host's windows could not be read" if shown is None else f"{len(shown)} host windows on screen"
    return (f"{block['unexpected_windows']} unexpected host windows, {screen}, "
            f"{len(block['unhandled_widgets'])} blocked widgets with no dismissal")


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


def checked(row, lines, on_screen=()):
    """`row` with its "host_windows" block from `lines` and `on_screen` (count's); a row that passed fails when the
    block does."""
    block = count(lines, on_screen)
    row = dict(row)
    row["host_windows"] = block
    if row.get("ok") and not block["ok"]:
        row["ok"] = False
        row["host_windows_failed"] = summary(block)
    return row


def failing(rows):
    """`(name, reason)` for each failing row of a native-ui result, in its order; a skipped row (another task's,
    chromium_host_native_ui_choosers.skipped) is not failing."""
    out = []
    for name, row in rows.items():
        if row.get("ok") or "skipped" in row:
            continue
        reason = (row.get("host_windows_failed") or row.get("not_run") or row.get("error") or
                  row.get("reason") or "row checks failed")
        out.append((name, str(reason)[:300]))
    return out
