#!/usr/bin/env python3
"""Pictures of a floating pane with the Debug Settings knob `Background opacity` (floatingPane.backgroundOpacity)
at 1 and below 1, on a tagged cmux-next build. A record for a person to look at: nothing here judges a picture.

No action and no key of the app makes a pane float: only a client of the daemon that sends `float-pane`
(capability `floating-panes-v1`). So this driver is that client. It starts the tagged app with a scratch
cmux.json, an empty Ghostty config and a scratch file for the Debug Settings values, and then:

  1. opens a workspace of its own, prints text in its terminal pane and splits it (`splitRight`);
  2. finds the new pane's id in the daemon's `list-workspaces` (the id that was not there before the split) and
     sends `float-pane` with `mode: "on"` and a frame, on the daemon's socket;
  3. takes the app's own picture of its window (`debug.window_snapshot`: no Screen Recording grant) for each state:
       01 terminal, knob 1            02 terminal, knob below 1
       03 terminal, knob below 1, with a background picture (`appearance.background`, a PNG this driver writes)
       04 terminal, knob 1, with the background picture
       05 page (a Chromium tab opened in the focused pane), knob below 1, with the background picture
       06 page, knob below 1, no background picture
  4. puts the pane back, closes its workspace, quits the app and ends the tag's daemon.

report.json has each reply (the float request's, each knob set, each snapshot), the screen's `floating` list from
the daemon, and `debug.pane_chrome` (the window's scale and each shown pane's frame, to find the card in a picture).

Usage: floating-pane-look.py --tag TAG --app PATH/TO/TAGGED.app --out DIR [--opacity 0.5]
Exit: 0 when report.json and at least 1 picture are written (also when a later step failed: the report says which);
3 when no picture was written.

       floating-pane-look.py --tag TAG --daemon-only PATH/TO/cmux-tui
The daemon's calls of step 2 alone, on a daemon that this starts with no app and no display (no picture, no
report): floating-pane-look-daemon.sh runs it before a display step. Exit: 0 when each call answered, else 1.
"""
import argparse
import glob
import hashlib
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--tag", required=True)
parser.add_argument("--app", default="")
parser.add_argument("--out", default="")
parser.add_argument("--opacity", type=float, default=0.5)
parser.add_argument("--daemon-only", metavar="CMUX_TUI", help="only the daemon's calls, on a daemon of this binary")
opts = parser.parse_args()
if not opts.daemon_only and not (opts.app and opts.out):
    parser.error("--app and --out are needed (or --daemon-only CMUX_TUI)")
TAG, APP, OUT = opts.tag, os.path.abspath(opts.app.rstrip("/")), os.path.abspath(opts.out)
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
KNOB = "floatingPane.backgroundOpacity"
FRAME = {"x": 0.3, "y": 0.15, "w": 0.5, "h": 0.6}
TILED_TEXT = "clear; for i in $(seq 1 45); do echo \"TILED-$i " + "#" * 150 + "\"; done\r"
FLOAT_TEXT = "clear; for i in 1 2 3; do echo \"FLOATING PANE TEXT $i\"; done\r"
PAGE = "<!doctype html><title>floating pane look</title><h1>FLOATING PAGE PANE</h1><p>A page in a floating pane.</p>\n"
REPORT = {"tag": TAG, "host": os.uname().nodename, "opacity": opts.opacity, "frame": FRAME, "steps": [], "pictures": []}
STATE = {"scratch": None, "app": None, "workspace_open": False, "pane": None, "stopping": False}


