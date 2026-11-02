"""Video capture of the real app for the resize-videos kit (handoff resize-videos/KIT.md).

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (standard library only).
It must not import driver.py: install() gets the driver module. It uses ext_realkey's CuaDriver session (real HID
input through the window server, the path a person's mouse and keyboard take) and the app's own recorder:
`debug.motion` `record_*` (every frame the window server composites for the app's main window, ScreenCaptureKit at
the display's rate, no Screen Recording grant) and `debug.motion` `trace_*` (each pane host's and divider's frame
on every display frame). Both exist in DEBUG and bench builds that have perf/debug-screen-record (#31504).

Every file of one recording goes to <journey out>/video/<name>.*:
  <name>.mov              the movie (HEVC by default), one movie frame per complete ScreenCaptureKit frame,
                          presentation time = display time - the first frame's display time
  <name>.mov.frames.json  {"frames": [[t, status, in_movie], ...]}: every frame ScreenCaptureKit gave, t its display
                          time in host seconds (mach_absolute_time, the clock of time.monotonic() on macOS and of
                          CACurrentMediaTime), status complete | idle (nothing changed) | blank | ...
  <name>.mov.scan         exact BGRA scanlines per complete frame (KIT.md: format)
  <name>.trace.json       debug.motion trace_stop: t0_s (host s of the first sample), samples [{t ms since t0_s,
                          window [w, h], panes [[id, x, y, w, h, alpha, z, fx, fy, fw, fh, cw, ch, header, cx, cy,
                          cw, ch]], dividers [[id, x, y, w, h, alpha, z]], zoom}] in window points, top-left origin
  <name>.events.json      {"hid": [every HID action: kind, args, t_sent, t_returned (host s)], "journal": the app's
                          input journal entries after the start}
  <name>.meta.json        the record_start reply (frame size, scale, rows, columns), the counts at the end, the
                          window frame and screen (debug.layers), the app pid, the clock note

Steps (`do`):
  video_start  {name, rows?, columns?, codec?: hevc|prores, mbps?, seconds?: 30, require_hz?: 120}
               require_hz: a pacing case; not run unless the app's display link runs at that rate
  video_stop   {name, tail?: 0.6}  waits `tail` s (the motion's end), stops, waits for the files (30 s)
  hid_drag     {target, by: [dx, dy] | to: [x, y], duration_ms, steps?, hold_ms?: 0, mark?}
               a REAL drag (CuaDriver `drag`, desktop scope, true pixels) from the target's center. target:
               {"divider": k} (the k-th vertical divider from the left, from the running trace), {"row_divider": k}
               (the k-th horizontal one from the top), {"window_point": [x, y]}, or {"window_edge": left|right|top|
               bottom|top-left|top-right|bottom-left|bottom-right} (2 points inside that edge or corner).
               steps default: one move per 8 ms (a 120 Hz mouse).
  hid_click    {target, count?: 1, modifiers?, mark?}   a real click (double-click: count 2) at the target
  hid_key      {key, modifiers?, mark?}                  a real key (CuaDriver hotkey / press_key, foreground)
  layout_note  {as}  keeps the current trace sample (panes, dividers) in the result as `as` (for a judge's
                     declared end state)
"""
import json
import os
import time

D = None
R = None  # ext_realkey: the CuaDriver session and the window placement


# cmux-ad 01:30Z (hard rule): CuaDriver is INPUT ONLY. Its screen recorder wedges the shared daemon and opens a
# "bypass the system private window picker" dialog per start; the only recorders are the app's own debug.motion
# record_* and the lease's 120 Hz virtual-display capture.
CUA_RECORD_TOOLS = ("start_recording", "stop_recording", "record_screen", "screen_record")
# Words of the CuaDriver consent dialog; a window with them on screen makes the round SMOKE ENV (not a result).
BYPASS_WORDS = ("bypass the system private window picker", "requesting to bypass")


def install(driver):
    global D, R
    D = driver
    import ext_realkey  # beside this file; load_extensions imported it already
    R = ext_realkey
    _guard_session_calls()


def _guard_session_calls():
    """Refuses any CuaDriver screen-recording call made through ext_realkey's session (KIT.md, hard rule)."""
    session = R._Session
    if getattr(session, "_video_guarded", False):
        return
    original = session.call

    def call(self, tool, args):
        if tool in CUA_RECORD_TOOLS:
            raise D.StepError(f"CuaDriver is input only (cmux-ad 01:30Z): {tool} refused; record with debug.motion record_*")
        return original(self, tool, args)

    session.call = call
    session._video_guarded = True


