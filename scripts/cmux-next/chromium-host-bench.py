#!/usr/bin/env python3
"""Chromium in process vs Chromium in its own host app (prototype; plans/cmux-next/cef-helper-app-DESIGN.md).

Launches one tagged Debug cmux-next app with `browserHost.helperPrototype` and `browserResize.layerHosting` on, and
measures the same probe page twice:

  inproc   a normal Chromium tab (`openBrowser.chromium`): the browser process is the cmux app, its pump runs on
           cmux's main thread, the page's pixels are layer hosted (fork API >= 26) and its input goes to the page
           window (debug.mouse/debug.key `target: page`)
  helper   `debug.chromium_host open`: the browser process is `<App>.app/Contents/MacOS/<App> Chromium Host`, the page's pixels are the
           host's CAContext in a CALayerHost over the same pane, and cmux forwards its input over the wire

Per mode:
  key      N key presses (debug.key, timestamped at send) into a focused text field. The page records, per key,
           performance.now() - event.timeStamp at its next requestAnimationFrame (`key_to_raf_ms`: the frame the
           change is drawn in, as Chromium schedules it). In helper mode Chromium stamps the key when the host
           dispatches it, so the hop cmux -> host UI thread is measured separately (`hop_us`, the host's
           event-time-to-dispatch percentiles) and `key_to_raf_ms + hop` is the comparable total.
  click    the same for N clicks (debug.mouse).
  pacing   the page's requestAnimationFrame intervals during a 3 s CSS animation (`raf_ms`: p50/p95/max,
           `long_frames`: intervals over 1.5 refresh periods), with the display refresh rate.
  ping     helper only: N round trips cmux -> host UI thread -> cmux over the wire (`ping_us`).
  kill     helper only: SIGKILL to the host. Pass when the cmux app's pid is unchanged and answers, a new host
           starts by itself (restart policy) and loads the saved page, and the in-process tab still answers.
  pixels   helper only: the share of screen samples in the probe's background color (a `screencapture` of the main
           display) before the host page opens (only the in-process page shows it) and after it shows, and again
           after the kill's restart. Pass when the host page adds at least 2 % of the screen: its pixels really
           composite through the CALayerHost (the host's page window is never ordered in, and its alpha 0 must not
           stop the hosted context from drawing).
  lifetime helper only, after every other row (it kills cmux): `debug.chromium_host close` ends and reaps the host
           within the quit limit and does not restart it; a host stopped with SIGSTOP (its UI thread never reads
           `quit`) and then closed is SIGKILLed at the quit limit (15 s); SIGKILL to cmux itself ends the host
           within the quit limit (it reads EOF on the wire).
  pump     the baseline the move removes: the share of cmux's main thread spent inside Chromium's pump passes
           (CefDoMessageLoopWork and every CEF callback it runs, `debug.cef` pump.work_ms over wall time) and the
           app's wakes (`wakes`, debug.wakeups: kernel wakeups and CPU of the app process, the wakeup ledger, and
           its CEFMessagePump part), `pump_share` idle (page shown, nothing happens) and while the page scrolls (one
           wheel event per frame). inproc: light and, with --stress, in the STRESS session (perf-stress-session.py,
           its Chromium pages selected). helper: light, the host page idles and scrolls while the in-process tab
           stays open, idle, in the other pane (cmux's pump still runs for it and the spare page).
           Key callbacks Chromium makes from cmux's own event dispatch are not in it (they run outside a pass).
  identity helper: the host is a second executable of cmux.app (cmux's bundle id): its LaunchServices type
           (UIElement: no Dock icon, menu bar or Cmd-Tab entry), the frontmost app after the input rows and after
           `open -b <bundle id>` and during 10 clicks with a key each (never the host; the host's own activation and
           key-window counters stay 0), the keys of cmux's defaults domain that changed while the host ran less
           those cmux changed alone before it (pass: none), and a Quit AppleEvent to the bundle id (cmux quits, not
           the host; last row).
  failure  helper: when the host page never shows, the host's Chromium log tail and its crash reports.

Debug build (reload.sh), not Release: the numbers compare the two paths, they are not shipping latencies.
Not a gate: exit 1 only when a mode could not run (no host app, refused fork API, launch failure).

On a fleet GUI host:
  python3 scripts/cmux-next/chromium-host-bench.py --app "<cmux DEV tag.app>" --out DIR [--count 60]
"""
import argparse, json, os, pathlib, signal, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--count", type=int, default=60)
parser.add_argument("--modes", default="inproc,helper")
parser.add_argument("--json", help="also write the result here (a fleet measure entry's report.json)")
parser.add_argument("--stress", action="store_true", help="also measure the pump share in the STRESS session")
parser.add_argument("--pump-seconds", type=float, default=10.0)
parser.add_argument("--host-switches", default="", help="more Chromium switches for the host, comma-separated (diagnosis)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

PAGE = """<!doctype html><meta charset=utf-8><title>host probe</title>
<style>html,body{margin:0;height:100%;background:#204080;color:#fff;font:16px system-ui}
#t{position:fixed;left:10%;top:20%;width:60%;font-size:20px}#b{position:fixed;left:10%;top:40%;width:30%;height:80px}
#box{position:fixed;left:0;top:70%;width:60px;height:60px;background:#f0c000}
.go{animation:slide 0.5s linear infinite alternate}@keyframes slide{to{transform:translateX(600px)}}</style>
<input id=t><button id=b>click</button><div id=box></div>
<script>
const S = {key: [], click: [], raf: [], key_paint: [], click_paint: []};
// The wall time (ms since 1970, the system clock the bench reads with time.time()) of the animation frame that
// shows each change: the bench subtracts its own send time, so both ends share one clock in both modes. A
// forwarded event's timeStamp cannot be used: the host's CEF windowed Send*Event gives the event no time, and
// Chromium clamps its timeStamp to the page's time origin (the in-page delta then read the page's age, 13 s).
const wall = () => performance.timeOrigin + performance.now();
function sample(list, paint, e) {
  const at = performance.now();
  // The frame that shows the change: the next animation frame after the event.
  requestAnimationFrame(() => { list.push(performance.now() - at); paint.push(+wall().toFixed(3)); report(); });
}
addEventListener('keydown', e => { if (e.key === 'p') { window.__pace(3000); return; } document.getElementById('t').style.outline = '2px solid #' + (S.key.length % 9) + 'f0'; sample(S.key, S.key_paint, e); }, true);
addEventListener('mousedown', e => { document.getElementById('b').textContent = 'click ' + S.click.length; sample(S.click, S.click_paint, e); }, true);
function pct(list, q) { if (!list.length) return null; const s = [...list].sort((a, b) => a - b); return +s[Math.round(q * (s.length - 1))].toFixed(2); }
function summary(list) { return {n: list.length, p50: pct(list, 0.5), p95: pct(list, 0.95), max: pct(list, 1)}; }
function report() { document.title = 'probe ' + JSON.stringify({key: summary(S.key), click: summary(S.click), raf: summary(S.raf), raf_raw: S.raf.map(v => +v.toFixed(2)), key_paint: S.key_paint, click_paint: S.click_paint}); }
window.__pace = function(ms) {
  S.raf = []; const box = document.getElementById('box'); box.classList.add('go');
  let last = null; const end = performance.now() + ms;
  function tick(t) { if (last !== null) S.raf.push(t - last); last = t; if (t < end) requestAnimationFrame(tick); else { box.classList.remove('go'); report(); } }
  requestAnimationFrame(tick);
};
window.__reset = function() { S.key = []; S.click = []; S.raf = []; S.key_paint = []; S.click_paint = []; report(); };
report();
</script>"""

TUNABLES = {"version": 1, "values": {"browserHost.helperPrototype": True, "browserResize.layerHosting": True}}
RESULT = {"build": "Debug", "modes": {}, "notes": []}


def main_display_hz():
    """The main display's refresh rate (CoreGraphics), or None."""
    import ctypes
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cg.CGMainDisplayID.restype = ctypes.c_uint32
    cg.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p
    cg.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
    cg.CGDisplayModeGetRefreshRate.restype = ctypes.c_double
    cg.CGDisplayModeGetRefreshRate.argtypes = [ctypes.c_void_p]
    mode = cg.CGDisplayCopyDisplayMode(cg.CGMainDisplayID())
    return round(cg.CGDisplayModeGetRefreshRate(mode), 2) if mode else None


TAB = {}
# ChromiumHostFrame.quitLimit: how long a host may take to end after `quit` or EOF before it is SIGKILLed / ends itself.
QUIT_LIMIT_S = 15.0
# The probe's background (#204080), with room for the display's color conversion.
PROBE_RGB, PROBE_TOLERANCE = (0x20, 0x40, 0x80), 24


def probe_color_share():
    """The share of main-display samples in the probe's background color, or None when the screen cannot be read
    (no Screen Recording permission, no display). A BMP capture, read without an imaging library."""
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "screen.bmp")
        done = subprocess.run(["/usr/sbin/screencapture", "-x", "-m", "-t", "bmp", path], capture_output=True, timeout=30)
        if done.returncode != 0 or not os.path.exists(path):
            return None
        data = open(path, "rb").read()
    if data[:2] != b"BM" or len(data) < 54:
        return None
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, compression = struct.unpack_from("<HI", data, 28)
    if bpp not in (24, 32) or compression not in (0, 3) or width <= 0 or height == 0:
        return None
    step = bpp // 8
    stride = (width * step + 3) & ~3
    rows = abs(height)
    hits = total = 0
    for y in range(0, rows, 4):
        base = offset + y * stride
        for x in range(0, width, 4):
            i = base + x * step
            if i + 3 > len(data):
                break
            b, g, r = data[i], data[i + 1], data[i + 2]  # BI_RGB and the BGRA bitfields screencapture writes
            total += 1
            if all(abs(c - w) <= PROBE_TOLERANCE for c, w in zip((r, g, b), PROBE_RGB)):
                hits += 1
    return round(hits / total, 4) if total else None


