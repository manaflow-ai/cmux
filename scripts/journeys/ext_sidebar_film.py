"""Sidebar row insert / remove films for the journeys (journeys/perf/sidebar-rows-film-*.json; cmux-ad m23, STATUS 14191).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

A film is the sidebar as the render server shows it, once per display frame, from just before a key press to after
its motion: `debug.sidebar_rows {"motion": "start"|"stop"}` (SidebarMotionProbe). Each frame has `t` (when the
presentation was read), `link` / `target` / `refresh` (the display link's tick: vsync time, show time, refresh period;
null refresh = a synthesized frame), `revision` (the list's model structure), `views` {row key: [x, y, w, h,
opacity]} (list coordinates, presented), `ids` {row key: view object id}, `selected` (the key of the row that draws
the selection) and `selection` (its presented [x, y, w, h]); each press keeps the report's `scale` (device px per pt),
the frame probe's reply (`frame_probe`: `debug.frames` raw, per frame interval_ms and main_ms, missed_split) and the
app's work counters for the press (`counters`: debug.sidebar_perf, debug.layout_counters). Builds before the probe's `ids` / `link`
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
  film_presses    {scenario, pairs?, gap?, record?, insert_key?, remove_key?, mode?}
                                          PAIRS (default 10) times: Cmd-N (a new workspace row: insert), then
                                          Cmd-Shift-W (Close Workspace on the new, selected row: remove), each under a
                                          film of RECORD seconds (default 1.2) and GAP seconds apart (default 0.8).
                                          Before and after each press the whole row list (debug.sidebar_rows rows, every
                                          row of the list, realized or not) is kept, outside the film. `mode:
                                          noswitch`: a script's newTab (focus false) and a Close Workspace aimed at
                                          that new unselected row instead of the keys (the window keeps its
                                          workspace: the sidebar's own cost). Writes
                                          film-SCENARIO.json in the journey folder (run.py fetches it) and returns the
                                          scenario's summary.

  film_profile    {scenario, kind, presses?, gap?, seconds?}
                                          Time Profiler (xctrace, attached to the app's pid) over PRESSES (default 5)
                                          presses of KIND (insert: Cmd-N, remove: Cmd-Shift-W), GAP seconds apart
                                          (default 2.5), no film and no socket reads meanwhile (they cost the main
                                          thread). The main thread is idle between presses, so its samples are the
                                          presses' own work. Each press also runs the per-frame probe (frame intervals,
                                          motion window). Writes profile-SCENARIO.json: main-thread ms by function
                                          (inclusive and self), the top stacks, the sample count, each press's frame
                                          measure, and main-thread ms per motion frame (all main samples / motion frames).

Condition (inside `expect.all`; evidence kind app):
  film_recorded   {scenario, presses}     the film of SCENARIO has at least PRESSES presses with frames
"""
import json
import os
import re
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


COUNTERS = (("sidebar", "debug.sidebar_perf"), ("layout", "debug.layout_counters"))


def counters_reset(j):
    for _, method in COUNTERS:
        try:
            j.app.rpc(method, {"reset": True})
        except (D.StepError, OSError, ValueError):
            pass


def counters_read(j):
    """The app's own work counters since the last reset: the sidebar's (list reloads, row configures, row views
    made, main_ns of its timed applies) and the window's (layout root passes, pane snapshots, workspace applies,
    terminal window updates). An app without one gives {"error": ...} for it."""
    out = {}
    for name, method in COUNTERS:
        try:
            value = j.app.rpc(method, {})
            if isinstance(value, dict):
                value = {k: v for k, v in value.items() if k != "sources" and not isinstance(v, list)}
            out[name] = value
        except (D.StepError, OSError, ValueError) as error:
            out[name] = {"error": str(error)[:200]}
    return out


