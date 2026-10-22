#!/usr/bin/env python3
"""Chromium (CEF) integration cost, measured in a real window (cef-perf, Leo's audit, msg 9136: "every frame we
recompute the position and clipping of each Chromium view and force a redraw; Chromium's work runs on the main
thread in 10 ms slices").

Launches a tagged cmux-next app (scratch config, empty Ghostty config). For each --tabs count it makes a fresh
workspace whose left pane holds that many Chromium tabs (local pages) and whose right pane is a terminal, then:

  idle     --idle seconds untouched: the main thread's CPU share (`ps -M`), Chromium's share of it (the pump's
           CefDoMessageLoopWork time, `debug.cef` pump), pump passes per second and their p50/p95/max
  drag     the divider between the panes dragged 120 pt out and back, one event per 120 Hz frame: display frame
           p50/p95/max and missed frames (`debug.frames`), main thread share, pump passes, and the hosts' geometry
           work (`debug.cef` geometry: clip builds, fork reads, updates asked and skipped)
  switch   Ctrl-Tab through the Chromium tabs (`debug.tab_switch`: apply p50/p95 ms per switch, late frames)
  scroll   the shown page scrolls itself (requestAnimationFrame, 3 px a frame) for --scroll seconds: frames,
           main thread share, pump passes

Usage (fleet, through the allowlisted entry):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh --ref SHA \\
    --arg=--suite=cef-perf --artifact artifacts/split-spring/report.json [--arg=--tabs=2,10,30] [--arg=--rounds=3]
Output: CEF-PERF lines and a summary table; --json gets the whole report.
"""
import argparse, glob, json, os, signal, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--tabs", default="2,10,30")
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--idle", type=float, default=10.0)
parser.add_argument("--scroll", type=float, default=4.0)
parser.add_argument("--sample", action="store_true", help="profile the main thread (/usr/bin/sample) over drags at the largest tab count")
parser.add_argument("--json")
parser.add_argument("--out", default="/tmp")
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"cef-perf-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
WINDOW = (80, 80, 1600, 1000)
ROWS, LAUNCHED = [], []
app = None


def page_body(index, scroll):
    script = ""
    if scroll:
        # The page scrolls itself one step a frame: the compositor and the browser process work every frame.
        script = ("<script>let y=0;function step(){y=(y+3)%20000;window.scrollTo(0,y);requestAnimationFrame(step)}"
                  "requestAnimationFrame(step)</script>")
    rows = "".join(f"<p>row {i} of page {index}: lorem ipsum dolor sit amet consectetur adipiscing elit</p>" for i in range(800))
    return (f"<!doctype html><title>page {index}</title><style>body{{font:14px system-ui;margin:24px}}"
            f".box{{width:240px;height:120px;border-radius:12px;background:linear-gradient(#69c,#36a);margin:8px}}</style>"
            f"<h1>page {index}</h1>" + "<div class=box></div>" * 6 + rows + script).encode()


def serve():
    import http.server

    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            scroll = "scroll" in self.path
            index = "".join(c for c in self.path if c.isdigit()) or "0"
            body = page_body(index, scroll)
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/"


def rpc(method, params=None, timeout=30):
    import socket
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


def action(name, args=None, settle=0.0, timeout=60):
    reply = rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)
    if settle:
        time.sleep(settle)  # test harness: the layout settles before the next step
    return reply


def wait(check, seconds, step=0.1):
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


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def main_thread_seconds():
    """The app's main thread CPU time (user + system) in seconds, from `ps -M` (first thread row)."""
    out = subprocess.run(["ps", "-M", "-p", str(app.pid)], capture_output=True, text=True).stdout.splitlines()
    if len(out) < 2:
        return None

    def secs(value):
        minutes, _, rest = value.partition(":")
        return int(minutes) * 60 + float(rest)
    fields = out[1].split()
    # USER PID TT %CPU STAT PRI STIME UTIME COMMAND (the first thread row carries the command)
    try:
        return secs(fields[6]) + secs(fields[7])
    except (IndexError, ValueError):
        return None


