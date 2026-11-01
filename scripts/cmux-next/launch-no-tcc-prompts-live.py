#!/usr/bin/env python3
"""Live check: a launch of cmux NEXT asks for no macOS permission (LAUNCH-NO-TCC-PROMPTS).

  scripts/cmux-next/launch-no-tcc-prompts-live.py --app PATH [--out DIR] [--seconds 45]
      [--phases first,restore] [--folder ~/Downloads]

The rule (Lawrence, 2026-10-30): cmux never asks for a permission at launch. Every permission
(Files and Folders, Contacts, Calendars, Photos, Microphone, Camera, Screen Recording,
Accessibility, Automation, Notifications, Local Network, Bluetooth, Full Disk Access) is asked
only when the person does the thing that needs it.

For each phase the script resets every macOS privacy answer of the app's bundle id
(`tccutil reset All <bundle id>`), streams tccd's log, launches the app through LaunchServices
(`open -n`, so the app is its own responsible process, as when the person opens it from the Dock
or Finder) and leaves it alone for `--seconds`. tccd logs every check a process makes with the
app as its responsible process, whether or not it would prompt (AUTHREQ_CTX, AUTHREQ_ATTRIBUTION,
AUTHREQ_RESULT). A check with `preflight=no` after a reset is a prompt the person would see.

  1. `first`: the first launch of this build (onboarding, Home, the daemons, the agent probes).
  2. `restore`: before it quits, the first phase opens a terminal in `--folder` (default
     ~/Downloads, the folder of the 2026-10-30 report). That is the person's own action, so a
     prompt there is allowed. The relaunch restores that terminal: nothing may read the folder
     until the person shows the terminal. It also leaves an agent chat in `--folder` (acpmux, a
     stand-in agent that lists its folder when it starts, like a real agent) with a turn running
     and a prompt queued: the relaunch's acpmux must not start that agent until the person opens
     the chat (cmux-tui/crates/acpmux/src/hub/protected_hold.rs). Run the job with nx-remote
     --allow-agents (else acpmux refuses the stand-in too); only the stand-in is probed. Opt-in
     (--agent-chat): making the chat starts its agent in the folder, which is the person's own
     action and asks macOS; on an unattended host nobody answers, and session/new never returns
     (mac26, 2026-10-30). acpmux's hold is proven by tests/hub_integration/protected_resume.rs.

Fails (exit 1) when a phase logs a non-preflight check of the app (any service), or macOS
registers a notification client of the app or its helpers (usernoted's app table, when readable:
the "Notifications may include alerts, sounds, and icon badges" request). Use a tag that never
ran on the host: usernoted keeps an app's row. The app runs with the account's real home (a GUI
job runner may point HOME at a work folder, whose Downloads macOS does not guard). Each phase writes `tcc-<phase>.log` (the raw stream),
`requests-<phase>.json` (one row per check: service, preflight, the requesting binary and pid,
the result) and `screen-<phase>-<n>.png` stills when `screencapture` may record the screen.

GUI host only: a capture mini or a Mac with a logged-in console session, run over SSH. The script
never touches another app's privacy answers. It quits the app and ends the tag's daemons at the end.
"""
import argparse, json, os, plistlib, pwd, re, signal, socket, sqlite3, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_names  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="launch-no-tcc-"))
parser.add_argument("--seconds", type=float, default=45)
parser.add_argument("--phases", default="first,restore")
parser.add_argument("--folder", default="~/Downloads")
parser.add_argument("--agent-chat", action="store_true", help="restore phase: also an acpmux chat in --folder (needs a host where the setup prompt is answered: see the docstring)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = os.path.abspath(opts.app.rstrip("/"))
# The account's real home, not $HOME: a GUI job runner (nx-remote) points HOME at a work folder,
# whose Downloads macOS does not guard. The app runs with this home, as from the Dock.
HOME = pwd.getpwuid(os.getuid()).pw_dir
FOLDER = os.path.join(HOME, opts.folder[2:]) if opts.folder.startswith("~/") else opts.folder
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BUNDLE = plistlib.load(f)["CFBundleIdentifier"]
SOCKETS = build_names.socket_paths(build_names.of_app(APP, HOME)["socket"], HOME)
USERNOTED_DB = os.path.join(HOME, "Library/Group Containers/group.com.apple.usernoted/db2/db")
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=20):
    for path in SOCKETS:
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
            return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
        except (OSError, ValueError):
            continue
    return {"error": "no socket answers"}


