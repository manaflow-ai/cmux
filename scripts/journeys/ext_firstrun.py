"""The first-run "Bring your history" page, left as a person leaves it (journeys of every kit).

Builds with #33215 (feat 51fad067074, 2026-11-03 19:09Z) open the page cmux.import-history on top of a fresh profile's
first window (OnboardingService.showHistoryAtFirstRun, once per app channel). The kit's first terminal then lands behind
that top page and `new_terminal` finds no focused terminal pane (STATUS 10288). A person leaves the page with its Skip
button. The page's finish (`cmux.importHistory.finish`) checks a user gesture, so a socket `call` cannot skip it: this
step presses Skip with a trusted Chromium click at the button's center (debug.page hover gives the center in CSS px,
debug.page press with native true clicks there), then waits until no import-history page is left.

driver.py loads this file (load_extensions) on the mini, under /usr/bin/python3 (3.9, standard library only).

Steps (`do`):
  skip_first_run_history {appear_s?: 6, gone_s?: 10}
             Looks for a live (not parked) import-history page for APPEAR_S. None: nothing to do (a build without the
             page, a profile that saw it, a build without debug.page); the record says why. Else: waits for the Skip
             button to render, reads its center, presses it there (trusted), and waits GONE_S for the page to close.
             A Skip button it cannot hit, or a page that stays, fails the step with the record. The generators put it
             right after the launch's smoke_make_key (never after a relaunch's: that profile saw the page already).
"""
import json
import time

D = None
PAGE = "cmux.import-history"
# The footer's first button is Skip (webviews/src/pages/import-history/ImportHistory.tsx); Import and Done sit in
# .history-primary-actions, not directly under the footer.
SKIP = "footer.history-footer > button.history-button"
APPEAR_S = 6.0
GONE_S = 10.0
POLL_S = 0.25  # orchestration poll of the app's own report


def install(driver):
    global D
    D = driver


def _page(j, params, timeout=10):
    """debug.page PARAMS: the reply, or {"error": ...} when the app refuses it (no live page, no such method)."""
    try:
        return j.app.rpc("debug.page", dict(params, page=PAGE), timeout=timeout) or {}
    except D.StepError as error:
        return {"error": str(error)[-300:]}


def _live(j):
    """The import-history pages a person sees (the pool's parked spare is none), and the reply's error if any."""
    reply = _page(j, {"action": "list"})
    pages = [p for p in reply.get("pages") or [] if isinstance(p, dict) and not p.get("parked")]
    return pages, reply.get("error")


def step_skip_first_run_history(j, step):
    record = {"page": PAGE}
    end = D.now() + float(step.get("appear_s", APPEAR_S))
    pages, error = _live(j)
    while not pages and not error and D.now() < end:
        time.sleep(POLL_S)
        pages, error = _live(j)
    record["pages_before"] = len(pages)
    if not pages:
        record.update(skipped=False, why=f"debug.page list: {error}" if error else "no import-history page in this launch")
        return record
    record["wait"] = _page(j, {"action": "wait", "selector": SKIP, "timeout_ms": 15000}, timeout=20)
    hover = _page(j, {"action": "hover", "selector": SKIP})
    record["hover"] = hover
    if not (hover.get("hovered") and isinstance(hover.get("x"), (int, float)) and isinstance(hover.get("y"), (int, float))):
        raise D.StepError("skip_first_run_history: the Skip button cannot be pressed at its center: " + json.dumps(record)[:600])
    record["press"] = _page(j, {"action": "press", "x": hover["x"], "y": hover["y"], "native": True})
    pressed = D.now()
    end = pressed + float(step.get("gone_s", GONE_S))
    while True:
        pages, error = _live(j)
        if not pages and not error:
            record.update(skipped=True, gone_after_s=round(D.now() - pressed, 2))
            return record
        if D.now() >= end:
            break
        time.sleep(POLL_S)
    record["left"] = len(pages)
    raise D.StepError("skip_first_run_history: the first-run Bring your history page did not close after Skip: "
                      + json.dumps(record)[:600])


STEPS = {"skip_first_run_history": step_skip_first_run_history}
CONDITIONS = {}
