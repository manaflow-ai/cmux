#!/usr/bin/env python3
"""GUI proof of the live Window Style preview in the command palette (Lawrence 2026-10-14:
"dont make me press enter to preview the style, just selecting it should show the style").

Launches the tagged app itself (no activation, a scratch cmux.json with no chromeStyle, an
isolated Chief home) on a GUI host, opens the palette (Cmd-Shift-P) and types "window style"
into it (every key is a `debug.key` into the palette panel; no pane gets typed text). Then:

  preview   each Down moves the selection; when the selected row is a Window Style action,
            the window shows that style at once (`debug.pane_chrome` chrome_style) and
            cmux.json is byte-identical; a non-style row shows the committed style again
  escape    Escape until the palette closes: the committed style is back, cmux.json unchanged
  commit    reopen, select a non-default style, Return: cmux.json has that chromeStyle and the
            window keeps it

Each step writes the palette report, `debug.pane_chrome` and a `debug.window_snapshot` of the
main window to --out. The style table comes from schemas/settings/chrome-styles.json.

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  window-style-preview-live.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/style"
Stop the app afterwards with "$NX_APP_STOP".
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
TABLE = json.load(open(os.path.join(ROOT, "schemas/settings/chrome-styles.json")))
STYLE_OF_ACTION = {f"appearance.chromeStyle.{s['actionName']}": s["id"] for s in TABLE["styles"]}
DEFAULT = TABLE["default"]
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"stylepreview-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
INITIAL_CONFIG = json.dumps({"appearance": {"theme": "Catppuccin Latte"}}, indent=2) + "\n"
failures = []
log = []
step_no = [0]


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    log.append({"ok": bool(ok), "what": what})
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=30):
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
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait(predicate, seconds, step=0.1):
    end = time.time() + seconds
    while time.time() < end:  # test harness: bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def key(name, modifiers=None, target="palette"):
    params = {"key": name, "modifiers": modifiers or []}
    if target:
        params["target"] = target
    return rpc("debug.key", params) or {}


def palette_state():
    """The palette's report for a no-op key (forward delete at the end of the query)."""
    return key("forwarddelete")


def settled():
    state = palette_state()
    return state if state.get("palette_open") and not state.get("palette_ranking") and not state.get("palette_loading") else None


def chrome():
    windows = (rpc("debug.pane_chrome") or {}).get("windows") or []
    return windows[0] if windows else {}


def chrome_style():
    return chrome().get("chrome_style")


def config_text():
    return open(CONFIG).read()


def capture(label, state=None):
    step_no[0] += 1
    name = f"{step_no[0]:02d}-{label}"
    window = chrome()
    record = {"palette": state, "chrome_style": window.get("chrome_style"), "config": config_text()}
    with open(os.path.join(opts.out, f"{name}.json"), "w") as f:
        json.dump(record, f, indent=1)
    shot = rpc("debug.window_snapshot", {"window": window.get("id"), "path": os.path.join(opts.out, f"{name}.png")}) or {}
    print(f"snapshot {name}: style={window.get('chrome_style')} {shot.get('path') or shot}", flush=True)
    return record


def open_palette_with(query):
    key("p", ["command", "shift"], target=None)
    check(bool(wait(lambda: palette_state().get("palette_open"), 10)), "the palette opens")
    for char in query:
        key(char)
    return wait(settled, 10)


def close_palette():
    for _ in range(6):
        if not palette_state().get("palette_open"):
            return True
        key("escape")
    return not palette_state().get("palette_open")


app = None
try:
    with open(CONFIG, "w") as f:
        f.write(INITIAL_CONFIG)
    open(GHOSTTY, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,1100,760"}
    app_log = open(os.path.join(opts.out, "app.log"), "a")
    app = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS/cmux DEV")], env=env, stdout=app_log, stderr=app_log,
                           stdin=subprocess.DEVNULL)
    print("launched pid", app.pid, flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and chrome().get("chrome_style"), 180, 0.25):
        sys.exit("the tagged app did not come up")
    committed = chrome_style()
    check(committed == DEFAULT, f"the committed style is the default ({committed})")
    capture("committed")

    # Preview: walk the rows with Down; every style row shows its style, nothing is written.
    state = open_palette_with("window style")
    check(state is not None, "the palette lists rows for 'window style'")
    seen_styles, left_styles = [], False
    for move in range(len(STYLE_OF_ACTION) + 3):
        state = wait(settled, 10) or palette_state()
        selected = state.get("palette_selected")
        expected = STYLE_OF_ACTION.get(selected, committed)
        record = capture(f"move{move}-{STYLE_OF_ACTION.get(selected, 'other')}", state)
        check(record["chrome_style"] == expected,
              f"move {move}: selected {selected} shows style {expected} (shows {record['chrome_style']})")
        check(record["config"] == INITIAL_CONFIG, f"move {move}: cmux.json is unchanged")
        if selected in STYLE_OF_ACTION:
            seen_styles.append(STYLE_OF_ACTION[selected])
        elif seen_styles:
            left_styles = True
        key("down")
    check(len(set(seen_styles)) >= 2, f"the selection previewed at least two styles ({seen_styles})")
    check(left_styles or len(set(seen_styles)) == len(STYLE_OF_ACTION),
          f"every style was previewed or a non-style row was reached ({seen_styles})")

    # Escape: the committed style is back and nothing was written.
    check(close_palette(), "Escape closes the palette")
    record = capture("after-escape")
    check(record["chrome_style"] == committed, f"after Escape the committed style is back ({record['chrome_style']})")
    check(record["config"] == INITIAL_CONFIG, "after Escape cmux.json is unchanged")

    # Commit: select a non-default style and press Return.
    state = open_palette_with("window style")
    target = None
    for _ in range(len(STYLE_OF_ACTION) + 3):
        state = wait(settled, 10) or palette_state()
        style = STYLE_OF_ACTION.get(state.get("palette_selected"))
        if style and style != committed:
            target = style
            break
        key("down")
    check(target is not None, f"a non-default style row is selectable ({state.get('palette_selected')})")
    capture(f"before-return-{target}", state)
    check(chrome_style() == target, f"the selected row previews {target}")
    key("return")
    written = wait(lambda: (json.loads(config_text()).get("appearance") or {}).get("chromeStyle") == target, 10)
    record = capture(f"after-return-{target}")
    check(bool(written), f"Return writes appearance.chromeStyle = {target} to cmux.json ({record['config'].strip()})")
    check(not palette_state().get("palette_open"), "Return closes the palette")
    check(wait(lambda: chrome_style() == target, 5) is not None, f"the window keeps {target} after the write")
finally:
    if app is not None:
        rpc("action.run", {"action": "quitEndSessions", "args": {}, "focus": False, "origin": "script"})
    with open(os.path.join(opts.out, "summary.json"), "w") as f:
        json.dump({"checks": log, "failures": failures}, f, indent=1)
    print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
