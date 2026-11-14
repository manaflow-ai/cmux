#!/usr/bin/env python3
"""Live proof of three Home Chief fixes in a tagged app (cmux-lawrence-2 only: an
`nx-remote --needs gui --allow-agents --app-from-fleet` job; hq6d dogfood 2026-10-15).

On a scratch Chief home (CMUX_NEXT_CHIEF_HOME in /tmp):
  rename  (cx-di8pd) `cmux chief new` makes a second Chief; `cmux chief edit ID --name NEW`
          changes its Home conversation's title to NEW within 30 s.
  engine  (cx-327wl) in that Chief's conversation, the Chief settings panel's effort pick
          (debug.home.drive engine_set) reaches that Chief's own brain: its engine.json
          says effort low within 60 s and the default Chief's engine.json does not.
  send    (cx-4io0o) with Home open, `cmux chief shutdown --chief-home H` stops the default
          brain and its owner; the app reconnects; a send from Home is an ask: a new brain
          holds state/host.lock within 90 s and its memory logs the send within 240 s.
Ends with quitEndSessions, then the scratch home's acpmux, router, Chief and owner.

Exit: 0 all passed; 1 a check failed; 2 the app or the first brain did not come up.
Usage: chief-home-fixes-live.py --tag TAG --app APP [--out DIR] [--only rename,engine,send]
"""
import argparse, json, os, random, shutil, socket, sqlite3, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--tag", default=os.environ.get("NX_APP_TAG"))
ap.add_argument("--app", default=os.environ.get("NX_APP"))
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
ap.add_argument("--only", default="rename,engine,send")
opts = ap.parse_args()
if not opts.tag or not opts.app:
    sys.exit("chief-home-fixes-live.py: --tag and --app (or NX_APP_TAG and NX_APP) are required")
if os.environ.get("ACPMUX_AGENT_LAUNCH", "").strip().lower() == "deny" or os.environ.get("CMUX_AGENTS_DISABLED", "").strip() == "1":
    sys.exit("chief-home-fixes-live.py: the Chief brains need agents; submit the job with `nx-remote --allow-agents`")

TAG, APP = opts.tag, opts.app
macos = os.path.join(APP, "Contents/MacOS")
BINARY = next((os.path.join(macos, n) for n in sorted(os.listdir(macos)) if n.startswith("cmux")), os.path.join(macos, "cmux DEV"))
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
SOCK = f"/tmp/cmux-debug-{TAG}.sock"
# Short: the brains' sockets (optchat/tools.sock) must fit sun_path; a job's TMPDIR is too deep.
SCRATCH = tempfile.mkdtemp(prefix="chf-", dir="/tmp")
HOME_DIR = os.path.join(SCRATCH, "h")
LOCK = os.path.join(HOME_DIR, "state", "host.lock")
RUN = "%04d" % random.randint(0, 9999)
os.makedirs(opts.out, exist_ok=True)
ROWS = []
ONLY = set(opts.only.split(","))


def say(*parts):
    print(*parts, flush=True)


def row(name, ok, observed):
    ROWS.append({"check": name, "ok": bool(ok), "observed": observed})
    say("PASS" if ok else "FAIL", name, json.dumps(observed)[:600])


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCK)
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
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness poll, not app code
    return None


def clean_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CMUX_", "ACPMUX_"))}
    env["NO_COLOR"] = "1"
    return env


def cli(*args, timeout=120):
    p = subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=clean_env())
    return {"args": list(args), "exit": p.returncode, "stdout": p.stdout[-3000:], "stderr": p.stderr[-1500:]}


def home():
    return rpc("debug.home") or {}


def conversation_with(participant):
    return next((c for c in home().get("conversations", []) if participant in c.get("participants", [])), None)