def _bypass_dialog(j):
    """Whether a CuaDriver consent dialog is on screen (its window list names it): the round is SMOKE ENV then."""
    try:
        bad, data, raw = R._session(j).call("list_windows", {})
    except D.NotRun:
        return None
    rows = data.get("windows") or []
    hits = [w for w in rows if any(word in json.dumps(w).lower() for word in BYPASS_WORDS)
            or ("cuadriver" in json.dumps(w).lower() and int(w.get("layer", 0) or 0) > 0)]
    return [{k: w.get(k) for k in ("app_name", "owner_name", "title", "name", "layer", "pid")} for w in hits][:4]


def _vdir(j):
    path = j.out / "video"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _motion(j, action, **params):
    reply = j.app.rpc("debug.motion", {"action": action, **params}) or {}
    if isinstance(reply, dict) and reply.get("error"):
        raise D.StepError(f"debug.motion {action}: {reply['error']}")
    return reply


def _hid_log(j, kind, args, sent, returned, answer=None):
    rec = getattr(j, "video", None)
    if rec is not None:
        rec["hid"].append({"kind": kind, "args": args, "t_sent": round(sent, 6), "t_returned": round(returned, 6),
                           "answer": answer})


def step_video_start(j, step):
    name = step["name"]
    if getattr(j, "video", None):
        raise D.StepError(f"video_start {name}: {j.video['name']} is still recording")
    path = _vdir(j) / f"{name}.mov"
    params = {"path": str(path), "window": 0, "seconds": float(step.get("seconds", 30))}
    for key in ("rows", "columns", "codec", "mbps"):
        if key in step:
            params[key] = step[key]
    seq = R._journal_last_seq(j)
    trace = _motion(j, "trace_start", window=0)
    started = _motion(j, "record_start", **params)
    if not started.get("starting"):
        _motion(j, "trace_stop")
        raise D.NotRun(f"video_start {name}: the recorder did not start: {json.dumps(started)[:300]}")
    end = time.monotonic() + 8
    counts = {}
    while time.monotonic() < end:
        counts = _motion(j, "record_read")
        if counts.get("capturing") or counts.get("error"):
            break
        time.sleep(0.05)
    if not counts.get("capturing"):
        _motion(j, "record_stop")
        _motion(j, "trace_stop")
        raise D.NotRun(f"video_start {name}: ScreenCaptureKit did not start: {json.dumps(counts)[:300]}")
    dialog = _bypass_dialog(j)
    j.video = {"name": name, "t_start": D.now(), "hid": [], "journal_seq": seq, "start": started, "bypass_dialog": dialog,
               "trace_views": trace.get("views"), "notes": {}}
    # The first frames show the layout at rest: the judge's reference.
    time.sleep(float(step.get("lead", 0.4)))
    # The refresh the app's display link runs at on the window's screen (the recording precondition, KIT.md): a
    # pacing case (`require_hz`) does not record at another rate; a geometry case records it.
    refresh = float(_motion(j, "trace_read").get("refresh_ms") or 0)
    j.video["refresh_ms"] = refresh
    want = step.get("require_hz")
    if want and abs(refresh - 1000.0 / float(want)) > 0.35:
        _motion(j, "record_stop")
        _motion(j, "trace_stop")
        j.video = None
        raise D.NotRun(f"video_start {name}: the window's display runs at {refresh} ms a frame, not {want} Hz")
    return {"path": str(path), "start": started, "trace_views": trace.get("views"), "refresh_ms": refresh}


