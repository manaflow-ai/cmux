#!/usr/bin/env python3
"""Instant new tab on a running no-activate tagged build (plans/cmux-next/new-tab.md 2.3).

Opens the new tab page and types in the same main-actor turn (`debug.new_tab`
open_and_type), then checks the field holds every key and has focus, closes the
tab, waits for the next spare, and repeats. Budget: a spare adoption under 16 ms
of main-thread time at p95, no lost key. Prints the cold opening and each spare's
WebContent footprint. Run on cmux-lawrence-2 or the fleet, never the laptop.

Launches the tagged app itself (no-activate, automation socket, scratch cmux.json
and an empty Ghostty config) and kills it at the end.

Usage: new-tab-e2e.py --tag <tag> [--runs 20] [--budget-ms 16]
"""
import argparse, glob, json, os, signal, socket, statistics, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--runs", type=int, default=20)
parser.add_argument("--budget-ms", type=float, default=16)
parser.add_argument("--text", default="hello")
parser.add_argument("--bench", action="store_true",
                    help="R81: Cmd-W and ! latency (main-thread ms, missed frames, span breakdown) instead of the open test")
parser.add_argument("--budget-close-ms", type=float, default=10)
parser.add_argument("--trace", action="store_true",
                    help="with --bench: record a Time Profiler trace during the runs and print the main thread's heaviest frames")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
