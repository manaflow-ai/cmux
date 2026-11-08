"""PIN MOTION steps (task pin-motion, cmux-ad m70 2026-11-08: "animation when i pin stuff and unpin stuff is not very
good. like it needs to translate properly from its original position to new position"). The cases are
video-cases/gen_pinmotion.py. Kit branch pin-motion/kit-nomerge (never merged).

driver.py loads this file (load_extensions) on the mini, under /usr/bin/python3 (3.9, standard library only).

Steps (`do`):
  pm_keys {film, i, keys: [{key, modifiers, gap?: seconds before this key}], rest?: 1.2, probe?: "sidebar"}
      Timed pin/unpin keys inside a running recording (video_start): debug.frames start, debug.motion start, the
      sidebar's per-frame probe (debug.sidebar_rows motion start: each row's presented frame, opacity and view
      identity per display frame), then each REAL key (ext_video hid_key, CuaDriver HID) GAP seconds after the one
      before, REST seconds, then the recorders stop and debug.action_budget's newest runs. All of it goes to
      <video>/<film>.close<NN>.json (the kit fetches *.closeNN.json with the movies), keys "frames", "motion",
      "budget_runs", "sidebar" (probe report) and "rows_before" / "rows_after" (debug.sidebar_rows).
"""
import json
import time

D = None
V = None  # ext_video: hid_key, the video folder, keep_journal


def install(driver):
    global D, V
    D = driver
    import ext_video
    V = ext_video


def _rpc(j, method, params):
    try:
        return j.app.rpc(method, params)
    except D.StepError as error:
        return {"error": str(error)[:300]}


def step_pm_keys(j, step):
    film, i = step["film"], int(step["i"])
    probe = step.get("probe", "sidebar")
    rows_before = _rpc(j, "debug.sidebar_rows", {})
    _rpc(j, "debug.frames", {"action": "start"})
    _rpc(j, "debug.motion", {"action": "start"})
    if probe == "sidebar":
        _rpc(j, "debug.sidebar_rows", {"motion": "start"})
    before = _rpc(j, "debug.action_budget", {"limit": 1})
    seq0 = before["recent"][-1].get("sequence") if isinstance(before, dict) and before.get("recent") else None
    t_host0 = time.monotonic()
    pressed = []
    for n, k in enumerate(step["keys"]):
        if n and float(k.get("gap", 0)) > 0:
            time.sleep(float(k["gap"]))
        pressed.append(V.step_hid_key(j, {"key": k["key"], "modifiers": list(k.get("modifiers", [])), "mark": f"pin.{i}.{n}"}))
    time.sleep(float(step.get("rest", 1.2)))
    sidebar = _rpc(j, "debug.sidebar_rows", {"motion": "stop"}) if probe == "sidebar" else None
    frames = _rpc(j, "debug.frames", {"action": "stop", "raw": True})
    motion = _rpc(j, "debug.motion", {"action": "stop"})
    budget = _rpc(j, "debug.action_budget", {"limit": 24})
    rows_after = _rpc(j, "debug.sidebar_rows", {})
    runs = []
    if isinstance(budget, dict):
        runs = [r for r in budget.get("recent") or [] if seq0 is None or (r.get("sequence") or 0) > seq0]
    if getattr(j, "video", None) is not None:
        V.keep_journal(j)
    rec = {"film": film, "i": i, "keys": step["keys"], "t_driver_before": t_host0, "pressed": pressed,
           "host_offset_s": V._host_offset_s(), "frames": frames, "motion": motion, "budget_runs": runs,
           "sidebar": sidebar, "rows_before": rows_before, "rows_after": rows_after}
    path = V._vdir(j) / f"{film}.close{i:02d}.json"
    path.write_text(json.dumps(rec, default=str))
    return {"file": path.name, "runs": [(r.get("id"), r.get("commit_ms")) for r in runs][:6],
            "missed": frames.get("missed") if isinstance(frames, dict) else None,
            "probe_frames": len((sidebar or {}).get("frames") or []) if isinstance(sidebar, dict) else None}


STEPS = {"pm_keys": step_pm_keys}
