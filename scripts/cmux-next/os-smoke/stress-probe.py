#!/usr/bin/env python3
"""Terminal-spam stress for one cmux-next DEV build, INSIDE a disposable Tart VM
(stdlib only). The guest half of `run.sh` when OS_SMOKE_PROBE=stress-probe.py;
the same script on macOS 15 and 26 guests gives comparable rows
(plans/cmux-next/sequoia-lag.md).

It launches the app like guest-probe.py, opens a first workspace, then:

1. rounds: each round creates a workspace, two tabs, a right split and a down
   split through `debug.new_tab {action: bench_create}` (the real Cmd-N / Cmd-T /
   Cmd-D / Cmd-Shift-D key path): key_ms, visible_ms, confirmed_ms per create;
   after each round one `debug.new_terminal_trace run` (time to the new shell's
   first prompt, the traced tab is closed again);
2. burst: BURST Cmd-T keys back to back (no wait), the wall time until every
   tab exists, and the stalls during it;
3. idle: IDLE seconds with every terminal open, nothing driven.

A sampler thread reads %CPU and RSS of the app, its child processes and
WindowServer every 0.5 s. A `sample` of the app runs during the burst. The
stalls (`debug.hangs`, 50 ms watchdog) of each phase are summed and their top
frames counted. Writes OUT/stress.json and prints STRESS lines.

Budget (the lag guard, run.sh's stress phase on every supported major): the WebKit web content
processes during the stress (one per New Tab page before the fix: 75 for 75 tabs) must stay at
most STRESS_BUDGET_WEB_PROCS, and the 20x Cmd-T burst's longest main-thread stall and summed
stalls under STRESS_BUDGET_MAX_MS and STRESS_BUDGET_TOTAL_MS (defaults below, set from the
Tart runs in plans/cmux-next/sequoia-lag.md).
Exit: 0 within budget, 1 the app died or never showed a window, 2 over budget, 3 skipped (a
release build has no debug.* methods).

Usage: stress-probe.py APP_PATH OUT_DIR
Env: STRESS_ROUNDS (default 10), STRESS_BURST (20), STRESS_IDLE (15), STRESS_GHOSTTY
(Ghostty config lines, "\\n" separated; default none).
"""
import collections, json, os, re, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
# The launch helpers (socket path, rpc, wait, stalls_after) of guest-probe.py, without its steps.
_src = open(os.path.join(HERE, "guest-probe.py")).read()
exec(compile(_src[:_src.index("# 1. OS gate")], "guest-probe.py", "exec"))

ROUNDS = int(os.environ.get("STRESS_ROUNDS", "10"))
BURST = int(os.environ.get("STRESS_BURST", "20"))
IDLE = float(os.environ.get("STRESS_IDLE", "15"))
# The VMs' stall times swing 2x run to run (host load), so the time budgets only catch a large
# regression; the WebContent process count is exact and is the main guard.
BUDGET_MAX_MS = float(os.environ.get("STRESS_BUDGET_MAX_MS", "1500"))
BUDGET_TOTAL_MS = float(os.environ.get("STRESS_BUDGET_TOTAL_MS", "6000"))
BUDGET_WEB_PROCS = int(os.environ.get("STRESS_BUDGET_WEB_PROCS", "20"))
report = {"guest_os": guest_os, "guest_build": result["guest_build"], "app": os.path.basename(APP),
          "rounds": [], "phases": {}}


def tabs():
    """Tabs in the snapshot (every terminal tab, shown or parked): the app keeps only the shown
    terminals live (debug.surfaces live_terminals), so this is the count the stress grows."""
    return (rpc("snapshot.get") or {}).get("tab_count") or 0


def long_stacks(after, floor_ms=150):
    """Full watchdog stacks of the stalls of at least `floor_ms` after hang sequence `after`."""
    records = (rpc("debug.hangs", {"after": after}) or {}).get("records") or []
    return [{"ms": round(r.get("duration_ms", 0)), "frames": (r.get("frames") or [])[:40]}
            for r in records if r.get("kind", "stall") == "stall" and r.get("duration_ms", 0) >= floor_ms]


