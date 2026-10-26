#!/usr/bin/env python3
"""Terminal typing while agents automate the app (plans/cmux-next/main-thread-budget.md; Lawrence 2026-10-23:
agent automation must never block the main thread).

Launches the tagged app (bench_launch.py: no activation, scratch config, isolated Chief, typing probe on, the hang
watchdog at 8 ms), makes --agents workspaces whose terminal runs `cat`, one workspace with a Chromium page of a few
thousand rows, and one focused workspace whose terminal runs `cat` (the tty echoes each key). Then it types --samples
keys in each phase:

  idle        nothing else happens
  automation  at the same time:
              - terminal agents: `cmux terminal <tab> write` round robin over the agent terminals at --agent-hz writes
                a second in total (the CLI path agents use: daemon -> PTY, no app main-thread hop expected)
              - one browser agent drives the Chromium page in a loop through the app's control socket: page text
                (browser.page.eval), a screenshot (browser.page.screenshot, inline PNG), a click and the page state
              - with --ax, one accessibility client walks the app's AX tree in a loop (a compiled helper; needs this
                host's Accessibility grant for the step's process, else the report says `ax: not trusted` and the
                phase runs without it)

Layouts (--layouts, both by default, reported side by side): `light` types into the focused `typing` workspace
above; `stress` then builds the standard STRESS session around it (perf-stress-session.py, Stress(rpc).build(): 60
workspaces, the 4x3 grid of 6-tab panes with 10 busy terminals, 10 workspaces of Chromium pages), prints its
STRESS-SESSION line and types into the measured workspace's focused terminal under the same agents.

Validity: the browser agent's page must be Chromium. Before the first phase the bench reads `debug.cef` (no error,
no `unavailable`, no WebKit fallback, state ready, no web-dev.json dev server) and the page's engine in
`debug.layers`; anything else exits 2 without measuring (a WebKit page would be measured silently otherwise). The
report records the host, its macOS and each display's resolution line with its refresh rate.

Input (--input, bench_input.py, shared with sidebar-churn-typing.py): `real` posts each key at the HID event tap, so
it takes a person's path through the window server and the app's event queue, and the probe's `contents_ms` is the
event's HID time to the frame that shows the echo (the number to quote; the job needs the GUI session and the input
grant, and the app runs frontmost). `debug` (default) is `debug.key` with the client's send time as the event's
timestamp (CLOCK_UPTIME_RAW): the socket's injected-input lane, never quoted as key latency. Per phase: key to frame
p50/p95/p99/max (scripts/perf-lab/perf_stats.py through typing_report.distribution), the scheduler's turn p99,
unattributed share, input yields and input-response yields (debug.main_budget; None until the app reports them), the
main-thread stalls over 8 ms (`debug.hangs`, each naming the scheduled task it caught), the tasks past their class
budget with stacks (`debug.hangs` over_budget), the scheduler counters (`debug.main_budget`), the agents' operation
counts and latencies. Each layout's key-to-frame samples, all rounds of a phase kind together, are also one
cmux-perf-result/v1 file per series in --out (BenchApp.record): story --story (default `automation-typing`) for the
light layout and `<story>-stress` for STRESS, metrics `idle.key_to_frame` and `automation.key_to_frame`
(`hid_key_to_frame` with --input real: another path, another series), engine chromium (the browser agent's page).

  automation-typing-bench.py --app APP --out DIR [--json DIR/report.json] [--layouts light,stress] [--agents 10]
      [--agent-hz 40] [--samples 120] [--rounds 1] [--ax] [--input debug|real] [--gate-p95-ms 8] [--gate-stall-ms 8]
      [--story ID]

The summary per layout keeps its idle/automation p95 and p99 keys and adds `modes`: {input mode: idle and storm
(automation) key-to-frame p50/p95/p99/max, storm minus idle p99, and each side's turn p99, unattributed share and
yield counts}.

Gates (exit 1): any layout's automation phase key-to-frame p95 over --gate-p95-ms, or a main-thread stall longer than
--gate-stall-ms. Fleet: `cmux-ci run --class exclusive --measurement --label measure --script
scripts/measure/split-spring.sh --ref SHA --artifact artifacts/split-spring/report.json --arg=--suite=automation-typing`.
"""
import argparse, csv, importlib.util, json, os, pathlib, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_tagged  # noqa: E402
import typing_report  # noqa: E402
from bench_launch import BenchApp, LaunchError  # noqa: E402
from bench_input import INPUT_HELP, INPUT_MODES, KeySender, budget_summary, frame_samples, mode_summary, typed_key  # noqa: E402


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


