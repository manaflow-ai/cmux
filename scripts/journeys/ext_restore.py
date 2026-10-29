"""Restart-restore steps and conditions for the journeys (group restart-restore).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (standard library
only). It must not import driver.py: install() gets the driver module instead.

Lawrence 2026-10-27 (handoff/restore-perf.md): cmux NIGHTLY relaunched with ~60 workspaces showed three visible
terminals as empty panes with a cursor box and "Restoring..." for seconds. The binding targets, Chrome's session
restore: the visible terminals show their last content in the first frame, never an empty pane; no "Restoring..."
pill unless the attach is missing after 1 s, and then over the last content; live within 300 ms p95 warm and 1 s
cold; hidden workspaces attach on first show.

Steps (`do`):
  seed_workspaces   {count, prefix?}       set-up, not under test: COUNT more workspaces of one terminal each,
                                           made through the daemon (`cmux workspace create`), each printing
                                           one line; the current terminal's workspace is shown again after
  close_seeded      {prefix}               clean-up: closes the workspaces seed_workspaces made
  require_drawable  {timeout?}             `not run` (with the window server's order) while the app's window is
                                           occluded on the shared capture host: frame checks cannot judge it
  restore_diagnose  {}                     evidence (a `finally` step): debug.surfaces/input/timings/windows,
                                           a window snapshot and a 3 s sample of the app, as diag-* files
  restore_relaunch  {how?, mark?}          the driver's `relaunch` (Cmd-Q, reopen through LaunchServices), with
                                           the visible panes sampled from the new process's first socket answer
                                           (`debug.surfaces`, about every 25 ms) until every visible terminal
                                           is live or 20 s pass; the launch marks are read at the end
                                           (`debug.timings`). The conditions below judge that record.

Conditions (inside `expect.all`; evidence kind app):
  restore_no_blank  {pill_over_blank?: 0}  every sample showed each visible terminal pane with content (its
                                           held last frame or its replayed screen), never an empty surface;
                                           and the last frame was up by the first window frame
                                           (`terminal.launch_frame_shown` <= `first_window_frame_committed`,
                                           or the first frame already drew live content); a "Restoring..."
                                           pill was never over an empty pane
  restore_live      {within_ms}            every visible terminal pane was live (attach live, link connected,
                                           its screen replayed) within WITHIN_MS of the app's `main_start` (the
                                           process start is in the detail: before main_start a capture slot's
                                           clone can wait 2-3 s on amfid, a cost of the slot's ad-hoc signature)
  restore_hidden_lazy {max}                the app attached at most MAX terminal views when restore settled
                                           (`debug.surfaces` live_terminals): hidden workspaces do not attach
"""
import ctypes
import json
import threading
import time

D = None  # the driver module (install)


def install(driver):
    global D
    D = driver


def step_seed_workspaces(journey, step):
    count = int(step["count"])
    prefix = journey.sub(step.get("prefix", "jr-bg"))
    made = 0
    for index in range(1, count + 1):
        ws = journey.app.cmux("workspace", "create", "--name", f"{prefix}-{index}")
        term = ws.get("terminal_id") if isinstance(ws, dict) else None
        if term:
            journey.app.cmux("terminal", term, "write", "--text", f"echo {prefix}-{index}-{journey.nonce}\n")
            made += 1
    # The journey's own workspace is the shown one again (as a person left it before the quit).
    place = journey.place_of(journey.need_term())
    if not place:
        raise D.StepError("seed_workspaces: the current terminal is in no workspace")
    journey.app.cmux("workspace", place[0].get("id"), "focus")
    journey.app.cmux("pane", place[1].get("id"), "focus")
    return {"made": made, "of": count, "workspace": place[0].get("name")}


