#!/usr/bin/env python3
"""Live perf check of the sidebar rows path (sidebar-v2 rows lane) on a tagged app.

  scripts/cmux-next/sidebar-rows-perf-live.py --tag <tag> [--label NAME] [--out DIR]
      [--count 1000] [--ticking 50] [--tick-ms 250] [--seconds 20] [--scroll-steps 120]
  scripts/cmux-next/sidebar-rows-perf-live.py --app <cmux DEV tag.app> [...]   (the perf lab story)

With --tag it attaches to the running app of that tag and never launches or quits one. With --app it
launches that app through bench_launch.BenchApp (the bench env, a fresh saved session) and quits it
and the tag's daemons at the end. Run it on a GUI lane host such as cmux-lawrence-2, never the
laptop. It makes `--count` workspaces: `--ticking` of them
with a terminal, the others empty (`workspace create --empty`, so 1,000 rows need no 1,000
PTYs). Then:

  ticks:  each ticking terminal's program reports OSC 7501 every `--tick-ms`, alternating
          `working` and `idle` (each report changes the row's status), for `--seconds`.
          Measured: the app's CPU time per tick (proc_pid_rusage), the main-thread reply delay
          of a cheap main-actor debug call sampled every 50 ms (a stall shows as a slow reply),
          and, when the build serves `debug.sidebar_perf`, its counters.
  scroll: in the window that lists the perf rows (`debug.sidebar_rows` window id; every scroll call
          names it, so the probe and the wheel use one window): a hit probe, a mouse-wheel check
          (`debug.sidebar_wheel`, line events) and a real trackpad gesture (`debug.mouse` scroll
          with phases, 60 events/s, `--gesture-events` down and back up), once with the tick
          programs stopped and once with them running. Measured: display frame intervals
          (`debug.frames` p50/p95/p99/max, missed vsyncs), xctrace Animation Hitches for the app
          (unless --no-trace), the counters, and that the list moved (realized rows changed).
  --profile: an xctrace Time Profiler recording of the tick window: main-thread top frames, and
          the frames of main-thread busy runs over 30 ms (the long replies). Also `debug.hangs`
          (the watchdog's stall records with their stacks) for the tick window.

With counters (a build of the rows lane) it asserts: no structural rebuild and no list reload
during the ticks; row configures stay at or under the row patches (one realized row per changed
row) and are not 0 when a ticking row is on screen; no list reload during the scroll. A build
without `debug.sidebar_perf` (the base) is measured only. Writes summary-<label>.json to --out;
with --app, also the raw samples as result-v1 (story sidebar-rows-live, sidebar_bench_report.py: the
tick reply delays, CPU and main time per tick, each scroll mode's event RPC times, and the hitch total
and hitch time ratio of each valid recording); exits 1 when an assertion fails. Every percentile is perf_stats.pct (p50, p95, p99).
"""
import argparse, json, os, shutil, socket, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

parser = argparse.ArgumentParser()
parser.add_argument("--tag", help="attach to the running app of this tag")
parser.add_argument("--app", help="launch this app through BenchApp (instead of --tag)")
parser.add_argument("--label", default="run")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--count", type=int, default=1000)
parser.add_argument("--ticking", type=int, default=50)
parser.add_argument("--tick-ms", type=int, default=250)
parser.add_argument("--seconds", type=float, default=20)
parser.add_argument("--scroll-steps", type=int, default=120)
parser.add_argument("--pid", type=int, help="the app's pid (default: found from the tag's app path)")
parser.add_argument("--gesture-events", type=int, default=300, help="trackpad events per direction (60 per second)")
parser.add_argument("--profile", action="store_true", help="Time Profiler of the tick window (main-thread stall frames)")
parser.add_argument("--no-trace", action="store_true", help="no Animation Hitches recording of the scroll")
parser.add_argument("--skip-create", action="store_true", help="use the perf workspaces an earlier run made")
parser.add_argument("--repeats", type=int, default=1,
                    help="valid scroll recordings per mode (the median by hitch total is the result; each is in `runs`)")
parser.add_argument("--hover-per-event", action="store_true",
                    help="move the synthesized pointer on every gesture event (round-1 harness; adds a hover recompute per event)")
opts = parser.parse_args()
if not opts.tag and not opts.app:
    parser.error("pass --tag (a running app) or --app (launch it)")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # the bench modules, also under `python3 -I`
