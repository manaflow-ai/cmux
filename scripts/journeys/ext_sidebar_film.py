"""Sidebar row insert / remove films for the journeys (journeys/perf/sidebar-rows-film-*.json; cmux-ad m23, STATUS 14191).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

A film is the sidebar as the render server shows it, once per display frame, from just before a key press to after
its motion: `debug.sidebar_rows {"motion": "start"|"stop"}` (SidebarMotionProbe). Each frame has `t` (when the
presentation was read), `link` / `target` / `refresh` (the display link's tick: vsync time, show time, refresh period;
null refresh = a synthesized frame), `revision` (the list's model structure), `views` {row key: [x, y, w, h,
opacity]} (list coordinates, presented), `ids` {row key: view object id}, `selected` (the key of the row that draws
the selection) and `selection` (its presented [x, y, w, h]); each press keeps the report's `scale` (device px per pt). Builds before the probe's `ids` / `link`
fields give `t` only: the summary then says so and counts by `t`.

This file films and measures; it judges nothing about where a row should be (the y oracle is pixel-perfect's PR).
It measures, per press, only what needs no oracle:
  - missed refreshes: frame intervals over 1.5 refresh periods (by `link`, else `t`), over the motion window
    (first to last frame where any row's y, height or opacity changed) and over the whole recording;
  - rebuilt rows: frames where a row key that was listed in the frame before has another view id during the motion.

Steps (`do`):
  film_grow       {count, settle?}        script workspaces (newTab with a name, wait) until the app has COUNT
  film_busy       {count, on?}            ON (default true): COUNT terminals of workspaces other than the shown one
                                          print a line every 20 ms (perf-stress-session.py's BUSY_COMMAND);
                                          on false: Ctrl-C to each terminal made busy before
  film_presses    {scenario, pairs?, gap?, record?, insert_key?, remove_key?}
                                          PAIRS (default 10) times: Cmd-N (a new workspace row: insert), then
                                          Cmd-Shift-W (Close Workspace on the new, selected row: remove), each under a
                                          film of RECORD seconds (default 1.2) and GAP seconds apart (default 0.8).
                                          Before and after each press the whole row list (debug.sidebar_rows rows, every
                                          row of the list, realized or not) is kept, outside the film. Writes
                                          film-SCENARIO.json in the journey folder (run.py fetches it) and returns the
                                          scenario's summary.

Condition (inside `expect.all`; evidence kind app):
  film_recorded   {scenario, presses}     the film of SCENARIO has at least PRESSES presses with frames
"""
import json
import time

D = None  # the driver module (install)
BUSY_COMMAND = 'while :; do echo "$RANDOM $RANDOM $RANDOM stress output line $(date +%s)"; sleep 0.02; done\r'
# A frame interval over this many refresh periods missed at least one refresh.
MISS_FACTOR = 1.5
# A row moved, resized or faded between two frames when one of these changed by more than this (points, opacity).
MOVE_EPS = 0.05
OPACITY_EPS = 0.002


def install(driver):
    global D
    D = driver


def now():
    return time.monotonic()


def _films(j):
    if not hasattr(j, "films"):
        j.films, j.film_busy = {}, []
    return j.films


def workspace_ids(j):
    return [w.get("id") for w in j.topology().get("workspaces") or [] if w.get("id")]


def step_film_grow(j, step):
    count = int(step.get("count", 50))
    start = len(workspace_ids(j))
    made, t = 0, now()
    for index in range(start, count):
        j.app.rpc("action.run", {"action": "newTab", "args": {"name": f"film-{j.nonce}-{index}"}, "wait": True}, timeout=60)
        made += 1
    have = len(workspace_ids(j))
    if have < count:
        raise D.StepError(f"film_grow: {have} workspaces, want {count}")
    time.sleep(float(step.get("settle", 2.0)))
    return {"workspaces": have, "made": made, "seconds": round(now() - t, 1)}


def step_film_busy(j, step):
    _films(j)
    if step.get("on", True) is False:
        stopped = []
        for term in j.film_busy:
            try:
                j.app.cmux("terminal", term, "write", "--text", "\x03")
                stopped.append(term)
            except D.StepError:
                pass
        j.film_busy = []
        time.sleep(float(step.get("settle", 1.0)))
        return {"stopped": stopped}
    count = int(step.get("count", 10))
    topo = j.topology()
    shown = {w.get("workspace") for w in topo.get("windows") or []}
    seen, terms = set(), []
    for ws, pane, tab, term in j.places(topo):
        wid = ws.get("id")
        if not term or wid in shown or wid in seen or term in j.film_busy:
            continue
        seen.add(wid)
        terms.append(term)
        if len(terms) >= count:
            break
    started = []
    for term in terms:
        try:
            j.app.cmux("terminal", term, "write", "--text", BUSY_COMMAND)
            started.append(term)
        except D.StepError:
            pass
    j.film_busy += started
    if len(started) < count:
        raise D.StepError(f"film_busy: {len(started)} busy terminals, want {count}")
    time.sleep(float(step.get("settle", 2.0)))
    return {"busy": started}


