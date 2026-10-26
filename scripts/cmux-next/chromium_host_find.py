"""The `--find` rows of chromium-host-bench.py (p01-process-048): find in a Chromium page whose browser runs in the
Chromium Host (`debug.cef` backend `host`: the bench's tunables turn `browserHost.helper` on, which makes the host
the backend of a Debug or bench build), through cmux's find pill and the person's keys. Cmd-F opens the pill, the
query is typed into it a key at a time, Cmd-G and Cmd-Shift-G step, Escape closes. cmux sends each search as the
shim's `find` op and Clear Find as `stop_finding`; Chromium's FIND_RESULT events carry the find id back, and the
pill shows them. The pill's state is the oracle's `overlays.findBar` (the chrome's BrowserFindModel); the page's
scroll position comes from the page.

  open      Cmd-F opens the pill
  count     typing `needle` ends at the page's 4 matches with one active. Every key starts a new search, and each
            shorter prefix matches more of the page, so a result of an earlier search that stayed (it was on the
            wire when the next search left cmux) shows a wrong count
  next      Cmd-G steps to the next match each time (one forward, wrapping) up to the last one, far down the page,
            and the page scrolls to it: Chromium shows the active match in the host page
  previous  Cmd-Shift-G steps back to the third match, at the top, and the page scrolls back
  close     Escape closes the pill

Each row passes or fails on its own and records how long its last change took to show (`show_ms`, from the key that
caused it, polled every POLL_S). Without the host backend every row says so and the mode fails: it could not run.
"""
import time

QUERY = "needle"
MATCHES = 4
# The last match is far below the first screen; the third is on it.
FAR_Y = 4000
SCROLLED_Y = 1500

# Each prefix of QUERY matches more of the page than QUERY itself ("needl" matches the lone "needl" too).
PAGE = f"""<!doctype html><meta charset=utf-8><title>find probe</title>
<style>body{{margin:0;font:20px system-ui;background:#fff;color:#000}} p{{margin:40px}}</style>
<p>nine nectar needy needed needl needle neon needle needle</p>
<div style="height:{FAR_Y}px"></div>
<p id=far>needle</p>
"""

# How long one change may take to show in the pill or the page.
DEADLINE_S = 10.0
POLL_S = 0.02
ROWS = ("open", "count", "next", "previous", "close")


def find_bar(rpc):
    """The oracle's `overlays.findBar` ({open, pane, querySha256, matches, selected}), or {} when unreadable."""
    snapshot = rpc("debug.oracle.snapshot", {"facets": ["overlays"]}) or {}
    return ((snapshot.get("overlays") if isinstance(snapshot, dict) else None) or {}).get("findBar") or {}


def run(rpc, wait, page_eval, url):
    """Every row; returns (rows, ok)."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        reason = f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or browserHost.helper off)"
        return {name: {"ok": False, "not_run": reason} for name in ROWS}, False
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
                 timeout=120)
    if not wait(lambda: page_eval("document.readyState === 'complete' && !!document.getElementById('far')"), 60, 0.5):
        return {"error": f"the probe never loaded: {str(opened)[:200]}"}, False
    rows = {}

    def key(name, *modifiers):
        rpc("debug.key", {"key": name, **({"modifiers": list(modifiers)} if modifiers else {})})
        return time.time()

    def shown(sent, check):
        """Waits for `check(find_bar)`; the row's reading and when it showed."""
        bar = wait(lambda: (lambda b: b if check(b) else None)(find_bar(rpc)), DEADLINE_S, POLL_S)
        return {"ok": bar is not None, "find_bar": bar or find_bar(rpc),
                "show_ms": round((time.time() - sent) * 1000, 1) if bar is not None else None}

    def scroll_y():
        return page_eval("Math.round(window.scrollY)")

    def scrolled(far_down):
        """Waits for the page to scroll below (or back above) SCROLLED_Y; the position it read last."""
        def check():
            y = scroll_y()
            ok = isinstance(y, (int, float)) and (y > SCROLLED_Y if far_down else y < SCROLLED_Y)
            return {"y": y} if ok else None
        reading = wait(check, DEADLINE_S, POLL_S)
        return reading is not None, (reading or {"y": scroll_y()})["y"]

    rows["open"] = shown(key("f", "cmd"), lambda b: b.get("open") is True)
    if not rows["open"]["ok"]:
        return {**rows, **{name: {"ok": False, "not_run": "the find pill did not open"} for name in ROWS[1:]}}, False

    sent = None
    for letter in QUERY:
        sent = key(letter)
    rows["count"] = shown(sent, lambda b: b.get("matches") == MATCHES and b.get("selected") is not None)

    # Forward to the last match, one step per Cmd-G (at most one lap).
    steps = []
    selected = rows["count"]["find_bar"].get("selected")
    for _ in range(MATCHES):
        if selected == MATCHES - 1 or selected is None:
            break
        expected = (selected + 1) % MATCHES
        step = shown(key("g", "cmd"), lambda b, want=expected: b.get("selected") == want)
        steps.append({"expected": expected, **step})
        selected = step["find_bar"].get("selected") if step["ok"] else None
    far, far_y = scrolled(True)
    rows["next"] = {"ok": selected == MATCHES - 1 and all(s["ok"] for s in steps) and far, "steps": steps, "scroll_y": far_y}

    back = shown(key("g", "cmd", "shift"), lambda b: b.get("selected") == MATCHES - 2)
    top, top_y = scrolled(False)
    rows["previous"] = {**back, "ok": back["ok"] and top, "scroll_y": top_y}

    rows["close"] = shown(key("escape"), lambda b: b.get("open") is False)
    return rows, all(row.get("ok") for row in rows.values())
