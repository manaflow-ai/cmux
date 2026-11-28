#!/usr/bin/env python3
"""T2 of cx-kvmz (cx-0q7o slice 2e): remote approvals on a Cloud machine of the app server
link, in a tagged cmux-next app on the GUI host (cmux-lawrence-2, `nx-remote --needs gui`).

The app runs with CMUX_NEXT_CLOUD_LINK=app against the DEVELOPMENT API Worker
(CMUX_NEXT_FEED_API_URL), signed in as the agent account only (CMUX_AUTH_CREDENTIALS_FILE, a
0600 file with CMUX_UITEST_STACK_*, and CMUX_DEV_AUTH_ACCOUNT, so no other account signs in).
The machine was readied by acpmux-app-approvals-t2-machine.py (acpmux's test agent as the
harness `fake`, no real model). Checks, as a person does them:
1. a chat on the machine with the fake harness; `ask:` makes the agent request permission;
2. Allow is refused by the machine's daemon (no key of this app): the "Remote approvals are
   off" notice shows, with Restart with approvals, and the agent got no answer;
3. Restart with approvals (the notice's button) goes through the API Worker's keyed start and
   person_holds; the notice goes away;
4. the next permission's Allow counts: the agent answers "chose yes".
The app is started by its executable from this job and ended by exact pid; it never touches
another cmux window.

  acpmux-app-approvals-t2-gui.py --app <cmux DEV tag.app> --tag <tag> --machine vm_... [--creds <0600 file>] [--account <email>]
Writes NX_ARTIFACTS/t2.json, app.log and window snapshots.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--app", required=True)
ap.add_argument("--tag", required=True)
ap.add_argument("--machine", required=True)
ap.add_argument("--creds", default=os.path.expanduser("~/.secrets/cmuxterm-dev.env"), help="a 0600 file with CMUX_UITEST_STACK_* (default: the host's ~/.secrets/cmuxterm-dev.env)")
ap.add_argument("--account", help="the agent account email (default: CMUX_UITEST_STACK_EMAIL of --creds)")
ap.add_argument("--worker", default="https://cmux-api-development.debussy.workers.dev")
opts = ap.parse_args()
_creds = os.lstat(opts.creds)
if not __import__("stat").S_ISREG(_creds.st_mode) or _creds.st_uid != os.getuid() or _creds.st_mode & 0o077:
    sys.exit(f"refusing {opts.creds}: the credentials file must be a regular file of this user with no group or other access")
if not opts.account:
    opts.account = next((l.split("=", 1)[1].strip().strip("'\"") for l in open(opts.creds) if l.strip().removeprefix("export ").startswith("CMUX_UITEST_STACK_EMAIL=")), "")
if opts.worker != "https://cmux-api-development.debussy.workers.dev":
    sys.exit("development Worker only")
OUT = os.environ.get("NX_ARTIFACTS") or f"/tmp/kvmz-t2-{os.getpid()}"
os.makedirs(OUT, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
STEPS = []


def say(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


def record(step, ok, detail):
    STEPS.append({"step": step, "ok": bool(ok), "detail": detail})
    say(f"{'PASS' if ok else 'FAIL'} {step} :: {detail}")
    with open(os.path.join(OUT, "t2.json"), "w") as f:
        json.dump({"machine": opts.machine, "tag": opts.tag, "steps": STEPS}, f, indent=2)


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=1.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def pane(pane_id, action, **params):
    r = rpc("debug.agent_pane", {"action": action, "pane": pane_id, **params}, timeout=40)
    if isinstance(r, dict) and isinstance(r.get("result"), str):
        try:
            r = dict(r, result=json.loads(r["result"]))
        except ValueError:
            pass
    return r


def topology():
    snap = rpc("snapshot.get") or {}
    return (snap.get("topology") or snap) if isinstance(snap, dict) else {}


def panes_of(workspace):
    found = {}
    for ws in topology().get("workspaces", []):
        if ws.get("id") == workspace:
            for screen in ws.get("screens", []):
                for p in screen.get("panes", []):
                    found[p.get("id")] = [t.get("kind") for t in p.get("tabs", [])]
    return found


def snapshot(name):
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, f"{name}.png")})


def transcript_text(state):
    return "\n".join(str(item.get("text", "")) for item in (state or {}).get("transcript", []) if isinstance(item, dict))


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown

# This tag's own daemon state of earlier runs is moved aside, so each run starts clean.
TAG_STATE = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{opts.tag}")
if os.path.isdir(TAG_STATE) and not os.path.islink(TAG_STATE):
    os.rename(TAG_STATE, TAG_STATE + ".old-" + str(int(time.time())))
# Short: acpmux puts unix sockets under its home, and a socket path over 104 bytes traps NWConnection.
HOME_ACP = f"/tmp/kvmz-acp-home-{os.getpid()}"
ACP_SOCKET = f"/tmp/kvmz-acp-{os.getpid()}.sock"
os.makedirs(HOME_ACP, mode=0o700, exist_ok=True)
os.chmod(HOME_ACP, 0o700)
with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    info = plistlib.load(f)
BINARY = os.path.join(opts.app, "Contents/MacOS", info["CFBundleExecutable"])
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(OUT, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = dict(os.environ)
env.update({"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1300,860", "CMUX_NEXT_CONFIG_FILE": config,
            "CMUX_NEXT_CLOUD_LINK": "app", "CMUX_NEXT_FEED_API_URL": opts.worker,
            "CMUX_AUTH_CREDENTIALS_FILE": opts.creds, "CMUX_DEV_AUTH_ACCOUNT": opts.account, "CMUX_DEV_AUTH_PROFILE": "agent",
            "ACPMUX_HOME": HOME_ACP, "ACPMUX_SOCKET": ACP_SOCKET})
TEARDOWN = TagTeardown(opts.app, acpmux_home=HOME_ACP, acpmux_socket=ACP_SOCKET, log=say)
TEARDOWN.install()
app_log = open(os.path.join(OUT, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=app_log, stderr=app_log, stdin=subprocess.DEVNULL)
say("started app pid", app.pid)
try:
    up = wait(lambda: "error" not in (rpc("debug.focus", timeout=5) or {"error": 1}), 120, 2)
    record("tagged app up (debug socket answers)", up, SOCKET)
    if not up:
        sys.exit(1)
    auth = wait(lambda: (lambda s: s if isinstance(s, dict) and s.get("signed_in") else None)(rpc("auth.status")), 120, 2) or {}
    record("signed in as the agent account only", (auth.get("email") or "").lower() == opts.account.lower(), f"email matches: {(auth.get('email') or '').lower() == opts.account.lower()}, team {auth.get('team_id')}, backend {auth.get('backend')}")
    if (auth.get("email") or "").lower() != opts.account.lower():
        sys.exit(1)

    def machine_ready():
        listed = rpc("cloud.machines") or {}
        m = next((x for x in listed.get("machines", []) if x.get("id") == opts.machine), None)
        return m if m and m.get("status") == "running" else None
    machine = wait(machine_ready, 180, 3)
    record("the app server lists the machine, running", machine, json.dumps(machine)[:300] if machine else json.dumps(rpc("cloud.machines"))[:400])
    if not machine:
        sys.exit(1)

    before = {ws.get("id") for ws in topology().get("workspaces", [])}
    opened = rpc("action.run", {"action": "cloudOpenMachine", "target": f"machine:{opts.machine}", "focus": True})
    workspace = wait(lambda: next((ws.get("id") for ws in topology().get("workspaces", []) if ws.get("id") not in before), None), 120, 2)
    term_pane = wait(lambda: next(iter(panes_of(workspace)), None), 60, 2) if workspace else None
    record("a workspace on the machine", term_pane, f"open {json.dumps(opened)[:160]}; workspace {workspace}; panes {panes_of(workspace) if workspace else {}}")
    if not term_pane:
        sys.exit(1)
    snapshot("01-machine-workspace")

    submitted = rpc("action.run", {"action": "newTab.submit", "target": f"pane:{term_pane}", "args": {"text": "hello from kvmz t2", "agent": "fake"}, "focus": True})

    def chat():
        for p in panes_of(workspace):
            s = pane(p, "chat_state")
            if isinstance(s, dict) and "error" not in s and s.get("sessionId"):
                return p, s
        return None
    found = wait(chat, 120, 2)
    record("a chat on the machine with the fake harness", found, f"submit {json.dumps(submitted)[:200]}; " + (json.dumps({k: found[1].get(k) for k in ("connection", "sessionId", "harness")}) if found else json.dumps({p: pane(p, "chat_state") for p in panes_of(workspace)})[:600]))
    if not found:
        snapshot("02-no-chat")
        sys.exit(1)
    chat_pane = found[0]

    def ask(word):
        pane(chat_pane, "send_prompt", text=f"ask: {word}")
        return wait(lambda: (lambda s: s if (s or {}).get("permission") else None)(pane(chat_pane, "chat_state")), 60, 1)
    asked = ask("first")
    record("the agent asks for permission", asked, json.dumps((asked or {}).get("permission"))[:300])
    if not asked:
        sys.exit(1)
    clicked = pane(chat_pane, "click", text="Allow")
    notice = wait(lambda: (lambda r: r if (r or {}).get("notice") else None)(pane(chat_pane, "remote_approvals")), 30, 1) or {}
    state = pane(chat_pane, "chat_state")
    off = any("Remote approvals are off" in line for line in notice.get("notice") or [])
    record("Allow refused: 'Remote approvals are off' with Restart with approvals, and the agent got no answer",
           off and notice.get("restart") and "chose" not in transcript_text(state),
           f"click {json.dumps(clicked)[:120]}; notice {notice.get('notice')}; restart {notice.get('restart')}; transcript has 'chose': {'chose' in transcript_text(state)}")
    snapshot("03-approvals-off")
    if not off:
        sys.exit(1)

    pressed = pane(chat_pane, "remote_approvals", press=True)
    gone = wait(lambda: (lambda r: r if isinstance(r, dict) and "error" not in r and r.get("notice") is None else None)(pane(chat_pane, "remote_approvals")), 150, 2)
    after = pane(chat_pane, "remote_approvals")
    record("Restart with approvals: keyed start and person_holds through the API Worker; the notice goes away",
           gone, f"pressed {pressed.get('pressed') if isinstance(pressed, dict) else pressed}; after {json.dumps(after)[:300]}")
    snapshot("04-after-restart")
    if not gone:
        sys.exit(1)

    # The restart replaced the machine's acpmux run; the chat reconnects to the new run (or a new chat starts).
    asked = ask("second")
    if not asked:
        rpc("action.run", {"action": "newTab.submit", "target": f"pane:{term_pane}", "args": {"text": "hello again", "agent": "fake"}, "focus": True})
        again = wait(lambda: next(((p, s) for p in panes_of(workspace) if p != chat_pane for s in [pane(p, "chat_state")] if isinstance(s, dict) and s.get("sessionId")), None), 120, 2)
        if again:
            chat_pane = again[0]
            asked = ask("second")
    record("the agent asks again after the restart", asked, json.dumps((asked or {}).get("permission"))[:300])
    if not asked:
        sys.exit(1)
    clicked = pane(chat_pane, "click", text="Allow")
    counted = wait(lambda: (lambda s: s if "chose yes" in transcript_text(s) and not s.get("permission") else None)(pane(chat_pane, "chat_state")), 60, 1)
    notice = pane(chat_pane, "remote_approvals")
    record("the next Allow counts: the agent answers 'chose yes', no notice", counted and (notice or {}).get("notice") is None,
           f"click {json.dumps(clicked)[:120]}; last {(counted or {}).get('lastAssistant')!r}; notice {json.dumps(notice)[:200]}")
    snapshot("05-allow-counted")
finally:
    try:
        rpc("debug.quit", timeout=5)
        app.wait(timeout=20)
    except Exception:
        pass
    if app.poll() is None:
        app.terminate()  # this job's own app, by its exact pid
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()
    say("app ended", app.returncode)
    TEARDOWN.end()
sys.exit(0 if STEPS and all(s["ok"] for s in STEPS) else 1)
