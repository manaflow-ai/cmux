"""CLOSE PERF steps (task close-perf, cmux-ad m56 2026-11-07: "the way we close panes and resulting movement is not back,
how can we optimize this"). The cases are video-cases/gen_closeperf.py. Local kit only (never pushed).

driver.py loads this file (load_extensions) on the mini, under /usr/bin/python3 (3.9, standard library only).

Steps (`do`):
  cp_close {film, i, key?: "w", modifiers?: ["cmd"], rest?: 1.2, repeat_after?: [seconds, ...]}
      One timed close inside a running recording (video_start): debug.frames start (it clears), debug.motion start
      (spans, work per frame: ca.commit, presentation.frame, split.layout ...), debug.terminal_final_grid start, the real
      key (ext_video hid_key: the CuaDriver HID path; the time base is the app's own key-down, not the send), REST
      seconds, then debug.frames stop raw, debug.motion stop, debug.terminal_final_grid stop and debug.action_budget's
      newest runs. All of it goes to <video>/<film>.close<NN>.json (fetched with the movies); the input journal is kept.
      REPEAT_AFTER presses the same key again after each gap, inside the same record (fast closes, RQ3).
  cp_click_close {film, i, pane, rest?: 1.4}
      The same record for a mouse close of named pane PANE (not focused): debug.mouse hover over its tab's x (the x of
      a tab shows on hover only), a check that the strip shows the x (debug.surfaces close_shown), then one REAL click
      (CuaDriver, desktop scope) on it. The time base is the app's own mouse-down. The click is checked after the
      recorders stop (the app's input journal has the mouse-down at the point; the pane is gone).
"""
import json
import time

D = None
V = None  # ext_video: hid_key, the video folder, keep_journal
R = None  # ext_realkey: CuaDriver session, window frame, input journal
W = None  # ext_window: named panes


def install(driver):
    global D, V, R, W
    D = driver
    import ext_realkey
    import ext_video
    import ext_window
    V, R, W = ext_video, ext_realkey, ext_window


def _rpc(j, method, params):
    try:
        return j.app.rpc(method, params)
    except D.StepError as error:
        return {"error": str(error)[:300]}


def _start(j):
    _rpc(j, "debug.frames", {"action": "start"})
    _rpc(j, "debug.motion", {"action": "start"})
    _rpc(j, "debug.terminal_final_grid", {"action": "start"})
    before = _rpc(j, "debug.action_budget", {"limit": 1})
    if isinstance(before, dict) and before.get("recent"):
        return before["recent"][-1].get("sequence")
    return None


def _stop(j, film, i, seq0, t_host0, pressed, extra):
    frames = _rpc(j, "debug.frames", {"action": "stop", "raw": True})
    motion = _rpc(j, "debug.motion", {"action": "stop"})
    grid = _rpc(j, "debug.terminal_final_grid", {"action": "stop"})
    budget = _rpc(j, "debug.action_budget", {"limit": 24})
    runs = []
    if isinstance(budget, dict):
        runs = [r for r in budget.get("recent") or [] if seq0 is None or (r.get("sequence") or 0) > seq0]
    if getattr(j, "video", None) is not None:
        V.keep_journal(j)
    rec = {"film": film, "i": i, **extra, "t_driver_before": t_host0, "pressed": pressed,
           "host_offset_s": V._host_offset_s(), "frames": frames, "motion": motion, "grid": grid, "budget_runs": runs}
    path = V._vdir(j) / f"{film}.close{i:02d}.json"
    path.write_text(json.dumps(rec, default=str))
    main = frames.get("main_ms") if isinstance(frames, dict) else None
    return {"file": path.name, "runs": [(r.get("id"), r.get("commit_ms")) for r in runs][:4],
            "missed": frames.get("missed") if isinstance(frames, dict) else None,
            "main_max_ms": max(main) if main else None}


def step_cp_close(j, step):
    film, i = step["film"], int(step["i"])
    key, mods = step.get("key", "w"), list(step.get("modifiers", ["cmd"]))
    seq0 = _start(j)
    t_host0 = time.monotonic()
    pressed = V.step_hid_key(j, {"key": key, "modifiers": mods, "mark": f"close.{i}"})
    rest, more = float(step.get("rest", 1.2)), []
    for k, gap in enumerate(step.get("repeat_after") or []):  # RQ3: more presses of the key inside this one record
        time.sleep(float(gap))
        rest -= float(gap)
        more.append(V.step_hid_key(j, {"key": key, "modifiers": mods, "mark": f"close.{i}.{k + 1}"}))
    time.sleep(max(0.0, rest))
    return _stop(j, film, i, seq0, t_host0, pressed, {"key": key, "modifiers": mods, "repeats": more})