def line_json(path, request, timeout=30):
    """One line-JSON request on a unix socket and its reply line; an error is a dict with `error`."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall((json.dumps(request) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def rpc(method, params=None, timeout=30):
    """One request on the app's control socket."""
    reply = line_json(SOCKET, {"id": 1, "method": method, "params": params or {}}, timeout)
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def daemon_paths():
    """Where the tag's daemon can listen: `<temp>/cmux-tui-<uid>/<session>.sock` for each temp folder, the app's own
    TMPDIR first, then the folders for a path that is too long for a socket: `<temp>/cmux-tui-hashed-<uid>/<sha256 of
    the session>.sock` (the same names as `session_socket_path` of bench-startup.py)."""
    session, uid = f"cmux-app-{TAG}", os.getuid()
    darwin = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    temps = [t for t in (os.environ.get("TMPDIR"), darwin, "/tmp", "/private/tmp") if t]
    hashed = hashlib.sha256(session.encode()).hexdigest() + ".sock"
    return ([os.path.join(t, f"cmux-tui-{uid}", session + ".sock") for t in temps]
            + [os.path.join(t, f"cmux-tui-hashed-{uid}", hashed) for t in temps])


def daemon(request, timeout=30):
    """One request on the socket of the tag's daemon; the first candidate path that exists is used. The reply is the
    line with the request's id: a line with another id, or an event, is passed over."""
    paths = daemon_paths()
    path = next((p for p in paths if os.path.exists(p)), None)
    if not path:
        folders = [os.path.dirname(p) for p in paths]
        seen = sorted({n for f in folders if os.path.isdir(f) for n in os.listdir(f)})
        there = ", ".join(seen) or "nothing"
        return {"error": "no daemon socket at " + ", ".join(paths) + "; in those folders: " + there}
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall((json.dumps(dict(request, id=1)) + "\n").encode())
        buf = b""
        while True:
            while b"\n" not in buf:
                chunk = conn.recv(1 << 20)
                if not chunk:
                    conn.close()
                    return {"error": "the daemon closed the connection before its reply"}
                buf += chunk
            line, buf = buf.split(b"\n", 1)
            value = json.loads(line)
            if isinstance(value, dict) and value.get("id") == 1 and "event" not in value:
                conn.close()
                return value
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def step(name, reply):
    """Keeps a reply in the report (as text, cut to 4,000 characters, when it is longer) and gives it back."""
    text = json.dumps(reply, default=str)
    REPORT["steps"].append({"step": name, "reply": reply if len(text) <= 4000 else text[:4000]})
    print(f"FLOATING-PANE-LOOK {name}: {text[:300]}", flush=True)
    return reply


def action(name, args=None):
    return step(f"action {name}", rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"},
                                      timeout=60))


