#!/usr/bin/env python3
"""Record chrome motion on a running tagged cmux-next build (cx-f6i7).

The motion pass's recorder for surfaces other than the sidebar rows (those
are `sidebar-motion-record.py`). Each scenario starts `debug.window_record`
(the window as composited, one JPEG per display frame plus frames.json), runs
one change through the control socket, and keeps the frames in
OUT/<surface>/<scenario>/. `layout.json` in each surface folder holds
`debug.pane_chrome` before the first scenario, for cropping. The script
attaches to an app already running (a capture slot's `capture-host launch`,
or a tagged build) through its debug socket and never launches or quits it.

Surfaces:
  tabs   tab open, close, move right and left, a drag reorder
  panes  split right, split down, close, equalize, zoom
  focus  focus moves between panes (left, right)
  toasts a toast appears (pin a tab), a second stacks under it (close a tab),
         and the newest ends (undo) while the other slides back down
  switch workspace switches: to the next workspace, back, and across several

--reduce-motion records with Reduce Motion on (in memory, `debug.motion reduce`).

Usage: motion-record.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock --out DIR
       [--surface NAME ...] [--only SCENARIO ...] [--reduce-motion]
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", required=True)
parser.add_argument("--surface", action="append", default=[])
parser.add_argument("--only", action="append", default=[])
parser.add_argument("--seconds", type=float, default=1.5)
parser.add_argument("--reduce-motion", action="store_true")
parser.add_argument("--window-height", type=float, default=720, help="the window's height in points (frames are window-sized)")
opts = parser.parse_args()


def rpc(method, params=None, timeout=30):
    """One request on the app's control socket (line JSON)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, **params):
    return rpc("action.run", {"action": name, **params})


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def record(surface, name, trigger, seconds=None, layout=False):
    if opts.only and name not in opts.only:
        return
    directory = os.path.join(opts.out, surface, name)
    os.makedirs(directory, exist_ok=True)
    seconds = seconds or opts.seconds
    if layout:  # the scenario's own start layout (strip-scroll-check.py places columns from it)
        with open(os.path.join(directory, "layout.json"), "w") as handle:
            json.dump({"pane_chrome": rpc("debug.pane_chrome")}, handle)
    t0 = time.monotonic()
    started = rpc("debug.window_record", {"dir": directory, "seconds": seconds})
    t_started = time.monotonic() - t0
    time.sleep(0.15)  # test harness: a few still frames before the change
    t_sent = time.monotonic() - t0
    reply = trigger()
    t_replied = time.monotonic() - t0
    # Host seconds since the record request: the first frame lands between record_reply and one
    # frame later; the change ran between trigger_sent and trigger_reply.
    with open(os.path.join(directory, "timing.json"), "w") as handle:
        json.dump({"record_reply": t_started, "trigger_sent": t_sent, "trigger_reply": t_replied}, handle)
    time.sleep(seconds + 0.6)  # test harness: the recording stops by itself
    frames = len([f for f in os.listdir(directory) if f.endswith(".jpg")])
    print(f"{surface}/{name}: {frames} frames; record={json.dumps(started)[:100]} reply={json.dumps(reply)[:160]}", flush=True)
    time.sleep(0.4)  # test harness: settle before the next scenario


def save_layout(surface):
    os.makedirs(os.path.join(opts.out, surface), exist_ok=True)
    with open(os.path.join(opts.out, surface, "layout.json"), "w") as handle:
        json.dump({"pane_chrome": rpc("debug.pane_chrome"), "windows": rpc("debug.windows")}, handle)


def paced_drag(x, y, to_x, to_y, seconds=0.45):
    """A drag at pointer pace: one `debug.mouse` move per display frame (a
    single `drag` call posts every event at once, so the release carries no
    real velocity), then the release where the pointer stopped moving."""
    frames = max(2, int(seconds * 60))
    rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1, "release": False})
    last = (x, y)
    for frame in range(1, frames + 1):
        t = frame / frames
        eased = 1 - (1 - t) ** 2  # the hand slows into the drop
        point = (x + (to_x - x) * eased, y + (to_y - y) * eased)
        rpc("debug.mouse", {"action": "drag", "x": last[0], "y": last[1], "to_x": point[0], "to_y": point[1],
                            "steps": 1, "press": False, "release": frame == frames})
        last = point
        time.sleep(1 / 60)  # test harness: pointer pace
    return {"frames": frames}