class _Sampler(threading.Thread):
    """Samples the visible panes of the relaunched app (any pid but `old`) until each visible terminal is live."""

    def __init__(self, app, old, seconds=20.0):
        super().__init__(daemon=True)
        self.app, self.old, self.seconds = app, old, seconds
        self.stop = threading.Event()
        self.samples, self.pid, self.first_answer = [], None, None

    def run(self):
        end = D.now() + 90
        while not self.stop.is_set() and D.now() < end:
            try:
                info = self.app.rpc("system.identify", timeout=1)
                if isinstance(info, dict) and info.get("pid") and int(info["pid"]) != self.old:
                    self.pid, self.first_answer = int(info["pid"]), time.time()
                    break
            except (D.StepError, OSError, ValueError):
                pass
            time.sleep(0.005)
        if not self.pid:
            return
        end = D.now() + self.seconds
        while not self.stop.is_set() and D.now() < end:
            t = time.time()  # wall: the kernel's process start is on it
            try:
                report = self.app.rpc("debug.surfaces", {"text": True}, timeout=5) or {}
            except (D.StepError, OSError, ValueError):
                time.sleep(0.02)
                continue
            panes = [p for w in report.get("windows", []) for p in w.get("panes", []) if isinstance(p, dict) and p.get("visible")]
            rows = []
            for p in panes:
                surface = p.get("surface") or {}
                replayed = bool(surface.get("replay_applied"))
                held = bool(p.get("frame_held"))
                rows.append({"pane": p.get("pane"), "kind": p.get("kind"), "held": held, "replayed": replayed,
                             "text": bool((p.get("text") or "").strip()), "link": p.get("link"), "attach": p.get("attach"),
                             "status": p.get("status_text")})
            self.samples.append({"t": t, "panes": rows})
            terms = [r for r in rows if r["kind"] == "terminal"]
            if terms and all(r["attach"] == "live" and r["link"] == "connected" and r["replayed"] for r in terms):
                break
            time.sleep(0.02)


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32), ("pbi_xstatus", ctypes.c_uint32),
                ("pbi_pid", ctypes.c_uint32), ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
                ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32), ("pbi_rgid", ctypes.c_uint32),
                ("pbi_svuid", ctypes.c_uint32), ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
                ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32), ("pbi_nfiles", ctypes.c_uint32),
                ("pbi_pgid", ctypes.c_uint32), ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
                ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32), ("pbi_start_tvsec", ctypes.c_uint64),
                ("pbi_start_tvusec", ctypes.c_uint64)]


def _process_start(pid):
    """Wall-clock seconds when the kernel started `pid` (PROC_PIDTBSDINFO, as the app's own launch clock), or None."""
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    except OSError:
        return None
    info = _ProcBSDInfo()
    if libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        return None
    return info.pbi_start_tvsec + info.pbi_start_tvusec / 1e6


