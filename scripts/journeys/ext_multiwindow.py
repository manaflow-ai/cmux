"""Multi-window steps and conditions for the journeys (group multi-window, journeys/p0/mw-*.json).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py (that runs as __main__ there): install() gets the driver module instead.

Lawrence 2026-10-28 (handoff/multiwindow.md): "keyboard shortcuts dont work, and clicking on home/workspaces might
bring me to the wrong window. we need to completely eliminate this error class". Each mw-* journey does one thing in
one window (the TARGET) and judges two things: the target changed as the person asked, and every OTHER window did
not change at all (what it shows, its sidebar rows, its panes and tabs, its focused pane, its frame).

What a window shows is read from the app's own state, three reads per poll:

  - `debug.windows`: each window's id (the window state id that `debug.key`, `debug.mouse` and `debug.layers` take),
    `open`, `visible`, `selected` (the workspace it shows), `shown_page` (`home` for classic Home's top page);
  - `snapshot.get` topology: each workspace's name and its panes and tabs (with each pane's selected tab), each
    window's public id (`win_...`) and focused pane;
  - `debug.sidebar_rows`: each window's sidebar rows (the workspaces it lists) and items (Home, with `active` while
    the window shows it: docked Home is the home workspace, which the rows leave out while the Home item shows it),
    with their frames in window points from the top-left, which `click_sidebar` clicks with `debug.mouse`;
  - `debug.layers`: each window's frame.

The oracle's `windows` facet (`debug.oracle.snapshot {facets: ["windows"]}`) has frames and the key window but not
what a window shows, so these reads are used instead.

Steps (`do`):
  name_window   {as, shows?}            names the journey's current window (the window of the current pane, or the
                                        one a step adopted), or the window that shows workspace SHOWS; `key`,
                                        `type` and `mouse` steps take the name as `window`. The first step of this
                                        group in a journey records the windows open then (the baseline)
  await_window  {as, timeout?}          waits for an open, visible window none of this group's steps knew (after
                                        Cmd-Shift-N, the menu's New Window, `cmux app new-window`, a move to a new
                                        window), makes it key (`debug.window.focus`, without activating the app) and
                                        the window keys and frames go to, and names it
  use_window    {window | shows, as?, focus?}
                                        makes a named window (or the window that shows workspace SHOWS, e.g. after a
                                        relaunch) the one keys and frames go to; `focus` (default true): it comes to
                                        the front and takes key, as a person's click on it does
  remember_windows {as}                 keeps every open window's state as AS (for `window_unchanged`, `since`) and
                                        sets the mark AS (for `expect`'s `since`)
  click_sidebar {window, home: true | workspace: NAME, mark?, focus_first?}
                                        a click (debug.mouse down and up) at the middle of the Home item or the
                                        workspace row NAME in that window's own sidebar. The window is NOT made key
                                        first: the key record stays whatever it was (a stale key window is the bug
                                        class these journeys guard), so the click alone must name its window.
                                        `focus_first: true` (opt-in, off in the mw- journeys) makes it key first
  move_workspace {workspace: NAME, to: WINDOW | "new", as?, mark?}
                                        `action.run moveWorkspaceToWindow` (target the workspace, argument `window`
                                        the named window), the action the sidebar row's Move to Window menu and the
                                        palette run; `to: new` runs moveWorkspaceToNewWindow and, with `as`, waits
                                        for the new window and names it (as await_window)
  run_cli       {args: [...], mark?}    the app's bundled `cmux` CLI on the app's own control socket
                                        (`--app-socket`, `--json`), as a script runs it
  close_extra_windows {keep_listing?: [NAME]}
                                        clean-up: Ctrl-Cmd-W (closeWindow) in every window that was not open at the
                                        baseline and shows no KEEP_LISTING row; when no baseline window id is open any
                                        more (a relaunch gave new ids), also every window that shows a row a baseline
                                        window showed (less the workspaces move_workspace moved) stays; never the
                                        last window

Conditions (inside `expect.all`; evidence kind app):
  window_state  {window, ...}           the named window now: `open` (bool), `home` (true: it shows Home, the
                                        classic top page or the docked Home's workspace with the Home item active;
                                        false: it does not), `workspace` NAME (it shows that workspace and not Home),
                                        `lists` / `lacks` [NAME] (its sidebar lists / does not list them),
                                        `first_entry` (it shows its sidebar's first entry: the first top item, or the
                                        first workspace row, whichever numbering Cmd-1 uses), and against `since`
                                        MARK: `dpanes`, `dtabs` (change of the shown workspace's pane and tab counts),
                                        `same_workspace` (shows the workspace it showed), `selected_changed` (a pane's
                                        selected tab changed)
  window_unchanged {since, window? | windows? | except?, ignore?}
                                        NEGATIVE (read every poll and through `settle`): each window remembered at
                                        SINCE (all of them, or `window` / `windows`, less `except`) is still open and
                                        shows the same page and workspace, the same Home state, the same sidebar rows,
                                        the same panes with the same tabs and selected tabs, the same focused pane and
                                        the same frame (2 points); `ignore` drops fields (`rows`, `frame`, ...)
  windows_open  {count? | baseline_plus? | since?, delta?}
                                        the number of open, visible windows: COUNT, the baseline's plus N, or the
                                        number at SINCE plus DELTA (default 0)
  windows_show  {names: [NAME]}         each workspace NAME is shown (not Home) in an open window, each in its own
"""
import json
import time

