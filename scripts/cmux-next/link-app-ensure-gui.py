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
   app's own ensure (`cloud.link.ensure` on the debug socket), and the app's `apps-link-changed`
   passes on its verified connection and tells at least one app server;
5. the link outlives the app (quit by exact pid), then `link stop` ends it and removes
   `link.json`.
The app is started by its executable from this job and ended by exact pid; it never touches
the user's cmux. The tag's daemons end through TagTeardown.
"""
import json, os, plistlib, socket, stat, subprocess, sys, time

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
if os.path.isdir(TAG_ROOT) and not os.path.islink(TAG_ROOT):
    os.rename(TAG_ROOT, TAG_ROOT + ".old-" + str(int(time.time())))
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
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
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
app = subprocess.Popen([BINARY], env=env, stdout=app_log, stderr=app_log, stdin=subprocess.DEVNULL)
say("started app pid", app.pid)
failed = False
try:
    up = wait(lambda: "error" not in (rpc("debug.focus", timeout=5) or {"error": 1}), 120, 2)
    record("tagged app up", up, SOCKET)
    auth = wait(lambda: (lambda s: s if isinstance(s, dict) and s.get("signed_in") else None)(rpc("auth.status")), 120, 2) or {}
    signed = (auth.get("email") or "").lower() == ACCOUNT.lower() and bool(ACCOUNT)
    record("signed in as the agent account only", signed, f"backend {auth.get('backend')}")
    if not (up and signed):
        failed = True
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
    # The app's real apps-link-changed call (round 2 item 7): the Cloud app
    # server runs (a machine list starts it), the link stops behind the
    # app's back, and the app's own ensure starts it again and tells the
    # daemon on its verified connection. The daemon answers how many app
    # servers it told: the Cloud server must be one of them.
    listed = rpc("cloud.machines")
    record("the Cloud app server answers the machine list", isinstance(listed, dict) and "error" not in listed,
           json.dumps(listed)[:200])
    record("the link stops behind the app (CLI link stop)", link("stop").get("stopped") is True, "")
    report = rpc("cloud.link.ensure", timeout=60) or {}
    changed = report.get("link_changed") or {}
    record("the app's ensure starts the link and its apps-link-changed passes on the verified connection",
           report.get("status") == "started" and "error" not in changed and (changed.get("servers") or 0) >= 1,
           json.dumps(report)[:400])
    status = link("status")
    record("the restarted link runs", status.get("running") is True and status.get("pid") == report.get("pid"),
           json.dumps({k: status.get(k) for k in ("running", "pid")}))
    pid = status.get("pid")
finally:
    app.terminate()
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.kill()
        app.wait()
    say("app ended", app.pid)
    if not failed:
        after_quit = link("status")
        record("the link outlives the app", after_quit.get("running") is True and after_quit.get("pid") == pid,
               json.dumps({k: after_quit.get(k) for k in ("running", "pid")}))
    stopped = link("stop")
    record("link stop ends it and removes link.json", not os.path.exists(REGISTRATION) and link("status").get("running") is False,
           json.dumps(stopped))
    TEARDOWN.end()
sys.exit(0 if all(s["ok"] for s in STEPS) else 1)
