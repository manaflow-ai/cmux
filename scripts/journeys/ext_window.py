"""Window and pane steps and conditions for the journeys (group window-pane-resize).

driver.py loads this file (load_extensions) on the mini, where it runs under the stock /usr/bin/python3
(3.9, standard library only). It must not import driver.py (that runs as __main__ there): install()
gets the driver module instead.

What a person does is played through the app's own input paths:

  - a drag of the window's edge or corner, or of a divider between panes: `debug.mouse` down, then one
    drag event per display frame (60 Hz) with the button held, then up. The events go through the app's
    event queue, so AppKit's own live-resize tracking (or the layout's divider drag) reads them, as it
    reads a real drag; the person's pointer never moves;
  - keys (Cmd-D, Cmd-Shift-D, Cmd-W, Cmd-Shift-Return, Ctrl-Cmd-F, Cmd-Shift-N): the driver's `key` step
    (`debug.key`, the key router's real path);
  - menu-only actions with no default key (Window > Zoom): `action.run`, the route the menu item takes.

What the person sees is read three ways, as the driver requires:

  - app state: the window's frame and screen (`debug.layers`), full screen (`debug.windows`), each
    pane's frame, grid, fitted grid and drawn grid (`debug.surfaces`: the terminal view's frame in the
    window, Ghostty's cell size, the grid the view fits, the grid Ghostty drew and the grid the PTY owner
    has), its viewport text;
  - the daemon: its screen's size (cols x rows) and text (`cmux terminal ID screen read`), and the PTY's
    own size as the shell reads it (`stty size`, typed by the journey);
  - the frame: the window's snapshot read with text recognition (the driver's `frame_text`).

Steps (`do`):
  name_pane     {as, window?: new}         names the current pane (after new_terminal); window: new
                                           fails unless it is in a window no named pane is in
  adopt_window  {}                         waits for a newly opened main window (after Cmd-Shift-N) and
                                           makes it key (without activating the app); keys and frames
                                           go to it
  adopt_pane    {as, window: same|new}     waits for the newly focused terminal pane (after a split or a
                                           new window) and makes it the current pane
  use_pane      {pane, click?}             makes a named pane current (its window gets keys and snapshots);
                                           click: true clicks into it first (`debug.mouse`), as a person
                                           does before typing there, and waits for its focus
  remember      {as, pane?}                keeps the window frame, the pane's frame and grid as NAME
  window_place  {fraction: [x, y, w, h]}   set-up, not under test: puts the window at these fractions of
                                           its screen's visible frame (top-left origin) and waits for it
  window_drag   {edge, by: [dx, dy], events?, hz?, press?, release?, mark?}
                                           drags the window's `bottom-right` (default), `right` or `bottom`
                                           edge by dx, dy points; press: false continues a drag left open
                                           (release: false), so checks can run while the window is in its
                                           live resize
  divider_drag  {between: [A, B], by, events?, hz?, mark?}
                                           drags the divider between named panes A (left or top) and B by
                                           `by` points along the split's axis
  action        {action, args?, mark?}     action.run as a menu item runs it (`origin: user`)
  leave_full_screen {}                     clean-up: Ctrl-Cmd-F until the window is out of full screen
  restore_window {from}                    clean-up: the window back to a remembered frame
  close_window  {pane} | {window: new}     clean-up: Ctrl-Cmd-W in the named pane's window (or the
                                           adopted new window)

Conditions (inside `expect.all`):
  window_frame  {from, dw?, dh?, tol?} | {fills: visible|screen, tol?} | {same_as, tol?}       app
  full_screen   true | false                                                                     app
  grid_fits     {pane?, vs?, cols?: wider|narrower|same, rows?: taller|shorter|same}             app
                the pane shows (not blank), its grid equals the grid the view fits and the grid Ghostty
                drew, the daemon's screen has that size, and the grid fits the view's frame at Ghostty's
                cell size (within one cell); `vs` compares with a remembered grid
  pane_frame    {pane?, vs, w?, h?, tol?} | {pane?, right_of} | {pane?, below}                    app
                w / h: the pane's width / height as a fraction of the remembered pane's
  pane_state    {pane, fields: {...}}                                                            app
  at_bottom     {pane?, lines?}       the app's viewport ends with the daemon screen's last lines    app
  output_advances {pattern, by, pane?}  the viewport's highest counter rose by `by`              app
  pty_size      TAG | {tag, pane?}    the shell's `echo TAG $(stty size)` line: the PTY's rows and
                                      cols equal the daemon screen's and the app's grid           daemon
  pane_frame_text TEXT | {text, pane?}  a fresh snapshot of the pane's window (kept as check-NN.png)
                                      shows TEXT inside the pane to text recognition: the rows
                                      around it, else the pane, else the whole window      frame
"""
import json
import re
import time

