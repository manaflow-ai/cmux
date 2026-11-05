"""PIXEL PERFECT steps (group pixel-perfect; Lawrence 2026-11-03: "resizing columns/splits is still not pixel perfect
animated ... record + rewatch videos at every single animation speed ... browser tabs + TUI in terminal, with like
multiple pixel border ... with different terminal/app shell background color"). The cases are video-cases/gen_pixel.py,
the fixtures pixel/tui_border.py and pixel/page.html, the judge video-cases/judge_pixel.py.

driver.py loads this file (load_extensions) on the mini, under /usr/bin/python3 (3.9, standard library only).

The tunable store. Speeds and browserResize.pageBackdrop go through the app's Debug tunables (`debug.tunables`, DEBUG and
bench builds). The store is active only in Debug compiles and nightly bundles (DebugSettingsService.start returns early
otherwise), so the first use asks `debug.tunables state`; when it is not active, `debug.tunables activate` (memory only;
newer builds) once. When the store stays inactive: a film at x1 runs on the spring defaults, a Reduce Motion film runs
(`debug.motion reduce` needs no store), and every other speed is "not run: tunable store inactive" in its px_film result
(the journey goes on); the note of each film says whether the page backdrop could be turned off.

Steps (`do`):
  px_film      {name, speed: S | reduce: true, switch?: {key, value}, steps: [...], after?: [...]}
               One film at one speed: sets the speed (as px_springs); with SWITCH, then sets that Debug tunable (a feature
               switch, e.g. motion.frameOwner.terminals) and reads it back (after the speed, whose springs reset must never
               undo it); then plays STEPS (the set-up of the film,
               px_record_start, the input, video_stop) and AFTER (the rebuild of a closed pane) through the driver's own
               step handlers. When the switch does not take (a key this build does not have, an inactive tunable store:
               never a film at the default) or the speed cannot be set, it plays nothing and returns {film, status: "not
               run", reason}. The switch as read back goes into the film's note (`switch`).
  px_springs   {speed: S} | {reduce: true} | {reset: true}
               The speed alone: every `motion.spring.<token>` of SPRING_TOKENS gets its default response divided by S
               (0.25: x4 slower; 4: x4 faster) and its default damping, read back; `debug.motion speed fast` first (time
               scale 1, in memory). reduce: `debug.motion reduce true` (the springs at their defaults). Not run when S
               needs the store and it is inactive. reset: springs reset (when the store is active) and `debug.motion reduce
               null` (the system setting again): the case's `finally`. Overrides persist in debug-tunables.json until reset.
  px_tunable   {key, value, required?}  one `debug.tunables set` (value null resets it), read back; `applied` false when
               the value did not take (store inactive): recorded, never a failure; the note says what the app kept.
               With `required` (a film fixture the case cannot film without, such as the tab outline) a value that does
               not take makes the round "not run" with the reason.
  px_page      {pane, bg, label?, x?, y?, z?, timeout?}
               Opens page.html (/tmp/jr-pixel-page.html, a `file` step wrote it) in a new browser tab of the named
               pane: `cmux pane <id> focus`, then `action.run openBrowser {url: file:///tmp/jr-pixel-page.html?bg=..,
               engine: cef}` (the action the person's Cmd-Shift-L runs; the run's own `focus` selects the tab); waits
               until debug.surfaces shows the pane's selected tab and `browser.page.eval` reads the page's own report
               twice with its rAF counter moving. Navigates the tab (`browser.page.navigate`) when another page opened.
  px_agent_css {fill?, remove?}
               Writes agent-pane/theme.css beside the slot's settings file (CMUX_NEXT_CONFIG_FILE: the agent pane
               watches and injects it): a loud page background and a fixed overlay with 1, 2 and 3 px rings in the
               fixture's ring colors, so an agent pane is judged as a page is. remove: deletes it (the case's finally).
  px_record_start {name, seconds, require_hz?, fixture: {NAME: {kind: tui|page|agent, fill: "#RRGGBB"}}, spring?: TOKEN,
               spring_default?: {response, damping}, input?: TEXT, lines_per_pane?: [fractions]}
               ext_video's video_start with scan lines (device px) that cross every pane border and every tab strip,
               from debug.pane_chrome (window points): first a row through the vertical middle of each pane's tab strip,
               then for each pane a row at each fraction of its content border's height and a column at each fraction
               of its width (default 0.3 and 0.7: clear of the TUI's ruler and centre text and of the page's ruler), as
               many as the recorder's 256 MB scan budget holds for the film. Then the judge's note in the recording's
               meta notes (`pixel`): the scale, the colors, each fixture pane's app pane id, kind, fill and name; the
               speed or Reduce Motion and where the springs came from; the declared spring of the input (TOKEN's
               response after the scale and its damping as the app applies it: structural tokens never under 1; from
               spring_default when the store cannot be read); the page backdrop as the app has it; the tunable store;
               each pane's strip, pill, cell and border at the start; the window frame; the lines and the strip rows.
               The recorder first (cmux22 2026-11-03: a second film's ScreenCaptureKit start gave no callback within
               ext_video's 8 s): waits until the app's recorder is idle (record_read: nothing capturing, the last
               recording written; after a failed start the app has dropped it), starts with the app's own bound
               (START_TIMEOUT: its two ScreenCaptureKit calls of at most 10 s each) and tries a start that did not take
               once more; each attempt's reason and each idle wait are in the note (`recorder`). A film whose start
               does not take the second time either (cmux22 2026-11-03: 4 of 40 starts stalled at the app's 10 s
               bound) is that film's "not run" line: px_film skips its motion and its rebuild (before the recorder a
               film only focuses and waits) and the journey goes on; the second such film ends the journey (not run).
  px_film also records each film's movie and scan bytes (`bytes`), so a round whose fetch fails still says how big
  its films were.
  px_agent     {pane, timeout?: 20}
               An agent chat in the named pane: `action.run palette.newAgentChat` with target pane:<id> and no focus, the
               app's targeted path (AgentHandlers.openTargetedChat) that opens the chat tab in that pane. With no target,
               a script's chat goes to a new left chat dock (NewChatPlacement .newDock) and leaves the pane a terminal;
               with focus the targeted path is not taken. The run answers the chat tab (`result.tab`) from the store,
               before the control snapshot lists it, and action.run finds a `tab:` target only in that snapshot
               (PublicIDTargetResolver): so px_agent first waits until snapshot.get (the same snapshot) lists the
               pane's chat tab, the answered id or else the one new tab of kind conversation, never a provisional
               `pending_tab_` id. In a pane a window shows, the targeted path leaves the selection alone (#23085), so
               px_agent selects the tab (`action.run tab.focus`, target tab:<id>: a focus action, as `cmux tab <id>
               focus`) unless the pane shows it already, then waits until debug.surfaces reports that tab selected and
               shown with content kind "agent" (TabContent.agent), all in one budget, and focuses the pane (`cmux pane
               focus`) for the next set-up step. Its result says where the id came from (`tab_source`) and how long the
               snapshot took to list it (`listed_s`).
  px_switch    {key, value}
               A feature switch (a boolean Debug tunable) for the rest of the journey: the store activated when it is
               inactive (`debug.tunables activate`), the switch set and read back. A switch that does not take (a key
               this build does not have, an inactive store) makes the round "not run" with the reason, never a run at
               the default. For journeys that relaunch the app (typing-load-l6's probe_relaunch: a bench build keeps
               tunables in memory only), it goes after the relaunch.
  px_window_frame {by: [dx, dy], ms?: 600, mark?}
               A live resize of the window from its bottom-right corner through ext_window's window_drag: debug.mouse down,
               drags at 120 events a second and up, which AppKit's own resize tracking reads as a person's drag (the path
               the R3a journeys take). A CuaDriver drag never reached the corner on cmux22 (2026-11-03). Logged in the
               film's events (kind window_drag) with the frame before and after.
  px_tab_new   {pane, timeout?: 20}
               One more terminal tab in the named pane: `action.run newSurface` aimed at the pane's selected tab (a pane
               target is refused) with the run's focus; waits until snapshot.get, the snapshot action.run resolves
               targets against, lists exactly one new terminal tab with a terminal, selects it with tab.focus unless the
               pane selected it, waits until debug.surfaces shows it and its shell has drawn, then makes its terminal the
               journey's terminal and the pane's named terminal (rk_focus, neutral_prompt and the after check read it).
  px_hold_tab_close {key, modifiers?, seconds?, delay?, interval?, mark?, close: {pane, which: middle, after_ms: 50},
                     timeout?: 5}
               The held key of rk_hold with its first key-down fixed CLOSE_LEAD_S ahead (ext_spam hold_key `start_at`, the
               app's clock), and on its own thread a script's `action.run closeTab` of the pane's middle tab (its id from
               snapshot.get, 3 tabs or more) AFTER_MS after that key-down. Waits until snapshot.get no longer lists the
               tab. The film's pixel note gets `tab_close`: the pane, its label, the tab and its index, the tabs before
               and after, the first key-down, the planned and the real delay, and the close's send and return times on
               the host clock (CLOCK_UPTIME_RAW: the trace's t0_s and the scan's frame times), so the judge finds the
               first frame after the close; events.json gets it as kind tab_close.
  px_key_then_drag {key, modifiers?, after_ms?: 60, drag: {target: {divider | row_divider: N}, by, duration_ms, share?: 1},
                    spring_default?, mark?}
               Stage S2b (a drag during a key spring). One real HID key (rk_press), then a real HID drag (ext_video
               hid_drag, hold 0) whose call starts AFTER_MS after the key-down: one CuaDriver session serves one call at a
               time. Its mouse-down reaches the app DRAG_DOWN_S (260-400 ms, cmux22) after the call, and the app hit-tests
               a divider at its shown frame, so the press goes where the edge will be then: its rest place plus SHARE
               times the key's step (KEY_STEP of the viewport, debug.pane_chrome main_pane) times the move spring's
               progress (this film's response). SHARE: how much of the key's step the dragged divider moves (1: it moves
               with the key's edge; 0: it stays, as the edge past the two columns a resize key trades since KEYS #34123). A split divider spans its column: the same shift lands in its middle. After the drag: the
               journal's key-down and mouse-down, and the trace. The film is "not run" (px_film: recorded and rebuilt, never
               judged) when vertical divider 0 (the column edge right of p0, which the key springs) did not move in the 3
               refreshes before the mouse-down (no overlap), or the dragged divider did not follow the pointer (the press
               missed it). The film's pixel note gets `key_then_drag`: the plan (rest, press, step, spring), the key's and
               the drag's send times, the journal's key-down and mouse-down, the spring edge at the mouse-down and what it
               had left, the dragged edge's travel and the verdict, on the host clock.
"""
import json
import math
import os
import threading
import time
import urllib.parse

