#!/usr/bin/env python3
"""Light and dark window shots of the pane ring, for the "ring only around the content area" Before/After
(Lawrence 2026-11-17: "ring should only be around terminal area not the full pane (top tabs) consider roundness
properly too").

  nx-remote --host cmux-lawrence-2 --class light --needs input --input-reason "pane ring shots" --input-minutes 20 \
    -- python3 scripts/cmux-next/pane-ring-shots-live.py --job <fleet build id> --tag <tag> --label before|after

GUI host only (cmux-lawrence-2). Downloads the build of `--job`, starts it with its own scratch cmux.json, and for
each scene and theme writes the window image (`debug.window_snapshot`) as `<label>-<scene>-<theme>.png`:
  floating-split    Floating Panes (the person's style), two panes, the unfocused one ringing (Mark as Unread)
  floating-single   Floating Panes, one pane, its tab marked unread (the ring on the focused pane)
  tiled-vertical    the default style with vertical tabs and the focus ring on, two panes, the unfocused one ringing
`rings.json` holds each scene's `debug.layers` rings (the ring rect against the pane's content rect).
Every process of this job's own app copy is ended on exit (tag_teardown.py, exact PIDs).
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--job", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--label", required=True)
parser.add_argument("--set", default="content", choices=["content", "styles"],
                    help="content: the three content-area scenes; styles: every appearance.chromeStyle, split, light and dark")
opts = parser.parse_args()

# A folder of this run's own when no artifacts folder is given: a fixed /tmp name another run could own or plant.
OUT = os.path.realpath(os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix=f"pane-ring-shots-{opts.tag}-"))
os.makedirs(OUT, exist_ok=True)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402


def say(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


say("shots in", OUT)


zip_path = os.path.join(OUT, "app.zip")
if not os.path.exists(zip_path):
    subprocess.run([os.path.expanduser("~/.local/bin/cmux-ci"), "artifact", opts.job, zip_path], check=True,
                   env=dict(os.environ, CMUX_CI_CONTROLLER="http://100.89.225.106:18765"))
app_dir = os.path.join(OUT, "app")
if not os.path.isdir(app_dir):
    subprocess.run(["ditto", "-x", "-k", zip_path, app_dir], check=True)
APP = next(iter(glob.glob(os.path.join(app_dir, "*.app"))), None)
if not APP:
    sys.exit("no .app in the artifact")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
# The build's own tag names its socket ("cmux DEV <tag>.app"), whatever --tag says.
TAG = os.path.basename(APP)[len("cmux DEV "):-len(".app")] if os.path.basename(APP).startswith("cmux DEV ") else opts.tag
say("tag", TAG)
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
THEME_DIRS = [d for d in glob.glob(os.path.join(APP, "Contents/Resources/**/themes"), recursive=True) if os.path.isdir(d)]
SHIPPED = {name for d in THEME_DIRS for name in os.listdir(d)}
THEMES = {
    "light": next((t for t in ["GitHub Light Default", "Catppuccin Latte", "Builtin Solarized Light"] if t in SHIPPED), "GitHub Light Default"),
    "dark": next((t for t in ["Monokai Classic", "GitHub Dark Default", "Builtin Dark"] if t in SHIPPED), "GitHub Dark Default"),
}
SCENES = {
    "floating-split": {"appearance": {"chromeStyle": "floating", "density": "compact"}},
    "floating-single": {"appearance": {"chromeStyle": "floating", "density": "compact"}},
    "tiled-vertical": {"appearance": {"density": "compact", "focusIndicator": "both"}, "focusRing": {"enabled": True},
                       "tabs": {"verticalTabs": True}},
}

CHROME_STYLES = ["default", "card", "card-outlined", "flat", "flat-sidebar-line", "bare", "panes", "two-tone", "floating", "blocks"]
if opts.set == "styles":
    SCENES = {f"style-{name}": {"appearance": {"chromeStyle": name, "density": "compact"}} for name in CHROME_STYLES}


def rpc(method, params=None, timeout=60):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(SOCKET)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:  # harness wait for the live app's own state
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def daemon_socket():
    roots = {os.environ.get("TMPDIR", "/tmp"), "/tmp"}
    darwin_tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    if darwin_tmp:
        roots.add(darwin_tmp)
    for root in roots:
        found = glob.glob(os.path.join(root, "cmux-tui-*", f"cmux-app-{TAG}.sock"))
        if found:
            return found[0]
    return None


def cli_json(*args):
    sock = daemon_socket()
    target = ["--socket", sock] if sock else ["--app-socket", SOCKET]
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
    try:
        r = subprocess.run([CLI, *target, "--json", *args], capture_output=True, text=True, timeout=30, env=env)
        return json.loads(r.stdout) if r.stdout.strip() else {"error": r.stderr.strip()}
    except (subprocess.TimeoutExpired, ValueError) as error:
        return {"error": str(error)}


def find_key(value, key):
    if isinstance(value, dict):
        if isinstance(value.get(key), str):
            return value[key]
        for v in value.values():
            found = find_key(v, key)
            if found:
                return found
    if isinstance(value, list):
        for v in value:
            found = find_key(v, key)
            if found:
                return found
    return None


def tab_of_terminal(term):
    tabs = cli_json("tab", "list")
    rows = tabs if isinstance(tabs, list) else (tabs.get("items") or []) if isinstance(tabs, dict) else []
    return next((t for t in rows if isinstance(t, dict) and term in json.dumps(t)), None)


def rings():
    value = rpc("debug.notifications") or {}
    return {pane for window in (value.get("windows") or []) for pane in window.get("attention", [])}


config = os.path.join(OUT, "cmux.json")


def write_config(scene, theme):
    body = json.loads(json.dumps(SCENES[scene]))
    body.setdefault("appearance", {})["theme"] = THEMES[theme]
    body["notifications"] = {"desktop": "never"}
    tmp = config + ".tmp"
    with open(tmp, "w") as f:
        json.dump(body, f)
    os.replace(tmp, config)


for tag_state in (os.path.expanduser(f"~/Library/Application Support/cmux-next/tags/{TAG}"),):
    if os.path.isdir(tag_state) and not os.path.islink(tag_state):
        os.rename(tag_state, f"{tag_state}.old-{int(time.time())}")
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
write_config(next(iter(SCENES)), "light")
env = dict(os.environ)
env.pop("CMUX_NEXT_NO_ACTIVATE", None)
env.update({"CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config,
            "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,700",
            "ACPMUX_AGENT_LAUNCH": "deny"})
TagTeardown(APP).install()
teardown = TagTeardown(APP, log=say)
app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(OUT, "app.log"), "w"), stderr=subprocess.STDOUT,
                       stdin=subprocess.DEVNULL)
say("app pid", app.pid, APP)
report = {}
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180, 0.5):
        sys.exit("the app did not come up")
    if not (rpc("debug.surfaces") or {}).get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script", "focus": True})
    wait(lambda: (rpc("debug.surfaces") or {}).get("windows"), 60, 0.5)
    subprocess.run(["open", APP], capture_output=True)  # active with a key window, as the person's app is
    say("daemon socket", daemon_socket())
    time.sleep(2)  # capture harness: the first window settles
    count = 0
    for scene in SCENES:
        for theme in ("light", "dark"):
            write_config(scene, theme)
            rpc("debug.appearance", {"mode": theme})
            time.sleep(1.5)  # capture harness: the config reloads and the theme repaints
            count += 1
            made = cli_json("workspace", "create", "--name", f"{scene}-{theme}", "--focus")
            term, ws, pane = find_key(made, "terminal_id"), find_key(made, "workspace_id"), find_key(made, "pane_id")
            if not term:
                say("workspace create failed", json.dumps(made)[:300])
                continue
            say("workspace", json.dumps(made)[:300])
            shown = lambda: ws in json.dumps(rpc("debug.focus") or {})
            rpc("action.run", {"action": "goToWorkspace", "target": f"workspace:{ws}", "origin": "script", "focus": True})
            if not wait(shown, 3):
                say("cli focus", json.dumps(cli_json("workspace", ws, "focus"))[:200])
                rpc("action.run", {"action": "selectWorkspace", "target": f"workspace:{ws}", "origin": "script", "focus": True})
                if not wait(shown, 5):
                    say("not shown", ws, json.dumps(rpc("debug.focus"))[:400])
            time.sleep(1.0)  # capture harness: the first prompt draws
            # A second tab, so the strip (or the vertical list) shows real tabs.
            say("tab", json.dumps(cli_json("tab", "create", "terminal", "--pane", pane))[:200])
            time.sleep(0.6)  # capture harness: the new tab's prompt
            if scene.endswith("-single"):
                tab = tab_of_terminal(term) or {}
                say("mark", json.dumps(cli_json("tab", tab.get("id", term), "update", "--marked-unread", "true"))[:200])
            else:
                styles = opts.set == "styles"
                split = cli_json("pane", pane, "split", "--right", *([] if styles else ["--focus"]))
                say("split", json.dumps(split)[:200])
                time.sleep(1.0)  # capture harness: the split lands and its prompt draws
                # content: the first pane, now unfocused, marked unread: its ring shows beside the focused new pane.
                # styles: the new trailing pane, unfocused, marked unread: its ring meets the window's (or card's) corner.
                tab = tab_of_terminal((find_key(split, "terminal_id") or find_key(split, "content_id") or find_key(split, "pane_id")) if styles else term) or {}
                say("mark", json.dumps(cli_json("tab", tab.get("id", term), "update", "--marked-unread", "true"))[:200])
            wait(lambda: rings(), 5)
            time.sleep(1.2)  # capture harness: the ring's entrance ends
            name = f"{opts.label}-{scene}-{theme}"
            path = os.path.join(OUT, f"{name}.png")
            shot = rpc("debug.window_snapshot", {"kind": "main", "path": path, "webviews": False}, timeout=60)
            layers = rpc("debug.layers") or {}
            report[name] = {"shot": os.path.exists(path), "snapshot": shot, "attention": sorted(rings()),
                            "rings": [p.get("rings") for w in layers.get("windows", []) for p in w.get("planes", [])],
                            "pane_chrome": rpc("debug.pane_chrome")}
            say("shot", name, os.path.exists(path))
finally:
    with open(os.path.join(OUT, f"{opts.label}-rings.json"), "w") as f:
        json.dump(report, f, indent=1, default=str)
    rpc("debug.quit", {"fixture_quit": "end-sessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()