import sidebar_bench_report as report  # noqa: E402
from bench_launch import BenchApp, socket_candidates, tag_of  # noqa: E402

if opts.app:
    app_tag = tag_of(os.path.realpath(opts.app))
    if opts.tag and opts.tag != app_tag:
        parser.error(f"--tag {opts.tag} is not the tag of --app ({app_tag})")
    opts.tag = app_tag
SOCKET = socket_candidates(opts.tag)[0] if opts.app else f"/tmp/cmux-debug-{opts.tag}.sock"
BENCH = None  # the BenchApp of the app this script launched (--app)

CLI = os.path.join(HERE, "..", "cmux-debug-cli.sh")
FRAME_MS = 1000 / 60
failures = []
summary = {"label": opts.label, "tag": opts.tag, "count": opts.count, "ticking": opts.ticking,
           "tick_ms": opts.tick_ms, "seconds": opts.seconds}
# The raw samples behind the summary's percentiles, for result-v1 (report.live_series).
raw = {"ticks": {}, "scrolls": {}}


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
    """The pid of the app: the one this script launched, else --pid, else the process running the tag's bundle."""
    if BENCH is not None:
        return BENCH.process.pid
    return opts.pid or report.running_bundle(opts.tag)[0]


def cpu_ns(pid):
    from bench_idle import usage  # noqa: E402
    sample = usage(pid) if pid else None
    return sample[0] if sample else None


def counters(reset=False):
    reply = rpc("debug.sidebar_perf", {"reset": reset})
    return None if not isinstance(reply, dict) or "error" in reply else reply


def workspace_rows(window=None):
    windows = (rpc("debug.sidebar_rows", timeout=120) or {}).get("windows") or []
    return [r for w in windows if window is None or w.get("window") == window
            for r in w.get("rows") or [] if str(r.get("key", "")).startswith("workspace")]


def perf_window():
    """The id of the window whose sidebar shows the most perf rows (the app can hold more windows;
    `debug.sidebar_wheel` and `debug.mouse` default to the first one, which may not list them)."""
    windows = (rpc("debug.sidebar_rows", timeout=120) or {}).get("windows") or []
    def shown(w):
        return sum(1 for r in w.get("rows") or [] if str(r.get("title") or "").startswith("perf-") and r.get("view_frame"))
    best = max(windows, key=shown, default=None)
    summary["windows"] = [{"window": w.get("window"), "perf_rows_realized": shown(w), "rows": len(w.get("rows") or [])} for w in windows]
    check(best is not None and shown(best) > 0, f"a window shows perf rows ({summary['windows']})")
    return best.get("window") if best and shown(best) > 0 else None


def latency_stats(values):
    return report.latency_stats(values, FRAME_MS)


def make_workspaces():
    have = {r.get("title") for r in workspace_rows()}
    empty = [f"perf-{i:04d}" for i in range(opts.count - opts.ticking) if f"perf-{i:04d}" not in have]
    ticking = [f"perf-tick-{i:02d}" for i in range(opts.ticking) if f"perf-tick-{i:02d}" not in have]
    rpc("debug.hangs", {"clear": True})
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
    # Window membership while 1,000 workspaces arrive: no stall in reconcileMembership (it was
    # O(n^2) in WindowRegistry.owner(of:)), and the registry stays consistent.
    hangs = hang_records(rpc("debug.hangs", {}))
    membership = [h for h in hangs if any("reconcileMembership" in f or "WindowRegistry" in f for f in h["frames"])]
    summary["create_hangs"] = hangs[:12]
    check(not membership, f"create: no main-thread stall in window membership ({[h['ms'] for h in membership]})")
    windows = rpc("debug.windows") or {}
    summary["windows_consistent"] = windows.get("consistent")
    check(windows.get("consistent") is not False, f"create: window invariants hold ({(windows.get('problems') or [])[:3]})")


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


def start_ticks(terms, seconds):
    """Starts each ticking terminal's OSC 7501 loop for `seconds` (it ends by itself, then idle)."""
    ticks_each = int(seconds * 1000 / opts.tick_ms)
    interval = opts.tick_ms / 1000
    loop = (f"i=0; while [ $i -lt {ticks_each} ]; do if [ $((i % 2)) = 0 ]; then s=working; else s=idle; fi; "
            f"printf '\\033]7501;state=%s\\033\\\\' $s; sleep {interval}; i=$((i + 1)); done; printf '\\033]7501;state=idle\\033\\\\'\n")
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda term: cli("terminal", term, "write", "--text", loop), terms))
    return ticks_each


