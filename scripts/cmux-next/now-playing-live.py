#!/usr/bin/env python3
"""Live check: the playing browser tab in macOS Now Playing and on the media keys, and
picture-in-picture, in both engines (cx-6qwm.3).

  scripts/cmux-next/now-playing-live.py --tag <tag> [--out DIR] [--app PATH] [--engines chromium,webkit]
  scripts/cmux-next/now-playing-live.py --socket PATH   (an app already running, e.g. a capture slot)

Launches the tagged app (no activation, automation socket, empty config) and
serves a page with a looping tone, a video it records from a canvas, and
`navigator.mediaSession` metadata and actions. Playback and
picture-in-picture run with a user gesture: in Chromium through DevTools
(`Runtime.evaluate` with `userGesture`), in WebKit through the page (WebKit
runs the app's scripts as a gesture). macOS's Now Playing is read through
MediaRemote. For each engine:

  1. the tone plays and macOS Now Playing shows the page's metadata, playing:
     for Chromium as this app, published by cmux (`debug.now_playing`); for
     WebKit by WebKit itself (its GPU process), and cmux adds no second entry;
  2. Chromium: the media keys (cmux's remote command handlers, through
     `debug.now_playing` `command`) pause the tab, play it again, and reach the
     page's `nexttrack` and `previoustrack` handlers. A posted play/pause key
     is tried in both engines, as a note: posting needs the posting process
     to be allowed to post events;
  3. the video enters picture-in-picture;
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
window.log = { clicks: 0, next: 0, previous: 0, pip: null, videoReady: false };
window.mode = 'play';
const a = document.getElementById('a'), v = document.getElementById('v');
const canvas = document.createElement('canvas');
canvas.width = 320; canvas.height = 180;
const paint = canvas.getContext('2d');
let hue = 0;
setInterval(() => { paint.fillStyle = `hsl(${hue++ % 360}, 70%, 50%)`; paint.fillRect(0, 0, 320, 180); }, 50);
// A recorded video (a file, as sites play): WebKit offers no picture-in-picture for a MediaStream.
const recorder = new MediaRecorder(canvas.captureStream(20));
const chunks = [];
recorder.ondataavailable = (event) => chunks.push(event.data);
recorder.onstop = () => {
  v.src = URL.createObjectURL(new Blob(chunks, { type: recorder.mimeType }));
  v.loop = true;
  v.onloadedmetadata = () => { log.videoReady = true; };
};
recorder.start();
setTimeout(() => recorder.stop(), 1500);
navigator.mediaSession.metadata = new MediaMetadata({ title: 'cmux tone', artist: 'cmux live test', album: 'cx-6qwm.3' });
// As players do, the handlers come with playback. (Handlers a tab's first document sets before
// cmux's scripts reach it are not seen: Chromium gets them after that document started.)
a.addEventListener('play', () => {
  navigator.mediaSession.setActionHandler('nexttrack', () => { log.next++; });
  navigator.mediaSession.setActionHandler('previoustrack', () => { log.previous++; });
}, { once: true });
v.addEventListener('enterpictureinpicture', () => { log.pip = 'entered'; });
document.getElementById('b').onclick = async () => {
  log.clicks++;
  try {
    if (mode === 'play') await a.play();
    else if (mode === 'pip') {
      // Synchronously, in the gesture: WebKit's ends at the first await.
      const entering = v.requestPictureInPicture();
      v.play();
      await entering;
    }
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


TAB = None


def page(script):
    """The test tab's value of `script` (the focused tab before it exists), or None."""
    reply = rpc("browser.page.eval", {"script": script, **({"tab": TAB} if TAB else {})}) or {}
    return reply.get("value") if isinstance(reply, dict) else None


def now_playing(params=None):
    reply = rpc("debug.now_playing", params) or {}
    return reply if isinstance(reply, dict) else {}


def info():
    return now_playing().get("info") or {}


# What macOS shows in Now Playing, read through MediaRemote (osascript is Apple-signed,
# which MediaRemote requires of its readers since macOS 15.4).
SYSTEM_JS = r"""
ObjC.import('Foundation');
function run() {
  $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
  const R = $.NSClassFromString('MRNowPlayingRequest');
  if (!R || R.isNil()) return JSON.stringify({ error: 'no MRNowPlayingRequest' });
  const item = R.localNowPlayingItem;
  const info = item && !item.isNil() ? item.nowPlayingInfo : null;
  const path = R.localNowPlayingPlayerPath;
  const client = path && !path.isNil() ? path.client : null;
  const get = (key) => {
    if (!info || info.isNil()) return null;
    const value = info.objectForKey(key);
    return value && !value.isNil() ? ObjC.unwrap(value.description) : null;
  };
  return JSON.stringify({
    bundle: client && !client.isNil() ? ObjC.unwrap(client.bundleIdentifier) : null,
    playing: !!ObjC.unwrap(R.localIsPlaying),
    title: get('kMRMediaRemoteNowPlayingInfoTitle'),
    artist: get('kMRMediaRemoteNowPlayingInfoArtist'),
  });
}
"""