def step_video_stop(j, step):
    rec = getattr(j, "video", None)
    if not rec or rec["name"] != step["name"]:
        raise D.StepError(f"video_stop {step['name']}: not recording it")
    time.sleep(float(step.get("tail", 0.6)))
    _motion(j, "record_stop")
    trace = _motion(j, "trace_stop")
    end = time.monotonic() + 30
    counts = {}
    while time.monotonic() < end:
        counts = _motion(j, "record_read")
        if counts.get("written"):
            break
        time.sleep(0.1)
    j.video = None
    base = _vdir(j) / rec["name"]
    (base.parent / f"{rec['name']}.trace.json").write_text(json.dumps(trace))
    entries = [e for e in R._journal_entries(j, 400) if int(e.get("seq") or 0) > int(rec["journal_seq"])]
    (base.parent / f"{rec['name']}.events.json").write_text(json.dumps({"hid": rec["hid"], "journal": entries}))
    layers = R._layers_window(j)
    meta = {"name": rec["name"], "start": rec["start"], "counts": counts, "window": layers, "pid": j.app.pid,
            "t_start": rec["t_start"], "t_stop": D.now(), "notes": rec["notes"], "trace_views": rec["trace_views"],
            "refresh_ms": rec.get("refresh_ms"), "display": _display_facts(),
            "bypass_dialog": {"start": rec.get("bypass_dialog"), "stop": _bypass_dialog(j)},
            "smoke_env": bool(rec.get("bypass_dialog") or _bypass_dialog(j)),
            "clock": "host seconds: mach_absolute_time (time.monotonic, CACurrentMediaTime, ScreenCaptureKit display time)"}
    (base.parent / f"{rec['name']}.meta.json").write_text(json.dumps(meta))
    if not counts.get("written"):
        raise D.StepError(f"video_stop {rec['name']}: the movie was not written within 30 s: {json.dumps(counts)[:300]}")
    return {"counts": counts, "samples": len(trace.get("samples") or []), "hid": len(rec["hid"]), "journal": len(entries)}


def _display_facts():
    """What the lease's display check measured (run.py --vdisplay writes vd.out beside the kit), if any."""
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(os.path.dirname(here), "vd.out")) as f:
            return f.read().strip()[-300:]
    except OSError:
        return None


def _latest_sample(j):
    samples = (_motion(j, "trace_read").get("samples") or [])
    return samples[-1] if samples else {}


def _target_point(j, target):
    """A point in the main window's points from its top-left."""
    if "window_point" in target:
        return tuple(float(v) for v in target["window_point"])
    if "window_edge" in target:
        win = R._layers_window(j)
        if not win:
            raise D.NotRun("hid target: debug.layers has no main window frame")
        _, _, w, h = win["frame"]
        edge, inset = target["window_edge"], float(target.get("inset", 2))
        x = {"left": inset, "right": w - inset}.get(edge.split("-")[-1] if "-" in edge else edge, w / 2)
        y = {"top": inset, "bottom": h - inset}.get(edge.split("-")[0] if "-" in edge else edge, h / 2)
        return (x, y)
    sample = _latest_sample(j)
    dividers = [d for d in sample.get("dividers") or [] if isinstance(d, list) and len(d) >= 5]
    if "divider" in target:
        vertical = sorted((d for d in dividers if d[4] > d[3]), key=lambda d: d[1])
        index = int(target["divider"])
        if index >= len(vertical):
            raise D.StepError(f"hid target: no vertical divider {index} ({len(vertical)} shown): {dividers}")
        d = vertical[index]
        return (d[1] + d[3] / 2, d[2] + d[4] / 2)
    if "row_divider" in target:
        horizontal = sorted((d for d in dividers if d[3] >= d[4]), key=lambda d: d[2])
        index = int(target["row_divider"])
        if index >= len(horizontal):
            raise D.StepError(f"hid target: no horizontal divider {index} ({len(horizontal)} shown): {dividers}")
        d = horizontal[index]
        return (d[1] + d[3] / 2, d[2] + d[4] / 2)
    raise D.StepError(f"hid target: unknown {target}")


def _desktop_pixels(j, point):
    """Window points from the top-left to CuaDriver's desktop pixels (the primary display's top-left), as real_click."""
    win = R._layers_window(j)
    if not win or not win.get("primary_max_y"):
        raise D.NotRun("hid: the main window is not on the primary display (debug.layers)")
    bad, size, raw = R._session(j).call("get_screen_size", {})
    scale = float((size or {}).get("scale_factor") or 1.0)
    wx, wy, ww, wh = win["frame"]
    sx, sy = wx + point[0], win["primary_max_y"] - (wy + wh) + point[1]
    return (round(sx * scale), round(sy * scale)), scale


def _cua_tools(j):
    """CuaDriver's tool list with input schemas (once per journey): the drag tool's arguments differ by version."""
    cached = getattr(j, "cua_tools", None)
    if cached is None:
        tools = R._session(j).request("tools/list", {})
        cached = j.cua_tools = {t.get("name"): t.get("inputSchema") for t in (tools.get("tools") or []) if isinstance(t, dict)}
    return cached


