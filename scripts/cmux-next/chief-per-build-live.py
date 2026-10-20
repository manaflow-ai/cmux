#!/usr/bin/env python3
"""Live proof of one Chief per build (cmux-lawrence-2 only, an --app-from-fleet
GUI job; run under `zsh -lic` for the Claude login). Everything happens under
a temp Chief root (CMUX_NEXT_CHIEF_ROOT), never ~/.cmux/chief.

  0. The shared home of older builds: app A runs on ROOT/default
     (CMUX_NEXT_CHIEF_HOME), one message M0 gets a reply, A quits (end sessions).
     Messages go through each build's bundled `cmux chief -p --chief-home`
     (the Chief home's conversation owner and brain), never through the Home
     UI: this proof is about the per-build brain, daemons and sockets.
  1. A as NIGHTLY (CMUX_NEXT_CHIEF_BUILD_ID=com.cmuxterm.app.nightly, a DEBUG
     override) resolves ROOT/default: its brain holds that lock, the memory
     still holds M0 once and the owner's Chief DM holds it.
  2. B, a copy of the app named "B.app" with bundle id com.cmuxterm.app.debug
     and no LSEnvironment tag (the untagged DEV build, ad-hoc signed), runs as
     cmux NEXT's NIGHTLY identity
     (CMUX_NEXT_CHIEF_BUILD_ID=com.cmuxterm.app.nightly.cmux-next) at the same
     time as A: two NIGHTLY identities never share one Chief, so its home is
     ROOT/com.cmuxterm.app.nightly.cmux-next, empty (no M0), with its own brain,
     tools socket and acpmux socket.
  3. B quits with quitEndSessions: A's brain is the same process, still alive,
     and A answers a new message.

The app's own (pane) acpmux, per build (S2, cx-is1kf.3): ACPMUX_ROOT stands
for ~/.acpmux (CMUX_NEXT_ACPMUX_ROOT, a DEBUG override). A as NIGHTLY keeps
the shared root itself; B has ACPMUX_ROOT/builds/com.cmuxterm.app.nightly.cmux-next.
Steps 1 to 3 also check: each app's daemon runs in its own home (pid, socket
inode), B's daemon is another process, and B's quit leaves A's daemon (same
pid, same socket inode) running.

The app daemon and control socket, per build (S3, cx-is1kf.4): A (a reload.sh
DEV build) keeps cmux-app-<tag> and /tmp/cmux-debug-<tag>.sock; B, the untagged
DEV build, has names of its build key (cmux-app--650e93e3,
/tmp/cmux-debug--650e93e3.sock, a link to ~/.local/state/cmux since hq#1870), never
release's cmux-app or cmux-debug.sock.
Each app's bundled `cmux` CLI, run outside any app terminal, reaches its own
app's owner daemon (the bundle decides, as in the app). B's start and quit
leave A's owner daemon (same pid) and control socket running. The daemon names
follow the real bundle id, never the DEBUG CMUX_NEXT_CHIEF_BUILD_ID override,
so A never touches the real /tmp/cmux-nightly.sock.

Exit 0 when every step passed; the first failed step's number otherwise.
Usage: chief-per-build-live.py --tag TAG --app APP [--reply-wait 240] [--out DIR]
Submit the nx-remote job with --allow-agents: gui and input jobs default to ACPMUX_AGENT_LAUNCH=deny (cx-tgf4h).
"""
import argparse, json, os, shutil, socket, sqlite3, subprocess, sys, tempfile, time
import re

ap = argparse.ArgumentParser()
ap.add_argument("--tag", required=True)
ap.add_argument("--app", required=True)
ap.add_argument("--reply-wait", type=float, default=240)
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = ap.parse_args()
# cx-tgf4h: nx-remote gui and input jobs run with ACPMUX_AGENT_LAUNCH=deny
# (HQ #2130), so no Chief turn can start; fail at once, not after a reply wait.
if os.environ.get("ACPMUX_AGENT_LAUNCH", "").strip().lower() == "deny" or os.environ.get("CMUX_AGENTS_DISABLED", "").strip() == "1":
    sys.exit("chief-per-build-live.py: this Chief proof needs agents; submit the job with `nx-remote --allow-agents` "
             "(ACPMUX_AGENT_LAUNCH=deny or CMUX_AGENTS_DISABLED=1 is set)")