def ps_rows():
    out = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,%cpu=,rss=,comm="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) == 5:
            rows.append((int(parts[0]), int(parts[1]), float(parts[2]), int(parts[3]), parts[4]))
    return rows


class Sampler(threading.Thread):
    """%CPU and RSS (MB) of the app, its descendants and WindowServer, every 0.5 s."""

    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.samples, self.stop_flag, self.phase = pid, [], threading.Event(), "launch"

    def run(self):
        while not self.stop_flag.is_set():
            rows = ps_rows()
            kids = {self.pid}
            changed = True
            while changed:
                changed = False
                for pid, ppid, *_ in rows:
                    if ppid in kids and pid not in kids:
                        kids.add(pid)
                        changed = True
            app = [r for r in rows if r[0] == self.pid]
            desc = [r for r in rows if r[0] in kids and r[0] != self.pid]
            ws = [r for r in rows if r[4].endswith("WindowServer")]
            # WebKit's web content processes are launchd's children, not the app's.
            web = [r for r in rows if "WebKit.WebContent" in r[4] or "WebKit.GPU" in r[4] or "WebKit.Networking" in r[4]]
            self.samples.append({"t": time.time(), "phase": self.phase,
                                 "app_cpu": sum(r[2] for r in app), "app_mb": sum(r[3] for r in app) / 1024,
                                 "kids_cpu": sum(r[2] for r in desc), "kids_mb": sum(r[3] for r in desc) / 1024,
                                 "kids": len(desc), "ws_cpu": sum(r[2] for r in ws),
                                 "web_cpu": sum(r[2] for r in web), "web_mb": sum(r[3] for r in web) / 1024,
                                 "web_procs": sum(1 for r in web if "WebContent" in r[4]),
                                 "all_cpu": sum(r[2] for r in rows)})
            self.stop_flag.wait(0.5)

    def summary(self, phase):
        rows = [s for s in self.samples if s["phase"] == phase]
        if not rows:
            return {}
        mean = lambda k: round(sum(r[k] for r in rows) / len(rows), 1)
        return {"n": len(rows), "app_cpu": mean("app_cpu"), "kids_cpu": mean("kids_cpu"), "ws_cpu": mean("ws_cpu"),
                "app_cpu_max": round(max(r["app_cpu"] for r in rows), 1), "ws_cpu_max": round(max(r["ws_cpu"] for r in rows), 1),
                "app_mb_end": round(rows[-1]["app_mb"]), "kids_mb_end": round(rows[-1]["kids_mb"]), "kids_end": rows[-1]["kids"],
                "web_cpu": mean("web_cpu"), "web_mb_end": round(rows[-1]["web_mb"]), "web_procs_end": rows[-1]["web_procs"],
                "web_procs_max": max(r["web_procs"] for r in rows), "all_cpu": mean("all_cpu")}


def stall_summary(stalls):
    tops = collections.Counter()
    for s in stalls:
        for frame in (s.get("top") or [])[:3]:
            tops[re.sub(r"\s+\+\s*\d+$", "", frame)[:140]] += s["ms"]
    return {"count": len(stalls), "total_ms": sum(s["ms"] for s in stalls), "max_ms": max([s["ms"] for s in stalls] or [0]),
            "over_250ms": sum(1 for s in stalls if s["ms"] >= 250), "top_frames_ms": tops.most_common(12)}


def pct(values, p):
    values = sorted(v for v in values if v is not None)
    return round(values[min(len(values) - 1, int(len(values) * p))], 1) if values else None


