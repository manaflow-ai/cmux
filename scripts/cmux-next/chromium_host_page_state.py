"""The page state row of chromium-host-bench.py `--kill-host` (p01-process-093): after a SIGKILL of the Chromium Host,
a Chromium tab comes back with its page state (scroll offset and typed form text), not only at its address, as
Chrome restores a crashed tab's `SerializedNavigationEntry::encoded_page_state`. Runs with features
chromiumPageStateRestore (the tab keeps and restores each entry's page state) and chromiumHostRestoreTabs (task 083:
the app starts a new host at once and brings the tab back on it).

The row opens PAGE (a tall page with one text field) in a Chromium tab, types TYPED into the field a key at a time
(`debug.key`, the person's keys, so the field's value is a user edit Blink saves in the form state), scrolls to
SCROLL_Y, waits past the renderer's page state sync (about 1 s), the host's idle push (1 s) and the history write,
SIGKILLs the host and checks:

  back      the tab is at its address again, loaded, within BACK_TIMEOUT_S (`back_ms`)
  scroll    `scrollY` is SCROLL_Y again (within SCROLL_SLACK_PX), within RESTORE_TIMEOUT_S of the load
  form      the field's value is TYPED again

Pass: back, scroll and form. A build whose backend is not the host says not_run and the row fails: it could not run.
"""
import json

FEATURES ="chromiumHostRestoreTabs,chromiumPageStateRestore"
TYPED = "typed"
SCROLL_Y = 1200
SCROLL_SLACK_PX = 2
# The renderer syncs a scroll or an edit to the browser after about 1 s (content's kDelaySecondsForContentStateSync),
# the host pushes it at its idle (1 s, host_page_state.h) and the history writer saves it after its debounce.
SETTLE_S = 3.5
# Generous: a row that waits this long has failed.
LOAD_TIMEOUT_S = 60
BACK_TIMEOUT_S = 20
RESTORE_TIMEOUT_S = 5

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>page state</title></head>
<body style="margin:0; height:6000px">
<input id="field" autocomplete="off" style="font-size:16px">
<div style="position:absolute; top:5800px">end</div>
</body></html>
"""

LOADED = "document.readyState === 'complete' && !!document.getElementById('field')"
READ = "JSON.stringify({y: Math.round(window.scrollY), value: document.getElementById('field').value})"


def read(page_eval, tab):
    """{"y": scrollY, "value": the field's value} of the page in `tab`, or None when it does not answer."""
    raw = page_eval(READ, tab)
    try:
        return json.loads(raw) if isinstance(raw, str) else None
    except ValueError:
        return None


def restored(state):
    return bool(state) and abs(state.get("y", -1) - SCROLL_Y) <= SCROLL_SLACK_PX and state.get("value") == TYPED


def run(rpc, wait, page_eval, focused_eval, url, host_pids, kill, clock, sleep):
    """The row; returns (row, ok). `url` is PAGE's address; `page_eval(script, tab)` is the value of `script` in that
    tab; `focused_eval(script)` is (value, tab id) in the focused page; `host_pids()` lists the app's Chromium Host
    pids; `kill(pid)` sends SIGKILL; `clock()` is seconds and `sleep(seconds)` waits."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        return {"not_run": f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or "
                           "browserHost.helper off)", "pass": False}, False
    row = {"backend": backend, "url": url}
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
        timeout=120)
    tab = wait(lambda: (lambda value, tab: tab if value is True and tab else None)(*focused_eval(LOADED)),
               LOAD_TIMEOUT_S, 0.5)
    if not tab:
        row["error"] = f"the page never loaded {url}"
        row["pass"] = False
        return row, False
    row["tab"] = tab
    page_eval("document.getElementById('field').focus(), true", tab)
    for key in TYPED:
        rpc("debug.key", {"target": "page", "key": key})
    page_eval(f"window.scrollTo(0, {SCROLL_Y}), true", tab)
    before = wait(lambda: (lambda state: state if restored(state) else None)(read(page_eval, tab)), 10, 0.1)
    row["before"] = before
    if not before:
        row["error"] = "the page never showed the typed text at the scroll offset before the kill"
        row["pass"] = False
        return row, False
    sleep(SETTLE_S)
    killed = host_pids()
    if len(killed) != 1:
        row["error"] = f"expected one Chromium Host before the kill, found {killed}"
        row["pass"] = False
        return row, False
    row["killed_host"] = killed[0]
    started = clock()
    kill(killed[0])
    back = wait(lambda: page_eval(f"location.href === {url!r} && {LOADED}", tab) is True, BACK_TIMEOUT_S, 0.02)
    row["back"] = bool(back)
    row["back_ms"] = round((clock() - started) * 1000, 1) if back else None
    after = None
    if back:
        loaded = clock()
        after = wait(lambda: (lambda state: state if restored(state) else None)(read(page_eval, tab)),
                     RESTORE_TIMEOUT_S, 0.05)
        row["restore_ms"] = round((clock() - loaded) * 1000, 1) if after else None
        after = after or read(page_eval, tab)
    row["after"] = after
    row["scroll"] = bool(after) and abs(after.get("y", -1) - SCROLL_Y) <= SCROLL_SLACK_PX
    row["form"] = bool(after) and after.get("value") == TYPED
    hosts = host_pids()
    row["new_host"] = len(hosts) == 1 and hosts[0] != killed[0]
    row["pass"] = row["back"] and row["scroll"] and row["form"]
    return row, True