def _close_point(j, pane):
    """The center of PANE's only tab's x, window points from the top-left: the pill's trailing edge less the content
    trailing inset and half the x (TabCell.layoutParts; TabTunables contentTrailingInset 4, closeButtonSize 16)."""
    for w in (j.app.rpc("debug.pane_chrome") or {}).get("windows") or []:
        for p in w.get("panes") or []:
            if isinstance(p, dict) and p.get("pane") == pane and p.get("pill"):
                x, y, width, height = p["pill"]
                return (x + width - 4 - 8, y + height / 2), p
    raise D.StepError(f"cp_click_close: debug.pane_chrome has no tab pill for pane {pane}")


def _screen_args(j, point):
    win = R._layers_window(j)
    if not win or not win.get("primary_max_y"):
        raise D.NotRun("cp_click_close: no main window frame on the primary display (debug.layers)")
    wx, wy, ww, wh = win["frame"]
    bad, size, raw = R._session(j).call("get_screen_size", {})
    scale = float((size or {}).get("scale_factor") or 1.0)
    sx, sy = wx + point[0], win["primary_max_y"] - (wy + wh) + point[1]
    return {"scope": "desktop", "x": round(sx * scale), "y": round(sy * scale)}


def step_cp_click_close(j, step):
    film, i = step["film"], int(step["i"])
    rec = W.named(j, step["pane"])
    pane = rec["pane"]
    row = W.pane_row(j, pane) or {}
    if row.get("focused"):
        raise D.StepError(f"cp_click_close: pane {step['pane']} is focused; the film needs an unfocused pane")
    R.require_front(j)
    point, chrome = _close_point(j, pane)
    hover = _rpc(j, "debug.mouse", {"action": "hover", "x": point[0], "y": point[1]})
    time.sleep(0.3)
    shown = ((W.pane_row(j, pane) or {}).get("strip") or {}).get("close_shown")
    if not shown:
        raise D.NotRun(f"cp_click_close: the x of pane {pane} does not show after a hover at {list(point)}: "
                       f"{json.dumps(hover)[:200]} pill {chrome.get('pill')}")
    args = _screen_args(j, point)
    seq_before = R._journal_last_seq(j)
    seq0 = _start(j)
    t_host0 = time.monotonic()
    sent = D.now()
    bad, data, raw = R._session(j).call("click", args)
    returned = D.now()
    V._hid_log(j, "click", {**args, "window_point": list(point)}, sent, returned, {"bad": bad, "effect": data.get("effect")})
    time.sleep(float(step.get("rest", 1.4)))
    out = _stop(j, film, i, seq0, t_host0, {"sent": round(sent, 6), "returned": round(returned, 6)},
                {"click": list(point), "pane": pane, "close_shown": shown, "pixels": [args["x"], args["y"]]})
    if bad or data.get("effect") in ("refused", "failed", "error"):
        raise D.NotRun(f"cp_click_close: CuaDriver did not click: {json.dumps(raw)[:300]}")
    landed = R._journal_mouse_down(j, seq_before, getattr(j, "key_window", None))
    if landed is None:
        raise D.NotRun("cp_click_close: the app's input journal has no mouse-down after the click")
    if max(abs(float(landed.get("x", 1e9)) - point[0]), abs(float(landed.get("y", 1e9)) - point[1])) > 4:
        raise D.NotRun(f"cp_click_close: the click reached cmux at ({landed.get('x')}, {landed.get('y')}), not {list(point)}")
    if W.pane_row(j, pane):
        raise D.StepError(f"cp_click_close: pane {pane} is still open after the click on its x at {list(point)}")
    return dict(out, mouse_down=landed, point=list(point))


STEPS = {"cp_close": step_cp_close, "cp_click_close": step_cp_click_close}
CONDITIONS = {}


if __name__ == "__main__":
    print(json.dumps(sorted(STEPS)))