D = None  # the driver module (install)

# Built-in sidebar items that open no page (launchers): never the "first entry" a Cmd-1 shows.
LAUNCHERS = {"new_terminal", "new_browser", "new_agent_chat", "customize", "search_chats"}


def install(driver):
    global D
    D = driver


# ---- reads -----------------------------------------------------------------------------------

def _rect_center(frame):
    if isinstance(frame, dict) and frame.get("width"):
        return frame["x"] + frame["width"] / 2.0, frame["y"] + frame["height"] / 2.0
    if isinstance(frame, list) and len(frame) == 4 and frame[2]:
        return frame[0] + frame[2] / 2.0, frame[1] + frame[3] / 2.0
    return None


def _y_of(frame):
    if isinstance(frame, dict):
        return (frame.get("y", 0), frame.get("x", 0))
    if isinstance(frame, list) and len(frame) == 4:
        return (frame[1], frame[0])
    return (1e9, 1e9)


def read_state(j, cache=None):
    """{window id: state} of every open window with a controller (see the module docstring)."""
    if cache is not None and "mw_state" in cache:
        return cache["mw_state"]
    report = j.app.rpc("debug.windows") or {}
    snap = j.app.rpc("snapshot.get") or {}
    topo = snap.get("topology") if isinstance(snap, dict) else None
    topo = topo or {}
    sidebar = j.app.rpc("debug.sidebar_rows") or {}
    layers = j.app.rpc("debug.layers") or {}
    workspaces = {}
    for ws in topo.get("workspaces") or []:
        panes = []
        for screen in ws.get("screens") or []:
            for pane in screen.get("panes") or []:
                tabs = [t.get("id") for t in pane.get("tabs") or []]
                selected = pane.get("selected_tab") or next((t.get("id") for t in pane.get("tabs") or [] if t.get("selected")), None)
                panes.append({"id": pane.get("id"), "tabs": tabs, "selected": selected})
        rec = {"key": ws.get("key") or ws.get("id"), "id": ws.get("id"), "name": ws.get("name"), "panes": panes}
        for k in (ws.get("key"), ws.get("id")):
            if k:
                workspaces[k] = rec
    topo_windows = {w.get("key"): w for w in topo.get("windows") or [] if w.get("key")}
    sides = {w.get("window"): w for w in sidebar.get("windows") or [] if isinstance(w, dict)}
    frames = {w.get("id"): w.get("frame") for w in layers.get("windows") or [] if isinstance(w, dict)}
    out = {}
    for w in report.get("windows") or []:
        wid = w.get("id")
        if not wid or not w.get("open") or not w.get("has_controller"):
            continue
        side = sides.get(wid) or {}
        items = [i for i in side.get("items") or [] if isinstance(i, dict)]
        rows = [r for r in side.get("rows") or [] if isinstance(r, dict) and r.get("in_list", True) and not r.get("suppressed")]
        home_item = next((i for i in items if i.get("ref_kind") == "built_in" and i.get("ref") == "home"), None)
        ws = workspaces.get(w.get("selected") or "")
        page = w.get("shown_page")
        tw = topo_windows.get(wid) or {}
        listed = [workspaces[k]["name"] if k in workspaces else k for k in w.get("workspaces") or []]
        out[wid] = {
            "id": wid, "public": tw.get("id"), "visible": bool(w.get("visible")), "page": page,
            "selected": w.get("selected"), "workspace": ws["name"] if ws else None,
            "home": page == "home" or bool(home_item and home_item.get("active")),
            "home_item": home_item, "items": items,
            "rows": [r.get("key") for r in rows], "row_titles": [r.get("title") for r in rows], "row_records": rows,
            "listed": listed, "panes": ws["panes"] if ws else [], "focused_pane": tw.get("focused_pane"),
            "frame": frames.get(wid),
        }
    if cache is not None:
        cache["mw_state"] = out
    return out


