#!/usr/bin/env python3
"""Tab switch latency, CPU and memory per tab kind and tab count, in a real window (tab-switch-rewrite).

Launches a tagged cmux-next app (no activation, scratch config, empty Ghostty config, test window on
the last screen). For each tab kind in --kinds and each count in --counts it makes a workspace whose
one pane holds that many tabs of that kind (plus the workspace's first terminal), visits every tab once
(warm), then measures:

  idle       app + Chromium helpers + daemon CPU % and physical footprint over --idle seconds, with the
             tabs parked; per hidden tab = (footprint - the empty baseline) / count
  switches   Ctrl-Tab, Cmd-Shift-], and clicks on the strip's visible tabs (`debug.key` / `debug.mouse`:
             the app's real key router and AppKit mouse path), one every --interval seconds; per switch
             `debug.tab_switch` gives input (event age at the intent), apply (intent -> shown), commit
             (the Core Animation commit carrying it) and late_vsyncs (frames it missed: 0 = the first
             frame it could reach), plus every stage mark
  end_to_end input_ms + commit_ms: OS event to the commit that puts the new tab on the next vsync

Kinds: terminal, chromium, webkit, markdown, file (code editor page), chat (New Tab page / agent pane).

Usage: tab-switch-matrix.py --tag <tag> --app PATH [--kinds terminal,chromium,...] [--counts 2,10,30,60]
       [--switches 60] [--interval 0.12] [--idle 5] [--json PATH] [--out DIR] [--budget-ms 16.7]
"""
import argparse, glob, json, os, re, signal, socket, statistics, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_idle import classify, usage  # noqa: E402
from bench_launch import launch_app, bundle_id  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--matrix", action="store_true", help="(accepted for the tab-switch-stages.py entry)")
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--kinds", default="terminal,chromium,webkit,markdown,file,chat")
parser.add_argument("--counts", default="2,10,30,60")
parser.add_argument("--switches", type=int, default=60, help="switches per input kind per scenario")
parser.add_argument("--interval", type=float, default=0.12)
parser.add_argument("--idle", type=float, default=5.0)
parser.add_argument("--budget-ms", type=float, default=16.7, help="end-to-end p90 budget (gate)")
parser.add_argument("--json", help="write the report here")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--profile", default="", help="kind:count scenarios (comma list) whose Ctrl-Tab phase runs under a Time Profiler")
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"tsmatrix-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
STAGES = ["input", "focus", "strip", "withdraw", "content", "reveal", "stripSync", "view", "present", "record", "apply", "commit"]
COLORS = ["#c0392b", "#27ae60", "#2980b9", "#8e44ad", "#d35400", "#16a085", "#2c3e50", "#f39c12", "#7f8c8d", "#e84393"]
ROWS, LAUNCHED = [], []
PAGE_TABS = []
app = None


def run(*args, timeout=30):
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1", "CMUX_TAG": TAG,
           "CMUX_BUNDLE_ID": BUNDLE_ID, "CMUX_BUNDLED_CLI_PATH": CLI}
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=env)


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


def action(name, args=None, timeout=60, origin="script"):  # the socket refuses "user" (ControlOrigin)
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": origin}, timeout=timeout)


def wait(check, seconds, step=0.2):
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


def panes():
    return [p for w in ((rpc("debug.surfaces") or {}).get("windows") or []) for p in w.get("panes", [])]


def focused_pane():
    return next((p for p in panes() if p.get("focused")), None)


def strip_tabs():
    """The largest strip's tabs as (id, center in window coordinates, visible width)."""
    best = []
    for strip in (rpc("debug.tab_drag") or {}).get("strips") or []:
        tabs = strip.get("tabs") or []
        if len(tabs) > len(best):
            best = tabs
    out = []
    for tab in best:
        f = tab["frame"]
        f = [f["x"], f["y"], f["width"], f["height"]] if isinstance(f, dict) else list(f)
        out.append((tab.get("id") or tab.get("label"), [f[0] + f[2] * 0.4, f[1] + f[3] / 2], f[2]))
    return out


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


