"""Resize fuzzing and live-resize latency for the journeys (felt 1e, Lawrence 2026-10-29: "there are resize
bugs where the terminal doesnt resize properly, make sure to fuzz it out. and it needs to be super fluid").

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It reuses ext_window's reads, drags and its grid_fits condition; it must not import driver.py.

Steps (`do`):
  resize_fuzz {seed, ops?, panes, divider?: [A, B], settle?: s, sample?: bool, max_pt?}
      A seeded random sequence of `ops` resizes of the current window and (with `divider`) of the divider
      between named panes A and B: corner drags of random size and speed (1 to 45 events at 60 Hz), tiny
      ones (1 to 8 points), large bursts, a drag out and back to the same size, a drag held still before its
      release, shrinks to the window's minimum. Each op is played as a person plays it (`debug.mouse` down,
      one drag event per display frame, up; the events go through AppKit's live-resize tracking or the
      layout's divider drag).
      With `sample` (default on) every drag event is followed by one `debug.surfaces` read: for each named
      pane the grid its view fits (`fit_grid`), the grid Ghostty's last frame drew (`drawn_grid`) and the
      owner's grid (`grid`: the PTY has it). From those it reports how long, in ms and in samples, the
      drawn grid and the owner's grid trail a new view size during the drag (p50, p95, max).
      After each op every named pane must pass ext_window's grid_fits within `settle` seconds (default 3):
      grid == fitted == drawn, the daemon's screen has that size, the grid fits the view's frame. The step
      fails at its end with every op that did not settle (seed, op index, op, detail), so one run lists all.
      `debug.terminal_final_grid` (builds with bench hooks) records each op's grids sent to the PTY owner,
      drawn and announced, in app time; the step keeps them per op and the send-to-announce delays.
"""
import random
import time

D = None  # the driver module (install)
W = None  # ext_window (install)


def install(driver):
    global D, W
    D = driver
    import ext_window
    W = ext_window


def _pct(values, q):
    if not values:
        return None
    s = sorted(values)
    return round(s[min(len(s) - 1, int(round(q * (len(s) - 1))))], 1)


def _summary(values):
    return {"n": len(values), "p50": _pct(values, 0.5), "p95": _pct(values, 0.95), "max": round(max(values), 1) if values else None}


def _sample(j, names):
    """{name: (fit, drawn, grid)} of the named panes now (one debug.surfaces read), and its time (s)."""
    t = time.monotonic()
    report = j.app.rpc("debug.surfaces") or {}
    rows = {}
    for w in report.get("windows") or []:
        for p in w.get("panes") or []:
            if isinstance(p, dict):
                rows[p.get("pane")] = p
    out = {}
    for name in names:
        row = rows.get(W.named(j, name)["pane"]) or {}
        s = row.get("surface") or {}
        out[name] = (s.get("fit_grid"), s.get("drawn_grid"), s.get("grid"))
    return t, out


def _trail(samples, names):
    """Per pane: for each new view size (a change of fit_grid between samples), how long until the drawn grid
    and the owner's grid showed it (ms from the sample that first saw the size; samples trailing). A size the
    drag left before a grid caught up counts as the time it stood (censored: listed apart)."""
    out = {}
    for name in names:
        series = [(t, s[name]) for t, s in samples if name in s]
        drawn_ms, owner_ms, drawn_left, owner_left, stale_drawn = [], [], 0, 0, 0
        for i, (t, (fit, drawn, grid)) in enumerate(series):
            if fit and drawn and fit != drawn:
                stale_drawn += 1
            if i == 0 or not fit or fit == series[i - 1][1][0]:
                continue
            for idx, key, bucket in ((1, "drawn", drawn_ms), (2, "owner", owner_ms)):
                caught = None
                for t2, grids in series[i:]:
                    if grids[0] != fit:
                        break  # the view moved on first
                    if grids[idx] == fit:
                        caught = (t2 - t) * 1000
                        break
                if caught is None:
                    if key == "drawn":
                        drawn_left += 1
                    else:
                        owner_left += 1
                else:
                    bucket.append(caught)
        out[name] = {"drawn_raw": drawn_ms, "owner_raw": owner_ms, "sizes": sum(1 for i in range(1, len(series)) if series[i][1][0] != series[i - 1][1][0]),
                     "samples": len(series), "samples_drawn_not_fit": stale_drawn,
                     "drawn_catch_up_ms": _summary(drawn_ms), "drawn_never_caught": drawn_left,
                     "owner_catch_up_ms": _summary(owner_ms), "owner_never_caught": owner_left}
    return out