# A media key press (NX_KEYTYPE_PLAY, NEXT, PREVIOUS), posted as the keyboard posts it.
KEY_JS = r"""
ObjC.import('AppKit');
ObjC.import('CoreGraphics');
function run(argv) {
  const code = { play: 16, next: 17, previous: 18 }[argv[0]];
  for (const down of [true, false]) {
    const event = $.NSEvent.otherEventWithTypeLocationModifierFlagsTimestampWindowNumberContextSubtypeData1Data2(
      14, $.NSMakePoint(0, 0), down ? 0xa00 : 0xb00, 0, 0, null, 8, (code << 16) | ((down ? 0xa : 0xb) << 8), -1);
    $.CGEventPost(0, event.CGEvent);
  }
  return 'posted ' + argv[0];
}
"""


def osascript(script, *args):
    try:
        return subprocess.run(["osascript", "-l", "JavaScript", "-e", script, *args], capture_output=True, text=True,
                              timeout=20).stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return str(error)


def system():
    """macOS's Now Playing: {bundle, playing, title, artist}."""
    try:
        return json.loads(osascript(SYSTEM_JS))
    except ValueError:
        return {}


def media_key(name):
    print("media key", osascript(KEY_JS, name), flush=True)


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


def gesture(engine, window, mode):
    """Runs the button's `mode` with a user gesture; whether the page saw it."""
    page(f"window.mode = {json.dumps(mode)}; true")
    clicks = page("log.clicks") or 0
    script = "document.getElementById('b').click(); true"
    if engine == "chromium":
        print(mode, rpc("debug.cef.devtools", {"method": "Runtime.evaluate",
                                                "params": {"expression": script, "userGesture": True}}), flush=True)
    else:
        print(mode, page(script), flush=True)
    return quiet_wait(lambda: (page("log.clicks") or 0) > clicks, 10)


def system_shows_tone():
    now = system()
    return now if now.get("title") == "cmux tone" and now.get("playing") else None


