#!/usr/bin/env python3
"""Where a default shortcut's time goes, from the key to the end of its Core Animation commit (SHORTCUT LATENCY).

Not a CI gate: a measurement an agent runs on the fleet (Lawrence 2026-10-23: every action reaches its committed
frame in under 10 ms). Launches the tagged app (bench_launch.BenchApp: no activation, scratch config, the agent pane
mock, the hang watchdog at 8 ms), shows a terminal workspace, then presses each shortcut --presses times through the
app's own key path (`debug.key`; the app stamps the event itself, so the action signposts carry its input age;
no time in this report comes from this script, cmux-ad 03:40Z) while an Instruments Time Profiler (`xctrace record --attach <app pid>`, 1 ms) and `log stream --signpost`
record. The first press waits for the profiler's first sample (KIT.md rule): the recorder's "Starting recording" line,
then --first-sample-wait seconds; the report proves it (`first_sample_before_first_press`).

Per press, from the always-on action signposts (CmuxNextSignposts, the same in Release):
  input_age_ms     the key event's timestamp to the run's start (the event's wait in the queue and the key routing)
  perform_ms       action.perform: the handler's synchronous main-thread time (the model change)
  after_ms         action.commit minus action.perform: the handler's end to the end of the next CA commit (SwiftUI
                   and AppKit updates, layout, display, the commit itself, and any run-loop turn before it)
  input_to_commit  input_age_ms + action.commit: the key to the committed frame (the 10 ms budget)
and the main thread's Time Profiler samples inside the run, split by phase (handler, after) and by bucket
(perf-profile-split.py: SwiftUI, AppKit layout, draw, CA commit, our code, idle), with the heaviest inclusive frames
of our code and the heaviest leaf frames per shortcut (stacks: OUT/stacks-<action>.txt).

Shortcuts (--shortcuts, default all): newTab.default (Cmd-T), newTab (Cmd-N), newSurface (Ctrl-`), closeTab
(Cmd-W, after an untimed script newSurface), commandPalette (Shift-Cmd-P, Escape after), terminal.clear (Cmd-K).
Each press starts from a focused terminal; what it made is closed by a script action (not timed).

--no-profile: the same presses with no profiler (the A/B numbers: a profiler adds work to the main thread).
--session stress: the STRESS session first (perf-stress-session.py), the same presses in its shown workspace.

Usage: shortcut-latency-profile.py --app APP --tag TAG --out DIR [--json PATH] [--presses 10] [--shortcuts a,b]
       [--no-profile] [--session light|stress] [--settle 0.6]
Fleet (an owned mini's console): cmux-ci run --class exclusive --measurement --label measure
  --script scripts/measure/split-spring.sh --ref SHA --artifact artifacts/split-spring/report.json
  --arg=--suite=shortcut-latency --arg=--config=bench --arg=--vdisplay=120 [--arg=--presses=10] [--arg=--no-profile]
"""
import argparse, collections, importlib.util, json, os, re, socket, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


trace = load("cmux_trace", "trace.py")
split = load("perf_profile_split", "perf-profile-split.py")

# action id -> (key, modifiers, label)
SHORTCUTS = {
    "newTab.default": ("t", ["command"], "Cmd-T"),
    "newTab": ("n", ["command"], "Cmd-N"),
    "newSurface": ("`", ["control"], "Ctrl-`"),
    "closeTab": ("w", ["command"], "Cmd-W"),
    "commandPalette": ("p", ["command", "shift"], "Shift-Cmd-P"),
    "terminal.clear": ("k", ["command"], "Cmd-K"),
}
OUR_MODULE = re.compile(r"(^cmux|CmuxNext|\.debug\.dylib$)", re.I)  # a frame's binary

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--presses", type=int, default=10)
parser.add_argument("--shortcuts", default=",".join(SHORTCUTS))
parser.add_argument("--no-profile", action="store_true")
parser.add_argument("--session", choices=["light", "stress"], default="light")
parser.add_argument("--settle", type=float, default=0.6, help="seconds after each press before its undo")
parser.add_argument("--first-sample-wait", type=float, default=1.0)
opts, _unknown = parser.parse_known_args()  # split-spring.sh passes options this script does not read
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
APP = os.path.abspath(opts.app.rstrip("/"))
CHOSEN = [s for s in opts.shortcuts.split(",") if s]
unknown = [s for s in CHOSEN if s not in SHORTCUTS]
if unknown:
    parser.error(f"--shortcuts: unknown {unknown}; one of {list(SHORTCUTS)}")
