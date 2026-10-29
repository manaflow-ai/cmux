"""Zoom transition steps and conditions for the journeys (felt 1d, journeys/p0/zoom-transition.json).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

Lawrence 2026-10-29 on v2.2.7-opt: "animations for cmd shift enter need to be better", "make sure cmd shift enter
animation is perfect (all the tabs are perfectly visible)". His clip: the zoomed pane gets an opaque dark layer
that wipes in, the browser pane vanishes at once and pops back at its final frame at the start of the unzoom, over
the zoom, and the unzoom ends in a second step. The rule (handoff/motion-cascade.md): one intent, one geometric
transition of the real pane content, the same material as a pane at rest, at most about 150 ms each way, nothing
popping ahead of or behind it; a held or spammed key ends in the last press's state with no runoff.

Steps (`do`):
  zoom_layout   {url?}        from the journey's terminal pane (the left pane): Cmd-D, Cmd-Shift-D, a browser tab
                              (`openBrowser.chromium`, URL) in the right-bottom pane, then Cmd-Opt-Up and a New Tab
                              page (`newTab.page`) in the right-top pane: terminal, Home and browser, as in the clip.
                              Waits until the window shows the three panes; keeps their ids by kind.
  zoom_round    {pane: home|terminal|browser, as, hold?: S, wait?: S}
                              focuses PANE (Cmd-Opt-arrows), starts `debug.motion trace_start` on the main window,
                              presses Cmd-Shift-Return, waits WAIT (0.8 s), presses it again, waits, stops the trace.
                              Keeps every display frame's pane frames, stacking, content size, header share, zoom
                              owner, pane backing (`backing`, when the build reports it) and the Chromium page rows
                              as AS; also written whole to diag-AS.json.
  zoom_spam     {pane, presses?: N, interval?: S, as}
                              N presses (default 7) INTERVAL apart (default 0.045 s) inside one trace, then 1 s.

Conditions (inside `expect.all`; evidence kind app):
  zoom_transition {of: AS, max_ms?: 150}
      For each press of the round: every frame change belongs to ONE transition (changes at most 2 frames apart),
      it lasts at most MAX_MS (+ one frame), the zooming pane passes through in-between frames (no pop), its content
      is laid out at its frame in every frame (live, never held at another size), its header shows whole, no pane
      appears, vanishes or changes stacking inside the transition, the Chromium page is on screen whenever its pane
      is not wholly covered, no page window draws over the zooming pane, and the zooming pane has the backing of a
      pane at rest (no opaque layer: the `backing` rows, or, on a build without them, the zoom owner, which is the
      backsZoom fill of PaneHostView there).
  zoom_settles  {of: AS}      after the last press: the state that press asked for, and no frame change later than
                              one transition after it (no queued runoff).
"""
import json
import time

D = None  # the driver module (install)
CMD_SHIFT_RETURN = ("return", ["cmd", "shift"])
# The core tour's page (scripts/cmux-next/media/tours/core.json): cmux opens http(s) pages only.
DATA_URL = "https://example.com"


def install(driver):
    global D
    D = driver


def _rows(j):
    report = j.app.rpc("debug.surfaces") or {}
    out = []
    for w in report.get("windows") or []:
        for p in w.get("panes") or []:
            if isinstance(p, dict):
                out.append(dict(p, window_number=w.get("window")))
    return out


def _kind(row):
    if row.get("url"):
        return "browser"
    if row.get("attach") is not None or row.get("grid") is not None:
        return "terminal"
    return "home"


def _focus_arrow(j, arrow):
    j.key(arrow, ["cmd", "option"])
    time.sleep(0.35)


def step_zoom_layout(j, step):
    j.need_pane()
    before = {r.get("pane") for r in _rows(j)}
    j.key("d", ["cmd"])
    time.sleep(D.CREATION_HOLD_SECONDS)
    j.key("d", ["cmd", "shift"])
    time.sleep(D.CREATION_HOLD_SECONDS)
    browser = j.app.rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": j.sub(step.get("url") or DATA_URL)},
                                       "focus": True})
    time.sleep(2.0)
    _focus_arrow(j, "up")
    page = j.app.rpc("action.run", {"action": "newTab.page", "args": {}, "focus": True})
    end = D.now() + float(step.get("timeout", 30))
    kinds = {}
    while D.now() < end:
        # The panes this step made, and the journey's terminal; not a pane the workspace had before (its own Home).
        rows = [r for r in _rows(j) if r.get("workspace") == _workspace(j)
                and (r.get("pane") == j.pane or r.get("pane") not in before)]
        kinds = {}
        for r in rows:
            kinds.setdefault(_kind(r), r.get("pane"))
        if len(rows) >= 3 and {"terminal", "home", "browser"} <= set(kinds):
            break
        time.sleep(0.3)
    else:
        raise D.StepError(f"zoom_layout: the window does not show terminal, Home and browser panes: {kinds} "
                          f"(browser reply {json.dumps(browser)[:200]}, newTab.page reply {json.dumps(page)[:200]})")
    j.zoom_panes = kinds
    time.sleep(1.5)  # the page paints, the New Tab page settles
    return {"panes": kinds, "before": sorted(p for p in before if p)}


