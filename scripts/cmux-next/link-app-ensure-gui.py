#!/usr/bin/env python3
"""GUI proof of cx-rtipa S3 on the GUI host (cmux-lawrence-2): a tagged cmux-next app with
CMUX_NEXT_CLOUD_LINK=app against the DEVELOPMENT API Worker starts its own `cmux link` after
sign-in, in the tag's own state directory, and never touches the release link.

  nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- \
    python3 -I scripts/cmux-next/link-app-ensure-gui.py

Checks (each a PASS/FAIL line, all in $NX_ARTIFACTS/link.json):
1. the tagged app is up and signed in as the agent account only;
2. `<tag state>/tui/link.json` appears, and the bundled `cmux-tui link status` of that state
   directory says running, as an install (`inst_...`), on a UDP port that is not 4101;
3. the release registration (`~/Library/Application Support/cmux-tui/sessions/link.json`) is
   the same before and after;
4. with the Cloud app server running, a link stopped behind the app is started again by the
   app's own ensure (`debug.cloud.link_ensure` on the debug socket, DEBUG builds only), and the app's `apps-link-changed`
   passes on its verified connection and tells at least one app server;
5. the link outlives the app (quit by exact pid);
6. a session end without the app's sign-out (`debug.cloud.end_session`) stops the link and
   archives its install; the next launch signs in and starts it again;
7. a sign-out while an ensure runs leaves no link.
The app is started by its executable from this job and ended by exact pid; it never touches
the user's cmux. The tag's daemons end through TagTeardown.
"""
import json, os, plistlib, socket, stat, subprocess, sys, threading, time

APP = os.environ["NX_APP"]
TAG = os.environ["NX_APP_TAG"]
CREDS = os.path.expanduser("~/.secrets/cmuxterm-dev.env")
WORKER = "https://cmux-api-development.debussy.workers.dev"
OUT = os.environ.get("NX_ARTIFACTS") or f"/tmp/link-gui-{os.getpid()}"
os.makedirs(OUT, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
STEPS = []

info = os.lstat(CREDS)
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
    sys.exit(f"refusing {CREDS}: it must be a regular file of this user with no group or other access")
ACCOUNT = next((l.split("=", 1)[1].strip().strip("'\"") for l in open(CREDS)
                if l.strip().removeprefix("export ").startswith("CMUX_UITEST_STACK_EMAIL=")), "")


def say(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


def record(step, ok, detail):
    STEPS.append({"step": step, "ok": bool(ok), "detail": detail})
    say(f"{'PASS' if ok else 'FAIL'} {step} :: {detail}")
    with open(os.path.join(OUT, "link.json"), "w") as f:
        json.dump({"tag": TAG, "steps": STEPS}, f, indent=2)


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        conn.close()
        reply = json.loads(data or b"{}")
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except Exception as e:
        return {"error": str(e)}


def wait(check, seconds, step=1.0):
    # A test harness waiting on a live app: bounded polling of observable state.
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def fingerprint(path):
    try:
        s = os.lstat(path)
        return {"exists": True, "mtime_ns": s.st_mtime_ns, "size": s.st_size, "body": open(path).read()}
    except FileNotFoundError:
        return {"exists": False}


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown

TAG_ROOT = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{TAG}")
# A fresh tag only: this script never moves or deletes a tag folder it did
# not make.
if os.path.lexists(TAG_ROOT):
    sys.exit(f"refusing: {TAG_ROOT} already exists; use a new tag")
TUI = os.path.join(TAG_ROOT, "tui")
LINK_STATE = os.path.join(TUI, "link")
REGISTRATION = os.path.join(TUI, "link.json")
RELEASE = os.path.expanduser("~/Library/Application Support/cmux-tui/sessions/link.json")
release_before = fingerprint(RELEASE)
CLI = os.path.join(APP, "Contents/Resources/bin/cmux-tui")


def link(*args):
    env = dict(os.environ, CMUX_TUI_STATE_DIR=TUI)
    env.pop("XDG_RUNTIME_DIR", None)
    out = subprocess.run([CLI, "link", *args, "--state-dir", LINK_STATE], env=env, capture_output=True, text=True, timeout=60)
    line = (out.stdout.strip().splitlines() or ["{}"])[-1]
    try:
        return json.loads(line)
    except ValueError:
        return {"error": out.stderr.strip()[-300:]}


with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])


