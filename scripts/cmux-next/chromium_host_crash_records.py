"""chromium-host-bench.py's `--kill-host` row (p01-process-085): a Chromium tab in the supervisor's Chromium Host
(`debug.cef` backend `host`: the bench turns `browserHost.helper` and `browserHost.tabs` on), then one `--signal` to
that host (default TRAP, a CHECK's trap) and `debug.crashes` lists the host's end in `chromium_host` (the supervisor's
records, the fields of its crash report). The row:

  crash_record    a record of the signalled host's pid came within RECORD_S of the signal
  signal          its signal is the one sent; `signal_name` its name
  fork_api        the host's fork API (read after its hello), present
  cef_version     the version the framework's Info.plist names (may be absent on a framework that names none)
  log_tail_lines  the lines of chromium-host.log it kept: at least the host's start line, at most 20
  urls            log lines that still hold a URL: must be 0

`run(rpc, wait, page_eval, url, number)` drives the row; `row(rpc, wait, host_pid, number)` checks the record of a
host already signalled, so a later kill row (chromium_host_kill.py, p01-process-082) adds it to each signal's row.
Without the host backend the row does not run and the mode fails: it could not run.
"""
import os
import re
import signal

TITLE = "crash record probe"
PAGE = f"<!doctype html><meta charset=utf-8><title>{TITLE}</title><p>crash record probe"
SIGNALS = ("TRAP", "SEGV", "ABRT", "KILL")
LOAD_S = 60.0
RECORD_S = 10.0
POLL_S = 0.05
LOG_TAIL_LINES = 20
# A scheme with "://", or a scheme whose URLs have none, at a word part's start (ChromiumHostCrashRecord.scrubbed).
URL = re.compile(r"(?i)(?:[a-z][a-z0-9+.-]*://|(?<![a-z0-9+.-])(?:about|blob|data|filesystem|javascript|mailto|view-source):)\S")


def records(reply):
    """The `chromium_host` records of a `debug.crashes` reply, oldest first; [] when it has none."""
    if not isinstance(reply, dict):
        return []
    listed = reply.get("chromium_host")
    return [record for record in listed if isinstance(record, dict)] if isinstance(listed, list) else []


def record_of(reply, host_pid):
    """The newest record of `host_pid` in a `debug.crashes` reply, or None."""
    return next((record for record in reversed(records(reply)) if record.get("pid") == host_pid), None)


def urls_in(lines):
    """The lines that still hold a URL."""
    return [line for line in lines if isinstance(line, str) and URL.search(line)]


def row(rpc, wait, host_pid, number):
    """The crash record row of the host `host_pid` after signal `number` was sent to it."""
    found = {}

    def recorded():
        found["record"] = record_of(rpc("debug.crashes"), host_pid)
        return found["record"] is not None

    if not wait(recorded, RECORD_S, POLL_S):
        return {"crash_record": False, "pass": False}
    record = found["record"]
    tail = record.get("log_tail") or []
    result = {
        "crash_record": True,
        "signal": record.get("signal"),
        "signal_name": record.get("signal_name"),
        "reason": record.get("reason"),
        "fork_api": record.get("fork_api"),
        "cef_version": record.get("cef_version"),
        "log_tail_lines": len(tail),
        "urls": len(urls_in(tail)),
    }
    result["pass"] = (result["signal"] == number and result["fork_api"] is not None
                      and 0 < result["log_tail_lines"] <= LOG_TAIL_LINES and result["urls"] == 0)
    return result


def signal_number(name):
    """`name` ("TRAP" or "SIGTRAP") as its signal number; ValueError for a name SIGNALS does not hold."""
    name = name.upper().removeprefix("SIG")
    if name not in SIGNALS:
        raise ValueError(f"--signal takes {', '.join(SIGNALS)}, not {name!r}")
    return int(getattr(signal, f"SIG{name}"))


def run(rpc, wait, page_eval, url, number, send=os.kill):
    """The `--kill-host` row; returns (row, ok). Opens `url` (PAGE) in a Chromium tab, sends signal `number` to the
    supervisor's host (`debug.cef` host_supervisor pid) once the page loaded, then checks its record (row())."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        return {"not_run": f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or "
                           "browserHost.helper or browserHost.tabs off)", "pass": False}, False
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
                 timeout=120)
    if not wait(lambda: page_eval(f"document.readyState === 'complete' && document.title === {TITLE!r}") is True,
                LOAD_S, 0.5):
        return {"error": f"the probe never loaded: {str(opened)[:200]}", "pass": False}, False
    host = ((rpc("debug.cef") or {}).get("host_supervisor") or {}).get("pid")
    if host is None:
        return {"not_run": "the supervisor runs no host", "pass": False}, False
    send(host, number)
    result = {"host_pid": host, **row(rpc, wait, host, number)}
    return result, True
