#!/usr/bin/env python3
"""Drag lag on a fleet-built app: column edge, tab and sidebar row drags at a fast hand pace.

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- python3 scripts/cmux-next/drag-lag-live.py --out "$NX_ARTIFACTS"
  python3 scripts/cmux-next/drag-lag-live.py --app APP --tag TAG --out DIR   (the perf-lab story runner)

Lawrence 2026-10-18: "I just saw an error about moving panes around... when I was dragging stuff
around, it was insanely laggy." Each drag sends one `debug.mouse` move per 1/120 s. `debug.mouse`
runs on the main actor and dispatches the event before it replies, so each reply's time is that
move's main-thread work plus any main-thread backlog. After the column drag, one daemon round-trip
(`list-workspaces` through the app socket) shows how far the daemon fell behind. The app's own
log is read for `timed out` errors. Prints one JSON summary; writes it to OUT/drag-lag.json
(each drag and probe: n, p50, p95, p99, max and replies over 16.7 ms; perf_stats percentiles).

The app (--app, else $NX_APP) launches and stops through bench_launch.BenchApp (the bench env, an
empty cmux.json, a fresh saved session for the tag, the tag's daemons ended at the stop). Every
move's reply time and every daemon probe are also written as cmux-perf-result/v1 in --out (story
drag-lag: `drag_lag.<drag>.move`, `drag_lag.daemon.<phase>.round_trip`, their failures and the
app's `timed out` errors; drag_layout_bench_report.py).
"""
import argparse, json, os, socket, subprocess, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
import drag_layout_bench_report as results  # noqa: E402
from bench_launch import BenchApp  # noqa: E402
from new_tab_bench_report import record_all  # noqa: E402


def parse(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
    parser.add_argument("--app", default=os.environ.get("NX_APP"), help="the tagged app bundle (default $NX_APP)")
    parser.add_argument("--tag")  # the story runner passes it; the bundle carries the tag
    parser.add_argument("--moves", type=int, default=120)
    parser.add_argument("--story", default=results.DRAG_LAG_STORY, help="result-v1 story")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    opts = parser.parse_args(argv)
    if not opts.app:
        parser.error("name the tagged app with --app, or run inside `nx-remote --needs gui --app-from-fleet cmux` (NX_APP)")
    return opts


# Set by main(): the options, the launched app (BenchApp), its socket and CLI, the report and the raw samples.
opts = LAUNCHER = SOCKET = CLI = None
SUMMARY = {}
MOVES = {}  # {drag report key: [reply ms of each move]}
PROBES = {}  # {probe report key: [daemon_round_trip results]}


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def env():
    return {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}


def cli(*args):
    out = subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=60, env=env())
    return (out.stdout + out.stderr).strip()


def daemon_round_trip():
    """One daemon command through the app socket (the bundled cmux-tui's `raw operation`): its wall time in ms."""
    tui = os.path.join(os.path.dirname(CLI), "cmux-tui")
    started = time.monotonic()
    out = subprocess.run([tui, "--app-socket", SOCKET, "--json", "raw", "operation", "workspace.list",
                          "--params-json", '{"machine":"current","session":"current"}'],
                         capture_output=True, text=True, timeout=60, env=env())
    result = {"ms": round((time.monotonic() - started) * 1000, 1), "ok": out.returncode == 0}
    if out.returncode != 0:
        result["error"] = (out.stdout + out.stderr)[:200]
    return result


class DaemonProbe:
    """Daemon round-trips every 150 ms on a thread while a drag runs (and for `tail` seconds after)."""

    def __init__(self):
        self.samples, self.stop = [], threading.Event()
        self.thread = threading.Thread(target=self.loop, daemon=True)

    def loop(self):
        while not self.stop.is_set():
            self.samples.append(daemon_round_trip())
            self.stop.wait(0.15)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(70)

    def summary(self):
        ok = [s["ms"] for s in self.samples if s["ok"]]
        failed = [s for s in self.samples if not s["ok"]]
        result = {"probes": len(self.samples), "failed": len(failed),
                  **{k: v for k, v in results.latency_block(ok).items() if k != "n"}}
        if failed:
            result["first_error"] = failed[0].get("error")
        return result


def probed(key, probe):
    """The probe's report block under `key`; its raw round trips are kept for result-v1."""
    PROBES[key] = list(probe.samples)
    SUMMARY[key] = probe.summary()