def _workspace(j):
    row = next((r for r in _rows(j) if r.get("pane") == j.pane), None)
    return (row or {}).get("workspace")


def _focus(j, which):
    """Moves the focus to the pane of kind WHICH with Cmd-Opt-arrows (the layout is fixed: terminal left, Home
    right-top, browser right-bottom)."""
    target = j.zoom_panes[which]
    for _ in range(4):
        focused = next((r.get("pane") for r in _rows(j) if r.get("focused") and r.get("workspace") == _workspace(j)), None)
        if focused == target:
            return target
        here = next((k for k, v in j.zoom_panes.items() if v == focused), None)
        path = {("terminal", "home"): ["right"], ("terminal", "browser"): ["right", "down"],
                ("home", "terminal"): ["left"], ("home", "browser"): ["down"],
                ("browser", "home"): ["up"], ("browser", "terminal"): ["left"]}.get((here, which), ["left"])
        for arrow in path:
            _focus_arrow(j, arrow)
    raise D.StepError(f"could not focus the {which} pane {target}")


def _pages_of(layers):
    """The Chromium pages debug.layers lists: [{pane, presentation, page_window_layer_hosts, ...}]."""
    out = []
    def walk(v):
        if isinstance(v, dict):
            if "presentation" in v and "pane" in v:
                out.append(v)
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    walk(layers or {})
    return out


def _trace(j, presses, as_name):
    extra = _pages_of(j.app.rpc("debug.layers") or {})
    j.app.rpc("debug.motion", {"action": "trace_start", "window": 0})
    t0 = D.now()
    time.sleep(0.25)
    marks = []
    for gap in presses:
        marks.append(round((D.now() - t0) * 1000, 1))
        j.key(*CMD_SHIFT_RETURN)
        time.sleep(gap)
    report = j.app.rpc("debug.motion", {"action": "trace_stop"}, timeout=60) or {}
    samples = report.get("samples") or []
    data = {"presses_ms": marks, "refresh_ms": report.get("refresh_ms"), "samples": samples, "panes": j.zoom_panes,
            "layers": extra}
    if not hasattr(j, "zoom_traces"):
        j.zoom_traces = {}
    j.zoom_traces[as_name] = data
    (j.out / f"diag-{as_name}.json").write_text(json.dumps(data) + "\n")
    return {"samples": len(samples), "presses_ms": marks, "refresh_ms": report.get("refresh_ms")}


def step_zoom_round(j, step):
    focused = _focus(j, step.get("pane", "home"))
    time.sleep(0.6)
    wait = float(step.get("wait", 0.8))
    result = _trace(j, [wait, wait], step["as"])
    return dict(result, focused=focused)


def step_zoom_spam(j, step):
    focused = _focus(j, step.get("pane", "home"))
    time.sleep(0.6)
    n, gap = int(step.get("presses", 7)), float(step.get("interval", 0.045))
    result = _trace(j, [gap] * (n - 1) + [1.2], step["as"])
    return dict(result, focused=focused)


# -- analysis (pure: tests feed it synthetic traces) --

def _panes(sample):
    """{pane: row} of one sample: [pane, x, y, w, h, alpha, z, fx, fy, fw, fh, cw, ch, header, cx, cy, cw2, ch2]."""
    return {row[0]: row for row in sample.get("panes") or [] if isinstance(row, list) and row}


def _rect(row):
    return tuple(round(v, 1) for v in row[1:5])


def _area(r):
    return max(0.0, r[2]) * max(0.0, r[3])


def _inter(a, b):
    x0, y0 = max(a[0], b[0]), max(a[1], b[1])
    x1, y1 = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    return (x0, y0, max(0.0, x1 - x0), max(0.0, y1 - y0))


def _visible(panes):
    """The panes a person can see: shown, and not wholly under a shown pane drawn in front of them."""
    out = {}
    for p, r in panes.items():
        if r[5] <= 0.01 or _area(r[1:5]) <= 0:
            continue
        under = any(q != p and o[6] > r[6] and o[5] > 0.99 and _area(_inter(o[1:5], r[1:5])) >= _area(r[1:5]) - 1
                    for q, o in panes.items())
        if not under:
            out[p] = r
    return out