TAG = opts.tag
# A short path: the brains' sockets (optchat/tools.sock) must fit sun_path
# (104 bytes); a job's TMPDIR is too deep.
SCRATCH = tempfile.mkdtemp(prefix="cpb-", dir="/tmp")
ROOT = os.path.join(SCRATCH, "chief")
NIGHTLY_HOME = os.path.join(ROOT, "default")
TAG_B = f"{TAG}b"
BUNDLE_B = "com.cmuxterm.app.debug"
# fnv1a32 of B's build key (its bundle id): schemas/build-identity/vectors.json.
B_KEY_HASH = "650e93e3"
B_SOCKET = f"/tmp/cmux-debug--{B_KEY_HASH}.sock"
B_SESSION = f"cmux-app--{B_KEY_HASH}"
B_STATE = os.path.expanduser("~/Library/Application Support/cmux/builds/com.cmuxterm.app.debug")
NEXT_NIGHTLY = "com.cmuxterm.app.nightly.cmux-next"
B_HOME = os.path.join(ROOT, NEXT_NIGHTLY)
ACPMUX_ROOT = os.path.join(SCRATCH, "acpmux")
A_ACPMUX = ACPMUX_ROOT
B_ACPMUX = os.path.join(ACPMUX_ROOT, "builds", NEXT_NIGHTLY)
os.makedirs(opts.out, exist_ok=True)


def say(*parts):
    print(*parts, flush=True)


