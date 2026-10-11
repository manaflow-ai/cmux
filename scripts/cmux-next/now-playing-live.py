#!/usr/bin/env python3
"""Live check: the playing browser tab in macOS Now Playing and on the media keys, and
picture-in-picture, in both engines (cx-6qwm.3).

  scripts/cmux-next/now-playing-live.py --tag <tag> [--out DIR] [--app PATH] [--engines chromium,webkit]
  scripts/cmux-next/now-playing-live.py --socket PATH   (an app already running, e.g. a capture slot)

Launches the tagged app (no activation, automation socket, empty config) and
serves a page with a looping tone, a canvas video and `navigator.mediaSession`
metadata and actions. The page is one big button, clicked through
`debug.mouse` (a real click, the user gesture playback and picture-in-picture
need). For each engine:

  1. the click plays the tone: Now Playing (`debug.now_playing`) names the
     page's metadata, reports playing, and enables play/pause, next and previous;
  2. the media keys (the Now Playing remote commands, `debug.now_playing`
     `command`) pause the tab, play it again, and reach the page's
     `nexttrack` handler;
  3. a click asks for picture-in-picture: the video enters it;
  4. closing the tab clears Now Playing.

GUI host only (a capture mini). An app it launched is quit and the tag's
daemons stopped at the end; one it attached to with --socket keeps running.
Exits 1 when a check fails.
"""
import argparse, functools, glob, http.server, json, math, os, plistlib, socket, struct, subprocess, sys, tempfile, threading, time, wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag")
parser.add_argument("--socket", help="attach to the app serving this automation socket instead of launching one")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="now-playing-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--engines", default="chromium,webkit")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

if not opts.socket and not opts.tag:
    parser.error("--tag or --socket is required")
SOCKET = opts.socket or f"/tmp/cmux-debug-{opts.tag}.sock"
failures = []

PAGE = """<!doctype html><title>cmux tone page</title>
<style>html, body { margin: 0; height: 100%; } button { width: 100vw; height: 100vh; font: 32px system-ui; }
video { position: fixed; right: 8px; bottom: 8px; width: 160px; height: 90px; }</style>
<button id="b">play</button>
<audio id="a" src="tone.wav" loop></audio>
<video id="v" muted playsinline></video>
<script>
window.log = { clicks: 0, next: 0, previous: 0, pip: null };
window.mode = 'play';
const a = document.getElementById('a'), v = document.getElementById('v');
const canvas = document.createElement('canvas');
canvas.width = 320; canvas.height = 180;
const paint = canvas.getContext('2d');
let hue = 0;
setInterval(() => { paint.fillStyle = `hsl(${hue++ % 360}, 70%, 50%)`; paint.fillRect(0, 0, 320, 180); }, 50);
v.srcObject = canvas.captureStream(20);
navigator.mediaSession.metadata = new MediaMetadata({ title: 'cmux tone', artist: 'cmux live test', album: 'cx-6qwm.3' });
navigator.mediaSession.setActionHandler('nexttrack', () => { log.next++; });
navigator.mediaSession.setActionHandler('previoustrack', () => { log.previous++; });
v.addEventListener('enterpictureinpicture', () => { log.pip = 'entered'; });
document.getElementById('b').onclick = async () => {
  log.clicks++;
  try {
    if (mode === 'play') await a.play();
    else if (mode === 'pip') { await v.play(); await v.requestPictureInPicture(); }
  } catch (error) { log.pip = log.pip || String(error); }
};
</script>
"""


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def call(method, params=None, timeout=30):
    """The raw reply: {"ok": true, "result": ...} or {"ok": false, "error": {...}}."""
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
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": {"code": "socket", "message": str(error)}}


def rpc(method, params=None):
    reply = call(method, params)
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def wait_for(predicate, what, seconds=20):
    value = quiet_wait(predicate, seconds)
    check(bool(value), what)
    return value


def windows():
    report = rpc("debug.focus") or {}
    return report.get("windows") or [] if isinstance(report, dict) else []


def focused_pane(window):
    entry = next((w for w in windows() if w.get("id") == window), None)
    return ((entry or {}).get("model") or {}).get("pane")


def page(script):
    """The focused tab's value of `script`, or None."""
    reply = rpc("browser.page.eval", {"script": script}) or {}
    return reply.get("value") if isinstance(reply, dict) else None


def now_playing(params=None):
    reply = rpc("debug.now_playing", params) or {}
    return reply if isinstance(reply, dict) else {}


def info():
    return now_playing().get("info") or {}


def serve():
    """A local server for the page and its tone; the page's URL."""
    root = tempfile.mkdtemp(prefix="now-playing-page-")
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write(PAGE)
    tone = wave.open(os.path.join(root, "tone.wav"), "wb")
    tone.setnchannels(1)
    tone.setsampwidth(2)
    tone.setframerate(22050)
    tone.writeframes(b"".join(struct.pack("<h", int(3000 * math.sin(2 * math.pi * 440 * i / 22050))) for i in range(22050 * 2)))
    tone.close()
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    handler.log_message = lambda *args: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/index.html"