D = None
V = None  # ext_video: video_start, the recording
W = None  # ext_window: named panes
S = None  # ext_spam: uptime (the app's clock: CLOCK_UPTIME_RAW, the trace's and the scan's) for the held keys

# Every spring token (MotionTunables.springDefaults): the whole app runs at the case's speed, so a pane and the strip
# camera that reveals it never move at two speeds.
SPRING_TOKENS = ("move", "appear", "disappear", "settle", "scroll", "screen", "track", "selection", "panel", "pinDrag",
                 "zoom", "exit", "tabOpen", "split", "popover", "popoverClose")
# MotionPolicy.spring: these get their damping raised to at least 1 (bounce none, the default).
STRUCTURAL = ("move", "appear", "disappear", "tabOpen")
ROLES = {"shell": "#FF00FF", "theme": "#00FFFF", "ring1": "#FF0000", "ring2": "#FFFFFF", "ring3": "#000000", "strip": "#000000"}
PAGE_PATH = "/tmp/jr-pixel-page.html"
SCAN_BUDGET = 230 << 20  # the recorder keeps at most 256 MB of scan lines (MotionScreenRecord.maxScanBytes)
FILM_HZ = 120
BACKDROP_KEY = "browserResize.pageBackdrop"
RESULT_CHARS = 2400  # a px_film sub-step's result kept in result.json, at most
# MotionScreenRecord bounds each ScreenCaptureKit call (the content list, the start) at 10 s (callLimit) and then reports
# its own error: wait for both, and a margin.
START_TIMEOUT = 22.0
START_ATTEMPTS = 2
IDLE_TIMEOUT = 35.0  # the last recording's stop (at most 10 s) and its files
IDLE_AFTER_ERROR_S = 0.5  # after a failed start the app has dropped it; its files close within milliseconds
RECORDER_RETRY = ("ScreenCaptureKit did not start", "still being written")
# The second film of a journey whose recorder does not start ends the journey (not run): the recorder is unreliable on
# this run, and each such film costs START_ATTEMPTS app bounds of 10 s.
FILMS_NOT_STARTED_MAX = 2

FilmNotStarted = None  # install(): a driver NotRun (this file must not import the driver, which runs as __main__)


def install(driver):
    global D, V, W, S, FilmNotStarted
    D = driver

    class FilmNotStarted(driver.NotRun):  # the module's name (global above), bound once the driver is
        """The recorder did not start a film in START_ATTEMPTS tries (a retryable reason, RECORDER_RETRY, every time).
        px_film makes that film one "not run" line and the journey goes on: before its recorder starts a film only
        focuses and waits (gen_pixel.py), so the layout is still the one the next film expects. Elsewhere a NotRun."""

    import ext_spam
    import ext_video
    import ext_window
    V, W, S = ext_video, ext_window, ext_spam


def _tunables(j, **params):
    reply = j.app.rpc("debug.tunables", params) or {}
    if isinstance(reply, dict) and reply.get("error"):
        raise D.StepError(f"debug.tunables {params.get('action')}: {reply['error']}")
    return reply


def _spring_value(row):
    """{response, dampingFraction} of a debug.tunables row's value or default."""
    value = row if isinstance(row, dict) else {}
    out = {}
    for key in ("response", "dampingFraction"):
        if isinstance(value.get(key), (int, float)):
            out[key] = float(value[key])
    return out if len(out) == 2 else None


def _state(j):
    if not hasattr(j, "px"):
        j.px = {"speed": 1.0, "reduce": False, "springs": {}, "springs_source": "defaults", "tunables": {}, "films": []}
    return j.px


def _store(j):
    """{active, activated, available, why}: whether tunable overrides take in this app. Asks `debug.tunables state` once
    per journey; when it is not active, `debug.tunables activate` (newer builds: the store on, in memory) and asks again."""
    st = _state(j)
    if "store" in st:
        return st["store"]
    info = {"active": False, "activated": False, "available": None, "why": ""}
    try:
        state = _tunables(j, action="state")
    except D.StepError as error:
        info["why"] = f"debug.tunables state failed: {str(error)[:200]}"
        st["store"] = info
        return info
    info.update(active=bool(state.get("active")), available=state.get("available"))
    if not info["active"]:
        try:
            reply = j.app.rpc("debug.tunables", {"action": "activate"}) or {}
            refused = reply.get("error") if isinstance(reply, dict) else None
        except D.StepError as error:
            reply, refused = {}, str(error)
        if refused:
            info["why"] = f"tunable store inactive (debug.tunables state active false; activate: {str(refused)[:160]})"
        else:
            again = _tunables(j, action="state")
            info.update(active=bool(again.get("active")), activated=bool(again.get("active")))
            if not info["active"]:
                info["why"] = f"tunable store inactive after activate: {json.dumps(again)[:200]}"
    st["store"] = info
    return info


def apply_speed(j, speed=None, reduce=False):
    """Sets the speed of the next film: (applied, facts). Reduce Motion and x1 need no store; any other speed does."""
    st = _state(j)
    store = _store(j)
    j.app.rpc("debug.motion", {"action": "speed", "value": "fast"})
    if reduce:
        if store["active"]:
            _tunables(j, action="reset", section="springs")
        reply = j.app.rpc("debug.motion", {"action": "reduce", "value": True}) or {}
        st.update(speed=1.0, reduce=True, springs={}, springs_source="defaults")
        return True, {"reduce": True, "store_active": store["active"],
                      "motion": {k: reply.get(k) for k in ("reduce_motion", "speed", "pane_animations") if k in reply}}
    speed = float(speed)
    if not 0.05 <= speed <= 20:
        raise D.StepError(f"speed {speed} is out of range")
    j.app.rpc("debug.motion", {"action": "reduce", "value": False})
    if not store["active"]:
        if abs(speed - 1.0) < 1e-9:
            st.update(speed=1.0, reduce=False, springs={}, springs_source="defaults (tunable store inactive)")
            return True, {"speed": 1.0, "store_active": False, "springs": "defaults"}
        return False, {"speed": speed, "store_active": False, "reason": f"not run: {store['why'] or 'tunable store inactive'}"}
    springs = {}
    for token in SPRING_TOKENS:
        key = f"motion.spring.{token}"
        row = _tunables(j, action="get", key=key)
        base = _spring_value(row.get("default"))
        if base is None:
            raise D.StepError(f"{key} has no spring default: {json.dumps(row)[:200]}")
        want = {"response": round(base["response"] / speed, 6), "dampingFraction": base["dampingFraction"]}
        got = _spring_value(_tunables(j, action="set", key=key, value=want).get("value")) or {}
        if abs(got.get("response", -1) - want["response"]) > 1e-6 or abs(got.get("dampingFraction", -1) - want["dampingFraction"]) > 1e-9:
            raise D.StepError(f"{key} reads back {got}, not {want} (the tunable clamps response 0.02..2 s)")
        damping = max(base["dampingFraction"], 1.0) if token in STRUCTURAL else base["dampingFraction"]
        springs[token] = {"response": want["response"], "damping": damping, "default_response": base["response"],
                          "default_damping": base["dampingFraction"]}
    st.update(speed=speed, reduce=False, springs=springs, springs_source="overrides" if abs(speed - 1.0) > 1e-9 else "defaults")
    return True, {"speed": speed, "store_active": True, "activated": store["activated"], "keys": [f"motion.spring.{t}" for t in SPRING_TOKENS],
                  "move": springs.get("move"), "split": springs.get("split")}