class Trace:
    """An xctrace recording attached to the app for the `with` body. `seconds` is the measured window;
    the recording also covers the 4 s attach wait before it and 2 s after it."""

    def __init__(self, pid, name, seconds, template):
        self.path = os.path.join(opts.out, "traces", f"{opts.label}-{name}.trace")
        self.pid, self.seconds, self.template, self.proc = pid, int(seconds) + 6, template, None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        if os.path.exists(self.path):
            shutil.rmtree(self.path)
        self.proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", self.template, "--attach", str(self.pid),
                                      "--time-limit", f"{self.seconds}s", "--output", self.path, "--no-prompt"],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        time.sleep(4)  # test script: the recorder attaches before the measured window
        return self

    def __exit__(self, *exc):
        try:
            out, _ = self.proc.communicate(timeout=self.seconds + 240)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            out = "timeout"
        if self.proc.returncode != 0:
            print(f"xctrace {self.template} exit {self.proc.returncode}: {(out or '')[-300:]}", flush=True)
        return False


def export_table(trace, schema):
    import xml.etree.ElementTree as ET
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                          f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], capture_output=True, text=True).stdout
    root = ET.fromstring(xml)
    ids = {}

    def resolve(element):
        ref = element.get("ref")
        if ref is not None:
            return ids.get(ref, element)
        if element.get("id") is not None:
            ids[element.get("id")] = element
        for child in element:
            resolve(child)
        return element

    for row in root.iter("row"):
        yield [(child.tag, resolve(child)) for child in row], ids


GENERIC = ("main", "start", "NSApplicationMain", "-[NSApplication run]", "_DPSNextEvent", "CFRunLoopRun", "__CFRunLoop",
           "_CFRunLoopRun", "-[NSApplication(NSEvent) _nextEventMatchingEventMask", "_BlockUntilNextEventMatchingListInMode",
           "ReceiveNextEventCommon", "RunCurrentEventLoopInMode", "_dispatch_main_queue", "__CFRUNLOOP", "_dispatch_", "?",
           "_DPSBlockUntilNextEventMatchingListInMode", "-[NSApplication(NSEventRouting)", "withExtendedLifetime",
           "__debug_main_executable_dylib_entry_point", "CmuxNextApp.main()", "closure #1 in CmuxNextApp.main()",
           "partial apply for closure #1 in CmuxNextApp.main()", "swift_job_run", "swift::runJobInEstablishedExecutorContext")


def top(counter, total, limit):
    return [{"frame": n[:220], "samples": c, "pct": round(100.0 * c / total, 1) if total else 0}
            for n, c in sorted(counter.items(), key=lambda kv: -kv[1]) if not n.startswith(GENERIC)][:limit]


def main_thread_profile(trace):
    """Main-thread Time Profiler samples: top inclusive and leaf frames, and the frames of busy runs
    (consecutive main-thread samples, gap under 3 ms) longer than 30 ms: what a slow reply waited for."""
    samples = []
    try:
        for cells, ids in export_table(trace, "time-profile"):
            thread = next((n for t, n in cells if t == "thread"), None)
            if thread is None or "Main Thread" not in (thread.get("fmt") or ""):
                continue
            when = next((n for t, n in cells if t == "sample-time"), None)
            bt = next((n for t, n in cells if t in ("backtrace", "tagged-backtrace")), None)
            if bt is not None and bt.tag != "backtrace":
                bt = next(iter(bt.iter("backtrace")), bt)
            frames = [ids.get(f.get("ref"), f).get("name") or "?" for f in bt.iter("frame")] if bt is not None else []
            samples.append((int(when.text) if when is not None and (when.text or "").isdigit() else 0, frames))
    except Exception as error:  # noqa: BLE001 (export failures are reported, the run goes on)
        return {"error": f"export: {error}"}
    samples.sort(key=lambda s: s[0])
    inclusive, leaf, runs = {}, {}, []
    current = []
    for when, frames in samples:
        if frames:
            leaf[frames[0]] = leaf.get(frames[0], 0) + 1
        for name in set(frames):
            inclusive[name] = inclusive.get(name, 0) + 1
        if current and when - current[-1][0] > 3_000_000:
            runs.append(current)
            current = []
        current.append((when, frames))
    if current:
        runs.append(current)
    long_runs = [r for r in runs if (r[-1][0] - r[0][0]) / 1e6 >= 30]
    stall = {}
    for run in long_runs:
        for _, frames in run:
            for name in set(frames):
                stall[name] = stall.get(name, 0) + 1
    stall_samples = sum(len(r) for r in long_runs)
    return {"main_samples": len(samples), "top_inclusive": top(inclusive, len(samples), 50), "top_leaf": top(leaf, len(samples), 25),
            "busy_runs_over_30ms": len(long_runs),
            "busy_run_ms": sorted((round((r[-1][0] - r[0][0]) / 1e6, 1) for r in long_runs), reverse=True)[:20],
            "stall_samples": stall_samples, "stall_top_inclusive": top(stall, stall_samples, 50)}


