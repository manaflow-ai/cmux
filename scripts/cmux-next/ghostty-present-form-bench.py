#!/usr/bin/env python3
"""Ghostty's present form, measured (spike p03-rendering-017, rendering-DESIGN.md "Spike 017: Ghostty present form").

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/ghostty-present-form-bench.py --app "$NX_APP" --out "$NX_ARTIFACTS/present-form" --vdisplay 120

The app must embed GhosttyNextKit from ghostty-next branch cp/p03-rendering-017, which reads the Ghostty config key
`macos-present-form`. A build without it ignores the key: every form then logs `main_contents` (or no line at all),
and the report says so (`form_mismatch`).

For each form (--forms, default main-contents,metal-layer,layer-host) the app is launched once, with a scratch
Ghostty config that sets the form (no activation, automation socket). In one new workspace it opens --terminals
terminals (10), each running `yes`, waits --settle seconds, then for --rounds windows of --seconds each records:

  frames    `debug.frames`: display-frame intervals, missed frames (an interval over 1.5 refresh periods), and the
            main thread's busy time per frame (main turns and the main thread's Core Animation commits)
  hitches   with xctrace (on by default when `xcrun xctrace` exists; --no-xctrace): the Animation Hitches template
            attached to the app (motion-hitches.py's recorder): hitches, commit durations (hitches-updates) and
            main-thread time per frame from the Time Profiler
  counters  `debug.surfaces`: Ghostty frames drawn by the shown terminals in the window

Then one resize (split the focused terminal, close the new one: the resize pre-commit of every off-main form) and the
teardown: every terminal closes while `yes` still writes. The app must still answer afterwards. Each Ghostty
renderer logs one `present form` line when it is freed (os_log category `present_form`, read here with `log stream`):
frames handed to the main queue (`main_hops`), frames shown off main, refused frames (they took the main queue),
main-thread presents, reveals (one main turn per resize, not per frame), and a histogram of the off-main wait
(metal-layer: `nextDrawable` on the renderer thread, under its draw mutex; layer-host: the renderer's own
transaction commit: the lock-contention signal).

Prints one PRESENT-FORM JSON line per form and writes OUT/present-form.json. Exit 0 always: a bench, not a gate.
Fleet minis have no lit display: pass --vdisplay 120 (a 120 Hz virtual main display). VM timing is not evidence.
`--self-test` checks the log parsing and summaries (any OS, no app).
"""
import argparse, importlib.util, json, os, plistlib, re, shutil, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
FORMS = ("main-contents", "metal-layer", "layer-host")
LOG_FORM = {"main-contents": "main_contents", "metal-layer": "metal_layer", "layer-host": "layer_host"}
LINE = re.compile(r"present form (\w+): (.*)")
BUCKETS = 20  # PresentHistogram.bucket_count


def parse_line(message):
    """One `present form` log message as {"form", counters..., "wait_buckets_us": [..]}, or None."""
    match = LINE.search(message or "")
    if not match:
        return None
    rest, out = match.group(2), {"form": match.group(1)}
    buckets = re.search(r"wait_buckets_us=\{([^}]*)\}", rest)
    if buckets:
        out["wait_buckets_us"] = [int(v) for v in buckets.group(1).replace(" ", "").split(",") if v]
        rest = rest[:buckets.start()] + rest[buckets.end():]
    for key, value in re.findall(r"(\w+)=(\d+)", rest):
        out[key] = int(value)
    return out


def bucket_quantile(buckets, q):
    """Upper bound (us) of the bucket that holds quantile q: bucket 0 is < 1 us, bucket i < 2^i us; the last bucket
    has no bound (None)."""
    total = sum(buckets)
    if not total:
        return None
    rank, seen = q * total, 0
    for index, count in enumerate(buckets):
        seen += count
        if seen >= rank:
            return None if index == len(buckets) - 1 else 2 ** index
    return None