def step_px_springs(j, step):
    st = _state(j)
    if step.get("reset"):
        store = st.get("store") or {}
        out = {"reduce": j.app.rpc("debug.motion", {"action": "reduce", "value": None})}
        if store.get("active", True):
            try:
                out["springs"] = _tunables(j, action="reset", section="springs")
            except D.StepError as error:
                out["springs"] = {"error": str(error)[:200]}
        st.update(speed=1.0, reduce=False, springs={}, springs_source="defaults")
        return out
    applied, facts = apply_speed(j, step.get("speed"), bool(step.get("reduce")))
    if not applied:
        raise D.NotRun(f"px_springs: {facts['reason']}")
    return facts


def step_px_tunable(j, step):
    key = step["key"]
    store = _store(j)
    try:
        row = _tunables(j, action="set", key=key, value=step.get("value"))
    except D.StepError as error:
        row = {"error": str(error)[:200]}
    wanted = step.get("value")
    value = row.get("value")
    applied = (value == row.get("default")) if wanted is None else (value == wanted)
    rec = {"key": key, "wanted": wanted, "value": value, "default": row.get("default"), "applied": bool(applied) and "error" not in row,
           "store_active": store["active"], "why": "" if applied else (row.get("error") or store["why"] or "the value did not take")}
    _state(j)["tunables"][key] = rec
    if step.get("required") and not rec["applied"]:
        # A fixture the case cannot film without (the tab outline): a build that does not take it is not run.
        raise D.NotRun(f"px_tunable: {key} = {json.dumps(wanted)} did not take: {rec['why']}")
    return rec


def _surface_row(j, pane_key):
    for w in (j.app.rpc("debug.surfaces") or {}).get("windows") or []:
        for p in w.get("panes") or []:
            if isinstance(p, dict) and p.get("pane") == pane_key:
                return p
    return None


def page_url(bg, label="", x=None, y=None, z=None):
    query = {"bg": bg.lstrip("#")}
    for k, v in (("x", x), ("y", y), ("z", z)):
        if v:
            query[k] = v.lstrip("#")
    if label:
        query["label"] = label
    return "file://" + PAGE_PATH + "?" + urllib.parse.urlencode(query)


def step_px_page(j, step):
    rec = W.named(j, step["pane"])
    url = page_url(step["bg"], step.get("label", step["pane"]), step.get("x"), step.get("y"), step.get("z"))
    focus = j.app.cmux("pane", rec["pane"], "focus")
    end = D.now() + 5
    while D.now() < end and not (_surface_row(j, rec["pane"]) or {}).get("focused"):
        time.sleep(0.05)  # orchestration poll of the app's own report
    # openBrowser takes url, engine and profile; the run's own `focus` (not an argument) lets it select the new tab.
    opened = j.app.rpc("action.run", {"action": "openBrowser", "args": {"url": url, "engine": "cef"}, "focus": True})
    timeout = float(step.get("timeout", 30))
    t0 = D.now()
    row, navigated, report, last = None, None, None, ""
    while D.now() < t0 + timeout:
        row = _surface_row(j, rec["pane"]) or {}
        tab = row.get("selected_tab")
        shown = str(row.get("url") or "")
        if tab and row.get("kind") != "terminal":
            if shown and os.path.basename(PAGE_PATH) not in shown and navigated is None and D.now() - t0 > 5:
                navigated = j.app.rpc("browser.page.navigate", {"tab": tab, "url": url})
            try:
                value = (j.app.rpc("browser.page.eval", {"tab": tab, "script": "window.__pixelFixture ? window.__pixelFixture() : null"},
                                   timeout=10) or {}).get("value")
            except D.StepError as error:
                value, last = None, str(error)[:200]
            if isinstance(value, dict) and value.get("w"):
                # Two reads with the rAF counter moving: the page runs (it draws every frame).
                if report and value.get("raf", 0) > report.get("raf", 0):
                    page = {"pane": rec["pane"], "tab": tab, "url": shown, "page": value, "focus": focus, "opened": opened,
                            "navigated": navigated}
                    j.px_pages = dict(getattr(j, "px_pages", {}), **{step["pane"]: page})
                    return page
                report = value
        time.sleep(0.25)  # orchestration poll
    raise D.StepError(f"px_page {step['pane']}: the page did not run within {timeout} s (pane {json.dumps(row)[:300]}; last eval "
                      f"error: {last}; openBrowser: {json.dumps(opened)[:200]})")


def agent_css(fill, rings=None):
    r1, r2, r3 = rings or (ROLES["ring1"], ROLES["ring2"], ROLES["ring3"])
    return ("/* PIXEL PERFECT fixture (gen_pixel.py): a loud ground and rings of 1, 2 and 3 px, as page.html. */\n"
            f"html, body {{ background: {fill} !important; }}\n"
            "html::after { content: \"\"; position: fixed; top: 0; right: 0; bottom: 0; left: 0; box-sizing: border-box;\n"
            f"  border: 1px solid {r1}; box-shadow: inset 0 0 0 2px {r2}, inset 0 0 0 5px {r3};\n"
            "  pointer-events: none; z-index: 2147483647; }\n")


def step_px_agent_css(j, step):
    path = os.path.join(os.path.dirname(j.config_file()), "agent-pane", "theme.css")
    if step.get("remove"):
        try:
            os.unlink(path)
            return {"removed": path}
        except OSError:
            return {"removed": None}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    text = agent_css(step.get("fill", "#0000FF"), step.get("rings"))
    with open(path, "w") as f:
        f.write(text)
    return {"path": path, "bytes": len(text)}


def _layers_frame(j):
    """The main window's frame and its screen's frame (debug.layers: global points, bottom-left origin)."""
    report = j.app.rpc("debug.layers") or {}
    for w in report.get("windows") or []:
        if isinstance(w, dict) and w.get("frame") and w.get("screen_frame"):
            return [float(v) for v in w["frame"]], [float(v) for v in w["screen_frame"]]
    raise D.StepError("px_record_start: debug.layers has no main window frame")


def frame_size(window, screen, scale):
    """The recorder's frame (device px): from the main window's top-left to its screen's right and bottom edges."""
    wx, wy, ww, wh = window
    sx, sy, sw, sh = screen
    left, top = max(0.0, wx - sx), max(0.0, (sy + sh) - (wy + wh))
    return int(round(max(ww, sw - left) * scale)) // 2 * 2, int(round(max(wh, sh - top) * scale)) // 2 * 2


def scan_lines(panes, scale, width, height, seconds, fractions=(0.3, 0.7), budget=SCAN_BUDGET, hz=FILM_HZ, strips=()):
    """Rows and columns (device px): first a row through each strip [x, y, w, h] (its vertical middle), then for each pane
    rect [x, y, w, h] (window points) a row at each fraction of its height and a column at each fraction of its width
    (every pane's first fraction first), deduplicated within 6 px, as many as `budget` bytes of scan hold for `seconds` of
    film at `hz`. Returns (rows, columns, strip rows {index: y}, dropped, bytes)."""
    frames = int(hz * (float(seconds) + 1.5))
    per_line = {"row": 4 * width, "col": 4 * height}
    wanted = [("strip", i, int(round((y + h / 2) * scale))) for i, (x, y, w, h) in enumerate(strips)]
    for frac in fractions:
        for x, y, w, h in panes:
            wanted.append(("row", None, int(round((y + h * frac) * scale))))
            wanted.append(("col", None, int(round((x + w * frac) * scale))))
    rows, cols, strip_rows, dropped, used = [], [], {}, 0, 8 * frames
    for axis, index, v in wanted:
        kind = "col" if axis == "col" else "row"
        limit = height if kind == "row" else width
        if not 0 <= v < limit:
            continue
        have = rows if kind == "row" else cols
        near = [o for o in have if abs(v - o) < 6]
        if near:
            if axis == "strip" and near[0] in strip_rows.values():
                strip_rows[index] = near[0]  # a strip at the same height as another one: one row for both
            continue
        cost = per_line[kind] * frames
        if used + cost > budget:
            dropped += 1
            continue
        have.append(v)
        used += cost
        if axis == "strip":
            strip_rows[index] = v
    return sorted(rows), sorted(cols), strip_rows, dropped, used


