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
                                      gap" -- or, with the journey option smoke_mode=diagnostic, the keys are typed
                                      after the creation hold and the round goes on (never a gate pass).
  smoke_ready        {timeout?}       waits (default 60 s) for a main window, a loaded topology and a connected daemon
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
  smoke_panes        {line, count}    the workspace whose terminal shows LINE has COUNT panes
  smoke_key_window   {}               a main window of the app is its key window (debug.window_list; a read only)
  smoke_new_terminals {since, lines, focused, placement, order?}
                                      the keys went to the new terminals, not to an old one: exactly len(LINES) new
                                      daemon terminals since the snapshot SINCE; each line is on exactly one terminal
                                      of the whole topology, that terminal is new, and no two lines share one; the
                                      line FOCUSED is on the focused terminal. PLACEMENT: `new_workspaces` (each in
                                      its own workspace not in the snapshot), `new_panes` (each in its own pane not in
                                      the snapshot) or `focused_pane` (all tabs of the pane focused at the snapshot,
                                      which now has len(LINES) more tabs); ORDER left_to_right: line i's pane is left
                                      of line i+1's (each line in the pane made for it, in split order)
  smoke_app_lines    {lines}          every line is a line of some pane's viewport text in the app (any pane)
  smoke_daemon_lines {lines}          (evidence daemon) every line is a line of some terminal's daemon screen

R3a (terminal resize) and R3b (new columns never resize old ones), cmux-ad orders 3 and 4 (2026-10-31):
  smoke_adopt_line   {line, as}       makes the terminal whose daemon screen shows LINE the current one and names
                                      its pane AS (ext_window's name_pane), so divider_drag, window_drag, remember
                                      and typing can use it
  smoke_long_line    {tag, longer_than: [NAME...]}
                                      waits for the prompt, then prints one line of TAG and x's longer than the widest
                                      grid of the current pane, the named panes and the remembered ones (+15 cells), so
                                      it must wrap; fails when the focused pane is not the current one
  smoke_widths       {name}           keeps the width and panes of every column of the current pane's workspace
Conditions:
  smoke_r3           {pane, pty_tag, long_tag?, vs?, cols?: wider|narrower}
                                      R3: the pane's grid == fitted grid == drawn grid == fit(the view's frame at the
                                      cell size) == the PTY's size (`echo PTY_TAG $(stty size)`) == the daemon's size
                                      (screen read) == the topology tab's columns x rows; all sizes in the result. With
                                      LONG_TAG the long line wraps at the NEW width: its first screen row is exactly
                                      `cols` long and the rest follows. VS/COLS: the grid is wider/narrower than the
                                      remembered one.
  smoke_same_widths  {since, new, split_in_place?}
                                      every column of the snapshot SINCE (matched by its panes) has EXACTLY its old width
                                      (0.01 point; float view frames), and the workspace has NEW more columns; each old
                                      and new width in the result. SPLIT_IN_PLACE (Cmd-D): the column of the pane focused
                                      at the snapshot gains exactly one pane and is not compared; every other column
                                      is. A width that is unknown (a pane with no frame) is not judged (not run)
"""
import json
import subprocess
import os
import time

D = None  # the driver module (install)
GAP = "known gap: the capture lease could not make the window key (debug.window.focus), so keys typed into a new " \
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
    # The frontmost app before the journey takes the keys: a foreign app front then (a system prompt left on the
    # console) is host noise if it takes the keys back later (_key_lost_to_another_app).
    j.smoke_front_before = _front_app()
    window = _journey_window(j)
    reply = j.app.rpc("debug.window.focus", {"window": window}) or {}
    took = isinstance(reply, dict) and reply.get("key") == window
    j.smoke_key_ok = took
    j.smoke_key_reply = reply
    return {"window": window, "reply": reply, "key_window_now": took, "front_before": list(j.smoke_front_before)}


def _diagnostic(j):
    """`smoke_mode=diagnostic` (run.py --journey-option, the gate's --diagnostic): when no window of the app can be
    key (a capture slot), type after the creation hold instead of at once, so the other steps are still checked.
    Never a gate pass (smoke-gate.py writes no .pass file in this mode)."""
    return (j.spec.get("options") or {}).get("smoke_mode") == "diagnostic"


def step_smoke_type_now(j, step):
    key_now, windows = _main_key(j)
    other = [w for w in windows if w["key"] is True and w["kind"] != "main"]
    if not key_now and other:
        # Another window of the app took the keys (a New Tab page's child window, a panel): the app's bug.
        raise D.StepError(f"the keys would go to a window that is not a main window: {json.dumps(other)[:300]}")
    waited = None
    if not (getattr(j, "smoke_key_ok", False) and key_now):
        if not any(w["kind"] == "main" for w in windows):
            raise D.StepError(f"the app has no main window to type in: {json.dumps(windows)[:200]}")
        if not _diagnostic(j):
            # The slot's limit, not the build's: report it as not run (the gate counts that as no pass).
            how = ("the window lost key status after smoke_make_key made it key" if getattr(j, "smoke_key_ok", False)
                   else f"debug.window.focus said {json.dumps(getattr(j, 'smoke_key_reply', None))[:200]}")
            front = _front_app()
            raise D.NotRun(GAP + f" ({how}; front app {front[0]!r} {front[1] or ''}; windows now {json.dumps(windows)[:200]})")
        # Diagnostic: no key window, so held keys could not be replayed; type after the creation hold instead.
        waited = j.outwait_creation_hold(getattr(j, "last_key_at", D.now()))
    text = j.sub(step["text"])
    j.hold_from = None  # at once (or, diagnostic, the hold already waited out above)
    sent, replies = D.now(), []
    for char in text:
        replies.append(j.key(char, [], j.key_window))
    replies.append(j.key("return", [], j.key_window))
    if step.get("bind"):  # never `as`: the driver names the current terminal after any step with `as`
        j.vars[step["bind"]] = text
    # Each key's path, in order (debug.key `handled_by`): "app" is the router's hold (a key held for a terminal still
    # being made, replayed there), "responder" a key that went straight to the focused view.
    paths = [str(r.get("handled_by")) if isinstance(r, dict) else "?" for r in replies]
    j.smoke_typed_paths = getattr(j, "smoke_typed_paths", []) + [{"line": text, "paths": paths}]
    return {"typed": text, "keys": len(replies), "at": round(sent, 3), "at_once": waited is None, "waited_hold_s": waited,
            "handled_by": sorted(set(paths)), "first_handled_by": paths[0] if paths else None,
            "held_keys": paths.count("app")}


def _workspace_ids(j):
    return [ws.get("id") for ws in j.topology().get("workspaces", []) if ws.get("id")]


def step_smoke_ready(j, step):
    """Waits (at most TIMEOUT s, default 60) until the app shows a main window and its topology is loaded with the
    daemon connected: the moment a person would start to use it after the launch. Under memory pressure this can
    take long; the wait is recorded, and an app that is not ready within TIMEOUT fails the round."""
    t0, last = D.now(), {}
    end = t0 + float(step.get("timeout", 60))
    while D.now() < end:
        windows = _windows(j)
        snap = j.app.rpc("snapshot.get") or {}
        topo = snap.get("topology") if isinstance(snap, dict) else None
        topo = topo if isinstance(topo, dict) else {}
        last = {"windows": len(windows), "loaded": topo.get("loaded"), "daemon_state": topo.get("daemon_state")}
        if windows and topo.get("loaded") is True and topo.get("daemon_state") == "connected":
            return dict(last, waited_s=round(D.now() - t0, 2))
        time.sleep(0.5)
    raise D.StepError(f"the app was not ready {step.get('timeout', 60)} s into the journey "
                      f"(a main window, topology loaded, daemon connected): {json.dumps(last)}")


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
    if want.get("order") == "left_to_right" and len(owners) == len(wanted) and len(set(owners)) == len(owners):
        # Each line in the pane made for it, in the order the panes were made: a split puts its new pane right of the
        # split one, so line i's pane is left of line i+1's (the view frames' x). Catches lines that swapped panes
        # or landed in the earlier new pane (TIP RED 1193: d1 and d2 both in the first new pane, focus kept there).
        xs = {}
        for row in j.app.panes():
            grid = row.get("grid") if isinstance(row.get("grid"), dict) else {}
            if "frame_x" in grid:
                xs[row.get("pane")] = float(grid["frame_x"])
        line_x = [xs.get(terms[t][1]) for t in owners]
        if any(x is None for x in line_x):
            problems.append(f"no view frame for the panes of the lines (x {line_x})")
        elif any(a >= b for a, b in zip(line_x, line_x[1:])):
            problems.append(f"the lines are not each in the pane made for it, left to right: pane x {line_x}")
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


def cond_smoke_panes(j, want, cache):
    """The workspace whose terminal shows LINE (a daemon screen line) has COUNT panes: the journey's own pane count
    (the driver's app_layout needs a terminal the driver adopted, which a key-made terminal here is not)."""
    line = j.sub(want["line"])
    topo = j.topology()
    for ws, _pane, _tab, term in j.places(topo):
        if not term:
            continue
        try:
            shown = set(_lines(j.app.screen(term)["text"]))
        except D.StepError:
            continue
        if line in shown:
            panes = [p for sc in ws.get("screens", []) for p in sc.get("panes", [])]
            return len(panes) == int(want["count"]), {"workspace": ws.get("id"), "panes": len(panes), "want": int(want["count"])}
    return False, {"error": f"no terminal shows {line}"}


def _front_app():
    """(name, bundle id) of the Mac's frontmost app (/usr/bin/lsappinfo, on the mini; no privacy grant needed), or
    (None, None) when it cannot be read."""
    def info(asn, field):
        out = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", field, asn], capture_output=True, text=True,
                             timeout=5).stdout
        for line in out.splitlines():
            key, sep, value = line.partition("=")
            if sep:
                value = value.strip().strip('"')
                return None if value in ("", "[ NULL ]") else value
        return None
    try:
        asn = subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True, timeout=5).stdout.strip()
        if not asn:
            return None, None
        return info(asn, "name"), info(asn, "bundleID")
    except (OSError, subprocess.SubprocessError):
        return None, None