BENCH_START = time.time()
APP_LOG = {}
DEFAULTS = {}


def app_log_lines(needles, limit=40):
    """The app log's distinct lines that hold one of `needles` (the first `limit`, process ids and times
    dropped for the dedupe, each up to 2,000 characters: a dlopen error names its reason at the end), or None."""
    import re
    try:
        lines = open(APP_LOG["path"], errors="replace").read().splitlines()
    except (KeyError, OSError):
        return None
    seen, out = set(), []
    for line in lines:
        if not any(n in line for n in needles):
            continue
        key = re.sub(r"^\[[0-9:/.]+\]|\[\d+:\d+\]|\d{4}-\d\d-\d\d [\d:.]+", "", line)
        if key in seen:
            continue
        seen.add(key)
        out.append(line[:2000])
    return out[:limit]


def log_tail(path, lines=40):
    """The last lines of the host's Chromium log (warnings and fatal messages), or None."""
    try:
        return open(path, errors="replace").read().splitlines()[-lines:] if path else None
    except OSError:
        return None


def host_crash_reports():
    """Crash reports of a Chromium host written since this bench started: file, exception, abort message and the
    crashed thread's top frames (image + offset; the framework is stripped, symbolicate with its dSYM)."""
    found = []
    for folder in ("/Library/Logs/DiagnosticReports", os.path.expanduser("~/Library/Logs/DiagnosticReports")):
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in sorted(names):
            path = os.path.join(folder, name)
            if "Chromium Host" not in name or os.path.getmtime(path) < BENCH_START:
                continue
            entry = {"file": path}
            try:
                body = json.loads(open(path).read().split("\n", 1)[1])
                images = body.get("usedImages") or []
                thread = (body.get("threads") or [{}])[body.get("faultingThread", 0)]
                entry.update(exception=body.get("exception"), asi=body.get("asi"), thread=thread.get("name"),
                             frames=[f"{(images[f['imageIndex']] or {}).get('name')}+{f.get('imageOffset')} {f.get('symbol') or ''}".strip()
                                     for f in (thread.get("frames") or [])[:24]])
            except (OSError, ValueError, IndexError, KeyError) as error:
                entry["unreadable"] = str(error)
            found.append(entry)
    return found