def pump():
    report = rpc("debug.cef") or {}
    return report.get("pump") or {}, report.get("geometry") or {}


def pass_percentiles(before, after):
    """p50/p95 pass time (ms, the bucket's upper bound) from the difference of two pump histograms."""
    bounds = (after.get("pass_bucket_upper_ms") or []) + [float("inf")]
    a, b = after.get("pass_histogram") or [], before.get("pass_histogram") or [0] * len(after.get("pass_histogram") or [])
    counts = [x - y for x, y in zip(a, b)]
    total = sum(counts)
    if not total:
        return None, None, 0

    def at(q):
        seen = 0
        for bound, count in zip(bounds, counts):
            seen += count
            if seen >= q * total:
                return bound
        return bounds[-1]
    return at(0.5), at(0.95), total


class Window:
    """Main thread share, pump work and geometry work between start() and stop()."""

    def start(self):
        self.t0, self.cpu0 = time.time(), main_thread_seconds()
        self.pump0, self.geo0 = pump()
        return self

    def stop(self):
        t1, cpu1 = time.time(), main_thread_seconds()
        pump1, geo1 = pump()
        span = max(t1 - self.t0, 1e-6)
        p50, p95, passes = pass_percentiles(self.pump0, pump1)
        work = (pump1.get("work_ms") or 0) - (self.pump0.get("work_ms") or 0)
        result = {
            "seconds": round(span, 2),
            "main_busy_pct": None if cpu1 is None or self.cpu0 is None else round(100 * (cpu1 - self.cpu0) / span, 1),
            "cef_main_pct": round(100 * work / 1000 / span, 2),
            "passes_per_s": round(passes / span, 1),
            "pass_p50_ms": p50, "pass_p95_ms": p95, "pass_max_ms_ever": pump1.get("max_pass_ms"),
            "long_passes": (pump1.get("long_work_runs") or 0) - (self.pump0.get("long_work_runs") or 0),
        }
        for key in ("clip_builds", "reads", "posts", "skipped_posts"):
            result[f"geo_{key}"] = (geo1.get(key) or 0) - (self.geo0.get(key) or 0)
        result["hosts"] = geo1.get("hosts")
        return result


def frames(run):
    rpc("debug.hangs", {"clear": True})
    rpc("debug.frames", {"action": "start"})
    window = Window().start()
    error = run()
    result = window.stop()
    stats = rpc("debug.frames", {"action": "stop"}) or {}
    hangs = rpc("debug.hangs") or {}
    result.update(error=error, frames=stats.get("frames"), frames_p50_ms=stats.get("p50_ms"), frames_p95_ms=stats.get("p95_ms"),
                  frames_max_ms=stats.get("max_ms"), missed=stats.get("missed"), refresh_ms=stats.get("refresh_ms"),
                  hangs=hangs.get("count"))
    return result


def divider():
    result = rpc("debug.layers")
    window = ((result or {}).get("windows") or [{}])[0] if isinstance(result, dict) else {}
    height = (window.get("frame") or [0, 0, 0, WINDOW[3]])[3]
    areas = sorted((x + w / 2, height - (y + h / 2)) for x, y, w, h in window.get("divider_areas_in_window") or [] if h > w)
    return areas[0] if areas else None


def drag():
    point = divider()
    if not point:
        return "no vertical divider"
    x0, y0 = point
    rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
    x = x0
    for delta in [3.0] * 40 + [-3.0] * 40:
        rpc("debug.mouse", {"action": "drag", "x": x, "y": y0, "to_x": x + delta, "to_y": y0, "steps": 1,
                            "press": False, "release": False})
        x += delta
        time.sleep(1 / 120)  # test harness: one pointer event per 120 Hz frame
    rpc("debug.mouse", {"action": "up", "x": x, "y": y0})
    time.sleep(0.5)  # test harness: the last frames land
    return None