# Each test page notes the first animation frame after it turns visible (epoch ms): the time its own
# content draws again, which the app's commit (`debug.tab_switch`) does not cover (the page's process
# commits it). `content_frames` collects them per switch.
SHOWN_SCRIPT = ("<script>window.__shown=[];document.addEventListener('visibilitychange',()=>{"
                "if(document.visibilityState==='visible')requestAnimationFrame(()=>"
                "window.__shown.push(performance.timeOrigin+performance.now()))});</script>")


def page_html(index):
    color = COLORS[index % len(COLORS)]
    return (f"<!doctype html><title>page {index}</title>{SHOWN_SCRIPT}<body style='margin:0;background:{color};color:white;"
            f"font:40px -apple-system'>" + f"<p>page {index} row</p>" * 40)


def content_frames(tab_ids, sends):
    """Per switch (epoch ms it was sent), the first page frame after it from any page: ms, or None."""
    shown = []
    for tab in tab_ids:
        reply = rpc("browser.page.eval", {"tab": tab, "script": "JSON.stringify(window.__shown ? window.__shown.splice(0) : [])"}, timeout=10)
        try:
            shown += json.loads((reply or {}).get("value") or "[]")
        except (TypeError, ValueError):
            pass
    shown.sort()
    out = []
    for index, sent in enumerate(sends):
        until = sends[index + 1] if index + 1 < len(sends) else sent + 2000
        first = next((t for t in shown if sent <= t < until), None)
        out.append(None if first is None else round(first - sent, 2))
    return out


def maker(kind, index):
    if kind == "terminal":
        return lambda: action("newSurface")
    if kind in ("chromium", "webkit"):
        path = os.path.join(SCRATCH, f"page-{index}.html")
        open(path, "w").write(page_html(index))
        return lambda: action(f"openBrowser.{kind}", {"url": "file://" + path}, timeout=120)
    if kind == "markdown":
        path = os.path.join(SCRATCH, f"notes-{index}.md")
        open(path, "w").write(f"# Notes {index}\n\n" + "\n".join(f"- item {i} with `code` and **bold**" for i in range(120)) + "\n")
        return lambda: action("openMarkdownFile", {"path": path})
    if kind == "file":
        path = os.path.join(SCRATCH, f"source-{index}.swift")
        open(path, "w").write("\n".join(f"let value{i} = {i} // file {index}" for i in range(300)) + "\n")
        return lambda: rpc("action.run", {"action": "file open", "args": {"path": path, "where": "tab"}, "focus": True, "origin": "cli"})
    if kind == "chat":
        return lambda: action("newTab.page")
    raise SystemExit(f"unknown kind {kind}")


def footprint():
    """(cpu %, footprint MB) of the app, its helpers and the daemon over --idle seconds."""
    kinds = classify(app.pid, APP)
    start = {pid: usage(pid) for pid in kinds}
    t0 = time.monotonic()
    time.sleep(opts.idle)  # test harness: the measurement window itself
    wall = time.monotonic() - t0
    cpu = mem = 0.0
    by_kind = {}
    for pid, kind in kinds.items():
        before, after = start.get(pid), usage(pid)
        if not before or not after:
            continue
        c = 100.0 * (after[0] - before[0]) / (wall * 1e9)
        m = after[2] / 1048576
        cpu += c
        mem += m
        entry = by_kind.setdefault(kind, [0.0, 0.0])
        entry[0] += c
        entry[1] += m
    return {"cpu_percent": round(cpu, 2), "footprint_mb": round(mem, 1),
            "by_process": {k: {"cpu_percent": round(v[0], 2), "footprint_mb": round(v[1], 1)} for k, v in by_kind.items()}}