D = None  # the driver module (install)


def install(driver):
    global D
    D = driver


# ---- reads -----------------------------------------------------------------------------------

def windows(j):
    """{state id: {id, number, frame, visible, screen}} of the app's main windows (debug.layers)."""
    report = j.app.rpc("debug.layers") or {}
    out = {}
    for w in report.get("windows") or []:
        out[w.get("id")] = {"id": w.get("id"), "number": w.get("window_number"), "frame": w.get("frame"),
                            "visible": w.get("screen_visible_frame"), "screen": w.get("screen_frame")}
    return out


def all_panes(j, cache=None):
    if cache is not None and "ext_panes" in cache:
        return cache["ext_panes"]
    report = j.app.rpc("debug.surfaces", {"text": True}) or {}
    panes = []
    for w in report.get("windows") or []:
        for p in w.get("panes") or []:
            if isinstance(p, dict):
                p = dict(p, window_number=w.get("window"))
                panes.append(p)
    if cache is not None:
        cache["ext_panes"] = panes
    return panes


def named(j, name):
    """A named pane's record, or the current pane's when name is None."""
    if not name:
        return {"pane": j.pane, "term": j.term, "host_pid": j.host_pid, "window": current_window(j)}
    panes = getattr(j, "ext_panes", {})
    if name not in panes:
        raise D.StepError(f"no pane named {name!r} (name_pane or adopt_pane first)")
    return panes[name]


def pane_row(j, key, cache=None):
    return next((p for p in all_panes(j, cache) if p.get("pane") == key), None)


def window_of_pane(j, key, cache=None):
    row = pane_row(j, key, cache)
    if row is None:
        return None
    grid = row.get("grid") or {}
    if grid.get("window"):
        return grid["window"]
    number = row.get("window_number")
    for w in windows(j).values():
        if str(w.get("number")) == str(number):
            return w["id"]
    return None


def current_window(j):
    if getattr(j, "ext_window", None):
        return j.ext_window
    if j.pane:
        j.ext_window = window_of_pane(j, j.pane)
        return j.ext_window
    first = next(iter(windows(j)), None)
    return first


def window_rec(j, wid):
    found = windows(j)
    if wid not in found:
        raise D.StepError(f"window {wid} is not in debug.layers (windows {list(found)[:4]})")
    return found[wid]


def parse_grid(text):
    m = re.fullmatch(r"(\d+)x(\d+)", str(text or ""))
    return (int(m.group(1)), int(m.group(2))) if m else None


def frame_of(row):
    """A pane's terminal view frame in window points from the top-left: (x, y, w, h)."""
    grid = (row or {}).get("grid") or {}
    if "frame_width" not in grid:
        return None
    return (grid["frame_x"], grid["frame_y"], grid["frame_width"], grid["frame_height"])


def daemon_terminal_of(j, pane_key, workspace_id=None, avoid=()):
    """The daemon terminal id of the selected tab of `pane_key` (topology from snapshot.get)."""
    snap = j.app.rpc("snapshot.get") or {}
    topo = snap.get("topology") if isinstance(snap, dict) else None
    exact, in_workspace = [], []
    for ws in (topo or {}).get("workspaces", []):
        for screen in ws.get("screens", []):
            for pane in screen.get("panes", []):
                for tab in pane.get("tabs", []):
                    term = tab.get("terminal")
                    term = term.get("id") if isinstance(term, dict) else term
                    if not term:
                        continue
                    if pane.get("id") == pane_key:
                        exact.append((bool(tab.get("selected")), str(term)))
                    elif workspace_id and ws.get("id") == workspace_id and str(term) not in avoid:
                        in_workspace.append((bool(tab.get("selected")), str(term)))
    if exact:
        return sorted(exact, reverse=True)[0][1]
    if len(in_workspace) == 1:
        return in_workspace[0][1]
    raise D.StepError(f"no daemon terminal for pane {pane_key} (workspace {workspace_id}: candidates {in_workspace[:4]})")


# ---- steps -----------------------------------------------------------------------------------

def _known(j):
    if not hasattr(j, "ext_panes"):
        j.ext_panes = {}
    if not hasattr(j, "ext_seen"):
        j.ext_seen = set()
    return j.ext_panes


def _record_current(j, name):
    panes = _known(j)
    j.ext_window = window_of_pane(j, j.pane)
    panes[name] = {"pane": j.pane, "term": j.term, "host_pid": j.host_pid, "window": j.ext_window}
    j.ext_seen |= {p.get("pane") for p in all_panes(j)}
    if not hasattr(j, "ext_windows_seen"):
        j.ext_windows_seen = set(windows(j))
    return panes[name]


