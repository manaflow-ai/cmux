#!/usr/bin/env python3
"""Live check: a video that played in a hidden Chromium tab plays again when the tab shows, also after the
hidden-tab freeze (2026-11-25, the in-tree video-freeze report).

  hidden-video-thaw-live.py --app "/path/cmux DEV <tag>.app" --out DIR [--hides 25,40] [--record]

A hidden page freezes after `browser.freezeHiddenTabs` (30 s by default; BrowserHibernation), and Blink pauses each
media element that plays when its frame freezes. Since M140 Blink never plays it again, so a muted live video (a
canvas `captureStream()`, a camera preview, a dashboard's stream) stayed paused at the frame it froze on, forever.
`CEFDocumentScripts.frozenMediaResume` plays it again when the frame resumes.

It launches the tagged build (BenchApp: fresh state, no activation, the tag's daemons ended at the end), serves its
pages on 127.0.0.1 and puts them in one workspace, each in its own pane:

  stream    a muted video of a canvas's captureStream()        must play after each show
  frame     the same page in a same-origin iframe               must play after each show (the script runs in every frame)
  file      a muted autoplay looping file video (VP8)           must play after each show (Chromium pauses it while hidden)
  paused    a stream video the page itself paused               must stay paused (nothing plays what the page paused)

Then, per `--hides` (seconds), it shows another workspace for that long and comes back. While hidden it reads only the
app's own state (`debug.surfaces` hibernation.frozen: when each page froze) and the processes' CPU time, never the
pages (an agent's call would thaw a page and restart its hidden clock). After the show it reads each video twice, 2 s
apart: paused, currentTime, decoded frames, and the page's own freeze, resume and hidden-time counts. A hide shorter
than the freeze threshold is the counter-proof: nothing freezes and every video plays. In a longer one the paused page
(nothing plays there) must freeze, which proves the hide passed the threshold; whether the others froze is reported.
`--record` records each show (the app's own window recorder, `debug.motion record_start`) to DIR/show-<seconds>s.mov.
In a hide past the threshold it also reads each renderer's and the GPU process's CPU time from 4 s after the
threshold to the end of the hide (`cpu` in the phase: percent of one core, per process and in total).

Writes DIR/results.json. Exit 0: every check passed; 1: a check failed; 2: inconclusive (setup failed, or the paused
page did not freeze in a hide past the threshold). It never activates the app or posts system-wide input.
"""
import argparse, http.server, json, os, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--hides", default="25,40", help="hidden times in seconds, in order (default 25,40)")
parser.add_argument("--record", action="store_true")
parser.add_argument("--screen", default="0", help="CMUX_NEXT_TEST_WINDOW_SCREEN for the app's window")
parser.add_argument("--env", action="append", default=[], help="KEY=VALUE for the app (repeatable)")
parser.add_argument("--tag", help="(accepted; the tag comes from the bundle name)")
opts, _unknown = parser.parse_known_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
HIDES = [float(h) for h in opts.hides.split(",") if h.strip()]
RESULTS = {"app": opts.app, "hides": HIDES, "checks": [], "phases": []}