STRESS = load("perf_stress_session", "perf-stress-session.py")

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag")  # split-spring.sh passes it; the app's own tag is read from the bundle
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--layouts", default="light,stress", help="comma list of light and stress (STRESS session)")
parser.add_argument("--agents", type=int, default=10)
parser.add_argument("--agent-hz", type=float, default=40.0, help="terminal agent writes per second, all agents together")
parser.add_argument("--samples", type=int, default=120)
parser.add_argument("--interval", type=float, default=0.12, help="seconds between keys (wider than one echo)")
parser.add_argument("--rounds", type=int, default=1)
parser.add_argument("--input", choices=INPUT_MODES, default="debug", help=INPUT_HELP)
parser.add_argument("--ax", action="store_true", help="also walk the app's AX tree in a loop (needs the Accessibility grant)")
parser.add_argument("--rows", type=int, default=3000, help="rows on the browser agent's page")
parser.add_argument("--gate-p95-ms", type=float)
parser.add_argument("--gate-stall-ms", type=float)
parser.add_argument("--story", default=typing_report.AUTOMATION_STORY,
                    help="result-v1 story of the light layout; the stress layout's is <story>-stress")
opts = parser.parse_args()
LAYOUTS = [name for name in opts.layouts.split(",") if name]
if not LAYOUTS or set(LAYOUTS) - {"light", "stress"}:
    parser.error("--layouts takes light and stress")
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
PROBE = os.path.join(OUT, "typing.csv")
results = {"host": load("action_signposts_bench", "action-signposts-bench.py").host_facts(), "opts": vars(opts), "log": [],
           "input": opts.input, "phases": []}
SAMPLES = {}  # layout -> result-v1 metric -> key-to-frame samples, every round together


def note(text):
    print(text, flush=True)
    results["log"].append(text)


dist = typing_report.distribution