APP = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
SCRATCH = tempfile.mkdtemp(prefix=f"newtab-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
WINDOW_IDS = []  # debug.surfaces window ids by index, for debug.key
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")


def rpc(method, params=None):
    """One request on the tagged debug socket (newline-delimited JSON, as background-match-e2e.py)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
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


def wait(label, predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)  # test harness wait, not app code
    sys.exit(f"FAIL {label} (timed out after {timeout:.0f} s)\n{json.dumps(rpc('debug.new_tab', {'action': 'state'}), indent=1)}")


def state():
    return rpc("debug.new_tab", {"action": "state"}) or {}


def open_and_check(expect_spare, snapshot=None, close=1, window=0):
    reply = rpc("debug.new_tab", {"action": "open_and_type", "text": opts.text, "window": window}) or {}
    opening = reply.get("opening") or {}
    if reply.get("first_responder") != "WKWebView":
        print(f"note: first responder right after the open: {reply.get('first_responder')}", flush=True)
    if opening.get("spare") != expect_spare:
        sys.exit(f"FAIL expected spare={expect_spare}, got {opening}")
    last = {}

    def read_field():
        last["field"] = rpc("debug.new_tab", {"action": "field", "window": window}) or {}
        last["focus"] = rpc("debug.focus") or {}
        return last["field"].get("text") == opts.text and last["field"]

    deadline = time.time() + 5
    field = None
    while time.time() < deadline and not (field := read_field()):
        time.sleep(0.1)  # test harness wait, not app code
    if not field:
        # Control: a key typed into the settled page, to tell a lost first key from a key path
        # that never reaches the page in this window.
        rpc("debug.key", {"key": "z"})
        time.sleep(1)  # test harness wait
        print(f"control after a settled key 'z': {rpc('debug.new_tab', {'action': 'field'})}", flush=True)
        sys.exit(f"FAIL the field lost keys: {last.get('field')}\nfocus: {json.dumps(last.get('focus'))[:1500]}")
    if not field.get("focused"):
        sys.exit(f"FAIL the field does not have focus: {field}")
    if snapshot:
        print(f"snapshot: {rpc('debug.window_snapshot', {'path': snapshot})}")
    for _ in range(close):
        rpc("debug.key", {"key": "w", "modifiers": ["command"], **({"window": WINDOW_IDS[window]} if window else {})})
    return opening


def p95(values):
    values = sorted(values)
    return values[max(0, int(round(0.95 * len(values))) - 1)] if values else 0


def summarize(label, results):
    keys = [r["key_ms"] for r in results]
    visible = [r["visible_ms"] for r in results if r.get("visible_ms") is not None]
    missed = [r["frames"]["missed"] for r in results]
    worst = [r["frames"]["max_ms"] for r in results]
    print(f"{label}: key p50={statistics.median(keys):.2f} p95={p95(keys):.2f} ms; "
          f"visible p50={statistics.median(visible) if visible else -1:.1f} p95={p95(visible):.1f} ms; "
          f"missed frames total={sum(missed)} runs-with-misses={sum(1 for m in missed if m)}; "
          f"worst frame p95={p95(worst):.1f} max={max(worst):.1f} ms", flush=True)
    names = {}
    for r in results:
        for span in r["spans"]:
            names.setdefault(span["name"], []).append(span["ms"])
    for name, values in sorted(names.items(), key=lambda kv: -statistics.median(kv[1])):
        print(f"  span {name}: n={len(values)} p50={statistics.median(values):.2f} p95={p95(values):.2f} ms", flush=True)
    # Where the missed frames fall (ms after the key, interval), to match them with spans.
    for i, r in enumerate(results):
        t, misses = 0.0, []
        period = r["frames"]["refresh_ms"] or 8.33
        for interval in r["frames"]["intervals_ms"]:
            t += interval
            if interval > period * 1.5:
                misses.append(f"{t:.0f}ms:{interval:.1f}")
        if misses:
            spans = ", ".join(f"{s['name']}@{s['at']:.0f}={s['ms']:.1f}" for s in r["spans"] if s["ms"] >= 0.5 or s["name"].startswith(("daemon", "bridge")))
            print(f"  run {i}: misses {misses}; spans {spans}", flush=True)


def ready_spare():
    return wait("a loaded spare is parked", lambda: [s for s in state().get("spares", []) if s.get("ready")], 20)


def main_thread_profile(trace):
    """Heaviest main-thread frames (inclusive and leaf sample counts) in a Time Profiler trace."""
    import xml.etree.ElementTree as ET
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], capture_output=True, text=True).stdout
    schema = "time-profile" if 'schema="time-profile"' in toc else "time-sample"
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

    inclusive, leaf, samples = {}, {}, 0
    for row in root.iter("row"):
        thread = backtrace = None
        for child in row:
            node = resolve(child)
            if child.tag == "thread":
                thread = node
            elif child.tag in ("backtrace", "tagged-backtrace"):
                backtrace = node
        if thread is None or backtrace is None:
            continue
        if "Main Thread" not in (thread.get("fmt") or ""):
            continue
        samples += 1
        bt = backtrace if backtrace.tag == "backtrace" else next(iter(backtrace.iter("backtrace")), None)
        if bt is None:
            continue
        frames = [resolve(f).get("name") or "?" for f in bt.iter("frame")]
        if frames:
            leaf[frames[0]] = leaf.get(frames[0], 0) + 1
        for name in set(frames):
            inclusive[name] = inclusive.get(name, 0) + 1
    print(f"main-thread samples: {samples}", flush=True)
    skip = ("main", "start", "NSApplicationMain", "-[NSApplication run]", "_DPSNextEvent", "CFRunLoopRun")
    for name, count in sorted(inclusive.items(), key=lambda kv: -kv[1])[:60]:
        if not name.startswith(skip):
            print(f"  incl {count:5d} {name[:160]}", flush=True)
    for name, count in sorted(leaf.items(), key=lambda kv: -kv[1])[:25]:
        print(f"  leaf {count:5d} {name[:160]}", flush=True)


def run_bench():
    closes, bangs = [], []
    recorder = None
    trace = os.path.join(os.environ.get("NX_ARTIFACTS", SCRATCH), "new-tab-bench.trace")
    if opts.trace:
        recorder = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(app.pid),
                                     "--time-limit", "40s", "--output", trace], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        time.sleep(3)  # test harness: the recorder attaches
    for _ in range(opts.runs):
        ready_spare()
        rpc("debug.new_tab", {"action": "open_and_type", "text": ""})
        time.sleep(0.4)  # test harness: the page settles before the measured close
        closes.append(rpc("debug.new_tab", {"action": "bench_close"}))
    for _ in range(opts.runs):
        ready_spare()
        rpc("debug.new_tab", {"action": "open_and_type", "text": ""})
        time.sleep(0.4)  # test harness: the page settles before the measured key
        bangs.append(rpc("debug.new_tab", {"action": "bench_bang"}))
        time.sleep(0.3)  # test harness
        rpc("debug.key", {"key": "w", "modifiers": ["command"]})
    bad = [r for r in closes + bangs if not isinstance(r, dict) or "error" in r]
    if bad:
        sys.exit(f"FAIL bench errors: {bad[:3]}")
    summarize("Cmd-W on the new tab page", closes)
    summarize("! on the new tab page", bangs)
    if recorder:
        recorder.wait(timeout=120)
        main_thread_profile(trace)


app = None
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(SCRATCH, "app.log"), "a"),
                           stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    wait("the tagged app comes up", lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 90)
    print("app is up", flush=True)
    time.sleep(2)  # test harness: let the first workspace settle
    if opts.bench:
        run_bench()
        sys.exit(0)
    spare_ms, footprints = [], []
    for run in range(opts.runs):
        spares = wait("a loaded spare is parked", lambda: [s for s in state().get("spares", []) if s.get("ready")], 20)
        footprints += [s["footprint_mb"] for s in spares if s.get("footprint_mb") is not None]
        shot = os.path.join(os.environ.get("NX_ARTIFACTS", SCRATCH), "new-tab-spare.png") if run == 0 else None
        spare_ms.append(open_and_check(True, shot)["ms"])
    # Cold: two opens back to back, so the second finds the slot empty (the next spare waits
    # for quiet input); close both tabs.
    wait("a loaded spare is parked", lambda: [s for s in state().get("spares", []) if s.get("ready")], 20)
    rpc("debug.new_tab", {"action": "open_and_type", "text": ""})
    opening = (rpc("debug.new_tab", {"action": "open_and_type", "text": opts.text}) or {}).get("opening") or {}
    if opening.get("spare") is not False:
        sys.exit(f"FAIL the second back-to-back opening should be cold: {opening}")
    time.sleep(5)  # test harness: let the cold page load before reading its field
    field = rpc("debug.new_tab", {"action": "field"}) or {}
    print(f"cold opening: {opening['ms']:.2f} ms main thread; field after 5 s: {field} "
          f"({'keys kept' if field.get('text') == opts.text else 'KEYS LOST on the cold path'})")
    for _ in range(2):
        rpc("debug.key", {"key": "w", "modifiers": ["command"]})
    p95 = sorted(spare_ms)[max(0, int(round(0.95 * len(spare_ms))) - 1)]
    print(f"spare openings: n={len(spare_ms)} p50={statistics.median(spare_ms):.2f} ms p95={p95:.2f} ms max={max(spare_ms):.2f} ms")
    if footprints:
        print(f"spare WebContent footprint: median={statistics.median(footprints):.1f} MB max={max(footprints):.1f} MB")
    # One spare per app: a second window adopts the spare parked in the first (a reparent), and a
    # key-window change moves the parked spare (debug `retarget`, since no-activate windows never
    # become key).
    windows_before = len((rpc("debug.surfaces") or {}).get("windows", []))
    print(f"new window: {rpc('action.run', {'id': 'newWindow'})}", flush=True)
    wait("a second window", lambda: len((rpc("debug.surfaces") or {}).get("windows", [])) > windows_before, 30)
    WINDOW_IDS[:] = [w.get("id") for w in (rpc("debug.focus") or {}).get("windows", [])]
    time.sleep(2)  # test harness: let the new window's workspace settle
    wait("a loaded spare is parked", lambda: [s for s in state().get("spares", []) if s.get("ready")], 20)
    cross = open_and_check(True, window=1)
    print(f"cross-window adoption: {cross}", flush=True)
    wait("a loaded spare is parked", lambda: [s for s in state().get("spares", []) if s.get("ready")], 20)
    moved = rpc("debug.new_tab", {"action": "retarget", "window": 1}) or {}
    print(f"key-window change moves the spare: target={moved.get('target_window')} move={moved.get('last_retarget_ms')} ms", flush=True)
    after = open_and_check(True, window=1)
    print(f"after the move, same-window adoption: {after}", flush=True)
    if p95 > opts.budget_ms:
        sys.exit(f"FAIL p95 {p95:.2f} ms is over the {opts.budget_ms} ms budget")
    print("ok: no lost key in any run; p95 within budget")
finally:
    if app and app.returncode not in (None, 0):
        print(open(os.path.join(SCRATCH, "app.log")).read()[-3000:])
    if app and app.poll() is None:
        app.send_signal(signal.SIGKILL)
        print(f"killed {app.pid}", flush=True)
