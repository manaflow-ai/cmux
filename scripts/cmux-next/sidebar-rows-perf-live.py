#!/usr/bin/env python3
"""Live perf check of the sidebar rows path (sidebar-v2 rows lane) on a running tagged app.

  scripts/cmux-next/sidebar-rows-perf-live.py --tag <tag> [--label NAME] [--out DIR]
      [--count 1000] [--ticking 50] [--tick-ms 250] [--seconds 20] [--scroll-steps 120]

Attaches to a running tagged app (it never launches or quits one; run it on a GUI lane host
such as cmux-lawrence-2, never the laptop). It makes `--count` workspaces: `--ticking` of them
with a terminal, the others empty (`workspace create --empty`, so 1,000 rows need no 1,000
PTYs). Then:

  ticks:  each ticking terminal's program reports OSC 7501 every `--tick-ms`, alternating
          `working` and `idle` (each report changes the row's status), for `--seconds`.
          Measured: the app's CPU time per tick (proc_pid_rusage), the main-thread reply delay
          of a cheap main-actor debug call sampled every 50 ms (a stall shows as a slow reply),
          and, when the build serves `debug.sidebar_perf`, its counters.
  scroll: `--scroll-steps` wheel events over the workspace list (`debug.sidebar_wheel`, one
          event per call), down then up. Measured: each call's main-thread time, hitches
          (calls over one 60 Hz frame, 16.7 ms), and the counters.

With counters (a build of the rows lane) it asserts: no structural rebuild and no list reload
during the ticks; row configures stay at or under the row patches (one realized row per changed
row) and are not 0 when a ticking row is on screen; no list reload during the scroll. A build
without `debug.sidebar_perf` (the base) is measured only. Writes summary-<label>.json to --out
and exits 1 when an assertion fails.
"""
import argparse, json, os, socket, statistics, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--label", default="run")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--count", type=int, default=1000)
parser.add_argument("--ticking", type=int, default=50)
parser.add_argument("--tick-ms", type=int, default=250)
parser.add_argument("--seconds", type=float, default=20)
parser.add_argument("--scroll-steps", type=int, default=120)
parser.add_argument("--pid", type=int, help="the app's pid (default: found from the tag's app path)")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "..", "cmux-debug-cli.sh")
FRAME_MS = 1000 / 60
failures = []
summary = {"label": opts.label, "tag": opts.tag, "count": opts.count, "ticking": opts.ticking,
           "tick_ms": opts.tick_ms, "seconds": opts.seconds}


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=60):
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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def timed_rpc(method, params=None):
    start = time.perf_counter()
    reply = rpc(method, params)
    return (time.perf_counter() - start) * 1000, reply


def cli(*args, timeout=60):
    env = dict(os.environ, CMUX_TAG=opts.tag)
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=timeout)


def app_pid():
    if opts.pid:
        return opts.pid
    marker = f"cmux DEV {opts.tag}.app/Contents/MacOS/"
    for line in subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout.splitlines():
        pid, _, command = line.strip().partition(" ")
        if marker in command and "Helper" not in command:
            return int(pid)
    return None


def cpu_ns(pid):
    sys.path.insert(0, HERE)
    from bench_idle import usage  # noqa: E402
    sample = usage(pid) if pid else None
    return sample[0] if sample else None


def counters(reset=False):
    reply = rpc("debug.sidebar_perf", {"reset": reset})
    return None if not isinstance(reply, dict) or "error" in reply else reply


def workspace_rows():
    windows = (rpc("debug.sidebar_rows", timeout=120) or {}).get("windows") or []
    return [r for w in windows for r in w.get("rows") or [] if str(r.get("key", "")).startswith("workspace")]


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(p / 100 * len(ordered)))], 2)


def latency_stats(values):
    return {"samples": len(values), "p50_ms": percentile(values, 50), "p95_ms": percentile(values, 95),
            "max_ms": round(max(values), 2) if values else None,
            "over_frame": sum(1 for v in values if v > FRAME_MS)}


def make_workspaces():
    have = {r.get("title") for r in workspace_rows()}
    empty = [f"perf-{i:04d}" for i in range(opts.count - opts.ticking) if f"perf-{i:04d}" not in have]
    ticking = [f"perf-tick-{i:02d}" for i in range(opts.ticking) if f"perf-tick-{i:02d}" not in have]
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=8) as pool:
        # The ticking ones first, so they list near the top, where the window shows rows.
        results = list(pool.map(lambda name: cli("workspace", "create", "--name", name), ticking))
        results += list(pool.map(lambda name: cli("workspace", "create", "--empty", "--name", name), empty))
    bad = [r.stderr.strip()[-160:] for r in results if r.returncode != 0]
    check(not bad, f"created {len(results)} workspaces in {time.monotonic() - start:.0f} s ({bad[:3]})")
    deadline = time.monotonic() + 300
    shown = 0
    while time.monotonic() < deadline:  # bounded wait for the sidebar to list them
        shown = len([r for r in workspace_rows() if str(r.get("title") or "").startswith("perf-")])
        if shown >= opts.count:
            break
        time.sleep(2)
    summary["listed"] = shown
    check(shown >= opts.count, f"the sidebar lists {shown} of {opts.count} perf workspaces")


