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
  px_film      {name, speed: S | reduce: true, steps: [...], after?: [...]}
               One film at one speed: sets the speed (as px_springs), then plays STEPS (the set-up of the film,
               px_record_start, the input, video_stop) and AFTER (the rebuild of a closed pane) through the driver's own
               step handlers. When the speed cannot be set it plays nothing and returns {film, status: "not run", reason}.
  px_springs   {speed: S} | {reduce: true} | {reset: true}
               The speed alone: every `motion.spring.<token>` of SPRING_TOKENS gets its default response divided by S
               (0.25: x4 slower; 4: x4 faster) and its default damping, read back; `debug.motion speed fast` first (time
               scale 1, in memory). reduce: `debug.motion reduce true` (the springs at their defaults). Not run when S
               needs the store and it is inactive. reset: springs reset (when the store is active) and `debug.motion reduce
               null` (the system setting again): the case's `finally`. Overrides persist in debug-tunables.json until reset.
  px_tunable   {key, value}  one `debug.tunables set` (value null resets it), read back; `applied` false when the value
               did not take (store inactive): recorded, never a failure; the note says what the app kept
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
"""
import json
import os
import time
import urllib.parse

D = None
V = None  # ext_video: video_start, the recording
W = None  # ext_window: named panes

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


def install(driver):
    global D, V, W
    D = driver
    import ext_video
    import ext_window
    V, W = ext_video, ext_window


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
    started = V.step_video_start(j, dict(step, rows=rows, columns=cols))
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
            "page_backdrop": backdrop, "tunables": st["tunables"], "pages": getattr(j, "px_pages", {}),
            "frame": [width, height], "window_frame": win_frame, "screen_frame": screen_frame,
            "lines": {"rows": rows, "columns": cols, "strip_rows": strip_rows, "dropped": dropped, "scan_bytes_planned": used},
            "panes": {keys[name]: {"kind": "page" if info.get("kind") == "agent" else info.get("kind"), "agent": info.get("kind") == "agent",
                                   "fill": info.get("fill"), "label": name} for name, info in fixture.items()},
            "chrome": [{k: p.get(k) for k in ("pane", "cell", "border", "first_cell", "strip", "pill", "strip_hidden")}
                       for p in window.get("panes") or []]}
    if getattr(j, "video", None) is not None:
        j.video["notes"]["pixel"] = note
    return dict(started, rows=rows, columns=cols, strip_rows=strip_rows, dropped_lines=dropped,
                fixture={keys[n]: n for n in fixture}, spring=spring, page_backdrop=backdrop)


def _short(value):
    text = json.dumps(value, default=str)
    return value if len(text) <= RESULT_CHARS else text[:RESULT_CHARS] + "..."


def step_px_film(j, step):
    name = step["name"]
    reduce = bool(step.get("reduce"))
    applied, facts = apply_speed(j, None if reduce else step.get("speed"), reduce)
    st = _state(j)
    if not applied:
        line = {"film": name, "status": "not run", "reason": facts["reason"], "speed": facts.get("speed")}
        st["films"].append(line)
        return line
    done = []
    for sub in list(step.get("steps") or []) + list(step.get("after") or []):
        handler = getattr(j, "step_" + str(sub.get("do")), None)
        if handler is None:
            raise D.StepError(f"px_film {name}: unknown step {sub.get('do')!r}")
        t = D.now()
        try:
            out = handler(sub)
        except D.StepError as error:
            raise D.StepError(f"px_film {name}: {sub['do']} ({sub.get('title', '')[:60]}): {error}")
        done.append({"do": sub["do"], "title": sub.get("title", ""), "seconds": round(D.now() - t, 3), "result": _short(out)})
    line = {"film": name, "status": "recorded", "speed": None if reduce else st["speed"], "reduce": reduce,
            "springs_source": st["springs_source"], "speed_facts": facts, "steps": done}
    st["films"].append({k: line[k] for k in ("film", "status", "speed", "reduce", "springs_source")})
    return line


STEPS = {"px_film": step_px_film, "px_springs": step_px_springs, "px_tunable": step_px_tunable, "px_page": step_px_page,
         "px_agent_css": step_px_agent_css, "px_record_start": step_px_record_start}
CONDITIONS = {}


if __name__ == "__main__":
    print(json.dumps(sorted(STEPS)))