def _backdrop(j):
    """browserResize.pageBackdrop as the app has it now: True, False, or None when it cannot be read."""
    try:
        return _tunables(j, action="get", key=BACKDROP_KEY).get("value")
    except D.StepError:
        return None


def recorder_idle(j, timeout=IDLE_TIMEOUT):
    """Waits until the app's recorder is idle, on its own state (debug.motion record_read): no recording capturing or
    starting, and the last one written (`written`; none at all reads {capturing: false}). A read that raises carries
    the app's last start error: that recording was dropped, so the recorder is idle once its files close. Returns
    {waited_s, state}; raises NotRun when it is not idle within TIMEOUT."""
    t0 = D.now()
    state = {}
    while True:
        try:
            state = j.app.rpc("debug.motion", {"action": "record_read"}) or {}
        except D.StepError as error:
            time.sleep(IDLE_AFTER_ERROR_S)
            return {"waited_s": round(D.now() - t0, 3), "state": {"error": str(error)[:300]}}
        if not state.get("capturing") and state.get("written", True):
            return {"waited_s": round(D.now() - t0, 3), "state": {k: state.get(k) for k in ("capturing", "written", "movie_status", "callbacks")}}
        if D.now() - t0 > timeout:
            raise D.NotRun(f"the app's recorder is not idle after {timeout:.0f} s: {json.dumps(state)[:300]}")
        time.sleep(0.05)  # orchestration poll of the app's own state


def start_film(j, step):
    """ext_video's video_start once the recorder is idle, with the app's own start bound; a start that did not take is
    tried once more. Returns (video_start's reply, {idle: [...], attempts: [reasons]})."""
    recorder = {"idle": [], "attempts": []}
    for attempt in range(START_ATTEMPTS):
        recorder["idle"].append(recorder_idle(j))
        try:
            return V.step_video_start(j, dict(step, start_timeout=float(step.get("start_timeout", START_TIMEOUT)))), recorder
        except (D.NotRun, D.StepError) as error:
            retry = any(text in str(error) for text in RECORDER_RETRY)
            if not retry:
                if recorder["attempts"]:
                    raise type(error)(f"{error} (after {len(recorder['attempts'])} earlier start(s): "
                                      f"{' | '.join(recorder['attempts'])[:400]})")
                raise
            if attempt == START_ATTEMPTS - 1:
                earlier = f" (after {len(recorder['attempts'])} earlier start(s): {' | '.join(recorder['attempts'])[:400]})" \
                    if recorder["attempts"] else ""
                raise FilmNotStarted(f"{error}{earlier}")
            recorder["attempts"].append(str(error)[:300])
    raise D.NotRun("unreachable")


def step_px_record_start(j, step):
    st = _state(j)
    chrome = j.app.rpc("debug.pane_chrome") or {}
    fixture = step.get("fixture") or {}
    keys = {name: W.named(j, name)["pane"] for name in fixture}
    window = None
    for w in chrome.get("windows") or []:
        ids = {p.get("pane") for p in w.get("panes") or []}
        if any(k in ids for k in keys.values()):
            window = w
            break
    if window is None:
        raise D.StepError(f"px_record_start: no window of debug.pane_chrome shows the fixture panes {sorted(keys.values())}")
    scale = float(window.get("scale") or 2.0)
    win_frame, screen_frame = _layers_frame(j)
    width, height = frame_size(win_frame, screen_frame, scale)
    panes = [p for p in window.get("panes") or [] if p.get("border") or p.get("cell")]
    rects = [p.get("border") or p.get("cell") for p in panes]
    strip_panes = [p for p in panes if p.get("strip") and not p.get("strip_hidden") and float(p["strip"][3]) > 2]
    rows, cols, strip_index, dropped, used = scan_lines(rects, scale, width, height, float(step.get("seconds", 20)),
                                                        tuple(step.get("lines_per_pane") or (0.3, 0.7)),
                                                        strips=[p["strip"] for p in strip_panes])
    strip_rows = {strip_panes[i]["pane"]: y for i, y in strip_index.items()}
    started, recorder = start_film(j, dict(step, rows=rows, columns=cols))
    token = step.get("spring")
    spring = None
    if token and not st["reduce"]:
        sp = st["springs"].get(token)
        if sp is None:
            # No override set (x1, or the store is inactive): the token's default as the app applies it.
            base = None
            try:
                row = _tunables(j, action="get", key=f"motion.spring.{token}")
                base = _spring_value(row.get("value")) or _spring_value(row.get("default"))
            except D.StepError:
                base = None
            if base:
                damping = max(base["dampingFraction"], 1.0) if token in STRUCTURAL else base["dampingFraction"]
                sp = {"response": base["response"], "damping": damping, "source": "debug.tunables get"}
            elif step.get("spring_default"):
                sp = dict(step["spring_default"], source="gen_pixel.py (MotionTunables.springDefaults)")
        if sp:
            spring = {"token": token, "response": sp["response"], "damping": sp["damping"], "source": sp.get("source", st["springs_source"])}
    backdrop = _backdrop(j)
    note = {"scale": scale, "roles": dict(ROLES), "speed": st["speed"], "reduce": st["reduce"], "spring": spring,
            "springs_source": st["springs_source"], "store": st.get("store"), "input": step.get("input"),
            "switch": st.get("switch"),
            "page_backdrop": backdrop, "tunables": st["tunables"], "pages": getattr(j, "px_pages", {}),
            "frame": [width, height], "window_frame": win_frame, "screen_frame": screen_frame,
            "main_pane": window.get("main_pane"),
            "lines": {"rows": rows, "columns": cols, "strip_rows": strip_rows, "dropped": dropped, "scan_bytes_planned": used},
            "recorder": recorder,
            "panes": {keys[name]: dict({"kind": "page" if info.get("kind") == "agent" else info.get("kind"), "agent": info.get("kind") == "agent",
                                        "fill": info.get("fill"), "label": name}, **({"wrap": info["wrap"]} if info.get("wrap") else {}))
                      for name, info in fixture.items()},
            "chrome": [{k: p.get(k) for k in ("pane", "cell", "border", "first_cell", "strip", "pill", "strip_hidden")}
                       for p in window.get("panes") or []]}
    if getattr(j, "video", None) is not None:
        j.video["notes"]["pixel"] = note
    return dict(started, rows=rows, columns=cols, strip_rows=strip_rows, dropped_lines=dropped,
                fixture={keys[n]: n for n in fixture}, spring=spring, page_backdrop=backdrop, recorder=recorder)


def _short(value):
    text = json.dumps(value, default=str)
    return value if len(text) <= RESULT_CHARS else text[:RESULT_CHARS] + "..."


def set_switch(j, key, value):
    """A feature switch (a Debug tunable) set to VALUE and read back: (applied, {key, wanted, value, applied[, why]}).
    Applied only when the store takes overrides and the read-back value is VALUE: an OFF read back from an inactive store
    is the default, not the kit's setting, so it is not applied either."""
    store = _store(j)
    rec = step_px_tunable(j, {"key": key, "value": value})
    applied = bool(rec["applied"]) and bool(store["active"])
    out = {"key": key, "wanted": value, "value": rec.get("value"), "applied": applied}
    if not applied:
        out["why"] = rec["why"] if not rec["applied"] else (store["why"] or "tunable store inactive")
    _state(j)["switch"] = out
    return applied, out


def step_px_switch(j, step):
    # A relaunch starts a new app: the store must be asked again (activate is per process, memory only).
    _state(j).pop("store", None)
    ok, rec = set_switch(j, step["key"], step["value"])
    if not ok:
        raise D.NotRun(f"px_switch: {rec['key']} = {json.dumps(rec['wanted'])} did not take: {rec['why']}")
    return rec