def step_name_pane(j, step):
    if not j.pane or not j.term:
        raise D.StepError("name_pane: no current pane (new_terminal first)")
    others = {p["window"] for p in _known(j).values()}
    rec = _record_current(j, step["as"])
    if step.get("window") == "new" and rec["window"] in others:
        raise D.StepError(f"name_pane {step['as']!r}: pane {rec['pane']} is in window {rec['window']}, "
                          f"not a new window (windows of the named panes: {sorted(others)})")
    j.key_window = j.app.snapshot_window = rec["window"]
    return rec


def step_adopt_window(j, step):
    """Waits for a main window that was not open at the journey's first named pane (after Cmd-Shift-N),
    shown and on screen, and makes it the window keys and snapshots go to (debug.window.focus: key,
    without activating the app)."""
    _known(j)
    old = getattr(j, "ext_windows_seen", set())
    end = D.now() + float(step.get("timeout", 20))
    found = {}
    while D.now() < end:
        found = windows(j)
        new = [w for w in found if w not in old]
        if new:
            wid = new[0]
            focus = j.app.rpc("debug.window.focus", {"window": wid})
            j.ext_window = j.key_window = j.app.snapshot_window = wid
            j.ext_windows_seen = set(found)
            j.ext_new_window = wid
            return {"window": wid, "frame": found[wid]["frame"], "focus": focus}
        time.sleep(0.2)
    raise D.StepError(f"no new window opened within {step.get('timeout', 20)} s (windows {sorted(found)})")


def step_adopt_pane(j, step):
    _known(j)
    seen = set(j.ext_seen)
    terms = {p["term"] for p in j.ext_panes.values()}
    want_window = step.get("window", "same")
    old_windows = getattr(j, "ext_windows_seen", set(windows(j)))
    end = D.now() + float(step.get("timeout", 20))
    last = "no new focused terminal pane"
    while D.now() < end:
        for row in all_panes(j):
            key = row.get("pane")
            if key in seen or not row.get("focused") or row.get("kind") != "terminal":
                continue
            wid = window_of_pane(j, key)
            if want_window == "new" and wid in old_windows:
                continue
            if want_window == "same" and wid != current_window(j):
                continue
            try:
                term = daemon_terminal_of(j, key, row.get("workspace"), avoid=terms)
                if j.app.screen(term)["text"].strip():
                    j.pane, j.term = key, term
                    j.host_pid = int(row["host_pid"]) if row.get("host_pid") else None
                    j.ext_window = wid
                    j.key_window = wid
                    j.app.snapshot_window = wid
                    rec = _record_current(j, step["as"])
                    j.ext_windows_seen = set(windows(j))
                    return dict(rec, workspace=row.get("workspace"), frame=frame_of(row), grid=row.get("surface", {}).get("grid"))
                last = f"pane {key}: terminal {term} has an empty screen"
            except D.StepError as error:
                last = str(error)
        time.sleep(0.2)
    raise D.StepError(f"adopt_pane {step['as']!r} ({want_window} window): {last[-400:]}")


def step_use_pane(j, step):
    release_open_drag(j)
    rec = named(j, step["pane"])
    j.pane, j.term, j.host_pid, j.ext_window = rec["pane"], rec["term"], rec["host_pid"], rec["window"]
    j.key_window = rec["window"]
    j.app.snapshot_window = rec["window"]
    if not step.get("click"):
        return rec
    # A person clicks into the pane to type there: a click at the center of its content.
    reply = j.app.rpc("debug.mouse", {"window": rec["window"], "pane": rec["pane"], "action": "click"})
    end = D.now() + float(step.get("timeout", 5))
    while D.now() < end:
        row = pane_row(j, rec["pane"])
        if row and row.get("focused"):
            return dict(rec, click=reply)
        time.sleep(0.1)
    raise D.StepError(f"a click in pane {step['pane']} did not focus it: {json.dumps(reply)[:200]}")


def step_remember(j, step):
    rec = named(j, step.get("pane"))
    row = pane_row(j, rec["pane"])
    if row is None:
        raise D.StepError(f"remember: pane {rec['pane']} is not in debug.surfaces")
    win = window_rec(j, rec["window"])
    surface = row.get("surface") or {}
    kept = {"window": win["frame"], "visible": win["visible"], "screen": win["screen"], "pane_frame": frame_of(row),
            "grid": parse_grid(surface.get("grid")), "fit_grid": surface.get("fit_grid")}
    if not hasattr(j, "ext_remembered"):
        j.ext_remembered = {}
    j.ext_remembered[step["as"]] = kept
    return kept


def remembered(j, name):
    kept = getattr(j, "ext_remembered", {})
    if name not in kept:
        raise D.StepError(f"nothing remembered as {name!r}")
    return kept[name]


def wait_frame(j, wid, target, timeout=10, tol=2):
    end = D.now() + timeout
    frame = None
    while D.now() < end:
        frame = window_rec(j, wid)["frame"]
        if frame and all(abs(a - b) <= tol for a, b in zip(frame, target)):
            return frame
        time.sleep(0.1)
    raise D.StepError(f"the window frame is {frame}, not {target}")


