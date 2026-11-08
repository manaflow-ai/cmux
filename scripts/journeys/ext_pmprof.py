"""PIN MOTION profile (task pin-motion-4, step 3: "120 Hz: 1-2 missed refreshes per pin. Profile (xctrace, n >= 20
pins), name the work by file:line, cut it, and show 0 missed"). Kit branch pin-motion/kit-nomerge (never merged).

  pm_xctrace_pins {runs: 20, gap: 1.0, rest: 0.6, window_ms: 150, key: {key, modifiers}}
      RUNS real pin keys (ext_video hid_key, CuaDriver HID), alternately pin and unpin of the focused workspace, under
      ONE `xctrace record --template "Time Profiler" --all-processes` (ext_cmdn's recorder and reader). Around each key:
      debug.frames start/stop (missed refreshes, when, main ms per frame) and debug.action_budget (the key turn). Each
      press's main-thread samples go on their own clock from the first sample in the pin's handler or the sidebar's
      pin flight (_HANDLER), in 5 ms bins with the deepest frames of ours, plus the heaviest inclusive and self frames.
      Writes diag-pmprofile.json (with the raw samples); result.json keeps the summary.
"""
import json
import re
import time

D = None
C = None
V = None


def install(driver):
    global D, C, V
    D = driver
    import ext_cmdn
    import ext_video
    C = ext_cmdn
    V = ext_video


def _rpc(j, method, params):
    try:
        return j.app.rpc(method, params)
    except D.StepError as error:
        return {"error": str(error)[:300]}


def step_pm_xctrace_pins(j, step):
    import shutil
    import signal
    import subprocess
    import threading
    C._HANDLER = re.compile(r"WorkspaceMetadataHandlers|PinFlight|SidebarDragSpring|togglePin|WorkspacePin")
    runs, gap, rest = int(step.get("runs", 20)), float(step.get("gap", 1.0)), float(step.get("rest", 0.6))
    key = step.get("key") or {"key": "p", "modifiers": ["control", "option", "cmd"]}
    xcrun = shutil.which("xcrun") or "/usr/bin/xcrun"
    trace = j.out / "pins.trace"
    shutil.rmtree(trace, ignore_errors=True)
    log = []
    rec = subprocess.Popen([xcrun, "xctrace", "record", "--template", "Time Profiler", "--all-processes",
                            "--time-limit", f"{int(step.get('cap_seconds', 120))}s", "--output", str(trace), "--no-prompt"],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    started = threading.Event()

    def read():
        for line in rec.stdout:
            log.append(line.rstrip()[:200])
            if "Starting recording" in line or "Ctrl-C to stop" in line:
                started.set()
        started.set()
    threading.Thread(target=read, daemon=True).start()
    started.wait(float(step.get("start_timeout", 90)))
    if rec.poll() is not None:
        raise D.StepError(f"xctrace record ended: {log[-6:]}")
    time.sleep(1.0)
    presses = []
    for n in range(runs):
        _rpc(j, "debug.frames", {"action": "start"})
        before = _rpc(j, "debug.action_budget", {"limit": 1})
        seq0 = before["recent"][-1].get("sequence") if isinstance(before, dict) and before.get("recent") else None
        pressed = V.step_hid_key(j, {"key": key["key"], "modifiers": list(key.get("modifiers", [])), "mark": f"pmprof.{n}"})
        time.sleep(rest)
        frames = _rpc(j, "debug.frames", {"action": "stop"})
        budget = _rpc(j, "debug.action_budget", {"limit": 4})
        turns = [r for r in (budget.get("recent") or []) if seq0 is None or (r.get("sequence") or 0) > seq0] if isinstance(budget, dict) else []
        presses.append({"n": n, "pressed": pressed, "turns": [(r.get("id"), r.get("commit_ms")) for r in turns],
                        "missed": frames.get("missed") if isinstance(frames, dict) else None,
                        "missed_frames": frames.get("missed_frames") if isinstance(frames, dict) else None,
                        "main_ms_head": (frames.get("main_ms") or [])[:12] if isinstance(frames, dict) else None,
                        "view_layouts_head": (frames.get("view_layouts_per_frame") or [])[:12] if isinstance(frames, dict) else None,
                        "refresh_ms": frames.get("refresh_ms") if isinstance(frames, dict) else None})
        time.sleep(max(0.0, gap - rest))
    rec.send_signal(signal.SIGINT)
    try:
        rec.wait(timeout=float(step.get("save_timeout", 150)))
    except subprocess.TimeoutExpired:
        rec.kill()
        log.append("xctrace save timed out")
    result = {"bench": "xctrace-pin", "runs": runs, "log": log[-8:], "presses": presses,
              "missed_total": sum(p["missed"] or 0 for p in presses),
              "missed_per_press": [p["missed"] for p in presses]}
    xml = j.out / "pin-profile.xml"
    done = subprocess.run([xcrun, "xctrace", "export", "--input", str(trace), "--output", str(xml), "--xpath",
                           '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                          capture_output=True, text=True, timeout=float(step.get("export_timeout", 150)))
    if done.returncode != 0:
        result["error"] = f"export exit {done.returncode}: {(done.stderr or done.stdout)[-300:]}"
    else:
        replies = [{} for _ in presses]
        result.update(C.xctrace_press_profiles(xml, j.app.pid, replies, float(step.get("window_ms", 150)), int(step.get("top", 50))))
        # Over every press: the heaviest inclusive frames of ours in the window (what to cut first).
        total = {}
        for row in result.get("rows") or []:
            for phase in (row.get("phases") or {}).values():
                for ms, name in phase.get("incl") or []:
                    total[name] = total.get(name, 0.0) + ms
        result["incl_all"] = [[round(v, 1), k] for k, v in sorted(total.items(), key=lambda kv: -kv[1])[:80]]
    xml.unlink(missing_ok=True)
    shutil.rmtree(trace, ignore_errors=True)
    (j.out / "diag-pmprofile.json").write_text(json.dumps(result))
    for row in result.get("rows") or []:
        row.pop("raw", None)
    # The whole summary goes in result.json (the run folder comes back; diag files on the mini may not).
    return result


STEPS = {"pm_xctrace_pins": step_pm_xctrace_pins}
