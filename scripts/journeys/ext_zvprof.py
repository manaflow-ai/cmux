"""ZOOM VARIANTS profile (lead 04:2xZ: Z4's key turn is 11-25 ms against V0's 1-1.4 ms; name where it goes). Local kit
branch zoom-variants/kit-prof-nomerge only.

  zv_xctrace_zooms {label, runs: 10, gap: 1.0, window_ms: 40, top: 40}
      RUNS Cmd-Shift-Enter presses (REAL HID keys, ext_video.step_hid_key: zoom in, out, in, ...) on the focused pane
      under ONE `xctrace record --template "Time Profiler" --all-processes` (ext_cmdn's recorder and reader). Each
      press's main-thread samples go on its own clock by the first sample inside the zoom handler (toggleSplitZoom,
      filmZoomNow), in 5 ms bins with the deepest frames of ours, plus the heaviest inclusive and self frames over the
      window. Writes diag-zoomprofile-<label>.json.
"""
import json
import re
import shutil
import signal
import subprocess
import threading
import time

D = None
C = None
V = None


def install(driver):
    global D, C, V
    D = driver
    import ext_cmdn
    import ext_video
    C, V = ext_cmdn, ext_video


def step_zv_xctrace_zooms(j, step):
    label = step.get("label", "z4")
    # ZOOM VARIANTS 5: on feat the handler is under one sample; a journey names a frame every press runs.
    C._HANDLER = re.compile(step.get("handler", r"toggleSplitZoom|filmZoomNow|PaneHandlers.bindSizing"))
    runs, gap = int(step.get("runs", 10)), float(step.get("gap", 1.0))
    xcrun = shutil.which("xcrun") or "/usr/bin/xcrun"
    trace = j.out / f"zooms-{label}.trace"
    shutil.rmtree(trace, ignore_errors=True)
    log = []
    rec = subprocess.Popen([xcrun, "xctrace", "record", "--template", "Time Profiler", "--all-processes",
                            "--time-limit", f"{int(step.get('cap_seconds', 60))}s", "--output", str(trace), "--no-prompt"],
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
    replies = []
    for i in range(runs):
        V.step_hid_key(j, {"key": "return", "modifiers": ["cmd", "shift"], "mark": f"zoomprof.{label}.{i}"})
        replies.append({})
        time.sleep(gap)
    if runs % 2:  # leave the pane unzoomed
        V.step_hid_key(j, {"key": "return", "modifiers": ["cmd", "shift"], "mark": f"zoomprof.{label}.back"})
        time.sleep(gap)
    rec.send_signal(signal.SIGINT)
    try:
        rec.wait(timeout=float(step.get("save_timeout", 150)))
    except subprocess.TimeoutExpired:
        rec.kill()
        log.append("xctrace save timed out")
    result = {"bench": "xctrace-zoom", "label": label, "log": log[-8:]}
    xml = j.out / f"zoom-profile-{label}.xml"
    done = subprocess.run([xcrun, "xctrace", "export", "--input", str(trace), "--output", str(xml), "--xpath",
                           '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                          capture_output=True, text=True, timeout=float(step.get("export_timeout", 150)))
    if done.returncode != 0:
        result["error"] = f"export exit {done.returncode}: {(done.stderr or done.stdout)[-300:]}"
    else:
        result.update(C.xctrace_press_profiles(xml, j.app.pid, replies, float(step.get("window_ms", 40)), int(step.get("top", 40))))
    xml.unlink(missing_ok=True)
    shutil.rmtree(trace, ignore_errors=True)
    (j.out / f"diag-zoomprofile-{label}.json").write_text(json.dumps(result))  # with the raw samples
    keep = float(step.get("keep_raw_ms", 0))
    for row in result.get("rows") or []:
        raw = row.pop("raw", None)
        if keep and raw:  # ZOOM VARIANTS 3: the key turn's own samples (0 .. keep ms), for turn-only attribution
            samples = [x for x in raw.get("samples") or [] if -1 <= x[0] <= keep]
            used = sorted({i for x in samples for i in x[2]})
            remap = {old: new for new, old in enumerate(used)}
            row["turn_raw"] = {"names": [raw["names"][i] for i in used],
                               "samples": [[x[0], x[1], [remap[i] for i in x[2]]] for x in samples]}
    return result


def _budget_seq(j):
    reply = j.app.rpc("debug.action_budget", {"limit": 1}) or {}
    recent = reply.get("recent") or []
    return recent[-1].get("sequence") if recent else None


def _pct(v, p):
    v = sorted(v)
    return round(v[min(len(v) - 1, int(round((len(v) - 1) * p)))], 2) if v else None


def step_zv_turn_zooms(j, step):
    """ZOOM VARIANTS 3: RUNS real Cmd-Shift-Enter presses with NO profiler; each press's key turn to its commit
    (debug.action_budget commit_ms, ActionBudgetMonitor), p50/p95/max, in and out apart. Writes diag-zoomturn-<label>.json."""
    label = step.get("label", "z4")
    runs, gap = int(step.get("runs", 12)), float(step.get("gap", 1.0))
    seq0 = _budget_seq(j)
    spans = []
    for i in range(runs):
        traced = bool(step.get("spans", True))
        if traced:
            j.app.rpc("debug.motion", {"action": "start"})
        V.step_hid_key(j, {"key": "return", "modifiers": ["cmd", "shift"], "mark": f"zoomturn.{label}.{i}"})
        time.sleep(gap)
        if traced:
            motion = j.app.rpc("debug.motion", {"action": "stop"}) or {}
            spans.append([s for s in motion.get("spans") or [] if str(s.get("name", "")).startswith("zk.") or s.get("name") == "layout"])
    if runs % 2:
        V.step_hid_key(j, {"key": "return", "modifiers": ["cmd", "shift"], "mark": f"zoomturn.{label}.back"})
        time.sleep(gap)
    reply = j.app.rpc("debug.action_budget", {"limit": 256}) or {}
    rows = [r for r in reply.get("recent") or [] if seq0 is None or (r.get("sequence") or 0) > seq0]
    zoom = [r for r in rows if "zoom" in str(r.get("id") or r.get("action") or "").lower()] or rows
    ms = [float(r.get("commit_ms")) for r in zoom if r.get("commit_ms") is not None]
    ins, outs = ms[0::2], ms[1::2]
    result = {"bench": "zoom-turn", "label": label, "n": len(ms), "ids": sorted({str(r.get("id")) for r in zoom}),
              "commit_ms": ms, "p50": _pct(ms, .5), "p95": _pct(ms, .95), "max": max(ms) if ms else None,
              "in_p50": _pct(ins, .5), "in_p95": _pct(ins, .95), "out_p50": _pct(outs, .5), "out_p95": _pct(outs, .95),
              "rows": zoom, "spans": spans}
    cpu = []  # ZOOM VARIANTS 5: the worst display frame's main-thread CPU per press (the daemon-echo turn included)
    for i in range(int(step.get("cpu_runs", 0))):
        j.app.rpc("debug.main_cpu", {"action": "start"})
        V.step_hid_key(j, {"key": "return", "modifiers": ["cmd", "shift"], "mark": f"zoomcpu.{label}.{i}"})
        time.sleep(gap)
        cpu.append(j.app.rpc("debug.main_cpu", {"action": "stop"}) or {})
    if int(step.get("cpu_runs", 0)) % 2:
        V.step_hid_key(j, {"key": "return", "modifiers": ["cmd", "shift"], "mark": f"zoomcpu.{label}.back"})
        time.sleep(gap)
    if cpu:
        mx = [float(c.get("main_ms_max") or 0) for c in cpu]
        result.update(cpu_frame_max_ms=mx, cpu_in_p50=_pct(mx[0::2], .5), cpu_in_p95=_pct(mx[0::2], .95),
                      cpu_out_p50=_pct(mx[1::2], .5), cpu_out_p95=_pct(mx[1::2], .95),
                      cpu_over_8_33=[c.get("main_over_8_33_ms") for c in cpu])
    (j.out / f"diag-zoomturn-{label}.json").write_text(json.dumps(result, default=str))
    result.pop("rows", None)
    return result


STEPS = {"zv_xctrace_zooms": step_zv_xctrace_zooms, "zv_turn_zooms": step_zv_turn_zooms}
CONDITIONS = {}