def wait_until(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    return None


def app_pids():
    out = subprocess.run(["pgrep", "-f", os.path.join(APP, "Contents/MacOS/")], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


REQUEST = re.compile(r"AUTHREQ_(CTX|ATTRIBUTION|RESULT): msgID=(\S+?), (.*)")


def requests(log_text):
    """One row per tccd check whose responsible process is the app (or one of its bundle's ids)."""
    rows = {}
    for line in log_text.splitlines():
        m = REQUEST.search(line)
        if not m:
            continue
        kind, msg, rest = m.groups()
        row = rows.setdefault(msg, {"msg": msg, "time": line[:23]})
        if kind == "CTX":
            row["service"] = (re.search(r"service=(\w+)", rest) or [None, None])[1]
            row["preflight"] = (re.search(r"preflight=(\w+)", rest) or [None, None])[1]
        elif kind == "ATTRIBUTION":
            resp = re.search(r"responsible=\{TCCDProcess: identifier=([^,]+), pid=(\d+).*?binary_path=([^}]+)\}", rest)
            req = re.search(r"requesting=\{TCCDProcess: identifier=([^,]+), pid=(\d+).*?binary_path=([^}]+)\}", rest)
            if resp:
                row["responsible"], row["responsible_path"] = resp.group(1), resp.group(3)
            if req:
                row["requesting"], row["requesting_pid"], row["requesting_path"] = req.group(1), int(req.group(2)), req.group(3)
        else:
            row["auth_value"] = (re.search(r"authValue=(\d+)", rest) or [None, None])[1]
    root = BUNDLE.split(".helper")[0]
    return [r for r in rows.values() if (r.get("responsible") or "").startswith(root)
            or APP in (r.get("responsible_path") or "")]


def notification_registrations():
    """usernoted's app rows for the bundle id and its helpers (the Alerts helper): a row is what shows
    the "Notifications may include alerts, sounds, and icon badges" request. None when unreadable."""
    try:
        db = sqlite3.connect(f"file:{USERNOTED_DB}?mode=ro", uri=True)
        try:
            rows = db.execute("select identifier from app where identifier = ? or identifier like ?",
                              (BUNDLE, BUNDLE + ".%")).fetchall()
        finally:
            db.close()
    except sqlite3.Error as error:
        print(f"note: usernoted db unreadable ({error}); the stills show any request", flush=True)
        return None
    return sorted(row[0] for row in rows)


def screenshot(phase, n):
    path = os.path.join(opts.out, f"screen-{phase}-{n}.png")
    subprocess.run(["screencapture", "-x", path], capture_output=True, timeout=20)
    return path if os.path.exists(path) else None


def launch():
    env = {"HOME": HOME, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
    if opts.agent_chat:
        # The agent chat needs agent launches (nx-remote --allow-agents, which drops its deny), and
        # only the stand-in harness is probed: no real agent starts with the host's credentials.
        env["ACPMUX_PROBE_HARNESSES"] = "tcc-lister"
    args = ["open", "-n", "-a", APP]
    for k, v in env.items():
        args += ["--env", f"{k}={v}"]
    subprocess.run(args, check=True, timeout=30)


def quit_app():
    rpc("action.run", {"action": "quit", "wait": False}, timeout=10)
    if wait_until(lambda: not app_pids(), 20) is None:
        for pid in app_pids():
            os.kill(pid, signal.SIGTERM)  # the app this script launched, by its bundle path
        wait_until(lambda: not app_pids(), 10)


def run_phase(phase, teardown):
    subprocess.run(["tccutil", "reset", "All", BUNDLE], capture_output=True, timeout=30)
    log_path = os.path.join(opts.out, f"tcc-{phase}.log")
    stream = subprocess.Popen(
        ["/usr/bin/log", "stream", "--info", "--style", "compact", "--predicate",
         'subsystem == "com.apple.TCC" OR (process == "usernoted" AND eventMessage CONTAINS[c] "authoriz")'],
        stdout=open(log_path, "w"), stderr=subprocess.STDOUT)
    time.sleep(2)  # log stream attaches before the launch it must see
    try:
        launch()
        up = wait_until(lambda: "error" not in (rpc("debug.focus") or {"error": 1}), 90)
        check(up is not None, f"{phase}: the app answers its socket")
        teardown.remember()
        shots, started, n = [], time.monotonic(), 0
        while time.monotonic() - started < opts.seconds:  # the person does nothing for --seconds
            time.sleep(min(10, max(0.1, opts.seconds - (time.monotonic() - started))))
            n += 1
            shots.append(screenshot(phase, n))
        stream.send_signal(signal.SIGINT)
        stream.wait(timeout=10)
        with open(log_path) as f:
            text = f.read()
        rows = requests(text)
        with open(os.path.join(opts.out, f"requests-{phase}.json"), "w") as f:
            json.dump(rows, f, indent=2)
        for r in rows:
            print(f"  {r.get('time')} {r.get('service')} preflight={r.get('preflight')} "
                  f"auth={r.get('auth_value')} by {r.get('requesting_path')} (pid {r.get('requesting_pid')})", flush=True)
        prompts = [r for r in rows if r.get("preflight") == "no"]
        named = sorted({"%s by %s" % (r.get("service"), os.path.basename(r.get("requesting_path") or "?")) for r in prompts})
        check(not prompts, f"{phase}: no privacy check that prompts ({len(prompts)} of {len(rows)} checks: {', '.join(named)})")
        notif = [l for l in text.splitlines() if "usernoted" in l and BUNDLE in l]
        check(not notif, f"{phase}: no notification authorization request ({len(notif)} lines)")
        registered = notification_registrations()
        if registered is not None:
            check(not registered, f"{phase}: macOS registered no notification client of the app ({registered})")
        print(f"  stills: {[s for s in shots if s]}", flush=True)
        return True
    finally:
        if stream.poll() is None:
            stream.kill()


def open_terminal_in_folder():
    # The front pane may be Home's chat, which does not split: a new workspace's terminal does.
    rpc("action.run", {"action": "workspace.newAtBottom", "focus": True})
    time.sleep(2)  # the new workspace's terminal pane mounts
    reply = rpc("action.run", {"action": "splitRight", "args": {"cwd": FOLDER}, "focus": True})
    print("terminal in", FOLDER, json.dumps(reply)[:300], flush=True)
    time.sleep(3)  # the shell starts in the folder (the person's own action: a prompt here is fine)


FAKE_AGENT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../cmux-tui/crates/acpmux/tests/fake_agent.py")
ACPMUX_CONFIG = []  # (path, original text or None): put back at the end


def acpmux_socket_of(home):
    """acpmux `config::socket_path()`: `<home>/acpmux.sock`, or `/tmp/acpmux-<uid>/<fnv1a64>.sock`."""
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred.encode()) < 96:
        return preferred
    h = 0xcbf29ce484222325
    for byte in home.encode():
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{h:016x}.sock"


class Acpmux:
    """JSON-RPC lines to the tag's acpmux; notifications are dropped."""

    def __init__(self, path):
        self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.conn.settimeout(30)
        self.conn.connect(path)
        self.next, self.buf = 0, b""
        self.request("initialize", {"protocolVersion": 1, "clientInfo": {"name": "launch-no-tcc"}})

    def post(self, method, params):
        self.next += 1
        self.conn.sendall((json.dumps({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params}) + "\n").encode())
        return self.next

    def until(self, predicate, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if predicate(message):
                    return message
            self.conn.settimeout(max(0.1, deadline - time.monotonic()))
            try:
                chunk = self.conn.recv(1 << 20)
            except socket.timeout:
                break
            if not chunk:
                break
            self.buf += chunk
        return None

    def request(self, method, params):
        rid = self.post(method, params)
        return self.until(lambda m: m.get("id") == rid and ("result" in m or "error" in m)) or {"error": "no answer"}


def leave_agent_chat_in_folder():
    """A chat in FOLDER whose turn runs and whose next prompt waits, as the app quits. Its stand-in
    agent lists its folder first thing, as Claude Code, Codex, Kimi or Gemini CLI do."""
    home = build_names.of_app(APP, HOME)["acpmux_home"]
    if not wait_until(lambda: os.path.exists(acpmux_socket_of(home)), 30):
        check(False, f"agent chat: the tag's acpmux answers ({home})")
        return
    path = os.path.join(home, "config.json")
    try:
        with open(path) as f:
            original = f.read()
    except FileNotFoundError:
        original = None
    ACPMUX_CONFIG.append((path, original))
    config = json.loads(original) if original else {}
    # It lists its folder only once ARMED exists: the setup's own start (the person's action) must
    # not leave a macOS prompt up that blocks session/new; a start after the relaunch lists it.
    armed = os.path.join(home, "tcc-lister-armed")
    if os.path.exists(armed):
        os.remove(armed)
    lister = (f'[ -e {json.dumps(armed)} ] && /bin/ls -la "$PWD" > /dev/null 2>&1; '
              f'exec python3 {json.dumps(os.path.abspath(FAKE_AGENT))}')
    config.setdefault("harnesses", {})["tcc-lister"] = {"argv": ["/bin/sh", "-c", lister]}
    with open(path + ".tcc", "w") as f:
        f.write(json.dumps(config, indent=2))
    os.replace(path + ".tcc", path)
    client = Acpmux(acpmux_socket_of(home))
    client.request("_acpmux/reload_config", {})
    created = client.request("session/new", {"cwd": FOLDER, "mcpServers": [], "_meta": {"acpmux": {"harness": "tcc-lister"}}})
    session = (created.get("result") or {}).get("sessionId")
    check(bool(session), f"agent chat: made in {FOLDER} ({json.dumps(created)[:200]})")
    if not session:
        return
    text = lambda t: [{"type": "text", "text": t}]
    client.post("session/prompt", {"sessionId": session, "prompt": text("until-cancel"), "_meta": {"acpmux": {"promptId": "tcc-run"}}})
    running = client.until(lambda m: (m.get("params") or {}).get("update", {}).get("content", {}).get("text") == "running")
    check(running is not None, "agent chat: its turn runs")
    client.post("session/prompt", {"sessionId": session, "prompt": text("queued"), "_meta": {"acpmux": {"promptId": "tcc-queued"}}})
    accepted = client.until(lambda m: m.get("method") == "_acpmux/prompt_accepted")
    check(accepted is not None and (accepted.get("params") or {}).get("queued") is True, "agent chat: a prompt waits behind it")
    open(armed, "w").close()
    print("agent chat", session, "in", FOLDER, flush=True)


def put_back_acpmux_config():
    for path, original in ACPMUX_CONFIG:
        if original is None:
            if os.path.exists(path):
                os.remove(path)
        else:
            with open(path + ".tcc", "w") as f:
                f.write(original)
            os.replace(path + ".tcc", path)
    ACPMUX_CONFIG.clear()


teardown = TagTeardown(APP)
teardown.install()
try:
    phases = [p for p in opts.phases.split(",") if p]
    for i, phase in enumerate(phases):
        run_phase(phase, teardown)
        if phase == "first" and "restore" in phases[i + 1:]:
            open_terminal_in_folder()
            if opts.agent_chat:
                leave_agent_chat_in_folder()
        quit_app()
        # A relaunch after a restart: the terminal daemons end too, so the relaunch restores the
        # terminal (a new shell in its folder) instead of finding its shell still running.
        teardown.end()
finally:
    quit_app()
    teardown.end()
    put_back_acpmux_config()
print(json.dumps({"bundle": BUNDLE, "failures": failures, "out": opts.out}), flush=True)
sys.exit(1 if failures else 0)