def first_pill(busiest=False):
    """The first pane's first tab pill in window points (`debug.pane_chrome`);
    with `busiest`, the narrowest first pill of any pane (tabs narrow as a
    pane fills)."""
    pills = [pane["pill"] for window in (rpc("debug.pane_chrome") or {}).get("windows") or []
             for pane in window.get("panes") or [] if pane.get("pill")]
    if busiest and pills:
        return min(pills, key=lambda pill: pill[2])
    return pills[0] if pills else None


def tabs():
    save_layout("tabs")
    for _ in range(3):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    record("tabs", "open", lambda: action("newSurface"))
    record("tabs", "close", lambda: action("tab.close"))
    # The last tab is selected after the close: move it left, then back.
    record("tabs", "move-left", lambda: action("moveSurfaceLeft"))
    record("tabs", "move-right", lambda: action("moveSurfaceRight"))
    pill = first_pill()
    if pill:
        # Pills sit side by side: drag the first one past the third's center.
        left, top, width, height = pill
        x, y = left + width / 2, top + height / 2
        to_x = x + width * 2.2
        record("tabs", "drag-reorder", lambda: paced_drag(x, y, to_x, y))
    else:
        print("tabs/drag-reorder: skipped, pane_chrome reports no tab pill", flush=True)


def panes():
    # A fresh workspace: a clean profile opens on Home, where no pane has focus.
    action("workspace.newAtBottom")
    time.sleep(1.0)  # test harness: the workspace settles
    save_layout("panes")
    record("panes", "split-right", lambda: action("splitRight"))
    record("panes", "split-down", lambda: action("splitDown"))
    record("panes", "close", lambda: action("closePane"))
    record("panes", "equalize", lambda: action("equalizeSplits"))
    record("panes", "zoom", lambda: action("toggleSplitZoom"))
    record("panes", "unzoom", lambda: action("toggleSplitZoom"))
    # Departures: a pane moved to another workspace and a strip column closed
    # mid-strip.
    action("splitRight")
    time.sleep(0.8)  # test harness: the split settles
    record("panes", "move-away", lambda: action("pane.moveToNewWorkspace"))
    print("after move-away:", json.dumps(rpc("debug.windows"))[:300], flush=True)
    action("workspace.newAtBottom")
    time.sleep(1.0)  # test harness: the workspace settles
    for _ in range(2):
        action("newColumn")
        time.sleep(0.8)  # test harness: one column at a time
    action("focusLeft")
    time.sleep(0.5)  # test harness: the focus settles
    save_layout("panes-strip")
    record("panes", "close-mid-strip", lambda: action("closePane"))
    # A zoom and an unzoom on a scrolled strip (its camera resets, then snaps back).
    for _ in range(3):
        action("newColumn")
        time.sleep(0.8)  # test harness: one column at a time
    record("panes", "zoom-strip", lambda: action("toggleSplitZoom"))
    record("panes", "unzoom-strip", lambda: action("toggleSplitZoom"))


def focus():
    # Focus moves between split panes in a fresh workspace (a restored
    # session's columns would fill the screen), then between strip columns.
    action("workspace.newAtBottom")
    time.sleep(1.0)  # test harness: the workspace settles
    action("splitRight")
    time.sleep(0.8)  # test harness: the split settles
    action("splitDown")
    time.sleep(0.8)  # test harness: the split settles
    save_layout("focus")
    record("focus", "left", lambda: action("focusLeft"))
    record("focus", "right", lambda: action("focusRight"))
    record("focus", "up", lambda: action("focusUp"))
    record("focus", "down", lambda: action("focusDown"))