def step_window_place(j, step):
    wid = current_window(j)
    win = window_rec(j, wid)
    vx, vy, vw, vh = win["visible"]
    fx, fy, fw, fh = step["fraction"]
    # The frame before (`restore_window {"from": "before-place"}` in `finally` puts it back).
    if not hasattr(j, "ext_remembered"):
        j.ext_remembered = {}
    j.ext_remembered.setdefault("before-place", {"window": win["frame"]})
    w, h = round(vw * fw), round(vh * fh)
    x = round(vx + vw * fx)
    y = round(vy + vh - vh * fy - h)
    reply = j.app.rpc("debug.window_frame", {"window": wid, "frame": [x, y, w, h]})
    frame = wait_frame(j, wid, [x, y, w, h])
    # The panes follow the window on their next layout: wait for every pane to fit its view again.
    return {"frame": frame, "visible": win["visible"], "reply": reply}


def _pace(t0, index, hz):
    due = t0 + index / float(hz)
    left = due - time.monotonic()
    if left > 0:
        time.sleep(left)


def step_window_drag(j, step):
    wid = current_window(j)
    edge = step.get("edge", "bottom-right")
    dx, dy = step.get("by", [0, 0])
    events, hz = int(step.get("events", 30)), float(step.get("hz", 60))
    win = window_rec(j, wid)
    x0, y0, w, h = win["frame"]
    vx, vy, vw, vh = win["visible"]
    drag = getattr(j, "ext_drag", None)
    if step.get("press", True):
        # Window-local points from the top-left: the edge the person grabs.
        start = {"bottom-right": (w - 1, h - 1), "right": (w - 1, h / 2), "bottom": (w / 2, h - 1)}[edge]
        j.ext_drag = drag = {"x": start[0], "y": start[1], "window": wid, "edge": edge, "events": 0}
        j.app.rpc("debug.mouse", {"window": wid, "action": "down", "x": start[0], "y": start[1]})
    elif not drag:
        raise D.StepError("window_drag press: false, but no drag is open")
    # Keep the window on its screen's visible frame (the top-left corner stays put in a resize from the
    # bottom or right): a drag past it only presses the window against the screen edge.
    room_right = (vx + vw) - (x0 + w)
    room_down = y0 - vy
    clamp = {"dx": dx, "dy": dy}
    dx = min(dx, max(0, room_right - 4)) if dx > 0 else dx
    dy = min(dy, max(0, room_down - 4)) if dy > 0 else dy
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    fx, fy = drag["x"], drag["y"]
    t0, rtt = time.monotonic(), []
    for i in range(1, events + 1):
        x, y = fx + dx * i / events, fy + dy * i / events
        t = time.monotonic()
        j.app.rpc("debug.mouse", {"window": wid, "action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1,
                                  "press": False, "release": False})
        rtt.append(round((time.monotonic() - t) * 1000, 1))
        _pace(t0, i, hz)
    drag["x"], drag["y"], drag["events"] = fx + dx, fy + dy, drag["events"] + events
    result = {"window": wid, "edge": edge, "asked": clamp, "dragged": [dx, dy], "events": events,
              "event_rpc_ms_max": max(rtt) if rtt else None, "frame_before": win["frame"]}
    if step.get("release", True):
        j.app.rpc("debug.mouse", {"window": wid, "action": "up", "x": drag["x"], "y": drag["y"]})
        j.ext_drag = None
        result["released"] = True
        result["settle"] = settle_queue(j)
    result["frame_after"] = window_rec(j, wid)["frame"]
    return result


def settle_queue(j, timeout=5.0):
    """Waits until the app's event queue has drained past the posted mouse-up.

    `debug.mouse` posts its events to the app's queue, where AppKit's resize tracking (or the
    layout's divider drag) reads them in a loop; `debug.key` dispatches at once. A key sent right
    after the release would reach the app before the queued mouse-up ends the tracking loop, which
    no person can do: their key is queued behind the mouse-up. So a right-button release outside the
    window's content (no view gets it; nothing reacts) is queued behind it (`debug.mouse`, the same
    queue), and the input journal, which records what `sendEvent` dispatches, shows it once the
    tracking loop ended. (`debug.key` `sequence` would be the natural marker, but a capture slot's
    app cannot make the CGEvents it needs: "no event timestamp".)"""
    before = j.app.rpc("debug.journal", {"last": 1}) or {}
    if not (before.get("stats") or {}).get("enabled"):
        time.sleep(0.5)  # no journal on this build: nothing observable; the drag's events drain meanwhile
        return {"settled_by": "wait 0.5 s (input journal off)"}
    last = max([e.get("seq", -1) for e in before.get("entries") or []] or [-1])
    t0 = D.now()
    wid = current_window(j)
    j.app.rpc("debug.mouse", {"window": wid, "action": "up", "button": "right", "x": -40, "y": -40})
    while D.now() - t0 < timeout:
        entries = (j.app.rpc("debug.journal", {"last": 40}) or {}).get("entries") or []
        if any(e.get("seq", -1) > last and '"up"' in json.dumps(e) for e in entries):
            return {"settled_by": "queued marker release dispatched", "ms": round((D.now() - t0) * 1000)}
        time.sleep(0.05)
    raise D.StepError(f"the app's event queue did not drain past the drag's mouse-up within {timeout} s "
                      f"(a queued marker never reached sendEvent: the drag's tracking loop may still run)")


