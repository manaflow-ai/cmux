#!/usr/bin/env python3
"""Omnibar mouse-down latency (omnibar-mousedown-latency): click to the frame that shows focus.

Launches the tagged app itself (no activation, scratch config), opens a page in a Chromium tab and
in a WebKit tab, and runs `debug.omnibar_bench` `--runs` times in each: the page takes the keyboard,
then one click lands in the omnibar through the app's real mouse path (`debug.mouse`). Per run the
app reports, in ms after the click was posted, the display frame at which the field editor is
attached (`attached_ms`, the caret), the whole address is selected (`selected_ms`) and the editing
look has fully shown (`focused_ms`, no fade left), plus the press's main-thread spans and marks.

Phases: `idle`, then `load` (every core busy with `yes`). With `--budget-ms N` the run fails when
any engine's p95 `focused_ms` is above N or a run never showed focus.

Usage: omnibar-click-bench.py --tag TAG --app PATH [--runs 15] [--engines chromium,webkit]
       [--phases idle,load] [--json FILE] [--budget-ms 0]
"""
import argparse, glob, json, os, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp, bundle_id  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=15)
parser.add_argument("--engines", default="chromium,webkit")
parser.add_argument("--phases", default="idle,load")
parser.add_argument("--budget-ms", type=float, default=0, help="fail when an engine's p95 focused_ms is above this (0: report only)")
parser.add_argument("--next-frame", action="store_true",
                    help="fail unless every row shows the caret and the whole selection on the first display frame after the press, "
                         "with p95 dispatch_to_selected_ms within one refresh (16.7 ms)")
parser.add_argument("--activate", action="store_true",
                    help="run the app active (real key windows: a Chromium page's child window holds the keys); fleet hosts only")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
opts = parser.parse_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"omnibar-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
CLI_ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1", "CMUX_TAG": TAG,
           "CMUX_BUNDLE_ID": BUNDLE_ID, "CMUX_BUNDLED_CLI_PATH": CLI}
LAUNCHED, LOAD = [], []
TIMINGS = {}  # (phase, engine) -> debug.timings omnibar_clicks
app = None


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def pct(values, q):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def start_load():
    for _ in range(os.cpu_count() or 8):
        LOAD.append(subprocess.Popen(["yes"], stdout=subprocess.DEVNULL))
    time.sleep(3)  # test harness: let the load ramp


def stop_load():
    for proc in LOAD:
        try:
            proc.terminate()
        except OSError:
            pass
    LOAD.clear()


def open_page(engine):
    path = os.path.join(SCRATCH, f"page-{engine}.html")
    open(path, "w").write("<!doctype html><title>omnibar bench</title><body style='font:20px -apple-system'>"
                          + "<p>omnibar bench row</p>" * 60)
    url = "file://" + path + "?q=" + "omnibar-latency-" * 6
    reply = rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    print(f"open {engine}:", json.dumps(reply)[:300], flush=True)
    ok = wait(lambda: "error" not in (rpc("debug.omnibar") or {"error": 1}), 60)
    time.sleep(1.5)  # test harness: let the page finish its first paint
    return ok


def marks(row):
    return {s["name"]: round(s["at"], 2) for s in row.get("spans") or [] if s.get("ms", 0) == 0}


def spans(row):
    return {s["name"]: round(s["ms"], 2) for s in row.get("spans") or [] if s.get("ms", 0) > 0}


def bench(phase, engine):
    rows = []
    rpc("debug.timings", {"clear": True})
    for index in range(opts.runs):
        result = rpc("debug.omnibar_bench", {}, timeout=20) or {}
        result.update({"phase": phase, "engine_asked": engine, "run": index})
        rows.append(result)
        print(f"{phase} {engine} #{index}: active={result.get('app_active')} key={result.get('key_window_before')}->{result.get('key_window_after')} attached={result.get('attached_ms')} selected={result.get('selected_ms')} "
              f"focused={result.get('focused_ms')} frames={result.get('frames_to_focused')} press={result.get('press_ms')} "
              f"after_press(a/s/f)={result.get('attached_frames_after_press')}/{result.get('selected_frames_after_press')}/{result.get('focused_frames_after_press')} "
              f"spans={spans(result)} marks={marks(result)} err={result.get('error')}", flush=True)
        time.sleep(0.25)  # test harness: space the clicks apart (not a double-click)
    clicks = (rpc("debug.timings", {"clear": True}) or {}).get("omnibar_clicks") or []
    print(f"{phase} {engine} debug.timings omnibar_clicks: {json.dumps(clicks)}", flush=True)
    TIMINGS[(phase, engine)] = clicks
    return rows