def ticking_terminals():
    """The terminals of the perf-tick workspaces (`terminal list` names each with its workspace)."""
    listed = cli("--json", "terminal", "list")
    terms = []
    try:
        data = json.loads(listed.stdout)
        items = data.get("terminals") if isinstance(data, dict) else data
        for item in items or []:
            text = json.dumps(item)
            ident = next((v for v in item.values() if isinstance(v, str) and v.startswith("term_")), None)
            if ident and "perf-tick-" in text:
                terms.append(ident)
    except (ValueError, AttributeError):
        pass
    if not terms:  # older CLI output: every terminal (the ticking ones and the first window's)
        terms = [word for word in cli("terminal", "list").stdout.split() if word.startswith("term_")]
    return terms


def visible_ticking():
    rows = workspace_rows()
    return len([r for r in rows if str(r.get("title") or "").startswith("perf-tick-") and r.get("view_frame")])


def sampler(stop, out):
    """Main-thread reply delay of a cheap main-actor call, every 50 ms."""
    while not stop.is_set():
        ms, reply = timed_rpc("debug.layout_counters")
        if isinstance(reply, dict) and "error" not in reply:
            out.append(ms)
        stop.wait(0.05)


def tick_phase(pid):
    terms = ticking_terminals()
    summary["ticking_terminals"] = len(terms)
    check(len(terms) >= min(opts.ticking, 1), f"{len(terms)} ticking terminals")
    summary["visible_ticking_rows"] = visible_ticking()
    ticks_each = int(opts.seconds * 1000 / opts.tick_ms)
    interval = opts.tick_ms / 1000
    loop = (f"i=0; while [ $i -lt {ticks_each} ]; do if [ $((i % 2)) = 0 ]; then s=working; else s=idle; fi; "
            f"printf '\\033]7501;state=%s\\033\\\\' $s; sleep {interval}; i=$((i + 1)); done; printf '\\033]7501;state=idle\\033\\\\'\n")
    time.sleep(3)  # test script: let the creates settle before the measured window
    base = counters(reset=True)
    cpu0 = cpu_ns(pid)
    stop, samples = threading.Event(), []
    thread = threading.Thread(target=sampler, args=(stop, samples))
    thread.start()
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda term: cli("terminal", term, "write", "--text", loop), terms))
    time.sleep(opts.seconds + 1)  # test script: the measured window is the ticks themselves
    stop.set()
    thread.join()
    cpu1 = cpu_ns(pid)
    ticks = ticks_each * len(terms)
    result = {"ticks": ticks, "latency": latency_stats(samples)}
    if cpu0 is not None and cpu1 is not None:
        result["app_cpu_ms"] = round((cpu1 - cpu0) / 1e6, 1)
        result["app_cpu_us_per_tick"] = round((cpu1 - cpu0) / 1e3 / max(ticks, 1), 1)
    after = counters()
    if base is not None and after is not None:
        result["counters"] = after
        result["main_us_per_tick"] = round(after.get("main_ns", 0) / 1e3 / max(ticks, 1), 1)
        visible = summary["visible_ticking_rows"]
        check(after.get("rebuilds", 0) == 0, f"ticks: no structural rebuild (rebuilds {after.get('rebuilds')})")
        check(after.get("list_reloads", 0) == 0, f"ticks: no list reload (list_reloads {after.get('list_reloads')})")
        check(after.get("row_configures", 0) <= after.get("row_patches", 0),
              f"ticks: row configures {after.get('row_configures')} <= row patches {after.get('row_patches')}")
        if visible:
            check(after.get("row_configures", 0) > 0, f"ticks: {visible} visible ticking rows were configured")
        result["expected_configures_visible"] = ticks_each * visible
    summary["ticks"] = result
    print("ticks:", json.dumps(result), flush=True)


def scroll_phase():
    rows = [r for r in workspace_rows() if r.get("view_frame")]
    if not rows:
        check(False, "scroll: a realized workspace row to scroll over")
        return
    x, y, w, h = rows[len(rows) // 2]["window_frame"]
    point = {"x": x + w / 2, "y": y + h / 2}
    counters(reset=True)
    durations = []
    for direction in (-3, 3):
        for _ in range(opts.scroll_steps // 2):
            ms, _ = timed_rpc("debug.sidebar_wheel", dict(point, dy=direction, count=1))
            durations.append(ms)
    result = {"steps": len(durations), "latency": latency_stats(durations)}
    after = counters()
    if after is not None:
        result["counters"] = after
        check(after.get("list_reloads", 0) == 0, f"scroll: no list reload (list_reloads {after.get('list_reloads')})")
        check(after.get("rebuilds", 0) == 0, f"scroll: no structural rebuild (rebuilds {after.get('rebuilds')})")
    summary["scroll"] = result
    print("scroll:", json.dumps(result), flush=True)


def main():
    if "error" in (rpc("debug.layout_counters") or {"error": 1}):
        sys.exit(f"no tagged app answering on {SOCKET}")
    summary["has_counters"] = counters() is not None
    pid = app_pid()
    summary["pid"] = pid
    make_workspaces()
    tick_phase(pid)
    scroll_phase()
    summary["failures"] = failures
    os.makedirs(opts.out, exist_ok=True)
    path = os.path.join(opts.out, f"summary-{opts.label}.json")
    with open(path, "w") as out:
        json.dump(summary, out, indent=2)
    print(f"summary: {path}", flush=True)
    print(json.dumps(summary), flush=True)
    print(f"{len(failures)} failure(s)", flush=True)
    sys.exit(1 if failures else 0)


main()