def hitches(trace, pid):
    """Animation Hitches rows for the app: count and durations."""
    durations, rows = [], 0
    try:
        for cells, _ in export_table(trace, "hitches"):
            process = next((n for t, n in cells if t == "process"), None)
            if process is None or f"({pid})" not in (process.get("fmt") or ""):
                continue
            rows += 1
            duration = next((n for t, n in cells if t == "duration"), None)
            if duration is not None and (duration.text or "").isdigit():
                durations.append(int(duration.text) / 1e6)
    except Exception as error:  # noqa: BLE001
        return {"error": f"export: {error}"}
    # The app's update (its transaction, begin to commit) per frame: an update longer than a
    # frame is what Instruments calls "Potentially expensive app update(s)".
    updates = []
    try:
        for cells, _ in export_table(trace, "hitches-updates"):
            process = next((n for t, n in cells if t == "process"), None)
            duration = next((n for t, n in cells if t == "duration"), None)
            if process is not None and f"({pid})" in (process.get("fmt") or "") and duration is not None and (duration.text or "").isdigit():
                updates.append(int(duration.text) / 1e6)
    except Exception:  # noqa: BLE001 (an older trace without the table)
        pass
    return {"hitches": rows, "p50_ms": report.pct(durations, 50), "p95_ms": report.pct(durations, 95),
            "p99_ms": report.pct(durations, 99),
            "max_ms": round(max(durations), 2) if durations else None, "total_ms": round(sum(durations), 1),
            "app_updates": len(updates), **report.update_stats(updates),
            "updates_over_8_3_ms": len([u for u in updates if u > 8.34])}


def hang_records(reply):
    out = []
    for record in (reply or {}).get("records") or []:
        frames = [f for f in record.get("frames") or [] if "cmux" in f.lower() or "Cmux" in f][:10]
        out.append({"ms": round(record.get("duration_ms", 0), 1), "frames": frames or (record.get("frames") or [])[:10]})
    return sorted(out, key=lambda r: -r["ms"])


