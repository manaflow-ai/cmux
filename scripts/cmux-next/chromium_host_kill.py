"""The `--kill-host` rows of chromium-host-bench.py (p01-process-082): a Chromium tab of the app's backend in the
Chromium Host (`debug.cef` backend `host`: the bench's tunables turn `browserHost.helper` on), then one signal per row
to the host process (`--signals`, default KILL; the done check of plans/cmux-next/chrome-parity/p01-process.md runs
TRAP,SEGV,ABRT,KILL). Per row:

  cmux_alive   the cmux app's pid still runs after the host's end
  crash_page   the tab shows the crash page (`debug.browser.page_status` gone "1") with a title, a message and Reload;
               `crash_page_ms` is the signal to the first poll that saw it. The app shows it in the turn its
               supervisor reports the exit (CEFRuntimeHostExitTests), so the poll interval (POLL_S) and the socket
               hop bound this number, not the app
  back         Reload (pressed through page_status, as a click) brings the page back: the crash page is gone and the
               page answers a script again, under a new host (`back_ms` from the signal)
  crash_record with `record` (the bench passes chromium_host_crash_records.row, p01-process-085): `debug.crashes`
               lists the signalled host's end with that signal, its fork API and its log's last lines without URLs

A row passes when all of them hold. Without the host backend no row runs and the mode fails: it could not run.
"""
import os
import signal
import time

TITLE = "kill host probe"
PAGE = f"<!doctype html><meta charset=utf-8><title>{TITLE}</title><p>kill host probe"
SIGNALS = ("TRAP", "SEGV", "ABRT", "KILL")
POLL_S = 0.005
CRASH_PAGE_S = 10.0
BACK_S = 30.0


def signal_numbers(names):
    """`names` ("KILL,SEGV" or a list) as signal numbers; ValueError for a name this list does not take."""
    if isinstance(names, str):
        names = [name for name in names.split(",") if name]
    numbers = []
    for name in names:
        name = name.upper().removeprefix("SIG")
        if name not in SIGNALS:
            raise ValueError(f"--signals takes {', '.join(SIGNALS)}, not {name!r}")
        numbers.append((name, getattr(signal, f"SIG{name}")))
    return numbers


def crash_page_shown(status):
    """True when `status` (page_status fields) shows the crash page with a title, a message and Reload."""
    if not isinstance(status, dict) or status.get("gone") != "1":
        return False
    lines = (status.get("gone_text") or "").split("\n")
    return len(lines) == 3 and all(lines)


def run(rpc, wait, url, signals, host_pid, app_pid, alive, send=os.kill, clock=time.monotonic, record=None):
    """Every row; returns (rows, ok). `host_pid()` reads the running host's pid, `alive(pid)` whether a pid runs,
    `send(pid, number)` signals it, `record(pid, number)` (optional) checks the crash record of that end: a dict
    with `pass`, kept as the row's `crash_record`."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        reason = f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or browserHost.helper off)"
        return {name: {"pass": False, "not_run": reason} for name, _ in signals}, False
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
                 timeout=120)
    tab = {}

    def page(script):
        reply = rpc("browser.page.eval", {"script": script, **({"tab": tab["tab"]} if tab.get("tab") else {})}, timeout=20)
        if not isinstance(reply, dict) or "error" in reply:
            return None
        tab.setdefault("tab", reply.get("tab"))
        return reply.get("value")

    def answers():
        return page(f"document.readyState === 'complete' && document.title === {TITLE!r}") is True

    if not wait(answers, 60, 0.5) or not tab.get("tab"):
        return {"error": f"the probe never loaded: {str(opened)[:200]}"}, False

    def status(press=None):
        return rpc("debug.browser.page_status", {"tab": tab["tab"], **({"press": press} if press else {})}) or {}

    rows = {}
    for name, number in signals:
        host = host_pid()
        if host is None:
            rows[name] = {"pass": False, "not_run": "no Chromium Host runs"}
            continue
        sent = clock()
        send(host, number)
        shown = wait(lambda: crash_page_shown(status()), CRASH_PAGE_S, POLL_S)
        row = {"host_pid": host, "cmux_alive": alive(app_pid), "crash_page": bool(shown),
               "crash_page_ms": round((clock() - sent) * 1000, 1) if shown else None,
               "gone_text": status().get("gone_text")}
        if record is not None:
            row["crash_record"] = record(host, number)
        pressed = bool(shown) and status(press="reload").get("pressed") == "1"
        back = pressed and wait(lambda: status().get("gone") == "0" and answers(), BACK_S, 0.1)
        fresh = host_pid()
        row.update({"back": bool(back), "back_ms": round((clock() - sent) * 1000, 1) if back else None, "new_host_pid": fresh,
                    "new_host": fresh is not None and fresh != host})
        row["pass"] = (row["cmux_alive"] and row["crash_page"] and row["back"] and row["new_host"]
                       and (record is None or bool(row["crash_record"].get("pass"))))
        rows[name] = row
    return rows, all(row.get("pass") for row in rows.values())
