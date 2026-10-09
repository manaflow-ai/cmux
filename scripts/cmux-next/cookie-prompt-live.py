#!/usr/bin/env python3
"""Live check: the cookie import card and the glass "Did you know" card on a tagged build (cx-367y).

  scripts/cmux-next/cookie-prompt-live.py --tag <tag> [--capture] [--out DIR]

Launches the tagged app with no activation, the automation socket, a scratch
cmux.json and CMUX_NEXT_COOKIE_PROMPT=1 (automation launches never show the
card otherwise), resets the card's state, then drives the person path:

  1. a Chromium tab on https://example.com: when its page finishes, the card
     must appear by itself (debug.cookie_prompt shown_on), once per launch;
  2. Not Now closes it and snoozes it; Don't Show Again ends it; Import
     Cookies opens the import step with only cookies checked;
  3. the Did you know card (debug.updater tip) sits on Liquid Glass.

With --capture it saves the browser card and the tip card in light, dark,
and dark over a backdrop painting through the one agent capture helper (its
daemon must run: scripts/agent-capture-helper.sh start). GUI host only.
Quits the app by PID and stops the tag's daemons at the end.
"""
import argparse, glob, json, os, plistlib, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--capture", action="store_true",
                    help="save screenshots through the agent capture helper's daemon (scripts/agent-capture-helper.sh start)")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="cookie-prompt-live-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--launch-backdrop", action="store_true",
                    help="launch with a backdrop painting already set and capture the Did you know card first (nxdog76)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"cookie-prompt-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


def cli(*args, timeout=30):
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)