def wait(check, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:  # bounded wait for the live app
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def probe_rows():
    try:
        with open(PROBE) as handle:
            return list(csv.DictReader(handle))
    except OSError:
        return []


def rpc(method, params=None, timeout=60):
    return APP.rpc(method, params, timeout=timeout)


KEYS = KeySender(opts.input, lambda key, timestamp: rpc("debug.key", {"key": key, "timestamp": timestamp}, timeout=10))
APP = BenchApp(opts.app, out=OUT, env=KEYS.launch_env({"CMUX_NEXT_TYPING_PROBE": PROBE, "CMUX_NEXT_HANG_THRESHOLD_MS": "8"}),
               window=(40, 40, 1200, 900))


def cli(*args, timeout=60):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    try:
        return subprocess.run([APP.cli, "--app-socket", APP.socket, *args], env=env, capture_output=True, text=True,
                              timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "timeout")


def topology():
    snap = rpc("snapshot.get") or {}
    return snap.get("topology") or {}


def terminal_of(workspace_name):
    for ws in topology().get("workspaces") or []:
        if (ws.get("name") or ws.get("title")) != workspace_name:
            continue
        for screen in ws.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("kind") == "terminal":
                        # The CLI's terminal selector is the daemon's terminal id (`term_...`), not the tab id.
                        return tab.get("terminal") or tab.get("id")
    return None


# ---------------------------------------------------------------- load
class Load(threading.Thread):
    def __init__(self, name, step, hz):
        super().__init__(daemon=True)
        self.name_, self.step, self.period = name, step, 1.0 / hz if hz > 0 else 0
        self.stop_flag = threading.Event()
        self.ops, self.failures, self.ms = 0, 0, []

    def run(self):
        while not self.stop_flag.is_set():
            t0 = time.perf_counter()
            ok = self.step(self.ops)
            spent = time.perf_counter() - t0
            self.ops += 1
            self.ms.append(spent * 1000)
            if not ok:
                self.failures += 1
            rest = self.period - spent
            if rest > 0:
                self.stop_flag.wait(rest)  # the agent's pace

    def stop(self):
        self.stop_flag.set()
        self.join(timeout=60)

    def report(self, wall):
        return {"ops": self.ops, "failures": self.failures, "ops_per_s": round(self.ops / max(wall, 0.001), 1),
                "op_ms": dist(self.ms)}


def terminal_agents(tabs):
    def step(index):
        tab = tabs[index % len(tabs)]
        done = cli("terminal", tab, "write", "--text", f"agent line {index} {'x' * 40}\n", timeout=20)
        return done.returncode == 0
    return Load("terminals", step, opts.agent_hz)


def browser_agent(tab):
    def step(index):
        kind = index % 4
        if kind == 0:
            reply = rpc("browser.page.eval", {"tab": tab, "script": "document.body.innerText.length"}, timeout=20)
        elif kind == 1:
            reply = rpc("browser.page.screenshot", {"tab": tab}, timeout=30)
        elif kind == 2:
            reply = rpc("browser.page.click", {"tab": tab, "selector": "#b"}, timeout=20)
        else:
            reply = rpc("browser.page.state", {"tab": tab}, timeout=20)
        return isinstance(reply, dict) and not reply.get("error")
    return Load("browser", step, 0)


AX_HELPER = r'''
import ApplicationServices
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
let seconds = Double(CommandLine.arguments[2])!
guard AXIsProcessTrusted() else { print("untrusted"); exit(2) }
let app = AXUIElementCreateApplication(pid)
func walk(_ element: AXUIElement, _ depth: Int, _ count: inout Int) {
    count += 1
    var role: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    var title: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
    guard depth < 8 else { return }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let list = children as? [AXUIElement] else { return }
    for child in list.prefix(40) { walk(child, depth + 1, &count) }
}
let end = Date().addingTimeInterval(seconds)
var walks = 0, elements = 0
while Date() < end { var count = 0; walk(app, 0, &count); walks += 1; elements += count }
print("walks \(walks) elements \(elements)")
'''


def ax_client(pid, seconds):
    """A compiled AX walker (in the out folder); None with the reason when it cannot run."""
    source = os.path.join(OUT, "ax-walk.swift")
    binary = os.path.join(OUT, "ax-walk")
    open(source, "w").write(AX_HELPER)
    built = subprocess.run(["xcrun", "swiftc", "-O", source, "-o", binary], capture_output=True, text=True)
    if built.returncode != 0:
        return None, f"ax helper did not compile: {built.stderr[-300:]}"
    probe = subprocess.run([binary, str(pid), "0.1"], capture_output=True, text=True)
    if "untrusted" in probe.stdout:
        return None, "ax: not trusted on this host (no Accessibility grant for the step's process); AX load not run"
    return subprocess.Popen([binary, str(pid), str(seconds)], stdout=subprocess.PIPE, text=True), None


# ---------------------------------------------------------------- typing
def type_keys(count, label):
    trips, stalls = [], 0
    for index in range(count):
        t0 = time.perf_counter()
        reply = KEYS.send(typed_key(index))
        trip = (time.perf_counter() - t0) * 1000
        trips.append(trip)
        if trip > 2000 or (isinstance(reply, dict) and reply.get("error")):
            stalls += 1
            note(f"{label}: key {index} took {trip:.0f} ms ({json.dumps(reply)[:120]})")
        if stalls >= 10:
            break
        rest = opts.interval - (time.perf_counter() - t0)
        if rest > 0:
            time.sleep(rest)  # one key in flight at a time
    time.sleep(0.5)  # the last echo lands
    return trips, stalls


def phase(name, loads, pid, ax=False, series=None):
    """One typing phase; `series` is (layout, phase kind: idle or automation) whose result-v1 series gets this phase's
    key-to-frame values."""
    rows_before = len(probe_rows())
    rpc("debug.hangs", {"clear": True})
    rpc("debug.main_budget", {"reset": True})
    for load in loads:
        load.start()
    ax_proc, ax_note = (None, None)
    if ax:
        ax_proc, ax_note = ax_client(pid, opts.samples * opts.interval + 5)
        if ax_note:
            note(ax_note)
    if loads:
        time.sleep(1.0)  # the load runs before the first key
    t0 = time.monotonic()
    trips, stalls = type_keys(opts.samples, name)
    wall = time.monotonic() - t0
    for load in loads:
        load.stop()
    ax_out = None
    if ax_proc:
        try:
            ax_out = ax_proc.communicate(timeout=60)[0].strip()
        except subprocess.TimeoutExpired:
            ax_proc.terminate()
    hangs = rpc("debug.hangs", {"limit": 16}, timeout=20)
    budget = rpc("debug.main_budget", timeout=20)
    rows = probe_rows()[rows_before:]
    complete = [r for r in rows if r.get("complete") == "1" and r.get("contents_ms")]
    samples = frame_samples(rows)
    if series:
        layout, phase_kind = series
        metric = typing_report.churn_metric(phase_kind, KEYS.real)
        SAMPLES.setdefault(layout, {}).setdefault(metric, []).extend(samples)
    hangs = hangs if isinstance(hangs, dict) else {}
    entry = {
        "phase": name, "wall_s": round(wall, 1), "keys": len(trips), "stalled_keys": stalls, "key_rpc_ms": dist(trips),
        "complete": len(complete), "key_to_frame_ms": dist(samples), "key_to_frame_samples_ms": samples,
        "key_to_dispatch_ms": dist([float(r["dispatch_start_ms"]) for r in complete if r.get("dispatch_start_ms")]),
        "hangs": {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "frames_over_8_3ms", "max_gap_ms", "over_budget_count")},
        "hang_records": hangs.get("records"), "over_budget": hangs.get("over_budget"), "main_budget": budget,
        "budget": budget_summary(budget),
        "loads": {load.name_: load.report(wall) for load in loads}, "ax": ax_out or ax_note,
    }
    k = entry["key_to_frame_ms"] or {}
    note(f"{name}: key-to-frame p50 {k.get('p50')} p95 {k.get('p95')} max {k.get('max')} ms (n={k.get('n')}); "
         f"stalls {entry['hangs'].get('count')} max {entry['hangs'].get('max_ms')} ms; loads {json.dumps(entry['loads'])[:300]}")
    results["phases"].append(entry)
    return entry