SCRATCH = tempfile.mkdtemp(prefix=f"shortcut-latency-{opts.tag}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
SOCKET = [None]


def note(text):
    print(f"shortcut-latency: {text}", flush=True)


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET[0])
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


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            if check():
                return True
        except Exception:  # a reply without the expected shape: try again
            pass
        time.sleep(step)  # test harness polling a live app
    return False


def panes():
    reply = rpc("debug.surfaces") or {}
    return [p for w in (reply.get("windows") or []) for p in w.get("panes", [])]


def focused():
    return next((p for p in panes() if p.get("focused")), None)


def topology():
    reply = rpc("snapshot.get") or {}
    return (reply.get("topology") or {}) if isinstance(reply, dict) else {}


def tab_count():
    return sum(len(p.get("tabs") or []) for w in topology().get("workspaces") or []
               for s in w.get("screens") or [] for p in s.get("panes") or [])


def workspace_count():
    return len([w for w in topology().get("workspaces") or [] if w.get("id")])


def ensure_terminal():
    # The undo's focus move can land a frame or two later: wait for it before making a new workspace (a run of 0.3 s
    # undo waits made 12 workspaces in 60 presses on cmux21, which grew the session under the later presses).
    if wait(lambda: (focused() or {}).get("kind") == "terminal", 3):
        return True
    reply = rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": "shortcut-latency"}, "wait": True})
    note(f"newTab (set-up): {json.dumps(reply)[:200]}")
    ok = wait(lambda: (focused() or {}).get("kind") == "terminal", 30)
    time.sleep(1.0)  # test harness: the shell prompt
    return ok


def uptime_us():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) / 1000.0


def press(action, window):
    key, modifiers, _ = SHORTCUTS[action]
    # No timestamp from here (cmux-ad 03:40Z: no time comes from Python): the app stamps the key event when debug.key
    # makes it (DebugKey.send: systemUptime), so input_age_ms is the app's own event-to-run time. `sent_us` only picks
    # which run belongs to this press; no number is computed from it.
    sent = uptime_us()
    reply = rpc("debug.key", {"key": key, "modifiers": modifiers, "window": window}, timeout=15)
    return {"action": action, "sent_us": sent,
            "error": reply.get("error") if isinstance(reply, dict) else None}


def before(action):
    """The press's precondition (untimed): a focused terminal; for Cmd-W one more terminal tab to close."""
    ensure_terminal()
    if action == "closeTab":
        count = tab_count()
        rpc("action.run", {"action": "newSurface", "wait": True})
        wait(lambda: tab_count() > count and (focused() or {}).get("kind") == "terminal", 10)
        time.sleep(0.5)  # test harness: the new terminal's shell starts


def after(action, state):
    """Undo of the press (untimed, a script action, origin cli: not counted as a user run)."""
    if action in ("newTab.default", "newSurface"):
        if tab_count() > state["tabs"]:
            rpc("action.run", {"action": "closeTab", "wait": True})
            wait(lambda: tab_count() <= state["tabs"], 10)
    elif action == "newTab":
        if workspace_count() > state["workspaces"]:
            rpc("action.run", {"action": "closeWorkspace", "wait": True})
            wait(lambda: workspace_count() <= state["workspaces"], 10)
    elif action == "commandPalette":
        rpc("debug.key", {"key": "escape", "modifiers": [], "window": state["window"]})
    time.sleep(0.3)  # test harness: the undo's frames settle before the next press


def pct(values, q):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round(q * (len(values) - 1))))], 2)


def dist(values):
    return {"n": len([v for v in values if v is not None]), "p50": pct(values, 0.5), "p95": pct(values, 0.95),
            "max": pct(values, 1.0)}