def wait(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness polling a live app
    return None


def action(name, **params):
    return rpc("action.run", {"action": name, **params})


def paced_drag(key, x, y, to_x, to_y, moves):
    """A held drag: one `debug.mouse` move per 1/120 s (a fast hand), timing each reply. Its report block goes to
    SUMMARY[key] and its reply times to MOVES[key]."""
    mouse = lambda **p: rpc("debug.mouse", p)
    if "error" in (mouse(action="drag", x=x, y=y, to_x=x, to_y=y, steps=1, release=False) or {}):
        SUMMARY[key] = {"error": "could not press"}
        return
    last, times = (x, y), []
    try:
        for move in range(1, moves + 1):
            point = (x + (to_x - x) * move / moves, y + (to_y - y) * move / moves)
            started = time.monotonic()
            mouse(action="drag", x=last[0], y=last[1], to_x=point[0], to_y=point[1], steps=1, press=False, release=False)
            times.append((time.monotonic() - started) * 1000)
            last = point
            time.sleep(max(0, 1 / 120 - times[-1] / 1000))  # test harness: pointer pace
    finally:
        mouse(action="drag", x=last[0], y=last[1], to_x=last[0], to_y=last[1], steps=1, press=False, release=True)
    MOVES[key] = times
    SUMMARY[key] = results.latency_block(times)


def column_edges():
    windows = (rpc("debug.layers") or {}).get("windows") or [{}]
    layer = windows[0]
    height = (layer.get("frame") or [0, 0, 0, 720])[3]
    return sorted((x + w / 2, height - (y + h / 2)) for x, y, w, h in layer.get("divider_areas_in_window") or [] if h > w)


def strips():
    return (rpc("debug.tab_drag") or {}).get("strips") or []


def sidebar_rows():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or [{}]
    return [r for r in windows[0].get("rows") or [] if str(r.get("key", "")).startswith("workspace(") and r.get("window_frame")]


def center(frame):
    if isinstance(frame, dict):
        return frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
    x, y, w, h = frame
    return x + w / 2, y + h / 2


def app_errors(since):
    """`timed out` errors in the log of the app this script launched (its own PID, never a process scan)."""
    process = LAUNCHER.process
    if process is None or process.poll() is not None:
        return {}
    out = subprocess.run(["log", "show", "--start", since, "--style", "compact", "--predicate",
                          f"processID == {process.pid} AND messageType >= 16"],
                         capture_output=True, text=True, timeout=120).stdout
    lines = [line for line in out.splitlines() if "timed out" in line]
    return {"timed_out": len(lines), "set_viewport_pane_width_timed_out": sum("set-viewport-pane-width" in l for l in lines),
            "sample": lines[-3:]}


def drags():
    for index in range(30):
        cli("workspace", "create", "--name", f"Workspace {index:02d}")
    action("newTab", focus=True)
    time.sleep(2)  # test harness: the tab's terminal starts
    for _ in range(4):
        action("newColumn", focus=True)
        time.sleep(1.5)  # test harness: the column lands
    action("splitRight", focus=True)
    time.sleep(1.5)  # test harness: the split lands
    action("newSurface", focus=True)
    time.sleep(2)  # test harness: the surface starts
    SUMMARY["daemon_idle"] = daemon_round_trip()

    edges = wait(column_edges, 20)
    if edges:
        x, y = edges[0]
        with DaemonProbe() as probe:
            paced_drag("column_drag", x, y, x + 240, y, opts.moves)
            paced_drag("column_drag_back", x + 240, y, x, y, opts.moves)
            time.sleep(3)  # test harness: the probe's tail after the drags
        probed("daemon_during_and_3s_after_column_drags", probe)
    else:
        SUMMARY["column_drag"] = {"error": "no column edge"}

    two = next((s for s in strips() if len(s.get("tabs") or []) >= 2), None)
    others = [s for s in strips() if s is not two]
    if two and others:
        tab = (two.get("tabs") or [])[-1]
        frame = tab.get("frame") or tab.get("window_frame")
        target = others[0].get("frame") or others[0].get("window_frame")
        if frame and target:
            sx, sy = center(frame)
            tx, ty = center(target)
            with DaemonProbe() as probe:
                paced_drag("tab_drag", sx, sy, tx, ty + 200, opts.moves)
                time.sleep(2)  # test harness: the probe's tail after the drag
            probed("daemon_during_tab_drag", probe)
    SUMMARY.setdefault("tab_drag", {"error": f"no two-tab strip: {json.dumps(strips())[:400]}"})

    rows = sidebar_rows()
    if len(rows) >= 8:
        frame = rows[1].get("window_frame")
        far = rows[-1].get("window_frame")
        if frame and far:
            sx, sy = center(frame)
            _, ty = center(far)
            with DaemonProbe() as probe:
                paced_drag("sidebar_drag", sx, sy, sx, ty, opts.moves)
                time.sleep(2)  # test harness: the probe's tail after the drag
            probed("daemon_during_sidebar_drag", probe)
    SUMMARY.setdefault("sidebar_drag", {"error": f"rows={len(rows)}"})


def record_results():
    """The moves, probes and log errors as cmux-perf-result/v1 in --out (BenchApp.record)."""
    series = results.drag_lag_series(SUMMARY, MOVES, PROBES, story=opts.story)
    for key, where in record_all(LAUNCHER, series).items():
        if not where.startswith("not recorded"):
            print(f"result-v1 {key}: {where}", flush=True)


def main(argv=None):
    global opts, LAUNCHER, SOCKET, CLI
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    LAUNCHER = BenchApp(opts.app, out=opts.out, config={}, window=(40, 40, 1280, 760), screen="last",
                        build_config=opts.build_config)
    SUMMARY["tag"] = LAUNCHER.tag
    try:
        LAUNCHER.launch(timeout=120)  # ready once debug.windows lists a window
        SOCKET, CLI = LAUNCHER.socket, LAUNCHER.cli
        time.sleep(2)  # test harness: let the window settle
        since = time.strftime("%Y-%m-%d %H:%M:%S")
        drags()
        time.sleep(2)  # test harness: late log lines land
        SUMMARY["app_errors"] = app_errors(since)
    finally:
        LAUNCHER.stop()
    with open(os.path.join(opts.out, "drag-lag.json"), "w") as f:
        json.dump(SUMMARY, f, indent=1)
    print(json.dumps(SUMMARY, indent=1))
    record_results()
    return 0


if __name__ == "__main__":
    sys.exit(main())
