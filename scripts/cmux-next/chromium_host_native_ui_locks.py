"""The fullscreen and lock rows of chromium-host-bench.py `--native-ui` (p01-process-229): a page's HTML fullscreen,
pointer lock and keyboard lock in host mode, each held by cmux while the Chromium host is never the frontmost app and
owns no visible window (CGWindowList: a window of the host's pid with alpha > 0), and each ended by Escape.

  fullscreen     a click calls requestFullscreen() on the probe's playing <video>: the video is the fullscreen
                 element (`debug.cef` `host_locks` `fullscreen`, document.fullscreenElement) with no host window,
                 and its pane zooms to fill the window; Escape ends it.
  pointer_lock   a click calls requestPointerLock(): cmux grants it (`host_locks` `pointer`, `granted` grows),
                 document.pointerLockElement is set, cmux holds the cursor (`host_locks` `cursor_held`: hidden and
                 dissociated from the mouse, so it stays in the page), and a pointer move over the page reaches the
                 page as a locked move (its mousemove count grows); Escape ends the lock and frees the cursor.

The click is `debug.mouse {"target": "page"}`, which in host mode goes through the page view's own mouse path; a
reply with an error or from another view fails the row, since the page never got the user activation.
  keyboard_lock  a click calls requestFullscreen() and navigator.keyboard.lock(['KeyT']) (Escape not locked, so one
                 press ends it): cmux grants it and, in the page's
                 fullscreen, the page gets Cmd-T (no new tab opens) while the lock holds keys (`holds_keys`); Escape
                 ends the lock and the fullscreen.

Without cmux's locks (`host_locks` null: host mode not live in this build, or chromiumHostLocks off) each row says so
and fails: it could not run.
"""
import json
import os
import time

ROWS = ("fullscreen", "pointer_lock", "keyboard_lock")
# What the app needs for these rows.
FEATURES = "chromiumHostLocks"
# How long a lock or fullscreen may take to show after the click that asks for it.
SHOW_DEADLINE_S = 10.0

PAGE = """<!doctype html><meta charset=utf-8><title>lock probe</title>
<body style="margin:0;height:100vh;background:#123">
<video id=video muted autoplay playsinline style="width:320px;height:180px"></video>
<canvas id=frames width=320 height=180 hidden></canvas>
<script>
window.moves = 0; window.keys = [];
const ask = new URLSearchParams(location.search).get('ask');
// A playing video with no file: the canvas's frames as its stream.
const frames = document.getElementById('frames'), paint = frames.getContext('2d'), video = document.getElementById('video');
let tick = 0;
(function draw() { paint.fillStyle = `hsl(${tick++ % 360} 60% 50%)`; paint.fillRect(0, 0, 320, 180); requestAnimationFrame(draw); })();
video.srcObject = frames.captureStream(30);
document.addEventListener('mousemove', () => { if (document.pointerLockElement) window.moves += 1; });
document.addEventListener('keydown', e => { window.keys.push((e.metaKey ? 'Meta+' : '') + e.key); });
document.addEventListener('mousedown', async () => {
  if (ask === 'fullscreen') await video.requestFullscreen();
  if (ask === 'keyboard') await document.documentElement.requestFullscreen();
  if (ask === 'keyboard') await navigator.keyboard.lock(['KeyT']);
  if (ask === 'pointer') document.body.requestPointerLock();
});
</script>
"""


def host_locks(rpc):
    """`debug.cef` `host_locks`: None without cmux's locks."""
    return (rpc("debug.cef") or {}).get("host_locks")


def open_probe(rpc, wait, page_eval, out, ask):
    path = os.path.join(out, "native-ui-locks.html")
    with open(path, "w") as f:
        f.write(PAGE)
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": f"file://{path}?ask={ask}"}, "focus": True,
                       "origin": "script"}, timeout=120)
    return bool(wait(lambda: page_eval("document.title") == "lock probe", 60))


class PageClickFailed(RuntimeError):
    """`debug.mouse {"target": "page"}` did not click the hosted page view."""


# The fullscreen element is the probe's video.
VIDEO_IS_FULLSCREEN = "document.fullscreenElement !== null && document.fullscreenElement.id === 'video'"
VIDEO_PLAYS = "!document.getElementById('video').paused"


def ask_by_click(rpc, wait, done):
    """Clicks the page (the user activation a lock needs) and waits for `done`; the time it took in ms, or None.
    Raises PageClickFailed when the click never went through the hosted page view (the row's error)."""
    started = time.time()
    reply = rpc("debug.mouse", {"target": "page"}) or {}
    if reply.get("error") or reply.get("view") != "ChromiumHostPageView":
        raise PageClickFailed(f"the page click missed the hosted page view: {reply}")
    return round((time.time() - started) * 1000, 1) if wait(done, SHOW_DEADLINE_S) else None


def escape_ends(rpc, wait, ended):
    rpc("debug.key", {"key": "escape"})
    return bool(wait(ended, 5))