def _mouse_events_since(j, seq):
    """The app's input-journal mouse entries after SEQ: [(phase, x, y)] (what the app received, window points)."""
    out = []
    for e in R._journal_entries(j, 400):
        if int(e.get("seq") or 0) <= seq:
            continue
        kind = e.get("kind") or {}
        mouse = kind.get("mouse")
        mouse = (mouse or {}).get("_0", mouse) if isinstance(mouse, dict) else None
        if isinstance(mouse, dict):
            out.append((mouse.get("phase"), mouse.get("x"), mouse.get("y")))
    return out


def _drag_args(j, mode, start, end, duration, steps):
    """CuaDriver drag arguments. `desktop`: true screen pixels from the primary display's top-left. `window`: the
    app's main window by id, window-local screenshot pixels (points x the screen scale)."""
    if mode == "desktop":
        (fx, fy), scale = _desktop_pixels(j, start)
        (tx, ty), _ = _desktop_pixels(j, end)
        return {"scope": "desktop", "from_x": fx, "from_y": fy, "to_x": tx, "to_y": ty, "duration_ms": duration,
                "steps": steps}, scale
    bad, size, raw = R._session(j).call("get_screen_size", {})
    scale = float((size or {}).get("scale_factor") or 1.0)
    return {"pid": j.app.pid, "window_id": R._main_window(j), "delivery_mode": "foreground",
            "from_x": round(start[0] * scale), "from_y": round(start[1] * scale), "to_x": round(end[0] * scale),
            "to_y": round(end[1] * scale), "duration_ms": duration, "steps": steps}, scale