def match_runs(presses, intervals, app_pid):
    """Each press's user run of its action: the first action.commit (and its action.perform) of that id that starts
    after the send, from a person (input_age_ms >= 0)."""
    by_name = collections.defaultdict(list)
    for interval in intervals:
        if interval.get("pid") == app_pid and interval["category"] == "action":
            by_name[interval["name"]].append(interval)
    for name in by_name:
        by_name[name].sort(key=lambda i: i["start_us"])
    for p in presses:
        def first(name):
            for interval in by_name.get(name, []):
                fields = interval.get("fields") or {}
                if fields.get("id") != p["action"] or interval["start_us"] < p["sent_us"] - 500:
                    continue
                # A run with no input age (a key a terminal routes back, as Cmd-K through Ghostty's binding) still
                # counts: its origin must be the user's; its input age is then unknown (None).
                if float(fields.get("input_age_ms", "-1")) < 0 and fields.get("origin") != "user":
                    continue
                if interval["start_us"] > p["sent_us"] + 2_000_000:
                    return None
                return interval
            return None
        commit, perform = first("action.commit"), first("action.perform")
        if not commit:
            near = sorted({(i["fields"] or {}).get("id", "?") + "/" + str((i["fields"] or {}).get("origin"))
                           for i in by_name.get("action.commit", []) if p["sent_us"] - 500 <= i["start_us"] <= p["sent_us"] + 1_000_000})
            p["missing"] = f"no user action.commit of {p['action']} after the send; runs in the next 1 s: {near}"
            continue
        age = float(commit["fields"].get("input_age_ms", "-1"))
        known = age >= 0
        p.update(run_start_us=commit["start_us"], commit_end_us=commit["end_us"], input_age_ms=round(age, 3) if known else None,
                 event_us=commit["start_us"] - (age * 1000.0 if known else 0.0), origin=commit["fields"].get("origin"),
                 commit_ms=round(commit["ms"], 3), commit_missed=commit.get("missed"), nested=commit.get("nested_loop"),
                 input_to_commit_ms=round(age + commit["ms"], 3) if known else None)
        if perform:
            p.update(perform_start_us=perform["start_us"], perform_end_us=perform["end_us"], perform_ms=round(perform["ms"], 3),
                     after_ms=round(commit["ms"] - perform["ms"], 3))


def is_main(thread, app_pid):
    return thread.get("pid") == app_pid and (thread.get("name") or "").startswith("Main Thread")


_parse_value = trace.parse_value


def parse_value(elem, vals):
    """trace.py's cell reader, plus each frame's binary: `symbol [binary]` (the export names the module only there)."""
    if elem.tag == "binary":
        return ("BIN", elem.get("name") or "")
    if elem.tag == "frame":
        name = elem.get("name") or elem.get("addr") or "?"
        binary = next((vals.get(id(c)) for c in elem if c.tag == "binary"), None)
        binary = binary[1] if isinstance(binary, tuple) and len(binary) == 2 and binary[0] == "BIN" else ""
        return f"{name} [{binary}]" if binary else name
    return _parse_value(elem, vals)


trace.parse_value = parse_value  # xctrace_rows reads the module's global
FRAME = re.compile(r"^(.*) \[([^\]]*)\]$")


def frame_parts(frame):
    match = FRAME.match(frame or "")
    return (match.group(1), match.group(2)) if match else (frame or "?", "")


def ours(frame):
    _, binary = frame_parts(frame)
    return bool(OUR_MODULE.search(binary))


IDLE_LEAF = re.compile(r"mach_msg|kevent|__psynch|semaphore_wait|__ulock_wait|__workq_kernreturn")


def bucket(stack):
    """perf-profile-split's buckets for a leaf-first stack: the CA commit wherever it is on the stack, idle by the
    leaf, else the first frame from the leaf that is ours or a framework's (by its binary)."""
    for frame in stack:
        if split.COMMIT_SYMBOL.search(frame_parts(frame)[0]):
            return "framework.ca_commit"
    if stack and IDLE_LEAF.search(frame_parts(stack[0])[0]):
        return "idle"
    for frame in stack:
        symbol, binary = frame_parts(frame)
        if OUR_MODULE.search(binary):
            return "ours"
        for name, module in split.FRAMEWORK:
            if module.match(binary):
                if name == "framework.appkit" and split.LAYOUT_SYMBOL.search(symbol):
                    return "framework.appkit_layout"
                if name == "framework.appkit" and split.DRAW_SYMBOL.search(symbol):
                    return "framework.draw"
                return name
    return "framework.other"