COUNTERS = """<script>
const d = document.documentElement.dataset;
document.addEventListener('freeze', () => { d.freezes = +(d.freezes || 0) + 1; });
document.addEventListener('resume', () => { d.resumes = +(d.resumes || 0) + 1; });
let hiddenAt = 0;
document.addEventListener('visibilitychange', () => {
  if (document.hidden) hiddenAt = performance.now(); else if (hiddenAt) d.hidden = Math.round(performance.now() - hiddenAt);
});
</script>"""
STREAM = """<!doctype html><title>stream</title><body style="margin:0;background:#111">
<video id=v muted playsinline style="width:100%;height:100vh;object-fit:contain"></video>""" + COUNTERS + """<script>
const c = document.createElement('canvas'); c.width = 320; c.height = 180;
const g = c.getContext('2d');
const draw = (now) => {
  g.fillStyle = '#12324a'; g.fillRect(0, 0, 320, 180);
  g.fillStyle = '#4cf'; g.fillRect((now / 4) % 320, 70, 40, 60);
  g.fillStyle = '#fff'; g.font = '28px monospace'; g.fillText((now / 1000).toFixed(1) + ' s', 10, 36);
  requestAnimationFrame(draw);
};
requestAnimationFrame(draw);
const v = document.getElementById('v');
v.srcObject = c.captureStream(30);
v.play();
if (location.search.includes('pause')) setTimeout(() => { v.pause(); d.pausedByPage = 1; }, 1500);
</script>"""
PAGES = {
    "stream.html": STREAM,
    "frame.html": """<!doctype html><title>frame</title><body style="margin:0">
<iframe src="stream.html" style="border:0;width:100%;height:100vh"></iframe>""",
    "file.html": """<!doctype html><title>file</title><body style="margin:0;background:#111">
<video muted autoplay loop playsinline src="clip.webm" style="width:100%;height:100vh;object-fit:contain"></video>""" + COUNTERS,
}
VIDEOS = {"stream": ("stream.html", True), "frame": ("frame.html", True), "file": ("file.html", True),
          "paused": ("stream.html?pause", False)}  # name: (page, plays after each show)
# Read through the DOM (shared by every world): the frame page's video and counters are its iframe's.
STATE = """(() => {
  const f = document.querySelector('iframe'); const doc = f ? f.contentDocument : document;
  const v = doc && doc.querySelector('video'); if (!v) return JSON.stringify({missing: true});
  const d = doc.documentElement.dataset;
  return JSON.stringify({paused: v.paused, ended: v.ended, t: v.currentTime, ready: v.readyState,
    frames: v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality().totalVideoFrames : -1,
    freezes: +(d.freezes || 0), resumes: +(d.resumes || 0), hidden_ms: +(d.hidden || 0), visible: document.visibilityState});
})()"""


class Pages(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0].lstrip("/")
        if path == "clip.webm":
            body, kind = open(os.path.join(HERE, "hidden-video-thaw-live.webm"), "rb").read(), "video/webm"
        elif path in PAGES:
            body, kind = PAGES[path].encode(), "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{server.server_address[1]}/"
extra = dict(item.split("=", 1) for item in opts.env)
bench = BenchApp(opts.app, out=OUT, env=extra, window=(40, 40, 1400, 880), screen=opts.screen)


def rpc(method, params=None, timeout=60):
    reply = bench.rpc(method, params, timeout=timeout)
    return reply if isinstance(reply, dict) else {"value": reply}


def action(name, args=None, target=None):
    query = {"action": name, "focus": True, "origin": "script"}
    if args:
        query["args"] = args
    if target:
        query["target"] = target
    return rpc("action.run", query)