def row_list(j):
    """Every row of the first window's list (debug.sidebar_rows), compact: key, layout frame y/height, the view's
    frame and alpha when realized, selected, in_list. Read outside the films (it costs the main thread)."""
    report = j.app.rpc("debug.sidebar_rows", timeout=60) or {}
    windows = report.get("windows") or []
    rows = (windows[0] if windows else {}).get("rows") or []
    out = []
    for r in rows:
        f, v = r.get("frame") or {}, r.get("view_frame")
        out.append({"key": r.get("key"), "y": f.get("y"), "h": f.get("height"), "x": f.get("x"), "w": f.get("width"),
                    "view": [v.get("x"), v.get("y"), v.get("width"), v.get("height")] if isinstance(v, dict) else None,
                    "alpha": r.get("view_alpha"), "selected": r.get("selected"), "in_list": r.get("in_list"),
                    "group": r.get("group"), "row_state": r.get("row_state")})
    return out


def film_one(j, key, modifiers, record):
    """One press under a film: motion start, 0.15 s of still frames, the key, RECORD seconds, motion stop."""
    j.app.rpc("debug.sidebar_rows", {"motion": "start"})
    time.sleep(0.15)  # still frames before the press
    sent = now()
    reply = j.key(key, modifiers)
    returned = now()
    time.sleep(record)
    stopped = j.app.rpc("debug.sidebar_rows", {"motion": "stop"}, timeout=60) or {}
    return {"key": key, "modifiers": modifiers, "sent": sent, "returned": returned,
            "reply": reply if isinstance(reply, dict) else {"value": reply}, "scale": stopped.get("scale"),
            "frames": stopped.get("frames") or []}


def step_film_presses(j, step):
    films = _films(j)
    scenario = step["scenario"]
    pairs, gap, record = int(step.get("pairs", 10)), float(step.get("gap", 0.8)), float(step.get("record", 1.2))
    insert_key = step.get("insert_key", {"key": "n", "modifiers": ["cmd"]})
    remove_key = step.get("remove_key", {"key": "w", "modifiers": ["cmd", "shift"]})
    presses = []
    for index in range(pairs):
        for kind, press in (("insert", insert_key), ("remove", remove_key)):
            before_ws = workspace_ids(j)
            before_rows = row_list(j)
            # A key typed while the app holds keys for a terminal being made (CreationInputCoordinator, after Cmd-N)
            # waits for it: the press would then move inside its film. Each press starts past that hold.
            held = j.outwait_creation_hold(getattr(j, "last_key_at", 0.0))
            time.sleep(0.3)  # the row list read settles before the film
            shot = film_one(j, press["key"], press.get("modifiers", []), record)
            want = len(before_ws) + (1 if kind == "insert" else -1)
            end, after_ws, fallback = now() + 5, before_ws, None
            while now() < end:
                after_ws = workspace_ids(j)
                if len(after_ws) == want:
                    break
                time.sleep(0.1)
            if len(after_ws) != want and kind == "remove":
                # The key did not close it (a question, a key the terminal took): the action, so the next pair
                # starts from the same count. The film of this press then shows no remove; the summary says so.
                fallback = j.app.rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}})
                time.sleep(1.0)
                after_ws = workspace_ids(j)
            after_rows = row_list(j)
            shot.update({"scenario": scenario, "index": len(presses), "pair": index, "kind": kind,
                         "workspaces_before": len(before_ws), "workspaces_after": len(after_ws),
                         "added": sorted(set(after_ws) - set(before_ws)), "removed": sorted(set(before_ws) - set(after_ws)),
                         "fallback_action": fallback, "waited_out_hold_s": held, "rows_before": before_rows, "rows_after": after_rows})
            shot["measure"] = measure(shot["frames"])
            presses.append(shot)
            time.sleep(gap)
    film = {"scenario": scenario, "busy": list(getattr(j, "film_busy", [])), "presses": presses,
            "summary": summarize(presses)}
    films[scenario] = film
    (j.out / f"film-{scenario}.json").write_text(json.dumps(film, separators=(",", ":")) + "\n")
    return {"scenario": scenario, "summary": film["summary"]}


def row_keys(frame):
    return {k for k in (frame.get("views") or {}) if str(k).startswith(("workspace(", "tab("))}


def moved(a, b):
    """Whether a row view's presented box or opacity changed between two frames."""
    return (abs(a[1] - b[1]) > MOVE_EPS or abs(a[3] - b[3]) > MOVE_EPS or abs(a[0] - b[0]) > MOVE_EPS
            or abs((a[4] if len(a) > 4 else 1) - (b[4] if len(b) > 4 else 1)) > OPACITY_EPS)


