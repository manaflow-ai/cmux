"""Dogfood smoke-gate steps and conditions for the journeys (group dogfood-smoke, journeys/dogfood/smoke-dogfood.json).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

cmux-ad 2026-10-30 (stop the line, item 2): a build goes to Lawrence only when the smoke journey passes 10 of 10
rounds under memory pressure. Most of it uses the driver's own steps; these add what it lacks:

Steps (`do`):
  smoke_make_key     {}               makes the journey's window the app's key window without activating the app
                                      (`debug.window.focus`: orderFrontRegardless + makeKey) and records whether it
                                      took (`key` == the window). A capture slot's window is never key otherwise
                                      (CMUX_NEXT_NO_ACTIVATE), and keys the app holds for a terminal still being made
                                      are replayed through NSApplication.sendEvent, which reaches only the key window.
                                      When the window did not become key, every later `smoke_type_now` is "not run:
                                      known gap" (the slot's limit), never a pass.
  smoke_type_now     {text, as?}      types TEXT and Return into the terminal that was just made, at once: no wait for
                                      the creation hold (the driver's typing waits 2.5 s after a new terminal; this is
                                      the case Lawrence reports, keys into a terminal while it is created). Binds
                                      ${AS} to the text. Needs `smoke_make_key` first in the journey.
  smoke_remember_workspaces {}        keeps the workspace ids the app has now (the baseline)
  smoke_close_all    {}               closes every workspace not in the baseline through the app's own
                                      closeWorkspace action, as the sidebar's close does

Conditions (inside `expect.all`; evidence kind app):
  smoke_workspaces   {new}            the topology has exactly NEW workspaces beyond the baseline
  smoke_key_window   {}               the journey's window is the app's key window (debug.window.focus's report)
  smoke_app_lines    {lines}          every line is a line of some pane's viewport text in the app (any pane)
  smoke_daemon_lines {lines}          (evidence daemon) every line is a line of some terminal's daemon screen
"""
import json
import time

D = None  # the driver module (install)
GAP = "known gap: the capture slot could not make the window key (debug.window.focus), so keys typed into a new " \
      "terminal while it is made cannot be checked here; not a pass"


def install(driver):
    global D
    D = driver


def _windows(j):
    report = j.app.rpc("debug.windows") or {}
    return [w for w in report.get("windows", []) if isinstance(w, dict)]


def _journey_window(j):
    """The window the journey types in: its key window if a step named one, else the first window."""
    if j.key_window:
        return j.key_window
    windows = _windows(j)
    if not windows:
        raise D.StepError("debug.windows lists no window")
    return windows[0].get("id")


def step_smoke_make_key(j, step):
    window = _journey_window(j)
    reply = j.app.rpc("debug.window.focus", {"window": window}) or {}
    took = isinstance(reply, dict) and reply.get("key") == window
    j.smoke_key_ok = took
    j.smoke_key_reply = reply
    return {"window": window, "reply": reply, "key_window_now": took}


def step_smoke_type_now(j, step):
    if not getattr(j, "smoke_key_ok", False):
        # The slot's limit, not the build's: report it as not run (the gate counts that as no pass).
        raise D.NotRun(GAP + f" (debug.window.focus said {json.dumps(getattr(j, 'smoke_key_reply', None))[:200]})")
    text = j.sub(step["text"])
    j.hold_from = None  # at once: never wait out the creation hold here
    sent, replies = D.now(), []
    for char in text:
        replies.append(j.key(char, [], j.key_window))
    replies.append(j.key("return", [], j.key_window))
    if step.get("as"):
        j.vars[step["as"]] = text
    return {"typed": text, "keys": len(replies), "at": round(sent, 3),
            "handled_by": sorted({str(r.get("handled_by")) for r in replies if isinstance(r, dict)})}


def _workspace_ids(j):
    return [ws.get("id") for ws in j.topology().get("workspaces", []) if ws.get("id")]


def step_smoke_remember_workspaces(j, step):
    """Keeps the workspace ids the app has now, so later steps can count and close the ones the journey made
    (workspaces made with the person's Cmd-N get the app's default names, so names cannot tell them apart)."""
    j.smoke_baseline = set(_workspace_ids(j))
    return {"workspaces": sorted(j.smoke_baseline)}


def step_smoke_close_all(j, step):
    """Closes every workspace the journey made (not in the remembered baseline) through the app's own
    closeWorkspace action, as the sidebar's close does."""
    baseline = getattr(j, "smoke_baseline", None)
    if baseline is None:
        raise D.StepError("smoke_close_all needs smoke_remember_workspaces first")
    closed, replies = [], []
    for wid in _workspace_ids(j):
        if wid not in baseline:
            replies.append(j.app.rpc("action.run", {"action": "closeWorkspace", "target": f"workspace:{wid}",
                                                    "args": {"confirm": True}}))
            closed.append(wid)
    return {"closed": closed, "replies": replies}


def cond_smoke_workspaces(j, want, cache):
    """The app has exactly `new` workspaces beyond the remembered baseline."""
    baseline = getattr(j, "smoke_baseline", set())
    mine = [w for w in _workspace_ids(j) if w not in baseline]
    return len(mine) == int(want["new"]), {"new_workspaces": mine, "want": int(want["new"])}


def _lines(text):
    return [line.strip() for line in (text or "").split("\n")]


def cond_smoke_app_lines(j, want, cache):
    """Every line in `lines` is a line of some pane's viewport text in the app (debug.surfaces): the output a
    person sees, in whichever pane shows it."""
    panes = cache.setdefault("smoke_panes", j.app.panes())
    shown = {line for p in panes for line in _lines(p.get("text"))}
    wanted = [j.sub(x) for x in want["lines"]]
    missing = [x for x in wanted if x not in shown]
    return not missing, {"missing": missing, "panes": len(panes)}


def cond_smoke_daemon_lines(j, want, cache):
    """Every line in `lines` is a line of some terminal's screen in the daemon (each terminal of the topology):
    the command ran, also in a tab that is not shown."""
    if "smoke_screens" not in cache:
        screens = []
        for _ws, _pane, _tab, term in j.places(j.topology()):
            if term:
                try:
                    screens.append(j.app.screen(term)["text"])
                except D.StepError:
                    pass
        cache["smoke_screens"] = screens
    shown = {line for text in cache["smoke_screens"] for line in _lines(text)}
    wanted = [j.sub(x) for x in want["lines"]]
    missing = [x for x in wanted if x not in shown]
    return not missing, {"missing": missing, "terminals": len(cache["smoke_screens"])}


def cond_smoke_key_window(j, want, cache):
    window = _journey_window(j)
    reply = j.app.rpc("debug.window.focus", {"window": window}) or {}
    return isinstance(reply, dict) and reply.get("key") == window, {"reply": reply}


STEPS = {"smoke_make_key": step_smoke_make_key, "smoke_type_now": step_smoke_type_now,
         "smoke_remember_workspaces": step_smoke_remember_workspaces, "smoke_close_all": step_smoke_close_all}
CONDITIONS = {"smoke_workspaces": ("app", cond_smoke_workspaces), "smoke_key_window": ("app", cond_smoke_key_window),
              "smoke_app_lines": ("app", cond_smoke_app_lines), "smoke_daemon_lines": ("daemon", cond_smoke_daemon_lines)}