def analyze_samples(presses, samples, offset_us, app_pid):
    """Per action: main-thread samples inside each run window, by phase and bucket, and the heaviest frames."""
    report = {}
    main = sorted(((t / 1000.0 + offset_us, w, stack) for t, w, thread, stack in samples if is_main(thread, app_pid)),
                  key=lambda s: s[0])
    times = [s[0] for s in main]
    import bisect
    for action in CHOSEN:
        rows = [p for p in presses if p["action"] == action and p.get("run_start_us")]
        buckets = collections.Counter()
        phases = collections.Counter()
        inclusive = collections.Counter()
        leaves = collections.Counter()
        stacks = collections.Counter()
        windows_ms = 0.0
        for p in rows:
            # The window starts at the app's own key event time (run start minus the signpost's input age), so the
            # event's queue wait shows as main-thread work before the run; it ends at the commit's end signpost.
            a, b = p["event_us"], p["commit_end_us"]
            windows_ms += (b - a) / 1000.0
            lo, hi = bisect.bisect_left(times, a), bisect.bisect_right(times, b)
            for t, weight, stack in main[lo:hi]:
                ms = weight / 1e6
                phase = ("before_run" if t < p["run_start_us"] else
                         "handler" if p.get("perform_end_us") and t <= p["perform_end_us"] else "after_handler")
                phases[phase] += ms
                kind = bucket(stack)
                buckets[f"{phase}:{kind}"] += ms
                seen = set()
                for frame in stack:
                    if ours(frame) and frame not in seen:
                        inclusive[frame] += ms
                        seen.add(frame)
                leaves[stack[0] if stack else "?"] += ms
                ourstack = [f for f in stack if ours(f)][:12]
                stacks[(phase, kind, " <- ".join(ourstack[:8]) or (stack[0] if stack else "?"))] += ms
        n = max(1, len(rows))
        report[action] = {
            "presses": len(rows), "window_ms_per_press": round(windows_ms / n, 2),
            "phases_ms_per_press": {k: round(v / n, 2) for k, v in phases.most_common()},
            "buckets_ms_per_press": {k: round(v / n, 2) for k, v in buckets.most_common()},
            "ours_inclusive_ms_per_press": [[f, round(v / n, 2)] for f, v in inclusive.most_common(30)],
            "leaf_ms_per_press": [[f, round(v / n, 2)] for f, v in leaves.most_common(20)],
        }
        with open(os.path.join(OUT, f"stacks-{action}.txt"), "w") as f:
            f.write(f"{action}: {len(rows)} presses; ms per press, phase, bucket, our frames leaf first\n")
            for (phase, kind, text), v in stacks.most_common(80):
                f.write(f"{v / n:7.2f}  {phase:13s} {kind:24s} {text}\n")
    return report