def step_px_film(j, step):
    name = step["name"]
    reduce = bool(step.get("reduce"))
    st = _state(j)
    applied, facts = apply_speed(j, None if reduce else step.get("speed"), reduce)
    if not applied:
        line = {"film": name, "status": "not run", "reason": facts["reason"], "speed": facts.get("speed")}
        st["films"].append(line)
        return line
    switch = None
    if step.get("switch"):
        # After the speed: the speed resets the springs section, which must never undo the switch.
        ok, switch = set_switch(j, step["switch"]["key"], step["switch"]["value"])
        if not ok:
            line = {"film": name, "status": "not run", "speed": None if reduce else step.get("speed"), "switch": switch,
                    "reason": f"not run: {switch['key']} = {json.dumps(switch['wanted'])} did not take: {switch['why']}"}
            st["films"].append(line)
            return line
    done = []
    st.pop("film_not_run", None)  # a film step's own verdict (px_key_then_drag): this film's only
    for sub in list(step.get("steps") or []) + list(step.get("after") or []):
        handler = getattr(j, "step_" + str(sub.get("do")), None)
        if handler is None:
            raise D.StepError(f"px_film {name}: unknown step {sub.get('do')!r}")
        t = D.now()
        try:
            out = handler(sub)
        except FilmNotStarted as error:
            return film_not_started(j, name, reduce, switch, done, error)
        except D.StepError as error:
            # The film failed mid-way: stop its recording first, so the movie is finished (its moov written) and the
            # failed film can still be watched; then report the step's error (cmux-ad m29: 20 films had no moov).
            stopped = _stop_failed_film(j, name)
            raise D.StepError(f"px_film {name}: {sub['do']} ({sub.get('title', '')[:60]}): {error}" + stopped)
        except BaseException:
            # Any other way out (a NotRun such as a drag that did not reach the app, an interrupt): the recording is
            # stopped and kept the same way, then the original exception goes on unchanged (ab-m28r2: a NotRun left the
            # Reduce Motion movie without its moov).
            _stop_failed_film(j, name)
            raise
        if sub.get("keep"):
            # `keep` (a film's measurement read, e.g. debug.frames stop raw): the whole reply in its own file, so a long
            # array is not cut at RESULT_CHARS; result.json keeps the file name.
            path = j.out / f"{step['name']}.{sub['keep']}.json"
            path.write_text(json.dumps(out, default=str))
            out = {"kept": path.name, "bytes": path.stat().st_size}
        done.append({"do": sub["do"], "title": sub.get("title", ""), "seconds": round(D.now() - t, 3), "result": _short(out)})
    line = {"film": name, "status": "recorded", "speed": None if reduce else st["speed"], "reduce": reduce,
            "springs_source": st["springs_source"], "speed_facts": facts, "bytes": film_bytes(j, name), "steps": done}
    verdict = st.pop("film_not_run", None)
    if verdict:
        # Recorded and rebuilt, but not a film of what the case films (no overlap, a missed press): never judged a pass.
        line.update(status="not run", reason=verdict)
    if switch:
        line["switch"] = switch
    st["films"].append({k: line[k] for k in ("film", "status", "reason", "speed", "reduce", "springs_source", "bytes", "switch")
                        if k in line})
    return line


def _stop_failed_film(j, name):
    """A film whose step failed while it recorded: its recording stopped through the kit's own stop (video_stop with no
    tail), so the movie, its scan, trace and meta are written. Returns a note for the error line; a stop that fails too is
    named there, never hidden."""
    rec = getattr(j, "video", None)
    if not rec or rec.get("name") != name:
        return ""
    try:
        j.step_video_stop({"name": name, "tail": 0.0})
        return " (its recording was stopped and kept: the film shows the run up to the failure)"
    except Exception as stop_error:  # noqa: BLE001 - reported in the step's error line
        j.video = None
        return f" (its recording could not be stopped: {str(stop_error)[:160]})"


def film_not_started(j, name, reduce, switch, done, error):
    """The film's "not run" line when its recorder did not start (FilmNotStarted): its motion and its rebuild are
    skipped. The second such film of the journey ends it (NotRun)."""
    st = _state(j)
    st["not_started"] = st.get("not_started", 0) + 1
    if st["not_started"] >= FILMS_NOT_STARTED_MAX:
        raise D.NotRun(f"{error} ({st['not_started']} films of this journey did not start)")
    line = {"film": name, "status": "not run", "speed": None if reduce else st["speed"], "reduce": reduce,
            "reason": f"not run: the recorder did not start: {error}", "steps": done}
    if switch:
        line["switch"] = switch
    st["films"].append({k: line[k] for k in ("film", "status", "speed", "reduce", "reason", "switch") if k in line})
    return line


def film_bytes(j, name):
    """The movie's and the scan's size on the mini (None when missing): the round's fetch has to move them."""
    out = {}
    for key, suffix in (("movie", ".mov"), ("scan", ".mov.scan")):
        path = os.path.join(str(j.out), "video", name + suffix)
        out[key] = os.path.getsize(path) if os.path.isfile(path) else None
    return out


# debug.surfaces' content kind of a pane that shows an agent chat (PaneSurfaceStatus: TabContent.agent). Its content kind
# "conversation" is a native Home conversation view (TabContent.conversation). snapshot.get's tab kind is another
# name space: every chat tab, an agent chat too, is "conversation" there (CHAT_TAB_KIND).
AGENT_KIND = "agent"
# The row fields that say what a pane shows (a 300-character cut of the whole row stopped before "kind").
AGENT_FACTS = ("kind", "selected_tab", "shown_tab", "content_installed", "content_visible", "visible", "focused", "phase")


def agent_shown(row, tab):
    """The pane's report shows the chat tab TAB: selected, shown, an agent chat, its content installed in the pane."""
    return (row.get("kind") == AGENT_KIND and row.get("selected_tab") == tab and row.get("shown_tab") == tab
            and bool(row.get("content_installed")))


# snapshot.get's kind of an agent chat tab (ControlTopologyMapper: TabModel.kind .conversation), and the id prefix of the
# app's provisional stand-in for a tab the daemon does not have yet (ProvisionalTab.idPrefix): no action can name it.
CHAT_TAB_KIND = "conversation"
PROVISIONAL_TAB = "pending_tab_"


def _topology_pane(j, pane_key):
    """PANE_KEY in the app's control snapshot (snapshot.get): the snapshot action.run resolves its targets against."""
    topology = (j.app.rpc("snapshot.get") or {}).get("topology") or {}
    for workspace in topology.get("workspaces") or []:
        for screen in workspace.get("screens") or []:
            for pane in screen.get("panes") or []:
                if isinstance(pane, dict) and pane.get("id") == pane_key:
                    return pane
    return None


def _pane_tabs(pane):
    return [t for t in (pane or {}).get("tabs") or [] if isinstance(t, dict) and t.get("id")]


def listed_chat(pane, answered, before):
    """The chat tab the control snapshot lists in PANE, and where its id came from: the open's ANSWERED id once listed
    (never a provisional stand-in), else the one new chat tab (kind conversation, not among BEFORE). (None, None) until
    then."""
    real = [t for t in _pane_tabs(pane) if not str(t["id"]).startswith(PROVISIONAL_TAB)]
    if answered and any(t["id"] == answered for t in real):
        return answered, "answer"
    new = [t["id"] for t in real if t.get("kind") == CHAT_TAB_KIND and t["id"] not in before]
    return (new[0], "report") if len(new) == 1 else (None, None)


def step_px_agent(j, step):
    rec = W.named(j, step["pane"])
    pane_key, name = rec["pane"], step["pane"]
    timeout = float(step.get("timeout", 20))
    before = {t["id"] for t in _pane_tabs(_topology_pane(j, pane_key))}
    opened = j.app.rpc("action.run", {"action": "palette.newAgentChat", "target": f"pane:{pane_key}", "args": {}}) or {}
    answered = (opened.get("result") or {}).get("tab")
    t0 = D.now()
    # 1. The open answers its tab from the store before the control snapshot lists it, and action.run finds a `tab:`
    #    target only in that snapshot (sweep-b08cc6f 18:54Z: a tab.focus 0.01 s after the open was not_found). So the
    #    select waits until snapshot.get, the same snapshot, lists the pane's chat tab.
    tab, source, pane = None, None, None
    while True:
        pane = _topology_pane(j, pane_key)
        tab, source = listed_chat(pane, answered, before)
        if tab or D.now() >= t0 + timeout:
            break
        time.sleep(0.1)  # orchestration poll of the app's own report
    if not tab:
        tabs = [{k: t.get(k) for k in ("id", "kind")} for t in _pane_tabs(pane)]
        raise D.StepError(f"px_agent {name}: snapshot.get lists no chat tab in the pane within {timeout:.0f} s (the open "
                          f"answered tab {answered}; the pane {'lists ' + json.dumps(tabs) if pane else 'is not listed'}; "
                          f"palette.newAgentChat: {json.dumps(opened)[:300]})")
    listed_s = round(D.now() - t0, 3)
    # 2. In a pane a window shows, the targeted open adds the tab and leaves the selection alone
    #    (AgentChatPlacement.openTab(selects: shown == nil), #23085): select it as a person's `cmux tab <id> focus` does.
    selected = None
    if not agent_shown(_surface_row(j, pane_key) or {}, tab):
        try:
            selected = j.app.rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab}"})
        except D.StepError as error:
            raise D.StepError(f"px_agent {name}: tab.focus {tab} refused after snapshot.get listed it: {error}")
    # 3. The pane shows it: debug.surfaces reports the tab selected and shown, an agent chat. One budget for 1 to 3.
    while True:
        row = _surface_row(j, pane_key) or {}
        if agent_shown(row, tab):
            focus = j.app.cmux("pane", pane_key, "focus")
            return {"pane": pane_key, "kind": row.get("kind"), "tab": tab, "tab_source": source, "listed_s": listed_s,
                    "opened": opened, "selected": selected, "focus": focus}
        if D.now() >= t0 + timeout:
            break
        time.sleep(0.1)  # orchestration poll of the app's own report
    facts = {k: row.get(k) for k in AGENT_FACTS if k in row}
    raise D.StepError(f"px_agent {name}: the pane does not show its chat tab {tab} within {timeout:.0f} s "
                      f"(pane {json.dumps(facts)}; tab.focus: {json.dumps(selected)[:200]}; "
                      f"palette.newAgentChat: {json.dumps(opened)[:300]})")