def _ours(j, bundle):
    """Whether BUNDLE is this app or one of its helpers (same bundle id, or a bundle id under it)."""
    mine = str((getattr(j.app, "identity", None) or {}).get("bundle_id") or "")
    return bool(mine) and (bundle == mine or bundle.startswith(mine + "."))


def _key_lost_to_another_app(j, windows):
    """When no window of the app is key: the frontmost app, if it is a foreign app that was ALREADY frontmost before the
    journey made its window key (smoke_make_key recorded it: a system prompt or another app's dialog left on the mini's
    console). That is the host's limit: a known gap naming that app. Else None (the app's fault): the app itself or
    its helper is front, a foreign app appeared during the journey (a panel or prompt the app may have raised), the
    app has no main window, or the front app cannot be read."""
    if any(w["key"] is True for w in windows) or not any(w["kind"] == "main" for w in windows):
        return None
    name, bundle = _front_app()
    before = getattr(j, "smoke_front_before", (None, None))
    if not bundle or _ours(j, bundle) or bundle != before[1]:
        return None
    return f"known gap: another app has the key window on this host ({name or '?'} {bundle}, frontmost before the journey): not a pass"


def cond_smoke_key_window(j, want, cache):
    """A main window is the app's key window: a read (debug.window_list), so the check does not make it key. When no
    window of the app is key because a foreign app that was frontmost before the journey is front again (a system
    prompt left on the mini's console), the check is not judged: it holds for this step (so the step's other checks
    are still judged) and records the gap; smoke-gate.py then makes a passed round "not run", never a pass. A non-main
    app window key, the app front with no key window, or a foreign app that appeared during the journey fails."""
    key_now, windows = _main_key(j)
    if not key_now and _diagnostic(j) \
            and not any(w["key"] is True for w in windows) and any(w["kind"] == "main" for w in windows):
        # Diagnostic on a slot: the app is never the active app there, so its window may be key for a moment
        # (smoke_make_key) and lose it again; no app window key is the slot's limit, not checked. The step's other
        # checks still count. A non-main app window that is key still fails.
        return True, {"windows": windows, "diagnostic": "no key window on this slot (not checked)",
                      "was_key_at_make_key": bool(getattr(j, "smoke_key_ok", False))}
    if not key_now:
        gap = _key_lost_to_another_app(j, windows)
        if gap:
            gaps = getattr(j, "smoke_key_gaps", [])
            j.smoke_key_gaps = gaps
            if gap not in gaps:
                gaps.append(gap)
            return True, {"windows": windows, "not_checked": gap}
    return key_now, {"windows": windows}



# ---- R3a: resize (cmux-ad order 3) ------------------------------------------------------------

def _grid(text):
    parts = str(text or "").split("x")
    return (int(parts[0]), int(parts[1])) if len(parts) == 2 and all(x.isdigit() for x in parts) else None


def _surfaces(j, cache):
    if "smoke_surfaces" not in cache:
        cache["smoke_surfaces"] = j.app.panes()
    return cache["smoke_surfaces"]


def _terminal_of_line(j, line):
    """(topology pane id, daemon terminal, tab record) of the one terminal whose daemon screen shows LINE."""
    found = []
    for ws, pane, tab, term in j.places(j.topology()):
        if not term:
            continue
        try:
            if line in set(_lines(j.app.screen(term)["text"])):
                found.append((pane.get("id"), term, tab, ws))
        except D.StepError:
            continue
    if len(found) != 1:
        raise D.StepError(f"{len(found)} terminals show {line!r}, not exactly one")
    return found[0]


def step_smoke_adopt_line(j, step):
    pane, term, _tab, ws = _terminal_of_line(j, j.sub(step["line"]))
    j.term, j.pane, j.host_pid = term, pane, None
    rec = j.step_name_pane({"as": step["as"]})
    if not hasattr(j, "smoke_named"):
        j.smoke_named = {}
    j.smoke_named[step["as"]] = {"pane": pane, "term": term, "workspace": ws.get("id")}
    return dict(rec, workspace=ws.get("id"))