def summary(rows):
    out = {}
    for phase in sorted({r["phase"] for r in rows}):
        for engine in opts.engines.split(","):
            sel = [r for r in rows if r["phase"] == phase and r["engine_asked"] == engine]
            if not sel:
                continue
            down = [next((s["ms"] for s in r.get("spans") or [] if s["name"] == "app.sendEvent.down"), None) for r in sel]
            out[f"{phase}/{engine}"] = {
                "n": len(sel), "missed": sum(r.get("focused_ms") is None for r in sel),
                "attached_p50": pct([r.get("attached_ms") for r in sel], .5), "attached_p95": pct([r.get("attached_ms") for r in sel], .95),
                "selected_p50": pct([r.get("selected_ms") for r in sel], .5), "selected_p95": pct([r.get("selected_ms") for r in sel], .95),
                "focused_p50": pct([r.get("focused_ms") for r in sel], .5), "focused_p95": pct([r.get("focused_ms") for r in sel], .95),
                "focused_max": pct([r.get("focused_ms") for r in sel], 1),
                "mouse_down_dispatch_p50": pct(down, .5), "mouse_down_dispatch_max": pct(down, 1),
            }
            for key in ("press_ms", "dispatch_to_attached_ms", "dispatch_to_selected_ms", "dispatch_to_focused_ms",
                        "attached_frames_after_press", "selected_frames_after_press", "focused_frames_after_press"):
                values = [r.get(key) for r in sel]
                out[f"{phase}/{engine}"].update({f"{key}_p50": pct(values, .5), f"{key}_p95": pct(values, .95), f"{key}_max": pct(values, 1)})
            clicks = TIMINGS.get((phase, engine)) or []
            for key in ("input_ms", "key_to_frame_ms"):
                values = [c.get(key) for c in clicks]
                out[f"{phase}/{engine}"].update({f"{key}_n": len(clicks), f"{key}_p50": pct(values, .5),
                                                 f"{key}_p95": pct(values, .95), f"{key}_max": pct(values, 1)})
    return out


def cleanup():
    stop_load()
    if not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in ps.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith(APP + "/") and int(parts[0]) != os.getpid():
            try:
                os.kill(int(parts[0]), signal.SIGTERM)
            except OSError:
                pass
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app, SOCKET
    # No socket check here: BenchApp.launch() refuses a live same-tag app (any bundle path) and unlinks only a
    # socket nothing accepts on.
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    if not opts.activate:
        env["CMUX_NEXT_NO_ACTIVATE"] = "1"
    else:
        env["CMUX_NEXT_NO_ACTIVATE"] = None  # bench_launch: not the default no-activate launch
    # One launch path (bench_launch.py): socket in the state folder, bench env, a clear reason when it does not come up.
    launcher = BenchApp(APP, out=opts.out, log_name=f"app-{TAG}.log", window=None, screen=None, teardown=False, env=env)
    try:
        launcher.launch(timeout=120, on_start=lambda process: LAUNCHED.append(process.pid))
    finally:
        app = launcher.process
    SOCKET = launcher.socket
    CLI_ENV["CMUX_SOCKET_PATH"] = SOCKET
    time.sleep(2)  # test harness: first launch settles
    if opts.activate:
        subprocess.run(["osascript", "-e", f'tell application id "{BUNDLE_ID}" to activate'], capture_output=True, timeout=30)
        time.sleep(1)  # test harness: activation settles
    rows = []
    for engine in opts.engines.split(","):
        if not open_page(engine):
            print(f"{engine}: no omnibar came up: {json.dumps(rpc('debug.omnibar'))[:400]}", flush=True)
            continue
        for phase in opts.phases.split(","):
            if phase == "load":
                start_load()
            try:
                rows += bench(phase, engine)
            finally:
                stop_load()
    result = {"tag": TAG, "host": os.uname().nodename, "cpus": os.cpu_count(), "summary": summary(rows), "runs": rows}
    print("\nSUMMARY", json.dumps(result["summary"], indent=1), flush=True)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        open(opts.json, "w").write(json.dumps(result, indent=1))
    if not rows:
        return False
    if opts.next_frame:
        frame = 1000 / 60
        bad = [k for k, v in result["summary"].items()
               if v["missed"] or (v["attached_frames_after_press_max"] or 9) > 1 or (v["selected_frames_after_press_max"] or 9) > 1
               or (v["dispatch_to_selected_ms_p95"] or 1e9) > frame]
        print("NEXT-FRAME", "FAIL " + ", ".join(bad) if bad else "PASS", flush=True)
        if bad:
            return False
    if opts.budget_ms:
        bad = [k for k, v in result["summary"].items() if v["missed"] or (v["focused_p95"] or 1e9) > opts.budget_ms]
        print("BUDGET", "FAIL " + ", ".join(bad) if bad else "PASS", flush=True)
        return not bad
    return True


ok = False
try:
    ok = main()
finally:
    cleanup()
sys.exit(0 if ok else 1)