def tick_phase(pid):
    terms = ticking_terminals()
    summary["terms"] = terms
    summary["ticking_terminals"] = len(terms)
    check(len(terms) >= min(opts.ticking, 1), f"{len(terms)} ticking terminals")
    summary["visible_ticking_rows"] = visible_ticking()
    time.sleep(3)  # test script: let the creates settle before the measured window
    base = counters(reset=True)
    rpc("debug.hangs", {"clear": True})
    cpu0 = cpu_ns(pid)
    stop, samples = threading.Event(), []
    trace = Trace(pid, "ticks-time-profile", opts.seconds + 1, "Time Profiler") if opts.profile else None
    if trace:
        trace.__enter__()
    thread = threading.Thread(target=sampler, args=(stop, samples))
    thread.start()
    ticks_each = start_ticks(terms, opts.seconds)
    time.sleep(opts.seconds + 1)  # test script: the measured window is the ticks themselves
    stop.set()
    thread.join()
    cpu1 = cpu_ns(pid)
    hangs = rpc("debug.hangs", {})
    if trace:
        trace.__exit__(None, None, None)
    ticks = ticks_each * len(terms)
    # With --profile the app CPU includes Time Profiler sampling: compare CPU only between runs alike.
    raw["ticks"]["reply_ms"] = list(samples)
    result = {"ticks": ticks, "latency": latency_stats(samples), "hangs": hang_records(hangs)[:12], "profiled": opts.profile,
              "hang_count": (hangs or {}).get("count"), "hang_max_ms": (hangs or {}).get("max_ms")}
    if cpu0 is not None and cpu1 is not None:
        result["app_cpu_ms"] = round((cpu1 - cpu0) / 1e6, 1)
        result["app_cpu_us_per_tick"] = round((cpu1 - cpu0) / 1e3 / max(ticks, 1), 1)
        if not opts.profile:  # Time Profiler sampling adds to the app's CPU: no result-v1 from a profiled run
            raw["ticks"]["cpu_us_per_tick"] = (cpu1 - cpu0) / 1e3 / max(ticks, 1)
    if trace and os.path.exists(trace.path):
        result["profile"] = main_thread_profile(trace.path)
        result["trace"] = os.path.relpath(trace.path, opts.out)
    after = counters()
    if base is not None and after is not None:
        result["counters"] = after
        result["main_us_per_tick"] = round(after.get("main_ns", 0) / 1e3 / max(ticks, 1), 1)
        raw["ticks"]["main_us_per_tick"] = after.get("main_ns", 0) / 1e3 / max(ticks, 1)
        visible = summary["visible_ticking_rows"]
        check(after.get("rebuilds", 0) == 0, f"ticks: no structural rebuild (rebuilds {after.get('rebuilds')})")
        check(after.get("list_reloads", 0) == 0, f"ticks: no list reload (list_reloads {after.get('list_reloads')})")
        check(after.get("row_configures", 0) <= after.get("row_patches", 0),
              f"ticks: row configures {after.get('row_configures')} <= row patches {after.get('row_patches')}")
        if visible:
            check(after.get("row_configures", 0) > 0, f"ticks: {visible} visible ticking rows were configured")
        result["expected_configures_visible"] = ticks_each * visible
    summary["ticks"] = result
    printable = {k: v for k, v in result.items() if k != "profile"}
    print("ticks:", json.dumps(printable)[:3000], flush=True)
    if result.get("profile"):
        prof = result["profile"]
        print("ticks profile: main samples", prof.get("main_samples"), "busy runs >30ms", prof.get("busy_run_ms"), flush=True)
        for entry in (prof.get("stall_top_inclusive") or [])[:30]:
            print(f"  stall {entry['pct']:5.1f}% {entry['frame'][:160]}", flush=True)


def quiet():
    """Waits until the tick programs have ended."""
    time.sleep(max(5, opts.seconds * 0.3))  # test script: the tick loops end a little after --seconds
    if counters() is None:
        return
    deadline, last = time.monotonic() + 30, None
    while time.monotonic() < deadline:  # bounded wait: no row patch for 2 s
        now = counters().get("row_patches")
        if now == last:
            return
        last = now
        time.sleep(2)


def realized_titles(window):
    return [r.get("title") for r in workspace_rows(window) if r.get("view_frame")]