def step_divider_drag(j, step):
    a, b = (named(j, n) for n in step["between"])
    ra, rb = pane_row(j, a["pane"]), pane_row(j, b["pane"])
    fa, fb = frame_of(ra), frame_of(rb)
    if not fa or not fb:
        raise D.StepError(f"divider_drag: no frame for {step['between']}: {fa} {fb}")
    wid = a["window"]
    by = float(step["by"])
    if fb[0] >= fa[0] + fa[2] - 1:  # B is right of A: a vertical divider
        x = (fa[0] + fa[2] + fb[0]) / 2
        top, bottom = max(fa[1], fb[1]), min(fa[1] + fa[3], fb[1] + fb[3])
        start, delta = (x, (top + bottom) / 2), (by, 0)
    elif fb[1] >= fa[1] + fa[3] - 1:  # B is below A: a horizontal divider
        y = (fa[1] + fa[3] + fb[1]) / 2
        left, right = max(fa[0], fb[0]), min(fa[0] + fa[2], fb[0] + fb[2])
        start, delta = ((left + right) / 2, y), (0, by)
    else:
        raise D.StepError(f"divider_drag: {step['between']} are not side by side: {fa} {fb}")
    events, hz = int(step.get("events", 30)), float(step.get("hz", 60))
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    # The pointer rests over the divider first (its hover), then presses and drags as a person does.
    j.app.rpc("debug.mouse", {"window": wid, "action": "move", "x": start[0], "y": start[1]})
    j.app.rpc("debug.mouse", {"window": wid, "action": "down", "x": start[0], "y": start[1]})
    t0 = time.monotonic()
    for i in range(1, events + 1):
        x, y = start[0] + delta[0] * i / events, start[1] + delta[1] * i / events
        j.app.rpc("debug.mouse", {"window": wid, "action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1,
                                  "press": False, "release": False})
        _pace(t0, i, hz)
    end = (start[0] + delta[0], start[1] + delta[1])
    j.app.rpc("debug.mouse", {"window": wid, "action": "up", "x": end[0], "y": end[1]})
    settle = settle_queue(j)
    j.app.rpc("debug.mouse", {"window": wid, "action": "leave", "x": end[0], "y": end[1]})
    return {"from": start, "to": end, "frames_before": [fa, fb], "settle": settle}


def step_action(j, step):
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    # The control socket takes origin cli, mcp, script or remote (never user); the default is the
    # script's. The action runs through the same registry handler as its menu item.
    params = {"action": step["action"], "args": j.sub(step.get("args") or {}), "focus": True}
    return {"reply": j.app.rpc("action.run", params)}


def full_screen_of(j, wid):
    report = j.app.rpc("debug.windows") or {}
    for w in report.get("windows") or []:
        if w.get("id") == wid:
            return bool(w.get("full_screen"))
    return None


def step_leave_full_screen(j, step):
    release_open_drag(j)
    wid = current_window(j)
    if not full_screen_of(j, wid):
        return {"full_screen": False}
    j.app.rpc("debug.key", {"key": "f", "modifiers": ["control", "cmd"], "window": wid})
    end = D.now() + float(step.get("timeout", 15))
    while D.now() < end:
        if not full_screen_of(j, wid):
            time.sleep(1.0)  # clean-up: the exit animation ends before the next journey's window reads
            return {"full_screen": False, "left": True}
        time.sleep(0.2)
    raise D.StepError("the window stayed in full screen")


def release_open_drag(j):
    """Clean-up: a journey that failed while a drag held the button (`release: false`) leaves AppKit's
    resize tracking loop running, which would take the next journey's input. Release it."""
    drag = getattr(j, "ext_drag", None)
    if not drag:
        return None
    j.app.rpc("debug.mouse", {"window": drag["window"], "action": "up", "x": drag["x"], "y": drag["y"]})
    j.ext_drag = None
    return {"released_open_drag": True, "settle": settle_queue(j)}