def strip():
    # Focus moves left and right across a scrolling strip of columns, each with two tabs: the camera
    # scrolls and every column's tab bar moves with it (Lawrence 2026-10-18: "tabbar when i move
    # around left/right in niri is bad").
    action("workspace.newAtBottom")
    time.sleep(1.0)  # test harness: the workspace settles
    for _ in range(3):
        action("newColumn")
        time.sleep(0.8)  # test harness: one column at a time
    for _ in range(4):
        action("newSurface")
        time.sleep(0.4)  # test harness: one tab at a time
        action("focusLeft")
        time.sleep(0.4)  # test harness: the focus settles
    for _ in range(3):
        action("focusRight")
        time.sleep(0.6)  # test harness: the camera settles
    save_layout("strip")
    record("strip", "left-1", lambda: action("focusLeft"), layout=True)
    record("strip", "left-2", lambda: action("focusLeft"), layout=True)
    record("strip", "right-1", lambda: action("focusRight"), layout=True)
    record("strip", "right-2", lambda: action("focusRight"), layout=True)
    # The sidebar hidden: the strip runs under the traffic lights, whose inset a column's tab bar keeps.
    action("toggleSidebar", focus=True)
    time.sleep(1.0)  # test harness: the sidebar hides
    record("strip", "hidden-left-1", lambda: action("focusLeft"), layout=True)
    record("strip", "hidden-right-1", lambda: action("focusRight"), layout=True)
    action("toggleSidebar", focus=True)


def groups():
    # A tab group of two tabs collapses into its chip and expands again.
    action("workspace.newAtBottom")
    time.sleep(1.0)  # test harness: the workspace settles
    for _ in range(3):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    rpc("action.run", {"action": "selectSurfaceByNumber", "args": {"index": 2}})
    created = rpc("action.run", {"action": "tabGroup.create", "args": {"name": "Motion"}}) or {}
    group = (created.get("created") or [None])[0]
    rpc("action.run", {"action": "selectSurfaceByNumber", "args": {"index": 4}})
    rpc("action.run", {"action": "tabGroup.addTab", "args": {"group": group}})
    rpc("action.run", {"action": "selectSurfaceByNumber", "args": {"index": 1}})
    time.sleep(0.8)  # test harness: the strip settles
    save_layout("groups")
    target = {"kind": "tabGroup", "id": group}
    record("groups", "collapse", lambda: rpc("action.run", {"action": "tabGroup.collapse", "target": target}))
    record("groups", "expand", lambda: rpc("action.run", {"action": "tabGroup.expand", "target": target}))


def drag():
    # A tab lifted, carried past two tabs and dropped, at pointer pace.
    action("workspace.newAtBottom")
    time.sleep(1.0)  # test harness: the workspace settles
    for _ in range(3):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    save_layout("drag")
    pill = first_pill(busiest=True)
    if not pill:
        print("drag: skipped, pane_chrome reports no tab pill", flush=True)
        return
    left, top, width, height = pill
    x, y = left + width / 2, top + height / 2
    record("drag", "reorder", lambda: paced_drag(x, y, x + width * 2.2, y), seconds=2.0)
    record("drag", "back", lambda: paced_drag(x + width * 2, y, x, y), seconds=2.0)


def key(name, *modifiers):
    """A key press through the window's key path, as a person types it."""
    return rpc("debug.key", {"key": name, "modifiers": list(modifiers)})


def shown_toasts():
    print("toasts shown:", json.dumps((rpc("debug.filepages") or {}).get("toasts")), flush=True)


def toasts():
    # Toasts answer a person's gesture (automation runs show none), so each
    # step is a key press. Cmd-W on a terminal tab shows the close undo
    # toast, recorded until it ends by itself; a second close while one is
    # up replaces it; Cmd-Z undoes that close and its toast leaves. (A stack
    # needs a second kind of user toast: the palette's Pin Tab traps on
    # open, cx-bpcj, and a capture slot's window never becomes key, which
    # the zoom readout needs.)
    for _ in range(4):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    save_layout("toasts")
    record("toasts", "appear", lambda: key("w", "cmd"), seconds=7.5)
    shown_toasts()
    key("w", "cmd")
    time.sleep(1.0)  # test harness: the close toast is up
    record("toasts", "replace", lambda: key("w", "cmd"))
    record("toasts", "undo", lambda: key("z", "cmd"))
    shown_toasts()


def hold(x, y, seconds=0.6):
    """A press held in place (the chip's press-and-hold opens its editor)."""
    rpc("debug.mouse", {"action": "down", "x": x, "y": y})
    time.sleep(seconds)  # test harness: the hold
    return rpc("debug.mouse", {"action": "up", "x": x, "y": y})


def snapshot(name):
    path = os.path.join(opts.out, "popups", name + ".png")
    print(name, json.dumps(rpc("debug.window_snapshot", {"path": path}))[:200], flush=True)