def fullscreen_row(rpc, wait, page_eval, out, clear):
    if not open_probe(rpc, wait, page_eval, out, "fullscreen"):
        return {"ok": False, "error": "the lock probe never loaded"}
    row = {"viewport_before": page_eval("innerWidth + 'x' + innerHeight")}
    row["show_ms"] = ask_by_click(rpc, wait, lambda: (host_locks(rpc) or {}).get("fullscreen") is not None
                                  and page_eval(VIDEO_IS_FULLSCREEN))
    row["video_plays"] = bool(page_eval(VIDEO_PLAYS))
    row["viewport_fullscreen"] = page_eval("innerWidth + 'x' + innerHeight")
    row["host"] = clear()
    row["escaped"] = escape_ends(rpc, wait, lambda: page_eval("document.fullscreenElement === null")
                                 and (host_locks(rpc) or {}).get("fullscreen") is None)
    row["ok"] = row["show_ms"] is not None and row["video_plays"] and row["host"]["clear"] and row["escaped"]
    return row


def pointer_lock_row(rpc, wait, page_eval, out, clear):
    if not open_probe(rpc, wait, page_eval, out, "pointer"):
        return {"ok": False, "error": "the lock probe never loaded"}
    granted = (host_locks(rpc) or {}).get("granted") or 0
    row = {"show_ms": ask_by_click(rpc, wait, lambda: (host_locks(rpc) or {}).get("pointer") is not None
                                   and page_eval("document.pointerLockElement !== null"))}
    row["granted"] = ((host_locks(rpc) or {}).get("granted") or 0) > granted
    row["cursor_held"] = (host_locks(rpc) or {}).get("cursor_held") is True
    row["host"] = clear()
    for _ in range(5):
        rpc("debug.mouse", {"action": "move", "target": "page"})
    row["moves"] = page_eval("window.moves") or 0
    row["cursor_held_after_moves"] = (host_locks(rpc) or {}).get("cursor_held") is True
    row["escaped"] = escape_ends(rpc, wait, lambda: page_eval("document.pointerLockElement === null")
                                 and (host_locks(rpc) or {}).get("pointer") is None)
    row["cursor_freed"] = (host_locks(rpc) or {}).get("cursor_held") is False
    row["ok"] = row["show_ms"] is not None and row["granted"] and row["cursor_held"] and row["host"]["clear"] and \
        row["moves"] > 0 and row["cursor_held_after_moves"] and row["escaped"] and row["cursor_freed"]
    return row


def tab_count(rpc):
    windows = (rpc("debug.focus") or {}).get("windows") or []
    return sum(len(p.get("tabs") or []) for p in (windows[0].get("topology") or [])) if windows else 0


def keyboard_lock_row(rpc, wait, page_eval, out, clear):
    if not open_probe(rpc, wait, page_eval, out, "keyboard"):
        return {"ok": False, "error": "the lock probe never loaded"}
    row = {"show_ms": ask_by_click(rpc, wait, lambda: (host_locks(rpc) or {}).get("holds_keys") is True)}
    row["host"] = clear()
    tabs = tab_count(rpc)
    rpc("debug.key", {"key": "t", "modifiers": ["cmd"]})
    row["page_got_cmd_t"] = bool(wait(lambda: "Meta+t" in (page_eval("window.keys") or []), 5))
    time.sleep(0.5)  # test harness: a new tab that cmux opened despite the lock would show within this
    row["no_new_tab"] = tab_count(rpc) == tabs
    row["escaped"] = escape_ends(rpc, wait, lambda: (host_locks(rpc) or {}).get("keyboard") is None
                                 and page_eval("document.fullscreenElement === null"))
    row["ok"] = row["show_ms"] is not None and row["host"]["clear"] and row["page_got_cmd_t"] and row["no_new_tab"] and \
        row["escaped"]
    return row


RUNNERS = {"fullscreen": fullscreen_row, "pointer_lock": pointer_lock_row, "keyboard_lock": keyboard_lock_row}


def run(rpc, wait, page_eval, out, clear, rows_to_run=ROWS, on_row=lambda name, row: row):
    """The rows of `rows_to_run`, in ROWS order; `clear()` is chromium_host_native_ui_dialogs.host_ui_clear for the
    running host. `on_row(name, row)` runs right after each row and returns the row to keep (the bench adds the host's
    window lines the row caused, p01-process-068). Returns (rows, ok)."""
    rows = {}
    for name in ROWS:
        if name not in rows_to_run:
            continue
        if host_locks(rpc) is None:
            row = {"ok": False, "not_run": "no cmux locks: host mode is not live in this build or chromiumHostLocks is off"}
        else:
            try:
                row = RUNNERS[name](rpc, wait, page_eval, out, clear)
            except Exception as error:  # noqa: BLE001 - a row's failure is that row's result
                row = {"ok": False, "error": f"{type(error).__name__}: {error}"[:300]}
        rows[name] = on_row(name, row)
    return rows, bool(rows) and all(row.get("ok") for row in rows.values())


if __name__ == "__main__":
    print(json.dumps({"rows": ROWS, "features": FEATURES}))