def profile_summary(trace, label):
    """Heaviest main-thread frames of the app in `trace` (self and inclusive ms)."""
    import collections, xml.etree.ElementTree as ET
    xml = trace + ".xml"
    with open(xml, "w") as handle:
        subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                        '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], stdout=handle, timeout=600)
    byid, selfw, incl, total = {}, collections.Counter(), collections.Counter(), 0
    def resolve(e):
        r = e.get("ref")
        return byid.get(r, e) if r else e
    for _, e in ET.iterparse(xml, events=("end",)):
        if e.get("id"):
            byid[e.get("id")] = e
        if e.tag != "row":
            continue
        thread = resolve(e.find("thread")) if e.find("thread") is not None else None
        if thread is None or "Main Thread" not in thread.get("fmt", ""):
            continue
        w = e.find("weight"); w = resolve(w) if w is not None else None
        weight = int(w.text) if w is not None and w.text and w.text.isdigit() else 1000000
        bt = e.find("backtrace"); bt = resolve(bt) if bt is not None else None
        if bt is None:
            continue
        names = [resolve(f).get("name", "?") for f in bt.findall("frame")]
        if not names:
            continue
        total += weight
        selfw[names[0]] += weight
        for n in set(names):
            incl[n] += weight
    lines = [f"PROFILE {label} main-thread total_ms={total / 1e6:.1f}"]
    lines += [f"PROFILE {label} self {w / 1e6:8.1f} ms  {n[:170]}" for n, w in selfw.most_common(30)]
    lines += [f"PROFILE {label} incl {w / 1e6:8.1f} ms  {n[:170]}" for n, w in incl.most_common(70)]
    print("\n".join(lines), flush=True)
    return {"total_ms": round(total / 1e6, 1), "self": [[n, round(w / 1e6, 1)] for n, w in selfw.most_common(30)],
            "incl": [[n, round(w / 1e6, 1)] for n, w in incl.most_common(70)]}


def time_switches(label, step, count, profile=None):
    rpc("debug.frames", {"action": "start"})  # keeps the display link ticking: a commit's frame is the next vsync
    rpc("debug.tab_switch", {"action": "start"})
    rpc("debug.hangs", {"clear": True})
    recorder = None
    if profile:
        recorder = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(app.pid),
                                     "--output", profile, "--no-prompt"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(4)  # test harness: the recorder attaches
    kinds = classify(app.pid, APP)
    start = {pid: usage(pid) for pid in kinds}
    t0 = time.monotonic()
    sends = []
    for index in range(count):
        sends.append(time.time() * 1000)
        step(index)
        time.sleep(opts.interval)  # test harness pacing: one switch per interval
    time.sleep(0.8)  # test harness: the last commit lands
    wall = time.monotonic() - t0
    profiled = None
    if recorder:
        recorder.send_signal(signal.SIGINT)
        try:
            recorder.wait(timeout=120)
        except subprocess.TimeoutExpired:
            recorder.kill()
        try:
            profiled = profile_summary(profile, label)
        except Exception as error:  # a failed export must not lose the timings
            print(f"profile export failed: {error!r}", flush=True)
    cpu = sum(100.0 * (usage(p)[0] - start[p][0]) / (wall * 1e9) for p in kinds if start.get(p) and usage(p))
    own = rpc("debug.tab_switch", {"action": "stop"}) or {}
    rpc("debug.frames", {"action": "stop"})
    hangs = rpc("debug.hangs") or {}
    switches = own.get("switches") or []
    for s in switches:
        if "commit_ms" in s:
            s["e2e_ms"] = s.get("input_ms", 0.0) + s["commit_ms"]
    table = {}
    for kind in sorted({s.get("kind", "?") for s in switches}):
        rows = [s for s in switches if s.get("kind", "?") == kind]
        line = {"n": len(rows)}
        for stage in STAGES + ["e2e"]:
            values = [r[stage + "_ms"] for r in rows if stage + "_ms" in r]
            if values:
                line[stage] = {"p50": round(pct(values, 0.5), 3), "p90": round(pct(values, 0.9), 3), "p95": round(pct(values, 0.95), 3), "max": round(max(values), 3)}
        late = [r.get("late_vsyncs", 0) for r in rows]
        line["late_switches"] = sum(1 for v in late if v > 0)
        line["late_max"] = max(late) if late else 0
        table[kind] = line
        cells = " ".join(f"{st}={line[st]['p50']}/{line[st]['p90']}/{line[st]['p95']}" for st in ("input", "apply", "commit", "e2e") if st in line)
        print(f"  {label:<14} {kind:<10} n={len(rows):<3} p50/p90/p95 ms: {cells} late={line['late_switches']}/{len(rows)} max={line['late_max']}", flush=True)
    stalls = {"count": hangs.get("count"), "max_ms": hangs.get("max_ms")}
    for record in (hangs.get("records") or [])[-3:]:
        frames = [f for f in record.get("frames", []) if "CmuxNext" in f or "Ghostty" in f][:8]
        print(f"    stall {record.get('duration_ms', 0):.1f} ms: " + " < ".join(str(f)[:90] for f in frames), flush=True)
    frames = content_frames(PAGE_TABS, sends) if PAGE_TABS else []
    got = [f for f in frames if f is not None]
    content = None
    if frames:
        content = {"switches": len(frames), "framed": len(got), "p50": pct(got, 0.5), "p90": pct(got, 0.9), "p95": pct(got, 0.95), "max": max(got) if got else None}
        print(f"  {label:<14} page content frame: {content}", flush=True)
    return {"table": table, "switches": switches, "stalls": stalls, "cpu_percent_during": round(cpu, 1), "content_frame_ms": content,
            "timed": len(switches), "asked": count, "profile": profiled}