def _pooled(ops, names):
    """Per pane, the catch-up times of every op pooled (each op's own samples: the waits between ops are no lag)."""
    out = {}
    for name in names:
        drawn = [v for o in ops for v in ((o.get("trail") or {}).get(name) or {}).get("drawn_raw", [])]
        owner = [v for o in ops for v in ((o.get("trail") or {}).get(name) or {}).get("owner_raw", [])]
        out[name] = {"drawn_catch_up_ms": _summary(drawn), "owner_catch_up_ms": _summary(owner)}
    return out


def _trace(j, action):
    try:
        return j.app.rpc("debug.terminal_final_grid", {"action": action} if action else {})
    except Exception as error:  # noqa: BLE001 (a build without bench hooks answers null or an error)
        return {"error": str(error)[:200]}


def _send_to_owner(trace):
    """App-time ms from each grid sent to the PTY owner to the owner's announcement of it."""
    delays = []
    for terminal in ((trace or {}).get("terminals") or {}).values():
        owners = terminal.get("owner") or []
        for send in terminal.get("sends") or []:
            hit = next((o for o in owners if o.get("grid") == send.get("grid") and o.get("ms", -1) >= send.get("ms", 0)), None)
            if hit:
                delays.append(hit["ms"] - send["ms"])
    return delays


def _drag(j, wid, start, path, hz, names, samples, hold=0.0):
    """Down at `start`, one drag event per display frame through `path`, a still `hold`, up; samples after each event."""
    j.app.rpc("debug.mouse", {"window": wid, "action": "down", "x": start[0], "y": start[1]})
    t0 = time.monotonic()
    for i, (x, y) in enumerate(path, 1):
        j.app.rpc("debug.mouse", {"window": wid, "action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1,
                                  "press": False, "release": False})
        if names is not None:
            samples.append(_sample(j, names))
        W._pace(t0, i, hz)
    end = path[-1] if path else start
    if hold:
        h0 = time.monotonic()
        while time.monotonic() - h0 < hold:
            if names is not None:
                samples.append(_sample(j, names))
            time.sleep(1 / hz)
    j.app.rpc("debug.mouse", {"window": wid, "action": "up", "x": end[0], "y": end[1]})
    return W.settle_queue(j)


def _line(start, delta, events):
    return [(start[0] + delta[0] * i / events, start[1] + delta[1] * i / events) for i in range(1, events + 1)]


def _divider_start(j, a, b):
    fa, fb = W.frame_of(W.pane_row(j, a["pane"])), W.frame_of(W.pane_row(j, b["pane"]))
    if not fa or not fb:
        raise D.StepError(f"resize_fuzz: no frames for the divider's panes: {fa} {fb}")
    if fb[0] >= fa[0] + fa[2] - 1:
        top, bottom = max(fa[1], fb[1]), min(fa[1] + fa[3], fb[1] + fb[3])
        return ((fa[0] + fa[2] + fb[0]) / 2, (top + bottom) / 2), "x", (fa, fb)
    left, right = max(fa[0], fb[0]), min(fa[0] + fa[2], fb[0] + fb[2])
    return ((left + right) / 2, (fa[1] + fa[3] + fb[1]) / 2), "y", (fa, fb)



def classify_chain(row):
    """Names the link that keeps a pane's terminal from counting as shown (felt 1e candidates), from the
    `shown` and `node_chain` fields `debug.surfaces` reports (builds from cp/fix-resize-standin-grid on).
    Each chain entry is "name own/effective", from the surface's window node up to the root.
      - "shown": the terminal counts as shown (no node problem);
      - "c2-placement": `terminal.surface.window` is own-hidden while every node above is visible or occluded:
        its placement (window, parking) was never read again (TerminalSurfaceView.syncPlacement);
      - "c3-dead-parent": the chain ends before a window root (no `pane:`/`window` link above the tab node):
        a parent the tree holds weakly is gone (a replaced pane controller's node);
      - "hidden-link:<name>": another link is own-hidden (the first such link above the window node);
      - "no-diagnostics": the build has no `node_chain` (older than the diagnostics commit)."""
    surface = (row or {}).get("surface") or {}
    if "node_chain" not in surface:
        return "no-diagnostics", []
    chain = surface.get("node_chain") or []
    links = []
    for entry in chain:
        name, _, states = entry.rpartition(" ")
        own, _, effective = states.partition("/")
        links.append({"name": name, "own": own, "effective": effective})
    if surface.get("shown"):
        return "shown", links
    if links and links[0]["own"] == "hidden" and all(l["own"] != "hidden" for l in links[1:]):
        if any(l["name"].startswith("pane:") for l in links) and links[-1]["effective"] != "hidden":
            return "c2-placement", links
    if not any(l["name"].startswith("pane:") for l in links):
        return "c3-dead-parent", links
    for link in links[1:]:
        if link["own"] == "hidden":
            return "hidden-link:" + link["name"], links
    return "unexplained", links


