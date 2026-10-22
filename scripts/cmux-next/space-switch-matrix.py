#!/usr/bin/env python3
"""Space switch latency in a real window (space-switch-100x, user msg 9582: "switching spaces is still laggy").

Launches a tagged cmux-next Debug app (no activation, scratch config, test window on the last screen),
makes --spaces spaces in its window, fills each to every count in --sizes workspaces (a terminal each;
the first --browsers of every space also hold a Chromium tab of a local page, and every space shows one
of those), visits every space once (warm), then switches spaces with Opt-Cmd-] and Opt-Cmd-[ through
the app's real key router (`debug.key`), one every --interval seconds. Per switch `debug.space_switch`
gives:

  input_ms    OS event age when the switch began (WindowManager.switchProfile)
  sidebar_ms  intent to the sidebar listing the new space's rows
  content_ms  intent to the content area showing the new space's workspace
  commit_ms   intent to the Core Animation commit that carries both (after layout and display)
  e2e_ms      input_ms + commit_ms: OS event to the first frame of the new space
  cpu_ms      main-thread CPU from the intent to the end of that commit
  late_vsyncs frames the commit missed (0: the first frame it could reach)
  settle_missed_frames / settle_max_frame_ms: vsyncs the main thread skipped from the intent to 600 ms
              after the commit (the sidebar's slide), and the longest frame interval

Gate (--budget-ms, default one 120 Hz frame): e2e p95 under the budget, and no missed frames at p95.

Fleet: cmux-ci run --class exclusive --measurement --label measure --key KEY --script scripts/measure/tab-switch.sh
       --ref SHA --artifact artifacts/space-switch/space-switch.json --arg=--space-switch [--arg=--sizes=20,100]
       (tab-switch-stages.py hands `--space-switch` to this script; the step builds the tagged app).

Usage: space-switch-matrix.py --tag <tag> --app PATH [--spaces 5] [--sizes 20,100] [--browsers 3]
       [--switches 40] [--interval 0.9] [--json PATH] [--out DIR] [--budget-ms 8.33] [--profile SIZE]
"""
import argparse, glob, json, os, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--spaces", type=int, default=5)
parser.add_argument("--sizes", default="20,100", help="workspaces per space, ascending (each step adds to the last)")
parser.add_argument("--browsers", type=int, default=3, help="Chromium tabs per space (in its first workspaces)")
parser.add_argument("--switches", type=int, default=40)
parser.add_argument("--interval", type=float, default=0.9, help="seconds between switches (past the 600 ms settle window)")
parser.add_argument("--budget-ms", type=float, default=8.33)
parser.add_argument("--json", default="artifacts/space-switch/space-switch.json")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--profile", default="", help="sizes (comma list) that also run a Time Profiler pass")
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"ssmatrix-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
STAGES = ["input", "sync", "sidebar", "content", "apply", "commit", "commit_end", "e2e", "cpu", "settle_max_frame"]
ROWS, LAUNCHED = [], []
app = None


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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, timeout=60):  # the socket refuses origin "user" (ControlOrigin)
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=timeout)


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


def window():
    windows = (rpc("debug.windows") or {}).get("windows") or []
    return next((w for w in windows if w.get("is_open", True)), windows[0] if windows else {})


def members():
    w = window()
    for key in ("workspaces", "workspace_ids", "members"):
        if isinstance(w.get(key), list):
            return w[key]
    return []


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))] if values else None


def page(index):
    path = os.path.join(SCRATCH, f"page-{index}.html")
    open(path, "w").write(f"<!doctype html><title>page {index}</title><body style='margin:0;background:#2980b9;color:white;"
                          f"font:32px -apple-system'>" + f"<p>space page {index} row</p>" * 60)
    return "file://" + path


def space_ids():
    """The window's space ids in strip order, from each space's switch."""
    return SPACES


SPACES = []  # [(name, id)]
FILLED = {}  # space name -> workspaces made in it
BROWSERS = {}  # space name -> Chromium tabs made in it


def enter(name):
    action("space.switch", {"space": name})
    return wait(lambda: window().get("space") == dict(SPACES).get(name), 20)