TAB_STEP_TIMEOUT_S = 20.0
CLOSE_LEAD_S = 0.15  # the hold's first key-down this long after px_hold_tab_close starts it: room for its key threads
CLOSE_GONE_S = 5.0  # the closed tab leaves the control snapshot within this


def _tab_terminal(tab):
    term = tab.get("terminal")
    return term.get("id") if isinstance(term, dict) else term


def _real_tabs(pane):
    return [t for t in _pane_tabs(pane) if not str(t["id"]).startswith(PROVISIONAL_TAB)]


def step_px_tab_new(j, step):
    """A new terminal tab in the named pane, shown and adopted (see the module doc)."""
    name = step["pane"]
    rec = W.named(j, name)
    pane_key = rec["pane"]
    timeout = float(step.get("timeout", TAB_STEP_TIMEOUT_S))
    pane = _topology_pane(j, pane_key)
    tabs = _real_tabs(pane)
    if not tabs:
        raise D.StepError(f"px_tab_new {name}: snapshot.get lists no tab in pane {pane_key}")
    before = {t["id"] for t in tabs}
    beside = pane.get("selected_tab") if pane.get("selected_tab") in before else tabs[-1]["id"]
    # newSurface opens a terminal tab beside a tab (a pane target is refused); the run's own focus makes it a person's open.
    reply = j.app.rpc("action.run", {"action": "newSurface", "target": f"tab:{beside}", "focus": True})
    t0 = D.now()
    new = []
    while True:
        pane = _topology_pane(j, pane_key) or {}
        new = [t for t in _real_tabs(pane) if t["id"] not in before and t.get("kind") == "terminal" and _tab_terminal(t)]
        if len(new) == 1 or D.now() >= t0 + timeout:
            break
        time.sleep(0.1)  # orchestration poll of the app's own report
    if len(new) != 1:
        listed = [{k: t.get(k) for k in ("id", "kind")} for t in _pane_tabs(pane)]
        raise D.StepError(f"px_tab_new {name}: snapshot.get lists {len(new)} new terminal tab(s) in the pane within {timeout:.0f} s "
                          f"(the pane lists {json.dumps(listed)}; newSurface: {json.dumps(reply)[:200]})")
    tab, term = new[0]["id"], _tab_terminal(new[0])
    selected = None
    if pane.get("selected_tab") != tab:
        selected = j.app.rpc("action.run", {"action": "tab.focus", "target": f"tab:{tab}"})
    row = {}
    while True:
        row = _surface_row(j, pane_key) or {}
        if row.get("kind") == "terminal" and row.get("selected_tab") == tab and row.get("shown_tab") == tab:
            break
        if D.now() >= t0 + timeout:
            raise D.StepError(f"px_tab_new {name}: the pane does not show its new tab {tab} within {timeout:.0f} s "
                              f"(pane {json.dumps({k: row.get(k) for k in AGENT_FACTS if k in row})})")
        time.sleep(0.1)  # orchestration poll of the app's own report
    while not (j.app.screen(term).get("text") or "").strip():
        if D.now() >= t0 + timeout:
            raise D.StepError(f"px_tab_new {name}: terminal {term} of tab {tab} shows nothing within {timeout:.0f} s")
        time.sleep(0.1)  # orchestration poll of the daemon's screen
    host_pid = int(row["host_pid"]) if row.get("host_pid") else None
    j.pane, j.term, j.host_pid = pane_key, term, host_pid
    rec.update(term=term, host_pid=host_pid)
    return {"pane": pane_key, "tab": tab, "terminal": term, "tabs": [t["id"] for t in _real_tabs(_topology_pane(j, pane_key))],
            "selected": selected, "reply": reply}


def step_px_hold_tab_close(j, step):
    """The held key with a script's closeTab of the pane's middle tab AFTER_MS after its first key-down (module doc)."""
    close = step.get("close") or {}
    name = close.get("pane", "p0")
    rec = W.named(j, name)
    pane_key = rec["pane"]
    if close.get("which", "middle") != "middle":
        raise D.StepError(f"px_hold_tab_close: which is middle, not {close.get('which')!r}")
    tabs = [t["id"] for t in _real_tabs(_topology_pane(j, pane_key))]
    if len(tabs) < 3:
        raise D.StepError(f"px_hold_tab_close: pane {name} lists {len(tabs)} tab(s) in snapshot.get, not 3 or more: {tabs}")
    index = len(tabs) // 2
    tab = tabs[index]
    after = float(close.get("after_ms", 50)) / 1000.0
    waits = getattr(j, "before_keys", None)
    if waits:
        waits()  # a creation hold first, so the hold's own wait is none and the first key-down stays where it is set
    first_key = S.uptime() + CLOSE_LEAD_S
    sent = {}

    def send():
        wait = first_key + after - S.uptime()
        if wait > 0:
            time.sleep(wait)
        sent.update(t_sent_host=S.uptime(), t_sent=D.now())
        try:
            sent["reply"] = j.app.rpc("action.run", {"action": "closeTab", "target": f"tab:{tab}"})
        except Exception as error:  # the step reports it after the hold
            sent["error"] = str(error)[:300]
        sent.update(t_returned_host=S.uptime(), t_returned=D.now())

    closer = threading.Thread(target=send, name="px-tab-close", daemon=True)
    closer.start()
    hold = {k: step[k] for k in ("key", "modifiers", "seconds", "delay", "interval", "mark", "window") if k in step}
    held = j.step_rk_hold(dict(hold, start_at=first_key))
    closer.join(10)
    info = {"pane": pane_key, "label": name, "tab": tab, "index": index, "which": "middle", "tabs_before": tabs,
            "first_key_host": first_key, "planned_after_ms": round(after * 1000, 3),
            "clock": "host seconds (CLOCK_UPTIME_RAW): the trace's t0_s and the scan's frame times"}
    for key in ("t_sent_host", "t_returned_host", "reply", "error"):
        if key in sent:
            info[key] = sent[key]
    if "t_sent_host" in sent:
        info["after_ms"] = round((sent["t_sent_host"] - first_key) * 1000, 3)
    video = getattr(j, "video", None)
    if video is not None:
        video["notes"].setdefault("pixel", {})["tab_close"] = info
        if "t_sent" in sent:
            V._hid_log(j, "tab_close", {"pane": pane_key, "tab": tab, "index": index, "after_ms": info["planned_after_ms"]},
                       sent["t_sent"], sent["t_returned"], sent.get("reply") or {"error": sent.get("error")})
    if "t_sent_host" not in sent:
        raise D.StepError(f"px_hold_tab_close: the close of tab {tab} was not sent within 10 s of the hold's end")
    if "error" in sent:
        raise D.StepError(f"px_hold_tab_close: closeTab {tab} refused: {sent['error']}")
    timeout = float(step.get("timeout", CLOSE_GONE_S))
    end = D.now() + timeout
    while True:
        left = [t["id"] for t in _real_tabs(_topology_pane(j, pane_key))]
        if tab not in left:
            break
        if D.now() >= end:
            raise D.StepError(f"px_hold_tab_close: snapshot.get still lists the closed tab {tab} {timeout:.0f} s after the close: {left}")
        time.sleep(0.05)  # orchestration poll of the app's own report
    info["tabs_after"] = left
    return {"hold": held, "tab_close": info}


KEY_STEP = 0.05  # PaneResize.step: a key resize moves a column's width by 5% of the viewport
HIT_WIDTH_KEY = "metrics.dividerHitWidth"  # the divider drag area's width; only the hit bands read it (no pane frame)
KEY_DOWN_S = 0.025  # a CuaDriver key reaches the app 20-28 ms after its call starts (cmux22 sweeps)
DRAG_DOWN_S = 0.40  # a CuaDriver drag's mouse-down reaches the app 390-407 ms after its call starts (6 drags, cmux22 and
                    # cmux24, 2026-11-04; 260-400 ms on cmux22 on 2026-11-03): at 0.33 the x0.125 column press missed the edge