def summarize_renderers(lines, form):
    """Sums the renderers' lines of one launch; per-frame ratios use `frames` (Ghostty frames drawn)."""
    expected = LOG_FORM[form]
    total = {"renderers": len(lines), "forms_logged": sorted({l["form"] for l in lines})}
    total["form_mismatch"] = bool(lines) and total["forms_logged"] != [expected]
    for key in ("main_hops", "offmain", "refused", "main_presents", "reveals", "wait_n", "wait_sum_ns"):
        total[key] = sum(l.get(key, 0) for l in lines)
    total["wait_max_ns"] = max((l.get("wait_max_ns", 0) for l in lines), default=0)
    buckets = [0] * BUCKETS
    for l in lines:
        for i, v in enumerate(l.get("wait_buckets_us") or []):
            if i < BUCKETS:
                buckets[i] += v
    total["wait_buckets_us"] = buckets
    total["wait_us"] = {"p50_le": bucket_quantile(buckets, 0.5), "p95_le": bucket_quantile(buckets, 0.95),
                        "p99_le": bucket_quantile(buckets, 0.99), "max": round(total["wait_max_ns"] / 1000, 1)}
    shown = total["main_hops"] + total["offmain"]
    total["main_hops_per_frame"] = round(total["main_hops"] / shown, 4) if shown else None
    return total


def self_test():
    line = ("present form metal_layer: offmain=120 refused=3 main_hops=3 main_presents=2 reveals=2 wait_n=123 "
            "wait_sum_ns=456000 wait_max_ns=9000 wait_buckets_us={ 10, 100, 13, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }")
    parsed = parse_line(line)
    assert parsed["form"] == "metal_layer" and parsed["offmain"] == 120 and parsed["main_hops"] == 3, parsed
    assert parsed["wait_buckets_us"][:3] == [10, 100, 13] and len(parsed["wait_buckets_us"]) == BUCKETS, parsed
    assert parse_line("present form main_contents: main_hops=77") == {"form": "main_contents", "main_hops": 77}
    assert parse_line("unrelated") is None
    assert bucket_quantile([10, 100, 13] + [0] * 17, 0.5) == 2
    assert bucket_quantile([1] + [0] * 18 + [1], 0.99) is None  # in the open last bucket
    assert bucket_quantile([0] * 20, 0.5) is None
    summary = summarize_renderers([parsed, dict(parsed)], "metal-layer")
    assert summary["offmain"] == 240 and summary["main_hops"] == 6 and not summary["form_mismatch"], summary
    assert summary["main_hops_per_frame"] == round(6 / 246, 4)
    assert summarize_renderers([parse_line("present form main_contents: main_hops=5")], "layer-host")["form_mismatch"]
    print("self-test ok")


parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/ghostty-present-form")
parser.add_argument("--forms", default=",".join(FORMS))
parser.add_argument("--terminals", type=int, default=10)
parser.add_argument("--seconds", type=float, default=10.0, help="each measured window")
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--settle", type=float, default=3.0)
parser.add_argument("--vdisplay", type=float, default=0, help="a virtual main display at this rate (Hz)")
parser.add_argument("--no-xctrace", action="store_true")
parser.add_argument("--self-test", action="store_true")
opts = parser.parse_args()
if opts.self_test:
    self_test()
    sys.exit(0)

APP = (opts.app or "").rstrip("/")
if not APP or not os.path.isdir(APP):
    sys.exit("pass --app (or run under nx-remote --app-from-fleet)")
os.makedirs(opts.out, exist_ok=True)
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    info = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", info["CFBundleExecutable"])
TAG = os.environ.get("NX_APP_TAG") or os.path.basename(APP).removesuffix(".app").split(" ")[-1]
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
sys.path.insert(0, HERE)
from tag_teardown import TagTeardown  # noqa: E402


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


XCTRACE = not opts.no_xctrace and shutil.which("xcrun") is not None
hitches_lib = load("motion_hitches", "motion-hitches.py") if XCTRACE or opts.vdisplay else None


