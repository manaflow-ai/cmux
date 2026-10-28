#!/usr/bin/env python3
"""SCRATCH (measure refs only, never lands): Cmd-N held and Cmd-W held in the sidebar, base and head in ONE fleet step on
one host, optimized bench build (split-spring.sh --config=bench builds the head; this builds the base the same way).

Per side and round: 60 workspaces exist (the list is taller than the viewport); then newTab (Cmd-N) every 33 ms for 2 s,
settle, then closeWorkspace (Cmd-W) every 33 ms for 2 s, settle. Measured per gesture:
  empty_slot_frames  display frames (the sidebar motion probe, one sample per frame, presented values) in which a
                     workspace row new to the gesture holds a slot at least half its height with presented opacity
                     under 0.15: the gap shows, its content does not
  missed             display frames the main thread missed (debug.frames), frame p50/p95/p99/max ms
  main_ms_p95/max    the main thread's work per display-link tick (debug.motion work.clock)
Round 1 of each side also records the window (debug.window_record, one JPEG per display frame) for the clips.

    split-spring.sh --suite=sidebar-burst-ab --config=bench --vdisplay=120 --base-ref=SHA [--ab-rounds=3]
"""
import json, os, re, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, cwd=HERE).stdout.strip()
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402


def flag(name, default=None):
    for arg in sys.argv[1:]:
        if arg.startswith(name + "="):
            return arg.split("=", 1)[1]
    return default


named, raw = {}, sys.argv[1:]
for i, arg in enumerate(raw):
    if arg in ("--app", "--out", "--json", "--tag") and i + 1 < len(raw):
        named[arg] = raw[i + 1]
head_app, out = named["--app"], named["--out"]
base_ref, rounds, config = flag("--base-ref"), int(flag("--ab-rounds", "3")), flag("--config", "bench")
os.makedirs(out, exist_ok=True)
log = open(os.path.join(out, "ab.log"), "a")


def say(text):
    print(text, flush=True)
    log.write(text + "\n")
    log.flush()


def build_base():
    src = os.path.join(out, "base-src")
    if not os.path.isdir(src):
        if subprocess.run(["git", "cat-file", "-e", base_ref + "^{commit}"], cwd=ROOT).returncode:
            subprocess.run(["git", "fetch", "--no-tags", "origin", base_ref], cwd=ROOT, check=True)
        subprocess.run(["git", "worktree", "add", "--detach", src, base_ref], cwd=ROOT, check=True)
    for sub in ("ghostty", "ghostty-next"):
        if not os.path.exists(os.path.join(src, sub, ".git")):
            subprocess.run(["git", "submodule", "update", "--init", "--depth", "1", sub], cwd=src, check=True)
    kit = os.path.join(src, "GhosttyKit.xcframework")
    if not os.path.exists(os.path.join(kit, "Info.plist")):
        same = subprocess.run(["git", "rev-parse", "HEAD:ghostty"], capture_output=True, text=True, cwd=src).stdout == \
            subprocess.run(["git", "rev-parse", "HEAD:ghostty"], capture_output=True, text=True, cwd=ROOT).stdout
        if same and os.path.exists(os.path.join(ROOT, "GhosttyKit.xcframework", "Info.plist")):
            subprocess.run(["ditto", os.path.join(ROOT, "GhosttyKit.xcframework"), kit], check=True)
        else:
            subprocess.run(["./scripts/download-prebuilt-ghosttykit.sh"], cwd=src, check=True)
    reload_log = os.path.join(out, "base-reload.log")
    done = threading.Event()

    def beat():  # the controller stops a measurement whose log is silent for 45 min
        while not done.wait(60):
            size = os.path.getsize(reload_log) if os.path.exists(reload_log) else 0
            say(f"sidebar-burst-ab: building the base app ({size} bytes of reload log)")
    threading.Thread(target=beat, daemon=True).start()
    with open(reload_log, "w") as handle:
        code = subprocess.run(["./scripts/reload.sh", "--tag", "burstbase", "--config", config], cwd=src,
                              env=dict(os.environ, CMUX_DEV_BACKEND_MODE="local"), stdout=handle, stderr=subprocess.STDOUT).returncode
    done.set()
    text = open(reload_log, errors="replace").read()
    match = re.findall(r"^App path:\s*\n\s*(.+)$", text, re.M)
    app = match[-1].strip() if match else ""
    if code or not app or not os.path.isdir(app):
        say("sidebar-burst-ab: the base build failed:\n" + "\n".join(l for l in text.splitlines() if "error" in l)[-4000:])
        sys.exit(1)
    return app


def empty_slot_frames(motion, new_keys):
    """Frames where a new workspace row shows its slot (>= half its rest height) at presented opacity < 0.15."""
    frames = motion.get("frames") or []
    heights = {}
    for frame in frames:  # rest height: the largest presented height a new row reaches
        for key, rect in (frame.get("views") or {}).items():
            if key in new_keys:
                heights[key] = max(heights.get(key, 0), (rect or [0, 0, 0, 0])[3] if isinstance(rect, list) else rect.get("height", 0))
    empty = 0
    for frame in frames:
        views, opacity = frame.get("views") or {}, frame.get("opacity") or {}
        for key in new_keys:
            rect = views.get(key)
            if rect is None or key not in heights or heights[key] <= 0:
                continue
            height = rect[3] if isinstance(rect, list) else rect.get("height", 0)
            alpha = rect[4] if isinstance(rect, list) and len(rect) > 4 else float(opacity.get(key, 1))
            if height >= 0.5 * heights[key] and alpha < 0.15:
                empty += 1
                break
    return empty, len(frames)