def app_bundle_id():
    import plistlib
    with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
        return plistlib.load(f).get("CFBundleIdentifier")


def ls_types():
    """LaunchServices' view of every app: {pid: application type} (`lsappinfo list`: Foreground has a Dock icon and
    a menu bar, UIElement and BackgroundOnly do not)."""
    import re
    done = subprocess.run(["/usr/bin/lsappinfo", "list"], capture_output=True, text=True, timeout=20)
    types = {}
    for block in re.split(r"\n(?=\s*\d+\) )", done.stdout):
        pid = re.search(r"\bpid = (\d+)", block)
        kind = re.search(r'\btype="([^"]+)"', block)
        if pid:
            types[int(pid.group(1))] = kind.group(1) if kind else None
    return types


def front_pid():
    """The pid of LaunchServices' frontmost app, or None."""
    import re
    asn = subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True, timeout=20).stdout.strip()
    if not asn:
        return None
    info = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "pid", asn], capture_output=True, text=True, timeout=20).stdout
    found = re.search(r"(\d+)", info.split("=", 1)[-1])
    return int(found.group(1)) if found else None


def defaults_snapshot(domain):
    """cmux's defaults domain as {key: value repr} (`defaults export`), or None."""
    import plistlib
    done = subprocess.run(["/usr/bin/defaults", "export", domain, "-"], capture_output=True, timeout=20)
    if done.returncode != 0:
        return None
    try:
        return {k: repr(v)[:200] for k, v in plistlib.loads(done.stdout).items()}
    except Exception:  # noqa: BLE001 - an unreadable export is reported as None
        return None