scratch = tempfile.mkdtemp(prefix="os-stress-")
open(os.path.join(scratch, "cmux.json"), "w").write("{}\n")
# STRESS_GHOSTTY: Ghostty config lines for the run ("\\n" separated), e.g. a glass window:
# "background-opacity = 0.8\\nbackground-blur = macos-glass-regular".
GHOSTTY = os.environ.get("STRESS_GHOSTTY", "").replace("\\n", "\n")
report["ghostty_config"] = GHOSTTY
open(os.path.join(scratch, "ghostty"), "w").write(GHOSTTY + "\n" if GHOSTTY else "")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"), "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"),
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
log = open(os.path.join(OUT, "app.log"), "a")
started = time.time()
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
alive = lambda: app.poll() is None
sampler = Sampler(app.pid)
sampler.start()
exit_code = 1
try:
    if not wait(windows_now, LAUNCH_DEADLINE, alive):
        print("STRESS FAIL no window", flush=True)
        sys.exit(1)
    report["launch_s"] = round(time.time() - started, 1)
    if not debug_router():
        print("STRESS skip release build: the stress needs debug.* methods (a DEV build)", flush=True)
        exit_code = 3
        sys.exit(3)
    rpc("action.run", {"action": "newTab", "focus": True, "wait": True})
    wait(lambda: terminal_count() >= 1, TAB_DEADLINE, alive)
    wait(lambda: False, 3, alive)  # past the launch preload delay
    _, cursor = stalls_after(0, 0)
    rounds_cursor = cursor

    sampler.phase = "rounds"
    commands = ["new_workspace", "new_tab", "new_tab", "split_right", "split_down"]
    for index in range(ROUNDS):
        row = {"round": index + 1, "creates": []}
        for command in commands:
            reply = rpc("debug.new_tab", {"action": "bench_create", "command": command}, timeout=30) or {}
            row["creates"].append({k: reply.get(k) for k in ("command", "key_ms", "visible_ms", "confirmed_ms", "frames_to_visible", "error")})
        trace = rpc("debug.new_terminal_trace", {"action": "run", "timeout_ms": 15000}, timeout=30) or {}
        marks = trace.get("marks_ms") or {}
        row["prompt_ms"] = max([v for v in marks.values() if isinstance(v, (int, float))] or [None]) if not trace.get("timed_out") else None
        row["trace"] = {"timed_out": trace.get("timed_out"), "marks_ms": marks, "error": trace.get("error")}
        row["terminals"] = tabs()
        stalls, cursor = stalls_after(cursor, 0)
        row["stalls"] = stall_summary(stalls)
        report["rounds"].append(row)
        vis = [c["visible_ms"] for c in row["creates"]]
        print("STRESS round %2d terminals=%3s visible_ms=%s prompt_ms=%s stalls=%d/%dms max=%dms" % (
            row["round"], row["terminals"], vis, row["prompt_ms"], row["stalls"]["count"], row["stalls"]["total_ms"],
            row["stalls"]["max_ms"]), flush=True)
        if not alive():
            break
    report["phases"]["rounds"] = sampler.summary("rounds")
    report["rounds_stacks"] = long_stacks(rounds_cursor)
    all_creates = [c for r in report["rounds"] for c in r["creates"]]
    for command in sorted(set(commands)):
        cs = [c for c in all_creates if c["command"] == command]
        report["phases"]["create_" + command] = {"n": len(cs), "visible_p50": pct([c["visible_ms"] for c in cs], 0.5),
                                                 "visible_p90": pct([c["visible_ms"] for c in cs], 0.9),
                                                 "key_p50": pct([c["key_ms"] for c in cs], 0.5),
                                                 "confirmed_p50": pct([c["confirmed_ms"] for c in cs], 0.5),
                                                 "first": cs[0]["visible_ms"] if cs else None, "last": cs[-1]["visible_ms"] if cs else None}

    sampler.phase = "burst"
    before = tabs()
    burst_cursor = cursor
    sample_path = os.path.join(OUT, "burst-sample.txt")
    sampling = subprocess.Popen(["/usr/bin/sample", str(app.pid), "8", "-mayDie", "-file", sample_path],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t0 = time.time()
    keys = [rpc("debug.key", {"key": "t", "modifiers": ["cmd"]}, timeout=30) for _ in range(BURST)]
    keys_s = time.time() - t0
    done = wait(lambda: tabs() >= before + BURST, 60, alive, step_s=0.1)
    burst_s = time.time() - t0
    sampling.wait(timeout=60)
    stalls, cursor = stalls_after(cursor, 0)
    report["phases"]["burst"] = {"keys": BURST, "keys_s": round(keys_s, 2), "all_tabs_s": round(burst_s, 2) if done else None,
                                 "tabs": tabs(), "stalls": stall_summary(stalls), **sampler.summary("burst")}
    report["burst_stacks"] = long_stacks(burst_cursor)
    print("STRESS burst %d Cmd-T keys_s=%.2f all_tabs_s=%s stalls=%s" % (BURST, keys_s, report["phases"]["burst"]["all_tabs_s"],
                                                                          json.dumps(report["phases"]["burst"]["stalls"])[:900]), flush=True)

    sampler.phase = "idle"
    wait(lambda: False, IDLE, alive)
    stalls, cursor = stalls_after(cursor, 0)
    report["phases"]["idle"] = {"seconds": IDLE, "stalls": stall_summary(stalls), **sampler.summary("idle")}
    trace = rpc("debug.new_terminal_trace", {"action": "run", "timeout_ms": 15000}, timeout=30) or {}
    marks = trace.get("marks_ms") or {}
    report["phases"]["idle"]["prompt_ms_after"] = max([v for v in marks.values() if isinstance(v, (int, float))] or [None])
    report["wakeups"] = rpc("debug.wakeups") if alive() else None
    report["layers"] = rpc("debug.layers") if alive() else None
    report["alive"] = alive()
    stalls = report["phases"]["burst"]["stalls"]
    web_procs = max([s.get("web_procs", 0) for s in sampler.samples] or [0])
    report["budget"] = {"max_ms": BUDGET_MAX_MS, "total_ms": BUDGET_TOTAL_MS, "web_procs": BUDGET_WEB_PROCS,
                        "ok": stalls["max_ms"] <= BUDGET_MAX_MS and stalls["total_ms"] <= BUDGET_TOTAL_MS
                        and web_procs <= BUDGET_WEB_PROCS}
    print("STRESS budget %s web content processes %d for %d tabs (budget %d), burst max stall %d ms (budget %d), "
          "total %d ms (budget %d)" % ("ok" if report["budget"]["ok"] else "FAIL", web_procs, tabs(), BUDGET_WEB_PROCS,
                                       stalls["max_ms"], BUDGET_MAX_MS, stalls["total_ms"], BUDGET_TOTAL_MS), flush=True)
    exit_code = (0 if report["budget"]["ok"] else 2) if alive() else 1
finally:
    sampler.stop_flag.set()
    for phase in ("rounds", "burst", "idle"):
        print("STRESS cpu %-6s %s" % (phase, json.dumps(sampler.summary(phase))), flush=True)
    for name, value in report["phases"].items():
        if name.startswith("create_"):
            print("STRESS %s %s" % (name, json.dumps(value)), flush=True)
    if alive():
        rpc("action.run", {"action": "quitEndEverything"}, timeout=10)
        if wait(lambda: not alive(), 30) is None and alive():
            app.kill()
    report["samples"] = sampler.samples
    with open(os.path.join(OUT, "stress.json"), "w") as f:
        json.dump(report, f, indent=1)
    # run.sh's PASS/FAIL table reads result.json; as run.sh's stress phase the launch probe owns it.
    with open(os.path.join(OUT, "result.json" if os.environ.get("STRESS_PHASE") != "1" else "stress-result.json"), "w") as f:
        json.dump({"ok": exit_code == 0, "guest_os": guest_os, "launch_seconds": report.get("launch_s"),
                   "steps": {"stress": {"ok": exit_code == 0}}, "failed_steps": [] if exit_code == 0 else ["stress"]}, f)
    if os.path.exists(os.path.join(OUT, "burst-sample.txt")):
        # The heaviest main-thread frames of the burst sample, for the step log.
        text = open(os.path.join(OUT, "burst-sample.txt"), errors="replace").read()
        main = text.split("Thread_", 2)[1] if "Thread_" in text else ""
        print("STRESS sample-main\n" + "\n".join(main.splitlines()[:120]), flush=True)
    print("STRESS done exit=%d" % exit_code, flush=True)
sys.exit(exit_code)