def _signature(sample):
    panes = _visible(_panes(sample))
    sig = tuple(sorted((p, _rect(r), round(r[5], 2)) for p, r in panes.items()))
    pages = tuple(tuple(round(v, 0) for v in (row[:4] + [row[5]])) for row in sample.get("page") or [] if isinstance(row, list))
    return sig, pages


def _zoom_owner(sample):
    zoom = sample.get("zoom") or [""]
    return zoom[0] if zoom else ""


def _backing(sample):
    """{pane: alpha of its host's own backing fill} when the build reports it (`backing` rows), else None."""
    rows = sample.get("backing")
    if rows is None:
        return None
    return {row[0]: row[1] for row in rows if isinstance(row, list) and len(row) >= 2}


def _page_in_window(pages, browser):
    """Whether the browser pane's page draws in its own window (over every view of the cmux window)."""
    for page in pages or []:
        if page.get("pane") == browser:
            return page.get("presentation") == "child_window" or (page.get("page_window_layer_hosts") or 0) > 0
    return False


def analyze_press(samples, start_ms, end_ms, refresh_ms, browser, max_ms=150.0, page_in_window=False):
    """Problems (strings) and facts of the frames between one press and the next."""
    frame = refresh_ms or 16.7
    seg = [s for s in samples if start_ms <= s.get("t", 0) < end_ms]
    problems, facts = [], {}
    if len(seg) < 3:
        return [f"only {len(seg)} frames after the press at {start_ms:.0f} ms"], facts
    prev_index = max([i for i, s in enumerate(samples) if s.get("t", 0) < start_ms] or [0])
    seq = [samples[prev_index]] + seg
    changes = [k for k in range(1, len(seq)) if _signature(seq[k]) != _signature(seq[k - 1])]
    facts["changed_frames"] = len(changes)
    if not changes:
        problems.append(f"nothing moved after the press at {start_ms:.0f} ms")
        return problems, facts
    # Episodes: runs of changes at most 2 frames apart.
    episodes, run = [], [changes[0]]
    for k in changes[1:]:
        if k - run[-1] <= 2:
            run.append(k)
        else:
            episodes.append(run)
            run = [k]
    episodes.append(run)
    first, last = seq[changes[0]]["t"], seq[changes[-1]]["t"]
    facts.update(first_ms=round(first - start_ms, 1), episodes=len(episodes),
                 episode_ms=[round(seq[e[-1]]["t"] - seq[e[0]]["t"] + frame, 1) for e in episodes])
    if len(episodes) > 1:
        problems.append(f"{len(episodes)} transitions for one press (frames that change: "
                        f"{[(round(seq[e[0]]['t'] - start_ms), round(seq[e[-1]]['t'] - start_ms)) for e in episodes]} ms after it)")
    main = max(episodes, key=len)
    duration = seq[main[-1]]["t"] - seq[main[0]]["t"] + frame
    facts["transition_ms"] = round(duration, 1)
    if duration > max_ms + frame:
        problems.append(f"the transition lasts {duration:.0f} ms (> {max_ms:.0f} ms)")
    # The zooming pane: the one whose rect changes most.
    moved = {}
    for k in range(1, len(seq)):
        a, b = _panes(seq[k - 1]), _panes(seq[k])
        for p in set(a) & set(b):
            if _rect(a[p]) != _rect(b[p]):
                moved[p] = moved.get(p, 0) + 1
    zooming = max(moved, key=moved.get) if moved else None
    facts["zooming"] = zooming
    if zooming:
        rects = [_rect(_panes(s)[zooming]) for s in seq if zooming in _panes(s)]
        distinct = len(set(rects))
        facts["zooming_rects"] = distinct
        if distinct < 4:
            problems.append(f"the zooming pane {zooming} jumps: {distinct} distinct frames (a pop, no in-between frames)")
        held, sizes, header = 0, set(), 0
        for s in seq:
            row = _panes(s).get(zooming)
            if not row or len(row) < 14:
                continue
            fw, fh, cw, ch = row[9], row[10], row[11], row[12]
            sizes.add((round(cw), round(ch)))
            if cw > fw + 1 or ch > fh + 1:
                held += 1
            if row[13] < 0.999:
                header += 1
        facts["content_sizes"] = len(sizes)
        if held:
            problems.append(f"the zooming pane's content is held larger than its pane in {held} frames (not laid out live)")
        if distinct >= 4 and len(sizes) < 3:
            problems.append(f"the zooming pane's content takes {len(sizes)} sizes while its pane takes {distinct}: it snaps")
        if header:
            problems.append(f"the zooming pane's tab bar is cut in {header} frames")
    # Presence and stacking inside the transition (a pop of a pane or of the browser page).
    inside = seq[main[0] - 1: main[-1] + 1]
    for k in range(1, len(inside)):
        a, b = _panes(inside[k - 1]), _panes(inside[k])
        t = round(inside[k]["t"] - start_ms)
        for p in set(a) ^ set(b):
            if p not in _visible(a) and p not in _visible(b):
                continue  # a pane let go under the zoomed one: nobody sees it go
            problems.append(f"pane {p} {'appears' if p in b else 'vanishes'} at once {t} ms after the press")
        for p in set(a) & set(b):
            if (a[p][5] > 0.01) != (b[p][5] > 0.01) or (_area(a[p][1:5]) > 0) != (_area(b[p][1:5]) > 0):
                problems.append(f"pane {p} shows or hides at once {t} ms after the press")
    # The browser page: on screen while its pane is not wholly covered; never a page window over the zooming pane.
    blank = over = 0
    for s in seq:
        panes = _panes(s)
        brow = panes.get(browser)
        if not brow:
            continue
        b = brow[1:5]
        covered = 0.0
        zrow = panes.get(zooming) if zooming and zooming != browser else None
        if zrow and zrow[6] > brow[6]:
            covered = _area(_inter(zrow[1:5], b))
        uncovered = _area(b) - covered
        pages = [row for row in s.get("page") or [] if isinstance(row, list)]
        shown = any(len(row) > 5 and row[5] == 0 for row in pages)
        if uncovered > 4 and not pages:
            blank += 1
        if page_in_window and zrow and covered > 4 and any(len(row) > 5 and row[2] > 0 and row[5] == 0 for row in pages):
            over += 1
        if uncovered > 4 and pages and not shown:
            blank += 1
    if blank:
        problems.append(f"the browser page is not on screen in {blank} frames where its pane shows")
    if over:
        problems.append(f"the browser's page window draws over the zooming pane in {over} frames")
    # Material: no backing the pane at rest does not have.
    opaque = []
    for s in seq:
        owner = _zoom_owner(s)
        backing = _backing(s)
        if backing is None:
            if owner:
                opaque.append(s["t"])
        elif any(v > 0.01 for v in backing.values()):
            opaque.append(s["t"])
    if opaque:
        problems.append(f"an opaque backing the resting pane does not have shows for {opaque[-1] - opaque[0] + frame:.0f} ms "
                        f"({len(opaque)} frames)" + ("" if _backing(seq[-1]) is not None else
                                                     ": inferred from the zoom owner, PaneHostView.backsZoom on this build"))
    facts["opaque_frames"] = len(opaque)
    return problems, facts