def open_conversation(conv_id):
    rpc("action.run", {"id": "home.openConversation", "args": {"conversation": conv_id}, "focus": True})
    return wait(lambda: (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("ok"), 30)


def brain_pid():
    """The pid in host.lock while that process runs optchat-chief (never takes the flock)."""
    try:
        pid = int(open(LOCK).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    comm = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
    return pid if comm.endswith("optchat-chief") else None


def logged(marker):
    path = os.path.join(HOME_DIR, "optchat", "memory.sqlite3")
    if not os.path.exists(path):
        return 0
    try:
        db = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=5)
        try:
            return sum(1 for (text,) in db.execute("SELECT text FROM messages WHERE kind = 'user'") if marker in (text or ""))
        finally:
            db.close()
    except sqlite3.Error:
        return 0


def effort(mux_home):
    try:
        return (json.load(open(os.path.join(mux_home, "optchat", "engine.json"))) or {}).get("effort")
    except (OSError, ValueError):
        return None


def brain_dir(chief):
    return os.path.join(HOME_DIR, "c", chief[-8:].lower())


def app_env():
    config = os.path.join(SCRATCH, "cmux.json")
    open(config, "w").write("{}")
    open(os.path.join(SCRATCH, "ghostty"), "w").write("")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_CHIEF_HOME": HOME_DIR,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900",
           "MUX_HARNESS": os.environ.get("MUX_HARNESS", "claude-sr")}
    for name in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "SUBROUTER_URL", "CLAUDE_CODE_OAUTH_TOKEN",
                 "CLAUDE_CONFIG_DIR", "LANG"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    return env


def check_rename_and_engine():
    name, renamed = f"Fix Two {RUN}", f"Fix Renamed {RUN}"
    made = cli("chief", "new", "--name", name, "--role", "second chief for the fixes proof", "--chief-home", HOME_DIR, "--json")
    try:
        chief = json.loads(made["stdout"].strip().splitlines()[-1])["id"]
    except (ValueError, KeyError, IndexError):
        row("chief new", False, made)
        return
    conv = wait(lambda: conversation_with(chief), 120, step=1)
    if not conv:
        row("Home lists the second Chief", False, {"chief": chief, "titles": [c.get("title") for c in home().get("conversations", [])]})
        return
    if "rename" in ONLY:
        edit = cli("chief", "edit", chief, "--name", renamed, "--chief-home", HOME_DIR, "--json")
        title = wait(lambda: (lambda c: c and renamed in (c.get("title") or "") and c.get("title"))(conversation_with(chief)), 30, step=1)
        row("cx-di8pd: chief edit --name retitles the Chief's Home conversation", edit["exit"] == 0 and title,
            {"edit_exit": edit["exit"], "title": (conversation_with(chief) or {}).get("title"), "want": renamed})
    if "engine" in ONLY:
        sock = os.path.join(brain_dir(chief), "optchat", "tools.sock")
        up = wait(lambda: os.path.exists(sock), 120, step=1)
        shown = open_conversation(conv["id"])
        # The view learns its Chief from the store (a main-actor task): wait until its controls name it.
        # A build without chief_control (before the fix) answers an error: the pick then goes as it would.
        controls = wait(lambda: (rpc("debug.home.drive", {"action": "chief_control"}) or {}).get("named") == chief, 15)
        before = {"default": effort(HOME_DIR), "named": effort(brain_dir(chief))}
        picked = rpc("debug.home.drive", {"action": "engine_set", "key": "effort", "value": "low"})
        named = wait(lambda: effort(brain_dir(chief)) == "low", 60, step=1) and controls
        after = {"default": effort(HOME_DIR), "named": effort(brain_dir(chief))}
        row("cx-327wl: the named Chief's panel sets that Chief's engine, not the default's",
            named and after["default"] == before["default"],
            {"brain_socket": bool(up), "shown": bool(shown), "controls_name_it": bool(controls), "pick": picked, "before": before, "after": after})


def check_send_after_shutdown():
    # Show the default Chief's conversation BEFORE the shutdown: showing another conversation is
    # an ask of its own (TopHomePageView.show), which would start the brain without the fix.
    default = conversation_with("agent_mux")
    if default:
        open_conversation(default["id"])
    first = brain_pid()
    log_at = os.path.getsize(os.path.join(HOME_DIR, "host.log")) if os.path.exists(os.path.join(HOME_DIR, "host.log")) else 0
    owner0 = home().get("chief_owner") or {}
    stopped = cli("chief", "shutdown", "--chief-home", HOME_DIR, timeout=150)
    back = wait(lambda: (lambda o: o if o.get("connected") and o.get("daemon_pid") and o.get("daemon_pid") != owner0.get("daemon_pid")
                         else None)(home().get("chief_owner") or {}), 240, step=1)
    # The shutdown marker holds: no brain until an ask (the send).
    idle = wait(lambda: brain_pid() is None, 20)
    time.sleep(5)  # test harness: a restart that ignores the marker would show within this window
    idle = idle and brain_pid() is None
    marker = f"FIX-SEND-{RUN}"
    steps = [rpc("debug.home.drive", {"action": a, **x}) for a, x in
             (("focus", {}), ("type", {"text": f"{marker} after a chief shutdown: reply with only the word back."}), ("send", {}))]
    second = wait(lambda: (lambda p: p if p and p != first else None)(brain_pid()), 90, step=1)
    heard = wait(lambda: logged(marker), 240, step=2) if second else 0
    row("cx-4io0o: a Home send after cmux chief shutdown starts the brain, which gets the send",
        bool(back) and bool(idle) and bool(second) and bool(heard),
        {"first_brain": first, "shutdown_exit": stopped["exit"], "owner_back": bool(back), "no_brain_before_send": bool(idle),
         "send": steps[-1], "new_brain": second, "logged": heard})
    if "send" in ONLY:
        check_probe_after_restart(log_at, default)