def open_visible(state):
    return [wid for wid, s in state.items() if s["visible"]]


def compact(s):
    """A window's state for evidence (no frames of every row)."""
    if not s:
        return None
    return {"id": s["id"], "page": s["page"], "workspace": s["workspace"], "home": s["home"], "rows": s["row_titles"][:8],
            "panes": [[len(p["tabs"]), p["selected"]] for p in s["panes"]], "focused_pane": s["focused_pane"], "frame": s["frame"]}


def _init(j):
    """The baseline: the windows open at this group's first step in the journey."""
    if getattr(j, "mw_baseline", None) is not None:
        return
    state = read_state(j)
    j.mw_baseline = set(state)
    # The rows the baseline windows show (docked Home's workspace is no row: it moves to the window Home shows in).
    j.mw_baseline_rows = {t for s in state.values() for t in s["row_titles"] if t}
    j.mw_moved = set()
    j.mw_known = set(state)
    j.mw_marks = {}
    if not hasattr(j, "named_windows"):
        j.named_windows = {}


def window_id(j, ref):
    _init(j)
    ref = j.sub(ref)
    if ref in j.named_windows:
        return j.named_windows[ref]
    if ref in read_state(j):
        return ref
    raise D.StepError(f"no window named {ref!r} (named: {sorted(j.named_windows)})")


def current_window(j):
    """The journey's current window: the one a step adopted, else the window that shows the current pane."""
    for wid in (getattr(j, "ext_window", None), j.key_window):
        if wid:
            return wid
    if j.pane:
        report = j.app.rpc("debug.surfaces") or {}
        layers = j.app.rpc("debug.layers") or {}
        numbers = {str(w.get("window_number")): w.get("id") for w in layers.get("windows") or []}
        for w in report.get("windows") or []:
            for p in w.get("panes") or []:
                if isinstance(p, dict) and p.get("pane") == j.pane:
                    return (p.get("grid") or {}).get("window") or numbers.get(str(w.get("window")))
    state = read_state(j)
    return next(iter(state), None)


def shows_window(j, name, state=None):
    state = state or read_state(j)
    hits = [wid for wid, s in state.items() if s["workspace"] == name and not s["home"]]
    if len(hits) != 1:
        raise D.StepError(f"{len(hits)} windows show workspace {name!r}: {[compact(s) for s in state.values()]}")
    return hits[0]


def make_current(j, wid, focus=True):
    """Keys (`debug.key`), frames (`debug.window_snapshot`) and ext_window's pane reads go to window `wid`."""
    j.key_window = j.app.snapshot_window = wid
    j.ext_window = wid
    if focus:
        return j.app.rpc("debug.window.focus", {"window": wid})
    return None


# ---- steps -----------------------------------------------------------------------------------

def step_name_window(j, step):
    _init(j)
    wid = shows_window(j, j.sub(step["shows"])) if step.get("shows") else current_window(j)
    if not wid:
        raise D.StepError("name_window: no current window")
    j.named_windows[step["as"]] = wid
    j.mw_known.add(wid)
    return {"window": wid, "state": compact(read_state(j).get(wid))}


def await_new_window(j, name, timeout):
    end = D.now() + float(timeout)
    state = {}
    while D.now() < end:
        state = read_state(j)
        new = [wid for wid in open_visible(state) if wid not in j.mw_known]
        if new:
            wid = new[0]
            j.mw_known.add(wid)
            focus = make_current(j, wid)
            if name:
                j.named_windows[name] = wid
            return {"window": wid, "focus": focus, "state": compact(state[wid]), "open": len(open_visible(state))}
        time.sleep(0.2)
    raise D.StepError(f"no new window opened within {timeout} s (open: {[compact(s) for s in state.values()]})")