def step_hid_drag(j, step):
    """A real drag. The mode that reaches the app is found once per journey (`desktop` first, then `window`) and
    proven by the app's own input journal: a mouse-down and moves after the call. No mode that reaches it: not run."""
    R.require_front(j)
    start = _target_point(j, step["target"])
    if "to" in step:
        end = tuple(float(v) for v in step["to"])
    else:
        dx, dy = (float(v) for v in step["by"])
        end = (start[0] + dx, start[1] + dy)
    duration = int(step["duration_ms"])
    steps = int(step.get("steps", max(2, duration // 8)))
    modes = [getattr(j, "hid_drag_mode", None)] if getattr(j, "hid_drag_mode", None) else ["desktop", "window"]
    tried = []
    for mode in modes:
        args, scale = _drag_args(j, mode, start, end, duration, steps)
        if step.get("hold_ms"):
            args["hold_ms"] = int(step["hold_ms"])
        if step.get("modifiers"):
            args["modifier"] = [R.MODIFIERS.get(m, m) for m in step["modifiers"]]
        seq = R._journal_last_seq(j)
        if step.get("mark"):
            j.marks[step["mark"]] = D.now()
        sent = D.now()
        bad, data, raw = R._session(j).call("drag", args)
        returned = D.now()
        time.sleep(0.15)
        got = _mouse_events_since(j, seq)
        downs = sum(1 for e in got if e[0] == "down")
        _hid_log(j, "drag", {**args, "mode": mode, "window_from": list(start), "window_to": list(end)}, sent, returned,
                 {"bad": bad, "effect": data.get("effect"), "app_mouse_events": len(got), "app_downs": downs})
        tried.append({"mode": mode, "effect": data.get("effect"), "bad": bad, "app_mouse_events": len(got),
                      "app_downs": downs, "first": got[:2], "last": got[-2:]})
        if downs and not bad:
            j.hid_drag_mode = mode
            return {"mode": mode, "from": list(start), "to": list(end), "args": args, "scale": scale,
                    "duration_ms": duration, "steps": steps, "sent": round(sent, 6), "returned": round(returned, 6),
                    "drag_s": round(returned - sent, 4), "app_mouse_events": len(got), "first": got[:2], "last": got[-2:]}
    raise D.NotRun(f"hid_drag: no CuaDriver drag reached the app (its journal has no mouse-down): {json.dumps(tried)[:700]}; "
                   f"drag schema: {json.dumps(_cua_tools(j).get('drag'))[:600]}")


def step_hid_probe(j, step):
    """Records CuaDriver's tools and their argument schemas (no input)."""
    tools = _cua_tools(j)
    return {"tools": sorted(t for t in tools if t), "drag": tools.get("drag"), "click": tools.get("click")}


def step_hid_click(j, step):
    R.require_front(j)
    point = _target_point(j, step["target"])
    (x, y), scale = _desktop_pixels(j, point)
    args = {"scope": "desktop", "x": x, "y": y}
    if int(step.get("count", 1)) != 1:
        args["count"] = int(step["count"])
    if step.get("modifiers"):
        args["modifier"] = [R.MODIFIERS.get(m, m) for m in step["modifiers"]]
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    sent = D.now()
    bad, data, raw = R._session(j).call("click", args)
    returned = D.now()
    _hid_log(j, "click", {**args, "window_point": list(point)}, sent, returned, {"bad": bad, "effect": data.get("effect")})
    if bad or data.get("effect") in ("refused", "failed", "error"):
        raise D.NotRun(f"hid_click: CuaDriver did not click: {json.dumps(raw)[:400]}")
    return {"point": list(point), "pixels": [x, y], "sent": round(sent, 6), "returned": round(returned, 6)}


def step_hid_key(j, step):
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    sent = D.now()
    answer = R.press(j, step["key"], step.get("modifiers", []))
    returned = D.now()
    _hid_log(j, "key", {"key": step["key"], "modifiers": step.get("modifiers", [])}, sent, returned, answer)
    return {"sent": round(sent, 6), "returned": round(returned, 6), "answer": answer}


def step_layout_note(j, step):
    sample = _latest_sample(j)
    note = {"panes": sample.get("panes"), "dividers": sample.get("dividers"), "window": sample.get("window")}
    if getattr(j, "video", None):
        j.video["notes"][step["as"]] = note
    return note


def step_video_count(j, step):
    """The running recording's counts now, kept in its meta notes under `as` (which change made frames come)."""
    counts = _motion(j, "record_read")
    if getattr(j, "video", None):
        j.video["notes"][step["as"]] = {"t": D.now(), "counts": counts}
    return counts


def step_sck_probe(j, step):
    """Builds sck_probe.swift on the mini (once), runs it as an app in the GUI session (`open`), and returns its
    JSON line: whether ScreenCaptureKit delivers own-window frames on this host, per kind of change."""
    import subprocess
    here = os.path.dirname(os.path.abspath(__file__))
    work = os.path.join(os.path.dirname(here), "sckprobe")
    exe_dir = os.path.join(work, "SCKProbe.app", "Contents", "MacOS")
    os.makedirs(exe_dir, exist_ok=True)
    built = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", os.path.join(here, "sck_probe.swift"),
                            "-o", os.path.join(exe_dir, "SCKProbe")], capture_output=True, text=True, timeout=300)
    if built.returncode:
        raise D.StepError(f"sck_probe: build failed: {built.stderr[-600:]}")
    with open(os.path.join(work, "SCKProbe.app", "Contents", "Info.plist"), "w") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key>'
                '<string>SCKProbe</string><key>CFBundleIdentifier</key><string>ai.manaflow.resize-videos.sckprobe</string>'
                '<key>CFBundlePackageType</key><string>APPL</string></dict></plist>')
    subprocess.run(["codesign", "-s", "-", "--force", os.path.join(work, "SCKProbe.app")], capture_output=True, timeout=60)
    out = os.path.join(work, "probe.out")
    if os.path.exists(out):
        os.remove(out)
    seconds = str(step.get("seconds", 9))
    subprocess.run(["open", "-W", "--stdout", out, "--stderr", out + ".err", os.path.join(work, "SCKProbe.app"),
                    "--args", seconds], capture_output=True, timeout=float(seconds) + 60)
    text = open(out).read() if os.path.exists(out) else ""
    line = next((l for l in reversed(text.splitlines()) if l.startswith("{")), None)
    if not line:
        err = open(out + ".err").read()[-400:] if os.path.exists(out + ".err") else ""
        raise D.StepError(f"sck_probe: no result: {text[-300:]} {err}")
    return json.loads(line)


STEPS = {"video_count": step_video_count, "sck_probe": step_sck_probe, "video_start": step_video_start, "video_stop": step_video_stop, "hid_drag": step_hid_drag, "hid_probe": step_hid_probe,
         "hid_click": step_hid_click, "hid_key": step_hid_key, "layout_note": step_layout_note}
