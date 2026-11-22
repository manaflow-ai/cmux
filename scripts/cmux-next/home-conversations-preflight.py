#!/usr/bin/env python3
#!/usr/bin/env python3
"""Home page conversation list preflight (plans/cmux-next/home-mac.md 7) on
a lab Mac (cmux-lawrence-2 only), against staging.

Launches the tagged app (no-activate, scratch config) with an explicit
profile and the account it must sign in as, and stops before any write
unless `auth.status` names that account (dev_account_guard). Then drives
every advertised path through the debug socket: the Home page and its list,
New Message (sheet), a DM invite, a group of two invites, a refused DM
(not_reachable), New Chief, Archive Chief, and Invite (sheet). Screenshots
each. Kills only the app it started.

Invites go only to plus-addresses of the expected account's own mailbox
(`--invite-base lawrence@manaflow.ai` gives lawrence+hmdm-...@manaflow.ai),
each address once.

Usage: home-conversations-preflight.py --tag T --app PATH --out DIR
         --profile personal|agent --expected-account EMAIL --invite-base EMAIL
         [--credentials-file FILE]
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dev_account_guard  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--profile", required=True, choices=["personal", "agent"])
parser.add_argument("--expected-account", required=True)
parser.add_argument("--invite-base", required=True)
parser.add_argument("--credentials-file", default=None)
parser.add_argument("--read-only", action="store_true", help="stop after the signed-in Home page screenshot (no writes)")
parser.add_argument("--visual", action="store_true",
                    help="with --read-only: dark and light shots, divider drag and double-click reset, "
                         "Cmd-Shift-[ / ] on Home and off Home (no cloud writes)")
opts = parser.parse_args()
APP, OUT, TAG = opts.app, opts.out, opts.tag
LOCAL, DOMAIN = opts.invite_base.split("@", 1)
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
os.makedirs(OUT, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix=f"hmdm-{TAG}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")
STAMP = time.strftime("%H%M%S")
results = {}


def rpc(method, params=None, timeout=60):
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
    except Exception as error:  # noqa: BLE001
        return {"error": str(error)}


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        try:
            if predicate():
                return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(step)
    return False


def shot(name):
    print(name, rpc("debug.window_snapshot", {"path": os.path.join(OUT, f"{name}.png")}).get("ok"), flush=True)


def screen(name):
    sheet = page().get("sheet")
    params = {"path": os.path.join(OUT, f"{name}-sheet.png")}
    if sheet is not None:
        params["window"] = sheet
    print(name, "sheet", sheet, rpc("debug.window_snapshot", params).get("ok"), flush=True)


def page():
    reply = rpc("debug.home")
    return ((reply.get("result") or {}).get("page")) or {}


def run(action, **args):
    reply = rpc("action.run", {"id": action, "arguments": args, "focus": True, "wait": True}, timeout=90)
    print(action, json.dumps(args), "->", json.dumps(reply)[:400], flush=True)
    results[f"{action} {json.dumps(args)}"] = reply
    return reply


def rows():
    return [line for line in page().get("lines", []) if "id" in line]


def headers():
    return [line["header"] for line in page().get("lines", []) if "header" in line]


def sidebar():
    return page().get("sidebar") or {}


def visual():
    """Appearance, divider and scoped-shortcut checks on the never-key test window."""
    for mode in ("dark", "light"):
        print("appearance", mode, rpc("debug.appearance", {"mode": mode}).get("ok"), flush=True)
        time.sleep(1.5)
        shot(f"10-home-{mode}")
    rpc("debug.appearance", {"mode": "dark"})
    # The divider as the app reports it (debug.home sidebar: window id, divider frame in window points).
    bar = sidebar()
    win, divider = bar.get("window"), bar.get("divider") or {}
    start = bar.get("width") or 0
    x = divider.get("x", start) + divider.get("width", 1) / 2
    y = divider.get("y", 0) + divider.get("height", 800) / 2
    print("divider", json.dumps({"window": win, "frame": divider, "width": start}), flush=True)
    drag = rpc("debug.mouse", {"window": win, "x": x, "y": y, "action": "drag", "to_x": x + 120, "to_y": y, "steps": 12})
    time.sleep(1)
    dragged = sidebar().get("width")
    shot("11-divider-dragged")
    moved_x = (sidebar().get("divider") or {}).get("x", x) + divider.get("width", 1) / 2
    reset = rpc("debug.mouse", {"window": win, "x": moved_x, "y": y, "action": "double_click"})
    time.sleep(1)
    after = sidebar().get("width")
    results["divider"] = {"window": win, "start": start, "dragged": dragged, "after_double_click": after,
                          "drag_ok": drag.get("ok"), "reset_ok": reset.get("ok")}
    reset_x = (sidebar().get("divider") or {}).get("x", x) + divider.get("width", 1) / 2
    rpc("debug.mouse", {"window": win, "x": reset_x, "y": y, "action": "drag", "to_x": 20, "to_y": y, "steps": 12})
    time.sleep(1)
    results["divider"]["narrowest"] = sidebar().get("width")
    shot("12-divider-compact")
    compact_x = (sidebar().get("divider") or {}).get("x", 76) + divider.get("width", 1) / 2
    rpc("debug.mouse", {"window": win, "x": compact_x, "y": y, "action": "double_click"})
    time.sleep(1)
    results["divider"]["restored"] = sidebar().get("width")
    print("divider", json.dumps(results["divider"]), flush=True)
    # Cmd-Shift-] / [ move between conversations on Home only.
    before = page().get("shown")
    nxt = rpc("debug.key", {"window": win, "key": "]", "modifiers": ["cmd", "shift"]})
    time.sleep(1.5)
    moved = page().get("shown")
    rpc("debug.key", {"window": win, "key": "[", "modifiers": ["cmd", "shift"]})
    time.sleep(1.5)
    back = page().get("shown")
    shot("13-home-after-shortcuts")
    run("workspace.selectFirst")
    time.sleep(1.5)
    rpc("debug.key", {"window": win, "key": "]", "modifiers": ["cmd", "shift"]})
    time.sleep(1.5)
    off_home = page().get("shown")
    shot("14-off-home-after-shortcut")
    results["shortcuts"] = {"before": before, "after_next": moved, "after_previous": back,
                            "off_home_shown": off_home, "next_ok": nxt.get("ok")}
    print("shortcuts", json.dumps(results["shortcuts"]), flush=True)
    run("home.show")
    time.sleep(1)


app = None
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,760",
           **dev_account_guard.launch_environment(opts.profile, opts.expected_account)}
    if opts.credentials_file:
        env["CMUX_AUTH_CREDENTIALS_FILE"] = opts.credentials_file
    log = open(os.path.join(OUT, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and rpc("debug.surfaces").get("ok"), 180):
        sys.exit("the tagged app did not come up")
    time.sleep(5)
    print("windows:", (rpc("debug.surfaces").get("result") or {}).get("windows"), flush=True)
    run("newWindow")
    wait(lambda: (rpc("debug.surfaces").get("result") or {}).get("windows"), 30)
    print("windows:", (rpc("debug.surfaces").get("result") or {}).get("windows"), flush=True)
    run("home.show")
    # No write before the app is signed in as the expected account.
    account = dev_account_guard.require_account(lambda m, p: rpc(m, p).get("result") or {}, opts.expected_account, timeout=120)
    print("signed in as", dev_account_guard.mask(account.get("email")), flush=True)
    signed_in = wait(lambda: page().get("online") and page().get("me"), 90)
    print("online:", signed_in, json.dumps(page())[:600], flush=True)
    wait(lambda: len(rows()) > 0, 60)
    time.sleep(3)
    shot("01-home-page-list")
    if opts.read_only:
        if opts.visual:
            visual()
        json.dump({"page": page(), "results": results}, open(os.path.join(OUT, "preflight.json"), "w"), indent=1, default=str)
        sys.exit(0)
    # New Message sheet (no arguments: the sheet over the Home page).
    run("home.newMessage")
    time.sleep(1.5)
    shot("02-new-message-sheet")
    screen("02-new-message-sheet")
    # A DM invite to a plus-address of the expected account (each address once).
    run("home.newMessage", to=f"{LOCAL}+hmdm-invite-{STAMP}@{DOMAIN}")
    wait(lambda: "invited" in headers(), 30)
    time.sleep(1)
    shot("03-dm-invite-in-invited-section")
    # A group of two plus-addresses.
    run("home.newMessage", to=f"{LOCAL}+hmdm-a-{STAMP}@{DOMAIN}, {LOCAL}+hmdm-b-{STAMP}@{DOMAIN}", title=f"Preflight group {STAMP}")
    time.sleep(4)
    shot("04-group-created")
    # Someone the account cannot reach: the owner refuses (not_reachable), the caller hears why.
    run("home.newMessage", to="user_hmdmnobody000000000000000")
    # New Chief twice: the first Chief is the default, which the owner never archives.
    run("home.newChief", name=f"Scratch {STAMP}")
    run("home.newChief", name=f"Research {STAMP}")
    wait(lambda: any(c.get("name") == f"Research {STAMP}" for c in page().get("chiefs", [])), 30)
    wait(lambda: any(r.get("title") == f"Research {STAMP}" for r in rows()), 60)
    time.sleep(2)
    shot("05-new-chief")
    chief = next((c for c in page().get("chiefs", []) if c.get("name") == f"Research {STAMP}"), None)
    if chief:
        run("home.archiveChief", chief=chief["id"])
        wait(lambda: not any(r.get("title") == f"Research {STAMP}" for r in rows()), 30)
        time.sleep(1)
        shot("06-chief-archived")
    # Invite sheet with the pending invites.
    run("home.invite")
    time.sleep(1.5)
    shot("07-invite-sheet")
    screen("07-invite-sheet")
    final = page()
    json.dump({"page": final, "results": results}, open(os.path.join(OUT, "preflight.json"), "w"), indent=1)
    print("headers:", headers(), flush=True)
finally:
    if app:
        app.terminate()
        try:
            app.wait(10)
        except subprocess.TimeoutExpired:
            app.kill()
        print(f"stopped {app.pid}", flush=True)