class App:
    def __init__(self, name, app, tag):
        self.name, self.app, self.tag = name, app, tag
        self.binary = os.path.join(app, "Contents/MacOS/cmux DEV")
        self.cli = os.path.join(app, "Contents/Resources/bin/cmux")
        self.acpmux = os.path.join(app, "Contents/Resources/bin/acpmux")
        self.socket = f"/tmp/cmux-debug-{tag}.sock"
        self.proc = None
        self.owner_said = ""

    def answers(self):
        """Whether this app's control socket answers."""
        reply = self.rpc("debug.windows", timeout=10)
        return isinstance(reply, dict) and "error" not in reply

    def owner(self):
        """(session, pid) of this app's owner daemon, as its bundled CLI finds it from
        the bundle alone (no app terminal env), else None. Never starts one."""
        env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_", "XDG_RUNTIME"))}
        try:
            run = subprocess.run([self.cli, "--json", "daemon", "status"], env=env,
                                 capture_output=True, text=True, timeout=30)
            self.owner_said = f"exit {run.returncode}: {run.stdout.strip()[:300]} {run.stderr.strip()[-300:]}"
            status = json.loads(run.stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            self.owner_said = f"{getattr(self, 'owner_said', '')} ({error!r})"
            return None
        return (status.get("session"), status.get("pid")) if status.get("status") == "running" else None

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

    def launch(self, extra):
        keep = ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR")
        env = {k: v for k, v in os.environ.items() if k in keep}
        config = os.path.join(SCRATCH, "cmux.json")
        open(config, "w").write("{}")
        env.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
                    "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config})
        env.update(extra)
        log = open(os.path.join(opts.out, f"app-{self.tag}.log"), "a")
        self.proc = subprocess.Popen([self.binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        up = wait(lambda: (self.rpc("debug.windows") or {}).get("windows"), 300)
        self.rpc("action.run", {"id": "home.show"})
        say(f"{self.name} ({self.tag}) pid {self.proc.pid}: {'up' if up else 'NOT UP'}")
        return bool(up)

    def send(self, home, text):
        """`text` as the person through this build's bundled `cmux chief` (pipe mode,
        `--chief-home`): the Chief home's conversation owner, never the Home UI.
        True when the Chief posted a reply. The brain runs already, so the CLI
        starts nothing; a "started" line on stderr is a failure."""
        if not wait(lambda: chief_conversation(home), 120, 1):
            say(self.name, "no Chief conversation in the owner of", home, chief_owner_socket(home))
            return False
        env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_", "XDG_RUNTIME"))}
        try:
            run = subprocess.run([self.cli, "--json", "chief", "-p", text, "--chief-home", home, "--no-wait-agents",
                                  "--timeout", str(int(opts.reply_wait))], env=env, stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True, timeout=opts.reply_wait + 60)
        except subprocess.TimeoutExpired:
            say(self.name, "cmux chief -p did not end")
            return False
        replies = [line for line in run.stdout.splitlines() if line.strip()]
        say(self.name, f"cmux chief -p exit {run.returncode}; {len(replies)} replies; stderr {run.stderr.strip()[-400:]!r};"
            f" first reply {(replies or [''])[0][:300]}")
        started = "started the Chief" in run.stderr
        return run.returncode == 0 and bool(replies) and not started

    def quit(self, home):
        self.rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
        try:
            self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            say(f"{self.name} pid {self.proc.pid} did not quit within 60 s")
        cleanup(self, home)


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def brain_pid(home):
    """The pid in host.lock while that process runs optchat-chief, else None.
    Never takes the flock: a probe can make a brain that starts at that instant exit."""
    try:
        pid = int(open(os.path.join(home, "state", "host.lock")).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    comm = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
    return pid if comm.endswith("optchat-chief") else None


def alive(pid):
    return subprocess.run(["ps", "-p", str(pid)], capture_output=True).returncode == 0


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
    """The Chief home's conversation owner socket: the app's record in client.log,
    else the owner's rule (ChiefHome.socket: cmux-chief-<fnv1a32 of the root> in
    the Darwin user temp dir)."""
    h = 0x811C9DC5
    for byte in home.encode():
        h = ((h ^ byte) * 0x01000193) & 0xFFFFFFFF
    name = f"cmux-chief-{h:08x}.sock"
    try:
        lines = [l for l in open(os.path.join(home, "client.log")) if "control socket at " in l]
        logged = lines[-1].split("control socket at ", 1)[1].strip() if lines else None
    except OSError:
        logged = None
    if logged and logged.endswith("/" + name) and os.path.exists(logged):
        return logged
    base = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip() or "/tmp"
    for candidate in (os.path.join(base, f"cmux-tui-{os.getuid()}", name), f"/tmp/cmux-tui-{os.getuid()}/{name}"):
        if os.path.exists(candidate):
            return candidate
    return None


def owner_call(path, cmd, **fields):
    """One request to a cmux-tui owner (its line protocol); the reply data, else {}."""
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
    """The id of the Chief DM (the oldest conversation with agent_mux, as `cmux chief`
    selects it) in the conversation owner of `home`, else None."""
    owner = chief_owner_socket(home)
    if not owner:
        return None
    rows = [c for c in owner_call(owner, "conversation-list").get("conversations") or []
            if any((p.get("id") if isinstance(p, dict) else p) == "agent_mux" for p in c.get("participants") or [])]
    rows.sort(key=lambda c: (str(c.get("created_at", "")), str(c.get("id", ""))))
    return rows[0].get("id") if rows else None


def chief_texts(home):
    """(author, text) of the last messages of the Chief DM of `home`, from its owner."""
    owner, conversation = chief_owner_socket(home), chief_conversation(home)
    if not owner or not conversation:
        return []
    messages = owner_call(owner, "conversation-snapshot", conversation=conversation, tail=50).get("messages") or []
    return [(m.get("author"), m.get("text") or " ".join(p.get("text", "") for p in m.get("parts") or []))
            for m in messages]


def acpmux_daemon(app, home):
    """(pid, socket inode) of the acpmux daemon in `home`, else None. Never starts one."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_"))}
    try:
        out = subprocess.run([app.acpmux, "daemon", "status", "--json"], env={**env, "ACPMUX_HOME": home},
                             capture_output=True, text=True, timeout=30).stdout
        status = json.loads(out)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    pid, sock = status.get("pid"), status.get("socket")
    if not pid or not sock or os.path.realpath(status.get("home") or "") != os.path.realpath(home):
        return None
    try:
        return (pid, os.stat(sock).st_ino)
    except OSError:
        return None


def pane_daemon(app, home):
    """The app's own acpmux daemon in `home`: started at launch (the agent pane prewarm),
    else by a new agent chat."""
    found = wait(lambda: acpmux_daemon(app, home), 60)
    if not found:
        say(app.name, "new agent chat", json.dumps(app.rpc("action.run", {"action": "palette.newAgentChat", "focus": True}))[:200])
        found = wait(lambda: acpmux_daemon(app, home), 90)
    return found


def acpmux_shutdown(app, home):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_"))}
    subprocess.run([app.acpmux, "daemon", "shutdown", "--end-agents"], env={**env, "ACPMUX_HOME": home}, capture_output=True, timeout=30)


def cleanup(app, home):
    """The Chief of `home`: its acpmux daemon and router, then brain and owner (documented stop)."""
    acpmux_home = os.path.join(home, "acpmux")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_"))}
    subprocess.run([app.acpmux, "daemon", "shutdown", "--end-agents"], env={**env, "ACPMUX_HOME": acpmux_home}, capture_output=True, timeout=30)
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(5)
        conn.connect(os.path.join(acpmux_home, "router", "router.sock"))
        conn.sendall(b'{"op":"shutdown"}\n')
        conn.recv(4096)
        conn.close()
    except OSError:
        pass
    subprocess.run([app.cli, "chief", "shutdown", "--chief-home", home], env=env, capture_output=True, timeout=90)


def copy_as_b(src):
    """App B: the same build as the untagged DEV build: bundle id com.cmuxterm.app.debug,
    no LSEnvironment tag and a name without one ("cmux DEV <tag>.app" would ship its
    name's tag), so its sockets and session are of its build key."""
    dst = os.path.join(SCRATCH, "B.app")
    subprocess.run(["ditto", src, dst], check=True)
    plist = os.path.join(dst, "Contents/Info.plist")
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE_B}", plist], check=True)
    for key in ("CMUX_TAG", "CMUX_BUNDLE_ID", "CMUX_SOCKET_PATH"):
        subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Delete :LSEnvironment:{key}", plist], capture_output=True)
    signed = subprocess.run(["codesign", "--force", "--deep", "--sign", "-", dst], capture_output=True, text=True)
    say("B signed:", signed.returncode, signed.stderr.strip()[-200:])
    return dst


# This test never resolves a real build's names (hq-6d, 2026-10-14).
REAL = ("cmux-app", "cmux-app-nightly", "cmux-app-cmux-next")
STATE_SOCKETS = os.path.expanduser("~/.local/state/cmux")
for name in (f"cmux-app-{TAG}", B_SESSION, f"/tmp/cmux-debug-{TAG}.sock", B_SOCKET,
             os.path.join(STATE_SOCKETS, f"cmux-debug-{TAG}.sock"), os.path.join(STATE_SOCKETS, os.path.basename(B_SOCKET))):
    file = os.path.basename(name)
    in_socket_dir = name.startswith("/tmp/") or name.startswith(STATE_SOCKETS + "/")
    if name in REAL or (in_socket_dir and (file.startswith("cmux-nightly")
                                           or file in ("cmux-rc.sock", "cmux-staging.sock", "cmux-debug.sock", "cmux.sock"))):
        sys.exit(f"refusing to run: {name} is a real build's name")
a = App("A", opts.app, TAG)
b = None
b_owned = False
b_state_new = False
failed = 0
m0 = f"per-build check {TAG}: M0 on the shared home, reply with only the word ok."
m1 = f"per-build check {TAG}: M1 after B quit, reply with only the word ok."
# The temp homes never push a memory backup and never take in this host's
# old per-tag Chiefs (~/.cmux/mux/tags): a backup setting and a done
# migration record before the first launch.
for home in (NIGHTLY_HOME, B_HOME):
    os.makedirs(os.path.join(home, "optchat"), exist_ok=True)
    open(os.path.join(home, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(NIGHTLY_HOME, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
try:
    # 0. the shared home of older builds
    a.launch({"CMUX_NEXT_CHIEF_HOME": NIGHTLY_HOME, "CMUX_NEXT_ACPMUX_ROOT": ACPMUX_ROOT})
    ok0 = wait(lambda: brain_pid(NIGHTLY_HOME), 180) and a.send(NIGHTLY_HOME, m0)
    say(f"step 0: shared home {NIGHTLY_HOME}: brain and reply {'ok' if ok0 else 'FAILED'}")
    a.quit(NIGHTLY_HOME)
    acpmux_shutdown(a, os.path.join(ACPMUX_ROOT, "builds", "com.cmuxterm.app.debug." + re.sub(r"[^a-z0-9]+", ".", TAG.lower()).strip(".")))
    if not ok0:
        failed = failed or 10
        raise SystemExit
    # 1. A as NIGHTLY under the temp root keeps that home
    a.launch({"CMUX_NEXT_CHIEF_ROOT": ROOT, "CMUX_NEXT_CHIEF_BUILD_ID": "com.cmuxterm.app.nightly",
              "CMUX_NEXT_ACPMUX_ROOT": ACPMUX_ROOT})
    a_brain = wait(lambda: brain_pid(NIGHTLY_HOME), 180)
    a_acpmux = pane_daemon(a, A_ACPMUX)
    say(f"step 1: NIGHTLY acpmux (pid, socket inode) {a_acpmux} in {A_ACPMUX}")
    shown_m0 = wait(lambda: any(t == m0 for _, t in chief_texts(NIGHTLY_HOME)), 60)
    count = memory_count(NIGHTLY_HOME, m0)
    others = sorted(n for n in os.listdir(ROOT) if n not in ("default", NEXT_NIGHTLY) and not n.startswith("."))
    a_owner = wait(a.owner, 60)
    say(f"step 1: NIGHTLY brain {a_brain} on default; the owner's Chief DM holds M0: {bool(shown_m0)}; memory has M0 {count}x; other homes {others}")
    say(f"step 1: A owner daemon (session, pid) {a_owner}; control socket {a.socket}; daemon status said {a.owner_said}")
    if not (a_brain and shown_m0 and count == 1 and not others and a_acpmux
            and a_owner and a_owner[0] == f"cmux-app-{TAG}" and a_owner[1]):
        failed = failed or 1
    probe = App("probe", opts.app, TAG_B)
    probe.socket = B_SOCKET
    if os.path.exists(B_SOCKET) and probe.answers():
        say(f"step 2: another untagged DEV build already serves {B_SOCKET}; B cannot run here")
        failed = failed or 2
        raise SystemExit
    # 2. B at the same time: its own empty home and brain
    b = App("B", copy_as_b(opts.app), TAG_B)
    b.socket = B_SOCKET
    # B's key session must not exist yet: else B would adopt another untagged
    # DEV build's daemon (and its terminals), and the cleanup would stop it.
    # Absent only when the session's socket refuses the connection
    # (server.unavailable); any other answer may be a real untagged DEV daemon.
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_", "XDG_RUNTIME"))}
    probe = subprocess.run([b.cli, "--json", "--session", B_SESSION, "daemon", "status"], env=env,
                           capture_output=True, text=True, timeout=30)
    if probe.returncode != 3 or "server.unavailable" not in probe.stdout + probe.stderr:
        say(f"step 2: {B_SESSION} is not provably absent (exit {probe.returncode}: {(probe.stdout + probe.stderr).strip()[:300]}); B cannot run here")
        b_owned = False
        failed = failed or 2
        raise SystemExit
    b_owned = True
    b_state_new = not os.path.exists(B_STATE)
    b.launch({"CMUX_NEXT_CHIEF_ROOT": ROOT, "CMUX_NEXT_CHIEF_BUILD_ID": NEXT_NIGHTLY,
              "CMUX_NEXT_ACPMUX_ROOT": ACPMUX_ROOT})
    b_brain = wait(lambda: brain_pid(B_HOME), 180)
    b_acpmux = pane_daemon(b, B_ACPMUX)
    a_acpmux_2 = acpmux_daemon(a, A_ACPMUX)
    say(f"step 2: B acpmux {b_acpmux} in {B_ACPMUX}; A acpmux now {a_acpmux_2} (was {a_acpmux})")
    b_dm = wait(lambda: chief_conversation(B_HOME), 60)
    b_shown = chief_texts(B_HOME)
    # A brain opens its tools socket after it connects; give B's a bounded wait.
    wait(lambda: os.path.exists(os.path.join(B_HOME, "optchat", "tools.sock")), 60)
    sockets = {h: os.path.exists(os.path.join(h, "optchat", "tools.sock")) for h in (NIGHTLY_HOME, B_HOME)}
    say(f"step 2: B brain {b_brain} on {B_HOME}; A brain {brain_pid(NIGHTLY_HOME)}; B's Chief DM {b_dm} holds {len(b_shown)} messages;"
        f" M0 in B: {any(t == m0 for _, t in b_shown)}; tools sockets {sockets}; memory M0 in B {memory_count(B_HOME, m0)}")
    b_owner = wait(b.owner, 60)
    a_owner_2 = a.owner()
    b_state = os.path.join(B_STATE, "tui")
    say(f"step 2: B daemon status said {b.owner_said}")
    say(f"step 2: B owner {b_owner} (want session {B_SESSION}); B control socket {B_SOCKET} answers:"
        f" {b.answers()}; B state dir {b_state} exists {os.path.isdir(b_state)};"
        f" A owner now {a_owner_2} (was {a_owner})")
    if not (b_brain and b_brain != a_brain and b_dm and not any(t == m0 for _, t in b_shown) and all(sockets.values())
            and memory_count(B_HOME, m0) <= 0
            and b_acpmux and a_acpmux_2 == a_acpmux and b_acpmux[0] != (a_acpmux or (0,))[0]
            and b_owner and b_owner[0] == B_SESSION and b_owner[1] and b_owner[1] != (a_owner or (0, 0))[1]
            and a_owner_2 == a_owner and b.answers() and a.answers() and os.path.isdir(b_state)):
        failed = failed or 2
    # 3. B quits; A's brain is untouched and answers
    b.quit(B_HOME)
    acpmux_shutdown(b, B_ACPMUX)
    after = brain_pid(NIGHTLY_HOME)
    a_acpmux_3 = acpmux_daemon(a, A_ACPMUX)
    replied = a.send(NIGHTLY_HOME, m1)
    a_owner_3 = a.owner()
    say(f"step 3: after B quit, A brain {after} (was {a_brain}, alive {bool(a_brain) and alive(a_brain)}); A replied {replied};"
        f" A acpmux {a_acpmux_3} (was {a_acpmux}); A owner {a_owner_3} (was {a_owner});"
        f" A control socket answers {a.answers()}")
    if not (after == a_brain and alive(a_brain) and replied and a_acpmux_3 == a_acpmux
            and a_owner_3 == a_owner and a.answers()):
        failed = failed or 3
except SystemExit:
    pass
finally:
    if a.proc and a.proc.poll() is None:
        a.quit(NIGHTLY_HOME)
    if b and b.proc and b.proc.poll() is None:
        b.quit(B_HOME)
    # The apps' own acpmux daemons (quitEndSessions ends them; this is the backstop).
    acpmux_shutdown(a, A_ACPMUX)
    if b:
        acpmux_shutdown(b, B_ACPMUX)
    if b and b_owned:
        # B's own owner daemon (its per-key session, absent before B started), if
        # quitEndSessions left it, and the state it wrote under its key.
        env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_"))}
        stop = subprocess.run([b.cli, "--json", "daemon", "stop", "--session", B_SESSION, "--end-terminals"], env=env,
                              capture_output=True, text=True, timeout=60)
        say(f"cleanup: B daemon stop exit {stop.returncode}: {(stop.stdout + stop.stderr).strip()[:300]}")
        if b_state_new:
            shutil.rmtree(B_STATE, ignore_errors=True)
    # Nothing of the run stays: the B copy and the temp homes with their memory.
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", "PASS" if failed == 0 else f"FAIL {failed}")
sys.exit(failed)