MOVING_PT = 0.25  # an edge moved this far in the 3 refreshes before the mouse-down is still moving (half a device px at 2x)
GRAB_SHARE = 0.5  # the dragged edge followed the pointer: it moved at least this share of the drag
# A drag shorter than STILL_DRAG_PT holds its edge still (the S2B clamp case: 1 pt, then held). Its own travel cannot tell a
# grab from a miss (a missed press leaves the edge sliding with its column), so the grab shows as the edge leaving the slide of
# the next divider on its axis by STILL_GRAB_PT or more between the mouse-down and the end of the drag.
STILL_DRAG_PT = 5.0
STILL_GRAB_PT = 3.0
# The press must land in the dragged divider's hit band as the trace has it at the mouse-down (half its width), plus this.
# The trace's divider rects are 7 pt wide even with metrics.dividerHitWidth 24 applied by debug.tunables, and a press 4.1 pt
# off a split missed it (ab-s2bdc-813ac15): the band that counts is the trace's, with no slack.
PRESS_SLACK_PT = 0.0


def spring_fraction(t, response, damping=1.0):
    """The share of its travel a spring of RESPONSE s has made t s after it starts (omega0 = 2 pi / response; critically
    damped, as the structural move token is: its damping is never under 1)."""
    if t <= 0:
        return 0.0
    if response <= 0:
        return 1.0
    w = 2 * math.pi / response
    return 1 - (1 + w * t) * math.exp(-w * t)


def _trace_now(j):
    """The trace so far (debug.motion trace_read with path: the app writes it off its main thread): {t0_s, samples}."""
    path = V._vdir(j) / ".trace-now.json"
    if path.exists():
        path.unlink()
    reply = V._motion(j, "trace_read", path=str(path))
    if isinstance(reply.get("samples"), list):
        return reply
    end = D.now() + 10
    while D.now() < end and not path.exists():
        time.sleep(0.02)  # orchestration wait for the app's file
    doc = json.loads(path.read_text()) if path.exists() else {"samples": []}
    if path.exists():
        path.unlink()
    return doc


def _dividers(sample):
    """{id: (center x, center y, w, h)} of one trace sample's divider rows (window points from the top-left)."""
    out = {}
    for d in sample.get("dividers") or []:
        if isinstance(d, list) and len(d) >= 5:
            out[str(d[0])] = (float(d[1]) + float(d[3]) / 2, float(d[2]) + float(d[4]) / 2, float(d[3]), float(d[4]))
    return out


def _ordered(dividers, window_w, vertical=True):
    """The ids of the shown vertical (sorted by x) or horizontal (sorted by y) dividers, as ext_video's targets count them."""
    rows = [(i, d) for i, d in dividers.items() if (d[3] > d[2]) == vertical and 8 <= d[0] <= window_w - 8]
    return [i for i, _ in sorted(rows, key=lambda r: r[1][0] if vertical else r[1][1])]


def _at(samples, t0, t):
    """The last sample shown at host time T (or the first)."""
    k = 0
    for n, smp in enumerate(samples):
        if t0 + float(smp.get("t", 0)) / 1000.0 <= t:
            k = n
        else:
            break
    return samples[k] if samples else {}


def _journal_times(j, since):
    """(the first key-down, the first left mouse-down) host times in the app's input journal at or after SINCE (s)."""
    key = mouse = None
    for e in _journal(j):
        t = float(e.get("uptimeNanos") or 0) / 1e9
        if t < since:
            continue
        kind = e.get("kind") or {}
        k = (kind.get("key") or {}).get("_0") if isinstance(kind.get("key"), dict) else None
        m = (kind.get("mouse") or {}).get("_0") if isinstance(kind.get("mouse"), dict) else None
        if key is None and isinstance(k, dict) and k.get("phase") == "down" and k.get("keyClass") != "modifier":
            key = t
        if mouse is None and isinstance(m, dict) and m.get("phase") == "down" and int(m.get("button") or 0) == 0:
            mouse = t
    return key, mouse


def _press_focus(j, mouse_down, window_s=0.1):
    """The pane the app focused by the mouse within WINDOW_S of MOUSE_DOWN (host s), or None. A press on a divider starts a
    drag and focuses no pane; a press that misses it lands in a pane, which takes the focus (journal kind focus, focusPane,
    source mouse): ab-s2bdc-813ac15, a press 4.1 pt off a split during its spring."""
    for e in _journal(j):
        t = float(e.get("uptimeNanos") or 0) / 1e9
        if not mouse_down - 0.002 <= t <= mouse_down + window_s:
            continue
        focus = (e.get("kind") or {}).get("focus")
        body = focus.get("_0") if isinstance(focus, dict) else None
        pane = body.get("focusPane") if isinstance(body, dict) else None
        if isinstance(pane, dict) and pane.get("source") == "mouse":
            return pane.get("_0") or "a pane"
    return None


def _journal(j, last=200):
    """The app's input journal's last LAST entries, in their order (a key press writes about 6, a 400 ms drag a few)."""
    reply = j.app.rpc("debug.journal", {"last": last}) or {}
    return sorted((e for e in reply.get("entries") or [] if isinstance(e, dict)), key=lambda e: int(e.get("seq") or 0))


def _hit_width(st):
    rec = (st.get("tunables") or {}).get(HIT_WIDTH_KEY) or {}
    return {"key": HIT_WIDTH_KEY, "pt": rec.get("value"), "default_pt": rec.get("default"), "applied": bool(rec.get("applied")),
            "frames": "none: only the divider hit bands read it"}


def _cell_widths(j, names):
    """The cells (window points) of the named fixture panes in debug.pane_chrome: {name: width} (None when not shown)."""
    chrome = j.app.rpc("debug.pane_chrome") or {}
    ids = {name: W.named(j, name)["pane"] for name in names}
    out = {name: None for name in names}
    for w in chrome.get("windows") or []:
        for p in w.get("panes") or []:
            for name, pid in ids.items():
                if p.get("pane") == pid and p.get("cell"):
                    out[name] = float(p["cell"][2])
    return out


def step_px_equalize(j, step):
    """Equalize Splits (action equalizeSplits) before a film, and wait until the named panes ({panes: [a, b]}) have equal
    widths (1 pt). An action.run timeout whose work finished (the app answered after the layout changed, or the layout
    was already equal) does not fail the film: it is recorded as `action_timeout` (a product finding to report: on feat
    8dea72b7d62f action.run equalizeSplits timed out at 1999 ms with its work done at 7 ms; on 84ffac38f96 it answered in
    5-16 ms). Widths still unequal after `timeout` s fail the step."""
    names = list(step.get("panes") or ["p0", "p1"])
    out = {"action": "equalizeSplits"}
    try:
        out["reply"] = j.app.rpc("action.run", {"action": "equalizeSplits", "args": {}, "focus": True})
    except D.StepError as error:
        text = str(error)
        if "timeout" not in text:
            raise
        out["action_timeout"] = text[:600]
    end = D.now() + float(step.get("timeout", 3.0))
    while True:
        widths = _cell_widths(j, names)
        vals = [v for v in widths.values() if v is not None]
        if len(vals) == len(names) and max(vals) - min(vals) <= 1.0:
            out["widths"] = widths
            return out
        if D.now() > end:
            raise D.StepError(f"px_equalize: {names} not equal after {step.get('timeout', 3.0)} s: {widths} ({out.get('action_timeout', 'action ran')})")
        time.sleep(0.05)  # orchestration: the layout spring lands; nothing to wait on but the widths