def run_engine(engine, window, url):
    global TAB
    print(f"== {engine}", flush=True)
    action = "openBrowser.chromium" if engine == "chromium" else "openBrowser.webkit"
    opened = rpc("action.run", {"action": action, "args": {"url": url}, "focus": True}) or {}
    print("open", opened, flush=True)
    TAB = ((opened.get("created") or [None]) if isinstance(opened, dict) else [None])[0]
    loaded = lambda: page("document.readyState === 'complete' && !!window.log")  # noqa: E731
    if not quiet_wait(loaded, 60):
        # Seen once right after launch: the new tab was "not a browser tab of this app".
        print("note: the page did not load:", rpc("browser.page.eval", {"script": "location.href", "tab": TAB}), flush=True)
        rpc("action.run", {"action": "closeTab", "origin": "script"})
        opened = rpc("action.run", {"action": action, "args": {"url": url}, "focus": True}) or {}
        TAB = ((opened.get("created") or [None]) if isinstance(opened, dict) else [None])[0]
    if not wait_for(loaded, f"{engine}: the page loads", 60):
        return
    time.sleep(1)

    # 1. The tone plays; macOS Now Playing names it.
    check(bool(gesture(engine, window, "play")), f"{engine}: the page runs play")
    wait_for(lambda: page("!document.getElementById('a').paused"), f"{engine}: the tone plays")
    shown = quiet_wait(system_shows_tone, 15) or system()
    print(f"{engine}: macOS Now Playing {shown}", flush=True)
    if engine == "webkit":
        # WebKit publishes its pages' media itself, from its GPU process; cmux adds no second entry.
        check(bool(system_shows_tone()) and shown.get("artist") == "cmux live test",
              f"{engine}: macOS Now Playing shows the tab's metadata, playing (WebKit's own, {shown.get('bundle')})")
        report = now_playing()
        print(json.dumps(report), flush=True)
        check("error" not in report and report.get("playback_state") and not report.get("info") and not report.get("tab"),
              f"{engine}: cmux does not publish the WebKit tab again")
    else:
        check(bool(system_shows_tone()) and shown.get("artist") == "cmux live test"
              and (not BUNDLE or shown.get("bundle") == BUNDLE),
              f"{engine}: macOS Now Playing shows the tab's metadata, playing, as this app")
        wait_for(lambda: info().get("title") == "cmux tone", f"{engine}: cmux publishes the page's title", 15)
        report = now_playing()
        print(json.dumps(report), flush=True)
        check((report.get("info") or {}).get("artist") == "cmux live test", f"{engine}: cmux publishes the artist")
        check((report.get("info") or {}).get("rate") == 1, f"{engine}: the rate is 1 while playing")
        check(report.get("playback_state") == "playing", f"{engine}: the playback state is playing")
        commands = report.get("commands") or {}
        check(all(commands.get(name) for name in ("play", "pause", "toggle", "next", "previous")),
              f"{engine}: play, pause, toggle, next and previous are enabled: {commands}")

    # 2. The media keys. A posted play/pause key (a note only: it needs the
    # posting process to be allowed to post events)...
    media_key("play")
    paused = quiet_wait(lambda: page("document.getElementById('a').paused"), 5)
    print(f"note: {engine}: after a posted play/pause key the tab is {'paused' if paused else 'playing'}", flush=True)
    if paused:
        media_key("play")
        resumed = quiet_wait(lambda: page("!document.getElementById('a').paused"), 5)
        print(f"note: {engine}: after a second posted key the tab is {'playing' if resumed else 'paused'}", flush=True)
        page("document.getElementById('a').play(); true")
    # ...then cmux's remote command handlers, which MediaPlayer runs for the keys (Chromium tabs).
    if engine == "chromium":
        wait_for(lambda: page("!document.getElementById('a').paused"), f"{engine}: the tone plays before the keys")
        print("pause", now_playing({"command": "pause"}).get("handled"), flush=True)
        wait_for(lambda: page("document.getElementById('a').paused"), f"{engine}: pause pauses the tab")
        wait_for(lambda: now_playing().get("playback_state") == "paused" and info().get("title") == "cmux tone"
                 and info().get("rate") == 0, f"{engine}: Now Playing keeps the paused tab, paused")
        print("toggle", now_playing({"command": "toggle"}).get("handled"), flush=True)
        wait_for(lambda: page("!document.getElementById('a').paused"), f"{engine}: play/pause plays it again")
        wait_for(lambda: now_playing().get("playback_state") == "playing", f"{engine}: the playback state is playing again")
        print("next", now_playing({"command": "next"}).get("handled"), flush=True)
        wait_for(lambda: page("log.next") == 1, f"{engine}: next reaches the page's nexttrack handler")
        print("previous", now_playing({"command": "previous"}).get("handled"), flush=True)
        wait_for(lambda: page("log.previous") == 1, f"{engine}: previous reaches the page's previoustrack handler")

    # 3. Picture-in-picture, of a recorded video (WebKit offers none for a MediaStream).
    wait_for(lambda: page("log.videoReady"), f"{engine}: the page recorded its video")
    gesture(engine, window, "pip")
    entered = quiet_wait(lambda: page("log.pip"), 10)
    support = page("JSON.stringify({ enabled: document.pictureInPictureEnabled, presentation: typeof document.getElementById('v')"
                   ".webkitSupportsPresentationMode === 'function' ? document.getElementById('v')"
                   ".webkitSupportsPresentationMode('picture-in-picture') : null })")
    print(f"{engine}: pip {entered} (support {support}), windows {now_playing().get('windows')}", flush=True)
    check(entered == "entered" and page("document.pictureInPictureElement === document.getElementById('v')"),
          f"{engine}: the video enters picture-in-picture ({entered})")
    page("document.pictureInPictureElement && document.exitPictureInPicture(); true")
    time.sleep(1)

    # 4. Closing the tab clears Now Playing.
    playing = page("!document.getElementById('a').paused")
    print("close", rpc("action.run", {"action": "closeTab", "origin": "script"}), flush=True)
    wait_for(lambda: playing and "error" not in now_playing() and not now_playing().get("info") and not system_shows_tone(),
             f"{engine}: closing the playing tab clears Now Playing", 15)
    if engine == "chromium":
        commands = now_playing().get("commands") or {}
        check(commands and not any(commands.values()), f"{engine}: the commands are disabled after it: {commands}")


app = teardown = None
BUNDLE = None
if not opts.socket:
    APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
    if not APP:
        sys.exit(f"no tagged app for {opts.tag}")
    with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
        plist = plistlib.load(f)
        BINARY = os.path.join(APP, "Contents/MacOS", plist["CFBundleExecutable"])
        BUNDLE = plist.get("CFBundleIdentifier")
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
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
        "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", "CMUX_NEXT_NO_ACTIVATE": "1"},
        stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 180)
    if not windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    window = (wait_for(lambda: windows(), "a window", 60) or [{}])[0].get("id")
    if not quiet_wait(lambda: focused_pane(window), 15):
        print("run newTab", rpc("action.run", {"action": "newTab", "origin": "script", "focus": True}), flush=True)
    wait_for(lambda: focused_pane(window), "a focused pane", 60)
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
