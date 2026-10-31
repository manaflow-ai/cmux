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
  smoke_type_now     {text, bind?}      types TEXT and Return into the terminal that was just made, at once: no wait for
                                      the creation hold (the driver's typing waits 2.5 s after a new terminal; this is
                                      the case Lawrence reports, keys into a terminal while it is created). Binds
                                      ${BIND} to the text. Needs `smoke_make_key` first in the journey; reads again
                                      that a main window is key (debug.window_list): another app window key is a
                                      fail (the app took the keys elsewhere), no app window key is "not run: known
                                      gap".
  smoke_remember_workspaces {}        keeps the workspace ids the app has now (the baseline)
  smoke_snapshot     {name}           keeps, before the keys that make terminals, the daemon terminals of the
                                      topology, each pane's tabs and the focused pane (smoke_new_terminals reads it)
  smoke_close_all    {mark?}          closes every workspace not in the baseline through the app's own
                                      closeWorkspace action, as the sidebar's close does

Conditions (inside `expect.all`; evidence kind app):
  smoke_workspaces   {new, same_as?}  the topology has exactly NEW workspaces beyond the baseline; SAME_AS (a
                                      smoke_snapshot name): and they are the ones that snapshot had (the restore
                                      keeps their ids)
  smoke_frame        {min_lines?, lacks?}
                                      (evidence frame) one fresh window frame, kept as check-NN.png, that is not blank
                                      (text recognition reads at least MIN_LINES, default 3, lines) and shows none of
                                      LACKS. The screenshot of a step whose state the app's reads prove
  smoke_key_window   {}               a main window of the app is its key window (debug.window_list; a read only)
  smoke_new_terminals {since, lines, focused, placement}
                                      the keys went to the new terminals, not to an old one: exactly len(LINES) new
                                      daemon terminals since the snapshot SINCE; each line is on exactly one terminal
                                      of the whole topology, that terminal is new, and no two lines share one; the
                                      line FOCUSED is on the focused terminal. PLACEMENT: `new_workspaces` (each in
                                      its own workspace not in the snapshot), `new_panes` (each in its own pane not in
                                      the snapshot) or `focused_pane` (all tabs of the pane focused at the snapshot,
                                      which now has len(LINES) more tabs)
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
    key_now, windows = _main_key(j)
    if not key_now:
        other = [w for w in windows if w["key"] is True]
        if other:
            # Another window of the app took the keys (a New Tab page's child window, a panel): the app's bug.
            raise D.StepError(f"the keys would go to a window that is not a main window: {json.dumps(other)[:300]}")
        # No window of the app is key any more: keys cannot be checked here (the slot's limit; never a pass).
        raise D.NotRun(GAP + f" (no app window is key after smoke_make_key: {json.dumps(windows)[:200]})")
    text = j.sub(step["text"])
    j.hold_from = None  # at once: never wait out the creation hold here
    sent, replies = D.now(), []
    for char in text:
        replies.append(j.key(char, [], j.key_window))
    replies.append(j.key("return", [], j.key_window))
    if step.get("bind"):  # never `as`: the driver names the current terminal after any step with `as`
        j.vars[step["bind"]] = text
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
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    closed, replies = [], []
    for wid in _workspace_ids(j):
        if wid not in baseline:
            replies.append(j.app.rpc("action.run", {"action": "closeWorkspace", "target": f"workspace:{wid}",
                                                    "args": {"confirm": True}}))
            closed.append(wid)
    return {"closed": closed, "replies": replies}


def cond_smoke_workspaces(j, want, cache):
    """The app has exactly `new` workspaces beyond the remembered baseline; with `same_as` (a smoke_snapshot
    name), they are the very workspaces (ids) that snapshot saw beyond the baseline: after a relaunch, the
    restore kept them. Take that snapshot once the workspaces are confirmed by the daemon (a person's Cmd-N
    first shows a stand-in whose id changes to the daemon's `ws_...` id), e.g. after their terminals ran."""
    baseline = getattr(j, "smoke_baseline", set())
    mine = sorted(w for w in _workspace_ids(j) if w not in baseline)
    holds = len(mine) == int(want["new"])
    detail = {"new_workspaces": mine, "want": int(want["new"])}
    if want.get("same_as"):
        snap = getattr(j, "smoke_snapshots", {}).get(want["same_as"])
        before = None if snap is None else sorted(w for w in snap["workspaces"] if w not in baseline)
        holds = holds and before is not None and mine == before
        detail["before"] = before
    return holds, detail


def _focused_pane(j):
    """The pane id of the app's focused pane (debug.surfaces), or None."""
    return next((p.get("pane") for p in j.app.panes() if p.get("focused")), None)


def _layout(j):
    """{terminal key: (workspace id, pane id, selected, daemon selector)} and {pane id: [tab ids]} of the topology
    now. Terminals are keyed on the tab's `terminal_key` (the app's own terminal id, which stays the same when the
    daemon's tab replaces a stand-in); the daemon screen is read through its `terminal` (the public id)."""
    terms, tabs = {}, {}
    for ws, pane, tab, term in j.places(j.topology()):
        tabs.setdefault(pane.get("id"), []).append(tab.get("id"))
        if term:
            key = str(tab.get("terminal_key") or term)
            terms[key] = (ws.get("id"), pane.get("id"), pane.get("selected_tab") == tab.get("id"), term)
    return terms, tabs


