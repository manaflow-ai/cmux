"""The `--hang MS` row of chromium-host-bench.py (p01-process-084, done check 11 of
plans/cmux-next/chrome-parity/p01-process.md): the busy banner of a Chromium Host that takes no input.

A Chromium page whose browser runs in the Chromium Host (`debug.cef` backend `host`), with the feature
`chromiumHostHangBanner` on. The row stops the host for MS ms (SIGSTOP, so its UI thread dispatches nothing), types
one key into the page while it is stopped, and reads cmux's busy deadline from `debug.cef` `host_hang`:

  idle_armed       with no input waiting, no busy deadline is armed (0): an idle cmux wakes no more than before
  busy_after_ms    how long the key had waited for the host when the banner showed, as cmux measured it; passes at
                   2000 +/- 100 ms
  busy_seen_ms     from the bench's key to the bench seeing the banner (POLL_S polling: an upper bound, not checked)
  gone             the banner goes once the host runs again and dispatches the key, and no deadline stays armed
  host_hangs       the host's UI hangs cmux heard. A stopped process measures no hang on its own UI thread (its
                   turns are not open while it waits), so this row does not check it: the hang reports are
                   ChromiumHost/tests/host_hang_watcher_test.cpp's (chromium-host-wire.test.sh)

Not here: cmux's main-thread turn p99 during the hang (`debug.main_turns` samples it in --baseline), and the hidden
page case (ChromiumHostHangMonitorTests.noDeadlineWhileNoPageShows). Without the host backend or the feature the row
says so and is not run.
"""
import time

FEATURES = "chromiumHostHangBanner"
BUSY_AFTER_MS = 2000
TOLERANCE_MS = 100
POLL_S = 0.02
PAGE = """<!doctype html><meta charset=utf-8><title>hang probe</title>
<style>body{margin:0;font:20px system-ui;background:#fff;color:#000}</style>
<input id=t autofocus style="margin:40px;font:inherit">
"""


def host_hang(rpc):
    """`debug.cef` `host_hang`, or None (in process, or the feature is off)."""
    report = rpc("debug.cef") or {}
    value = report.get("host_hang") if isinstance(report, dict) else None
    return value if isinstance(value, dict) else None


def verdict(row):
    """True when the row's numbers meet done check 11."""
    after = row.get("busy_after_ms")
    return (row.get("idle_armed") == 0 and isinstance(after, (int, float)) and after >= 0
            and abs(after - BUSY_AFTER_MS) <= TOLERANCE_MS and row.get("gone") is True)


def run(rpc, wait, page_eval, url, host_pid, stop, resume, hold_ms, sleep=time.sleep, clock=time.monotonic):
    """The row; returns (row, ok). `stop(pid)` and `resume(pid)` stop and continue the host process."""
    row = {"hold_ms": hold_ms}
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        row["not_run"] = f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or browserHost.helper off)"
        return row, False
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
                 timeout=120)
    if not wait(lambda: page_eval("document.readyState === 'complete' && document.title === 'hang probe'"), 60, 0.5):
        row["error"] = f"the probe never loaded: {str(opened)[:200]}"
        return row, False
    state = host_hang(rpc)
    if state is None:
        row["not_run"] = f"no host_hang in debug.cef: the feature {FEATURES} is off"
        return row, False
    if not state.get("watching"):
        row["not_run"] = "the host does not ack its input dispatch (its HELLO lacks cmux_host_hang_watch)"
        return row, False
    pid = host_pid()
    if not pid:
        row["error"] = "no Chromium Host process"
        return row, False
    sleep(1.0)  # test harness: input from the load settles
    idle = host_hang(rpc) or {}
    row["idle_armed"] = idle.get("armed")
    busy_before = idle.get("busy_count") or 0
    hangs_before = idle.get("host_hangs") or 0
    stop(pid)
    try:
        started = clock()
        rpc("debug.key", {"target": "page", "key": "a"})
        shown = wait(lambda: (lambda s: s if s and (s.get("busy_count") or 0) > busy_before else None)(host_hang(rpc)),
                     hold_ms / 1000, POLL_S)
        if shown:
            row["busy_seen_ms"] = round((clock() - started) * 1000, 1)
            row["busy_after_ms"] = shown.get("last_busy_after_ms")
        else:
            row["error"] = "no banner while the host was stopped: did the key reach the host's input ring (p01-process-042)?"
        rest = hold_ms / 1000 - (clock() - started)
        if rest > 0:
            sleep(rest)  # test harness: the host stays stopped for the whole hold
    finally:
        resume(pid)
    gone = wait(lambda: (lambda s: s if s and not s.get("busy") and not s.get("armed") else None)(host_hang(rpc)), 5, POLL_S)
    row["gone"] = gone is not None
    row["host_hangs"] = ((gone or host_hang(rpc) or {}).get("host_hangs") or 0) - hangs_before
    row["pass"] = verdict(row)
    return row, row["pass"]