def click(window, mode):
    page(f"window.mode = {json.dumps(mode)}; true")
    clicks = (page("log.clicks") or 0)
    print("click", mode, rpc("debug.mouse", {"window": window, "pane": focused_pane(window)}), flush=True)
    return quiet_wait(lambda: (page("log.clicks") or 0) > clicks, 10)


def run_engine(engine, window, url):
    print(f"== {engine}", flush=True)
    action = "openBrowser.chromium" if engine == "chromium" else "openBrowser.webkit"
    print("open", rpc("action.run", {"action": action, "args": {"url": url}, "focus": True}), flush=True)
    if not wait_for(lambda: page("document.readyState === 'complete' && !!window.log"), f"{engine}: the page loads", 60):
        return
    time.sleep(1)

    # 1. A click plays the tone; Now Playing names it.
    check(bool(click(window, "play")), f"{engine}: the click reaches the page")
    wait_for(lambda: page("!document.getElementById('a').paused"), f"{engine}: the tone plays")
    wait_for(lambda: info().get("title") == "cmux tone", f"{engine}: Now Playing names the page's title", 15)
    report = now_playing()
    print(json.dumps(report), flush=True)
    check((report.get("info") or {}).get("artist") == "cmux live test", f"{engine}: Now Playing has the artist")
    check((report.get("info") or {}).get("rate") == 1, f"{engine}: Now Playing rate is 1 while playing")
    check(report.get("playback_state") == "playing", f"{engine}: playback state is playing")
    commands = report.get("commands") or {}
    check(all(commands.get(name) for name in ("play", "pause", "toggle", "next", "previous")),
          f"{engine}: play, pause, toggle, next and previous are enabled: {commands}")

    # 2. The media keys.
    print("pause", now_playing({"command": "pause"}).get("handled"), flush=True)
    wait_for(lambda: page("document.getElementById('a').paused"), f"{engine}: pause pauses the tab")
    wait_for(lambda: now_playing().get("playback_state") == "paused" and info().get("title") == "cmux tone",
             f"{engine}: Now Playing keeps the paused tab, paused")
    print("toggle", now_playing({"command": "toggle"}).get("handled"), flush=True)
    wait_for(lambda: page("!document.getElementById('a').paused"), f"{engine}: play/pause plays it again")
    wait_for(lambda: now_playing().get("playback_state") == "playing", f"{engine}: playback state is playing again")
    print("next", now_playing({"command": "next"}).get("handled"), flush=True)
    wait_for(lambda: page("log.next") == 1, f"{engine}: next reaches the page's nexttrack handler")
    print("previous", now_playing({"command": "previous"}).get("handled"), flush=True)
    wait_for(lambda: page("log.previous") == 1, f"{engine}: previous reaches the page's previoustrack handler")

    # 3. Picture-in-picture.
    click(window, "pip")
    entered = quiet_wait(lambda: page("log.pip"), 10)
    print(f"{engine}: pip {entered}, element {page('document.pictureInPictureElement && document.pictureInPictureElement.id')},"
          f" windows {now_playing().get('windows')}", flush=True)
    check(entered == "entered" and page("document.pictureInPictureElement === document.getElementById('v')"),
          f"{engine}: the video enters picture-in-picture ({entered})")
    page("document.pictureInPictureElement && document.exitPictureInPicture(); true")
    time.sleep(1)

    # 4. Closing the tab clears Now Playing.
    print("close", rpc("action.run", {"action": "closeTab", "origin": "script"}), flush=True)
    wait_for(lambda: not now_playing().get("info") and "error" not in now_playing(), f"{engine}: closing the tab clears Now Playing", 15)


app = teardown = None
if not opts.socket:
    APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
    if not APP:
        sys.exit(f"no tagged app for {opts.tag}")
    with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
        BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
    SCRATCH = tempfile.mkdtemp(prefix=f"now-playing-{opts.tag}-")
    CONFIG = os.path.join(SCRATCH, "cmux.json")
    with open(CONFIG, "w") as f:
        f.write("{}\n")
    teardown = TagTeardown(APP)
    teardown.install()
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    app = subprocess.Popen([BINARY], env={
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
        "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"},
        stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 180)
    if not windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    window = (wait_for(lambda: windows(), "a window", 60) or [{}])[0].get("id")
    url = serve()
    print("page", url, flush=True)
    for engine in opts.engines.split(","):
        run_engine(engine, window, url)
finally:
    if app:
        rpc("action.run", {"action": "quitEndSessions"})
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()  # the exact PID this script started
            app.wait()
        teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