def step_px_key_then_drag(j, step):
    """One real HID key, then a real HID drag whose call starts AFTER_MS after the key-down (see the module doc)."""
    st = _state(j)
    drag = dict(step["drag"])
    target, by = dict(drag["target"]), [float(v) for v in drag["by"]]
    share = float(drag.get("share", 1.0))
    # less_pt: points the dragged divider's own spring travels short of SHARE x the key's step (the S2B clamp case: b1 starts
    # CLAMP_ROOM_PT above its minimum, so the split travels the step less that room: 59 of 65 pt; ab-s2bdc-813ac15 missed by 4.1).
    less = float(drag.get("less_pt", 0.0))
    after = float(step.get("after_ms", 60)) / 1000.0
    spring = (st.get("springs") or {}).get("move") or step.get("spring_default") or {"response": 0.15, "damping": 1.0}
    response = 0.0 if st.get("reduce") else float(spring["response"])
    offset = V._host_offset_s()
    # Before the key: where the dividers rest, and the viewport the key's step is a share of.
    trace = _trace_now(j)
    samples, t0 = trace.get("samples") or [], float(trace.get("t0_s") or 0)
    rest = _dividers(samples[-1]) if samples else {}
    window_w = float(((samples[-1] if samples else {}).get("window") or [1e9])[0])
    vertical = _ordered(rest, window_w, True)
    horizontal = _ordered(rest, window_w, False)
    chrome = j.app.rpc("debug.pane_chrome") or {}
    main = next((w.get("main_pane") for w in chrome.get("windows") or [] if w.get("main_pane")), None)
    step_pt = round(KEY_STEP * float(main[2]) * 2) / 2 if main else 0.0
    if not vertical:
        raise D.StepError(f"px_key_then_drag: the trace shows no vertical divider: {sorted(rest)}")
    spring_edge = vertical[0]  # the column edge right of p0: the key's spring moves it and every edge right of it
    if "divider" in target:
        ids, axis = vertical, "x"
    elif "row_divider" in target:
        ids, axis = horizontal, "y"
    else:
        raise D.StepError(f"px_key_then_drag: target {target}: divider or row_divider")
    index = int(target.get("divider", target.get("row_divider", 0)))
    if index >= len(ids):
        raise D.StepError(f"px_key_then_drag: no {'vertical' if axis == 'x' else 'horizontal'} divider {index}: {sorted(rest)}")
    dragged = ids[index]
    cx, cy, w, h = rest[dragged]
    # Where the drag's mouse-down will find the edge: the key's spring moves every divider right of p0 by its step.
    expect = after + DRAG_DOWN_S
    moved = (share * step_pt - less) * (spring_fraction(expect, response) if response else 1.0)
    press = [cx + moved, cy]  # SHARE of the key's step: 1 for the key's own edge, 0 for an edge past the traded columns
    info = {"key": {"key": step["key"], "modifiers": list(step.get("modifiers", []))},
            "drag": {"target": target, "by": by, "duration_ms": int(drag["duration_ms"]), "divider": dragged,
                     "rest": [cx, cy], "press": press, "share": share, "less_pt": less},
            "spring_edge": spring_edge, "spring_edge_rest": rest[spring_edge][0], "key_step_pt": step_pt,
            "spring": {"response": response, "damping": float(spring.get("damping", 1.0))},
            "planned": {"after_ms": round(after * 1000, 3), "mouse_down_after_key_ms": round(expect * 1000, 3),
                        "moved_pt": round(moved, 3)},
            # The press tolerance the verdict depends on: the case's hit width as the app read it back (px_tunable).
            "hit_width": _hit_width(st),
            "clock": "host seconds (CLOCK_UPTIME_RAW): the trace's t0_s, the scan's frame times and the journal's uptimeNanos"}
    video = getattr(j, "video", None)
    if video is not None:
        video["notes"].setdefault("pixel", {})["key_then_drag"] = info
    # The input guard before the key, for the drag's press point too: the drag's call must follow the key-down AFTER_MS later.
    V.R.require_input_clear(j, press)
    key_sent = D.now()
    j.step_rk_press({"key": step["key"], "modifiers": list(step.get("modifiers", [])), "count": 1, "gap_ms": 0,
                     "mark": step.get("mark", "kd") + "-key"})
    # One CuaDriver session serves one call at a time: the drag starts once the key's call returned, AFTER after the key-down.
    wait = key_sent + KEY_DOWN_S + after - D.now()
    if wait > 0:
        time.sleep(wait)
    drag_sent = D.now()
    info.update(key_sent_host=key_sent + offset, drag_sent_host=drag_sent + offset)
    j.step_hid_drag({"target": {"window_point": press}, "by": by, "duration_ms": int(drag["duration_ms"]), "hold_ms": 0,
                     "mark": step.get("mark", "kd") + "-drag", "cover_checked": True})
    info["drag_returned_host"] = D.now() + offset
    # The verdict: the journal's key-down and mouse-down, and the trace around them.
    key_down, mouse_down = _journal_times(j, key_sent + offset - 0.05)
    info.update(key_down_host=key_down, mouse_down_host=mouse_down)
    trace = _trace_now(j)
    samples, t0 = trace.get("samples") or [], float(trace.get("t0_s") or 0)
    period = float(trace.get("refresh_ms") or 8.333) / 1000.0
    verdict = None
    if key_down is None or mouse_down is None:
        verdict = f"no {'key-down' if key_down is None else 'mouse-down'} of this step in the app's input journal"
    else:
        info["mouse_down_after_key_ms"] = round((mouse_down - key_down) * 1000, 3)
        at = _dividers(_at(samples, t0, mouse_down))
        before = _dividers(_at(samples, t0, mouse_down - 3 * period))
        edge_at, edge_before = (at.get(spring_edge) or (None,))[0], (before.get(spring_edge) or (None,))[0]
        landing = info["spring_edge_rest"] + step_pt
        info["spring_edge_at_down"] = edge_at
        info["spring_left_pt"] = None if edge_at is None else round(landing - edge_at, 3)
        info["edge_moving_at_down"] = edge_at is not None and edge_before is not None and abs(edge_at - edge_before) >= MOVING_PT
        shown = at.get(dragged)
        info["dragged_at_down"] = list(shown[:2]) if shown else None
        end = _dividers(samples[-1]) if samples else {}
        travel = None
        if shown and dragged in end:
            k = 0 if axis == "x" else 1
            travel = end[dragged][k] - shown[k]
        want = by[0] if axis == "x" else by[1]
        info["dragged_travel_pt"] = None if travel is None else round(travel, 3)
        # The press against the dragged divider's hit band at the mouse-down (the trace's frame there): a press outside it
        # missed, whatever the divider does after (a missed press beside a springing edge shows the same end state).
        if shown:
            k = 0 if axis == "x" else 1
            half = (shown[2] if axis == "x" else shown[3]) / 2.0
            info["press_off_pt"] = round(press[k] - shown[k], 3)
            info["press_band_pt"] = round(half, 3)
            info["press_in_band"] = abs(press[k] - shown[k]) <= half + PRESS_SLACK_PT
        focused = _press_focus(j, mouse_down)
        info["press_focused_pane"] = focused
        if focused:
            # The app's own answer: the press went into a pane, not to the divider.
            info["grabbed"] = False
        elif abs(want) < STILL_DRAG_PT:
            # A still drag: its own travel cannot tell a grab (the edge may spring on either way), only the press point can.
            k = 0 if axis == "x" else 1
            nxt = ids[index + 1] if index + 1 < len(ids) else None
            shown_next = at.get(nxt) if nxt else None
            travel_next = end[nxt][k] - shown_next[k] if shown_next and nxt in end else None
            info["still_drag"] = {"next_divider": nxt, "next_travel_pt": None if travel_next is None else round(travel_next, 3),
                                  "rule": "the press in the divider's hit band at the mouse-down"}
            info["grabbed"] = bool(info.get("press_in_band"))
        else:
            info["grabbed"] = travel is not None and want != 0 and travel / want >= GRAB_SHARE
        if not info["grabbed"] and focused:
            verdict = (f"the press missed the edge: it focused pane {focused} (journal focus, source mouse) at the mouse-down; "
                       f"pressed at {press}, {dragged} at {info['dragged_at_down']}")
        elif not info["grabbed"]:
            verdict = (f"the press missed the edge: {dragged} moved {travel} pt of the drag's {want} pt (pressed at {press}, "
                       f"the edge at the mouse-down {info['dragged_at_down']}"
                   + (f"; a still drag: the press was {info.get('press_off_pt')} pt from the divider, its band +-{info.get('press_band_pt')} pt"
                      if "still_drag" in info else "")
                   + ")")
        elif not info["edge_moving_at_down"]:
            verdict = (f"no overlap: the key's spring edge {spring_edge} was not moving at the drag's mouse-down "
                       f"({info['mouse_down_after_key_ms']} ms after the key-down)")
    info["verdict"] = "overlap" if verdict is None else ("no overlap" if verdict.startswith("no overlap") else "not run")
    if verdict:
        info["reason"] = verdict
        st["film_not_run"] = f"not run: {verdict}"
    return {"key_then_drag": info}


def step_px_window_frame(j, step):
    ms = float(step.get("ms", 600))
    events = max(2, int(round(ms / 1000.0 * 120)))
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    sent = D.now()
    out = W.step_window_drag(j, {"edge": "bottom-right", "by": list(step["by"]), "events": events, "hz": 120})
    returned = D.now()
    V._hid_log(j, "window_drag", {"by": list(step["by"]), "events": events, "path": "debug.mouse (AppKit live resize)"}, sent, returned,
               {k: out.get(k) for k in ("frame_before", "frame_after", "dragged")})
    return out


STEPS = {"px_switch": step_px_switch, "px_agent": step_px_agent, "px_window_frame": step_px_window_frame, "px_film": step_px_film, "px_springs": step_px_springs, "px_tunable": step_px_tunable, "px_page": step_px_page,
         "px_agent_css": step_px_agent_css, "px_record_start": step_px_record_start, "px_tab_new": step_px_tab_new,
         "px_equalize": step_px_equalize,
         "px_hold_tab_close": step_px_hold_tab_close,
         "px_key_then_drag": step_px_key_then_drag}
CONDITIONS = {}


if __name__ == "__main__":
    print(json.dumps(sorted(STEPS)))