def wait(check, seconds, pause=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(pause)  # test script: a poll of the app's or the daemon's state
    return None


def app_panes():
    return [p for w in ((rpc("debug.surfaces") or {}).get("windows") or []) for p in w.get("panes", [])]


def screens():
    tree = daemon({"cmd": "list-workspaces"})
    return [s for w in ((tree.get("data") or {}).get("workspaces") or []) for s in w.get("screens") or []]


def pane_ids():
    return {p.get("id") for s in screens() for p in s.get("panes") or [] if p.get("id") is not None}


def scratch():
    if not STATE["scratch"]:
        os.makedirs(OUT, exist_ok=True)
        STATE["scratch"] = tempfile.mkdtemp(prefix=f"floating-pane-look-{TAG}-", dir=OUT)  # the driver's own, below --out
        open(os.path.join(STATE["scratch"], "ghostty"), "w").close()
        open(os.path.join(STATE["scratch"], "cmux.json"), "w").write("{}\n")
        open(os.path.join(STATE["scratch"], "debug-tunables.json"), "w").write('{"version": 1, "values": {}}\n')
        open(os.path.join(STATE["scratch"], "page.html"), "w").write(PAGE)
    return STATE["scratch"]


def write_png(path, width=640, height=400):
    """A background picture with a color for each place: red grows to the right, green grows down, blue in squares."""
    rows = b"".join(b"\x00" + bytes(c for x in range(width) for c in (
        x * 255 // width, y * 255 // height, 200 if (x // 40 + y // 40) % 2 else 40)) for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


def launch():
    if not BINARY:
        stop(3, f"no binary in {APP}")
    if os.path.exists(SOCKET):
        ps = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout
        if any(line.startswith(APP + "/Contents/MacOS/") for line in ps.splitlines()):
            stop(3, f"{SOCKET} exists and a {TAG} app runs; pick a fresh tag")
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch(), "cmux.json"),
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch(), "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900",
           "CMUX_NEXT_DEBUG_TUNABLES_FILE": os.path.join(scratch(), "debug-tunables.json")}
    log = open(os.path.join(OUT, f"app-{TAG}.log"), "a")
    STATE["app"] = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        stop(3, "the tagged app did not come up")
    time.sleep(2)  # test script: the first workspace


def knob(value):
    """Sets the knob (None = its default, 1) and keeps the row that the app answers."""
    step(f"knob {value}", rpc("debug.tunables", {"action": "set", "key": KNOB, "value": value}))


def picture(name, kind, value, background):
    time.sleep(2.5)  # test script: the config reload, the layout and the paint end before the picture
    path = os.path.join(OUT, name + ".png")
    reply = step(f"picture {name}", rpc("debug.window_snapshot", {"path": path}, timeout=60))
    REPORT["pictures"].append({"name": name, "kind": kind, "knob": value, "background_picture": background,
                               "written": os.path.exists(path), "snapshot": reply})


def cleanup():
    app = STATE["app"]
    if app:
        if STATE["pane"] is not None:
            daemon({"cmd": "float-pane", "pane": STATE["pane"], "mode": "off"}, timeout=10)
        rpc("debug.tunables", {"action": "set", "key": KNOB, "value": None}, timeout=10)
        if STATE["workspace_open"]:
            # The look's workspace must not come back at the tag's next start.
            rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "focus": True, "origin": "script"},
                timeout=10)
        rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                os.kill(app.pid, signal.SIGKILL)
                app.wait(timeout=10)
            except (OSError, subprocess.SubprocessError):
                pass
        STATE["app"] = None
    try:
        subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                       env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        pass
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def stop(code, reason=None):
    if STATE["stopping"]:
        sys.exit(code)
    STATE["stopping"] = True
    if reason:
        REPORT["stopped"] = reason
        print(f"FLOATING-PANE-LOOK STOPPED: {reason}", flush=True)
    try:
        cleanup()
    except Exception as error:
        REPORT["cleanup_failed"] = repr(error)
    finally:
        if STATE["scratch"]:
            shutil.rmtree(STATE["scratch"], ignore_errors=True)
        made = sum(1 for p in REPORT["pictures"] if p["written"])
        REPORT["pictures_written"] = made
        os.makedirs(OUT, exist_ok=True)
        open(os.path.join(OUT, "report.json"), "w").write(json.dumps(REPORT, indent=1, default=str))
        print(f"FLOATING-PANE-LOOK pictures={made} of 6 stopped={REPORT.get('stopped')}", flush=True)
    sys.exit(0 if made else 3)


