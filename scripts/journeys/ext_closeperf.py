"""CLOSE PERF steps (task close-perf, cmux-ad m56 2026-11-07: "the way we close panes and resulting movement is not back,
how can we optimize this"). The cases are video-cases/gen_closeperf.py. Local kit only (never pushed).

driver.py loads this file (load_extensions) on the mini, under /usr/bin/python3 (3.9, standard library only).

Steps (`do`):
  cp_close {film, i, key?: "w", modifiers?: ["cmd"], rest?: 1.2}
      One timed close inside a running recording (video_start): debug.frames start (it clears), debug.motion start
      (spans, work per frame: ca.commit, presentation.frame, split.layout ...), debug.terminal_final_grid start, the real
      key (ext_video hid_key: the CuaDriver HID path; the time base is the app's own key-down, not the send), REST
      seconds, then debug.frames stop raw, debug.motion stop, debug.terminal_final_grid stop and debug.action_budget's
      newest runs. All of it goes to <video>/<film>.close<NN>.json (fetched with the movies); the input journal is kept.
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


def step_cp_close(j, step):
    film, i = step["film"], int(step["i"])
    key, mods = step.get("key", "w"), list(step.get("modifiers", ["cmd"]))
    rest = float(step.get("rest", 1.2))
    _rpc(j, "debug.frames", {"action": "start"})
    _rpc(j, "debug.motion", {"action": "start"})
    _rpc(j, "debug.terminal_final_grid", {"action": "start"})
    before = _rpc(j, "debug.action_budget", {"limit": 1})
    seq0 = None
    if isinstance(before, dict) and before.get("recent"):
        seq0 = before["recent"][-1].get("sequence")
    t_host0 = time.monotonic()
    pressed = V.step_hid_key(j, {"key": key, "modifiers": mods, "mark": f"close.{i}"})
    time.sleep(rest)
    frames = _rpc(j, "debug.frames", {"action": "stop", "raw": True})
    motion = _rpc(j, "debug.motion", {"action": "stop"})
    grid = _rpc(j, "debug.terminal_final_grid", {"action": "stop"})
    budget = _rpc(j, "debug.action_budget", {"limit": 24})
    runs = []
    if isinstance(budget, dict):
        runs = [r for r in budget.get("recent") or [] if seq0 is None or (r.get("sequence") or 0) > seq0]
    if getattr(j, "video", None) is not None:
        V.keep_journal(j)
    rec = {"film": film, "i": i, "key": key, "modifiers": mods, "t_driver_before": t_host0, "pressed": pressed,
           "host_offset_s": V._host_offset_s(), "frames": frames, "motion": motion, "grid": grid, "budget_runs": runs}
    path = V._vdir(j) / f"{film}.close{i:02d}.json"
    path.write_text(json.dumps(rec, default=str))
    main = frames.get("main_ms") if isinstance(frames, dict) else None
    return {"file": path.name, "runs": [(r.get("id"), r.get("commit_ms")) for r in runs][:4],
            "missed": frames.get("missed") if isinstance(frames, dict) else None,
            "main_max_ms": max(main) if main else None}


STEPS = {"cp_close": step_cp_close}
CONDITIONS = {}


if __name__ == "__main__":
    print(json.dumps(sorted(STEPS)))