def _named(j, name):
    named = getattr(j, "smoke_named", {})
    if name not in named:
        raise D.StepError(f"no pane named {name!r} (smoke_adopt_line first)")
    return named[name]


def _pane_grid(j, pane_key, cache):
    row = next((p for p in _surfaces(j, cache) if p.get("pane") == pane_key), None)
    return row, _grid(((row or {}).get("surface") or {}).get("grid"))


# The bare prompts a key-made terminal shows: the capture lease's neutral shell home ("$ "), zsh's "%", root's "#",
# and the driver's neutral prompt ("J> ").
PROMPTS = ("$", "%", "#", "J>")


def _wait_prompt(j, timeout):
    """Seconds until the current terminal's last non-empty daemon screen line is a bare prompt (PROMPTS)."""
    t0 = D.now()
    last = None
    while D.now() - t0 < timeout:
        lines = [l for l in _lines(j.app.screen(j.need_term())["text"]) if l]
        last = lines[-1] if lines else None
        if last in PROMPTS:
            return round(D.now() - t0, 2)
        time.sleep(0.1)
    raise D.StepError(f"the prompt did not come back within {timeout} s (last screen line {last!r})")


def step_smoke_long_line(j, step):
    focused = _focused_pane(j)
    if focused != j.pane:
        raise D.StepError(f"smoke_long_line: the focused pane is {focused}, not the current pane {j.pane}: the keys "
                          "would go elsewhere")
    _row, current = _pane_grid(j, j.pane, {})
    widest = current[0] if current else 0
    for name in step.get("longer_than", []):
        _row, grid = _pane_grid(j, _named(j, name)["pane"], {})
        widest = max(widest, grid[0] if grid else 0)
    for kept in getattr(j, "ext_remembered", {}).values():
        if kept.get("grid"):
            widest = max(widest, kept["grid"][0])
    if widest <= 0 or not current:
        raise D.StepError(f"smoke_long_line: no grid width to exceed (current pane grid {current})")
    tag = j.sub(step["tag"])
    length = widest + 15
    # As a person does: wait until the command before has finished and the prompt is back (the last screen line
    # is the bare prompt), so these keys do not echo into that command's output.
    waited = _wait_prompt(j, float(step.get("timeout", 10)))
    # The shell prints TAG then x's to LENGTH characters; the typed command itself holds no such run.
    text = f"printf '%s' {tag}; printf 'x%.0s' $(seq 1 {length - len(tag)}); echo"
    replies = [j.key(char, [], j.key_window) for char in text] + [j.key("return", [], j.key_window)]
    if not hasattr(j, "smoke_long"):
        j.smoke_long = {}
    j.smoke_long[tag] = length
    return {"tag": tag, "length": length, "widest_before": widest, "keys": len(replies), "prompt_wait_s": waited}


def _pty_size(text, tag):
    for line in _lines(text):
        parts = line.split()
        if len(parts) == 3 and parts[0] == tag and parts[1].isdigit() and parts[2].isdigit():
            return int(parts[2]), int(parts[1])  # stty size prints rows then cols
    return None


def _wrap_rows(text, tag, length):
    """The screen rows the long line takes: the row that starts with TAG, then the rows of x's after it."""
    rows = (text or "").split("\n")
    for index, row in enumerate(rows):
        row = row.rstrip()
        if row.startswith(tag) and set(row[len(tag):]) <= {"x"}:
            got = [row]
            for more in rows[index + 1:]:
                more = more.rstrip()
                if more and set(more) <= {"x"} and sum(len(r) for r in got) < length:
                    got.append(more)
                else:
                    break
            return got
    return None


def _screen_retry(j, term):
    """The daemon screen of TERM; one failed read (a slow reply under memory pressure) is read again once."""
    try:
        return j.app.screen(term)
    except D.StepError:
        time.sleep(0.2)
        return j.app.screen(term)