def scenario(kind, count, baseline):
    name = f"ts-{kind}-{count}"
    made = run("workspace", "create", "--name", name)
    workspace = re.search(r"value\.workspace_id\s+(\S+)", made.stdout)
    if not workspace:
        row(f"{name}: setup", "a workspace", made.stdout[-200:] + made.stderr[-200:], False)
        return None
    ws = workspace.group(1)
    run("workspace", ws, "focus")
    if not wait(lambda: (focused_pane() or {}).get("kind") == "terminal", 30):
        row(f"{name}: setup", "a focused terminal", json.dumps(focused_pane())[:200], False)
        return None
    time.sleep(1.0)  # test harness: shell prompt
    t0 = time.time()
    for index in range(count):
        reply = maker(kind, index)()
        if isinstance(reply, dict) and reply.get("error"):
            print(f"  open {kind} {index}: {json.dumps(reply)[:200]}", flush=True)
        if not wait(lambda: len(strip_tabs()) >= index + 2, 60):
            row(f"{name}: setup", f"{index + 2} tabs", f"{len(strip_tabs())}", False)
            run("workspace", ws, "close")
            return None
        if kind in ("chromium", "webkit", "chat"):
            time.sleep(0.4)  # test harness: the page loads before the next tab
    print(f"{name}: {count} tabs made in {time.time() - t0:.1f} s", flush=True)
    total = len(strip_tabs())
    global PAGE_TABS
    PAGE_TABS = [t[0] for t in strip_tabs()] if kind in ("chromium", "webkit") else []
    for _ in range(total):  # warm: every tab once
        rpc("debug.key", {"key": "tab", "modifiers": ["control"]})
        time.sleep(0.35 if kind != "terminal" else 0.15)  # test harness: slow warm-up visit
    time.sleep(2.0)  # test harness: pages settle
    idle = footprint()
    per_tab = {"footprint_mb": round((idle["footprint_mb"] - baseline["footprint_mb"]) / count, 2),
               "cpu_percent": round((idle["cpu_percent"] - baseline["cpu_percent"]) / count, 3)}
    print(f"  idle {idle['cpu_percent']}% {idle['footprint_mb']} MB; per hidden tab {per_tab}", flush=True)
    n = min(opts.switches, max(total * 2, 8))
    result = {"kind": kind, "count": count, "tabs": total, "idle": idle, "per_tab": per_tab}
    profile = os.path.join(opts.out, f"{name}.trace") if f"{kind}:{count}" in opts.profile.split(",") else None
    result["ctrl_tab"] = time_switches("Ctrl-Tab", lambda i: rpc("debug.key", {"key": "tab", "modifiers": ["control"]}), n)
    if profile:  # a separate pass, so the profiler's cost stays out of the timed numbers
        result["profile"] = time_switches("Ctrl-Tab profiled", lambda i: rpc("debug.key", {"key": "tab", "modifiers": ["control"]}),
                                          max(n, 120), profile=profile)["profile"]
    result["cmd_shift_bracket"] = time_switches("Cmd-Shift-]", lambda i: rpc("debug.key", {"key": "]", "modifiers": ["command", "shift"]}), n)
    tabs = [t for t in strip_tabs() if t[2] >= 24]  # clickable: drawn wide enough
    if len(tabs) >= 2:
        result["click"] = time_switches("click", lambda i: rpc("debug.mouse", {"action": "click", "x": tabs[i % len(tabs)][1][0], "y": tabs[i % len(tabs)][1][1]}), n)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}.png")})
    for input_kind in ("ctrl_tab", "cmd_shift_bracket", "click"):
        part = result.get(input_kind)
        if not part:
            continue
        row(f"{name}: {input_kind} timed", f">= 80% of {part['asked']}", f"{part['timed']}", part["timed"] >= part["asked"] * 0.8)
        line = part["table"].get(kind) or {}
        e2e = (line.get("e2e") or line.get("commit") or {}).get("p90")
        if e2e is not None:
            row(f"{name}: {input_kind} e2e p90", f"<= {opts.budget_ms} ms", f"{e2e}", e2e <= opts.budget_ms)
    run("workspace", ws, "close")
    time.sleep(2.0)  # test harness: the workspace's content goes
    return result


