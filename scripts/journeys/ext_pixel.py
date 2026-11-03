"""PIXEL PERFECT steps (group pixel-perfect; Lawrence 2026-11-03: "resizing columns/splits is still not pixel perfect
animated ... record + rewatch videos at every single animation speed ... browser tabs + TUI in terminal, with like
multiple pixel border ... with different terminal/app shell background color"). The cases are video-cases/gen_pixel.py,
the fixtures pixel/tui_border.py and pixel/page.html, the judge video-cases/judge_pixel.py.

driver.py loads this file (load_extensions) on the mini, under /usr/bin/python3 (3.9, standard library only).

Steps (`do`):
  px_springs   {speed: S} | {reduce: true} | {reset: true}
               The animation speed of the case, through the app's own Debug tunables (`debug.tunables`, DEBUG and bench
               builds; refused as not run when the tunable store is not active): every `motion.spring.<token>` of
               SPRING_TOKENS gets its default response divided by S (0.25: x4 slower; 4: x4 faster) and its default
               damping, read back after the set. `debug.motion speed fast` first (time scale 1, in memory), so the scale
               is the only factor. reduce: `debug.motion reduce true` (Reduce Motion on, in memory; the springs keep
               their defaults). reset: `debug.tunables reset section springs` and `debug.motion reduce null` (the system
               setting again): the case's `finally`. The overrides persist in debug-tunables.json until reset.
  px_tunable   {key, value}  one `debug.tunables set` (value null resets it), read back; e.g. browserResize.pageBackdrop
  px_page      {pane, bg, label?, x?, y?, z?, timeout?}
               Opens page.html (/tmp/jr-pixel-page.html, a `file` step wrote it) in a new browser tab of the named
               pane: `cmux pane <id> focus`, then `action.run openBrowser {url: file:///tmp/jr-pixel-page.html?bg=..,
               engine: cef}` (the action the person's Cmd-Shift-L runs); waits until debug.surfaces shows the pane's
               selected tab on that url and `browser.page.eval` reads the page's own report (innerWidth, innerHeight,
               devicePixelRatio, its rAF counter running). Navigates the tab (`browser.page.navigate`) when the action
               opened another page.
  px_agent_css {fill?, remove?}
               Writes agent-pane/theme.css beside the slot's settings file (CMUX_NEXT_CONFIG_FILE: the agent pane
               watches and injects it): a loud page background and a fixed overlay with 1, 2 and 3 px rings in the
               fixture's ring colors, so an agent pane is judged as a page is. remove: deletes it (the case's finally).
  px_record_start {name, seconds, require_hz?, fixture: {NAME: {kind: tui|page|agent, fill: "#RRGGBB"}}, spring?: TOKEN,
               input?: TEXT, lines_per_pane?: [fractions]}
               ext_video's video_start with scan lines that cross every pane border: for each pane of the window
               (debug.pane_chrome: its content border, window points), a row at each fraction of its height and a
               column at each fraction of its width (default 0.3 and 0.7: clear of the TUI's ruler and centre text and
               of the page's ruler), in device px, as many as the recorder's 256 MB scan budget holds for the film
               (each complete frame keeps every row and column). Then writes the judge's note into the recording's
               meta notes (`pixel`): the scale, the colors, each fixture pane's app pane id, kind, fill and name, the
               speed or Reduce Motion, the declared spring of the input (TOKEN's response after the scale and its
               damping as the app applies it: structural tokens never under 1), the input kind and the lines.
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
ROLES = {"shell": "#FF00FF", "theme": "#00FFFF", "ring1": "#FF0000", "ring2": "#FFFFFF", "ring3": "#000000"}
PAGE_PATH = "/tmp/jr-pixel-page.html"
SCAN_BUDGET = 230 << 20  # the recorder keeps at most 256 MB of scan lines (MotionScreenRecord.maxScanBytes)
FILM_HZ = 120


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
        j.px = {"speed": 1.0, "reduce": False, "springs": {}, "tunables": {}}
    return j.px


def step_px_springs(j, step):
    st = _state(j)
    if step.get("reset"):
        out = {"springs": _tunables(j, action="reset", section="springs"), "reduce": j.app.rpc("debug.motion", {"action": "reduce", "value": None})}
        st.update(speed=1.0, reduce=False, springs={})
        return out
    state = _tunables(j, action="state")
    if not state.get("active"):
        raise D.NotRun(f"debug.tunables: the tunable store is not active in this build (overrides do nothing): {json.dumps(state)[:300]}")
    j.app.rpc("debug.motion", {"action": "speed", "value": "fast"})
    if step.get("reduce"):
        _tunables(j, action="reset", section="springs")
        reply = j.app.rpc("debug.motion", {"action": "reduce", "value": True}) or {}
        st.update(speed=1.0, reduce=True, springs={})
        return {"reduce": True, "motion": {k: reply.get(k) for k in ("reduce_motion", "speed", "pane_animations") if k in reply}}
    speed = float(step["speed"])
    if not 0.05 <= speed <= 20:
        raise D.StepError(f"px_springs: speed {speed} is out of range")
    j.app.rpc("debug.motion", {"action": "reduce", "value": False})
    springs = {}
    for token in SPRING_TOKENS:
        key = f"motion.spring.{token}"
        row = _tunables(j, action="get", key=key)
        base = _spring_value(row.get("default"))
        if base is None:
            raise D.StepError(f"px_springs: {key} has no spring default: {json.dumps(row)[:200]}")
        want = {"response": round(base["response"] / speed, 6), "dampingFraction": base["dampingFraction"]}
        got = _spring_value(_tunables(j, action="set", key=key, value=want).get("value")) or {}
        if abs(got.get("response", -1) - want["response"]) > 1e-6 or abs(got.get("dampingFraction", -1) - want["dampingFraction"]) > 1e-9:
            raise D.StepError(f"px_springs: {key} reads back {got}, not {want} (the tunable clamps response 0.02..2 s)")
        damping = max(base["dampingFraction"], 1.0) if token in STRUCTURAL else base["dampingFraction"]
        springs[token] = {"response": want["response"], "damping": damping, "default_response": base["response"],
                          "default_damping": base["dampingFraction"]}
    st.update(speed=speed, reduce=False, springs=springs)
    return {"speed": speed, "keys": [f"motion.spring.{t}" for t in SPRING_TOKENS],
            "move": springs.get("move"), "split": springs.get("split"), "scroll": springs.get("scroll")}


def step_px_tunable(j, step):
    key = step["key"]
    row = _tunables(j, action="set", key=key, value=step.get("value"))
    _state(j)["tunables"][key] = row.get("value")
    return {"key": key, "value": row.get("value"), "default": row.get("default"), "changed": row.get("changed")}


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
    # `focus` (the run's and the argument): a script's tab opens selected, not in the background of the focused pane.
    opened = j.app.rpc("action.run", {"action": "openBrowser", "args": {"url": url, "engine": "cef", "focus": True}, "focus": True})
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


def _frame_size(j, scale):
    """The recorder's frame (device px): from the main window's top-left to its screen's right and bottom edges."""
    report = j.app.rpc("debug.layers") or {}
    for w in report.get("windows") or []:
        if isinstance(w, dict) and w.get("frame") and w.get("screen_frame"):
            wx, wy, ww, wh = (float(v) for v in w["frame"])
            sx, sy, sw, sh = (float(v) for v in w["screen_frame"])
            left, top = max(0.0, wx - sx), max(0.0, (sy + sh) - (wy + wh))
            width = int(round(max(ww, sw - left) * scale)) // 2 * 2
            height = int(round(max(wh, sh - top) * scale)) // 2 * 2
            return width, height
    raise D.StepError("px_record_start: debug.layers has no main window frame")