def _chains(j, names):
    """{name: (verdict, chain)} for the named panes now."""
    out = {}
    for name in names:
        row = W.pane_row(j, W.named(j, name)["pane"])
        verdict, links = classify_chain(row)
        out[name] = {"verdict": verdict, "chain": [f"{l['name']} {l['own']}/{l['effective']}" for l in links]}
    return out

def _settled(j, names, timeout):
    """(ms until every named pane passes grid_fits, or None) and the last details."""
    t0 = time.monotonic()
    details = {}
    while True:
        ok = True
        for name in names:
            holds, detail = W.cond_grid_fits(j, {"pane": name}, {})
            details[name] = detail
            ok = ok and holds
        if ok:
            return round((time.monotonic() - t0) * 1000), details
        if time.monotonic() - t0 > timeout:
            return None, details
        time.sleep(0.1)


def step_resize_fuzz(j, step):
    """`seeds: [..]` plays each seed's sequence in turn (one result per seed) and fails at the end with every
    failing seed; `seed: N` plays one."""
    if "seeds" in step:
        results, failed = [], []
        for seed in step["seeds"]:
            one = dict(step, seed=seed)
            one.pop("seeds")
            try:
                results.append(_fuzz_one(j, one))
            except D.StepError as error:
                results.append(getattr(j, "ext_resize_fuzz", None))
                failed.append(f"seed {seed}: {str(error)[:300]}")
        summary = {"seeds": step["seeds"], "results": results, "failed_seeds": failed}
        if failed:
            raise D.StepError(f"resize_fuzz: {len(failed)} of {len(step['seeds'])} seeds failed: " + " | ".join(failed)[:1200])
        return summary
    return _fuzz_one(j, step)