def step_await_window(j, step):
    _init(j)
    return await_new_window(j, step.get("as"), step.get("timeout", 20))


def step_use_window(j, step):
    _init(j)
    wid = shows_window(j, j.sub(step["shows"])) if step.get("shows") else window_id(j, step["window"])
    if step.get("as"):
        j.named_windows[step["as"]] = wid
        j.mw_known.add(wid)
    focus = make_current(j, wid, step.get("focus", True))
    return {"window": wid, "focus": focus}


def step_remember_windows(j, step):
    _init(j)
    state = read_state(j)
    j.mw_marks[step["as"]] = state
    # Also a mark of the same name, for `expect`'s `since` (a later step's `mark` of that name moves it).
    j.marks[step["as"]] = D.now()
    return {"windows": [compact(s) for s in state.values()]}


def sidebar_target(j, wid, step):
    report = j.app.rpc("debug.sidebar_rows") or {}
    side = next((w for w in report.get("windows") or [] if isinstance(w, dict) and w.get("window") == wid), None)
    if side is None:
        raise D.StepError(f"debug.sidebar_rows has no sidebar for window {wid}")
    if step.get("home"):
        item = next((i for i in side.get("items") or [] if i.get("ref_kind") == "built_in" and i.get("ref") == "home"), None)
        if not item or not item.get("window_frame"):
            raise D.StepError(f"window {wid}'s sidebar shows no Home item: "
                              f"{[(i.get('ref_kind'), i.get('ref'), bool(i.get('window_frame'))) for i in side.get('items') or []]}")
        return item, "home"
    name = j.sub(step["workspace"])
    rows = [r for r in side.get("rows") or [] if r.get("in_list", True) and not r.get("suppressed")]
    row = next((r for r in rows if r.get("title") == name), None)
    if row is None:
        raise D.StepError(f"window {wid}'s sidebar lists no row {name!r}: {[r.get('title') for r in rows][:12]}")
    if not row.get("window_frame") or row.get("view_frame") is None:
        raise D.StepError(f"the row {name!r} has no view in window {wid} (scrolled off?): {json.dumps(row)[:300]}")
    return row, name


def step_click_sidebar(j, step):
    _init(j)
    wid = window_id(j, step["window"])
    # Never key first unless asked: the click must act in its own window whatever window the app last had as key.
    focus = make_current(j, wid, bool(step.get("focus_first", False)))
    target, what = sidebar_target(j, wid, step)
    center = _rect_center(target["window_frame"])
    if not center:
        raise D.StepError(f"no frame to click for {what}: {target.get('window_frame')}")
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    reply = j.app.rpc("debug.mouse", {"window": wid, "action": "click", "x": center[0], "y": center[1]})
    if isinstance(reply, dict) and reply.get("error"):
        raise D.StepError(f"debug.mouse: {reply['error']}")
    return {"window": wid, "clicked": what, "at": center, "focus": focus, "reply": reply}


def public_window(j, wid):
    pub = (read_state(j).get(wid) or {}).get("public")
    if pub:
        return pub
    plain = wid.replace("-", "").lower()
    return "win_" + plain if len(plain) == 32 else wid


def workspace_public(j, name):
    snap = j.app.rpc("snapshot.get") or {}
    topo = (snap.get("topology") if isinstance(snap, dict) else None) or {}
    hits = [ws for ws in topo.get("workspaces") or [] if ws.get("name") == name]
    if len(hits) != 1:
        raise D.StepError(f"{len(hits)} workspaces are named {name!r}")
    return hits[0].get("id")


def step_move_workspace(j, step):
    _init(j)
    name = j.sub(step["workspace"])
    j.mw_moved.add(name)
    target = "workspace:" + workspace_public(j, name)
    if step["to"] == "new":
        params = {"action": "moveWorkspaceToNewWindow", "target": target, "focus": True}
    else:
        params = {"action": "moveWorkspaceToWindow", "target": target, "focus": True,
                  "args": {"window": "window:" + public_window(j, window_id(j, step["to"]))}}
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    reply = j.app.rpc("action.run", params)
    out = {"params": params, "reply": reply}
    if step["to"] == "new" and step.get("as"):
        out["window"] = await_new_window(j, step["as"], step.get("timeout", 20))
    return out