def scan_lines(panes, scale, width, height, seconds, fractions=(0.3, 0.7), budget=SCAN_BUDGET, hz=FILM_HZ):
    """Rows and columns (device px) that cross every pane: for each pane rect [x, y, w, h] (window points), a row at each
    fraction of its height and a column at each fraction of its width, in that priority (every pane's first fraction
    first), deduplicated within 6 px, as many as `budget` bytes of scan hold for `seconds` of film at `hz`."""
    frames = int(hz * (float(seconds) + 1.5))
    per_line = {"row": 4 * width, "col": 4 * height}
    wanted = []
    for frac in fractions:
        for x, y, w, h in panes:
            wanted.append(("row", int(round((y + h * frac) * scale))))
            wanted.append(("col", int(round((x + w * frac) * scale))))
    rows, cols, dropped, used = [], [], 0, 8 * frames
    for axis, v in wanted:
        limit = height if axis == "row" else width
        if not 0 <= v < limit:
            continue
        have = rows if axis == "row" else cols
        if any(abs(v - o) < 6 for o in have):
            continue
        cost = per_line[axis] * frames
        if used + cost > budget:
            dropped += 1
            continue
        have.append(v)
        used += cost
    return sorted(rows), sorted(cols), dropped, used


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
    width, height = _frame_size(j, scale)
    rects = [p.get("border") or p.get("cell") for p in window.get("panes") or [] if (p.get("border") or p.get("cell"))]
    rows, cols, dropped, used = scan_lines(rects, scale, width, height, float(step.get("seconds", 20)),
                                           tuple(step.get("lines_per_pane") or (0.3, 0.7)))
    started = V.step_video_start(j, dict(step, rows=rows, columns=cols))
    token = step.get("spring")
    spring = None
    if token and not st["reduce"]:
        sp = st["springs"].get(token)
        if sp is None:
            # No override set (px_springs not run): the token's default as the app applies it.
            row = _tunables(j, action="get", key=f"motion.spring.{token}")
            base = _spring_value(row.get("value")) or _spring_value(row.get("default")) or {}
            if base:
                damping = max(base["dampingFraction"], 1.0) if token in STRUCTURAL else base["dampingFraction"]
                sp = {"response": base["response"], "damping": damping}
        if sp:
            spring = {"token": token, "response": sp["response"], "damping": sp["damping"]}
    note = {"scale": scale, "roles": dict(ROLES), "speed": st["speed"], "reduce": st["reduce"], "spring": spring,
            "input": step.get("input"), "frame": [width, height], "lines": {"rows": rows, "columns": cols, "dropped": dropped,
                                                                             "scan_bytes_planned": used},
            "tunables": st["tunables"], "pages": getattr(j, "px_pages", {}),
            "panes": {keys[name]: {"kind": "page" if info.get("kind") == "agent" else info.get("kind"), "agent": info.get("kind") == "agent",
                                   "fill": info.get("fill"), "label": name} for name, info in fixture.items()},
            "chrome": [{k: p.get(k) for k in ("pane", "cell", "border", "first_cell", "strip")} for p in window.get("panes") or []]}
    if getattr(j, "video", None) is not None:
        j.video["notes"]["pixel"] = note
    return dict(started, rows=rows, columns=cols, dropped_lines=dropped, fixture={keys[n]: n for n in fixture}, spring=spring)


STEPS = {"px_springs": step_px_springs, "px_tunable": step_px_tunable, "px_page": step_px_page, "px_agent_css": step_px_agent_css,
         "px_record_start": step_px_record_start}
CONDITIONS = {}


if __name__ == "__main__":
    print(json.dumps(sorted(STEPS)))