def cond_smoke_r3(j, want, cache):
    rec = _named(j, want["pane"])
    row, grid = _pane_grid(j, rec["pane"], cache)
    surface, info = (row or {}).get("surface") or {}, (row or {}).get("grid") or {}
    fit, drawn = _grid(surface.get("fit_grid")), _grid(surface.get("drawn_grid"))
    bounds, slack = None, None
    cw, ch = info.get("cell_width"), info.get("cell_height")
    if cw and ch and "frame_width" in info:
        pad_x = max(0.0, info.get("origin_x", 0) - info.get("frame_x", 0))
        pad_y = max(0.0, info.get("origin_y", 0) - info.get("frame_y", 0))
        bounds = (int((info["frame_width"] - 2 * pad_x + 0.5) // cw), int((info["frame_height"] - 2 * pad_y + 0.5) // ch))
        if grid:
            # The far side's padding the grid leaves (any split of the leftover between the sides): it must be at least
            # the near side's (no cell drawn past the view) and less than it plus one cell (no whole column unused).
            far = (info["frame_width"] - pad_x - grid[0] * cw, info["frame_height"] - pad_y - grid[1] * ch)
            slack = [round(far[0], 2), round(far[1], 2)]
            if pad_x - 0.5 <= far[0] < pad_x + cw and pad_y - 0.5 <= far[1] < pad_y + ch:
                bounds = tuple(grid)
    screen = _screen_retry(j, rec["term"])
    daemon = (screen.get("cols"), screen.get("rows"))
    topo_size = None
    for _ws, pane, tab, term in j.places(j.topology()):
        if term == rec["term"]:
            topo_size = (tab.get("columns"), tab.get("rows"))
    pty = _pty_size(screen.get("text"), j.sub(want["pty_tag"])) if want.get("pty_tag") else None
    sizes = {"grid": grid, "fit_grid": fit, "drawn_grid": drawn, "fit_bounds": bounds, "pty": pty, "daemon": daemon,
             "topology": topo_size}
    detail = {"pane": rec["pane"], "terminal": rec["term"], "sizes": sizes, "far_padding": slack,
              "frame": [info.get("frame_width"), info.get("frame_height")],
              "cell": [cw, ch], "content_size": (row or {}).get("content_size")}
    problems = []
    if row is None:
        problems.append("the pane is not in debug.surfaces")
    if not grid:
        problems.append("no grid")
    for name in ("fit_grid", "drawn_grid", "daemon", "topology"):
        if sizes[name] != grid:
            problems.append(f"{name} {sizes[name]} != grid {grid}")
    if want.get("pty_tag") and pty != grid:
        problems.append(f"pty {pty} != grid {grid}")
    # fit(bounds): the view's frame at the cell size holds the grid (Ghostty may keep one cell of slack).
    # fit(bounds): the cells the view's frame holds at the cell size, padding on both sides (floor, as Ghostty fits).
    if bounds is None or not grid or tuple(bounds) != tuple(grid):
        problems.append(f"grid {grid} != fit(bounds) {bounds}")
    if want.get("vs") and grid:
        base = (getattr(j, "ext_remembered", {}).get(want["vs"]) or {}).get("grid")
        detail["vs"] = base
        if not base:
            problems.append(f"nothing remembered as {want['vs']}")
        elif want.get("cols") == "wider" and not grid[0] > base[0]:
            problems.append(f"cols {grid[0]} not wider than {base[0]}")
        elif want.get("cols") == "narrower" and not grid[0] < base[0]:
            problems.append(f"cols {grid[0]} not narrower than {base[0]}")
    if want.get("long_tag"):
        tag = j.sub(want["long_tag"])
        length = getattr(j, "smoke_long", {}).get(tag)
        rows = _wrap_rows(screen.get("text"), tag, length or 0)
        detail["long_line"] = {"length": length, "rows": [len(r) for r in rows] if rows else None}
        if not length or not rows:
            problems.append("the long line is not on the screen")
        elif not grid or len(rows[0]) != min(length, grid[0]) or sum(len(r) for r in rows) != length:
            problems.append(f"the long line ({length} cells) wraps at {len(rows[0])}, not at the new width {grid and grid[0]} "
                            f"(rows {[len(r) for r in rows]})")
    detail["problems"] = problems
    return not problems, detail


# An old column whose pane has no frame for this long is not judged (smoke_same_widths).
UNKNOWN_SECONDS = 3.0


# ---- R3b: new columns never resize old ones (cmux-ad, Lawrence's P0 rule) ------------------------

def _widths(j, workspace, cache=None, frames_out=None):
    """{column index: width in points} of every column of WORKSPACE: the topology's `column` of each pane, and the
    union of its panes' horizontal extents in the window (debug.surfaces: the view frame, floats). A column with a
    pane that has no frame has width None (FRAMES_OUT gets {column: [pane ids]}). Panes stacked in one column share
    its width."""
    panes = {p.get("pane"): p for p in (_surfaces(j, cache) if cache is not None else j.app.panes())}
    extents, missing_frames = {}, {}
    for ws in j.topology().get("workspaces", []):
        if ws.get("id") != workspace:
            continue
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                column = pane.get("column")
                row = panes.get(pane.get("id")) or {}
                grid = row.get("grid") if isinstance(row.get("grid"), dict) else {}
                if "frame_width" not in grid or "frame_x" not in grid:
                    # No frame for this pane (off screen, a page, not drawn yet): the column's width is unknown;
                    # never guessed from another pane.
                    extents[column] = None
                    missing_frames.setdefault(str(column), []).append(pane.get("id"))
                    continue
                if column in extents and extents[column] is None:
                    continue
                extents.setdefault(column, []).append((float(grid["frame_x"]), float(grid["frame_width"])))
    out = {}
    for column, spans in extents.items():
        out[str(column)] = None if not spans else round(max(x0 + w for x0, w in spans) - min(x0 for x0, _w in spans), 2)
    if frames_out is not None:
        frames_out.update(missing_frames)
    return out


def _span(j, members, cache=None):
    """(width in points, [members with no frame]) of the panes MEMBERS: the union of their horizontal extents in the
    window (debug.surfaces view frames, floats); width None when any of them has no frame."""
    panes = {p.get("pane"): p for p in (_surfaces(j, cache) if cache is not None else j.app.panes())}
    spans, missing = [], []
    for pane in members:
        grid = (panes.get(pane) or {}).get("grid")
        if not isinstance(grid, dict) or "frame_width" not in grid or "frame_x" not in grid:
            missing.append(pane)
        else:
            spans.append((float(grid["frame_x"]), float(grid["frame_width"])))
    if missing or not spans:
        return None, missing
    return round(max(x0 + w for x0, w in spans) - min(x0 for x0, _w in spans), 2), []


def _columns(j, workspace, cache=None):
    """{column index: [pane ids]} of WORKSPACE (the topology's `column` of each pane)."""
    out = {}
    for ws in j.topology().get("workspaces", []):
        if ws.get("id") == workspace:
            for screen in ws.get("screens", []):
                for pane in screen.get("panes", []):
                    out.setdefault(str(pane.get("column")), []).append(pane.get("id"))
    return out


def _current_workspace(j):
    """The topology workspace id of the current pane (the topology's ids, which _columns and _widths read)."""
    for ws, pane, _tab, _term in j.places(j.topology()):
        if pane.get("id") == j.pane:
            return ws.get("id")
    raise D.StepError(f"the current pane {j.pane} is in no workspace of the topology")


def _alive(pid):
    """Whether process PID runs (the driver's App.alive: a zombie counts as gone)."""
    app = getattr(D, "App", None)
    if app is not None and hasattr(app, "alive"):
        return app.alive(pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _layout_panes(node, out):
    """The pane ids of a daemon layout node (leaf, split, rows), in order."""
    if not isinstance(node, dict):
        return out
    if node.get("kind") == "leaf" and node.get("pane_id"):
        out.append(str(node["pane_id"]))
    for key in ("a", "b", "root", "first", "second"):
        _layout_panes(node.get(key), out)
    for key in ("children", "rows", "columns"):
        for child in node.get(key) or []:
            _layout_panes(child.get("root", child) if isinstance(child, dict) else child, out)
    return out


def _daemon_widths(j, workspace):
    """{frozenset(pane ids): width share} of every viewport column of WORKSPACE's screens, from the daemon's own layout
    (`cmux screen ID layout export`: root.kind "viewport", columns[].width, a share of the viewport). The daemon's
    record of the layout, independent of whether the app shows a column's view. {} when it cannot be read."""
    out = {}
    for ws in j.topology().get("workspaces", []):
        if ws.get("id") != workspace:
            continue
        for screen in ws.get("screens", []):
            try:
                layout = j.app.cmux("screen", str(screen.get("id")), "layout", "export")
            except D.StepError:
                continue
            root = (layout or {}).get("root") if isinstance(layout, dict) else None
            if not isinstance(root, dict) or root.get("kind") != "viewport":
                continue
            for column in root.get("columns") or []:
                panes = frozenset(_layout_panes(column.get("root"), []))
                if panes and isinstance(column.get("width"), (int, float)):
                    out[panes] = float(column["width"])
    return out


def _daemon_width_of(widths, members):
    """The daemon width share of the column that holds every pane of MEMBERS, or None."""
    for panes, width in widths.items():
        if set(members) <= panes:
            return width
    return None


def _frame_loss(j, panes, again=True):
    """For each pane with no view frame: is its terminal only hidden (the view unmounted or discarded, the daemon pane,
    its terminal and the shell process alive) or GONE? GONE needs a clear answer: the daemon topology has no such pane
    or no terminal on its selected tab, the topology tab is `dead`, the daemon's terminal list says the terminal is
    not running (lifecycle) or has exited, or the shell pid the daemon gave is dead. A failed read (no daemon socket,
    an answer that is not JSON, a timeout) proves nothing: that pane counts as hidden-but-unproven, and the gate
    reads once more before a GONE verdict. Returns ({pane: evidence}, [gone panes])."""
    rows = {p.get("pane"): p for p in j.app.panes()}
    places, topo_panes = {}, {}
    topology = j.topology()
    for _ws, pane, _tab, _term in j.places(topology):
        topo_panes.setdefault(pane.get("id"), pane)
    for ws in topology.get("workspaces", []):  # panes with no tabs are panes too (never GONE for having no tab)
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                topo_panes.setdefault(pane.get("id"), pane)
    for _ws, pane, tab, term in j.places(topology):
        if pane.get("id") in panes and pane.get("selected_tab") == tab.get("id"):
            places[pane.get("id")] = (term, tab)
    try:
        registry = {str(r.get("terminal_id") or r.get("id")): r for r in _terminal_rows(j)}
    except (D.StepError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        registry = None
        registry_error = str(error)[:200]
    evidence, gone = {}, []
    for pane in panes:
        row = rows.get(pane) or {}
        surface = row.get("surface") if isinstance(row.get("surface"), dict) else {}
        ev = {"app": {k: row.get(k) for k in ("presence", "kind", "visible", "blank", "content_installed",
                                               "content_in_window", "content_size", "link", "attach", "host_pid")},
              "app_surface": {k: surface.get(k) for k in ("exists", "replay_applied", "rendering_suspended", "grid")},
              "in_topology": pane in places}
        reasons, unproven = [], []
        term, tab = places.get(pane, (None, {}))
        ev["terminal"], ev["tab_dead"] = term, tab.get("dead") if isinstance(tab, dict) else None
        topo_pane = topo_panes.get(pane)
        if topo_pane is None:
            reasons.append("the daemon topology has no such pane")
        elif pane not in places:
            # A pane with no selected tab (null when no window mounts it): its terminal is not known here.
            unproven.append("the topology pane has no selected tab (no window mounts it)")
        elif not term:
            reasons.append("the pane's selected tab has no terminal")
        else:
            if ev["tab_dead"] is True:
                reasons.append("the topology says the terminal tab is dead")
            if registry is None:
                unproven.append(f"the daemon terminal list could not be read: {registry_error}")
            else:
                record = registry.get(str(term)) or next((r for r in registry.values()
                                                           if str(r.get("terminal_key") or "") == str(term)), None)
                ev["lifecycle"] = record.get("lifecycle") if record else None
                ev["exit"] = record.get("exit") if record else None
                if record is None:
                    unproven.append("the terminal is not in the daemon's terminal list under that id")
                elif record.get("exit") or record.get("lifecycle") == "exited":
                    reasons.append(f"the daemon's terminal list says lifecycle {record.get('lifecycle')!r}, "
                                   f"exit {record.get('exit')!r}")
            try:
                screen = j.app.screen(term)
                ev["daemon_screen"] = {"ok": True, "cols": screen.get("cols"), "rows": screen.get("rows")}
            except (D.StepError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                ev["daemon_screen"] = {"ok": False, "error": str(error)[:200]}
                unproven.append("the daemon screen read failed")
            try:
                proc = j.app.cmux("terminal", term, "process", "show")
                pid = proc.get("pid") if isinstance(proc, dict) else None
                ev["daemon_process"] = {"pid": pid}
                if pid:
                    ev["shell_alive"] = _alive(int(pid))
                    if not ev["shell_alive"]:
                        reasons.append(f"the terminal's process {pid} is not running")
                else:
                    unproven.append("the daemon reports no pid for the terminal")
            except (D.StepError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                ev["daemon_process"] = {"error": str(error)[:200]}
                unproven.append("the daemon process read failed")
        ev["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        ev["gone_because"], ev["unproven"] = reasons, unproven
        evidence[pane] = ev
        if reasons:
            gone.append(pane)
    if gone and again:
        # A GONE verdict is final: read once more (one slow answer under memory pressure must not decide it).
        time.sleep(0.5)
        evidence2, gone2 = _frame_loss(j, gone, again=False)
        evidence.update(evidence2)
        gone = gone2
    return evidence, gone


def _terminal_rows(j):
    """The daemon's terminal list rows (`cmux terminal list`: terminal_id, lifecycle, exit)."""
    rows = j.app.cmux("terminal", "list")
    if isinstance(rows, dict):
        rows = next((rows[k] for k in ("terminals", "value", "result") if isinstance(rows.get(k), list)), [])
    return [r for r in rows or [] if isinstance(r, dict)]


def _no_frame_verdict(j, panes, what):
    """Not judged (NotRun) when every pane without a frame is only hidden; a FAIL (StepError) when a terminal is gone:
    a person would lose a terminal under memory pressure (cmux-ad, possible P0)."""
    evidence, gone = _frame_loss(j, panes)
    if gone:
        raise getattr(D, "TerminalGone", D.StepError)(
            f"TERMINAL GONE under memory pressure ({what}): panes {gone}: " + json.dumps({p: evidence[p] for p in gone})[:1500])
    unproven = sorted(p for p, ev in evidence.items() if ev.get("unproven"))
    state = ("each terminal is alive (daemon pane, screen and shell process)" if not unproven else
             f"no terminal is proven gone, but {unproven} could not be fully read")
    raise D.NotRun(f"{what}: panes {sorted(panes)} have no view frame; {state}: the view is hidden or discarded, "
                   f"not judged: " + json.dumps(evidence)[:1200])


def step_smoke_widths(j, step):
    workspace = _current_workspace(j)
    for state in ("smoke_unknown_since", "smoke_width_held"):
        stored = getattr(j, state, None)
        if stored is not None:
            stored.discard(step["name"]) if isinstance(stored, set) else stored.pop(step["name"], None)
    end = time.monotonic() + float(step.get("frame_wait", UNKNOWN_SECONDS))
    while True:
        no_frame = {}
        widths, columns = _widths(j, workspace, None, no_frame), _columns(j, workspace)
        if not no_frame or time.monotonic() >= end:
            break
        time.sleep(0.2)
    hidden_alive = None
    if no_frame:
        # A pane with no view frame: its column's width is unknown from the view. A gone terminal fails at once; a
        # hidden one whose terminal lives is kept with width None, and the daemon's own column share (saved below)
        # judges that column in smoke_same_widths.
        panes = sorted({p for v in no_frame.values() for p in v})
        evidence, gone = _frame_loss(j, panes)
        if gone:
            raise getattr(D, "TerminalGone", D.StepError)(
                f"TERMINAL GONE under memory pressure (smoke_widths): panes {gone}: "
                + json.dumps({p: evidence[p] for p in gone})[:1500])
        hidden_alive = evidence
    if not hasattr(j, "smoke_width_snaps"):
        j.smoke_width_snaps = {}
    focused = _focused_pane(j)
    daemon = _daemon_widths(j, workspace)
    j.smoke_width_snaps[step["name"]] = {"workspace": workspace, "widths": widths, "columns": columns, "focused": focused,
                                         "daemon_widths": daemon, "hidden_alive": hidden_alive}
    return {"workspace": workspace, "widths": widths, "columns": columns, "focused": focused,
            "daemon_widths": {",".join(sorted(k)): v for k, v in daemon.items()}, "hidden_alive": hidden_alive}


def cond_smoke_same_widths(j, want, cache):
    snap = getattr(j, "smoke_width_snaps", {}).get(want["since"])
    if snap is None:
        return False, {"error": f"no smoke_widths named {want['since']!r}"}
    # Columns are matched by their content, not their index: a new column after the focused one shifts the
    # indexes of the columns right of it. Each old column is its set of panes.
    old_cols, new_cols = snap["columns"], _columns(j, snap["workspace"], cache)
    widths_now = {}
    changed, gone, unknown = {}, [], {}
    split_in = None
    if want.get("split_in_place"):
        # Cmd-D (Split Right) splits the pane focused at the snapshot inside its own column (Lawrence 2026-10-01,
        # column-sizing.md): that column gains one pane and is not compared; every OTHER column must keep its width.
        split_in = next((k for k, m in old_cols.items() if snap.get("focused") in m), None)
    for index, members in old_cols.items():
        match = next((k for k, m in new_cols.items() if set(members) <= set(m)), None)
        before = snap["widths"].get(index)
        if match is None:
            gone.append(index)
            continue
        if index == split_in:
            continue
        # The old column's width now, from its OLD panes only: a pane a split just added to it (Split Down) may not
        # have its frame yet, and the column's width is the span of the panes it already had. When every pane of the
        # column has its frame, the span of all of them must be that width too (a column that grew to hold a new pane
        # beside its old ones changed width).
        after, missing = _span(j, members, cache)
        whole, _whole_missing = _span(j, new_cols.get(match, members), cache)
        widths_now[match] = whole if whole is not None else after
        if before is None or after is None:
            unknown[index] = {"old": before, "new": after, "panes": members, "no_frame": missing}
        elif abs(before - after) > 0.01 or (whole is not None and abs(before - whole) > 0.01):
            changed[index] = {"old": before, "new": whole if whole is not None and abs(before - whole) > 0.01 else after,
                              "panes": members, "old_panes_span": after, "all_panes_span": whole}

    matched = {next((k for k, m in new_cols.items() if set(members) <= set(m)), None) for members in old_cols.values()}
    added = sorted(k for k in new_cols if k not in matched)
    for k in added:
        widths_now[k] = _span(j, new_cols[k], cache)[0]
    problems = []
    if changed:
        problems.append(f"{len(changed)} existing columns changed width")
    if gone:
        problems.append(f"{len(gone)} existing columns are gone")
    if len(added) != int(want.get("new", 1)):
        problems.append(f"{len(added)} new columns, not {want.get('new', 1)}")
    if want.get("split_in_place"):
        if split_in is None:
            problems.append(f"the focused pane {snap.get('focused')} was in no column of the snapshot")
        else:
            members = old_cols[split_in]
            match = next((k for k, m in new_cols.items() if set(members) <= set(m)), None)
            grown = len(new_cols.get(match, [])) - len(members) if match is not None else None
            if grown != 1:
                problems.append(f"the focused pane's column has {grown} more panes, not 1 (no split in place)")
    detail = {"problems": problems, "changed": changed, "gone": gone, "added": added, "unknown": unknown,
              "split_in_column": split_in, "old_widths": snap["widths"], "new_widths": widths_now,
              "old_columns": old_cols, "new_columns": new_cols}
    seen = getattr(j, "smoke_unknown_since", {})
    j.smoke_unknown_since = seen
    if unknown and not problems:
        # A hidden view (its terminal alive, proven by _frame_loss) is measured by the daemon's own column width share
        # instead: the same column (by its panes) before and now. A gone terminal still fails in _no_frame_verdict.
        hidden = sorted({p for v in unknown.values() for p in v["no_frame"]})
        evidence, gone = _frame_loss(j, hidden)
        if gone:
            # A terminal is gone: the step ends now, whatever a later poll would show.
            raise getattr(D, "TerminalGone", D.StepError)(
                f"TERMINAL GONE under memory pressure (an old pane lost its view frame): panes {gone}: "
                + json.dumps({p: evidence[p] for p in gone})[:1500])
        if not gone:
            now_daemon = _daemon_widths(j, snap["workspace"])
            resolved = {}
            for index, info in unknown.items():
                before_share = _daemon_width_of(snap.get("daemon_widths") or {}, info["panes"])
                now_share = _daemon_width_of(now_daemon, info["panes"])
                if before_share is None or now_share is None:
                    continue
                resolved[index] = {"daemon_share_old": before_share, "daemon_share_new": now_share, "source": "daemon"}
                if abs(before_share - now_share) > 1e-4:
                    changed[index] = dict(info, **resolved[index], old=before_share, new=now_share)
            for index in resolved:
                unknown.pop(index, None)
            detail["daemon_resolved"] = resolved
            detail["hidden_evidence"] = evidence
            if changed:
                problems.append(f"{len(changed)} existing columns changed width")
                detail["changed"] = changed
    held = getattr(j, "smoke_width_held", set())
    j.smoke_width_held = held
    if unknown and not problems and want["since"] in held:
        # The check held, then an old pane lost its frame during the settle (its terminal closed under memory
        # pressure): the driver's settle reads a negative condition again only while it holds, so a False here would
        # be final. Not judged at once.
        _no_frame_verdict(j, sorted({p for v in unknown.values() for p in v["no_frame"]}),
                          "an old pane lost its view frame after the width check held")
    if unknown and not problems:
        # Only unknown widths (an old column's pane has no frame, e.g. an off-screen column whose terminal the app
        # closed under memory pressure): not yet judged this poll; past UNKNOWN_SECONDS, not judged at all (the
        # round is "not run"). Any real problem (a width change, a lost or extra column, no split in place) is
        # judged first and fails.
        first = seen.setdefault(want["since"], D.now())
        if D.now() - first >= float(want.get("unknown_seconds", UNKNOWN_SECONDS)):
            _no_frame_verdict(j, sorted({p for v in unknown.values() for p in v["no_frame"]}),
                              f"old panes had no view frame for {float(want.get('unknown_seconds', UNKNOWN_SECONDS)):g} s")
        return False, dict(detail, waiting_for_frames=True)
    seen.pop(want["since"], None)
    if not problems:
        held.add(want["since"])
    return not problems, detail


def step_smoke_no_key_gaps(j, step):
    """The journey's last step: a round whose key-window checks were not judged (a host prompt took the keys) is
    not run, never a pass, also when run.py runs the journey without smoke-gate.py."""
    gaps = getattr(j, "smoke_key_gaps", [])
    if gaps:
        raise D.NotRun(f"{len(gaps)} key-window checks not judged: " + " | ".join(gaps)[:600])
    return {"key_gaps": 0}


# ---- TIP RED 1193: keys posted in the same event-queue drain as the key that makes the terminal ------------------

# US ANSI virtual key codes (Carbon kVK_*): the keys a line of the journeys uses.
_KEYCODES = {**{c: k for c, k in zip("asdfhgzxcvbqweryt", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17])},
             "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
             "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
             "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50}
_SHIFTED = {"$": "4", "(": "9", ")": "0", "*": "8", "!": "1", "@": "2", "#": "3", "%": "5", "^": "6", "&": "7",
            "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", '"': "'", "<": ",", ">": ".", "?": "/", "~": "`"}
_MODS = {"cmd": 55, "shift": 56, "option": 58, "control": 59}
_RETURN = 36


def _seq_key(code, mods=(), gap=0.0):
    """Key-down and key-up of CODE with MODS held: the steps of a debug.key sequence."""
    steps = [{"key_code": _MODS[m], "down": True, "after_ms": gap if i == 0 else 0} for i, m in enumerate(mods)]
    steps += [{"key_code": code, "down": True, "after_ms": 0 if mods else gap}, {"key_code": code, "down": False}]
    steps += [{"key_code": _MODS[m], "down": False} for m in reversed(mods)]
    return steps


def _seq_text(text, gap):
    steps = []
    for ch in text:
        if ch in _SHIFTED:
            steps += _seq_key(_KEYCODES[_SHIFTED[ch]], ("shift",), gap)
        elif ch.lower() in _KEYCODES and ch.isupper():
            steps += _seq_key(_KEYCODES[ch.lower()], ("shift",), gap)
        elif ch in _KEYCODES:
            steps += _seq_key(_KEYCODES[ch], (), gap)
        else:
            raise D.StepError(f"smoke_burst: no key code for {ch!r}")
    return steps


def _holds(j):
    """{hold path: keys it held since launch} (debug.input late_keys `holds`), or None on a build without it."""
    try:
        reply = j.app.rpc("debug.input", {"action": "late_keys", "since_launch": True}) or {}
    except D.StepError:
        return None
    holds = reply.get("holds") if isinstance(reply, dict) else None
    if not isinstance(holds, list):
        return None
    out = {}
    for h in holds:
        stage = h.get("stage") if isinstance(h.get("stage"), dict) else {}
        out[str(h.get("path"))] = int(stage.get("count") or 0)
    return out


# debug.key sequence errors that mean the journey's request was wrong (a red of the journey, never "not run").
_BURST_JOURNEY_ERRORS = ("each step needs key_code and down", "key_window must be shell or page")


def step_smoke_hold_path(j, step):
    """TIP RED 1193 counts a round only when its keys took the hold path (cmux-ad 11:05Z): at least one key typed at
    once after a Cmd-D was held by the app's router (debug.key handled_by "app"), or a burst's hold counter rose.
    Else the round is not run ("hold path not proven"): a pass with every key handled by the focused view (responder)
    proves nothing about the hold. Runs after the round's checks, so a failure on any path still counts as a failure;
    the step records each line's paths either way."""
    typed = [t for t in getattr(j, "smoke_typed_paths", []) if t["line"] in set(j.sub(step.get("lines", [])))] \
        if step.get("lines") else getattr(j, "smoke_typed_paths", [])
    lines = [{"line": t["line"], "held": t["paths"].count("app"), "first": t["paths"][0] if t["paths"] else None,
              "paths": sorted(set(t["paths"]))} for t in typed]
    burst = getattr(j, "smoke_burst_holds", "none")
    held = sum(t["held"] for t in lines) + (sum(burst.values()) if isinstance(burst, dict) else 0)
    # `held_marks`: key steps (by their mark, e.g. the second Cmd-D) whose own key must be held too.
    marks = {}
    specs = j.spec.get("steps", []) if isinstance(getattr(j, "spec", None), dict) else []
    for record in getattr(j, "steps", []):
        index = record.get("index", 0) - 1
        mark = specs[index].get("mark") if 0 <= index < len(specs) else None
        if mark in step.get("held_marks", []):
            reply = (record.get("result") or {}).get("reply") if isinstance(record.get("result"), dict) else None
            if not isinstance(reply, dict):
                marks[mark] = {"handled_by": None, "trace": None, "held": False}
                continue
            trace = [str(t) for t in reply.get("trace") or []]
            # "app" is any router intercept: a chord the router RUNS at once (no creation pending) is "app" too, and
            # its dispatch adds a "dispatcher: <decision>" trace line; a held key returns from capture before that.
            ran = [t for t in trace if t.startswith("dispatcher:")]
            marks[mark] = {"handled_by": str(reply.get("handled_by")), "trace": trace[:8],
                           "held": reply.get("handled_by") == "app" and not ran}
    result = {"hold_path": held > 0, "held_keys": held, "lines": lines, "burst_holds": burst, "marks": marks}
    if step.get("creation_held"):
        # The creation hold's own report proves the hold path: creation N stayed pending (its reply held by the hook)
        # while the keys after it were typed, and the next creation started meanwhile. The key paths are data only.
        pending, reply = _creation_proof(j, int(step["creation_held"]))
        result.update({"creation_pending": pending, "creation_release": reply, "hold_path": pending})
        if not pending:
            raise D.NotRun(f"hold path not proven: creation {step['creation_held']} was not held while the keys "
                           f"were typed (release reply {json.dumps(reply)[:300]}) ({json.dumps(result)[:400]})")
        return result
    why = []
    if held <= 0:
        why.append("no key typed at once was handled_by app" if lines else "no typed line recorded")
        if burst is None:
            why.append("this build has no debug.input late_keys hold counter for the burst")
    if step.get("every_line"):
        why += [f"no key of {t['line']!r} was held" for t in lines if t["held"] <= 0]
        why += [f"line {line!r} was not typed" for line in j.sub(step.get("lines", [])) if line not in {t["line"] for t in lines}]
    why += [f"the key of step {m!r} was not held (handled_by {(marks.get(m) or {}).get('handled_by')!r}, "
            f"trace {(marks.get(m) or {}).get('trace')!r})" for m in step.get("held_marks", [])
            if not (marks.get(m) or {}).get("held")]
    if why:
        result["hold_path"] = False
        raise D.NotRun(f"hold path not proven: {'; '.join(why)} ({json.dumps(result)[:500]})")
    return result


def step_smoke_creation(j, step):
    """The P0 1193 owner's DEBUG hook (#29301): ACTION "hold" (`debug.creation.hold {n}`: the n-th creation that
    starts keeps its daemon reply, so it stays pending) or "release" (`debug.creation.release {n}`, or every hold with
    no n). Records each reply for smoke_hold_path. A build without the hook (feat, a dogfood line) cannot run the
    journey: not run, never a red."""
    method = "debug.creation." + step["action"]
    params = {"n": step["n"]} if "n" in step else {}
    try:
        reply = j.app.rpc(method, params)
    except D.StepError as error:
        text = str(error)
        if "method_not_found" in text or "unknown method" in text.lower() or "not found" in text.lower():
            raise D.NotRun(f"this build has no {method} (the creation hold of #29301): {text[:200]}")
        raise
    j.smoke_creation = {**getattr(j, "smoke_creation", {}), step["action"]: reply, step["action"] + "_at": D.now()}
    return {"reply": reply}


def step_smoke_wait_new_view(j, step):
    """After a key that makes a terminal (Cmd-D) while its creation is held (smoke_creation hold): waits, at most
    TIMEOUT s (default 5), until AppKit's first responder of the key window is a terminal view inside another pane than
    the one focused at the smoke_snapshot SINCE (the pane that was split): the new pane's early view has the keyboard
    (debug.focus `appkit.first_responder` == "TerminalSurfaceView" and `appkit.classified` == "content:<pane>"; the
    focus model's `focused` moves in the key's own turn, before the view takes the keyboard). The P0 1193 owner: from
    then on the keys typed for it, the second Cmd-D too, go straight through while creation 1 is still pending (the race
    of TIP RED 1193). Reads only; polls every 75 ms. Not reached in time: recorded, the journey goes on (smoke_hold_path
    then judges whether the race happened)."""
    old = (getattr(j, "smoke_snapshots", {}).get(step.get("since", "before_splits")) or {}).get("focused_pane")
    if not old:  # without the split pane, the old pane's own terminal would pass at once
        return {"reached": False, "after_s": 0, "last": "no focused pane in the smoke_snapshot before the split"}
    end, last, t0 = D.now() + float(step.get("timeout", 5)), None, D.now()
    while D.now() < end:
        report = j.app.rpc("debug.focus") or {}
        for w in report.get("windows", []) if isinstance(report, dict) else []:
            kit = w.get("appkit") or {}
            where = str(kit.get("classified") or "")
            last = {"window": w.get("id"), "is_key": w.get("is_key"), "first_responder": kit.get("first_responder"),
                    "classified": where, "split_pane": old}
            if not w.get("is_key") or kit.get("first_responder") != "TerminalSurfaceView" or not where.startswith("content:"):
                continue
            pane = where[len("content:"):]
            if pane and pane != old:
                return {"reached": True, "after_s": round(D.now() - t0, 3), "pane": pane, "split_pane": old}
        time.sleep(0.075)
    return {"reached": False, "after_s": round(D.now() - t0, 3), "last": last}


def _creation_proof(j, n):
    """(creation N was pending when it was released, and a later creation had started, the release reply)."""
    seen = getattr(j, "smoke_creation", {})
    reply = seen.get("release")
    if not isinstance(reply, dict):
        return False, reply
    ints = lambda key: [int(x) for x in reply.get(key) or [] if isinstance(x, (int, float))]
    # "started" >= N + 1: creation N and the next one (the second Cmd-D) both started after the hold was armed.
    started = int(reply.get("started") or 0) >= n + 1
    if "resumed" in reply:  # a hook that names the creations it really resumed: the direct proof
        return started and n in ints("resumed"), reply
    # Else: "released" names N even when N never waited, so the proof is that N started under the armed hold and was
    # released before the hook's own 30 s limit (it would have gone on by itself). The non-optimistic split path
    # has no hook; it is not used by a key-made split.
    in_time = (seen.get("release_at", 0) - seen.get("hold_at", 0)) < 25
    return started and n in ints("released") + ints("held") and in_time, reply


def step_smoke_burst(j, step):
    """Plays BURST (a list of {key, modifiers} and {text, enter?}) as ONE `debug.key {sequence}`: real key events posted
    to the app's queue (its sendEvent, key router, hold and replay paths, as hardware keys), GAP_MS (default 0) apart.
    The keys after a key that makes a terminal (Cmd-D, Ctrl-`) are in the queue before that terminal exists, so the
    app must hold them for it and replay them there: the hold path, every time, without changing the app's timing.
    Needs the journey's window key (smoke_make_key; a whole-host lease): the sequence goes to the key window. Records
    the hold paths' counts before and after (debug.input late_keys holds, on builds that have it)."""
    if not getattr(j, "smoke_key_ok", False):
        raise D.NotRun(GAP + " (smoke_burst posts real key events to the key window)")
    gap = float(step.get("gap_ms", 0))
    steps = []
    for item in step["burst"]:
        if "text" in item:
            steps += _seq_text(j.sub(item["text"]), gap)
            if item.get("enter", True):
                steps += _seq_key(_RETURN, (), gap)
        else:
            key = item["key"]
            if key != "return" and key not in _KEYCODES:
                raise D.StepError(f"smoke_burst: no key code for key {key!r}")
            code = _RETURN if key == "return" else _KEYCODES[key]
            steps += _seq_key(code, tuple(item.get("modifiers", [])), gap)
        if item.get("mark"):
            j.marks[item["mark"]] = D.now()
    before = _holds(j)
    reply = j.app.rpc("debug.key", {"sequence": steps, "key_window": "shell", "window": j.key_window or _journey_window(j)}) or {}
    if not isinstance(reply, dict):
        raise D.StepError(f"debug.key sequence: no reply object: {json.dumps(reply)[:300]}")
    if reply.get("error"):
        if reply["error"] in _BURST_JOURNEY_ERRORS:
            raise D.StepError(f"debug.key sequence refused the journey's request: {reply['error']}")
        # The host's limit, not the build's (no key window, an inactive app, no event clock): no keys were posted.
        raise D.NotRun(GAP + f" (debug.key sequence refused: {str(reply['error'])[:200]})")
    time.sleep(float(reply.get("duration_ms") or 0) / 1000 + 1.0)  # until the last event was posted and dispatched
    key_now, windows = _main_key(j)
    if not key_now:
        # Posted keys go to the key window; with none, the app drops them (a host prompt took the key, not the build).
        raise D.NotRun(GAP + f" (the journey's window lost key status during the burst; windows {json.dumps(windows)[:200]})")
    after = _holds(j)
    held = None if before is None or after is None else {k: after.get(k, 0) - before.get(k, 0) for k in after}
    j.smoke_burst_holds = held
    return {"steps": len(steps), "reply": reply, "held_keys": held}


STEPS = {"smoke_burst": step_smoke_burst, "smoke_wait_new_view": step_smoke_wait_new_view, "smoke_creation": step_smoke_creation, "smoke_hold_path": step_smoke_hold_path, "smoke_no_key_gaps": step_smoke_no_key_gaps, "smoke_ready": step_smoke_ready, "smoke_make_key": step_smoke_make_key, "smoke_type_now": step_smoke_type_now,
         "smoke_remember_workspaces": step_smoke_remember_workspaces, "smoke_close_all": step_smoke_close_all,
         "smoke_snapshot": step_smoke_snapshot, "smoke_adopt_line": step_smoke_adopt_line,
         "smoke_long_line": step_smoke_long_line, "smoke_widths": step_smoke_widths}
CONDITIONS = {"smoke_workspaces": ("app", cond_smoke_workspaces), "smoke_key_window": ("app", cond_smoke_key_window),
              "smoke_app_lines": ("app", cond_smoke_app_lines), "smoke_daemon_lines": ("daemon", cond_smoke_daemon_lines),
              "smoke_new_terminals": ("daemon", cond_smoke_new_terminals), "smoke_frame": ("frame", cond_smoke_frame),
              "smoke_panes": ("app", cond_smoke_panes), "smoke_r3": ("daemon", cond_smoke_r3),
              "smoke_same_widths": ("app", cond_smoke_same_widths)}
# Re-read every poll and through an expect's `settle`: an old column that changes width a moment after the new one
# shows (an animation, a late layout pass), or a terminal size that snaps back after it agreed, must fail.
NEGATIVE = ("smoke_same_widths", "smoke_r3")
