#!/usr/bin/env python3
"""Native Home tab beside the channels Home (bead cx-mmg0, lane cx-59n8) on a
GUI lab Mac (cmux-lawrence-2 only), through the tagged app's debug socket.

Launches the tagged app (no-activate, scratch config), then:
  1. `home.channels` opens the channels Home as a tab (UNVERIFIED when the
     build has no such action yet);
  2. `splitRight` makes a second pane;
  3. `home.tab` opens the native Home as a tab in that pane, and a second
     `home.tab` opens one more Home tab (several Home tabs);
  4. both Home tabs show the same conversation; a message typed and sent in
     one Home tab (`debug.home.drive` with `tab`) shows in the other tab and
     in the store at once (`debug.home` page.tabs, conversations.shown_tail);
  5. window screenshots after each step (the channels tab is checked only on
     the screenshot: its React page has no debug read verb).
Exits 1 when a step fails. Kills only the app it started.

With --expected-account the app signs in as that account first
(dev_account_guard), and no message is sent before `auth.status` names it.

Usage: home-tab-split-preflight.py --tag T --app PATH --out DIR
         [--profile personal|agent --expected-account EMAIL] [--credentials-file FILE]
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dev_account_guard  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--profile", choices=["personal", "agent"], default=None)
parser.add_argument("--expected-account", default=None)
parser.add_argument("--credentials-file", default=None)
opts = parser.parse_args()
BINARY = os.path.join(opts.app, "Contents/MacOS/cmux DEV")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix=f"hometab-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")
TEXT = f"home tab side by side {time.strftime('%H%M%S')}"
results = {"steps": {}}


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


def step(name, ok, detail=None):
    results["steps"][name] = {"ok": ok, "detail": detail}
    print(("PASS " if ok is True else "UNVERIFIED " if ok is None else "FAIL ") + name, json.dumps(detail)[:500], flush=True)


def shot(name):
    print(name, rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}.png")}).get("ok"), flush=True)


def home():
    return rpc("debug.home").get("result") or {}


def tabs():
    return (home().get("page") or {}).get("tabs") or []


def run(action, **args):
    reply = rpc("action.run", {"id": action, "arguments": args, "focus": True, "wait": True}, timeout=90)
    print(action, json.dumps(args), "->", json.dumps(reply)[:400], flush=True)
    return reply


def ran(reply):
    result = reply.get("result") if isinstance(reply.get("result"), dict) else reply
    return not reply.get("error") and result.get("ran") is not False and reply.get("ok") is not False


def shown_texts(conversation):
    for row in home().get("conversations") or []:
        if row.get("id") == conversation:
            return [item.get("text") for item in row.get("shown_tail") or []]
    return []


app = None
failed = False
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1500,860"}
    if opts.expected_account:
        env.update(dev_account_guard.launch_environment(opts.profile or "agent", opts.expected_account))
    if opts.credentials_file:
        env["CMUX_AUTH_CREDENTIALS_FILE"] = opts.credentials_file
    log = open(os.path.join(opts.out, f"app-{opts.tag}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and rpc("debug.surfaces").get("ok"), 180):
        sys.exit("the tagged app did not come up")
    if not (rpc("debug.surfaces").get("result") or {}).get("windows"):
        run("newWindow")
        wait(lambda: (rpc("debug.surfaces").get("result") or {}).get("windows"), 30)
    if opts.expected_account:
        account = dev_account_guard.require_account(lambda m, p: rpc(m, p).get("result") or {}, opts.expected_account, timeout=120)
        print("signed in as", dev_account_guard.mask(account.get("email")), flush=True)
    wait(lambda: home().get("available"), 90)

    # 1. The channels Home as a tab in the first pane.
    channels = run("home.channels")
    step("home.channels opens a tab", True if ran(channels) else None, channels)
    time.sleep(3)
    shot("01-channels-tab")

    # 2-3. A second pane, then the native Home as a tab in it; a second Home tab.
    step("splitRight", ran(run("splitRight")))
    # The CLI's path (`cmux home tab` sends action.run with the CLI name).
    first = rpc("action.run", {"action": "home tab", "cli": True, "focus": True, "wait": True}, timeout=90)
    print("cli home tab ->", json.dumps(first)[:400], flush=True)
    opened = wait(lambda: len(tabs()) >= 1, 30)
    step("home.tab opens a Home tab", ran(first) and opened, {"reply": first, "tabs": tabs()})
    if not opened:
        failed = True
        raise SystemExit
    wait(lambda: tabs()[0].get("shown"), 60)
    time.sleep(2)
    shot("02-channels-and-home-tab-split")
    second = run("home.tab")
    two = wait(lambda: len(tabs()) >= 2, 30)
    step("a second home.tab opens a second Home tab", ran(second) and two, tabs())
    failed |= not two

    # 4. The same conversation in both Home tabs; send in one, it shows in the other.
    listed = tabs()
    conversation = listed[0].get("shown")
    for tab in listed[1:]:
        if tab.get("shown") != conversation:
            rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": conversation}, "focus": True})
    same = wait(lambda: len({t.get("shown") for t in tabs()}) == 1 and tabs()[0].get("shown"), 30)
    step("both Home tabs show one conversation", same, tabs())
    sender = listed[-1].get("key")
    typed = rpc("debug.home.drive", {"tab": sender, "action": "type", "text": TEXT})
    sent = rpc("debug.home.drive", {"tab": sender, "action": "send"})
    step("send in one Home tab", bool((typed.get("result") or {}).get("ok")) and bool((sent.get("result") or {}).get("ok")),
         {"type": typed, "send": sent})
    in_store = wait(lambda: TEXT in shown_texts(conversation), 30)
    step("the store shows the message", in_store, shown_texts(conversation)[-3:])
    others = [t.get("key") for t in tabs() if t.get("key") != sender]
    in_others = wait(lambda: all(TEXT in (t.get("transcript_tail") or []) for t in tabs() if t.get("key") in others), 30)
    step("the other Home tab shows the message", in_others, tabs())
    failed |= not (same and in_store and in_others)
    time.sleep(2)
    shot("03-message-in-both-homes")
    rpc("action.run", {"id": "home.show", "focus": True})
    time.sleep(2)
    shot("04-top-page-home-unchanged")
    step("home.show still shows the top page", (home().get("page") or {}).get("shown") is not None, None)
    # The channels tab shows the message on the screenshot only (no debug read verb for the React page).
    step("channels tab shows the message", None, "screenshot 03-message-in-both-homes.png")
except SystemExit:
    pass
finally:
    json.dump(results, open(os.path.join(opts.out, "home-tab-preflight.json"), "w"), indent=1, default=str)
    if app is not None:
        app.terminate()
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
    print("RESULT", "FAIL" if failed else "PASS", flush=True)
    sys.exit(1 if failed else 0)