def step_restore_window(j, step):
    released = release_open_drag(j)
    kept = remembered(j, step["from"])
    wid = current_window(j)
    target = [round(v) for v in kept["window"]]
    j.app.rpc("debug.window_frame", {"window": wid, "frame": target})
    return {"frame": wait_frame(j, wid, target, timeout=float(step.get("timeout", 10)), tol=4), "drag": released}


def step_close_window(j, step):
    release_open_drag(j)
    if step.get("window") == "new":
        wid = getattr(j, "ext_new_window", None)
        if not wid:
            return {"closed": None, "why": "no new window was adopted"}
    else:
        wid = named(j, step["pane"])["window"]
    reply = j.app.rpc("debug.key", {"key": "w", "modifiers": ["control", "cmd"], "window": wid})
    end = D.now() + float(step.get("timeout", 10))
    while D.now() < end:
        if wid not in windows(j):
            return {"closed": wid, "reply": reply}
        time.sleep(0.2)
    raise D.StepError(f"window {wid} is still open after Ctrl-Cmd-W: {json.dumps(reply)[:200]}")


STEPS = {"name_pane": step_name_pane, "adopt_window": step_adopt_window, "adopt_pane": step_adopt_pane, "use_pane": step_use_pane, "remember": step_remember,
         "window_place": step_window_place, "window_drag": step_window_drag, "divider_drag": step_divider_drag,
         "action": step_action, "leave_full_screen": step_leave_full_screen, "restore_window": step_restore_window,
         "close_window": step_close_window}


# ---- conditions --------------------------------------------------------------------------------

def near(a, b, tol):
    return abs(float(a) - float(b)) <= tol


def cond_window_frame(j, want, cache):
    wid = current_window(j)
    win = window_rec(j, wid)
    frame = win["frame"]
    tol = float(want.get("tol", 12))
    detail = {"window": wid, "frame": frame}
    if "fills" in want:
        target = win["visible"] if want["fills"] == "visible" else win["screen"]
        detail["target"] = target
        return all(near(a, b, tol) for a, b in zip(frame, target)), detail
    if "same_as" in want:
        target = remembered(j, want["same_as"])["window"]
        detail["target"] = target
        return all(near(a, b, tol) for a, b in zip(frame, target)), detail
    base = remembered(j, want["from"])["window"]
    dw, dh = frame[2] - base[2], frame[3] - base[3]
    detail.update(dw=dw, dh=dh, from_frame=base)
    ok = True
    for key, got in (("dw", dw), ("dh", dh)):
        if key in want:
            wanted = float(want[key])
            # A positive or negative change of at least the asked size less tol; 0 means unchanged.
            ok = ok and (near(got, 0, tol) if wanted == 0 else (got * wanted > 0 and abs(got) >= abs(wanted) - tol))
    return ok, detail


def cond_full_screen(j, want, cache):
    wid = current_window(j)
    state = full_screen_of(j, wid)
    win = window_rec(j, wid)
    fills = all(near(a, b, 2) for a, b in zip(win["frame"], win["screen"] or []))
    if want:
        return bool(state) and fills, {"full_screen": state, "frame": win["frame"], "screen": win["screen"]}
    return state is False and not fills, {"full_screen": state, "frame": win["frame"], "screen": win["screen"]}


def daemon_size(j, term):
    screen = j.app.screen(term)
    return screen.get("cols"), screen.get("rows"), screen


def cond_grid_fits(j, want, cache):
    want = want if isinstance(want, dict) else {}
    rec = named(j, want.get("pane"))
    row = pane_row(j, rec["pane"], cache)
    if row is None:
        return False, {"error": f"pane {rec['pane']} is not in debug.surfaces"}
    surface, grid_info = row.get("surface") or {}, row.get("grid") or {}
    grid, fit, drawn = parse_grid(surface.get("grid")), parse_grid(surface.get("fit_grid")), parse_grid(surface.get("drawn_grid"))
    cols, rows, _ = daemon_size(j, rec["term"])
    detail = {"pane": rec["pane"], "grid": surface.get("grid"), "fit_grid": surface.get("fit_grid"),
              "drawn_grid": surface.get("drawn_grid"), "daemon": f"{cols}x{rows}", "blank": row.get("blank"),
              "visible": row.get("visible"), "view_size": surface.get("view_size")}
    problems = []
    if not row.get("visible") or row.get("blank") or not row.get("content_visible", True):
        problems.append("the pane does not show its terminal")
    if not grid or grid != fit or grid != drawn:
        problems.append("grid, fitted grid and drawn grid differ")
    if grid and (cols, rows) != grid:
        problems.append("the daemon's screen is not the app's grid")
    cw, ch = grid_info.get("cell_width"), grid_info.get("cell_height")
    if grid and cw and ch:
        pad_x = max(0.0, grid_info.get("origin_x", 0) - grid_info.get("frame_x", 0))
        pad_y = max(0.0, grid_info.get("origin_y", 0) - grid_info.get("frame_y", 0))
        # The columns and rows the view's frame holds at Ghostty's cell size (padding on both sides).
        est_c = (grid_info["frame_width"] - 2 * pad_x) / cw
        est_r = (grid_info["frame_height"] - 2 * pad_y) / ch
        detail.update(cell=[cw, ch], padding=[pad_x, pad_y], frame=frame_of(row), fits=[round(est_c, 2), round(est_r, 2)])
        if not (est_c - 2 <= grid[0] <= est_c + 1 and est_r - 2 <= grid[1] <= est_r + 1):
            problems.append("the grid does not fit the view's frame")
    else:
        problems.append("no cell metrics")
    if want.get("vs") and grid:
        base = remembered(j, want["vs"])["grid"]
        detail["vs"] = base
        rel = {"wider": grid[0] > base[0], "narrower": grid[0] < base[0], "same": grid[0] == base[0]}
        if want.get("cols") and not rel[want["cols"]]:
            problems.append(f"cols not {want['cols']} than {base}")
        rel = {"taller": grid[1] > base[1], "shorter": grid[1] < base[1], "same": grid[1] == base[1]}
        if want.get("rows") and not rel[want["rows"]]:
            problems.append(f"rows not {want['rows']} than {base}")
    detail["problems"] = problems
    return not problems, detail