def popups():
    # The tab group editor opens from a press-and-hold on its chip and
    # closes when its group is ungrouped; the sidebar group editor
    # opens from a click on its header and closes on a second click there.
    for _ in range(2):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    rpc("action.run", {"action": "selectSurfaceByNumber", "args": {"index": 1}})
    print("group:", json.dumps(rpc("action.run", {"action": "tabGroup.create", "args": {"name": "Motion"}}))[:200], flush=True)
    time.sleep(0.8)  # test harness: the chip settles
    save_layout("popups")
    chrome = (rpc("debug.pane_chrome") or {}).get("windows") or []
    pane = (chrome[0].get("panes") or [{}])[0] if chrome else {}
    strip, pill = pane.get("strip"), pane.get("pill")
    print("strip", strip, "pill", pill, flush=True)
    snapshot("chip")
    if strip and pill:
        x, y = (strip[0] + pill[0]) / 2, pill[1] + pill[3] / 2
        record("popups", "tab-open", lambda: hold(x, y))
        snapshot("tab-opened")
        # A click elsewhere closes it for a person by making the window key,
        # which a capture slot's window never becomes; Ungroup (its own row's
        # command) closes it as the group goes.
        record("popups", "tab-close", lambda: action("tabGroup.ungroup"))
        snapshot("tab-closed")
    print("ws group:", json.dumps(rpc("action.run", {"action": "workspace.moveToNewGroup", "args": {"name": "Motion"}}))[:200], flush=True)
    time.sleep(1.0)  # test harness: the group row settles
    rows = ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
    header = next((r for r in rows if str(r.get("key", "")).startswith("group")), None)
    print("header", json.dumps(header)[:300], flush=True)
    if header:
        f = header["window_frame"]
        hx, hy = f["x"] + 40, f["y"] + f["height"] / 2
        record("popups", "sidebar-open", lambda: rpc("debug.mouse", {"action": "click", "x": hx, "y": hy}))
        snapshot("sidebar-opened")
        record("popups", "sidebar-close", lambda: rpc("debug.mouse", {"action": "click", "x": hx, "y": hy}))
        snapshot("sidebar-closed")


def sweep(points, step=1 / 60):
    """The pointer through `points` (window coordinates, top-left origin),
    one `debug.pointer_hover` move per display frame, then out of the window."""
    height = opts.window_height
    entered = set()
    rpc("debug.motion", {"action": "start"})
    for x, y in points:
        reply = rpc("debug.pointer_hover", {"point": [x, height - y]}) or {}
        entered.update(reply.get("entered") or [])
        time.sleep(step)  # test harness: pointer pace, one move per frame
    rpc("debug.pointer_hover", {"point": None})
    time.sleep(0.3)  # test harness: the last fades settle
    trace = rpc("debug.motion", {"action": "stop"}) or {}
    print("hovered:", sorted(entered), "speed:", trace.get("speed"), "reduce_motion:", trace.get("reduce_motion"),
          "spans:", json.dumps(trace.get("spans"))[:600], flush=True)


def line(x0, y0, x1, y1, frames):
    return [(x0 + (x1 - x0) * i / frames, y0 + (y1 - y0) * i / frames) for i in range(frames + 1)]


def hover():
    # A fast sweep down the sidebar rows and along the tab strip, with the
    # hover fill clearing at once (the default) and over 120 ms
    # (`motion.fade.hoverOut`; absent on builds before cx-f6i7's hover pass).
    for _ in range(5):
        action("workspace.newAtBottom")
        time.sleep(0.3)  # test harness: one workspace at a time
    for _ in range(4):
        action("newTab")
        time.sleep(0.3)  # test harness: one tab at a time
    save_layout("hover")
    for out in (0, 0.12):
        rpc("debug.tunables", {"action": "set", "key": "motion.fade.hoverOut", "value": out})
        rpc("debug.motion", {"action": "speed", "value": "fast"})  # the tunable write reloads settings
        suffix = "-out%d" % round(out * 1000)
        record("hover", "sidebar" + suffix, lambda: sweep(line(110, 60, 110, 330, 16)))
        record("hover", "tabs" + suffix, lambda: sweep(line(240, 54, 900, 54, 16)))
    rpc("debug.tunables", {"action": "set", "key": "motion.fade.hoverOut", "value": None})


