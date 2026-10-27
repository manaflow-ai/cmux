#!/usr/bin/env python3
"""Omnibar mouse-down latency (omnibar-mousedown-latency): click to the frame that shows focus.

Launches the tagged app itself (no activation, scratch config), opens a page in a Chromium tab and
in a WebKit tab, and runs `debug.omnibar_bench` `--runs` times in each: the page takes the keyboard,
then one click lands in the omnibar through the app's real mouse path (`debug.mouse`). Per run the
app reports, in ms after the click was posted, the display frame at which the field editor is
attached (`attached_ms`, the caret), the whole address is selected (`selected_ms`) and the editing
look has fully shown (`focused_ms`, no fade left), plus the press's main-thread spans and marks.

Phases: `idle`, then `load` (every core busy with `yes`). With `--budget-ms N` the run fails when
any engine's p95 `focused_ms` is above N or a run never showed focus. The summary has p50, p95, p99 and
max of each value (scripts/perf-lab/perf_stats.py pct: linear interpolation between closest ranks).

--story ID also writes one cmux-perf-result/v1 file per phase and value into --out (BenchApp.record):
metric `<phase>.<value>` in ms with every click as a sample, for example `idle.focused_ms`; the values are
RESULT_KEYS and TIMING_KEYS below. A story names one engine (scripts/perf-lab/stories.d), so --story needs
exactly that one engine in --engines: omnibar-click is the Chromium arm, omnibar-click-webkit the WebKit
arm. A --story run that writes no series fails.

Usage: omnibar-click-bench.py --tag TAG --app PATH [--runs 15] [--engines chromium,webkit]
       [--phases idle,load] [--json FILE] [--budget-ms 0] [--story ID]
"""
import argparse, glob, json, os, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import PERF_LAB, BenchApp, RecordError, bundle_id, load_by_path  # noqa: E402
from bench_story import story_problem  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

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
parser.add_argument("--story", help="write cmux-perf-result/v1 of this stories.d story (one engine, the story's)")
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


# The per-click values of debug.omnibar_bench written as result-v1 (ms after the click was posted, or after its
# dispatch), and those of debug.timings omnibar_clicks.
RESULT_KEYS = ("attached_ms", "selected_ms", "focused_ms", "dispatch_to_attached_ms", "dispatch_to_selected_ms",
               "dispatch_to_focused_ms")
TIMING_KEYS = ("input_ms", "key_to_frame_ms")


def pct(values, q):
    """perf_stats.pct over the values the runs reported (a missed run reports None)."""
    return perf_stats.pct([v for v in values if v is not None], q)


def spread(prefix, values):
    """{prefix_p50, prefix_p95, prefix_p99, prefix_max} of the values."""
    return {f"{prefix}_p50": pct(values, .5), f"{prefix}_p95": pct(values, .95), f"{prefix}_p99": pct(values, .99),
            f"{prefix}_max": pct(values, 1)}


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


def summary(rows, engines, timings):
    """{"<phase>/<engine>": n, missed and the p50/p95/p99/max of every value} of the bench rows and the debug.timings
    clicks `timings` {(phase, engine): clicks}."""
    out = {}
    for phase in sorted({r["phase"] for r in rows}):
        for engine in engines:
            sel = [r for r in rows if r["phase"] == phase and r["engine_asked"] == engine]
            if not sel:
                continue
            down = [next((s["ms"] for s in r.get("spans") or [] if s["name"] == "app.sendEvent.down"), None) for r in sel]
            row = {"n": len(sel), "missed": sum(r.get("focused_ms") is None for r in sel)}
            for name in ("attached", "selected", "focused"):
                row.update(spread(name, [r.get(f"{name}_ms") for r in sel]))
            row.update({"mouse_down_dispatch_p50": pct(down, .5), "mouse_down_dispatch_p99": pct(down, .99),
                        "mouse_down_dispatch_max": pct(down, 1)})
            for key in ("press_ms", "dispatch_to_attached_ms", "dispatch_to_selected_ms", "dispatch_to_focused_ms",
                        "attached_frames_after_press", "selected_frames_after_press", "focused_frames_after_press"):
                row.update(spread(key, [r.get(key) for r in sel]))
            clicks = timings.get((phase, engine)) or []
            for key in TIMING_KEYS:
                row[f"{key}_n"] = len(clicks)
                row.update(spread(key, [c.get(key) for c in clicks]))
            out[f"{phase}/{engine}"] = row
    return out


def record_results(launcher, story, engine, rows, timings):
    """One cmux-perf-result/v1 file per phase and value (BenchApp.record) of a one-engine run, every click that
    reported the value a sample. A series the bench cannot describe truthfully (no build sha, no features snapshot) is not written; its
    reason is returned in its place."""
    series = {}
    for row in rows:
        for key in RESULT_KEYS:
            series.setdefault(f"{row['phase']}.{key}", []).append(row.get(key))
    for (phase, _), clicks in timings.items():
        for key in TIMING_KEYS:
            series.setdefault(f"{phase}.{key}", []).extend(c.get(key) for c in clicks)
    written = {}
    for metric, values in series.items():
        samples = [v for v in values if isinstance(v, (int, float))]
        if not samples:
            continue
        try:
            written[metric] = str(launcher.record(story, metric, "ms", samples, better="lower", engine=engine))
        except (RecordError, perf_result.ResultError) as error:
            written[metric] = f"not recorded: {error}"
            print(f"result-v1 {metric}: not recorded: {error}", flush=True)
    return written


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
        activated = launcher.activate(timeout=10)  # returns once a window of the app is key
        print("activate:", json.dumps(activated), flush=True)
    rows = []
    for engine in ENGINES:
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
    result = {"tag": TAG, "host": os.uname().nodename, "cpus": os.cpu_count(), "summary": summary(rows, ENGINES, TIMINGS),
              "runs": rows}
    print("\nSUMMARY", json.dumps(result["summary"], indent=1), flush=True)
    recorded = True
    if opts.story:
        result["results"] = record_results(launcher, opts.story, ENGINES[0], rows, TIMINGS)
        missing = [why for why in result["results"].values() if not why.endswith(".ndjson")]
        recorded = len(result["results"]) > len(missing)
        # A story run that recorded nothing measured nothing for the lab.
        print("RESULT-V1", "PASS" if recorded else "FAIL: nothing recorded", *missing, flush=True)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        open(opts.json, "w").write(json.dumps(result, indent=1))
    if not rows or not recorded:
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


if __name__ == "__main__":
    opts = parser.parse_args()
    ENGINES = [e for e in opts.engines.split(",") if e]
    if not ENGINES or any(e not in ("chromium", "webkit") for e in ENGINES):
        parser.error(f"--engines takes chromium, webkit or both, got {opts.engines!r}")
    if opts.story:
        if len(ENGINES) != 1:
            parser.error("--story records one engine (result-v1 names one): pass --engines chromium or webkit")
        problem = story_problem(opts.story, ENGINES[0])
        if problem:
            parser.error(problem)
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
    ok = False
    try:
        ok = main()
    finally:
        cleanup()
    sys.exit(0 if ok else 1)
