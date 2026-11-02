"""TYPING UNDER LOAD (Lawrence P0, lead 2026-11-02 02:3xZ): background load profiles and the realistic typist.

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead. run.py packs tui-kit/ and typing/
beside the driver (kit/), so the load tool and the typist plan come from the same reviewed commit.

Steps (`do`):
  echo_start  {}   in the current terminal (smoke_adopt_line names it), runs typing/echo.py with its log in the
                   journey's out folder (OUT/echo.jsonl, fetched with the results) and waits for its ready line.
                   The typed keys then go to that program, which echoes them as a line editor does and logs each
                   PTY read with its time.
  load_start  {profile: L1..L6, seed?: 7, duration?: 300, keep: NAME, ready_timeout?: 180}
                   starts tui-kit/load_profiles.py run PROFILE --app-socket <the lease's socket> --home <its HOME>
                   --keep <the pane named NAME> --out OUT/load in the background, and waits for its
                   `LOAD-READY <L>` line. Its stdout (LOAD-RATE lines) goes to OUT/load/<L>.stdout. A tool that is
                   missing or ends before it is ready: not run (a kit gap, never a product red).
  load_stop   {}   SIGTERM to the load tool, waits up to 60 s for its teardown, records its exit and focus_changed.
  probe_relaunch {hang_ms?: 4}  reopens the app with the in-app per-key marks on (see the function).
  probe_mark  {as}  keeps debug.hangs and debug.wakeups as OUT/probe-<as>.json.
  typist_play {seed?: 7, seconds?: 120, from?: 0, to?, label?}
                   plays typing/typist.py's seeded plan with real HID keys (ext_realkey press: CuaDriver, desktop
                   scope) at the planned times: characters, Backspace, Left/Right, Ctrl-C, Return, and pastes
                   (the text goes to the pasteboard with pbcopy just before its Cmd-V). Each event's `t_post` and
                   `t_back` (time.monotonic, the frame clock) are in the result for keys_check.py and the video
                   judge. FROM/TO: only the plan's events with FROM <= t < TO (a 2-minute sample in two parts, one
                   movie each: the recorder records at most 120 s). Real keys only (key_path=real).
"""
import json
import os
import signal
import subprocess
import sys
import time

D = None


def install(driver):
    global D
    D = driver


def _kit():
    return os.path.dirname(os.path.abspath(__file__))


def _realkey():
    import ext_realkey
    return ext_realkey


def step_echo_start(j, step):
    log = j.out / "echo.jsonl"
    j.out.mkdir(parents=True, exist_ok=True)
    if log.exists():
        log.unlink()
    prog = os.path.join(_kit(), "typing", "echo.py")
    if not os.path.isfile(prog):
        raise D.NotRun(f"echo_start: the kit has no {prog}")
    line = f"clear; exec /usr/bin/python3 -I {prog} {log}"
    j.before_keys()
    for ch in line:
        _realkey().press_char(j, ch)
    _realkey().press(j, "return")
    end = D.now() + 20
    while D.now() < end:
        if log.exists() and '"ready"' in log.read_text():
            j.echo_log = log
            return {"log": str(log), "program": prog}
        time.sleep(0.1)
    raise D.StepError(f"echo_start: echo.py wrote no ready line to {log} within 20 s")


def step_load_start(j, step):
    profile = step["profile"]
    tool = os.path.join(_kit(), "tui-kit", "load_profiles.py")
    if not os.path.isfile(tool):
        raise D.NotRun(f"load_start: the kit has no {tool} (the load-profile owner's tool, STATUS 4629)")
    named = (getattr(j, "smoke_named", {}) or {}).get(step["keep"])
    if not named:
        raise D.StepError(f"load_start: no pane named {step['keep']!r} (smoke_adopt_line first)")
    out = j.out / "load"
    out.mkdir(parents=True, exist_ok=True)
    env = j.app.launch_env()
    home = env.get("HOME") or j.app.home
    argv = ["/usr/bin/python3", "-I", tool, "run", profile, "--app-socket", str(j.app.sock), "--home", str(home),
            "--seed", str(step.get("seed", 7)), "--duration", str(step.get("duration", 300)), "--out", str(out),
            "--keep", named["pane"]]
    stdout = open(out / f"{profile}.stdout", "w")
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=open(out / f"{profile}.stderr", "w"),
                            env=dict(os.environ, HOME=str(home)))
    j.load = {"proc": proc, "profile": profile, "out": out, "stdout": stdout}
    end = D.now() + float(step.get("ready_timeout", 180))
    ready, buf = None, b""
    import select
    fd = proc.stdout.fileno()
    # Raw reads of the pipe, split into lines here (a buffered readline could hide LOAD-READY: review 7).
    while D.now() < end and ready is None:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            chunk = os.read(fd, 65536)
            if not chunk:
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                stdout.write(buf.decode(errors="replace"))
                raise D.NotRun(f"load_start: {profile} ended (exit {proc.returncode}) before LOAD-READY: "
                               f"{buf.decode(errors='replace')[-300:]}")
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode(errors="replace")
                stdout.write(text + "\n")
                stdout.flush()
                if text.startswith(f"LOAD-READY {profile}"):
                    ready = text.strip()
    if ready is None:
        proc.send_signal(signal.SIGTERM)
        raise D.NotRun(f"load_start: no LOAD-READY {profile} within {step.get('ready_timeout', 180)} s")
    import threading

    def pump(rest=buf):
        stdout.write(rest.decode(errors="replace"))
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                return
            stdout.write(chunk.decode(errors="replace"))
            stdout.flush()
    threading.Thread(target=pump, daemon=True).start()
    return {"profile": profile, "ready": ready, "t_ready": round(D.now(), 4), "argv": argv[3:], "pid": proc.pid}