PAGE = """<!doctype html><title>agent page</title><button id=b onclick="this.dataset.n=(+this.dataset.n||0)+1">go</button>
<ul>{rows}</ul>"""


def chromium_problems(cef):
    """Why the browser agent's page may not be Chromium (`debug.cef`, and the engine `debug.layers` shows for the
    browser pane of the shown window); empty when it is."""
    problems = STRESS.cef_problems(cef, STRESS.WEB_DEV_CONFIG)
    layers = rpc("debug.layers", timeout=20)
    windows = layers.get("windows") if isinstance(layers, dict) else None
    engines = sorted({b.get("engine") for w in windows or [] for b in w.get("browsers") or []})
    if engines != ["cef"]:
        problems.append(f"the shown browser panes' engines are {engines}, not cef")
    return problems


def run_layout(layout, tabs, browser_tab, pid):
    """The idle and automation phases of `layout` (--rounds each), typed into the focused terminal."""
    rpc("debug.mouse", {"x": 900, "y": 450, "action": "hover"})  # the pointer rests over the terminal
    KEYS.bring_front(pid)  # a real key goes to the frontmost app's key window
    time.sleep(4)
    rows_before_warmup = len(probe_rows())
    type_keys(10, f"{layout}-warmup")
    if KEYS.real and len(probe_rows()) <= rows_before_warmup:
        sys.exit(f"--input real ({layout}): no key reached the app (not frontmost, or this session has no input grant)")
    for r in range(opts.rounds):
        phase(f"{layout}-idle-{r}", [], pid, series=(layout, "idle"))
        loads = ([terminal_agents(tabs)] if tabs else []) + ([browser_agent(browser_tab)] if browser_tab else [])
        phase(f"{layout}-automation-{r}", loads, pid, ax=opts.ax, series=(layout, "automation"))
    idle = [p for p in results["phases"] if p["phase"].startswith(f"{layout}-idle") and p.get("key_to_frame_ms")]
    busy = [p for p in results["phases"] if p["phase"].startswith(f"{layout}-automation") and p.get("key_to_frame_ms")]
    if not (idle and busy):
        return None
    return {"idle_p95_ms": max(p["key_to_frame_ms"]["p95"] for p in idle),
            "idle_p99_ms": max(p["key_to_frame_ms"]["p99"] for p in idle),
            "automation_p95_ms": max(p["key_to_frame_ms"]["p95"] for p in busy),
            "automation_p99_ms": max(p["key_to_frame_ms"]["p99"] for p in busy),
            "automation_max_ms": max(p["key_to_frame_ms"]["max"] for p in busy),
            "automation_stalls": sum(p["hangs"].get("count") or 0 for p in busy),
            "automation_stall_max_ms": max((p["hangs"].get("max_ms") or 0) for p in busy),
            "modes": {opts.input: mode_summary(opts.input, idle, busy)}}