def rpc(method, params=None, timeout=60):
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


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bench script: bounded poll of the app's socket state
        value = predicate()
        if value:
            return value
        time.sleep(step)  # bench script: the poll interval
    return None


def shown_terminals():
    """{pane/tab id: frames drawn} of the shown, drawing terminals."""
    result = rpc("debug.surfaces") or {}
    out = {}
    for win in result.get("windows") or []:
        for pane in win.get("panes") or []:
            surface = pane.get("surface") or {}
            if not surface.get("fit_grid") or surface.get("hidden") or not surface.get("drawing", True):
                continue
            ident = "%s/%s" % (pane.get("pane"), pane.get("shown_tab") or pane.get("selected_tab"))
            out[ident] = int((surface.get("render_counters") or {}).get("frames", 0))
    return out


def write(text):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    subprocess.run([CLI, "--app-socket", SOCKET, "--json", "terminal", "current", "write", "--text", text],
                   capture_output=True, text=True, timeout=60, env=env, stdin=subprocess.DEVNULL)


def open_yes_terminals(count):
    """One new workspace with `count` terminals, split right and down in turn, each running `yes`."""
    rpc("action.run", {"action": "newTab", "focus": True})
    wait(lambda: shown_terminals(), 30)
    write("yes\r")
    for index in range(1, count):
        before = len(shown_terminals())
        rpc("action.run", {"action": "splitRight" if index % 2 else "splitDown", "focus": True})
        wait(lambda: len(shown_terminals()) > before, 30)
        write("yes\r")
    return len(shown_terminals())


def frames_delta(before, after):
    paired = [k for k in after if k in before]
    return {"terminals": len(paired), "ghostty_frames": sum(after[k] - before[k] for k in paired)}


def measure_window(app_pid, folder):
    """One --seconds window: debug.frames, Ghostty frames drawn, and (xctrace) hitches and main time."""
    os.makedirs(folder, exist_ok=True)
    recorder = None
    if XCTRACE:
        try:
            recorder = hitches_lib.start_recorder(folder, app_pid, tempfile.mkdtemp(prefix="present-form-xctrace-"))
            time.sleep(hitches_lib.RECORDER_ATTACH_S)  # bench script: xctrace's attach settles before the window
        except RuntimeError as error:
            recorder = None
            print(f"present-form: xctrace did not start ({str(error)[:200]})", flush=True)
    before = shown_terminals()
    rpc("debug.frames", {"action": "start"})
    time.sleep(opts.seconds)  # bench script: the measured window (yes keeps every terminal drawing)
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    after = shown_terminals()
    result = {"frames": {k: frames.get(k) for k in ("frames", "refresh_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms",
                                                    "missed", "main_p50_ms", "main_p95_ms", "main_max_ms",
                                                    "main_total_ms", "main_over_8_3_ms")},
              "counters": frames_delta(before, after)}
    if recorder is not None:
        saved = recorder.stop()
        result["xctrace"] = trace_summary(folder, app_pid, frames.get("refresh_ms") or 1000 / 120) if saved \
            else {"unavailable": "the recording was not saved"}
    return result


def trace_summary(folder, pid, refresh_ms):
    out = {"schemas": hitches_lib.export_tables(folder)}
    hitches = os.path.join(folder, "xctrace-hitches.xml")
    if os.path.exists(hitches):
        rows, _, _ = hitches_lib.interval_rows(hitches)
        mine = [d / 1e6 for _, d, p in rows if p in (pid, None)]
        out["hitches"] = {"count": len(mine), "duration_ms": hitches_lib.pcts(mine)}
    updates = os.path.join(folder, "xctrace-hitches-updates.xml")
    if os.path.exists(updates):
        rows, _, _ = hitches_lib.interval_rows(updates)
        commits = [d / 1e6 for _, d, p in rows if p in (pid, None)]
        out["commits"] = {"duration_ms": hitches_lib.pcts(commits), "over_refresh": sum(1 for c in commits if c > refresh_ms)}
    profile = os.path.join(folder, "xctrace-time-profile.xml")
    if os.path.exists(profile):
        samples = hitches_lib.main_samples(profile, pid)
        busy_ms = sum(w for _, w, busy in samples if busy) / 1e6
        out["main_busy_ms"] = round(busy_ms, 2)
    return out