def step_load_stop(j, step):
    load = getattr(j, "load", None)
    if not load:
        return {"running": None}
    proc = load["proc"]
    alive = proc.poll() is None  # the load ran until now (a tool that died early is no load: review 3)
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
    j.load = None
    manifest = load["out"] / load["profile"] / "manifest.json"
    focus_changed = None
    try:
        focus_changed = json.loads(manifest.read_text()).get("focus_changed")
    except (OSError, ValueError):
        pass
    return {"profile": load["profile"], "exit": proc.returncode, "alive_at_stop": alive, "focus_changed": focus_changed,
            "manifest": str(manifest)}


def step_typist_play(j, step):
    if (j.spec.get("options") or {}).get("key_path") != "real":
        raise D.NotRun("typist_play: real keys only (journey option key_path=real)")
    sys.path.insert(0, os.path.join(_kit(), "typing"))
    import typist
    rect = getattr(j, "typing_rect", None) or {}
    cw = rect.get("cell_width")
    columns = int(rect["rect_points_top_left"][2] // cw) if cw else 80
    columns = min(columns, int(step.get("columns", 80)))
    events = typist.plan(int(step.get("seed", 7)), float(step.get("seconds", 120)), columns=columns)
    lo, hi = float(step.get("from", 0)), float(step.get("to", 1e9))
    events = [e for e in events if lo <= e["t"] < hi]
    if not events:
        raise D.StepError(f"typist_play: no event in [{lo}, {hi})")
    rk = _realkey()
    rk.require_front(j)
    j.before_keys()
    start = D.now() + 0.3 - lo
    played = []
    for e in events:
        if e["kind"] == "paste":
            subprocess.run(["/usr/bin/pbcopy"], input=e["text"], text=True, timeout=10)
        due = start + e["t"]
        left = due - D.now()
        if left > 0.004:
            time.sleep(left - 0.003)
        while D.now() < due:
            pass
        t_post = D.now()
        if e["kind"] == "char":
            rk.press_char(j, e["key"])
        else:
            rk.press(j, e["key"], e.get("mods") or [])
        t_back = D.now()
        played.append(dict(e, t_post=round(t_post, 6), t_back=round(t_back, 6), late_ms=round((t_post - due) * 1000, 2)))
    late = sorted(p["late_ms"] for p in played)
    calls = sorted(p["t_back"] - p["t_post"] for p in played)
    return {"label": step.get("label"), "events": played, "planned": len(events), "columns": columns,
            "wall_minus_mono": round(time.time() - time.monotonic(), 6),  # the hog log's clock is wall time
            "call_ms": {"p50": round(calls[len(calls) // 2] * 1000, 2), "max": round(calls[-1] * 1000, 2)}, "key_path": "real_hid", "start": round(start, 6),
            "post_late_ms": {"p50": late[len(late) // 2], "max": late[-1]},
            "clock": "time.monotonic (mach_absolute_time, the clock of frames.json t and of echo.py)"}


def step_probe_relaunch(j, step):
    """Quits the lease's app (Cmd-Q path of the driver's relaunch) and opens it again with the in-app per-key marks
    on: CMUX_NEXT_TYPING_PROBE=OUT/probe.csv (TypingLatencyProbe: one CSV row per key, ms after the key's
    NSEvent.timestamp: dispatch, io write, socket submit, output decoded/received/parsed, the echo's layer contents),
    CMUX_NEXT_TRACE_FLOWS=OUT/flows (the daemon's per-hop flow trace) and CMUX_NEXT_HANG_THRESHOLD_MS=4 (the main
    thread watchdog names every turn over 4 ms; debug.hangs). Every other launch variable is the lease's own."""
    out = j.out
    out.mkdir(parents=True, exist_ok=True)
    (out / "flows").mkdir(exist_ok=True)
    app = j.app
    env = app.launch_env()
    if not env.get("HOME"):
        raise D.NotRun(f"probe_relaunch: no launch variables read from pid {app.pid}")
    env.update({"CMUX_NEXT_TYPING_PROBE": str(out / "probe.csv"), "CMUX_NEXT_TRACE_FLOWS": str(out / "flows"),
                "CMUX_NEXT_HANG_THRESHOLD_MS": str(step.get("hang_ms", 4))})
    app.launch_env = lambda: dict(env)
    try:
        rec = j.step_relaunch({"how": "quit", "mark": step.get("mark")})
    finally:
        del app.launch_env
    return dict(rec, probe=str(out / "probe.csv"), flows=str(out / "flows"))


def step_probe_mark(j, step):
    """Keeps debug.hangs (every main-thread turn over the watchdog threshold, with its stack) and debug.wakeups (each
    process's cumulative CPU: app, daemon, terminal hosts, CEF) as OUT/probe-<as>.json; `as` names the moment
    (before, after). A build without the methods: recorded as missing, never a failure."""
    rec = {"t": round(D.now(), 6)}
    for method, params in (("debug.hangs", {"limit": 500}), ("debug.wakeups", {})):
        try:
            rec[method] = j.app.rpc(method, params, timeout=20)
        except (D.StepError, OSError, ValueError) as error:
            rec[method] = {"missing": str(error)[:200]}
    (j.out / f"probe-{step['as']}.json").write_text(json.dumps(rec))
    hangs = (rec.get("debug.hangs") or {}).get("records") if isinstance(rec.get("debug.hangs"), dict) else None
    return {"as": step["as"], "hangs": len(hangs) if isinstance(hangs, list) else None, "file": f"probe-{step['as']}.json"}


STEPS = {"probe_relaunch": step_probe_relaunch, "probe_mark": step_probe_mark, "echo_start": step_echo_start, "load_start": step_load_start, "load_stop": step_load_stop,
         "typist_play": step_typist_play}
CONDITIONS = {}
