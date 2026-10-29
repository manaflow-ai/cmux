"""The renderer hang row of chromium-host-bench.py `--renderer-hang` (p01-process-072): a `while(true){}` page's
hang is that tab's own Page unresponsive prompt, with Chrome's semantics (feature `chromiumHangFollowsVisibility`).

  renderer_hang  a click into a page whose mousedown handler never returns. Chromium calls the renderer unresponsive
                 after kHungRendererDelay, 15 s (components/input/input_constants.h): the prompt shows in that tab,
                 not before the delay, and in no other tab (`debug.cef` `renderer_hangs`). The Chromium host shows
                 nothing: it is never frontmost, owns no visible window, and its busy banner (p01-process-084,
                 `debug.cef` `host_hang.banner`, null until a build reports it) never shows. The calm tab, opened
                 first, in front hides the hung one: its prompt goes, and no prompt comes back while it stays hidden longer than
                 the delay (Chrome stops the timer on WasHidden and drops a hidden tab's report,
                 WebContentsImpl::RendererUnresponsive). Shown again, the prompt comes back a full delay after the
                 show (WasShown restarts the timer). Exit page then ends that renderer.

The row's clock and sleep are parameters, so tests/test_chromium_host_renderer_hang.py drives it on a fake clock.
"""
import time

import chromium_host_native_ui_dialogs as dialogs

ROWS = ("renderer_hang",)
# What the app needs for this row.
FEATURES = "chromiumHangFollowsVisibility"
HUNG_RENDERER_DELAY_S = 15.0
# A prompt sooner than this after the input that hung did not wait for the delay (1 s of slack for the click's trip).
EARLIEST_S = HUNG_RENDERER_DELAY_S - 1.0
# The delay, Chromium's ping, and a loaded fleet Mac (chromium_host_native_ui_dialogs.HANG_DEADLINE_S).
HANG_DEADLINE_S = dialogs.HANG_DEADLINE_S
# How long the hung tab stays hidden: past one whole delay.
HIDDEN_S = HUNG_RENDERER_DELAY_S + 5.0
# How soon a hidden tab's prompt goes.
WITHDRAW_S = 2.0
HANG_TITLE = "hang probe"
CALM_TITLE = "calm probe"
CALM_PAGE = """<!doctype html><meta charset=utf-8><title>calm probe</title>
<p>In front of the hang probe, which stays hidden behind this tab.
"""


def hangs(rpc):
    """`debug.cef` `renderer_hangs`, one entry per Chromium tab; None with the feature off."""
    return (rpc("debug.cef") or {}).get("renderer_hangs")


def hang_of(rpc, title=HANG_TITLE):
    """The `renderer_hangs` entry of the tab titled `title`, {} when there is none."""
    return next((hang for hang in hangs(rpc) or [] if hang.get("title") == title), {})


def host_banner(rpc):
    """Whether the Chromium host's busy banner shows (`debug.cef` `host_hang.banner`); None while the build reports none."""
    report = (rpc("debug.cef") or {}).get("host_hang")
    return None if report is None else bool(report.get("banner"))


def focused_tab_besides(rpc, other):
    """The focused tab once it is not `other`, else None."""
    tab = dialogs.focused_tab(rpc)[0]
    return tab if tab != other else None


def seconds_ms(seconds):
    return round(seconds * 1000, 1)