def dock():
    # A tab moved into a new dock column (the chat dock's path: a lone chat
    # moves into a left dock when it opens a tool), then the column undocks.
    save_layout("dock")
    for _ in range(2):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    for edge in ("left", "right"):
        record("dock", "dock-" + edge, lambda: rpc("action.run", {"action": "tab.moveToNewDockColumn", "args": {"edge": edge}}))
        record("dock", "undock-" + edge, lambda: action("column.undock"))


def sidebar():
    # Workspace rows open and close their slots: a new one at the end, one
    # closed in the middle (rows below close the gap), the last one closed.
    for _ in range(3):
        action("workspace.newAtBottom")
        time.sleep(0.4)  # test harness: one workspace at a time
    save_layout("sidebar")
    record("sidebar", "insert", lambda: action("workspace.newAtBottom"))
    # The second workspace row is selected with a click (no action selects it by place).
    rows = ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
    workspaces = [r for r in rows if str(r.get("key", "")).startswith("workspace")]
    print("workspace rows:", len(workspaces), flush=True)
    if len(workspaces) > 2:
        f = workspaces[1]["window_frame"]
        rpc("debug.mouse", {"action": "click", "x": f["x"] + 40, "y": f["y"] + f["height"] / 2})
        time.sleep(0.4)  # test harness: the selection settles
    record("sidebar", "remove-middle", lambda: action("closeWorkspace", args={"confirm": True}))
    action("workspace.selectLast")
    time.sleep(0.3)  # test harness: the selection settles
    record("sidebar", "remove-last", lambda: action("closeWorkspace", args={"confirm": True}))


def palette():
    # The palette opens over the window and closes again. Tab search opens it
    # over the active window (a child of it); a capture slot's app never
    # activates, and the palette opened with no key window closes at once.
    save_layout("palette")
    record("palette", "open", lambda: action("tab.search", focus=True))
    print("palette open:", json.dumps(rpc("debug.palette.capture", {"path": os.path.join(opts.out, "palette", "open.png")}))[:200], flush=True)
    record("palette", "close", lambda: rpc("debug.key", {"key": "escape", "target": "palette"}))
    print("palette closed:", json.dumps(rpc("debug.palette.capture", {"path": os.path.join(opts.out, "palette", "closed.png")}))[:200], flush=True)

def panels():
    # The notifications and feed panels open at the window's top-right corner
    # and close again (each action toggles its panel). Focus is requested as
    # for the palette: a capture slot's app never activates on its own.
    save_layout("panels")
    for name, toggle in (("notifications", "showNotifications"), ("feed", "feed.show")):
        record("panels", f"{name}-open", lambda toggle=toggle: action(toggle, focus=True))
        record("panels", f"{name}-close", lambda toggle=toggle: action(toggle, focus=True))

def everyday():
    # The audit's everyday session (cx-f6i7): one step after another, each
    # recorded. Steps that need focus run with it, as a person's would.
    steps = [
        ("home", lambda: action("home.show", focus=True)),
        ("new-workspace", lambda: action("workspace.newAtBottom", focus=True)),
        ("new-tab-page", lambda: action("newTab", focus=True)),
        ("new-terminal-tab", lambda: action("newSurface", focus=True)),
        ("next-tab", lambda: action("nextSurface", focus=True)),
        ("close-tab", lambda: action("closeTab", focus=True)),
        ("split-right", lambda: action("splitRight", focus=True)),
        ("split-down", lambda: action("splitDown", focus=True)),
        ("focus-left", lambda: action("focusLeft", focus=True)),
        ("zoom", lambda: action("toggleSplitZoom", focus=True)),
        ("unzoom", lambda: action("toggleSplitZoom", focus=True)),
        ("close-pane", lambda: action("closePane", focus=True)),
        ("new-chat", lambda: action("palette.newAgentChat", focus=True)),
        ("palette-open", lambda: action("tab.search", focus=True)),
        ("palette-close", lambda: rpc("debug.key", {"key": "escape", "target": "palette"})),
        ("settings-open", lambda: action("openSettings", focus=True)),
        ("settings-section", lambda: action("openSettings", focus=True, args={"section": "appearance"})),
        ("settings-close", lambda: action("closeTab", focus=True)),
        ("tab-group-create", lambda: action("tabGroup.create", focus=True)),
        ("tab-group-collapse", lambda: action("tabGroup.toggleCollapsed", focus=True)),
        ("tab-group-expand", lambda: action("tabGroup.toggleCollapsed", focus=True)),
        ("workspace-new-group", lambda: action("workspace.newInNewGroup", focus=True)),
        ("groups-collapse", lambda: action("workspaceGroup.collapseAll", focus=True)),
        ("groups-expand", lambda: action("workspaceGroup.expandAll", focus=True)),
        ("floating-chat-open", lambda: action("palette.quickAgentChat", focus=True)),
        ("floating-chat-close", lambda: action("palette.quickAgentChat", focus=True)),
        ("sidebar-hide", lambda: action("toggleSidebar", focus=True)),
        ("sidebar-show", lambda: action("toggleSidebar", focus=True)),
        ("home-again", lambda: action("home.show", focus=True)),
    ]
    save_layout("everyday")
    for index, (name, run) in enumerate(steps):
        def trigger(run=run, name=name):
            reply = run()
            if isinstance(reply, dict) and (reply.get("error") or reply.get("ok") is False):
                print(f"everyday {name}:", json.dumps(reply)[:300], flush=True)
        record("everyday", f"{index:02d}-{name}", trigger, seconds=1.6)
        time.sleep(0.3)  # test harness: settle between steps