def step_smoke_snapshot(j, step):
    terms, tabs = _layout(j)
    snap = {"terms": sorted(terms), "workspaces": sorted({t[0] for t in terms.values()} | set(_workspace_ids(j))),
            "panes": sorted(tabs), "tabs": tabs, "focused_pane": _focused_pane(j)}
    if not hasattr(j, "smoke_snapshots"):
        j.smoke_snapshots = {}
    j.smoke_snapshots[step["name"]] = snap
    return {"terminals": len(snap["terms"]), "panes": len(snap["panes"]), "focused_pane": snap["focused_pane"]}


def cond_smoke_new_terminals(j, want, cache):
    """The typed lines landed one each on the terminals the keys made (see the module text)."""
    snap = getattr(j, "smoke_snapshots", {}).get(want["since"])
    if snap is None:
        return False, {"error": f"no smoke_snapshot named {want['since']!r} ran before this check"}
    terms, tabs = _layout(j)
    focused_pane = _focused_pane(j)
    screens = {}
    for term, place in terms.items():
        try:
            screens[term] = set(_lines(j.app.screen(place[3])["text"]))
        except D.StepError:
            screens[term] = set()
    old = set(snap["terms"])
    new = sorted(t for t in terms if t not in old)
    wanted = [j.sub(x) for x in want["lines"]]
    holders = {line: [t for t in terms if line in screens[t]] for line in wanted}
    problems = []
    if len(new) != len(wanted):
        problems.append(f"{len(new)} new terminals, not {len(wanted)}")
    for line, on in holders.items():
        if len(on) != 1:
            problems.append(f"{line} is on {len(on)} terminals ({', '.join(on) or 'none'}), not exactly one")
        elif on[0] in old:
            problems.append(f"{line} is on the old terminal {on[0]} (the keys missed the new one)")
    owners = [on[0] for on in holders.values() if len(on) == 1]
    if len(set(owners)) != len(owners):
        problems.append("two lines are on one terminal")
    focus_line = j.sub(want["focused"]) if want.get("focused") else None
    if focus_line and len(holders.get(focus_line, [])) == 1:
        ws, pane, selected, _sel = terms[holders[focus_line][0]]
        if not (pane == focused_pane and selected):
            problems.append(f"{focus_line} is not on the focused terminal (focused pane {focused_pane}, line in "
                            f"pane {pane}, its selected tab: {selected})")
    placement = want.get("placement")
    places = [terms[t] for t in owners]
    if placement == "new_workspaces":
        ids = [t[0] for t in places]
        if any(w in snap["workspaces"] for w in ids) or len(set(ids)) != len(ids):
            problems.append(f"the lines are not each in its own new workspace: {ids}")
    elif placement == "new_panes":
        ids = [t[1] for t in places]
        if any(p in snap["panes"] for p in ids) or len(set(ids)) != len(ids):
            problems.append(f"the lines are not each in its own new pane: {ids}")
    elif placement == "focused_pane":
        ids = [t[1] for t in places]
        target = snap["focused_pane"]
        if any(p != target for p in ids):
            problems.append(f"the lines are not all tabs of the pane focused before the keys ({target}): {ids}")
        had, has = len(snap["tabs"].get(target, [])), len(tabs.get(target, []))
        if has != had + len(wanted):
            problems.append(f"pane {target} has {has} tabs, not {had} + {len(wanted)}")
    elif placement is not None:
        problems.append(f"unknown placement {placement!r}")
    return not problems, {"problems": problems, "new_terminals": new, "holders": holders,
                          "focused_pane": focused_pane, "placement": placement}


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


def cond_smoke_frame(j, want, cache):
    """A fresh frame of the window that is not blank (the step's screenshot; the app state proves the rest)."""
    j.checks += 1
    image = j.app.snapshot(j.out / f"check-{j.checks:02d}.png")
    lines = j.app.read_text(image)
    present = [t for t in j.sub(want.get("lacks", [])) if D.ocr_contains(lines, t)]
    return len(lines) >= int(want.get("min_lines", 3)) and not present, \
        {"image": image.name, "lines": len(lines), "present": present, "text": lines[-8:]}


def _main_key(j):
    """(a main window is the app's key window, the app's windows): a read (debug.window_list), never a focus."""
    report = j.app.rpc("debug.window_list") or {}
    windows = [{"id": w.get("id"), "kind": w.get("kind"), "key": w.get("key"), "visible": w.get("visible")}
               for w in report.get("windows", []) if isinstance(w, dict)]
    return any(w["key"] is True and w["kind"] == "main" for w in windows), windows


def cond_smoke_key_window(j, want, cache):
    """A main window is the app's key window: a read (debug.window_list), so the check does not make it key."""
    key_now, windows = _main_key(j)
    return key_now, {"windows": windows}


STEPS = {"smoke_make_key": step_smoke_make_key, "smoke_type_now": step_smoke_type_now,
         "smoke_remember_workspaces": step_smoke_remember_workspaces, "smoke_close_all": step_smoke_close_all,
         "smoke_snapshot": step_smoke_snapshot}
CONDITIONS = {"smoke_workspaces": ("app", cond_smoke_workspaces), "smoke_key_window": ("app", cond_smoke_key_window),
              "smoke_app_lines": ("app", cond_smoke_app_lines), "smoke_daemon_lines": ("daemon", cond_smoke_daemon_lines),
              "smoke_new_terminals": ("daemon", cond_smoke_new_terminals), "smoke_frame": ("frame", cond_smoke_frame)}