def renderer_hang_row(rpc, wait, page_eval, out, clear, clock=time.monotonic, sleep=time.sleep):
    if hangs(rpc) is None:
        return {"ok": False, "not_run": f"debug.cef reports no renderer_hangs: {FEATURES} is off or the build predates "
                                        "p01-process-072"}
    # The calm tab first: a second Chromium tab the hang must leave alone, and later the one in front of it.
    if not dialogs.open_page(rpc, wait, page_eval, dialogs.write_page(out, "renderer-hang-calm.html", CALM_PAGE),
                             CALM_TITLE):
        return {"ok": False, "error": "the calm probe never loaded"}
    calm_tab = wait(lambda: dialogs.focused_tab(rpc)[0], 10)
    if not dialogs.open_page(rpc, wait, page_eval, dialogs.write_page(out, "renderer-hang.html", dialogs.HANG_PAGE),
                             HANG_TITLE):
        return {"ok": False, "error": "the hang probe never loaded"}
    hung_tab = wait(lambda: focused_tab_besides(rpc, calm_tab), 10)
    rpc("debug.mouse", {"target": "page"})
    started = clock()
    shown = wait(lambda: hang_of(rpc).get("prompting"), HANG_DEADLINE_S)
    after = clock() - started
    row = {"shown": bool(shown), "show_ms": seconds_ms(after) if shown else None}
    row["waited_for_delay"] = bool(shown) and after >= EARLIEST_S
    row["host"] = clear()
    row["host_banner"] = host_banner(rpc)
    row["prompting_tabs"] = [hang.get("title") for hang in hangs(rpc) or [] if hang.get("prompting")]
    row["that_tab_only"] = row["prompting_tabs"] == [HANG_TITLE]

    # The calm tab in front: the hung tab hides.
    rpc("action.run", {"action": "tab.focus", "target": f"tab:{calm_tab}", "focus": True})
    row["hidden"] = bool(wait(lambda: hang_of(rpc) and not hang_of(rpc).get("shown"), WITHDRAW_S))
    row["withdrawn"] = row["hidden"] and not hang_of(rpc).get("prompting")
    hidden_at = clock()
    prompted_hidden = False
    while clock() - hidden_at < HIDDEN_S:
        if hang_of(rpc).get("prompting"):
            prompted_hidden = True
            break
        sleep(1.0)
    row["quiet_while_hidden"] = row["hidden"] and not prompted_hidden
    # Informational: true while cmux holds the hang; false once Chromium took it back on its own WasHidden.
    row["held_while_hidden"] = hang_of(rpc).get("held")
    row["host_banner_while_hidden"] = host_banner(rpc)

    # Shown again: a full delay from the show, then Exit page.
    rpc("action.run", {"action": "tab.focus", "target": f"tab:{hung_tab}", "focus": True})
    shown_at = clock()
    back = wait(lambda: hang_of(rpc).get("prompting") and hang_of(rpc).get("shown"), HANG_DEADLINE_S)
    after_show = clock() - shown_at
    row["reshow_ms"] = seconds_ms(after_show) if back else None
    row["restarted_from_show"] = bool(back) and after_show >= EARLIEST_S
    row["exited"] = bool(back) and dialogs.page_status(rpc, press="exit").get("pressed") == "1" and \
        bool(wait(lambda: dialogs.page_status(rpc).get("gone") == "1", 10))
    row["ok"] = bool(calm_tab) and bool(hung_tab) and row["shown"] and row["waited_for_delay"] and row["host"]["clear"] and \
        row["that_tab_only"] and row["host_banner"] is not True and row["host_banner_while_hidden"] is not True and \
        row["withdrawn"] and row["quiet_while_hidden"] and row["restarted_from_show"] and row["exited"]
    return row


def run(rpc, wait, page_eval, out, host_pid, front, windows, clock=time.monotonic, sleep=time.sleep):
    """The renderer hang row. `host_pid` gives the running host's pid, `front` the frontmost app's, `windows(pid)` that
    pid's on-screen windows (chromium-host-bench.py's on_screen_windows). Returns (rows, ok)."""
    clear = lambda: dialogs.host_ui_clear(host_pid, front, windows)  # noqa: E731
    try:
        row = renderer_hang_row(rpc, wait, page_eval, out, clear, clock=clock, sleep=sleep)
    except Exception as error:  # noqa: BLE001 - a row's failure is that row's result
        row = {"ok": False, "error": f"{type(error).__name__}: {error}"[:300]}
    return {"renderer_hang": row}, bool(row.get("ok"))