def cleanup():
    if os.environ.get("TABSWITCH_KEEP") or not LAUNCHED:
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


def started(process):
    global app
    app = process
    LAUNCHED.append(process.pid)


def main():
    global app, SOCKET
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900"}
    # One launch path (bench_launch.py): socket in the state folder, bench env, the reason when it does not come up.
    app, SOCKET = launch_app(APP, env, os.path.join(opts.out, f"app-{TAG}.log"), timeout=120, on_start=started)
    print(f"launched pid {app.pid}", flush=True)
    time.sleep(5)  # test harness: launch work settles before the baseline
    baseline = footprint()
    print(f"baseline idle {baseline}", flush=True)
    report = {"tag": TAG, "baseline": baseline, "scenarios": []}
    for kind in opts.kinds.split(","):
        for count in [int(c) for c in opts.counts.split(",")]:
            try:
                result = scenario(kind, count, baseline)
            except Exception as error:  # one scenario's failure must not hide the others
                row(f"ts-{kind}-{count}", "ran", repr(error)[:200], False)
                result = None
            if result:
                report["scenarios"].append(result)
            if opts.json:
                with open(opts.json, "w") as handle:
                    json.dump(report, handle, indent=1)
    print("\n== summary (end-to-end p50/p90 ms: input age + intent -> commit; late = switches past their first frame)")
    for s in report["scenarios"]:
        for input_kind in ("ctrl_tab", "cmd_shift_bracket", "click"):
            line = ((s.get(input_kind) or {}).get("table") or {}).get(s["kind"])
            if line and "e2e" in line:
                print(f"  {s['kind']:<9} {s['count']:>3} {input_kind:<18} e2e {line['e2e']['p50']}/{line['e2e']['p90']} "
                      f"apply {line['apply']['p50']}/{line['apply']['p90']} late {line['late_switches']}/{line['n']} "
                      f"per-tab {s['per_tab']['footprint_mb']} MB {s['per_tab']['cpu_percent']}%", flush=True)


try:
    main()
finally:
    cleanup()
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
