#!/usr/bin/env python3
"""Live proof that cmux NEXT keeps its agent chats and Chief memory across the
per-build isolation update (cx-is1kf.9; cmux-lawrence-2 only, an
--app-from-fleet GUI job with --allow-agents, run under `zsh -lic` for the
Claude login). Everything happens under a temp root: CMUX_NEXT_CHIEF_ROOT for
~/.cmux/chief and CMUX_NEXT_ACPMUX_ROOT for ~/.acpmux (DEBUG overrides), never
the real homes.

  0. The pre-update layout. The app as NIGHTLY (CMUX_NEXT_CHIEF_BUILD_ID=
     com.cmuxterm.app.nightly) runs on the shared Chief home ROOT/default, one
     message M0 gets a reply, the app quits (end sessions). NEXT's old acpmux
     home ACPMUX_ROOT/tags/cmux-next gets two sessions and its config, and a
     pre-update NEXT acpmux daemon runs there (daemons outlive the app).
  1. The app as cmux NEXT (CMUX_NEXT_CHIEF_BUILD_ID=com.cmuxterm.app.nightly.cmux-next)
     launches: the old daemon is stopped, tags/cmux-next is NEXT's acpmux home
     ACPMUX_ROOT/builds/<key> (the old path a link to it), the app's own acpmux
     daemon runs there and lists both old sessions; NEXT's Chief home
     ROOT/com.cmuxterm.app.nightly.cmux-next holds M0 in its memory and its
     owner's Chief DM; NIGHTLY's ROOT/default did not change.
  2. NEXT quits and launches again: both adopted.json records are unchanged.

Exit 0 when every step passed; the first failed step's number (10 for step 0) otherwise.
Usage: next-home-adopt-live.py --tag TAG --app APP [--reply-wait 240] [--out DIR]
"""
import argparse, json, os, shutil, socket, sqlite3, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--tag", required=True)
ap.add_argument("--app", required=True)
ap.add_argument("--reply-wait", type=float, default=240)
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = ap.parse_args()
if os.environ.get("ACPMUX_AGENT_LAUNCH", "").strip().lower() == "deny" or os.environ.get("CMUX_AGENTS_DISABLED", "").strip() == "1":
    sys.exit("next-home-adopt-live.py: step 0 needs a Chief reply; submit the job with `nx-remote --allow-agents`")

TAG = opts.tag
SCRATCH = tempfile.mkdtemp(prefix="nha-", dir="/tmp")
ROOT = os.path.join(SCRATCH, "chief")
NIGHTLY_HOME = os.path.join(ROOT, "default")
NEXT = "com.cmuxterm.app.nightly.cmux-next"
NEXT_HOME = os.path.join(ROOT, NEXT)
ACPMUX_ROOT = os.path.join(SCRATCH, "acpmux")
OLD_ACPMUX = os.path.join(ACPMUX_ROOT, "tags", "cmux-next")
NEXT_ACPMUX = os.path.join(ACPMUX_ROOT, "builds", NEXT)
SESSIONS = {"01a10000-0000-7000-8000-0000000000e1": f"live-old-a-{TAG}", "01a10000-0000-7000-8000-0000000000e2": f"live-old-b-{TAG}"}
os.makedirs(opts.out, exist_ok=True)


def say(*parts):
    print(*parts, flush=True)