def cond_pane_frame(j, want, cache):
    rec = named(j, want.get("pane"))
    row = pane_row(j, rec["pane"], cache)
    frame = frame_of(row)
    if not frame:
        return False, {"error": f"pane {rec['pane']} has no frame"}
    detail = {"pane": rec["pane"], "frame": frame}
    if "right_of" in want or "below" in want:
        other = frame_of(pane_row(j, named(j, want.get("right_of") or want.get("below"))["pane"], cache))
        detail["other"] = other
        if not other:
            return False, detail
        if "right_of" in want:
            return frame[0] >= other[0] + other[2] - 1 and near(frame[1], other[1], 4), detail
        return frame[1] >= other[1] + other[3] - 1 and near(frame[0], other[0], 4), detail
    base = remembered(j, want["vs"])["pane_frame"]
    tol = float(want.get("tol", 0.06))
    detail["vs"] = base
    ok = True
    if "w" in want:
        ratio = frame[2] / base[2]
        detail["w"] = round(ratio, 3)
        ok = ok and near(ratio, want["w"], tol)
    if "h" in want:
        ratio = frame[3] / base[3]
        detail["h"] = round(ratio, 3)
        ok = ok and near(ratio, want["h"], tol)
    if "dw" in want:
        detail["dw"] = frame[2] - base[2]
        ok = ok and near(frame[2] - base[2], want["dw"], float(want.get("tol_points", 24)))
    return ok, detail


def cond_pane_state(j, want, cache):
    rec = named(j, want["pane"])
    row = pane_row(j, rec["pane"], cache)
    if row is None:
        gone = want.get("gone", False)
        return gone, {"pane": rec["pane"], "present": False}
    if want.get("gone"):
        return False, {"pane": rec["pane"], "present": True}
    got = {k: row.get(k) for k in want.get("fields", {})}
    return got == want.get("fields", {}), {"pane": rec["pane"], "got": got}


def tail(text, n):
    return [line.rstrip() for line in (text or "").split("\n") if line.strip()][-n:]


def cond_at_bottom(j, want, cache):
    want = want if isinstance(want, dict) else {}
    rec = named(j, want.get("pane"))
    n = int(want.get("lines", 3))
    row = pane_row(j, rec["pane"], cache)
    app = tail((row or {}).get("text"), n)
    daemon = tail(j.app.screen(rec["term"])["text"], n)
    return bool(app) and app == daemon, {"app_tail": app, "daemon_tail": daemon}


def cond_output_advances(j, want, cache):
    rec = named(j, want.get("pane"))
    row = pane_row(j, rec["pane"], cache)
    numbers = [int(m) for m in re.findall(want["pattern"], (row or {}).get("text") or "")]
    top = max(numbers) if numbers else None
    key = ("ext_advance", rec["pane"], want["pattern"])
    base = j.binds.setdefault(key, top)
    if base is None and top is not None:
        j.binds[key] = base = top
    ok = top is not None and base is not None and top >= base + int(want.get("by", 10))
    return ok, {"first": base, "now": top}


