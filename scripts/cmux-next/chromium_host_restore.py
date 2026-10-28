"""The restore row of chromium-host-bench.py `--kill-host` (p01-process-083): after a SIGKILL of the Chromium Host,
every Chromium tab of every window comes back at its address with its back/forward list, from its daemon history
record, on a new host the app starts at once (feature chromiumHostRestoreTabs, within Chrome's GPU crash budget).

The row opens `windows` windows (`newWindow`) and `tabs` Chromium tabs spread over them (`openBrowser.chromium`),
each at `<probe>?restore=N`, then navigates each to `?restore=N&next=1`, so its history has two entries. Once every
tab's record keeps its engine state (`debug.browser.page_status` `engine_state_saved`), it SIGKILLs the host and
checks:

  shown     the tab each window shows is back at its address with both entries (`history.length` 2) within
            SHOWN_BUDGET_MS of the kill (`shown_ms`, the slowest window); a hidden tab restores only when it shows,
            as Chrome loads a restored background tab when it is activated
  hidden    each hidden tab, focused (`tab.focus`), is back the same way: `hidden_ms` is show to back per tab
  one_host  exactly one Chromium Host runs after, and not the killed one

Pass: every tab back with its history, `shown_ms` <= SHOWN_BUDGET_MS, and one new host. A build whose backend is not
the host says not_run and the row fails: it could not run.
"""

FEATURES = "chromiumHostRestoreTabs"
WINDOWS = 3
TABS = 20
SHOWN_BUDGET_MS = 2000
# Generous: a row that waits this long has failed.
BACK_TIMEOUT_S = 20
SAVED_TIMEOUT_S = 30
WRITE_BACK_S = 1.5


def page_url(url, index, step):
    return f"{url}?restore={index}" + ("&next=1" if step else "")


def back_check(page_eval, tab, expected):
    """True once `tab` shows `expected`, loaded, with both history entries."""
    script = (f"location.href === {expected!r} && document.readyState === 'complete' && history.length === 2")
    return page_eval(script, tab) is True


def run(rpc, wait, page_eval, focused_eval, url, host_pids, kill, clock, sleep, windows=WINDOWS, tabs=TABS):
    """The row; returns (row, ok). `page_eval(script, tab)` is the value of `script` in that tab; `focused_eval(script)`
    is (value, tab id) in the focused page; `host_pids()` lists the app's Chromium Host pids; `kill(pid)` sends
    SIGKILL; `clock()` is seconds and `sleep(seconds)` waits."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        return {"not_run": f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or "
                           "browserHost.helper off)", "pass": False}, False
    row = {"backend": backend, "windows": windows, "tabs": []}
    for index in range(tabs):
        window = index * windows // tabs
        if index and window != (index - 1) * windows // tabs:
            rpc("action.run", {"action": "newWindow", "origin": "script"}, timeout=60)
        first = page_url(url, index, False)
        rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": first}, "focus": True, "origin": "script"},
            timeout=120)
        tab = wait(lambda: (lambda value, tab: tab if value is True and tab else None)(
            *focused_eval(f"location.href === {first!r} && document.readyState === 'complete'")), 60, 0.5)
        if not tab:
            row["error"] = f"tab {index} never loaded {first}"
            row["pass"] = False
            return row, False
        page_eval(f"location.assign({page_url(url, index, True)!r}), true", tab)
        row["tabs"].append({"tab": tab, "window": window, "url": page_url(url, index, True)})
    # The tab each window shows is the last one opened in it.
    shown = {entry["window"]: entry["tab"] for entry in row["tabs"]}
    for entry in row["tabs"]:
        entry["shown"] = shown[entry["window"]] == entry["tab"]
    if not wait(lambda: all(back_check(page_eval, e["tab"], e["url"]) for e in row["tabs"]), 30, 0.5):
        row["error"] = "a tab never reached its second entry"
        row["pass"] = False
        return row, False
    # The history writer saves each change after its debounce (BrowserTabService.writeBackDelay, 500 ms).
    sleep(WRITE_BACK_S)
    saved = wait(lambda: all((rpc("debug.browser.page_status", {"tab": e["tab"]}) or {}).get("engine_state_saved") == "1"
                             for e in row["tabs"]), SAVED_TIMEOUT_S, 0.5)
    row["engine_state_saved"] = bool(saved)
    killed = host_pids()
    if len(killed) != 1:
        row["error"] = f"expected one Chromium Host before the kill, found {killed}"
        row["pass"] = False
        return row, False
    row["killed_host"] = killed[0]
    started = clock()
    kill(killed[0])
    back = wait(lambda: all(back_check(page_eval, e["tab"], e["url"]) for e in row["tabs"] if e["shown"]), BACK_TIMEOUT_S, 0.02)
    row["shown_ms"] = round((clock() - started) * 1000, 1) if back else None
    for entry in row["tabs"]:
        if entry["shown"]:
            entry["back"] = bool(back)
            continue
        focused = clock()
        rpc("action.run", {"action": "tab.focus", "target": f"tab:{entry['tab']}", "focus": True, "origin": "script"},
            timeout=60)
        entry["back"] = bool(wait(lambda: back_check(page_eval, entry["tab"], entry["url"]), BACK_TIMEOUT_S, 0.02))
        entry["hidden_ms"] = round((clock() - focused) * 1000, 1) if entry["back"] else None
    hosts = host_pids()
    row["one_host"] = len(hosts) == 1 and hosts[0] != killed[0]
    row["all_back"] = all(entry["back"] for entry in row["tabs"])
    row["pass"] = (row["all_back"] and row["one_host"] and row["shown_ms"] is not None
                   and row["shown_ms"] <= SHOWN_BUDGET_MS)
    return row, True