def switch():
    # Workspace switches by number, as Cmd-1 to Cmd-9: to the next one, back,
    # and across several (each workspace keeps its own tabs and content).
    while len([r for r in ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
               if str(r.get("key", "")).startswith("workspace")]) < 4:
        action("workspace.newAtBottom")
        time.sleep(0.4)  # test harness: one workspace at a time
    # The last workspace's terminal holds a full screen of lines, so a switch to it shows
    # whether the whole screen or only the prompt redraws.
    action("selectWorkspaceByNumber", args={"index": 4})
    time.sleep(0.8)  # test harness: the terminal shows
    action("terminal.sendText", args={"text": "for i in $(seq 1 40); do echo line $i; done\r"})
    time.sleep(1.0)  # test harness: the lines print
    action("selectWorkspaceByNumber", args={"index": 1})
    time.sleep(0.6)  # test harness: the switch settles
    save_layout("switch")
    for name, index in (("next", 2), ("back", 1), ("across", 4), ("across-back", 1)):
        record("switch", name, lambda index=index: action("selectWorkspaceByNumber", args={"index": index}))


def hovercard():
    # A tab hover card shows after the pointer rests on a tab, then moves to
    # the next tab (a retarget: one tab's thumbnail replaces the other's).
    for _ in range(2):
        action("newSurface")
        time.sleep(0.5)  # test harness: one tab at a time
    save_layout("hovercard")
    pill = first_pill()
    if not pill:
        print("hovercard: skipped, pane_chrome reports no tab pill", flush=True)
        return
    left, top, width, height = pill
    y = opts.window_height - (top + height / 2)
    first, second = (left + width / 2, y), (left + width * 1.5, y)
    rpc("debug.pointer_hover", {"point": list(first)})
    record("hovercard", "show", lambda: time.sleep(0.05), seconds=2.5)  # test harness: the card's show delay
    record("hovercard", "retarget", lambda: rpc("debug.pointer_hover", {"point": list(second)}))
    print("hover cards:", json.dumps(rpc("debug.hover_cards"))[:300], flush=True)
    record("hovercard", "hide", lambda: rpc("debug.pointer_hover", {"point": None}))



SURFACES = {"strip": strip, "tabs": tabs, "panes": panes, "focus": focus, "toasts": toasts, "popups": popups, "hover": hover, "groups": groups, "drag": drag, "dock": dock, "sidebar": sidebar, "palette": palette, "hovercard": hovercard, "panels": panels, "everyday": everyday, "switch": switch}


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    os.makedirs(opts.out, exist_ok=True)
    # Capture slots can launch with ui.animationSpeed "off"; record at "fast" (in memory only).
    rpc("debug.motion", {"action": "speed", "value": "fast"})
    if opts.reduce_motion:
        print("reduce motion:", json.dumps(rpc("debug.motion", {"action": "reduce", "value": True}))[:120], flush=True)
    try:
        action("workspace.selectFirst")
        time.sleep(1.0)  # test harness: the workspace settles
        for name in opts.surface or list(SURFACES):
            SURFACES[name]()
    finally:
        if opts.reduce_motion:
            rpc("debug.motion", {"action": "reduce", "value": None})
    print("\nRESULT PASS (recorded)")


main()