def film_one(j, key, modifiers, record, act=None):
    """One press under a film: counters reset, the frame probe and the motion probe start, 0.15 s of still frames,
    the key, RECORD seconds, both stop, counters read (the press's own work, outside the film). The frame probe
    (`debug.frames` raw) gives each display frame's interval and the main thread's busy ms in it, and why each
    missed refresh was late (main work, the commit, or the presentation)."""
    counters_reset(j)
    try:
        j.app.rpc("debug.frames", {"action": "start"})
    except (D.StepError, OSError, ValueError):
        pass
    j.app.rpc("debug.sidebar_rows", {"motion": "start"})
    time.sleep(0.15)  # still frames before the press
    sent = now()
    reply = act() if act else j.key(key, modifiers)
    returned = now()
    time.sleep(record)
    stopped = j.app.rpc("debug.sidebar_rows", {"motion": "stop"}, timeout=60) or {}
    try:
        frame_probe = j.app.rpc("debug.frames", {"action": "stop", "raw": True}, timeout=60) or {}
    except (D.StepError, OSError, ValueError) as error:
        frame_probe = {"error": str(error)[:200]}
    work = counters_read(j)
    return {"key": key, "modifiers": modifiers, "sent": sent, "returned": returned, "counters": work,
            "frame_probe": frame_probe,
            "reply": reply if isinstance(reply, dict) else {"value": reply}, "scale": stopped.get("scale"),
            "frames": stopped.get("frames") or []}