def probe_point(window):
    """A point over the workspace list of `window` whose hit view is a workspace row or the list."""
    rows = [r for r in workspace_rows(window) if r.get("view_frame") and (r.get("window_frame") or {}).get("y", -1) > 0]
    if not rows:
        return None, []
    picks = [rows[i] for i in sorted({min(2, len(rows) - 1), len(rows) // 4, len(rows) // 3, len(rows) // 2})]
    candidates = [{"x": f["x"] + dx, "y": f["y"] + f["height"] / 2}
                  for f in (r["window_frame"] for r in picks)  # {x, y, width, height}, window points from the top left
                  for dx in (f["width"] / 2, 4, f["width"] - 6)]
    hits = [(c, (rpc("debug.sidebar_wheel", dict(c, window=window, dy=0, count=1)) or {}).get("hit")) for c in candidates]
    point = next((c for c, hit in hits if hit and ("WorkspaceRow" in hit or "SidebarList" in hit)), None) \
        or next((c for c, hit in hits if hit and "SidebarItemRowView" not in hit), None)
    return point, [hit for _, hit in hits]


def scroll_to_top(window, point):
    for _ in range(3):
        rpc("debug.mouse", dict(point, window=window, action="scroll", dy=100000, phase="began"))
        rpc("debug.mouse", dict(point, window=window, action="scroll", dy=0, phase="ended"))


def gesture(window, point, events, dy):
    """One trackpad gesture: `events` scroll events at 60 per second; per-event RPC times.
    Only the first event moves the synthesized pointer (`hover: false` after it): every pointer move
    recomputes each hover target in the window (PointerHover.refresh), which is harness work, not
    scroll work (30-40% of the main thread in the round-1 scroll profiles). An app without the
    parameter ignores it (and so measures with the per-event hover refresh)."""
    times = []
    phases = ["began"] + ["changed"] * (events - 2) + ["ended"]
    for index, phase in enumerate(phases):
        t0 = time.perf_counter()
        params = dict(point, window=window, action="scroll", dy=dy, phase=phase)
        if index > 0 and not opts.hover_per_event:
            params["hover"] = False
        ms, _ = timed_rpc("debug.mouse", params)
        times.append(ms)
        rest = 1 / 60 - (time.perf_counter() - t0)
        if rest > 0:
            time.sleep(rest)  # 60 events per second, as a trackpad sends them
    return times


def scroll_mode(pid, window, label, terms):
    point, probe = probe_point(window)
    print(f"scroll {label}: window {window} probe hits {probe}", flush=True)
    check(point is not None, f"scroll {label}: a probe point in window {window} hits the workspace list ({probe})")
    if point is None:
        return {"probe": probe}
    result = {"window": window, "point": point, "probe": probe}
    # The mouse wheel path (`debug.sidebar_wheel`, line events) in the same window.
    scroll_to_top(window, point)
    before = realized_titles(window)
    counters(reset=True)
    wheel = [timed_rpc("debug.sidebar_wheel", dict(point, window=window, dy=-5, count=1)) for _ in range(40)]
    result["wheel_routes"] = sorted({r for _, reply in wheel for r in (reply or {}).get("routes") or []})
    deadline = time.monotonic() + 3
    wheel_moved = realized_titles(window) != before
    while not wheel_moved and time.monotonic() < deadline:  # bounded wait: AppKit's smooth-scroll animation of line events
        time.sleep(0.2)
        wheel_moved = realized_titles(window) != before
    # Informational: right after a scroll-to-top gesture, line wheel events posted at once sometimes
    # do not move the list (mac26, no ticks); the measured path is the trackpad gesture below.
    result["wheel_moved"] = wheel_moved
    print(f"{'info' if wheel_moved else 'note'} scroll {label}: the mouse wheel moved the list: {wheel_moved}", flush=True)
    # The trackpad gesture, measured.
    scroll_to_top(window, point)
    time.sleep(1)
    before = realized_titles(window)
    seconds = opts.gesture_events * 2 / 60 + 2
    attempts = opts.repeats * 2  # a recording that fails (another xctrace on the host) or saw no app updates runs again
    if terms:
        start_ticks(terms, (seconds + 10) * attempts)
        time.sleep(1)
    counters(reset=True)
    runs, moved, down, up, frames = [], False, [], [], None
    for attempt in range(attempts):
        if len([r for r in runs if r.get("valid")]) >= opts.repeats:
            break
        trace = None if opts.no_trace else Trace(pid, f"scroll-{label}-hitches-{attempt + 1}", opts.gesture_events / 60 + 1, "Animation Hitches")
        if trace:
            trace.__enter__()
        rpc("debug.frames", {"action": "start"})
        started = time.perf_counter()
        d = gesture(window, point, opts.gesture_events, -60.0)
        gesture_s = time.perf_counter() - started  # the recorded gesture: the hitch ratio's denominator
        moved = moved or realized_titles(window) != before
        if trace:
            trace.__exit__(None, None, None)
        u = gesture(window, point, opts.gesture_events, 60.0)
        f = rpc("debug.frames", {"action": "stop"})
        down, up, frames = down + d, up + u, f
        run = {"frames": f}
        if trace and os.path.exists(trace.path):
            run["hitches"] = hitches(trace.path, pid)
            ratio = report.hitch_ratio(run["hitches"].get("total_ms"), gesture_s)
            if ratio is not None:
                run["hitches"]["hitch_ratio_pct"] = round(ratio, 3)
            run["hitches_trace"] = os.path.relpath(trace.path, opts.out)
        # Valid: the recording worked and the app drew (an occluded or sleeping window commits nothing).
        h = run.get("hitches") or {}
        run["valid"] = bool(trace) and "error" not in h and (h.get("app_updates") or 0) >= opts.gesture_events // 3
        runs.append(run)
        print(f"scroll {label} run {attempt + 1}: valid {run['valid']} hitches {h.get('hitches')} total {h.get('total_ms')} "
              f"updates {h.get('app_updates')} p99 {(f or {}).get('p99_ms')}", flush=True)
    valid = sorted((r for r in runs if r.get("valid")), key=lambda r: r["hitches"].get("total_ms") or 0)
    pick = valid[len(valid) // 2] if valid else (runs[-1] if runs else {})
    raw["scrolls"][label.replace("-", "_")] = {
        "event_rpc_ms": down + up, "hitch_total_ms": [r["hitches"].get("total_ms") for r in valid],
        "hitch_ratio": [r["hitches"].get("hitch_ratio_pct") for r in valid]}
    result.update({"frames": pick.get("frames") or frames, "event_rpc": latency_stats(down + up), "moved_down": moved,
                   "runs": runs, "valid_runs": len(valid)})
    if "hitches" in pick:
        result["hitches"], result["hitches_trace"] = pick["hitches"], pick.get("hitches_trace")
    if not opts.no_trace:
        check(len(valid) >= opts.repeats, f"scroll {label}: {len(valid)} valid hitch recordings of {opts.repeats}")
    check(moved, f"scroll {label}: the trackpad gesture moved the list (realized rows changed: {moved})")
    after = counters()
    if after is not None:
        result["counters"] = after
        check(after.get("rebuilds", 0) == 0, f"scroll {label}: no structural rebuild (rebuilds {after.get('rebuilds')})")
        if not terms:
            check(after.get("list_reloads", 0) == 0, f"scroll {label}: no list reload (list_reloads {after.get('list_reloads')})")
        check(after.get("scroll_realizes", 0) > 0, f"scroll {label}: rows realized while scrolling ({after.get('scroll_realizes')})")
    if terms:
        quiet()
    print(f"scroll {label}:", json.dumps(result), flush=True)
    return result


def scroll_phase(pid):
    quiet()
    window = perf_window()
    summary["scroll_window"] = window
    if window is None:
        return
    terms = summary.get("terms") or []
    summary["scroll"] = scroll_mode(pid, window, "no-ticks", [])
    summary["scroll_ticking"] = scroll_mode(pid, window, "ticking", terms)


def launch():
    """--app: launches it through BenchApp; SOCKET and CLI then name its socket and its own CLI (a fleet-built bundle
    has no DerivedData build for cmux-debug-cli.sh to find)."""
    global BENCH, SOCKET, CLI
    BENCH = BenchApp(opts.app, out=opts.out, perf_session=report.SESSION)
    BENCH.launch()
    SOCKET, CLI = BENCH.socket, BENCH.cli


def write_summary():
    os.makedirs(opts.out, exist_ok=True)
    path = os.path.join(opts.out, f"summary-{opts.label}.json")
    with open(path, "w") as out:
        json.dump(summary, out, indent=2)
    return path


def measure():
    if "error" in (rpc("debug.layout_counters") or {"error": 1}):
        sys.exit(f"no tagged app answering on {SOCKET}")
    summary["has_counters"] = counters() is not None
    pid = app_pid()
    summary["pid"] = pid
    if not opts.skip_create:
        make_workspaces()
    tick_phase(pid)
    scroll_phase(pid)
    summary["failures"] = failures
    path = write_summary()
    # result-v1 only from an app this script launched (its launch env is BenchApp's), and after the summary is on
    # disk, so a failure here cannot lose it.
    if BENCH is None:
        summary["result_v1"] = "not recorded: attached to an app this bench did not launch (--tag)"
    else:
        summary["result_v1"] = report.record_all(BENCH, report.live_series(opts.count, raw["ticks"], raw["scrolls"]))
    write_summary()
    print(f"summary: {path}", flush=True)
    print(json.dumps(summary), flush=True)
    print(f"{len(failures)} failure(s)", flush=True)


def main():
    try:
        if opts.app:
            launch()
        measure()
    finally:
        if BENCH is not None:
            BENCH.stop()
    sys.exit(1 if failures else 0)


main()