def _fuzz_one(j, step):
    seed = int(step.get("seed", 1))
    rng = random.Random(seed)
    names = list(step["panes"])
    sample = bool(step.get("sample", True))
    settle = float(step.get("settle", 3))
    hz = float(step.get("hz", 60))
    max_pt = float(step.get("max_pt", 320))
    divider = step.get("divider")
    wid = W.current_window(j)
    kinds = ["corner", "corner", "tiny", "burst", "out_and_back", "held", "shrink_min", "right", "bottom"]
    if divider:
        kinds += ["divider", "divider", "divider_tiny"]
    ops, failures = [], []
    owner_delays = []
    for index in range(int(step.get("ops", 24))):
        kind = rng.choice(kinds)
        win = W.window_rec(j, wid)
        x0, y0, w, h = win["frame"]
        vx, vy, vw, vh = win["visible"]
        room_right, room_down = (vx + vw) - (x0 + w) - 4, y0 - vy - 4
        events = rng.randint(2, 45)
        hold = 0.0
        if kind in ("corner", "right", "bottom", "burst", "held", "tiny", "out_and_back", "shrink_min"):
            edge = {"right": "right", "bottom": "bottom"}.get(kind, "bottom-right")
            start = {"bottom-right": (w - 1, h - 1), "right": (w - 1, h / 2), "bottom": (w / 2, h - 1)}[edge]
            if kind == "tiny":
                dx, dy, events = rng.choice([-1, 1]) * rng.randint(1, 8), rng.choice([-1, 1]) * rng.randint(1, 8), rng.randint(1, 3)
            elif kind == "burst":
                dx, dy, events = rng.uniform(-max_pt, max_pt), rng.uniform(-max_pt, max_pt), rng.randint(2, 5)
            elif kind == "shrink_min":
                dx, dy = -w, -h  # AppKit stops it at the window's minimum size
            else:
                dx, dy = rng.uniform(-max_pt, max_pt), rng.uniform(-max_pt * 0.7, max_pt * 0.7)
            if edge == "right":
                dy = 0
            if edge == "bottom":
                dx = 0
            dx = min(dx, max(0, room_right)) if dx > 0 else dx
            dy = min(dy, max(0, room_down)) if dy > 0 else dy
            path = _line(start, (dx, dy), events)
            if kind == "out_and_back":
                path += _line(path[-1], (-dx, -dy), events)  # the same size twice: out and back
            if kind == "held":
                hold = rng.uniform(0.2, 1.0)
            op = {"i": index, "kind": kind, "edge": edge, "by": [round(dx), round(dy)], "events": len(path), "hold_s": round(hold, 2),
                  "frame_before": win["frame"]}
        else:
            a, b = (W.named(j, n) for n in divider)
            start, axis, frames = _divider_start(j, a, b)
            size_a = frames[0][2] if axis == "x" else frames[0][3]
            size_b = frames[1][2] if axis == "x" else frames[1][3]
            by = rng.uniform(-(size_a - 120), size_b - 120) if kind == "divider" else rng.choice([-1, 1]) * rng.randint(1, 8)
            delta = (by, 0) if axis == "x" else (0, by)
            if kind == "divider_tiny":
                events = rng.randint(1, 3)
            path = _line(start, delta, events)
            j.app.rpc("debug.mouse", {"window": wid, "action": "move", "x": start[0], "y": start[1]})
            op = {"i": index, "kind": kind, "axis": axis, "by": round(by), "events": events, "frames_before": list(frames)}
        if index == 0:
            j.ext_resize_chains_before = _chains(j, names)
        _trace(j, "start")
        samples = []
        op["settle_queue"] = _drag(j, wid, start, path, hz, names if sample else None, samples, hold)
        if kind.startswith("divider"):
            j.app.rpc("debug.mouse", {"window": wid, "action": "leave", "x": path[-1][0], "y": path[-1][1]})
        ms, details = _settled(j, names, settle)
        trace = _trace(j, None)
        op["settle_ms"] = ms
        op["frame_after"] = W.window_rec(j, wid)["frame"]
        op["trail"] = _trail(samples, names) if samples else None
        delays = _send_to_owner(trace)
        owner_delays += delays
        op["send_to_owner_ms"] = _summary(delays)
        if ms is None:
            op["unsettled"] = {n: d for n, d in details.items() if d.get("problems")}
            op["chains"] = _chains(j, [n for n in names if n in op["unsettled"]])
            failures.append({"seed": seed, "op": index, "kind": kind, "detail": op["unsettled"]})
        ops.append(op)
    result = {"seed": seed, "ops": ops, "failures": failures, "chains_before": getattr(j, "ext_resize_chains_before", None),
              "chains_after": _chains(j, names),
              "trail_all": _pooled(ops, names),
              "send_to_owner_ms_all": _summary(owner_delays),
              "settle_ms_all": _summary([o["settle_ms"] for o in ops if o["settle_ms"] is not None])}
    j.ext_resize_fuzz = result
    if failures:
        verdicts = sorted({c["verdict"] for o in ops for c in (o.get("chains") or {}).values()})
        raise D.StepError(f"resize_fuzz seed {seed}: {len(failures)} of {len(ops)} ops left a pane unfitted; node verdicts "
                          f"{verdicts}; first: {str(failures[0])[:500]}")
    return result


def step_retarget_pane(j, step):
    """The named pane's selected tab changed (a new tab in the same pane, Ctrl-`): its record and the current
    terminal follow the tab's daemon terminal, once that terminal's screen has text."""
    rec = W.named(j, step["as"])
    end = D.now() + float(step.get("timeout", 20))
    last = None
    while D.now() < end:
        try:
            term = W.daemon_terminal_of(j, rec["pane"])
            if term != rec["term"] and j.app.screen(term)["text"].strip():
                rec["term"] = term
                j.pane, j.term = rec["pane"], term
                return {"pane": rec["pane"], "term": term}
            last = f"terminal {term} (was {rec['term']})"
        except D.StepError as error:
            last = str(error)
        time.sleep(0.2)
    raise D.StepError(f"retarget_pane {step['as']!r}: no new terminal with text: {last}")


def step_node_chain(j, step):
    """Records, for each named pane (`panes`), whether its terminal counts as shown and, if not, which link of its
    visibility node chain is hidden or missing (``classify_chain``). With `expect_shown` (default on) it fails with
    the verdicts when one is not shown; a build without the diagnostics passes with "no-diagnostics"."""
    chains = _chains(j, list(step["panes"]))
    if step.get("expect_shown", True):
        bad = {n: c for n, c in chains.items() if c["verdict"] not in ("shown", "no-diagnostics")}
        if bad:
            raise D.StepError(f"node_chain: not shown: {bad}")
    return {"chains": chains}


STEPS = {"resize_fuzz": step_resize_fuzz, "retarget_pane": step_retarget_pane, "node_chain": step_node_chain}