def gesture(bench, label, verb, seconds, record_dir):
    rpc = bench.rpc
    before = {r["key"] for r in ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []}
    if record_dir:
        rpc("debug.window_record", {"dir": record_dir, "seconds": seconds + 1.5})
    rpc("debug.sidebar_rows", {"motion": "start"})
    rpc("debug.motion", {"action": "start"})
    rpc("debug.frames", {"action": "start"})
    start, presses = time.time(), 0
    while time.time() - start < seconds:
        delay = start + presses * 0.033 - time.time()
        if delay > 0:
            time.sleep(delay)  # test harness: key-repeat spacing (33 ms)
        rpc("action.run", {"action": verb, "arguments": {"confirm": "true"} if verb == "closeWorkspace" else {}}, timeout=10)
        presses += 1
    time.sleep(1.5)  # test harness: the last opens and closes land
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    work = ((rpc("debug.motion", {"action": "stop"}) or {}).get("work") or {}).get("clock") or {}
    probe = rpc("debug.sidebar_rows", {"motion": "stop"}) or {}
    after = {r["key"] for r in ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []}
    new = {k for k in after - before if str(k).startswith("workspace(")}
    empty, sampled = empty_slot_frames(probe, new) if verb == "newTab" else (None, len(probe.get("frames") or []))
    result = {"label": label, "presses": presses, "new_rows": len(new), "empty_slot_frames": empty, "probe_frames": sampled,
              "missed": frames.get("missed"), "frames_p50_ms": frames.get("p50_ms"), "frames_p95_ms": frames.get("p95_ms"),
              "frames_p99_ms": frames.get("p99_ms"), "frames_max_ms": frames.get("max_ms"), "refresh_ms": frames.get("refresh_ms"),
              "main_ms_p50": work.get("p50_ms"), "main_ms_p95": work.get("p95_ms"), "main_ms_max": work.get("max_ms")}
    say("  " + json.dumps(result))
    if record_dir:
        time.sleep(1.0)  # test harness: the recording stops by itself
    return result


def side(app, tag, label, r):
    bench = BenchApp(app, out=os.path.join(out, f"{label}-r{r}"), config={}, env={"CMUX_NEXT_NO_ACTIVATE": None},
                     window=(80, 80, 1400, 900), log_name=f"app-{tag}.log")
    try:
        bench.launch(timeout=180)
    except LaunchError as error:
        say(f"{label}: launch failed: {error}")
        return [{"label": label, "error": str(error)}]
    try:
        time.sleep(4)  # test harness: launch work settles
        for _ in range(60):
            bench.rpc("action.run", {"action": "newTab", "arguments": {}}, timeout=10)
        time.sleep(4)  # test harness: the 60 creates confirm
        record = os.path.join(out, "frames") if r == 1 else None
        results = [gesture(bench, f"{label} cmd-n", "newTab", 2.0, record and os.path.join(record, f"{label}-cmd-n")),
                   gesture(bench, f"{label} cmd-w", "closeWorkspace", 2.0, record and os.path.join(record, f"{label}-cmd-w"))]
        return results
    finally:
        bench.stop()


say(f"sidebar-burst-ab: base {base_ref}, head {head_app}, {rounds} rounds, config {config}")
base_app = build_base()
host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
report = {"bench": "sidebar-burst-ab.py (Cmd-N / Cmd-W held at 33 ms, 60 workspaces)", "host": host, "config": config,
          "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
          "base_ref": base_ref, "runs": []}
for r in range(1, rounds + 1):
    for label, app, tag in (("base", base_app, "burstbase"), ("head", head_app, named.get("--tag", "split-spring"))):
        say(f"=== round {r} {label}")
        report["runs"] += [dict(x, round=r) for x in side(app, tag, label, r)]
        json.dump(report, open(named.get("--json") or os.path.join(out, "report.json"), "w"), indent=1)
if subprocess.run(["which", "ffmpeg"], capture_output=True).returncode == 0:
    for clip in sorted(os.listdir(os.path.join(out, "frames"))) if os.path.isdir(os.path.join(out, "frames")) else []:
        folder = os.path.join(out, "frames", clip)
        for speed, name in ((1, "1x"), (10, "10x")):
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(120 // speed), "-pattern_type", "glob",
                            "-i", os.path.join(folder, "*.jpg"), "-pix_fmt", "yuv420p", os.path.join(out, f"{clip}-{name}.mp4")])
subprocess.run(["tar", "-czf", os.path.join(out, "out.tgz"), "-C", out, "--exclude", "base-src", "--exclude", "*.app",
                "--exclude", "out.tgz", "."], capture_output=True)
say("REPORT-JSON " + json.dumps([{k: v for k, v in x.items() if k != "error"} for x in report["runs"]]))
sys.exit(0)