def remove_own_socket(path):
    """Removes a stale debug socket only when it is a socket of this user."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid():
        os.unlink(path)
    else:
        sys.exit(f"refusing to remove {path}: not a socket of this user")


config = os.path.join(OUT, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
HOME_ACP = f"/tmp/lkg-acp-{os.getpid()}"
ACP_SOCKET = f"/tmp/lkg-acp-{os.getpid()}.sock"
os.makedirs(HOME_ACP, mode=0o700, exist_ok=True)
env = dict(os.environ)
env.update({"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", "CMUX_NEXT_CONFIG_FILE": config,
            "CMUX_NEXT_CLOUD_LINK": "app", "CMUX_NEXT_FEED_API_URL": WORKER,
            "CMUX_AUTH_CREDENTIALS_FILE": CREDS, "CMUX_DEV_AUTH_ACCOUNT": ACCOUNT, "CMUX_DEV_AUTH_PROFILE": "agent",
            "ACPMUX_HOME": HOME_ACP, "ACPMUX_SOCKET": ACP_SOCKET})
TEARDOWN = TagTeardown(APP, acpmux_home=HOME_ACP, acpmux_socket=ACP_SOCKET, log=say)
TEARDOWN.install()
app_log = open(os.path.join(OUT, "app.log"), "a")
APP_PROC = None


def launch(label):
    """Starts the app by its executable and waits until it is up and signed in."""
    global APP_PROC
    remove_own_socket(SOCKET)
    APP_PROC = subprocess.Popen([BINARY], env=env, stdout=app_log, stderr=app_log, stdin=subprocess.DEVNULL)
    say("started app pid", APP_PROC.pid, label)
    up = wait(lambda: "error" not in (rpc("debug.focus", timeout=5) or {"error": 1}), 120, 2)
    auth = wait(lambda: (lambda s: s if isinstance(s, dict) and s.get("signed_in") else None)(rpc("auth.status")), 120, 2) or {}
    signed = bool(ACCOUNT) and (auth.get("email") or "").lower() == ACCOUNT.lower()
    return bool(up), signed, auth


def quit_app():
    """Ends the app this script started, by its exact pid."""
    global APP_PROC
    if APP_PROC is None:
        return
    APP_PROC.terminate()
    try:
        APP_PROC.wait(timeout=30)
    except subprocess.TimeoutExpired:
        APP_PROC.kill()
        APP_PROC.wait()
    say("app ended", APP_PROC.pid)
    APP_PROC = None


def signed_out():
    return wait(lambda: (lambda s: isinstance(s, dict) and s.get("signed_in") is False)(rpc("auth.status")), 60, 1)


pid = None
try:
    up, signed, auth = launch("first")
    record("tagged app up", up, SOCKET)
    record("signed in as the agent account only", signed, f"backend {auth.get('backend')}")
    if not (up and signed):
        sys.exit(1)
    registered = wait(lambda: os.path.exists(REGISTRATION), 90, 1)
    record("the app started its link: tag registration appears", registered, REGISTRATION)
    status = link("status")
    record("bundled `link status`: running as an install, not on port 4101",
           status.get("running") is True and str(status.get("install", "")).startswith("inst_") and status.get("port") != 4101
           and status.get("state_dir") == LINK_STATE,
           json.dumps({k: status.get(k) for k in ("running", "pid", "port", "udp", "state_dir", "socket")}) + f" install inst_: {str(status.get('install', '')).startswith('inst_')}")
    release_after = fingerprint(RELEASE)
    record("the release link registration did not change", release_after == release_before,
           f"exists before {release_before['exists']} after {release_after['exists']}")
    # The app's real apps-link-changed call: the Cloud app server runs (a
    # machine list starts it), the link stops behind the app's back, and the
    # app's own ensure starts it again and tells the daemon on its verified
    # connection, which answers how many app servers it told.
    # The app's own daemon connection must be up before its call can pass:
    # the machine list says so (`last_error` names a missing connection).
    listed = wait(lambda: (lambda m: m if isinstance(m, dict) and "error" not in m and not m.get("last_error") else None)(rpc("cloud.machines")), 120, 2) or rpc("cloud.machines")
    record("the Cloud app server answers the machine list on a connected daemon",
           isinstance(listed, dict) and "error" not in listed and not listed.get("last_error"), json.dumps(listed)[:200])
    record("the link stops behind the app (CLI link stop)", link("stop").get("stopped") is True, "")
    report = rpc("debug.cloud.link_ensure", timeout=60) or {}
    changed = report.get("link_changed") or {}
    record("the app's ensure starts the link and its apps-link-changed passes on the verified connection",
           report.get("status") == "started" and "error" not in changed and (changed.get("servers") or 0) >= 1,
           json.dumps(report)[:400])
    status = link("status")
    record("the restarted link runs", status.get("running") is True and status.get("pid") == report.get("pid"),
           json.dumps({k: status.get(k) for k in ("running", "pid")}))
    pid = status.get("pid")
    quit_app()
    after_quit = link("status")
    record("the link outlives the app", pid is not None and after_quit.get("running") is True and after_quit.get("pid") == pid,
           json.dumps({k: after_quit.get(k) for k in ("running", "pid")}))

    # A session end without the app's sign-out stops the link.
    up, signed, _ = launch("second")
    record("the app comes back signed in", up and signed, "")
    ended = rpc("debug.cloud.end_session", timeout=60)
    gone = signed_out()
    stopped_link = wait(lambda: link("status").get("running") is False, 60, 1)
    record("a session end without sign-out stops the link and archives its install",
           bool(gone) and bool(stopped_link) and not os.path.exists(os.path.join(LINK_STATE, "config.json")),
           f"end_session {json.dumps(ended)[:120]}; signed out {bool(gone)}; config left {os.path.exists(os.path.join(LINK_STATE, 'config.json'))}")
    quit_app()

    # A sign-out while an ensure runs leaves no link.
    up, signed, _ = launch("third")
    record("the next launch signs in and starts the link again", up and signed and wait(lambda: link("status").get("running") is True, 90, 1),
           json.dumps({k: link("status").get(k) for k in ("running", "pid")}))
    link("stop")
    racing = {}

    def ensure_now():
        racing["report"] = rpc("debug.cloud.link_ensure", timeout=90)

    ensure_thread = threading.Thread(target=ensure_now)
    ensure_thread.start()
    signout = rpc("action.run", {"action": "palette.auth.signOut"}, timeout=90)
    ensure_thread.join(120)
    gone = signed_out()
    settled = wait(lambda: link("status").get("running") is False, 30, 1)
    record("a sign-out during an ensure leaves no link", bool(gone) and bool(settled),
           f"sign-out {json.dumps(signout)[:120]}; ensure {json.dumps(racing.get('report'))[:200]}; link {json.dumps(link('status'))[:120]}")
finally:
    for step in (quit_app,
                 lambda: record("link stop at the end leaves no link.json",
                                link("stop") is not None and not os.path.exists(REGISTRATION), ""),
                 TEARDOWN.end):
        try:
            step()
        except Exception as error:  # each cleanup step runs, whatever the one before did
            say("cleanup step failed:", error)
sys.exit(0 if STEPS and all(s["ok"] for s in STEPS) else 1)
