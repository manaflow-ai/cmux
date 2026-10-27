"""The quit and runtime-update rows of chromium-host-bench.py (p01-process-087).

quit (`--quit`, feature chromiumQuitAsksPages): a Chromium page with a form and a beforeunload handler that asks once
the form changed. The row clicks the field and types into it with trusted DevTools input (the page's recorder counts
the person's use only from trusted input), then starts an interactive quit (`debug.quit {open: true}`) and checks:

  asked     the page's beforeunload question shows (`debug.browser.prompts`) within ASK_BUDGET_MS of the quit
  stayed    Stay (`respond: cancel`) ends the quit: `debug.quit` no longer quits, cmux and the same Chromium Host run,
            and the page keeps its address and the typed text
  left      a second quit answered Leave ends cmux, and no Chromium Host of it runs QUIT_BUDGET_S after the quit:
            quit's deadline, so no host outlives cmux (an update's bundle swap needs it gone)

runtime-update (`--runtime-update`, feature chromiumHostRuntimeUpdate): a Chromium tab with two history entries; once
its daemon record keeps its engine state, `debug.updater {action: "chromium-runtime", path}` gives the host a newer
runtime: a folder of links to the app's own Frameworks (the same files at another path, so the row can tell which
runtime the next host ran). While the page shows, the host stays (`state` names the blocker); a new workspace hides the
page, and the row checks:

  restarted  a new Chromium Host replaced the old one within RESTART_BUDGET_S of the hide
  runtime    that host started from the new folder (`host_runtimes`)
  back       the tab, focused again, is at its address with both entries

A build whose Chromium backend is not the host says not_run and the row fails: it could not run.
"""
import os

QUIT_FEATURES = "chromiumQuitAsksPages"
RUNTIME_FEATURES = "chromiumHostRuntimeUpdate"
ASK_BUDGET_MS = 2000
QUIT_BUDGET_S = 15
RESTART_BUDGET_S = 30
# Generous: a row that waits this long has failed.
LOAD_TIMEOUT_S = 60
SAVED_TIMEOUT_S = 30
WRITE_BACK_S = 1.5

QUIT_PAGE = """<!doctype html><meta charset="utf-8"><title>quit probe</title>
<input id="field" style="position:absolute;left:40px;top:40px;width:300px;height:40px;font-size:20px">
<script>
window.changed = false;
document.getElementById('field').addEventListener('input', () => { window.changed = true; });
window.addEventListener('beforeunload', (event) => {
  if (!window.changed) return;
  event.preventDefault();
  event.returnValue = '';
});
</script>
"""

TYPED = "unsaved draft"


def host_backend(rpc):
    """`debug.cef`'s backend, or the not_run row when it is not the Chromium Host."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend == "host":
        return backend, None
    return backend, {"not_run": f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or "
                                "browserHost.helper off)", "pass": False}


def beforeunload_asked(rpc, tab):
    """True once `tab` shows a beforeunload question."""
    prompts = (rpc("debug.browser.prompts", {"tab": tab}) or {}).get("prompts") or []
    return any("beforeUnload" in (prompt.get("kind") or "") for prompt in prompts)


def devtools(rpc, method, params):
    """Runs a DevTools method on the focused Chromium tab; True when it answered."""
    reply = rpc("debug.cef.devtools", {"method": method, "params": params}) or {}
    return "error" not in reply


def type_into_field(rpc, page_eval, tab):
    """Clicks the probe's field and types TYPED with trusted input; True once the page saw the text."""
    rect = page_eval("(() => { const r = document.getElementById('field').getBoundingClientRect(); "
                     "return [r.left + r.width / 2, r.top + r.height / 2]; })()", tab)
    if not isinstance(rect, list) or len(rect) != 2:
        return False
    x, y = rect
    for kind in ("mousePressed", "mouseReleased"):
        if not devtools(rpc, "Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left", "clickCount": 1}):
            return False
    if not devtools(rpc, "Input.insertText", {"text": TYPED}):
        return False
    return page_eval(f"document.getElementById('field').value === {TYPED!r} && window.changed", tab) is True


def open_page(rpc, wait, focused_eval, url):
    """Opens `url` in a focused Chromium tab; its tab id once loaded, else None."""
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
        timeout=120)
    return wait(lambda: (lambda value, tab: tab if value is True and tab else None)(
        *focused_eval(f"location.href === {url!r} && document.readyState === 'complete'")), LOAD_TIMEOUT_S, 0.5)