def step_restore_relaunch(journey, step):
    sampler = _Sampler(journey.app, journey.app.pid)
    sampler.start()
    try:
        record = journey.step_relaunch(step)
    finally:
        sampler.join(timeout=30)
        sampler.stop.set()
    try:
        timings = journey.app.rpc("debug.timings", timeout=10) or {}
    except (D.StepError, OSError, ValueError):
        timings = {}
    marks = timings.get("launch_ms_since_process_start") or {}
    try:
        settled = journey.app.rpc("debug.surfaces", timeout=10) or {}
    except (D.StepError, OSError, ValueError):
        settled = {}
    # Every time is ms since the process start (the launch marks' zero); the samples carry wall time, the clock
    # the kernel's start time is on.
    zero = sampler.first_answer
    start = _process_start(sampler.pid) if sampler.pid else None
    first_live = {}
    blank, pill_over_blank = 0, 0
    for sample in sampler.samples:
        for row in sample["panes"]:
            if row["kind"] != "terminal":
                continue
            content = row["held"] or (row["replayed"] and row["text"])
            if not content:
                blank += 1
                if "Restoring" in (row["status"] or ""):
                    pill_over_blank += 1
            if row["attach"] == "live" and row["link"] == "connected" and row["replayed"] and row["pane"] not in first_live:
                first_live[row["pane"]] = sample["t"]
    live_ms = {pane: round((t - start) * 1000, 1) for pane, t in first_live.items()} if start else {}
    # The time before `main_start` is the system's (dyld, and in a capture slot amfid checking the clone's ad-hoc
    # signed frameworks: 2-3 s in about half the launches, 2026-10-27, cmux17 log `amfid ... Sparkle.framework not
    # valid`), not the app's: `live` is judged from the app's own start, and the process start is kept beside it.
    main_start = marks.get("main_start")
    live_app_ms = {pane: round(ms - main_start, 1) for pane, ms in live_ms.items()} if main_start is not None else {}
    journey.restore = {
        "samples": len(sampler.samples), "blank_pane_samples": blank, "pill_over_blank": pill_over_blank,
        "first_window_frame_committed": marks.get("first_window_frame_committed"),
        "launch_frame_shown": marks.get("terminal.launch_frame_shown"),
        "first_terminal_frame": marks.get("first_terminal_frame"),
        "sidebar_rows_shown": marks.get("sidebar_rows_shown"),
        "live_ms": live_ms, "main_start": main_start, "live_from_main_ms": live_app_ms, "visible_terminals": len({r["pane"] for s in sampler.samples for r in s["panes"] if r["kind"] == "terminal"}),
        "live_terminals": settled.get("live_terminals"),
        "socket_ms": round((zero - start) * 1000, 1) if zero and start else None,
        "trace": [[round((s["t"] - start) * 1000, 1) if start else None,
                   [[r["pane"], int(r["held"]), int(r["replayed"]), r["link"], r["attach"], r["status"]] for r in s["panes"]]]
                  for s in sampler.samples[:400]],
    }
    record["restore"] = {k: v for k, v in journey.restore.items() if k != "trace"}
    (journey.out / "restore-trace.json").write_text(json.dumps(journey.restore, indent=1) + "\n")
    return record


def step_close_seeded(journey, step):
    """Clean-up: closes every workspace whose name starts with PREFIX (the seeded ones), so the next journey's
    app restores no extra workspaces."""
    prefix = journey.sub(step.get("prefix", "jr-bg"))
    closed = 0
    for ws in journey.topology().get("workspaces", []):
        if (ws.get("name") or "").startswith(prefix):
            journey.app.cmux("workspace", ws.get("id"), "close")
            closed += 1
    return {"closed": closed}


# Front to back: one line per on-screen window at layer 0 (owner, pid, x, y, w, h).
WINDOW_ORDER_JXA = """
ObjC.import('CoreGraphics');
const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
list.filter(w => w.kCGWindowLayer === 0).map(w => [w.kCGWindowOwnerName, w.kCGWindowOwnerPID, w.kCGWindowBounds.X,
  w.kCGWindowBounds.Y, w.kCGWindowBounds.Width, w.kCGWindowBounds.Height].join(' ')).join('\\n');
"""


def step_restore_diagnose(journey, step):
    """Evidence of what the window draws now, whatever the journey's result (a `finally` step): the full
    `debug.surfaces` (each pane's frame hold, surface, drawing, layers and render counters), `debug.input`, a
    window snapshot, the launch marks, and a 3 s `sample` of the app process. For the case seen once on the
    nightly (2026-10-28, run 1): the app's text and link were live but the window showed all 3 panes empty."""
    out = journey.out
    saved = {}
    for name, method, params in (("surfaces", "debug.surfaces", {"text": True}), ("input", "debug.input", {}),
                                 ("timings", "debug.timings", {}), ("windows", "debug.windows", {})):
        try:
            value = journey.app.rpc(method, params, timeout=30)
        except (D.StepError, OSError, ValueError) as error:
            value = {"error": str(error)[-300:]}
        (out / f"diag-{name}.json").write_text(json.dumps(value, indent=1, default=str) + "\n")
        saved[name] = True
    try:
        journey.app.snapshot(out / "diag-window.png")
        saved["window"] = True
    except (D.StepError, OSError, ValueError) as error:
        saved["window"] = str(error)[-200:]
    # The window server's on-screen windows, front to back (owner, pid, layer, bounds): whether another app's
    # window covers ours, which AppKit then reports occluded and the terminals stop drawing (by design).
    order = D.subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", WINDOW_ORDER_JXA],
                             capture_output=True, text=True, timeout=60)
    (out / "diag-order.txt").write_text(order.stdout + order.stderr)
    done = D.subprocess.run(["/usr/bin/sample", str(journey.app.pid), "3", "-mayDie", "-file", str(out / "diag-app-sample.txt")],
                            capture_output=True, text=True, timeout=60)
    saved["sample"] = done.returncode == 0
    return saved