def check_probe_after_restart(log_at, default):
    """cx-oqnw3: the restarted brain's compactor probe starts (its session name is free), and a
    compactor fault is never a Chief message in the conversation."""
    path = os.path.join(HOME_DIR, "host.log")

    def since():
        try:
            with open(path, errors="replace") as f:
                f.seek(log_at)
                return f.read()
        except OSError:
            return ""
    probed = wait(lambda: "compactor probe (" in since() and "built a node" in since() or "is taken" in since(), 120, step=2)
    text = since()
    shown = [m.get("text") or "" for m in (conversation_with("agent_mux") or {}).get("shown_tail", [])
             if m.get("author") == "agent_mux"]
    row("cx-oqnw3: the restarted brain's compactor probe runs; no compactor notice as a Chief message",
        bool(probed) and "is taken" not in text and not any("memory compactor" in t for t in shown),
        {"probe_line": next((l for l in text.splitlines() if "compactor probe" in l or "is taken" in l), None),
         "chief_messages_about_compactor": [t[:160] for t in shown if "memory compactor" in t]})


def end(app):
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        say(f"app {app.pid} did not quit within 60 s; NX_APP_STOP ends it at job end")
    acpmux_home = os.path.join(HOME_DIR, "acpmux")
    env = {k: v for k, v in os.environ.items() if not k.startswith("ACPMUX_")}
    env.update(ACPMUX_HOME=acpmux_home, ACPMUX_SOCKET=os.path.join(acpmux_home, "acpmux.sock"))
    subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env=env, capture_output=True, timeout=30)
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(5)
        conn.connect(os.path.join(acpmux_home, "router", "router.sock"))
        conn.sendall(b'{"op":"shutdown"}\n')
        conn.recv(4096)
        conn.close()
    except OSError:
        pass
    session = (home().get("chief_owner") or {}).get("session") if os.path.exists(SOCK) else None
    cli("chief", "shutdown", "--chief-home", HOME_DIR, timeout=150)
    if session:
        cli("server", "stop", "--session", session, "--end-terminals")


if os.path.exists(SOCK):
    sys.exit(f"{SOCK} exists: another {TAG} app runs")
# The scratch home never pushes a memory backup or imports this host's old Chiefs.
os.makedirs(os.path.join(HOME_DIR, "optchat"), exist_ok=True)
open(os.path.join(HOME_DIR, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(HOME_DIR, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
app = subprocess.Popen([BINARY], env=app_env(), stdout=log, stderr=log, stdin=subprocess.DEVNULL)
code = 0
try:
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 300):
        say("FAIL: the app did not come up")
        code = 2
        raise SystemExit
    rpc("action.run", {"id": "home.show"})
    if not wait(brain_pid, 180):
        say("FAIL: no default brain after Home opened")
        code = 2
        raise SystemExit
    if ONLY & {"rename", "engine"}:
        check_rename_and_engine()
    if "send" in ONLY:
        check_send_after_shutdown()
    code = 0 if ROWS and all(r["ok"] for r in ROWS) else 1
except SystemExit:
    pass
finally:
    json.dump({"rows": ROWS, "home": home()}, open(os.path.join(opts.out, "chief-home-fixes.json"), "w"), indent=1)
    for name in ("host.log",):
        try:
            shutil.copy(os.path.join(HOME_DIR, name), os.path.join(opts.out, name))
        except OSError:
            pass
    end(app)
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", "PASS" if code == 0 else f"FAIL {code}")
sys.exit(code)