def switch_tabs(count):
    rpc("debug.tab_switch", {"action": "start"})
    for _ in range(count):
        rpc("debug.key", {"key": "tab", "modifiers": ["control"]})
        time.sleep(0.25)  # test harness pacing: one switch, then its page paints
    time.sleep(1.0)  # test harness: the last commit lands
    own = rpc("debug.tab_switch", {"action": "stop"}) or {}
    # Warm switches only (a tab's first show creates its page: "cold").
    rows = [s for s in own.get("switches") or [] if s.get("kind") != "cold"]
    applies = sorted(s["apply_ms"] for s in rows if "apply_ms" in s)
    late = sum(1 for s in rows if (s.get("late_vsyncs") or 0) > 0)

    def pct(q):
        return round(applies[min(len(applies) - 1, int(q * len(applies)))], 2) if applies else None
    return {"switches": len(rows), "apply_p50_ms": pct(0.5), "apply_p95_ms": pct(0.95), "late_switches": late,
            "kinds": sorted({s.get("kind", "?") for s in rows})}


def profile_drags(count, repeats=4):
    """Samples the app (1 ms) over `repeats` divider drags; prints the main thread's heaviest symbols
    (inclusive samples of frames named like cmux, CEF, AppKit or Core Animation code)."""
    path = os.path.join(opts.out, f"sample-drag-{count}.txt")
    seconds = repeats * 2 + 2
    sampler = subprocess.Popen(["/usr/bin/sample", str(app.pid), str(seconds), "1", "-mayDie", "-file", path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)  # test harness: the sampler attaches
    for _ in range(repeats):
        drag()
    sampler.wait(timeout=seconds + 60)
    try:
        text = open(path, errors="replace").read()
    except OSError:
        print("  (no sample)", flush=True)
        return
    import re
    graph = text.split("Call graph:", 1)[-1]
    lines = graph.splitlines()
    start = next((i for i, l in enumerate(lines) if "com.apple.main-thread" in l), None)
    if start is None:
        print("  (no main thread in the sample)", flush=True)
        return
    node = re.compile(r"^([ +!:|]*)(\d+) (.*)$")
    head = node.match(lines[start])
    total, base = int(head.group(2)), len(head.group(1))
    best = {}
    path_symbols = []
    for line in lines[start + 1:]:
        m = node.match(line)
        if not m:
            continue
        depth = len(m.group(1))
        if depth <= base:
            break
        while path_symbols and path_symbols[-1][0] >= depth:
            path_symbols.pop()
        symbol = re.sub(r"\s+\(in [^)]*\).*$", "", m.group(3)).strip()[:140]
        if all(sym != symbol for _, sym in path_symbols):
            best[symbol] = best.get(symbol, 0) + int(m.group(2))
        path_symbols.append((depth, symbol))
    print(f"\n== sample: {repeats} drags, {count} tabs, main thread {total} samples (1 ms each); heaviest inclusive symbols", flush=True)
    keys = ("CmuxNext", "CEF", "cef", "Cmux", "NSView", "NSWindow", "CA::", "layout", "Layout", "postNotification", "NSNotification")
    shown = 0
    for symbol, samples in sorted(best.items(), key=lambda kv: -kv[1]):
        if any(k in symbol for k in keys):
            print(f"  {samples:>6} {100.0 * samples / max(total, 1):5.1f}%  {symbol}", flush=True)
            shown += 1
            if shown >= 45:
                break


def build(count, base):
    action("workspace.newAtBottom", settle=1.5)
    for index in range(count):
        reply = action("openBrowser.chromium", {"url": f"{base}p{index}"}, timeout=120)
        if isinstance(reply, dict) and reply.get("error"):
            print(f"  (tab {index}: {reply})", flush=True)
        time.sleep(0.4)  # test harness: one tab at a time
    action("splitRight", settle=1.0)
    action("focusLeft", settle=0.5)
    time.sleep(4.0)  # test harness: the pages load and settle


def med(values):
    values = sorted(v for v in values if v is not None)
    return values[len(values) // 2] if values else None


def cleanup():
    if os.environ.get("CEF_PERF_KEEP") or not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)  # the app this script launched
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(str(v) for v in WINDOW)}
    os.makedirs(opts.out, exist_ok=True)
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    LAUNCHED.append(app.pid)
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
    sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    print(f"launched pid {app.pid} macOS {macos} host {host} sha {sha}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        print(f"the tagged app did not come up: alive={app.poll() is None}", flush=True)
        log.flush()
        print(open(os.path.join(opts.out, f"app-{TAG}.log"), errors="replace").read()[-6000:], flush=True)
        sys.exit(1)
    time.sleep(5)  # test harness: launch work settles
    base = serve()
    report = {"tag": TAG, "macos": macos, "host": host, "sha": sha, "runs": []}
    for count in [int(v) for v in opts.tabs.split(",")]:
        build(count, base)
        state = rpc("debug.cef") or {}
        print(f"CEF-PERF {count} tabs: cef state {state.get('state')} hosts {(state.get('geometry') or {}).get('hosts')}", flush=True)
        row(f"{count} tabs: Chromium runs", "state running/ready", str(state.get("state")), bool(state.get("pump")))
        for index in range(opts.rounds):
            idle = Window().start()
            time.sleep(opts.idle)  # the measured idle interval
            runs = {"idle": idle.stop()}
            runs["drag"] = frames(drag)
            runs["switch"] = switch_tabs(max(count, 6)) if count > 1 else None
            for name, result in runs.items():
                if result is None:
                    continue
                print(f"CEF-PERF {count:>2} tabs #{index} {name:<6} " + json.dumps(result), flush=True)
                report["runs"].append({"tabs": count, "round": index, "step": name, **result})
            time.sleep(0.5)  # test harness: idle between rounds
        if opts.sample and count == max(int(v) for v in opts.tabs.split(",")):
            profile_drags(count)
        # The scroll page last: it keeps the browser busy until the workspace closes.
        action("openBrowser.chromium", {"url": f"{base}scroll"}, timeout=120)
        time.sleep(2.0)  # test harness: the page loads and starts scrolling
        for index in range(opts.rounds):
            result = frames(lambda: time.sleep(opts.scroll))  # the measured scrolling interval
            print(f"CEF-PERF {count:>2} tabs #{index} scroll " + json.dumps(result), flush=True)
            report["runs"].append({"tabs": count, "round": index, "step": "scroll", **result})
        action("closeWorkspace", settle=2.0)
        if opts.json:
            json.dump(report, open(opts.json, "w"), indent=1)
    print("\n== summary (median over rounds)")
    keys = ["frames_p50_ms", "frames_p95_ms", "frames_max_ms", "missed", "main_busy_pct", "cef_main_pct", "passes_per_s",
            "pass_p50_ms", "pass_p95_ms", "long_passes", "geo_clip_builds", "geo_reads", "geo_posts", "geo_skipped_posts",
            "apply_p50_ms", "apply_p95_ms", "late_switches"]
    for count in [int(v) for v in opts.tabs.split(",")]:
        for step in ("idle", "drag", "switch", "scroll"):
            runs = [r for r in report["runs"] if r["tabs"] == count and r["step"] == step]
            if not runs:
                continue
            summary = {key: med([r.get(key) for r in runs]) for key in keys if any(r.get(key) is not None for r in runs)}
            report.setdefault("summary", []).append({"tabs": count, "step": step, **summary})
            print(f"  {count:>2} tabs {step:<6} " + "  ".join(f"{k}={v}" for k, v in summary.items()), flush=True)
    if opts.json:
        json.dump(report, open(opts.json, "w"), indent=1)


try:
    main()
except Exception:  # the step log is stdout only
    import traceback
    traceback.print_exc(file=sys.stdout)
finally:
    cleanup()
    if opts.json and os.path.exists(opts.json):
        print("REPORT-JSON " + json.dumps(json.load(open(opts.json)).get("summary") or []), flush=True)
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