def step_require_drawable(journey, step):
    """Frame checks judge what a person sees only in a window on screen. A capture mini's GUI login is shared by
    its slots and keeps other apps' windows (another slot's cmux, Safari, Terminal); `open -g` can reopen our
    window fully behind them. AppKit then reports it occluded and the terminals stop drawing by design, so the
    window's own snapshot shows its panes empty though the text and the link are live (proven 6 of 6 on cmux17,
    2026-10-28). Such a run is `not run`, with the window server's order as evidence, never a pass or a fail."""
    end = D.now() + float(step.get("timeout", 5))
    while True:
        panes = [p for p in journey.app.panes() if p.get("visible") and p.get("kind", "terminal") == "terminal"]
        covered = [p.get("pane") for p in panes if p.get("window_occluded")]
        if not covered:
            return {"panes": len(panes), "occluded": 0}
        if D.now() >= end:
            break
        time.sleep(0.25)
    order = D.subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", WINDOW_ORDER_JXA],
                             capture_output=True, text=True, timeout=60)
    (journey.out / "diag-order.txt").write_text(order.stdout + order.stderr)
    front = [line for line in order.stdout.splitlines() if f" {journey.app.pid} " not in line][:6]
    raise D.NotRun(f"the app's window is covered on the shared capture host (AppKit occluded, {len(covered)} visible "
                   f"terminal pane(s) paused); in front of it: {front}")


def _restore(journey):
    record = getattr(journey, "restore", None)
    if record is None:
        raise D.StepError("no restore_relaunch before this check")
    return record


def cond_restore_no_blank(journey, want, cache):
    r = _restore(journey)
    first_frame, shown, live = r["first_window_frame_committed"], r["launch_frame_shown"], r["first_terminal_frame"]
    in_first_frame = first_frame is not None and (
        (shown is not None and shown <= first_frame + 0.5) or (live is not None and live <= first_frame + 0.5))
    limit = int((want or {}).get("pill_over_blank", 0)) if isinstance(want, dict) else 0
    ok = r["samples"] > 0 and r["blank_pane_samples"] == 0 and r["pill_over_blank"] <= limit and in_first_frame
    return ok, {"samples": r["samples"], "blank_pane_samples": r["blank_pane_samples"],
                "pill_over_blank": r["pill_over_blank"], "first_window_frame_committed": first_frame,
                "launch_frame_shown": shown, "first_terminal_frame": live, "last_content_in_first_frame": in_first_frame}


def cond_restore_live(journey, want, cache):
    r = _restore(journey)
    within = float(want["within_ms"] if isinstance(want, dict) else want)
    live = r["live_from_main_ms"]
    worst = max(live.values()) if live else None
    ok = bool(live) and len(live) >= r["visible_terminals"] and worst <= within
    return ok, {"live_from_main_ms": live, "worst_ms": worst, "within_ms": within, "main_start": r["main_start"],
                "live_from_process_start_ms": r["live_ms"], "visible_terminals": r["visible_terminals"]}


def cond_restore_hidden_lazy(journey, want, cache):
    r = _restore(journey)
    most = int(want["max"] if isinstance(want, dict) else want)
    got = r["live_terminals"]
    return got is not None and got <= most, {"live_terminals": got, "max": most}


STEPS = {"seed_workspaces": step_seed_workspaces, "restore_relaunch": step_restore_relaunch,
         "close_seeded": step_close_seeded, "restore_diagnose": step_restore_diagnose,
         "require_drawable": step_require_drawable}
CONDITIONS = {"restore_no_blank": ("app", cond_restore_no_blank), "restore_live": ("app", cond_restore_live),
              "restore_hidden_lazy": ("app", cond_restore_hidden_lazy)}
