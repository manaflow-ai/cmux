#!/usr/bin/env python3
"""Live check: a hidden Chromium tab playing Web Audio never hibernates (cx-d0d.9).

  scripts/cmux-next/hibernation-busy-live.py --socket /tmp/cmux-debug-<tag>.sock

The app must run with a short `browser.hibernation` (minutes, e.g. 0.05) from a config of its
own: launch it with CMUX_NEXT_CONFIG_FILE=<file> holding {"browser": {"hibernation": 0.05}},
never by writing a shared config. Each page starts a Web
Audio oscillator on a click (`debug.mouse {"target": "page"}`, an in-app event; autoplay
needs a gesture). Then, in one pane:

  1. a page whose own document plays Web Audio, and a page whose iframe plays it, are hidden
     behind a silent control page;
  2. the control page is hidden too, behind a last page;
  3. the control page hibernates (the trigger fired), and the audio pages stay loaded with
     the `web_audio` exemption (`debug.surfaces` hibernation). Critical memory pressure
     overrides that exemption; this script runs at normal pressure.

Before cx-d0d.9 the probe saw only <audio>/<video> elements, so both audio pages hibernated.
Camera, microphone and screen capture share the recorder (BrowserPageBusy) but need a
permission prompt and a device; this script does not cover them. GUI host only. Leaves the
app running. Exits 1 when a check fails, 2 when the app's hibernation threshold is not short.
"""
import argparse, json, os, socket, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
opts = parser.parse_args()
failures = []

AUDIO = """<script>
let context;
addEventListener("mousedown", () => {
  if (context) return;
  context = new AudioContext();
  const tone = context.createOscillator(), gain = context.createGain();
  gain.gain.value = 0.001;
  tone.connect(gain).connect(context.destination);
  tone.start();
  const show = () => { document.title = "audio " + context.state; if (parent !== window) parent.postMessage(document.title, "*"); };
  context.addEventListener("statechange", show);
  show();
});
</script>"""
PAGES = {
    "top": "<!doctype html><title>audio idle</title><body style='height:100vh;margin:0'>Web Audio here." + AUDIO,
    "frame": "<!doctype html><title>audio idle</title><body style='margin:0'>"
             "<script>addEventListener('message', (e) => { if (typeof e.data === 'string') document.title = e.data; })</script>"
             "<iframe style='border:0;width:100vw;height:100vh' srcdoc=\""
             + ("<body style='height:100vh;margin:0'>Web Audio in a frame." + AUDIO).replace('"', "&quot;") + "\"></iframe>",
    "control": "<!doctype html><title>silent</title><body>Nothing plays here.",
    "front": "<!doctype html><title>front</title><body>The shown page.",
}


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    result = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    return result if isinstance(result, dict) else {"value": result}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    return None


def hibernation():
    return rpc("debug.surfaces").get("hibernation") or {}


def title(tab):
    return str(rpc("browser.page.eval", {"script": "document.title", "tab": tab}, timeout=5).get("value"))


def open_tab(url):
    tab = (rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True}, timeout=60)
           .get("created") or [None])[0]
    quiet_wait(lambda: rpc("debug.browser.page_status", {"tab": tab}).get("gone") is not None, 20)
    time.sleep(2)
    return tab


mode = hibernation().get("mode")
if not isinstance(mode, (int, float)) or mode > 0.5:
    print(f"browser.hibernation is {mode!r}: launch the app with a short threshold (see --help)", flush=True)
    sys.exit(2)

scratch = tempfile.mkdtemp(prefix="hibernation-busy-")
tabs = {}
for name, html in PAGES.items():
    path = os.path.join(scratch, f"{name}.html")
    with open(path, "w") as f:
        f.write(html)
    tabs[name] = open_tab("file://" + path)
    check(bool(tabs[name]), f"{name}: a Chromium tab opens")
    if name in ("top", "frame") and tabs[name]:
        reply = rpc("debug.mouse", {"target": "page"})
        check(reply.get("delivered") == 2, f"{name}: a click reaches the page ({reply})")
        playing = quiet_wait(lambda: title(tabs[name]) == "audio running", 10)
        check(bool(playing), f"{name}: Web Audio runs ({title(tabs[name])})")

control = quiet_wait(lambda: tabs["control"] in (hibernation().get("hibernated") or []), 60)
check(bool(control), f"control: the silent hidden page hibernates ({hibernation()})")
time.sleep(5)
state = hibernation()
for name in ("top", "frame"):
    tab = tabs[name]
    check(tab not in (state.get("hibernated") or []) and (state.get("exemptions") or {}).get(tab) == "web_audio",
          f"{name}: the hidden page playing Web Audio stays loaded, exemption web_audio "
          f"(hibernated={tab in (state.get('hibernated') or [])}, exemption={(state.get('exemptions') or {}).get(tab)})")
    if tab not in (state.get("hibernated") or []):
        check(title(tab) == "audio running", f"{name}: its audio still runs ({title(tab)})")

for tab in tabs.values():
    if tab:
        rpc("action.run", {"action": "closeTab", "target": f"tab:{tab}", "origin": "script"})
print("FAILED: " + "; ".join(failures) if failures else "PASS", flush=True)
sys.exit(1 if failures else 0)