def record_results():
    """One cmux-perf-result/v1 file per layout and series. The light and stress layouts share one launch, so each
    layout's results name its own session and story (a lab series key has no session: store.series_key)."""
    recorded = {}
    for layout, series in SAMPLES.items():
        APP.perf_session = layout  # BenchApp.record writes the session it holds; this launch measured both
        recorded[layout] = bench_tagged.record_series(APP, typing_report.session_story(opts.story, layout), series,
                                                      engine="chromium", log=note)
    results["recorded"] = recorded


def main():
    try:
        APP.launch()
    except LaunchError as error:
        results["launch_error"] = str(error)
        raise
    pid = APP.process.pid
    summary = {}
    try:
        names = [f"agent {i:02d}" for i in range(opts.agents)]
        for name in names:
            cli("workspace", "create", "--name", name, "--shell", "exec cat")
        tabs = [t for t in (wait(lambda n=n: terminal_of(n), 20) for n in names) if t]
        note(f"agent terminals: {len(tabs)} of {opts.agents}")
        cli("workspace", "create", "--name", "browser agent", "--focus", "--empty")
        page = os.path.join(OUT, "agent-page.html")
        open(page, "w").write(PAGE.format(rows="".join(f"<li>row {i} {'lorem ipsum ' * 4}</li>" for i in range(opts.rows))))
        rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": pathlib.Path(page).as_uri()}, "origin": "script"}, timeout=120)
        browser_tab = wait(lambda: (lambda r: r.get("tab") if isinstance(r, dict) and r.get("value") is True else None)(
            rpc("browser.page.eval", {"script": "document.readyState === 'complete' && !!document.getElementById('b')"}, timeout=20)), 60, 0.5)
        note(f"browser agent tab: {browser_tab}")
        cef = rpc("debug.cef", timeout=20)
        results["cef"] = cef
        not_chromium = chromium_problems(cef) if browser_tab else ["the browser agent's page never loaded"]
        if not_chromium:
            results["invalid"] = not_chromium
            note(f"not measured: the browser agent's page is not Chromium: {not_chromium}")
            return 2
        cli("workspace", "create", "--name", "typing", "--focus", "--shell", "exec cat")
        typing = terminal_of("typing")
        results["setup"] = {"agent_terminals": len(tabs), "browser_tab": browser_tab, "typing": typing}
        for layout in LAYOUTS:
            if layout == "stress":
                session = STRESS.Stress(rpc, log=note).build()
                results["stress_session"] = session
                print("STRESS-SESSION " + json.dumps(session), flush=True)
            summary[layout] = run_layout(layout, tabs, browser_tab, pid)
    finally:
        results["summary"] = summary
        note(f"summary: {json.dumps(summary)}")
        record_results()
        with open(opts.json or os.path.join(OUT, "report.json"), "w") as f:
            json.dump(results, f, indent=1, default=str)
        APP.stop()
    for layout, numbers in summary.items():
        if not numbers:
            continue
        if opts.gate_stall_ms is not None and numbers["automation_stall_max_ms"] > opts.gate_stall_ms:
            sys.exit(f"gate ({layout}): main-thread stall {numbers['automation_stall_max_ms']} ms under automation is over {opts.gate_stall_ms} ms")
        if opts.gate_p95_ms is not None and numbers["automation_p95_ms"] > opts.gate_p95_ms:
            sys.exit(f"gate ({layout}): key-to-frame p95 {numbers['automation_p95_ms']} ms under automation is over {opts.gate_p95_ms} ms")
    return 0

sys.exit(main())