def measure(frames):
    """Per press, with no oracle: the motion window, the frame intervals (by the display link when the build reports
    it, else by `t`), the missed refreshes in the window and in the whole film, and the frames where a listed row's
    view identity changed during the motion."""
    if len(frames) < 2:
        return {"frames": len(frames), "error": "fewer than 2 frames"}
    clock = "link" if all(isinstance(f.get("link"), (int, float)) for f in frames) else "t"
    refreshes = sorted(f["refresh"] for f in frames if isinstance(f.get("refresh"), (int, float)) and f["refresh"] > 0)
    period = refreshes[len(refreshes) // 2] if refreshes else None
    times = [f[clock] for f in frames]
    gaps = [b - a for a, b in zip(times, times[1:])]
    if period is None:
        # No refresh period reported (an older build): the median interval stands for it.
        period = sorted(gaps)[len(gaps) // 2]
    moving = []
    for i in range(1, len(frames)):
        va, vb = frames[i - 1].get("views") or {}, frames[i].get("views") or {}
        keys_a, keys_b = row_keys(frames[i - 1]), row_keys(frames[i])
        if keys_a != keys_b or any(moved(va[k], vb[k]) for k in keys_a & keys_b) or frames[i - 1].get("scroll") != frames[i].get("scroll"):
            moving.append(i)
    first, last = (moving[0], moving[-1]) if moving else (None, None)

    def misses(lo, hi):
        """Missed refreshes over intervals lo..hi (interval i is frames[i-1] -> frames[i])."""
        count, worst, long = 0, 0.0, 0
        for i in range(max(1, lo), hi + 1):
            gap = times[i] - times[i - 1]
            worst = max(worst, gap)
            if gap > MISS_FACTOR * period:
                long += 1
                count += max(1, int(round(gap / period)) - 1)
        return {"missed_refreshes": count, "long_intervals": long, "worst_ms": round(worst * 1000, 2)}

    rebuilt_frames, rebuilt = 0, []
    ids_known = all(isinstance(f.get("ids"), dict) for f in frames)
    if ids_known and first is not None:
        for i in range(first, last + 1):
            ia, ib = frames[i - 1].get("ids") or {}, frames[i].get("ids") or {}
            changed = [k for k in ib if k in ia and ib[k] != ia[k] and str(k).startswith(("workspace(", "tab("))]
            if changed:
                rebuilt_frames += 1
                rebuilt.append({"frame": i, "keys": changed[:8]})
    synthesized = sum(1 for f in frames if "refresh" in f and f.get("refresh") is None)
    whole = misses(1, len(frames) - 1)
    window = misses(first, last) if first is not None else {"missed_refreshes": 0, "long_intervals": 0, "worst_ms": 0.0}
    return {"frames": len(frames), "clock": clock, "refresh_ms": round(period * 1000, 3),
            "hz": round(1.0 / period, 1) if period else None,
            "motion_frames": (last - first + 1) if first is not None else 0,
            "motion_ms": round((times[last] - times[first - 1]) * 1000, 1) if first is not None else 0.0,
            "window": window, "whole": whole, "synthesized_frames": synthesized,
            "ids_known": ids_known, "rebuilt_frames": rebuilt_frames if ids_known else None, "rebuilt": rebuilt[:20]}


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))]


def summarize(presses):
    out = {}
    for kind in ("insert", "remove", "all"):
        ms = [p["measure"] for p in presses if (kind == "all" or p["kind"] == kind) and "window" in p["measure"]]
        missed = [m["window"]["missed_refreshes"] for m in ms]
        missed_whole = [m["whole"]["missed_refreshes"] for m in ms]
        worst = [m["window"]["worst_ms"] for m in ms]
        rebuilt = [m["rebuilt_frames"] for m in ms if m["rebuilt_frames"] is not None]
        out[kind] = {"presses": len(ms), "missed_p95": pct(missed, 0.95), "missed_max": max(missed) if missed else None,
                     "missed_total": sum(missed), "missed_whole_max": max(missed_whole) if missed_whole else None,
                     "worst_interval_ms_max": max(worst) if worst else None,
                     "presses_with_misses": sum(1 for m in missed if m),
                     "rebuilt_frames_total": sum(rebuilt) if rebuilt else (0 if ms and all(m["ids_known"] for m in ms) else None),
                     "motion_frames_p50": pct([m["motion_frames"] for m in ms], 0.5)}
    hz = sorted(p["measure"].get("hz") for p in presses if p["measure"].get("hz"))
    out["hz"] = hz[len(hz) // 2] if hz else None
    out["clock"] = presses[0]["measure"].get("clock") if presses else None
    out["fallback_closes"] = sum(1 for p in presses if p.get("fallback_action") is not None)
    out["unchanged_count"] = sum(1 for p in presses if p["workspaces_after"] == p["workspaces_before"])
    return out


def cond_film_recorded(j, want, cache):
    film = _films(j).get(want.get("scenario"))
    if not film:
        return False, f"no film {want.get('scenario')!r}"
    got = sum(1 for p in film["presses"] if len(p["frames"]) >= 2)
    return got >= int(want.get("presses", 20)), f"{got} presses with frames; summary {json.dumps(film['summary'])[:600]}"


STEPS = {"film_grow": step_film_grow, "film_busy": step_film_busy, "film_presses": step_film_presses}
CONDITIONS = {"film_recorded": ("app", cond_film_recorded)}