def cond_zoom_transition(j, want, cache):
    data = getattr(j, "zoom_traces", {}).get(want["of"])
    if not data:
        return False, {"error": f"no trace named {want['of']}"}
    samples, presses = data["samples"], data["presses_ms"]
    report, problems = [], []
    for i, start in enumerate(presses):
        end = presses[i + 1] if i + 1 < len(presses) else float("inf")
        browser = data["panes"].get("browser")
        found, facts = analyze_press(samples, start, end, data.get("refresh_ms"), browser, float(want.get("max_ms", 150)),
                                     _page_in_window(data.get("layers"), browser))
        report.append({"press": i + 1, "facts": facts, "problems": found})
        problems += [f"press {i + 1}: {p}" for p in found]
    return not problems, {"presses": report, "problems": problems[:20], "frames": len(samples)}


def cond_zoom_settles(j, want, cache):
    data = getattr(j, "zoom_traces", {}).get(want["of"])
    if not data:
        return False, {"error": f"no trace named {want['of']}"}
    samples, presses = data["samples"], data["presses_ms"]
    last = presses[-1]
    zoomed_wanted = len(presses) % 2 == 1
    end = samples[-1] if samples else {}
    panes = _panes(end)
    shown = [p for p, r in panes.items() if r[5] > 0.01 and _area(r[1:5]) > 0]
    zoomed_now = len(shown) == 1
    frame = data.get("refresh_ms") or 16.7
    late = [s["t"] for k, s in enumerate(samples[1:], 1) if s["t"] > last + 150 + 2 * frame
            and _signature(s) != _signature(samples[k - 1])]
    problems = []
    if zoomed_now != zoomed_wanted:
        problems.append(f"after {len(presses)} presses the screen is {'zoomed' if zoomed_now else 'not zoomed'}")
    if late:
        problems.append(f"frames still change {late[0] - last:.0f} to {late[-1] - last:.0f} ms after the last press (runoff)")
    return not problems, {"problems": problems, "shown_panes": shown, "presses": len(presses)}


STEPS = {"zoom_layout": step_zoom_layout, "zoom_round": step_zoom_round, "zoom_spam": step_zoom_spam}
CONDITIONS = {"zoom_transition": ("app", cond_zoom_transition), "zoom_settles": ("app", cond_zoom_settles)}