class LogStream:
    """`log stream` of the app's `present_form` lines (info level), ndjson."""

    def __init__(self, pid, path):
        self.path = path
        self.file = open(path, "w")
        self.proc = subprocess.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--level", "info", "--predicate",
                                      f'processID == {pid} AND category == "present_form"'],
                                     stdout=self.file, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)

    def lines(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.file.close()
        out = []
        for raw in open(self.path, errors="replace"):
            try:
                message = json.loads(raw).get("eventMessage")
            except ValueError:
                continue
            parsed = parse_line(message)
            if parsed:
                out.append(parsed)
        return out


def run_form(form):
    folder = os.path.join(opts.out, form)
    os.makedirs(folder, exist_ok=True)
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    scratch = tempfile.mkdtemp(prefix=f"present-form-{TAG}-")
    config = os.path.join(scratch, "cmux.json")
    with open(config, "w") as f:
        f.write("{}\n")
    ghostty = os.path.join(scratch, "ghostty")
    with open(ghostty, "w") as f:
        f.write(f"macos-present-form = {form}\n")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "80,80,1600,1000"}
    teardown = TagTeardown(APP)
    teardown.install()
    log = open(os.path.join(folder, "app.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    result = {"form": form, "pid": app.pid}
    stream = None
    try:
        if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
            result["error"] = f"app did not come up (socket {SOCKET})"
            return result
        stream = LogStream(app.pid, os.path.join(folder, "present-form.ndjson"))
        result["terminals"] = open_yes_terminals(opts.terminals)
        time.sleep(opts.settle)  # bench script: every terminal is drawing yes output
        result["rounds"] = [measure_window(app.pid, os.path.join(folder, f"round-{i}")) for i in range(opts.rounds)]
        # One resize: the off-main forms present the new size's frame on main, hide and reveal the overlay.
        rpc("action.run", {"action": "splitRight", "focus": True})
        time.sleep(1.0)  # bench script: the split lands
        rpc("action.run", {"action": "closeTab", "focus": True})
        time.sleep(1.0)  # bench script: the close lands
        # Teardown while yes writes: every renderer stops and logs its line.
        start = time.monotonic()
        for _ in range(result["terminals"]):
            rpc("action.run", {"action": "closeTab", "focus": True})
        wait(lambda: not shown_terminals(), 30)
        result["teardown_s"] = round(time.monotonic() - start, 2)
        time.sleep(2.0)  # bench script: the renderers are freed and their log lines flushed
        alive = app.poll() is None and not (rpc("debug.windows") or {}).get("error")
        result["alive_after_teardown"] = alive
    finally:
        if stream is not None:
            lines = stream.lines()
            result["renderers"] = summarize_renderers(lines, form)
            if not lines:
                result["renderers"]["note"] = "no present form line: the app's Ghostty does not have the spike"
        if app.poll() is None:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(20)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
        teardown.end()
    return result


report = {"app": APP, "terminals": opts.terminals, "seconds": opts.seconds, "rounds": opts.rounds, "forms": []}
display = None
try:
    if opts.vdisplay:
        display = hitches_lib.stress_lib.start_vdisplay(opts.vdisplay, opts.out, 3600)
        report["vdisplay_hz"] = opts.vdisplay
    for form in [f for f in opts.forms.split(",") if f]:
        if form not in FORMS:
            sys.exit(f"unknown form {form}: {', '.join(FORMS)}")
        result = run_form(form)
        report["forms"].append(result)
        print(f"PRESENT-FORM {json.dumps(result)}", flush=True)
finally:
    if display is not None:
        display.terminate()  # the helper this script started
    with open(os.path.join(opts.out, "present-form.json"), "w") as f:
        json.dump(report, f, indent=1)