def fill(size):
    """Every space up to `size` workspaces; its first --browsers hold a Chromium tab."""
    t0 = time.time()
    for name, _ in SPACES:
        if not enter(name):
            row(f"setup {name}", "entered", json.dumps(window())[:200], False)
            return False
        have = FILLED.get(name, 1)
        before = len(members())
        for index in range(have, size):
            action("space.newWorkspace", {"space": name})
            if index % 10 == 9:
                wait(lambda: len(members()) >= before + (index - have + 1), 30, step=0.1)
        if not wait(lambda: len(members()) >= before + max(0, size - have), 60):
            row(f"setup {name} {size}", f"{before + size - have} members", f"{len(members())}", False)
            return False
        FILLED[name] = max(have, size)
        # Chromium tabs in the space's first workspaces; the last one stays shown (each switch shows a page).
        made = BROWSERS.get(name, 0)
        if made < opts.browsers:
            enter(name)
            for b in range(made, opts.browsers):
                action("openBrowser.chromium", {"url": page(len(SPACES) * 100 + b)}, timeout=120)
                time.sleep(1.0)  # test harness: the page loads before the next one
            BROWSERS[name] = opts.browsers
    print(f"filled {len(SPACES)} spaces to {size} workspaces in {time.time() - t0:.1f} s; window lists {len(members())}", flush=True)
    return True


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
        w = e.find("weight")
        w = resolve(w) if w is not None else None
        weight = int(w.text) if w is not None and w.text and w.text.isdigit() else 1000000
        bt = e.find("backtrace")
        bt = resolve(bt) if bt is not None else None
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
    lines += [f"PROFILE {label} self {w / 1e6:8.1f} ms  {n[:170]}" for n, w in selfw.most_common(40)]
    lines += [f"PROFILE {label} incl {w / 1e6:8.1f} ms  {n[:170]}" for n, w in incl.most_common(120)]
    print("\n".join(lines), flush=True)
    return {"total_ms": round(total / 1e6, 1), "self": [[n, round(w / 1e6, 1)] for n, w in selfw.most_common(40)],
            "incl": [[n, round(w / 1e6, 1)] for n, w in incl.most_common(120)]}


def switch_key(index, spaces):
    # Next through the strip, then back: every switch moves one space.
    phase = index % (2 * (spaces - 1))
    return "]" if phase < spaces - 1 else "["


def time_switches(label, count, profile=None):
    rpc("debug.frames", {"action": "start"})  # keeps the display link ticking: every frame of the settle window is seen
    rpc("debug.space_switch", {"action": "start"})
    rpc("debug.hangs", {"clear": True})
    recorder = None
    if profile:
        recorder = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(app.pid),
                                     "--output", profile, "--no-prompt"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(4)  # test harness: the recorder attaches
    for index in range(count):
        rpc("debug.key", {"key": switch_key(index, len(SPACES)), "modifiers": ["option", "command"]})
        time.sleep(opts.interval)  # test harness pacing: one switch per interval, past its settle window
    time.sleep(1.0)  # test harness: the last row's settle window ends
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
    own = rpc("debug.space_switch", {"action": "stop"}) or {}
    rpc("debug.frames", {"action": "stop"})
    hangs = rpc("debug.hangs") or {}
    switches = own.get("switches") or []
    for s in switches:
        if "commit_ms" in s:
            s["e2e_ms"] = s.get("input_ms", 0.0) + s["commit_ms"]
    line = {"n": len(switches), "asked": count}
    for stage in STAGES:
        values = [r[stage + "_ms"] for r in switches if stage + "_ms" in r]
        if values:
            line[stage] = {"p50": round(pct(values, 0.5), 3), "p95": round(pct(values, 0.95), 3), "max": round(max(values), 3)}
    for key in ("late_vsyncs", "settle_missed_frames"):
        values = [r.get(key, 0) for r in switches]
        line[key] = {"p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": max(values) if values else None,
                     "switches_with_any": sum(1 for v in values if v > 0)}
    line["refresh_ms"] = pct([r.get("refresh_ms", 0) for r in switches], 0.5)
    cells = " ".join(f"{st}={line[st]['p50']}/{line[st]['p95']}" for st in ("input", "sidebar", "content", "commit", "e2e", "cpu") if st in line)
    print(f"  {label:<20} n={len(switches)}/{count} p50/p95 ms: {cells} late={line['late_vsyncs']} "
          f"settle_missed={line['settle_missed_frames']} refresh={line['refresh_ms']}", flush=True)
    for record in (hangs.get("records") or [])[-3:]:
        frames = [f for f in record.get("frames", []) if "CmuxNext" in f][:10]
        print(f"    stall {record.get('duration_ms', 0):.1f} ms: " + " < ".join(str(f)[:100] for f in frames), flush=True)
    return {"table": line, "switches": switches, "stalls": {"count": hangs.get("count"), "max_ms": hangs.get("max_ms")}, "profile": profiled}