def main():
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_HANG_THRESHOLD_MS": "8", "CMUX_NEXT_AGENT_PANE_MOCK": "1", "ACPMUX_AGENT_LAUNCH": "deny",
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1600,1000"}
    app = BenchApp(APP, out=OUT, log_name=f"app-{opts.tag}.log", window=None, screen=None, teardown=True, env=env)
    result = {"tag": opts.tag, "host": os.uname().nodename, "session": opts.session, "profiled": not opts.no_profile,
              "presses_per_shortcut": opts.presses}
    signposts = trace.SignpostStream(os.path.join(OUT, "signposts.ndjson"))
    xc = None
    presses = []
    try:
        app.launch(timeout=120)
        SOCKET[0] = app.socket
        app_pid = app.process.pid
        result["app_pid"] = app_pid
        time.sleep(2)  # test harness: the window and its first terminal settle
        if opts.session == "stress":
            stress = load("perf_stress_session", "perf-stress-session.py")
            note("building STRESS")
            builder = stress.Stress(rpc, log=note)
            result["stress"] = builder.build(check=False)
        if not ensure_terminal():
            raise SystemExit("no focused terminal")
        window = ((rpc("debug.windows") or {}).get("windows") or [{}])[0].get("id")
        # One warm press of each shortcut (spares, caches, first-use costs), not reported.
        for action in CHOSEN:
            before(action)
            state = {"tabs": tab_count(), "workspaces": workspace_count(), "window": window}
            press(action, window)
            time.sleep(opts.settle)
            after(action, state)
        signposts.start()
        if not opts.no_profile:
            cap = 60 + len(CHOSEN) * opts.presses * (opts.settle + 3.0)
            xc = trace.XcTrace(OUT, cap_s=cap)
            xc.attach = app_pid
            xc.start()
            # KIT.md: the profiled key waits for the profiler's first sample, not its start line.
            time.sleep(opts.first_sample_wait)
            result["xctrace"] = {"command": xc.command(), "started_us": xc.started_us, "started_wall": xc.started_wall}
        for action in CHOSEN:
            for index in range(opts.presses):
                before(action)
                state = {"tabs": tab_count(), "workspaces": workspace_count(), "window": window}
                row = press(action, window)
                row["index"] = index
                presses.append(row)
                time.sleep(opts.settle)
                after(action, state)
        if xc:
            xc.stop()
        signposts.stop()
    finally:
        if xc and xc.proc and xc.proc.poll() is None:
            xc.kill()
        try:
            app.stop()
        except Exception as error:  # the report still comes from what was recorded
            note(f"app stop: {error}")
    parsed = trace.read_signposts(os.path.join(OUT, "signposts.ndjson"))
    match_runs(presses, parsed["intervals"], result["app_pid"])
    result["signposts_lost"] = parsed["lost"]
    if xc:
        exported = trace.export_xctrace(OUT)
        toc = trace.parse_toc(os.path.join(OUT, "xctrace-toc.xml"))
        xc_signposts = trace.xctrace_signposts(exported["os-signpost"]) if "os-signpost" in exported else None
        offset, how, warning = trace.xctrace_offset_us(xc_signposts, toc, parsed["intervals"], result)
        result["clock"] = {"how": how, "warning": warning}
        samples = trace.time_profile_samples(exported["time-profile"]) if "time-profile" in exported else []
        app_samples = [t / 1000.0 + offset for t, _, thread, _ in samples if thread.get("pid") == result["app_pid"]]
        first_press = min((p["event_us"] for p in presses if p.get("event_us")), default=None)  # the app's own key time
        result["first_sample_before_first_press"] = bool(app_samples and first_press and min(app_samples) < first_press)
        result["first_sample_lead_ms"] = round((first_press - min(app_samples)) / 1000.0, 1) if app_samples and first_press else None
        result["profile"] = analyze_samples(presses, samples, offset, result["app_pid"])
    result["timing"] = {}
    for action in CHOSEN:
        rows = [p for p in presses if p["action"] == action]
        result["timing"][action] = {
            "label": SHORTCUTS[action][2], "matched": len([r for r in rows if r.get("run_start_us")]), "presses": len(rows),
            **{metric: dist([r.get(metric) for r in rows])
               for metric in ("input_age_ms", "perform_ms", "after_ms", "commit_ms", "input_to_commit_ms")},
            "errors": [r.get("error") or r.get("missing") for r in rows if r.get("error") or r.get("missing")][:5],
        }
    result["presses"] = presses
    lines = [f"SHORTCUT LATENCY {opts.session} profiled={not opts.no_profile} presses={opts.presses} host={result['host']}",
             "ms p50/p95/max: input_age (key to run start) | perform (handler) | after (handler end to commit end) | input_to_commit"]
    for action, t in result["timing"].items():
        def f(m):
            d = t[m]
            return f"{d['p50']}/{d['p95']}/{d['max']}"
        lines.append(f"  {t['label']:12s} {action:16s} n={t['matched']}/{t['presses']}  {f('input_age_ms')} | {f('perform_ms')} | "
                     f"{f('after_ms')} | {f('input_to_commit_ms')}" + (f"  errors={t['errors']}" if t["errors"] else ""))
    for action, prof in (result.get("profile") or {}).items():
        lines.append(f"PROFILE {action}: main-thread ms per press by phase {prof['phases_ms_per_press']}")
        lines.append(f"  buckets {dict(list(prof['buckets_ms_per_press'].items())[:8])}")
        for frame, ms in prof["ours_inclusive_ms_per_press"][:12]:
            lines.append(f"  {ms:6.2f} ms  {frame[:160]}")
    if xc:
        lines.append(f"first sample before first press: {result.get('first_sample_before_first_press')} "
                     f"(lead {result.get('first_sample_lead_ms')} ms); clock {result.get('clock')}")
    text = "\n".join(lines)
    print(text, flush=True)
    open(os.path.join(OUT, "SUMMARY.txt"), "w").write(text + "\n")
    if opts.json:
        open(opts.json, "w").write(json.dumps(result, indent=1))
    # The step log carries the whole report too (the controller returns --artifact only on a pass).
    print("SHORTCUT-LATENCY-REPORT " + json.dumps({k: v for k, v in result.items() if k != "presses"}), flush=True)
    for action in CHOSEN:
        path = os.path.join(OUT, f"stacks-{action}.txt")
        if os.path.exists(path):
            print(open(path).read()[:6000], flush=True)
    return all(t["matched"] for t in result["timing"].values())


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