def run_quit(rpc, wait, page_eval, focused_eval, url, host_pids, app_running, clock):
    """The quit row; returns (row, ok). `page_eval(script, tab)` is the value of `script` in that tab; `focused_eval`
    is (value, tab id) in the focused page; `host_pids()` lists the app's Chromium Host pids; `app_running()` says
    whether cmux still runs; `clock()` is seconds. Ends cmux when it passes its stay checks."""
    backend, not_run = host_backend(rpc)
    if not_run:
        return not_run, False
    row = {"backend": backend}
    tab = open_page(rpc, wait, focused_eval, url)
    if not tab:
        return {**row, "error": f"the probe never loaded {url}", "pass": False}, False
    row["typed"] = bool(wait(lambda: type_into_field(rpc, page_eval, tab), 10, 0.5))
    if not row["typed"]:
        return {**row, "error": "the field never took the trusted typing", "pass": False}, False
    hosts = host_pids()
    started = clock()
    rpc("debug.quit", {"open": True})
    asked = wait(lambda: beforeunload_asked(rpc, tab), 10, 0.02)
    row["asked_ms"] = round((clock() - started) * 1000, 1) if asked else None
    if not asked:
        return {**row, "error": "the page's beforeunload never asked", "quit": rpc("debug.quit"), "pass": False}, True
    rpc("debug.browser.prompts", {"tab": tab, "respond": "cancel"})
    row["stayed"] = bool(wait(lambda: not (rpc("debug.quit") or {}).get("quitting", True), 10, 0.1))
    row["same_host"] = host_pids() == hosts
    row["page_kept"] = page_eval(f"location.href === {url!r} && document.getElementById('field').value === {TYPED!r}",
                                 tab) is True
    stay_ok = row["stayed"] and row["same_host"] and row["page_kept"] and app_running()
    if not stay_ok:
        return {**row, "pass": False}, True
    started = clock()
    rpc("debug.quit", {"open": True})
    if wait(lambda: beforeunload_asked(rpc, tab), 10, 0.02):
        rpc("debug.browser.prompts", {"tab": tab, "respond": "accept"})
    ended = wait(lambda: not app_running() and not host_pids(), QUIT_BUDGET_S + 5, 0.1)
    row["quit_s"] = round(clock() - started, 2) if ended else None
    row["left"] = bool(ended) and row["quit_s"] <= QUIT_BUDGET_S
    row["pass"] = row["asked_ms"] <= ASK_BUDGET_MS and row["left"]
    return row, True


def runtime_copy(app, out):
    """A folder of links to each entry of the app's Frameworks: the same runtime at another path. Its path."""
    frameworks = os.path.join(os.path.abspath(app), "Contents", "Frameworks")
    copy = os.path.join(os.path.abspath(out), "runtime-update", "Frameworks")
    os.makedirs(copy, exist_ok=True)
    for name in sorted(os.listdir(frameworks)):
        link = os.path.join(copy, name)
        if not os.path.lexists(link):
            os.symlink(os.path.join(frameworks, name), link)
    return copy


def history_back(page_eval, tab, expected):
    """True once `tab` shows `expected`, loaded, with both history entries."""
    script = f"location.href === {expected!r} && document.readyState === 'complete' && history.length === 2"
    return page_eval(script, tab) is True


def run_runtime_update(rpc, wait, page_eval, focused_eval, url, host_pids, runtime_path, clock, sleep):
    """The runtime-update row; returns (row, ok). `runtime_path` is the newer runtime's Frameworks folder
    (``runtime_copy``); the other callables are as for ``run_quit``, `sleep(seconds)` waits."""
    backend, not_run = host_backend(rpc)
    if not_run:
        return not_run, False
    row = {"backend": backend, "runtime": runtime_path}
    first, second = f"{url}?update=1", f"{url}?update=1&next=1"
    tab = open_page(rpc, wait, focused_eval, first)
    if not tab:
        return {**row, "error": f"the page never loaded {first}", "pass": False}, False
    page_eval(f"location.assign({second!r}), true", tab)
    if not wait(lambda: history_back(page_eval, tab, second), 30, 0.5):
        return {**row, "error": "the page never reached its second entry", "pass": False}, False
    # The history writer saves each change after its debounce (BrowserTabService.writeBackDelay, 500 ms).
    sleep(WRITE_BACK_S)
    row["engine_state_saved"] = bool(wait(
        lambda: (rpc("debug.browser.page_status", {"tab": tab}) or {}).get("engine_state_saved") == "1", SAVED_TIMEOUT_S, 0.5))
    before = host_pids()
    if len(before) != 1:
        return {**row, "error": f"expected one Chromium Host before the update, found {before}", "pass": False}, False
    update = rpc("debug.updater", {"action": "chromium-runtime", "path": runtime_path}) or {}
    if "error" in update or not update.get("updated"):
        return {**row, "error": f"the newer runtime was not taken: {update}", "pass": False}, False
    kept = wait(lambda: "on screen" in ((rpc("debug.updater", {"action": "chromium-runtime"}) or {}).get("state") or ""), 10, 0.1)
    row["kept_while_shown"] = bool(kept) and host_pids() == before
    started = clock()
    rpc("action.run", {"action": "newTab", "origin": "script"}, timeout=60)
    restarted = wait(lambda: (lambda pids: pids if len(pids) == 1 and pids[0] != before[0] else None)(host_pids()),
                     RESTART_BUDGET_S, 0.1)
    row["restart_s"] = round(clock() - started, 2) if restarted else None
    report = rpc("debug.updater", {"action": "chromium-runtime"}) or {}
    row["host_runtimes"] = report.get("host_runtimes")
    row["runtime_used"] = (report.get("host_runtimes") or [None])[-1] == runtime_path
    rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab}", "focus": True, "origin": "script"}, timeout=60)
    row["back"] = bool(wait(lambda: history_back(page_eval, tab, second), 20, 0.1))
    row["pass"] = bool(restarted) and row["runtime_used"] and row["back"] and row["kept_while_shown"]
    return row, True
