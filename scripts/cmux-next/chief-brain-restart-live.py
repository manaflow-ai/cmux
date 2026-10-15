#!/usr/bin/env python3
"""Live proof that a running app starts its Chief brain again after the brain
stops, with no app relaunch and Home already open (cmux-lawrence-2 only, an
--app-from-fleet GUI job). Lawrence's NIGHTLY sat with a dead brain after
another build's quit stopped it: Home was open, so nothing started it, and
Settings said "Open Home to start it".

Steps, on a scratch Chief home (CMUX_NEXT_CHIEF_HOME in a temp dir):
  1. launch the tagged app, show Home, wait until a brain holds state/host.lock;
  2. stop the Chief the documented way (`cmux chief shutdown --chief-home H`:
     brain, then the owner daemon), as another build's quit did;
  3. PASS when a new brain (another pid) holds the lock within --deadline s,
     with the same app process; then one message gets a Chief reply
     (needs the Claude login of a login shell: run under `zsh -lic`);
  4. `cmux --socket <app control socket> chief engine` names the timeout
     (no bare "Resource temporarily unavailable").
Ends with quitEndSessions, then the scratch Chief's acpmux, router and owner.

Exit: 0 all passed; 1 the brain did not start again; 2 no reply; 3 the CLI error.
Usage: chief-brain-restart-live.py --tag TAG --app APP [--deadline 120] [--reply-wait 240] [--out DIR]
Submit the nx-remote job with --allow-agents: gui and input jobs default to ACPMUX_AGENT_LAUNCH=deny (cx-tgf4h).
"""
import argparse, json, os, shutil, socket, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--tag", required=True)
ap.add_argument("--app", required=True)
ap.add_argument("--deadline", type=float, default=120)
ap.add_argument("--reply-wait", type=float, default=240)
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = ap.parse_args()
# cx-tgf4h: nx-remote gui and input jobs run with ACPMUX_AGENT_LAUNCH=deny
# (HQ #2130), so no Chief turn can start; fail at once, not after a reply wait.
if os.environ.get("ACPMUX_AGENT_LAUNCH", "").strip().lower() == "deny" or os.environ.get("CMUX_AGENTS_DISABLED", "").strip() == "1":
    sys.exit("chief-brain-restart-live.py: this Chief proof needs agents; submit the job with `nx-remote --allow-agents` "
             "(ACPMUX_AGENT_LAUNCH=deny or CMUX_AGENTS_DISABLED=1 is set)")

TAG, APP = opts.tag, opts.app
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
DEBUG_SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
# A short path: the brain's sockets (optchat/tools.sock) must fit sun_path
# (104 bytes); a job's TMPDIR is too deep.
SCRATCH = tempfile.mkdtemp(prefix="cbr-", dir="/tmp")
HOME_DIR = os.path.join(SCRATCH, "chief")
LOCK = os.path.join(HOME_DIR, "state", "host.lock")
os.makedirs(opts.out, exist_ok=True)


def say(*parts):
    print(*parts, flush=True)


def rpc(method, params=None, timeout=30, path=DEBUG_SOCKET):
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
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def brain_pid():
    """The pid in host.lock while that process runs optchat-chief, else None.
    Never takes the flock: a probe that holds it for an instant can make a
    brain that starts in that instant exit ("already running")."""
    try:
        pid = int(open(LOCK).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    comm = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
    return pid if comm.endswith("optchat-chief") else None


def host_log_tail():
    try:
        return open(os.path.join(HOME_DIR, "host.log"), errors="replace").read()[-3000:]
    except OSError:
        return ""


def chief_row():
    rows = [c for c in (rpc("debug.home") or {}).get("conversations", []) if "agent_mux" in c.get("participants", [])]
    return rows[0] if rows else None


def send_and_wait(text):
    say("drive", rpc("debug.home.drive", {"action": "focus"}), rpc("debug.home.drive", {"action": "type", "text": text}),
        rpc("debug.home.drive", {"action": "send"}))

    def answered():
        shown = [(m["author"], m["text"]) for m in (chief_row() or {}).get("shown_tail", [])]
        mine = [i for i, (_, t) in enumerate(shown) if t == text]
        return mine and any(a == "agent_mux" for a, _ in shown[mine[-1] + 1:])
    return bool(wait(answered, opts.reply_wait, 2))


def end(app):
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        say(f"app {app.pid} did not quit within 60 s; NX_APP_STOP ends it at job end")
    acpmux_home = os.path.join(HOME_DIR, "acpmux")
    env = {k: v for k, v in os.environ.items() if not k.startswith("ACPMUX_")}
    env.update({"ACPMUX_HOME": acpmux_home})
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
    subprocess.run([CLI, "chief", "shutdown", "--chief-home", HOME_DIR],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=90)


keep = ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR")
env = {k: v for k, v in os.environ.items() if k in keep}
env.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_CHIEF_HOME": HOME_DIR})
config = os.path.join(SCRATCH, "cmux.json")
open(config, "w").write("{}")
env["CMUX_NEXT_CONFIG_FILE"] = config
# The temp home never pushes a memory backup or imports this host's old Chiefs.
os.makedirs(os.path.join(HOME_DIR, "optchat"), exist_ok=True)
open(os.path.join(HOME_DIR, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(HOME_DIR, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
code = 0
try:
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 300):
        say("FAIL: the app did not come up")
        code = 1
        raise SystemExit
    rpc("action.run", {"id": "home.show"})
    first = wait(brain_pid, 180)
    say(f"step 1: brain pid {first}; app pid {app.pid}")
    if not first:
        say("FAIL: no brain after Home opened\n" + host_log_tail())
        code = 1
        raise SystemExit
    stopped = subprocess.run([CLI, "chief", "shutdown", "--chief-home", HOME_DIR], capture_output=True, text=True, timeout=90,
                             env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")})
    say(f"step 2: chief shutdown exit {stopped.returncode}: {stopped.stderr.strip()}")
    started = time.time()
    second = wait(lambda: (lambda p: p if p and p != first else None)(brain_pid()), opts.deadline)
    if not second or app.poll() is not None:
        say(f"FAIL step 3: no new brain within {opts.deadline:.0f} s (app alive: {app.poll() is None})\n" + host_log_tail())
        code = 1
    else:
        say(f"step 3: PASS new brain pid {second} after {time.time() - started:.1f} s, same app pid {app.pid}")
        if send_and_wait(f"restart check {TAG}: reply with only the word ok."):
            say("step 3: PASS the restarted brain replied")
        else:
            say(f"FAIL step 3: no reply within {opts.reply_wait:.0f} s\n" + host_log_tail())
            code = 2
    control = DEBUG_SOCKET
    probe = subprocess.run([CLI, "--socket", control, "chief", "engine"], capture_output=True, text=True, timeout=60,
                           env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")})
    said = (probe.stderr + probe.stdout).strip()
    say(f"step 4: cmux --socket {control} chief engine -> exit {probe.returncode}: {said[:300]}")
    clear = "did not answer within" in said or "closed the connection" in said
    if probe.returncode == 0 or not clear or "os error 35" in said or "temporarily unavailable" in said:
        say("FAIL step 4: no clear error (want a nonzero exit naming the timeout or the closed connection)")
        code = code or 3
except SystemExit:
    pass
finally:
    end(app)
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", "PASS" if code == 0 else f"FAIL {code}")
sys.exit(code)