def wait(check, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = check()
        if value:
            return value
        time.sleep(step)  # sleep-ok: the poll tick of a bounded wait on the app's state
    return None


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    RESULTS["checks"].append({"ok": bool(ok), "what": what})


def save():
    with open(os.path.join(OUT, "results.json"), "w") as f:
        json.dump(RESULTS, f, indent=1, default=str)


def current_workspace():
    window = ((rpc("debug.focus").get("windows") or [{}])[0]).get("workspace")
    return window.get("workspace") if isinstance(window, dict) else window


def state(tab):
    value = rpc("browser.page.eval", {"script": STATE, "tab": tab}, timeout=10).get("value")
    try:
        return json.loads(value) if isinstance(value, str) else {"error": value}
    except ValueError:
        return {"error": value}


def open_page(path):
    made = action("openBrowser.chromium", {"url": URL + path})
    tab = (made.get("created") or [None])[0]
    if tab:
        wait(lambda: state(tab).get("ready", 0) >= 2, 30)
    return tab


NUMBERS = {}


def show(workspace):
    """Selects `workspace` by its sidebar number (learnt once by trying 1 to 9)."""
    if current_workspace() == workspace:
        return True
    if workspace in NUMBERS:
        action("selectWorkspaceByNumber", {"index": NUMBERS[workspace]})
        if wait(lambda: current_workspace() == workspace, 5, 0.05):
            return True
    for number in range(1, 10):
        action("selectWorkspaceByNumber", {"index": number})
        if wait(lambda: current_workspace() == workspace, 1.5, 0.05):
            NUMBERS[workspace] = number
            return True
    return False


def frozen():
    return set((rpc("debug.surfaces").get("hibernation") or {}).get("frozen") or [])


def cpu_times():
    """{pid: (kind, CPU seconds)} of the app's renderer and GPU processes (`ps`)."""
    out = subprocess.run(["ps", "-axo", "pid=,time=,command="], capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3 or bench.app not in parts[2]:
            continue
        kind = "renderer" if "--type=renderer" in parts[2] else "gpu" if "--type=gpu-process" in parts[2] else None
        if not kind:
            continue
        seconds = 0.0
        for field in parts[1].replace("-", ":").split(":"):
            seconds = seconds * 60 + float(field)
        client = next((a.split("=", 1)[1] for a in parts[2].split() if a.startswith("--renderer-client-id=")), None)
        found[int(parts[0])] = (kind + (f":{client}" if client else ""), seconds)
    return found


def cpu_report(before, after, seconds):
    """Percent of one core per process over `seconds`, and the renderers' total."""
    rows = {f"{kind}:{pid}": round(100 * (after[pid][1] - spent) / seconds, 2)
            for pid, (kind, spent) in before.items() if pid in after}
    renderers = sum(v for k, v in rows.items() if k.startswith("renderer"))
    return {"seconds": round(seconds, 1), "percent": dict(sorted(rows.items(), key=lambda kv: -kv[1])),
            "renderers_total": round(renderers, 2)}


def record(path, seconds):
    """Starts the app's window recorder on `path`; the reply once it captures (or its error)."""
    started = rpc("debug.motion", {"action": "record_start", "path": path, "seconds": seconds, "mbps": 30})
    if started.get("error"):
        return started
    return wait(lambda: (lambda r: r if (r.get("capturing") and r.get("path") == path) or r.get("error") else None)(
        rpc("debug.motion", {"action": "record_read"})), 10, 0.05)


def record_end():
    """Stops the recording (a timed one keeps the recorder until stopped) and waits until its movie is written."""
    rpc("debug.motion", {"action": "record_stop"})
    return wait(lambda: (lambda r: r if r.get("written") or r.get("error") else None)(
        rpc("debug.motion", {"action": "record_read"})), 30, 0.25)


def phase(seconds, tabs, away, home, threshold):
    """Hides the video workspace for `seconds`, shows it again and reads every video."""
    name = f"hide-{int(seconds)}s"
    show(away)
    hidden_at = time.monotonic()
    froze = {}
    cpu_from, cpu = None, None
    while time.monotonic() - hidden_at < seconds:  # the hide itself: read only the app's own state
        now_frozen = frozen()
        for label, tab in tabs.items():
            if tab in now_frozen and label not in froze:
                froze[label] = round(time.monotonic() - hidden_at, 1)
        if cpu_from is None and seconds > threshold + 8 and time.monotonic() - hidden_at >= threshold + 4:
            cpu_from = (time.monotonic(), cpu_times())
        time.sleep(1.0)  # sleep-ok: one read of the app's freeze state per second while the workspace is hidden
    if cpu_from:
        cpu = cpu_report(cpu_from[1], cpu_times(), time.monotonic() - cpu_from[0])
    movie = os.path.join(OUT, f"show-{int(seconds)}s.mov") if opts.record else None
    recorded = None
    if movie:
        recorded = record(movie, 9)
        time.sleep(0.8)  # sleep-ok: the movie starts on the hidden workspace, before the switch back
    shown_at = time.monotonic()
    back = show(home)
    still_frozen = frozen() & set(tabs.values())
    time.sleep(2.5)  # sleep-ok: an observation window: a video that plays again does so within it
    first = {label: state(tab) for label, tab in tabs.items()}
    time.sleep(2.0)  # sleep-ok: the second read, 2 s later: currentTime and decoded frames must move
    second = {label: state(tab) for label, tab in tabs.items()}
    if movie:
        recorded = {"start": recorded, "end": record_end()}
    record_ = {"phase": name, "hidden_s": round(shown_at - hidden_at, 1), "froze_at_s": froze, "frozen_after_show": sorted(still_frozen),
               "shown": back, "first": first, "second": second, "movie": movie, "recorded": recorded, "cpu": cpu}
    RESULTS["phases"].append(record_)
    save()
    return record_


def judge(result, threshold):
    name, long_hide = result["phase"], result["hidden_s"] > threshold + 5
    check(result["shown"], f"{name}: the video workspace shows again")
    if long_hide:
        froze = result["froze_at_s"]
        if "paused" not in froze:
            print(f"INCONCLUSIVE {name}: the paused page did not freeze in a {result['hidden_s']} s hide (threshold {threshold} s; "
                  f"froze: {froze})", flush=True)
            return "inconclusive"
        check(True, f"{name}: the hide passed the freeze threshold: the paused page froze (froze at: {froze}; cpu: {result.get('cpu')})")
    else:
        check(not result["froze_at_s"], f"{name}: no page froze in a hide under the {threshold} s threshold ({result['froze_at_s']})")
    check(not result["frozen_after_show"], f"{name}: no page is still frozen once shown ({result['frozen_after_show']})")
    for label, (_page, plays) in VIDEOS.items():
        a, b = result["first"].get(label) or {}, result["second"].get(label) or {}
        moved_t, moved_frames = (b.get("t") or 0) - (a.get("t") or 0), (b.get("frames") or 0) - (a.get("frames") or 0)
        seen = f"paused={b.get('paused')} t+{moved_t:.2f}s frames+{moved_frames} freezes={b.get('freezes')} resumes={b.get('resumes')} hidden_ms={b.get('hidden_ms')}"
        if plays:
            # currentTime moves (a looping clip wraps it, so any change counts) and new frames are decoded.
            check(b.get("paused") is False and abs(moved_t) >= 0.2 and moved_frames >= 5,
                  f"{name}: {label}: the video plays after the show ({seen})")
        else:
            check(b.get("paused") is True and moved_frames == 0, f"{name}: {label}: the video the page paused stays paused ({seen})")
    return "judged"


status = 0
try:
    bench.launch(timeout=180)
    setting = (rpc("debug.surfaces").get("hibernation") or {})
    threshold = 30.0
    RESULTS["hibernation_mode"] = setting.get("mode")
    first = current_workspace()
    action("workspace.newAtBottom")
    away = wait(lambda: (lambda w: w if w and w != first else None)(current_workspace()), 10)
    action("workspace.newAtBottom")
    home = wait(lambda: (lambda w: w if w and w not in (first, away) else None)(current_workspace()), 10)
    tabs = {}
    for index, (label, (page, _plays)) in enumerate(VIDEOS.items()):
        if index:
            action("splitRight" if index % 2 else "splitDown")
        tabs[label] = open_page(page)
    RESULTS["tabs"], RESULTS["workspaces"] = tabs, {"away": away, "home": home}
    learned = show(away) and show(home)
    time.sleep(2.0)  # sleep-ok: the paused control page pauses itself 1.5 s after load
    ready = {label: state(tab) for label, tab in tabs.items()}
    RESULTS["ready"] = ready
    setup_ok = learned and all(tabs.values()) and all(
        (s.get("paused") is False) == plays for (label, (_p, plays)), s in zip(VIDEOS.items(), ready.values()))
    check(setup_ok, f"setup: four Chromium video pages, the three live ones playing ({ready})")
    save()
    if not setup_ok:
        status = 2
    else:
        for seconds in HIDES:
            verdict = judge(phase(seconds, tabs, away, home, threshold), threshold)
            if verdict == "inconclusive" and status == 0:
                status = 2
        if any(not c["ok"] for c in RESULTS["checks"]):
            status = 1
finally:
    try:
        bench.stop()
    finally:
        server.shutdown()
        RESULTS["status"] = status
        save()
print("PASS" if status == 0 else ("FAILED" if status == 1 else "INCONCLUSIVE"), flush=True)
sys.exit(status)