def defaults_diff(before, after):
    if before is None or after is None:
        return None
    return {"added": sorted(set(after) - set(before)), "removed": sorted(set(before) - set(after)),
            "changed": sorted(k for k in set(before) & set(after) if before[k] != after[k])}


def pid_gone(pid):
    """True once `pid` no longer exists; a zombie (ended, not reaped) still counts as there."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def page_eval(rpc, script):
    reply = rpc("browser.page.eval", {"script": script, **({"tab": TAB["tab"]} if TAB.get("tab") else {})}, timeout=20)
    if isinstance(reply, dict) and reply.get("tab"):
        TAB.setdefault("tab", reply["tab"])
    return reply.get("value") if isinstance(reply, dict) and "error" not in reply else None


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def paired(sent, painted):
    """Send-to-paint percentiles (ms) of events matched in order; None when the page reported none. Only as many as
    painted; a count below len(sent) means events were lost and the pairs may be shifted (the row says so)."""
    if not painted:
        return None
    n = min(len(sent), len(painted))
    out = percentiles([p - s for s, p in zip(sent[:n], painted[:n])])
    out["sent"] = len(sent)
    return out


def percentiles(values):
    if not values:
        return None
    s = sorted(values)
    at = lambda q: round(s[round(q * (len(s) - 1))], 3)
    return {"n": len(s), "p50": at(0.5), "p95": at(0.95), "p99": at(0.99), "max": round(s[-1], 3)}


def main():
    tunables = os.path.join(opts.out, "debug-tunables.json")
    json.dump(TUNABLES, open(tunables, "w"))
    probe = os.path.join(opts.out, "probe.html")
    open(probe, "w").write(PAGE)
    url = pathlib.Path(probe).as_uri()
    env = {"CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables}
    if opts.host_switches:
        env["CMUX_NEXT_CHROMIUM_HOST_SWITCHES"] = opts.host_switches
        RESULT["host_switches"] = opts.host_switches
    app = BenchApp(opts.app, out=opts.out, env=env)
    APP_LOG["path"] = app.log_path
    ok = True
    try:
        app.launch()
        rpc = app.rpc
        RESULT["refresh_hz"] = main_display_hz()
        cef = rpc("debug.cef") or {}
        RESULT["cef"] = {"fork_api": (cef.get("windows") or {}).get("fork_api"), "unavailable": cef.get("unavailable"),
                         "fallback": cef.get("fallback")}
        DEFAULTS["launch"] = defaults_snapshot(app_bundle_id())
        modes = opts.modes.split(",")
        inproc_tab = None
        if "inproc" in modes:
            inproc_tab = run_inproc(rpc, url)
            ok = ok and inproc_tab is not None
        if "helper" in modes:
            ok = run_helper(rpc, url, inproc_tab) and ok
        if opts.stress:
            run_stress_pump(rpc)
        if "helper" in modes and RESULT["modes"].get("helper", {}).get("kill"):
            ok = run_lifetime(app, url) and ok
    except LaunchError as error:
        RESULT["error"] = error.reason
        ok = False
    finally:
        for path in filter(None, [os.path.join(opts.out, "chromium-host-bench.json"), opts.json]):
            with open(path, "w") as out:
                json.dump(RESULT, out, indent=2)
        print("CHROMIUM-HOST-BENCH " + json.dumps(RESULT), flush=True)
        app.stop()
    return 0 if ok else 1


def probe_stats(title):
    if not title or not title.startswith("probe "):
        return None
    try:
        return json.loads(title[len("probe "):])
    except ValueError:
        return None


def drive(rpc, mode, title_of, key_target, mouse_target, click_point):
    """Keys, clicks and pacing for one mode; title_of() reads the page's summary title."""
    row = {}
    # Focus the text field with one click first.
    rpc("debug.mouse", {**mouse_target, **click_point("t")})
    time.sleep(0.3)  # test harness: focus lands
    key_sent = []
    for i in range(opts.count):
        key_sent.append(time.time() * 1000)
        reply = rpc("debug.key", {**key_target, "key": "a", "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)})
        if i == 0:
            row["first_key_reply"] = reply
        time.sleep(1 / 30)  # test harness: one key per two frames, so samples do not share a frame
    stats = wait(lambda: (probe_stats(title_of()) or {}).get("key", {}).get("n", 0) >= opts.count and probe_stats(title_of()), 10)
    stats = stats or probe_stats(title_of()) or {}
    # key_to_raf_ms: from the page's handler to the frame (in-page clock). key_to_paint_ms: from cmux's send to that
    # frame, one wall clock at both ends; matched in order (n says how many keys arrived).
    row["key_to_raf_ms"] = stats.get("key")
    row["key_to_paint_ms"] = paired(key_sent, stats.get("key_paint"))
    click_sent = []
    for i in range(opts.count):
        click_sent.append(time.time() * 1000)
        rpc("debug.mouse", {**mouse_target, **click_point("b")})
        time.sleep(1 / 30)  # test harness: as above
    stats = wait(lambda: (probe_stats(title_of()) or {}).get("click", {}).get("n", 0) >= opts.count and probe_stats(title_of()), 10)
    stats = stats or probe_stats(title_of()) or {}
    row["click_to_raf_ms"] = stats.get("click")
    # The first click focused the field: it is not in click_sent.
    row["click_to_paint_ms"] = paired(click_sent, (stats.get("click_paint") or [])[-len(click_sent):])
    # Pacing: the key `p` starts a 3 s animation in the page; the page records its frame intervals.
    rpc("debug.key", {**key_target, "key": "p"})
    time.sleep(3.6)  # test harness: the page animates for 3 s
    raw = (probe_stats(title_of()) or {}).get("raf_raw") or []
    row["raf_ms"] = percentiles(raw)
    if raw and RESULT.get("refresh_hz"):
        period = 1000 / RESULT["refresh_hz"]
        row["long_frames"] = sum(1 for v in raw if v > 1.5 * period)
    return row


def run_inproc(rpc, url):
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    page = lambda script: page_eval(rpc, script)
    if not wait(lambda: page("document.readyState === 'complete' && document.title.startsWith('probe ')"), 60, 0.5):
        RESULT["modes"]["inproc"] = {"error": f"the probe never loaded: {json.dumps(opened)[:200]}"}
        return None
    cef = rpc("debug.cef") or {}
    hosted = (cef.get("tracker") or {}).get("hosted_pages", 0)
    page("window.__reset()")

    def click_point(element):
        rect = page(f"(() => {{ const r = document.getElementById('{element}').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; }})()")
        return {"x": rect[0], "y": rect[1]} if rect else {}
    row = drive(rpc, "inproc", lambda: page("document.title"), {"target": "page"}, {"target": "page"}, click_point)
    row["hosted_pages"] = hosted
    row["pump_share"] = {"light": pump_share(rpc, page)}
    RESULT["modes"]["inproc"] = row
    return True


def pump_work_ms(rpc):
    return float(((rpc("debug.cef") or {}).get("pump") or {}).get("work_ms") or 0)


def wake_sample(rpc):
    """The app's kernel wakeups and CPU, and the wakeup ledger's counts (all owners, and CEFMessagePump: the
    in-process pump's timer and cross-thread wakes), from debug.wakeups."""
    report = rpc("debug.wakeups") or {}
    app = next((p for p in report.get("processes") or [] if p.get("kind") == "app"), {})
    ledger = report.get("ledger") or []
    return {"app_wakeups": app.get("wakeups") or 0, "app_cpu_ms": app.get("cpu_ms") or 0.0,
            "ledger": sum(e.get("count") or 0 for e in ledger),
            "cef_pump": sum(e.get("count") or 0 for e in ledger if e.get("owner") == "CEFMessagePump")}


def wake_rates(before, after, seconds):
    rate = lambda key: round((after[key] - before[key]) / seconds, 2)
    out = {"app_wakeups_per_s": rate("app_wakeups"), "app_cpu_share": round((after["app_cpu_ms"] - before["app_cpu_ms"]) / (seconds * 1000), 4),
           "ledger_per_s": rate("ledger"), "cef_pump_per_s": rate("cef_pump")}
    # The pump's part of the app's sanctioned main wakes (the ledger), and of all its kernel wakeups.
    out["cef_pump_share_of_ledger"] = round(out["cef_pump_per_s"] / out["ledger_per_s"], 4) if out["ledger_per_s"] > 0 else None
    out["cef_pump_share_of_app_wakeups"] = (round(out["cef_pump_per_s"] / out["app_wakeups_per_s"], 4)
                                            if out["app_wakeups_per_s"] > 0 else None)
    return out


def pump_share(rpc, page, scroll=None):
    """Main-thread share inside Chromium pump passes, and the app's wakes, idle and while the shown page scrolls.
    `scroll` sends one wheel event (default: to the focused in-process page)."""
    scroll = scroll or (lambda: rpc("debug.mouse", {"target": "page", "action": "scroll", "dy": -12}))
    shares = {}
    for phase in ("idle", "scroll"):
        if page:
            page("window.scrollTo(0, 0); document.body.style.height = '40000px'")
        start_ms, start, wakes = pump_work_ms(rpc), time.monotonic(), wake_sample(rpc)
        deadline = start + opts.pump_seconds
        while time.monotonic() < deadline:
            if phase == "scroll":
                scroll()
            time.sleep(1 / 60)  # test harness: one wheel event per 60 Hz frame (idle: just the wait)
        wall_ms = (time.monotonic() - start) * 1000
        shares[phase] = {"share": round((pump_work_ms(rpc) - start_ms) / wall_ms, 4), "wall_ms": round(wall_ms),
                         "wakes": wake_rates(wakes, wake_sample(rpc), wall_ms / 1000)}
    shares["pump"] = (rpc("debug.cef") or {}).get("pump")
    return shares


def run_stress_pump(rpc):
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    summary = module.Stress(rpc, selected="chromium").build()
    RESULT["stress_session"] = summary
    # Scroll goes to the focused pane's page: a Chromium page in STRESS (selected chromium).
    RESULT["modes"].setdefault("inproc", {}).setdefault("pump_share", {})["stress"] = pump_share(rpc, None)


def run_helper(rpc, url, inproc_tab):
    # A pane of its own (the in-process page keeps the left one).
    rpc("action.run", {"action": "splitRight", "focus": True, "origin": "script"}, timeout=60)
    time.sleep(1)  # test harness: the split settles
    pixels = {"before_open": probe_color_share()}
    bundle_id = app_bundle_id()
    DEFAULTS["before"] = defaults_snapshot(bundle_id)
    reply = rpc("debug.chromium_host", {"op": "open", "url": url, "focus": True}) or {}
    if reply.get("error"):
        RESULT["modes"]["helper"] = {"error": reply["error"]}
        return False
    state = wait(lambda: (lambda r: r if r.get("shown_context_id") and (r.get("title") or "").startswith("probe ") else None)(
        rpc("debug.chromium_host") or {}), 90, 0.25)
    if not state:
        failed = rpc("debug.chromium_host") or {}
        RESULT["modes"]["helper"] = {"error": "the host page never showed", "state": failed,
                                     "host_log": log_tail(failed.get("log_file")), "crash_reports": host_crash_reports(),
                                     # The host's children write to cmux's stderr (the app log): sandbox and load errors.
                                     "app_log_children": app_log_lines(("Helper", "sandbox", "Sandbox", "seatbelt", "Check failed",
                                                                        "ERROR", "FATAL", "LoadInHelper", "dlopen"))}
        return False
    time.sleep(0.5)  # test harness: the shown context's first frame reaches the screen
    pixels["shown"] = probe_color_share()
    title = lambda: (rpc("debug.chromium_host") or {}).get("title")
    # The pane is the focused one; the host page view covers its content: click points are the page's own layout
    # (the probe's elements are at fixed fractions of the viewport), turned into window points by the app.
    # The rightmost pane's content rect (window points, top left): the host page view fills it.
    layers = rpc("debug.pane_chrome") or {}
    borders = [pane.get("border") for window in layers.get("windows") or [] for pane in window.get("panes") or []
               if isinstance(pane.get("border"), list)]
    if not borders:
        RESULT["modes"]["helper"] = {"error": "no pane geometry (debug.pane_chrome)"}
        return False
    bx, by, bw, bh = max(borders, key=lambda b: b[0])
    # The probe's fixed layout: the field spans 10-70 % at 20 % height, the button 10-40 % at 40 % (+40 px).
    spots = {"t": (0.4, 0.2, 10), "b": (0.25, 0.4, 40)}

    def click_point(element):
        fx, fy, dy = spots[element]
        return {"x": bx + bw * fx, "y": by + bh * fy + dy}
    row = drive(rpc, "helper", title, {}, {}, click_point)
    # The host is a second executable of cmux.app with its bundle id: it must stay out of the Dock, the menu bar
    # and Cmd-Tab (UIElement), never be frontmost while cmux takes keys, and `open -b` must reach cmux, not it.
    host_pid, app_pid = state.get("pid"), (rpc("debug.chromium_host") or {}).get("app_pid")
    types = ls_types()
    identity = {"host_pid": host_pid, "app_pid": app_pid, "host_type": types.get(host_pid), "app_type": types.get(app_pid),
                "front_after_input": front_pid()}
    # 10 clicks on the page and a key after each: the frontmost app stays cmux's process the whole time, and the
    # host never becomes active nor owns the key window (its own counters, debug.chromium_host.measure input).
    fronts = []
    for _ in range(10):
        rpc("debug.mouse", click_point("b"))
        rpc("debug.key", {"key": "a"})
        fronts.append(front_pid())
    counters = rpc("debug.chromium_host.measure", {"op": "input"}) or {}
    identity["clicks"] = {"fronts": sorted(set(p for p in fronts if p is not None)), "host_frontmost": fronts.count(host_pid),
                          "activations": counters.get("activations"), "key_windows": counters.get("key_windows")}
    opened = subprocess.run(["/usr/bin/open", "-b", bundle_id], capture_output=True, text=True, timeout=30)
    time.sleep(1.5)  # test harness: LaunchServices activates the target app
    identity["open_b"] = {"exit": opened.returncode, "stderr": opened.stderr.strip()[:200], "front": front_pid(),
                          "host_still_runs": not pid_gone(host_pid), "host_type": ls_types().get(host_pid)}
    identity["pass"] = (identity["host_type"] in ("UIElement", "BackgroundOnly") and identity["front_after_input"] != host_pid
                        and identity["open_b"]["front"] != host_pid and identity["open_b"]["host_type"] in ("UIElement", "BackgroundOnly")
                        and identity["clicks"]["host_frontmost"] == 0 and identity["clicks"]["activations"] == 0
                        and identity["clicks"]["key_windows"] == 0)
    # The same baseline with the page in the host: cmux's pump still runs for in-process Chromium (the
    # in-process tab, idle in the other pane, and the spare page), the host's page idles and scrolls.
    host_point = click_point("t")
    row["pump_share"] = {"light": pump_share(rpc, None, scroll=lambda: rpc(
        "debug.mouse", {"action": "scroll", "dy": -12, "hover": False, **host_point}))}
    # Pointer moves in a burst: the host folds the moves its UI thread has not run into one (FrameQueue).
    for i in range(200):
        rpc("debug.mouse", {"action": "move", "x": host_point["x"] + (i % 40), "y": host_point["y"]})
    hop = rpc("debug.chromium_host.measure", {"op": "input"}) or {}
    row["hop_us"] = hop
    row["ping_us"] = rpc("debug.chromium_host.measure", {"op": "ping", "count": 500}, timeout=60)
    RESULT["modes"]["helper"] = row
    row["identity"] = identity
    row["host_pid"] = state.get("pid")
    row["fork_api"] = state.get("fork_api")

    # Kill: cmux keeps running, a new host loads the saved page.
    before = rpc("debug.chromium_host") or {}
    app_pid = before.get("app_pid")
    killed = (rpc("debug.chromium_host", {"op": "kill"}) or {}).get("killed_pid")
    after = wait(lambda: (lambda r: r if r.get("restarts", 0) >= 1 and r.get("shown_context_id") and r.get("pid") != killed else None)(
        rpc("debug.chromium_host") or {}), 90, 0.25)
    windows = rpc("debug.windows") or {}
    inproc_alive = None
    if inproc_tab:
        inproc_alive = page_eval(rpc, "1 + 1") == 2
    row["kill"] = {
        "killed_pid": killed, "app_pid_before": app_pid, "app_pid_after": (after or {}).get("app_pid"),
        "app_answers": bool(windows.get("windows")), "restarted": bool(after), "new_host_pid": (after or {}).get("pid"),
        "url_after": (after or {}).get("url"), "exits": (after or rpc("debug.chromium_host") or {}).get("exits"),
        "inproc_tab_answers": inproc_alive,
    }
    row["kill"]["pass"] = bool(after) and row["kill"]["app_answers"] and app_pid == (after or {}).get("app_pid")
    if after:
        time.sleep(0.5)  # test harness: as above, for the restarted host's context
        pixels["after_restart"] = probe_color_share()
    if None in (pixels["before_open"], pixels["shown"]):
        pixels["error"] = "the screen could not be read (screencapture)"
    else:
        added = lambda key: pixels.get(key) is not None and pixels[key] - pixels["before_open"] >= 0.02
        pixels["pass"] = added("shown") and (not after or added("after_restart"))
    row["pixels"] = pixels
    return True


def run_lifetime(app, url):
    """close, SIGSTOP + close and SIGKILL to cmux (the last row: cmux is gone after it)."""
    rpc = app.rpc
    row = {}
    RESULT["modes"]["helper"]["lifetime"] = row

    def shown_host(not_pid):
        return wait(lambda: (lambda r: r if r.get("shown_context_id") and r.get("pid") and r.get("pid") != not_pid else None)(
            rpc("debug.chromium_host") or {}), 90, 0.25)

    def timed_end(pid, limit):
        start = time.monotonic()
        gone = wait(lambda: pid_gone(pid), limit, 0.05)
        return bool(gone), round(time.monotonic() - start, 2)

    # 1. close: quit over the wire, the host ends by itself and is reaped; no restart.
    state = rpc("debug.chromium_host") or {}
    pid, restarts = state.get("pid"), state.get("restarts")
    rpc("debug.chromium_host", {"op": "close"})
    ended, seconds = timed_end(pid, QUIT_LIMIT_S + 10)
    time.sleep(1)  # test harness: a wrong restart would have started by now
    after = rpc("debug.chromium_host") or {}
    row["close"] = {"pid": pid, "ended": ended, "seconds": seconds, "phase": after.get("phase"),
                    "restarts_before": restarts, "restarts_after": after.get("restarts")}
    row["close"]["pass"] = ended and seconds < QUIT_LIMIT_S and after.get("phase") == "idle" and after.get("restarts") == restarts
    # Keys of cmux's defaults domain that changed while the host ran, less the keys cmux itself changed from its
    # launch to the host's open (the same cmux, no host): any other key is the host's (or cmux's for another
    # reason; the names say which).
    host_ran = defaults_diff(DEFAULTS.get("before"), defaults_snapshot(app_bundle_id()))
    cmux_alone = defaults_diff(DEFAULTS.get("launch"), DEFAULTS.get("before"))
    row_defaults = {"while_host_ran": host_ran, "cmux_alone": cmux_alone}
    if host_ran is not None and cmux_alone is not None:
        own = set(cmux_alone["added"]) | set(cmux_alone["changed"]) | set(cmux_alone["removed"])
        unexplained = sorted((set(host_ran["added"]) | set(host_ran["changed"]) | set(host_ran["removed"])) - own)
        row_defaults["unexplained"] = unexplained
        row_defaults["pass"] = not unexplained
    RESULT["modes"]["helper"]["defaults"] = row_defaults

    # 2. a host whose UI thread never reads quit (SIGSTOP; a child of the cmux this bench started) is SIGKILLed at the limit.
    rpc("debug.chromium_host", {"op": "open", "url": url})  # over the focused pane
    state = shown_host(pid)
    if not state:
        row["stop_close"] = {"error": "no host after the reopen", "state": rpc("debug.chromium_host")}
        return False
    pid = state["pid"]
    os.kill(pid, signal.SIGSTOP)
    rpc("debug.chromium_host", {"op": "close"})
    ended, seconds = timed_end(pid, QUIT_LIMIT_S + 15)
    row["stop_close"] = {"pid": pid, "ended": ended, "seconds": seconds,
                         "exits": (rpc("debug.chromium_host") or {}).get("exits")}
    row["stop_close"]["pass"] = ended and QUIT_LIMIT_S - 1 <= seconds <= QUIT_LIMIT_S + 5

    # 3. A Quit AppleEvent to cmux's bundle id (the Dock's Quit): cmux must get it, not the host (the same bundle
    # id); then the host reads EOF and ends itself within the limit. When cmux does not quit (a confirmation, or
    # Automation not allowed for this bench), SIGKILL to cmux checks the EOF end instead.
    rpc("debug.chromium_host", {"op": "open", "url": url})
    state = shown_host(pid)
    if not state:
        row["cmux_quit"] = {"error": "no host after the second reopen", "state": rpc("debug.chromium_host")}
        return False
    pid = state["pid"]
    quit_event = subprocess.run(["/usr/bin/osascript", "-e", f'tell application id "{app_bundle_id()}" to quit'],
                                capture_output=True, text=True, timeout=40)
    try:
        app.process.wait(20)
        cmux_quit = True
    except subprocess.TimeoutExpired:
        cmux_quit = False
    row["ae_quit"] = {"osascript_exit": quit_event.returncode, "stderr": quit_event.stderr.strip()[:200],
                      "cmux_quit": cmux_quit, "host_ended_first": pid_gone(pid) and not cmux_quit}
    row["ae_quit"]["pass"] = cmux_quit and not row["ae_quit"]["host_ended_first"]
    if not cmux_quit:
        app.process.kill()  # the cmux process this bench started
        app.process.wait(30)
    ended, seconds = timed_end(pid, QUIT_LIMIT_S + 15)
    row["cmux_killed" if not cmux_quit else "cmux_quit"] = {"pid": pid, "ended": ended, "seconds": seconds,
                                                             "pass": ended and seconds <= QUIT_LIMIT_S + 1}
    if not ended:
        os.kill(pid, signal.SIGKILL)  # leave no host behind on the measure host (a grandchild of this bench)
    return True


if __name__ == "__main__":
    sys.exit(main())