def scenario(size):
    if not fill(size):
        return None
    for name, _ in SPACES:  # warm: every space once
        enter(name)
        time.sleep(0.5)  # test harness: slow warm-up visit
    enter(SPACES[0][0])
    time.sleep(2.0)  # test harness: pages settle
    label = f"{len(SPACES)}x{size}"
    result = {"spaces": len(SPACES), "per_space": size, "browsers_per_space": opts.browsers, "workspaces": len(members())}
    result["keys"] = time_switches(f"{label} Opt-Cmd-]/[", opts.switches)
    if str(size) in opts.profile.split(","):  # a separate pass, so the profiler's cost stays out of the timed numbers
        result["profile"] = time_switches(f"{label} profiled", max(opts.switches, 60),
                                          profile=os.path.join(opts.out, f"space-{label}.trace"))["profile"]
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"space-{label}.png")})
    t = result["keys"]["table"]
    row(f"{label}: timed", f">= 80% of {t['asked']}", f"{t['n']}", t["n"] >= t["asked"] * 0.8)
    e2e = (t.get("e2e") or {}).get("p95")
    row(f"{label}: e2e p95", f"<= {opts.budget_ms} ms", f"{e2e}", e2e is not None and e2e <= opts.budget_ms)
    row(f"{label}: missed frames p95", "0", f"{t['settle_missed_frames']['p95']}", (t["settle_missed_frames"]["p95"] or 0) == 0)
    return result


def cleanup():
    if os.environ.get("SPACESWITCH_KEEP") or not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900"}
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    LAUNCHED.append(app.pid)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        sys.exit("the tagged app did not come up")
    time.sleep(5)  # test harness: launch work settles
    print("window:", json.dumps(window())[:600], flush=True)
    first = window().get("space")
    SPACES.append(("S1", first))
    for index in range(2, opts.spaces + 1):
        name = f"S{index}"
        known = window().get("space")
        action("space.new", {"name": name})
        # A script's space.new files its first workspace without showing the space: enter it by name.
        def entered_space():
            action("space.switch", {"space": name})
            current = window().get("space")
            return current not in (None, known) and current not in dict(SPACES).values() and current
        entered = wait(entered_space, 30, step=0.5)
        if not entered:
            row(f"setup {name}", "a new space", json.dumps(window())[:200], False)
            return
        SPACES.append((name, entered))
    print("spaces:", SPACES, flush=True)
    report = {"tag": TAG, "scenarios": []}
    for size in [int(s) for s in opts.sizes.split(",")]:
        try:
            result = scenario(size)
        except Exception as error:  # one size's failure must not hide the others
            row(f"size {size}", "ran", repr(error)[:200], False)
            result = None
        if result:
            report["scenarios"].append(result)
        if opts.json:
            os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
            with open(opts.json, "w") as handle:
                json.dump(report, handle, indent=1)
    print("\n== summary (p50/p95; e2e = OS key event to the commit showing the new space)")
    for s in report["scenarios"]:
        t = s["keys"]["table"]
        get = lambda k, q: (t.get(k) or {}).get(q)
        print(f"SPACE-SWITCH {s['spaces']}x{s['per_space']} e2e {get('e2e', 'p50')}/{get('e2e', 'p95')} ms "
              f"commit {get('commit', 'p50')}/{get('commit', 'p95')} cpu {get('cpu', 'p50')}/{get('cpu', 'p95')} ms "
              f"late {t['late_vsyncs']['p50']}/{t['late_vsyncs']['p95']} missed {t['settle_missed_frames']['p50']}/{t['settle_missed_frames']['p95']} "
              f"max_frame {get('settle_max_frame', 'p50')}/{get('settle_max_frame', 'p95')} ms refresh {t['refresh_ms']}", flush=True)


try:
    main()
finally:
    cleanup()
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