def cond_pty_size(j, want, cache):
    want = want if isinstance(want, dict) else {"tag": want}
    rec = named(j, want.get("pane"))
    cols, rows, screen = daemon_size(j, rec["term"])
    found = None
    for line in screen["text"].split("\n"):
        m = re.fullmatch(re.escape(want["tag"]) + r" (\d+) (\d+)", line.strip())
        if m:
            found = (int(m.group(2)), int(m.group(1)))  # stty size prints rows then cols
    row = pane_row(j, rec["pane"], cache)
    grid = parse_grid(((row or {}).get("surface") or {}).get("grid"))
    detail = {"stty_cols_rows": found, "daemon": [cols, rows], "app_grid": grid}
    return found is not None and found == (cols, rows) == grid, detail


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise D.StepError(f"{path} is not a PNG")
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def crop_read(j, image, box, upscale=2):
    """Text recognition of `box` ([x, y, w, h] pixels) of `image`, scaled by `upscale` (stock sips)."""
    x, y, w, h = box
    crop = image.with_name(image.stem + "-crop.png")
    done = D.subprocess.run(["/usr/bin/sips", "--cropOffset", str(y), str(x), "-c", str(h), str(w), str(image),
                             "--out", str(crop)], capture_output=True, text=True, timeout=60)
    if done.returncode == 0 and upscale != 1:
        D.subprocess.run(["/usr/bin/sips", "--resampleWidth", str(int(w * upscale)), str(crop)],
                         capture_output=True, text=True, timeout=60)
    if done.returncode != 0 or not crop.is_file():
        raise D.StepError(f"sips crop failed: {(done.stderr or done.stdout)[-200:]}")
    try:
        return j.app.read_text(crop)
    finally:
        crop.unlink()


def cond_pane_frame_text(j, want, cache):
    """A fresh snapshot of the pane's window (kept whole as check-NN.png, as frame_text keeps it)
    shows TEXT inside the pane, to text recognition (the driver's folding).

    Vision drops lines of a whole window (1920 points of mostly empty terminal: the last lines, or
    every terminal line next to the sidebar's text; seen on this build's captures, where the frame
    showed the text). So it reads, in order, until one shows TEXT: (1) the band of the pane's rows
    around the row whose viewport text holds TEXT (two rows above and below, as wide as the longest
    of those lines), scaled 2x; (2) the pane's whole terminal view, scaled 2x; (3) the whole window.
    The row only says where to look: the pixels must still show the text."""
    want = want if isinstance(want, dict) else {"text": want}
    text = want["text"]
    rec = named(j, want.get("pane"))
    j.checks += 1
    image = j.app.snapshot(j.out / f"check-{j.checks:02d}.png")
    row = pane_row(j, rec["pane"])
    rect, grid = frame_of(row), (row or {}).get("grid") or {}
    win = window_rec(j, rec["window"])
    if not rect or not win.get("frame"):
        return False, {"image": image.name, "error": f"no frame for pane {rec['pane']}"}
    width, height = png_size(image)
    scale = width / float(win["frame"][2])
    reads, boxes = [], []
    lines_app = ((row or {}).get("text") or "").split("\n")
    hits = [i for i, line in enumerate(lines_app) if text in line]
    cw, ch = grid.get("cell_width"), grid.get("cell_height")
    if hits and cw and ch and "origin_x" in grid:
        first, last = max(0, hits[-1] - 2), hits[-1] + 2
        longest = max(len(l.rstrip()) for l in lines_app[first:last + 1])
        bx, by = grid["origin_x"] - 2, grid["origin_y"] + first * ch - 2
        bw = min((longest + 4) * cw, rect[0] + rect[2] - bx)
        bh = min((last - first + 1) * ch + 4, rect[1] + rect[3] - by)
        boxes.append(("rows", [round(bx * scale), round(by * scale), round(bw * scale), round(bh * scale)], 2))
    boxes.append(("pane", [round(v * scale) for v in rect], 2))
    for name, box, up in boxes:
        x, y, w, h = (max(0, v) for v in box)
        box = [x, y, min(w, width - x), min(h, height - y)]
        lines = crop_read(j, image, box, up)
        reads.append({"read": name, "crop_px": box, "text": lines[-8:], "lines": len(lines)})
        if D.ocr_contains(lines, text):
            return True, {"image": image.name, "pane": rec["pane"], "scale": round(scale, 3), "reads": reads}
    lines = j.app.read_text(image)
    reads.append({"read": "window", "text": lines[-8:], "lines": len(lines)})
    return D.ocr_contains(lines, text), {"image": image.name, "pane": rec["pane"], "scale": round(scale, 3),
                                         "app_row": hits[-1] if hits else None, "reads": reads}


CONDITIONS = {"pane_frame_text": ("frame", cond_pane_frame_text), "window_frame": ("app", cond_window_frame), "full_screen": ("app", cond_full_screen),
              "grid_fits": ("app", cond_grid_fits), "pane_frame": ("app", cond_pane_frame),
              "pane_state": ("app", cond_pane_state), "at_bottom": ("app", cond_at_bottom),
              "output_advances": ("app", cond_output_advances), "pty_size": ("daemon", cond_pty_size)}