def main():
    signal.signal(signal.SIGTERM, lambda *_: stop(3, "SIGTERM"))
    launch()
    step("knob store", rpc("debug.tunables", {"action": "activate"}))
    earlier = {p.get("workspace") for p in app_panes()}
    action("newTab", {"name": "floating-pane-look"})
    STATE["workspace_open"] = True
    came = wait(lambda: any(p.get("focused") and p.get("kind") == "terminal" and p.get("workspace") not in earlier
                            for p in app_panes()), 30)
    step("the look's terminal pane came", bool(came))
    time.sleep(1.5)  # test script: the shell starts
    action("terminal.sendText", {"text": TILED_TEXT})
    before = pane_ids()
    step("daemon pane ids before the split", sorted(before, key=str))
    if not before:
        stop(3, f"the daemon gave no pane id: {json.dumps(daemon({'cmd': 'list-workspaces'}), default=str)[:300]}")
    action("splitRight")
    new = wait(lambda: sorted(pane_ids() - before, key=str), 30)
    if not new:
        stop(3, f"no new pane id in the daemon's list after the split (before: {len(before)} ids)")
    pane = new[0]
    time.sleep(1.5)  # test script: the new pane's shell starts
    action("terminal.sendText", {"text": FLOAT_TEXT})
    reply = step("float-pane on", daemon(dict({"cmd": "float-pane", "pane": pane, "mode": "on"}, **FRAME)))
    if not reply.get("ok"):
        stop(3, f"the daemon refused float-pane: {json.dumps(reply)[:300]}")
    STATE["pane"] = pane
    floating = wait(lambda: next((s.get("floating") for s in screens() if s.get("floating")), None), 10)
    step("the screen's floating list", floating)
    time.sleep(1.0)  # test script: the app shows the card
    chrome = rpc("debug.pane_chrome") or {}
    keys = ("pane", "cell", "border", "first_cell")
    REPORT["windows"] = [{"scale": w.get("scale"), "main_pane": w.get("main_pane"),
                          "panes": [{k: p.get(k) for k in keys} for p in w.get("panes") or []]}
                         for w in chrome.get("windows") or []]
    knob(None)
    picture("01-terminal-knob-1", "terminal", 1, False)
    knob(opts.opacity)
    picture("02-terminal-knob-below-1", "terminal", opts.opacity, False)
    art = os.path.join(scratch(), "background.png")
    write_png(art)
    step("background picture on", rpc("settings.set", {"path": "appearance.background", "value": "file:" + art}))
    picture("03-terminal-picture-knob-below-1", "terminal", opts.opacity, True)
    knob(None)
    picture("04-terminal-picture-knob-1", "terminal", 1, True)
    knob(opts.opacity)
    action("openBrowser.chromium", {"url": "file://" + os.path.join(scratch(), "page.html")})
    time.sleep(4)  # test script: the page loads and paints
    step("app panes after the page", [{k: v for k, v in p.items() if isinstance(v, (str, int, float, bool))}
                                      for p in app_panes()])
    picture("05-page-picture-knob-below-1", "page", opts.opacity, True)
    step("background picture off", rpc("settings.unset", {"path": "appearance.background"}))
    picture("06-page-knob-below-1", "page", opts.opacity, False)
    stop(0)


def daemon_only(binary):
    """The look's calls on the daemon with no app and no display: a daemon of the tag alone on its own default socket
    (so `daemon_paths` is checked too), a workspace, a split, `float-pane` on, the screen's `floating` list, and off.
    Returns 0 when each call answered as the look needs it, else 1; the lines say which call did not."""
    session, env = f"cmux-app-{TAG}", {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    proc = subprocess.Popen([binary, "--headless", "--session", session], env=env, stdin=subprocess.DEVNULL)
    good = False
    try:
        up = wait(lambda: daemon({"cmd": "list-workspaces"}, timeout=5).get("ok"), 60)
        step("list-workspaces", daemon({"cmd": "list-workspaces"}))
        if up and not pane_ids():
            step("new-workspace", daemon({"cmd": "new-workspace"}))
        before = wait(pane_ids, 10) or set()
        step("daemon pane ids before the split", sorted(before, key=str))
        if before:
            step("split", daemon({"cmd": "split", "pane": sorted(before, key=str)[0], "dir": "right"}))
        new = wait(lambda: sorted(pane_ids() - before, key=str), 10) if before else None
        step("new pane ids after the split", new)
        if new:
            on = step("float-pane on", daemon(dict({"cmd": "float-pane", "pane": new[0], "mode": "on"}, **FRAME)))
            floating = next((s.get("floating") for s in screens() if s.get("floating")), None)
            step("the screen's floating list", floating)
            off = step("float-pane off", daemon({"cmd": "float-pane", "pane": new[0], "mode": "off"}))
            good = bool(on.get("ok") and floating and off.get("ok"))
    finally:
        subprocess.run([binary, "server", "stop", "--session", session, "--end-terminals"], env=env,
                       capture_output=True, timeout=30)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
    print(f"FLOATING-PANE-LOOK daemon-only {'PASS' if good else 'FAIL'}", flush=True)
    return 0 if good else 1


if __name__ == "__main__":
    if opts.daemon_only:
        sys.exit(daemon_only(opts.daemon_only))
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:
        stop(3, f"the driver failed: {error!r}")