def step_run_cli(j, step):
    args = [j.sub(a) for a in step["args"]]
    env = {"HOME": j.app.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    done = D.subprocess.run([j.app.cli, "--app-socket", j.app.sock, "--json", *args], capture_output=True, text=True,
                            timeout=float(step.get("timeout", 30)), env=env)
    if done.returncode != 0:
        raise D.StepError(f"cmux {' '.join(args)}: exit {done.returncode}: {(done.stdout + done.stderr).strip()[-300:]}")
    return {"argv": ["cmux", "--app-socket", "SOCKET", "--json", *args], "stdout": done.stdout.strip()[-400:]}


def step_close_extra_windows(j, step):
    if getattr(j, "mw_baseline", None) is None:
        return {"closed": [], "why": "no window was recorded"}
    # A window that shows a row a baseline window showed (less the workspaces the journey moved) stays: after a
    # relaunch the baseline window may have a new id.
    state = read_state(j)
    keep = {j.sub(n) for n in step.get("keep_listing") or []}
    if not j.mw_baseline & set(state):
        keep |= j.mw_baseline_rows - j.mw_moved
    closing = [wid for wid, s in state.items() if wid not in j.mw_baseline and not (set(s["row_titles"]) & keep)]
    closed, left = [], []
    for wid in closing:
        if len(read_state(j)) <= 1:
            left.append({"window": wid, "why": "the last open window"})
            continue
        j.app.rpc("debug.key", {"key": "w", "modifiers": ["control", "cmd"], "window": wid})
        end = D.now() + float(step.get("timeout", 10))
        while D.now() < end and wid in read_state(j):
            time.sleep(0.2)
        (left if wid in read_state(j) else closed).append(wid)
    # The window keys go to after: a baseline window still open.
    rest = [wid for wid in read_state(j) if wid in j.mw_baseline] or list(read_state(j))
    if rest:
        make_current(j, rest[0], focus=False)
    return {"closed": closed, "left_open": left}


STEPS = {"name_window": step_name_window, "await_window": step_await_window, "use_window": step_use_window,
         "remember_windows": step_remember_windows, "click_sidebar": step_click_sidebar,
         "move_workspace": step_move_workspace, "run_cli": step_run_cli, "close_extra_windows": step_close_extra_windows}


# ---- conditions --------------------------------------------------------------------------------

def remembered(j, mark):
    marks = getattr(j, "mw_marks", {})
    if mark not in marks:
        raise D.StepError(f"no remember_windows step kept {mark!r}")
    return marks[mark]


def tab_count(s):
    return sum(len(p["tabs"]) for p in s["panes"])


def first_entry_shown(s):
    """Whether the window shows its sidebar's first entry: the first top item that opens a page (by its place), or
    the first workspace row; which one Cmd-1 picks depends on the sidebar's numbering setting."""
    items = [i for i in s["items"] if i.get("window_frame") and i.get("region", "top") == "top"
             and not (i.get("ref_kind") == "built_in" and i.get("ref") in LAUNCHERS)]
    items.sort(key=lambda i: _y_of(i.get("window_frame")))
    rows = sorted(s["row_records"], key=lambda r: _y_of(r.get("window_frame")))
    first_item = items[0] if items else None
    first_row = next((r for r in rows if str(r.get("key", "")).startswith("workspace")), rows[0] if rows else None)
    item_shown = bool(first_item and first_item.get("active"))
    row_shown = bool(first_row and first_row.get("title") == s["workspace"] and not s["home"])
    detail = {"first_item": first_item and [first_item.get("ref_kind"), first_item.get("ref"), first_item.get("active")],
              "first_row": first_row and first_row.get("title")}
    return item_shown or row_shown, detail


def cond_window_state(j, want, cache):
    wid = window_id(j, want["window"])
    state = read_state(j, cache)
    s = state.get(wid)
    detail = {"window": wid, "now": compact(s)}
    problems = []
    if "open" in want:
        if bool(s) != bool(want["open"]):
            problems.append(f"open is {bool(s)}")
    elif s is None:
        return False, dict(detail, problems=["the window is not open"])
    if s is not None:
        if "home" in want and s["home"] != bool(want["home"]):
            problems.append(f"home is {s['home']}")
        if "workspace" in want and (s["workspace"] != want["workspace"] or s["home"]):
            problems.append(f"shows {s['workspace']!r} (home {s['home']}), not {want['workspace']!r}")
        for name in want.get("lists") or []:
            if name not in s["row_titles"] and name not in s["listed"]:
                problems.append(f"does not list {name!r}")
        for name in want.get("lacks") or []:
            if name in s["row_titles"] or name in s["listed"]:
                problems.append(f"lists {name!r}")
        if want.get("first_entry"):
            ok, first = first_entry_shown(s)
            detail["first_entry"] = first
            if not ok:
                problems.append("does not show its sidebar's first entry")
        if want.get("since"):
            before = remembered(j, want["since"]).get(wid)
            if before is None:
                problems.append(f"window {wid} was not open at {want['since']}")
            else:
                detail["before"] = compact(before)
                if "dpanes" in want and len(s["panes"]) - len(before["panes"]) != int(want["dpanes"]):
                    problems.append(f"panes {len(before['panes'])} -> {len(s['panes'])}, not {int(want['dpanes']):+d}")
                if "dtabs" in want and tab_count(s) - tab_count(before) != int(want["dtabs"]):
                    problems.append(f"tabs {tab_count(before)} -> {tab_count(s)}, not {int(want['dtabs']):+d}")
                if "same_workspace" in want and (s["selected"] == before["selected"]) != bool(want["same_workspace"]):
                    problems.append(f"workspace {before['workspace']!r} -> {s['workspace']!r}")
                if want.get("selected_changed"):
                    old = {p["id"]: p["selected"] for p in before["panes"]}
                    if not any(p["id"] in old and p["selected"] != old[p["id"]] for p in s["panes"]):
                        problems.append("no pane's selected tab changed")
    detail["problems"] = problems
    return not problems, detail


FIELDS = ("page", "selected", "home", "rows", "panes", "focused_pane", "frame")


def same_frame(a, b, tol=2.0):
    if a is None or b is None:
        return a == b
    return all(abs(float(x) - float(y)) <= tol for x, y in zip(a, b))


def cond_window_unchanged(j, want, cache):
    before = remembered(j, want["since"])
    if want.get("window"):
        ids = [window_id(j, want["window"])]
    elif want.get("windows"):
        ids = [window_id(j, w) for w in want["windows"]]
    else:
        ids = list(before)
    ids = [w for w in ids if w not in {window_id(j, e) for e in want.get("except") or []}]
    fields = [f for f in FIELDS if f not in set(want.get("ignore") or [])]
    now = read_state(j, cache)
    changed = {}
    for wid in ids:
        old, new = before.get(wid), now.get(wid)
        if old is None:
            changed[wid] = "not open at the mark"
            continue
        if new is None:
            changed[wid] = "closed"
            continue
        diff = {}
        for f in fields:
            same = same_frame(old[f], new[f]) if f == "frame" else old[f] == new[f]
            if not same:
                diff[f] = {"was": old[f] if f != "rows" else old["row_titles"], "now": new[f] if f != "rows" else new["row_titles"]}
        if diff:
            changed[wid] = diff
    names = {v: k for k, v in getattr(j, "named_windows", {}).items()}
    return not changed, {"windows": [names.get(w, w) for w in ids], "changed": {names.get(k, k): v for k, v in changed.items()}}


def cond_windows_open(j, want, cache):
    count = len(open_visible(read_state(j, cache)))
    if "count" in want:
        target = int(want["count"])
    elif "baseline_plus" in want:
        target = len(getattr(j, "mw_baseline", set())) + int(want["baseline_plus"])
    else:
        target = len(open_visible(remembered(j, want["since"]))) + int(want.get("delta", 0))
    return count == target, {"open": count, "want": target}


def cond_windows_show(j, want, cache):
    state = read_state(j, cache)
    where, problems = {}, []
    for name in want["names"]:
        hits = [wid for wid, s in state.items() if s["visible"] and s["workspace"] == name and not s["home"]]
        if len(hits) != 1:
            problems.append(f"{name!r} shows in {len(hits)} windows")
        else:
            where[name] = hits[0]
    if len(set(where.values())) != len(where):
        problems.append("two workspaces show in one window")
    return not problems, {"where": where, "problems": problems, "windows": [compact(s) for s in state.values()]}


CONDITIONS = {"window_state": ("app", cond_window_state), "window_unchanged": ("app", cond_window_unchanged),
              "windows_open": ("app", cond_windows_open), "windows_show": ("app", cond_windows_show)}
NEGATIVE = {"window_unchanged"}
