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
  smoke_same_widths  {since, new}     every column of the snapshot SINCE (matched by its panes) has EXACTLY its old width
                                      (0.01 point; float view frames), and the workspace has NEW more columns; each old
                                      and new width in the result
"""
import json
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
    window = _journey_window(j)
    reply = j.app.rpc("debug.window.focus", {"window": window}) or {}
    took = isinstance(reply, dict) and reply.get("key") == window
    j.smoke_key_ok = took
    j.smoke_key_reply = reply
    return {"window": window, "reply": reply, "key_window_now": took}


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
            raise D.NotRun(GAP + f" ({how}; windows now {json.dumps(windows)[:200]})")
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
    return {"typed": text, "keys": len(replies), "at": round(sent, 3), "at_once": waited is None, "waited_hold_s": waited,
            "handled_by": sorted({str(r.get("handled_by")) for r in replies if isinstance(r, dict)})}


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


def cond_smoke_key_window(j, want, cache):
    """A main window is the app's key window: a read (debug.window_list), so the check does not make it key."""
    key_now, windows = _main_key(j)
    if not key_now and _diagnostic(j) and not getattr(j, "smoke_key_ok", False) \
            and not any(w["key"] is True for w in windows) and any(w["kind"] == "main" for w in windows):
        # Diagnostic on a slot: no window was ever key; the step's other checks still count.
        return True, {"windows": windows, "diagnostic": "no key window on this slot (not checked)"}
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


def cond_smoke_r3(j, want, cache):
    rec = _named(j, want["pane"])
    row, grid = _pane_grid(j, rec["pane"], cache)
    surface, info = (row or {}).get("surface") or {}, (row or {}).get("grid") or {}
    fit, drawn = _grid(surface.get("fit_grid")), _grid(surface.get("drawn_grid"))
    bounds = None
    cw, ch = info.get("cell_width"), info.get("cell_height")
    if cw and ch and "frame_width" in info:
        pad_x = max(0.0, info.get("origin_x", 0) - info.get("frame_x", 0))
        pad_y = max(0.0, info.get("origin_y", 0) - info.get("frame_y", 0))
        bounds = (int((info["frame_width"] - 2 * pad_x + 1e-6) // cw), int((info["frame_height"] - 2 * pad_y + 1e-6) // ch))
    screen = j.app.screen(rec["term"])
    daemon = (screen.get("cols"), screen.get("rows"))
    topo_size = None
    for _ws, pane, tab, term in j.places(j.topology()):
        if term == rec["term"]:
            topo_size = (tab.get("columns"), tab.get("rows"))
    pty = _pty_size(screen.get("text"), j.sub(want["pty_tag"])) if want.get("pty_tag") else None
    sizes = {"grid": grid, "fit_grid": fit, "drawn_grid": drawn, "fit_bounds": bounds, "pty": pty, "daemon": daemon,
             "topology": topo_size}
    detail = {"pane": rec["pane"], "terminal": rec["term"], "sizes": sizes, "frame": [info.get("frame_width"), info.get("frame_height")],
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


# ---- R3b: new columns never resize old ones (cmux-ad, Lawrence's P0 rule) ------------------------

def _widths(j, workspace, cache=None):
    """{column index: width in points} of every column of WORKSPACE: the topology's `column` of each pane, and the
    union of its panes' horizontal extents in the window (debug.surfaces: the view frame, floats; content_size,
    whole points, only when a pane has no frame). Panes stacked in one column share its width."""
    panes = {p.get("pane"): p for p in (_surfaces(j, cache) if cache is not None else j.app.panes())}
    extents = {}
    for ws in j.topology().get("workspaces", []):
        if ws.get("id") != workspace:
            continue
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                column = pane.get("column")
                row = panes.get(pane.get("id")) or {}
                grid = row.get("grid") if isinstance(row.get("grid"), dict) else {}
                if "frame_width" in grid:
                    x0, w = float(grid.get("frame_x", 0.0)), float(grid["frame_width"])
                else:
                    size = str(row.get("content_size") or "")
                    head = size.split("x")[0] if "x" in size else ""
                    if not head.replace(".", "", 1).isdigit():
                        extents.setdefault(column, None)
                        continue
                    x0, w = None, float(head)
                if extents.get(column, 0) is None:
                    continue
                spans = extents.setdefault(column, [])
                spans.append((x0, w))
    out = {}
    for column, spans in extents.items():
        if not spans:
            out[str(column)] = None
        elif all(x0 is not None for x0, _w in spans):
            out[str(column)] = round(max(x0 + w for x0, w in spans) - min(x0 for x0, _w in spans), 2)
        else:
            out[str(column)] = round(max(w for _x0, w in spans), 2)
    return out


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


def step_smoke_widths(j, step):
    workspace = _current_workspace(j)
    widths, columns = _widths(j, workspace), _columns(j, workspace)
    if not hasattr(j, "smoke_width_snaps"):
        j.smoke_width_snaps = {}
    j.smoke_width_snaps[step["name"]] = {"workspace": workspace, "widths": widths, "columns": columns}
    return {"workspace": workspace, "widths": widths, "columns": columns}


def cond_smoke_same_widths(j, want, cache):
    snap = getattr(j, "smoke_width_snaps", {}).get(want["since"])
    if snap is None:
        return False, {"error": f"no smoke_widths named {want['since']!r}"}
    # Columns are matched by their content, not their index: a new column after the focused one shifts the
    # indexes of the columns right of it. Each old column is its set of panes.
    old_cols, new_cols = snap["columns"], _columns(j, snap["workspace"], cache)
    widths_now = _widths(j, snap["workspace"], cache)
    changed, gone = {}, []
    for index, members in old_cols.items():
        match = next((k for k, m in new_cols.items() if set(members) <= set(m)), None)
        before = snap["widths"].get(index)
        if match is None:
            gone.append(index)
            continue
        after = widths_now.get(match)
        if before is None or after is None or abs(before - after) > 0.01:
            changed[index] = {"old": before, "new": after, "panes": members}
    matched = {next((k for k, m in new_cols.items() if set(members) <= set(m)), None) for members in old_cols.values()}
    added = sorted(k for k in new_cols if k not in matched)
    problems = []
    if changed:
        problems.append(f"{len(changed)} existing columns changed width")
    if gone:
        problems.append(f"{len(gone)} existing columns are gone")
    if len(added) != int(want.get("new", 1)):
        problems.append(f"{len(added)} new columns, not {want.get('new', 1)}")
    return not problems, {"problems": problems, "changed": changed, "gone": gone, "added": added,
                          "old_widths": snap["widths"], "new_widths": widths_now, "old_columns": old_cols, "new_columns": new_cols}

STEPS = {"smoke_ready": step_smoke_ready, "smoke_make_key": step_smoke_make_key, "smoke_type_now": step_smoke_type_now,
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