def step_film_presses(j, step):
    films = _films(j)
    scenario = step["scenario"]
    pairs, gap, record = int(step.get("pairs", 10)), float(step.get("gap", 0.8)), float(step.get("record", 1.2))
    insert_key = step.get("insert_key", {"key": "n", "modifiers": ["cmd"]})
    remove_key = step.get("remove_key", {"key": "w", "modifiers": ["cmd", "shift"]})
    # `noswitch`: the same row insert and remove with the window staying on its workspace (a script's newTab with
    # focus false, then Close Workspace aimed at that new, unselected row): the sidebar's own work, without the
    # window's content switching to another workspace as Cmd-N and Cmd-Shift-W do.
    noswitch = step.get("mode") == "noswitch"
    presses = []
    for index in range(pairs):
        for kind, press in (("insert", insert_key), ("remove", remove_key)):
            before_ws = workspace_ids(j)
            before_rows = row_list(j)
            act = None
            if noswitch and kind == "insert":
                name = f"film-ns-{j.nonce}-{index}"
                act = lambda name=name: j.app.rpc("action.run", {"action": "newTab", "origin": "script",
                                                                 "args": {"name": name, "focus": False}})
            elif noswitch:
                made = [w for w in before_ws if w in getattr(j, "film_noswitch_made", set())]
                if not made:
                    raise D.StepError("film_presses noswitch: no workspace of this step's insert to close")
                act = lambda wid=made[-1]: j.app.rpc("action.run", {"action": "closeWorkspace", "origin": "script",
                                                                    "args": {"confirm": True}, "target": f"workspace:{wid}"})
            # A key typed while the app holds keys for a terminal being made (CreationInputCoordinator, after Cmd-N)
            # waits for it: the press would then move inside its film. Each press starts past that hold.
            held = j.outwait_creation_hold(getattr(j, "last_key_at", 0.0))
            time.sleep(0.3)  # the row list read settles before the film
            shot = film_one(j, press["key"], press.get("modifiers", []), record, act=act)
            want = len(before_ws) + (1 if kind == "insert" else -1)
            end, after_ws, fallback = now() + 5, before_ws, None
            while now() < end:
                after_ws = workspace_ids(j)
                if len(after_ws) == want:
                    break
                time.sleep(0.1)
            if len(after_ws) != want and kind == "remove" and not noswitch:
                # The key did not close it (a question, a key the terminal took): the action, so the next pair
                # starts from the same count. The film of this press then shows no remove; the summary says so.
                fallback = j.app.rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}})
                time.sleep(1.0)
                after_ws = workspace_ids(j)
            after_rows = row_list(j)
            if noswitch and kind == "insert":
                j.film_noswitch_made = getattr(j, "film_noswitch_made", set()) | (set(after_ws) - set(before_ws))
            shot.update({"mode": "noswitch" if noswitch else "keys", "scenario": scenario, "index": len(presses), "pair": index, "kind": kind,
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
    for kind in ("insert", "remove"):
        probes = [p.get("frame_probe") or {} for p in presses if p["kind"] == kind]
        main = [ms for probe in probes for ms in (probe.get("main_ms") or [])]
        split = {}
        for probe in probes:
            for name, value in (probe.get("missed_split") or {}).items():
                if isinstance(value, (int, float)):
                    split[name] = split.get(name, 0) + value
        out[kind]["main_ms_per_frame"] = {"p50": pct(main, 0.5), "p95": pct(main, 0.95), "p99": pct(main, 0.99),
                                          "max": max(main) if main else None, "frames": len(main),
                                          "over_8_3": sum(1 for ms in main if ms > 1000 / 120)}
        out[kind]["missed_split"] = split
    hz = sorted(p["measure"].get("hz") for p in presses if p["measure"].get("hz"))
    out["hz"] = hz[len(hz) // 2] if hz else None
    out["clock"] = presses[0]["measure"].get("clock") if presses else None
    out["fallback_closes"] = sum(1 for p in presses if p.get("fallback_action") is not None)
    out["unchanged_count"] = sum(1 for p in presses if p["workspaces_after"] == p["workspaces_before"])
    return out


def _profile_rows(xml_path):
    """(thread name, weight ns, [frame names leaf first]) per sample of an xctrace time-profile export. Elements
    with `ref` point at an earlier element with that `id`."""
    import xml.etree.ElementTree as ET
    ids = {}
    rows = []
    for _, el in ET.iterparse(xml_path, events=("end",)):
        if el.get("id"):
            ids[el.get("id")] = el
        if el.tag == "row":
            rows.append(el)
    deref = lambda e: ids.get(e.get("ref"), e) if e is not None and e.get("ref") else e
    out = []
    for row in rows:
        when = deref(row.find("sample-time"))
        try:
            at = int((when.text or "").strip()) if when is not None else None
        except ValueError:
            at = None
        thread = deref(row.find("thread"))
        weight = deref(row.find("weight"))
        # The backtrace column is `backtrace` or `tagged-backtrace` (which holds a `backtrace`), by reference or inline.
        trace = next((deref(e) for e in row if "backtrace" in e.tag), None)
        if trace is not None and trace.tag != "backtrace":
            inner = next((deref(e) for e in trace.iter() if e.tag == "backtrace" and e is not trace), None)
            trace = inner if inner is not None else trace
        frames = [deref(f).get("name") or deref(f).get("fmt") or "?" for f in (trace.iter("frame") if trace is not None else [])]
        try:
            ns = int((weight.text or "0").strip()) if weight is not None else 1000000
        except ValueError:
            ns = 1000000
        out.append(((thread.get("fmt") if thread is not None else "") or "", ns, frames, at))
    return out


# The main-thread work under these frames, as a call tree (root first), so the display cycle's flush splits into
# its layout, display and commit parts and the display-link clients into their owners.
TREE_ROOTS = ("stepTransactionFlush", "CA::Transaction::commit()", "FrameScheduler.tick(_:)", "__CFMachPortPerform",
              "MainActorWorkQueue.drainFrame()")
TREE_DEPTH = 40
TREE_MIN_MS = 4.0


def call_tree(main, root):
    """{name: [ms, children]} of the samples whose stack holds `root`, from the root's first frame down to TREE_DEPTH
    frames, the branches under TREE_MIN_MS dropped. `main`: (ns, frames leaf first)."""
    tree = {}
    for ns, frames in main:
        path = list(reversed(frames))
        at = next((i for i, name in enumerate(path) if name == root), None)
        if at is None:
            continue
        node = tree
        for name in path[at:at + TREE_DEPTH]:
            entry = node.setdefault(name, [0.0, {}])
            entry[0] += ns / 1e6
            node = entry[1]

    def prune(node):
        return {k: [round(v[0], 1), prune(v[1])] for k, v in sorted(node.items(), key=lambda kv: -kv[1][0]) if v[0] >= TREE_MIN_MS}
    return prune(tree)


def step_film_profile(j, step):
    import subprocess
    scenario, kind = step["scenario"], step.get("kind", "insert")
    presses, gap = int(step.get("presses", 5)), float(step.get("gap", 2.5))
    press = {"insert": ("n", ["cmd"]), "remove": ("w", ["cmd", "shift"])}[kind]
    seconds = int(step.get("seconds", 4 + presses * gap + 2))
    trace = j.out / f"profile-{scenario}.trace"
    xml = j.out / f"profile-{scenario}.xml"
    proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(j.app.pid),
                             "--time-limit", f"{seconds}s", "--output", str(trace), "--no-prompt"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    time.sleep(4.0)  # xctrace attaches before the first press
    j.outwait_creation_hold(getattr(j, "last_key_at", 0.0))
    sent, sent_wall, measures = [], [], []
    for _ in range(presses):
        # The per-frame probe (cheap, one presentation read per frame) runs beside the profiler, so each press has
        # its frame intervals; its start and stop requests fall outside the motion.
        counters_reset(j)
        j.app.rpc("debug.sidebar_rows", {"motion": "start"})
        time.sleep(0.15)  # still frames before the press
        sent.append(now())
        sent_wall.append(time.time())
        j.key(press[0], press[1])
        time.sleep(gap)  # the press's motion ends; the main thread idles (no samples) until the next
        stopped = j.app.rpc("debug.sidebar_rows", {"motion": "stop"}, timeout=60) or {}
        measured = measure(stopped.get("frames") or [])
        measured["counters"] = counters_read(j)
        measures.append(measured)
    try:
        log = proc.communicate(timeout=seconds + 60)[0].decode(errors="replace")[-600:]
    except subprocess.TimeoutExpired:
        proc.kill()
        raise D.StepError(f"film_profile: xctrace did not end after {seconds + 60} s")
    done = subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
                           '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]', "--output", str(xml)],
                          capture_output=True, text=True, timeout=300)
    if done.returncode != 0 or not xml.exists():
        raise D.StepError(f"film_profile: export failed: {(done.stdout + done.stderr)[-400:]}; record: {log}")
    rows = _profile_rows(str(xml))
    with open(str(xml), errors="replace") as handle:
        head = handle.read(6000)  # the export's first rows, kept as evidence of its shape
    main = [(ns, frames) for name, ns, frames, _ in rows if "Main Thread" in name]
    # The raw main-thread samples (time from the trace start, weight, stack index), so the burst after each press can be
    # cut out offline: the trace's start date (TOC) and each press's wall time align them.
    table, index, raw = [], {}, []
    for name, ns, frames, at in rows:
        if "Main Thread" not in name:
            continue
        key = "\x1f".join(frames)
        if key not in index:
            index[key] = len(table)
            table.append(frames)
        raw.append([at, ns, index[key]])
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--toc"], capture_output=True, text=True,
                         timeout=120).stdout
    start_date = re.search(r"<start-date>([^<]+)</start-date>", toc or "")
    inclusive, own, stacks = {}, {}, {}
    for ns, frames in main:
        ms = ns / 1e6
        for name in set(frames):
            inclusive[name] = inclusive.get(name, 0.0) + ms
        if frames:
            own[frames[0]] = own.get(frames[0], 0.0) + ms
            key = " < ".join(frames[:12])
            stacks[key] = stacks.get(key, 0.0) + ms
    total = sum(ns for ns, _ in main) / 1e6
    trees = {root: call_tree(main, root) for root in TREE_ROOTS}
    top = lambda d, n: [[k, round(v, 2)] for k, v in sorted(d.items(), key=lambda kv: -kv[1])[:n]]
    profile = {"scenario": scenario, "kind": kind, "presses": presses, "rows": len(workspace_ids(j)),
               "main_ms": round(total, 2), "main_ms_per_press": round(total / max(1, presses), 2),
               "samples": len(main), "all_samples": len(rows), "inclusive": top(inclusive, 150), "self": top(own, 80),
               "stacks": top(stacks, 60), "frames": measures, "export_head": head, "trees": trees,
               "trace_start": start_date.group(1) if start_date else None, "toc_head": (toc or "")[:3000],
               "press_wall": sent_wall, "press_mono": sent, "samples_raw": raw, "stack_table": table,
               "motion_frames": sum(m.get("motion_frames", 0) for m in measures),
               "main_ms_per_motion_frame": round(total / max(1, sum(m.get("motion_frames", 0) for m in measures)), 2)}
    (j.out / f"profile-{scenario}.json").write_text(json.dumps(profile) + "\n")
    for path in (xml,):
        try:
            os.unlink(str(path))
        except OSError:
            pass
    subprocess.run(["rm", "-rf", str(trace)], timeout=60)
    return {k: profile[k] for k in ("scenario", "kind", "presses", "rows", "main_ms", "main_ms_per_press", "samples",
                                    "motion_frames", "main_ms_per_motion_frame")}


def cond_film_recorded(j, want, cache):
    film = _films(j).get(want.get("scenario"))
    if not film:
        return False, f"no film {want.get('scenario')!r}"
    got = sum(1 for p in film["presses"] if len(p["frames"]) >= 2)
    return got >= int(want.get("presses", 20)), f"{got} presses with frames; summary {json.dumps(film['summary'])[:600]}"


STEPS = {"film_grow": step_film_grow, "film_busy": step_film_busy, "film_presses": step_film_presses,
         "film_profile": step_film_profile}
CONDITIONS = {"film_recorded": ("app", cond_film_recorded)}
