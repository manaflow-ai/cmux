#!/usr/bin/env python3
"""Chromium in process vs Chromium in its own host app (prototype; plans/cmux-next/cef-helper-app-DESIGN.md).

Launches one tagged Debug cmux-next app with `browserHost.helperPrototype` and `browserResize.layerHosting` on, and
measures the same probe page twice:

  inproc   a normal Chromium tab (`openBrowser.chromium`): the browser process is the cmux app, its pump runs on
           cmux's main thread, the page's pixels are layer hosted (fork API >= 26) and its input goes to the page
           window (debug.mouse/debug.key `target: page`)
  helper   `debug.chromium_host open`: the browser process is `<App> Chromium Host.app`, the page's pixels are the
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
  kill     helper only, last: SIGKILL to the host. Pass when the cmux app's pid is unchanged and answers, a new host
           starts by itself (restart policy) and loads the saved page, and the in-process tab still answers.
  pump     the baseline the move removes: the share of cmux's main thread spent inside Chromium's pump passes
           (CefDoMessageLoopWork and every CEF callback it runs, `debug.cef` pump.work_ms over wall time), in process
           only: `pump_share` idle (page shown, nothing happens) and while the page scrolls (one wheel event per frame),
           light and, with --stress, in the STRESS session (perf-stress-session.py, its Chromium pages selected).
           Key callbacks Chromium makes from cmux's own event dispatch are not in it (they run outside a pass).

Debug build (reload.sh), not Release: the numbers compare the two paths, they are not shipping latencies.
Not a gate: exit 1 only when a mode could not run (no host app, refused fork API, launch failure).

On a fleet GUI host:
  python3 scripts/cmux-next/chromium-host-bench.py --app "<cmux DEV tag.app>" --out DIR [--count 60]
"""
import argparse, json, os, pathlib, sys, time

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
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

PAGE = """<!doctype html><meta charset=utf-8><title>host probe</title>
<style>html,body{margin:0;height:100%;background:#204080;color:#fff;font:16px system-ui}
#t{position:fixed;left:10%;top:20%;width:60%;font-size:20px}#b{position:fixed;left:10%;top:40%;width:30%;height:80px}
#box{position:fixed;left:0;top:70%;width:60px;height:60px;background:#f0c000}
.go{animation:slide 0.5s linear infinite alternate}@keyframes slide{to{transform:translateX(600px)}}</style>
<input id=t><button id=b>click</button><div id=box></div>
<script>
const S = {key: [], click: [], raf: []};
function sample(list, e) {
  // The frame that shows the change: the next animation frame after the event.
  requestAnimationFrame(() => { list.push(performance.now() - e.timeStamp); report(); });
}
addEventListener('keydown', e => { if (e.key === 'p') { window.__pace(3000); return; } document.getElementById('t').style.outline = '2px solid #' + (S.key.length % 9) + 'f0'; sample(S.key, e); }, true);
addEventListener('mousedown', e => { document.getElementById('b').textContent = 'click ' + S.click.length; sample(S.click, e); }, true);
function pct(list, q) { if (!list.length) return null; const s = [...list].sort((a, b) => a - b); return +s[Math.round(q * (s.length - 1))].toFixed(2); }
function summary(list) { return {n: list.length, p50: pct(list, 0.5), p95: pct(list, 0.95), max: pct(list, 1)}; }
function report() { document.title = 'probe ' + JSON.stringify({key: summary(S.key), click: summary(S.click), raf: summary(S.raf), raf_raw: S.raf.map(v => +v.toFixed(2))}); }
window.__pace = function(ms) {
  S.raf = []; const box = document.getElementById('box'); box.classList.add('go');
  let last = null; const end = performance.now() + ms;
  function tick(t) { if (last !== null) S.raf.push(t - last); last = t; if (t < end) requestAnimationFrame(tick); else { box.classList.remove('go'); report(); } }
  requestAnimationFrame(tick);
};
window.__reset = function() { S.key = []; S.click = []; S.raf = []; report(); };
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
    app = BenchApp(opts.app, out=opts.out, env={"CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables})
    ok = True
    try:
        app.launch()
        rpc = app.rpc
        RESULT["refresh_hz"] = main_display_hz()
        cef = rpc("debug.cef") or {}
        RESULT["cef"] = {"fork_api": (cef.get("windows") or {}).get("fork_api"), "unavailable": cef.get("unavailable"),
                         "fallback": cef.get("fallback")}
        modes = opts.modes.split(",")
        inproc_tab = None
        if "inproc" in modes:
            inproc_tab = run_inproc(rpc, url)
            ok = ok and inproc_tab is not None
        if "helper" in modes:
            ok = run_helper(rpc, url, inproc_tab) and ok
        if opts.stress:
            run_stress_pump(rpc)
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
    for i in range(opts.count):
        rpc("debug.key", {**key_target, "key": "a", "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)})
        time.sleep(1 / 30)  # test harness: one key per two frames, so samples do not share a frame
    stats = wait(lambda: (probe_stats(title_of()) or {}).get("key", {}).get("n", 0) >= opts.count and probe_stats(title_of()), 10)
    row["key_to_raf_ms"] = (stats or {}).get("key")
    for i in range(opts.count):
        rpc("debug.mouse", {**mouse_target, **click_point("b")})
        time.sleep(1 / 30)  # test harness: as above
    stats = wait(lambda: (probe_stats(title_of()) or {}).get("click", {}).get("n", 0) >= opts.count and probe_stats(title_of()), 10)
    row["click_to_raf_ms"] = (stats or {}).get("click")
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


def pump_share(rpc, page):
    """Main-thread share inside Chromium pump passes, idle and while the shown page scrolls."""
    shares = {}
    for phase in ("idle", "scroll"):
        if page:
            page("window.scrollTo(0, 0); document.body.style.height = '40000px'")
        start_ms, start = pump_work_ms(rpc), time.monotonic()
        deadline = start + opts.pump_seconds
        while time.monotonic() < deadline:
            if phase == "scroll":
                rpc("debug.mouse", {"target": "page", "action": "scroll", "dy": -12})
            time.sleep(1 / 60)  # test harness: one wheel event per 60 Hz frame (idle: just the wait)
        wall_ms = (time.monotonic() - start) * 1000
        shares[phase] = {"share": round((pump_work_ms(rpc) - start_ms) / wall_ms, 4), "wall_ms": round(wall_ms)}
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
    reply = rpc("debug.chromium_host", {"op": "open", "url": url}) or {}
    if reply.get("error"):
        RESULT["modes"]["helper"] = {"error": reply["error"]}
        return False
    state = wait(lambda: (lambda r: r if r.get("shown_context_id") and (r.get("title") or "").startswith("probe ") else None)(
        rpc("debug.chromium_host") or {}), 90, 0.25)
    if not state:
        RESULT["modes"]["helper"] = {"error": "the host page never showed", "state": rpc("debug.chromium_host")}
        return False
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
    hop = rpc("debug.chromium_host.measure", {"op": "input"}) or {}
    row["hop_us"] = hop
    row["ping_us"] = rpc("debug.chromium_host.measure", {"op": "ping", "count": 500}, timeout=60)
    RESULT["modes"]["helper"] = row
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
    return True


if __name__ == "__main__":
    sys.exit(main())