def rpc(method, params=None):
    r = cli("--json", "app", "call", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    check(False, f"timed out: {what}")
    return None


CAPTURE_SOCKET = os.path.expanduser("~/Library/Application Support/cmux/agent-capture/run/cua.sock")


def capture_call(name, args):
    import socket
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(60)
    s.connect(CAPTURE_SOCKET)
    s.sendall(json.dumps({"method": "call", "name": name, "args": args}).encode() + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data or b"{}")


COMPOSITE_SWIFT = r"""
import AppKit
// composite.swift OUT W H [PNG X Y W H]...: draws each PNG into the rect X,Y,W,H (pixels, top-left origin) on a W x H canvas.
let a = CommandLine.arguments
let width = Int(a[2])!, height = Int(a[3])!
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
var i = 4
while i + 4 < a.count {
    if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[i]) as CFURL, nil),
       let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        let x = Double(a[i + 1])!, y = Double(a[i + 2])!, w = Double(a[i + 3])!, h = Double(a[i + 4])!
        ctx.draw(image, in: CGRect(x: x, y: Double(height) - y - h, width: w, height: h))
    }
    i += 5
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
"""


def capture(name):
    """Each on-screen window of the app (main window, dialog and toast overlays) through the
    capture helper's window path, drawn back to front on the main window's frame."""
    if not opts.capture:
        return
    path = os.path.join(opts.out, f"{name}.png")
    listed = ((capture_call("list_windows", {"pid": app.pid}).get("result") or {}).get("structuredContent") or {}).get("windows") or []
    windows = [w for w in listed if w.get("is_on_screen", True) and w.get("bounds") and w["bounds"]["width"] > 1]
    if not windows:
        return check(False, f"capture {name}: no on-screen window")
    titled = [w for w in windows if w.get("title")]
    main = (titled or windows)[-1]
    scale = 2.0
    layers = []
    # list_windows is front to back; draw back to front with the main window first.
    for w in [main] + [w for w in reversed(windows) if w is not main]:
        part = os.path.join(opts.out, "layers", f"{name}-{w['window_id']}.png")
        os.makedirs(os.path.dirname(part), exist_ok=True)
        capture_call("get_window_state", {"pid": app.pid, "window_id": w["window_id"], "max_elements": 1, "screenshot_out_file": part})
        if os.path.exists(part):
            b = w["bounds"]
            layers += [part, str((b["x"] - main["bounds"]["x"]) * scale), str((b["y"] - main["bounds"]["y"]) * scale),
                       str(b["width"] * scale), str(b["height"] * scale)]
    script = os.path.join(SCRATCH, "composite.swift")
    write(script, COMPOSITE_SWIFT)
    size = [str(int(main["bounds"][k] * scale)) for k in ("width", "height")]
    r = subprocess.run(["/usr/bin/swift", script, path, *size, *layers], capture_output=True, text=True, timeout=300)
    check(r.returncode == 0 and os.path.exists(path), f"capture {name}: {len(layers) // 5} window(s) {[(w.get('title'), w['bounds']) for w in windows]} -> {path} {r.stderr.strip()[-300:]}")



def prompt(action="state", **params):
    return rpc("debug.cookie_prompt", {"action": action, **params})


def settle(seconds=1.0):
    time.sleep(seconds)  # let the window redraw (and the glass settle) before a capture (screenshot only)


def config(background=None):
    write(CONFIG, json.dumps({"appearance": {"background": background}} if background else {}) + "\n")
    settle(2.0)


write(CONFIG, (json.dumps({"appearance": {"background": "wheat-field-with-cypresses"}}) if opts.launch_backdrop else "{}") + "\n")
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
write(EMPTY_GHOSTTY, "")
teardown = TagTeardown(APP)
teardown.install()
app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
                                      "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
                                      "CMUX_NEXT_COOKIE_PROMPT": "1",
                                      # The default Ghostty theme follows light and dark (no host config).
                                      "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY},
                       stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)
    if opts.launch_backdrop:
        # The card first built over a painting set at launch drew empty (nxdog76).
        for mode in ["dark", "light"]:
            rpc("debug.appearance", {"mode": mode})
            rpc("debug.updater", {"action": "tip"})
            settle(2.0)
            capture(f"tip-card-launch-backdrop-{mode}")
        config(None)
    # A recovered-draft toast from an earlier run of this tag would hold the card back (and cover it).
    for draft in rpc("debug.filepages").get("drafts") or []:
        rpc("debug.filepages", {"restore": draft["id"]})
    wait_for(lambda: not rpc("debug.filepages").get("toasts"), "no window toast before the check", 15)
    state = prompt("reset")
    # A tab restored from an earlier run may already show the card (its page finished at launch).
    check(not state.get("never_show") and not state.get("imported") and not state.get("snoozed_until"), f"fresh state: {state}")
    rpc("debug.appearance", {"mode": "light"})
    # A browser workspace gives the window a pane with a tab, so openBrowser has a target.
    print("newBrowserWorkspace:", json.dumps(rpc("action.run", {"action": "newBrowserWorkspace", "focus": True}))[:300], flush=True)
    settle(3.0)
    # A window toast (here the pin undo toast) at the bottom: the card still shows, lifted above it.
    rpc("action.run", {"action": "palette.toggleTabPin"})
    deadline = time.monotonic() + 5
    toasts = None
    while not toasts and time.monotonic() < deadline:  # bounded wait; a missing toast is a SKIP, not a failure
        toasts = rpc("debug.filepages").get("toasts")
        time.sleep(0.2)
    if not toasts:
        print("SKIP toast lift: the pin made no toast", flush=True)
    # The person's path: a URL typed into the omnibar of their own tab. (A tab an agent opens
    # through openBrowser is agent-driven and never shows the card.)
    typed = rpc("debug.omnibar_type", {"text": "https://example.com/"})
    print("omnibar_type:", json.dumps(typed)[:300], flush=True)
    if toasts:
        settle(1.5)
        capture("browser-card-over-toast")
    shown = wait_for(lambda: prompt().get("shown_on"), "the card appears when the page finishes", 60)
    state = prompt()
    check(bool(shown), f"the card showed by itself on the finished page: {state}")
    check(bool(state.get("browsers")), f"installed browsers found: {state.get('browsers')}")
    focus = rpc("debug.focus")
    check(not focus.get("app_active"), f"no activation: {focus}")
    # The card may have come up on a tab restored from an earlier run (a hidden workspace);
    # the captures need it on the tab on screen.
    state = prompt("show")
    check(len(state.get("shown_on") or []) >= 1, f"card on the visible tab for the captures: {state}")
    settle()
    capture("browser-card-light")
    rpc("debug.appearance", {"mode": "dark"})
    settle()
    capture("browser-card-dark")
    config("wheat-field-with-cypresses")
    capture("browser-card-dark-backdrop")
    rpc("debug.updater", {"action": "tip"})
    settle()
    capture("tip-card-dark-backdrop")
    config(None)
    capture("tip-card-dark")
    rpc("debug.appearance", {"mode": "light"})
    settle()
    capture("tip-card-light")
    config("wheat-field-with-cypresses")
    capture("tip-card-light-backdrop")
    config(None)

    # Answers: Not Now snoozes, a second page in this launch shows nothing.
    state = prompt("answer", choice="not_now")
    check(state.get("snoozed_until") is not None and state.get("shown_on") == [], f"Not Now closes and snoozes: {state}")
    rpc("debug.omnibar_type", {"text": "https://example.org/"})
    settle(5.0)
    check(prompt().get("shown_on") == [], "once per launch and snoozed: no second card")
    state = prompt("answer", choice="never")
    check(state.get("never_show") is True, f"Don't Show Again ends it: {state}")
    prompt("reset")
    shown_tab = (wait_for(lambda: prompt("show").get("shown_on"), "the card again for Import Cookies", 10) or [None])[0]
    state = prompt("answer", choice="import")
    onboarding = rpc("debug.onboarding", {"action": "state"})
    print("onboarding after Import Cookies:", json.dumps(onboarding)[:600], flush=True)
    check(onboarding.get("step") == "importData", f"Import Cookies opens the import step: {onboarding.get('step')}")
    kinds = onboarding.get("import", {}).get("kinds") or onboarding.get("kinds")
    check(kinds == ["cookies"], f"only cookies checked: {kinds}")
    target = onboarding.get("merge_target")
    check(target is not None, f"Import Cookies from the card imports into the profile of tab {shown_tab}: merge_target={target}")
    settle()
    capture("import-step-cookies")
    rpc("debug.onboarding", {"action": "close"})
    prompt("reset")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()
    teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