def clean_env():
    return {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_", "XDG_RUNTIME"))}


class App:
    def __init__(self, app, tag):
        self.app, self.tag = app, tag
        self.binary = os.path.join(app, "Contents/MacOS/cmux DEV")
        self.cli = os.path.join(app, "Contents/Resources/bin/cmux")
        self.acpmux = os.path.join(app, "Contents/Resources/bin/acpmux")
        self.proc = None

    @property
    def socket(self):
        """The control socket the app's own rule names (build_names.py): ~/.local/state/cmux first, then /tmp."""
        here = os.path.dirname(os.path.abspath(__file__))
        found = subprocess.run([sys.executable, os.path.join(here, "build_names.py"), "socket", self.app],
                               capture_output=True, text=True).stdout.split()
        return next((p for p in found if os.path.exists(p)), found[0] if found else f"/tmp/cmux-debug-{self.tag}.sock")

    def rpc(self, method, params=None, timeout=30):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(self.socket)
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

    def launch(self, build):
        keep = ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR")
        env = {k: v for k, v in os.environ.items() if k in keep}
        config = os.path.join(SCRATCH, "cmux.json")
        open(config, "w").write("{}")
        env.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
                    "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config,
                    "CMUX_NEXT_CHIEF_ROOT": ROOT, "CMUX_NEXT_CHIEF_BUILD_ID": build, "CMUX_NEXT_ACPMUX_ROOT": ACPMUX_ROOT})
        log = open(os.path.join(opts.out, f"app-{self.tag}.log"), "a")
        self.proc = subprocess.Popen([self.binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        up = wait(lambda: (self.rpc("debug.windows") or {}).get("windows"), 300)
        self.rpc("action.run", {"id": "home.show"})
        say(f"app as {build} pid {self.proc.pid}: {'up' if up else 'NOT UP'}")
        return bool(up)

    def send(self, home, text):
        """`text` through the bundled `cmux chief -p --chief-home`; True when the Chief replied."""
        if not wait(lambda: chief_conversation(home), 120, 1):
            say("no Chief conversation in the owner of", home)
            return False
        try:
            run = subprocess.run([self.cli, "--json", "chief", "-p", text, "--chief-home", home, "--no-wait-agents",
                                  "--timeout", str(int(opts.reply_wait))], env=clean_env(), stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True, timeout=opts.reply_wait + 60)
        except subprocess.TimeoutExpired:
            say("cmux chief -p did not end")
            return False
        replies = [line for line in run.stdout.splitlines() if line.strip()]
        say(f"cmux chief -p exit {run.returncode}; {len(replies)} replies; stderr {run.stderr.strip()[-300:]!r}")
        return run.returncode == 0 and bool(replies)

    def quit(self, home):
        self.rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
        try:
            self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            say(f"pid {self.proc.pid} did not quit within 60 s")
        cleanup_chief(self, home)


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def brain_pid(home):
    try:
        pid = int(open(os.path.join(home, "state", "host.lock")).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    comm = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
    return pid if comm.endswith("optchat-chief") else None


def alive(pid):
    return bool(pid) and subprocess.run(["ps", "-p", str(pid)], capture_output=True).returncode == 0


def memory_count(home, text):
    path = os.path.join(home, "optchat", "memory.sqlite3")
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            rows = db.execute("SELECT kind, text FROM messages").fetchall()
        finally:
            db.close()
    except sqlite3.Error:
        return -1
    return sum(1 for kind, body in rows if kind == "user" and text in body)


def chief_owner_socket(home):
    h = 0x811C9DC5
    for byte in home.encode():
        h = ((h ^ byte) * 0x01000193) & 0xFFFFFFFF
    name = f"cmux-chief-{h:08x}.sock"
    base = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip() or "/tmp"
    for candidate in (os.path.join(base, f"cmux-tui-{os.getuid()}", name), f"/tmp/cmux-tui-{os.getuid()}/{name}"):
        if os.path.exists(candidate):
            return candidate
    return None


def owner_call(path, cmd, **fields):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(20)
        conn.connect(path)
        stream = conn.makefile("rwb")
        stream.write((json.dumps({"id": 7, "cmd": cmd, **fields}) + "\n").encode())
        stream.flush()
        for line in stream:
            reply = json.loads(line)
            if reply.get("id") == 7:
                conn.close()
                return reply.get("data") or {}
        conn.close()
    except (OSError, ValueError):
        pass
    return {}


def chief_conversation(home):
    owner = chief_owner_socket(home)
    if not owner:
        return None
    rows = [c for c in owner_call(owner, "conversation-list").get("conversations") or []
            if any((p.get("id") if isinstance(p, dict) else p) == "agent_mux" for p in c.get("participants") or [])]
    rows.sort(key=lambda c: (str(c.get("created_at", "")), str(c.get("id", ""))))
    return rows[0].get("id") if rows else None


def chief_texts(home):
    owner, conversation = chief_owner_socket(home), chief_conversation(home)
    if not owner or not conversation:
        return []
    messages = owner_call(owner, "conversation-snapshot", conversation=conversation, tail=50).get("messages") or []
    return [m.get("text") or " ".join(p.get("text", "") for p in m.get("parts") or []) for m in messages]


def acpmux(app, home, *args):
    return subprocess.run([app.acpmux, *args], env={**clean_env(), "ACPMUX_HOME": home},
                          capture_output=True, text=True, timeout=60)


def daemon_pid(app, home):
    try:
        status = json.loads(acpmux(app, home, "daemon", "status", "--json").stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    same = os.path.realpath(status.get("home") or "") == os.path.realpath(home)
    return status.get("pid") if same and status.get("pid") else None


def cleanup_chief(app, home):
    """The Chief of `home`: its acpmux daemon, then brain and owner (documented stop)."""
    acpmux(app, os.path.join(home, "acpmux"), "daemon", "shutdown")
    subprocess.run([app.cli, "chief", "shutdown", "--chief-home", home], env=clean_env(), capture_output=True, timeout=90)


def snapshot(top):
    out = []
    for dirpath, _, files in os.walk(top):
        for name in files:
            path = os.path.join(dirpath, name)
            if name.endswith("-shm") or os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                out.append((os.path.relpath(path, top), f.read()))
    return sorted(out)


def old_acpmux_layout():
    for sid, name in SESSIONS.items():
        os.makedirs(os.path.join(OLD_ACPMUX, "sessions", sid))
        meta = {"schema": "acpmux.session.v1", "id": sid, "name": name, "harness": "codex", "harnessArgv": [],
                "cwd": "/tmp", "status": "idle", "createdAt": 1760000000000, "updatedAt": 1760000000000}
        open(os.path.join(OLD_ACPMUX, "sessions", sid, "session.json"), "w").write(json.dumps(meta))
    open(os.path.join(OLD_ACPMUX, "config.json"), "w").write(json.dumps(
        {"webAskingModes": {"codex": [f"live-old-config-{TAG}"]},
         "websocket": {"listen": "127.0.0.1:0", "token": os.urandom(12).hex()}}))


app = App(opts.app, TAG)
failed = 0
m0 = f"next adoption check {TAG}: M0 on the shared home, reply with only the word ok."
os.makedirs(os.path.join(NIGHTLY_HOME, "optchat"))
open(os.path.join(NIGHTLY_HOME, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(NIGHTLY_HOME, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
try:
    # 0. the pre-update layout
    app.launch("com.cmuxterm.app.nightly")
    ok0 = wait(lambda: brain_pid(NIGHTLY_HOME), 180) and app.send(NIGHTLY_HOME, m0)
    conversation0 = chief_conversation(NIGHTLY_HOME)
    app.quit(NIGHTLY_HOME)
    acpmux(app, ACPMUX_ROOT, "daemon", "shutdown")
    old_acpmux_layout()
    started = acpmux(app, OLD_ACPMUX, "daemon", "start", "--json")
    old_daemon = daemon_pid(app, OLD_ACPMUX)
    count0 = memory_count(NIGHTLY_HOME, m0)
    say(f"step 0: shared home reply {bool(ok0)}, Chief DM {conversation0}, memory has M0 {count0}x;"
        f" pre-update NEXT acpmux daemon {old_daemon} ({started.returncode})")
    if not (ok0 and conversation0 and count0 == 1 and old_daemon):
        failed = 10
        raise SystemExit
    nightly_before = snapshot(NIGHTLY_HOME)

    # 1. NEXT launches on the new code
    app.launch(NEXT)
    pane = wait(lambda: daemon_pid(app, NEXT_ACPMUX), 120)
    listed = acpmux(app, NEXT_ACPMUX, "ls", "--json").stdout if pane else ""
    sessions_ok = all(name in listed for name in SESSIONS.values())
    link_ok = os.path.islink(OLD_ACPMUX) and os.path.realpath(OLD_ACPMUX) == os.path.realpath(NEXT_ACPMUX)
    config_ok = f"live-old-config-{TAG}" in open(os.path.join(NEXT_ACPMUX, "config.json")).read() if pane else False
    acpmux_record = os.path.join(NEXT_ACPMUX, "adopted.json")
    say(f"step 1: pre-update daemon {old_daemon} alive {alive(old_daemon)}; NEXT pane acpmux {pane} in {NEXT_ACPMUX};"
        f" old sessions listed {sessions_ok}; old path linked {link_ok}; old config kept {config_ok};"
        f" record {os.path.exists(acpmux_record)}")
    next_brain = wait(lambda: brain_pid(NEXT_HOME), 180)
    shown = wait(lambda: any(m0 in t for t in chief_texts(NEXT_HOME)), 120)
    count1 = memory_count(NEXT_HOME, m0)
    chief_record = os.path.join(NEXT_HOME, "adopted.json")
    nightly_same = snapshot(NIGHTLY_HOME) == nightly_before
    say(f"step 1: NEXT Chief brain {next_brain}; owner's Chief DM {chief_conversation(NEXT_HOME)} shows M0 {bool(shown)};"
        f" memory has M0 {count1}x; record {os.path.exists(chief_record)}; NIGHTLY's home unchanged {nightly_same}")
    for record in (acpmux_record, chief_record):
        if os.path.exists(record):
            say(f"{record}: {open(record).read()[:1500]}")
    if not (not alive(old_daemon) and pane and sessions_ok and link_ok and config_ok and os.path.exists(acpmux_record)
            and next_brain and shown and count1 == 1 and os.path.exists(chief_record) and nightly_same):
        failed = failed or 1
    records = [open(r).read() if os.path.exists(r) else None for r in (acpmux_record, chief_record)]

    # 2. a second launch changes nothing
    app.quit(NEXT_HOME)
    acpmux(app, NEXT_ACPMUX, "daemon", "shutdown")
    app.launch(NEXT)
    pane2 = wait(lambda: daemon_pid(app, NEXT_ACPMUX), 120)
    wait(lambda: brain_pid(NEXT_HOME), 180)
    again = [open(r).read() if os.path.exists(r) else None for r in (acpmux_record, chief_record)]
    say(f"step 2: second launch pane acpmux {pane2}; records unchanged {again == records}")
    if not (pane2 and again == records and None not in again):
        failed = failed or 2
except SystemExit:
    pass
finally:
    if app.proc and app.proc.poll() is None:
        app.quit(NEXT_HOME)
    for home in (ACPMUX_ROOT, OLD_ACPMUX, NEXT_ACPMUX):
        if os.path.isdir(home):
            acpmux(app, home, "daemon", "shutdown")
    cleanup_chief(app, NIGHTLY_HOME)
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", "PASS" if failed == 0 else f"FAIL {failed}")
sys.exit(failed)
